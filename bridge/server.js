'use strict';

require('dotenv').config({ path: require('path').join(__dirname, '.env') });
const express  = require('express');
const { WebSocketServer } = require('ws');
const mqtt     = require('mqtt');
const fs       = require('fs');
const path     = require('path');
const http     = require('http');
const https    = require('https');
const webpush  = require('web-push');
const apnsLive = require('./apns_live_activity');
apnsLive.init();

// ── Configuração ──────────────────────────────────────────────────────────────

const MQTT_HOST   = process.env.MQTT_HOST   || 'mqtt://localhost';
const MQTT_PORT   = parseInt(process.env.MQTT_PORT || '1883', 10);
const MQTT_USER   = process.env.MQTT_USER   || '';
const MQTT_PASS   = process.env.MQTT_PASS   || '';
const MQTT_PREFIX    = process.env.MQTT_PREFIX || 'haval/ecotrip';
const PORT           = parseInt(process.env.PORT || '3000', 10);
// Integração GWM Brasil — publica direto via MQTT (sem passar pelo app).
// Bridge subscribe nesses tópicos pra ter estado confiável de body/lock/etc.
//
// Origem do chassi (precedência): vehicle.json (editável via UI) → .env (legacy).
// vehicle.json vence porque é a fonte autoritativa quando o usuário configura
// pela tela de Settings → Veículo. .env é fallback pra setups antigos.
const VEHICLE_FILE = path.join(__dirname, 'vehicle.json');
function _loadVehicleChassiFromFile() {
  try {
    if (!fs.existsSync(VEHICLE_FILE)) return '';
    const v = JSON.parse(fs.readFileSync(VEHICLE_FILE, 'utf8'));
    return (v && typeof v.chassi === 'string') ? v.chassi.toLowerCase().trim() : '';
  } catch (e) {
    console.error('Aviso: erro ao ler vehicle.json:', e.message);
    return '';
  }
}
const _chassiFromFile = _loadVehicleChassiFromFile();
const _chassiFromEnv  = (process.env.GWM_CHASSI || '').toLowerCase().trim();
const GWM_CHASSI       = _chassiFromFile || _chassiFromEnv;
const GWM_CHASSI_SOURCE = _chassiFromFile ? 'file' : (_chassiFromEnv ? 'env' : 'none');
if (!GWM_CHASSI) {
  console.error('⚠️  Chassi do veículo não configurado — integração GWM Brasil/HA desabilitada.');
  console.error('   Configure em Settings → Veículo (UI) ou via GWM_CHASSI no .env.');
} else {
  console.log(`✓ Chassi do veículo: ${GWM_CHASSI} (fonte: ${GWM_CHASSI_SOURCE === 'file' ? 'vehicle.json' : '.env'})`);
}
const GWM_TOPIC_PREFIX = `gwmbrasil_${GWM_CHASSI}`;

// Home Assistant REST — usado APENAS no boot pra puxar o estado inicial das
// entidades que a integração GWM não publica com retain (doors, lock, AC,
// windows, sunroof, pneus, etc). Depois disso, MQTT live cobre as mudanças.
const HA_URL   = process.env.HA_URL   || '';
const HA_TOKEN = process.env.HA_TOKEN || '';

// ── Token de acesso (hash SHA-256 da senha) ────────────────────────────────────
// Suporta migração: BRIDGE_TOKEN (plain) → calcula hash automaticamente
// Em produção usa BRIDGE_TOKEN_HASH diretamente (gerado pelo endpoint change-password)
function sha256hex(str) {
  return require('crypto').createHash('sha256').update(str).digest('hex');
}
const _plainToken   = process.env.BRIDGE_TOKEN      || '';
let BRIDGE_TOKEN_HASH = process.env.BRIDGE_TOKEN_HASH
  || (_plainToken ? sha256hex(_plainToken) : '');

// ── 2FA (TOTP) ────────────────────────────────────────────────────────────────
// Estado em arquivo gitignored. Quando ativado: requer código TOTP no login.
// APK e dispositivos que já logaram não são afetados (bearer token continua válido).
const otplib = require('otplib');
otplib.authenticator.options = { window: 1 };  // tolera ±30s de drift
const QRCode = require('qrcode');
const AUTH_FILE = path.join(__dirname, 'auth.json');
let authConfig = { totp_secret: '', backup_codes: [] };
try {
  if (fs.existsSync(AUTH_FILE)) authConfig = JSON.parse(fs.readFileSync(AUTH_FILE, 'utf8'));
} catch (_) {}
function saveAuthConfig() {
  try { fs.writeFileSync(AUTH_FILE, JSON.stringify(authConfig, null, 2)); } catch (_) {}
}
function is2faEnabled() { return !!authConfig.totp_secret; }
function verifyTotpOrBackup(code) {
  if (!code) return false;
  const trimmed = String(code).trim().replace(/[\s-]/g, '');
  // 1. TOTP normal (6 dígitos)
  if (/^\d{6}$/.test(trimmed) && authConfig.totp_secret) {
    if (otplib.authenticator.check(trimmed, authConfig.totp_secret)) return true;
  }
  // 2. Backup code (8 chars hex) — single-use
  const idx = (authConfig.backup_codes || []).indexOf(trimmed.toUpperCase());
  if (idx >= 0) {
    authConfig.backup_codes.splice(idx, 1);
    saveAuthConfig();
    return true;
  }
  return false;
}
function genBackupCodes(n = 10) {
  const codes = [];
  for (let i = 0; i < n; i++) {
    codes.push(require('crypto').randomBytes(4).toString('hex').toUpperCase());
  }
  return codes;
}

// TRIPS_FILE removido — Trip A/B descontinuados.
const CHARGES_FILE    = path.join(__dirname, 'charges.json');
const STATE_FILE      = path.join(__dirname, 'state.json');
const AUTOTRIPS_DIR   = path.join(__dirname, 'autotrips');
const SNAPSHOTS_FILE  = path.join(__dirname, 'lifetime_snapshots.json');
const VAPID_FILE        = path.join(__dirname, 'vapid_keys.json');
const PUSH_SUBS_FILE    = path.join(__dirname, 'push_subscriptions.json');
const RENAMES_FILE      = path.join(__dirname, 'pending_renames.json');
const CHARGE_LOCS_FILE    = path.join(__dirname, 'charge_locations.json');
const KNOWN_PLACES_FILE   = path.join(__dirname, 'known_places.json');
const MAINTENANCE_FILE    = path.join(__dirname, 'maintenance.json');
const REFUELS_FILE        = path.join(__dirname, 'refuels.json');
const TELEMETRY_LOG_FILE  = path.join(__dirname, 'telemetry_history.json');
const DELETED_IDS_FILE    = path.join(__dirname, 'deleted_ids.json');

// Capacidades do Haval H6 PHEV (uso pra estimar kWh atual a partir do SOC%)
const BATTERY_CAPACITY_KWH = 34;
const TANK_CAPACITY_L      = 55;
const NOTIF_PREFS_FILE    = path.join(__dirname, 'notif_prefs.json');
const NOTIF_HISTORY_FILE  = path.join(__dirname, 'notif_history.json');
const EVENTS_FILE         = path.join(__dirname, 'events.json');

if (!fs.existsSync(AUTOTRIPS_DIR)) fs.mkdirSync(AUTOTRIPS_DIR, { recursive: true });

// ── Web Push / VAPID ─────────────────────────────────────────────────────────
let vapidKeys;
try { if (fs.existsSync(VAPID_FILE)) vapidKeys = JSON.parse(fs.readFileSync(VAPID_FILE, 'utf8')); } catch (_) {}
if (!vapidKeys?.publicKey) {
  vapidKeys = webpush.generateVAPIDKeys();
  fs.writeFileSync(VAPID_FILE, JSON.stringify(vapidKeys));
  console.log('✓ VAPID keys geradas e salvas em vapid_keys.json');
}
webpush.setVapidDetails('https://github.com/rafaelcs28/haval-ecotrip', vapidKeys.publicKey, vapidKeys.privateKey);

let pushSubs = [];
try { if (fs.existsSync(PUSH_SUBS_FILE)) pushSubs = JSON.parse(fs.readFileSync(PUSH_SUBS_FILE, 'utf8')); } catch (_) {}

function savePushSubs() {
  try { fs.writeFileSync(PUSH_SUBS_FILE, JSON.stringify(pushSubs, null, 2)); } catch (_) {}
}

// Migration: subscriptions antigas não têm device_id. Atribui UUID + nome
// genérico pra cada uma. Migration roda 1x; se já tiver device_id, ignora.
function _migrateLegacySubs() {
  let changed = 0;
  pushSubs.forEach((s, idx) => {
    if (!s.device_id) {
      s.device_id = (typeof require !== 'undefined' && require('crypto').randomUUID)
        ? require('crypto').randomUUID()
        : 'dev_' + Date.now() + '_' + idx;
      s.device_name = s.device_name || `Dispositivo ${idx + 1}`;
      s.created_at  = s.created_at  || Date.now();
      changed++;
    }
  });
  if (changed) {
    savePushSubs();
    console.log(`✓ Push subs migrados: ${changed} subscription(s) ganharam device_id`);
  }
}
_migrateLegacySubs();

// ── Histórico de notificações ─────────────────────────────────────────────────
const NOTIF_HISTORY_MAX = 100;
let notifHistory = [];
try {
  if (fs.existsSync(NOTIF_HISTORY_FILE))
    notifHistory = JSON.parse(fs.readFileSync(NOTIF_HISTORY_FILE, 'utf8')) || [];
} catch (_) {}
function saveNotifHistory() {
  try { fs.writeFileSync(NOTIF_HISTORY_FILE, JSON.stringify(notifHistory)); } catch (_) {}
}

/**
 * Dispara push notification.
 * @param {string} title
 * @param {string} body
 * @param {string} [type]  - chave em NOTIF_DEFAULTS (ex: 'charge_start'). Quando
 *   passado, cada sub é avaliada contra as prefs do device dela (silencia
 *   subs cujo prefs[type] === false). Sem type, dispara pra todos.
 * @param {object} [opts] - { tag, silent, renotify, skipHistory } — controla
 *   o comportamento da notification (usado pra "live update" durante recarga,
 *   onde queremos substituir a notif anterior em silêncio).
 */
// ── ntfy.sh (push externo grátis, sem APNs paga) ─────────────────────────────
// Bridge publica notificações também num topic ntfy.sh; user instala o app
// `ntfy` no iPhone (gratuito) e subscreve nesse topic. Push chega em background
// instantaneamente. Topic é configurado em NTFY_TOPIC no .env — escolha um
// nome difícil de adivinhar (ex: eco-trip-7a3b9f2e8c1d), porque topics
// públicos ntfy.sh sem auth são acessíveis a qualquer um que saiba o nome.
const NTFY_TOPIC = (process.env.NTFY_TOPIC || '').trim();
const NTFY_URL   = (process.env.NTFY_URL   || 'https://ntfy.sh').replace(/\/$/, '');
// Auth opcional pra self-hosted (basic ou token)
const NTFY_AUTH  = (process.env.NTFY_AUTH || '').trim();

async function sendNtfy(title, body, type) {
  if (!NTFY_TOPIC) return;
  // Mapeia type → prioridade + tag
  const meta = {
    charge_start:        { prio: 4, tag: 'zap' },
    charge_end:          { prio: 3, tag: 'battery' },
    charge_ending:       { prio: 4, tag: 'hourglass_flowing_sand' },
    charge_live:         { prio: 2, tag: 'zap' },
    maintenance_soon:    { prio: 4, tag: 'wrench' },
    maintenance_overdue: { prio: 5, tag: 'warning' },
    anomaly_detected:    { prio: 4, tag: 'warning' },
    door_open:           { prio: 3, tag: 'door' },
    tyre_low:            { prio: 4, tag: 'warning' },
    geofence_arrival:    { prio: 3, tag: 'house' },
    geofence_departure:  { prio: 3, tag: 'car' },
  }[type] || { prio: 3, tag: 'car' };

  try {
    // ntfy aceita títulos Unicode via RFC 2047 (=?UTF-8?B?<base64>?=).
    // Sem isso, emoji/acento aparece como mojibake no banner do iOS.
    const titleEnc = `=?UTF-8?B?${Buffer.from(title, 'utf8').toString('base64')}?=`;
    const headers = {
      'Title':    titleEnc,
      'Priority': String(meta.prio),
      'Tags':     meta.tag,
      'Content-Type': 'text/plain; charset=utf-8',
    };
    if (NTFY_AUTH) headers['Authorization'] = NTFY_AUTH;
    await fetch(`${NTFY_URL}/${encodeURIComponent(NTFY_TOPIC)}`, {
      method: 'POST',
      headers,
      body,
    });
  } catch (e) {
    console.warn('[ntfy] falha:', e.message);
  }
}

async function sendPush(title, body, type, opts = {}) {
  // Despacha pro ntfy.sh em paralelo (best-effort, não bloqueia o Web Push)
  if (!opts.skipNtfy) sendNtfy(title, body, type || 'generic').catch(() => {});

  // Registra no histórico — exceto se for live update silencioso (poluiria o feed)
  const ts = Date.now();
  if (!opts.skipHistory) {
    notifHistory.unshift({ ts, title, body, type: type || null });
    if (notifHistory.length > NOTIF_HISTORY_MAX) notifHistory.length = NOTIF_HISTORY_MAX;
    saveNotifHistory();
    // Notifica clientes WebSocket sobre nova notificação (para badge)
    state.notif_latest_ts = ts;
    broadcast('update', { notif_latest_ts: ts });
  }

  if (!pushSubs.length) {
    if (!opts.skipHistory) console.log(`Push "${title}" — sem subscribers registrados`);
    return;
  }
  const payloadObj = { title, body };
  if (opts.tag)      payloadObj.tag      = opts.tag;
  if (opts.silent)   payloadObj.silent   = true;
  if (opts.renotify !== undefined) payloadObj.renotify = !!opts.renotify;
  const payload = JSON.stringify(payloadObj);
  const dead = [];
  let sent = 0, skipped = 0;
  await Promise.all(pushSubs.map(async (sub, i) => {
    // Gating por device: se a sub tem device_id e o tipo está OFF nas prefs, pula.
    if (type) {
      const prefs = getPrefsForDevice(sub.device_id);
      if (prefs[type] === false) { skipped++; return; }
    }
    try {
      await webpush.sendNotification(sub, payload);
      sent++;
    } catch (e) {
      const code = e.statusCode;
      console.error(`Push error [${code}] ...${sub.endpoint?.slice(-30)}: ${e.body || e.message}`);
      // Remove subscrições expiradas (410/404), inválidas (400) ou com VAPID errado (401)
      if (code === 410 || code === 404 || code === 400 || code === 401) dead.push(i);
    }
  }));
  if (type) console.log(`Push "${title}" type=${type} sent=${sent} skipped=${skipped}/${pushSubs.length}`);
  if (dead.length) {
    console.log(`Push: removendo ${dead.length} subscrição(ões) inválida(s)`);
    dead.reverse().forEach(i => pushSubs.splice(i, 1));
    savePushSubs();
  }
}

// ── Preferências de notificações push ────────────────────────────────────────
const NOTIF_DEFAULTS = {
  // Tudo desativado por padrão. Cada device escolhe o que ativar — sem
  // surpresas pra device novo. charge_ending_min fica em 5 porque é
  // um número, não um toggle (entra em uso só se charge_ending=true).
  charge_start:      false,
  charge_end:        false,
  charge_ending:     false,
  charge_ending_min: 5,
  charge_live:       false,   // notif "ao vivo" na tela de bloqueio durante recarga
  door_open:         false,
  door_close:        false,
  trunk_open:        false,
  trunk_close:       false,
  engine_on:         false,
  engine_off:        false,
  app_update:        false,
  trip_end:          false,
  geofence_arrival:  false,
  geofence_departure:false,
  geofence_arrival_places:   [],
  geofence_departure_places: [],
  maintenance_soon:  false,
  maintenance_overdue: false,
  anomaly_detected:  false,
  tyre_low:          false,
  tyre_high:         false,
  refuel_detected:   false,
};
let notifPrefs = { ...NOTIF_DEFAULTS };
try {
  if (fs.existsSync(NOTIF_PREFS_FILE))
    notifPrefs = { ...NOTIF_DEFAULTS, ...JSON.parse(fs.readFileSync(NOTIF_PREFS_FILE, 'utf8')) };
} catch (_) {}
function saveNotifPrefs() {
  try { fs.writeFileSync(NOTIF_PREFS_FILE, JSON.stringify(notifPrefs, null, 2)); } catch (_) {}
}

// ── Preferências por device ────────────────────────────────────────────────
// notifPrefsByDevice = { <device_id>: { charge_start, charge_end, ... } }
// Cada push subscription tem um device_id estável (gerado no client e
// guardado no localStorage). Quando uma notificação dispara, cada sub é
// avaliada contra as prefs do seu device — não há mais "global".
// `notifPrefs` acima vira o fallback default pra devices sem prefs próprias.
const NOTIF_PREFS_BY_DEVICE_FILE = path.join(__dirname, 'notif_prefs_by_device.json');
let notifPrefsByDevice = {};
try {
  if (fs.existsSync(NOTIF_PREFS_BY_DEVICE_FILE))
    notifPrefsByDevice = JSON.parse(fs.readFileSync(NOTIF_PREFS_BY_DEVICE_FILE, 'utf8')) || {};
} catch (_) { notifPrefsByDevice = {}; }
function saveNotifPrefsByDevice() {
  try { fs.writeFileSync(NOTIF_PREFS_BY_DEVICE_FILE, JSON.stringify(notifPrefsByDevice, null, 2)); } catch (_) {}
}

function getPrefsForDevice(deviceId) {
  // Devices SEM prefs próprias recebem apenas NOTIF_DEFAULTS (tudo OFF).
  // Não caem mais no fallback `notifPrefs` global — antes isso fazia 7 devices
  // antigos (sem prefs) receberem tudo automaticamente.
  // notifPrefs global continua sendo lido só pras listas de places (geofence)
  // e como ponto de partida quando o user ativa algo no painel global.
  if (deviceId && notifPrefsByDevice[deviceId]) {
    return { ...NOTIF_DEFAULTS, ...notifPrefsByDevice[deviceId] };
  }
  return { ...NOTIF_DEFAULTS };
}

// Gera UUID v4 (usa crypto.randomUUID em Node ≥14.17). Fallback simples.
function genDeviceId() {
  try { return require('crypto').randomUUID(); }
  catch (_) { return 'dev_' + Date.now() + '_' + Math.random().toString(36).slice(2, 8); }
}

// Guard para não reenviar a notificação de fim de recarga na mesma sessão
let chargeEndingNotifSent = false;

// ── Detecção de transição de estado de carga ──────────────────────────────────
// Hysteresis: car emite valores oscilantes (ex.: sunroof posição, AC compressor cycle)
// pro mesmo estado físico. Sem debounce, o log enche de eventos a cada flip do sensor.
// Espera N ms de valor estável antes de atualizar state + disparar evento.
const HYSTERESIS_MS    = 3000;     // sunroof/vidros/portas/trava/trunk — filtra ruído de sensor
const AC_HYSTERESIS_MS = 15000;    // AC — compressor cycle do HEV/PHEV (10-15s típico)
const _hystPending = {
  sunroof: null,
  window_fl: null, window_fr: null, window_rl: null, window_rr: null,
  door_fl: null, door_fr: null, door_rl: null, door_rr: null, door_trunk: null,
  lock_state: null,
  ac_state: null,
};
const _hystTimers  = {
  sunroof: null,
  window_fl: null, window_fr: null, window_rl: null, window_rr: null,
  door_fl: null, door_fr: null, door_rl: null, door_rr: null, door_trunk: null,
  lock_state: null,
  ac_state: null,
};

let prevChargingState    = null;
let chargeStartTimer     = null;
let chargeSessionStartMs = 0;   // timestamp de início da sessão (para duração e potência média)
let chargeStartSoc       = 0;   // SOC% no início da sessão (para log de eventos)
let _chargeTempSamples   = [];  // amostras de temp externa durante a sessão atual
let _lastChargeAvgTemp   = null;// média calculada ao fim da sessão, anexada ao próximo charging/history

// ── SOC — fonte HA tem prioridade quando disponível ───────────────────────────
// Após o primeiro tópico haval/ecotrip/soc_pct (publicado via automação HA),
// ignoramos o trip_a/b/soc_current para soc_pct — evita que o Android
// sobrescreva com um valor mais antigo.
let haSocActive = false;

// ── Detecção de transição porta/motor ─────────────────────────────────────────
let prevEngineState = null;
const prevDoorStates = { fl: null, fr: null, rl: null, rr: null, trunk: null };
const DOOR_NAMES = { fl: 'Dianteira esq.', fr: 'Dianteira dir.', rl: 'Traseira esq.', rr: 'Traseira dir.' };
const WINDOW_NAMES = { fl: 'Vidro diant. esq.', fr: 'Vidro diant. dir.', rl: 'Vidro tras. esq.', rr: 'Vidro tras. dir.' };
const WIN_NAMES  = { fl: 'Vidro diant. esq.', fr: 'Vidro diant. dir.', rl: 'Vidro tras. esq.', rr: 'Vidro tras. dir.' };
const prevWindowStates = { fl: null, fr: null, rl: null, rr: null };
let prevLockState   = null;
let prevSunroof     = null;
let prevGearForTrip = null;

// ── Alerta de pressão de pneus ────────────────────────────────────────────────
// PSI a frio. Pneu rodando esquenta e a pressão sobe ~1 PSI a cada 10°C acima
// da temperatura ambiente (rule of thumb). Sem filtrar por temperatura, a média
// inflaciona em movimento e gera "pressão alta" falsa; pior, o ALTO mascara
// pneu que originalmente estava baixo (compensa). Solução: só avaliar quando
// a temperatura do pneu está dentro da faixa "fria" (≤ TYRE_COLD_MAX_C).
const TYRE_PSI_MIN     = 34;   // abaixo → alerta
const TYRE_PSI_MAX     = 40;   // acima  → alerta
const TYRE_COLD_MAX_C  = 35;   // pneu acima disso: rodando, ignora pra alerta
const tyreAlertSent = {};
function checkTyrePressure(pos, psi, isRetained = false, tempC = null) {
  if (!psi || psi < 5) return;
  // Pneu quente: skip — pressão real (a frio) é menor que o lido aqui.
  // Aceita null/0 como "sem leitura de temperatura" (mantém comportamento legado)
  if (tempC != null && tempC > 0 && tempC > TYRE_COLD_MAX_C) {
    // Limpa state.alertSent pra que assim que esfriar e cair abaixo do mín
    // a notificação volte a disparar (caso ainda esteja baixo).
    return;
  }
  const lowKey  = `${pos}_low`;
  const highKey = `${pos}_high`;
  if (psi < TYRE_PSI_MIN) {
    if (!tyreAlertSent[lowKey] && !isRetained) {
      tyreAlertSent[lowKey] = true;
      delete tyreAlertSent[highKey];
      sendPush('⚠️ Pneu com pressão baixa', `${pos}: ${psi.toFixed(1)} PSI (mín ${TYRE_PSI_MIN} PSI, pneu a frio)`, 'tyre_low');
    } else {
      tyreAlertSent[lowKey] = true;
    }
  } else if (psi > TYRE_PSI_MAX) {
    if (!tyreAlertSent[highKey] && !isRetained) {
      tyreAlertSent[highKey] = true;
      delete tyreAlertSent[lowKey];
      sendPush('⚠️ Pneu com pressão alta', `${pos}: ${psi.toFixed(1)} PSI (máx ${TYRE_PSI_MAX} PSI, pneu a frio)`, 'tyre_high');
    } else {
      tyreAlertSent[highKey] = true;
    }
  } else {
    delete tyreAlertSent[lowKey];
    delete tyreAlertSent[highKey];
  }
}

// ── Lifetime snapshots — checkpoints periódicos para filtros do PWA ──────────
// Salvo a cada 5 min quando dados MQTT chegam; serve de baseline para
// os filtros "Hoje / 7 dias / 30 dias" sem depender de auto-trips sincronizados.
let lifeSnapshots = [];
try {
  if (fs.existsSync(SNAPSHOTS_FILE)) {
    lifeSnapshots = JSON.parse(fs.readFileSync(SNAPSHOTS_FILE, 'utf8'));
    if (!Array.isArray(lifeSnapshots)) lifeSnapshots = [];
    console.log(`✓ Lifetime snapshots: ${lifeSnapshots.length}`);
  }
} catch (_) { lifeSnapshots = []; }

let lastSnapMs = 0;
function maybeSaveLifetimeSnapshot() {
  const now = Date.now();
  if (now - lastSnapMs < 5 * 60 * 1000) return;          // máx 1 a cada 5 min
  const l = state.lifetime;
  if (!l || !(l.distance_km > 0)) return;                 // ignora se sem dados
  lastSnapMs = now;
  lifeSnapshots.push({
    ts:          now,
    distance_km: l.distance_km || 0,
    energy_kwh:  l.energy_kwh  || 0,
    regen_kwh:   l.regen_kwh   || 0,
    net_kwh:     l.net_kwh     || 0,
    fuel_l:      l.fuel_l      || 0,
    time_sec:    Number(l.time_sec)    || 0,
    charge_kwh:  l.charge_kwh  || 0,
    charge_sec:  Number(l.charge_sec)  || 0,
  });
  // Mantém últimos 2016 snapshots ≈ 7 dias a 5 min
  if (lifeSnapshots.length > 2016) lifeSnapshots = lifeSnapshots.slice(-2016);
  try { fs.writeFileSync(SNAPSHOTS_FILE, JSON.stringify(lifeSnapshots)); } catch (_) {}
}

// ── Auto-trips — índice em memória (carregado do disco) ───────────────────────
// Recalcula hybridTimeSec / hybridDistKm a partir das amostras de telemetria.
// Retorna {} se não há amostras (sem telemetria = sem dados de split).
// Retorna {hybridTimeSec: 0, hybridDistKm: 0} para viagens 100% elétricas.
function _calcHybrid(samples = []) {
  if (!samples.length) return {};   // sem amostras → campos ficam undefined (= "sem dados")
  let hybridTimeSec = 0, hybridDistKm = 0;
  for (let i = 1; i < samples.length; i++) {
    const a = samples[i - 1], b = samples[i];
    const dt = (b.t || 0) - (a.t || 0);
    if (dt > 0 && dt < 30 && (a.rpm || 0) > 50) {
      hybridTimeSec += dt;
      hybridDistKm  += ((a.spd || 0) + (b.spd || 0)) / 2 / 3600 * dt;
    }
  }
  return {
    hybridTimeSec: Math.round(hybridTimeSec),
    hybridDistKm:  parseFloat(hybridDistKm.toFixed(3)),
  };
}

let autoTripsArr = [];
try {
  const files = fs.readdirSync(AUTOTRIPS_DIR).filter(f => f.endsWith('.json'));
  for (const f of files) {
    try {
      const d = JSON.parse(fs.readFileSync(path.join(AUTOTRIPS_DIR, f), 'utf8'));
      if (d.autoTrip) {
        // Usa hybrid pré-calculado do JSON; arquivos antigos (sem o campo) ainda
        // são recalculados na carga — após o primeiro POST/merge, ficam persistidos.
        const hybrid = (d.hybridTimeSec != null && d.hybridDistKm != null)
          ? { hybridTimeSec: d.hybridTimeSec, hybridDistKm: d.hybridDistKm }
          : _calcHybrid(d.samples || []);
        autoTripsArr.push({ tripId: d.tripId, ...d.autoTrip, ...hybrid });
      }
    } catch (_) {}
  }
  autoTripsArr.sort((a, b) => (b.startMs || 0) - (a.startMs || 0));
  console.log(`✓ Auto-trips carregados: ${autoTripsArr.length}`);

  // Limpa viagens irrelevantes: dist=0 E energia=0 E duração<60s
  let purged = 0;
  autoTripsArr = autoTripsArr.filter(t => {
    const keep = (t.distKm || 0) > 0 || (t.netKwh || 0) >= 0.10 || (t.timeSec || 0) >= 60;
    if (!keep) {
      const filePath = path.join(AUTOTRIPS_DIR, `${t.tripId}.json`);
      try { fs.unlinkSync(filePath); } catch (_) {}
      purged++;
    }
    return keep;
  });
  if (purged > 0) console.log(`🗑  Auto-trips irrelevantes removidos: ${purged}`);
} catch (e) { console.error('Aviso: erro ao carregar auto-trips:', e.message); }

// ── Log de eventos ────────────────────────────────────────────────────────────
const MAX_EVENTS = 2000;
let eventsLog = [];
try {
  if (fs.existsSync(EVENTS_FILE)) {
    const _ev = JSON.parse(fs.readFileSync(EVENTS_FILE, 'utf8'));
    eventsLog = Array.isArray(_ev) ? _ev : [];
    console.log(`✓ Eventos carregados: ${eventsLog.length}`);
  }
} catch(e) { console.error('Aviso: não foi possível ler events.json:', e.message); }

let _saveEventsTimer = null;
function _saveEventsSoon() {
  clearTimeout(_saveEventsTimer);
  _saveEventsTimer = setTimeout(() => {
    fs.writeFile(EVENTS_FILE, JSON.stringify(eventsLog), () => {});
  }, 2000);
}

function addEvent(type, label, ts) {
  // ts opcional — quando o app publica `valor:ms_real_da_mudanca`, o handler
  // passa esse ms aqui pra que o evento no log mostre a hora real e não a
  // hora da confirmação (ex.: vidros com voting filter têm ~40s de latência
  // entre mudança real e confirmação — usar Date.now() distorceria o log).
  const now = Date.now();
  const eventTs = ts && ts > 0 ? ts : now;
  const ev = { id: now, ts: eventTs, type, label };
  eventsLog.unshift(ev);
  if (eventsLog.length > MAX_EVENTS) eventsLog.pop();
  _saveEventsSoon();
  broadcast('new_event', ev);
}

// ── Estado em memória (espelha todos os tópicos MQTT) ─────────────────────────
// Valores iniciais = defaults. Serão sobrescritos pelo state.json persistido
// e depois pelos tópicos MQTT retained (ao conectar) e live (quando carro liga).

const state = {
  car_online:        false,
  car_network:       null,   // { type, ip, downlink_kbps, ts } publicado pelo APK
  bridge_online:     true,
  last_update_ms:    null,
  car_last_update:   null,
  car_app_version:   null,

  gps_lat:          0,
  gps_lng:          0,
  gps_ts:           0,   // timestamp ms da última posição recebida

  speed_kmh:        0,
  gear:             '--',
  inside_temp:      0,
  outside_temp:     0,
  odometer_km:         0,    // km total do veículo
  fuel_l:              0,    // litros no tanque (direto da GWM Brasil)
  tank_avg_price_per_l: 0,   // R$/L médio ponderado do que está no tanque
  battery_avg_price_per_kwh: 0,  // R$/kWh médio ponderado do que está na bateria
  batt_12v_pct:        0,    // % bateria auxiliar 12V
  charging_state:      'Desconhecido',
  charge_power_kw:     0,
  charge_max_power_kw: 0,    // pico de potência da sessão atual (reset ao iniciar)
  charge_avg_power_kw: 0,    // potência média da sessão atual (kWh / tempo decorrido)
  charge_start_soc_pct: 0,   // % SOC quando a sessão atual começou (reset ao iniciar)
  charge_session_start_ms: 0,// timestamp do início da sessão — persistido pra sobreviver a restart
  charge_session_kwh_at_init: 0, // kWh já acumulado no momento do lazy init (0 quando sessão começa nova)
  motor_power_kw:      0,
  charge_session_kwh:  0,
  charge_remaining_min:0,
  charge_limit_pct:    null,   // % limite de carga SOC (null = desconhecido)
  battery_power_pct:   0,
  engine_rpm:          0,
  notif_latest_ts:     0,
  price_gas_per_l:     0,
  price_kwh:           0,
  charge_current_a:    0,
  battery_voltage_v:0,
  battery_current_a:0,
  soc_pct:          0,
  range_ev_km:      0,      // autonomia elétrica real (sensor HA)
  range_ice_km:     0,      // autonomia térmica real  (sensor HA)
  current_trip:     null,   // snapshot da viagem em andamento (publicado retained pelo APK)
  status_message:   '',     // string pipe-separada de alertas do carro
  engine_state:     null,   // null=desconhecido | '0'=desligado | '1'=ligado
  lock_state:       null,   // null=desconhecido | 'off'=trancado | 'on'=destrancado
  high_beam:        null,   // null | 'on' | 'off'
  light_state:      null,   // null | 'on' | 'off' — farol (sem sensor por ora)
  ac_state:         null,   // null | 'on' | 'off'
  seat_vent_drv:    null,   // null | '0'=desligado | '1'=fraco | '2'=médio | '3'=forte
  seat_vent_pass:   null,   // idem motorista
  hvac_driver_temp:    null, // null | float (°C) — temperatura definida (motorista)
  hvac_passenger_temp: null, // null | float (°C) — temperatura definida (passageiro) — pendente
  hvac_fan_speed:      null, // null | int (0..N) — velocidade do ventilador
  hvac_sync_enable:    null, // null | '0'=desligado | '1'=ligado
  hvac_auto_enable:    null, // null | '0'=desligado | '1'=ligado
  hvac_ac_enable:      null, // null | '0'=desligado | '1'=ligado — car.hvac.ac_enable
  door_fl:          null,   // front-left  | 'on'=aberta | 'off'=fechada
  door_fr:          null,   // front-right
  door_rl:          null,   // rear-left
  door_rr:          null,   // rear-right
  door_trunk:       null,   // porta-malas
  sunroof:          null,   // '3'=fechado | outro=aberto
  window_fl:        null,   // 1=fechado | 2=aberto | 3=entreaberto
  window_fr:        null,
  window_rl:        null,
  window_rr:        null,
  tyre_pressure_fl: 0,     // PSI (direto, sem conversão)
  tyre_pressure_fr: 0,
  tyre_pressure_rl: 0,
  tyre_pressure_rr: 0,
  tyre_temp_fl:     0,     // °C
  tyre_temp_fr:     0,
  tyre_temp_rl:     0,
  tyre_temp_rr:     0,

  rolling: {
    kwh_per_100km: 0, km_per_l: 0, distance_km: 0, fuel_l: 0, cost_brl: 0,
  },
  lifetime: {
    energy_kwh: 0, regen_kwh: 0, net_kwh: 0, distance_km: 0,
    time_sec: '--', fuel_l: 0, charge_kwh: 0, charge_sec: '--', cost_brl: 0,
  },

  // Timestamps do último "Limpar histórico" — rejeita dados MQTT retained anteriores
  // a este corte, impedindo que o Android restaure histórico apagado ao reconectar.
  charges_cleared_at: 0,
  trips_cleared_at:   0,
};

