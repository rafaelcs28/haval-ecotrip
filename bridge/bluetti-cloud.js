'use strict';

// ── Bluetti Cloud (nativo, sem Home Assistant) ───────────────────────────────
// Porta do que a integração oficial bluetti-home-assistant faz, direto em Node.
// A integração NÃO é local (apesar do iot_class dizer local_polling): tudo passa
// pela nuvem da Bluetti. Superfície completa:
//   OAuth2 authorization_code em sso.bluettipower.com (client_id/secret são os
//   mesmos hardcoded no repo oficial — config_flow.py importa como default).
//   REST em gw.bluettipower.com:
//     GET  /api/bluiotdata/ha/v1/devices        → SNs do usuário
//     POST /api/bluiotdata/ha/v1/bindDevices    → obrigatório antes de operar
//     GET  /api/bluiotdata/ha/v1/deviceStates   → stateList (fnCode/fnValue)
//     POST /api/bluiotdata/ha/v1/fulfillment    → controle
//   WS STOMP em gw.bluettipower.com/.../ws-coordination/websocket: só NOTIFICA
//   que algo mudou num SN; o valor vem do re-poll do deviceStates.
//
// Atualização automática = 3 coisas:
//   1. push do WS → re-poll imediato do SN que mudou (latência ~1s)
//   2. poll de fundo (BLUETTI_POLL_MS, default 60s) como rede de segurança
//   3. refresh do OAuth em background — só precisa de login manual uma vez
//      (e de novo só se o refresh_token morrer, aí `needsReauth` acende).

const fs   = require('fs');
const path = require('path');
const WebSocket = require('ws');

const SSO = 'https://sso.bluettipower.com';
const GW  = 'https://gw.bluettipower.com';
const WSS = 'wss://gw.bluettipower.com/api/edgeiotgw/ws-coordination/websocket';
// Credencial pública da integração oficial (bluetti-home-assistant,
// custom_components/bluetti/config_flow.py: ClientCredential("HomeAssistant", ...)).
const CLIENT_ID     = 'HomeAssistant';
const CLIENT_SECRET = 'SG9tZUFzc2lzdGFudA==';

const POLL_MS        = +(process.env.BLUETTI_POLL_MS || 60_000);
const TOKEN_CHECK_MS = 30 * 60_000;         // checa validade do token a cada 30min
const REFRESH_AHEAD  = 7 * 24 * 3600_000;   // renova quando faltar < 7 dias
const REFRESH_MIN_GAP = 3600_000;           // nunca 2 refresh na mesma hora
const HTTP_TIMEOUT   = 12_000;

// ── Estado ───────────────────────────────────────────────────────────────────
let DATA_DIR   = __dirname;
let TOKEN_FILE = path.join(DATA_DIR, 'bluetti_tokens.json');
let _log       = (...a) => console.log('[bluetti-cloud]', ...a);
let _onUpdate  = null;               // callback(snapshot) a cada mudança de estado

let _tok = null;                     // { access_token, refresh_token, expires_at, ... }
let _authPrefix = null;              // '' ou 'Bearer ' — descoberto no 1º request
let _needsReauth = false;
let _lastRefreshAt = 0;
let _refreshing = null;

const _devices = new Map();          // SN(upper) → { sn, model, name, online, states, ts }
let _bootstrapped = false;
let _lastError = null;
let _lastPollAt = 0;
let _pending = new Map();            // SN → timer de debounce do push

let _ws = null, _wsConnected = false, _wsUser = null, _wsBackoff = 1000, _hbTimer = null;
// Códigos de ERROR do STOMP que NÃO adiantam retentar. 600 = "Upgrade required,
// and then reconfigure the BLUETTI integration": o protocolo que este cliente
// fala deixou de ser aceito. Reconectar não conserta — e como o backoff zerava no
// CONNECTED (que chega ANTES do ERROR do SUBSCRIBE), virava laço de ~2 tentativas
// por segundo: 636 mil reconexões em 4 dias martelando o servidor da Bluetti.
// O poll REST continua funcionando e é de onde os dados já vinham.
const WS_FATAL = new Set([600]);
let _wsGaveUp = null;
let _wsClosedAt = 0, _wsOpenedAt = 0, _wsMsgs = 0;

