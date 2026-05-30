// apns_live_activity.js
// Cliente APNs HTTP/2 mínimo para Live Activities (iOS 16.1+), sem deps externas.
// JWT ES256 manual com `crypto` nativo + HTTP/2 nativo do Node 18+.
//
// Suporta os 3 eventos do ActivityKit:
//   - start  → push-to-start (iOS 17.2+): SERVIDOR cria a Live Activity com o
//              app fechado/bloqueado. Vai pro "push-to-start token" (por TIPO).
//   - update → atualiza uma LA existente. Vai pro token POR ATIVIDADE.
//   - end    → encerra a LA.
//
// Configuração via .env (todas obrigatórias quando ENABLED=true):
//   APNS_ENABLED=true
//   APNS_TEAM_ID=ABCDE12345
//   APNS_KEY_ID=AAAA1111BB
//   APNS_KEY_P8_PATH=/path/key.p8
//   APNS_BUNDLE_ID=br.com.consorciolimpagyn.havalecotrip
//   APNS_ENV=sandbox            # sandbox p/ build de desenvolvimento (Xcode)
//
// API:
//   apns.init();
//   apns.registerStartToken(type, deviceId, tokenHex);    // POST /api/activity/pts-token
//   apns.registerUpdateToken(type, activityId, deviceId, tokenHex); // POST /api/activity/start
//   apns.unregisterActivity(activityId);                  // POST /api/activity/stop
//   await apns.pushStart(type, deviceId, attributes, contentState, { alert, staleDate });
//   await apns.pushUpdate(type, { deviceId, activityId }, contentState, { isFinal, alert, staleDate });
//   apns.enabled / apns.tokenCount();
//
const fs    = require('fs');
const path  = require('path');
const crypto = require('crypto');
const http2 = require('http2');

// Tokens APNs são por-tenant → vão na pasta de dados (ECOTRIP_DATA_DIR), não no código.
const DATA_DIR = process.env.ECOTRIP_DATA_DIR || __dirname;
const TOKENS_FILE = path.join(DATA_DIR, 'activity_tokens.json');

let enabled = false;
let teamId = '', keyId = '', bundleId = '', env = 'sandbox';
let privateKeyPem = '';
// startTokens:  { type, deviceId, token, ts }              — push-to-start (por tipo+device)
// updateTokens: { type, activityId, deviceId, token, ts }  — update por atividade
// alertTokens:  { deviceId, token, ts }                    — notificações de alerta
let startTokens = [];
let updateTokens = [];
let alertTokens = [];
let _jwt = '', _jwtIat = 0;

function _save() {
  try {
    fs.writeFileSync(TOKENS_FILE, JSON.stringify(
      { updatedAt: new Date().toISOString(), startTokens, updateTokens, alertTokens }, null, 2));
  } catch (e) { console.error('[apns] falha salvar tokens:', e.message); }
}

function _load() {
  try {
    if (fs.existsSync(TOKENS_FILE)) {
      const d = JSON.parse(fs.readFileSync(TOKENS_FILE, 'utf8'));
      startTokens  = Array.isArray(d.startTokens)  ? d.startTokens  : [];
      updateTokens = Array.isArray(d.updateTokens) ? d.updateTokens : [];
      alertTokens  = Array.isArray(d.alertTokens)  ? d.alertTokens  : [];
    }
  } catch (e) { console.error('[apns] falha carregar tokens:', e.message); }
}

function init() {
  enabled = process.env.APNS_ENABLED === 'true';
  if (!enabled) { console.log('[apns] desativado (APNS_ENABLED != true)'); return; }
  teamId   = process.env.APNS_TEAM_ID   || '';
  keyId    = process.env.APNS_KEY_ID    || '';
  bundleId = process.env.APNS_BUNDLE_ID || '';
  env      = process.env.APNS_ENV       || 'sandbox';
  const keyPath = process.env.APNS_KEY_P8_PATH || '';
  if (!teamId || !keyId || !bundleId || !keyPath) {
    console.warn('[apns] config incompleta — desabilitando.'); enabled = false; return;
  }
  try { privateKeyPem = fs.readFileSync(keyPath, 'utf8'); }
  catch (e) { console.warn('[apns] falha ler AuthKey:', e.message); enabled = false; return; }
  _load();
  console.log(`[apns] pronto · team=${teamId} bundle=${bundleId} env=${env} · start=${startTokens.length} update=${updateTokens.length}`);
}

