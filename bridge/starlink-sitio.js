'use strict';

// ── Starlink do Sítio via o HA de lá ─────────────────────────────────────────
// O dish só fala gRPC na LAN dele (192.168.100.1:9200) e telemetria por cloud é
// só conta enterprise — então o HA do sítio (integração starlink_grpc) é a fonte
// legítima, não um intermediário dispensável como era no Bluetti.
//
// Caminho: pull HTTPS pelo túnel Cloudflare que já existe (sitio.malha.dev). É
// outbound do lado do sítio, então atravessa o CGNAT da Starlink e sobrevive à
// mudança trabalho → sítio sem reconfigurar nada (nenhum IP/porta no meio).
//
// Por que /api/template e não /api/states: o payload cruza a PRÓPRIA Starlink que
// estamos monitorando. /api/states são 134KB (≈5,8GB/mês a 60s); o template
// devolve 579 bytes (≈0,8MB/dia). Se o template falhar (HA antigo/erro), cai
// automaticamente pro /api/states, que é auto-descritivo.
//
// AVISO estrutural: o caminho de dados passa pelo link monitorado. Starlink cai →
// túnel cai → paramos de receber. Isso É o sinal de queda (starlink_no_data), mas
// não distingue dish de HA de Cloudflare. Quem desempata é o histórico: obstrução
// subindo antes = dish; corte seco = energia/HA.

const fs   = require('fs');
const path = require('path');

// Persistência: sem isto, restart do bridge zerava o card (e a histerese de
// qualidade recomeçava do nada). O ts do último acerto é gravado junto, então
// depois de um restart o card mostra o dado antigo COM a idade real — não finge
// que é leitura fresca, e o alerta de "sem dados" continua honesto.
let DATA_DIR   = __dirname;
let STATE_FILE = path.join(DATA_DIR, 'starlink_state.json');
let HIST_FILE  = path.join(DATA_DIR, 'starlink_history.ndjson');
const HIST_TTL_DAYS = +(process.env.STARLINK_HIST_DAYS || 30);
let OUTAGE_FILE = path.join(DATA_DIR, 'starlink_outages.json');
let EPOCH_FILE  = path.join(DATA_DIR, 'starlink_epoch.json');
const OUTAGE_REFRESH_MS = +(process.env.STARLINK_OUTAGE_REFRESH_MS || 6 * 3600_000);

const ENTITIES = {
  conn:           'binary_sensor.starlink_conectividade',
  obstructed:     'binary_sensor.starlink_obstruido',
  thermal:        'binary_sensor.starlink_acelerador_termico',
  heating:        'binary_sensor.starlink_aquecimento',
  roaming:        'binary_sensor.starlink_modo_de_roaming',
  mast:           'binary_sensor.starlink_mastro_perto_da_vertical',
  motors:         'binary_sensor.starlink_motores_presos',
  unexpected_loc: 'binary_sensor.starlink_localizacao_inesperada',
  eth:            'binary_sensor.starlink_velocidades_ethernet',
  sleeping:       'binary_sensor.starlink_sleep',
  update:         'binary_sensor.starlink_atualizacao',
  stowed:         'switch.starlink_stowed',
  ping_ms:        'sensor.starlink_ping',
  ping_drop:      'sensor.starlink_ping_drop_rate',
  down_mbps:      'sensor.starlink_taxa_de_transferencia_de_downlink',
  up_mbps:        'sensor.starlink_uplink_throughput',
  dl_gb:          'sensor.starlink_download',
  ul_gb:          'sensor.starlink_upload',
  power_w:        'sensor.starlink_energia',
  energy_kwh:     'sensor.starlink_energia_2',
  last_restart:   'sensor.starlink_last_restart',
  // Do próprio monitor externo que roda nesse HA — é a visão dele da qualidade
  // do link (quantas quedas e quanto tempo fora hoje).
  drops_today:    'sensor.contagem_de_quedas_hoje',
  offline_today:  'sensor.tempo_internet_fora_do_ar_hoje',
};