// ── Persistência ─────────────────────────────────────────────────────────────
function _atomicWrite(file, data) {
  const tmp = file + '.tmp-' + process.pid;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, file);
}
function _loadTokens() {
  try {
    const raw = JSON.parse(fs.readFileSync(TOKEN_FILE, 'utf8'));
    if (raw && raw.access_token) { _tok = raw; _authPrefix = raw.auth_prefix ?? null; }
  } catch (_) { _tok = null; }
}
function _saveTokens() {
  try { _atomicWrite(TOKEN_FILE, JSON.stringify({ ..._tok, auth_prefix: _authPrefix }, null, 2)); }
  catch (e) { _log('falha salvando token:', e.message); }
}

// ── OAuth2 ───────────────────────────────────────────────────────────────────
function redirectUri() {
  const base = (process.env.BRIDGE_PUBLIC_URL || 'https://bridge.malha.dev').replace(/\/$/, '');
  // Path do callback é configurável porque não se sabe se o SSO da Bluetti valida
  // redirect_uri contra whitelist. Se recusar o nosso, basta apontar pro path que
  // o HA usa (/auth/external/callback) — o bridge atende os dois.
  const p = process.env.BLUETTI_REDIRECT_PATH || '/api/bluetti/oauth/callback';
  return base + (p.startsWith('/') ? p : '/' + p);
}
function authUrl(state) {
  const q = new URLSearchParams({
    response_type: 'code',
    client_id: CLIENT_ID,
    redirect_uri: redirectUri(),
    state,
  });
  return `${SSO}/oauth2/grant?${q}`;
}

// O refresh do SSO da Bluetti é fora do padrão: exige o header `Authorization`
// com o access_token ATUAL (cru, sem "Bearer") junto do grant_type=refresh_token.
// Sem ele responde 400 invalid_grant, e com "Bearer " também falha. É por isso que
// o refresh da integração oficial do HA não funciona (o helper OAuth do HA não
// manda header nenhum) — testado nos dois formatos, só o cru passa.
async function _tokenRequest(body) {
  const headers = { 'Content-Type': 'application/x-www-form-urlencoded' };
  if (body.grant_type === 'refresh_token' && _tok?.access_token) headers.Authorization = _tok.access_token;
  const r = await fetch(`${SSO}/oauth2/token`, {
    method: 'POST',
    headers,
    body: new URLSearchParams({ client_id: CLIENT_ID, client_secret: CLIENT_SECRET, ...body }),
    signal: AbortSignal.timeout(HTTP_TIMEOUT),
  });
  const txt = await r.text();
  let j = null; try { j = JSON.parse(txt); } catch (_) {}
  if (!j || j.error || !j.access_token) {
    throw new Error(`token endpoint: ${r.status} ${j?.error_description || j?.error || txt.slice(0, 200)}`);
  }
  return j;
}
function _store(j) {
  const now = Date.now();
  _tok = {
    // Se o servidor rotacionar o refresh_token, vem no payload; se não vier, mantém
    // o atual (perder esse campo obrigaria login manual no próximo ciclo).
    refresh_token: _tok?.refresh_token,
    ...j,
    obtained_at: now,
    expires_at: j.expires_at ? j.expires_at * 1000 :
                (j.expires_in ? now + j.expires_in * 1000 : now + 30 * 24 * 3600_000),
  };
  _needsReauth = false;
  _saveTokens();
}

// Troca o code do callback pelo token. Depois disso o bridge se sustenta sozinho.
async function exchangeCode(code) {
  _store(await _tokenRequest({
    grant_type: 'authorization_code',
    code,
    redirect_uri: redirectUri(),
  }));
  _log('token obtido, expira em', new Date(_tok.expires_at).toISOString());
  _bootstrapped = false;
  await bootstrap();
  return true;
}

async function _refresh(force = false) {
  if (_refreshing) return _refreshing;
  if (!_tok || !_tok.refresh_token) { _needsReauth = true; return false; }
  const now = Date.now();
  if (!force && now - _lastRefreshAt < REFRESH_MIN_GAP) return false;
  _lastRefreshAt = now;
  _refreshing = (async () => {
    try {
      _store(await _tokenRequest({ grant_type: 'refresh_token', refresh_token: _tok.refresh_token }));
      _log('refresh ok, novo expiry', new Date(_tok.expires_at).toISOString());
      _wsReconnect('token renovado');
      return true;
    } catch (e) {
      _log('refresh falhou:', e.message);
      // invalid_grant = refresh_token morreu → só login manual resolve
      if (/invalid_grant|invalid_token|expired/i.test(e.message)) _needsReauth = true;
      return false;
    } finally { _refreshing = null; }
  })();
  return _refreshing;
}