// ── Persistência do estado ─────────────────────────────────────────────────────
// Restaura o último estado conhecido do disco — evita zeros após restart do bridge.
// Os tópicos MQTT retained sobrescreverão os valores ao reconectar.

function deepMergeState(target, source) {
  for (const [k, v] of Object.entries(source)) {
    if (v !== null && v !== undefined) {
      if (typeof v === 'object' && !Array.isArray(v) && typeof target[k] === 'object') {
        deepMergeState(target[k], v);
      } else {
        target[k] = v;
      }
    }
  }
}

if (fs.existsSync(STATE_FILE)) {
  try {
    const saved = JSON.parse(fs.readFileSync(STATE_FILE, 'utf8'));
    // Não restaura flags de runtime — esses são redefinidos ao conectar
    delete saved.car_online;
    delete saved.bridge_online;
    delete saved.last_update_ms;
    deepMergeState(state, saved);
    // Recupera contexto da sessão de recarga em andamento após restart.
    chargeSessionStartMs = state.charge_session_start_ms || 0;
    chargeStartSoc       = state.charge_start_soc_pct   || 0;
    console.log(`✓ Estado anterior restaurado de state.json`);
  } catch (e) {
    console.error('Aviso: erro ao restaurar state.json:', e.message);
  }
}

let stateSaveTimer    = null;
let stateLastSavedAt  = 0;
function scheduleStateSave() {
  if (stateSaveTimer) clearTimeout(stateSaveTimer);
  // Trailing debounce de 2s, COM cap de 15s sem salvar. Durante recarga o APK
  // publica continuamente (charge_power_kw, charge_session_kwh, etc) em janelas
  // < 2s — sem o cap o timer era resetado pra sempre e o state.json NUNCA era
  // persistido em disco. Em caso de crash, perdíamos pico/média da sessão.
  const sinceLast = Date.now() - stateLastSavedAt;
  const delay = sinceLast > 13000 ? 0 : 2000;
  stateSaveTimer = setTimeout(() => {
    try {
      fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));
      stateLastSavedAt = Date.now();
    } catch (_) {}
  }, delay);
}

// ── Histórico de recargas — persistência JSON ─────────────────────────────────

/** @type {object[]} — sessões mais recentes primeiro */
let chargesArr = [];

if (fs.existsSync(CHARGES_FILE)) {
  try {
    const saved = JSON.parse(fs.readFileSync(CHARGES_FILE, 'utf8'));
    chargesArr = saved.charges || [];
    console.log(`✓ Recargas locais: ${chargesArr.length} sessão(ões)`);
  } catch (e) {
    console.error('Aviso: não foi possível ler charges.json:', e.message);
  }
}

let chargesSaveTimer = null;
function scheduleChargesFlush() {
  if (chargesSaveTimer) clearTimeout(chargesSaveTimer);
  chargesSaveTimer = setTimeout(() => {
    fs.writeFileSync(CHARGES_FILE, JSON.stringify({ charges: chargesArr }, null, 2));
  }, 500);
}

// ── Locais de recarga ─────────────────────────────────────────────────────────
let chargeLocations = [];
try {
  if (fs.existsSync(CHARGE_LOCS_FILE))
    chargeLocations = JSON.parse(fs.readFileSync(CHARGE_LOCS_FILE, 'utf8')) || [];
  if (chargeLocations.length) console.log(`✓ Locais de recarga: ${chargeLocations.length}`);
} catch (_) {}
function saveChargeLocations() {
  try { fs.writeFileSync(CHARGE_LOCS_FILE, JSON.stringify(chargeLocations, null, 2)); } catch (_) {}
}