// `problem`: 'on' = problema (o HA mostra "OK" quando off).
const PROBLEM_FLAGS = ['obstructed', 'thermal', 'mast', 'motors', 'unexpected_loc', 'eth'];
const NUM_FIELDS = ['ping_ms', 'ping_drop', 'down_mbps', 'up_mbps', 'dl_gb', 'ul_gb', 'power_w', 'energy_kwh', 'drops_today', 'offline_today'];
const BOOL_FIELDS = ['conn', 'obstructed', 'thermal', 'heating', 'roaming', 'mast', 'motors', 'unexpected_loc', 'eth', 'sleeping', 'update', 'stowed'];

const POLL_MS = +(process.env.STARLINK_POLL_MS || 60_000);
const TIMEOUT = +(process.env.STARLINK_TIMEOUT_MS || 12_000);

let _log = (...a) => console.log('[starlink]', ...a);
let _onUpdate = null;
let _state = null;          // último normalizado bom
let _lastOkAt = 0;
let _lastTryAt = 0;
let _lastError = null;
let _failStreak = 0;
let _mode = null;           // 'template' | 'states'
let _outages = null;        // { d7, d30, computed_at, covered_days, source }
let _outagesAt = 0;
// Marco de corte: agregados só contam a partir daqui. Serve pra mudança de local
// (trabalho → sítio) sem purgar o recorder do HA — o histórico antigo continua lá
// pra comparação, só sai da conta.
let _epoch = 0;

function _atomicWrite(file, data) {
  const tmp = file + '.tmp-' + process.pid;
  fs.writeFileSync(tmp, data);
  fs.renameSync(tmp, file);
}

function _saveState() {
  try { _atomicWrite(STATE_FILE, JSON.stringify({ state: _state, last_ok_at: _lastOkAt })); }
  catch (e) { _log('falha salvando estado:', e.message); }
}

function _loadState() {
  try {
    const j = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    if (j && j.state) {
      _state = j.state;
      _lastOkAt = j.last_ok_at || j.state.ts || 0;
      _log(`estado restaurado do disco (${Math.round((Date.now() - _lastOkAt) / 60_000)}min atrás)`);
    }
  } catch (_) {}
}

// Uma linha por leitura boa (60s → ~170KB/dia). Só o que serve pra série
// temporal; o resto se lê no snapshot.
function _appendHistory(d) {
  try {
    fs.appendFileSync(HIST_FILE, JSON.stringify({
      t: Math.round(d.ts / 1000),
      on: d.online ? 1 : 0,
      p: d.ping_ms == null ? null : +d.ping_ms.toFixed(1),
      dr: d.ping_drop,
      dn: d.down_mbps == null ? null : +d.down_mbps.toFixed(3),
      up: d.up_mbps == null ? null : +d.up_mbps.toFixed(3),
      w: d.power_w == null ? null : Math.round(d.power_w),
      pb: (d.problems || []).join(',') || undefined,
    }) + '\n');
  } catch (e) { _log('falha gravando histórico:', e.message); }
}

function _pruneHistory() {
  try {
    if (!fs.existsSync(HIST_FILE)) return;
    const cutoff = Math.round((Date.now() - HIST_TTL_DAYS * 86400_000) / 1000);
    const lines = fs.readFileSync(HIST_FILE, 'utf8').split('\n').filter(Boolean);
    const keep = lines.filter(l => { try { return (JSON.parse(l).t || 0) >= cutoff; } catch (_) { return false; } });
    if (keep.length !== lines.length) {
      _atomicWrite(HIST_FILE, keep.join('\n') + (keep.length ? '\n' : ''));
      _log(`histórico podado: ${lines.length - keep.length} linha(s) fora da janela de ${HIST_TTL_DAYS}d`);
    }
  } catch (e) { _log('falha podando histórico:', e.message); }
}

// Série temporal pro gráfico/inspeção. `hours` limita a janela; `every` faz
// downsample (1 = tudo).
function history({ hours = 24, every = 1 } = {}) {
  try {
    if (!fs.existsSync(HIST_FILE)) return [];
    const cutoff = Math.round((Date.now() - hours * 3600_000) / 1000);
    const out = [];
    let i = 0;
    for (const l of fs.readFileSync(HIST_FILE, 'utf8').split('\n')) {
      if (!l) continue;
      let j; try { j = JSON.parse(l); } catch (_) { continue; }
      if ((j.t || 0) < cutoff) continue;
      if (every > 1 && (i++ % every)) continue;
      out.push(j);
    }
    return out;
  } catch (_) { return []; }
}