function _tokenValid() {
  return !!(_tok && _tok.access_token && (_tok.expires_at || 0) - 30_000 > Date.now());
}
async function _tokenCheck() {
  if (!_tok) return;
  const remain = (_tok.expires_at || 0) - Date.now();
  if (remain < REFRESH_AHEAD) await _refresh();
}

// ── REST ─────────────────────────────────────────────────────────────────────
// A integração oficial manda `Authorization: <token>` cru (sem "Bearer"). Se o
// servidor recusar, tenta com prefixo e memoriza o que funcionou.
async function _raw(method, p, { params, body, prefix } = {}) {
  const url = new URL(GW + p);
  if (params) for (const [k, v] of Object.entries(params)) if (v != null) url.searchParams.set(k, v);
  const headers = { Authorization: (prefix ?? _authPrefix ?? '') + (_tok?.access_token || '') };
  const init = { method, headers, signal: AbortSignal.timeout(HTTP_TIMEOUT) };
  if (body && method !== 'GET') { headers['Content-Type'] = 'application/json'; init.body = JSON.stringify(body); }
  const r = await fetch(url, init);
  const txt = await r.text();
  let j = null; try { j = JSON.parse(txt); } catch (_) {}
  return { http: r.status, json: j, text: txt };
}

async function _req(method, p, opts = {}) {
  if (!_tok) throw new Error('sem token — faça o OAuth em /api/bluetti/oauth/start');
  if (!_tokenValid()) await _refresh(true);

  let res = await _raw(method, p, opts);
  const bad = (x) => x.http === 401 || x.http === 403 || [803, 805].includes(x.json?.code ?? x.json?.msgCode);

  // 1ª vez: descobre se o header vai cru ou com "Bearer "
  if (bad(res) && _authPrefix === null) {
    const alt = await _raw(method, p, { ...opts, prefix: 'Bearer ' });
    if (!bad(alt)) { _authPrefix = 'Bearer '; _saveTokens(); res = alt; }
    else { _authPrefix = ''; }
  }
  // Token expirado de verdade → refresh + 1 retry
  if (bad(res)) {
    if (await _refresh(true)) res = await _raw(method, p, opts);
  }
  if (bad(res)) { _needsReauth = true; throw new Error(`token rejeitado (${res.http}/${res.json?.msgCode ?? '-'})`); }
  if (res.http >= 400) throw new Error(`HTTP ${res.http} em ${p}: ${res.text.slice(0, 200)}`);
  const code = res.json?.msgCode ?? res.json?.code;
  if (code != null && code !== 0) throw new Error(`msgCode ${code} em ${p}: ${res.json?.message || ''}`);
  return res.json?.data;
}

const getUserProducts = ()      => _req('GET',  '/api/bluiotdata/ha/v1/devices');
const bindDevices     = (sns)   => _req('POST', '/api/bluiotdata/ha/v1/bindDevices', { body: { bindSnList: sns } });
const getDeviceStates = (sns)   => _req('GET',  '/api/bluiotdata/ha/v1/deviceStates', { params: { sns } });
const controlDevice   = (sn, fnCode, fnValue) =>
  _req('POST', '/api/bluiotdata/ha/v1/fulfillment', { body: { sn, fnCode, fnValue: String(fnValue) } });

