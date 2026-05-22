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
const RADARS_FILE         = path.join(__dirname, 'radars.json');
const RADARS_IGNORED_FILE = path.join(__dirname, 'radars_ignored.json');
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
  try { fs.writeFileSync(PUSH_SUBS_FILE, JSON.stringify(pushSubs)); } catch (_) {}
}

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

async function sendPush(title, body) {
  // Registra no histórico sempre — mesmo sem subscribers (útil para debug)
  const ts = Date.now();
  notifHistory.unshift({ ts, title, body });
  if (notifHistory.length > NOTIF_HISTORY_MAX) notifHistory.length = NOTIF_HISTORY_MAX;
  saveNotifHistory();

  // Notifica clientes WebSocket sobre nova notificação (para badge)
  state.notif_latest_ts = ts;
  broadcast('update', { notif_latest_ts: ts });

  if (!pushSubs.length) {
    console.log(`Push "${title}" — sem subscribers registrados`);
    return;
  }
  const payload = JSON.stringify({ title, body });
  const dead = [];
  await Promise.all(pushSubs.map(async (sub, i) => {
    try {
      await webpush.sendNotification(sub, payload);
    } catch (e) {
      const code = e.statusCode;
      console.error(`Push error [${code}] ...${sub.endpoint?.slice(-30)}: ${e.body || e.message}`);
      // Remove subscrições expiradas (410/404), inválidas (400) ou com VAPID errado (401)
      if (code === 410 || code === 404 || code === 400 || code === 401) dead.push(i);
    }
  }));
  if (dead.length) {
    console.log(`Push: removendo ${dead.length} subscrição(ões) inválida(s)`);
    dead.reverse().forEach(i => pushSubs.splice(i, 1));
    savePushSubs();
  }
}