// ── Quedas e tempo fora do ar em 7d/30d ─────────────────────────────────────
// Os sensores do HA são "hoje" (resetam à meia-noite local), então o total de uma
// janela sai do histórico do recorder. Somo INCREMENTOS POSITIVOS em vez de máximo
// por dia: isso é imune ao reset diário E a reset no meio do dia (restart do HA
// zera o contador), e não depende de acertar o fuso do bucket.
//
// Uma consulta de 30d são ~82KB, então roda a cada 6h (não a cada minuto) e o
// resultado fica em disco — sobrevive a restart do bridge.
function _sumPositiveDeltas(series) {
  const vals = [];
  for (const x of series || []) {
    const st = x.state;
    if (st == null || st === 'unknown' || st === 'unavailable') continue;
    const v = +st;
    if (Number.isFinite(v)) vals.push(v);
  }
  let total = 0;
  for (let i = 1; i < vals.length; i++) if (vals[i] > vals[i - 1]) total += vals[i] - vals[i - 1];
  return { total, points: vals.length };
}

const OUTAGE_ENTITIES = [ENTITIES.drops_today, ENTITIES.offline_today];

async function fetchOutages(force = false) {
  const cfg = _cfg();
  if (!cfg.ok) return _outages;
  if (!force && _outages && Date.now() - _outagesAt < OUTAGE_REFRESH_MS) return _outages;
  const now = new Date();
  const start = new Date(Math.max(now.getTime() - 30 * 86400_000, _epoch || 0));
  const url = `${cfg.url}/api/history/period/${start.toISOString()}` +
    `?end_time=${encodeURIComponent(now.toISOString())}` +
    `&filter_entity_id=${OUTAGE_ENTITIES.join(',')}&minimal_response&no_attributes`;
  try {
    const r = await fetch(url, {
      headers: { Authorization: `Bearer ${cfg.tok}` },
      signal: AbortSignal.timeout(TIMEOUT * 3),
    });
    if (!r.ok) throw new Error(`history HTTP ${r.status}`);
    const arr = await r.json();
    if (!Array.isArray(arr)) throw new Error('history devolveu payload inesperado');
    const cut7 = Math.max(now.getTime() - 7 * 86400_000, _epoch || 0);
    const out = { d7: {}, d30: {} };
    let earliest = null;
    for (const series of arr) {
      if (!series || !series.length) continue;
      const eid = series[0].entity_id || '';
      const key = eid === ENTITIES.drops_today ? 'drops' : eid === ENTITIES.offline_today ? 'offline_h' : null;
      if (!key) continue;
      // minimal_response só repete entity_id no 1º ponto; o resto vem com
      // last_changed/lc e state.
      const stamped = series.map(x => ({ ...x, _t: Date.parse(x.last_changed || x.lc || x.lu || 0) }));
      const t0 = stamped.find(x => x._t)?._t;
      if (t0 && (earliest == null || t0 < earliest)) earliest = t0;
      out.d30[key] = +_sumPositiveDeltas(stamped).total.toFixed(2);
      // Pro 7d incluo o ponto imediatamente ANTES do corte como baseline, senão o
      // primeiro incremento da janela seria perdido.
      const idx = stamped.findIndex(x => x._t >= cut7);
      const slice7 = idx <= 0 ? stamped : stamped.slice(idx - 1);
      out.d7[key] = +_sumPositiveDeltas(slice7).total.toFixed(2);
    }
    const windowStart = Math.max(earliest || 0, _epoch || 0) || earliest;
    _outages = {
      ...out,
      epoch: _epoch || null,
      computed_at: Date.now(),
      // Quanto o recorder REALMENTE cobre: se ele só guarda 10 dias, o "30d" é
      // mentira e o card precisa dizer isso.
      covered_days: windowStart ? +(((now.getTime() - windowStart) / 86400_000).toFixed(1)) : null,
      source: 'ha_recorder',
    };
    _outagesAt = Date.now();
    _saveOutages();
    _log(`agregados: 7d ${_outages.d7.drops} quedas/${_outages.d7.offline_h}h · 30d ${_outages.d30.drops} quedas/${_outages.d30.offline_h}h (recorder cobre ${_outages.covered_days}d)`);
  } catch (e) {
    _log('agregados 7d/30d falharam:', e.message);
  }
  return _outages;
}