// ── Normalização ─────────────────────────────────────────────────────────────
// O payload da nuvem é genérico (fnCode/fnValue/fnType). As entidades que o HA
// criava eram slug(fnName), então normalizo pelos DOIS: fnCode conhecido e, como
// fallback, slug do fnName — assim o shape sai idêntico ao que /api/bluetti-status
// devolvia via HA, independente de quais fnCodes o modelo expõe.
function _slug(s) {
  return String(s || '').toLowerCase().normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
}
const FIELDS = {
  battery_pct:      { codes: ['SOC'],                  names: ['battery_level', 'soc'],                     kind: 'num'  },
  pv_in_w:          { codes: ['PVAllTotalPower'],      names: ['photovoltaics_input_power', 'pv_input_power'], kind: 'num' },
  grid_in_w:        { codes: ['GridAllTotalPower'],    names: ['grid_input_power'],                         kind: 'num'  },
  ac_out_w:         { codes: ['ACLoadAllTotalPower'],  names: ['alternating_current_out_power', 'ac_output_power'], kind: 'num' },
  dc_out_w:         { codes: ['DCLoadAllTotalPower'],  names: ['direct_current_out_power', 'dc_output_power'],  kind: 'num' },
  battery_time_min: { codes: ['DsgFullTime', 'BatteryTime'], names: ['battery_time_in_minutes'],            kind: 'num'  },
  full_charge_min:  { codes: ['ChgFullTime'],          names: ['full_charge_time_in_minutes'],              kind: 'num'  },
  ac_on:            { codes: ['SetCtrlAc'],            names: ['ac'],                                       kind: 'bool' },
  dc_on:            { codes: ['SetCtrlDc'],            names: ['dc'],                                       kind: 'bool' },
  ac_eco_on:        { codes: ['SetACECO'],             names: ['ac_eco'],                                    kind: 'bool' },
  dc_eco_on:        { codes: ['SetDCECO'],             names: ['dc_eco'],                                    kind: 'bool' },
  power_on:         { codes: ['SetCtrlPowerOn'],       names: ['power_switch', 'main_unit_power_switch'],    kind: 'bool' },
  inv_state:        { codes: ['InvWorkState'],         names: ['inverter_status'],                           kind: 'mode' },
  working_mode:     { codes: ['SetCtrlWorkMode'],      names: ['working_mode', 'work_mode'],                 kind: 'mode' },
};

function _num(v) { if (v == null || v === '') return null; const n = +v; return Number.isFinite(n) ? n : null; }
function _bool(v) {
  if (v == null || v === '') return null;
  const s = String(v).toLowerCase();
  if (['1', 'true', 'on', 'open'].includes(s)) return true;
  if (['0', 'false', 'off', 'close'].includes(s)) return false;
  return null;
}

function normalize(dev) {
  const byCode = new Map(), byName = new Map();
  for (const st of dev.states || []) {
    if (st.fnCode) byCode.set(st.fnCode, st);
    const sl = _slug(st.fnName);
    if (sl && !byName.has(sl)) byName.set(sl, st);
  }
  const out = { sn: dev.sn, name: dev.name || null, model: dev.model || null, online: dev.online === '1' };
  for (const [field, def] of Object.entries(FIELDS)) {
    let st = def.codes.map(c => byCode.get(c)).find(Boolean);
    if (!st) st = def.names.map(n => byName.get(n)).find(Boolean);
    if (!st) { out[field] = null; continue; }
    if (def.kind === 'num')  out[field] = _num(st.fnValue);
    else if (def.kind === 'bool') out[field] = _bool(st.fnValue);
    else {
      const m = (st.supportModeValues || []).find(v => String(v.code) === String(st.fnValue));
      out[field] = m ? (m.name || m.code) : (st.fnValue ?? null);
    }
  }
  // reachable: `online` da nuvem NÃO é confiável sozinho — estação sem
  // comunicação há dias continua vindo online=1 com todo valor zerado (é o caso
  // do Sítio hoje). Tratar isso como "reachable" faria o watchdog gritar AC off +
  // bateria crítica de mentira. Então exijo sinal de vida: algum campo > 0.
  // Bateria em passthrough real nunca dá SOC=0 (com 0% a estação desliga e para
  // de reportar), logo tudo-zero = dado morto, não apagão.
  const NUM = ['battery_pct', 'grid_in_w', 'ac_out_w', 'dc_out_w', 'pv_in_w'];
  const any   = NUM.some(k => out[k] != null);
  const alive = NUM.some(k => (out[k] ?? 0) > 0);
  out.stale_zeros = !!(out.online && any && !alive);
  out.reachable = out.online && any && alive;
  out.fn = Object.fromEntries([...byCode.entries()].map(([k, v]) => [k, v.fnValue]));
  out.ts = dev.ts || Date.now();
  out.age_ms = Date.now() - out.ts;
  return out;
}

function snapshot() {
  const devices = {};
  for (const [sn, dev] of _devices) devices[sn] = normalize(dev);
  return {
    ready: _bootstrapped && _devices.size > 0,
    devices,
    ws: _wsConnected,
    ts: _lastPollAt || null,
    needs_reauth: _needsReauth,
    error: _lastError,
  };
}