// JWT ES256 (reusável ~1h; regenera a cada 50min).
function _getJwt() {
  const now = Math.floor(Date.now() / 1000);
  if (_jwt && (now - _jwtIat) < 50 * 60) return _jwt;
  const header  = Buffer.from(JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' })).toString('base64url');
  const payload = Buffer.from(JSON.stringify({ iss: teamId, iat: now })).toString('base64url');
  const data    = `${header}.${payload}`;
  const sig     = crypto.sign('sha256', Buffer.from(data), { key: privateKeyPem, dsaEncoding: 'ieee-p1363' });
  _jwt = `${data}.${sig.toString('base64url')}`; _jwtIat = now;
  return _jwt;
}

function _apnsHost() {
  return env === 'production' ? 'api.push.apple.com' : 'api.sandbox.push.apple.com';
}

// ── Registro de tokens ───────────────────────────────────────────────────────
function registerStartToken(type, deviceId, tokenHex) {
  if (!enabled || !type || !tokenHex) return;
  startTokens = startTokens.filter(t => !(t.type === type && t.deviceId === deviceId));
  startTokens.push({ type, deviceId: deviceId || '', token: tokenHex, ts: Date.now() });
  _save();
  console.log(`[apns] push-to-start token registrado (type=${type} device=${(deviceId||'').slice(0,8)}…)`);
}

function registerUpdateToken(type, activityId, deviceId, tokenHex) {
  if (!enabled || !activityId || !tokenHex) return;
  const idx = updateTokens.findIndex(t => t.activityId === activityId);
  const rec = { type, activityId, deviceId: deviceId || '', token: tokenHex, ts: Date.now() };
  if (idx >= 0) updateTokens[idx] = rec; else updateTokens.push(rec);
  _save();
  console.log(`[apns] update token registrado (type=${type} activity=${activityId.slice(0,8)}…)`);
}

function unregisterActivity(activityId) {
  if (!enabled) return;
  const before = updateTokens.length;
  updateTokens = updateTokens.filter(t => t.activityId !== activityId);
  if (updateTokens.length !== before) _save();
}

// Token de notificação de alerta (remote notification "normal").
function registerAlertToken(deviceId, tokenHex) {
  if (!enabled || !tokenHex) return;
  alertTokens = alertTokens.filter(t => t.token !== tokenHex && t.deviceId !== (deviceId || ''));
  alertTokens.push({ deviceId: deviceId || '', token: tokenHex, ts: Date.now() });
  _save();
  console.log(`[apns] alert token registrado (device=${(deviceId||'').slice(0,8)}…, total=${alertTokens.length})`);
}

function tokenCount() { return startTokens.length + updateTokens.length + alertTokens.length; }

// ── Envio HTTP/2 pra uma lista de tokens ──────────────────────────────────────
// pushType: 'liveactivity' (topic .push-type.liveactivity) ou 'alert' (topic = bundle).
async function _send(targets, body, pushType = 'liveactivity') {
  if (!enabled || !targets.length) return { sent: 0, dead: [] };
  const jwt = _getJwt();
  const client = http2.connect(`https://${_apnsHost()}`);
  let sent = 0; const dead = [];
  await Promise.all(targets.map(t => new Promise((resolve) => {
    const req = client.request({
      ':method': 'POST',
      ':path':   `/3/device/${t.token}`,
      'authorization':  `bearer ${jwt}`,
      'apns-topic':     pushType === 'alert' ? bundleId : `${bundleId}.push-type.liveactivity`,
      'apns-push-type': pushType,
      'apns-priority':  '10',
      'content-type':   'application/json',
    });
    let status = 0, respBody = '';
    req.on('response', h => { status = h[':status']; });
    req.on('data', c => { respBody += c; });
    req.on('end', () => {
      console.log(`[apns] resp ${status} (${pushType}) token=${t.token.slice(0,8)}…${respBody ? ' body=' + respBody.slice(0,160) : ''}`);
      if (status === 200) { sent++; }
      else {
        console.warn(`[apns] HTTP ${status} token ${t.token.slice(0,8)}…: ${respBody.slice(0,140)}`);
        // Prune só 410 ExpiredToken e 400 BadDeviceToken. NÃO prunar 403
        // BadEnvironmentKeyInToken: enquanto a Apple não ativa o APNs de produção
        // (conta nova), tokens de produção VÁLIDOS dão 403 — prunar perderia o token
        // que precisamos pra notificar quando ativar.
        if (status === 410 || (status === 400 && /BadDeviceToken|BadCollapseId/i.test(respBody))) dead.push(t.token);
      }
      resolve();
    });
    req.on('error', err => { console.warn('[apns] erro req:', err.message); resolve(); });
    req.end(body);
  })));
  client.close();
  return { sent, dead };
}

// ── push-to-start: cria a Live Activity (app fechado/bloqueado) ───────────────
async function pushStart(type, deviceId, attributes, contentState, opts = {}) {
  let targets = startTokens.filter(t => t.type === type && (!deviceId || t.deviceId === deviceId));
  // Gating opcional por device (ex.: só devices com la_songpro=true). Sem isso,
  // qualquer device que registrou o pts-token do tipo receberia a LA.
  if (typeof opts.allow === 'function') targets = targets.filter(t => opts.allow(t.deviceId));
  if (!targets.length) { console.warn(`[apns] pushStart sem token (type=${type})`); return { sent: 0 }; }
  const aps = {
    timestamp: Math.floor(Date.now() / 1000),
    event: 'start',
    'attributes-type': type,
    'attributes': attributes,
    'content-state': contentState,
  };
  if (opts.staleDate) aps['stale-date'] = Math.floor(opts.staleDate / 1000);
  if (opts.alert) { aps.alert = opts.alert; aps.sound = 'default'; }
  const { sent, dead } = await _send(targets, JSON.stringify({ aps }));
  if (dead.length) { startTokens = startTokens.filter(t => !dead.includes(t.token)); _save(); }
  return { sent };
}

// ── update / end: atualiza uma LA existente ───────────────────────────────────
async function pushUpdate(type, sel = {}, contentState, opts = {}) {
  let targets = updateTokens.filter(t => t.type === type);
  if (sel.activityId) targets = targets.filter(t => t.activityId === sel.activityId);
  else if (sel.deviceId) targets = targets.filter(t => t.deviceId === sel.deviceId);
  if (!targets.length) return { sent: 0 };
  const aps = {
    timestamp: Math.floor(Date.now() / 1000),
    event: opts.isFinal ? 'end' : 'update',
    'content-state': contentState,
  };
  if (opts.staleDate) aps['stale-date'] = Math.floor(opts.staleDate / 1000);
  if (opts.dismissalDate) aps['dismissal-date'] = Math.floor(opts.dismissalDate / 1000);
  if (opts.alert) { aps.alert = opts.alert; aps.sound = 'default'; }
  const { sent, dead } = await _send(targets, JSON.stringify({ aps }));
  if (dead.length) { updateTokens = updateTokens.filter(t => !dead.includes(t.token)); _save(); }
  return { sent };
}

// ── Notificação de alerta (banner/som) direto pro app ─────────────────────────
// opts.allow(deviceId) → predicado de gating (prefs por device etc.).
async function pushAlert(title, body, opts = {}) {
  let targets = alertTokens;
  if (typeof opts.allow === 'function') targets = targets.filter(t => opts.allow(t.deviceId));
  if (!targets.length) return { sent: 0 };
  const aps = { alert: { title, body }, sound: opts.silent ? undefined : 'default' };
  if (opts.threadId) aps['thread-id'] = opts.threadId;
  const { sent, dead } = await _send(targets, JSON.stringify({ aps }), 'alert');
  if (dead.length) { alertTokens = alertTokens.filter(t => !dead.includes(t.token)); _save(); }
  return { sent };
}

module.exports = {
  init, registerStartToken, registerUpdateToken, unregisterActivity, registerAlertToken,
  pushStart, pushUpdate, pushAlert, tokenCount,
  get enabled() { return enabled; },
};