function _saveOutages() {
  try { _atomicWrite(OUTAGE_FILE, JSON.stringify(_outages)); } catch (_) {}
}
function _loadOutages() {
  try {
    const j = JSON.parse(fs.readFileSync(OUTAGE_FILE, 'utf8'));
    if (j && j.d30) { _outages = j; _outagesAt = j.computed_at || 0; }
  } catch (_) {}
}

function _loadEpoch() {
  try {
    const j = JSON.parse(fs.readFileSync(EPOCH_FILE, 'utf8'));
    if (j && j.epoch) { _epoch = j.epoch; _log('marco de corte ativo desde ' + new Date(_epoch).toLocaleString('pt-BR')); }
  } catch (_) {}
}

// Zera os contadores DAQUI pra frente: marca o corte e arquiva (não apaga) a nossa
// série temporal, pra o antes/depois da mudança de local seguir comparável.
async function resetCounters() {
  _epoch = Date.now();
  try { _atomicWrite(EPOCH_FILE, JSON.stringify({ epoch: _epoch, at: new Date(_epoch).toISOString() })); }
  catch (e) { _log('falha salvando marco:', e.message); }
  let archived = null;
  try {
    if (fs.existsSync(HIST_FILE)) {
      // Timestamp LOCAL no nome: o dono vê 14:46 na tela, o arquivo tem que dizer
      // 1446 também — UTC aqui só gera dúvida na hora de comparar.
      const d = new Date(_epoch);
      const p2 = (n) => String(n).padStart(2, '0');
      const stamp = `${d.getFullYear()}${p2(d.getMonth() + 1)}${p2(d.getDate())}-${p2(d.getHours())}${p2(d.getMinutes())}`;
      archived = HIST_FILE.replace(/\.ndjson$/, `.pre-${stamp}.ndjson`);
      fs.renameSync(HIST_FILE, archived);
    }
  } catch (e) { _log('falha arquivando histórico:', e.message); archived = null; }
  _outages = null; _outagesAt = 0;
  try { fs.unlinkSync(OUTAGE_FILE); } catch (_) {}
  _log(`contadores zerados em ${new Date(_epoch).toLocaleString('pt-BR')}` + (archived ? ` · histórico arquivado em ${path.basename(archived)}` : ''));
  await fetchOutages(true);
  return { epoch: _epoch, archived: archived ? path.basename(archived) : null, outages: _outages };
}

function _cfg() {
  const url = (process.env.HA_SITIO_URL || '').replace(/\/$/, '');
  const tok = process.env.HA_SITIO_TOKEN || '';
  return { url, tok, ok: !!(url && tok) };
}

const _tpl = () => '{{ {' +
  Object.entries(ENTITIES).map(([k, e]) => `'${k}': states('${e}')`).join(',') +
  ",'ha_now': now().isoformat()} | tojson }}";

async function _viaTemplate({ url, tok }) {
  const r = await fetch(`${url}/api/template`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${tok}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ template: _tpl() }),
    signal: AbortSignal.timeout(TIMEOUT),
  });
  if (!r.ok) throw new Error(`template HTTP ${r.status}`);
  const txt = await r.text();
  const j = JSON.parse(txt);
  if (!j || typeof j !== 'object') throw new Error('template devolveu payload inesperado');
  return j;
}

async function _viaStates({ url, tok }) {
  const r = await fetch(`${url}/api/states`, {
    headers: { Authorization: `Bearer ${tok}` },
    signal: AbortSignal.timeout(TIMEOUT),
  });
  if (!r.ok) throw new Error(`states HTTP ${r.status}`);
  const arr = await r.json();
  const by = new Map(arr.map(x => [x.entity_id, x.state]));
  const out = {};
  for (const [k, e] of Object.entries(ENTITIES)) out[k] = by.get(e) ?? null;
  return out;
}

function _num(v) {
  if (v == null || v === '' || v === 'unknown' || v === 'unavailable') return null;
  const n = +v; return Number.isFinite(n) ? n : null;
}
function _bool(v) {
  if (v === 'on' || v === 'true') return true;
  if (v === 'off' || v === 'false') return false;
  return null;   // unknown/unavailable
}