// ── Poll ─────────────────────────────────────────────────────────────────────
// O /devices traz o catálogo completo (inclui supportModeValues e sensorInfo); o
// /deviceStates traz só fnCode+fnValue. Merge por fnCode preservando os metadados
// do bootstrap — sem isso o working_mode volta como "workmode_3" cru em vez de
// "Customized UPS" no primeiro poll.
function _mergeStateList(prev, incoming) {
  if (!Array.isArray(incoming) || !incoming.length) return prev;
  const byCode = new Map((prev || []).map(s => [s.fnCode, s]));
  for (const s of incoming) {
    const old = byCode.get(s.fnCode);
    byCode.set(s.fnCode, old ? {
      ...old, ...s,
      supportModeValues: (s.supportModeValues && s.supportModeValues.length) ? s.supportModeValues : old.supportModeValues,
      sensorInfo: s.sensorInfo || old.sensorInfo,
    } : s);
  }
  return [...byCode.values()];
}

function _mergeStates(sn, data) {
  const key = String(sn).toUpperCase();
  const prev = _devices.get(key) || { sn, states: [] };
  const next = {
    sn: data.sn || sn,
    model: data.model || prev.model,
    name: data.name || prev.name,
    online: data.online ?? prev.online,
    bound: data.isBindByCurUser ?? prev.bound,
    states: _mergeStateList(prev.states, data.stateList),
    ts: Date.now(),
  };
  _devices.set(key, next);
}

// A única forma real de perder o bind é desbindar no app da Bluetti (o HA não tem
// chamada de unbind: o `_handle_unbind` dele só limpa entidade local). Se acontecer,
// o deviceStates vem com isBindByCurUser='0' e a leitura morre — então re-bindo
// sozinho, no máximo 1x a cada 10min por SN (o bind zera o cache da sessão, mas
// desbindado não há cache nenhum pra preservar).
const _rebindAt = new Map();
async function _rebindIfNeeded() {
  const now = Date.now();
  const need = [...
    _devices.values()].filter(d => String(d.bound) === '0' && (now - (_rebindAt.get(d.sn) || 0)) > 600_000);
  if (!need.length) return;
  for (const d of need) _rebindAt.set(d.sn, now);
  const sns = need.map(d => d.sn);
  _log('SN desbindado na nuvem, re-bindando:', sns.join(', '));
  try { await bindDevices(sns); await getDeviceStates(sns.join(',')); }
  catch (e) { _log('re-bind falhou:', e.message); }
}

async function poll(sns) {
  const list = sns && sns.length ? sns : [..._devices.keys()];
  if (!list.length) return snapshot();
  try {
    const data = await getDeviceStates(list.join(','));
    for (const d of data || []) _mergeStates(d.sn, d);
    _lastPollAt = Date.now();
    _lastError = null;
    await _rebindIfNeeded();
  } catch (e) {
    _lastError = e.message;
    _log('poll falhou:', e.message);
  }
  const snap = snapshot();
  if (_onUpdate) { try { _onUpdate(snap); } catch (_) {} }
  return snap;
}

// ── WS STOMP (só notificação: "mudou algo no SN X") ──────────────────────────
function _stompFrame(cmd, headers, body = '') {
  let s = cmd + '\n';
  for (const [k, v] of Object.entries(headers)) s += `${k}:${v}\n`;
  return s + '\n' + body + '\0';
}
function _stompParse(chunk) {
  const nul = chunk.indexOf('\0');
  const raw = nul >= 0 ? chunk.slice(0, nul) : chunk;
  const sep = raw.indexOf('\n\n');
  const head = sep >= 0 ? raw.slice(0, sep) : raw;
  const body = sep >= 0 ? raw.slice(sep + 2) : '';
  const lines = head.split('\n');
  const cmd = (lines.shift() || '').trim();
  const headers = {};
  for (const l of lines) {
    const i = l.indexOf(':');
    if (i > 0) headers[l.slice(0, i).trim()] = l.slice(i + 1).replace(/\\c/g, ':').replace(/\\n/g, '\n').trim();
  }
  return { cmd, headers, body };
}

function _wsPushDebounced(sn) {
  const key = String(sn).toUpperCase();
  if (_pending.has(key)) return;
  _pending.set(key, setTimeout(() => { _pending.delete(key); poll([key]).catch(() => {}); }, 800));
}

