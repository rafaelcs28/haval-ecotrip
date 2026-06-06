'use strict';

// DATA_DIR: raiz dos dados MUTÁVEIS (state/trips/charges/tokens/.env). Em multi-tenant
// cada instância recebe ECOTRIP_DATA_DIR=<.../tenants/NOME>; sem ela cai em __dirname
// (instância principal, comportamento legado inalterado). Código/estáticos (public/, certs,
// git) continuam em __dirname e são compartilhados. NUNCA gravar dados em __dirname.
const DATA_DIR = process.env.ECOTRIP_DATA_DIR || __dirname;
try { require('fs').mkdirSync(DATA_DIR, { recursive: true }); } catch (_) {}
require('dotenv').config({ path: require('path').join(DATA_DIR, '.env') });
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
// Endereço PÚBLICO do broker que o CARRO usa (4G/internet) — diferente do MQTT_HOST,
// que é o endereço LOCAL usado pelo bridge. O carro recebe este no pareamento.
const CAR_MQTT_HOST = (process.env.CAR_MQTT_HOST || '').replace(/^mqtts?:\/\//, '');
const CAR_MQTT_PORT = parseInt(process.env.CAR_MQTT_PORT || '8883', 10);
const CAR_MQTT_TLS  = process.env.CAR_MQTT_TLS === 'true';
const PORT           = parseInt(process.env.PORT || '3000', 10);
// Integração GWM Brasil — publica direto via MQTT (sem passar pelo app).
// Bridge subscribe nesses tópicos pra ter estado confiável de body/lock/etc.
//
// Origem do chassi (precedência): vehicle.json (editável via UI) → .env (legacy).
// vehicle.json vence porque é a fonte autoritativa quando o usuário configura
// pela tela de Settings → Veículo. .env é fallback pra setups antigos.
const VEHICLE_FILE = path.join(DATA_DIR, 'vehicle.json');
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

// Versão do bridge — usada no endpoint /api/bridge-version e no full_state WS
const BRIDGE_VERSION = '5.11';

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
const AUTH_FILE = path.join(DATA_DIR, 'auth.json');
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
const CHARGES_FILE    = path.join(DATA_DIR, 'charges.json');
const STATE_FILE      = path.join(DATA_DIR, 'state.json');
const AUTOTRIPS_DIR   = path.join(DATA_DIR, 'autotrips');
const SNAPSHOTS_FILE  = path.join(DATA_DIR, 'lifetime_snapshots.json');
const VAPID_FILE        = path.join(DATA_DIR, 'vapid_keys.json');
const PUSH_SUBS_FILE    = path.join(DATA_DIR, 'push_subscriptions.json');
const RENAMES_FILE      = path.join(DATA_DIR, 'pending_renames.json');
const CHARGE_LOCS_FILE    = path.join(DATA_DIR, 'charge_locations.json');
const KNOWN_PLACES_FILE   = path.join(DATA_DIR, 'known_places.json');
const MAINTENANCE_FILE    = path.join(DATA_DIR, 'maintenance.json');
const REFUELS_FILE        = path.join(DATA_DIR, 'refuels.json');
const TELEMETRY_LOG_FILE  = path.join(DATA_DIR, 'telemetry_history.json');
const DELETED_IDS_FILE    = path.join(DATA_DIR, 'deleted_ids.json');
const PRECLIMAT_FILE      = path.join(DATA_DIR, 'preclimat.json');
const DRIVE_HISTORY_FILE  = path.join(DATA_DIR, 'drive_history.json');

// Capacidades do Haval H6 PHEV (uso pra estimar kWh atual a partir do SOC%)
const BATTERY_CAPACITY_KWH = 34;
const TANK_CAPACITY_L      = 55;
const NOTIF_PREFS_FILE    = path.join(DATA_DIR, 'notif_prefs.json');
const NOTIF_HISTORY_FILE  = path.join(DATA_DIR, 'notif_history.json');
const EVENTS_FILE         = path.join(DATA_DIR, 'events.json');
const RULES_FILE          = path.join(DATA_DIR, 'automation_rules.json');
const AUTO_PLACES_FILE    = path.join(DATA_DIR, 'automation_places.json');

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
async function sendPush(title, body, type, opts = {}) {

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
  if (type)          payloadObj.type     = type;
  if (opts.state)    payloadObj.state    = opts.state;
  const payload = JSON.stringify(payloadObj);

  // Opções de envio para push silencioso. Sem headers extras — o endpoint
  // web.push.apple.com segue RFC 8030 e rejeita headers APNS proprietários.
  // A supressão de banner/som é feita pelo `silent: true` no payload, que o
  // Service Worker repassa pro showNotification({ silent: true }).
  const _silentWpOpts = {};

  const dead = [];
  let sent = 0, skipped = 0;
  await Promise.all(pushSubs.map(async (sub, i) => {
    // Restrição por lista de devices (ex: preclimat só pro device que agendou)
    if (opts.onlyDeviceIds && !opts.onlyDeviceIds.includes(sub.device_id)) { skipped++; return; }
    // Gating por device: se a sub tem device_id e o tipo está OFF nas prefs, pula.
    if (type) {
      const prefs = getPrefsForDevice(sub.device_id);
      if (prefs[type] === false) { skipped++; return; }
    }
    try {
      await webpush.sendNotification(sub, payload, opts.silent ? _silentWpOpts : {});
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

  // APNs alert direto pro app nativo iOS (conta paga). Mesmo gating de device
  // do web-push. Updates silenciosos (charge_live) não viram banner.
  // skipApnsAlert: o evento já vai TOCAR via alert da própria Live Activity
  // (recarga/pré-clima) — não manda banner separado pro nativo (evita duplicar).
  // O web-push acima continua indo pro PWA, que não tem Live Activity.
  if (apnsLive.enabled && !opts.silent && !opts.skipApnsAlert) {
    apnsLive.pushAlert(title, body, {
      threadId: type || undefined,
      allow: (deviceId) => {
        if (opts.onlyDeviceIds && !opts.onlyDeviceIds.includes(deviceId)) return false;
        if (type && getPrefsForDevice(deviceId)[type] === false) return false;
        return true;
      },
    }).catch(e => console.warn('[apns] alert falhou:', e.message));
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
  charge_stopped:    true,     // recarga PAROU antes do limite − 1% (falha) — default ON (segurança)
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
  ac_on_parked:      false,   // AC ligado com velocidade=0 por mais de ac_on_parked_min minutos
  ac_on_parked_min:  10,      // minutos de tolerância antes de alertar (padrão 10)
  batt12_low:        false,   // bateria auxiliar 12V abaixo de 50%
  daily_summary:     false,   // resumo diário às 20h (km, kWh, recargas)
  charge_slow:       false,   // alerta quando potência de recarga cai >30% do pico por 5+ min
  window_forgotten:     false, // vidro aberto X min após motor desligar
  window_forgotten_min: 10,    // minutos antes de alertar (padrão 10)
  lock_forgotten:       false, // carro destravado X min após motor desligar
  lock_forgotten_min:   5,     // minutos antes de alertar (padrão 5)
  trunk_forgotten:      false,  // porta-malas aberta X min após motor desligar
  trunk_forgotten_min:  10,
  soc_low_idle:         false,  // SOC < X% sem estar carregando
  soc_low_idle_pct:     20,
  soc_arrival:          false,  // SOC baixo ao chegar num local sem carregar
  soc_arrival_places:   [],     // IDs dos locais a monitorar (por device)
  soc_arrival_min:      5,      // minutos após chegar antes de alertar
  soc_arrival_pct:      30,     // threshold SOC % na chegada
  soc_full_long:        false,  // SOC > 95% por mais de 24h (saúde da bateria)
  tyre_drop:            true,   // queda de pressão > X PSI durante viagem (segurança — default ON)
  tyre_drop_psi:        4,      // queda mínima para alertar (PSI)
  // ── Live Activities (masters GLOBAIS, default LIGADO — preserva comportamento atual).
  // Controlam se cada card ao vivo nasce na tela de bloqueio. via /api/la-prefs.
  la_charge:            true,
  la_preclimat:         true,
  la_trip:              true,
  la_motor:             true,
  la_security:          true,
  la_songpro:           false,  // LA paralela da BYD Song Pro (Grasi) — opt-in, só admin
  la_songpro_trip:      false,  // LA de deslocamento do BYD (Grasi) — opt-in, default OFF
  preclimat_steps:      true,   // alerta (som) a cada passo da pré-climatização
};
let notifPrefs = { ...NOTIF_DEFAULTS };
try {
  if (fs.existsSync(NOTIF_PREFS_FILE))
    notifPrefs = { ...NOTIF_DEFAULTS, ...JSON.parse(fs.readFileSync(NOTIF_PREFS_FILE, 'utf8')) };
} catch (_) {}
function saveNotifPrefs() {
  try { fs.writeFileSync(NOTIF_PREFS_FILE, JSON.stringify(notifPrefs, null, 2)); } catch (_) {}
}

// ── Pré-climatização agendada ─────────────────────────────────────────────
// Estrutura: { enabled, time:"HH:MM", recurrence:"once"|"daily"|"weekdays"|"weekends",
//              temp:22.0, fan:3, lastFiredDate:"YYYY-MM-DD" }
// Lista de agendamentos. Cada um: { id, enabled, time:"HH:MM", recurrence,
//   temp, fan, duration, leadMin, device_id, lastFiredDate, startedDate }.
const PRECLIMAT_SCHED_DEFAULTS = { enabled: true, time: '07:30', recurrence: 'daily', temp: 22.0, fan: 3, duration: 20, leadMin: 10, device_id: '', lastFiredDate: '', startedDate: '' };
function _genSchedId() { return Date.now().toString(36) + Math.random().toString(36).slice(2, 8); }
let preclimat = { schedules: [] };
try {
  if (fs.existsSync(PRECLIMAT_FILE)) {
    const raw = JSON.parse(fs.readFileSync(PRECLIMAT_FILE, 'utf8'));
    if (Array.isArray(raw.schedules)) {
      preclimat.schedules = raw.schedules.map(s => ({ ...PRECLIMAT_SCHED_DEFAULTS, ...s, id: s.id || _genSchedId() }));
    } else if (raw && raw.time) {
      // Migra o formato antigo (agendamento único) pra um item da lista.
      preclimat.schedules = [{ ...PRECLIMAT_SCHED_DEFAULTS, ...raw, id: _genSchedId() }];
    }
  }
} catch (_) {}
function savePreclimat() {
  try { fs.writeFileSync(PRECLIMAT_FILE, JSON.stringify(preclimat, null, 2)); } catch (_) {}
}

// Live Activity: uma por vez. `_activeSched` é o agendamento que a controla.
// phase: idle|scheduled|starting|engine_on|cooling|restoring|ended|failed.
let preclimatStatus = { phase: 'idle', detail: '', endsAtMs: 0, temp: 0, fan: 0, updatedAtMs: 0 };
let _activeSched = null;
// Trava de segurança: handle do timer que desliga o motor no fim da pré-clima e
// flag de cancelamento. Se o motorista ENTRAR no carro (abrir porta) antes do
// fim, cancelamos o desligamento remoto — senão o motor poderia desligar com a
// pessoa já dirigindo. Ver _abortPreclimatAutoOff() e o handler de portas.
let _preclimatRestoreTimer   = null;
let _preclimatAutoOffCancelled = false;
let _preclimatPrevHvac       = null;   // { fan, drvTemp, passTemp, acEnable } salvo antes da pré-clima

// Fases em que o motor foi ligado pela pré-clima e o desligamento automático
// ainda está pendente — só aí faz sentido a trava da porta agir.
function _preclimatAutoOffPending() {
  return ['starting', 'engine_on', 'cooling'].includes(preclimatStatus.phase);
}

// Restaura o AC ao estado salvo antes da pré-climatização (temperatura/fan/master).
// Usado no fim normal (timer) E quando o usuário entra e cancela o desligamento —
// aí o motor segue ligado, mas o AC volta ao que estava antes da pré-clima.
async function _restorePreclimatHvac() {
  const prev = _preclimatPrevHvac;
  if (!prev) return;
  _preclimatPrevHvac = null;   // evita restaurar duas vezes
  if (prev.drvTemp  !== null) mqttClient.publish(`${MQTT_PREFIX}/cmd/hvac/driver_temp`,    prev.drvTemp.toFixed(1),  { qos: 1, retain: false });
  if (prev.passTemp !== null) mqttClient.publish(`${MQTT_PREFIX}/cmd/hvac/passenger_temp`, prev.passTemp.toFixed(1), { qos: 1, retain: false });
  await new Promise(r => setTimeout(r, 1_000));
  mqttClient.publish(`${MQTT_PREFIX}/cmd/hvac/fan_speed`, prev.fan.toString(), { qos: 1, retain: false });
  // Restaura a recirculação (ar interno/externo) ao que estava antes do pré-clima.
  if (prev.cycle !== null && prev.cycle !== undefined)
    mqttClient.publish(`${MQTT_PREFIX}/cmd/hvac/cycle_mode`, prev.cycle.toString(), { qos: 1, retain: false });
  // Restaura o master do A/C ao estado anterior (desliga se estava desligado/desconhecido).
  mqttClient.publish(`${MQTT_PREFIX}/cmd/hvac/ac_enable`, prev.acEnable === '1' ? '1' : '0', { qos: 1, retain: false });
  console.log(`[preclimat] AC restaurado ao estado anterior (fan=${prev.fan} acEnable=${prev.acEnable} cycle=${prev.cycle})`);
}

// Cancela o desligamento remoto agendado (motor segue ligado) e restaura o AC.
function _abortPreclimatAutoOff(reason) {
  if (_preclimatAutoOffCancelled && !_preclimatRestoreTimer && !_preclimatPrevHvac) return;
  _preclimatAutoOffCancelled = true;
  if (_preclimatRestoreTimer) { clearTimeout(_preclimatRestoreTimer); _preclimatRestoreTimer = null; }
  console.log(`[preclimat] desligamento automático CANCELADO (${reason}) — motor segue ligado, restaurando AC`);
  _restorePreclimatHvac().catch(e => console.warn('[preclimat] restaurar AC falhou:', e.message));
  _setPreclimatStatus('ended', 'Você entrou no carro — AC restaurado, motor segue ligado',
    { endsAtMs: Date.now() + 2 * 60_000,
      alert: { title: '🚗 Pré-climatização',
               body: 'Você entrou no carro — desligamento cancelado e AC voltou ao ajuste anterior. O motor segue ligado.' } });
  // Entrou no carro → encerra a LA logo (1 min, tempo de ver a confirmação),
  // sobrepondo os 5 min do encerramento normal.
  _schedulePreclimatLAEnd(_activeSched && _activeSched.device_id, 60_000);
}

const PRECLIMAT_LA_TYPE = 'PreClimatActivityAttributes';
function _preclimatAttributes() {
  return { scheduledTime: _activeSched ? _activeSched.time : '', carName: 'Haval H6 PHEV' };
}
function _preclimatContentState() {
  return {
    phase: preclimatStatus.phase, detail: preclimatStatus.detail,
    temp: preclimatStatus.temp, fan: preclimatStatus.fan,
    tempIn:  +state.inside_temp  || 0,
    tempOut: +state.outside_temp || 0,
    endsAtMs: preclimatStatus.endsAtMs, updatedAtMs: preclimatStatus.updatedAtMs,
  };
}
function _setPreclimatStatus(phase, detail, extra = {}) {
  preclimatStatus = {
    phase, detail,
    endsAtMs: extra.endsAtMs != null ? extra.endsAtMs : preclimatStatus.endsAtMs,
    temp: extra.temp != null ? extra.temp : preclimatStatus.temp,
    fan:  extra.fan  != null ? extra.fan  : preclimatStatus.fan,
    updatedAtMs: Date.now(),
  };
  console.log(`[preclimat] status → ${phase}: ${detail}`);
  const dev = _activeSched && _activeSched.device_id;
  // extra.alert = { title, body }: este passo deve TOCAR (som+vibração).
  // Nativo: o toque vem pelo alert da própria LA (abaixo). PWA: web-push aqui
  // com skipApnsAlert (sem banner nativo duplicado).
  // "cada passo" toca som? respeita o toggle preclimat_steps (default ligado).
  const stepAlert = (notifPrefs.preclimat_steps !== false) ? extra.alert : undefined;
  if (stepAlert) {
    sendPush(stepAlert.title, stepAlert.body, 'preclimat',
      { onlyDeviceIds: dev ? [dev] : undefined, skipApnsAlert: true });
  }
  if (!apnsLive.enabled || notifPrefs.la_preclimat === false) return;
  apnsLive.pushUpdate(PRECLIMAT_LA_TYPE, dev ? { deviceId: dev } : {}, _preclimatContentState(),
    { staleDate: preclimatStatus.endsAtMs || undefined, alert: stepAlert })
    .catch(e => console.warn('[apns] preclimat update falhou:', e.message));
  // Finalizou todo o procedimento (sem entrar no carro): mantém a LA por 5 min e encerra.
  if (phase === 'ended' || phase === 'failed') _schedulePreclimatLAEnd(dev, 5 * 60_000);
}

// Agenda o encerramento da LA de pré-climatização (cancela qualquer agendamento
// anterior). 5 min após finalizar normalmente; ~1 min quando o usuário entra no carro.
let _preclimatLAEndTimer = null;
function _schedulePreclimatLAEnd(dev, delayMs) {
  if (_preclimatLAEndTimer) clearTimeout(_preclimatLAEndTimer);
  _preclimatLAEndTimer = setTimeout(() => {
    _preclimatLAEndTimer = null;
    if (!apnsLive.enabled) return;
    apnsLive.pushUpdate(PRECLIMAT_LA_TYPE, dev ? { deviceId: dev } : {}, _preclimatContentState(),
      { isFinal: true, dismissalDate: Date.now() })
      .catch(e => console.warn('[apns] preclimat end falhou:', e.message));
  }, delayMs);
}
// Cria a Live Activity (push-to-start) na janela T-leadMin, fase "scheduled".
function _startPreclimatLA(sched, fireMs) {
  _activeSched = sched;
  preclimatStatus = { phase: 'scheduled', detail: `Agendada para ${sched.time}`,
    endsAtMs: fireMs, temp: sched.temp, fan: sched.fan, updatedAtMs: Date.now() };
  console.log(`[preclimat] LA push-to-start (agendada p/ ${sched.time})`);
  if (!apnsLive.enabled || notifPrefs.la_preclimat === false) return;
  // device_id vazio → broadcast pros devices com la_preclimat ligado (igual às
  // outras LAs). Antes exigia device_id e a LA não saía quando o agendamento vinha sem ele.
  // O `alert` é necessário: sem ele o iOS trata o push-to-start como silencioso.
  apnsLive.pushStart(PRECLIMAT_LA_TYPE, sched.device_id || '', _preclimatAttributes(), _preclimatContentState(),
    { staleDate: fireMs, alert: { title: '⏰ Pré-climatização', body: `Começa às ${sched.time}` },
      allow: sched.device_id ? undefined : (d) => getPrefsForDevice(d).la_preclimat !== false })
    .catch(e => console.warn('[apns] preclimat pushStart falhou:', e.message));
}
// Encerra a LA agora SE ela for deste agendamento (ao desativar/reagendar/remover).
function _dismissPreclimatLA(sched) {
  if (!_activeSched || _activeSched.id !== sched.id) return;
  const dev = sched.device_id;
  _activeSched = null;
  preclimatStatus = { phase: 'ended', detail: 'Cancelada', temp: 0, fan: 0, endsAtMs: 0, updatedAtMs: Date.now() };
  if (!apnsLive.enabled || !dev) return;
  console.log('[preclimat] encerrando LA (desativado/reagendado/removido)');
  apnsLive.pushUpdate(PRECLIMAT_LA_TYPE, { deviceId: dev }, _preclimatContentState(),
    { isFinal: true, dismissalDate: Date.now() })
    .catch(e => console.warn('[apns] preclimat dismiss falhou:', e.message));
}
function _schedEligibleToday(sched, now) {
  const dow = now.getDay(); // 0=Dom … 6=Sáb
  if (sched.recurrence === 'weekdays' && (dow === 0 || dow === 6)) return false;
  if (sched.recurrence === 'weekends' && dow !== 0 && dow !== 6) return false;
  return true;
}
function _schedFireMsToday(sched, now) {
  const [h, m] = String(sched.time).split(':').map(Number);
  if (isNaN(h) || isNaN(m)) return null;
  const d = new Date(now); d.setHours(h, m, 0, 0);
  return d.getTime();
}

// ── Resumo diário ─────────────────────────────────────────────────────────────
// Estado operacional — não é preferência, não persiste em notif_prefs.json.
let daily_summary_last_date = '';

// ── Alerta carga desacelera ───────────────────────────────────────────────────
let _chargePeakKw        = 0;
let _chargeSlowAlertSent = false;
let _chargeSlowCheckTs   = 0;

// Checker a cada 60s — percorre TODOS os agendamentos. Pra cada um: T-leadMin
// cria a Live Activity (push-to-start) e T dispara motor+AC.
let _preclimatFiring = false;
setInterval(() => {
  const now   = new Date();
  const today = now.toISOString().slice(0, 10);
  const nowMs = now.getTime();
  let dirty = false;
  for (const sched of preclimat.schedules) {
    if (!sched.enabled) continue;
    if (!_schedEligibleToday(sched, now)) continue;
    const fireMs = _schedFireMsToday(sched, now);
    if (fireMs == null) continue;
    const lead = (sched.leadMin != null ? sched.leadMin : 10) * 60_000;

    // Etapa 1 — T-leadMin: cria a LA via push-to-start (uma vez por dia).
    if (lead > 0 && nowMs >= fireMs - lead && nowMs < fireMs && sched.startedDate !== today) {
      sched.startedDate = today; dirty = true;
      _startPreclimatLA(sched, fireMs);
    }

    // Etapa 2 — T (até +90s de folga): dispara motor+AC.
    if (!_preclimatFiring && sched.lastFiredDate !== today
        && nowMs >= fireMs && nowMs < fireMs + 90_000) {
      sched.lastFiredDate = today;
      if (sched.recurrence === 'once') sched.enabled = false;
      dirty = true;
      _preclimatFiring = true;
      firePreClimat(sched).finally(() => { _preclimatFiring = false; });
    }
  }
  if (dirty) savePreclimat();
}, 60_000);

// ── Resumo diário às 20h ──────────────────────────────────────────────────────
// Roda a cada 60s, dispara exatamente uma vez por dia às 20:00 local.
setInterval(() => {
  const now  = new Date();
  const hhmm = now.getHours().toString().padStart(2, '0') + ':' + now.getMinutes().toString().padStart(2, '0');
  if (hhmm !== '20:00') return;
  const today = now.toISOString().slice(0, 10);
  if (daily_summary_last_date === today) return;
  daily_summary_last_date = today;

  const todayMidnight = new Date(today + 'T00:00:00').getTime();

  // km e kWh rodados hoje (das auto-trips)
  let kmHoje  = 0;
  let kwhHoje = 0;
  for (const t of autoTripsArr) {
    if ((t.startMs || 0) >= todayMidnight) {
      kmHoje  += +t.distKm || 0;
      kwhHoje += +t.netKwh || 0;
    }
  }

  // Recargas finalizadas hoje (eventos charge_end)
  const chargesHoje = eventsLog.filter(e => e.type === 'charge_end' && (e.ts || 0) >= todayMidnight).length;

  if (kmHoje <= 0 && chargesHoje <= 0) return; // nada a reportar

  const kmStr  = kmHoje.toFixed(0);
  // netKwh é negativo quando energia é consumida; exibe o valor absoluto
  const kwhStr = Math.abs(kwhHoje).toFixed(1).replace('.', ',');
  const parts  = [`${kmStr} km rodados`, `${kwhStr} kWh`];
  if (chargesHoje > 0) parts.push(`${chargesHoje} recarga${chargesHoje > 1 ? 's' : ''}`);

  sendPush('📊 Resumo do dia', parts.join(' · '), 'daily_summary', { tag: 'daily_summary' });
}, 60_000);

async function firePreClimat(sched) {
  _activeSched = sched;
  // Nova sessão: zera a trava e limpa qualquer desligamento pendente de antes.
  _preclimatAutoOffCancelled = false;
  _preclimatPrevHvac = null;   // descarta estado anterior não-restaurado de uma sessão antiga
  if (_preclimatRestoreTimer) { clearTimeout(_preclimatRestoreTimer); _preclimatRestoreTimer = null; }
  const { temp, fan, duration } = sched;
  console.log(`[preclimat] disparando — temp=${temp}°C fan=${fan} (${sched.time})`);
  _setPreclimatStatus('starting', 'Ligando o motor…',
    { temp, fan, endsAtMs: 0, alert: { title: '⏰ Pré-climatização', body: 'Ligando o motor…' } });

  // Passo 1: ligar motor via HA (mesmo mecanismo do botão do dashboard)
  if (HA_URL && HA_TOKEN) {
    const entityId = `button.${GWM_TOPIC_PREFIX}_ligar_o_motor`;
    try {
      const r = await fetch(`${HA_URL}/api/services/button/press`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${HA_TOKEN}`, 'Content-Type': 'application/json' },
        body: JSON.stringify({ entity_id: entityId }),
      });
      if (!r.ok) throw new Error(`HA HTTP ${r.status}`);
      _lastEngineOnCmdMs = Date.now();   // marca: foi comando NOSSO (pré-clima)
      console.log('[preclimat] comando engine_on enviado via HA');
    } catch (e) {
      console.error(`[preclimat] falha ao ligar motor: ${e.message}`);
      _setPreclimatStatus('failed', 'Não foi possível ligar o motor',
        { endsAtMs: Date.now() + 5 * 60_000,
          alert: { title: '⏰ Pré-climatização falhou', body: 'Não foi possível ligar o motor.' } });
      return;
    }
  } else {
    console.warn('[preclimat] HA não configurado — pulando engine_on');
  }

  // Passo 2: aguardar engine_state='1' por até 2 min (poll a cada 5s)
  const engineOk = await new Promise(resolve => {
    if (state.engine_state === '1') return resolve(true);
    let attempts = 0;
    const t = setInterval(() => {
      attempts++;
      if (state.engine_state === '1') { clearInterval(t); resolve(true); return; }
      if (attempts >= 24) { clearInterval(t); resolve(false); }
    }, 5_000);
  });

  if (!engineOk) {
    console.warn('[preclimat] timeout esperando engine_state=1');
    _setPreclimatStatus('failed', 'Motor não confirmou em 2 min',
      { endsAtMs: Date.now() + 5 * 60_000,
        alert: { title: '⏰ Pré-climatização falhou', body: 'Motor não confirmou em 2 min.' } });
    return;
  }

  console.log('[preclimat] motor confirmado — aguardando o carro restaurar o AC');
  _setPreclimatStatus('engine_on', 'Motor ligado ✓',
    { temp, fan, endsAtMs: 0, alert: { title: '🔑 Motor ligado', body: 'Pré-climatização: enviando temperatura e ventilação…' } });

  // Ao acordar, o carro publica fan=-1; só DEPOIS de ligar de fato ele restaura e
  // reporta o último ajuste do motorista. Espera esse estado real chegar (até ~12s)
  // antes de capturar — senão guardaríamos o estado "dormindo" e o AC voltaria off.
  await new Promise(resolve => {
    const ready = () => {
      const f = parseInt(state.hvac_fan_speed, 10);
      return Number.isFinite(f) && f >= 0 && state.hvac_ac_enable != null;
    };
    if (ready()) return resolve();
    let n = 0;
    const t = setInterval(() => { if (ready() || ++n >= 24) { clearInterval(t); resolve(); } }, 500);
  });
  await new Promise(r => setTimeout(r, 1_500));   // margem p/ temp/ac_enable assentarem

  // Se o motorista entrou durante a espera, não sobrescreve o ajuste dele.
  if (_preclimatAutoOffCancelled) {
    console.log('[preclimat] entrada detectada antes de aplicar o AC — mantém ajuste do motorista');
    return;
  }
  console.log(`[preclimat] estado real do AC: fan=${state.hvac_fan_speed} ac=${state.hvac_ac_enable} temp=${state.hvac_driver_temp} — enviando HVAC`);

  // Captura estado anterior do AC antes de sobrescrever
  const prevFan      = Math.max(0, parseInt(state.hvac_fan_speed, 10) || 0);  // -1/off → 0
  const prevDrvTemp  = parseFloat(state.hvac_driver_temp)    || null;
  const prevPassTemp = parseFloat(state.hvac_passenger_temp) || null;
  const prevAcEnable = state.hvac_ac_enable;   // '0'|'1'|null — pra restaurar no fim
  const _pc = parseInt(state.hvac_cycle_mode, 10);
  const prevCycle    = Number.isFinite(_pc) ? _pc : null;   // recirculação anterior (0/1) — restaura no fim
  // Guarda no escopo de módulo pra também restaurar se o usuário entrar e cancelar
  // o desligamento (_abortPreclimatAutoOff), não só no timer de fim.
  _preclimatPrevHvac = { fan: prevFan, drvTemp: prevDrvTemp, passTemp: prevPassTemp, acEnable: prevAcEnable, cycle: prevCycle };

  // Passo 3: LIGA o A/C via MQTT.
  // 1) power=1 → car.hvac.power_mode (MESTRE: 0=tudo off, 1=on). É o liga/desliga real.
  // 2) ac_enable=1 → compressor (sem ele só sopra ar ambiente, não climatiza).
  // 3) temperatura + fan.
  const fanStr  = fan.toString();
  const tempStr = temp.toFixed(1);
  mqttClient.publish(`${MQTT_PREFIX}/cmd/hvac/power`,          '1',     { qos: 1, retain: false });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/hvac/ac_enable`,      '1',     { qos: 1, retain: false });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/hvac/driver_temp`,    tempStr, { qos: 1, retain: false });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/hvac/passenger_temp`, tempStr, { qos: 1, retain: false });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/hvac/fan_speed`,      fanStr,  { qos: 1, retain: false });
  // Sempre puxa ar de FORA no pré-clima (cycle_mode=1 = ar externo, não recircula).
  mqttClient.publish(`${MQTT_PREFIX}/cmd/hvac/cycle_mode`,     '1',     { qos: 1, retain: false });

  const durStr = duration > 0 ? ` · desliga em ${duration} min` : '';
  const acEndsAtMs = duration > 0 ? Date.now() + duration * 60_000 : 0;
  _setPreclimatStatus('cooling', `Climatizando · ${temp.toFixed(0)}° · fan ${fan}/7`,
    { temp, fan, endsAtMs: acEndsAtMs,
      alert: { title: '⏰ Pré-climatização ativada',
               body: `Motor ligado · AC ${temp.toFixed(0)}° · ventilação ${fan}/7${durStr}` } });
  console.log(`[preclimat] AC ativado — temp=${temp} fan=${fan} duration=${duration}min (prev: fan=${prevFan} temp=${prevDrvTemp})`);

  // Passo 4: restaurar AC ao estado anterior + desligar motor após X minutos
  if (duration > 0) {
    // Se o motorista já entrou (porta aberta) enquanto subíamos o AC, nem agenda.
    if (_preclimatAutoOffCancelled) {
      console.log('[preclimat] entrada detectada antes do timer — não agenda desligamento');
      return;
    }
    _preclimatRestoreTimer = setTimeout(async () => {
      _preclimatRestoreTimer = null;
      // Trava de segurança: aborta o desligamento se o motorista entrou (porta)
      // ou se o carro já está em movimento — nunca desligar o motor dirigindo.
      if (_preclimatAutoOffCancelled) {
        console.log('[preclimat] timer expirou mas desligamento já foi cancelado — ignorando');
        return;
      }
      if ((+state.speed_kmh || 0) > 3) {
        console.log('[preclimat] carro em movimento no fim do timer — desligamento abortado');
        _abortPreclimatAutoOff('em movimento');
        return;
      }
      console.log('[preclimat] timer expirado — restaurando AC e desligando motor');
      _setPreclimatStatus('restoring', 'Restaurando AC e desligando motor…',
        { endsAtMs: 0, alert: { title: '⏰ Pré-climatização', body: 'Tempo encerrado — restaurando AC e desligando o motor…' } });

      // Restaura o AC ao estado anterior (temp/fan/master) antes de desligar o motor.
      await _restorePreclimatHvac();
      await new Promise(r => setTimeout(r, 3_000));

      // Reconfirma a trava após os delays (a porta pode ter aberto nesse meio).
      if (_preclimatAutoOffCancelled || (+state.speed_kmh || 0) > 3) {
        console.log('[preclimat] entrada/movimento durante a restauração — NÃO desliga o motor');
        return;
      }
      if (HA_URL && HA_TOKEN) {
        const entityId = `button.${GWM_TOPIC_PREFIX}_desligar_o_motor`;
        try {
          await fetch(`${HA_URL}/api/services/button/press`, {
            method: 'POST',
            headers: { Authorization: `Bearer ${HA_TOKEN}`, 'Content-Type': 'application/json' },
            body: JSON.stringify({ entity_id: entityId }),
          });
          console.log('[preclimat] engine_off enviado via HA');
        } catch (e) {
          console.error(`[preclimat] falha ao desligar motor: ${e.message}`);
        }
      }
      _setPreclimatStatus('ended', `Encerrada · motor desligado após ${duration} min`,
        { endsAtMs: Date.now() + 5 * 60_000,
          alert: { title: '⏰ Pré-climatização encerrada',
                   body: `AC restaurado · motor desligado após ${duration} min.` } });
    }, duration * 60_000);
  } else {
    // Sem duração definida: marca como encerrada na hora (LA some em 5 min).
    _setPreclimatStatus('ended', 'Pré-climatização ativada (sem desligamento automático)',
      { endsAtMs: Date.now() + 5 * 60_000,
        alert: { title: '⏰ Pré-climatização ativada', body: `AC ${temp.toFixed(0)}° · ventilação ${fan}/7 · sem desligamento automático` } });
  }
}

// ── Histórico de modos de condução ────────────────────────────────────────
// Cada segmento: { dm, tm, from_ts, to_ts }
// dm = drive_mode (0=HEV, 1=Prior.EV, 3=EV Puro)
// tm = terrain_mode (0=Normal, 1=Sport, 2=Eco, 3=Neve, 4=Areia, 5=Lama, 11=AWD)
const DRIVE_HISTORY_MAX = 5000;
let driveHistory = [];
try {
  if (fs.existsSync(DRIVE_HISTORY_FILE))
    driveHistory = JSON.parse(fs.readFileSync(DRIVE_HISTORY_FILE, 'utf8')) || [];
} catch (_) {}
function saveDriveHistory() {
  try { fs.writeFileSync(DRIVE_HISTORY_FILE, JSON.stringify(driveHistory)); } catch (_) {}
}

let _dmSegment = null; // segmento aberto: { dm, tm, from_ts }

function _closeDmSegment(to_ts) {
  if (!_dmSegment) return;
  const dur = to_ts - _dmSegment.from_ts;
  if (dur >= 5_000) { // ignora transições < 5s (ruído de inicialização)
    driveHistory.push({ dm: _dmSegment.dm, tm: _dmSegment.tm, from_ts: _dmSegment.from_ts, to_ts });
    if (driveHistory.length > DRIVE_HISTORY_MAX) driveHistory.shift();
    saveDriveHistory();
  }
  _dmSegment = null;
}

function _openDmSegment() {
  const dm = state.drive_mode  ?? null;
  const tm = state.terrain_mode ?? null;
  if (dm === null || tm === null) return; // espera ter os dois
  _dmSegment = { dm, tm, from_ts: Date.now() };
}

function _onDriveModeChange() {
  _closeDmSegment(Date.now());
  _openDmSegment();
}

// ── Preferências por device ────────────────────────────────────────────────
// notifPrefsByDevice = { <device_id>: { charge_start, charge_end, ... } }
// Cada push subscription tem um device_id estável (gerado no client e
// guardado no localStorage). Quando uma notificação dispara, cada sub é
// avaliada contra as prefs do seu device — não há mais "global".
// `notifPrefs` acima vira o fallback default pra devices sem prefs próprias.
const NOTIF_PREFS_BY_DEVICE_FILE = path.join(DATA_DIR, 'notif_prefs_by_device.json');
let notifPrefsByDevice = {};
try {
  if (fs.existsSync(NOTIF_PREFS_BY_DEVICE_FILE))
    notifPrefsByDevice = JSON.parse(fs.readFileSync(NOTIF_PREFS_BY_DEVICE_FILE, 'utf8')) || {};
} catch (_) { notifPrefsByDevice = {}; }
function saveNotifPrefsByDevice() {
  try { fs.writeFileSync(NOTIF_PREFS_BY_DEVICE_FILE, JSON.stringify(notifPrefsByDevice, null, 2)); } catch (_) {}
}

function getPrefsForDevice(deviceId) {
  // Device com prefs próprias (PWA, que salva por device) → elas (override sobre defaults).
  if (deviceId && notifPrefsByDevice[deviceId]) {
    return { ...NOTIF_DEFAULTS, ...notifPrefsByDevice[deviceId] };
  }
  // Device SEM id → app nativo, que configura via /api/push/prefs (GLOBAL). Usa o
  // global, senão o gating bloquearia TUDO (era o bug: app nativo registra o token
  // APNs com device_id vazio e não recebia nenhum banner, mesmo ativando em config).
  if (!deviceId) return { ...NOTIF_DEFAULTS, ...notifPrefs };
  // Device COM id mas sem prefs próprias → defaults (tudo OFF), pra não spammar
  // devices antigos registrados sem configuração.
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
        const meta = d._estimated ? {
          _estimated:       true,
          _estimatedFields: d._estimatedFields || [],
          _estimatedReason: d._estimatedReason || '',
        } : {};
        autoTripsArr.push({ tripId: d.tripId, ...d.autoTrip, ...hybrid, ...meta });
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
const MAX_EVENTS = 10000;
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
  last_update_ms:    null,    // última msg de QUALQUER fonte (carro APK ou GWM)
  last_apk_ms:       null,    // última msg do APK (haval/ecotrip/*)
  last_gwm_ms:       null,    // última msg da integração GWM Brasil (gwmbrasil_*)
  last_obd_ms:       null,    // última msg do OBD Companion (haval/ecotrip/obd/snapshot)
  car_last_update:   null,
  car_app_version:   null,

  gps_lat:          0,
  gps_lng:          0,
  gps_ts:           0,   // timestamp ms da última posição recebida
  car_heading:      0,   // rumo do carro (graus, 0=N) do deslocamento GPS; PERSISTIDO
  apns_prod_confirmed: false,  // watchdog: já confirmou (e notificou) o APNs de produção ativo

  speed_kmh:        0,
  steering_angle:   0,      // ângulo do volante (graus, ±) — gira o volante no PWA
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
  drive_mode:          null,   // 0=HEV, 1=Prior. EV, 3=EV (null = desconhecido)
  power_reserve:       null,   // sub-modo HEV: 1=Inteligente, 2=Prioritário
  charge_soc_target:   null,   // alvo SOC no modo Prioritário (20..80 %)
  terrain_mode:   null,   // 0=Normal, 1=Sport, 2=Eco, 3=Neve, 4=Areia, 5=Lama, 11=AWD
  regen_level:    null,   // 0=Normal, 1=Alto, 2=Baixo
  one_pedal:      null,   // 0=off, 1=on
  regen_power_pct: 0,     // energy_output_percentage (negativo = regenerando)
  esp_enable:     null,   // 0=off, 1=on
  steer_mode:     null,   // 0=Normal, 1=Sport, 2=Conforto
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
  hvac_acmax:          null, // null | '0'|'1' — resfriamento máximo
  hvac_anion:          null, // null | '0'|'1' — ionizador
  hvac_aqs:            null, // null | '0'|'1' — recirc. autom. qualidade do ar
  hvac_heating:        null, // null | '0'|'1' — aquecimento
  hvac_front_defrost:  null, // null | '0'|'1'
  hvac_rear_defrost:   null, // null | '0'|'1'
  hvac_auto_defrost:   null, // null | '0'|'1'
  hvac_pm25:           null, // null | int µg/m³ (leitura)
  hvac_blower_mode:    null, // null | 0..4 — direção do sopro
  hvac_power_mode:     null, // null | '0'|'1' — mestre do AC
  seat_belt_warning:   null, // null | '0'=ok | >0 = ocupante sentado sem cinto
  seated_state:        null, // null | ocupação dos bancos (formato cru, a confirmar)
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
      if (typeof v === 'object' && !Array.isArray(v) && target[k] !== null && typeof target[k] === 'object') {
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
    // Retoma o timer de live-notification se o carro já estava carregando
    // quando o server foi reiniciado. setImmediate garante que os `let` mais
    // abaixo (ex: _chargeLiveTimer) já estão inicializados antes de chamar.
    if (state.charging_state === 'Carregando') {
      setImmediate(() => startChargeLiveTimer());
    }
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
let deletedIds = { autotrips: [], charges: [], refuels: [], rules: [] };
// Sets paralelos pra lookup O(1) — array continua sendo a fonte de verdade
// (mantém ordem de inserção e serializa direto pro JSON).
let deletedIdsSets = { autotrips: new Set(), charges: new Set(), refuels: new Set(), rules: new Set() };
try {
  if (fs.existsSync(DELETED_IDS_FILE)) {
    const loaded = JSON.parse(fs.readFileSync(DELETED_IDS_FILE, 'utf8'));
    deletedIds = { autotrips: [], charges: [], refuels: [], rules: [], ...loaded };
  }
  for (const k of ['autotrips', 'charges', 'refuels', 'rules']) {
    deletedIdsSets[k] = new Set((deletedIds[k] || []).map(String));
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

// ── AC esquecido ligado com carro parado (velocidade = 0 por X min) ──────────
let _acParkedTimer   = null;   // setTimeout handle
let _acParkedSentAt  = 0;      // ts do último push para evitar re-envio imediato

function _cancelAcParkedTimer() {
  if (_acParkedTimer) { clearTimeout(_acParkedTimer); _acParkedTimer = null; }
}

function _scheduleAcParkedAlert() {
  _cancelAcParkedTimer();
  if (!notifPrefs.ac_on_parked) return;
  const mins = Math.max(1, +(notifPrefs.ac_on_parked_min) || 10);
  _acParkedTimer = setTimeout(() => {
    _acParkedTimer = null;
    if ((+state.speed_kmh || 0) > 0) return;             // carro se moveu
    const fan = parseInt(state.hvac_fan_speed, 10) || 0;
    if (fan <= 0) return;                                 // AC desligado (0) ou inválido (-1, carro dormindo)
    if (Date.now() - _acParkedSentAt < 30 * 60_000) return; // re-envio mín 30 min
    _acParkedSentAt = Date.now();
    sendPush('❄️ AC ligado com carro parado',
      `Ventilação ${fan}/7 há mais de ${mins} min. Lembre de desligar.`, 'ac_on_parked');
  }, mins * 60_000);
}

// ── Vidros esquecidos abertos após motor desligar ─────────────────────────────
let _windowForgottenTimer  = null;
let _windowForgottenSentAt = 0;

function _cancelWindowForgottenTimer() {
  if (_windowForgottenTimer) { clearTimeout(_windowForgottenTimer); _windowForgottenTimer = null; }
}

function _scheduleWindowForgottenAlert() {
  _cancelWindowForgottenTimer();
  // Usa o menor delay entre os devices com a notif ativa (ou global default)
  const minsArr = pushSubs
    .map(s => getPrefsForDevice(s.device_id))
    .filter(p => p.window_forgotten)
    .map(p => Math.max(1, +(p.window_forgotten_min) || 10));
  if (!minsArr.length) return;   // nenhum device ativou — não agenda
  const mins = Math.min(...minsArr);
  _windowForgottenTimer = setTimeout(() => {
    _windowForgottenTimer = null;
    if (state.engine_state !== '0') return;                          // motor voltou
    const openNames = ['fl','fr','rl','rr']
      .filter(s => state[`window_${s}`] === 'on')
      .map(s => WINDOW_NAMES[s] || s.toUpperCase());
    if (!openNames.length) return;                                    // tudo fechado
    if (Date.now() - _windowForgottenSentAt < 30 * 60_000) return;  // cooldown 30 min
    _windowForgottenSentAt = Date.now();
    sendPush('🪟 Vidro aberto com carro desligado',
      `${openNames.join(', ')} há mais de ${mins} min.`, 'window_forgotten');
  }, mins * 60_000);
}

// ── Carro destravado após motor desligar ──────────────────────────────────────
let _lockForgottenTimer  = null;
let _lockForgottenSentAt = 0;

function _cancelLockForgottenTimer() {
  if (_lockForgottenTimer) { clearTimeout(_lockForgottenTimer); _lockForgottenTimer = null; }
}

function _scheduleLockForgottenAlert() {
  _cancelLockForgottenTimer();
  const minsArr = pushSubs
    .map(s => getPrefsForDevice(s.device_id))
    .filter(p => p.lock_forgotten)
    .map(p => Math.max(1, +(p.lock_forgotten_min) || 5));
  if (!minsArr.length) return;
  const mins = Math.min(...minsArr);
  _lockForgottenTimer = setTimeout(() => {
    _lockForgottenTimer = null;
    if (state.engine_state !== '0') return;        // motor voltou
    if (state.lock_state !== 'on') return;          // foi trancado
    if (Date.now() - _lockForgottenSentAt < 30 * 60_000) return;
    _lockForgottenSentAt = Date.now();
    sendPush('🔓 Carro destravado com motor desligado',
      `Carro continua destrancado há mais de ${mins} min.`, 'lock_forgotten');
  }, mins * 60_000);
}

// ── Porta-malas esquecida aberta após motor desligar ──────────────────────────
let _trunkForgottenTimer  = null;
let _trunkForgottenSentAt = 0;

function _cancelTrunkForgottenTimer() {
  if (_trunkForgottenTimer) { clearTimeout(_trunkForgottenTimer); _trunkForgottenTimer = null; }
}

function _scheduleTrunkForgottenAlert() {
  _cancelTrunkForgottenTimer();
  if (state.door_trunk !== 'on') return;  // porta-malas já fechada
  const minsArr = pushSubs
    .map(s => getPrefsForDevice(s.device_id))
    .filter(p => p.trunk_forgotten)
    .map(p => Math.max(1, +(p.trunk_forgotten_min) || 10));
  if (!minsArr.length) return;
  const mins = Math.min(...minsArr);
  _trunkForgottenTimer = setTimeout(() => {
    _trunkForgottenTimer = null;
    if (state.engine_state !== '0') return;
    if (state.door_trunk !== 'on') return;
    if (Date.now() - _trunkForgottenSentAt < 30 * 60_000) return;
    _trunkForgottenSentAt = Date.now();
    sendPush('🧳 Porta-malas aberta com carro desligado',
      `Porta-malas continua aberta há mais de ${mins} min.`, 'trunk_forgotten');
  }, mins * 60_000);
}

// ── SOC baixo sem estar carregando ───────────────────────────────────────────
let _socLowIdleSentAt = 0;
const SOC_LOW_IDLE_COOLDOWN = 4 * 60 * 60_000; // 4h entre notifs

function checkSocLowIdle() {
  const minsArr = pushSubs
    .map(s => getPrefsForDevice(s.device_id))
    .filter(p => p.soc_low_idle);
  if (!minsArr.length) return;
  if (state.charging_state === 'Carregando') return;
  if (Date.now() - _socLowIdleSentAt < SOC_LOW_IDLE_COOLDOWN) return;
  const soc = +state.soc_pct || 0;
  if (!soc) return;
  // Use the lowest threshold across enabled devices
  const thresholds = minsArr.map(p => Math.max(1, Math.min(100, +(p.soc_low_idle_pct) || 20)));
  const threshold = Math.max(...thresholds); // alert if below ANY device's threshold
  if (soc >= threshold) return;
  _socLowIdleSentAt = Date.now();
  sendPush('🔋 Bateria do EV baixa',
    `SOC em ${soc.toFixed(0)}% e carro não está carregando.`, 'soc_low_idle');
}

// ── SOC baixo ao chegar num local sem carregar ────────────────────────────────
const _socArrivalTimers = {};  // { [placeId]: timeoutHandle }

function _scheduleSocArrivalAlert(place) {
  if (_socArrivalTimers[place.id]) return;  // já agendado pra este local
  // Verifica se algum device tem esta notif + este local configurado
  const eligible = pushSubs
    .map(s => ({ prefs: getPrefsForDevice(s.device_id) }))
    .filter(({ prefs }) => {
      if (!prefs.soc_arrival) return false;
      const places = (prefs.soc_arrival_places || []).map(String);
      return places.length === 0 || places.includes(String(place.id));
    })
    .map(({ prefs }) => prefs);
  if (!eligible.length) return;
  const mins = Math.min(...eligible.map(p => Math.max(1, +(p.soc_arrival_min) || 5)));
  _socArrivalTimers[place.id] = setTimeout(() => {
    delete _socArrivalTimers[place.id];
    if (geofenceState[place.id] !== 'in') return;  // saiu antes do timer
    if (state.charging_state === 'Carregando') return;  // está carregando
    const soc = +state.soc_pct || 0;
    if (!soc) return;
    const threshold = Math.max(...eligible.map(p => Math.max(1, Math.min(100, +(p.soc_arrival_pct) || 30))));
    if (soc >= threshold) return;
    sendPush('🔌 Chegou em ' + place.name + ' — bateria baixa',
      `SOC em ${soc.toFixed(0)}% e carro não está carregando.`, 'soc_arrival');
  }, mins * 60_000);
}

// ── Bateria mantida cheia (>95%) por mais de 24h ──────────────────────────────
let _socFullTimer   = null;
let _socFullSentAt  = 0;
const SOC_FULL_THRESHOLD = 95;
const SOC_FULL_HOURS     = 24;

function _checkSocFullLong(soc) {
  const enabled = pushSubs.some(s => getPrefsForDevice(s.device_id).soc_full_long);
  if (!enabled) { _cancelSocFullTimer(); return; }
  if (soc < SOC_FULL_THRESHOLD) { _cancelSocFullTimer(); return; }
  if (_socFullTimer) return;  // já agendado
  _socFullTimer = setTimeout(() => {
    _socFullTimer = null;
    const curSoc = +state.soc_pct || 0;
    if (curSoc < SOC_FULL_THRESHOLD) return;  // caiu entre o agendamento e o disparo
    if (Date.now() - _socFullSentAt < SOC_FULL_HOURS * 60 * 60_000) return;
    _socFullSentAt = Date.now();
    sendPush('⚡ Bateria mantida cheia',
      `SOC acima de ${SOC_FULL_THRESHOLD}% há mais de ${SOC_FULL_HOURS}h. Considere descarregar um pouco para preservar a bateria.`,
      'soc_full_long');
  }, SOC_FULL_HOURS * 60 * 60_000);
}

function _cancelSocFullTimer() {
  if (_socFullTimer) { clearTimeout(_socFullTimer); _socFullTimer = null; }
}

// ── Queda de pressão do pneu durante viagem ───────────────────────────────────
const TYRE_POSITIONS = ['fl', 'fr', 'rl', 'rr'];
let _tyreTripBaseline = {};    // { fl: psi, fr: psi, rl: psi, rr: psi }
let _tyreDropAlertSent = {};   // { fl: bool, ... }

function _resetTyreTrip() {
  _tyreTripBaseline = {};
  _tyreDropAlertSent = {};
}

function _captureTyreBaseline() {
  for (const pos of TYRE_POSITIONS) {
    const psi = +state[`tyre_pressure_${pos}`] || 0;
    if (psi > 5 && !_tyreTripBaseline[pos]) _tyreTripBaseline[pos] = psi;
  }
}

function checkTyreDrop(pos, currentPsi) {
  // Segurança: detecta SEMPRE (independe do toggle) pra destacar o pneu na LA de
  // Viagem. A notificação respeita a pref tyre_drop (default LIGADA).
  if ((+state.speed_kmh || 0) < 5) return;  // parado — não avalia
  if (!_tyreTripBaseline[pos]) { _captureTyreBaseline(); return; }
  if (_tyreDropAlertSent[pos]) return;
  const dropPsi = Math.max(1, +notifPrefs.tyre_drop_psi || 4);
  const drop = _tyreTripBaseline[pos] - currentPsi;
  if (drop < dropPsi) return;
  _tyreDropAlertSent[pos] = true;   // ← destaca o pneu na LA de Viagem
  const name = { fl: 'Dianteiro Esq.', fr: 'Dianteiro Dir.', rl: 'Traseiro Esq.', rr: 'Traseiro Dir.' }[pos] || pos.toUpperCase();
  sendPush('⚠️ Queda de pressão detectada',
    `${name}: ${currentPsi.toFixed(1)} PSI (era ${_tyreTripBaseline[pos].toFixed(1)} PSI, queda de ${drop.toFixed(1)} PSI)`,
    'tyre_drop');
}

// ── Bateria 12V baixa ────────────────────────────────────────────────────────
let _batt12LowSentAt = 0;
const BATT12_LOW_PCT = 50;       // threshold %
const BATT12_LOW_COOLDOWN = 60 * 60_000; // 1 hora entre notifs

function checkBatt12Low() {
  if (!notifPrefs.batt12_low) return;
  const pct = +state.batt_12v_pct || 0;
  if (pct <= 0 || pct > BATT12_LOW_PCT) return;
  if (Date.now() - _batt12LowSentAt < BATT12_LOW_COOLDOWN) return;
  _batt12LowSentAt = Date.now();
  sendPush('🔋 Bateria auxiliar baixa',
    `12V em ${pct.toFixed(0)}% · verifique se há dreno excessivo.`, 'batt12_low');
}

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
    // PREFERE total/energy_kwh atual em vez do perKwh salvo. Se energy_kwh
    // for corrigido após o user setar override, o perKwh fica defasado
    // mas (total / energy) sempre reflete a realidade da sessão.
    let pricePerKwh = ovr?.free === true ? 0
                    : ovr && +ovr.total  > 0 ? (+ovr.total / energy)
                    : ovr && +ovr.perKwh > 0 ? +ovr.perKwh
                    : SEED_KWH_PRICE;
    // Anti-outlier: R$/kWh > 5 indica erro de input ou energy_kwh parcial.
    // Cai pro SEED em vez de contaminar o avg.
    if (pricePerKwh > 5) {
      console.warn(`[charge] pricePerKwh anormal ts=${c.timestamp_ms}: R$ ${pricePerKwh.toFixed(2)}/kWh — usando SEED ${SEED_KWH_PRICE}`);
      pricePerKwh = SEED_KWH_PRICE;
    }
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

// ── Monitor do certificado TLS Let's Encrypt ─────────────────────────────────
// DuckDNS add-on renova sozinho, mas se quebrar (rate limit, bug, DNS) o cert
// expira em silêncio. Checamos 1×/dia (e 1× no boot) via handshake TLS na
// porta 8883 e parseamos o validTo. Alerta se faltar menos de 7 dias.
const CERT_HOST = (process.env.CAR_MQTT_HOST || 'mqttrafael.duckdns.org').replace(/^mqtts?:\/\//, '');
const CERT_PORT = parseInt(process.env.CAR_MQTT_PORT || '8883', 10);
let _certWarnNotifiedDay = '';   // 'YYYY-MM-DD' do último alerta — anti-spam diário
function _checkCertExpiry() {
  const tls = require('tls');
  const socket = tls.connect({ host: CERT_HOST, port: CERT_PORT, servername: CERT_HOST, rejectUnauthorized: false, timeout: 8000 }, () => {
    try {
      const cert = socket.getPeerCertificate();
      socket.end();
      if (!cert || !cert.valid_to) return;
      const expiry = new Date(cert.valid_to).getTime();
      const daysLeft = Math.floor((expiry - Date.now()) / 86_400_000);
      console.log(`[cert] ${CERT_HOST}:${CERT_PORT} valid until ${cert.valid_to} (${daysLeft}d restantes)`);
      const today = new Date().toISOString().slice(0, 10);
      if (daysLeft < 7 && _certWarnNotifiedDay !== today) {
        _certWarnNotifiedDay = today;
        sendPush('🔒 Certificado TLS próximo do vencimento',
          `Cert do broker expira em ${daysLeft} dia(s). Verifique o add-on DuckDNS no HA.`,
          'anomaly_detected', { renotify: true });
      }
    } catch (e) { console.warn('[cert] parse falhou:', e.message); }
  });
  socket.on('error', e => console.warn(`[cert] check falhou: ${e.code || e.message}`));
  socket.on('timeout', () => { console.warn('[cert] check timeout'); socket.destroy(); });
}
setTimeout(_checkCertExpiry, 30_000);          // 1ª verificação 30s após boot
setInterval(_checkCertExpiry, 24 * 60 * 60_000); // depois diário

// Watchdog do car_online: se não chega mensagem do carro há >30s, marca offline.
// Cobre o caso raro de queda silenciosa em que nem a LWT chegou.
setInterval(() => {
  if (!state.car_online) return;
  const ageSec = (Date.now() - (state.last_update_ms || 0)) / 1000;
  if (ageSec > 30) {
    state.car_online = false;
    console.log(`[mqtt] watchdog: marcando carro offline (sem msg há ${Math.round(ageSec)}s)`);
  }
}, 10_000);

// Watchdog POR FONTE: detecta quando UMA das pernas (APK ou GWM) cai sozinha.
// Cenário que motivou: GWM Brasil parou de publicar mas o APK continuou — sem
// alerta visível, dados ficaram defasados (SOC). Agora, se uma fonte ficar >10min
// silenciosa enquanto a outra continua atualizando, notifica uma vez por hora.
//
// REGRA PRÁTICA: o APK só transmite quando o head unit do carro está ligado.
// Quando o carro está estacionado/dormindo (gear=P, sem carregar, sem driving_ready),
// é NORMAL o APK ficar silencioso — não dispara alerta. Já o GWM (HA Brasil) é
// polled pelo HA e DEVE continuar respondendo mesmo com carro dormindo — silêncio
// dele é sempre anomalia.
let _sourceStallNotifiedApk = 0;
let _sourceStallNotifiedGwm = 0;
const SOURCE_STALL_MS  = 10 * 60_000;          // 10 min de silêncio = stalled
const SOURCE_NOTIF_GAP = 60 * 60_000;          // não repete antes de 1h

/** True quando há sinal de que o carro está "em uso" — em movimento, com
 *  motor pronto, ou carregando. Nesses casos o APK DEVE estar publicando.
 *
 *  IMPORTANTE: só confia em state.gear/driving_ready/speed se a FONTE que
 *  publicou esses campos ainda está VIVA. Se APK silente E GWM também stale,
 *  tudo no state é antigo — não dá pra saber. Trata como "carro dormindo"
 *  (não-acordado) e evita falso-positivo de notificação. */
function _carIsAwake() {
  const now    = Date.now();
  const apkAge = now - (state.last_apk_ms || 0);
  const gwmAge = now - (state.last_gwm_ms || 0);
  // Se NENHUMA fonte publicou recentemente, state está stale —
  // não há como saber se o carro está em uso. Assume dormindo.
  const apkFresh = state.last_apk_ms && apkAge < 90_000;          // APK publica a cada poucos segundos
  const gwmFresh = state.last_gwm_ms && gwmAge < 5 * 60_000;      // GWM é polled a cada 30s-2min
  if (!apkFresh && !gwmFresh) return false;
  const gear   = String(state.gear || 'P').toUpperCase();
  const ready  = state.driving_ready === 1 || state.driving_ready === true;
  const chrg   = state.charging_state === 1;
  const speed  = +state.speed_kmh || 0;
  const power  = state.power_mode != null && +state.power_mode > 0;
  return ready || chrg || speed > 1 || power || (gear !== 'P' && gear !== 'N');
}

setInterval(() => {
  const now    = Date.now();
  const apkMs  = state.last_apk_ms || 0;
  const gwmMs  = state.last_gwm_ms || 0;
  // Só faz sentido comparar quando AMBAS fontes já produziram algo nesta sessão.
  if (apkMs === 0 || gwmMs === 0) return;
  const apkAge = now - apkMs;
  const gwmAge = now - gwmMs;
  // APK silente mas GWM ativo → só alerta se o carro estiver ACORDADO.
  // Carro dormindo (gear=P + parado + sem carregar) silencia esse alerta — é o normal.
  if (apkAge > SOURCE_STALL_MS && gwmAge < SOURCE_STALL_MS &&
      (now - _sourceStallNotifiedApk) > SOURCE_NOTIF_GAP &&
      _carIsAwake()) {
    _sourceStallNotifiedApk = now;
    const min = Math.round(apkAge / 60_000);
    console.log(`[watchdog] APK silente há ${min}min com CARRO ACORDADO (gear=${state.gear} chrg=${state.charging_state} ready=${state.driving_ready})`);
    sendPush('📡 App do carro silente',
      `Sem dados do app no carro há ${min}min (integração GWM continua ativa).`,
      'anomaly_detected');
  }
  // GWM silente mas APK ativo → SEMPRE notifica (HA é polled, deveria sempre responder).
  if (gwmAge > SOURCE_STALL_MS && apkAge < SOURCE_STALL_MS && (now - _sourceStallNotifiedGwm) > SOURCE_NOTIF_GAP) {
    _sourceStallNotifiedGwm = now;
    const min = Math.round(gwmAge / 60_000);
    console.log(`[watchdog] GWM silente há ${min}min (APK ativo)`);
    sendPush('🛰️ Integração GWM silente',
      `Sem dados da GWM Brasil/HA há ${min}min (app do carro continua ativo). Verifique a integração.`,
      'anomaly_detected');
  }
}, 60_000);

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
// ── Heading do carro (orientação no mapa) ───────────────────────────────────
// Calculado do deslocamento GPS quando em movimento (>3 km/h e >5 m), guardado
// em state.car_heading (PERSISTIDO via scheduleStateSave). Assim o marcador do
// PWA acerta o rumo mesmo parado, ao abrir o app ou após restart do bridge —
// não depende de cada cliente recalcular. 0 = Norte.
let _headingPrevLat = null, _headingPrevLng = null;
function _maybeUpdateCarHeading() {
  const lat = +state.gps_lat, lng = +state.gps_lng;
  if (!lat || !lng) return;
  if (_headingPrevLat == null) { _headingPrevLat = lat; _headingPrevLng = lng; return; }
  if (haversineM(_headingPrevLat, _headingPrevLng, lat, lng) < 5) return;   // movimento mínimo (~5 m)
  if ((+state.speed_kmh || 0) > 1) {   // ≥1 km/h: atualiza rumo até em manobra lenta (5 m filtra jitter)
    const toRad = d => d * Math.PI / 180, toDeg = r => r * 180 / Math.PI;
    const f1 = toRad(_headingPrevLat), f2 = toRad(lat), dl = toRad(lng - _headingPrevLng);
    const y = Math.sin(dl) * Math.cos(f2);
    const x = Math.cos(f1) * Math.sin(f2) - Math.sin(f1) * Math.cos(f2) * Math.cos(dl);
    state.car_heading = Math.round((toDeg(Math.atan2(y, x)) + 360) % 360);
    scheduleStateSave();
  }
  _headingPrevLat = lat;
  _headingPrevLng = lng;
}

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
        _scheduleSocArrivalAlert(loc);
      }
    } else if (isOutside && prev !== 'out') {
      geofenceState[loc.id] = 'out';
      if (_socArrivalTimers[loc.id]) { clearTimeout(_socArrivalTimers[loc.id]); delete _socArrivalTimers[loc.id]; }
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
const _certFile  = path.join(DATA_DIR, 'cert.pem');
const _keyFile   = path.join(DATA_DIR, 'key.pem');
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

// ── Proxy pra Ellevar Clockin (app de ponto separado em :3010) ─────────────
// /clockin/* passa direto, sem auth do Haval. App tem auth propria (PIN + WebAuthn).
const _clockinProxy = require('http-proxy').createProxyServer({ ws: true, xfwd: true });
_clockinProxy.on('error', (err, req, res) => {
  console.warn('[clockin] proxy erro:', err.message);
  if (res && res.writeHead && !res.headersSent) { res.writeHead(502); res.end('clockin offline'); }
});
function _isClockinPath(u) {
  return typeof u === 'string' && (u === '/clockin' || u.startsWith('/clockin/') || u.startsWith('/clockin?'));
}
app.use((req, res, next) => {
  if (_isClockinPath(req.url)) return _clockinProxy.web(req, res, { target: 'http://127.0.0.1:3010' });
  next();
});
server.on('upgrade', (req, socket, head) => {
  if (_isClockinPath(req.url)) _clockinProxy.ws(req, socket, head, { target: 'http://127.0.0.1:3010' });
});

app.use(require('compression')());  // gzip — backup de 11MB cai pra ~1.5MB
app.use(express.json({ limit: '200mb' }));
app.use((req, res, next) => {
  // Sem isso, o URLSession (iOS) pode cachear por heurística respostas de sync
  // (sem Cache-Control) e servir corpo antigo. Boa prática pra APIs dinâmicas.
  if (req.path.startsWith('/api')) res.setHeader('Cache-Control', 'no-store, must-revalidate');
  next();
});
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
// O app iOS usa um OAuth client iOS próprio → o ID token vem com aud = client iOS,
// diferente do client web. Aceitamos ambos como audiência válida.
const GOOGLE_IOS_CLIENT_ID   = process.env.GOOGLE_IOS_CLIENT_ID || '';
const GOOGLE_AUDIENCES = [GOOGLE_OAUTH_CLIENT_ID, GOOGLE_IOS_CLIENT_ID].filter(Boolean);
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
      audience: GOOGLE_AUDIENCES,
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

// ── Sign in with Apple ────────────────────────────────────────────────────
// aud do ID token nativo = o App ID (bundle). Verificamos a assinatura RS256 com
// as chaves públicas da Apple (JWKS) — Node converte JWK→chave nativamente.
const APPLE_CLIENT_IDS = (process.env.APPLE_CLIENT_ID || process.env.APNS_BUNDLE_ID || '')
  .split(',').map(s => s.trim()).filter(Boolean);
const APPLE_ALLOWED_EMAILS = (process.env.APPLE_ALLOWED_EMAILS || process.env.GOOGLE_ALLOWED_EMAILS || '')
  .split(',').map(s => s.trim().toLowerCase()).filter(Boolean);
const APPLE_ENABLED = APPLE_CLIENT_IDS.length > 0;
if (APPLE_ENABLED) console.log(`✓ Sign in with Apple: aud=${APPLE_CLIENT_IDS.join(',')} · ${APPLE_ALLOWED_EMAILS.length} email(s) na whitelist`);

let _appleJwksCache = { keys: [], ts: 0 };
async function _appleJwks() {
  if (_appleJwksCache.keys.length && (Date.now() - _appleJwksCache.ts) < 3600_000) return _appleJwksCache.keys;
  const r = await fetch('https://appleid.apple.com/auth/keys');
  const d = await r.json();
  _appleJwksCache = { keys: d.keys || [], ts: Date.now() };
  return _appleJwksCache.keys;
}
async function _verifyAppleIdToken(idToken) {
  const crypto = require('crypto');
  const [h, p, s] = String(idToken).split('.');
  if (!h || !p || !s) throw new Error('token malformado');
  const header  = JSON.parse(Buffer.from(h, 'base64').toString('utf8'));
  const jwk = (await _appleJwks()).find(k => k.kid === header.kid);
  if (!jwk) throw new Error('kid desconhecido');
  const pub = crypto.createPublicKey({ key: jwk, format: 'jwk' });
  const ok  = crypto.verify('RSA-SHA256', Buffer.from(`${h}.${p}`), pub, Buffer.from(s, 'base64url'));
  if (!ok) throw new Error('assinatura inválida');
  const payload = JSON.parse(Buffer.from(p, 'base64').toString('utf8'));
  if (payload.iss !== 'https://appleid.apple.com') throw new Error('iss inválido');
  if (!APPLE_CLIENT_IDS.includes(payload.aud)) throw new Error('aud inválido (' + payload.aud + ')');
  if ((payload.exp || 0) * 1000 < Date.now()) throw new Error('expirado');
  return payload;
}

app.get('/api/auth/apple/config', (_req, res) => res.json({
  enabled: APPLE_ENABLED, client_id: APPLE_CLIENT_IDS[0] || null,
}));

// POST /api/auth/apple/login — { credential (ID token), totp_code? } → { ok, token }
app.post('/api/auth/apple/login', async (req, res) => {
  if (!APPLE_ENABLED) return res.status(503).json({ error: 'apple_login_disabled' });
  const ip = req.ip || req.connection?.remoteAddress || 'unknown';
  const rl = _checkRateLimit(ip);
  if (!rl.ok) return res.status(429).json({ error: 'rate_limited', retry_after_sec: rl.retryAfterSec });
  if (rl.state.count >= 5) return res.status(429).json({ error: 'too_many_attempts' });

  const { credential, totp_code } = req.body || {};
  if (!credential) return res.status(400).json({ error: 'missing_credential' });

  let payload;
  try { payload = await _verifyAppleIdToken(credential); }
  catch (e) { _registerFailure(rl.state); return res.status(401).json({ error: 'invalid_credential', detail: e.message }); }

  const email = (payload.email || '').toLowerCase();
  if (!email) {  // Apple só manda email se o usuário concedeu; sub é estável
    _registerFailure(rl.state);
    return res.status(401).json({ error: 'email_missing', sub: payload.sub });
  }
  if (APPLE_ALLOWED_EMAILS.length > 0 && !APPLE_ALLOWED_EMAILS.includes(email)) {
    _registerFailure(rl.state);
    console.warn(`[auth] login Apple NEGADO · email fora da whitelist: ${email}`);
    return res.status(403).json({ error: 'email_not_allowed', email });
  }
  if (is2faEnabled()) {
    if (!totp_code) return res.status(401).json({ error: 'totp_required', requires_2fa: true, email });
    if (!verifyTotpOrBackup(totp_code)) { _registerFailure(rl.state); return res.status(401).json({ error: 'invalid_totp' }); }
  }

  _registerSuccess(ip);
  console.log(`[auth] login Apple OK · ${email}`);
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
      req.path === '/auth/passkey/login/finish' ||
      req.path === '/pair/redeem' ||
      req.path === '/mapkit/token') return next();   // mapkit/token: JWT só vale pra Apple Maps, não dá acesso a nada do bridge
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
const PASSKEYS_FILE = path.join(DATA_DIR, 'passkeys.json');
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

app.get('/api/state',  (_req, res) => res.json({ ...state, _field_source: _fieldSource }));
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

// Cursor de sync incremental: ignora `since` no futuro. O relógio do carro/APK
// já publicou recargas com timestamp_ms adiantado; o cliente (SyncedList) avança
// o ponteiro pro maior campo visto e, com um valor futuro, fica preso — `?since=
// <futuro>` passa a retornar vazio pra sempre e dados novos somem. Clampa pra 0
// (full sync) quando o cursor está à frente do relógio do servidor.
function parseSince(req) {
  const s = parseInt(req.query.since || '0', 10);
  if (!Number.isFinite(s) || s <= 0) return 0;
  return s > Date.now() + 60_000 ? 0 : s;
}

app.get('/api/charges', (req, res) => {
  const since = parseSince(req);
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
const CHARGE_TELEMETRY_DIR = path.join(DATA_DIR, 'charge_telemetry');
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

// ── Automações (regras) ───────────────────────────────────────────────────────
// Fonte da verdade pra EDIÇÃO (sincroniza iPhone↔iPad via ?since=). A EXECUÇÃO é
// no carro: ao salvar, publica a lista completa em cmd/rules/set (retido) e o APK
// persiste + avalia sozinho. Ver AutomationManager no app.
let automationRules = [];
try {
  if (fs.existsSync(RULES_FILE)) automationRules = JSON.parse(fs.readFileSync(RULES_FILE, 'utf8'));
  if (!Array.isArray(automationRules)) automationRules = [];
  if (automationRules.length) console.log(`✓ Automações carregadas: ${automationRules.length}`);
} catch (_) { automationRules = []; }

function saveRules() {
  try { fs.writeFileSync(RULES_FILE, JSON.stringify(automationRules, null, 2)); }
  catch (e) { console.error('saveRules:', e.message); }
}
// Publica a lista completa no carro (RETIDO → chega mesmo se o carro estava off).
function relayRules() {
  if (!mqttClient?.connected) return false;
  try {
    mqttClient.publish(`${MQTT_PREFIX}/cmd/rules/set`, JSON.stringify(automationRules), { qos: 1, retain: true });
    return true;
  } catch (e) { console.error('relayRules:', e.message); return false; }
}

// GET /api/rules?since=  → array (espelha SyncedList: _updated_ms + X-Tombstones)
app.get('/api/rules', (req, res) => {
  const since = parseSince(req);
  const arr = since > 0 ? automationRules.filter(r => (r._updated_ms || 0) > since) : automationRules;
  if (Array.isArray(deletedIds.rules) && deletedIds.rules.length) {
    res.setHeader('X-Tombstones', deletedIds.rules.join(','));
    res.setHeader('Access-Control-Expose-Headers', 'X-Tombstones');
  }
  res.json(arr);
});

// POST /api/rules  → cria/atualiza uma regra (upsert por id) + relay pro carro.
app.post('/api/rules', (req, res) => {
  const r = req.body;
  if (!r || typeof r !== 'object' || !r.trigger || !r.action) {
    return res.status(400).json({ error: 'regra inválida (precisa de trigger e action)' });
  }
  if (!r.id) r.id = 'rule_' + Date.now();
  r._updated_ms = Date.now();
  if (r.enabled === undefined) r.enabled = true;
  const idx = automationRules.findIndex(x => x.id === r.id);
  if (idx >= 0) automationRules[idx] = r; else automationRules.push(r);
  saveRules();
  const relayed = relayRules();
  res.json({ ok: true, rule: r, relayed });
});

// DELETE /api/rules/:id → remove + tombstone + relay
app.delete('/api/rules/:id', (req, res) => {
  const id = String(req.params.id);
  const idx = automationRules.findIndex(x => String(x.id) === id);
  if (idx === -1) return res.status(404).json({ error: 'não encontrada' });
  automationRules.splice(idx, 1);
  markDeleted('rules', id);
  saveRules();
  const relayed = relayRules();
  res.json({ ok: true, relayed });
});

// ── Locais de AUTOMAÇÃO (separados dos Locais Conhecidos de recarga/trajeto) ───
// Automação LÊ os locais conhecidos (pra oferecer como opção), mas o que cria na
// automação fica AQUI — nunca polui known_places.
let automationPlaces = [];
try {
  if (fs.existsSync(AUTO_PLACES_FILE)) automationPlaces = JSON.parse(fs.readFileSync(AUTO_PLACES_FILE, 'utf8'));
  if (!Array.isArray(automationPlaces)) automationPlaces = [];
} catch (_) { automationPlaces = []; }
function saveAutoPlaces() {
  try { fs.writeFileSync(AUTO_PLACES_FILE, JSON.stringify(automationPlaces, null, 2)); }
  catch (e) { console.error('saveAutoPlaces:', e.message); }
}

// Catálogo de chaves do carro (referência pra montar condições/ações de automação).
// Derivado de CarConstants.kt (APK). `values` descreve o tipo/semântica do valor.
// `w: true` = gravável (pode ser usado em ação "avançado"). Ordenado por key no GET.
const CAR_KEYS_CATALOG = [
  { key: 'car.basic.instant_fuel_consumption', label: 'Consumo instantâneo (combustível)', values: 'número (L/100km)' },
  { key: 'car.ev_info.instant_energy_consumption', label: 'Consumo instantâneo (energia)', values: 'número (kWh/100km)' },
  { key: 'car.ev_info.energy_output_percentage', label: 'Saída de energia', values: 'número (%)' },
  { key: 'car.ev_info.cycle_fuel_consume_info', label: 'Combustível consumido no ciclo', values: 'número' },
  { key: 'car.ev_info.cycle_energy_consume_info', label: 'Energia consumida no ciclo', values: 'número' },
  { key: 'car.ev_info.energy_recovery_info', label: 'Energia recuperada (regen)', values: 'número' },
  { key: 'car.basic.remain_fuel_percentage', label: 'Combustível restante', values: 'número (%)' },
  { key: 'car.basic.cur_journey_odometer', label: 'Odômetro da viagem', values: 'número (km)' },
  { key: 'car.basic.total_odometer', label: 'Odômetro total', values: 'número (km)' },
  { key: 'car.basic.vehicle_speed', label: 'Velocidade', values: 'número (km/h)' },
  { key: 'car.basic.steering_wheel_angle', label: 'Ângulo do volante', values: 'número (graus, ±)' },
  { key: 'car.basic.engine_speed', label: 'RPM do motor', values: 'número' },
  { key: 'car.basic.power_mode', label: 'Power mode (chassi)', values: '0 / 1' },
  { key: 'car.basic.inside_temp', label: 'Temperatura interna', values: 'número (°C)' },
  { key: 'car.basic.outside_temp', label: 'Temperatura externa', values: 'número (°C)' },
  { key: 'car.ev_info.battery_charge_percentage', label: 'Carga da bateria', values: 'número (%)' },
  { key: 'car.ev_info.soc_of_battery', label: 'SOC da bateria', values: 'número (%)' },
  { key: 'car.ev_info.cur_battery_power_percentage', label: 'Potência atual da bateria', values: 'número (%)' },
  { key: 'car.ev_info.cur_charge_current', label: 'Corrente de carga', values: 'número (A)' },
  { key: 'car.ev_info.power_battery_voltage', label: 'Tensão do pack', values: 'número (V)' },
  { key: 'car.ev_info.power_battery_current', label: 'Corrente do pack', values: 'número (A)' },
  { key: 'car.basic.battery_voltage', label: 'Tensão da bateria (basic)', values: 'número (V)' },
  { key: 'car.ev_info.motor_power', label: 'Potência do motor', values: 'número (kW; + consumo / − regen)' },
  { key: 'car.ev_info.charging_state', label: 'Estado de recarga', values: '0=Desconectado · 1=Carregando · 2=Programado · 3=Finalizado · 5=Aguardando' },
  { key: 'car.ev_info.charge_remaining_time', label: 'Tempo restante de recarga', values: 'número (min)' },
  { key: 'car.basic.vehicle_model1', label: 'ID do modelo (1)', values: 'número' },
  { key: 'car.basic.vehicle_model2', label: 'ID do modelo (2)', values: 'número' },
  { key: 'car.ev_setting.charge_soc_limit_config', label: 'Limite de carga (SOC)', values: '0–5 (a confirmar)', w: true },
  { key: 'car.ev_setting.power_model_config', label: 'Modo PHEV', values: '0=HEV · 1=Prioridade EV · 3=EV puro', w: true },
  { key: 'car.ev_setting.power_reserve_config', label: 'Reserva de energia (HEV)', values: '1=Inteligente · 2=Prioritário', w: true },
  { key: 'car.ev_setting.charge_soc_target_config', label: 'SOC alvo (HEV prioritário)', values: '20–80 (%)', w: true },
  { key: 'car.basic.gear_status', label: 'Marcha', values: '0=N · 2=D · 3=P · 4=R' },
  { key: 'car.basic.driving_ready_state', label: 'Pronto para condução', values: '0=desligado · 1=pronto' },
  { key: 'car.comfort_setting.driver_seat_ventilation_level', label: 'Ventilação banco motorista', values: '0=off · 1/2/3=nível' },
  { key: 'car.comfort_setting.passenger_seat_ventilation_level', label: 'Ventilação banco passageiro', values: '0=off · 1/2/3=nível' },
  { key: 'car.hvac.driver_temperature', label: 'Temperatura AC (motorista)', values: 'número (°C)' },
  { key: 'car.hvac.pass_temperature', label: 'Temperatura AC (passageiro)', values: 'número (°C)' },
  { key: 'car.hvac.fan_speed', label: 'Velocidade do ventilador', values: '1–7' },
  { key: 'car.hvac.sync_enable', label: 'Sincronizar AC', values: '0=off · 1=on' },
  { key: 'car.hvac.auto_enable', label: 'AC automático', values: '0=off · 1=on' },
  { key: 'car.hvac.ac_enable', label: 'AC ligado (mestre)', values: '0=off · 1=on' },
  { key: 'car.hvac.cycle_mode', label: 'Recirculação do ar', values: '0=interna · 1=externa' },
  { key: 'car.hvac.acmax_enable', label: 'AC máximo', values: '0=off · 1=on' },
  { key: 'car.hvac.anion_enable', label: 'Ionizador', values: '0=off · 1=on' },
  { key: 'car.hvac.aqs_enable', label: 'Recirculação automática (AQS)', values: '0=off · 1=on' },
  { key: 'car.hvac.heating_enable', label: 'Aquecimento', values: '0=off · 1=on' },
  { key: 'car.hvac.front_defrost_enable', label: 'Desembaçador dianteiro', values: '0=off · 1=on' },
  { key: 'car.hvac.rear_defrost_enable', label: 'Desembaçador traseiro', values: '0=off · 1=on' },
  { key: 'car.hvac.setting.auto_defrost_enable', label: 'Desembaçador automático', values: '0=off · 1=on' },
  { key: 'car.hvac.pm2.5_value', label: 'PM2.5 (qualidade do ar)', values: 'número (µg/m³)' },
  { key: 'car.hvac.blower_mode', label: 'Direção do ar', values: '0=frente · 1=frente+pés · 2=pés · 3=pés+parabrisa · 4=parabrisa' },
  { key: 'car.hvac.power_mode', label: 'AC power mode (mestre)', values: '0=off · 1=on' },
  { key: 'car.basic.door_lock_status', label: 'Trava das portas', values: '0=trancado · 1=destrancado (a confirmar)' },
  { key: 'car.basic.door_status', label: 'Portas', values: 'CSV "FL,FR,RL,RR,Trunk" — 0=fechada · 1=aberta' },
  { key: 'car.basic.window_status', label: 'Vidros', values: 'CSV "FL,FR,RL,RR" — 0=fechado · ≠0=aberto' },
  { key: 'car.basic.sunroof_status', label: 'Teto solar', values: '0=fechado · >0=aberto' },
  { key: 'car.basic.seat_belt_warning', label: 'Aviso de cinto', values: '0=ok · >0=ocupante sem cinto' },
  { key: 'car.basic.seated_state', label: 'Ocupação dos bancos', values: 'CSV (X,X,X,X,X), 0/1 por assento. Use [N] p/ posição: passageiro = car.basic.seated_state[1]' },
  { key: 'car.drive_setting.drive_mode', label: 'Modo de condução', values: '0=Normal · 1=Sport · 2=Eco · 3=Neve · 4=Areia · 5=Lama · 11=AWD', w: true },
  { key: 'car.ev_setting.energy_recovery_level', label: 'Nível de regeneração', values: '0=Normal · 1=Alto · 2=Baixo', w: true },
  { key: 'car.ev.setting.pedal_control_enable', label: 'Condução de um pedal', values: '0=off · 1=on', w: true },
  { key: 'car.drive_setting.esp_enable', label: 'ESP (estabilidade)', values: '0=off · 1=on', w: true },
  { key: 'car.drive_setting.steering_wheel_assist_mode', label: 'Assistência da direção', values: '0=Normal · 1=Sport · 2=Conforto', w: true },
];

app.get('/api/car-keys', (_req, res) => {
  res.json([...CAR_KEYS_CATALOG].sort((a, b) => a.key.localeCompare(b.key)));
});

app.get('/api/automation-places', (_req, res) => res.json(automationPlaces));

app.post('/api/automation-places', (req, res) => {
  const { name, lat, lng, radius_m } = req.body || {};
  if (!name || !String(name).trim()) return res.status(400).json({ error: 'nome obrigatório' });
  const place = {
    id: 'ap_' + Date.now(),
    name: String(name).trim(),
    lat: lat ?? null, lng: lng ?? null,
    radius_m: radius_m ?? 30,
  };
  automationPlaces.push(place);
  saveAutoPlaces();
  res.json(place);
});

app.put('/api/automation-places/:id', (req, res) => {
  const id = String(req.params.id);
  const p = automationPlaces.find(x => String(x.id) === id);
  if (!p) return res.status(404).json({ error: 'não encontrado' });
  const { name, lat, lng, radius_m } = req.body || {};
  if (name !== undefined) {
    if (!String(name).trim()) return res.status(400).json({ error: 'nome obrigatório' });
    p.name = String(name).trim();
  }
  if (lat !== undefined && lat !== null) p.lat = lat;
  if (lng !== undefined && lng !== null) p.lng = lng;
  if (radius_m !== undefined && radius_m !== null) p.radius_m = radius_m;
  p._updated_ms = Date.now();
  saveAutoPlaces();
  res.json(p);
});

app.delete('/api/automation-places/:id', (req, res) => {
  const id = String(req.params.id);
  const idx = automationPlaces.findIndex(p => String(p.id) === id);
  if (idx === -1) return res.status(404).json({ error: 'não encontrado' });
  automationPlaces.splice(idx, 1);
  saveAutoPlaces();
  res.json({ ok: true });
});

// ── MapKit JS — JWT ES256 pro cluster do iPad ─────────────────────────────────
// Apple exige token assinado pra inicializar o SDK web (mapkit.js). Token é
// válido por até 1 ano, mas a recomendação é regenerar a cada ~30min e cachear.
// Caching: regenera só quando faltarem <5min pra expirar.
const _mapkitCfg = {
  teamId:   process.env.MAPKIT_TEAM_ID  || '',
  keyId:    process.env.MAPKIT_KEY_ID   || '',
  p8Path:   process.env.MAPKIT_KEY_P8_PATH || '',
};
let _mapkitJwt = null, _mapkitJwtExp = 0, _mapkitKeyPem = null;
function _mapkitKey() {
  if (_mapkitKeyPem) return _mapkitKeyPem;
  if (!_mapkitCfg.p8Path) return null;
  try {
    const abs = path.isAbsolute(_mapkitCfg.p8Path)
      ? _mapkitCfg.p8Path
      : path.join(__dirname, _mapkitCfg.p8Path);
    _mapkitKeyPem = fs.readFileSync(abs, 'utf8');
    return _mapkitKeyPem;
  } catch (e) {
    console.warn('[mapkit] falha lendo .p8:', e.message);
    return null;
  }
}
function _mapkitToken() {
  const now = Math.floor(Date.now() / 1000);
  if (_mapkitJwt && (_mapkitJwtExp - now) > 300) return _mapkitJwt;
  const key = _mapkitKey();
  if (!key || !_mapkitCfg.teamId || !_mapkitCfg.keyId) return null;
  const ttl = 30 * 60;  // 30 min
  const header  = Buffer.from(JSON.stringify({ alg: 'ES256', kid: _mapkitCfg.keyId, typ: 'JWT' })).toString('base64url');
  const payload = Buffer.from(JSON.stringify({ iss: _mapkitCfg.teamId, iat: now, exp: now + ttl })).toString('base64url');
  const data    = `${header}.${payload}`;
  const sig     = require('crypto').sign('sha256', Buffer.from(data), { key, dsaEncoding: 'ieee-p1363' });
  _mapkitJwt    = `${data}.${sig.toString('base64url')}`;
  _mapkitJwtExp = now + ttl;
  return _mapkitJwt;
}
app.get('/api/mapkit/token', (req, res) => {
  const token = _mapkitToken();
  if (!token) return res.status(503).json({ error: 'MapKit não configurado (faltam MAPKIT_TEAM_ID/KEY_ID/KEY_P8_PATH)' });
  res.json({ token, expires_at: new Date(_mapkitJwtExp * 1000).toISOString() });
});
if (_mapkitCfg.teamId && _mapkitCfg.keyId && _mapkitCfg.p8Path) {
  console.log(`[mapkit] pronto · team=${_mapkitCfg.teamId} key=${_mapkitCfg.keyId}`);
}

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
  const totalCost = maintenance.history.reduce((s, h) => s + (h.cost || 0), 0);
  let costPerKm = 0;
  const curOdo = +state.odometer_km || 0;
  if (totalCost > 0 && curOdo > 0) costPerKm = totalCost / curOdo;
  res.json({
    intervals: maintenance.intervals,
    history:   [...maintenance.history].sort((a, b) => (b.date_ms || 0) - (a.date_ms || 0)),
    next:      computeMaintenance(),
    current_odometer_km: +state.odometer_km || 0,
    daily_km_avg: parseFloat(avgDailyKm(30).toFixed(1)),
    total_cost:  parseFloat(totalCost.toFixed(2)),
    cost_per_km: parseFloat(costPerKm.toFixed(4)),
  });
});

// POST /api/maintenance/intervals  — cria ou atualiza um intervalo
app.post('/api/maintenance/intervals', (req, res) => {
  const { id, label, every_km, every_months, icon, alert_km, alert_days, category } = req.body || {};
  const km   = parseFloat(every_km)   || 0;
  const mths = parseFloat(every_months) || 0;
  if (!label || (!(km > 0) && !(mths > 0)))
    return res.status(400).json({ error: 'label e pelo menos every_km ou every_months > 0 obrigatórios' });
  const slug = String(label).trim().toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 28);
  const safeId = id ? String(id).trim() : slug + '-' + Math.random().toString(36).slice(2, 6);
  const interval = {
    id: safeId,
    label: String(label).trim(),
    category: category ? String(category).trim() : 'outros',
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
// type_id nulo = entrada avulsa (não periódica); nesse caso label obrigatório.
app.post('/api/maintenance/history', (req, res) => {
  const { type_id, label, category, odometer_km, date_ms, notes, cost } = req.body || {};
  const tid = type_id ? String(type_id).trim() : null;
  if (!tid && !label) return res.status(400).json({ error: 'type_id ou label obrigatório' });
  if (tid && !maintenance.intervals.find(i => i.id === tid))
    return res.status(400).json({ error: 'type_id inválido' });
  const odo = parseFloat(odometer_km);
  if (!(odo > 0)) return res.status(400).json({ error: 'odometer_km > 0 obrigatório' });
  const rec = {
    id: 'h-' + Date.now() + '-' + Math.random().toString(36).slice(2, 8),
    type_id: tid,
    odometer_km: odo,
    date_ms: parseInt(date_ms) || Date.now(),
    notes: notes ? String(notes).slice(0, 240) : '',
  };
  if (!tid) rec.label = String(label).slice(0, 120);
  if (category) rec.category = String(category).slice(0, 40);
  const c = parseFloat(cost);
  if (!isNaN(c) && c > 0) rec.cost = parseFloat(c.toFixed(2));
  maintenance.history.push(rec);
  if (maintenance._alerts && tid) delete maintenance._alerts[tid];
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
    if (b.type_id && !maintenance.intervals.find(i => i.id === b.type_id))
      return res.status(400).json({ error: 'type_id inválido' });
    rec.type_id = b.type_id ? String(b.type_id) : null;
  }
  if (b.notes    !== undefined) rec.notes    = String(b.notes).slice(0, 240);
  if (b.label    !== undefined) rec.label    = b.label ? String(b.label).slice(0, 120) : undefined;
  if (b.category !== undefined) rec.category = b.category ? String(b.category).slice(0, 40) : undefined;
  if (b.cost !== undefined) {
    const c = parseFloat(b.cost);
    if (!isNaN(c) && c > 0) rec.cost = parseFloat(c.toFixed(2));
    else delete rec.cost;
  }
  if (maintenance._alerts) maintenance._alerts = {};
  saveMaintenance();
  res.json({ ok: true, record: rec, next: computeMaintenance() });
});

// ── Abastecimentos ──────────────────────────────────────────────────────────
app.get('/api/refuels', (req, res) => {
  const since = parseSince(req);
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

// POST /api/admin/notify { token, title, body } — push de aviso admin (ex.:
// renovação TestFlight). Manda APNs alert (banner real na tela bloqueada, app
// fechado) gated SÓ pro device do Rafael (ADMIN_DEVICE_ID) — assim não vaza pro
// iPhone da Grasi. Web Push no PWA iOS só aparece com o app em foco, por isso
// agora vai pelo APNs nativo. skipHistory pra não poluir o feed.
const ADMIN_DEVICE_ID = process.env.ADMIN_DEVICE_ID || '';
app.post('/api/admin/notify', async (req, res) => {
  if (!adminCheckToken(req, res)) return;
  const title = String(req.body?.title || 'Ecotrip').slice(0, 120);
  const body  = String(req.body?.body  || '').slice(0, 400);
  try {
    await sendPush(title, body, null, {
      skipHistory: true,
      onlyDeviceIds: ADMIN_DEVICE_ID ? [ADMIN_DEVICE_ID] : undefined,
    });
    res.json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
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

// ── Auto-serviço: cada dono configura a conexão do PRÓPRIO broker + HA + chassi ──
// (Multi-tenant Modelo B: a instância conecta no broker da HA da pessoa, via tailnet.)
// Atualiza chaves específicas no .env do tenant, preservando o resto.
function _updateEnvKeys(updates) {
  const envPath = path.join(DATA_DIR, '.env');
  let lines = [];
  try { lines = fs.readFileSync(envPath, 'utf8').split('\n'); } catch (_) {}
  const keys = Object.keys(updates);
  const kept = lines.filter(l => !keys.some(k => l.startsWith(k + '=')));
  for (const k of keys) kept.push(`${k}=${updates[k]}`);
  fs.writeFileSync(envPath, kept.join('\n').replace(/\n+$/, '') + '\n');
}

app.get('/api/my-setup', (req, res) => {
  res.json({
    mqtt_host:   MQTT_HOST.replace(/^mqtts?:\/\//, ''),   // sem o scheme (a UI mostra limpo)
    mqtt_port:   MQTT_PORT, mqtt_user: MQTT_USER,
    mqtt_tls:    MQTT_HOST.startsWith('mqtts://'),         // TLS = scheme mqtts://
    car_mqtt_host: CAR_MQTT_HOST, car_mqtt_port: CAR_MQTT_PORT, car_mqtt_tls: CAR_MQTT_TLS,
    mqtt_prefix: MQTT_PREFIX, has_mqtt_pass: !!MQTT_PASS,
    chassi:      GWM_CHASSI, ha_url: HA_URL, has_ha_token: !!HA_TOKEN,
    mqtt_connected: !!(mqttClient && mqttClient.connected),
  });
});

app.post('/api/my-setup', (req, res) => {
  const b = req.body || {};
  const env = {};
  // Host + TLS: broker público da pessoa usa mqtts:// (TLS na 8883). Sem TLS → mqtt://.
  if (b.mqtt_host !== undefined) {
    const bare = String(b.mqtt_host).trim().replace(/^mqtts?:\/\//, '');
    if (bare) env.MQTT_HOST = (b.mqtt_tls ? 'mqtts://' : 'mqtt://') + bare;
  }
  if (b.mqtt_port   !== undefined) env.MQTT_PORT   = String(parseInt(b.mqtt_port, 10) || 1883);
  // Broker PÚBLICO do carro (pareamento) — separado do host local do bridge.
  if (b.car_mqtt_host !== undefined) env.CAR_MQTT_HOST = String(b.car_mqtt_host).trim().replace(/^mqtts?:\/\//, '');
  if (b.car_mqtt_port !== undefined) env.CAR_MQTT_PORT = String(parseInt(b.car_mqtt_port, 10) || 8883);
  if (b.car_mqtt_tls  !== undefined) env.CAR_MQTT_TLS  = b.car_mqtt_tls ? 'true' : 'false';
  if (b.mqtt_user   !== undefined) env.MQTT_USER   = String(b.mqtt_user).trim();
  if (b.mqtt_pass)                 env.MQTT_PASS   = String(b.mqtt_pass);          // só troca se veio
  if (b.mqtt_prefix !== undefined) env.MQTT_PREFIX = String(b.mqtt_prefix).trim().replace(/\/+$/, '');
  if (b.ha_url      !== undefined) env.HA_URL      = String(b.ha_url).trim().replace(/\/+$/, '');
  if (b.ha_token)                  env.HA_TOKEN    = String(b.ha_token);            // só troca se veio
  // Chassi → vehicle.json (mesma fonte da aba Veículo)
  if (b.chassi !== undefined) {
    const raw = String(b.chassi).toLowerCase().trim();
    if (raw && !/^lgw[a-z0-9]{14}$/.test(raw)) return res.status(400).json({ error: 'Chassi inválido (esperado: lgw + 14 alfanuméricos)' });
    try { const cur = _loadVehicleFile(); fs.writeFileSync(VEHICLE_FILE, JSON.stringify({ ...cur, chassi: raw, updated_at: Date.now() }, null, 2)); }
    catch (e) { return res.status(500).json({ error: 'Falha ao salvar chassi: ' + e.message }); }
  }
  try { if (Object.keys(env).length) _updateEnvKeys(env); }
  catch (e) { return res.status(500).json({ error: 'Falha ao salvar config: ' + e.message }); }
  res.json({ ok: true, restarting: true });
  // .env é lido no boot → reinicia pra aplicar (pm2 sobe de novo).
  console.log('[my-setup] config atualizada — reiniciando pra aplicar…');
  setTimeout(() => process.exit(0), 800);
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
  const envPath = path.join(DATA_DIR, '.env');
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

// Detecta re-POST do mesmo trecho (retry de rede): o trecho `incoming` já está no
// FIM dos `existing` (pós-merge anterior). Compara assinatura de coords (lat/lng/spd)
// no início/meio/fim — o rebasing de `t` no resume só altera o `t`, não as coords.
function _isDuplicateTail(existing, incoming) {
  if (incoming.length === 0 || existing.length < incoming.length) return false;
  const tail = existing.slice(existing.length - incoming.length);
  const eq = (a, b) => Math.abs((a || 0) - (b || 0)) < 1e-5;
  const idxs = [0, incoming.length >> 1, incoming.length - 1];
  return idxs.every(i =>
    eq(tail[i].lat, incoming[i].lat) &&
    eq(tail[i].lng, incoming[i].lng) &&
    eq(tail[i].spd, incoming[i].spd));
}

app.post('/api/autotrips', (req, res) => {
  // DEBUG temporário: loga TODA tentativa pra rastrear viagens travadas no APK
  const ua = req.headers['user-agent'] || '?';
  const auth = req.headers['authorization'] ? 'OK' : 'FALTANDO';
  const tid = req.body?.tripId || 'sem tripId';
  console.log(`[autotrip] POST recebido · tripId=${tid} · auth=${auth} · ua=${ua.slice(0,40)} · ip=${req.ip}`);
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
        } else if (_isDuplicateTail(existingSamples, newSamples)) {
          // Re-POST do mesmo trecho (retry de rede): o trecho novo já está no fim
          // dos existentes. Mantém como está pra não duplicar.
          finalSamples = existingSamples;
        } else {
          // Overlap de `t` SEM ser duplicata = RESUME em que o APK re-baseou o `t`
          // do segundo trecho (começa perto de 0 de novo). Se a gente cortasse em
          // maxExistingT, TODO o segundo trecho sumiria do trajeto (era o bug: km e
          // tempo vinham completos do autoTrip, mas a rota só mostrava o 1º trecho).
          // Correção: re-baseia o `t` do trecho novo pra continuar DEPOIS do
          // existente, preservando o espaçamento interno, e concatena.
          const offset = maxExistingT + 1 - minNewT;
          const rebased = newSamples.map(s => ({ ...s, t: (s.t || 0) + offset }));
          finalSamples = [...existingSamples, ...rebased];
          console.log(`↻ AutoTrip ${safeId}: resume detectado (t re-baseado +${offset}s) — 2º trecho preservado`);
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

    // Calcula tempo e distância em modo híbrido (ICE ligado, rpm > 0).
    // Se o arquivo existente foi marcado como _estimated (telemetria parou no
    // meio da viagem e os hybrid foram inferidos por média histórica), PRESERVA
    // a estimativa em vez de recalcular dos samples (que dariam 0 ou subestimaria).
    let existingEstimated = null;
    if (fs.existsSync(filePath)) {
      try {
        const ex = JSON.parse(fs.readFileSync(filePath, 'utf8'));
        if (ex._estimated && ex.hybridTimeSec != null && ex.hybridDistKm != null) {
          existingEstimated = {
            hybridTimeSec:        ex.hybridTimeSec,
            hybridDistKm:         ex.hybridDistKm,
            _estimated:           true,
            _estimatedFields:     ex._estimatedFields  || ['hybridDistKm','hybridTimeSec'],
            _estimatedReason:     ex._estimatedReason  || '',
            _estimatedAppliedAt:  ex._estimatedAppliedAt || '',
          };
        }
      } catch (_) {}
    }

    let hybridTimeSec, hybridDistKm;
    if (existingEstimated) {
      hybridTimeSec = existingEstimated.hybridTimeSec;
      hybridDistKm  = existingEstimated.hybridDistKm;
      console.log(`↻ AutoTrip ${safeId}: hybrid preservado (estimado): ${hybridDistKm}km / ${hybridTimeSec}s`);
    } else {
      hybridTimeSec = 0;
      hybridDistKm  = 0;
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
    }

    // Persiste hybrid junto — boot não precisa recalcular.
    // Se foi estimado, marca o arquivo também com os campos _estimated*.
    const persisted = {
      tripId: safeId, autoTrip, samples: finalSamples, hybridTimeSec, hybridDistKm,
    };
    if (existingEstimated) {
      persisted._estimated          = true;
      persisted._estimatedFields    = existingEstimated._estimatedFields;
      persisted._estimatedReason    = existingEstimated._estimatedReason;
      persisted._estimatedAppliedAt = existingEstimated._estimatedAppliedAt;
    }
    fs.writeFileSync(filePath, JSON.stringify(persisted));

    const record = { tripId: safeId, ...autoTrip, hybridTimeSec, hybridDistKm };
    if (existingEstimated) {
      record._estimated       = true;
      record._estimatedFields = existingEstimated._estimatedFields;
      record._estimatedReason = existingEstimated._estimatedReason;
    }

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
  const since = parseSince(req);
  // Inclui também viagens ATUALIZADAS (rename, reprocessamento de locais) via
  // _updated_ms — senão o sync incremental do app (que filtra por startMs) nunca
  // recebe o nome novo de uma viagem antiga.
  const arr   = since > 0
    ? autoTripsArr.filter(t => (t.startMs || 0) > since || (t._updated_ms || 0) > since)
    : autoTripsArr;
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

    // Marker: lista das tripIds originais antes deste merge. Preserva o
    // histórico se for um merge encadeado (A+B+C — segunda chamada já vê o
    // merged_from da primeira). Bridge depois exibe isso pra usuario saber.
    const prevMergedFrom = Array.isArray(dataA.merged_from) ? dataA.merged_from
                          : Array.isArray(dataB.merged_from) ? dataB.merged_from
                          : [];
    const mergedFrom = Array.from(new Set([...prevMergedFrom, lateId]));

    // Salva arquivo unificado (ID da viagem mais antiga) — hybrid persistido pra
    // boot não recalcular.
    fs.writeFileSync(
      path.join(AUTOTRIPS_DIR, `${earlyId}.json`),
      JSON.stringify({
        tripId: earlyId, autoTrip: merged, samples: mergedSamples,
        hybridTimeSec, hybridDistKm, merged_from: mergedFrom,
      })
    );
    // Remove arquivo da viagem mais recente
    try { fs.unlinkSync(path.join(AUTOTRIPS_DIR, `${lateId}.json`)); } catch (_) {}

    // Marca tombstone pro lateId — sem isso, PWAs com cache local
    // continuam mostrando a viagem absorvida como fantasma. O endpoint
    // GET /api/autotrips devolve esses ids no header X-Tombstones e o
    // PWA limpa o cache.
    markDeleted('autotrips', lateId);

    // Atualiza array em memória
    autoTripsArr = autoTripsArr.filter(t => t.tripId !== earlyId && t.tripId !== lateId);
    const record = { tripId: earlyId, ...merged, hybridTimeSec, hybridDistKm, merged_from: mergedFrom };
    autoTripsArr.push(record);
    autoTripsArr.sort((a, b) => (b.startMs||0)-(a.startMs||0));

    console.log(`[merge] ${earlyId} + ${lateId} → ${earlyId} (${merged.distKm} km, ${mergedSamples.length} amostras, merged_from=${mergedFrom.length})`);
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
    // Atualiza array em memória + marca _updated_ms (pro sync incremental do app).
    const t = autoTripsArr.find(r => r.tripId === String(tripId));
    if (t) { t.name = trimmed; t._updated_ms = Date.now(); }
    // Atualiza arquivo do auto-trip
    const safeId   = String(tripId).replace(/\D/g, '');
    const filePath = path.join(AUTOTRIPS_DIR, `${safeId}.json`);
    if (fs.existsSync(filePath)) {
      try {
        const data = JSON.parse(fs.readFileSync(filePath, 'utf8'));
        data.autoTrip = data.autoTrip || {};
        data.autoTrip.name = trimmed;
        data._updated_ms = Date.now();
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

// Retorna versão do bridge e versão mínima de app compatível.
// Útil para o PWA alertar quando o bridge está desatualizado.
app.get('/api/bridge-version', (_req, res) => {
  res.json({ version: BRIDGE_VERSION, min_app_version: '5.0' });
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
  // Aceita chaves do Haval (NOTIF_DEFAULTS) E as do BYD/Grasi (prefixo `byd_`,
  // inclui as sub-chaves de geofence por local byd_geofence_*_<locId>).
  const isByd = typeof key === 'string' && key.startsWith('byd_');
  if (!key || (!(key in NOTIF_DEFAULTS) && !isByd)) return res.status(400).json({ error: 'chave inválida' });
  if (!notifPrefsByDevice[id]) notifPrefsByDevice[id] = {};
  const def = NOTIF_DEFAULTS[key];
  if (Array.isArray(def)) {
    if (!Array.isArray(value)) return res.status(400).json({ error: 'esperado array' });
    notifPrefsByDevice[id][key] = value.map(String);
  } else if (typeof def === 'number') {
    const n = parseInt(value);
    if (isNaN(n)) return res.status(400).json({ error: 'valor numérico inválido' });
    notifPrefsByDevice[id][key] = Math.max(1, Math.min(60, n));
  } else if (isByd && typeof value === 'number') {
    // Prefs numéricas do BYD (ex.: byd_unlocked_min) — minutos/limiares.
    notifPrefsByDevice[id][key] = Math.max(0, Math.min(240, value));
  } else {
    notifPrefsByDevice[id][key] = !!value;
  }
  saveNotifPrefsByDevice();
  res.json({ ok: true, prefs: getPrefsForDevice(id) });
});

// ── Live Activities: masters GLOBAIS (nível da instância) ─────────────────────
const LA_PREF_KEYS = ['la_charge', 'la_preclimat', 'la_trip', 'la_motor', 'la_security', 'la_songpro', 'la_songpro_trip', 'preclimat_steps'];
app.get('/api/la-prefs', (_req, res) => {
  const out = {};
  for (const k of LA_PREF_KEYS) out[k] = notifPrefs[k] !== false;   // default ligado
  res.json(out);
});
app.post('/api/la-prefs', (req, res) => {
  const { key, value } = req.body || {};
  if (!LA_PREF_KEYS.includes(key)) return res.status(400).json({ error: 'chave inválida' });
  notifPrefs[key] = !!value;
  saveNotifPrefs();
  res.json({ ok: true, key, value: notifPrefs[key] });
});

// ── Pareamento do carro (provisioning) ────────────────────────────────────
// Celular gera um código curto (one-time, expira). O carro resgata via
// /api/pair/redeem (SEM login) e recebe a config MQTT — assim ninguém digita
// broker/senha no carro nem vê as credenciais lá.
const _pairCodes = new Map();            // code -> { config, expiresAt }
const PAIR_TTL_MS = 10 * 60_000;
const _PAIR_ALPHABET = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';   // sem I/O/0/1 (ambíguos)
function _prunePairCodes() { const now = Date.now(); for (const [k, v] of _pairCodes) if (v.expiresAt < now) _pairCodes.delete(k); }
function _genPairCode() {
  const buf = require('crypto').randomBytes(6); let c = '';
  for (let i = 0; i < 6; i++) c += _PAIR_ALPHABET[buf[i] % _PAIR_ALPHABET.length];
  return c;
}
app.post('/api/pair/generate', (_req, res) => {   // autenticado (passa pelo guard /api)
  _prunePairCodes();
  const code = _genPairCode();
  // O CARRO usa o endereço PÚBLICO (CAR_MQTT_*); se não configurado, cai pro local
  // (MQTT_HOST) — que só funciona se o carro estiver na mesma rede do broker.
  const carHost = CAR_MQTT_HOST || MQTT_HOST.replace(/^mqtts?:\/\//, '');
  const carPort = CAR_MQTT_HOST ? CAR_MQTT_PORT : MQTT_PORT;
  const carTls  = CAR_MQTT_HOST ? CAR_MQTT_TLS : MQTT_HOST.startsWith('mqtts://');
  // BRIDGE URL/TOKEN pra HTTP (POST /api/autotrips no fim da viagem).
  // Detecta a URL externa: prioridade BRIDGE_PUBLIC_URL → Tailscale funnel → vazio.
  const bridgeUrl = (process.env.BRIDGE_PUBLIC_URL ||
                     process.env.TAILSCALE_FUNNEL_URL ||
                     'https://mac-mini.tailacc6e7.ts.net').replace(/\/+$/, '');
  // Token: o hash do .env (o bridge aceita tanto plain quanto hash como Bearer).
  const bridgeToken = BRIDGE_TOKEN_HASH || '';
  _pairCodes.set(code, {
    expiresAt: Date.now() + PAIR_TTL_MS,
    config: {
      mqtt_host:    carHost,
      mqtt_port:    carPort,
      mqtt_user:    MQTT_USER,
      mqtt_pass:    MQTT_PASS,
      mqtt_prefix:  MQTT_PREFIX,
      mqtt_tls:     carTls,
      bridge_url:   bridgeUrl,    // pra POST /api/autotrips no fim da viagem
      bridge_token: bridgeToken,  // Authorization: Bearer <token>
    },
  });
  console.log(`[pair] código gerado (expira em ${PAIR_TTL_MS / 60000} min)`);
  res.json({ code, expires_in_sec: Math.round(PAIR_TTL_MS / 1000) });
});
// SEM auth — gateado pelo código one-time + expiração + rate-limit por IP.
const _pairRedeemHits = new Map();
app.post('/api/pair/redeem', (req, res) => {
  const ip = req.ip || 'unknown', now = Date.now();
  const hits = (_pairRedeemHits.get(ip) || []).filter(t => now - t < 60_000);
  if (hits.length >= 10) return res.status(429).json({ error: 'muitas tentativas' });
  hits.push(now); _pairRedeemHits.set(ip, hits);
  _prunePairCodes();
  const code = String((req.body || {}).code || '').toUpperCase().trim();
  const entry = _pairCodes.get(code);
  if (!entry) return res.status(404).json({ error: 'código inválido ou expirado' });
  _pairCodes.delete(code);   // one-time
  console.log(`[pair] código resgatado por ${ip}`);
  res.json({ ok: true, config: entry.config });
});

// ── Reativar Live Activities em andamento ─────────────────────────────────
// Se o usuário dispensou (swipe) uma LA sem querer, re-lança via push-to-start
// com o ESTADO ATUAL (continua dali, como se nunca tivesse saído).
app.post('/api/la/relaunch', async (req, res) => {
  if (!apnsLive.enabled) return res.status(503).json({ error: 'apns desativado' });
  const done = [];
  try {
    if (state.charging_state === 'Carregando' && notifPrefs.la_charge !== false) {
      // iOS ignora pushStart se já existe LA do mesmo tipo "viva" (mesmo que
      // o user tenha dispensado por swipe). Encerra a existente PRIMEIRO
      // (isFinal + dismissalDate imediata) e DEPOIS cria nova. Garante que
      // o card reaparece visível ao usuário.
      try {
        await apnsLive.pushUpdate('ChargeActivityAttributes', {}, _chargeContentState(),
          { isFinal: true, dismissalDate: Date.now() });
      } catch (_) {}
      // Pequeno delay pra iOS processar o end antes do start.
      await new Promise(r => setTimeout(r, 250));
      await apnsLive.pushStart('ChargeActivityAttributes', '', { carName: 'Haval H6 PHEV' }, _chargeContentState(),
        { staleDate: Date.now() + 3600_000, alert: { title: '⚡ Recarga', body: 'Card reativado — acompanhe na tela bloqueada.' } });
      done.push('recarga');
    }
    if (_tripActive && notifPrefs.la_trip !== false) {
      await apnsLive.pushStart(TRIP_LA_TYPE, '', { carName: 'Haval H6 PHEV' }, _tripContentState(_lastTripSnapshot || {}, true),
        { staleDate: Date.now() + 6 * 3600_000, alert: { title: '🚗 Viagem', body: 'Card reativado.' } });
      done.push('viagem');
    }
    if (_motorActive && notifPrefs.la_motor !== false) {
      await apnsLive.pushStart(MOTOR_LA_TYPE, '', { carName: 'Haval H6 PHEV' }, _motorContentState(true),
        { staleDate: Date.now() + 3 * 3600_000, alert: { title: '🔑 Motor ligado', body: 'Card reativado.' } });
      done.push('motor');
    }
    if (['starting', 'engine_on', 'cooling'].includes(preclimatStatus.phase) && _activeSched && notifPrefs.la_preclimat !== false) {
      const pdev = _activeSched.device_id || '';
      await apnsLive.pushStart(PRECLIMAT_LA_TYPE, pdev, _preclimatAttributes(), _preclimatContentState(),
        { staleDate: preclimatStatus.endsAtMs || (Date.now() + 1800_000), alert: { title: '❄️ Pré-climatização', body: 'Card reativado.' },
          allow: pdev ? undefined : (d) => getPrefsForDevice(d).la_preclimat !== false });
      done.push('pre-clima');
    }
    if (_securityActive && notifPrefs.la_security !== false) {
      _securityActive = false; _evalSecurityAlert();   // re-cria se ainda há problema
      done.push('seguranca');
    }
    // BYD Song Pro (Grasi) — só relança se sessão ativa e algum device opt-in.
    if (_songProSession && _songProSession.active && _songProEnabled()) {
      const cs = _songProContentState(true);
      await apnsLive.pushStart(SONGPRO_LA_TYPE, '', { carName: 'BYD Song Pro' }, cs,
        { staleDate: Date.now() + 6 * 3600_000, alert: { title: '🔵 BYD da Grasi carregando', body: 'Card reativado.' },
          allow: (deviceId) => getPrefsForDevice(deviceId).la_songpro === true });
      done.push('song-pro');
    }
  } catch (e) { return res.status(500).json({ error: e.message }); }
  console.log(`[la-relaunch] reativadas: ${done.join(', ') || '(nenhuma ativa)'}`);
  res.json({ ok: true, relaunched: done });
});

// ── 🤖 AI local (Ollama) — pergunte sobre viagens/recargas ────────────────
// 100% local: nenhum dado sai do Mac Mini. Modelo configurável via .env
// (default llama3.1:8b). Bridge monta contexto com últimas viagens/recargas/
// estado e manda pro Ollama. Resposta em PT-BR.
const OLLAMA_URL   = process.env.OLLAMA_URL   || 'http://localhost:11434';
const OLLAMA_MODEL = process.env.OLLAMA_MODEL || 'llama3.1:8b';

// Resumo compacto de uma viagem — agrega samples por modo (HEV/EV) e calcula
// km/L só do HEV (assumindo que todo combustível foi queimado em HEV, que é
// quase sempre verdade num PHEV: motor ICE só liga em HEV).
function _summarizeTrip(tripFile) {
  try {
    const t = JSON.parse(fs.readFileSync(tripFile, 'utf8'));
    const a = t.autoTrip || {};
    const ss = t.samples || [];
    let evDist = 0, evTime = 0, hevDist = 0, hevTime = 0;
    for (let i = 1; i < ss.length; i++) {
      const dt = Math.max(0, (ss[i].t || 0) - (ss[i-1].t || 0));
      const spd = +ss[i].spd || 0;
      const dKm = spd * dt / 3600;
      if ((+ss[i].rpm || 0) > 0) { hevDist += dKm; hevTime += dt; }
      else                       { evDist  += dKm; evTime  += dt; }
    }
    const kmLhev = (a.fuelL > 0) ? (hevDist / a.fuelL) : null;
    return {
      startMs: a.startMs, endMs: a.endMs,
      origem: a.startAddress || null, destino: a.endAddress || null,
      distKm: +(a.distKm || 0).toFixed(1),
      timeMin: Math.round((a.timeSec || 0) / 60),
      fuelL: +(a.fuelL || 0).toFixed(2),
      netKwh: +(a.netKwh || 0).toFixed(2),
      maxSpeedKmh: a.maxSpeedKmh,
      socStart: a.startSocPct, socEnd: a.endSocPct,
      modo_ev:  { distKm: +evDist.toFixed(1),  timeMin: Math.round(evTime/60)  },
      modo_hev: { distKm: +hevDist.toFixed(1), timeMin: Math.round(hevTime/60), kmL: kmLhev ? +kmLhev.toFixed(2) : null },
    };
  } catch (e) { return null; }
}

function _buildAiContext(N = 10) {
  // Últimas N viagens
  const files = fs.readdirSync(AUTOTRIPS_DIR)
    .filter(f => f.endsWith('.json'))
    .sort()
    .slice(-N);
  const trips = files.map(f => _summarizeTrip(path.join(AUTOTRIPS_DIR, f))).filter(Boolean);

  // Últimas N recargas
  let charges = [];
  try {
    const cj = JSON.parse(fs.readFileSync(CHARGES_FILE, 'utf8'));
    charges = (cj.charges || []).slice(-N).map(c => ({
      timestamp: c.timestamp,
      duration_min: Math.round((c.duration_sec || 0) / 60),
      energy_kwh_bateria: c.energy_kwh,
      energy_kwh_medidor: c.charger_kwh || null,
      soc: `${c.soc_start}→${c.soc_end}%`,
      avg_power_kw: c.avg_power_kw,
      local: c.location_name || null,
      custo_brl: c.cost_override?.total || null,
      preco_kwh_efetivo: (c.cost_override?.total && c.energy_kwh > 0) ? +(c.cost_override.total / c.energy_kwh).toFixed(2) : null,
    }));
  } catch (_) {}

  const cur = {
    soc_pct: state.soc_pct,
    charging_state: state.charging_state,
    charge_power_kw: state.charge_power_kw,
    odometer_km: state.odometer_km,
    autonomy_ev_km: state.autonomy_ev_km,
    autonomy_ice_km: state.autonomy_ice_km,
    fuel_l: state.fuel_l,
  };

  return { now_iso: new Date().toISOString(), atual: cur, viagens_recentes: trips, recargas_recentes: charges };
}

app.post('/api/ai/ask', async (req, res) => {
  // Aceita 2 formatos:
  //   { question: '...' }       — single-turn (backward compat).
  //   { messages: [...] }       — multi-turn (chat com histórico).
  // Em multi-turn, o cliente envia toda a thread (user+assistant alternados);
  // o bridge antepõe um system prompt com o contexto atual.
  let userMsgs;
  if (Array.isArray(req.body?.messages) && req.body.messages.length > 0) {
    userMsgs = req.body.messages
      .filter(m => m && (m.role === 'user' || m.role === 'assistant') && m.content)
      .map(m => ({ role: m.role, content: String(m.content).slice(0, 4000) }));
    if (!userMsgs.length) return res.status(400).json({ error: 'messages vazias' });
  } else {
    const question = (req.body?.question || '').toString().trim();
    if (!question) return res.status(400).json({ error: 'question vazia' });
    if (question.length > 2000) return res.status(400).json({ error: 'question muito longa' });
    userMsgs = [{ role: 'user', content: question }];
  }
  // Limita histórico ao máximo de 20 turnos pra evitar context window estourar.
  if (userMsgs.length > 20) userMsgs = userMsgs.slice(-20);

  const ctx = _buildAiContext(req.body?.context_size || 10);
  const sys = `Você é um assistente especializado em telemetria de carros híbridos plug-in (PHEV) integrado ao app Haval EcoTrip. Responda em português brasileiro, com clareza e precisão. Use APENAS os dados fornecidos abaixo no JSON de contexto pra responder. Não invente números. Se a pergunta exigir algo fora do contexto, diga.

CONTEXTO (JSON):
${JSON.stringify(ctx, null, 2)}

DICAS:
- "Modo HEV" = motor térmico ligado (rpm > 0). "Modo EV" = elétrico puro.
- "kWh efetivo" da recarga = custo / energia que entrou na bateria.
- Datas em viagens_recentes.startMs/endMs são milissegundos epoch (use Date(ms).toLocaleString se precisar formatar).
- Seja conciso. Tabelas simples ou bullets quando útil.
- Mantenha continuidade da conversa: se o usuário pergunta "e nessa outra?" assume o contexto da mensagem anterior.`;

  try {
    const r = await fetch(`${OLLAMA_URL}/api/chat`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: OLLAMA_MODEL,
        messages: [{ role: 'system', content: sys }, ...userMsgs],
        stream: false,
        options: { temperature: 0.2, num_ctx: 8192 },
      }),
    });
    if (!r.ok) return res.status(502).json({ error: `Ollama ${r.status}` });
    const o = await r.json();
    res.json({
      answer: o.message?.content || '(sem resposta)',
      duration_sec: o.total_duration ? +(o.total_duration/1e9).toFixed(2) : null,
      tokens: o.eval_count || null,
    });
  } catch (e) {
    console.warn('[ai] erro:', e.message);
    res.status(500).json({ error: 'falha ao consultar Ollama: ' + e.message });
  }
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
  // Mesmo critério do gating de envio (getPrefsForDevice): device sem id usa a
  // config global; com prefs próprias usa elas. Nunca retorna o histórico cru.
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
            // Atualiza também o array em memória (servido por GET /api/autotrips) —
            // sem isso os nomes só apareciam após restart do bridge.
            const _rec = autoTripsArr.find(t => String(t.tripId) === String(d.tripId));
            if (_rec) { _rec.startKp = at.startKp; _rec.endKp = at.endKp; }
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
// (requireAuth global já cobre; não precisa do admin gate extra.)
app.post('/api/charge-limit/refresh', (req, res) => {
  if (!mqttClient?.connected) return res.status(503).json({ error: 'MQTT offline' });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/refresh_charge_limit`, '1', { retain: false, qos: 1 }, err => {
    if (err) return res.status(500).json({ error: 'Falha ao publicar: ' + err.message });
    console.log('[charge-limit] refresh solicitado — aguardando APK re-publicar');
    res.json({ ok: true });
  });
});

// POST /api/charge-limit  { pct: 80 }  — publica cmd/charge_limit no MQTT
// (requireAuth global já cobre; não precisa do admin gate extra — antes
// rejeitava o bridge_token do PWA com 401, fazendo o UI reverter o pedido.)
app.post('/api/charge-limit', (req, res) => {
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

// POST /api/hazard  { value: 0|1 } — pisca-alerta (4 setas). Alterna
// car.light_setting.sport_mode_light. O iPad chama isto a cada ~1s (0/1).
app.post('/api/hazard', (req, res) => {
  const v = (String(req.body?.value).trim() === '1') ? 1 : 0;
  if (!mqttClient?.connected)
    return res.status(503).json({ error: 'MQTT offline' });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/hazard`, v.toString(), { retain: false, qos: 0 }, err => {
    if (err) return res.status(500).json({ error: 'Falha ao publicar no MQTT' });
    res.json({ ok: true });
  });
});

// POST /api/drive-mode  { mode: 0|1|3 } — publica cmd/drive_mode no MQTT.
// Valores: 0=HEV (híbrido), 1=Prior. EV, 3=EV puro.
app.post('/api/drive-mode', (req, res) => {
  const mode = parseInt(req.body?.mode);
  if (![0, 1, 3].includes(mode))
    return res.status(400).json({ error: 'Valor inválido. Use 0 (HEV), 1 (Prior. EV) ou 3 (EV).' });
  if (!mqttClient?.connected)
    return res.status(503).json({ error: 'MQTT offline' });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/drive_mode`, mode.toString(), { retain: false, qos: 1 }, err => {
    if (err) return res.status(500).json({ error: 'Falha ao publicar no MQTT' });
    console.log(`[drive-mode] Enviando mode=${mode} para o carro via MQTT`);
    res.json({ ok: true });
  });
});

// POST /api/drive-mode/refresh — força APK reler valor do carro
app.post('/api/drive-mode/refresh', (_req, res) => {
  if (!mqttClient?.connected) return res.status(503).json({ error: 'MQTT offline' });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/refresh_drive_mode`, '1', { retain: false, qos: 1 }, err => {
    if (err) return res.status(500).json({ error: 'Falha ao publicar: ' + err.message });
    res.json({ ok: true });
  });
});

// POST /api/power-reserve  { mode: 1|2 } — sub-modo HEV
//   1 = Inteligente (carro decide quando ligar motor)
//   2 = Prioritário (preserva SOC alvo definido em charge_soc_target)
app.post('/api/power-reserve', (req, res) => {
  const mode = parseInt(req.body?.mode);
  if (![1, 2].includes(mode))
    return res.status(400).json({ error: 'Valor inválido. Use 1 (Inteligente) ou 2 (Prioritário).' });
  if (!mqttClient?.connected) return res.status(503).json({ error: 'MQTT offline' });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/power_reserve`, mode.toString(), { retain: false, qos: 1 }, err => {
    if (err) return res.status(500).json({ error: 'Falha ao publicar no MQTT' });
    res.json({ ok: true });
  });
});
app.post('/api/power-reserve/refresh', (_req, res) => {
  if (!mqttClient?.connected) return res.status(503).json({ error: 'MQTT offline' });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/refresh_power_reserve`, '1', { retain: false, qos: 1 }, err => {
    if (err) return res.status(500).json({ error: err.message });
    res.json({ ok: true });
  });
});

// POST /api/charge-soc-target  { pct: 20..80 } — alvo SOC no HEV Prioritário
app.post('/api/charge-soc-target', (req, res) => {
  const pct = parseInt(req.body?.pct);
  if (!(pct >= 20 && pct <= 80))
    return res.status(400).json({ error: 'Valor fora da faixa. Use 20..80.' });
  if (!mqttClient?.connected) return res.status(503).json({ error: 'MQTT offline' });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/charge_soc_target`, pct.toString(), { retain: false, qos: 1 }, err => {
    if (err) return res.status(500).json({ error: 'Falha ao publicar no MQTT' });
    res.json({ ok: true });
  });
});
app.post('/api/charge-soc-target/refresh', (_req, res) => {
  if (!mqttClient?.connected) return res.status(503).json({ error: 'MQTT offline' });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/refresh_charge_soc_target`, '1', { retain: false, qos: 1 }, err => {
    if (err) return res.status(500).json({ error: err.message });
    res.json({ ok: true });
  });
});

// POST /api/terrain-mode  { mode: 0|1|2|3|4|5|11 }
app.post('/api/terrain-mode', (req, res) => {
  const mode = parseInt(req.body?.mode);
  if (![0,1,2,3,4,5,11].includes(mode))
    return res.status(400).json({ error: 'Valor inválido.' });
  if (!mqttClient?.connected) return res.status(503).json({ error: 'MQTT offline' });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/terrain_mode`, mode.toString(), { retain: false, qos: 1 }, err => {
    if (err) return res.status(500).json({ error: 'Falha ao publicar no MQTT' });
    res.json({ ok: true });
  });
});

// POST /api/regen-level  { level: 0|1|2 }
app.post('/api/regen-level', (req, res) => {
  const level = parseInt(req.body?.level);
  if (![0,1,2].includes(level))
    return res.status(400).json({ error: 'Valor inválido. Use 0 (Normal), 1 (Alto), 2 (Baixo).' });
  if (!mqttClient?.connected) return res.status(503).json({ error: 'MQTT offline' });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/regen_level`, level.toString(), { retain: false, qos: 1 }, err => {
    if (err) return res.status(500).json({ error: 'Falha ao publicar no MQTT' });
    res.json({ ok: true });
  });
});

// POST /api/one-pedal  { enable: 0|1 }
app.post('/api/one-pedal', (req, res) => {
  const enable = parseInt(req.body?.enable);
  if (![0,1].includes(enable))
    return res.status(400).json({ error: 'Valor inválido. Use 0 ou 1.' });
  if (!mqttClient?.connected) return res.status(503).json({ error: 'MQTT offline' });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/one_pedal`, enable.toString(), { retain: false, qos: 1 }, err => {
    if (err) return res.status(500).json({ error: 'Falha ao publicar no MQTT' });
    res.json({ ok: true });
  });
});

// POST /api/esp  { enable: 0|1 }
app.post('/api/esp', (req, res) => {
  const enable = parseInt(req.body?.enable);
  if (![0,1].includes(enable))
    return res.status(400).json({ error: 'Valor inválido. Use 0 ou 1.' });
  if (!mqttClient?.connected) return res.status(503).json({ error: 'MQTT offline' });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/esp`, enable.toString(), { retain: false, qos: 1 }, err => {
    if (err) return res.status(500).json({ error: 'Falha ao publicar no MQTT' });
    res.json({ ok: true });
  });
});

// POST /api/steer-mode  { mode: 0|1|2 }
app.post('/api/steer-mode', (req, res) => {
  const mode = parseInt(req.body?.mode);
  if (![0,1,2].includes(mode))
    return res.status(400).json({ error: 'Valor inválido. Use 0 (Normal), 1 (Sport), 2 (Conforto).' });
  if (!mqttClient?.connected) return res.status(503).json({ error: 'MQTT offline' });
  mqttClient.publish(`${MQTT_PREFIX}/cmd/steer_mode`, mode.toString(), { retain: false, qos: 1 }, err => {
    if (err) return res.status(500).json({ error: 'Falha ao publicar no MQTT' });
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
    // Ligar motor pelo app arma a LA de lembrete (confirma no engine_state='1').
    if (name === 'engine_on') markRemoteEngineStart();
    res.json({ ok: true });
  } catch (e) {
    console.error(`[action] ${name} erro: ${e.message}`);
    res.status(502).json({ error: 'falha ao chamar HA' });
  }
});

// ── Pré-climatização — lista de agendamentos ──────────────────────────────
app.get('/api/preclimat', requireAuth, (_req, res) =>
  res.json({ schedules: preclimat.schedules, status: preclimatStatus }));

// Cria (sem id) ou atualiza (com id) um agendamento.
app.post('/api/preclimat/schedule', requireAuth, (req, res) => {
  const b = req.body || {};
  if (b.time !== undefined && !/^\d{2}:\d{2}$/.test(b.time))
    return res.status(400).json({ error: 'time inválido (HH:MM)' });
  if (b.recurrence !== undefined && !['once', 'daily', 'weekdays', 'weekends'].includes(b.recurrence))
    return res.status(400).json({ error: 'recurrence inválido' });
  const t = b.temp !== undefined ? parseFloat(b.temp) : null;
  if (t !== null && (isNaN(t) || t < 16 || t > 32)) return res.status(400).json({ error: 'temp fora de 16-32' });
  const f = b.fan !== undefined ? parseInt(b.fan, 10) : null;
  if (f !== null && (isNaN(f) || f < 1 || f > 7)) return res.status(400).json({ error: 'fan fora de 1-7' });
  const dur = b.duration !== undefined ? parseInt(b.duration, 10) : null;
  if (dur !== null && (isNaN(dur) || dur < 0 || dur > 180)) return res.status(400).json({ error: 'duration fora de 0-180' });
  const lead = b.leadMin !== undefined ? parseInt(b.leadMin, 10) : null;
  if (lead !== null && (isNaN(lead) || lead < 0 || lead > 60)) return res.status(400).json({ error: 'leadMin fora de 0-60' });

  let sched = b.id ? preclimat.schedules.find(s => s.id === b.id) : null;
  if (!sched) { sched = { ...PRECLIMAT_SCHED_DEFAULTS, id: _genSchedId() }; preclimat.schedules.push(sched); }

  const timeChanged = b.time !== undefined && b.time !== sched.time;
  const disabling   = b.enabled !== undefined && !b.enabled && sched.enabled;
  const enabling    = b.enabled !== undefined && !!b.enabled && !sched.enabled;

  if (b.device_id)        sched.device_id  = String(b.device_id);
  if (b.time !== undefined)       sched.time = b.time;
  if (b.recurrence !== undefined) sched.recurrence = b.recurrence;
  if (t !== null)         sched.temp = t;
  if (f !== null)         sched.fan = f;
  if (dur !== null)       sched.duration = dur;
  if (lead !== null)      sched.leadMin = lead;
  if (b.enabled !== undefined)    sched.enabled = !!b.enabled;

  // Efeitos: mudar horário ou desativar encerra a LA ativa deste agendamento;
  // reagendar/reabilitar libera disparo/criação de novo hoje.
  if (timeChanged || disabling) _dismissPreclimatLA(sched);
  if (timeChanged || disabling || enabling) { sched.lastFiredDate = ''; sched.startedDate = ''; }

  savePreclimat();
  res.json(sched);
});

// Remove um agendamento por id.
app.delete('/api/preclimat/schedule/:id', requireAuth, (req, res) => {
  const sched = preclimat.schedules.find(s => s.id === req.params.id);
  if (sched) {
    _dismissPreclimatLA(sched);
    preclimat.schedules = preclimat.schedules.filter(s => s.id !== req.params.id);
    savePreclimat();
  }
  res.json({ ok: true });
});

// ── Histórico de modos — GET /api/drive-history ───────────────────────────
app.get('/api/drive-history', requireAuth, (req, res) => {
  const since = parseInt(req.query.since || '0', 10);
  const segs   = since > 0 ? driveHistory.filter(s => s.to_ts > since) : driveHistory;

  // Agrega: soma duração e conta por combinação dm+tm
  const map = new Map();
  for (const s of segs) {
    const key = `${s.dm}_${s.tm}`;
    const dur = s.to_ts - s.from_ts;
    if (!map.has(key)) map.set(key, { dm: s.dm, tm: s.tm, total_ms: 0, count: 0 });
    const e = map.get(key);
    e.total_ms += dur;
    e.count++;
  }

  // Segmento aberto (modo atual ainda em andamento)
  if (_dmSegment) {
    const key = `${_dmSegment.dm}_${_dmSegment.tm}`;
    const dur = Date.now() - _dmSegment.from_ts;
    if (!map.has(key)) map.set(key, { dm: _dmSegment.dm, tm: _dmSegment.tm, total_ms: 0, count: 0 });
    map.get(key).total_ms += dur;
  }

  const stats = [...map.values()].sort((a, b) => b.total_ms - a.total_ms);
  res.json({ stats, segments: segs.length + (_dmSegment ? 1 : 0) });
});

// ── Drive history clear ───────────────────────────────────────────────────────
app.post('/api/drive-history/clear', requireAuth, (req, res) => {
  driveHistory.length = 0;
  _dmSegment = null;
  try { fs.writeFileSync(DRIVE_HISTORY_FILE, '[]'); } catch (_) {}
  res.json({ ok: true });
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
  blower_mode:    { type: 'int',   min: 0,  max: 4 },   // 0=frente,1=frente+pés,2=pés,3=pés+parabrisa,4=parabrisa
  seat_vent_drv:  { type: 'int',   min: 0,  max: 3 },
  seat_vent_pass: { type: 'int',   min: 0,  max: 3 },
  // Liga/desliga o compressor do AC (não só o fan). Mapeia para
  // `car.hvac.ac_enable` no barramento via Shizuku. Usar junto com fan_speed
  // pra garantir que liga o AC e não só sopra ar.
  ac_enable:      { type: 'bool' },
  // ON/OFF "inteligente" do AC: o APK guarda o fan anterior. OFF→fan=0;
  // ON→ac_enable=1 + restaura o fan que estava antes de desligar.
  power:          { type: 'bool' },
  // Extras (toggles on/off)
  acmax:          { type: 'bool' },   // resfriamento máximo
  anion:          { type: 'bool' },   // ionizador
  aqs:            { type: 'bool' },   // recirc. automática por qualidade do ar
  heating:        { type: 'bool' },   // aquecimento
  front_defrost:  { type: 'bool' },   // desembaçador dianteiro
  rear_defrost:   { type: 'bool' },   // desembaçador traseiro
  auto_defrost:   { type: 'bool' },   // desembaçar automático
};

// ── HF mode (alta frequência sob demanda) ─────────────────────────────────
// PWA chama este endpoint quando entra na aba cluster/conforto pra forçar o
// APK a publicar a 250ms em vez do intervalo configurado (5s default).
// Heartbeat: PWA bate a cada 5s. Se passar 10s sem chamada, o watchdog
// publica '0' automaticamente — evita ficar travado em HF se o PWA crashar.
let _hfModeActive = false;
// Ref-count POR CLIENTE: HF fica ON enquanto QUALQUER cliente quiser, e só
// desliga quando todos saem ou expiram. Acaba o flapping (múltiplos clientes
// brigando pelo estado global, ou o app indo pro background por segundos).
const _hfClients = new Map();   // clientId -> lastBeatMs
// 15s: cada cliente bate heartbeat a cada 3s. Margem cobre throttle de timer do
// iOS e o app indo pro background por poucos segundos (volta sem "congelar").
const HF_HEARTBEAT_TIMEOUT_MS = 15_000;
function _publishHfMode(active) {
  if (!mqttClient?.connected) return;
  mqttClient.publish(`${MQTT_PREFIX}/cmd/hf_mode`, active ? '1' : '0', { qos: 1, retain: false });
}
function _recomputeHf() {
  const now = Date.now();
  for (const [id, ts] of _hfClients) if (now - ts > HF_HEARTBEAT_TIMEOUT_MS) _hfClients.delete(id);
  const want = _hfClients.size > 0;
  if (want !== _hfModeActive) {
    _hfModeActive = want;
    _publishHfMode(want);
    console.log(`[hf_mode] ${want ? 'ON' : 'OFF'} (clients=${_hfClients.size})`);
  }
}
setInterval(_recomputeHf, 2000);
app.post('/api/hf_mode', (req, res) => {
  const active = req.body?.active === true;
  const cid = String(req.body?.client_id || req.ip || 'anon');
  if (active) _hfClients.set(cid, Date.now()); else _hfClients.delete(cid);
  _recomputeHf();
  res.json({ ok: true, active: _hfModeActive, clients: _hfClients.size });
});

// Resultados dos comandos físicos de teste, por sub (window/skylight/...).
const _vehicleResults = {};

// POST /api/vehicle/test  { sub, payload } — dispara cmd/vehicle/<sub> no carro e
// aguarda o /result (até 12s). Atalho pra descobrir o valor de "abrir" vidro etc.
//   sub: window | skylight | shade | door | windows_status
//   payload: objeto ou string. Ex: window → {"window":0,"status":0}; skylight → "1"
app.post('/api/vehicle/test', async (req, res) => {
  const sub = String(req.body?.sub || '').trim();
  if (!sub) return res.status(400).json({ error: 'sub obrigatório (window|skylight|shade|door|windows_status)' });
  if (!mqttClient?.connected) return res.status(503).json({ error: 'MQTT offline' });
  let payload = req.body?.payload;
  if (payload === undefined || payload === null) payload = '';
  if (typeof payload !== 'string') payload = JSON.stringify(payload);
  delete _vehicleResults[sub];
  mqttClient.publish(`${MQTT_PREFIX}/cmd/vehicle/${sub}`, payload, { qos: 1, retain: false });
  const start = Date.now();
  while (Date.now() - start < 12_000) {
    if (_vehicleResults[sub]) return res.json({ ok: true, sub, sent: payload, result: _vehicleResults[sub].value });
    await new Promise(r => setTimeout(r, 250));
  }
  res.json({ ok: true, sub, sent: payload, result: null, note: 'sem resposta em 12s (carro dormindo?)' });
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
  res.json(result.slice(0, 10000));
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
  ws.send(JSON.stringify({ type: 'full_state', data: state, startedAt: SERVER_START_AT, bridge_version: BRIDGE_VERSION }));
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
  // Re-afirma as regras de automação no tópico retido (caso o broker tenha
  // perdido o retain num restart). O carro só reprocessa se mudou.
  relayRules();
  // Subscribe nos tópicos da integração GWM Brasil — body/lock/AC/etc. vêm
  // direto da fonte oficial via cloud, sem ruído do barramento do app.
  mqttClient.subscribe(`${GWM_TOPIC_PREFIX}/+/state`, { qos: 1 });
  console.log(`✓ Subscribed em ${GWM_TOPIC_PREFIX}/+/state (integração HA)`);
  // BYD Song Pro (BYD da Grasi) — JSON payload com charging_power + soc.
  // Usado pra mostrar LA paralela quando carrega no mesmo carregador. Opt-in
  // via toggle la_songpro (default OFF). NÃO persiste dado.
  mqttClient.subscribe('electro/telemetry/song-pro/data', { qos: 0 });
  console.log('✓ Subscribed em electro/telemetry/song-pro/data (LA Grasi)');
  // OBD Companion (iPad com ELM327 BLE) — fonte alternativa de telemetria
  // direto do CAN. Payload é JSON consolidado a 1Hz em haval/ecotrip/obd/snapshot
  // com campos planos: { ts, source, rpm, speed_kmh, ect_c, ... }. Atualiza
  // state.last_obd_ms e mescla os campos numéricos.
  mqttClient.subscribe(`${MQTT_PREFIX}/obd/snapshot`, { qos: 0 });
  console.log(`✓ Subscribed em ${MQTT_PREFIX}/obd/snapshot (OBD Companion)`);
  // A integração não publica esses tópicos com retain — broker fica sem o
  // estado atual ao subscribe. Puxamos via REST do HA no boot pra popular.
  fetchInitialStateFromHA();
});

mqttClient.on('error',      (err) => console.error('MQTT erro:', err.message));
mqttClient.on('reconnect',  ()    => console.log('MQTT reconectando...'));

// ── Cluster extra (iPad HEC) ──────────────────────────────────────────────
// O cluster nativo no iPad usa MQTT pra puxar campos que NÃO vêm direto do
// APK no MQTT individual. Publica a cada 3s no tópico cluster_extra (JSON
// consolidado) + tópicos individuais retained pra valores essenciais.
const CLUSTER_EXTRA_FIELDS = [
  'current_trip',
  'price_kwh',
  'price_gas_per_l',
  'battery_avg_price_per_kwh',
  'tank_avg_price_per_l',
  'charge_power_kw',
  'charging_state',
  'last_apk_ms',
  'last_gwm_ms',
];
// Campos numéricos individuais publicados retained — clientes pegam o último
// valor imediatamente ao subscribar (sem esperar próximo refresh).
const CLUSTER_INDIVIDUAL_FIELDS = [
  'fuel_l',            // litros no tanque (state interno do bridge, não publicado pelo APK)
];
function publishClusterExtra() {
  if (!mqttClient || !mqttClient.connected) return;
  const extra = {};
  for (const k of CLUSTER_EXTRA_FIELDS) {
    if (state[k] !== undefined && state[k] !== null) extra[k] = state[k];
  }
  mqttClient.publish(`${MQTT_PREFIX}/cluster_extra`, JSON.stringify(extra),
    { qos: 0, retain: true });
  // Tópicos individuais (retained) — o cluster do iPad subscrita em #
  // e pega esses automaticamente.
  for (const k of CLUSTER_INDIVIDUAL_FIELDS) {
    const v = state[k];
    if (v !== undefined && v !== null) {
      mqttClient.publish(`${MQTT_PREFIX}/${k}`, String(v),
        { qos: 0, retain: true });
    }
  }
}
setInterval(publishClusterExtra, 3000);
mqttClient.on('disconnect', ()    => console.log('MQTT desconectado'));

// ─── Modo Diagnóstico (debug) ─────────────────────────────────────────────
// APK publica TODAS as constantes do CarConstants.kt em haval/ecotrip/diag/<key>
// quando habilitado via cmd/diag. Bridge mantém snapshot em memória + log em
// disco (rotacionado), broadcast pelo WS (msg type=diag_update) e expõe
// endpoints REST.
const DIAG_FILE      = path.join(DATA_DIR, 'diag_state.json');
const DIAG_LOG_FILE  = path.join(DATA_DIR, 'diag_log.json');
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

  // Resultado dos comandos de teste físico (cmd/vehicle/<sub>/result) — guarda o
  // último por sub pra o endpoint POST /api/vehicle/test devolver na resposta.
  if (topic.startsWith(`${MQTT_PREFIX}/cmd/vehicle/`) && topic.endsWith('/result')) {
    const sub = topic.slice(`${MQTT_PREFIX}/cmd/vehicle/`.length, -'/result'.length);
    _vehicleResults[sub] = { value, ts: Date.now() };
    return;
  }

  // Dispatcher: tópicos da integração GWM Brasil vão pro handler dedicado;
  // outros caem no handler legado do app.
  if (topic === MQTT_PREFIX + '/car_dest_raw') {
    // Nav Relay (celular) compartilhou um destino do Maps/Waze. Resolve a
    // coordenada e devolve pro carro em cmd/nav_dest → Ecotrip abre a Chegada.
    if (!isRetained) _handleSharedDest(value);
    return;
  }
  if (topic.startsWith(GWM_TOPIC_PREFIX + '/') && topic.endsWith('/state')) {
    const id = topic.slice(GWM_TOPIC_PREFIX.length + 1, topic.length - '/state'.length);
    applyGwmEntity(id, value, isRetained);
  } else if (topic === 'electro/telemetry/song-pro/data') {
    // BYD Song Pro da Grasi — JSON com charging_power + soc. No-op se ninguém
    // tem la_songpro=true (evita CPU inútil quando feature desligada).
    if (!isRetained) handleSongProMessage(value);
  } else if (topic === MQTT_PREFIX + '/obd/snapshot') {
    // OBD Companion (iPad+ELM327) — fonte alternativa via BLE direto do CAN.
    // Payload: { ts, source, <pidId>: <number>, ... }. Atualiza state com os
    // campos numéricos (sem sobrescrever fonte APK se ele estiver fresh).
    if (isRetained) return;   // ignora retained antigo
    try {
      const o = JSON.parse(value);
      if (!o || typeof o !== 'object') return;
      const now = Date.now();
      // Idade da fonte APK pra decidir se o OBD complementa ou substitui
      const apkFresh = state.last_apk_ms && (now - state.last_apk_ms) < 30_000;
      let nApplied = 0;
      for (const [k, v] of Object.entries(o)) {
        if (k === 'ts' || k === 'source') continue;
        if (typeof v !== 'number' || !Number.isFinite(v)) continue;
        // Quando APK está fresco, OBD só preenche campos que o APK NÃO publica
        // (ex: temperaturas BMS, pressões dos pneus, knock retard, etc.).
        // Quando APK silente, OBD vira fonte primária pra tudo.
        const apkOwnsField = apkFresh && state[k] !== undefined && state[k] !== null;
        if (!apkOwnsField) {
          state[k] = v;
          nApplied++;
        }
      }
      state.last_obd_ms = now;
      if (nApplied > 0) {
        broadcast('update', state);
        // Log throttled — só primeiro msg ou a cada 60s
        const sinceLog = now - (state._obdLastLogMs || 0);
        if (sinceLog > 60_000) {
          state._obdLastLogMs = now;
          console.log(`[obd] snapshot · ${nApplied} campos · apkFresh=${apkFresh}`);
        }
      }
    } catch (e) {
      console.warn('[obd] payload inválido:', e.message);
    }
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
// Content-state da Live Activity de recarga (casa com ChargeActivityAttributes.ContentState).
function _chargeContentState() {
  return {
    soc:          +state.soc_pct || 0,
    powerKw:      +state.charge_power_kw || 0,
    sessionKwh:   +state.charge_session_kwh || 0,
    remainingMin: chargeEtaMin(),   // ETA calculado por nós (o do carro trava em ~5min)
    charging:     state.charging_state === 'Carregando',
    targetPct:    +state.charge_limit_pct || 100,
    updatedAtMs:  Date.now(),
  };
}

// ── Live Activity de viagem ao vivo ───────────────────────────────────────
const TRIP_LA_TYPE = 'TripActivityAttributes';
let _tripActive = false;
let _lastTripSnapshot = null;   // último snapshot não-vazio (p/ estado final correto)
function _tripContentState(ct, active) {
  const dist = +ct.distKm || 0;
  const net  = Math.abs(+ct.netKwh || 0);
  // Enriquecimento ao vivo: SOC, autonomia EV e pneus (glance no bloqueio dirigindo).
  const tyres = ['fl', 'fr', 'rl', 'rr'].map(p => +state[`tyre_pressure_${p}`] || 0).filter(v => v > 0);
  const tyreMin = tyres.length ? Math.min(...tyres) : 0;
  return {
    distKm: dist, netKwh: net,
    effKwh100: dist > 0.5 ? net / dist * 100 : 0,
    timeSec: Math.max(0, Math.round(+ct.timeSec || 0)),
    avgSpeedKmh: +ct.avgSpeedKmh || 0,
    fuelL: +ct.fuelL || 0,
    socPct:  Math.round(+state.soc_pct || 0),
    rangeKm: Math.round(+state.range_ev_km || 0),
    tyreMinPsi: tyreMin,
    // alerta = perda de pressão DETECTADA na viagem (checkTyreDrop) → pneu em
    // destaque na LA + notificação. Sem isso, fica só o PSI normal.
    tyreAlert: Object.values(_tyreDropAlertSent).some(Boolean),
    active: !!active,
    updatedAtMs: Date.now(),
  };
}
// Chamado pelo handler de current_trip a cada atualização do snapshot.
// isRetained: mensagem reentregue pelo broker (ex.: restart do bridge no meio da
// viagem). Nesse caso a LA JÁ existe no telefone → só atualiza, nunca cria outra
// (era a causa de aparecerem 2 LAs idênticas).
function handleTripUpdate(ct, isRetained) {
  if (ct) _lastTripSnapshot = ct;   // guarda o último snapshot não-vazio
  if (!apnsLive.enabled || notifPrefs.la_trip === false) { _tripActive = !!ct; return; }
  if (ct) {
    _cancelTripEndTimer();   // chegou snapshot → viagem em curso, cancela encerramento agendado
    const cs = _tripContentState(ct, true);
    if (!_tripActive) {
      _tripActive = true;
      // Decide CRIAR (pushStart) vs ATUALIZAR (pushUpdate) pela existência de uma
      // LA viva (token de update), não pelo `isRetained`. Antes, após restart do
      // bridge no meio da viagem, a mensagem retida só atualizava e a LA nunca era
      // criada → nenhuma LA aparecia. iOS dedupa pushStart se já houver LA viva.
      if (apnsLive.hasUpdateToken(TRIP_LA_TYPE)) {
        apnsLive.pushUpdate(TRIP_LA_TYPE, {}, cs, {}).catch(() => {});
      } else {
        apnsLive.pushStart(TRIP_LA_TYPE, '', { carName: 'Haval H6 PHEV' }, cs,
          { staleDate: Date.now() + 6 * 3600_000, alert: { title: '🚗 Viagem iniciada', body: 'Acompanhe na tela bloqueada.' } })
          .catch(e => console.warn('[apns] trip pushStart falhou:', e.message));
      }
    } else {
      apnsLive.pushUpdate(TRIP_LA_TYPE, {}, cs, {}).catch(() => {});
    }
  } else if (_tripActive) {
    // Viagem encerrada (current_trip foi a null). Mostra o resumo por 5 min e some.
    _endTripLA(5 * 60_000);
  }
}

// ── Encerramento da LA de viagem (compartilhado) ──────────────────────────────
let _tripEndTimer = null;
function _cancelTripEndTimer() { if (_tripEndTimer) { clearTimeout(_tripEndTimer); _tripEndTimer = null; } }

// Encerra a LA de viagem com o ÚLTIMO snapshot não-vazio (current_trip já é null
// aqui, senão a LA final mostraria 0.0 km — era o bug do "zerou ao encerrar").
// dismissMs = quanto tempo o iOS mantém o card no estado final antes de removê-lo.
function _endTripLA(dismissMs = 5 * 60_000) {
  _cancelTripEndTimer();
  if (!_tripActive) return;
  _tripActive = false;
  if (!apnsLive.enabled || notifPrefs.la_trip === false) return;
  const last = _tripContentState(_lastTripSnapshot || {}, false);
  _lastTripSnapshot = null;
  apnsLive.pushUpdate(TRIP_LA_TYPE, {}, last, { isFinal: true, dismissalDate: Date.now() + dismissMs })
    .catch(e => console.warn('[apns] trip end falhou:', e.message));
  // Próxima viagem recria a LA do zero (não fica presa num token de LA morta).
  apnsLive.clearUpdateTokensByType(TRIP_LA_TYPE);
}

// Fallback: o APK nem sempre limpa o current_trip retido ao fim da viagem, então a
// LA podia ficar presa indefinidamente. Ao desligar o motor, agenda o encerramento
// da LA em 5 min (cancelado se o motor religar ou chegar novo snapshot antes).
function _scheduleTripLAEnd() {
  if (!_tripActive) return;
  _cancelTripEndTimer();
  _tripEndTimer = setTimeout(() => {
    _tripEndTimer = null;
    if (state.engine_state === '1') return;   // religou no intervalo → viagem continua
    _endTripLA(0);                            // os 5 min já passaram → remove agora
  }, 5 * 60_000);
}

// ── BYD Song Pro (Grasi) — LA paralela de recarga ───────────────────────────
// Tópico único `electro/telemetry/song-pro/data` traz JSON completo (charging_power,
// soc, etc.). Tracker em MEMÓRIA: sessão começa quando power>0, energia é integrada
// (P × dt), termina quando power=0 OU soc=100. Opt-in via la_songpro (default OFF).
// Como o usuário pediu: NÃO persiste dado — só LA pra acompanhar visualmente.
const SONGPRO_LA_TYPE = 'SongProActivityAttributes';
const SONGPRO_BATTERY_KWH = 18;  // BYD Song Pro PHEV — capacidade nominal
let _songProSession = null;   // { startMs, lastMs, lastPower, lastSoc, sessionKwh, active }
const SONGPRO_STOP_GRACE_MS = 60_000;  // power=0 sustentado por 60s pra encerrar (evita flicker)
let _songProZeroSinceMs = 0;
// Última amostra recebida (mesmo ocioso) — pro app mostrar o % da bateria sempre,
// não só durante a sessão de recarga. Persistido em disco pra sobreviver a restart.
const SONGPRO_FILE = path.join(DATA_DIR, 'songpro.json');
let _songProLatest  = { soc: 0, powerKw: 0, ts: 0 };
// Localização do carro (da telemetria) e do celular do monitor (reportada pelo app),
// + cache da rota de carro carro→celular (OSRM). Pra LA de viagem mostrar distância/ETA.
let _spCarLoc   = { lat: 0, lng: 0, ts: 0 };
let _phoneLoc   = { lat: 0, lng: 0, ts: 0 };
let _routeToPhone = { distKm: null, etaMin: null, ms: 0, busy: false };

// Calcula (throttle 30s) a rota de CARRO do carro até o celular. Usa _fetchRoute:
// Mapbox driving-traffic (ETA com TRÂNSITO ao vivo) se houver token, OSRM de fallback.
// Fire-and-forget: atualiza o cache; a LA lê o último valor no próximo ciclo.
async function _maybeRouteToPhone() {
  const now = Date.now();
  if (_routeToPhone.busy || now - _routeToPhone.ms < 30_000) return;
  if (!(_spCarLoc.lat && _spCarLoc.lng) || !(_phoneLoc.lat && _phoneLoc.lng)) return;
  if (now - _phoneLoc.ts > 15 * 60_000) return;   // celular sem reportar há 15min → não calcula
  _routeToPhone.busy = true;
  try {
    const route = await _fetchRoute(_spCarLoc.lat, _spCarLoc.lng, _phoneLoc.lat, _phoneLoc.lng);
    if (route) {
      _routeToPhone.distKm = Math.round((route.distance / 1000) * 10) / 10;
      _routeToPhone.etaMin = Math.round(route.duration / 60);   // com trânsito (Mapbox)
      _routeToPhone.ms = now;
    }
  } catch (_) { /* mantém último valor em caso de falha de rede */ }
  finally { _routeToPhone.busy = false; }
}
let _songProLastEnd = { soc: 0, sessionKwh: 0, endedMs: 0 };  // resumo da última recarga
let _songProTele    = { ts: 0 };   // telemetria completa (último payload mapeado)
// Estado pra detecção de borda das notificações (lock/porta/soc/etc + odômetro
// da última manutenção). Persistido pra não repetir alertas após restart.
let _spEv = { locked: null, doorOpen: null, carOn: null, moving: false, movingNotified: false, socLow: false,
              batt12: false, cellTemp: false, imbal: false, tyrePress: false, tyreTemp: false,
              curLocId: null, lastMaintOdo: 0, tripDistM: 0, tripStartSoc: 0 };
let _songProTrail = [];      // trilha [{t,lat,lng,spd,kw,soc},…] desde a última ignição
let _songProLastTrail = null; // { trail, startMs, endMs } da viagem anterior (linha do tempo)
try {
  const d = JSON.parse(fs.readFileSync(SONGPRO_FILE, 'utf8'));
  if (d.latest)  _songProLatest  = d.latest;
  if (d.lastEnd) _songProLastEnd = d.lastEnd;
  if (d.tele)    _songProTele    = d.tele;
  if (d.evstate) _spEv = { ..._spEv, ...d.evstate };
  // Migração: descarta pontos no formato antigo [lat,lng] (sem telemetria).
  if (Array.isArray(d.trail)) _songProTrail = d.trail.filter(p => p && typeof p === 'object' && !Array.isArray(p));
  if (d.lastTrail) _songProLastTrail = d.lastTrail;
} catch (_) {}
let _songProSaveTs = 0;
function _saveSongPro(force) {
  const now = Date.now();
  if (!force && now - _songProSaveTs < 30_000) return;   // throttle: no máx a cada 30s
  _songProSaveTs = now;
  try { fs.writeFileSync(SONGPRO_FILE, JSON.stringify({ latest: _songProLatest, lastEnd: _songProLastEnd, tele: _songProTele, evstate: _spEv, trail: _songProTrail, lastTrail: _songProLastTrail })); } catch (_) {}
}

// Limiares das notificações (configuráveis depois; manutenção a cada 12.000 km).
const SP_THRESH = {
  chargeTargetPct: 100, slowKw: 3,
  socLowPct: 20, batt12Low: 11.8, cellTempHigh: 45, imbalanceMv: 50,
  tyreMin: 30, tyreMax: 38, tyreTempHigh: 60, maintKm: 12000,
};

// Dispara um alerta gated pela pref POR DEVICE (só quem ligou recebe).
function _spNotify(key, title, body) {
  if (!apnsLive.enabled) return;
  apnsLive.pushAlert(title, body, {
    threadId: key,
    allow: (deviceId) => getPrefsForDevice(deviceId)[key] === true,
  }).catch(() => {});
}

// Geofence: gating por master (key) + sub-pref por local (key_<locId>). O sub
// default é TRUE (se o master está ON e o usuário não desmarcou aquele local,
// notifica). Cada device escolhe livremente os locais de chegada e de saída.
function _spNotifyLoc(key, locId, title, body) {
  if (!apnsLive.enabled) return;
  apnsLive.pushAlert(title, body, {
    threadId: key,
    allow: (deviceId) => {
      const p = getPrefsForDevice(deviceId);
      return p[key] === true && p[`${key}_${locId}`] !== false;
    },
  }).catch(() => {});
}

// Geofence: casa só locais JÁ configurados (não cria nem usa "Local N" novo).
function _spGeofenceLoc(lat, lng) {
  if (!lat && !lng) return null;
  let best = null, bestD = Infinity;
  for (const l of songProLocs) {
    if (l.configured === false || (!l.lat && !l.lng)) continue;
    const d = haversineM(lat, lng, l.lat, l.lng);
    const r = (+l.radiusM) || 200;
    if (d <= r && d < bestD) { bestD = d; best = l; }
  }
  return best;
}

// Detecção de eventos (borda) a cada telemetria do BYD. Cada um é gated por
// pref do device em _spNotify; o estado só atualiza (não spamma).
function _songProEvents(o) {
  const locked = +o.car_locked === 1, doorOpen = +o.any_door_opened === 1, carOn = +o.car_on === 1;
  const speed = +o.speed || 0, soc = +o.soc || +o.soc_panel || 0, b12 = +o.battery_12v_voltage || 0;
  const ctMax = +o.battery_cell_temp_max || 0;
  const imbal = Math.round(((+o.battery_cell_voltage_max || 0) - (+o.battery_cell_voltage_min || 0)) * 1000);
  const charging = !!(_songProSession && _songProSession.active);

  _spEv.locked = locked;
  if (_spEv.doorOpen === false && doorOpen) _spNotify('byd_door_open', '🚪 Porta aberta', 'Uma porta do BYD foi aberta.');
  _spEv.doorOpen = doorOpen;
  const nowMs = Date.now();
  if (_spEv.carOn === false && carOn) {
    _spNotify('byd_ignition_on', '🔑 BYD ligado', 'A ignição do carro da Grasi foi ligada.');
    _spEv.movingNotified = false;   // rearma o aviso "começou a andar"
    // Obs: o início/fim da viagem é por MOVIMENTO (abaixo), não pela ignição —
    // assim "carro ligado parado" não infla o tempo nem mantém viagem fantasma.
  }
  // Estacionou (desligou): carro ON→OFF. Inclui o nome do local se conhecido.
  if (_spEv.carOn === true && !carOn) {
    const plat = +o.location_latitude || 0, plng = +o.location_longitude || 0;
    const place = matchKnownPlace(plat, plng);
    _spNotify('byd_parked', '🅿️ BYD estacionou',
      place ? `O carro foi desligado em ${place.name}.` : 'O carro foi desligado.');
  }
  _spEv.carOn = carOn;

  // Localização atual do carro (pra distância/ETA até o celular na LA de viagem).
  const _clat = +o.location_latitude || 0, _clng = +o.location_longitude || 0;
  if (_clat && _clng) _spCarLoc = { lat: _clat, lng: _clng, ts: nowMs };

  // ── Viagem por MOVIMENTO ──────────────────────────────────────────────────
  // tripStartMs = início do deslocamento; tripLastMs = último movimento. Volta a
  // andar após >60min parado (ou 1ª vez) = viagem NOVA (salva a anterior, zera a
  // trilha). Assim o tempo "em andamento" reflete só o deslocamento real, e carro
  // ligado parado não gera viagem fantasma.
  const moving = speed > 3;
  if (moving) {
    const idleMin = _spEv.tripLastMs ? (nowMs - _spEv.tripLastMs) / 60000 : Infinity;
    if (idleMin >= 60 || !_spEv.tripStartMs) {
      if (_songProTrail.length > 1) {
        _songProLastTrail = { trail: _songProTrail, startMs: _spEv.tripStartMs || 0, endMs: _spEv.tripLastMs || 0 };
      }
      _songProTrail = [];
      _spEv.tripStartMs = nowMs;
      _spEv.tripDistM = 0;                 // zera odômetro da viagem nova
      _spEv.tripStartSoc = soc;            // SOC no início (p/ consumo da LA)
      _spEv.movingNotified = false;
    }
    _spEv.tripLastMs = nowMs;
    if (!_spEv.movingNotified) {
      _spNotify('byd_moving', '🚗 BYD em movimento', `O carro começou a andar (${Math.round(speed)} km/h).`);
      _spEv.movingNotified = true;
    }
  }
  _spEv.moving = moving;

  // Acumula a trilha enquanto ligado (dedup 5m → trajeto detalhado; teto 60000
  // pontos ≈ 300km por viagem). Coordenadas a 5 casas (~1m) pra encolher o JSON.
  if (carOn) {
    const lat = +o.location_latitude || 0, lng = +o.location_longitude || 0;
    if (lat || lng) {
      const last = _songProTrail[_songProTrail.length - 1];
      if (!last || haversineM(lat, lng, last.lat, last.lng) > 5) {
        // Acumula distância só durante o deslocamento (entre tripStartMs e idle).
        if (last && _spEv.tripStartMs) _spEv.tripDistM += haversineM(lat, lng, last.lat, last.lng);
        // Ponto enriquecido p/ a linha do tempo (scrubber): tempo, posição,
        // velocidade, potência de tração (kW) e SOC no instante.
        _songProTrail.push({
          t:   Math.round((nowMs - (_spEv.tripStartMs || nowMs)) / 1000),
          lat: Math.round(lat * 1e5) / 1e5,
          lng: Math.round(lng * 1e5) / 1e5,
          spd: Math.round(+o.speed || 0),
          kw:  Math.round((+o.engine_power || 0) * 10) / 10,
          soc: Math.round(+o.soc || +o.soc_panel || 0),
        });
        if (_songProTrail.length > 60000) _songProTrail.shift();
      }
    }
  }

  // Destrancado: notifica só após X min com motor DESLIGADO e destrancado.
  // X é configurável por device (byd_unlocked_min, default 5). Dispara uma vez
  // por "episódio" (reseta quando tranca ou liga o carro).
  if (!carOn && !locked) {
    if (!_spEv.unlockedSinceMs) { _spEv.unlockedSinceMs = nowMs; _spEv.unlockedNotified = []; }
    const elapsedMin = (nowMs - _spEv.unlockedSinceMs) / 60000;
    for (const [dev, p] of Object.entries(notifPrefsByDevice)) {
      if (p.byd_unlocked !== true) continue;
      if ((_spEv.unlockedNotified || []).includes(dev)) continue;
      const min = Math.max(0, +p.byd_unlocked_min || 5);
      if (elapsedMin >= min && apnsLive.enabled) {
        apnsLive.pushAlert('🔓 BYD destrancado',
          `Destrancado há ${Math.round(elapsedMin)} min com o motor desligado.`,
          { threadId: 'byd_unlocked', allow: (d) => d === dev }).catch(() => {});
        (_spEv.unlockedNotified ||= []).push(dev);
      }
    }
  } else {
    _spEv.unlockedSinceMs = 0;
    _spEv.unlockedNotified = [];
  }

  const socLow = !charging && soc > 0 && soc < SP_THRESH.socLowPct;
  if (!_spEv.socLow && socLow) _spNotify('byd_soc_low', '🔋 Bateria baixa', `SOC do BYD em ${Math.round(soc)}%.`);
  _spEv.socLow = socLow;

  const b12low = b12 > 0 && b12 < SP_THRESH.batt12Low;
  if (!_spEv.batt12 && b12low) _spNotify('byd_batt12_low', '⚠️ Bateria 12V baixa', `12V em ${b12.toFixed(1)} V.`);
  _spEv.batt12 = b12low;

  const ctHigh = ctMax >= SP_THRESH.cellTempHigh;
  if (!_spEv.cellTemp && ctHigh) _spNotify('byd_cell_temp_high', '🌡️ Bateria quente', `Célula a ${Math.round(ctMax)}°C.`);
  _spEv.cellTemp = ctHigh;

  const imb = imbal >= SP_THRESH.imbalanceMv;
  if (!_spEv.imbal && imb) _spNotify('byd_cell_imbalance', '⚖️ Células desbalanceadas', `Δ ${imbal} mV entre células.`);
  _spEv.imbal = imb;

  const ps = [+o.tyre_pressure_left_front_psi, +o.tyre_pressure_right_front_psi, +o.tyre_pressure_left_rear_psi, +o.tyre_pressure_right_rear_psi];
  const tBad = ps.some(p => p > 0 && (p < SP_THRESH.tyreMin || p > SP_THRESH.tyreMax));
  if (!_spEv.tyrePress && tBad) _spNotify('byd_tyre_pressure', '🛞 Pressão de pneu', 'Um pneu está fora da faixa ideal (30–38 psi).');
  _spEv.tyrePress = tBad;

  const ts = [+o.tyre_temperature_left_front_c, +o.tyre_temperature_right_front_c, +o.tyre_temperature_left_rear_c, +o.tyre_temperature_right_rear_c];
  const ttHigh = ts.some(t => t >= SP_THRESH.tyreTempHigh);
  if (!_spEv.tyreTemp && ttHigh) _spNotify('byd_tyre_temp_high', '🛞 Pneu quente', 'Temperatura de pneu alta.');
  _spEv.tyreTemp = ttHigh;

  const gl = _spGeofenceLoc(+o.location_latitude || 0, +o.location_longitude || 0);
  const glId = gl ? gl.id : null;
  if (glId && glId !== _spEv.curLocId) _spNotifyLoc('byd_geofence_arrival', glId, '📍 Chegou', `BYD chegou em ${gl.name}.`);
  if (!glId && _spEv.curLocId) {
    const prev = songProLocs.find(l => l.id === _spEv.curLocId);
    if (prev) _spNotifyLoc('byd_geofence_departure', prev.id, '📍 Saiu', `BYD saiu de ${prev.name}.`);
  }
  _spEv.curLocId = glId;

  const odo = +o.odometer || 0;
  if (odo > 0) {
    if (!_spEv.lastMaintOdo) { _spEv.lastMaintOdo = odo; }   // 1ª leitura: só semeia
    else if (Math.floor(odo / SP_THRESH.maintKm) > Math.floor(_spEv.lastMaintOdo / SP_THRESH.maintKm)) {
      const mark = Math.floor(odo / SP_THRESH.maintKm) * SP_THRESH.maintKm;
      _spNotify('byd_maintenance_km', '🔧 Revisão do BYD', `Atingiu ${mark.toLocaleString('pt-BR')} km — revisão recomendada (a cada ${SP_THRESH.maintKm.toLocaleString('pt-BR')} km).`);
      _spEv.lastMaintOdo = odo;
    } else { _spEv.lastMaintOdo = odo; }
  }

  // Live Activity de deslocamento do BYD (tela bloqueada). Opt-in por device.
  _evalSongProTripLA();
}

// ── LA de deslocamento do BYD (tempo · km · SOC) ──────────────────────────────
const SONGPRO_TRIP_LA_TYPE = 'SongProTripActivityAttributes';
let _songProTripActive = !!(state._songpro_trip_la_active);
let _songProTripLastStartMs = 0;

function _songProTripEnabled() {
  return Object.values(notifPrefsByDevice).some(p => p && p.la_songpro_trip === true);
}

function _songProTripContentState(active) {
  const distKm  = _spEv.tripDistM / 1000;
  const timeSec = _spEv.tripStartMs
    ? Math.max(0, Math.round(((_spEv.tripLastMs || Date.now()) - _spEv.tripStartMs) / 1000))
    : 0;
  const soc = Math.round(_songProLatest.soc || 0);
  const avgSpeedKmh = timeSec > 30 ? distKm / (timeSec / 3600) : 0;
  return {
    distKm:      Math.round(distKm * 10) / 10,
    timeSec,
    socPct:      soc,
    avgSpeedKmh: Math.round(avgSpeedKmh),
    active:      !!active,
    updatedAtMs: Date.now(),
    distToPhoneKm: _routeToPhone.distKm,   // null se ainda não calculado/indisponível
    etaToPhoneMin: _routeToPhone.etaMin,
  };
}

// Em deslocamento = carro ligado, viagem iniciada e movimento recente (<60min de
// idle). Quando desliga ou fica parado demais, encerra. Espelha o handleTripUpdate
// do Haval, mas dirigido pela telemetria do BYD (não há current_trip publicado).
function _evalSongProTripLA() {
  if (!apnsLive.enabled) return;
  const idleMs   = _spEv.tripLastMs ? Date.now() - _spEv.tripLastMs : Infinity;
  const inTrip   = !!_spEv.carOn && !!_spEv.tripStartMs && idleMs < 60 * 60_000;

  if (inTrip && _songProTripEnabled()) {
    _maybeRouteToPhone();   // atualiza cache de distância/ETA até o celular (async, throttle)
    const cs = _songProTripContentState(true);
    if (!_songProTripActive) {
      _songProTripActive = true;
      state._songpro_trip_la_active = true; scheduleStateSave();
    }
    // Decide por TOKEN, não pela flag: se não há update token (LA não está viva no
    // device — flag presa de uma viagem anterior, app reinstalado, LA expirada),
    // (re)inicia com pushStart. Throttle de 30s evita spam enquanto o token não chega.
    if (apnsLive.hasUpdateToken(SONGPRO_TRIP_LA_TYPE)) {
      apnsLive.pushUpdate(SONGPRO_TRIP_LA_TYPE, {}, cs, {}).catch(() => {});
    } else if (Date.now() - _songProTripLastStartMs > 30_000) {
      _songProTripLastStartMs = Date.now();
      apnsLive.pushStart(SONGPRO_TRIP_LA_TYPE, '', { carName: 'BYD Song Pro' }, cs,
        { staleDate: Date.now() + 6 * 3600_000,
          alert: { title: '🚗 BYD em deslocamento', body: 'Acompanhe o trajeto na tela bloqueada.' },
          allow: (deviceId) => getPrefsForDevice(deviceId).la_songpro_trip === true })
        .catch(e => console.warn('[songpro-trip] pushStart falhou:', e.message));
    }
  } else if (_songProTripActive) {
    _songProTripActive = false;
    state._songpro_trip_la_active = false; scheduleStateSave();
    apnsLive.pushUpdate(SONGPRO_TRIP_LA_TYPE, {}, _songProTripContentState(false),
      { isFinal: true, dismissalDate: Date.now() + 5 * 60_000 })
      .catch(e => console.warn('[songpro-trip] end falhou:', e.message));
    apnsLive.clearUpdateTokensByType(SONGPRO_TRIP_LA_TYPE);
  }
}

// Mapeia o payload cru do BYD Song Pro (electro/telemetry/song-pro/data) pro
// shape camelCase que o app consome. Todos os campos numéricos viram número.
function _mapSongProTele(o) {
  const n = v => { const x = +v; return Number.isFinite(x) ? x : 0; };
  return {
    soc:          n(o.soc),
    socPanel:     n(o.soc_panel),
    soh:          n(o.soh),
    powerKw:      n(o.charging_power),
    enginePowerKw:n(o.engine_power),
    rpmFront:     n(o.engine_speed_front),
    rpmRear:      n(o.engine_speed_rear),
    packVoltage:  n(o.battery_total_voltage),
    batt12v:      n(o.battery_12v_voltage),
    cellTempMax:  n(o.battery_cell_temp_max),
    cellTempMin:  n(o.battery_cell_temp_min),
    cellVoltMax:  n(o.battery_cell_voltage_max),
    cellVoltMin:  n(o.battery_cell_voltage_min),
    evRangeKm:    n(o.electric_driving_range_km),
    fuelRangeKm:  n(o.fuel_driving_range_km),
    fuelPct:      n(o.fuel_percentage),
    odometer:     n(o.odometer),
    totalDischarge: n(o.total_discharge),
    speed:        n(o.speed),
    carLocked:    n(o.car_locked) === 1,
    carOn:        n(o.car_on) === 1,
    anyDoorOpen:  n(o.any_door_opened) === 1,
    gear:         String(o.gear || '-'),
    lat:          n(o.location_latitude),
    lng:          n(o.location_longitude),
    altitude:     n(o.location_altitude),
    tyrePressFL:  n(o.tyre_pressure_left_front_psi),
    tyrePressFR:  n(o.tyre_pressure_right_front_psi),
    tyrePressRL:  n(o.tyre_pressure_left_rear_psi),
    tyrePressRR:  n(o.tyre_pressure_right_rear_psi),
    tyreTempFL:   n(o.tyre_temperature_left_front_c),
    tyreTempFR:   n(o.tyre_temperature_right_front_c),
    tyreTempRL:   n(o.tyre_temperature_left_rear_c),
    tyreTempRR:   n(o.tyre_temperature_right_rear_c),
    carTime:      String(o.current_datetime || ''),   // horário do envio (relógio do carro, UTC)
  };
}

// Shape "vazio" — garante TODAS as chaves quando ainda não há telemetria
// (o Decodable do Swift exige todas as chaves não-opcionais presentes).
function _emptySongProTele() {
  return _mapSongProTele({});
}

// "Recarga finalizada" fica visível por até 24h depois de encerrar (some sozinho).
const SONGPRO_FINISHED_WINDOW_MS = 24 * 3600_000;

// Status consolidado pro app (Grasi Recarga): % sempre + infos da LA se carregando
// + estado "finalizada" logo após terminar.
function songProStatus() {
  const charging = !!(_songProSession && _songProSession.active);
  const finished = !charging && _songProLastEnd.endedMs > 0
    && (Date.now() - _songProLastEnd.endedMs) < SONGPRO_FINISHED_WINDOW_MS;
  const cs = charging ? _songProContentState(true) : null;
  const tele = (_songProTele && _songProTele.ts) ? _songProTele : _emptySongProTele();
  // Shape SEMPRE completo (todas as chaves nas duas situações): o Decodable
  // sintetizado do Swift lança erro se uma chave não-opcional faltar — então
  // nunca omitir finishedKwh/etc, senão o app não decodifica e mostra "Sem dados".
  return {
    soc:          charging ? cs.soc        : (_songProLatest.soc || tele.soc || 0),
    powerKw:      charging ? cs.powerKw     : 0,
    sessionKwh:   charging ? cs.sessionKwh  : 0,
    remainingMin: charging ? cs.remainingMin: 0,
    charging,
    finished,
    finishedSoc:  _songProLastEnd.soc || 0,
    finishedKwh:  +(_songProLastEnd.sessionKwh || 0).toFixed(2),
    finishedAtMs: _songProLastEnd.endedMs || 0,
    updatedAtMs:  _songProLatest.ts || (charging ? Date.now() : 0),
    hasData:      charging || _songProLatest.ts > 0 || finished,
    // Telemetria completa do veículo (bateria, pneus, autonomia, localização…)
    tele,
  };
}

// Estima minutos restantes pra atingir 100%: (100−soc)·battery_kwh / power · 60.
// Retorna 0 quando power insuficiente (=0 ou irreal).
function _songProRemainingMin(soc, power) {
  if (power <= 0.1 || soc >= 100) return 0;
  const kwhFaltam = (100 - soc) / 100 * SONGPRO_BATTERY_KWH;
  return Math.round(kwhFaltam / power * 60);
}

function _songProContentState(active) {
  const s = _songProSession || {};
  const soc   = +s.lastSoc   || 0;
  const power = active ? (+s.lastPower || 0) : 0;
  return {
    soc,
    powerKw:      power,
    sessionKwh:   +(s.sessionKwh || 0).toFixed(2),
    remainingMin: active ? _songProRemainingMin(soc, power) : 0,
    charging:     !!active,
    updatedAtMs:  Date.now(),
  };
}

// ── Histórico de recargas do BYD Song Pro (por local, com custo estimado) ────
const SONGPRO_CHARGES_FILE = path.join(DATA_DIR, 'songpro_charges.json');
const SONGPRO_LOCS_FILE    = path.join(DATA_DIR, 'songpro_locations.json');
let songProCharges = [];
let songProLocs    = [];
try { songProCharges = JSON.parse(fs.readFileSync(SONGPRO_CHARGES_FILE, 'utf8')) || []; } catch (_) {}
try { songProLocs    = JSON.parse(fs.readFileSync(SONGPRO_LOCS_FILE, 'utf8'))    || []; } catch (_) {}
function _saveSongProCharges() { try { fs.writeFileSync(SONGPRO_CHARGES_FILE, JSON.stringify(songProCharges, null, 2)); } catch (_) {} }
function _saveSongProLocs()    { try { fs.writeFileSync(SONGPRO_LOCS_FILE, JSON.stringify(songProLocs, null, 2)); } catch (_) {} }

// Acha o local existente a ≤200m, ou cria um novo (preço 0 — usuário edita depois).
function _songProLocFor(lat, lng) {
  if (!lat && !lng) return null;
  // Casa um local pré-configurado se estiver dentro do RAIO dele (cada local tem
  // o seu; default 200m). Pega o mais próximo entre os que casam.
  let best = null, bestD = Infinity;
  for (const l of songProLocs) {
    if (!l.lat && !l.lng) continue;
    const d = haversineM(lat, lng, l.lat, l.lng);
    const r = (+l.radiusM) || 200;
    if (d <= r && d < bestD) { bestD = d; best = l; }
  }
  if (best) return best;
  // Nenhum casou → local NOVO (configured:false pro app pedir nome + R$/kWh).
  const loc = { id: 'loc-' + Date.now().toString(36), name: `Local ${songProLocs.length + 1}`,
                lat, lng, radiusM: 200, pricePerKwh: 0, free: false, configured: false };
  songProLocs.push(loc); _saveSongProLocs();
  return loc;
}

// Custo de uma recarga dado o local (grátis → 0).
function _songProCost(energyKwh, loc) {
  if (!loc || loc.free) return 0;
  return +(energyKwh * (+loc.pricePerKwh || 0)).toFixed(2);
}

// Salva uma recarga concluída no histórico. `s` é o _songProSession encerrado.
function _recordSongProCharge(s, finalSoc, endMs) {
  const energy = +(s.sessionKwh || 0);
  if (energy < 0.05) return;   // descarta ruído (cabo plugado sem carga real)
  const durationSec = Math.max(1, Math.round((endMs - s.startMs) / 1000));
  const avgPowerKw  = +(energy / (durationSec / 3600)).toFixed(2);
  const loc  = _songProLocFor(s.lat || 0, s.lng || 0);
  const cost = _songProCost(energy, loc);
  songProCharges.unshift({
    id: 'sp-' + endMs.toString(36),
    startMs: s.startMs, endMs, durationSec,
    socStart: Math.round(s.startSoc || 0), socEnd: Math.round(finalSoc || 0),
    energyKwh: +energy.toFixed(2),
    avgPowerKw,
    lat: s.lat || 0, lng: s.lng || 0,
    locationId: loc ? loc.id : null,
    pricePerKwh: loc ? (+loc.pricePerKwh || 0) : 0,   // preço do momento (histórico)
    free: loc ? !!loc.free : false,
    costEstimate: cost,
  });
  if (songProCharges.length > 1000) songProCharges.length = 1000;
  _saveSongProCharges();
  console.log(`[songpro] recarga salva · ${energy.toFixed(2)}kWh · ${loc ? loc.name : 'sem local'}${loc && !loc.configured ? ' (novo)' : ''} · R$ ${cost.toFixed(2)}`);
}

function _songProEnabled() {
  // Pelo menos um device com la_songpro=true → vale a pena enviar push.
  // Varre as prefs POR DEVICE (não só pushSubs): o app "Grasi Recarga" é nativo
  // (APNs), não tem Web Push sub — então não aparecia em pushSubs e o pushStart
  // nunca disparava. O gating fino (quem recebe) continua no allow() do pushStart.
  return Object.values(notifPrefsByDevice).some(p => p && p.la_songpro === true);
}

function handleSongProMessage(jsonStr) {
  let o;
  try { o = JSON.parse(jsonStr); } catch (_) { return; }
  const power = +o.charging_power || 0;
  const soc   = +o.soc || +o.soc_panel || 0;
  if (soc <= 0 && power <= 0) return;   // amostra ruim — ignora
  // Tracking SEMPRE rola (custo zero — memória). PUSH da LA gateado por
  // _songProEnabled(). Assim, mesmo sem toggle ligado a sessão existe e o
  // user pode clicar em "Reativar cards" depois de ligar pra ver a LA do
  // que JÁ estava carregando.

  const now = Date.now();
  _songProLatest = { soc, powerKw: power, ts: now };   // % sempre disponível pro app
  _songProTele = { ..._mapSongProTele(o), ts: now };   // telemetria completa pro dash
  _songProEvents(o);                                   // notificações por borda (gated)
  _saveSongPro(false);

  if (power > 0) {
    _songProZeroSinceMs = 0;
    if (!_songProSession) {
      // Início da sessão.
      _songProSession = { startMs: now, lastMs: now, lastPower: power, lastSoc: soc, startSoc: soc,
                          lat: +o.location_latitude || 0, lng: +o.location_longitude || 0,
                          sessionKwh: 0, active: true, targetNotified: false, slowNotified: false };
      console.log(`[songpro] sessão iniciada (SOC ${soc}% · ${power} kW)`);
      _spNotify('byd_charge_start', '🔌 Recarga iniciada', `BYD começou a carregar · SOC ${soc.toFixed(0)}% · ${power.toFixed(1)} kW`);
      if (_songProEnabled() && apnsLive.enabled) {
        apnsLive.pushStart(SONGPRO_LA_TYPE, '', { carName: 'BYD Song Pro' }, _songProContentState(true),
          { staleDate: now + 6 * 3600_000, alert: { title: '🔵 BYD da Grasi carregando', body: `SOC ${soc.toFixed(0)}% · ${power.toFixed(1)} kW` },
            allow: (deviceId) => getPrefsForDevice(deviceId).la_songpro === true })
          .catch(e => console.warn('[songpro] pushStart falhou:', e.message));
      }
    } else {
      // Update: integra energia (power kW × dt h).
      const dtH = (now - _songProSession.lastMs) / 3_600_000;
      _songProSession.sessionKwh += _songProSession.lastPower * dtH;
      _songProSession.lastMs = now;
      _songProSession.lastPower = power;
      _songProSession.lastSoc = soc;
      // Alvo atingido (ex.: 100%) — uma vez por sessão.
      if (!_songProSession.targetNotified && soc >= SP_THRESH.chargeTargetPct) {
        _songProSession.targetNotified = true;
        _spNotify('byd_charge_target', '✅ Recarga no alvo', `BYD atingiu ${soc.toFixed(0)}%.`);
      }
      // Carregamento lento — uma vez por sessão.
      if (!_songProSession.slowNotified && power > 0 && power < SP_THRESH.slowKw) {
        _songProSession.slowNotified = true;
        _spNotify('byd_charge_slow', '🐌 Carregamento lento', `BYD carregando a só ${power.toFixed(1)} kW.`);
      }
      // Throttle: só envia se SOC mudou ≥1%, power ≥0.5kW, ou 60s desde último.
      const lastUpd = _songProSession.lastPushMs || 0;
      const dSocOk  = Math.abs(soc - (_songProSession.lastPushedSoc || 0)) >= 1;
      const dPwrOk  = Math.abs(power - (_songProSession.lastPushedPwr || 0)) >= 0.5;
      const dTOk    = (now - lastUpd) > 60_000;
      if (apnsLive.enabled && _songProEnabled() && (dSocOk || dPwrOk || dTOk)) {
        _songProSession.lastPushMs = now;
        _songProSession.lastPushedSoc = soc;
        _songProSession.lastPushedPwr = power;
        apnsLive.pushUpdate(SONGPRO_LA_TYPE, {}, _songProContentState(true), {}).catch(() => {});
      }
    }
  } else {
    // power = 0: pode ser pausa breve do carregador. Espera 60s pra concluir.
    if (!_songProSession) return;
    if (_songProZeroSinceMs === 0) _songProZeroSinceMs = now;
    _songProSession.lastSoc = soc;
    if (now - _songProZeroSinceMs > SONGPRO_STOP_GRACE_MS || soc >= 100) {
      const finalKwh = _songProSession.sessionKwh;
      const finalSoc = soc || _songProSession.lastSoc || 0;
      console.log(`[songpro] sessão encerrada · ${finalKwh.toFixed(2)} kWh · SOC final ${finalSoc}%`);
      // Persiste o resumo (app mostra "recarga finalizada" + % por até 24h).
      _songProLastEnd = { soc: finalSoc, sessionKwh: finalKwh, endedMs: now };
      _songProLatest  = { soc: finalSoc, powerKw: 0, ts: now };
      _saveSongPro(true);
      const stoppedEarly = finalSoc > 0 && finalSoc < (SP_THRESH.chargeTargetPct - 1) && soc < 100;
      _recordSongProCharge(_songProSession, finalSoc, now);   // grava no histórico
      // LA final atualiza em silêncio (gated por la_songpro); o card vira "finalizada".
      if (apnsLive.enabled && _songProEnabled()) {
        apnsLive.pushUpdate(SONGPRO_LA_TYPE, {}, _songProContentState(false),
          { isFinal: true, dismissalDate: now + 5 * 60_000 })
          .catch(e => console.warn('[songpro] end falhou:', e.message));
      }
      // Notificações (banner) por toggle independente da LA.
      _spNotify('byd_charge_end', '🔋 Recarga finalizada',
                `BYD · SOC ${finalSoc.toFixed(0)}% · ${finalKwh.toFixed(2)} kWh nesta sessão`);
      if (stoppedEarly) {
        _spNotify('byd_charge_stopped', '⚠️ Recarga interrompida',
                  `BYD parou em ${finalSoc.toFixed(0)}% (antes do alvo de ${SP_THRESH.chargeTargetPct}%).`);
      }
      _songProSession = null;
      _songProZeroSinceMs = 0;
    }
  }
}

// ── Live Activity de motor ligado remotamente ─────────────────────────────
// Lembrete de segurança: quando você liga o motor PELO APP (POST /api/action/
// engine_on), aparece uma LA "Motor ligado há X min · interna 24°" que conta
// sozinha no device e encerra quando o motor desliga. A pré-climatização liga
// o motor por outro caminho (HA direto) e tem LA própria, então não cai aqui.
const MOTOR_LA_TYPE = 'MotorActivityAttributes';
let _motorActive       = false;
let _motorStartedAtMs  = 0;
let _remoteEnginePending = false;   // setado pelo /api/action/engine_on
let _remoteEnginePendingTimer = null;
const PRECLIMAT_BUSY_PHASES = ['starting', 'engine_on', 'cooling', 'restoring'];
// Detecção de AUTO-START (motor ligou sem comando nosso e sem ninguém entrar).
let _lastEngineOnCmdMs = 0;   // último engine_on comandado por nós (app/pré-clima)
let _lastDoorOpenMs    = 0;   // última porta aberta (sinal de que alguém entrou)

function _motorContentState(active) {
  return {
    startedAtMs: _motorStartedAtMs || Date.now(),
    cabinTemp:   +state.inside_temp  || 0,
    outsideTemp: +state.outside_temp || 0,
    acOn:        state.ac_state === 'on' || (parseInt(state.hvac_fan_speed, 10) || 0) > 0,
    active:      !!active,
    updatedAtMs: Date.now(),
  };
}
// Chamado quando o app dispara o ligar-motor remoto.
function markRemoteEngineStart() {
  _remoteEnginePending = true;
  _lastEngineOnCmdMs = Date.now();   // marca: foi comando NOSSO (não é auto-start)
  clearTimeout(_remoteEnginePendingTimer);
  // Janela de 2 min pra o engine_state='1' confirmar; senão descarta a intenção.
  _remoteEnginePendingTimer = setTimeout(() => { _remoteEnginePending = false; }, 120_000);
}
function _startMotorLA() {
  if (!apnsLive.enabled || _motorActive || notifPrefs.la_motor === false) return;
  _motorActive      = true;
  _motorStartedAtMs = Date.now();
  apnsLive.pushStart(MOTOR_LA_TYPE, '', { carName: 'Haval H6 PHEV' }, _motorContentState(true),
    { staleDate: Date.now() + 3 * 3600_000,
      alert: { title: '🔑 Motor ligado remotamente', body: 'Não esqueça o veículo ligado.' } })
    .catch(e => console.warn('[apns] motor pushStart falhou:', e.message));
}
function _updateMotorLA() {
  if (!_motorActive || !apnsLive.enabled) return;
  apnsLive.pushUpdate(MOTOR_LA_TYPE, {}, _motorContentState(true), {}).catch(() => {});
}
function _endMotorLA() {
  if (!_motorActive) return;
  _motorActive = false;
  if (!apnsLive.enabled) return;
  apnsLive.pushUpdate(MOTOR_LA_TYPE, {}, _motorContentState(false),
    { isFinal: true, dismissalDate: Date.now() + 10_000 })
    .catch(e => console.warn('[apns] motor end falhou:', e.message));
}

// ── Live Activity persistente: veículo desprotegido ───────────────────────
// Fica visível na tela bloqueada enquanto o carro estacionado estiver
// destrancado e/ou com porta/vidro/teto/porta-malas aberto. Some sozinha
// quando tudo for fechado/trancado. Suprimida com o motor ligado (dirigindo
// com vidro aberto é normal).
const SECURITY_LA_TYPE = 'SecurityActivityAttributes';
// Persistido em state.json (_security_la_active/_sig) — sem isso o restart do
// bridge perdia o flag e a LA orfã ficava no iPhone pra sempre.
let _securityActive = !!state._security_la_active;
let _securitySig    = state._security_la_sig || '';
// Portão de saída: só alerta "desprotegido" depois que o motorista REALMENTE saiu.
//  • Caso normal (dirigiu e desligou): exige a porta do MOTORISTA (dianteira esq.).
//  • Caso destrancou com o motor já desligado: aí qualquer porta abrindo vale.
// Enquanto isso não ocorre (você ainda dentro), segura o alerta. Religar zera tudo.
// Persistidos em state.json — sem isso, restart do bridge perdia o gate e a LA
// existente parava de receber updates (sintoma: conteúdo da LA ficava stale).
let _exitedSincePark   = !!state._security_exited_since_park;
let _unlockedWhileOff  = !!state._security_unlocked_while_off;
function _persistSecurityGate() {
  state._security_exited_since_park   = _exitedSincePark;
  state._security_unlocked_while_off  = _unlockedWhileOff;
  scheduleStateSave();
}

const _DOOR_LABELS = { fl: 'Porta diant. esq.', fr: 'Porta diant. dir.', rl: 'Porta tras. esq.', rr: 'Porta tras. dir.' };
const _WIN_LABELS  = { fl: 'Vidro diant. esq.', fr: 'Vidro diant. dir.', rl: 'Vidro tras. esq.', rr: 'Vidro tras. dir.' };

function _securitySnapshot() {
  // Estado por posição (vista de cima): fl=diant.esq, fr=diant.dir, rl=tras.esq, rr=tras.dir.
  const door = {};
  const win  = {};
  for (const s of ['fl', 'fr', 'rl', 'rr']) {
    door[s] = state['door_' + s] === 'on';
    win[s]  = state['window_' + s] === 'on';
  }
  const trunkOpen   = state.door_trunk === 'on';
  const sunroofOpen = state.sunroof === 'on';
  const unlocked    = state.lock_state === 'on';   // 'on' = destrancado
  // Resumo nomeando cada item aberto (a LA desenha as posições; isto é o fallback textual).
  const issues = [];
  if (unlocked) issues.push('Destrancado');
  for (const s of ['fl', 'fr', 'rl', 'rr']) if (door[s]) issues.push(_DOOR_LABELS[s]);
  if (trunkOpen) issues.push('Porta-malas');
  for (const s of ['fl', 'fr', 'rl', 'rr']) if (win[s]) issues.push(_WIN_LABELS[s]);
  if (sunroofOpen) issues.push('Teto solar');
  return { issues, unlocked, door, win, trunkOpen, sunroofOpen };
}
function _securityContentState(snap, active) {
  return {
    unlocked:    snap.unlocked,
    doorFL: snap.door.fl, doorFR: snap.door.fr, doorRL: snap.door.rl, doorRR: snap.door.rr,
    winFL:  snap.win.fl,  winFR:  snap.win.fr,  winRL:  snap.win.rl,  winRR:  snap.win.rr,
    trunk:       snap.trunkOpen,
    sunroof:     snap.sunroofOpen,
    summary:     snap.issues.join(' · ') || 'Tudo seguro',
    active:      !!active,
    updatedAtMs: Date.now(),
  };
}
// Reavalia e cria/atualiza/encerra a LA. Chamado após cada transição de
// lock/door/window/sunroof/trunk e do motor.
// Ocupação dos bancos (car.basic.seated_state, CSV "{0,0,0,0,0}"):
//   true  = alguém sentado · false = ninguém · null = indisponível
function _anyoneSeated() {
  const raw = state.seated_state;
  if (raw == null || raw === '') return null;
  const parts = String(raw).replace(/[^0-9,]/g, '').split(',').filter(x => x !== '');
  if (parts.length === 0) return null;
  return parts.some(x => x !== '0');
}
function _evalSecurityAlert() {
  if (!apnsLive.enabled) return;
  const parked = state.engine_state === '0';   // só estacionado (evita falso alarme dirigindo)
  const snap = _securitySnapshot();
  // "Exposto" = motorista fora do carro. Sinal preferido: ocupação dos bancos
  // (seated_state) — ninguém sentado → exposto. Se indisponível, cai no gate antigo
  // (_exitedSincePark: porta abriu após desligar). Evita o alerta ficar preso a uma
  // transição de porta que pode vir "retida" após restart do bridge.
  const seated  = _anyoneSeated();
  const exposed = seated === false ? true : (seated === true ? false : _exitedSincePark);
  if (parked && exposed && snap.issues.length > 0 && notifPrefs.la_security !== false) {
    const cs  = _securityContentState(snap, true);
    // Assinatura só dos campos que importam (ignora updatedAtMs) — evita reenviar
    // update a cada mensagem do GWM quando nada mudou.
    const sig = snap.issues.join('|');
    if (!_securityActive) {
      _securityActive = true;
      _securitySig    = sig;
      state._security_la_active = true; state._security_la_sig = sig; scheduleStateSave();
      apnsLive.pushStart(SECURITY_LA_TYPE, '', { carName: 'Haval H6 PHEV' }, cs,
        { staleDate: Date.now() + 12 * 3600_000,
          alert: { title: '🔓 Veículo desprotegido', body: snap.issues.join(' · ') } })
        .catch(e => console.warn('[apns] security pushStart falhou:', e.message));
    } else if (sig !== _securitySig) {
      _securitySig = sig;
      state._security_la_sig = sig; scheduleStateSave();
      apnsLive.pushUpdate(SECURITY_LA_TYPE, {}, cs, {}).catch(() => {});
    }
    // sig igual → nada mudou, não reenvia (anti-spam).
  } else if (_securityActive) {
    _securityActive = false;
    _securitySig    = '';
    state._security_la_active = false; state._security_la_sig = ''; scheduleStateSave();
    apnsLive.pushUpdate(SECURITY_LA_TYPE, {}, _securityContentState(snap, false),
      { isFinal: true, dismissalDate: Date.now() + 60_000 })   // tudo seguro → mostra 60s e encerra
      .catch(e => console.warn('[apns] security end falhou:', e.message));
  }
}

// Força reconciliação da LA de segurança com o snapshot atual, ignorando o gate
// `_exitedSincePark` (que sumia em restart do bridge e deixava LA com conteúdo
// stale no iPhone). Se issues=0, encerra; senão atualiza com snapshot atual.
app.post('/api/security/refresh', requireAuth, async (req, res) => {
  if (!apnsLive.enabled) return res.status(503).json({ error: 'apns desativado' });
  try {
    const snap = _securitySnapshot();
    if (snap.issues.length === 0) {
      await apnsLive.pushUpdate(SECURITY_LA_TYPE, {}, _securityContentState(snap, false),
        { isFinal: true, dismissalDate: Date.now() + 60_000 });   // tudo seguro → 60s e encerra
      _securityActive = false; _securitySig = '';
    } else {
      const sig = snap.issues.join('|');
      await apnsLive.pushUpdate(SECURITY_LA_TYPE, {}, _securityContentState(snap, true), {});
      _securityActive = true; _securitySig = sig;
    }
    state._security_la_active = _securityActive; state._security_la_sig = _securitySig;
    scheduleStateSave();
    res.json({ ok: true, issues: snap.issues });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
});

// GET estado de segurança atual — o app usa pra encerrar LOCALMENTE a LA de
// "veículo desprotegido" presa (push-to-start sem update token não dá pra encerrar
// por push enquanto o app está fechado; ao abrir, o app consulta e encerra local).
app.get('/api/security/status', requireAuth, (_req, res) => {
  const snap = _securitySnapshot();
  res.json({ issues: snap.issues, active: _securityActive });
});

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
    _chargeFinalKwh                  = 0;   // nova sessão → zera o total guardado
    _chargePwrWin = []; _chargeEtaMin = 0;  // zera o ETA calculado
    // Reinicia tracking de desaceleração da recarga
    _chargePeakKw        = 0;
    _chargeSlowAlertSent = false;
    _chargeSlowCheckTs   = 0;
    addEvent('charge_start', `Recarga iniciada · SOC: ${chargeStartSoc.toFixed(0)}%`);
    // Cria a Live Activity de recarga via push-to-start (app fechado/bloqueado).
    // O alert é necessário pra apresentar a LA; o timer de live update mantém ela
    // atualizada e o fim encerra com sendChargeLiveUpdate(true).
    if (apnsLive.enabled && notifPrefs.la_charge !== false) {
      // Cria a LA só se não houver uma viva (robusto a restart/redelivery — antes
      // o !isRetained impedia a criação após restart no meio da recarga).
      if (apnsLive.hasUpdateToken('ChargeActivityAttributes')) {
        apnsLive.pushUpdate('ChargeActivityAttributes', {}, _chargeContentState(), {}).catch(() => {});
      } else {
        apnsLive.pushStart('ChargeActivityAttributes', '', { carName: 'Haval H6 PHEV' }, _chargeContentState(),
          { staleDate: Date.now() + 3600_000, alert: { title: '⚡ Recarga iniciada', body: 'Acompanhe o progresso na tela bloqueada.' } })
          .catch(e => console.warn('[apns] charge pushStart falhou:', e.message));
      }
    }
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
        // Usa o mesmo tag das live-updates pra que o 1º update silencioso substitua
        // esta notif (sem acumular) em vez de criar uma segunda notification separada.
        // skipApnsAlert: o nativo já tocou no alert do push-to-start da LA;
        // este é só refinamento (potência/tempo) → web-push pro PWA, sem banner duplo.
        sendPush('⚡ Recarga iniciada', `${pwr.toFixed(1)} kW · tempo restante: ${remStr}`, 'charge_start',
          { tag: CHARGE_LIVE_TAG, skipApnsAlert: true });
      }, 30000);
    }
  } else if (prev === 'Carregando') {
    if (chargeStartTimer) { clearTimeout(chargeStartTimer); chargeStartTimer = null; }
    chargeEndingNotifSent = false;       // reset para próxima sessão
    // Recarga encerrou: limpa o token de update da LA com folga (deixa o update
    // final ser entregue) pra que a PRÓXIMA recarga recrie a LA do zero.
    setTimeout(() => apnsLive.clearUpdateTokensByType('ChargeActivityAttributes'), 60_000);
    const endSoc = state.soc_pct || 0;
    addEvent('charge_end', `Recarga concluída · SOC: ${chargeStartSoc.toFixed(0)}% → ${endSoc.toFixed(0)}%`);
    // Calcula temperatura média da sessão encerrada
    if (_chargeTempSamples.length > 0) {
      const avg = _chargeTempSamples.reduce((a, b) => a + b, 0) / _chargeTempSamples.length;
      _lastChargeAvgTemp = Math.round(avg * 10) / 10;
      console.log(`🌡 Temp média recarga: ${_lastChargeAvgTemp}°C (${_chargeTempSamples.length} amostras)`);
    }
    _chargeTempSamples = [];

    // ── Alerta de FALHA de carregamento ────────────────────────────────────
    // Recarga parou (qualquer motivo) ANTES de atingir o limite, com 1% de
    // tolerância (limite − 1). Ex.: limite 100 → alerta se parar em ≤98%.
    // Pega problema no carregamento (cabo soltou, falha do carregador, etc.).
    // endSoc > 0 evita falso alarme se o SOC vier zerado/desconhecido.
    const chargeLimit  = +state.charge_limit_pct || 100;
    const chargeFailed = endSoc > 0 && endSoc < (chargeLimit - 1);
    if (!isRetained && chargeFailed) {
      const aTitle = '⚠️ Carregamento interrompido';
      const aBody  = `Parou em ${endSoc.toFixed(0)}% (limite ${chargeLimit}%). Verifique o carregamento.`;
      sendPush(aTitle, aBody, 'charge_stopped', { renotify: true });
      // Encerra a Live Activity de recarga com o alerta (em vez do "concluída").
      // Mesmo toggle (charge_stopped, por-device) governa o push E o alerta na LA.
      const chargeStoppedOn = pushSubs.some(s => getPrefsForDevice(s.device_id).charge_stopped !== false);
      if (apnsLive.enabled && notifPrefs.la_charge !== false && chargeStoppedOn) {
        stopChargeLiveTimer();
        apnsLive.pushUpdate('ChargeActivityAttributes', {}, {
          soc: endSoc, powerKw: 0,
          sessionKwh: Math.max(_chargeFinalKwh, +state.charge_session_kwh || 0),
          remainingMin: 0, charging: false,
          targetPct: chargeLimit, updatedAtMs: Date.now(),
        }, { isFinal: true, dismissalDate: Date.now() + 30 * 60_000, alert: { title: aTitle, body: aBody } })
          .catch(e => console.warn('[apns] charge-stopped end falhou:', e.message));
      }
    }

    if (!isRetained && value === 'Finalizado' && chargeFailed) {
      // "Finalizou" abaixo do limite → já alertamos acima; só limpa a sessão.
      stopChargeLiveTimer();
      chargeSessionStartMs = 0;
      state.charge_session_start_ms    = 0;
      state.charge_session_kwh_at_init = 0;
    } else if (!isRetained && value === 'Finalizado') {
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
      // skipApnsAlert: o toque do fim vem pelo alert da LA final (logo abaixo).
      // Web-push continua indo pro PWA. Evita banner duplicado no nativo.
      sendPush('✅ Recarga concluída', parts.length ? parts.join(' · ') : 'Sessão encerrada', 'charge_end',
        { skipApnsAlert: true });
      // Encerra a "live notification" (substitui pela final, agora com som via LA)
      stopChargeLiveTimer();
      sendChargeLiveUpdate(true /* final */);
      chargeSessionStartMs = 0;
      state.charge_session_start_ms    = 0;
      state.charge_session_kwh_at_init = 0;
    }
  }
  // Inicia o ciclo de "live notification" quando começa a carregar.
  // Aceita retained: se o server reinicia com o carro carregando, o broker entrega
  // o estado como retained (packet.retain = true) e sem isso o timer nunca começa.
  // startChargeLiveTimer() já tem guarda interna contra duplo-início.
  if (value === 'Carregando') startChargeLiveTimer();
}

// ── Live notification durante recarga ─────────────────────────────────────────
// Notif fixa no lock screen com tag 'charge-live'. Atualiza a cada 60s ou
// quando SOC/potência mudam significativamente. Cada update substitui a
// notif anterior pelo `tag` igual. Silent = true → atualiza sem ding/vibrar.
let _chargeLiveTimer = null;
let _chargeLiveLast  = { soc: -1, pwr: -1, rem: -1, ts: 0 };
const CHARGE_LIVE_TAG = 'charge-live';
// Maior kWh visto na sessão atual. O APK zera o contador ao terminar a recarga,
// então guardamos o total aqui pra a LA final NÃO mostrar 0 (fica fixo até o
// usuário limpar a LA). Reseta ao iniciar uma nova sessão.
let _chargeFinalKwh = 0;

// ── ETA de recarga calculado por NÓS ──────────────────────────────────────
// O tempo do carro trava em ~5 min e nunca zera. Calculamos: kWh faltante até o
// alvo (SOC) ÷ potência média recente (lado bateria, V×I) → minutos. Zera ao
// atingir o alvo. Janela de 60s + EMA pra contagem suave; mantém o último valor
// se a potência cai a ~0 (pausa). charge_power_kw é lado-bateria → sem fator de
// eficiência. Reseta a cada nova sessão.
let _chargePwrWin = [];          // {ts, kw} dos últimos CHARGE_ETA_WIN_MS
let _chargeEtaMin = 0;           // ETA suavizado (min)
const CHARGE_ETA_WIN_MS = 60_000;
function _recalcChargeEta() {
  const soc  = +state.soc_pct || 0;
  const lim  = +state.charge_limit_pct || 100;
  const need = Math.max(0, (lim - soc) / 100 * BATTERY_CAPACITY_KWH);   // kWh até o alvo
  if (need <= 0.05) { _chargeEtaMin = 0; return; }
  const now = Date.now();
  _chargePwrWin = _chargePwrWin.filter(s => now - s.ts <= CHARGE_ETA_WIN_MS);
  const avg = _chargePwrWin.length
    ? _chargePwrWin.reduce((a, s) => a + s.kw, 0) / _chargePwrWin.length
    : (+state.charge_avg_power_kw || 0);
  if (avg < 0.3) return;   // potência ~0 (pausa) → mantém o último ETA
  const raw = need / avg * 60;
  _chargeEtaMin = _chargeEtaMin > 0 ? (_chargeEtaMin * 0.6 + raw * 0.4) : raw;   // EMA
}
// Minutos a mostrar: nosso ETA enquanto carregando; 0 caso contrário.
function chargeEtaMin() {
  return (state.charging_state === 'Carregando') ? Math.max(0, Math.round(_chargeEtaMin)) : 0;
}

function _fmtChargeLiveBody(stateObj) {
  const soc = +stateObj.soc_pct || 0;
  const pwr = +stateObj.charge_power_kw || 0;
  const rem = chargeEtaMin();   // nosso ETA
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
  const rem = chargeEtaMin();   // nosso ETA (o do carro trava em ~5min)
  const now = Date.now();
  if (!isFinal) {
    const dT = now - _chargeLiveLast.ts;
    // Mínimo de 10s entre pushes event-driven — respeita o budget do APNs
    // mesmo se dados chegarem em rajada do carro. Updates atrasados sao
    // capturados no proximo evento ou no heartbeat de 60s.
    if (dT < 10_000) return;
    // Throttle: passada a porta de 10s, so envia se houve mudança REAL
    // significativa (SOC≥1%, potência≥0.5kW) ou se completou 60s sem update.
    const dSoc = Math.abs(soc - _chargeLiveLast.soc);
    const dPwr = Math.abs(pwr - _chargeLiveLast.pwr);
    const significant = dSoc >= 1 || dPwr >= 0.5 || dT >= 60_000;
    if (!significant) return;
  }
  _chargeLiveLast = { soc, pwr, rem, ts: now };
  // No final, usa o total guardado (o APK zera o contador ao terminar a recarga).
  const kwh   = isFinal ? Math.max(_chargeFinalKwh, +state.charge_session_kwh || 0) : (+state.charge_session_kwh || 0);
  const title = isFinal ? '✅ Recarga concluída' : '⚡ Carregando…';
  const bodyState = isFinal ? { ...state, charge_session_kwh: kwh } : state;
  const body  = _fmtChargeLiveBody(bodyState) || 'Sessão encerrada';
  // skipApnsAlert: no nativo o som vem pelo alert da LA (abaixo, só no final).
  // Updates não-finais são silent de qualquer forma. Web-push segue pro PWA.
  sendPush(title, body, 'charge_live', {
    tag: CHARGE_LIVE_TAG,
    silent: !isFinal,                // updates não fazem barulho; a final sim
    renotify: isFinal,
    skipHistory: !isFinal,           // updates ao vivo não entram na central de notif
    skipApnsAlert: true,
    // Dados de estado embarcados no payload: o app nativo iOS usa para atualizar
    // a Live Activity diretamente a partir da notificação (sem fetch extra).
    state: { soc, pwr, rem: Math.max(0, Math.round(rem)), kwh, charging: !isFinal },
  });
  // Live Activity (iOS) via APNs — manda o mesmo content-state pra todos os
  // pushTokens registrados pelo app companion. No-op se APNS_ENABLED=false.
  // No FINAL leva alert → toca/vibra no nativo (é o "toque" do fim da recarga).
  if (apnsLive.enabled) {
    apnsLive.pushUpdate('ChargeActivityAttributes', {}, {
      soc, powerKw: pwr,
      // No final, usa o total guardado (o APK zera o contador ao terminar).
      sessionKwh: isFinal ? Math.max(_chargeFinalKwh, +state.charge_session_kwh || 0) : (+state.charge_session_kwh || 0),
      remainingMin: Math.max(0, Math.round(rem)),
      charging: !isFinal,
      targetPct: +state.charge_limit_pct || 100,
      updatedAtMs: now,
    }, { isFinal, dismissalDate: isFinal ? Date.now() + 30 * 60_000 : undefined, alert: isFinal ? { title, body } : undefined })
      .catch(err => console.warn('[apns] push falhou:', err.message));
  }
}

// ── Endpoints da Live Activity (iOS companion) ────────────────────────────────
// O app registra:
//  - push-to-start token (por TIPO de LA): permite o servidor CRIAR a LA.
//  - update token (por atividade): permite atualizar/encerrar uma LA específica.
const LA_TYPES = ['ChargeActivityAttributes', 'PreClimatActivityAttributes', 'TripActivityAttributes',
                  'MotorActivityAttributes', 'SecurityActivityAttributes', 'SongProActivityAttributes',
                  'SongProTripActivityAttributes'];

// push-to-start token (por tipo de Live Activity)
// GET /api/songpro/status — % da bateria do BYD Song Pro sempre, + infos da
// recarga (potência, kWh, min restantes) quando carregando. Consumido pelo app
// "Grasi Recarga" pra mostrar num card. Protegido pelo requireAuth global.
app.get('/api/songpro/status', (req, res) => {
  res.json(songProStatus());
});

// Trilha do trajeto atual (desde a última partida). Endpoint separado do status
// porque o app puxa o status a 500ms (gauges) e a trilha bem mais devagar — a
// rota cresce lentamente e pode ser grande (viagem inteira).
app.get('/api/songpro/trail', (req, res) => {
  // Busca incremental: o app manda ?since=<nº de pontos que já tem> e recebe só
  // os novos. `full=true` = mande tudo (primeira carga, ou trilha resetada/nova
  // ignição → since fica > total). Evita rebaixar a trilha inteira a cada 4s.
  const total = _songProTrail.length;
  let since = parseInt(req.query.since, 10);
  if (!Number.isFinite(since) || since < 0 || since > total) since = 0;   // inválido/reset → full
  res.json({
    trail:       _songProTrail.slice(since),
    full:        since === 0,
    total,
    tripStartMs: _spEv.tripStartMs || 0,
    tripLastMs:  _spEv.tripLastMs || 0,
  });
});

// Última viagem encerrada (enriquecida) — pra linha do tempo quando o carro está
// parado. Estática até a próxima viagem terminar, então não precisa de incremental.
app.get('/api/songpro/last-trip', (req, res) => {
  const lt = _songProLastTrail || {};
  res.json({ trail: lt.trail || [], startMs: lt.startMs || 0, endMs: lt.endMs || 0 });
});

// Histórico de recargas do BYD + locais (com preço/kWh). O app filtra por
// local e mês e soma energia/custo. Protegido pelo requireAuth global.
app.get('/api/songpro/charges', (req, res) => {
  res.json({ charges: songProCharges, locations: songProLocs });
});

// Lançamento MANUAL de recarga (ex.: recargas antigas). Body:
// { endMs, durationSec, energyKwh, socStart, socEnd, locationId? | locationName?, pricePerKwh?, free? }
app.post('/api/songpro/charges', (req, res) => {
  const b = req.body || {};
  const energy = +b.energyKwh;
  if (!Number.isFinite(energy) || energy <= 0) return res.status(400).json({ error: 'energyKwh inválido' });
  const endMs = +b.endMs || Date.now();
  const durationSec = Math.max(1, parseInt(b.durationSec, 10) || 0);
  let loc = null;
  if (b.locationId) {
    loc = songProLocs.find(l => l.id === b.locationId) || null;
  } else if (typeof b.locationName === 'string' && b.locationName.trim()) {
    loc = { id: 'loc-' + endMs.toString(36), name: b.locationName.trim().slice(0, 60),
            lat: +b.lat || 0, lng: +b.lng || 0,
            pricePerKwh: +b.pricePerKwh || 0, free: !!b.free, configured: true };
    songProLocs.push(loc); _saveSongProLocs();
  }
  const charge = {
    id: 'sp-m-' + endMs.toString(36) + '-' + Math.random().toString(36).slice(2, 6),
    startMs: endMs - durationSec * 1000, endMs, durationSec,
    socStart: Math.round(+b.socStart || 0), socEnd: Math.round(+b.socEnd || 0),
    energyKwh: +energy.toFixed(2),
    avgPowerKw: +(energy / (durationSec / 3600)).toFixed(2),
    lat: loc?.lat || 0, lng: loc?.lng || 0,
    locationId: loc ? loc.id : null,
    pricePerKwh: loc ? (+loc.pricePerKwh || 0) : (+b.pricePerKwh || 0),
    free: loc ? !!loc.free : !!b.free,
    costEstimate: _songProCost(energy, loc),
    manual: true,
  };
  songProCharges.push(charge);
  songProCharges.sort((a, b) => b.endMs - a.endMs);
  _saveSongProCharges();
  res.json(charge);
});

// Edita uma recarga: energia e/ou custo. Custo informado = override manual
// (fica fixo, não é recalculado por mudança de preço do local).
app.patch('/api/songpro/charges/:id', (req, res) => {
  const c = songProCharges.find(x => x.id === req.params.id);
  if (!c) return res.status(404).json({ error: 'not found' });
  const b = req.body || {};
  if (b.energyKwh !== undefined) {
    const e = +b.energyKwh;
    if (Number.isFinite(e) && e >= 0) {
      c.energyKwh = +e.toFixed(2);
      if (c.durationSec > 0) c.avgPowerKw = +(e / (c.durationSec / 3600)).toFixed(2);
      // Recalcula custo pelo preço guardado, exceto se houver override manual.
      if (b.costEstimate === undefined && !c.costManual) {
        c.costEstimate = c.free ? 0 : +(e * (+c.pricePerKwh || 0)).toFixed(2);
      }
    }
  }
  if (b.costEstimate !== undefined) {
    const v = +b.costEstimate;
    if (Number.isFinite(v) && v >= 0) { c.costEstimate = +v.toFixed(2); c.costManual = true; }
  }
  _saveSongProCharges();
  res.json(c);
});

// Cria um local PRÉ-configurado (ponto + raio + nome + preço). Quando o carro
// recarregar dentro do raio, já puxa nome/preço automaticamente.
app.post('/api/songpro/locations', (req, res) => {
  const b = req.body || {};
  const loc = {
    id: 'loc-' + Date.now().toString(36),
    name: (typeof b.name === 'string' && b.name.trim() ? b.name.trim() : 'Local').slice(0, 60),
    lat: +b.lat || 0, lng: +b.lng || 0,
    radiusM: Math.max(30, Math.min(5000, parseInt(b.radiusM, 10) || 200)),
    pricePerKwh: Math.max(0, +b.pricePerKwh || 0),
    free: !!b.free, configured: true,
  };
  songProLocs.push(loc); _saveSongProLocs();
  res.json(loc);
});

// Edita nome/preço/raio/posição de um local; recomputa o custo das recargas dele.
app.patch('/api/songpro/locations/:id', (req, res) => {
  const loc = songProLocs.find(l => l.id === req.params.id);
  if (!loc) return res.status(404).json({ error: 'not found' });
  const b = req.body || {};
  if (typeof b.name === 'string' && b.name.trim()) loc.name = b.name.trim().slice(0, 60);
  if (b.pricePerKwh !== undefined) {
    const p = +b.pricePerKwh;
    if (Number.isFinite(p) && p >= 0) loc.pricePerKwh = p;
  }
  if (b.free !== undefined) loc.free = !!b.free;
  if (b.radiusM !== undefined) loc.radiusM = Math.max(30, Math.min(5000, parseInt(b.radiusM, 10) || loc.radiusM || 200));
  if (b.lat !== undefined) loc.lat = +b.lat || loc.lat;
  if (b.lng !== undefined) loc.lng = +b.lng || loc.lng;
  loc.configured = true;   // editou → deixa de ser "novo"
  _saveSongProLocs();
  // NÃO recalcula recargas passadas: o preço é histórico — cada recarga guarda
  // o custo do momento. A mudança só vale pras PRÓXIMAS recargas.
  res.json(loc);
});

// Localização do celular do monitor — usada pra calcular distância/ETA (carro→celular)
// na LA de viagem do BYD. O app reporta periodicamente enquanto a LA está ativa.
app.post('/api/phone-location', (req, res) => {
  const lat = +(req.body && req.body.lat), lng = +(req.body && req.body.lng);
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || (lat === 0 && lng === 0))
    return res.status(400).json({ error: 'lat/lng válidos obrigatórios' });
  _phoneLoc = { lat, lng, ts: Date.now() };
  res.json({ ok: true });
});

// ── Planejamento de rota p/ previsão de SOC na chegada ──────────────────────
// Geocoding (Nominatim) + rota de carro (OSRM) + perfil de elevação (Open-Meteo).
// Retorna distância, duração, subida e descida acumuladas. O app projeta o SOC.
async function _geocode(q) {
  const url = `https://nominatim.openstreetmap.org/search?format=jsonv2&limit=1&q=${encodeURIComponent(q)}`;
  const r = await fetch(url, { headers: { 'User-Agent': 'EcotripImpulse/1.0 (haval ecotrip)' }, signal: AbortSignal.timeout(8000) });
  const j = await r.json();
  if (!Array.isArray(j) || !j.length) return null;
  return { lat: +j[0].lat, lng: +j[0].lon, name: j[0].display_name };
}

// Extrai lat/lng de uma URL de Maps/Waze. Cobre os formatos mais comuns do
// compartilhamento ("Compartilhar local" do Google Maps e do Waze).
function _parseLatLngFromUrl(u) {
  const pats = [
    /@(-?\d+\.\d+),(-?\d+\.\d+)/,                    // .../maps/place/.../@lat,lng,17z
    /[?&]q=(-?\d+\.\d+),\s*(-?\d+\.\d+)/,            // ?q=lat,lng
    /[?&]query=(-?\d+\.\d+),\s*(-?\d+\.\d+)/,        // ?query=lat,lng (api=1)
    /[?&]daddr=(-?\d+\.\d+),\s*(-?\d+\.\d+)/,        // ?daddr=lat,lng
    /[?&]destination=(-?\d+\.\d+),\s*(-?\d+\.\d+)/,  // ?destination=lat,lng
    /[?&]ll=(-?\d+\.\d+),\s*(-?\d+\.\d+)/,           // waze ?ll=lat,lng
    /[?&]to=ll\.(-?\d+\.\d+),(-?\d+\.\d+)/,          // waze ?to=ll.lat,lng
    /!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)/,                // google data=...!3dlat!4dlng
  ];
  for (const re of pats) { const m = u.match(re); if (m) return { lat: +m[1], lng: +m[2] }; }
  return null;
}

// Recebe o texto compartilhado pelo Maps/Waze (link e/ou nome) e devolve {lat,lng,name}.
// Estratégia: pega a 1ª URL → tenta parsear coordenada direto → se for link curto
// (maps.app.goo.gl / ul.waze.com), segue o redirect e parseia o destino final →
// se ainda não houver coordenada, geocodifica o texto restante via Nominatim.
async function _resolveSharedDest(text) {
  if (!text) return null;
  const raw = String(text).trim();
  const urlMatch = raw.match(/https?:\/\/[^\s]+/);
  const url = urlMatch ? urlMatch[0] : '';
  if (url) {
    let hit = _parseLatLngFromUrl(url);
    if (!hit && /goo\.gl|app\.goo\.gl|ul\.waze\.com|waze\.com\/ul|maps\.apple/.test(url)) {
      try {
        const r = await fetch(url, { redirect: 'follow', headers: { 'User-Agent': 'Mozilla/5.0' }, signal: AbortSignal.timeout(9000) });
        const finalUrl = r.url || '';
        hit = _parseLatLngFromUrl(finalUrl);
        if (!hit) { const body = await r.text(); hit = _parseLatLngFromUrl(body); }
      } catch (e) { console.warn('[shareDest] redirect falhou:', e.message); }
    }
    if (hit && Number.isFinite(hit.lat) && Number.isFinite(hit.lng)) {
      // nome = texto sem a URL (ex.: "Aeroporto de Goiânia https://...") ou coordenada.
      const name = raw.replace(url, '').trim() || `${hit.lat.toFixed(5)}, ${hit.lng.toFixed(5)}`;
      return { lat: hit.lat, lng: hit.lng, name };
    }
  }
  // Sem coordenada na URL → geocodifica o texto (tira a URL pra não poluir a busca).
  const q = raw.replace(/https?:\/\/[^\s]+/g, '').trim();
  if (q) { const g = await _geocode(q); if (g) return g; }
  return null;
}

// Recebe o payload do tópico car_dest_raw, resolve o destino e publica pro carro.
async function _handleSharedDest(value) {
  let text = value;
  try { const j = JSON.parse(value); text = j.text || j.url || value; } catch (_) { /* texto puro */ }
  try {
    const d = await _resolveSharedDest(text);
    if (!d) { console.warn('[shareDest] não resolveu:', String(text).slice(0, 120)); return; }
    const payload = JSON.stringify({ lat: d.lat, lng: d.lng, name: d.name, ts: Date.now() });
    mqttClient.publish(`${MQTT_PREFIX}/cmd/nav_dest`, payload, { qos: 1, retain: false });
    console.log(`[shareDest] → carro: ${d.name} (${d.lat.toFixed(5)},${d.lng.toFixed(5)})`);
  } catch (e) { console.warn('[shareDest] erro:', e.message); }
}
// Busca a rota: Mapbox driving-traffic (ETA COM trânsito ao vivo) se houver MAPBOX_TOKEN;
// senão OSRM (sem trânsito). Retorna distância(m), duração(s), geometria e flag de trânsito.
async function _fetchRoute(fromLat, fromLng, toLat, toLng) {
  const tok = process.env.MAPBOX_TOKEN;
  if (tok) {
    try {
      const mu = `https://api.mapbox.com/directions/v5/mapbox/driving-traffic/`
        + `${fromLng},${fromLat};${toLng},${toLat}`
        + `?access_token=${tok}&geometries=geojson&overview=full&alternatives=false`;
      const mr = await fetch(mu, { signal: AbortSignal.timeout(9000) });
      const mj = await mr.json();
      const rt = mj && mj.routes && mj.routes[0];
      if (rt) return { distance: rt.distance, duration: rt.duration, coords: rt.geometry.coordinates, traffic: true };
      console.warn('[route] Mapbox sem rota:', mj && mj.message);
    } catch (e) { console.warn('[route] Mapbox falhou, caindo p/ OSRM:', e.message); }
  }
  const u = `https://router.project-osrm.org/route/v1/driving/${fromLng},${fromLat};${toLng},${toLat}`
    + `?overview=full&geometries=geojson&alternatives=false&steps=false`;
  const rr = await fetch(u, { signal: AbortSignal.timeout(9000) });
  const rj = await rr.json();
  const route = rj && rj.routes && rj.routes[0];
  if (!route) return null;
  return { distance: route.distance, duration: route.duration, coords: route.geometry.coordinates, traffic: false };
}
async function _routeElevation(fromLat, fromLng, toLat, toLng) {
  const route = await _fetchRoute(fromLat, fromLng, toLat, toLng);
  if (!route) return null;
  const coords = route.coords;   // [lng,lat] ao longo da rota
  // Downsample p/ ≤100 pontos (limite do Open-Meteo) — ceil garante não estourar.
  const step = Math.max(1, Math.ceil(coords.length / 99));
  const pts = []; for (let i = 0; i < coords.length; i += step) pts.push(coords[i]);
  if (pts[pts.length - 1] !== coords[coords.length - 1]) pts.push(coords[coords.length - 1]);
  const lats = pts.map(c => c[1]).join(','), lngs = pts.map(c => c[0]).join(',');
  let climbM = 0, descentM = 0;
  try {
    const er = await fetch(`https://api.open-meteo.com/v1/elevation?latitude=${lats}&longitude=${lngs}`, { signal: AbortSignal.timeout(9000) });
    const ej = await er.json();
    const elev = ej && ej.elevation;
    if (Array.isArray(elev)) {
      for (let i = 1; i < elev.length; i++) {
        const d = elev[i] - elev[i - 1];
        if (d > 0) climbM += d; else descentM += -d;
      }
    }
  } catch (_) { /* elevação indisponível → climb/descent ficam 0 */ }
  return {
    distanceKm: Math.round((route.distance / 1000) * 10) / 10,
    durationMin: Math.round(route.duration / 60),
    climbM: Math.round(climbM), descentM: Math.round(descentM),
    traffic: route.traffic,
  };
}
app.get('/api/route-plan', async (req, res) => {
  try {
    const fromLat = +req.query.from_lat, fromLng = +req.query.from_lng;
    if (!Number.isFinite(fromLat) || !Number.isFinite(fromLng))
      return res.status(400).json({ error: 'from_lat/from_lng obrigatórios' });
    let toLat = +req.query.to_lat, toLng = +req.query.to_lng, toName = req.query.q || '';
    if (!Number.isFinite(toLat) || !Number.isFinite(toLng)) {
      if (!req.query.q) return res.status(400).json({ error: 'to_lat/to_lng ou q (destino) obrigatórios' });
      const g = await _geocode(String(req.query.q));
      if (!g) return res.status(404).json({ error: 'destino não encontrado' });
      toLat = g.lat; toLng = g.lng; toName = g.name;
    }
    const plan = await _routeElevation(fromLat, fromLng, toLat, toLng);
    if (!plan) return res.status(502).json({ error: 'rota indisponível' });
    res.json({ ...plan, destLat: toLat, destLng: toLng, destName: toName });
  } catch (e) {
    res.status(500).json({ error: String(e.message || e) });
  }
});

app.post('/api/activity/pts-token', (req, res) => {
  const { type, push_to_start_token, device_id } = req.body || {};
  if (!type || !push_to_start_token || !LA_TYPES.includes(String(type)))
    return res.status(400).json({ error: 'type válido e push_to_start_token obrigatórios' });
  apnsLive.registerStartToken(String(type), device_id ? String(device_id) : '', String(push_to_start_token));
  res.json({ ok: true, registered: apnsLive.tokenCount() });
});

// update token (por atividade)
app.post('/api/activity/start', (req, res) => {
  const { push_token, activity_id, type, device_id } = req.body || {};
  if (!push_token || !activity_id) return res.status(400).json({ error: 'push_token e activity_id obrigatórios' });
  const t = LA_TYPES.includes(String(type)) ? String(type) : 'ChargeActivityAttributes';
  apnsLive.registerUpdateToken(t, String(activity_id), device_id ? String(device_id) : '', String(push_token));
  // Reconcilia a LA de segurança ao registrar o token: se ela iniciou mas o carro
  // já está seguro, encerra agora. Cobre o race em que o "end" foi enviado ANTES do
  // app reportar o update token (a LA ficava presa em "Veículo desprotegido").
  if (t === SECURITY_LA_TYPE && apnsLive.enabled) {
    const snap = _securitySnapshot();
    if (snap.issues.length === 0) {
      _securityActive = false; _securitySig = '';
      state._security_la_active = false; state._security_la_sig = ''; scheduleStateSave();
      apnsLive.pushUpdate(SECURITY_LA_TYPE, {}, _securityContentState(snap, false),
        { isFinal: true, dismissalDate: Date.now() + 60_000 }).catch(() => {});   // tudo seguro → 60s e encerra
    }
  }
  res.json({ ok: true, registered: apnsLive.tokenCount() });
});
app.post('/api/activity/stop', (req, res) => {
  const { activity_id } = req.body || {};
  if (activity_id) apnsLive.unregisterActivity(String(activity_id));
  res.json({ ok: true, registered: apnsLive.tokenCount() });
});

// Device token de notificação de alerta (remote notification) do app nativo.
app.post('/api/apns/register', (req, res) => {
  const { device_token, device_id } = req.body || {};
  if (!device_token) return res.status(400).json({ error: 'device_token obrigatório' });
  apnsLive.registerAlertToken(device_id ? String(device_id) : '', String(device_token));
  res.json({ ok: true });
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
  state.last_gwm_ms = Date.now();   // marca atividade da integração GWM Brasil
  const field = GWM_TOPIC_MAP[id];
  if (!field) {
    console.log(`[gwm] id desconhecido='${id}' value='${value}' isRetained=${isRetained}`);
    return;
  }
  _fieldSource[field] = 'gwm';   // rastreia origem por campo

  // ── Binary body (doors, lock, AC) ─────────────────────────────────────────
  if (GWM_BODY_BINARY.has(field)) {
    const norm = value === '1' ? 'on' : 'off';
    const prev = state[field];
    state[field] = norm;
    if (!isRetained && prev !== undefined && prev !== null && prev !== norm) {
      if (field === 'lock_state') {
        if (norm === 'on') {
          if (state.engine_state === '0') { _unlockedWhileOff = true; _persistSecurityGate(); }   // destrancou parado
          addEvent('lock_open',  'Carro destrancado');
        } else             addEvent('lock_close', 'Carro trancado');
      } else if (field === 'ac_state') {
        if (norm === 'on') addEvent('ac_on',  'Ar condicionado ligado');
        else               addEvent('ac_off', 'Ar condicionado desligado');
      } else if (field === 'door_trunk') {
        if (norm === 'on') {
          // Porta-malas só conta como "saída" no caso de destrancar parado.
          if (state.engine_state === '0' && _unlockedWhileOff) { _exitedSincePark = true; _persistSecurityGate(); }
          addEvent('trunk_open',  'Porta-malas aberta');
          sendPush('🧳 Porta-malas aberta', 'Verifique se está segura.', 'trunk_open');
        } else {
          addEvent('trunk_close', 'Porta-malas fechada');
          sendPush('🧳 Porta-malas fechada', 'Porta-malas foi fechada.', 'trunk_close');
          _cancelTrunkForgottenTimer();
        }
      } else {
        // door_fl/fr/rl/rr
        const side = field.slice(5);
        const label = DOOR_NAMES[side] || side.toUpperCase();
        if (norm === 'on') {
          // Saída confirmada: porta do MOTORISTA (fl) com motor desligado, OU
          // qualquer porta quando o carro foi destrancado com o motor já parado.
          if (state.engine_state === '0' && (side === 'fl' || _unlockedWhileOff)) { _exitedSincePark = true; _persistSecurityGate(); }
          _lastDoorOpenMs = Date.now();
          // Trava de segurança da pré-clima: porta aberta = motorista entrou →
          // cancela o desligamento remoto (esta via, applyGwmEntity, é a que roda
          // com o app aberto/HF ligado — faltava o abort aqui).
          if (_preclimatAutoOffPending()) _abortPreclimatAutoOff('porta aberta');
          addEvent('door_open',  `${label} aberta`);
          sendPush('🚪 Porta aberta', label, 'door_open');
        } else {
          addEvent('door_close', `${label} fechada`);
          sendPush('🚪 Porta fechada', label, 'door_close');
        }
      }
    }
    // Trava/portas mudaram → reavalia a LA de "veículo desprotegido". (AC não é
    // problema de segurança, mas o eval ignora — chamar é idempotente.)
    if (field !== 'ac_state') _evalSecurityAlert();
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
    _evalSecurityAlert();
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
    _evalSecurityAlert();
    return;
  }

  // ── Engine state (cru "1"=ligado, "0"=desligado, mesma convenção do app) ─
  if (field === 'engine_state') {
    const prev = state.engine_state;
    state.engine_state = value;
    if (!isRetained && prev !== undefined && prev !== null && prev !== value) {
      if (value === '1') {
        _exitedSincePark = false; _unlockedWhileOff = false; _persistSecurityGate();   // voltou/dirigindo → rearma o portão
        addEvent('engine_on',  'Motor ligado');
        sendPush('🔑 Motor ligado',  'O veículo foi ligado.', 'engine_on');
        checkRefuelOnEngineOn();
        _cancelTrunkForgottenTimer();
        _resetTyreTrip();
      } else if (value === '0') {
        addEvent('engine_off', 'Motor desligado');
        sendPush('🔑 Motor desligado', 'O veículo foi desligado.', 'engine_off');
        _fuelLAtPark = +state.fuel_l || 0;
        _fuelParkTs  = Date.now();
        _scheduleWindowForgottenAlert();
        _scheduleLockForgottenAlert();
        _scheduleTrunkForgottenAlert();
        _resetTyreTrip();
      } else {
        _cancelWindowForgottenTimer();
        _cancelLockForgottenTimer();
        _cancelTrunkForgottenTimer();
        _resetTyreTrip();
      }
    }
    // Estacionou/ligou → reavalia a LA de "veículo desprotegido" (só dispara
    // estacionado; ligar o motor encerra a LA se estava ativa).
    _evalSecurityAlert();
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
  if (field === 'soc_pct') { checkSocLowIdle(); _checkSocFullLong(+state.soc_pct || 0); }
}

// Fonte de origem do último valor de cada campo: 'apk' (carro) ou 'gwm' (HA).
// Atualizado em applyMqttMessage / applyGwmEntity. Exposto via /api/state pro
// PWA mostrar ícone 🚗/📡 ao lado de cada métrica.
const _fieldSource = {};

function applyMqttMessage(key, value, isRetained = false) {
  const _now = Date.now();
  state.last_apk_ms = _now;   // qualquer msg em haval/ecotrip/* = APK do carro vivo
  _fieldSource[key] = 'apk';  // rastreia origem por chave
  // Status (LWT) é tratado ANTES de atualizar last_update_ms — assim conseguimos
  // detectar LWT 'offline' que chega atrasado da sessão anterior (corrida com
  // o reconnect rápido): se uma mensagem fresca do carro chegou nos últimos
  // ~5s, a LWT é stale e deve ser ignorada (senão o app mostra "Desconectado"
  // mesmo com o carro publicando dados).
  if (key === 'status') {
    if (value === 'online') {
      state.car_online = true;
    } else if (value === 'offline') {
      const ageSec = (_now - (state.last_update_ms || 0)) / 1000;
      if (ageSec > 5) {
        state.car_online = false;
      } else {
        console.log(`[mqtt] LWT 'offline' stale ignorado (última msg do carro há ${ageSec.toFixed(1)}s)`);
      }
    }
    state.last_update_ms = _now;
    return;
  }
  state.last_update_ms = _now;
  // Qualquer mensagem do carro (não-status) = carro está online. Fonte mais
  // confiável que a LWT — se o carro publica, está conectado por definição.
  state.car_online = true;

  // Body/lock/etc. migradas pra HA — ignora publishes do app pra essas chaves.
  // Bridge usa exclusivamente os tópicos da integração GWM Brasil (sem ruído).
  if (MIGRATED_TO_HA.has(key)) return;

  // Resultados de comandos HVAC: cmd/hvac/<control>/result
  if (key.startsWith('cmd/hvac/') && key.endsWith('/result')) {
    const control = key.slice('cmd/hvac/'.length, -'/result'.length);
    console.log(`[hvac] resultado ${control}: ${value}`);
    broadcast('hvac_result', { control, result: value });
    return;
  }

  switch (key) {
    // Status já tratado no topo da função (com proteção contra LWT stale).
    // Heartbeat (5s, do carro): só serve pra manter last_update_ms fresco e
    // detectar TCP morto rápido. last_update_ms já foi atualizado no topo.
    case 'heartbeat': return;
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
          _cancelTrunkForgottenTimer();
          _cancelTripEndTimer();   // religou → não encerra a LA de viagem
          _resetTyreTrip();
          // AUTO-START: motor ligou SEM comando nosso (>30s) E sem ninguém entrar
          // (nenhuma porta aberta nos últimos 3 min) E fora de pré-clima ativa.
          // Distingue "ligou sozinho estacionado" de "ligou pra dirigir" (que abre porta).
          const _nowEng = Date.now();
          const _commandedByUs = (_nowEng - _lastEngineOnCmdMs < 30_000)
            || PRECLIMAT_BUSY_PHASES.includes(preclimatStatus.phase);
          const _someoneEntered = (_nowEng - _lastDoorOpenMs < 180_000);
          if (!_commandedByUs && !_someoneEntered) {
            addEvent('engine_self_start', 'Motor ligou sozinho (sem comando e sem ninguém entrar) — provável auto-start do carro');
            sendPush('⚠️ Motor ligou sozinho', 'O motor ligou sem comando do app e sem ninguém entrar — provável auto-start do PHEV ou remote start externo.', 'engine_self_start');
            console.log('[engine] ⚠️ AUTO-START detectado (sem comando nosso, sem porta aberta recente)');
          }
          // Motor ligado pelo app (fora da pré-clima): inicia a LA de lembrete.
          if (_remoteEnginePending && !PRECLIMAT_BUSY_PHASES.includes(preclimatStatus.phase)) {
            _remoteEnginePending = false;
            _startMotorLA();
          }
        } else if (value === '0') {
          addEvent('engine_off', 'Motor desligado');
          sendPush('🔑 Motor desligado', 'O veículo foi desligado.', 'engine_off');
          _scheduleWindowForgottenAlert();
          _scheduleLockForgottenAlert();
          _scheduleTrunkForgottenAlert();
          _resetTyreTrip();
          _endMotorLA();
          _scheduleTripLAEnd();   // desligou → encerra a LA de viagem em 5 min (fallback p/ current_trip preso)
        } else {
          _cancelWindowForgottenTimer();
          _cancelLockForgottenTimer();
          _cancelTrunkForgottenTimer();
          _resetTyreTrip();
        }
      }
      // Estacionou/ligou → reavalia a LA de "veículo desprotegido".
      if (!isRetained) _evalSecurityAlert();
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
          else {
            addEvent('lock_close', 'Carro trancado', realTs);
            _cancelLockForgottenTimer();   // carro foi trancado — cancela alerta
          }
        }
        _evalSecurityAlert();
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
    case 'hvac_fan_speed': {
      state.hvac_fan_speed = value;
      const fan = parseInt(value, 10) || 0;
      if (fan <= 0) {
        _cancelAcParkedTimer(); // AC desligado (0) ou inválido (-1, carro dormindo) — cancela alerta pendente
      } else if (state.engine_state === '0') {
        _scheduleAcParkedAlert(); // AC ligou com motor parado — agenda alerta
      }
      break;
    }
    case 'hvac_sync_enable':    state.hvac_sync_enable    = value; break; // '0'|'1'
    case 'hvac_auto_enable':    state.hvac_auto_enable    = value; break; // '0'|'1'
    case 'hvac_ac_enable':      state.hvac_ac_enable      = value; break; // '0'|'1' — car.hvac.ac_enable
    case 'hvac_acmax':          state.hvac_acmax          = value; break; // '0'|'1' — resfriamento máximo
    case 'hvac_anion':          state.hvac_anion          = value; break; // '0'|'1' — ionizador
    case 'hvac_aqs':            state.hvac_aqs            = value; break; // '0'|'1' — recirc. autom. qualidade do ar
    case 'hvac_heating':        state.hvac_heating        = value; break; // '0'|'1' — aquecimento
    case 'hvac_front_defrost':  state.hvac_front_defrost  = value; break; // '0'|'1'
    case 'hvac_rear_defrost':   state.hvac_rear_defrost   = value; break; // '0'|'1'
    case 'hvac_auto_defrost':   state.hvac_auto_defrost   = value; break; // '0'|'1'
    case 'hvac_pm25':           state.hvac_pm25           = value; break; // µg/m³ (leitura)
    case 'hvac_blower_mode':    state.hvac_blower_mode    = value; break; // 0..4 direção do sopro
    case 'hvac_power_mode':     state.hvac_power_mode     = value; break; // 0=AC off (mestre) | 1=on
    case 'seat_belt_warning':   state.seat_belt_warning   = value; break; // 0=ok | >0 ocupante sem cinto
    case 'seated_state': {
      const prevSeat = state.seated_state;
      state.seated_state = value;   // ocupação dos bancos (CSV cru)
      if (!isRetained && prevSeat !== value) _evalSecurityAlert();   // saiu/entrou → reavalia desproteção
      break;
    }
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
      // Trava de segurança da pré-clima: porta aberta = motorista entrou →
      // cancela o desligamento remoto NA HORA (sem esperar a histerese de 3s).
      if (norm === 'on' && _preclimatAutoOffPending()) _abortPreclimatAutoOff('porta aberta');
      if (norm === _hystPending[key]) break;
      _hystPending[key] = norm;
      clearTimeout(_hystTimers[key]);
      _hystTimers[key] = setTimeout(() => {
        state[key] = norm;
        if (norm !== prevDoorStates[side]) {
          prevDoorStates[side] = norm;
          const label = DOOR_NAMES[side] || side.toUpperCase();
          if (norm === 'on') {
            _lastDoorOpenMs = Date.now();
            addEvent('door_open',  `${label} aberta`);
            sendPush('🚪 Porta aberta', label, 'door_open');
          } else {
            addEvent('door_close', `${label} fechada`);
            sendPush('🚪 Porta fechada', label, 'door_close');
          }
        }
        _evalSecurityAlert();
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
            _cancelTrunkForgottenTimer();
          }
        }
        _evalSecurityAlert();
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
        _evalSecurityAlert();
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
          else {
            addEvent('window_close', `${label} fechado`, realTs);
            // Se todos os vidros estão fechados, cancela o alerta pendente
            const anyOpen = ['fl','fr','rl','rr'].some(s => (s === wside ? norm : state[`window_${s}`]) === 'on');
            if (!anyOpen) _cancelWindowForgottenTimer();
          }
        }
        _evalSecurityAlert();
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
    case 'tyre_pressure_fl': { state.tyre_pressure_fl = num(value); checkTyrePressure('FL', num(value), isRetained, state.tyre_temp_fl); checkTyreDrop('fl', num(value)); break; }
    case 'tyre_pressure_fr': { state.tyre_pressure_fr = num(value); checkTyrePressure('FR', num(value), isRetained, state.tyre_temp_fr); checkTyreDrop('fr', num(value)); break; }
    case 'tyre_pressure_rl': { state.tyre_pressure_rl = num(value); checkTyrePressure('RL', num(value), isRetained, state.tyre_temp_rl); checkTyreDrop('rl', num(value)); break; }
    case 'tyre_pressure_rr': { state.tyre_pressure_rr = num(value); checkTyrePressure('RR', num(value), isRetained, state.tyre_temp_rr); checkTyreDrop('rr', num(value)); break; }
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
      if (lng && lng !== 0) { state.gps_lng = lng; state.gps_ts = Date.now(); _maybeUpdateCarHeading(); checkGeofence(); }
      break;
    }

    // Telemetria ao vivo
    case 'steering_angle': state.steering_angle = num(value); break;
    case 'speed_kmh': {
      const prevSpeed = +state.speed_kmh || 0;
      state.speed_kmh = num(value);
      const curSpeed  = +state.speed_kmh || 0;
      if (curSpeed > 0) {
        _cancelAcParkedTimer(); // carro em movimento — cancela alerta pendente
      } else if (prevSpeed > 0) {
        // Carro acabou de parar; agenda alerta se AC estiver ligado
        if ((parseInt(state.hvac_fan_speed, 10) || 0) > 0) _scheduleAcParkedAlert();
      }
      if (curSpeed >= 5 && prevSpeed < 5) _captureTyreBaseline();
      break;
    }
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
    case 'inside_temp':       state.inside_temp        = num(value); _updateMotorLA(); break;
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
        // Janela de potência (60s) + recálculo do nosso ETA.
        if (p > 0.3) _chargePwrWin.push({ ts: Date.now(), kw: p });
        _recalcChargeEta();
        state.charge_remaining_min = chargeEtaMin();   // sobrescreve o valor travado do carro
        // ── Alerta carga desacelera ──────────────────────────────────────────
        // Rastreia pico da sessão e detecta queda >30% sustentada por 5+ min.
        if (p > _chargePeakKw) _chargePeakKw = p;
        if (_chargePeakKw > 3 && p < _chargePeakKw * 0.7 && !_chargeSlowAlertSent
            && (+state.soc_pct || 0) < 90) {  // acima de 90% é normal desacelerar
          if (_chargeSlowCheckTs === 0) _chargeSlowCheckTs = Date.now();
          if (Date.now() - _chargeSlowCheckTs > 5 * 60_000) {
            _chargeSlowAlertSent = true;
            sendPush(
              '⚡ Carga desacelerou',
              `Potência caiu de ${_chargePeakKw.toFixed(1)} para ${p.toFixed(1)} kW · possível limitação térmica`,
              'charge_slow',
              { tag: 'charge_slow' }
            );
          }
        } else if (p >= _chargePeakKw * 0.7 || (+state.soc_pct || 0) >= 90) {
          _chargeSlowCheckTs = 0; // recuperou ou entrou no final da carga — reinicia janela
        }
      }
      // Event-driven: potência mudou → tenta atualizar a LA (throttle interno gateia).
      if (state.charging_state === 'Carregando') sendChargeLiveUpdate(false);
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
        _chargeFinalKwh                = 0;
        _chargePwrWin = []; _chargeEtaMin = 0;
        addEvent('charge_start', `Recarga iniciada · SOC: ${chargeStartSoc.toFixed(0)}%`);
      }
      state.charge_session_kwh = newKwh;
      // Guarda o maior kWh da sessão (só cresce) p/ a LA final não cair pra 0.
      if (state.charging_state === 'Carregando' && newKwh > _chargeFinalKwh) _chargeFinalKwh = newKwh;
      break;
    }
    case 'charge_remaining_min': {
      // Ignoramos o valor do carro (trava em ~5min) — usamos NOSSO ETA.
      const rem = chargeEtaMin();
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
      // Event-driven: tempo restante mudou → tenta atualizar a LA (throttle interno gateia).
      if (state.charging_state === 'Carregando') sendChargeLiveUpdate(false);
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
    case 'ha/drive_mode/state': {
      const m = parseInt(value);
      if ([0, 1, 3].includes(m)) { state.drive_mode = m; _onDriveModeChange(); }
      break;
    }
    case 'cmd/drive_mode/result':
      broadcast('drive_mode_result', { result: value });
      break;
    case 'ha/power_reserve/state': {
      const m = parseInt(value);
      if ([1, 2].includes(m)) state.power_reserve = m;
      break;
    }
    case 'cmd/power_reserve/result':
      broadcast('power_reserve_result', { result: value });
      break;
    case 'ha/charge_soc_target/state': {
      const m = parseInt(value);
      if (m >= 20 && m <= 80) state.charge_soc_target = m;
      break;
    }
    case 'cmd/charge_soc_target/result':
      broadcast('charge_soc_target_result', { result: value });
      break;
    case 'ha/terrain_mode/state': {
      const m = parseInt(value);
      if ([0,1,2,3,4,5,11].includes(m)) { state.terrain_mode = m; _onDriveModeChange(); }
      break;
    }
    case 'cmd/terrain_mode/result':
      broadcast('terrain_mode_result', { result: value });
      break;
    case 'ha/regen_level/state': {
      const m = parseInt(value);
      if ([0,1,2].includes(m)) state.regen_level = m;
      break;
    }
    case 'cmd/regen_level/result':
      broadcast('regen_level_result', { result: value });
      break;
    case 'ha/one_pedal/state': {
      const m = parseInt(value);
      if ([0,1].includes(m)) state.one_pedal = m;
      break;
    }
    case 'cmd/one_pedal/result':
      broadcast('one_pedal_result', { result: value });
      break;
    case 'ha/regen_power/state':
      state.regen_power_pct = parseFloat(value) || 0;
      break;
    case 'ha/esp/state': {
      const m = parseInt(value);
      if ([0,1].includes(m)) state.esp_enable = m;
      break;
    }
    case 'cmd/esp/result':
      broadcast('esp_result', { result: value });
      break;
    case 'ha/steer_mode/state': {
      const m = parseInt(value);
      if ([0,1,2].includes(m)) state.steer_mode = m;
      break;
    }
    case 'cmd/steer_mode/result':
      broadcast('steer_mode_result', { result: value });
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
    case 'batt_12v_pct':      state.batt_12v_pct        = num(value); checkBatt12Low(); break;
    case 'range_ev_km':       state.range_ev_km         = Math.round(num(value)); break;
    case 'range_ice_km':      state.range_ice_km        = Math.round(num(value)); break;
    case 'battery_power_pct': state.battery_power_pct = Math.round(num(value)); break;
    case 'engine_rpm':        state.engine_rpm        = Math.round(num(value)); break;

    // SOC — fonte primária: HA publica via automação em haval/ecotrip/soc_pct (retain)
    // Uma vez recebido, marca haSocActive = true e ignora trip_a/b soc_current para soc_pct
    case 'soc_pct':
      haSocActive   = true;
      state.soc_pct = num(value);
      // Event-driven: SOC mudou → tenta atualizar a Live Activity de recarga
      // na hora (em vez de esperar o timer de 60s). O throttle interno
      // (dSoc≥1 / dPwr≥0.5 / 60s) garante que não vira spam.
      if (state.charging_state === 'Carregando') sendChargeLiveUpdate(false);
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
            // Validação de energy_kwh: o APK às vezes envia valor parcial
            // (perdeu samples no meio da sessão). Se SOC delta × capacidade
            // for muito maior que o reportado, recalcula via SOC.
            const PACK_KWH = 34;
            const socDelta = (newCharge.soc_end || 0) - (newCharge.soc_start || 0);
            if (socDelta > 0) {
              const expected = (socDelta / 100) * PACK_KWH;
              const reported = +newCharge.energy_kwh || 0;
              // Tolerância: se expected > 2× reported, o APK perdeu telemetria
              if (reported > 0 && expected > reported * 2 && !newCharge.energy_kwh_overridden) {
                console.log(`[charge] energy_kwh corrigido ts=${newCharge.timestamp_ms}: ${reported.toFixed(2)}→${expected.toFixed(2)} kWh (SOC ${newCharge.soc_start}→${newCharge.soc_end})`);
                newCharge.energy_kwh_reported = reported;     // mantém o original pra debug
                newCharge.energy_kwh = +expected.toFixed(3);
                newCharge.energy_kwh_corrected = true;
                // Recalcula avg_power_kw com base na nova energia
                if (newCharge.duration_sec > 0) {
                  newCharge.avg_power_kw = +((newCharge.energy_kwh / (newCharge.duration_sec / 3600)).toFixed(2));
                }
                // Se há cost_override com total, recalcula perKwh com a nova energy.
                // Sem isso, perKwh ficaria inflado (calculado quando energy era parcial)
                // e contamina o battery_avg_price_per_kwh.
                if (newCharge.cost_override && +newCharge.cost_override.total > 0) {
                  const newPerKwh = newCharge.cost_override.total / newCharge.energy_kwh;
                  console.log(`[charge] cost_override.perKwh recalculado: ${newCharge.cost_override.perKwh}→${newPerKwh.toFixed(4)}`);
                  newCharge.cost_override.perKwh = +newPerKwh.toFixed(4);
                }
              }
            }
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
      handleTripUpdate(state.current_trip, isRetained);
      break;
    }

    default: break;
  }
  scheduleStateSave();
}

// ── Start ─────────────────────────────────────────────────────────────────────

// [removido 2026-05-27] Watchdog do APNs de produção: a produção JÁ funciona.
// A causa do 403 era a auth key escopada só p/ Sandbox; a key GGH3WT8RC6 (Sandbox &
// Production) resolveu. Não há mais push periódico de "Live Activities ativadas".

server.listen(PORT, () => {
  const pkg = require('./package.json');
  console.log(`\n🚗  EcoTrip Bridge v${pkg.version}`);
  // [removido 2026-05-27] watchdog do APNs de produção: já resolvido (era a auth key
  // escopada só p/ Sandbox; a key nova GGH3WT8RC6 cobre produção). Não precisa mais
  // do push periódico "Live Activities ativadas".
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