// Haversine — distância em metros entre dois pontos GPS
function haversineM(lat1, lng1, lat2, lng2) {
  const R = 6371000;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLng = (lng2 - lng1) * Math.PI / 180;
  const a = Math.sin(dLat / 2) ** 2
    + Math.cos(lat1 * Math.PI / 180) * Math.cos(lat2 * Math.PI / 180)
    * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

// ── Locais Conhecidos — unificado para recargas e viagens ─────────────────────
let knownPlaces = [];
try {
  if (fs.existsSync(KNOWN_PLACES_FILE)) {
    knownPlaces = JSON.parse(fs.readFileSync(KNOWN_PLACES_FILE, 'utf8')) || [];
  } else if (chargeLocations.length) {
    // Migração one-time: charge_locations → known_places
    knownPlaces = chargeLocations.map(l => ({ ...l, radius_m: 200 }));
    fs.writeFileSync(KNOWN_PLACES_FILE, JSON.stringify(knownPlaces, null, 2));
    console.log(`✓ Migrados ${knownPlaces.length} locais → known_places.json`);
  }
  if (knownPlaces.length) console.log(`✓ Locais conhecidos: ${knownPlaces.length}`);
} catch (_) {}

function saveKnownPlaces() {
  try { fs.writeFileSync(KNOWN_PLACES_FILE, JSON.stringify(knownPlaces, null, 2)); } catch (_) {}
}

// ── Manutenções — intervalos por km + histórico ─────────────────────────────
// Pré-config inicial baseada no carro do usuário: revisão a cada 12k, última em 24.200.
let maintenance = {
  intervals: [
    { id: 'revisao', label: 'Revisão geral', every_km: 12000, every_months: 12, alert_km: 1000, alert_days: 15, icon: '🔧' },
  ],
  history: [
    {
      id: 'init-revisao-24200',
      type_id: 'revisao',
      odometer_km: 24200,
      date_ms: Date.now() - 60 * 24 * 60 * 60 * 1000,   // estimativa: ~2 meses atrás
      notes: 'Pré-configurado a partir do dado inicial do usuário',
    },
  ],
};
try {
  if (fs.existsSync(MAINTENANCE_FILE)) {
    maintenance = JSON.parse(fs.readFileSync(MAINTENANCE_FILE, 'utf8'));
  } else {
    fs.writeFileSync(MAINTENANCE_FILE, JSON.stringify(maintenance, null, 2));
    console.log('✓ maintenance.json criado com config inicial');
  }
  console.log(`✓ Manutenções: ${maintenance.intervals.length} intervalo(s), ${maintenance.history.length} registro(s)`);
} catch (e) { console.error('Aviso: maintenance.json:', e.message); }

function saveMaintenance() {
  try { fs.writeFileSync(MAINTENANCE_FILE, JSON.stringify(maintenance, null, 2)); } catch (_) {}
}

// ── Tombstones (IDs explicitamente deletados pelo usuário) ────────────────
// Sem isso, o APK reenviaria via MQTT (trips/history, charging/history) e o
// bridge re-aceitaria. Tombstone bloqueia o re-insert. Mantém últimos 2000
// por categoria pra não crescer infinito.
let deletedIds = { autotrips: [], charges: [], refuels: [] };
// Sets paralelos pra lookup O(1) — array continua sendo a fonte de verdade
// (mantém ordem de inserção e serializa direto pro JSON).
let deletedIdsSets = { autotrips: new Set(), charges: new Set(), refuels: new Set() };
try {
  if (fs.existsSync(DELETED_IDS_FILE)) {
    const loaded = JSON.parse(fs.readFileSync(DELETED_IDS_FILE, 'utf8'));
    deletedIds = { autotrips: [], charges: [], refuels: [], ...loaded };
  }
  for (const k of ['autotrips', 'charges', 'refuels']) {
    deletedIdsSets[k] = new Set(deletedIds[k].map(String));
  }
  const total = deletedIds.autotrips.length + deletedIds.charges.length + deletedIds.refuels.length;
  if (total > 0) console.log(`✓ Tombstones: ${deletedIds.autotrips.length} viagens, ${deletedIds.charges.length} recargas, ${deletedIds.refuels.length} abastecimentos`);
} catch (e) { console.error('Aviso deleted_ids:', e.message); }

function saveDeletedIds() {
  try { fs.writeFileSync(DELETED_IDS_FILE, JSON.stringify(deletedIds, null, 2)); } catch (_) {}
}
function markDeleted(kind, id) {
  const key = String(id);
  if (!deletedIds[kind]) { deletedIds[kind] = []; deletedIdsSets[kind] = new Set(); }
  if (!deletedIdsSets[kind].has(key)) {
    deletedIds[kind].push(key);
    deletedIdsSets[kind].add(key);
    if (deletedIds[kind].length > 2000) {
      deletedIds[kind] = deletedIds[kind].slice(-2000);
      deletedIdsSets[kind] = new Set(deletedIds[kind]);
    }
    saveDeletedIds();
  }
}
function isDeleted(kind, id) {
  return deletedIdsSets[kind]?.has(String(id)) || false;
}

// ── Abastecimentos ──────────────────────────────────────────────────────────
// Cada registro tem `liters_added`, opcionalmente `price_per_liter` (vazio =
// pendente, aguardando preenchimento). `fuel_l_before`/`fuel_l_after` capturam
// o estado do tanque no momento do abastecimento. `tank_avg_after` é o preço
// médio ponderado do tanque resultante (mix do que tinha + o que entrou).
let refuels = [];
try {
  if (fs.existsSync(REFUELS_FILE)) refuels = JSON.parse(fs.readFileSync(REFUELS_FILE, 'utf8')) || [];
  console.log(`✓ Abastecimentos: ${refuels.length}`);
} catch (e) { console.error('Aviso refuels.json:', e.message); }

function saveRefuels() {
  try { fs.writeFileSync(REFUELS_FILE, JSON.stringify(refuels, null, 2)); } catch (_) {}
}

// Preços de referência (seed) usados quando não há histórico próprio.
// Também valoram o combustível/energia já presente antes do primeiro registro:
// no mix do primeiro abastecimento real, o que estava no tanque conta a SEED_*.
const SEED_GAS_PRICE_PER_L = 6.50;
const SEED_KWH_PRICE       = 0.55;

// Recalcula o preço médio do tanque iterando pelos refuels em ordem cronológica.
// Lógica de mix ponderado: ao abastecer, mistura o R$/L do que sobrou com o novo.
function recomputeTankAvgPrice() {
  // Ordena por ts crescente
  const ordered = [...refuels].sort((a, b) => (a.timestamp_ms || 0) - (b.timestamp_ms || 0));
  let avgPrice = SEED_GAS_PRICE_PER_L;  // R$/L médio inicial = seed
  let lastAfter = 0;    // litros no tanque após último abastecimento processado
  for (const r of ordered) {
    if (!(r.price_per_liter > 0)) {
      // Pendente — pula no cálculo do médio. Mantém o avg anterior.
      lastAfter = +r.fuel_l_after || lastAfter;
      continue;
    }
    const before  = +r.fuel_l_before || 0;
    const after   = +r.fuel_l_after  || (before + (+r.liters_added || 0));
    const added   = +r.liters_added  || Math.max(0, after - before);
    const oldL    = Math.max(0, Math.min(before, lastAfter > 0 ? lastAfter : before));
    const total   = oldL + added;
    if (total > 0.1) avgPrice = (oldL * avgPrice + added * r.price_per_liter) / total;
    lastAfter = after;
    // Persiste no registro o snapshot
    r.tank_avg_after = +avgPrice.toFixed(3);
  }
  state.tank_avg_price_per_l = +avgPrice.toFixed(3);
  // Sempre escreve no global — quando não há refuels, avgPrice é o seed.
  state.price_gas_per_l = +avgPrice.toFixed(3);
  saveRefuels();
  publishPricesToCar();
  return avgPrice;
}

// Snapshot do tanque ao desligar o motor — usado pra detectar abastecimento ao religar
let _fuelLAtPark = 0;
let _fuelParkTs  = 0;
const REFUEL_MIN_LITERS = 5;          // threshold mínimo pra detectar abastecimento

function checkRefuelOnEngineOn() {
  const fuelNow = +state.fuel_l || 0;
  if (_fuelLAtPark <= 0 || fuelNow <= 0) return;
  const added = fuelNow - _fuelLAtPark;
  if (added < REFUEL_MIN_LITERS) return;

  // Criar registro PENDENTE (sem preço — usuário preenche depois)
  const rec = {
    id: 'r-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8),
    timestamp_ms: Date.now(),
    fuel_l_before: +_fuelLAtPark.toFixed(2),
    fuel_l_after:  +fuelNow.toFixed(2),
    liters_added:  +added.toFixed(2),
    price_per_liter: 0,           // pendente — usuário registra
    total_cost: 0,
    odometer_km: +state.odometer_km || 0,
    location_name: '',
    notes: '',
    pending: true,
  };
  refuels.push(rec);
  saveRefuels();
  addEvent('refuel_detected', `⛽ Abastecimento de ~${added.toFixed(1)}L detectado`);
  sendPush(
    `⛽ Abastecimento detectado`,
    `~${added.toFixed(1)}L. Toque pra registrar o preço.`,
    'refuel_detected'
  );
  console.log(`[refuel] detectado +${added.toFixed(1)}L (${_fuelLAtPark.toFixed(1)} → ${fuelNow.toFixed(1)})`);
  broadcast('new_refuel', rec);
}

// Idem pra bateria — itera por charges com preço e mixa com kWh estimado restante.
// kWh restante na bateria = SOC% × BATTERY_CAPACITY_KWH / 100.
function recomputeBatteryAvgPrice() {
  // chargesArr é o storage de recargas (carregado no boot via CHARGES_FILE).
  // Preço por sessão: cost_override.perKwh > 0 ou cost_override.total / energy.
  // Quando não há override, usa SEED_KWH_PRICE pra valorar a sessão.
  // Persiste `battery_avg_after` em cada recarga pra permitir reconstruir o
  // preço histórico (custo de viagens antigas com preço da época).
  const ordered = [...chargesArr].sort((a, b) => (a.timestamp_ms || 0) - (b.timestamp_ms || 0));
  let avgPrice = SEED_KWH_PRICE;  // R$/kWh médio inicial = seed
  for (const c of ordered) {
    const energy = +c.energy_kwh || 0;
    if (energy < 0.05) continue;
    const ovr = c.cost_override;
    const pricePerKwh = ovr?.free === true ? 0
                       : ovr && +ovr.perKwh > 0 ? ovr.perKwh
                       : ovr && +ovr.total  > 0 ? (ovr.total / energy)
                       : SEED_KWH_PRICE;
    const socStart = +c.soc_start || 0;
    const kWhBefore = socStart * BATTERY_CAPACITY_KWH / 100;
    const kWhAfter  = kWhBefore + energy;
    avgPrice = (kWhBefore * avgPrice + energy * pricePerKwh) / kWhAfter;
    c.battery_avg_after = +avgPrice.toFixed(4);   // snapshot pós-recarga
  }
  state.battery_avg_price_per_kwh = +avgPrice.toFixed(4);
  state.price_kwh = +avgPrice.toFixed(4);
  publishPricesToCar();
  return avgPrice;
}

// Retorna { kwhPrice, gasPrice } válidos no momento `targetMs`. Usa o
// `battery_avg_after`/`tank_avg_after` persistido na recarga/abastecimento
// IMEDIATAMENTE ANTERIOR a esse timestamp. Cai no SEED quando o histórico
// não cobre o período (viagem antes da primeira recarga).
function priceMixAtMs(targetMs) {
  // Bateria: pega o avg pós-recarga mais recente <= targetMs
  let kwhPrice = SEED_KWH_PRICE;
  const cBefore = chargesArr
    .filter(c => (c.timestamp_ms || 0) <= targetMs && c.battery_avg_after != null)
    .sort((a, b) => (b.timestamp_ms || 0) - (a.timestamp_ms || 0))[0];
  if (cBefore) kwhPrice = +cBefore.battery_avg_after || kwhPrice;
  // Tanque: idem com refuels
  let gasPrice = SEED_GAS_PRICE_PER_L;
  const rBefore = refuels
    .filter(r => (r.timestamp_ms || 0) <= targetMs && r.tank_avg_after != null)
    .sort((a, b) => (b.timestamp_ms || 0) - (a.timestamp_ms || 0))[0];
  if (rBefore) gasPrice = +rBefore.tank_avg_after || gasPrice;
  return { kwhPrice, gasPrice };
}

// Publica os preços médios atuais no MQTT (retained) pra o APK do carro guardar
// nas SharedPreferences e usar nos cálculos internos da tela de viagem.
let _lastPublishedGas = null, _lastPublishedKwh = null;
function publishPricesToCar() {
  // mqttClient é declarado depois do boot — protege contra TDZ no primeiro
  // recompute (que roda antes do mqtt.connect).
  let client;
  try { client = mqttClient; } catch (_) { return; }
  if (!client?.connected) return;
  const gas = +state.price_gas_per_l || 0;
  const kwh = +state.price_kwh || 0;
  if (gas > 0 && gas !== _lastPublishedGas) {
    client.publish(`${MQTT_PREFIX}/cmd/set_price_gas_per_l`, gas.toFixed(3),
      { qos: 1, retain: true });
    _lastPublishedGas = gas;
  }
  if (kwh > 0 && kwh !== _lastPublishedKwh) {
    client.publish(`${MQTT_PREFIX}/cmd/set_price_kwh`, kwh.toFixed(4),
      { qos: 1, retain: true });
    _lastPublishedKwh = kwh;
  }
}

// Estado de alerta já disparado por intervalo (evita re-notificar a cada km).
// Reseta automaticamente quando uma nova manutenção é registrada (ciclo novo).
// Persistido em maintenance.json como `_alerts: { type_id: 'soon'|'overdue' }`.
maintenance._alerts = maintenance._alerts || {};

// Compõe descrição "X km / Y dias" da condição que disparou o alerta
function _maintBody(it) {
  const parts = [];
  if (it.has_km && it.km_status !== 'ok') {
    const rk = it.remaining_km;
    parts.push(rk <= 0
      ? `${Math.round(Math.abs(rk)).toLocaleString('pt-BR')} km atrasada`
      : `${Math.round(rk).toLocaleString('pt-BR')} km restantes`);
  }
  if (it.has_time && it.time_status !== 'ok') {
    const rd = it.remaining_days;
    parts.push(rd <= 0
      ? `${Math.abs(rd)} dias atrasada`
      : `${rd} dias restantes`);
  }
  return parts.join(' · ') || `${Math.round(it.remaining_km).toLocaleString('pt-BR')} km`;
}

function checkMaintenanceAlerts() {
  const items = computeMaintenance();
  for (const it of items) {
    const prev = maintenance._alerts[it.id] || 'ok';
    if (it.status === prev) continue;  // sem mudança de severidade

    // Só notifica em transição pra estado MAIS severo (ok→soon, ok→overdue, soon→overdue)
    const order = { ok: 0, soon: 1, overdue: 2 };
    if (order[it.status] > order[prev]) {
      const body = _maintBody(it);
      if (it.status === 'soon') {
        sendPush(`${it.icon || '🔧'} ${it.label} se aproximando`, body, 'maintenance_soon');
        addEvent('maint_soon', `${it.icon || '🔧'} ${it.label}: ${body}`);
      } else if (it.status === 'overdue') {
        sendPush(`⚠️ ${it.label} atrasada`, body, 'maintenance_overdue');
        addEvent('maint_overdue', `⚠️ ${it.label}: ${body}`);
      }
    }
    maintenance._alerts[it.id] = it.status;
    saveMaintenance();
  }
}

// Verificação diária pros alertas por tempo (km já dispara em cada update do odo)
setInterval(checkMaintenanceAlerts, 60 * 60 * 1000);  // 1h

// ── Detecção de anomalia preventiva ────────────────────────────────────────
// Mantém histórico de snapshots diários (telemetry_history.json) e dispara
// push notif quando uma métrica se desvia significativamente da média móvel
// dos últimos N dias. Não substitui sensores de defeito do carro — é um
// "olha esquisito" baseado em variações graduais.
let telemetryHistory = [];
try {
  if (fs.existsSync(TELEMETRY_LOG_FILE)) {
    telemetryHistory = JSON.parse(fs.readFileSync(TELEMETRY_LOG_FILE, 'utf8')) || [];
  }
  console.log(`✓ Snapshots de telemetria: ${telemetryHistory.length}`);
} catch (e) { console.error('Aviso telemetry_history:', e.message); }

function _todayKey() {
  return new Date().toISOString().slice(0, 10);  // YYYY-MM-DD
}

// Pressão é registrada só quando o pneu está "a frio" (≤ TYRE_COLD_C°C).
// Em movimento o pneu esquenta e a pressão sobe ~1 PSI a cada 10°C — incluir
// essas leituras na média histórica inflava o baseline e gerava falso "perdendo
// pressão" quando o carro voltava a esfriar. A captura mantém o pneu anterior
// (não sobrescreve com 0) quando a temperatura inviabiliza a leitura.
const TYRE_COLD_C = 28;

function _tyreColdPsi(pos) {
  const psi = +state[`tyre_pressure_${pos}`] || 0;
  const t   = +state[`tyre_temp_${pos}`]     || 0;
  // Sem leitura de PSI ou temperatura elevada: retorna null pra preservar
  // o valor anterior do snapshot do dia (não dilui a média com 0).
  if (psi <= 5) return null;
  if (t > TYRE_COLD_C) return null;
  return psi;
}

function captureTelemetrySnapshot() {
  const today = _todayKey();
  const idx = telemetryHistory.findIndex(s => s.date === today);
  const prev = idx >= 0 ? telemetryHistory[idx] : null;
  // Pneus: usa leitura a frio quando disponível; senão preserva o que tinha no
  // snapshot anterior do dia (ou 0 se primeira chamada do dia).
  const tyre = (pos) => {
    const cold = _tyreColdPsi(pos);
    if (cold != null) return cold;
    return prev ? (+prev[`tyre_${pos}`] || 0) : 0;
  };
  const snap = {
    date: today,
    ts: Date.now(),
    tyre_fl: tyre('fl'),
    tyre_fr: tyre('fr'),
    tyre_rl: tyre('rl'),
    tyre_rr: tyre('rr'),
    batt_12v: +state.batt_12v_pct || 0,
    autonomy_ice: +state.autonomy_ice_km || 0,
    autonomy_ev:  +state.autonomy_ev_km  || 0,
    fuel_l: +state.fuel_l || 0,
    soc_pct: +state.soc_pct || 0,
    odometer: +state.odometer_km || 0,
  };
  if (idx >= 0) telemetryHistory[idx] = snap;
  else telemetryHistory.push(snap);
  // Mantém só os últimos 90 dias
  if (telemetryHistory.length > 90) telemetryHistory = telemetryHistory.slice(-90);
  try { fs.writeFileSync(TELEMETRY_LOG_FILE, JSON.stringify(telemetryHistory, null, 2)); } catch (_) {}
}

// Detecta anomalias comparando o snapshot atual com a média dos últimos 14d.
// Evita re-alertar todo dia: mantém memória do dia de cada alerta disparado.
let _anomalyAlerted = {};  // { metric: 'YYYY-MM-DD' }
function checkAnomalies() {
  if (telemetryHistory.length < 7) return;  // amostra mínima
  const today = _todayKey();
  const last = telemetryHistory[telemetryHistory.length - 1];
  const window = telemetryHistory.slice(-15, -1);  // últimos 14 dias (excluindo hoje)
  if (window.length < 5) return;
  const avg = (key) => {
    const vals = window.map(s => +s[key] || 0).filter(v => v > 0);
    return vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : 0;
  };

  const issues = [];

  // Pneus: cada um cai mais de 2 PSI da média
  for (const pos of ['fl', 'fr', 'rl', 'rr']) {
    const k = `tyre_${pos}`;
    const a = avg(k), cur = +last[k] || 0;
    if (a > 0 && cur > 0 && (a - cur) >= 2) {
      issues.push({
        metric: `tyre_${pos}_drop`,
        title: `🚗 Pneu ${pos.toUpperCase()} perdendo pressão`,
        body: `Atual ${cur.toFixed(1)} PSI · média 14d ${a.toFixed(1)} PSI (−${(a-cur).toFixed(1)})`,
      });
    }
  }

  // Bateria 12V abaixo de 75% e tendência caindo
  const v12 = avg('batt_12v'), cur12 = +last.batt_12v || 0;
  if (v12 > 0 && cur12 > 0 && cur12 < 75 && (v12 - cur12) >= 5) {
    issues.push({
      metric: 'batt_12v_low',
      title: '🔋 Bateria 12V baixa',
      body: `Atual ${cur12}% · média ${v12.toFixed(0)}%. Considere verificar.`,
    });
  }

  // Autonomia ICE caindo com tanque similar (pode indicar filtro/injeção)
  if (last.fuel_l > 5) {
    const recent = telemetryHistory.slice(-15).filter(s => Math.abs((s.fuel_l || 0) - last.fuel_l) < 3 && (s.autonomy_ice || 0) > 0);
    if (recent.length >= 5) {
      const sortedByDate = [...recent].sort((a, b) => a.ts - b.ts);
      const first3 = sortedByDate.slice(0, 3).map(s => s.autonomy_ice);
      const last3  = sortedByDate.slice(-3).map(s => s.autonomy_ice);
      const avgFirst = first3.reduce((a, b) => a + b, 0) / first3.length;
      const avgLast  = last3.reduce((a, b) => a + b, 0) / last3.length;
      if (avgFirst > 0 && (avgFirst - avgLast) / avgFirst > 0.10) {
        issues.push({
          metric: 'autonomy_ice_drop',
          title: '⛽ Autonomia (combustão) caindo',
          body: `Com tanque ~${last.fuel_l.toFixed(0)}L, estimativa caiu de ${avgFirst.toFixed(0)} km pra ${avgLast.toFixed(0)} km.`,
        });
      }
    }
  }

  // Dispara alertas — evita repetir o mesmo no mesmo dia
  for (const iss of issues) {
    if (_anomalyAlerted[iss.metric] === today) continue;
    _anomalyAlerted[iss.metric] = today;
    addEvent('anomaly', `${iss.title} — ${iss.body}`);
    sendPush(iss.title, iss.body, 'anomaly_detected');
  }
}

// Captura snapshot diário + check de anomalia 1×/dia (à meia-noite + boot)
function _runDailyTelemetry() {
  captureTelemetrySnapshot();
  checkAnomalies();
}
setTimeout(_runDailyTelemetry, 30 * 1000);                       // 30s após boot
setInterval(_runDailyTelemetry, 24 * 60 * 60 * 1000);            // 24h

// Computa o status de cada intervalo (próxima manutenção, km restantes, severidade)
// Média de km/dia dos últimos N dias (default 30) baseada em autotrips.
// Cai pra 0 se não houver viagens — UI trata como "sem ETA".
function avgDailyKm(daysWindow = 30) {
  const now = Date.now();
  const cutoff = now - daysWindow * 24 * 60 * 60 * 1000;
  let totalKm = 0, firstMs = now;
  for (const t of autoTripsArr) {
    if ((t.startMs || 0) < cutoff) continue;
    totalKm += +t.distKm || 0;
    if ((t.startMs || 0) < firstMs) firstMs = t.startMs;
  }
  const spanMs = Math.max(now - firstMs, 24 * 60 * 60 * 1000); // mín 1 dia
  return totalKm / (spanMs / (24 * 60 * 60 * 1000));
}

function computeMaintenance() {
  const odom = +state.odometer_km || 0;
  const now  = Date.now();
  const MS_PER_DAY = 24 * 60 * 60 * 1000;
  // km/dia médio dos últimos 30 dias — usado pra prever DATA do próximo
  // vencimento por km (até hoje só prevíamos por meses). Se < 1 km/dia,
  // ignora a previsão (carro parado ou recém-instalado).
  const dailyKm = avgDailyKm(30);
  return maintenance.intervals.map(itv => {
    // Pega registro mais recente pra essa manutenção — preferindo o de maior
    // odômetro (fallback: data mais recente se odômetro for igual/zero).
    const all = maintenance.history.filter(h => h.type_id === itv.id);
    const last = all.sort((a, b) => {
      const dk = (b.odometer_km || 0) - (a.odometer_km || 0);
      return dk !== 0 ? dk : (b.date_ms || 0) - (a.date_ms || 0);
    })[0];
    const lastKm   = last ? last.odometer_km : 0;
    const lastDate = last?.date_ms || null;

    // ── Componente km ──
    const everyKm    = +itv.every_km || 0;
    const alertKm    = +itv.alert_km || 500;
    const hasKm      = everyKm > 0;
    const nextKm     = hasKm ? lastKm + everyKm : 0;
    const remainKm   = hasKm ? (nextKm - odom) : Infinity;
    let kmStatus = 'ok';
    if (hasKm) {
      if (remainKm <= 0)        kmStatus = 'overdue';
      else if (remainKm <= alertKm) kmStatus = 'soon';
    }

    // ── Componente tempo (meses) ──
    const everyMonths = +itv.every_months || 0;
    const alertDays   = +itv.alert_days   || 15;
    const hasTime     = everyMonths > 0 && lastDate;
    let nextDate = null, remainDays = Infinity, timeStatus = 'ok';
    if (hasTime) {
      const d = new Date(lastDate);
      d.setMonth(d.getMonth() + everyMonths);
      nextDate = d.getTime();
      remainDays = Math.round((nextDate - now) / MS_PER_DAY);
      if (remainDays <= 0)              timeStatus = 'overdue';
      else if (remainDays <= alertDays) timeStatus = 'soon';
    }

    // Status final: o pior entre os dois (overdue > soon > ok)
    const order = { ok: 0, soon: 1, overdue: 2 };
    const status = order[kmStatus] >= order[timeStatus] ? kmStatus : timeStatus;

    // ── ETA por km/dia: estima quantos dias ainda faltam pro vencimento
    // por km, baseado no ritmo de uso recente. Se carro está parado
    // (dailyKm < 1) ou intervalo não usa km, ignora.
    let etaDaysFromKm = null, etaDateMsFromKm = null;
    if (hasKm && dailyKm >= 1 && remainKm > 0 && Number.isFinite(remainKm)) {
      etaDaysFromKm = Math.round(remainKm / dailyKm);
      etaDateMsFromKm = now + etaDaysFromKm * MS_PER_DAY;
    }

    return {
      ...itv,
      last_km: lastKm,
      last_date_ms: lastDate,
      next_km: nextKm,
      remaining_km: remainKm,
      next_date_ms: nextDate,
      remaining_days: hasTime ? remainDays : null,
      km_status: kmStatus,
      time_status: timeStatus,
      has_km: hasKm,
      has_time: hasTime,
      eta_days_from_km: etaDaysFromKm,     // dias previstos até vencer pelo km/dia
      eta_date_ms_from_km: etaDateMsFromKm, // timestamp previsto
      status,
    };
  });
}

// Retorna o local conhecido mais próximo dentro do raio do local, ou null
function matchKnownPlace(lat, lng) {
  if (!lat || !lng) return null;
  let best = null, bestDist = Infinity;
  for (const loc of knownPlaces) {
    if (!loc.lat || !loc.lng) continue;
    const d = haversineM(lat, lng, loc.lat, loc.lng);
    const r = loc.radius_m || 200;
    if (d < r && d < bestDist) { best = loc; bestDist = d; }
  }
  return best;
}

// ── Geofence: detecta entrada/saída de locais conhecidos e dispara push ───
// Mantém estado por place {id → 'in'|'out'}. Histerese de 20% no raio pra evitar
// flapping na borda. Saída só notifica se motor ligado (evita ruído de
// reconexão GPS). Loga eventos `geofence_in` / `geofence_out` em events.json.
const geofenceState = {};  // { placeId: 'in' | 'out' }
function checkGeofence() {
  const lat = state.gps_lat, lng = state.gps_lng;
  if (!lat || !lng) return;
  const engineOn = String(state.engine_state) === '1' || state.engine_state === 1;
  for (const loc of knownPlaces) {
    if (!loc.lat || !loc.lng) continue;
    const r = loc.radius_m || 200;
    const d = haversineM(lat, lng, loc.lat, loc.lng);
    const prev = geofenceState[loc.id];
    const isInside = d < r;
    // Histerese: pra mudar IN → OUT precisa estar 20% além do raio
    const isOutside = d > r * 1.2;
    if (isInside && prev !== 'in') {
      geofenceState[loc.id] = 'in';
      if (prev === 'out') {  // só notifica se houve transição (não no boot)
        addEvent('geofence_in', `📍 Chegou em ${loc.name}`);
        // Filtro de places permanece global (todos devices reagem aos mesmos locais).
        // O on/off da categoria geofence_arrival fica por device dentro do sendPush.
        const arrPlaces = notifPrefs.geofence_arrival_places || [];
        if (arrPlaces.length === 0 || arrPlaces.includes(String(loc.id)))
          sendPush(`📍 Chegou em ${loc.name}`, `Veículo dentro da zona.`, 'geofence_arrival');
      }
    } else if (isOutside && prev !== 'out') {
      geofenceState[loc.id] = 'out';
      if (prev === 'in' && engineOn) {  // saída só com motor ligado
        addEvent('geofence_out', `🚗 Saiu de ${loc.name}`);
        const depPlaces = notifPrefs.geofence_departure_places || [];
        if (depPlaces.length === 0 || depPlaces.includes(String(loc.id)))
          sendPush(`🚗 Saiu de ${loc.name}`, `Veículo deixou a zona.`, 'geofence_departure');
      }
    }
  }
}

// Retorna o local conhecido mais próximo dentro de radiusM metros, ou null
function autoMatchLocation(lat, lng, radiusM = 200) {
  // Tenta known_places primeiro (raio por local); fallback para chargeLocations com raio fixo
  const kp = matchKnownPlace(lat, lng);
  if (kp) return kp;
  if (!lat || !lng) return null;
  let best = null, bestDist = Infinity;
  for (const loc of chargeLocations) {
    if (!loc.lat || !loc.lng) continue;
    const d = haversineM(lat, lng, loc.lat, loc.lng);
    if (d < radiusM && d < bestDist) { best = loc; bestDist = d; }
  }
  return best;
}

// ── Express + HTTP ────────────────────────────────────────────────────────────

const app    = express();
const server = http.createServer(app);

// ── HTTPS opcional — ativo quando cert.pem + key.pem existem no diretório ────
// Setup: brew install mkcert && mkcert -install
//        cd ~/haval-ecotrip/bridge
//        mkcert mac-mini.local localhost 127.0.0.1 <IP-LAN>
//        mv mac-mini.local+*.pem cert.pem; mv mac-mini.local+*-key.pem key.pem
const HTTPS_PORT = parseInt(process.env.HTTPS_PORT || '3443', 10);
const _certFile  = path.join(__dirname, 'cert.pem');
const _keyFile   = path.join(__dirname, 'key.pem');
let httpsServer  = null;
if (fs.existsSync(_certFile) && fs.existsSync(_keyFile)) {
  try {
    httpsServer = require('https').createServer(
      { cert: fs.readFileSync(_certFile), key: fs.readFileSync(_keyFile) },
      app
    );
    console.log('✅  Certificado HTTPS encontrado — porta', HTTPS_PORT);
  } catch (e) {
    console.warn('⚠️  HTTPS: falha ao ler certificado —', e.message);
  }
}

app.use(require('compression')());  // gzip — backup de 11MB cai pra ~1.5MB
app.use(express.json({ limit: '200mb' }));
app.use(express.static(path.join(__dirname, 'public')));

// ── Autenticação ──────────────────────────────────────────────────────────────
// O cliente envia SHA-256(senha) no header Authorization: Bearer <hash>
// O servidor compara com BRIDGE_TOKEN_HASH armazenado no .env
function requireAuth(req, res, next) {
  if (!BRIDGE_TOKEN_HASH) return next();   // sem hash configurado → sem auth (dev local)
  const auth  = req.headers['authorization'] || '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
  // Aceita SHA-256(senha) [HTTPS] ou texto puro [HTTP — fallback quando crypto.subtle indisponível]
  const valid = token === BRIDGE_TOKEN_HASH || sha256hex(token) === BRIDGE_TOKEN_HASH;
  if (!valid) return res.status(401).json({ error: 'unauthorized' });
  next();
}
// Ping público — sem auth, útil para verificar se o servidor está online
app.get('/ping', (_req, res) => res.json({ ok: true, ts: Date.now() }));

// ── /api/auth/* — rotas de autenticação (públicas e privadas) ────────────────
// Rate limit simples por IP pra /api/auth/login: 5 tentativas/min, 15min de
// bloqueio após 10 falhas consecutivas. Hash da senha NUNCA volta no response.
const _loginAttempts = new Map();   // ip → { count, firstMs, blockedUntilMs }
function _checkRateLimit(ip) {
  const now = Date.now();
  let s = _loginAttempts.get(ip);
  if (!s) { s = { count: 0, firstMs: now, blockedUntilMs: 0 }; _loginAttempts.set(ip, s); }
  if (s.blockedUntilMs > now) return { ok: false, retryAfterSec: Math.ceil((s.blockedUntilMs - now) / 1000) };
  if (now - s.firstMs > 60_000) { s.count = 0; s.firstMs = now; }  // janela de 1min
  return { ok: true, state: s };
}
function _registerFailure(s) {
  s.count++;
  if (s.count >= 10) s.blockedUntilMs = Date.now() + 15 * 60_000;   // bloqueio 15min
}
function _registerSuccess(ip) { _loginAttempts.delete(ip); }

// POST /api/auth/login — { password_hash, totp_code? } → { ok, token? }
app.post('/api/auth/login', (req, res) => {
  const ip = req.ip || req.connection?.remoteAddress || 'unknown';
  const rl = _checkRateLimit(ip);
  if (!rl.ok) return res.status(429).json({ error: 'rate_limited', retry_after_sec: rl.retryAfterSec });
  if (rl.state.count >= 5) return res.status(429).json({ error: 'too_many_attempts' });
  const { password_hash, totp_code } = req.body || {};
  // Sem hash configurado no servidor (dev mode) → aceita qualquer login
  if (!BRIDGE_TOKEN_HASH) return res.json({ ok: true, token: '' });
  const passwordValid = password_hash === BRIDGE_TOKEN_HASH ||
                        (password_hash && sha256hex(password_hash) === BRIDGE_TOKEN_HASH);
  if (!passwordValid) {
    _registerFailure(rl.state);
    return res.status(401).json({ error: 'invalid_password' });
  }
  // Senha ok. Se 2FA está ativo, exige o código.
  if (is2faEnabled()) {
    if (!totp_code) return res.status(401).json({ error: 'totp_required', requires_2fa: true });
    if (!verifyTotpOrBackup(totp_code)) {
      _registerFailure(rl.state);
      return res.status(401).json({ error: 'invalid_totp' });
    }
  }
  _registerSuccess(ip);
  res.json({ ok: true, token: BRIDGE_TOKEN_HASH });
});

// GET /api/auth/2fa/status — pública: PWA chama no início pra saber se precisa pedir código
app.get('/api/auth/2fa/status', (_req, res) => res.json({ enabled: is2faEnabled() }));

// ── Google Sign-In ────────────────────────────────────────────────────────────
const GOOGLE_OAUTH_CLIENT_ID = process.env.GOOGLE_OAUTH_CLIENT_ID || '';
const GOOGLE_ALLOWED_EMAILS  = (process.env.GOOGLE_ALLOWED_EMAILS || '')
  .split(',').map(s => s.trim().toLowerCase()).filter(Boolean);
let googleAuthClient = null;
if (GOOGLE_OAUTH_CLIENT_ID) {
  try {
    const { OAuth2Client } = require('google-auth-library');
    googleAuthClient = new OAuth2Client(GOOGLE_OAUTH_CLIENT_ID);
    console.log(`✓ Google Sign-In: client configurado · ${GOOGLE_ALLOWED_EMAILS.length} email(s) na whitelist`);
  } catch (e) { console.error('Falha google-auth-library:', e.message); }
}

// GET /api/auth/google/config — público. PWA usa pra saber se renderiza botão e qual client ID.
app.get('/api/auth/google/config', (_req, res) => res.json({
  enabled:    !!googleAuthClient,
  client_id:  GOOGLE_OAUTH_CLIENT_ID || null,
}));

// POST /api/auth/google/login — { credential (ID token), totp_code? } → { ok, token }
// Verifica o ID token (assinado pelo Google), checa email contra whitelist,
// aplica 2FA TOTP se ativo. Retorna o bearer (mesmo BRIDGE_TOKEN_HASH).
app.post('/api/auth/google/login', async (req, res) => {
  if (!googleAuthClient) return res.status(503).json({ error: 'google_login_disabled' });
  const ip = req.ip || req.connection?.remoteAddress || 'unknown';
  const rl = _checkRateLimit(ip);
  if (!rl.ok) return res.status(429).json({ error: 'rate_limited', retry_after_sec: rl.retryAfterSec });
  if (rl.state.count >= 5) return res.status(429).json({ error: 'too_many_attempts' });

  const { credential, totp_code } = req.body || {};
  if (!credential) return res.status(400).json({ error: 'missing_credential' });

  let payload;
  try {
    const ticket = await googleAuthClient.verifyIdToken({
      idToken:  credential,
      audience: GOOGLE_OAUTH_CLIENT_ID,
    });
    payload = ticket.getPayload();
  } catch (e) {
    _registerFailure(rl.state);
    return res.status(401).json({ error: 'invalid_credential', detail: e.message });
  }

  const email = (payload?.email || '').toLowerCase();
  if (!email || !payload.email_verified) {
    _registerFailure(rl.state);
    return res.status(401).json({ error: 'email_not_verified' });
  }
  if (GOOGLE_ALLOWED_EMAILS.length > 0 && !GOOGLE_ALLOWED_EMAILS.includes(email)) {
    _registerFailure(rl.state);
    return res.status(403).json({ error: 'email_not_allowed', email });
  }

  // 2FA: se ativo, exige o código (igual ao login por senha)
  if (is2faEnabled()) {
    if (!totp_code) return res.status(401).json({ error: 'totp_required', requires_2fa: true, email });
    if (!verifyTotpOrBackup(totp_code)) {
      _registerFailure(rl.state);
      return res.status(401).json({ error: 'invalid_totp' });
    }
  }

  _registerSuccess(ip);
  console.log(`[auth] login Google OK · ${email}`);
  res.json({ ok: true, token: BRIDGE_TOKEN_HASH, email });
});

// requireAuth: aplica a toda a API exceto /api/push/* (SW não consegue enviar headers)
// e rotas de auth públicas (login, google, status).
app.use('/api', (req, res, next) => {
  if (req.path.startsWith('/push')) return next();        // push routes: sem auth
  if (req.path === '/auth/login' ||
      req.path === '/auth/2fa/status' ||
      req.path === '/auth/google/config' ||
      req.path === '/auth/google/login' ||
      req.path === '/auth/passkey/available' ||
      req.path === '/auth/passkey/login/begin' ||
      req.path === '/auth/passkey/login/finish') return next();
  requireAuth(req, res, next);
});

// POST /api/auth/2fa/setup — autenticado. Gera secret + QR + backup codes
// mas NÃO ativa ainda. Cliente precisa confirmar via /api/auth/2fa/activate.
let _pending2faSecret = null;   // { secret, generatedAt }
app.post('/api/auth/2fa/setup', async (req, res) => {
  const secret = otplib.authenticator.generateSecret();
  _pending2faSecret = { secret, generatedAt: Date.now() };
  const issuer = 'EcoTrip Impulse';
  const label  = 'bridge';
  const uri    = otplib.authenticator.keyuri(label, issuer, secret);
  const qrDataUrl = await QRCode.toDataURL(uri);
  res.json({ secret, qr: qrDataUrl, otpauth_uri: uri });
});

// POST /api/auth/2fa/activate — { code } confirma e persiste. Retorna backup codes.
app.post('/api/auth/2fa/activate', (req, res) => {
  const { code } = req.body || {};
  if (!_pending2faSecret) return res.status(400).json({ error: 'no_pending_setup' });
  if (Date.now() - _pending2faSecret.generatedAt > 10 * 60_000) {
    _pending2faSecret = null;
    return res.status(400).json({ error: 'setup_expired' });
  }
  if (!code || !otplib.authenticator.check(String(code).trim(), _pending2faSecret.secret)) {
    return res.status(401).json({ error: 'invalid_code' });
  }
  authConfig.totp_secret  = _pending2faSecret.secret;
  authConfig.backup_codes = genBackupCodes(10);
  saveAuthConfig();
  _pending2faSecret = null;
  res.json({ ok: true, backup_codes: authConfig.backup_codes });
});

// POST /api/auth/2fa/disable — autenticado + exige código TOTP atual
app.post('/api/auth/2fa/disable', (req, res) => {
  if (!is2faEnabled()) return res.json({ ok: true, already_disabled: true });
  const { code } = req.body || {};
  if (!verifyTotpOrBackup(code)) return res.status(401).json({ error: 'invalid_code' });
  authConfig = { totp_secret: '', backup_codes: [] };
  saveAuthConfig();
  res.json({ ok: true });
});

// GET /api/auth/2fa/backup-codes — lista códigos restantes (não regenera)
app.get('/api/auth/2fa/backup-codes', (_req, res) => {
  res.json({ enabled: is2faEnabled(), backup_codes: authConfig.backup_codes || [] });
});

// POST /api/auth/2fa/regenerate-backup — gera nova lista, descarta a antiga
app.post('/api/auth/2fa/regenerate-backup', (req, res) => {
  if (!is2faEnabled()) return res.status(400).json({ error: 'not_enabled' });
  const { code } = req.body || {};
  if (!verifyTotpOrBackup(code)) return res.status(401).json({ error: 'invalid_code' });
  authConfig.backup_codes = genBackupCodes(10);
  saveAuthConfig();
  res.json({ ok: true, backup_codes: authConfig.backup_codes });
});

// ── Passkeys (WebAuthn) ───────────────────────────────────────────────────────
// Login biométrico complementar (Face ID/Touch ID/fingerprint). O user PRIMEIRO
// faz login normal com senha+TOTP; daí registra a passkey nesse device. Próximas
// vezes pode entrar direto com biometria. O caminho senha+TOTP continua existindo
// como fallback se o device for perdido.
const PASSKEYS_FILE = path.join(__dirname, 'passkeys.json');
let passkeys = [];
try {
  if (fs.existsSync(PASSKEYS_FILE)) {
    passkeys = JSON.parse(fs.readFileSync(PASSKEYS_FILE, 'utf8')).passkeys || [];
    console.log(`✓ Passkeys: ${passkeys.length} registrada(s)`);
  }
} catch (e) { console.error('Aviso passkeys.json:', e.message); }
function savePasskeys() {
  try {
    fs.writeFileSync(PASSKEYS_FILE, JSON.stringify({
      updatedAt: new Date().toISOString(),
      passkeys,
    }, null, 2));
  } catch (e) { console.error('Falha salvar passkeys:', e.message); }
}

// Challenges efêmeros — TTL 5min. Sem persistência: se o bridge cai no meio
// do registro/login, é só recomeçar.
const _passkeyChallenges = new Map();   // challenge → expiresMs
const _PASSKEY_CHALLENGE_TTL = 5 * 60 * 1000;
function _putChallenge(ch) { _passkeyChallenges.set(ch, Date.now() + _PASSKEY_CHALLENGE_TTL); }
function _takeChallenge(ch) {
  const exp = _passkeyChallenges.get(ch);
  if (!exp) return false;
  _passkeyChallenges.delete(ch);
  return exp > Date.now();
}
setInterval(() => {
  const now = Date.now();
  for (const [k, v] of _passkeyChallenges) if (v < now) _passkeyChallenges.delete(k);
}, 10 * 60 * 1000).unref();

// Lazy import — só quando o primeiro endpoint é chamado, pra não atrasar boot.
let _swa = null;
function _swaLib() {
  if (!_swa) _swa = require('@simplewebauthn/server');
  return _swa;
}

// rpID é o domínio (sem protocolo nem porta). Pega do header Host pra suportar
// Tailscale Funnel sem hardcode. Origin é montado com https:// porque WebAuthn
// só funciona em HTTPS (ou localhost).
function _passkeyRpInfo(req) {
  const host = req.headers.host || 'localhost';
  const rpID = host.split(':')[0];
  const proto = (rpID === 'localhost' || rpID.startsWith('127.')) ? 'http' : 'https';
  const origin = `${proto}://${host}`;
  return { rpID, rpName: 'EcoTrip', origin };
}

// GET /api/auth/passkey — lista passkeys do user (autenticado)
app.get('/api/auth/passkey', (_req, res) => {
  res.json({
    passkeys: passkeys.map(p => ({
      id: p.id,
      device_name: p.device_name || 'Dispositivo',
      created_ms: p.created_ms,
      last_used_ms: p.last_used_ms || null,
    })),
  });
});

// POST /api/auth/passkey/register/begin — gera challenge de registro (autenticado)
app.post('/api/auth/passkey/register/begin', async (req, res) => {
  try {
    const { rpID, rpName } = _passkeyRpInfo(req);
    const opts = await _swaLib().generateRegistrationOptions({
      rpName, rpID,
      userID:    Buffer.from('ecotrip-user'),         // single-user
      userName:  'EcoTrip',
      attestationType: 'none',
      excludeCredentials: passkeys.map(p => ({
        id: p.id,
        transports: p.transports,
      })),
      authenticatorSelection: {
        residentKey: 'preferred',
        userVerification: 'preferred',                 // Face ID/Touch ID quando disponível
      },
    });
    _putChallenge(opts.challenge);
    res.json(opts);
  } catch (e) {
    console.error('passkey register/begin:', e);
    res.status(500).json({ error: e.message });
  }
});

// POST /api/auth/passkey/register/finish — valida e armazena a credential
app.post('/api/auth/passkey/register/finish', async (req, res) => {
  try {
    const { response, device_name } = req.body || {};
    if (!response) return res.status(400).json({ error: 'missing response' });
    const expectedChallenge = response.response?.clientDataJSON
      ? JSON.parse(Buffer.from(response.response.clientDataJSON, 'base64url').toString()).challenge
      : null;
    if (!expectedChallenge || !_takeChallenge(expectedChallenge)) {
      return res.status(400).json({ error: 'invalid_or_expired_challenge' });
    }
    const { rpID, origin } = _passkeyRpInfo(req);
    const verification = await _swaLib().verifyRegistrationResponse({
      response,
      expectedChallenge,
      expectedOrigin: origin,
      expectedRPID:   rpID,
    });
    if (!verification.verified || !verification.registrationInfo) {
      return res.status(400).json({ error: 'verification_failed' });
    }
    const reg = verification.registrationInfo;
    const cred = reg.credential || reg;       // v13 traz dentro de .credential
    const newPk = {
      id:           cred.id,
      publicKey:    Buffer.from(cred.publicKey).toString('base64url'),
      counter:      cred.counter || 0,
      transports:   cred.transports || response.response?.transports || [],
      device_name:  String(device_name || 'Dispositivo').slice(0, 60),
      created_ms:   Date.now(),
      last_used_ms: null,
    };
    passkeys.push(newPk);
    savePasskeys();
    console.log(`[passkey] registrada: ${newPk.device_name} (id=${newPk.id.slice(0, 12)}…)`);
    res.json({ ok: true, id: newPk.id });
  } catch (e) {
    console.error('passkey register/finish:', e);
    res.status(500).json({ error: e.message });
  }
});

// DELETE /api/auth/passkey/:id — remove passkey
app.delete('/api/auth/passkey/:id', (req, res) => {
  const id = String(req.params.id);
  const idx = passkeys.findIndex(p => p.id === id);
  if (idx < 0) return res.status(404).json({ error: 'not_found' });
  const [removed] = passkeys.splice(idx, 1);
  savePasskeys();
  console.log(`[passkey] removida: ${removed.device_name}`);
  res.json({ ok: true });
});

// POST /api/auth/passkey/login/begin — público. Gera challenge + lista de
// credentials permitidas. Sem rate limit aqui — o limit aplica ao /finish.
app.post('/api/auth/passkey/login/begin', async (req, res) => {
  try {
    if (!passkeys.length) return res.status(404).json({ error: 'no_passkeys_registered' });
    const { rpID } = _passkeyRpInfo(req);
    const opts = await _swaLib().generateAuthenticationOptions({
      rpID,
      allowCredentials: passkeys.map(p => ({
        id: p.id,
        transports: p.transports,
      })),
      userVerification: 'preferred',
    });
    _putChallenge(opts.challenge);
    res.json(opts);
  } catch (e) {
    console.error('passkey login/begin:', e);
    res.status(500).json({ error: e.message });
  }
});

// POST /api/auth/passkey/login/finish — valida assertion e emite o bearer
app.post('/api/auth/passkey/login/finish', async (req, res) => {
  const ip = req.ip || req.connection?.remoteAddress || 'unknown';
  const rl = _checkRateLimit(ip);
  if (!rl.ok) return res.status(429).json({ error: 'rate_limited', retry_after_sec: rl.retryAfterSec });
  if (rl.state.count >= 5) return res.status(429).json({ error: 'too_many_attempts' });
  try {
    const { response } = req.body || {};
    if (!response?.id) return res.status(400).json({ error: 'missing response' });
    const cred = passkeys.find(p => p.id === response.id);
    if (!cred) { _registerFailure(rl.state); return res.status(401).json({ error: 'unknown_credential' }); }
    const expectedChallenge = response.response?.clientDataJSON
      ? JSON.parse(Buffer.from(response.response.clientDataJSON, 'base64url').toString()).challenge
      : null;
    if (!expectedChallenge || !_takeChallenge(expectedChallenge)) {
      _registerFailure(rl.state);
      return res.status(400).json({ error: 'invalid_or_expired_challenge' });
    }
    const { rpID, origin } = _passkeyRpInfo(req);
    const verification = await _swaLib().verifyAuthenticationResponse({
      response,
      expectedChallenge,
      expectedOrigin: origin,
      expectedRPID:   rpID,
      credential: {
        id:        cred.id,
        publicKey: Buffer.from(cred.publicKey, 'base64url'),
        counter:   cred.counter || 0,
        transports: cred.transports,
      },
    });
    if (!verification.verified) {
      _registerFailure(rl.state);
      return res.status(401).json({ error: 'verification_failed' });
    }
    // Atualiza counter (anti-replay) + last_used
    cred.counter      = verification.authenticationInfo?.newCounter ?? cred.counter;
    cred.last_used_ms = Date.now();
    savePasskeys();
    _registerSuccess(ip);
    console.log(`[auth] login passkey OK · ${cred.device_name}`);
    res.json({ ok: true, token: BRIDGE_TOKEN_HASH });
  } catch (e) {
    console.error('passkey login/finish:', e);
    res.status(500).json({ error: e.message });
  }
});

// GET /api/auth/passkey/available — público, conta passkeys cadastradas
// (PWA usa pra decidir se mostra o botão "Entrar com biometria")
app.get('/api/auth/passkey/available', (_req, res) => {
  res.json({ count: passkeys.length, available: passkeys.length > 0 });
});

app.get('/api/state',  (_req, res) => res.json(state));
app.get('/api/counts', (_req, res) => res.json({
  trips:     0,                  // Trip A/B descontinuados
  autotrips: autoTripsArr.length,
  charges:   chargesArr.length,
}));
// /api/trips removido — Trip A/B descontinuados. Retorna 410 (Gone).
app.get('/api/trips', (_req, res) => res.status(410).json({ error: 'Trip A/B descontinuados' }));
app.delete('/api/trips/:tripId', (_req, res) => res.status(410).json({ error: 'Trip A/B descontinuados' }));
// Aplica edições manuais (manual_overrides) sobre os valores base do Android.
// Recalcula avg_power_kw quando energy_kwh ou duration_sec foram editados.
// Retorna um objeto novo (não muta o original em chargesArr).
function applyChargeOverrides(c) {
  if (!c || !c.manual_overrides || Object.keys(c.manual_overrides).length === 0) return c;
  const eff = { ...c, ...c.manual_overrides };
  // Recalcula potência média se energia ou duração foram editados
  const energy = +eff.energy_kwh;
  const dur    = +eff.duration_sec;
  if (energy > 0 && dur > 0) eff.avg_power_kw = (energy * 3600) / dur;
  // Sinaliza pra PWA quais campos vieram de edição
  eff._overridden_fields = Object.keys(c.manual_overrides);
  return eff;
}

app.get('/api/charges', (req, res) => {
  const since = parseInt(req.query.since || '0', 10);
  // Retorna entradas novas (timestamp_ms > since) OU atualizadas (_updated_ms > since)
  const filtered = since > 0
    ? chargesArr.filter(c => (c.timestamp_ms || 0) > since || (c._updated_ms || 0) > since)
    : chargesArr;
  // Tombstones: PWA precisa saber quais IDs foram deletados pra remover do
  // cache local (sem isso, merge incremental mantinha entries fantasma após
  // delete/merge). Mandados via header pra preservar shape do body (array).
  if (Array.isArray(deletedIds.charges) && deletedIds.charges.length) {
    res.setHeader('X-Tombstones', deletedIds.charges.join(','));
    res.setHeader('Access-Control-Expose-Headers', 'X-Tombstones');
  }
  res.json(filtered.map(applyChargeOverrides));
});

app.delete('/api/charges/:ts', (req, res) => {
  const ts  = parseInt(req.params.ts, 10);
  const idx = chargesArr.findIndex(c => (c.timestamp_ms || 0) === ts);
  if (idx < 0) return res.status(404).json({ error: 'not found' });
  chargesArr.splice(idx, 1);
  scheduleChargesFlush();
  markDeleted('charges', ts);
  recomputeBatteryAvgPrice();
  console.log(`[delete] Charge ${ts} removida (tombstone gravado)`);
  res.json({ ok: true });
});

// ── Linha do tempo de recarga (amostras de potência/energia) ─────────────────
const CHARGE_TELEMETRY_DIR = path.join(__dirname, 'charge_telemetry');
try { require('fs').mkdirSync(CHARGE_TELEMETRY_DIR, { recursive: true }); } catch (_) {}

app.post('/api/charges/:ts/samples', (req, res) => {
  const ts = parseInt(req.params.ts, 10);
  if (!ts) return res.status(400).json({ error: 'ts inválido' });
  const { samples, avgTempC } = req.body || {};
  if (!Array.isArray(samples)) return res.status(400).json({ error: 'samples deve ser array' });
  try {
    fs.writeFileSync(path.join(CHARGE_TELEMETRY_DIR, `${ts}.json`), JSON.stringify(samples));
    // Se Android enviou avgTempC junto, atualiza a recarga (preferência sobre cálculo bridge-side)
    if (typeof avgTempC === 'number' && !isNaN(avgTempC)) {
      const charge = chargesArr.find(c => (c.timestamp_ms || 0) === ts);
      if (charge) { charge.avg_temp_c = avgTempC; scheduleChargesFlush(); }
    }
    console.log(`✓ Amostras de recarga salvas: ts=${ts} (${samples.length} pontos)`);
    res.json({ ok: true, count: samples.length });
  } catch (e) {
    console.error('Erro ao salvar amostras de recarga:', e.message);
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/charges/:ts/samples', (req, res) => {
  const ts   = parseInt(req.params.ts, 10);
  const file = path.join(CHARGE_TELEMETRY_DIR, `${ts}.json`);
  try {
    res.json(fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : []);
  } catch (_) { res.json([]); }
});

// ── Unir recargas ─────────────────────────────────────────────────────────────
// POST /api/charges/merge  { tsA, tsB }
// Funde duas sessões de recarga em uma só.
// - timestamp_ms da sessão mais antiga é preservado (ID da sessão unificada)
// - duration_sec e energy_kwh são somados
// - soc_start = sessão mais antiga; soc_end = sessão mais nova
// - location, charger_kwh, cost_override, avg_temp_c: preservados do que existir
// - amostras de linha do tempo: concatenadas (late offset por duration da early)
app.post('/api/charges/merge', (req, res) => {
  try {
    const { tsA, tsB } = req.body;
    const numA = parseInt(tsA, 10), numB = parseInt(tsB, 10);
    if (!numA || !numB || numA === numB) return res.status(400).json({ error: 'tsA e tsB devem ser diferentes e válidos' });

    const idxA = chargesArr.findIndex(c => (c.timestamp_ms || 0) === numA);
    const idxB = chargesArr.findIndex(c => (c.timestamp_ms || 0) === numB);
    if (idxA < 0) return res.status(404).json({ error: `recarga não encontrada: ${numA}` });
    if (idxB < 0) return res.status(404).json({ error: `recarga não encontrada: ${numB}` });

    const cA = chargesArr[idxA], cB = chargesArr[idxB];
    // Ordem cronológica
    const [early, late] = cA.timestamp_ms <= cB.timestamp_ms ? [cA, cB] : [cB, cA];

    // Campos numéricos — soma
    const mergedDurationSec = (early.duration_sec || 0) + (late.duration_sec  || 0);
    const mergedEnergyKwh   = parseFloat(((early.energy_kwh  || 0) + (late.energy_kwh  || 0)).toFixed(4));
    const mergedAvgPowerKw  = mergedDurationSec > 0
      ? parseFloat((mergedEnergyKwh / (mergedDurationSec / 3600)).toFixed(4)) : 0;

    // charger_kwh: soma se ambas têm; caso contrário usa o que existir
    let mergedChargerKwh = null;
    if (early.charger_kwh > 0 && late.charger_kwh > 0) {
      mergedChargerKwh = parseFloat(((early.charger_kwh || 0) + (late.charger_kwh || 0)).toFixed(4));
    } else if (early.charger_kwh > 0) {
      mergedChargerKwh = early.charger_kwh;
    } else if (late.charger_kwh > 0) {
      mergedChargerKwh = late.charger_kwh;
    }

    // cost_override: soma totais se ambas têm preço; se ambas grátis, mantém grátis;
    // se uma grátis e outra paga, conta só o pago.
    let mergedCostOverride = null;
    const eFree = early.cost_override?.free === true;
    const lFree = late.cost_override?.free  === true;
    if (eFree && lFree) {
      mergedCostOverride = { total: 0, perKwh: 0, free: true };
    } else if (eFree || lFree) {
      // Só uma é grátis — pega o total da paga
      const paid = eFree ? late.cost_override : early.cost_override;
      if (paid?.total > 0) {
        const perKwh = mergedEnergyKwh > 0 ? parseFloat((paid.total / mergedEnergyKwh).toFixed(4)) : 0;
        mergedCostOverride = { total: paid.total, perKwh };
      } else {
        mergedCostOverride = { total: 0, perKwh: 0, free: true };
      }
    } else if (early.cost_override?.total > 0 && late.cost_override?.total > 0) {
      const total     = parseFloat((early.cost_override.total + late.cost_override.total).toFixed(2));
      const perKwh    = mergedEnergyKwh > 0 ? parseFloat((total / mergedEnergyKwh).toFixed(4)) : 0;
      mergedCostOverride = { total, perKwh };
    } else {
      mergedCostOverride = early.cost_override || late.cost_override || null;
    }

    // avg_temp_c: média ponderada pela duração se ambas têm; caso contrário usa o que existir
    let mergedAvgTemp = null;
    if (early.avg_temp_c != null && late.avg_temp_c != null) {
      const totalSec = mergedDurationSec || 1;
      mergedAvgTemp  = parseFloat(
        ((early.avg_temp_c * (early.duration_sec || 0) + late.avg_temp_c * (late.duration_sec || 0)) / totalSec)
        .toFixed(1)
      );
    } else if (early.avg_temp_c != null) { mergedAvgTemp = early.avg_temp_c; }
    else if (late.avg_temp_c != null)    { mergedAvgTemp = late.avg_temp_c;  }

    // Location: prefere a mais antiga; fallback para a mais nova
    const locName  = early.location_name || late.location_name  || null;
    const locLat   = early.location_lat  != null ? early.location_lat  : (late.location_lat  || null);
    const locLng   = early.location_lng  != null ? early.location_lng  : (late.location_lng  || null);

    // Objeto final da recarga unificada
    const merged = {
      ...early,
      duration_sec: mergedDurationSec,
      energy_kwh:   mergedEnergyKwh,
      avg_power_kw: mergedAvgPowerKw,
      soc_start:    early.soc_start,
      soc_end:      late.soc_end,
      _updated_ms:  Date.now(),
      // Marca de quais ts originais a recarga foi consolidada — o handler
      // de charging/history (retained do APK) usa pra NÃO sobrescrever os
      // campos somados quando o APK reenvia o estado original da early.
      merged_from:  [...(early.merged_from || []), late.timestamp_ms],
    };
    if (locName != null)           merged.location_name  = locName;
    if (locLat  != null)           merged.location_lat   = locLat;
    if (locLng  != null)           merged.location_lng   = locLng;
    if (mergedChargerKwh != null)  merged.charger_kwh    = mergedChargerKwh;
    else                           delete merged.charger_kwh;
    if (mergedCostOverride != null) merged.cost_override = mergedCostOverride;
    else                            delete merged.cost_override;
    if (mergedAvgTemp != null)     merged.avg_temp_c     = mergedAvgTemp;
    else                           delete merged.avg_temp_c;

    // Amostras da linha do tempo: early + late com offset de t para continuar após a early
    const earlyFile = path.join(CHARGE_TELEMETRY_DIR, `${early.timestamp_ms}.json`);
    const lateFile  = path.join(CHARGE_TELEMETRY_DIR, `${late.timestamp_ms}.json`);
    let earlySamples = [], lateSamples = [];
    try { if (fs.existsSync(earlyFile)) earlySamples = JSON.parse(fs.readFileSync(earlyFile, 'utf8')); } catch (_) {}
    try { if (fs.existsSync(lateFile))  lateSamples  = JSON.parse(fs.readFileSync(lateFile,  'utf8')); } catch (_) {}
    if (earlySamples.length || lateSamples.length) {
      const offset   = early.duration_sec || 0;
      const lateOff  = lateSamples.map(s => ({ ...s, t: (s.t || 0) + offset }));
      const combined = [...earlySamples, ...lateOff];
      try { fs.writeFileSync(earlyFile, JSON.stringify(combined)); } catch (_) {}
      try { if (fs.existsSync(lateFile)) fs.unlinkSync(lateFile); } catch (_) {}
    }

    // Actualiza chargesArr: remove late, substitui early pelo merged
    chargesArr = chargesArr.filter(c => (c.timestamp_ms || 0) !== late.timestamp_ms);
    const earlyIdx = chargesArr.findIndex(c => (c.timestamp_ms || 0) === early.timestamp_ms);
    if (earlyIdx >= 0) chargesArr[earlyIdx] = merged;
    else chargesArr.unshift(merged);

    // Tombstone da `late` — sem isso, próximo charging/history retained do APK
    // re-adiciona a recarga (PWA "perde" a unificação ao dar refresh).
    markDeleted('charges', late.timestamp_ms);
    // Mix da bateria muda quando recargas fundem (cost_override pode mudar)
    recomputeBatteryAvgPrice();
    scheduleChargesFlush();
    console.log(`[merge-charges] ${early.timestamp_ms} + ${late.timestamp_ms} → ${early.timestamp_ms} (${mergedEnergyKwh} kWh, ${mergedDurationSec}s)`);
    res.json({ ok: true, merged });
  } catch (e) {
    console.error('[merge-charges]', e);
    res.status(500).json({ error: String(e.message) });
  }
});

// ── Locais de recarga ─────────────────────────────────────────────────────────
app.get('/api/charge-locations', (_req, res) => res.json(chargeLocations));

app.post('/api/charge-locations', (req, res) => {
  const { name, lat, lng } = req.body || {};
  if (!name?.trim()) return res.status(400).json({ error: 'nome obrigatório' });
  // Evita duplicatas: mesmo nome ou GPS a < 100 m
  const dup = chargeLocations.find(l =>
    l.name === name.trim() ||
    (l.lat && l.lng && lat && lng && haversineM(l.lat, l.lng, lat, lng) < 100)
  );
  if (dup) return res.json(dup);
  const loc = { id: Date.now(), name: name.trim(), lat: lat ?? null, lng: lng ?? null };
  chargeLocations.push(loc);
  saveChargeLocations();
  res.json(loc);
});

app.delete('/api/charge-locations/:id', (req, res) => {
  const id = parseInt(req.params.id);
  const idx = chargeLocations.findIndex(l => l.id === id);
  if (idx === -1) return res.status(404).json({ error: 'não encontrado' });
  chargeLocations.splice(idx, 1);
  saveChargeLocations();
  res.json({ ok: true });
});

// ── API Locais Conhecidos ─────────────────────────────────────────────────────
app.get('/api/known-places', (_req, res) => res.json(knownPlaces));

app.post('/api/known-places', (req, res) => {
  const { name, lat, lng, radius_m } = req.body || {};
  if (!name?.trim() || lat == null || lng == null)
    return res.status(400).json({ error: 'name, lat, lng obrigatórios' });
  // Rejeita nome duplicado (case-insensitive) para evitar entradas repetidas
  const dup = knownPlaces.find(p => p.name.trim().toLowerCase() === name.trim().toLowerCase());
  if (dup) return res.status(409).json({ error: 'duplicate', existing: dup });
  const r = Math.max(50, Math.min(2000, parseInt(radius_m) || 200));
  const place = { id: Date.now(), name: name.trim(), lat, lng, radius_m: r };
  knownPlaces.push(place);
  saveKnownPlaces();
  res.json(place);
});

app.put('/api/known-places/:id', (req, res) => {
  const id = parseInt(req.params.id, 10);
  const place = knownPlaces.find(p => p.id === id);
  if (!place) return res.status(404).json({ error: 'not found' });
  const { name, lat, lng, radius_m } = req.body || {};
  if (name?.trim()) place.name = name.trim();
  if (lat != null) place.lat = lat;
  if (lng != null) place.lng = lng;
  if (radius_m != null) place.radius_m = Math.max(50, Math.min(2000, parseInt(radius_m)));
  saveKnownPlaces();
  res.json(place);
});

app.delete('/api/known-places/:id', (req, res) => {
  const id = parseInt(req.params.id, 10);
  const idx = knownPlaces.findIndex(p => p.id === id);
  if (idx < 0) return res.status(404).json({ error: 'not found' });
  knownPlaces.splice(idx, 1);
  saveKnownPlaces();
  res.json({ ok: true });
});

// ── Manutenções ──────────────────────────────────────────────────────────────
app.get('/api/maintenance', (_req, res) => {
  res.json({
    intervals: maintenance.intervals,
    history:   [...maintenance.history].sort((a, b) => (b.odometer_km || 0) - (a.odometer_km || 0)),
    next:      computeMaintenance(),
    current_odometer_km: +state.odometer_km || 0,
    daily_km_avg: parseFloat(avgDailyKm(30).toFixed(1)),
  });
});

// POST /api/maintenance/intervals  — cria ou atualiza um intervalo
app.post('/api/maintenance/intervals', (req, res) => {
  const { id, label, every_km, every_months, icon, alert_km, alert_days } = req.body || {};
  const km   = parseFloat(every_km)   || 0;
  const mths = parseFloat(every_months) || 0;
  if (!id || !label || (!(km > 0) && !(mths > 0)))
    return res.status(400).json({ error: 'id, label e pelo menos every_km ou every_months > 0 obrigatórios' });
  const interval = {
    id: String(id).trim(),
    label: String(label).trim(),
    every_km:     km,
    every_months: mths,
    alert_km:    parseFloat(alert_km)   || 500,
    alert_days:  parseFloat(alert_days) || 15,
    icon: icon || '🔧',
  };
  const idx = maintenance.intervals.findIndex(i => i.id === interval.id);
  if (idx >= 0) maintenance.intervals[idx] = interval;
  else maintenance.intervals.push(interval);
  saveMaintenance();
  res.json({ ok: true, interval });
});

app.delete('/api/maintenance/intervals/:id', (req, res) => {
  const idx = maintenance.intervals.findIndex(i => i.id === req.params.id);
  if (idx < 0) return res.status(404).json({ error: 'não encontrado' });
  maintenance.intervals.splice(idx, 1);
  saveMaintenance();
  res.json({ ok: true });
});

// POST /api/maintenance/history — registra manutenção feita
app.post('/api/maintenance/history', (req, res) => {
  const { type_id, odometer_km, date_ms, notes, cost } = req.body || {};
  if (!type_id) return res.status(400).json({ error: 'type_id obrigatório' });
  if (!maintenance.intervals.find(i => i.id === type_id))
    return res.status(400).json({ error: 'type_id inválido' });
  const odo = parseFloat(odometer_km);
  if (!(odo > 0)) return res.status(400).json({ error: 'odometer_km > 0 obrigatório' });
  const rec = {
    id: 'h-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8),
    type_id: String(type_id),
    odometer_km: odo,
    date_ms: parseInt(date_ms) || Date.now(),
    notes: notes ? String(notes).slice(0, 240) : '',
  };
  // Custo opcional — entra no cálculo de R$/km nas estatísticas de Desloc.
  // Lançamentos antigos sem custo continuam válidos (não contam pro TCO).
  const c = parseFloat(cost);
  if (!isNaN(c) && c > 0) rec.cost = parseFloat(c.toFixed(2));
  maintenance.history.push(rec);
  // Reseta o alerta do tipo — novo ciclo começa
  if (maintenance._alerts) delete maintenance._alerts[rec.type_id];
  saveMaintenance();
  res.json({ ok: true, record: rec });
});

app.delete('/api/maintenance/history/:id', (req, res) => {
  const idx = maintenance.history.findIndex(h => h.id === req.params.id);
  if (idx < 0) return res.status(404).json({ error: 'não encontrado' });
  maintenance.history.splice(idx, 1);
  // Reseta alertas pros tipos afetados — recompute pode mover o "último"
  if (maintenance._alerts) maintenance._alerts = {};
  saveMaintenance();
  res.json({ ok: true });
});

// PATCH /api/maintenance/history/:id — edita registro existente
// (próximas manutenções recalculam automaticamente em computeMaintenance)
app.patch('/api/maintenance/history/:id', (req, res) => {
  const rec = maintenance.history.find(h => h.id === req.params.id);
  if (!rec) return res.status(404).json({ error: 'não encontrado' });
  const b = req.body || {};
  if (b.odometer_km !== undefined) {
    const o = parseFloat(b.odometer_km);
    if (!(o > 0)) return res.status(400).json({ error: 'odometer_km > 0 obrigatório' });
    rec.odometer_km = o;
  }
  if (b.date_ms !== undefined) {
    const d = parseInt(b.date_ms);
    if (!(d > 0)) return res.status(400).json({ error: 'date_ms inválido' });
    rec.date_ms = d;
  }
  if (b.type_id !== undefined) {
    if (!maintenance.intervals.find(i => i.id === b.type_id))
      return res.status(400).json({ error: 'type_id inválido' });
    rec.type_id = String(b.type_id);
  }
  if (b.notes !== undefined) rec.notes = String(b.notes).slice(0, 240);
  // Reseta alertas pros tipos afetados — registro mudou, ciclo novo
  if (maintenance._alerts) maintenance._alerts = {};
  saveMaintenance();
  res.json({ ok: true, record: rec, next: computeMaintenance() });
});

// ── Abastecimentos ──────────────────────────────────────────────────────────
app.get('/api/refuels', (req, res) => {
  const since = parseInt(req.query.since || '0', 10);
  const all = [...refuels].sort((a, b) => (b.timestamp_ms || 0) - (a.timestamp_ms || 0));
  // Suporta fetch incremental: ?since=ts retorna só registros novos/editados após o ts
  const filtered = since > 0
    ? all.filter(r => (r.timestamp_ms || 0) > since || (r._updated_ms || 0) > since)
    : all;
  if (Array.isArray(deletedIds.refuels) && deletedIds.refuels.length) {
    res.setHeader('X-Tombstones', deletedIds.refuels.join(','));
    res.setHeader('Access-Control-Expose-Headers', 'X-Tombstones');
  }
  res.json({
    refuels: filtered,
    tank_avg_price_per_l: state.tank_avg_price_per_l || 0,
    fuel_l_current: +state.fuel_l || 0,
    tank_capacity_l: TANK_CAPACITY_L,
  });
});

// POST /api/refuels — registro manual (ou completar pendente via PATCH)
app.post('/api/refuels', (req, res) => {
  const b = req.body || {};
  const liters = parseFloat(b.liters_added);
  if (!(liters > 0)) return res.status(400).json({ error: 'liters_added obrigatório' });
  const pricePerL = parseFloat(b.price_per_liter) || 0;
  const total     = parseFloat(b.total_cost) || (pricePerL * liters);
  const finalPrice = pricePerL > 0 ? pricePerL : (total > 0 ? total / liters : 0);
  const rec = {
    id: 'r-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8),
    timestamp_ms: parseInt(b.timestamp_ms) || Date.now(),
    fuel_l_before: parseFloat(b.fuel_l_before) || 0,
    fuel_l_after:  parseFloat(b.fuel_l_after)  || 0,
    liters_added: liters,
    price_per_liter: finalPrice,
    total_cost: finalPrice * liters,
    odometer_km: parseFloat(b.odometer_km) || (+state.odometer_km || 0),
    location_name: b.location_name || '',
    notes: b.notes ? String(b.notes).slice(0, 240) : '',
    pending: !(finalPrice > 0),
  };
  refuels.push(rec);
  recomputeTankAvgPrice();
  broadcast('new_refuel', rec);
  res.json({ ok: true, refuel: rec, tank_avg_price_per_l: state.tank_avg_price_per_l });
});

// PATCH /api/refuels/:id — atualiza campos (preço, posto, notas)
app.patch('/api/refuels/:id', (req, res) => {
  const r = refuels.find(x => x.id === req.params.id);
  if (!r) return res.status(404).json({ error: 'não encontrado' });
  const b = req.body || {};
  if (b.price_per_liter !== undefined) {
    const p = parseFloat(b.price_per_liter);
    if (!(p > 0)) return res.status(400).json({ error: 'price_per_liter inválido' });
    r.price_per_liter = p;
    r.total_cost = p * (+r.liters_added || 0);
    r.pending = false;
  } else if (b.total_cost !== undefined) {
    const t = parseFloat(b.total_cost);
    if (!(t > 0)) return res.status(400).json({ error: 'total_cost inválido' });
    r.total_cost = t;
    r.price_per_liter = (+r.liters_added || 0) > 0 ? t / r.liters_added : 0;
    r.pending = false;
  }
  if (b.liters_added !== undefined) r.liters_added = parseFloat(b.liters_added) || r.liters_added;
  if (b.location_name !== undefined) r.location_name = String(b.location_name).slice(0, 80);
  if (b.notes !== undefined)         r.notes = String(b.notes).slice(0, 240);
  if (b.timestamp_ms !== undefined)  r.timestamp_ms = parseInt(b.timestamp_ms) || r.timestamp_ms;
  if (b.odometer_km !== undefined)   r.odometer_km = parseFloat(b.odometer_km) || r.odometer_km;
  // Recoeficiente total se price ou liters mudaram
  if (r.price_per_liter > 0 && r.liters_added > 0) r.total_cost = r.price_per_liter * r.liters_added;
  recomputeTankAvgPrice();
  res.json({ ok: true, refuel: r, tank_avg_price_per_l: state.tank_avg_price_per_l });
});

app.delete('/api/refuels/:id', (req, res) => {
  const idx = refuels.findIndex(x => x.id === req.params.id);
  if (idx < 0) return res.status(404).json({ error: 'não encontrado' });
  refuels.splice(idx, 1);
  recomputeTankAvgPrice();
  res.json({ ok: true, tank_avg_price_per_l: state.tank_avg_price_per_l });
});

// PATCH /api/charges/:ts/location
// Body: { name?, lat?, lng?, save_known? }
// - Se name === '' → limpa localização
// - Se só lat+lng → tenta auto-match em locais conhecidos
// - Se name + (lat+lng) + save_known → salva como local favorito também
app.patch('/api/charges/:ts/location', (req, res) => {
  const ts = parseInt(req.params.ts);
  const charge = chargesArr.find(c => (c.timestamp_ms || 0) === ts);
  if (!charge) return res.status(404).json({ error: 'recarga não encontrada' });

  const { name, lat, lng, save_known } = req.body || {};

  if (name === '') {
    // Limpar localização
    delete charge.location_name;
    delete charge.location_lat;
    delete charge.location_lng;
    charge._updated_ms = Date.now();
    scheduleChargesFlush();
    return res.json(charge);
  }

  if (!name && (lat != null || lng != null)) {
    // Auto-tag por GPS (chamado pela PWA quando recarga termina)
    if (lat != null) charge.location_lat = lat;
    if (lng != null) charge.location_lng = lng;
    const match = autoMatchLocation(lat, lng);
    if (match) charge.location_name = match.name;
    charge._updated_ms = Date.now();
    scheduleChargesFlush();
    return res.json(charge);
  }

  if (name?.trim()) charge.location_name = name.trim();
  if (lat != null)  charge.location_lat  = lat;
  if (lng != null)  charge.location_lng  = lng;

  if (save_known && name?.trim() && lat != null && lng != null) {
    // Salva no sistema unificado knownPlaces (radius_m padrão 200m)
    const dup = knownPlaces.find(p =>
      p.name.trim().toLowerCase() === name.trim().toLowerCase() ||
      (p.lat && p.lng && haversineM(p.lat, p.lng, lat, lng) < 50)
    );
    if (!dup) {
      knownPlaces.push({ id: Date.now(), name: name.trim(), lat, lng, radius_m: 200 });
      saveKnownPlaces();
    }
  }

  charge._updated_ms = Date.now();
  scheduleChargesFlush();
  res.json(charge);
});

// PATCH /api/charges/:ts/charger_kwh — kWh marcado no carregador externo
app.patch('/api/charges/:ts/charger_kwh', (req, res) => {
  const ts     = parseInt(req.params.ts, 10);
  // Aceita ambas as chaves: PWA antigo cacheado mandava `kwh`; PWA novo manda
  // `charger_kwh`. Sem isso, body com `kwh` era lido como undefined e o campo
  // era SILENCIOSAMENTE deletado — valor sumia após o próximo refetch/restart.
  const body = req.body || {};
  const raw = body.charger_kwh != null ? body.charger_kwh : body.kwh;
  const charge = chargesArr.find(c => (c.timestamp_ms || 0) === ts);
  if (!charge) return res.status(404).json({ error: 'not found' });
  const val = parseFloat(raw) || 0;
  if (val > 0) charge.charger_kwh = val; else delete charge.charger_kwh;
  charge._updated_ms = Date.now();
  scheduleChargesFlush();
  res.json(charge);
});

// PATCH /api/charges/:ts/cost — override de custo de recarga
app.patch('/api/charges/:ts/cost', (req, res) => {
  const ts     = parseInt(req.params.ts, 10);
  const { total, per_kwh, free } = req.body || {};
  const charge = chargesArr.find(c => (c.timestamp_ms || 0) === ts);
  if (!charge) return res.status(404).json({ error: 'not found' });
  const t = parseFloat(total) || 0;
  if (free === true)  charge.cost_override = { total: 0, perKwh: 0, free: true };
  else if (t > 0)     charge.cost_override = { total: t, perKwh: parseFloat(per_kwh) || 0 };
  else                delete charge.cost_override;
  charge._updated_ms = Date.now();
  scheduleChargesFlush();
  recomputeBatteryAvgPrice();   // recalcula mix da bateria após override
  res.json(charge);
});

// PATCH /api/charges/:ts/edit — edita SOC início/fim, energia injetada e duração.
// Sobrescreve dados do Android pra corrigir leituras incorretas do carro (falhas
// de comunicação). Armazenado em `manual_overrides`; o merge MQTT preserva o
// objeto, então re-publicações do Android NÃO sobrescrevem a edição.
// Body: { soc_start?, soc_end?, energy_kwh?, duration_sec? } — campos ausentes
// ou null limpam aquele override individual. Para limpar TUDO: { clear: true }.
app.patch('/api/charges/:ts/edit', (req, res) => {
  const ts     = parseInt(req.params.ts, 10);
  const charge = chargesArr.find(c => (c.timestamp_ms || 0) === ts);
  if (!charge) return res.status(404).json({ error: 'not found' });
  const body = req.body || {};

  if (body.clear === true) {
    delete charge.manual_overrides;
    charge._updated_ms = Date.now();
    scheduleChargesFlush();
    return res.json(applyChargeOverrides(charge));
  }

  const ov = { ...(charge.manual_overrides || {}) };
  const setOrClear = (field, raw, parser, validate) => {
    if (!(field in body)) return;             // não enviado → mantém como está
    if (raw === null || raw === '') { delete ov[field]; return; }  // explícito clear
    const v = parser(raw);
    if (!Number.isFinite(v) || !validate(v)) return;  // inválido → ignora
    ov[field] = v;
  };
  setOrClear('soc_start',    body.soc_start,    parseFloat, v => v >= 0 && v <= 100);
  setOrClear('soc_end',      body.soc_end,      parseFloat, v => v >= 0 && v <= 100);
  setOrClear('energy_kwh',   body.energy_kwh,   parseFloat, v => v >= 0 && v < 1000);
  setOrClear('duration_sec', body.duration_sec, x => parseInt(x, 10), v => v >= 0 && v < 86400 * 7);

  if (Object.keys(ov).length > 0) charge.manual_overrides = ov;
  else                            delete charge.manual_overrides;
  charge._updated_ms = Date.now();
  scheduleChargesFlush();
  // energy_kwh editado muda o mix da bateria
  recomputeBatteryAvgPrice();
  res.json(applyChargeOverrides(charge));
});

// ── Proxy de tiles OSM para o canvas do Snapshot ──────────────────────────────
// Evita CORS: o canvas carrega via apiFetch (com auth) e recebe PNG do OSM
app.get('/api/tiles/:z/:x/:y', (req, res) => {
  const z = parseInt(req.params.z, 10);
  const x = parseInt(req.params.x, 10);
  const y = parseInt(req.params.y, 10);
  if (isNaN(z) || isNaN(x) || isNaN(y) || z < 0 || z > 19) return res.status(400).end();
  const opts = {
    hostname: 'tile.openstreetmap.org',
    path:     `/${z}/${x}/${y}.png`,
    method:   'GET',
    timeout:  8000,
    headers: {
      'User-Agent': 'EcotripBridge/1.0 (https://github.com/rafaelcs28/haval-ecotrip)',
      'Accept':     'image/png',
    },
  };
  const proxyReq = https.get(opts, proxyRes => {
    res.setHeader('Content-Type',  'image/png');
    res.setHeader('Cache-Control', 'public, max-age=86400');
    res.status(proxyRes.statusCode || 200);
    proxyRes.pipe(res);
  });
  proxyReq.on('timeout', () => { proxyReq.destroy(); res.status(504).end(); });
  proxyReq.on('error',   () => res.status(502).end());
});

// ── Admin: restart remoto ─────────────────────────────────────────────────────
// GET /api/ntfy/config — retorna topic + server pra PWA exibir QR/link de subscribe
app.get('/api/ntfy/config', (_req, res) => {
  res.json({
    enabled: !!NTFY_TOPIC,
    topic:   NTFY_TOPIC || null,
    server:  NTFY_URL,
    subscribe_url: NTFY_TOPIC ? `${NTFY_URL}/${encodeURIComponent(NTFY_TOPIC)}` : null,
  });
});

// POST /api/admin/test-charging — simula uma recarga em andamento por N segundos.
// Útil pra testar Live Activity, notificações ao vivo e UX da Dash sem o
// carro estar realmente plugado. Body: { duration_sec?: 60, soc?: 50, power_kw?: 7.2 }
let _testChargingTimer = null;
let _testChargingSnapshot = null;
app.post('/api/admin/test-charging', (req, res) => {
  const { duration_sec, soc, power_kw, remaining_min } = req.body || {};
  const dur  = Math.max(15, Math.min(600, parseInt(duration_sec) || 60));
  const _soc = Math.max(0, Math.min(100, parseFloat(soc) || 50));
  const _pwr = Math.max(0, parseFloat(power_kw) || 7.2);
  const _rem = Math.max(0, parseInt(remaining_min) || 120);

  // Salva snapshot do estado atual (se ainda não houver) pra restaurar depois
  if (!_testChargingSnapshot) {
    _testChargingSnapshot = {
      charging_state:        state.charging_state,
      soc_pct:               state.soc_pct,
      charge_power_kw:       state.charge_power_kw,
      charge_session_kwh:    state.charge_session_kwh,
      charge_remaining_min:  state.charge_remaining_min,
      charge_start_soc_pct:  state.charge_start_soc_pct,
    };
  }
  // Mock state
  state.charging_state       = 'Carregando';
  state.soc_pct              = _soc;
  state.charge_power_kw      = _pwr;
  state.charge_session_kwh   = 1.2;
  state.charge_remaining_min = _rem;
  state.charge_start_soc_pct = _soc - 5;
  broadcast('update', state);

  // Injeta notif no histórico (app nativo iOS vai pegar via polling em ~30s)
  sendPush('⚡ Recarga iniciada (teste)',
           `${_pwr.toFixed(1)} kW · ~${_rem} min · SOC ${_soc.toFixed(0)}%`,
           'charge_start');

  // Restaura estado depois de `dur` segundos
  if (_testChargingTimer) clearTimeout(_testChargingTimer);
  _testChargingTimer = setTimeout(() => {
    if (_testChargingSnapshot) {
      Object.assign(state, _testChargingSnapshot);
      _testChargingSnapshot = null;
      broadcast('update', state);
      sendPush('✅ Recarga concluída (teste)',
               `SOC ${_soc.toFixed(0)}% · sessão encerrada`,
               'charge_end');
    }
    _testChargingTimer = null;
  }, dur * 1000);

  res.json({ ok: true, duration_sec: dur, ends_at: new Date(Date.now() + dur * 1000).toISOString() });
});

// POST /api/admin/restart  body: { "token": "..." }
// Admin usa ADMIN_TOKEN se definido, senão cai para BRIDGE_TOKEN
// Aceita token via Authorization header (PWA novo) ou body.token (retrocompat)
function adminCheckToken(req, res) {
  const adminToken = process.env.ADMIN_TOKEN ? sha256hex(process.env.ADMIN_TOKEN) : BRIDGE_TOKEN_HASH;
  if (!adminToken) { res.status(503).json({ error: 'ADMIN_TOKEN not configured' }); return false; }
  const auth  = req.headers['authorization'] || '';
  const token = (auth.startsWith('Bearer ') ? auth.slice(7).trim() : '')
             || req.body?.token || req.query.token || '';
  const adminValid = token === adminToken || sha256hex(token) === adminToken;
  if (!adminValid) { res.status(401).json({ error: 'unauthorized' }); return false; }
  return true;
}

app.post('/api/admin/restart', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  res.json({ ok: true, msg: 'reiniciando em 500ms...' });
  setTimeout(() => {
    console.log('[admin] Restart solicitado remotamente');
    process.exit(0);
  }, 500);
});

// ── Veículo (chassi GWM) ─────────────────────────────────────────────────────
// GET retorna config ATIVA (a que o bridge subiu com) + a que está salva em
// vehicle.json — podem divergir se o user editou mas não reiniciou.
// Lê o conteúdo inteiro do vehicle.json (chassi + model_name)
function _loadVehicleFile() {
  try {
    if (!fs.existsSync(VEHICLE_FILE)) return {};
    return JSON.parse(fs.readFileSync(VEHICLE_FILE, 'utf8')) || {};
  } catch (_) { return {}; }
}

app.get('/api/vehicle', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  const onDisk = _loadVehicleFile();
  res.json({
    active:        GWM_CHASSI || null,
    active_source: GWM_CHASSI_SOURCE,
    saved_in_file: onDisk.chassi || null,
    env_value:     _chassiFromEnv || null,
    model_name:    onDisk.model_name || 'Haval H6 PHEV',
    needs_restart: !!(onDisk.chassi && onDisk.chassi !== GWM_CHASSI),
  });
});