// Fecha o socket anterior SEM gerar uncaughtException. `close()` num socket
// ainda em CONNECTING não lança aqui: o ws chama abortHandshake, que emite
// 'error' num process.nextTick — fora do try/catch, que só cobre o síncrono. E
// como removeAllListeners() acabou de tirar o handler de 'error', o EventEmitter
// promove isso a uncaughtException. Eram ~1300 por dia desde 09/09, e elas
// enchiam o _healthEvents (4958 de 5000 entradas), expulsando os eventos reais.
function _wsDescarta(ws) {
  if (!ws) return;
  try {
    ws.removeAllListeners();
    ws.on('error', () => {});
    if (ws.readyState === 0 /* CONNECTING */) ws.terminate(); else ws.close();
  } catch (_) {}
}

function _wsGiveUp(code, msg) {
  _wsGaveUp = { code, msg, at: Date.now() };
  _log(`ws desistiu (code ${code}) — seguindo só com o poll REST:`, msg);
  _wsDescarta(_ws); _ws = null;
  _wsConnected = false;
  if (_hbTimer) { clearInterval(_hbTimer); _hbTimer = null; }
}

function _wsReconnect(why) {
  if (_wsGaveUp) return;                 // rejeição definitiva: não insiste
  if (_ws) { _wsDescarta(_ws); _ws = null; }
  _wsConnected = false;
  if (_hbTimer) { clearInterval(_hbTimer); _hbTimer = null; }
  if (why) _log('ws reconnect:', why);
  setTimeout(() => connectWs().catch(() => {}), Math.min(_wsBackoff, 30_000));
  _wsBackoff = Math.min(_wsBackoff * 2, 30_000);
}

async function connectWs() {
  // needsReauth (refresh_token recusado) não bloqueia: o access_token ainda vale
  // até 31 dias. Sem isso um refresh falho cegaria o monitor de imediato, quando
  // na verdade ainda há semanas de leitura boa — o alerta já avisa pra religar.
  if (!_tok) return;
  if (!_tokenValid()) await _refresh(true);
  if (!_tokenValid()) return;
  let buf = '';
  const ws = new WebSocket(WSS, { handshakeTimeout: 15_000 });
  _ws = ws;
  ws.on('open', () => {
    _wsOpenedAt = Date.now();
    ws.send(_stompFrame('CONNECT', {
      'accept-version': '1.0,1.1,2.0',
      Host: 'gw.bluettipower.com',
      Authorization: (_authPrefix || '') + _tok.access_token,
      'heart-beat': '10000,10000',
    }));
    if (_hbTimer) clearInterval(_hbTimer);
    _hbTimer = setInterval(() => { try { if (ws.readyState === 1) ws.send('\n'); } catch (_) {} }, 10_000);
  });
  ws.on('message', (data) => {
    buf += data.toString();
    let i;
    while ((i = buf.indexOf('\0')) >= 0) {
      const chunk = buf.slice(0, i); buf = buf.slice(i + 1).replace(/^\n+/, '');
      if (!chunk.trim()) continue;
      _wsMsgs++;
      const f = _stompParse(chunk);
      if (f.cmd === 'CONNECTED') {
        // NÃO zera o backoff aqui: CONNECTED só prova que o socket abriu, e o
        // ERROR do SUBSCRIBE vem logo depois. Zerar aqui é o que fazia o laço
        // apertado. O backoff só volta ao mínimo quando chega MESSAGE, que é a
        // prova de que a inscrição vingou.
        _wsConnected = true;
        _wsUser = f.headers['user-name'] || null;
        _log('ws conectado, user=' + _wsUser);
        ws.send(_stompFrame('SUBSCRIBE', {
          id: 'ecotrip-bridge', ack: 'auto',
          destination: `/ws-subscribe/user/${_wsUser}/notify`,
        }));
      } else if (f.cmd === 'MESSAGE') {
        _wsBackoff = 1000;               // inscrição funcionando de verdade
        let sn = null;
        try { sn = JSON.parse(f.body)?.data?.deviceSn; } catch (_) {}
        if (sn) _wsPushDebounced(sn);
        else poll().catch(() => {});
      } else if (f.cmd === 'ERROR') {
        let code = null;
        try { code = JSON.parse((f.headers.message || '{}').replace(/\\c/g, ':'))?.msgCode; } catch (_) {}
        _log('ws ERROR', code ?? '', (f.headers.message || '').slice(0, 160));
        if (code === 805 || code === 803) _refresh(true).then(() => _wsReconnect('token expirado no ws'));
        else if (WS_FATAL.has(code)) _wsGiveUp(code, (f.headers.message || '').slice(0, 160));
        else _wsReconnect('frame ERROR');
      }
    }
    if (buf.length > 1e6) buf = '';   // guarda contra frame corrompido sem NULL
  });
  ws.on('close', () => { _wsClosedAt = Date.now(); if (_ws === ws) _wsReconnect('close'); });
  ws.on('error', (e) => { _log('ws erro:', e.message); });
}