function _normalize(raw) {
  const out = { ts: Date.now(), ha_now: raw.ha_now || null };
  for (const k of BOOL_FIELDS) out[k] = _bool(raw[k]);
  for (const k of NUM_FIELDS)  out[k] = _num(raw[k]);
  out.last_restart = raw.last_restart && !['unknown', 'unavailable'].includes(raw.last_restart)
    ? raw.last_restart : null;
  out.uptime_h = out.last_restart
    ? +(((Date.now() - Date.parse(out.last_restart)) / 3600_000).toFixed(1)) : null;
  // online: conectividade é a verdade; stowed/sleeping explicam um off "de propósito".
  out.online = out.conn === true;
  out.problems = PROBLEM_FLAGS.filter(f => out[f] === true);
  // Entidade toda unavailable = HA de pé mas integração fora (dish sem resposta).
  out.integration_ok = out.conn != null || out.ping_ms != null;
  return out;
}

async function poll() {
  const cfg = _cfg();
  _lastTryAt = Date.now();
  if (!cfg.ok) { _lastError = 'HA_SITIO_URL/HA_SITIO_TOKEN não configurados'; return snapshot(); }
  try {
    let raw;
    if (_mode === 'states') raw = await _viaStates(cfg);
    else {
      try { raw = await _viaTemplate(cfg); _mode = 'template'; }
      catch (e) {
        _log('template falhou, caindo pro /api/states:', e.message);
        raw = await _viaStates(cfg); _mode = 'states';
      }
    }
    _state = _normalize(raw);
    _lastOkAt = _state.ts;
    _lastError = null;
    _failStreak = 0;
    _saveState();
    _appendHistory(_state);
  } catch (e) {
    _failStreak++;
    _lastError = e.message;
    // Silencia o log repetido: link do sítio cai e volta, não precisa poluir.
    if (_failStreak === 1 || _failStreak % 10 === 0) _log(`falha ${_failStreak}x:`, e.message);
  }
  const snap = snapshot();
  if (_onUpdate) { try { _onUpdate(snap); } catch (_) {} }
  return snap;
}

function snapshot() {
  return {
    ok: !!_state,
    stale_s: _lastOkAt ? Math.round((Date.now() - _lastOkAt) / 1000) : null,
    fail_streak: _failStreak,
    error: _lastError,
    mode: _mode,
    data: _state,
    outages: _outages,
  };
}

function status() {
  const cfg = _cfg();
  return {
    configured: cfg.ok,
    url: cfg.url || null,
    mode: _mode,
    poll_ms: POLL_MS,
    last_ok_at: _lastOkAt || null,
    last_try_at: _lastTryAt || null,
    stale_s: _lastOkAt ? Math.round((Date.now() - _lastOkAt) / 1000) : null,
    fail_streak: _failStreak,
    last_error: _lastError,
    epoch: _epoch || null,
  };
}

function start(opts = {}) {
  if (opts.log) _log = opts.log;
  if (opts.onUpdate) _onUpdate = opts.onUpdate;
  if (opts.dataDir) {
    DATA_DIR = opts.dataDir;
    STATE_FILE = path.join(DATA_DIR, 'starlink_state.json');
    HIST_FILE  = path.join(DATA_DIR, 'starlink_history.ndjson');
    OUTAGE_FILE = path.join(DATA_DIR, 'starlink_outages.json');
    EPOCH_FILE  = path.join(DATA_DIR, 'starlink_epoch.json');
  }
  if (!_cfg().ok) { _log('HA do sítio não configurado (HA_SITIO_URL/HA_SITIO_TOKEN) — monitor Starlink inativo'); return; }
  _loadState();
  _loadEpoch();
  _loadOutages();
  _pruneHistory();
  setInterval(_pruneHistory, 24 * 3600_000);
  setTimeout(() => { fetchOutages().catch(() => {}); }, 15_000);
  setInterval(() => { fetchOutages().catch(() => {}); }, OUTAGE_REFRESH_MS);
  setTimeout(() => { poll().catch(() => {}); }, 8_000);
  setInterval(() => { poll().catch(() => {}); }, POLL_MS);
}

module.exports = { start, poll, snapshot, status, history, fetchOutages, resetCounters, ENTITIES };