// POST { chassi?, model_name? } — aceita atualização parcial. Salva o que vier.
app.post('/api/vehicle', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  const body = req.body || {};
  const current = _loadVehicleFile();
  const out = { ...current };
  let needsRestart = false;
  // Chassi (opcional na chamada, mas se vier precisa ser válido)
  if (body.chassi !== undefined) {
    const raw = String(body.chassi).toLowerCase().trim();
    if (!/^lgw[a-z0-9]{14}$/.test(raw)) {
      return res.status(400).json({ error: 'Formato de chassi inválido. Esperado: lgw + 14 alfanuméricos' });
    }
    out.chassi = raw;
    needsRestart = raw !== GWM_CHASSI;
  }
  // Nome do modelo (opcional)
  if (body.model_name !== undefined) {
    const name = String(body.model_name).trim().slice(0, 60);
    if (!name) return res.status(400).json({ error: 'Nome do modelo vazio' });
    out.model_name = name;
  }
  if (Object.keys(out).length === Object.keys(current).length &&
      Object.keys(out).every(k => out[k] === current[k])) {
    return res.json({ ok: true, unchanged: true });
  }
  out.updated_at = Date.now();
  try {
    fs.writeFileSync(VEHICLE_FILE, JSON.stringify(out, null, 2));
    res.json({ ok: true, ...out, needs_restart: needsRestart });
  } catch (e) {
    res.status(500).json({ error: 'Falha ao gravar vehicle.json: ' + e.message });
  }
});

app.post('/api/admin/update', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  const { exec } = require('child_process');
  const repoDir = path.join(__dirname, '..');
  // 1) Diagnóstico rápido: remote + branch atual
  exec('git remote -v && git branch --show-current', { cwd: repoDir }, (e0, s0) => {
    const diagInfo = (s0 || '').trim();
    // 2) fetch + reset --hard evita falhar por mudanças locais ou merge conflicts
    exec('git fetch origin 2>&1 && git reset --hard origin/main 2>&1', { cwd: repoDir, shell: true }, (err, stdout, stderr) => {
      const pullOut = (stdout || '').trim() || (stderr || '').trim() || '(sem saída)';
      if (err) {
        console.error('[admin] update falhou:', err.message);
        return res.json({ ok: false, msg: `Diagnóstico:\n${diagInfo}\n\nErro:\n${pullOut}` });
      }
      console.log('[admin] update OK:', pullOut);
      res.json({ ok: true, msg: pullOut + '\n\nReiniciando servidor...' });
      setTimeout(() => {
        console.log('[admin] Reiniciando após update');
        process.exit(0);
      }, 500);
    });
  });
});

app.post('/api/admin/change-password', (req, res) => {
  // Autenticação já foi verificada pelo middleware requireAuth
  const { newHash } = req.body || {};
  console.log('[change-password] recebido newHash length:', newHash?.length, 'body keys:', Object.keys(req.body || {}));
  if (!newHash || typeof newHash !== 'string' || newHash.length < 4) {
    return res.status(400).json({ error: 'Nova senha muito curta (mínimo 4 caracteres)' });
  }
  // Atualiza o .env: substitui BRIDGE_TOKEN e BRIDGE_TOKEN_HASH pelo novo hash
  const envPath = path.join(__dirname, '.env');
  let envContent = fs.existsSync(envPath) ? fs.readFileSync(envPath, 'utf8') : '';
  envContent = envContent.split('\n')
    .filter(l => !l.startsWith('BRIDGE_TOKEN=') && !l.startsWith('BRIDGE_TOKEN_HASH='))
    .join('\n').trimEnd();
  envContent += '\nBRIDGE_TOKEN_HASH=' + newHash + '\n';
  fs.writeFileSync(envPath, envContent, 'utf8');
  BRIDGE_TOKEN_HASH = newHash;
  console.log('[admin] Senha alterada. Novo BRIDGE_TOKEN_HASH:', newHash.substring(0, 8) + '…');
  res.json({ ok: true, msg: 'Senha alterada com sucesso.' });
});