// ── Bootstrap / loop ─────────────────────────────────────────────────────────
async function bootstrap() {
  const prods = await getUserProducts();
  if (!Array.isArray(prods) || !prods.length) throw new Error('nenhum device na conta Bluetti');
  for (const p of prods) _mergeStates(p.sn, p);
  const sns = prods.map(p => p.sn);
  // bindDevices NÃO é idempotente de graça: re-bindar reseta o cache da sessão na
  // nuvem e o deviceStates passa a devolver tudo zero até o device reportar de
  // novo (observado ao vivo: casa caiu de 100%/54W pra tudo 0 depois de 3 binds
  // em sequência, enquanto a sessão do HA seguia com dado bom). Então só bindo o
  // que a nuvem diz que ainda não está bindado.
  const unbound = prods.filter(p => String(p.isBindByCurUser) !== '1').map(p => p.sn);
  if (unbound.length) {
    _log('bindDevices:', unbound.join(', '));
    try { await bindDevices(unbound); } catch (e) { _log('bindDevices falhou:', e.message); }
  }
  _bootstrapped = true;
  _log('devices:', sns.join(', '));
  await poll(sns);
  await connectWs();
  return snapshot();
}

function start(opts = {}) {
  if (opts.dataDir) { DATA_DIR = opts.dataDir; TOKEN_FILE = path.join(DATA_DIR, 'bluetti_tokens.json'); }
  if (opts.log) _log = opts.log;
  if (opts.onUpdate) _onUpdate = opts.onUpdate;
  _loadTokens();
  if (!_tok) { _log('sem token salvo — abra /api/bluetti/oauth/start?token=<ADMIN_TOKEN> pra autorizar'); }
  else bootstrap().catch(e => { _lastError = e.message; _log('bootstrap falhou:', e.message); });

  setInterval(() => {
    if (!_tok || _needsReauth) return;
    if (!_bootstrapped) return void bootstrap().catch(e => { _lastError = e.message; });
    poll().catch(() => {});
    if (!_wsConnected && !_wsGaveUp) _wsReconnect('poll viu ws off');
  }, POLL_MS);
  setInterval(() => { _tokenCheck().catch(() => {}); }, TOKEN_CHECK_MS);
  setTimeout(() => { _tokenCheck().catch(() => {}); }, 20_000);
}

function status() {
  return {
    has_token: !!_tok,
    needs_reauth: _needsReauth,
    token_expires_at: _tok?.expires_at || null,
    token_expires_in_days: _tok?.expires_at ? +(((_tok.expires_at - Date.now()) / 86400_000).toFixed(1)) : null,
    auth_prefix: _authPrefix,
    bootstrapped: _bootstrapped,
    devices: [..._devices.keys()],
    ws_connected: _wsConnected,
    ws_gave_up: _wsGaveUp,   // {code,msg,at} quando a nuvem rejeitou de vez
    ws_user: _wsUser,
    ws_msgs: _wsMsgs,
    ws_opened_at: _wsOpenedAt || null,
    ws_closed_at: _wsClosedAt || null,
    last_poll_at: _lastPollAt || null,
    last_poll_age_s: _lastPollAt ? Math.round((Date.now() - _lastPollAt) / 1000) : null,
    poll_ms: POLL_MS,
    redirect_uri: redirectUri(),
    last_error: _lastError,
  };
}

module.exports = {
  start, bootstrap, poll, snapshot, status, normalize,
  refreshNow: () => _refresh(true),
  authUrl, redirectUri, exchangeCode,
  getUserProducts, getDeviceStates, controlDevice, bindDevices,
  ready: () => _bootstrapped && _devices.size > 0,
  needsReauth: () => _needsReauth,
  hasToken: () => !!_tok,
};