// ── Preferências de notificações push ────────────────────────────────────────
const NOTIF_DEFAULTS = {
  charge_start:      true,   // ⚡ Recarga iniciada
  charge_end:        true,   // ✅ Recarga concluída
  charge_ending:     false,  // 🔔 Aviso de proximidade do fim da recarga
  charge_ending_min: 5,      // minutos antes do fim para enviar o aviso (1–20)
  door_open:         true,   // 🚪 Qualquer porta aberta
  door_close:        false,  // 🚪 Qualquer porta fechada
  trunk_open:        true,   // 🧳 Porta-malas aberta
  trunk_close:       true,   // 🧳 Porta-malas fechada
  engine_on:         true,   // 🔑 Motor ligado
  engine_off:        false,  // 🔑 Motor desligado
  app_update:        true,   // 📱 Nova versão do app instalada no carro
  trip_end:          true,   // 🏁 Viagem concluída (auto-trip)
  geofence_arrival:  true,   // 📍 Chegou em local conhecido
  geofence_departure:false,  // 🚗 Saiu de local conhecido
  maintenance_soon:  true,   // 🔧 Manutenção se aproximando (dentro do alert_km)
  maintenance_overdue: true, // ⚠️ Manutenção atrasada
  anomaly_detected:  true,   // ⚠️ Anomalia detectada na telemetria
};
let notifPrefs = { ...NOTIF_DEFAULTS };
try {
  if (fs.existsSync(NOTIF_PREFS_FILE))
    notifPrefs = { ...NOTIF_DEFAULTS, ...JSON.parse(fs.readFileSync(NOTIF_PREFS_FILE, 'utf8')) };
} catch (_) {}
function saveNotifPrefs() {
  try { fs.writeFileSync(NOTIF_PREFS_FILE, JSON.stringify(notifPrefs, null, 2)); } catch (_) {}
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
// Os valores chegam diretamente em PSI (sem conversão necessária)
const TYRE_PSI_MIN = 34;   // abaixo disso → alerta
const TYRE_PSI_MAX = 40;   // acima disso  → alerta
const tyreAlertSent = {};   // evita spam: chave = 'FL_low' | 'FL_high' etc.
function checkTyrePressure(pos, psi, isRetained = false) {
  if (!psi || psi < 5) return;   // valor inválido ou zero
  const lowKey  = `${pos}_low`;
  const highKey = `${pos}_high`;
  if (psi < TYRE_PSI_MIN) {
    if (!tyreAlertSent[lowKey] && !isRetained) {
      tyreAlertSent[lowKey] = true;
      delete tyreAlertSent[highKey];
      sendPush('⚠️ Pneu com pressão baixa', `${pos}: ${psi.toFixed(1)} PSI (mín ${TYRE_PSI_MIN} PSI)`);
    } else {
      tyreAlertSent[lowKey] = true;   // marca como "já visto" mesmo em retained
    }
  } else if (psi > TYRE_PSI_MAX) {
    if (!tyreAlertSent[highKey] && !isRetained) {
      tyreAlertSent[highKey] = true;
      delete tyreAlertSent[lowKey];
      sendPush('⚠️ Pneu com pressão alta', `${pos}: ${psi.toFixed(1)} PSI (máx ${TYRE_PSI_MAX} PSI)`);
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
        const radarAlertCount = Array.isArray(d.radar_alerts) ? d.radar_alerts.length : 0;
        autoTripsArr.push({ tripId: d.tripId, ...d.autoTrip, ...hybrid, radarAlertCount });
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

// ── Radares (OSM Overpass — speed cameras do Brasil inteiro) ─────────────
// Cache de radares em radars.json. Refresh manual via POST /api/radars/refresh
// ou automático se o arquivo tem >7 dias. Análise por viagem: pra cada sample
// com GPS, busca radar mais próximo. Se ≤30m E velocidade excede limite +
// tolerância brasileira (7 km/h até 100, 7% acima), marca como alerta.
let radarsArr = [];
let radarBuckets = new Map();   // chave geohash 0.01° (~1km) → [radar...]
let ignoredRadars = new Set();  // IDs de radares marcados pra ignorar pelo usuário
try {
  if (fs.existsSync(RADARS_IGNORED_FILE)) {
    const data = JSON.parse(fs.readFileSync(RADARS_IGNORED_FILE, 'utf8'));
    ignoredRadars = new Set((data.ids || []).map(String));
  }
} catch (_) {}
function _saveIgnoredRadars() {
  try {
    fs.writeFileSync(RADARS_IGNORED_FILE, JSON.stringify({
      updatedAt: new Date().toISOString(),
      ids: Array.from(ignoredRadars),
    }, null, 2));
  } catch (_) {}
}
function _rbKey(lat, lng) { return Math.floor(lat * 100) + ':' + Math.floor(lng * 100); }
function _rebuildRadarIndex() {
  radarBuckets = new Map();
  for (const r of radarsArr) {
    const k = _rbKey(r.lat, r.lng);
    let arr = radarBuckets.get(k);
    if (!arr) { arr = []; radarBuckets.set(k, arr); }
    arr.push(r);
  }
}
function _loadRadars() {
  try {
    if (fs.existsSync(RADARS_FILE)) {
      const data = JSON.parse(fs.readFileSync(RADARS_FILE, 'utf8'));
      radarsArr = data.radars || [];
      _rebuildRadarIndex();
      console.log(`✓ Radares: ${radarsArr.length} carregados (atualizado em ${data.updatedAt || '?'})`);
    }
  } catch (e) { console.error('Aviso radars.json:', e.message); }
}
_loadRadars();

// Distância em metros entre dois pontos lat/lng (Haversine)
function _haversineM(la1, ln1, la2, ln2) {
  const R = 6371000, toRad = d => d * Math.PI / 180;
  const dLat = toRad(la2 - la1), dLng = toRad(ln2 - ln1);
  const a = Math.sin(dLat/2)**2 + Math.cos(toRad(la1))*Math.cos(toRad(la2))*Math.sin(dLng/2)**2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

// Tolerância legal brasileira: +7 km/h. Alerta dispara apenas quando excede
// isso (speed > limit + 7), ou seja, a partir de 8 km/h acima do limite —
// confirmação de multa real, já considerando que a leitura do veículo é a
// velocidade verdadeira (não o velocímetro otimista).
function _radarTolerance() { return 7; }

// Pega o radar mais próximo de (lat, lng) dentro de maxMeters.
function _findNearestRadar(lat, lng, maxMeters = 50) {
  const bx = Math.floor(lat * 100), by = Math.floor(lng * 100);
  let best = null, bestDist = Infinity;
  for (let dx = -1; dx <= 1; dx++) for (let dy = -1; dy <= 1; dy++) {
    const arr = radarBuckets.get((bx+dx) + ':' + (by+dy));
    if (!arr) continue;
    for (const r of arr) {
      const d = _haversineM(lat, lng, r.lat, r.lng);
      if (d < bestDist && d <= maxMeters) { bestDist = d; best = r; }
    }
  }
  return best ? { radar: best, distM: bestDist } : null;
}

/** Analisa samples e retorna lista de alertas. Cada alerta = sample no
 *  raio de 30m de um radar com speed > limit + tolerance. Dedupe: cada
 *  radar gera no máximo 1 alerta por viagem (pega o maior excesso). */
function analyzeTripRadars(samples) {
  if (!radarsArr.length || !samples?.length) return [];
  const byRadar = new Map();   // radar.id → melhor alerta
  for (const s of samples) {
    if (!s || (s.lat === 0 && s.lng === 0)) continue;
    const speed = +s.spd || 0;
    if (speed < 1) continue;
    const near = _findNearestRadar(s.lat, s.lng, 30);
    if (!near) continue;
    const r = near.radar;
    if (ignoredRadars.has(String(r.id))) continue;   // usuário marcou como inexistente
    const limit = +r.maxspeed || 0;
    if (limit <= 0) continue;          // radar sem velocidade tag — pula
    const tol  = _radarTolerance();
    const excess = speed - (limit + tol);
    if (excess <= 0) continue;
    const prev = byRadar.get(r.id);
    if (!prev || excess > prev.excess_kmh) {
      byRadar.set(r.id, {
        t:         s.t,
        lat:       s.lat,
        lng:       s.lng,
        speed_kmh: Math.round(speed),
        limit_kmh: limit,
        excess_kmh: Math.round(excess * 10) / 10,
        radar_id:  r.id,
        dist_m:    Math.round(near.distM),
      });
    }
  }
  return Array.from(byRadar.values()).sort((a, b) => (a.t||0) - (b.t||0));
}

async function fetchRadarsFromOSM() {
  // Overpass: timeout generoso (300s = 5min) pra coletar Brasil inteiro.
  // out:csv pra reduzir tamanho da resposta (~30% menor que JSON).
  const query = `
    [out:json][timeout:300];
    area["ISO3166-1"="BR"][admin_level=2]->.br;
    (
      node["highway"="speed_camera"](area.br);
      node["enforcement"="maxspeed"](area.br);
    );
    out body;
  `;
  console.log('→ Baixando radares do OSM (Brasil)...');
  const startMs = Date.now();
  const res = await fetch('https://overpass-api.de/api/interpreter', {
    method:  'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Accept':       'application/json',
      'User-Agent':   'ecotrip-bridge/1.0 (https://github.com/rafaelcs28/haval-ecotrip)',
    },
    body:    'data=' + encodeURIComponent(query),
  });
  if (!res.ok) throw new Error(`Overpass HTTP ${res.status}`);
  const data = await res.json();
  const nodes = (data.elements || []).filter(e => e.type === 'node' && e.lat && e.lon);
  // Normaliza pro formato interno
  const radars = nodes.map(n => ({
    id:       String(n.id),
    lat:      n.lat,
    lng:      n.lon,
    maxspeed: parseInt(n.tags?.maxspeed) || parseInt(n.tags?.['maxspeed:type']) || 0,
    direction: n.tags?.direction || n.tags?.['camera:direction'] || null,
  }));
  radarsArr = radars;
  _rebuildRadarIndex();
  fs.writeFileSync(RADARS_FILE, JSON.stringify({
    updatedAt: new Date().toISOString(),
    count: radars.length,
    radars,
  }, null, 2));
  console.log(`✓ ${radars.length} radares baixados em ${((Date.now() - startMs)/1000).toFixed(1)}s`);
  return radars.length;
}

// Refresh automático: se o arquivo tem >7 dias, agenda update em background.
(function _maybeAutoRefreshRadars() {
  try {
    const stat = fs.statSync(RADARS_FILE);
    const ageMs = Date.now() - stat.mtimeMs;
    if (ageMs > 7 * 86400000) {
      console.log(`Radares com ${Math.round(ageMs/86400000)} dias — atualizando em background`);
      setTimeout(() => fetchRadarsFromOSM().catch(e => console.error('refresh radars:', e.message)), 30_000);
    }
  } catch (_) {
    // Arquivo não existe — agenda primeiro download
    setTimeout(() => fetchRadarsFromOSM().catch(e => console.error('first radars fetch:', e.message)), 5_000);
  }
})();

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
    `~${added.toFixed(1)}L. Toque pra registrar o preço.`
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
  const ordered = [...chargesArr].sort((a, b) => (a.timestamp_ms || 0) - (b.timestamp_ms || 0));
  let avgPrice = SEED_KWH_PRICE;  // R$/kWh médio inicial = seed
  for (const c of ordered) {
    const energy = +c.energy_kwh || 0;
    if (energy < 0.05) continue;
    const ovr = c.cost_override;
    // Preço da sessão: override manual (incluindo recarga gratuita: free===true → 0),
    // ou SEED_KWH_PRICE como default
    const pricePerKwh = ovr?.free === true ? 0
                       : ovr && +ovr.perKwh > 0 ? ovr.perKwh
                       : ovr && +ovr.total  > 0 ? (ovr.total / energy)
                       : SEED_KWH_PRICE;
    // Estima kWh antes da recarga: usa soc_start se disponível
    const socStart = +c.soc_start || 0;
    const kWhBefore = socStart * BATTERY_CAPACITY_KWH / 100;
    const kWhAfter  = kWhBefore + energy;
    avgPrice = (kWhBefore * avgPrice + energy * pricePerKwh) / kWhAfter;
  }
  state.battery_avg_price_per_kwh = +avgPrice.toFixed(4);
  state.price_kwh = +avgPrice.toFixed(4);
  publishPricesToCar();
  return avgPrice;
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
      if (it.status === 'soon' && notifPrefs.maintenance_soon) {
        sendPush(`${it.icon || '🔧'} ${it.label} se aproximando`, body);
        addEvent('maint_soon', `${it.icon || '🔧'} ${it.label}: ${body}`);
      } else if (it.status === 'overdue' && notifPrefs.maintenance_overdue) {
        sendPush(`⚠️ ${it.label} atrasada`, body);
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

function captureTelemetrySnapshot() {
  const today = _todayKey();
  // Substitui o snapshot de hoje se já existe (atualiza valores mais recentes)
  const idx = telemetryHistory.findIndex(s => s.date === today);
  const snap = {
    date: today,
    ts: Date.now(),
    tyre_fl: +state.tyre_pressure_fl || 0,
    tyre_fr: +state.tyre_pressure_fr || 0,
    tyre_rl: +state.tyre_pressure_rl || 0,
    tyre_rr: +state.tyre_pressure_rr || 0,
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
    if (notifPrefs.anomaly_detected) sendPush(iss.title, iss.body);
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
function computeMaintenance() {
  const odom = +state.odometer_km || 0;
  const now  = Date.now();
  const MS_PER_DAY = 24 * 60 * 60 * 1000;
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
        if (notifPrefs.geofence_arrival) sendPush(`📍 Chegou em ${loc.name}`, `Veículo dentro da zona.`);
      }
    } else if (isOutside && prev !== 'out') {
      geofenceState[loc.id] = 'out';
      if (prev === 'in' && engineOn) {  // saída só com motor ligado
        addEvent('geofence_out', `🚗 Saiu de ${loc.name}`);
        if (notifPrefs.geofence_departure) sendPush(`🚗 Saiu de ${loc.name}`, `Veículo deixou a zona.`);
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
      req.path === '/auth/google/login') return next();
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
  res.json(filtered.map(applyChargeOverrides));
});

app.delete('/api/charges/:ts', (req, res) => {
  const ts  = parseInt(req.params.ts, 10);
  const idx = chargesArr.findIndex(c => (c.timestamp_ms || 0) === ts);
  if (idx < 0) return res.status(404).json({ error: 'not found' });
  chargesArr.splice(idx, 1);
  scheduleChargesFlush();
  markDeleted('charges', ts);
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
  const { type_id, odometer_km, date_ms, notes } = req.body || {};
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
  const { charger_kwh } = req.body || {};
  const charge = chargesArr.find(c => (c.timestamp_ms || 0) === ts);
  if (!charge) return res.status(404).json({ error: 'not found' });
  const val = parseFloat(charger_kwh) || 0;
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
app.get('/api/vehicle', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  // Re-lê o arquivo (pode ter sido alterado depois do boot)
  const onDiskFile = _loadVehicleChassiFromFile();
  res.json({
    active:        GWM_CHASSI || null,
    active_source: GWM_CHASSI_SOURCE,
    saved_in_file: onDiskFile || null,
    env_value:     _chassiFromEnv || null,
    needs_restart: !!(onDiskFile && onDiskFile !== GWM_CHASSI),
  });
});

// POST { chassi } — valida e persiste. Restart manual via /api/admin/restart.
app.post('/api/vehicle', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  const raw = (req.body?.chassi || '').toString().toLowerCase().trim();
  // GWM (Haval H6) chassi padrão: lgw + 14 alfanuméricos = 17 total
  if (!/^lgw[a-z0-9]{14}$/.test(raw)) {
    return res.status(400).json({ error: 'Formato inválido. Esperado: lgw + 14 alfanuméricos (ex: lgwffva55sh931315)' });
  }
  try {
    fs.writeFileSync(VEHICLE_FILE, JSON.stringify({ chassi: raw, updated_at: Date.now() }, null, 2));
    const needsRestart = raw !== GWM_CHASSI;
    res.json({ ok: true, chassi: raw, needs_restart: needsRestart });
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

    // Radares marcados como ignorados pelo usuário
    const radarsIgnoredList = Array.from(ignoredRadars);

    const backup = {
      version:           4,
      exportedAt:        new Date().toISOString(),
      // Histórico (trips manuais A/B descontinuados — campo legado pra compat v2)
      trips:             [],
      autotrips:         autotripsWithSamples,        // inclui radar_alerts em cada
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
      radarsIgnored:     radarsIgnoredList,           // novo v4: radares marcados como inexistentes
      // NÃO inclui: auth.json (TOTP secret), radars.json (re-baixa do OSM),
      // state.json (runtime, recomputado), cert.pem/key.pem (per-server).
    };

    const filename = `ecotrip-backup-${new Date().toISOString().slice(0, 10)}.json`;
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.json(backup);
    console.log(`✓ Backup v4 exportado: ${backup.autotrips.length} auto-trips · ${backup.charges.length} recargas (${Object.keys(chargeTelemetry).length} com telemetria) · ${backup.refuels.length} abastecimentos · ${backup.maintenance.history.length} manutenções · ${backup.knownPlaces.length} locais · ${radarsIgnoredList.length} radares ignorados`);
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
      // Preserva hybridTimeSec/hybridDistKm e radar_alerts se vieram no backup,
      // senão recalcula hybrid (radar_alerts vira [] se ausente — reanalyze
      // pode regenerar depois).
      const hybrid = (at.hybridTimeSec != null && at.hybridDistKm != null)
        ? { hybridTimeSec: at.hybridTimeSec, hybridDistKm: at.hybridDistKm }
        : _calcHybrid(at.samples || []);
      const radarAlerts = Array.isArray(at.radar_alerts) ? at.radar_alerts : [];
      fs.writeFileSync(
        path.join(AUTOTRIPS_DIR, `${safeId}.json`),
        JSON.stringify({
          tripId: safeId,
          autoTrip: at.autoTrip || {},
          samples: at.samples || [],
          hybridTimeSec: hybrid.hybridTimeSec,
          hybridDistKm:  hybrid.hybridDistKm,
          radar_alerts:  radarAlerts,
        })
      );
      if (at.autoTrip) {
        autoTripsArr.push({
          tripId: safeId, ...at.autoTrip, ...hybrid,
          radarAlertCount: radarAlerts.length,
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

    // 12. Radares ignorados (v4+) — substitui lista local
    if (Array.isArray(bk.radarsIgnored)) {
      ignoredRadars = new Set(bk.radarsIgnored.map(String));
      _saveIgnoredRadars();
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
      radarsIgnored:     ignoredRadars.size,
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

// ── Radares ───────────────────────────────────────────────────────────────────
// GET /api/radars/status — info de saúde da base
app.get('/api/radars/status', (_req, res) => {
  let updatedAt = null;
  try { updatedAt = JSON.parse(fs.readFileSync(RADARS_FILE,'utf8')).updatedAt; } catch (_) {}
  res.json({
    total: radarsArr.length,
    ignored: ignoredRadars.size,
    with_maxspeed: radarsArr.filter(r => r.maxspeed > 0).length,
    updated_at: updatedAt,
  });
});

// POST /api/radars/refresh — força redownload do OSM
app.post('/api/radars/refresh', async (_req, res) => {
  try {
    const n = await fetchRadarsFromOSM();
    res.json({ ok: true, total: n });
  } catch (e) {
    res.status(500).json({ ok: false, error: e.message });
  }
});

// GET /api/radars/ignored — lista IDs marcados como ignorados (com lat/lng)
app.get('/api/radars/ignored', (_req, res) => {
  const list = radarsArr.filter(r => ignoredRadars.has(String(r.id)));
  res.json({ count: list.length, radars: list });
});

// POST /api/radars/:id/ignore — marca um radar como ignorado
app.post('/api/radars/:id/ignore', (req, res) => {
  const id = String(req.params.id);
  ignoredRadars.add(id);
  _saveIgnoredRadars();
  res.json({ ok: true, ignored_count: ignoredRadars.size });
});

// DELETE /api/radars/:id/ignore — remove radar da lista de ignorados (volta a alertar)
app.delete('/api/radars/:id/ignore', (req, res) => {
  const id = String(req.params.id);
  const had = ignoredRadars.delete(id);
  _saveIgnoredRadars();
  res.json({ ok: true, removed: had, ignored_count: ignoredRadars.size });
});

// POST /api/radars/reanalyze — reprocessa todas as auto-trips com a base atual de
// radares (após download inicial OU mudança na lista de ignorados). Atualiza
// radar_alerts em cada arquivo + autoTripsArr em memória.
app.post('/api/radars/reanalyze', (_req, res) => {
  let processed = 0, withAlerts = 0;
  try {
    const files = fs.readdirSync(AUTOTRIPS_DIR).filter(f => f.endsWith('.json'));
    for (const f of files) {
      try {
        const fp = path.join(AUTOTRIPS_DIR, f);
        const data = JSON.parse(fs.readFileSync(fp, 'utf8'));
        const samples = data.samples || [];
        const alerts = analyzeTripRadars(samples);
        data.radar_alerts = alerts;
        fs.writeFileSync(fp, JSON.stringify(data));
        const rec = autoTripsArr.find(t => t.tripId === data.tripId);
        if (rec) rec.radarAlertCount = alerts.length;
        if (alerts.length > 0) withAlerts++;
        processed++;
      } catch (_) {}
    }
    res.json({ ok: true, processed, with_alerts: withAlerts });
  } catch (e) {
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

    // Análise de radares — detecta possíveis multas comparando samples GPS+speed
    // com a base OSM. Cada radar pode gerar no máximo 1 alerta por viagem (o de
    // maior excesso). Ignora radares marcados pelo usuário como inexistentes.
    const radarAlerts = analyzeTripRadars(finalSamples);

    // Persiste hybrid + alertas junto — boot não precisa recalcular.
    fs.writeFileSync(filePath, JSON.stringify({
      tripId: safeId, autoTrip, samples: finalSamples, hybridTimeSec, hybridDistKm,
      radar_alerts: radarAlerts,
    }));

    const record = { tripId: safeId, ...autoTrip, hybridTimeSec, hybridDistKm, radarAlertCount: radarAlerts.length };

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
    // Push: viagem concluída (só se >1 km OU >3 min)
    if (notifPrefs.trip_end) {
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
        const cost   = (state.price_gas_per_l > 0 || state.price_kwh > 0)
          ? fuelL * state.price_gas_per_l + netKwh * state.price_kwh : 0;

        const parts = [`${dist} km`, dur];
        if (netKwh > 0.01) parts.push(`${netKwh.toFixed(2)} kWh`);
        if (kwh100)        parts.push(`${kwh100} kWh/100`);
        if (fuelL > 0.01)  parts.push(`${fuelL.toFixed(2)} L`);
        if (kmL)           parts.push(`${kmL} km/L`);
        if (cost  > 0.01)  parts.push(`R$ ${cost.toFixed(2)}`);

        sendPush('🏁 Viagem concluída', parts.join(' · '));
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

app.get('/api/config', (_req, res) => res.json({
  mqtt_host:   MQTT_HOST,
  mqtt_prefix: MQTT_PREFIX,
  version:     require('./package.json').version,
}));

// ── Push Notifications ────────────────────────────────────────────────────────
app.get('/api/push/vapid-key', (_req, res) => res.json({ key: vapidKeys.publicKey }));

app.post('/api/push/subscribe', (req, res) => {
  const sub = req.body;
  if (!sub?.endpoint) return res.status(400).json({ error: 'invalid subscription' });
  const exists = pushSubs.some(s => s.endpoint === sub.endpoint);
  if (!exists) { pushSubs.push(sub); savePushSubs(); }
  res.json({ ok: true });
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
  if (typeof NOTIF_DEFAULTS[key] === 'number') {
    const n = parseInt(value);
    if (isNaN(n)) return res.status(400).json({ error: 'valor numérico inválido' });
    notifPrefs[key] = Math.max(1, Math.min(20, n));
  } else {
    notifPrefs[key] = !!value;
  }
  saveNotifPrefs();
  res.json({ ok: true, prefs: notifPrefs });
});

// GET /api/push/history  — central de notificações
app.get('/api/push/history', (_req, res) => res.json(notifHistory));

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
const HF_HEARTBEAT_TIMEOUT_MS = 10_000;
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

mqttClient.on('message', (topic, payload, packet) => {
  const value      = payload.toString().trim();
  const isRetained = !!(packet && packet.retain);

  // Dispatcher: tópicos da integração GWM Brasil vão pro handler dedicado;
  // outros caem no handler legado do app.
  if (topic.startsWith(GWM_TOPIC_PREFIX + '/') && topic.endsWith('/state')) {
    // gwmbrasil_<chassi>/<id>/state
    const id = topic.slice(GWM_TOPIC_PREFIX.length + 1, topic.length - '/state'.length);
    applyGwmEntity(id, value, isRetained);
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
          if (notifPrefs.trunk_open)  sendPush('🧳 Porta-malas aberta', 'Verifique se está segura.');
        } else {
          addEvent('trunk_close', 'Porta-malas fechada');
          if (notifPrefs.trunk_close) sendPush('🧳 Porta-malas fechada', 'Porta-malas foi fechada.');
        }
      } else {
        // door_fl/fr/rl/rr
        const side = field.slice(5);
        const label = DOOR_NAMES[side] || side.toUpperCase();
        if (norm === 'on') {
          addEvent('door_open',  `${label} aberta`);
          if (notifPrefs.door_open)  sendPush('🚪 Porta aberta', label);
        } else {
          addEvent('door_close', `${label} fechada`);
          if (notifPrefs.door_close) sendPush('🚪 Porta fechada', label);
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
        if (notifPrefs.engine_on)  sendPush('🔑 Motor ligado',  'O veículo foi ligado.');
        // Transição off→on: compara fuel atual com snapshot ao desligar
        checkRefuelOnEngineOn();
      } else if (value === '0') {
        addEvent('engine_off', 'Motor desligado');
        if (notifPrefs.engine_off) sendPush('🔑 Motor desligado', 'O veículo foi desligado.');
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

  // ── Charging state — converte número do HA pro texto que a PWA usa ────────
  if (field === 'charging_state_raw') {
    state.charging_state = mapChargingStateText(value);
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
      if (!isRetained && prevVer !== null && prevVer !== value && notifPrefs.app_update) {
        sendPush('📱 App atualizado', `Nova versão: ${value}${prevVer ? ` (era ${prevVer})` : ''}`);
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
          if (notifPrefs.engine_on)  sendPush('🔑 Motor ligado',  'O veículo foi ligado.');
        } else if (value === '0') {
          addEvent('engine_off', 'Motor desligado');
          if (notifPrefs.engine_off) sendPush('🔑 Motor desligado', 'O veículo foi desligado.');
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
            if (notifPrefs.door_open)  sendPush('🚪 Porta aberta', label);
          } else {
            addEvent('door_close', `${label} fechada`);
            if (notifPrefs.door_close) sendPush('🚪 Porta fechada', label);
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
            if (notifPrefs.trunk_open)  sendPush('🧳 Porta-malas aberta', 'Verifique se está segura.');
          } else {
            addEvent('trunk_close', 'Porta-malas fechada');
            if (notifPrefs.trunk_close) sendPush('🧳 Porta-malas fechada', 'Porta-malas foi fechada.');
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
    case 'tyre_pressure_fl': { state.tyre_pressure_fl = num(value); checkTyrePressure('FL', num(value), isRetained); break; }
    case 'tyre_pressure_fr': { state.tyre_pressure_fr = num(value); checkTyrePressure('FR', num(value), isRetained); break; }
    case 'tyre_pressure_rl': { state.tyre_pressure_rl = num(value); checkTyrePressure('RL', num(value), isRetained); break; }
    case 'tyre_pressure_rr': { state.tyre_pressure_rr = num(value); checkTyrePressure('RR', num(value), isRetained); break; }
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
      const prev = prevChargingState;
      state.charging_state = value;
      prevChargingState    = value;

      // Detecta transição REAL: prev definido e diferente do novo valor.
      // No primeiro boot do bridge, prev é vazio → pula (não há transição).
      // Em qualquer outra mudança (retained ou não), registra evento no log;
      // só o push de notificação é gateado por !isRetained (pra não notificar
      // o user no boot quando o broker reenvia 'Carregando' antigo).
      const realTransition = prev && prev !== value;
      if (realTransition) {
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
              if (notifPrefs.charge_start)
              sendPush('⚡ Recarga iniciada', `${pwr.toFixed(1)} kW · tempo restante: ${remStr}`);
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
          if (!isRetained && value === 'Finalizado' && notifPrefs.charge_end) {
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
            sendPush('✅ Recarga concluída', parts.length ? parts.join(' · ') : 'Sessão encerrada');
            chargeSessionStartMs = 0;
            state.charge_session_start_ms    = 0;
            state.charge_session_kwh_at_init = 0;
          }
        }
      }
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
      if (
        notifPrefs.charge_ending &&
        rem > 0 &&
        rem <= (notifPrefs.charge_ending_min || 5) &&
        !chargeEndingNotifSent &&
        state.charging_state === 'Carregando'
      ) {
        chargeEndingNotifSent = true;
        sendPush('🔔 Recarga finalizando', `Recarga finalizando em ${rem} minuto${rem !== 1 ? 's' : ''}.`);
      }
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
            // manual_overrides: edições feitas no PWA pra corrigir leituras erradas do carro
            // (SOC início/fim, energia injetada, duração). Têm prioridade sobre o que o
            // Android re-publicar — caso contrário, a edição sumiria no próximo reconnect.
            if (existing.manual_overrides != null) keep.manual_overrides = existing.manual_overrides;
            // Preserva _updated_ms para que dispositivos que ainda não sincronizaram
            // continuem a detectar as edições feitas via PATCH após o merge MQTT.
            if (existing._updated_ms      != null) keep._updated_ms      = existing._updated_ms;
            return { ...newCharge, ...keep };
          });
          scheduleChargesFlush();
          const skipped = all.length - charges.length;
          console.log(`✓ Recargas MQTT: ${charges.length} sessão(ões)${skipped > 0 ? ` (${skipped} anteriores ao clear ignoradas)` : ''}`);
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