// ── Backup & Restore completo ─────────────────────────────────────────────────
// GET /api/backup — exporta tudo em um único JSON (trips + autotrips com
// telemetria + charges + lifetime snapshots + prefs de notificação).
// Protegido por requireAuth (middleware global).
app.get('/api/backup', (req, res) => {
  if (!adminCheckToken(req, res)) return;  // exige token (Authorization header OR ?token=)
  try {
    // Lê todos os arquivos de auto-trips com amostras de telemetria completas
    const autotripsWithSamples = [];
    const atFiles = fs.readdirSync(AUTOTRIPS_DIR).filter(f => f.endsWith('.json'));
    for (const f of atFiles) {
      try {
        const d = JSON.parse(fs.readFileSync(path.join(AUTOTRIPS_DIR, f), 'utf8'));
        autotripsWithSamples.push(d);  // { tripId, autoTrip, samples }
      } catch (_) {}
    }
    autotripsWithSamples.sort((a, b) =>
      (b.autoTrip?.startMs || 0) - (a.autoTrip?.startMs || 0));

    // Telemetria de recargas — um arquivo por sessão em charge_telemetry/
    const chargeTelemetry = {};
    try {
      const ctFiles = fs.readdirSync(CHARGE_TELEMETRY_DIR).filter(f => f.endsWith('.json'));
      for (const f of ctFiles) {
        const ts = f.replace('.json', '');
        try {
          chargeTelemetry[ts] = JSON.parse(fs.readFileSync(path.join(CHARGE_TELEMETRY_DIR, f), 'utf8'));
        } catch (_) {}
      }
    } catch (_) {}

    const backup = {
      version:           4,
      exportedAt:        new Date().toISOString(),
      // Histórico (trips manuais A/B descontinuados — campo legado pra compat v2)
      trips:             [],
      autotrips:         autotripsWithSamples,
      charges:           chargesArr,
      chargeTelemetry,                                // novo v4: samples por sessão de recarga
      refuels,                                        // abastecimentos
      lifeSnapshots,
      telemetryHistory,                               // snapshots diários (anomalia)
      // Configurações
      notifPrefs,
      maintenance,                                    // intervalos + histórico + alerts
      knownPlaces,                                    // locais conhecidos
      chargeLocations,                                // locais antigos (compat)
      deletedIds,                                     // tombstones de deleção
      // NÃO inclui: auth.json (TOTP secret), state.json (runtime, recomputado),
      // cert.pem/key.pem (per-server).
    };

    const filename = `ecotrip-backup-${new Date().toISOString().slice(0, 10)}.json`;
    // Pré-serializa pra saber o tamanho exato — expõe via X-Original-Size pro
    // PWA calcular % de progresso (com gzip ativo, Content-Length some).
    const buf = Buffer.from(JSON.stringify(backup), 'utf8');
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.setHeader('X-Original-Size', String(buf.length));
    res.setHeader('Access-Control-Expose-Headers', 'X-Original-Size');
    res.send(buf);
    const mb = (buf.length / 1024 / 1024).toFixed(2);
    console.log(`✓ Backup v4 exportado (${mb} MB): ${backup.autotrips.length} auto-trips · ${backup.charges.length} recargas (${Object.keys(chargeTelemetry).length} com telemetria) · ${backup.refuels.length} abastecimentos · ${backup.maintenance.history.length} manutenções · ${backup.knownPlaces.length} locais`);
  } catch (e) {
    console.error('[backup] Erro:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// POST /api/restore — importa backup gerado por /api/backup e reconstrói
// todos os dados em disco e em memória (sem precisar reiniciar o servidor).
app.post('/api/restore', (req, res) => {
  try {
    const bk = req.body;

    // Validação básica — aceita v2 (legado), v3 e v4 (completo)
    if (!bk || (bk.version !== 2 && bk.version !== 3 && bk.version !== 4)) {
      return res.status(400).json({ error: 'Formato inválido. Use um backup gerado por GET /api/backup (version 2, 3 ou 4).' });
    }
    if (!Array.isArray(bk.trips) || !Array.isArray(bk.autotrips) || !Array.isArray(bk.charges)) {
      return res.status(400).json({ error: 'Backup incompleto: trips, autotrips e charges são obrigatórios.' });
    }

    // 1. Trips manuais
    // Trip A/B descontinuados — backup v2 podia conter trips manuais, mas
    // não são mais restaurados. Ignora bk.trips silenciosamente.

    // 2. Auto-trips (com telemetria completa)
    const existingFiles = fs.readdirSync(AUTOTRIPS_DIR).filter(f => f.endsWith('.json'));
    existingFiles.forEach(f => { try { fs.unlinkSync(path.join(AUTOTRIPS_DIR, f)); } catch (_) {} });
    autoTripsArr.length = 0;

    for (const at of bk.autotrips) {
      const safeId = String(at.tripId || at.autoTrip?.startMs || '').replace(/\D/g, '');
      if (!safeId) continue;
      // Preserva hybridTimeSec/hybridDistKm se vieram no backup, senão recalcula.
      const hybrid = (at.hybridTimeSec != null && at.hybridDistKm != null)
        ? { hybridTimeSec: at.hybridTimeSec, hybridDistKm: at.hybridDistKm }
        : _calcHybrid(at.samples || []);
      fs.writeFileSync(
        path.join(AUTOTRIPS_DIR, `${safeId}.json`),
        JSON.stringify({
          tripId: safeId,
          autoTrip: at.autoTrip || {},
          samples: at.samples || [],
          hybridTimeSec: hybrid.hybridTimeSec,
          hybridDistKm:  hybrid.hybridDistKm,
        })
      );
      if (at.autoTrip) {
        autoTripsArr.push({
          tripId: safeId, ...at.autoTrip, ...hybrid,
        });
      }
    }
    autoTripsArr.sort((a, b) => (b.startMs || 0) - (a.startMs || 0));

    // 3. Recargas
    chargesArr.length = 0;
    chargesArr.push(...bk.charges);
    fs.writeFileSync(CHARGES_FILE, JSON.stringify({ charges: chargesArr }, null, 2));

    // 4. Lifetime snapshots (para Stats da PWA)
    if (Array.isArray(bk.lifeSnapshots)) {
      lifeSnapshots.length = 0;
      lifeSnapshots.push(...bk.lifeSnapshots);
      try { fs.writeFileSync(SNAPSHOTS_FILE, JSON.stringify(lifeSnapshots)); } catch (_) {}
    }

    // 5. Preferências de notificação
    if (bk.notifPrefs && typeof bk.notifPrefs === 'object') {
      Object.assign(notifPrefs, bk.notifPrefs);
      try { fs.writeFileSync(NOTIF_PREFS_FILE, JSON.stringify(notifPrefs, null, 2)); } catch (_) {}
    }

    // 6. Refuels (abastecimentos) — só se backup v3+
    if (Array.isArray(bk.refuels)) {
      refuels.length = 0;
      refuels.push(...bk.refuels);
      saveRefuels();
      recomputeTankAvgPrice();
    }

    // 7. Maintenance (intervalos + histórico)
    if (bk.maintenance && typeof bk.maintenance === 'object') {
      maintenance.intervals = bk.maintenance.intervals || maintenance.intervals;
      maintenance.history   = bk.maintenance.history   || maintenance.history;
      maintenance._alerts   = bk.maintenance._alerts   || {};
      saveMaintenance();
    }

    // 8. Locais conhecidos
    if (Array.isArray(bk.knownPlaces)) {
      knownPlaces.length = 0;
      knownPlaces.push(...bk.knownPlaces);
      saveKnownPlaces();
    }

    // 9. Telemetry history (snapshots diários — alertas de anomalia)
    if (Array.isArray(bk.telemetryHistory)) {
      telemetryHistory.length = 0;
      telemetryHistory.push(...bk.telemetryHistory);
      try { fs.writeFileSync(TELEMETRY_LOG_FILE, JSON.stringify(telemetryHistory, null, 2)); } catch (_) {}
    }

    // 10. Tombstones — preserva memória de o que foi deletado
    if (bk.deletedIds && typeof bk.deletedIds === 'object') {
      deletedIds.autotrips = bk.deletedIds.autotrips || [];
      deletedIds.charges   = bk.deletedIds.charges   || [];
      deletedIds.refuels   = bk.deletedIds.refuels   || [];
      for (const k of ['autotrips', 'charges', 'refuels']) {
        deletedIdsSets[k] = new Set(deletedIds[k].map(String));
      }
      saveDeletedIds();
    }

    // 11. Telemetria de recargas (v4+) — restaura arquivos charge_telemetry/{ts}.json
    let chargeTelemetryRestored = 0;
    if (bk.chargeTelemetry && typeof bk.chargeTelemetry === 'object') {
      // Limpa diretório antes de restaurar
      try {
        fs.readdirSync(CHARGE_TELEMETRY_DIR)
          .filter(f => f.endsWith('.json'))
          .forEach(f => { try { fs.unlinkSync(path.join(CHARGE_TELEMETRY_DIR, f)); } catch (_) {} });
      } catch (_) {}
      for (const [ts, samples] of Object.entries(bk.chargeTelemetry)) {
        try {
          fs.writeFileSync(path.join(CHARGE_TELEMETRY_DIR, `${ts}.json`), JSON.stringify(samples));
          chargeTelemetryRestored++;
        } catch (_) {}
      }
    }

    // Recalcula preço médio da bateria após restore
    recomputeBatteryAvgPrice();

    const summary = {
      autotrips:         autoTripsArr.length,
      charges:           chargesArr.length,
      chargeTelemetry:   chargeTelemetryRestored,
      refuels:           refuels.length,
      lifeSnapshots:     lifeSnapshots.length,
      maintenance:       maintenance.history.length,
      knownPlaces:       knownPlaces.length,
      tombstones:        (deletedIds.autotrips.length + deletedIds.charges.length + deletedIds.refuels.length),
    };
    console.log('✓ Restore completo:', summary);
    res.json({ ok: true, msg: 'Restore concluído com sucesso.', ...summary });
  } catch (e) {
    console.error('[restore] Erro:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// POST /api/admin/sync — sincroniza servidor com lista do cliente.
// O PWA envia keep_autotrips + keep_charges (+ opcional keep_refuels) com
// os IDs que existem no cache local. Tudo no servidor que NÃO está nessas
// listas é deletado e marcado como tombstone (não volta nem por MQTT).
app.post('/api/admin/sync', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  const b = req.body || {};
  const keepA = new Set((b.keep_autotrips || []).map(String));
  const keepC = new Set((b.keep_charges   || []).map(v => parseInt(v, 10)));
  const keepR = b.keep_refuels ? new Set(b.keep_refuels.map(String)) : null;

  // Autotrips
  let remA = 0;
  for (let i = autoTripsArr.length - 1; i >= 0; i--) {
    const t = autoTripsArr[i];
    const id = String(t.tripId || t.startMs || '');
    if (!keepA.has(id)) {
      markDeleted('autotrips', id);
      autoTripsArr.splice(i, 1);
      try { fs.unlinkSync(path.join(AUTOTRIPS_DIR, `${id}.json`)); } catch (_) {}
      remA++;
    }
  }

  // Charges
  let remC = 0;
  for (let i = chargesArr.length - 1; i >= 0; i--) {
    const ts = chargesArr[i].timestamp_ms || 0;
    if (!keepC.has(ts)) {
      markDeleted('charges', ts);
      chargesArr.splice(i, 1);
      remC++;
    }
  }
  if (remC > 0) scheduleChargesFlush();

  // Refuels (opcional — só sincroniza se o cliente enviou keep_refuels)
  let remR = 0;
  if (keepR) {
    for (let i = refuels.length - 1; i >= 0; i--) {
      if (!keepR.has(String(refuels[i].id || ''))) {
        markDeleted('refuels', refuels[i].id);
        refuels.splice(i, 1);
        remR++;
      }
    }
    if (remR > 0) { saveRefuels(); recomputeTankAvgPrice(); }
  }

  console.log(`✓ Sync: removidas ${remA} viagens + ${remC} recargas${keepR ? ` + ${remR} abastecimentos` : ''}`);
  res.json({ ok: true, removed_autotrips: remA, removed_charges: remC, removed_refuels: remR });
});

app.post('/api/admin/clear-history', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  try {
    // 1. Recargas
    chargesArr.length = 0;
    fs.writeFileSync(CHARGES_FILE, JSON.stringify({ charges: [] }, null, 2));

    // 3. Auto-trips — apaga todos os arquivos da pasta
    const files = fs.readdirSync(AUTOTRIPS_DIR).filter(f => f.endsWith('.json'));
    for (const f of files) fs.unlinkSync(path.join(AUTOTRIPS_DIR, f));
    autoTripsArr.length = 0;

    // 4. Grava timestamp do clear — impede que dados MQTT retained anteriores
    //    (re-publicados pelo Android ao reconectar) restaurem o histórico apagado.
    const clearedAt = Date.now();
    state.charges_cleared_at = clearedAt;
    state.trips_cleared_at   = clearedAt;
    fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2));

    console.log('[admin] Histórico apagado (trips, charges, auto-trips)');
    res.json({ ok: true, msg: 'Histórico apagado com sucesso.' });
  } catch (e) {
    console.error('[admin] Erro ao apagar histórico:', e.message);
    res.status(500).json({ error: e.message });
  }
});

// ── Auto-trips + Telemetria ───────────────────────────────────────────────────

app.post('/api/autotrips', (req, res) => {
  try {
    const { tripId, autoTrip, samples } = req.body;
    if (!tripId || !autoTrip) return res.status(400).json({ error: 'missing fields' });

    // Sanitiza tripId (só dígitos — é o startMs em ms)
    const safeId = String(tripId).replace(/\D/g, '');
    if (!safeId) return res.status(400).json({ error: 'invalid tripId' });

    // Bloqueia viagens explicitamente deletadas pelo usuário (tombstone)
    if (isDeleted('autotrips', safeId)) {
      console.log(`↷ AutoTrip ${safeId} bloqueada (tombstoned)`);
      return res.json({ ok: true, skipped: true, reason: 'tombstoned' });
    }

    // Descarta viagens irrelevantes: energia E distância zeradas com menos de 1 min
    const _distKm  = autoTrip.distKm  || 0;
    const _netKwh  = autoTrip.netKwh  || 0;
    const _timeSec = autoTrip.timeSec || 0;
    if (_distKm <= 0 && _netKwh < 0.10 && _timeSec < 60) {
      console.log(`↷ AutoTrip ${safeId} ignorado (dist=0 energy=0 time=${_timeSec}s)`);
      return res.json({ ok: true, skipped: true });
    }

    const filePath = path.join(AUTOTRIPS_DIR, `${safeId}.json`);

    // Merge de samples com o que já existe no arquivo. Resolve o caso clássico
    // de RESUME no APK em que os samples antigos foram deletados localmente
    // pós-sync (linha 1258 do TripManager.kt) — o POST do resume só traz os
    // samples do trecho NOVO. Sem este merge, a rota visual + startLat/Lng do
    // primeiro trecho desaparecem da viagem combinada.
    //
    // Estratégia: deduplica por `t` arredondado (offset em segundos relativo
    // a startMs). Em conflito, prefere o sample NOVO (mais fresco). Os samples
    // antigos sobrevivem nos `t` que o novo POST não cobre.
    let existingSamples = [];
    if (fs.existsSync(filePath)) {
      try {
        const existing = JSON.parse(fs.readFileSync(filePath, 'utf8'));
        existingSamples = existing.samples || [];
      } catch (_) {}
    }

    const newSamples = samples || [];
    let finalSamples = newSamples;
    let didMerge = false;

    if (existingSamples.length > 0) {
      if (newSamples.length === 0) {
        // POST sem samples (sync metadata-only) — preserva existentes
        finalSamples = existingSamples;
      } else {
        // Atenção: `t` é em segundos (offset de startMs) e múltiplos samples no
        // mesmo segundo são comuns (tick de 500ms). Dedupe por t inteiro colapsa
        // samples legítimos. Estratégia: comparar os RANGES de `t` dos dois sets.
        //   - Disjuntos (typical resume): concatena e ordena
        //   - Overlap: assume que os existentes cobrem a parte mais antiga e os
        //     novos a mais recente; corta no maxExistingT
        const maxExistingT = existingSamples.reduce((m, s) => Math.max(m, s.t || 0), 0);
        const minNewT      = newSamples.reduce((m, s) => Math.min(m, s.t || 0), Infinity);
        if (minNewT > maxExistingT) {
          // Ranges disjuntos — apenas concatena
          finalSamples = [...existingSamples, ...newSamples];
        } else {
          // Overlap — corta os existentes em maxExistingT e usa novos pra t > cutT.
          // Em prática raro porque o APK reseta o array ao iniciar (resume traz
          // só t a partir do retomar). Mas é defensivo.
          finalSamples = [
            ...existingSamples.filter(s => (s.t || 0) <= maxExistingT),
            ...newSamples.filter(s => (s.t || 0) > maxExistingT),
          ];
        }
        if (finalSamples.length > newSamples.length) {
          didMerge = true;
          const preserved = finalSamples.length - newSamples.length;
          console.log(`↻ AutoTrip ${safeId}: merge — ${existingSamples.length} existentes + ${newSamples.length} novos = ${finalSamples.length} (${preserved} antigos preservados)`);
        }
      }
    }

    // Se o merge preservou samples antigos, recalcula start/end com o primeiro
    // e último ponto com GPS válido — corrige o startLat/Lng que o APK enviou
    // baseado só nos samples do trecho novo (pode estar no meio da viagem real).
    if (didMerge) {
      const firstGps = finalSamples.find(s => s.lat && s.lat !== 0);
      const lastGps  = [...finalSamples].reverse().find(s => s.lat && s.lat !== 0);
      if (firstGps && (firstGps.lat !== autoTrip.startLat || firstGps.lng !== autoTrip.startLng)) {
        console.log(`↻ AutoTrip ${safeId}: startLat ${(+autoTrip.startLat||0).toFixed(5)},${(+autoTrip.startLng||0).toFixed(5)} → ${firstGps.lat.toFixed(5)},${firstGps.lng.toFixed(5)}`);
        autoTrip.startLat = firstGps.lat;
        autoTrip.startLng = firstGps.lng;
      }
      if (lastGps && (lastGps.lat !== autoTrip.endLat || lastGps.lng !== autoTrip.endLng)) {
        autoTrip.endLat = lastGps.lat;
        autoTrip.endLng = lastGps.lng;
      }
    }

    // Calcula tempo e distância em modo híbrido (ICE ligado, rpm > 0)
    let hybridTimeSec = 0, hybridDistKm = 0;
    for (let i = 1; i < finalSamples.length; i++) {
      const a = finalSamples[i - 1], b = finalSamples[i];
      const dt = (b.t || 0) - (a.t || 0);
      if (dt > 0 && dt < 30 && (a.rpm || 0) > 50) {
        hybridTimeSec += dt;
        hybridDistKm  += ((a.spd || 0) + (b.spd || 0)) / 2 / 3600 * dt;
      }
    }
    hybridTimeSec = Math.round(hybridTimeSec);
    hybridDistKm  = parseFloat(hybridDistKm.toFixed(3));

    // Persiste hybrid junto — boot não precisa recalcular.
    fs.writeFileSync(filePath, JSON.stringify({
      tripId: safeId, autoTrip, samples: finalSamples, hybridTimeSec, hybridDistKm,
    }));

    const record = { tripId: safeId, ...autoTrip, hybridTimeSec, hybridDistKm };

    // Auto-naming por Locais Conhecidos
    const _sp = matchKnownPlace(autoTrip.startLat, autoTrip.startLng);
    const _ep = matchKnownPlace(autoTrip.endLat,   autoTrip.endLng);
    if (_sp) record.knownStart = _sp.name;
    if (_ep) record.knownEnd   = _ep.name;
    if (_sp && _ep) {
      record.name = `${_sp.name} → ${_ep.name}`;
      pendingRenames.push({ id: `kp-${safeId}`, type: 'auto', tripId: safeId, name: record.name, createdAt: Date.now() });
      try { fs.writeFileSync(RENAMES_FILE, JSON.stringify(pendingRenames, null, 2)); } catch (_) {}
    }

    const idx = autoTripsArr.findIndex(t => t.tripId === safeId);
    if (idx >= 0) autoTripsArr[idx] = record;
    else {
      autoTripsArr.unshift(record);
      autoTripsArr.sort((a, b) => (b.startMs || 0) - (a.startMs || 0));
    }

    console.log(`✓ AutoTrip: ${safeId} (${(samples || []).length} amostras)`);
    // Notifica a PWA em tempo real — qualquer aba aberta recebe o evento imediatamente
    broadcast('new_autotrip', {
      tripId:  safeId,
      startMs: autoTrip.startMs || 0,
      distKm:  autoTrip.distKm  || 0,
    });
    addEvent('trip_end', `Viagem concluída: ${(autoTrip.distKm||0).toFixed(1)} km`);
    // Push: viagem concluída (só se >1 km OU >3 min). On/off por device.
    {
      const distKm = autoTrip.distKm  || 0;
      const sec    = autoTrip.timeSec || 0;
      if (distKm > 1 || sec > 180) {
        const netKwh = autoTrip.netKwh || 0;
        const fuelL  = autoTrip.fuelL  || 0;
        const dist   = distKm.toFixed(1);
        const dur    = sec >= 3600
          ? `${Math.floor(sec / 3600)}h ${Math.floor((sec % 3600) / 60)}min`
          : `${Math.floor(sec / 60)}min`;
        const kwh100 = distKm > 0.1 && netKwh > 0 ? (netKwh / distKm * 100).toFixed(1) : null;
        const kmL    = fuelL  > 0.01              ? (distKm / fuelL).toFixed(1)         : null;
        // Custo da viagem usa preços PONDERADOS pelo mix de combustível/recargas
        // do tanque/bateria, recalculados a cada refuel/charge. Sem isso, o
        // valor exibido ignorava se a recarga foi grátis ou se o tanque tinha
        // mix de preços diferentes.
        const pKwh = state.battery_avg_price_per_kwh || state.price_kwh || 0;
        const pGas = state.tank_avg_price_per_l      || state.price_gas_per_l || 0;
        const cost = (pGas > 0 || pKwh > 0) ? fuelL * pGas + netKwh * pKwh : 0;

        const parts = [`${dist} km`, dur];
        if (netKwh > 0.01) parts.push(`${netKwh.toFixed(2)} kWh`);
        if (kwh100)        parts.push(`${kwh100} kWh/100`);
        if (fuelL > 0.01)  parts.push(`${fuelL.toFixed(2)} L`);
        if (kmL)           parts.push(`${kmL} km/L`);
        if (cost  > 0.01)  parts.push(`R$ ${cost.toFixed(2)}`);

        sendPush('🏁 Viagem concluída', parts.join(' · '), 'trip_end');
      }
    }
    res.json({ ok: true });
  } catch (e) {
    console.error('Erro ao salvar auto-trip:', e.message);
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/autotrips', (req, res) => {
  const since = parseInt(req.query.since || '0', 10);
  const arr   = since > 0 ? autoTripsArr.filter(t => t.startMs > since) : autoTripsArr;
  if (Array.isArray(deletedIds.autotrips) && deletedIds.autotrips.length) {
    res.setHeader('X-Tombstones', deletedIds.autotrips.join(','));
    res.setHeader('Access-Control-Expose-Headers', 'X-Tombstones');
  }
  res.json(arr.slice(0, 300));
});

app.delete('/api/autotrips/:tripId', (req, res) => {
  const id = String(req.params.tripId).replace(/\D/g, '');
  if (!id) return res.status(400).json({ error: 'invalid tripId' });
  const idx = autoTripsArr.findIndex(t => t.tripId === id || String(t.startMs) === id);
  console.log(`[delete] AutoTrip lookup id=${id} idx=${idx} total=${autoTripsArr.length}`);
  // Mesmo se já não está em memória (ex: APK reenviou e bridge ignorou), grava
  // tombstone — bloqueia futuras tentativas do APK de inserir esse ID.
  markDeleted('autotrips', id);
  if (idx < 0) return res.status(404).json({ error: 'not found', id, tombstoned: true });
  autoTripsArr.splice(idx, 1);
  const filePath = path.join(AUTOTRIPS_DIR, `${id}.json`);
  try { fs.unlinkSync(filePath); } catch (_) {}
  console.log(`[delete] AutoTrip ${id} removido (tombstone gravado)`);
  res.json({ ok: true });
});

// ── Unir dois auto-trips em um só ────────────────────────────────────────────
app.post('/api/autotrips/merge', (req, res) => {
  try {
    const { tripAId, tripBId } = req.body;
    if (!tripAId || !tripBId) return res.status(400).json({ error: 'missing tripAId or tripBId' });

    const safeA = String(tripAId).replace(/\D/g, '');
    const safeB = String(tripBId).replace(/\D/g, '');
    if (!safeA || !safeB || safeA === safeB) return res.status(400).json({ error: 'invalid ids' });

    const fileA = path.join(AUTOTRIPS_DIR, `${safeA}.json`);
    const fileB = path.join(AUTOTRIPS_DIR, `${safeB}.json`);
    if (!fs.existsSync(fileA)) return res.status(404).json({ error: `trip not found: ${safeA}` });
    if (!fs.existsSync(fileB)) return res.status(404).json({ error: `trip not found: ${safeB}` });

    const dataA = JSON.parse(fs.readFileSync(fileA, 'utf8'));
    const dataB = JSON.parse(fs.readFileSync(fileB, 'utf8'));
    const atA = dataA.autoTrip || {}, samplesA = dataA.samples || [];
    const atB = dataB.autoTrip || {}, samplesB = dataB.samples || [];

    // Garante ordem cronológica: early = mais antigo
    const [earlyId, earlyAT, earlySamples, lateId, lateAT, lateSamples] =
      (atA.startMs || parseInt(safeA,10)) <= (atB.startMs || parseInt(safeB,10))
        ? [safeA, atA, samplesA, safeB, atB, samplesB]
        : [safeB, atB, samplesB, safeA, atA, samplesA];

    const merged = {
      startMs:      earlyAT.startMs,
      endMs:        lateAT.endMs,
      startSocPct:  earlyAT.startSocPct  || 0,
      endSocPct:    lateAT.endSocPct     || 0,
      startFuelPct: earlyAT.startFuelPct || 0,
      endFuelPct:   lateAT.endFuelPct    || 0,
      distKm:   parseFloat(((earlyAT.distKm   ||0)+(lateAT.distKm   ||0)).toFixed(3)),
      timeSec:  Math.round ((earlyAT.timeSec  ||0)+(lateAT.timeSec  ||0)),
      energyKwh:parseFloat(((earlyAT.energyKwh||0)+(lateAT.energyKwh||0)).toFixed(4)),
      regenKwh: parseFloat(((earlyAT.regenKwh ||0)+(lateAT.regenKwh ||0)).toFixed(4)),
      netKwh:   parseFloat(((earlyAT.netKwh   ||0)+(lateAT.netKwh   ||0)).toFixed(4)),
      fuelL:    parseFloat(((earlyAT.fuelL    ||0)+(lateAT.fuelL    ||0)).toFixed(4)),
      startLat: earlyAT.startLat || 0,  startLng: earlyAT.startLng || 0,
      endLat:   lateAT.endLat   || 0,  endLng:   lateAT.endLng   || 0,
    };
    if (earlyAT.name || lateAT.name) merged.name = earlyAT.name || lateAT.name;

    // Samples unificados — já estão em ordem cronológica
    const mergedSamples = [...earlySamples, ...lateSamples];

    // Recalcula métricas híbridas
    let hybridTimeSec = 0, hybridDistKm = 0;
    for (let i = 1; i < mergedSamples.length; i++) {
      const a = mergedSamples[i-1], b = mergedSamples[i];
      const dt = (b.t||0)-(a.t||0);
      if (dt > 0 && dt < 30 && (a.rpm||0) > 50) {
        hybridTimeSec += dt;
        hybridDistKm  += ((a.spd||0)+(b.spd||0))/2/3600*dt;
      }
    }
    hybridTimeSec = Math.round(hybridTimeSec);
    hybridDistKm  = parseFloat(hybridDistKm.toFixed(3));

    // Salva arquivo unificado (ID da viagem mais antiga) — hybrid persistido pra
    // boot não recalcular.
    fs.writeFileSync(
      path.join(AUTOTRIPS_DIR, `${earlyId}.json`),
      JSON.stringify({ tripId: earlyId, autoTrip: merged, samples: mergedSamples, hybridTimeSec, hybridDistKm })
    );
    // Remove arquivo da viagem mais recente
    try { fs.unlinkSync(path.join(AUTOTRIPS_DIR, `${lateId}.json`)); } catch (_) {}

    // Atualiza array em memória
    autoTripsArr = autoTripsArr.filter(t => t.tripId !== earlyId && t.tripId !== lateId);
    const record = { tripId: earlyId, ...merged, hybridTimeSec, hybridDistKm };
    autoTripsArr.push(record);
    autoTripsArr.sort((a, b) => (b.startMs||0)-(a.startMs||0));

    console.log(`[merge] ${earlyId} + ${lateId} → ${earlyId} (${merged.distKm} km, ${mergedSamples.length} amostras)`);
    res.json({ ok: true, mergedId: earlyId, trip: record });
  } catch (e) {
    console.error('[merge]', e);
    res.status(500).json({ error: String(e.message) });
  }
});

// DELETE /api/trips/:id retorna 410 (Gone) — Trip A/B descontinuados.

// ── Renomear trips (PWA → fila → Android) ─────────────────────────────────────
// Carrega fila persistida
let pendingRenames = [];
try {
  if (fs.existsSync(RENAMES_FILE))
    pendingRenames = JSON.parse(fs.readFileSync(RENAMES_FILE, 'utf8')) || [];
} catch (_) {}

function savePendingRenames() {
  // Mantém só últimos 30 dias para não acumular para sempre
  const cutoff = Date.now() - 30 * 86_400_000;
  pendingRenames = pendingRenames.filter(r => r.createdAt > cutoff);
  fs.writeFileSync(RENAMES_FILE, JSON.stringify(pendingRenames, null, 2));
}

// POST /api/rename  { tripId, type, name, ts? }
// type: 'auto' | 'manual' | 'trip_finish' | 'trip_name'
// trip_finish / trip_name: tripId deve ser 'A' ou 'B'; name opcional para trip_finish
app.post('/api/rename', (req, res) => {
  const { tripId, type, name, ts } = req.body || {};
  if (!tripId) return res.status(400).json({ error: 'tripId obrigatório' });

  const isTripCmd = type === 'trip_finish' || type === 'trip_name';

  // Comandos de trip A/B: validação específica
  if (isTripCmd) {
    if (!['A', 'B'].includes(String(tripId).toUpperCase())) {
      return res.status(400).json({ error: 'tripId deve ser A ou B para trip commands' });
    }
    if (type === 'trip_name' && !name) {
      return res.status(400).json({ error: 'name obrigatório para trip_name' });
    }
  } else {
    // Renames normais: name obrigatório
    if (!name) return res.status(400).json({ error: 'name obrigatório' });
  }

  const trimmed = name ? String(name).trim().slice(0, 80) : '';

  if (type === 'auto') {
    // Atualiza array em memória
    const t = autoTripsArr.find(r => r.tripId === String(tripId));
    if (t) t.name = trimmed;
    // Atualiza arquivo do auto-trip
    const safeId   = String(tripId).replace(/\D/g, '');
    const filePath = path.join(AUTOTRIPS_DIR, `${safeId}.json`);
    if (fs.existsSync(filePath)) {
      try {
        const data = JSON.parse(fs.readFileSync(filePath, 'utf8'));
        data.autoTrip = data.autoTrip || {};
        data.autoTrip.name = trimmed;
        fs.writeFileSync(filePath, JSON.stringify(data));
      } catch (_) {}
    }
  }
  // type 'manual' (Trip A/B) descontinuado — ignora rename silenciosamente
  // trip_finish / trip_name: sem dados locais para atualizar — o carro aplica ao ligar

  // Enfileira para o Android consumir
  const id = `${Date.now()}-${Math.random().toString(36).slice(2, 7)}`;
  const entry = { id, tripId: String(tripId), type: type || 'auto', name: trimmed, createdAt: Date.now() };
  if (isTripCmd && ts) entry.ts = Number(ts);
  pendingRenames.push(entry);
  savePendingRenames();
  console.log(`✓ Rename enfileirado: [${type}] ${tripId} → "${trimmed}"`);
  res.json({ ok: true, id });  // id necessário para PWA rastrear status de confirmação
});

// GET /api/pending-renames  — Android consulta ao conectar
app.get('/api/pending-renames', (_req, res) => res.json(pendingRenames));

// POST /api/rename-ack  { ids: ['id1','id2',...] }  — Android confirma após aplicar
app.post('/api/rename-ack', (req, res) => {
  const { ids } = req.body || {};
  if (!Array.isArray(ids)) return res.status(400).json({ error: 'ids deve ser array' });
  pendingRenames = pendingRenames.filter(r => !ids.includes(r.id));
  savePendingRenames();
  res.json({ ok: true, remaining: pendingRenames.length });
});

// Snapshots do lifetime para filtros de período no PWA (não depende de sync de auto-trips)
app.get('/api/lifetime/snapshots', (_req, res) => res.json(lifeSnapshots));

// Limpar snapshots (admin)
app.post('/api/lifetime/snapshots/clear', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  lifeSnapshots = [];
  lastSnapMs = 0;
  try { fs.writeFileSync(SNAPSHOTS_FILE, '[]'); } catch (_) {}
  console.log('[admin] snapshots limpos');
  res.json({ ok: true, msg: 'Snapshots apagados. O próximo chegará em até 5 min.' });
});

// Forçar snapshot imediato (admin)
app.post('/api/lifetime/snapshots/force', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  lastSnapMs = 0;   // zera debounce
  maybeSaveLifetimeSnapshot();
  const n = lifeSnapshots.length;
  console.log('[admin] snapshot forçado — total:', n);
  res.json({ ok: true, msg: n > 0 ? `Snapshot forçado. Total: ${n}.` : 'Sem dados lifetime ainda (aguarde dados do carro).' });
});

app.get('/api/telemetry/:tripId', (req, res) => {
  const safeId   = String(req.params.tripId).replace(/\D/g, '');
  const filePath = path.join(AUTOTRIPS_DIR, `${safeId}.json`);
  if (!fs.existsSync(filePath)) return res.status(404).json({ error: 'not found' });
  res.sendFile(filePath);
});

// Última localização GPS conhecida do carro (pega do arquivo de telemetria mais recente)
app.get('/api/location', (_req, res) => {
  // Usa GPS em memória — atualizado live por gps_lat/gps_lng do MQTT e persistido
  // em state.json. Endpoint O(1) em vez de varrer todos os JSONs de auto-trip a
  // cada GET (antes lia N arquivos do disco por chamada).
  if (state.gps_lat && state.gps_lng) {
    return res.json({
      lat: state.gps_lat,
      lng: state.gps_lng,
      ts:  state.gps_ts || null,
    });
  }
  // Fallback: se state.json estava vazio no boot, varre arquivos uma vez.
  try {
    const files = fs.readdirSync(AUTOTRIPS_DIR).filter(f => f.endsWith('.json')).sort().reverse();
    for (const f of files) {
      const d = JSON.parse(fs.readFileSync(path.join(AUTOTRIPS_DIR, f), 'utf8'));
      const samples = d.samples || [];
      const lastGps = [...samples].reverse().find(s => s.lat !== 0 || s.lng !== 0);
      if (lastGps) {
        // Popula state pra próximas chamadas serem O(1)
        state.gps_lat = lastGps.lat;
        state.gps_lng = lastGps.lng;
        state.gps_ts  = d.autoTrip?.endMs || null;
        return res.json({ lat: lastGps.lat, lng: lastGps.lng, tripId: d.tripId, ts: state.gps_ts });
      }
    }
    res.json({ lat: null, lng: null });
  } catch (_e) {
    res.json({ lat: null, lng: null });
  }
});

// ─── Diag mode ────────────────────────────────────────────────────────────
app.get('/api/diag/status', (_req, res) => {
  res.json({
    enabled:        diagState.enabled,
    interval_sec:   diagState.interval_sec,
    keys_count:     Object.keys(diagState.values).length,
    last_update_ms: diagState.last_update_ms,
  });
});

app.get('/api/diag/data', (req, res) => {
  // Snapshot atual: { values: {key: {value, ts}}, ... }
  res.json({
    enabled:                  diagState.enabled,
    interval_sec:             diagState.interval_sec,
    last_update_ms:           diagState.last_update_ms,
    last_state_from_apk_ms:   diagState.last_state_from_apk_ms || 0,
    last_requested:           diagState.last_requested || null,
    values:                   diagState.values,
  });
});

app.get('/api/diag/log', (req, res) => {
  // Histórico completo (rotacionado a DIAG_LOG_MAX entradas)
  const limit = Math.min(DIAG_LOG_MAX, parseInt(req.query.limit) || DIAG_LOG_MAX);
  res.json(diagLog.slice(-limit));
});

app.post('/api/diag/enable', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  const b = req.body || {};
  if (typeof b.enabled !== 'boolean') return res.status(400).json({ error: 'enabled (bool) obrigatório' });
  const interval = parseInt(b.interval_sec || diagState.interval_sec || 5);
  if (interval < 1 || interval > 300) return res.status(400).json({ error: 'interval_sec entre 1 e 300' });
  // NÃO atualizamos diagState.enabled aqui — fonte de verdade é o ack do APK
  // (tópico diag/state). Só registramos o pedido e gravamos o intervalo solicitado.
  diagState.interval_sec = interval;
  diagState.last_requested = { enabled: b.enabled, interval_sec: interval, ts: Date.now() };
  _saveDiagState();
  // Publica comando pro APK começar/parar a coleta
  if (!mqttClient?.connected) {
    _pushDiagEvent({ type: 'cmd_error', error: 'MQTT offline', requested: { enabled: b.enabled, interval_sec: interval } });
    return res.status(503).json({ error: 'MQTT offline' });
  }
  const cmd = JSON.stringify({ enabled: b.enabled, interval_sec: interval });
  _pushDiagEvent({ type: 'cmd_sent', topic: `${MQTT_PREFIX}/cmd/diag`, payload: { enabled: b.enabled, interval_sec: interval } });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/diag`, cmd, { qos: 1, retain: true }, err => {
    if (err) {
      _pushDiagEvent({ type: 'cmd_error', error: err.message });
      return res.status(500).json({ error: 'Falha ao publicar no MQTT: ' + err.message });
    }
    console.log(`[diag] cmd publicado: enabled=${b.enabled} interval=${interval}s — aguardando ack do APK`);
    res.json({ ok: true, pending: true, requested: { enabled: b.enabled, interval_sec: interval } });
  });
});

// GET /api/diag/events — últimos eventos de comandos (envio/ack/erro)
app.get('/api/diag/events', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  res.json({ events: diagEvents });
});

app.post('/api/diag/clear', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  diagLog = [];
  diagState.values = {};
  _saveDiagState();
  res.json({ ok: true });
});

// POST /api/diag/set { key, value } — pede pro APK tentar gravar a constante
// no carro via Shizuku. Nem todas são writable — APK responde em diag_ack/<key>
// com { ok, error }. Bridge propaga via WS pra UI mostrar resultado.
app.post('/api/diag/set', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  const { key, value } = req.body || {};
  if (!key || typeof key !== 'string') return res.status(400).json({ error: 'key obrigatório' });
  if (value === undefined) return res.status(400).json({ error: 'value obrigatório' });
  if (!mqttClient?.connected) return res.status(503).json({ error: 'MQTT offline' });
  const payload = typeof value === 'object' ? JSON.stringify(value) : String(value);
  _pushDiagEvent({ type: 'set_cmd_sent', topic: `${MQTT_PREFIX}/cmd/diag_set/${key}`, key, payload });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/diag_set/${key}`, payload, { qos: 1, retain: false }, err => {
    if (err) {
      _pushDiagEvent({ type: 'cmd_error', error: err.message, key });
      return res.status(500).json({ error: 'Falha ao publicar: ' + err.message });
    }
    console.log(`[diag] set ${key} = ${payload}`);
    res.json({ ok: true, key, value: payload, sent_at: Date.now() });
  });
});

// Commit + data do HEAD, lido uma vez no boot (não muda em runtime)
let _BRIDGE_GIT_INFO = null;
function _readGitInfo() {
  if (_BRIDGE_GIT_INFO) return _BRIDGE_GIT_INFO;
  try {
    const { execSync } = require('child_process');
    const cwd = path.join(__dirname, '..');
    const sha = execSync('git rev-parse --short HEAD', { cwd, encoding: 'utf8', timeout: 1500 }).trim();
    const date = execSync('git log -1 --format=%cI HEAD', { cwd, encoding: 'utf8', timeout: 1500 }).trim();
    _BRIDGE_GIT_INFO = { sha, date };
  } catch (_) { _BRIDGE_GIT_INFO = { sha: null, date: null }; }
  return _BRIDGE_GIT_INFO;
}
// GET /api/network/ssid — retorna o SSID da rede onde o bridge está conectado.
// Browsers não expõem SSID por privacidade; esse endpoint pega do macOS via
// `networksetup`. Útil só quando user/bridge estão na mesma rede Wi-Fi.
let _ssidCache = { value: null, ts: 0 };
app.get('/api/network/ssid', (_req, res) => {
  // Cache 30s pra não shellar a cada open do modal
  if (Date.now() - _ssidCache.ts < 30_000) return res.json({ ssid: _ssidCache.value, cached: true });
  if (process.platform !== 'darwin') return res.json({ ssid: null, reason: 'platform_not_supported' });
  const { exec } = require('child_process');
  // Descobre a interface Wi-Fi (varia por Mac: en0/en1/...). networksetup
  // -listallhardwareports retorna pares "Hardware Port: Wi-Fi" + "Device: enN"
  exec('/usr/sbin/networksetup -listallhardwareports', { timeout: 2000 }, (err1, ports) => {
    if (err1) { _ssidCache = { value: null, ts: Date.now() }; return res.json({ ssid: null }); }
    const m = ports.match(/Hardware Port:\s*Wi-Fi[\s\S]*?Device:\s*(\S+)/i);
    const iface = m ? m[1] : 'en0';
    exec(`/usr/sbin/networksetup -getairportnetwork ${iface}`, { timeout: 2000 }, (err2, stdout) => {
      let ssid = null;
      if (!err2 && stdout) {
        const m2 = stdout.match(/:\s*(.+?)\s*$/);
        if (m2 && m2[1] && !/not associated|off/i.test(m2[1])) ssid = m2[1];
      }
      _ssidCache = { value: ssid, ts: Date.now() };
      res.json({ ssid, iface });
    });
  });
});

// GET /api/whoami — retorna IP do cliente + headers úteis pra debug de rede.
// Usado pelo indicador de rede no header da PWA (toque mostra IP).
app.get('/api/whoami', (req, res) => {
  const xff = req.headers['x-forwarded-for'] || '';
  const remoteIp = (xff.split(',')[0] || req.socket.remoteAddress || '').trim();
  res.json({
    remote_ip: remoteIp,
    x_forwarded_for: xff || null,
    user_agent: req.headers['user-agent'] || null,
    via: req.headers['via'] || null,  // se via Tailscale Funnel, vem aqui
    host: req.headers['host'] || null,
    timestamp: Date.now(),
  });
});

app.get('/api/config', (_req, res) => {
  const git = _readGitInfo();
  res.json({
    mqtt_host:        MQTT_HOST,
    mqtt_prefix:      MQTT_PREFIX,
    mqtt_connected:   !!(mqttClient && mqttClient.connected),
    version:          require('./package.json').version,
    git_commit:       git.sha,
    git_commit_date:  git.date,
    bridge_uptime_sec: Math.floor(process.uptime()),
    started_at_ms:    SERVER_START_AT,
    node_version:     process.version,
    platform:         process.platform,
  });
});

// ── Push Notifications ────────────────────────────────────────────────────────
app.get('/api/push/vapid-key', (_req, res) => res.json({ key: vapidKeys.publicKey }));

app.post('/api/push/subscribe', (req, res) => {
  const body = req.body || {};
  if (!body?.endpoint) return res.status(400).json({ error: 'invalid subscription' });
  const incomingDeviceId = body.device_id && String(body.device_id).trim();
  const incomingName = body.device_name && String(body.device_name).trim();
  // Dedup #1: match exato por endpoint — atualiza no lugar
  const sameEndpoint = pushSubs.find(s => s.endpoint === body.endpoint);
  if (sameEndpoint) {
    if (incomingDeviceId) sameEndpoint.device_id = incomingDeviceId;
    if (incomingName)     sameEndpoint.device_name = incomingName;
    sameEndpoint.last_seen = Date.now();
    savePushSubs();
    return res.json({ ok: true, device_id: sameEndpoint.device_id, device_name: sameEndpoint.device_name });
  }
  // Dedup #2: mesmo device_id, endpoint diferente (browser re-subscreveu) →
  // REMOVE as entradas antigas pra evitar duplicatas. Browsers iOS/Android giram
  // endpoint quando o token push é renovado; sem isso o histórico enche de subs
  // do mesmo aparelho.
  if (incomingDeviceId) {
    const dups = pushSubs.filter(s => s.device_id === incomingDeviceId);
    if (dups.length > 0) {
      pushSubs = pushSubs.filter(s => s.device_id !== incomingDeviceId);
      console.log(`[push] device_id ${incomingDeviceId.slice(0,8)} re-subscribed — removidas ${dups.length} entry(s) antigas`);
    }
  }
  const deviceId = incomingDeviceId || genDeviceId();
  const sub = {
    endpoint:    body.endpoint,
    keys:        body.keys,
    device_id:   deviceId,
    device_name: incomingName || 'Dispositivo',
    created_at:  Date.now(),
    last_seen:   Date.now(),
  };
  if (!notifPrefsByDevice[deviceId]) {
    notifPrefsByDevice[deviceId] = { ...NOTIF_DEFAULTS };
    saveNotifPrefsByDevice();
  }
  pushSubs.push(sub);
  savePushSubs();
  res.json({ ok: true, device_id: deviceId, device_name: sub.device_name });
});

// POST /api/admin/dedup-devices — limpa duplicatas existentes (mantém apenas a
// entry mais recente por device_id; nomes diferentes → opta pela mais nova).
app.post('/api/admin/dedup-devices', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  const byId = new Map();
  for (const s of pushSubs) {
    const id = s.device_id || s.endpoint;
    const prev = byId.get(id);
    if (!prev || (s.last_seen || s.created_at || 0) > (prev.last_seen || prev.created_at || 0)) {
      byId.set(id, s);
    }
  }
  const before = pushSubs.length;
  pushSubs = [...byId.values()];
  savePushSubs();
  console.log(`[push] dedup: ${before} → ${pushSubs.length} subs`);
  res.json({ ok: true, before, after: pushSubs.length });
});

app.post('/api/push/unsubscribe', (req, res) => {
  const { endpoint } = req.body || {};
  if (endpoint) { pushSubs = pushSubs.filter(s => s.endpoint !== endpoint); savePushSubs(); }
  res.json({ ok: true });
});

// POST /api/push/test — envia notificação de teste (diagnóstico)
app.post('/api/push/test', async (_req, res) => {
  if (!pushSubs.length) return res.json({ ok: false, error: 'sem subscribers' });
  await sendPush('🔔 Teste EcoTrip', 'Notificações push estão funcionando!');
  res.json({ ok: true, subscribers: pushSubs.length });
});

// POST /api/push/reset-subs — limpa TODAS as subscrições (força re-subscribe no cliente)
app.post('/api/push/reset-subs', (_req, res) => {
  const count = pushSubs.length;
  pushSubs = [];
  savePushSubs();
  console.log(`Push: ${count} subscrição(ões) removida(s) via reset-subs`);
  res.json({ ok: true, removed: count });
});

// GET /api/push/prefs  — preferências de notificação por tipo de evento
app.get('/api/push/prefs', (_req, res) => res.json(notifPrefs));

// POST /api/push/prefs  { key, value }  — atualiza uma preferência (boolean ou numérica)
app.post('/api/push/prefs', (req, res) => {
  const { key, value } = req.body || {};
  if (!key || !(key in NOTIF_DEFAULTS)) return res.status(400).json({ error: 'chave inválida' });
  const def = NOTIF_DEFAULTS[key];
  if (Array.isArray(def)) {
    // Lista de IDs (ex: geofence_arrival_places)
    if (!Array.isArray(value)) return res.status(400).json({ error: 'esperado array' });
    notifPrefs[key] = value.map(String);
  } else if (typeof def === 'number') {
    const n = parseInt(value);
    if (isNaN(n)) return res.status(400).json({ error: 'valor numérico inválido' });
    notifPrefs[key] = Math.max(1, Math.min(20, n));
  } else {
    notifPrefs[key] = !!value;
  }
  saveNotifPrefs();
  res.json({ ok: true, prefs: notifPrefs });
});

// ── Devices: lista, prefs por device, rename, delete ─────────────────────────
// GET /api/notif/devices — lista todos os devices registrados (push subs)
app.get('/api/notif/devices', (_req, res) => {
  const list = pushSubs.map(s => ({
    device_id:   s.device_id || null,
    device_name: s.device_name || '(sem nome)',
    last_seen:   s.last_seen || s.created_at || null,
    has_prefs:   !!(s.device_id && notifPrefsByDevice[s.device_id]),
    endpoint_tail: (s.endpoint || '').slice(-24),
  }));
  res.json({ devices: list });
});

// GET /api/notif/prefs/:device_id — prefs efetivas (defaults + global + device)
app.get('/api/notif/prefs/:device_id', (req, res) => {
  const id = req.params.device_id;
  res.json({
    device_id: id,
    prefs:     getPrefsForDevice(id),
    overrides: notifPrefsByDevice[id] || {},
  });
});

// POST /api/notif/prefs/:device_id  { key, value }
app.post('/api/notif/prefs/:device_id', (req, res) => {
  const id = req.params.device_id;
  const { key, value } = req.body || {};
  if (!key || !(key in NOTIF_DEFAULTS)) return res.status(400).json({ error: 'chave inválida' });
  if (!notifPrefsByDevice[id]) notifPrefsByDevice[id] = {};
  const def = NOTIF_DEFAULTS[key];
  if (Array.isArray(def)) {
    if (!Array.isArray(value)) return res.status(400).json({ error: 'esperado array' });
    notifPrefsByDevice[id][key] = value.map(String);
  } else if (typeof def === 'number') {
    const n = parseInt(value);
    if (isNaN(n)) return res.status(400).json({ error: 'valor numérico inválido' });
    notifPrefsByDevice[id][key] = Math.max(1, Math.min(20, n));
  } else {
    notifPrefsByDevice[id][key] = !!value;
  }
  saveNotifPrefsByDevice();
  res.json({ ok: true, prefs: getPrefsForDevice(id) });
});

// PATCH /api/notif/devices/:device_id  { device_name }
app.patch('/api/notif/devices/:device_id', (req, res) => {
  const id = req.params.device_id;
  const name = (req.body?.device_name || '').toString().trim();
  if (!name) return res.status(400).json({ error: 'device_name vazio' });
  const sub = pushSubs.find(s => s.device_id === id);
  if (!sub) return res.status(404).json({ error: 'device não encontrado' });
  sub.device_name = name.slice(0, 50);
  savePushSubs();
  res.json({ ok: true, device_id: id, device_name: sub.device_name });
});

// DELETE /api/notif/devices/:device_id — remove subscription E prefs
app.delete('/api/notif/devices/:device_id', (req, res) => {
  const id = req.params.device_id;
  const before = pushSubs.length;
  pushSubs = pushSubs.filter(s => s.device_id !== id);
  savePushSubs();
  if (notifPrefsByDevice[id]) {
    delete notifPrefsByDevice[id];
    saveNotifPrefsByDevice();
  }
  res.json({ ok: true, removed: before - pushSubs.length });
});

// GET /api/push/history  — central de notificações
// History é gravado globalmente (pra log/diagnóstico) mas o PWA filtra por
// device: só mostra entradas cujo `type` está ON nas prefs daquele device.
// Entradas sem `type` (testes/genéricas) sempre passam.
app.get('/api/push/history', (req, res) => {
  const deviceId = req.query.device_id || '';
  if (!deviceId) return res.json(notifHistory);  // sem device: comportamento legado
  const prefs = getPrefsForDevice(deviceId);
  const filtered = notifHistory.filter(n => !n.type || prefs[n.type] === true);
  res.json(filtered);
});

// POST /api/push/history/clear  — limpa histórico de notificações
app.post('/api/push/history/clear', (_req, res) => {
  notifHistory = [];
  saveNotifHistory();
  res.json({ ok: true });
});

// ── Remote Actions ────────────────────────────────────────────────────────────
// Cada ação do PWA mapeia 1:1 num button.* da integração GWM Brasil no HA.
// O bridge dispara via REST: POST $HA_URL/api/services/button/press { entity_id }.
const ACTION_TO_HA_BUTTON = {
  engine_on:      'ligar_o_motor',
  engine_off:     'desligar_o_motor',
  lock_open:      'abrir_as_portas',
  lock_close:     'fechar_as_portas',
  windows_open:   'abrir_os_vidros',
  windows_close:  'fechar_os_vidros',
  trunk_open:     'abrir_porta_malas',
  trunk_close:    'fechar_porta_malas',
  sunroof_open:   'abrir_teto_solar',
  sunroof_close:  'fechar_teto_solar',
  ac_on:          'ativacao_do_ar_condicionado',
  charge_stop:    'interromper_carregamento',
  charge_history: 'historico_de_carregamento',
};
const ALLOWED_ACTIONS = new Set(Object.keys(ACTION_TO_HA_BUTTON));

// ── Reverse-geocode via Nominatim (1 req/s, cache em memória) ─────────────
// Usado pelo reprocessamento de trips/charges. Para o uso runtime do PWA,
// cada cliente faz o seu (Nominatim aceita); aqui o foco é batch server-side.
const _geocodeMem = new Map();
function _geocodeMemKey(lat, lng) {
  return (Math.round(lat * 1000) / 1000) + ',' + (Math.round(lng * 1000) / 1000);
}
async function _reverseGeocode(lat, lng) {
  const k = _geocodeMemKey(lat, lng);
  if (_geocodeMem.has(k)) return _geocodeMem.get(k);
  try {
    const r = await fetch(`https://nominatim.openstreetmap.org/reverse?format=json&lat=${lat}&lon=${lng}&zoom=16`, {
      headers: {
        'Accept': 'application/json',
        'User-Agent': 'ecotrip-bridge/1.0 (https://github.com/rafaelcs28/haval-ecotrip)',
      },
    });
    const j = await r.json();
    const a = j.address || {};
    const result = {
      city:   a.city || a.town || a.village || a.county || '',
      suburb: a.suburb || a.neighbourhood || a.quarter || a.borough || a.city_district || '',
    };
    _geocodeMem.set(k, result);
    return result;
  } catch (_) {
    _geocodeMem.set(k, { city: '', suburb: '' });
    return { city: '', suburb: '' };
  }
}
function _formatPlace(g, otherG) {
  // Mesma cidade do oposto → "Bairro, Cidade"; cidade diferente → só cidade
  const sameCity = otherG && g.city && otherG.city && g.city === otherG.city;
  if (sameCity && g.suburb && g.city) return g.suburb + ', ' + g.city;
  if (sameCity && g.suburb)           return g.suburb;
  return g.city || g.suburb || '';
}

let _reprocessRunning = false;
let _reprocessStatus = null;  // { kind, total, done, current, errors }

function _broadcastReprocess() {
  broadcast('reprocess_progress', _reprocessStatus);
}

// POST /api/admin/reprocess-places  body { kind: 'trips'|'charges'|'all', force?: bool }
// Itera tudo, faz reverse-geocode 1/s. Resposta imediata; progresso via WS.
app.post('/api/admin/reprocess-places', async (req, res) => {
  if (!adminCheckToken(req, res)) return;
  if (_reprocessRunning) return res.status(409).json({ error: 'já em execução', status: _reprocessStatus });
  const kind  = req.body?.kind || 'all';   // 'trips' | 'charges' | 'all'
  const force = !!req.body?.force;
  const tripFiles = (kind === 'trips' || kind === 'all')
    ? fs.readdirSync(AUTOTRIPS_DIR).filter(f => f.endsWith('.json'))
    : [];
  const chargesTodo = (kind === 'charges' || kind === 'all')
    ? chargesArr.filter(c => c.location_lat && c.location_lng && (force || !c.location_name))
    : [];
  const total = tripFiles.length + chargesTodo.length;
  _reprocessRunning = true;
  _reprocessStatus = { kind, total, done: 0, trips_updated: 0, charges_updated: 0, errors: 0, current: '' };
  res.json({ ok: true, total, kind });
  // Resolve um lado: prioridade pra knownPlace (autoMatchLocation, raio 200m);
  // só cai no Nominatim quando o GPS está fora de qualquer KP. SEMPRE retorna
  // o geocode (mesmo quando é KP) pra que a regra "mesma cidade" funcione no
  // OUTRO lado da viagem.
  async function _resolveSide(lat, lng) {
    const kp = autoMatchLocation(lat, lng);
    const geo = await _reverseGeocode(lat, lng);
    await new Promise(r => setTimeout(r, 1100));
    if (kp?.name) return { name: kp.name, from_kp: true, geo };
    return { name: null, from_kp: false, geo };
  }
  // Roda em background
  (async () => {
    try {
      // Trips
      for (const f of tripFiles) {
        try {
          const filePath = path.join(AUTOTRIPS_DIR, f);
          const d = JSON.parse(fs.readFileSync(filePath, 'utf8'));
          const at = d.autoTrip || {};
          const skip = !force && at.startKp && at.endKp;
          if (!skip && at.startLat && at.endLat) {
            const s = await _resolveSide(at.startLat, at.startLng);
            const e = await _resolveSide(at.endLat, at.endLng);
            // KP tem prioridade; senão "Bairro, Cidade" (se mesma cidade do oposto)
            const newStart = s.from_kp ? s.name : _formatPlace(s.geo, e.geo);
            const newEnd   = e.from_kp ? e.name : _formatPlace(e.geo, s.geo);
            if (force || !at.startKp) at.startKp = newStart || at.startKp || null;
            if (force || !at.endKp)   at.endKp   = newEnd   || at.endKp   || null;
            _reprocessStatus.current = (at.startKp || '?') + ' → ' + (at.endKp || '?');
            fs.writeFileSync(filePath, JSON.stringify(d, null, 2));
            _reprocessStatus.trips_updated++;
          }
        } catch (e) { _reprocessStatus.errors++; }
        _reprocessStatus.done++;
        if (_reprocessStatus.done % 3 === 0) _broadcastReprocess();
      }
      // Charges — também prioriza KP. Sem KP: "Cidade" (sem oposto, fica só cidade).
      for (const c of chargesTodo) {
        try {
          const kp = autoMatchLocation(c.location_lat, c.location_lng);
          let name = kp?.name || null;
          if (!name) {
            const g = await _reverseGeocode(c.location_lat, c.location_lng);
            await new Promise(r => setTimeout(r, 1100));
            name = _formatPlace(g, null);
          }
          if (name) {
            c.location_name = name;
            c._updated_ms = Date.now();
            _reprocessStatus.current = name;
            _reprocessStatus.charges_updated++;
          }
        } catch (e) { _reprocessStatus.errors++; }
        _reprocessStatus.done++;
        if (_reprocessStatus.done % 3 === 0) _broadcastReprocess();
      }
      if (_reprocessStatus.charges_updated > 0) scheduleChargesFlush();
      _broadcastReprocess();
      broadcast('reprocess_done', _reprocessStatus);
      console.log(`✓ Reprocess: trips=${_reprocessStatus.trips_updated} charges=${_reprocessStatus.charges_updated} errors=${_reprocessStatus.errors}`);
    } finally {
      _reprocessRunning = false;
    }
  })();
});

app.get('/api/admin/reprocess-places/status', (_req, res) => {
  res.json({ running: _reprocessRunning, status: _reprocessStatus });
});

// POST /api/admin/bulk-set-cost-by-location  { location, per_kwh, use_charger? }
// Aplica preço unitário fixo (R$/kWh) em todas as recargas de um local.
// Total = per_kwh * (charger_kwh quando use_charger=true e disponível,
// senão energy_kwh do carro). Útil pra retroceder histórico em locais com
// tarifa fixa conhecida.
app.post('/api/admin/bulk-set-cost-by-location', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  const location = (req.body?.location || '').toString().trim();
  const perKwh   = parseFloat(req.body?.per_kwh);
  const useCharger = req.body?.use_charger !== false;  // default true
  if (!location)          return res.status(400).json({ error: 'location obrigatório' });
  if (!(perKwh >= 0))     return res.status(400).json({ error: 'per_kwh inválido' });
  let updated = 0, skipped = 0;
  const details = [];
  for (const c of chargesArr) {
    if (c.location_name !== location) continue;
    const kwh = useCharger && c.charger_kwh > 0 ? c.charger_kwh
              : c.energy_kwh > 0 ? c.energy_kwh
              : 0;
    if (kwh <= 0) {
      skipped++;
      details.push({ ts: c.timestamp_ms, action: 'skipped', reason: 'sem kWh' });
      continue;
    }
    const total = +(kwh * perKwh).toFixed(2);
    c.cost_override = perKwh === 0
      ? { total: 0, perKwh: 0, free: true }
      : { total, perKwh: perKwh };
    c._updated_ms = Date.now();
    updated++;
    details.push({ ts: c.timestamp_ms, action: 'updated', kwh, total });
  }
  if (updated > 0) {
    scheduleChargesFlush();
    recomputeBatteryAvgPrice();
  }
  console.log(`[bulk-cost] "${location}" @ R$ ${perKwh}/kWh: ${updated} atualizadas, ${skipped} puladas`);
  res.json({ ok: true, location, per_kwh: perKwh, updated, skipped, details });
});

// POST /api/admin/recompute-trip-costs — recalcula o custo de TODAS as viagens
// usando o preço médio que valia NO MOMENTO de cada viagem (não o atual).
// body: { dry_run?: bool } — dry_run só conta quantas seriam afetadas
// O resultado vai pra `autoTrip.costRecomputed = { total, kwhPrice, gasPrice, ts }`,
// preservando o `cost` original. PWA usa o recomputed quando presente.
app.post('/api/admin/recompute-trip-costs', async (req, res) => {
  if (!adminCheckToken(req, res)) return;
  const dryRun = req.body?.dry_run === true;
  // Garante que battery_avg_after/tank_avg_after estão atualizados em todas
  // recargas/abastecimentos antes de iterar viagens.
  recomputeBatteryAvgPrice();
  recomputeTankAvgPrice();
  let updated = 0, skipped = 0, errors = 0;
  try {
    const files = fs.readdirSync(AUTOTRIPS_DIR).filter(f => f.endsWith('.json'));
    for (const f of files) {
      try {
        const filePath = path.join(AUTOTRIPS_DIR, f);
        const d = JSON.parse(fs.readFileSync(filePath, 'utf8'));
        const at = d.autoTrip;
        if (!at?.endMs) { skipped++; continue; }
        const netKwh = +at.netKwh || 0;
        const fuelL  = +at.fuelL  || 0;
        if (netKwh < 0.01 && fuelL < 0.01) { skipped++; continue; }
        // Preço usado: o que valia no FIM da viagem (consumiu durante o trajeto)
        const { kwhPrice, gasPrice } = priceMixAtMs(at.endMs);
        const total = +(netKwh * kwhPrice + fuelL * gasPrice).toFixed(2);
        at.costRecomputed = {
          total,
          kwhPrice: +kwhPrice.toFixed(4),
          gasPrice: +gasPrice.toFixed(3),
          ts:       Date.now(),
        };
        if (!dryRun) {
          fs.writeFileSync(filePath, JSON.stringify(d, null, 2));
          // Espelha em memória pra que /api/autotrips reflita imediato
          const mem = autoTripsArr.find(t => t.tripId === d.tripId);
          if (mem) mem.costRecomputed = at.costRecomputed;
        }
        updated++;
      } catch (_) { errors++; }
    }
  } catch (e) {
    return res.status(500).json({ error: 'Falha ao iterar autotrips: ' + e.message });
  }
  res.json({ ok: true, dry_run: dryRun, updated, skipped, errors });
});

// POST /api/admin/reset-tyre-baseline — zera o histórico de PSI dos pneus.
// Outras métricas (12V, autonomia, combustível) permanecem. Útil quando a
// média 14d ficou viciada com leituras em movimento (pneu quente).
app.post('/api/admin/reset-tyre-baseline', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  let cleared = 0;
  for (const snap of telemetryHistory) {
    for (const pos of ['fl', 'fr', 'rl', 'rr']) {
      if (snap[`tyre_${pos}`]) { snap[`tyre_${pos}`] = 0; cleared++; }
    }
  }
  try { fs.writeFileSync(TELEMETRY_LOG_FILE, JSON.stringify(telemetryHistory, null, 2)); } catch (_) {}
  // Limpa flags de "alerta já enviado hoje" pra que novos alertas legítimos
  // (a frio) voltem a disparar sem precisar passar a data
  for (const k of Object.keys(_anomalyAlerted)) {
    if (k.startsWith('tyre_')) delete _anomalyAlerted[k];
  }
  console.log(`✓ Baseline de pneus zerado (${cleared} valores limpos)`);
  res.json({ ok: true, cleared, entries: telemetryHistory.length });
});

// POST /api/charge-limit/refresh — pede pro APK reler o limite real do carro
// e re-publicar em ha/charge_limit/state. Útil quando o user muda direto no
// carro (sem usar o PWA) e o state do bridge ficou desatualizado.
app.post('/api/charge-limit/refresh', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  if (!mqttClient?.connected) return res.status(503).json({ error: 'MQTT offline' });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/refresh_charge_limit`, '1', { retain: false, qos: 1 }, err => {
    if (err) return res.status(500).json({ error: 'Falha ao publicar: ' + err.message });
    console.log('[charge-limit] refresh solicitado — aguardando APK re-publicar');
    res.json({ ok: true });
  });
});

// POST /api/charge-limit  { pct: 80 }  — publica cmd/charge_limit no MQTT
app.post('/api/charge-limit', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  const pct = parseInt(req.body?.pct);
  if (![50, 60, 70, 80, 90, 100].includes(pct))
    return res.status(400).json({ error: 'Valor inválido. Use 50, 60, 70, 80, 90 ou 100.' });
  if (!mqttClient?.connected)
    return res.status(503).json({ error: 'MQTT offline' });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/charge_limit`, pct.toString(), { retain: false, qos: 1 }, err => {
    if (err) return res.status(500).json({ error: 'Falha ao publicar no MQTT' });
    console.log(`[charge-limit] Enviando ${pct}% para o carro via MQTT`);
    res.json({ ok: true });
  });
});

app.post('/api/action/:name', async (req, res) => {
  const { name } = req.params;
  console.log(`[action] recebido name='${name}'`);
  const suffix = ACTION_TO_HA_BUTTON[name];
  if (!suffix) {
    console.warn(`[action] ${name} REJEITADO: ação desconhecida`);
    return res.status(400).json({ error: 'ação desconhecida' });
  }
  if (!HA_URL || !HA_TOKEN) {
    console.warn(`[action] ${name} REJEITADO: HA não configurado`);
    return res.status(503).json({ error: 'HA não configurado' });
  }
  const entityId = `button.${GWM_TOPIC_PREFIX}_${suffix}`;
  try {
    const r = await fetch(`${HA_URL}/api/services/button/press`, {
      method:  'POST',
      headers: {
        Authorization: `Bearer ${HA_TOKEN}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ entity_id: entityId }),
    });
    if (!r.ok) {
      const txt = await r.text().catch(() => '');
      console.error(`[action] ${name} → ${entityId} HTTP ${r.status} ${txt.slice(0, 200)}`);
      return res.status(502).json({ error: `HA HTTP ${r.status}` });
    }
    console.log(`[action] ${name} → ${entityId} OK`);
    res.json({ ok: true });
  } catch (e) {
    console.error(`[action] ${name} erro: ${e.message}`);
    res.status(502).json({ error: 'falha ao chamar HA' });
  }
});

// ── HVAC commands ────────────────────────────────────────────────────────────
// Publica em `${MQTT_PREFIX}/cmd/hvac/<control>` — o APK escuta e usa
// CarDataManager.requestSetting() pra escrever no barramento via Shizuku.
// Cada controle tem range/tipo validados aqui antes do publish pra evitar
// que valores fora de faixa cheguem no carro.
const HVAC_CONTROLS = {
  driver_temp:    { type: 'float', min: 16, max: 32, step: 0.5 },
  passenger_temp: { type: 'float', min: 16, max: 32, step: 0.5 },
  fan_speed:      { type: 'int',   min: 0,  max: 7 },
  sync:           { type: 'bool' },
  auto:           { type: 'bool' },
  cycle_mode:     { type: 'int',   min: 0,  max: 1 },
  seat_vent_drv:  { type: 'int',   min: 0,  max: 3 },
  seat_vent_pass: { type: 'int',   min: 0,  max: 3 },
  // Liga/desliga o compressor do AC (não só o fan). Mapeia para
  // `car.hvac.ac_enable` no barramento via Shizuku. Usar junto com fan_speed
  // pra garantir que liga o AC e não só sopra ar.
  ac_enable:      { type: 'bool' },
};

// ── HF mode (alta frequência sob demanda) ─────────────────────────────────
// PWA chama este endpoint quando entra na aba cluster/conforto pra forçar o
// APK a publicar a 250ms em vez do intervalo configurado (5s default).
// Heartbeat: PWA bate a cada 5s. Se passar 10s sem chamada, o watchdog
// publica '0' automaticamente — evita ficar travado em HF se o PWA crashar.
let _hfModeActive = false;
let _hfLastBeatMs = 0;
// 15s (antes 10s): PWA bate heartbeat a cada 3s. Margem grande pra cobrir
// throttle de timer do iOS Safari e variação de rede. Sintoma do timeout
// curto era Drive "congelar" alguns segundos enquanto HF desligava sozinho.
const HF_HEARTBEAT_TIMEOUT_MS = 15_000;
function _publishHfMode(active) {
  if (!mqttClient?.connected) return;
  mqttClient.publish(`${MQTT_PREFIX}/cmd/hf_mode`, active ? '1' : '0', { qos: 1, retain: false });
}
setInterval(() => {
  if (_hfModeActive && Date.now() - _hfLastBeatMs > HF_HEARTBEAT_TIMEOUT_MS) {
    console.log('[hf_mode] heartbeat expirou — desligando');
    _hfModeActive = false;
    _publishHfMode(false);
  }
}, 2000);
app.post('/api/hf_mode', (req, res) => {
  const active = req.body?.active === true;
  _hfLastBeatMs = Date.now();
  if (active !== _hfModeActive) {
    _hfModeActive = active;
    _publishHfMode(active);
    console.log(`[hf_mode] ${active ? 'ON' : 'OFF'}`);
  }
  res.json({ ok: true, active: _hfModeActive });
});

app.post('/api/hvac/:control', (req, res) => {
  const { control } = req.params;
  const spec = HVAC_CONTROLS[control];
  if (!spec) return res.status(400).json({ error: 'controle desconhecido' });
  if (!mqttClient?.connected) return res.status(503).json({ error: 'MQTT offline' });

  let raw = req.body?.value;
  if (raw === undefined || raw === null) return res.status(400).json({ error: 'value ausente' });

  let normalized;
  if (spec.type === 'bool') {
    normalized = (raw === true || raw === 1 || raw === '1' || raw === 'on' || raw === 'true') ? '1' : '0';
  } else if (spec.type === 'int') {
    const n = parseInt(raw, 10);
    if (Number.isNaN(n) || n < spec.min || n > spec.max)
      return res.status(400).json({ error: `valor inválido (esperado int ${spec.min}..${spec.max})` });
    normalized = String(n);
  } else {  // float
    let n = parseFloat(raw);
    if (Number.isNaN(n) || n < spec.min || n > spec.max)
      return res.status(400).json({ error: `valor inválido (esperado float ${spec.min}..${spec.max})` });
    if (spec.step) n = Math.round(n / spec.step) * spec.step;
    normalized = n.toFixed(1);
  }

  console.log(`[hvac] ${control} = '${normalized}'`);
  mqttClient.publish(`${MQTT_PREFIX}/cmd/hvac/${control}`, normalized, { qos: 1, retain: false }, err => {
    if (err) return res.status(500).json({ error: 'falha ao publicar' });
    res.json({ ok: true, value: normalized });
  });
});

app.get('/api/events', requireAuth, (req, res) => {
  const since = parseInt(req.query.since || '0', 10);
  let result  = since > 0 ? eventsLog.filter(e => e.ts > since) : eventsLog;
  res.json(result.slice(0, 1000));
});

// ── WebSocket ─────────────────────────────────────────────────────────────────

const clients       = new Set();
const SERVER_START_AT = Date.now();   // timestamp único por processo

function _handleWsConnection(ws, req) {
  // Verificação de token via query string: /ws?token=...
  if (BRIDGE_TOKEN_HASH) {
    const url   = new URL(req.url, 'http://localhost');
    const token = url.searchParams.get('token') || '';
    const wsValid = token === BRIDGE_TOKEN_HASH || sha256hex(token) === BRIDGE_TOKEN_HASH;
    if (!wsValid) {
      ws.send(JSON.stringify({ type: 'AUTH_ERROR' }));
      ws.close(4001, 'unauthorized');
      return;
    }
  }
  clients.add(ws);
  ws.isAlive = true;
  ws.on('pong', () => { ws.isAlive = true; });
  ws.send(JSON.stringify({ type: 'full_state', data: state, startedAt: SERVER_START_AT }));
  ws.on('close', () => clients.delete(ws));
  ws.on('error', () => clients.delete(ws));
}

const wss = new WebSocketServer({ server, path: '/ws' });
wss.on('connection', _handleWsConnection);

// WSS no servidor HTTPS (mesmos clientes e handlers)
if (httpsServer) {
  const wssHttps = new WebSocketServer({ server: httpsServer, path: '/ws' });
  wssHttps.on('connection', _handleWsConnection);
}

// ── WebSocket heartbeat (iOS Safari fecha silenciosamente conexões idle) ────────
setInterval(() => {
  for (const ws of clients) {
    if (ws.isAlive === false) { ws.terminate(); continue; }
    ws.isAlive = false;
    ws.ping();
  }
}, 25000);

function broadcast(type, data) {
  const msg = JSON.stringify({ type, data });
  for (const ws of clients) {
    if (ws.readyState === WebSocket.OPEN) ws.send(msg);
  }
}

// Coalesce de updates de state: o APK manda ~10 tópicos por snapshot (speed,
// RPM, soc, doors, etc). Sem coalesce, o PWA recebia 10 'update' messages
// quase simultâneos por snapshot — flood ineficiente. Agrupa numa janela de
// 16ms (1 frame a 60fps): múltiplas mensagens MQTT viram 1 broadcast WS.
// Mantém latência ~imperceptível e reduz tráfego/CPU do PWA significativamente.
let _stateBroadcastTimer = null;
function scheduleStateBroadcast() {
  if (_stateBroadcastTimer) return;
  _stateBroadcastTimer = setTimeout(() => {
    _stateBroadcastTimer = null;
    broadcast('update', state);
  }, 16);
}

// ── MQTT ──────────────────────────────────────────────────────────────────────

const mqttOptions = {
  port:           MQTT_PORT,
  clientId:       `ecotrip-bridge-${Date.now()}`,
  clean:          true,
  reconnectPeriod: 5000,
};
if (MQTT_USER) { mqttOptions.username = MQTT_USER; mqttOptions.password = MQTT_PASS; }

// Recalcula médios de tanque/bateria a partir dos JSONs já carregados (refuels + charges)
recomputeTankAvgPrice();
recomputeBatteryAvgPrice();
console.log(`✓ Preço médio tanque: R$ ${state.tank_avg_price_per_l.toFixed(2)}/L · bateria: R$ ${state.battery_avg_price_per_kwh.toFixed(2)}/kWh`);

const mqttClient = mqtt.connect(MQTT_HOST, mqttOptions);

mqttClient.on('connect', () => {
  console.log(`✓ MQTT conectado: ${MQTT_HOST} (prefix: ${MQTT_PREFIX})`);
  mqttClient.subscribe(`${MQTT_PREFIX}/#`, { qos: 1 });
  // Reset cache de publish pra forçar republicação dos preços ao reconectar
  _lastPublishedGas = null; _lastPublishedKwh = null;
  publishPricesToCar();
  // Subscribe nos tópicos da integração GWM Brasil — body/lock/AC/etc. vêm
  // direto da fonte oficial via cloud, sem ruído do barramento do app.
  mqttClient.subscribe(`${GWM_TOPIC_PREFIX}/+/state`, { qos: 1 });
  console.log(`✓ Subscribed em ${GWM_TOPIC_PREFIX}/+/state (integração HA)`);
  // A integração não publica esses tópicos com retain — broker fica sem o
  // estado atual ao subscribe. Puxamos via REST do HA no boot pra popular.
  fetchInitialStateFromHA();
});

mqttClient.on('error',      (err) => console.error('MQTT erro:', err.message));
mqttClient.on('reconnect',  ()    => console.log('MQTT reconectando...'));
mqttClient.on('disconnect', ()    => console.log('MQTT desconectado'));

// ─── Modo Diagnóstico (debug) ─────────────────────────────────────────────
// APK publica TODAS as constantes do CarConstants.kt em haval/ecotrip/diag/<key>
// quando habilitado via cmd/diag. Bridge mantém snapshot em memória + log em
// disco (rotacionado), broadcast pelo WS (msg type=diag_update) e expõe
// endpoints REST.
const DIAG_FILE      = path.join(__dirname, 'diag_state.json');
const DIAG_LOG_FILE  = path.join(__dirname, 'diag_log.json');
const DIAG_LOG_MAX   = 5000;  // rotação por linhas
let diagState        = { enabled: false, interval_sec: 5, values: {}, last_update_ms: 0 };
let diagLog          = [];
let diagEvents       = [];  // últimos N eventos de comando (envio/ack/erro)
const DIAG_EVENTS_MAX = 100;

function _pushDiagEvent(ev) {
  ev.ts = ev.ts || Date.now();
  diagEvents.push(ev);
  if (diagEvents.length > DIAG_EVENTS_MAX) diagEvents = diagEvents.slice(-DIAG_EVENTS_MAX);
  const wsMsg = JSON.stringify({ type: 'diag_event', data: ev });
  for (const c of clients) {
    try { c.readyState === 1 && c.send(wsMsg); } catch (_) {}
  }
  console.log(`[diag-event] ${ev.type} ${JSON.stringify(ev)}`);
}
try {
  if (fs.existsSync(DIAG_FILE)) diagState = { ...diagState, ...JSON.parse(fs.readFileSync(DIAG_FILE, 'utf8')) };
  if (fs.existsSync(DIAG_LOG_FILE)) diagLog = JSON.parse(fs.readFileSync(DIAG_LOG_FILE, 'utf8')) || [];
} catch (_) {}
let _diagSaveTimer = null;
function _saveDiagState() {
  if (_diagSaveTimer) return;
  _diagSaveTimer = setTimeout(() => {
    _diagSaveTimer = null;
    try { fs.writeFileSync(DIAG_FILE, JSON.stringify(diagState, null, 2)); } catch (_) {}
    try { fs.writeFileSync(DIAG_LOG_FILE, JSON.stringify(diagLog.slice(-DIAG_LOG_MAX))); } catch (_) {}
  }, 2000);
}
function handleDiagMessage(key, raw) {
  let value = raw;
  // tenta parse JSON pra valores compostos; senão mantém string
  if (raw && (raw.startsWith('{') || raw.startsWith('['))) {
    try { value = JSON.parse(raw); } catch (_) {}
  }
  const ts = Date.now();
  diagState.values[key] = { value, ts };
  diagState.last_update_ms = ts;
  diagLog.push({ ts, key, value });
  if (diagLog.length > DIAG_LOG_MAX) diagLog = diagLog.slice(-DIAG_LOG_MAX);
  _saveDiagState();
  // Broadcast pelo WS em tempo real
  const msg = JSON.stringify({ type: 'diag_update', data: { key, value, ts } });
  for (const c of clients) {
    try { c.readyState === 1 && c.send(msg); } catch (_) {}
  }
}

mqttClient.on('message', (topic, payload, packet) => {
  const value      = payload.toString().trim();
  const isRetained = !!(packet && packet.retain);

  // Dispatcher: tópicos da integração GWM Brasil vão pro handler dedicado;
  // outros caem no handler legado do app.
  if (topic.startsWith(GWM_TOPIC_PREFIX + '/') && topic.endsWith('/state')) {
    const id = topic.slice(GWM_TOPIC_PREFIX.length + 1, topic.length - '/state'.length);
    applyGwmEntity(id, value, isRetained);
  } else if (topic === MQTT_PREFIX + '/diag/state') {
    // APK confirma estado real do modo diagnóstico — single source of truth
    try {
      const o = JSON.parse(value);
      const prevEnabled = diagState.enabled;
      diagState.enabled = !!o.enabled;
      if (o.interval_sec) diagState.interval_sec = +o.interval_sec;
      diagState.last_state_from_apk_ms = Date.now();
      // Quando o APK confirma desativação, limpa snapshot do servidor
      // (mas o PWA mantém sua cópia local — vide localStorage no view-config)
      if (prevEnabled && !diagState.enabled) diagState.values = {};
      _saveDiagState();
      _pushDiagEvent({
        type: 'state_ack',
        enabled: !!o.enabled,
        interval_sec: o.interval_sec || diagState.interval_sec,
        source: o.source || null,
        applied_at: o.applied_at || null,
      });
      const wsMsg = JSON.stringify({
        type: 'diag_state',
        data: { enabled: !!o.enabled, interval_sec: o.interval_sec || diagState.interval_sec, source: o.source || null }
      });
      for (const c of clients) {
        try { c.readyState === 1 && c.send(wsMsg); } catch (_) {}
      }
    } catch (e) {
      console.warn(`[diag] payload de state inválido: ${value} (${e.message})`);
    }
  } else if (topic.startsWith(MQTT_PREFIX + '/diag/')) {
    // Modo diagnóstico: APK publica em diag/<constant_name>
    const key = topic.slice((MQTT_PREFIX + '/diag/').length);
    handleDiagMessage(key, value);
  } else if (topic.startsWith(MQTT_PREFIX + '/diag_ack/')) {
    // Resposta do APK ao set: { ok, error?, applied? }
    const key = topic.slice((MQTT_PREFIX + '/diag_ack/').length);
    let ack = { raw: value };
    try { ack = JSON.parse(value); } catch (_) {}
    const msg = JSON.stringify({ type: 'diag_ack', data: { key, ...ack, ts: Date.now() } });
    for (const c of clients) {
      try { c.readyState === 1 && c.send(msg); } catch (_) {}
    }
    _pushDiagEvent({ type: 'set_ack', key, ok: !!ack.ok, applied: ack.applied, error: ack.error, requested: ack.requested });
    console.log(`[diag] ack ${key}: ${value}`);
  } else {
    const key = topic.startsWith(MQTT_PREFIX + '/')
      ? topic.slice(MQTT_PREFIX.length + 1)
      : topic;
    applyMqttMessage(key, value, isRetained);
  }
  scheduleStateBroadcast();
});

// ── Roteamento dos tópicos MQTT → state ──────────────────────────────────────

function num(v) { const n = parseFloat(v); return isNaN(n) ? 0 : n; }

// Mapeamento: tópico MQTT da integração GWM Brasil → campo no state do bridge.
// A integração GWM publica direto em `gwmbrasil_<chassi>/<id_numerico>/state` com
// payloads "1"/"0" pra binários e numéricos diretos pros sensores. Mais confiável
// que ler pelo app (sem ruído de sensor do barramento direto).
const GWM_TOPIC_MAP = {
  // Body (binary "1"=aberto/destrancado/on, "0"=fechado/trancado/off)
  '2206001': 'door_trunk',
  '2206002': 'door_fl',
  '2206003': 'door_rl',
  '2206004': 'door_fr',
  '2206005': 'door_rr',
  '2208001': 'lock_state',
  '2202001': 'ac_state',
  // Vidros (cru "1"=fechado, demais valores=aberto)
  '2210001': 'window_fl',
  '2210002': 'window_fr',
  '2210003': 'window_rl',
  '2210004': 'window_rr',
  // Sunroof (cru "3"=fechado, demais=aberto)
  '2210005': 'sunroof',
  // Sensores numéricos
  '2013021': 'soc_pct',
  '2013005': 'batt_12v_pct',
  '2103010': 'odometer_km',
  '2101001': 'tyre_pressure_fl',
  '2101002': 'tyre_pressure_fr',
  '2101003': 'tyre_pressure_rl',
  '2101004': 'tyre_pressure_rr',
  '2101005': 'tyre_temp_fl',
  '2101006': 'tyre_temp_fr',
  '2101007': 'tyre_temp_rl',
  '2101008': 'tyre_temp_rr',
  '2011501': 'autonomy_ev_km',
  '2011007': 'autonomy_ice_km',
  '2017002': 'fuel_l',           // nível de combustível em litros (direto da GWM)
  // Charging (HA mapping: 0=Desconectado, 1=Carregando, 2=Programado, 3=Finalizado, 5=Aguardando)
  '2041142': 'charging_state_raw',
  '2013022': 'charge_remaining_min',
  // Texto / outros
  'hyengsts':       'engine_state',       // "0"=off, "1"=on (mesma convenção do app)
  'endereco_atual': 'current_address',
  'status_message': 'car_status_message', // alertas tipo "NO_ALERTS" ou códigos
};

/** Converte código numérico do charging_state do HA pro texto que a PWA espera. */
function mapChargingStateText(raw) {
  switch (String(raw).trim()) {
    case '0': return 'Desconectado';
    case '1': return 'Carregando';
    case '2': return 'Programado';
    case '3': return 'Finalizado';
    case '5': return 'Aguardando liberação';
    default:  return 'Desconhecido';
  }
}

/**
 * Mapeia uma entidade HA (state via REST) pro handler GWM equivalente.
 * Converte estado HA ('on'/'off' p/ binary, valor cru p/ sensor) pro formato
 * MQTT esperado por applyGwmEntity ('1'/'0' p/ binary, valor cru p/ sensor),
 * e despacha. Usado SÓ no boot do bridge — runtime usa MQTT.
 */
function applyHaEntityState(entityId, haState) {
  if (haState === 'unknown' || haState === 'unavailable' || haState == null) return false;
  const c = GWM_CHASSI.toLowerCase();
  // (entityId → { gwmId, isBinary }) — derivado dos discovery configs do HA.
  const m = {
    // Binary sensors (HA state 'on'/'off' → MQTT '1'/'0')
    [`binary_sensor.gwmbrasil_${c}_estado_da_trava`]:                     { id: '2208001', isBinary: true },
    [`binary_sensor.gwmbrasil_${c}_porta_malas`]:                         { id: '2206001', isBinary: true },
    [`binary_sensor.gwmbrasil_${c}_porta_dianteira_esquerda`]:            { id: '2206002', isBinary: true },
    [`binary_sensor.gwmbrasil_${c}_porta_traseira_esquerda`]:             { id: '2206003', isBinary: true },
    [`binary_sensor.gwmbrasil_${c}_porta_dianteira_direita`]:             { id: '2206004', isBinary: true },
    [`binary_sensor.gwmbrasil_${c}_porta_traseira_direita`]:              { id: '2206005', isBinary: true },
    [`binary_sensor.gwmbrasil_${c}_estado_do_ar_condicionado`]:           { id: '2202001', isBinary: true },
    // Sensores numéricos (state HA = valor cru)
    [`sensor.gwmbrasil_${c}_vidro_dianteiro_esquerdo`]:                   { id: '2210001' },
    [`sensor.gwmbrasil_${c}_vidro_dianteiro_direito`]:                    { id: '2210002' },
    [`sensor.gwmbrasil_${c}_vidro_traseiro_esquerdo`]:                    { id: '2210003' },
    [`sensor.gwmbrasil_${c}_vidro_traseiro_direito`]:                     { id: '2210004' },
    [`sensor.gwmbrasil_${c}_posicao_do_teto_solar`]:                      { id: '2210005' },
    [`sensor.gwmbrasil_${c}_estado_do_motor`]:                            { id: 'hyengsts' },
    [`sensor.gwmbrasil_${c}_estado_de_carga_soc`]:                        { id: '2013021' },
    [`sensor.gwmbrasil_${c}_estado_de_carga_12v`]:                        { id: '2013005' },
    [`sensor.gwmbrasil_${c}_quilometragem_total`]:                        { id: '2103010' },
    [`sensor.gwmbrasil_${c}_pressao_do_pneu_dianteiro_esquerdo`]:         { id: '2101001' },
    [`sensor.gwmbrasil_${c}_pressao_do_pneu_dianteiro_direito`]:          { id: '2101002' },
    [`sensor.gwmbrasil_${c}_pressao_do_pneu_traseiro_esquerdo`]:          { id: '2101003' },
    [`sensor.gwmbrasil_${c}_pressao_do_pneu_traseiro_direito`]:           { id: '2101004' },
    [`sensor.gwmbrasil_${c}_temperatura_do_pneu_dianteiro_esquerdo`]:     { id: '2101005' },
    [`sensor.gwmbrasil_${c}_temperatura_do_pneu_dianteiro_direito`]:      { id: '2101006' },
    [`sensor.gwmbrasil_${c}_temperatura_do_pneu_traseiro_esquerdo`]:      { id: '2101007' },
    [`sensor.gwmbrasil_${c}_temperatura_do_pneu_traseiro_direito`]:       { id: '2101008' },
    [`sensor.gwmbrasil_${c}_autonomia_ev`]:                               { id: '2011501' },
    [`sensor.gwmbrasil_${c}_autonomia_combustao`]:                        { id: '2011007' },
    [`sensor.gwmbrasil_${c}_estado_da_carga`]:                            { id: '2041142' },
    [`sensor.gwmbrasil_${c}_tempo_de_carga`]:                             { id: '2013022' },
    [`sensor.gwmbrasil_${c}_endereco_atual`]:                             { id: 'endereco_atual' },
    [`sensor.gwmbrasil_${c}_status_message`]:                             { id: 'status_message' },
  };
  const entry = m[entityId];
  if (!entry) return false;
  const mqttValue = entry.isBinary
    ? (haState === 'on' ? '1' : '0')
    : String(haState);
  applyGwmEntity(entry.id, mqttValue, false);
  return true;
}

/**
 * Fetch inicial via HA REST — popula estado das entidades GWM que a integração
 * não publica com retain (doors, lock, windows, etc). Chamado uma vez no boot.
 * Runtime usa MQTT pra mudanças (integração publica live quando estado muda).
 */
async function fetchInitialStateFromHA() {
  if (!HA_URL || !HA_TOKEN) {
    console.log('[ha-init] HA_URL/HA_TOKEN não configurados — pulando initial fetch');
    return;
  }
  try {
    const res = await fetch(`${HA_URL}/api/states`, {
      headers: { Authorization: `Bearer ${HA_TOKEN}` },
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const states = await res.json();
    let applied = 0;
    for (const ent of states) {
      if (applyHaEntityState(ent.entity_id, ent.state)) applied++;
    }
    console.log(`✓ [ha-init] ${applied} entidades populadas via REST HA`);
  } catch (e) {
    console.error(`[ha-init] erro: ${e.message}`);
  }
}

// Chaves que migraram pro HA — handlers do app são ignorados aqui pra evitar
// que dados ruidosos do app (via Shizuku/CarDataManager) sobrescrevam o estado
// confiável que vem do HA.
const MIGRATED_TO_HA = new Set([
  'door_fl', 'door_fr', 'door_rl', 'door_rr', 'door_trunk',
  'lock_state', 'ac_state',
  'window_fl', 'window_fr', 'window_rl', 'window_rr',
  'sunroof', 'engine_state',
  // Sensores numéricos passivos — HA é mais confiável
  'odometer_km', 'batt_12v_pct',
  // Charging state agora vem do HA com mapeamento texto
  'charging_state', 'charge_remaining_min',
]);

const GWM_BODY_BINARY = new Set([
  'door_trunk', 'door_fl', 'door_fr', 'door_rl', 'door_rr', 'lock_state', 'ac_state',
]);

/**
 * Single source of truth pro handler de transição de charging_state.
 * Chamado por DOIS lugares:
 *   - applyGwmEntity (caminho HA) quando `charging_state_raw` chega — caminho ATUAL
 *   - applyMqttMessage (caminho legado APK) — só dispara se key sair de MIGRATED_TO_HA
 * Antes, a lógica estava SÓ no segundo lugar e parou de rodar após a migração:
 *   - events.json nunca recebia charge_start/charge_end
 *   - sendPush('⚡ Recarga iniciada' / '✅ Recarga concluída') jamais era chamado
 *   - chargeStartTimer (30s pra potência estabilizar) nunca disparava
 *   - _chargeTempSamples ficava sempre vazio → avg_temp_c null nos charges
 */
function handleChargingStateTransition(value, isRetained) {
  const prev = prevChargingState;
  state.charging_state = value;
  prevChargingState    = value;

  // Detecta transição REAL: prev definido e diferente do novo valor.
  // No primeiro boot do bridge, prev é vazio → pula (não há transição).
  // Em qualquer outra mudança (retained ou não), registra evento no log;
  // só o push de notificação é gateado por !isRetained (pra não notificar
  // o user no boot quando o broker reenvia 'Carregando' antigo).
  const realTransition = prev && prev !== value;
  if (!realTransition) return;

  if (value === 'Carregando') {
    _chargeTempSamples = [];   // inicia nova coleta de temperatura
    chargeSessionStartMs = Date.now();
    chargeStartSoc = state.soc_pct || 0;
    state.charge_start_soc_pct       = chargeStartSoc;
    state.charge_session_start_ms    = chargeSessionStartMs;
    state.charge_max_power_kw        = 0;
    state.charge_avg_power_kw        = 0;
    state.charge_session_kwh_at_init = 0;
    addEvent('charge_start', `Recarga iniciada · SOC: ${chargeStartSoc.toFixed(0)}%`);
    if (!isRetained) {
      // Aguarda 30s para a potência estabilizar antes de notificar
      if (chargeStartTimer) clearTimeout(chargeStartTimer);
      chargeStartTimer = setTimeout(() => {
        chargeStartTimer = null;
        const pwr = state.charge_power_kw || 0;
        const rem = state.charge_remaining_min || 0;
        const remStr = rem > 0
          ? (rem > 59 ? `${Math.floor(rem / 60)}h ${rem % 60}min` : `${rem} min`)
          : '~?';
        sendPush('⚡ Recarga iniciada', `${pwr.toFixed(1)} kW · tempo restante: ${remStr}`, 'charge_start');
      }, 30000);
    }
  } else if (prev === 'Carregando') {
    if (chargeStartTimer) { clearTimeout(chargeStartTimer); chargeStartTimer = null; }
    chargeEndingNotifSent = false;  // reset para próxima sessão
    const endSoc = state.soc_pct || 0;
    addEvent('charge_end', `Recarga concluída · SOC: ${chargeStartSoc.toFixed(0)}% → ${endSoc.toFixed(0)}%`);
    // Calcula temperatura média da sessão encerrada
    if (_chargeTempSamples.length > 0) {
      const avg = _chargeTempSamples.reduce((a, b) => a + b, 0) / _chargeTempSamples.length;
      _lastChargeAvgTemp = Math.round(avg * 10) / 10;
      console.log(`🌡 Temp média recarga: ${_lastChargeAvgTemp}°C (${_chargeTempSamples.length} amostras)`);
    }
    _chargeTempSamples = [];
    if (!isRetained && value === 'Finalizado') {
      const kwh = state.charge_session_kwh || 0;
      const durSec = chargeSessionStartMs > 0
        ? Math.round((Date.now() - chargeSessionStartMs) / 1000)
        : 0;
      const durStr = durSec > 0
        ? (durSec >= 3600
          ? `${Math.floor(durSec / 3600)}h ${Math.floor((durSec % 3600) / 60)}min`
          : `${Math.floor(durSec / 60)}min`)
        : null;
      const avgKw = (durSec > 0 && kwh > 0.05)
        ? (kwh / (durSec / 3600))
        : null;
      const parts = [];
      if (kwh > 0.05) parts.push(`${kwh.toFixed(2)} kWh`);
      if (durStr)     parts.push(durStr);
      if (avgKw)      parts.push(`${avgKw.toFixed(1)} kW médios`);
      sendPush('✅ Recarga concluída', parts.length ? parts.join(' · ') : 'Sessão encerrada', 'charge_end');
      // Encerra a "live notification" (substitui pela final, agora com som)
      stopChargeLiveTimer();
      sendChargeLiveUpdate(true /* final */);
      chargeSessionStartMs = 0;
      state.charge_session_start_ms    = 0;
      state.charge_session_kwh_at_init = 0;
    }
  }
  // Inicia o ciclo de "live notification" quando começa a carregar
  if (value === 'Carregando' && !isRetained) startChargeLiveTimer();
}

// ── Live notification durante recarga ─────────────────────────────────────────
// Notif fixa no lock screen com tag 'charge-live'. Atualiza a cada 60s ou
// quando SOC/potência mudam significativamente. Cada update substitui a
// notif anterior pelo `tag` igual. Silent = true → atualiza sem ding/vibrar.
let _chargeLiveTimer = null;
let _chargeLiveLast  = { soc: -1, pwr: -1, rem: -1, ts: 0 };
const CHARGE_LIVE_TAG = 'charge-live';

function _fmtChargeLiveBody(stateObj) {
  const soc = +stateObj.soc_pct || 0;
  const pwr = +stateObj.charge_power_kw || 0;
  const rem = +stateObj.charge_remaining_min || 0;
  const kwh = +stateObj.charge_session_kwh || 0;
  const parts = [];
  parts.push(`SOC ${soc.toFixed(0)}%`);
  if (pwr > 0.1) parts.push(`${pwr.toFixed(1)} kW`);
  if (kwh > 0.05) parts.push(`${kwh.toFixed(1)} kWh`);
  if (rem > 0) {
    const remStr = rem >= 60 ? `${Math.floor(rem/60)}h${(rem%60).toString().padStart(2,'0')}` : `${rem} min`;
    parts.push(`~${remStr}`);
  }
  return parts.join(' · ');
}

function sendChargeLiveUpdate(isFinal = false) {
  // Só dispara se o estado é Carregando (ou se é a notif final)
  const charging = state.charging_state === 'Carregando';
  if (!charging && !isFinal) return;
  const soc = +state.soc_pct || 0;
  const pwr = +state.charge_power_kw || 0;
  const rem = +state.charge_remaining_min || 0;
  const now = Date.now();
  if (!isFinal) {
    // Throttle: só envia se mudou SOC≥1%, potência≥0.5kW, ou 60s desde o último
    const dSoc = Math.abs(soc - _chargeLiveLast.soc);
    const dPwr = Math.abs(pwr - _chargeLiveLast.pwr);
    const dT   = now - _chargeLiveLast.ts;
    const significant = dSoc >= 1 || dPwr >= 0.5 || dT >= 60_000;
    if (!significant) return;
  }
  _chargeLiveLast = { soc, pwr, rem, ts: now };
  const title = isFinal ? '✅ Recarga concluída' : '⚡ Carregando…';
  const body  = isFinal
    ? _fmtChargeLiveBody(state) || 'Sessão encerrada'
    : _fmtChargeLiveBody(state);
  sendPush(title, body, 'charge_live', {
    tag: CHARGE_LIVE_TAG,
    silent: !isFinal,                // updates não fazem barulho; a final sim
    renotify: isFinal,
    skipHistory: !isFinal,           // updates ao vivo não entram na central de notif
  });
  // Live Activity (iOS) via APNs — manda o mesmo content-state pra todos os
  // pushTokens registrados pelo app companion. No-op se APNS_ENABLED=false.
  if (apnsLive.tokenCount() > 0) {
    apnsLive.pushUpdate({
      soc, powerKw: pwr,
      sessionKwh: +state.charge_session_kwh || 0,
      remainingMin: Math.max(0, Math.round(rem)),
      charging: !isFinal,
      updatedAtMs: now,
    }, { isFinal }).catch(err => console.warn('[apns] push falhou:', err.message));
  }
}

// ── Endpoints da Live Activity (iOS companion) ────────────────────────────────
// O app companion swift chama esses dois endpoints; o bridge usa o pushToken
// retornado pra disparar updates da Live Activity via APNs HTTP/2.
app.post('/api/activity/start', (req, res) => {
  const { push_token, activity_id } = req.body || {};
  if (!push_token || !activity_id) return res.status(400).json({ error: 'push_token e activity_id obrigatórios' });
  apnsLive.registerToken(String(activity_id), String(push_token));
  res.json({ ok: true, registered: apnsLive.tokenCount() });
});
app.post('/api/activity/stop', (req, res) => {
  const { activity_id } = req.body || {};
  if (activity_id) apnsLive.unregisterToken(String(activity_id));
  res.json({ ok: true, registered: apnsLive.tokenCount() });
});

function startChargeLiveTimer() {
  if (_chargeLiveTimer) return;
  _chargeLiveLast = { soc: -1, pwr: -1, rem: -1, ts: 0 };
  // Aguarda 30s do início (potência estabilizar) antes da primeira live notif
  setTimeout(() => sendChargeLiveUpdate(false), 30_000);
  _chargeLiveTimer = setInterval(() => sendChargeLiveUpdate(false), 60_000);
}

function stopChargeLiveTimer() {
  if (_chargeLiveTimer) { clearInterval(_chargeLiveTimer); _chargeLiveTimer = null; }
}

/**
 * Processa mensagem da integração GWM Brasil (tópicos `gwmbrasil_<chassi>/.../state`).
 * Aplica conversão por tipo e dispara eventos quando há transição binária real.
 */
function applyGwmEntity(id, value, isRetained = false) {
  const field = GWM_TOPIC_MAP[id];
  if (!field) {
    console.log(`[gwm] id desconhecido='${id}' value='${value}' isRetained=${isRetained}`);
    return;
  }

  // ── Binary body (doors, lock, AC) ─────────────────────────────────────────
  if (GWM_BODY_BINARY.has(field)) {
    const norm = value === '1' ? 'on' : 'off';
    const prev = state[field];
    state[field] = norm;
    if (!isRetained && prev !== undefined && prev !== null && prev !== norm) {
      if (field === 'lock_state') {
        if (norm === 'on') addEvent('lock_open',  'Carro destrancado');
        else               addEvent('lock_close', 'Carro trancado');
      } else if (field === 'ac_state') {
        if (norm === 'on') addEvent('ac_on',  'Ar condicionado ligado');
        else               addEvent('ac_off', 'Ar condicionado desligado');
      } else if (field === 'door_trunk') {
        if (norm === 'on') {
          addEvent('trunk_open',  'Porta-malas aberta');
          sendPush('🧳 Porta-malas aberta', 'Verifique se está segura.', 'trunk_open');
        } else {
          addEvent('trunk_close', 'Porta-malas fechada');
          sendPush('🧳 Porta-malas fechada', 'Porta-malas foi fechada.', 'trunk_close');
        }
      } else {
        // door_fl/fr/rl/rr
        const side = field.slice(5);
        const label = DOOR_NAMES[side] || side.toUpperCase();
        if (norm === 'on') {
          addEvent('door_open',  `${label} aberta`);
          sendPush('🚪 Porta aberta', label, 'door_open');
        } else {
          addEvent('door_close', `${label} fechada`);
          sendPush('🚪 Porta fechada', label, 'door_close');
        }
      }
    }
    return;
  }

  // ── Vidros (cru "1"=fechado, demais=aberto) ───────────────────────────────
  if (field.startsWith('window_')) {
    const norm = value === '1' ? 'off' : 'on';
    const prev = state[field];
    state[field] = norm;
    if (!isRetained && prev !== undefined && prev !== null && prev !== norm) {
      const wside = field.slice(7);
      const label = WINDOW_NAMES[wside] || wside.toUpperCase();
      if (norm === 'on') addEvent('window_open',  `${label} aberto`);
      else               addEvent('window_close', `${label} fechado`);
    }
    return;
  }

  // ── Sunroof (cru "3"=fechado, demais=aberto) ──────────────────────────────
  if (field === 'sunroof') {
    const norm = value === '3' ? 'off' : 'on';
    const prev = state.sunroof;
    state.sunroof = norm;
    if (!isRetained && prev !== undefined && prev !== null && prev !== norm) {
      if (norm === 'on') addEvent('sunroof_open',  'Teto solar aberto');
      else               addEvent('sunroof_close', 'Teto solar fechado');
    }
    return;
  }

  // ── Engine state (cru "1"=ligado, "0"=desligado, mesma convenção do app) ─
  if (field === 'engine_state') {
    const prev = state.engine_state;
    state.engine_state = value;
    if (!isRetained && prev !== undefined && prev !== null && prev !== value) {
      if (value === '1') {
        addEvent('engine_on',  'Motor ligado');
        sendPush('🔑 Motor ligado',  'O veículo foi ligado.', 'engine_on');
        // Transição off→on: compara fuel atual com snapshot ao desligar
        checkRefuelOnEngineOn();
      } else if (value === '0') {
        addEvent('engine_off', 'Motor desligado');
        sendPush('🔑 Motor desligado', 'O veículo foi desligado.', 'engine_off');
        // Snapshot: fuel_l quando o motor desliga, comparado quando voltar a ligar
        _fuelLAtPark = +state.fuel_l || 0;
        _fuelParkTs  = Date.now();
      }
    }
    return;
  }

  // ── Address string (sem evento, só state) ─────────────────────────────────
  if (field === 'current_address') {
    state.current_address = value;
    return;
  }

  // ── Status message do carro (alertas/códigos) ─────────────────────────────
  if (field === 'car_status_message') {
    state.car_status_message = value;
    return;
  }

  // ── Charging state — converte número do HA pro texto que a PWA usa.
  // Delega a transição (events + push + temperatura média + chargeStartTimer)
  // pro handler único — sem isso, eventos de recarga param de ser registrados.
  if (field === 'charging_state_raw') {
    const txt = mapChargingStateText(value);
    handleChargingStateTransition(txt, isRetained);
    return;
  }

  // ── Sensores numéricos (soc, 12v, odo, pneus, autonomia, remaining_min) ──
  state[field] = num(value);
  if (field === 'odometer_km') checkMaintenanceAlerts();
}

function applyMqttMessage(key, value, isRetained = false) {
  state.last_update_ms = Date.now();

  // Body/lock/etc. migradas pra HA — ignora publishes do app pra essas chaves.
  // Bridge usa exclusivamente os tópicos da integração GWM Brasil (sem ruído).
  if (MIGRATED_TO_HA.has(key)) return;

  switch (key) {
    // Status
    case 'status':
      state.car_online = (value === 'online');
      break;
    case 'last_update':
      state.car_last_update = value;   // ISO timestamp publicado pelo Android (retain=true)
      break;
    case 'app_version': {
      const prevVer = state.car_app_version;
      state.car_app_version = value;
      // Notifica quando a versão muda (não na primeira leitura/retained)
      if (!isRetained && prevVer !== null && prevVer !== value) {
        sendPush('📱 App atualizado', `Nova versão: ${value}${prevVer ? ` (era ${prevVer})` : ''}`, 'app_update');
      }
      break;
    }

    // Sensores de estado (publicados pelo HA via automação)
    case 'status_message': state.status_message = value; break; // pipe-sep alerts
    case 'engine_state': {
      const prevEng = prevEngineState;
      state.engine_state = value;
      prevEngineState    = value;
      if (!isRetained && prevEng !== null && prevEng !== value) {
        if (value === '1') {
          addEvent('engine_on',  'Motor ligado');
          sendPush('🔑 Motor ligado',  'O veículo foi ligado.', 'engine_on');
        } else if (value === '0') {
          addEvent('engine_off', 'Motor desligado');
          sendPush('🔑 Motor desligado', 'O veículo foi desligado.', 'engine_off');
        }
      }
      break;
    }
    case 'lock_state': {
      // App publica "1" (destrancado) / "0" (trancado).
      // Formato: "valor" (legacy) ou "valor:ms_da_mudanca" (v5.11+).
      // Hysteresis 3s + voting filter Android-side (v5.11+) → defesa em camadas.
      const colonIdx = value.indexOf(':');
      const normRaw  = colonIdx >= 0 ? value.slice(0, colonIdx) : value;
      const realTs   = colonIdx >= 0 ? (parseInt(value.slice(colonIdx + 1), 10) || 0) : 0;
      const norm     = normRaw === '1' ? 'on' : 'off';
      if (isRetained) {
        state.lock_state = norm;
        prevLockState    = norm;
        break;
      }
      if (norm === _hystPending.lock_state) break;
      _hystPending.lock_state = norm;
      clearTimeout(_hystTimers.lock_state);
      _hystTimers.lock_state = setTimeout(() => {
        state.lock_state = norm;
        if (norm !== prevLockState) {
          prevLockState = norm;
          if (norm === 'on') addEvent('lock_open',  'Carro destrancado', realTs);
          else               addEvent('lock_close', 'Carro trancado',    realTs);
        }
      }, HYSTERESIS_MS);
      break;
    }
    case 'high_beam':    state.high_beam    = value; break;   // 'on' | 'off'
    case 'light_state':  state.light_state  = value; break;   // 'on' | 'off' (farol)
    case 'ac_state': {
      // App publica '1' (ligado) / '0' (desligado). Normaliza pra 'on'/'off'.
      // Hysteresis 15s — `car.hvac.ac_enable` reflete o ciclo do compressor no
      // HEV/PHEV (liga/desliga a cada ~10s pra eficiência), não o setting do
      // usuário. Sem isso o log enchia de eventos `ac_on`/`ac_off`.
      const norm = value === '1' ? 'on' : 'off';
      if (isRetained) {
        state.ac_state = norm;
        break;
      }
      if (norm === _hystPending.ac_state) break;
      _hystPending.ac_state = norm;
      clearTimeout(_hystTimers.ac_state);
      _hystTimers.ac_state = setTimeout(() => {
        const prevAc = state.ac_state;
        state.ac_state = norm;
        if (norm !== prevAc) {
          if (norm === 'on') addEvent('ac_on',  'Ar condicionado ligado');
          else               addEvent('ac_off', 'Ar condicionado desligado');
        }
      }, AC_HYSTERESIS_MS);
      break;
    }
    case 'hvac_cycle_mode': state.hvac_cycle_mode = value; break; // '0'=recirc interna, '1'=ar externo
    case 'seat_vent_drv':  state.seat_vent_drv  = value; break; // '0'..'3'
    case 'seat_vent_pass': state.seat_vent_pass = value; break; // '0'..'3'
    case 'hvac_driver_temp':    state.hvac_driver_temp    = value; break; // float °C
    case 'hvac_passenger_temp': state.hvac_passenger_temp = value; break; // float °C (pendente)
    case 'hvac_fan_speed':      state.hvac_fan_speed      = value; break; // int 0..N
    case 'hvac_sync_enable':    state.hvac_sync_enable    = value; break; // '0'|'1'
    case 'hvac_auto_enable':    state.hvac_auto_enable    = value; break; // '0'|'1'
    case 'hvac_ac_enable':      state.hvac_ac_enable      = value; break; // '0'|'1' — car.hvac.ac_enable
    case 'door_fl':
    case 'door_fr':
    case 'door_rl':
    case 'door_rr': {
      // App publica '1' (aberta) / '0' (fechada). Hysteresis 3s — sensor de porta
      // pode oscilar durante o ato de abrir/fechar (latch intermediário).
      const side  = key.slice(5);
      const norm  = value === '1' ? 'on' : 'off';
      if (isRetained) {
        state[key]           = norm;
        prevDoorStates[side] = norm;
        break;
      }
      if (norm === _hystPending[key]) break;
      _hystPending[key] = norm;
      clearTimeout(_hystTimers[key]);
      _hystTimers[key] = setTimeout(() => {
        state[key] = norm;
        if (norm !== prevDoorStates[side]) {
          prevDoorStates[side] = norm;
          const label = DOOR_NAMES[side] || side.toUpperCase();
          if (norm === 'on') {
            addEvent('door_open',  `${label} aberta`);
            sendPush('🚪 Porta aberta', label, 'door_open');
          } else {
            addEvent('door_close', `${label} fechada`);
            sendPush('🚪 Porta fechada', label, 'door_close');
          }
        }
      }, HYSTERESIS_MS);
      break;
    }
    case 'door_trunk': {
      // Mesmo padrão hysteresis 3s.
      const norm = value === '1' ? 'on' : 'off';
      if (isRetained) {
        state.door_trunk     = norm;
        prevDoorStates.trunk = norm;
        break;
      }
      if (norm === _hystPending.door_trunk) break;
      _hystPending.door_trunk = norm;
      clearTimeout(_hystTimers.door_trunk);
      _hystTimers.door_trunk = setTimeout(() => {
        state.door_trunk = norm;
        if (norm !== prevDoorStates.trunk) {
          prevDoorStates.trunk = norm;
          if (norm === 'on') {
            addEvent('trunk_open',  'Porta-malas aberta');
            sendPush('🧳 Porta-malas aberta', 'Verifique se está segura.', 'trunk_open');
          } else {
            addEvent('trunk_close', 'Porta-malas fechada');
            sendPush('🧳 Porta-malas fechada', 'Porta-malas foi fechada.', 'trunk_close');
          }
        }
      }, HYSTERESIS_MS);
      break;
    }
    case 'sunroof': {
      // App publica '1' (aberto) / '0' (fechado) já normalizado a partir de car.basic.sunroof_status.
      // Sensor de posição oscila — hysteresis de 3s evita spam no log.
      const norm = value === '1' ? 'on' : 'off';
      if (isRetained) {
        state.sunroof = norm;
        prevSunroof   = norm;
        break;
      }
      if (norm === _hystPending.sunroof) break;  // já agendado pra esse valor
      _hystPending.sunroof = norm;
      clearTimeout(_hystTimers.sunroof);
      _hystTimers.sunroof = setTimeout(() => {
        state.sunroof = norm;
        if (norm !== prevSunroof) {
          prevSunroof = norm;
          if (norm === 'on') addEvent('sunroof_open',  'Teto solar aberto');
          else               addEvent('sunroof_close', 'Teto solar fechado');
        }
      }, HYSTERESIS_MS);
      break;
    }
    case 'window_fl':
    case 'window_fr':
    case 'window_rl':
    case 'window_rr': {
      // App publica '1' (aberto) / '0' (fechado) com voting filter.
      // Formato: "valor" (legacy) ou "valor:ms_da_mudanca" (v5.x+ com voting).
      // Aceita ambos pra backward compat. O ms é a hora REAL da mudança detectada
      // pelo app (antes do voting confirmar), não a hora da confirmação.
      const wside = key.slice(7);
      const colonIdx = value.indexOf(':');
      const normRaw  = colonIdx >= 0 ? value.slice(0, colonIdx) : value;
      const realTs   = colonIdx >= 0 ? (parseInt(value.slice(colonIdx + 1), 10) || 0) : 0;
      const norm     = normRaw === '1' ? 'on' : 'off';
      if (isRetained) {
        state[key]              = norm;
        prevWindowStates[wside] = norm;
        break;
      }
      console.log(`[window:${wside}] mqtt='${value}' isRetained=${isRetained} → norm='${norm}' prev='${prevWindowStates[wside]}' hystPending='${_hystPending[key]}' realTs=${realTs}`);
      if (norm === _hystPending[key]) break;
      _hystPending[key] = norm;
      clearTimeout(_hystTimers[key]);
      _hystTimers[key] = setTimeout(() => {
        state[key] = norm;
        if (norm !== prevWindowStates[wside]) {
          prevWindowStates[wside] = norm;
          const label = WINDOW_NAMES[wside] || wside.toUpperCase();
          console.log(`[window:${wside}] EVENT after hysteresis: ${norm === 'on' ? 'open' : 'close'} ts=${realTs || 'now'}`);
          if (norm === 'on') addEvent('window_open',  `${label} aberto`, realTs);
          else               addEvent('window_close', `${label} fechado`, realTs);
        }
      }, HYSTERESIS_MS);
      break;
    }
    case 'debug/window_status_raw': {
      // Log do CSV cru que o Android publicou — ajuda a diagnosticar oscilação
      console.log(`[window:raw] csv='${value}' isRetained=${isRetained}`);
      break;
    }
    case 'debug/door_status_raw': {
      console.log(`[door:raw] csv='${value}' isRetained=${isRetained}`);
      break;
    }
    case 'debug/sunroof_raw': {
      console.log(`[sunroof:raw] value='${value}' isRetained=${isRetained}`);
      break;
    }
    case 'debug/lock_status_raw': {
      console.log(`[lock:raw] value='${value}' isRetained=${isRetained}`);
      break;
    }
    case 'tyre_pressure_fl': { state.tyre_pressure_fl = num(value); checkTyrePressure('FL', num(value), isRetained, state.tyre_temp_fl); break; }
    case 'tyre_pressure_fr': { state.tyre_pressure_fr = num(value); checkTyrePressure('FR', num(value), isRetained, state.tyre_temp_fr); break; }
    case 'tyre_pressure_rl': { state.tyre_pressure_rl = num(value); checkTyrePressure('RL', num(value), isRetained, state.tyre_temp_rl); break; }
    case 'tyre_pressure_rr': { state.tyre_pressure_rr = num(value); checkTyrePressure('RR', num(value), isRetained, state.tyre_temp_rr); break; }
    case 'tyre_temp_fl': state.tyre_temp_fl = num(value); break;
    case 'tyre_temp_fr': state.tyre_temp_fr = num(value); break;
    case 'tyre_temp_rl': state.tyre_temp_rl = num(value); break;
    case 'tyre_temp_rr': state.tyre_temp_rr = num(value); break;

    // GPS — posição ao vivo do veículo
    case 'gps_lat': {
      const lat = parseFloat(value);
      if (lat && lat !== 0) { state.gps_lat = lat; state.gps_ts = Date.now(); checkGeofence(); }
      break;
    }
    case 'gps_lng': {
      const lng = parseFloat(value);
      if (lng && lng !== 0) { state.gps_lng = lng; state.gps_ts = Date.now(); checkGeofence(); }
      break;
    }

    // Telemetria ao vivo
    case 'speed_kmh':         state.speed_kmh          = num(value); break;
    case 'gear': {
      const prevG = prevGearForTrip;
      state.gear = value || '--';
      prevGearForTrip = value;
      if (!isRetained && prevG !== null && prevG !== value) {
        const wasParked  = prevG === 'P';
        const nowDriving = value === 'D' || value === 'R';   // N não inicia viagem
        if (wasParked && nowDriving) addEvent('trip_start', 'Viagem iniciada');
      }
      break;
    }
    case 'inside_temp':       state.inside_temp        = num(value); break;
    case 'outside_temp': {
      const t = num(value);
      state.outside_temp = t;
      // Acumula amostras durante recarga para calcular temperatura média da sessão
      if (state.charging_state === 'Carregando' && t !== 0) _chargeTempSamples.push(t);
      break;
    }
    case 'charging_state': {
      // Mantido como fallback pro caso de charging_state sair de MIGRATED_TO_HA;
      // hoje quem chama handleChargingStateTransition é applyGwmEntity via HA.
      handleChargingStateTransition(value, isRetained);
      break;
    }
    case 'charge_power_kw': {
      const p = num(value);
      state.charge_power_kw = p;
      // Rastreia pico + média só enquanto carregando.
      if (state.charging_state === 'Carregando') {
        // Init lazy: se a sessão começou ANTES deste boot (state.json restaurado já
        // tinha charging_state='Carregando' mas o tracking nunca foi inicializado),
        // marca o início agora E guarda o kWh atual como baseline — a média será
        // calculada só sobre o que injetou DEPOIS do restart, evitando inflar pela
        // divisão de kWh total (cumulativo desde o início real) pelo tempo parcial.
        if (chargeSessionStartMs === 0) {
          chargeSessionStartMs = Date.now();
          state.charge_session_start_ms    = chargeSessionStartMs;
          state.charge_session_kwh_at_init = state.charge_session_kwh || 0;
          if (!chargeStartSoc) {
            chargeStartSoc = state.soc_pct || 0;
            state.charge_start_soc_pct = chargeStartSoc;
          }
          console.log(`⚡ Sessão de recarga já em andamento — tracking parcial a partir de agora (baseline ${state.charge_session_kwh_at_init.toFixed(2)} kWh)`);
        }
        if (p > state.charge_max_power_kw) state.charge_max_power_kw = +p.toFixed(2);
        const elapsedH = (Date.now() - chargeSessionStartMs) / 3_600_000;
        const deltaKwh = Math.max(0, (state.charge_session_kwh || 0) - (state.charge_session_kwh_at_init || 0));
        // Threshold: >60s e >0.1 kWh. Antes era 5s/0.05 mas o MQTT retain pós-restart
        // entrega valores acumulados rapidamente nos primeiros segundos, gerando picos
        // de 100+ kW na média. Janela maior amortece o ruído inicial.
        if (elapsedH > 0.0167 && deltaKwh > 0.1) {
          state.charge_avg_power_kw = +(deltaKwh / elapsedH).toFixed(2);
        }
      }
      break;
    }
    case 'charge_session_kwh': {
      const newKwh  = num(value);
      const oldInit = +state.charge_session_kwh_at_init || 0;
      // Detecta nova sessão de recarga quando o transition `charging_state→Carregando`
      // veio retained do broker (pulou o reset em 3806–3815) e o APK reiniciou seu
      // contador. Sinal: o valor publicado cai abaixo do baseline anterior — só
      // possível se zerou. Reseta pico/média/início pra refletir a sessão atual.
      if (state.charging_state === 'Carregando' && newKwh + 0.3 < oldInit) {
        console.log(`⚡ Nova sessão de recarga detectada (kwh ${newKwh.toFixed(2)} < init ${oldInit.toFixed(2)}) — resetando tracking`);
        chargeSessionStartMs           = Date.now();
        chargeStartSoc                 = state.soc_pct || 0;
        state.charge_session_start_ms  = chargeSessionStartMs;
        state.charge_start_soc_pct     = chargeStartSoc;
        state.charge_session_kwh_at_init = 0;
        state.charge_max_power_kw      = 0;
        state.charge_avg_power_kw      = 0;
        _chargeTempSamples             = [];
        addEvent('charge_start', `Recarga iniciada · SOC: ${chargeStartSoc.toFixed(0)}%`);
      }
      state.charge_session_kwh = newKwh;
      break;
    }
    case 'charge_remaining_min': {
      const rem = num(value);
      state.charge_remaining_min = rem;
      // Dispara notificação quando threshold atingido — apenas uma vez por sessão
      // (chargeEndingNotifSent só é resetado quando charging_state sai de 'Carregando')
      // Charge_ending: threshold pra disparar é o MÍNIMO entre todos os devices.
      // Cada device tem seu próprio `charge_ending_min`; o gate per-device acontece
      // dentro do sendPush (devices com charge_ending=false não recebem).
      const minThreshold = Math.max(
        notifPrefs.charge_ending_min || 5,
        ...Object.values(notifPrefsByDevice).map(p => p.charge_ending_min || 0)
      );
      if (
        rem > 0 &&
        rem <= minThreshold &&
        !chargeEndingNotifSent &&
        state.charging_state === 'Carregando'
      ) {
        chargeEndingNotifSent = true;
        sendPush(
          '🔔 Recarga quase no fim',
          `Faltam ${rem} min`,
          'charge_ending'
        );
      }
      break;
    }
    case 'network/info': {
      // APK publica IP/tipo de rede do head unit. Salva no state pra PWA usar.
      try {
        const o = JSON.parse(value);
        state.car_network = {
          type:          o.type || null,
          ip:            o.ip || null,
          downlink_kbps: o.downlink_kbps || null,
          ts:            o.ts || Date.now(),
        };
      } catch (_) {}
      break;
    }
    case 'ha/charge_limit/state': {
      const pct = parseInt(value);
      if ([50,60,70,80,90,100].includes(pct)) state.charge_limit_pct = pct;
      break;
    }
    case 'cmd/charge_limit/result':
      broadcast('charge_limit_result', { result: value });
      break;
    // price_gas_per_l e price_kwh do APK: IGNORADOS — valor agora vem do mix
    // ponderado de abastecimentos/recargas (recomputeTankAvgPrice / recomputeBatteryAvgPrice).
    // Próxima versão do APK vai parar de publicar esses tópicos.
    case 'price_gas_per_l': break;
    case 'price_kwh':       break;
    case 'charge_current_a':     state.charge_current_a     = num(value); break;
    case 'battery_voltage_v': state.battery_voltage_v  = num(value); break;
    case 'battery_current_a': state.battery_current_a  = num(value); break;
    case 'motor_power_kw': {
      // Safety: H6 PHEV pico ~173 kW; clamp absurdos (vinham de APK pré-v5.16
      // sem filtro de sentinela do bus). Mantém regen negativo até -200.
      const v = num(value);
      state.motor_power_kw = (Math.abs(v) > 250) ? 0 : v;
      break;
    }
    case 'odometer_km':       state.odometer_km         = num(value); checkMaintenanceAlerts(); break;
    case 'batt_12v_pct':      state.batt_12v_pct        = num(value); break;
    case 'range_ev_km':       state.range_ev_km         = Math.round(num(value)); break;
    case 'range_ice_km':      state.range_ice_km        = Math.round(num(value)); break;
    case 'battery_power_pct': state.battery_power_pct = Math.round(num(value)); break;
    case 'engine_rpm':        state.engine_rpm        = Math.round(num(value)); break;

    // SOC — fonte primária: HA publica via automação em haval/ecotrip/soc_pct (retain)
    // Uma vez recebido, marca haSocActive = true e ignora trip_a/b soc_current para soc_pct
    case 'soc_pct':
      haSocActive   = true;
      state.soc_pct = num(value);
      break;

    // Trip A/B foram descontinuados — bridge ignora os tópicos legados.
    // SOC vem agora exclusivamente do HA (gwmbrasil_.../soc_pct) ou do
    // próprio app via gwmbrasil; sem fallback do trip_a.
    case 'trip_a/soc_current': case 'trip_b/soc_current':
      if (!haSocActive) state.soc_pct = num(value);   // legacy fallback até HA estar online
      break;

    // Rolling
    case 'rolling/kwh_per_100km': state.rolling.kwh_per_100km = num(value); break;
    case 'rolling/km_per_l':      state.rolling.km_per_l      = num(value); break;
    case 'rolling/distance_km':   state.rolling.distance_km   = num(value); break;
    case 'rolling/fuel_l':        state.rolling.fuel_l        = num(value); break;
    case 'rolling/cost_brl':      state.rolling.cost_brl      = num(value); break;

    // Lifetime
    case 'lifetime/energy_kwh':  state.lifetime.energy_kwh  = num(value); maybeSaveLifetimeSnapshot(); break;
    case 'lifetime/regen_kwh':   state.lifetime.regen_kwh   = num(value); break;
    case 'lifetime/net_kwh':     state.lifetime.net_kwh     = num(value); break;
    case 'lifetime/distance_km': state.lifetime.distance_km = num(value); break;
    case 'lifetime/time_sec':    state.lifetime.time_sec    = value; break;
    case 'lifetime/fuel_l':      state.lifetime.fuel_l      = num(value); break;
    case 'lifetime/charge_kwh':  state.lifetime.charge_kwh  = num(value); break;
    case 'lifetime/charge_sec':  state.lifetime.charge_sec  = value; break;
    case 'lifetime/cost_brl':    state.lifetime.cost_brl    = num(value); break;

    // Histórico de recargas (tópico retained)
    case 'charging/history': {
      try {
        const parsed = JSON.parse(value);
        const all    = parsed.charges || [];
        // Filtra entradas anteriores ao último "Limpar histórico" + tombstones
        // de recargas explicitamente apagadas pelo usuário.
        const cutMs  = state.charges_cleared_at || 0;
        const charges = all
          .filter(c => cutMs === 0 || (c.timestamp_ms || 0) > cutMs)
          .filter(c => !isDeleted('charges', c.timestamp_ms || 0));
        if (charges.length > 0) {
          // Snapshot dos timestamps que JÁ tínhamos — pra detectar novas depois do merge.
          // Em mensagens retained (chegam no boot do bridge), não dispara broadcast/push.
          const prevTsSet = new Set(chargesArr.map(c => c.timestamp_ms));
          // Merge: preserva campos server-side (location, charger_kwh, cost_override)
          // que o Android não conhece — sem isso o MQTT retained apaga tudo
          chargesArr = charges.map(newCharge => {
            const existing = chargesArr.find(c => c.timestamp_ms === newCharge.timestamp_ms);
            if (!existing) {
              // Nova sessão — preferência: avg_temp_c do Android; fallback: cálculo bridge-side
              const entry = { ...newCharge };
              if (entry.avg_temp_c != null) {
                // Android enviou temperatura média diretamente — consume a do bridge
                _lastChargeAvgTemp = null;
              } else if (_lastChargeAvgTemp !== null) {
                entry.avg_temp_c   = _lastChargeAvgTemp;
                _lastChargeAvgTemp = null;   // consumida
              }
              return entry;
            }
            const keep = {};
            if (existing.location_name    != null) keep.location_name    = existing.location_name;
            if (existing.location_lat     != null) keep.location_lat     = existing.location_lat;
            if (existing.location_lng     != null) keep.location_lng     = existing.location_lng;
            if (existing.charger_kwh      != null) keep.charger_kwh      = existing.charger_kwh;
            if (existing.cost_override    != null) keep.cost_override    = existing.cost_override;
            if (existing.avg_temp_c       != null) keep.avg_temp_c       = existing.avg_temp_c;
            if (existing.manual_overrides != null) keep.manual_overrides = existing.manual_overrides;
            if (existing._updated_ms      != null) keep._updated_ms      = existing._updated_ms;
            // Recarga consolidada (merge): preserva os campos somados — sem isso
            // o APK retained sobrescreve com os valores originais da `early` e o
            // merge "se desfaz" em cada reconnect.
            if (Array.isArray(existing.merged_from) && existing.merged_from.length > 0) {
              keep.merged_from  = existing.merged_from;
              keep.duration_sec = existing.duration_sec;
              keep.energy_kwh   = existing.energy_kwh;
              keep.avg_power_kw = existing.avg_power_kw;
              keep.soc_end      = existing.soc_end;
            }
            return { ...newCharge, ...keep };
          });
          scheduleChargesFlush();
          // Mix ponderado da bateria precisa ser recalculado a cada recarga
          // nova/atualizada — sem isso, o custo das viagens segue usando o
          // preço fixo até alguém editar override manualmente.
          recomputeBatteryAvgPrice();
          const skipped = all.length - charges.length;
          console.log(`✓ Recargas MQTT: ${charges.length} sessão(ões)${skipped > 0 ? ` (${skipped} anteriores ao clear ignoradas)` : ''}`);
          // Broadcast WS pra PWA re-fazer fetch — só pra entradas novas, em msg live (não retained)
          if (!isRetained) {
            const novas = charges.filter(c => !prevTsSet.has(c.timestamp_ms));
            // Auto-tag de local: usa GPS atual do bridge. Se cair dentro de um
            // knownPlace (raio 200m), preenche location_name automaticamente.
            // Antes só faltava ser chamado — o autoMatchLocation já existia.
            for (const nova of novas) {
              const stored = chargesArr.find(c => c.timestamp_ms === nova.timestamp_ms);
              if (stored && !stored.location_name && state.gps_lat && state.gps_lng) {
                stored.location_lat = state.gps_lat;
                stored.location_lng = state.gps_lng;
                const match = autoMatchLocation(state.gps_lat, state.gps_lng);
                if (match) {
                  stored.location_name = match.name;
                  console.log(`📍 Auto-tag recarga ${nova.timestamp_ms}: "${match.name}"`);
                } else {
                  console.log(`📍 Recarga ${nova.timestamp_ms} salva com GPS (${state.gps_lat.toFixed(5)}, ${state.gps_lng.toFixed(5)}) — fora de locais conhecidos`);
                }
                stored._updated_ms = Date.now();
                scheduleChargesFlush();
              }
              broadcast('new_charge', {
                timestamp_ms: nova.timestamp_ms,
                energy_kwh:   nova.energy_kwh,
                soc_start:    nova.soc_start,
                soc_end:      nova.soc_end,
              });
              console.log(`✓ Broadcast new_charge ts=${nova.timestamp_ms} (${nova.energy_kwh} kWh)`);
            }
          }
        }
      } catch (e) {
        console.error('Erro ao parsear charging/history:', e.message);
      }
      break;
    }

    // Histórico de Trip A/B descontinuado — ignora msg do APK
    case 'trips/history': break;

    // ── Abastecimentos auto-detectados (retained pelo APK ≥5.20) ──────────
    // O APK detecta pulos no fuel_l com carro parado e registra como
    // abastecimento com price_per_liter=0 (pendente). Bridge mescla com os
    // do PWA preservando campos editados pelo usuário (preço, posto, notas).
    case 'refuels/history': {
      try {
        const parsed = JSON.parse(value);
        const incoming = parsed.refuels || [];
        let merged = 0, added = 0;
        for (const r of incoming) {
          const tsMs = r.timestamp_ms || 0;
          if (!tsMs) continue;
          if (isDeleted('refuels', tsMs)) continue;
          // Match por timestamp_ms (±2s pra tolerar drift entre APK e PWA)
          const existing = refuels.find(x =>
            Math.abs((x.timestamp_ms || 0) - tsMs) <= 2000
          );
          if (existing) {
            // Preserva preço/cost/notes/location do PWA, atualiza só dados físicos.
            existing.fuel_l_before = r.fuel_l_before || existing.fuel_l_before;
            existing.fuel_l_after  = r.fuel_l_after  || existing.fuel_l_after;
            existing.liters_added  = r.liters_added  || existing.liters_added;
            if (r.odometer_km > 0) existing.odometer_km = r.odometer_km;
            merged++;
          } else {
            const pricePerL = +r.price_per_liter || 0;
            refuels.push({
              id: 'apk-' + tsMs,
              timestamp_ms: tsMs,
              fuel_l_before: +r.fuel_l_before || 0,
              fuel_l_after:  +r.fuel_l_after  || 0,
              liters_added:  +r.liters_added  || 0,
              price_per_liter: pricePerL,
              total_cost: pricePerL * (+r.liters_added || 0),
              odometer_km: +r.odometer_km || 0,
              location_name: '',
              notes: '',
              pending: !(pricePerL > 0),
            });
            added++;
          }
        }
        if (added > 0 || merged > 0) {
          refuels.sort((a, b) => (b.timestamp_ms || 0) - (a.timestamp_ms || 0));
          saveRefuels();
          recomputeTankAvgPrice();
          console.log(`✓ Abastecimentos MQTT: ${incoming.length} (${added} novos, ${merged} atualizados)`);
        }
      } catch (e) {
        console.error('Erro ao parsear refuels/history:', e.message);
      }
      break;
    }

    // ── Viagem em andamento (retained pelo APK ≥5.20) ─────────────────────
    // Snapshot da auto-trip ativa. Sobrevive a desconexão pq é retained — se o
    // carro atingiu 140 km/h offline, ao reconectar entrega o último valor.
    // Payload vazio = sem viagem ativa.
    case 'current_trip': {
      if (!value || value.trim() === '') {
        state.current_trip = null;
      } else {
        try {
          state.current_trip = JSON.parse(value);
        } catch (e) {
          console.error('current_trip JSON inválido:', e.message);
        }
      }
      break;
    }

    default: break;
  }
  scheduleStateSave();
}

// ── Start ─────────────────────────────────────────────────────────────────────

server.listen(PORT, () => {
  const pkg = require('./package.json');
  console.log(`\n🚗  EcoTrip Bridge v${pkg.version}`);
  console.log(`    HTTP PWA:  http://localhost:${PORT}`);
  console.log(`    WebSocket: ws://localhost:${PORT}/ws`);
  if (httpsServer) {
    console.log(`    HTTPS PWA: https://localhost:${HTTPS_PORT}  ← use este para Push`);
    console.log(`    WSS:       wss://localhost:${HTTPS_PORT}/ws`);
  } else {
    console.log(`    HTTPS:     inativo (sem cert.pem / key.pem)`);
  }
  console.log(`    MQTT:      ${MQTT_HOST} (prefix: ${MQTT_PREFIX})\n`);
});

if (httpsServer) {
  httpsServer.listen(HTTPS_PORT);
}

process.on('SIGINT',  () => { mqttClient.end(); process.exit(0); });
process.on('SIGTERM', () => { mqttClient.end(); process.exit(0); });
