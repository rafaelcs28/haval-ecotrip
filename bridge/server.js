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

// ── Token de acesso (hash SHA-256 da senha) ────────────────────────────────────
// Suporta migração: BRIDGE_TOKEN (plain) → calcula hash automaticamente
// Em produção usa BRIDGE_TOKEN_HASH diretamente (gerado pelo endpoint change-password)
function sha256hex(str) {
  return require('crypto').createHash('sha256').update(str).digest('hex');
}
const _plainToken   = process.env.BRIDGE_TOKEN      || '';
let BRIDGE_TOKEN_HASH = process.env.BRIDGE_TOKEN_HASH
  || (_plainToken ? sha256hex(_plainToken) : '');

const TRIPS_FILE      = path.join(__dirname, 'trips.json');
const CHARGES_FILE    = path.join(__dirname, 'charges.json');
const STATE_FILE      = path.join(__dirname, 'state.json');
const AUTOTRIPS_DIR   = path.join(__dirname, 'autotrips');
const SNAPSHOTS_FILE  = path.join(__dirname, 'lifetime_snapshots.json');
const VAPID_FILE        = path.join(__dirname, 'vapid_keys.json');
const PUSH_SUBS_FILE    = path.join(__dirname, 'push_subscriptions.json');
const RENAMES_FILE      = path.join(__dirname, 'pending_renames.json');
const CHARGE_LOCS_FILE    = path.join(__dirname, 'charge_locations.json');
const KNOWN_PLACES_FILE   = path.join(__dirname, 'known_places.json');
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
// Hysteresis: car emite valores oscilantes (ex.: sunroof posição) pro mesmo estado
// físico. Sem debounce, o log enche de eventos abertos/fechados a cada flip do sensor.
// Espera N ms de valor estável antes de atualizar state + disparar evento.
const HYSTERESIS_MS = 3000;
const _hystPending = { sunroof: null, window_fl: null, window_fr: null, window_rl: null, window_rr: null };
const _hystTimers  = { sunroof: null, window_fl: null, window_fr: null, window_rl: null, window_rr: null };

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
        const hybrid = _calcHybrid(d.samples || []);
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

function addEvent(type, label) {
  const ev = { id: Date.now(), ts: Date.now(), type, label };
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
  batt_12v_pct:        0,    // % bateria auxiliar 12V
  charging_state:      'Desconhecido',
  charge_power_kw:     0,
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

  trip_a: {
    distance_km:   0, time_sec: '--', kwh_per_100km: 0, km_per_l: 0,
    avg_speed_kmh: 0, fuel_l: 0, energy_kwh: 0, regen_kwh: 0,
    soc_start:     0, soc_current: 0, tank_start_l: 0, tank_now_l: 0,
    cost_brl:      0, cost_per_km: 0,
  },
  trip_b: {
    distance_km:   0, time_sec: '--', kwh_per_100km: 0, km_per_l: 0,
    avg_speed_kmh: 0, fuel_l: 0, energy_kwh: 0, regen_kwh: 0,
    soc_start:     0, soc_current: 0, tank_start_l: 0, tank_now_l: 0,
    cost_brl:      0, cost_per_km: 0,
  },
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
    console.log(`✓ Estado anterior restaurado de state.json`);
  } catch (e) {
    console.error('Aviso: erro ao restaurar state.json:', e.message);
  }
}

let stateSaveTimer = null;
function scheduleStateSave() {
  if (stateSaveTimer) clearTimeout(stateSaveTimer);
  stateSaveTimer = setTimeout(() => {
    try { fs.writeFileSync(STATE_FILE, JSON.stringify(state, null, 2)); } catch (_) {}
  }, 2000); // debounce de 2s — não grava a cada mensagem MQTT individual
}

// ── Histórico de trips — persistência JSON ────────────────────────────────────
// O histórico vem do tópico MQTT retained `trips/history` (JSON completo).
// Guardamos em trips.json para não perder entre reinicios do bridge.

/** @type {Map<string, object>}  timestamp → trip object */
const tripsMap = new Map();

// Carrega do disco na inicialização
if (fs.existsSync(TRIPS_FILE)) {
  try {
    const saved = JSON.parse(fs.readFileSync(TRIPS_FILE, 'utf8'));
    for (const t of (saved.trips || [])) {
      if (t.timestamp) tripsMap.set(t.timestamp, t);
    }
    console.log(`✓ Histórico local: ${tripsMap.size} trips`);
  } catch (e) {
    console.error('Aviso: não foi possível ler trips.json:', e.message);
  }
}

let saveTimer = null;
function scheduleTripsFlush() {
  if (saveTimer) clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    const trips = [...tripsMap.values()].sort((a, b) =>
      (b.timestamp || '').localeCompare(a.timestamp || ''));
    fs.writeFileSync(TRIPS_FILE, JSON.stringify({ trips }, null, 2));
  }, 500);
}

function upsertTrips(trips) {
  for (const t of trips) {
    if (t.timestamp) tripsMap.set(t.timestamp, t);
  }
  scheduleTripsFlush();
}

function getTrips(limit = 200) {
  const all = [...tripsMap.values()].sort((a, b) =>
    (b.timestamp || '').localeCompare(a.timestamp || ''));
  return all.slice(0, limit);
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
// requireAuth: aplica a toda a API exceto /api/push/* (SW não consegue enviar headers)
app.use('/api', (req, res, next) => {
  if (req.path.startsWith('/push')) return next();  // push routes: sem auth
  requireAuth(req, res, next);
});

app.get('/api/state',  (_req, res) => res.json(state));
app.get('/api/counts', (_req, res) => res.json({
  trips:    tripsMap.size,
  autotrips: autoTripsArr.length,
  charges:  chargesArr.length,
}));
app.get('/api/trips', (req, res) => {
  const since = req.query.since || '';
  const all   = getTrips(500);
  res.json(since ? all.filter(t => (t.timestamp || '') > since) : all);
});
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
  console.log(`[delete] Charge ${ts} removida`);
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

    // cost_override: soma totais se ambas têm; caso contrário usa o que existir
    let mergedCostOverride = null;
    if (early.cost_override?.total > 0 && late.cost_override?.total > 0) {
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
  const { total, per_kwh } = req.body || {};
  const charge = chargesArr.find(c => (c.timestamp_ms || 0) === ts);
  if (!charge) return res.status(404).json({ error: 'not found' });
  const t = parseFloat(total) || 0;
  if (t > 0) charge.cost_override = { total: t, perKwh: parseFloat(per_kwh) || 0 };
  else        delete charge.cost_override;
  charge._updated_ms = Date.now();
  scheduleChargesFlush();
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

    const backup = {
      version:       2,
      exportedAt:    new Date().toISOString(),
      trips:         [...tripsMap.values()],
      autotrips:     autotripsWithSamples,
      charges:       chargesArr,
      lifeSnapshots,
      notifPrefs,
    };

    const filename = `ecotrip-backup-${new Date().toISOString().slice(0, 10)}.json`;
    res.setHeader('Content-Disposition', `attachment; filename="${filename}"`);
    res.setHeader('Content-Type', 'application/json; charset=utf-8');
    res.json(backup);
    console.log(`✓ Backup exportado: ${backup.trips.length} trips · ${backup.autotrips.length} auto-trips · ${backup.charges.length} recargas`);
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

    // Validação básica
    if (!bk || bk.version !== 2) {
      return res.status(400).json({ error: 'Formato inválido. Use um backup gerado por GET /api/backup (version 2).' });
    }
    if (!Array.isArray(bk.trips) || !Array.isArray(bk.autotrips) || !Array.isArray(bk.charges)) {
      return res.status(400).json({ error: 'Backup incompleto: trips, autotrips e charges são obrigatórios.' });
    }

    // 1. Trips manuais
    tripsMap.clear();
    bk.trips.forEach(t => { if (t.timestamp) tripsMap.set(t.timestamp, t); });
    fs.writeFileSync(TRIPS_FILE, JSON.stringify({ trips: [...tripsMap.values()] }, null, 2));

    // 2. Auto-trips (com telemetria completa)
    const existingFiles = fs.readdirSync(AUTOTRIPS_DIR).filter(f => f.endsWith('.json'));
    existingFiles.forEach(f => { try { fs.unlinkSync(path.join(AUTOTRIPS_DIR, f)); } catch (_) {} });
    autoTripsArr.length = 0;

    for (const at of bk.autotrips) {
      const safeId = String(at.tripId || at.autoTrip?.startMs || '').replace(/\D/g, '');
      if (!safeId) continue;
      fs.writeFileSync(
        path.join(AUTOTRIPS_DIR, `${safeId}.json`),
        JSON.stringify({ tripId: safeId, autoTrip: at.autoTrip || {}, samples: at.samples || [] })
      );
      if (at.autoTrip) {
        const hybrid = _calcHybrid(at.samples || []);
        autoTripsArr.push({ tripId: safeId, ...at.autoTrip, ...hybrid });
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

    const summary = {
      trips:         tripsMap.size,
      autotrips:     autoTripsArr.length,
      charges:       chargesArr.length,
      lifeSnapshots: lifeSnapshots.length,
    };
    console.log('✓ Restore completo:', summary);
    res.json({ ok: true, msg: 'Restore concluído com sucesso.', ...summary });
  } catch (e) {
    console.error('[restore] Erro:', e.message);
    res.status(500).json({ error: e.message });
  }
});

app.post('/api/admin/clear-history', (req, res) => {
  if (!adminCheckToken(req, res)) return;
  try {
    // 1. Trips manuais
    tripsMap.clear();
    fs.writeFileSync(TRIPS_FILE, JSON.stringify({ trips: [] }, null, 2));

    // 2. Recargas
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

    // Descarta viagens irrelevantes: energia E distância zeradas com menos de 1 min
    const _distKm  = autoTrip.distKm  || 0;
    const _netKwh  = autoTrip.netKwh  || 0;
    const _timeSec = autoTrip.timeSec || 0;
    if (_distKm <= 0 && _netKwh < 0.10 && _timeSec < 60) {
      console.log(`↷ AutoTrip ${safeId} ignorado (dist=0 energy=0 time=${_timeSec}s)`);
      return res.json({ ok: true, skipped: true });
    }

    const filePath = path.join(AUTOTRIPS_DIR, `${safeId}.json`);

    // Se a viagem já existe com samples e o novo POST tem samples vazio (sync sem telemetria),
    // preserva os samples existentes para não apagar dados GPS de viagens anteriores.
    let finalSamples = samples || [];
    if (finalSamples.length === 0 && fs.existsSync(filePath)) {
      try {
        const existing = JSON.parse(fs.readFileSync(filePath, 'utf8'));
        if (existing.samples && existing.samples.length > 0) finalSamples = existing.samples;
      } catch (_) {}
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

    fs.writeFileSync(filePath, JSON.stringify({ tripId: safeId, autoTrip, samples: finalSamples }));

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
  // Aceita tanto tripId (string safeId) quanto startMs (número equivalente)
  const idx = autoTripsArr.findIndex(t => t.tripId === id || String(t.startMs) === id);
  console.log(`[delete] AutoTrip lookup id=${id} idx=${idx} total=${autoTripsArr.length}`);
  if (idx < 0) return res.status(404).json({ error: 'not found', id });
  autoTripsArr.splice(idx, 1);
  const filePath = path.join(AUTOTRIPS_DIR, `${id}.json`);
  try { fs.unlinkSync(filePath); } catch (_) {}
  console.log(`[delete] AutoTrip ${id} removido`);
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

    // Salva arquivo unificado (ID da viagem mais antiga)
    fs.writeFileSync(
      path.join(AUTOTRIPS_DIR, `${earlyId}.json`),
      JSON.stringify({ tripId: earlyId, autoTrip: merged, samples: mergedSamples })
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

app.delete('/api/trips/:tripId', (req, res) => {
  const id = decodeURIComponent(req.params.tripId);
  console.log(`[delete] Trip lookup id="${id}" found=${tripsMap.has(id)}`);
  if (!tripsMap.has(id)) return res.status(404).json({ error: 'not found', id });
  tripsMap.delete(id);
  fs.writeFileSync(TRIPS_FILE, JSON.stringify({ trips: [...tripsMap.values()] }, null, 2));
  console.log(`[delete] Trip manual ${id} removido`);
  res.json({ ok: true });
});

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
  } else if (type === 'manual') {
    // Manual trip: key = timestamp string
    const t = tripsMap.get(String(tripId));
    if (t) { t.name = trimmed; scheduleTripsFlush(); }
  }
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
  try {
    const files = fs.readdirSync(AUTOTRIPS_DIR)
      .filter(f => f.endsWith('.json'))
      .sort()
      .reverse();
    for (const f of files) {
      const d = JSON.parse(fs.readFileSync(path.join(AUTOTRIPS_DIR, f), 'utf8'));
      const samples = d.samples || [];
      const lastGps = [...samples].reverse().find(s => s.lat !== 0 || s.lng !== 0);
      if (lastGps) {
        return res.json({
          lat: lastGps.lat,
          lng: lastGps.lng,
          tripId: d.tripId,
          ts: d.autoTrip?.endMs || null,
        });
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
const ALLOWED_ACTIONS = new Set([
  'engine_on',  'engine_off',
  'lock_open',  'lock_close',
  'windows_open', 'windows_close',
  'trunk_open', 'trunk_close',
  'sunroof_open', 'sunroof_close',
  'ac_on',
  'charge_stop',
  'charge_history',
]);

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

app.post('/api/action/:name', (req, res) => {
  const { name } = req.params;
  if (!ALLOWED_ACTIONS.has(name)) return res.status(400).json({ error: 'ação desconhecida' });
  if (!mqttClient?.connected)     return res.status(503).json({ error: 'MQTT offline' });
  mqttClient.publish(`${MQTT_PREFIX}/remote/${name}`, '1', { retain: false, qos: 1 }, err => {
    if (err) return res.status(500).json({ error: 'falha ao publicar' });
    res.json({ ok: true });
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

// ── MQTT ──────────────────────────────────────────────────────────────────────

const mqttOptions = {
  port:           MQTT_PORT,
  clientId:       `ecotrip-bridge-${Date.now()}`,
  clean:          true,
  reconnectPeriod: 5000,
};
if (MQTT_USER) { mqttOptions.username = MQTT_USER; mqttOptions.password = MQTT_PASS; }

const mqttClient = mqtt.connect(MQTT_HOST, mqttOptions);

mqttClient.on('connect', () => {
  console.log(`✓ MQTT conectado: ${MQTT_HOST} (prefix: ${MQTT_PREFIX})`);
  mqttClient.subscribe(`${MQTT_PREFIX}/#`, { qos: 1 });
});

mqttClient.on('error',      (err) => console.error('MQTT erro:', err.message));
mqttClient.on('reconnect',  ()    => console.log('MQTT reconectando...'));
mqttClient.on('disconnect', ()    => console.log('MQTT desconectado'));

mqttClient.on('message', (topic, payload, packet) => {
  const value      = payload.toString().trim();
  const isRetained = !!(packet && packet.retain);
  const key        = topic.startsWith(MQTT_PREFIX + '/')
    ? topic.slice(MQTT_PREFIX.length + 1)
    : topic;

  applyMqttMessage(key, value, isRetained);
  broadcast('update', state);
});

// ── Roteamento dos tópicos MQTT → state ──────────────────────────────────────

function num(v) { const n = parseFloat(v); return isNaN(n) ? 0 : n; }

function applyMqttMessage(key, value, isRetained = false) {
  state.last_update_ms = Date.now();

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
      // App publica "1" (destrancado) / "0" (trancado) — normalizado a partir
      // do cru car.basic.door_lock_status (3=destrancado, 1=trancado).
      const norm = value === '1' ? 'on' : 'off';
      const prevL = prevLockState;
      state.lock_state = norm;
      prevLockState = norm;
      console.log(`[lock] mqtt='${value}' isRetained=${isRetained} → state.lock_state='${norm}' (prev='${prevL}')`);
      if (!isRetained && prevL !== null && prevL !== norm) {
        if (norm === 'on')  addEvent('lock_open',  'Carro destrancado');
        else                addEvent('lock_close', 'Carro trancado');
      }
      break;
    }
    case 'high_beam':    state.high_beam    = value; break;   // 'on' | 'off'
    case 'light_state':  state.light_state  = value; break;   // 'on' | 'off' (farol)
    case 'ac_state': {
      // App publica '1' (ligado) / '0' (desligado). Normaliza pra 'on'/'off'.
      const norm = value === '1' ? 'on' : 'off';
      const prevAc = state.ac_state;
      state.ac_state = norm;
      if (!isRetained && prevAc !== null && prevAc !== norm) {
        if (norm === 'on') addEvent('ac_on',  'Ar condicionado ligado');
        else               addEvent('ac_off', 'Ar condicionado desligado');
      }
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
    case 'door_fl':
    case 'door_fr':
    case 'door_rl':
    case 'door_rr': {
      // App publica '1' (aberta) / '0' (fechada). Normaliza pra 'on'/'off' que o PWA espera.
      const side  = key.slice(5);           // 'fl' | 'fr' | 'rl' | 'rr'
      const norm  = value === '1' ? 'on' : 'off';
      const prevD = prevDoorStates[side];
      state[key]           = norm;
      prevDoorStates[side] = norm;
      if (!isRetained && prevD !== null && prevD !== norm) {
        const label = DOOR_NAMES[side] || side.toUpperCase();
        if (norm === 'on') {
          addEvent('door_open',  `${label} aberta`);
          if (notifPrefs.door_open)  sendPush('🚪 Porta aberta', label);
        } else {
          addEvent('door_close', `${label} fechada`);
          if (notifPrefs.door_close) sendPush('🚪 Porta fechada', label);
        }
      }
      break;
    }
    case 'door_trunk': {
      const norm = value === '1' ? 'on' : 'off';
      const prevT = prevDoorStates.trunk;
      state.door_trunk     = norm;
      prevDoorStates.trunk = norm;
      if (!isRetained && prevT !== null && prevT !== norm) {
        if (norm === 'on') {
          addEvent('trunk_open',  'Porta-malas aberta');
          if (notifPrefs.trunk_open)  sendPush('🧳 Porta-malas aberta', 'Verifique se está segura.');
        } else {
          addEvent('trunk_close', 'Porta-malas fechada');
          if (notifPrefs.trunk_close) sendPush('🧳 Porta-malas fechada', 'Porta-malas foi fechada.');
        }
      }
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
      // App publica '1' (aberto) / '0' (fechado) já normalizado a partir de car.basic.window_status.
      // Mesmo padrão de hysteresis 3s — sensor oscila no estado fechado.
      const wside = key.slice(7);
      const norm  = value === '1' ? 'on' : 'off';
      if (isRetained) {
        state[key]              = norm;
        prevWindowStates[wside] = norm;
        break;
      }
      if (norm === _hystPending[key]) break;
      _hystPending[key] = norm;
      clearTimeout(_hystTimers[key]);
      _hystTimers[key] = setTimeout(() => {
        state[key] = norm;
        if (norm !== prevWindowStates[wside]) {
          prevWindowStates[wside] = norm;
          const label = WINDOW_NAMES[wside] || wside.toUpperCase();
          if (norm === 'on') addEvent('window_open',  `${label} aberto`);
          else               addEvent('window_close', `${label} fechado`);
        }
      }, HYSTERESIS_MS);
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
      if (lat && lat !== 0) { state.gps_lat = lat; state.gps_ts = Date.now(); }
      break;
    }
    case 'gps_lng': {
      const lng = parseFloat(value);
      if (lng && lng !== 0) { state.gps_lng = lng; state.gps_ts = Date.now(); }
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

      // Mensagens retained chegam ao reconectar ao broker e refletem o estado
      // anterior — não representam uma transição real, então NÃO disparam push.
      // Sem esse filtro, a mensagem retained 'Carregando' de uma sessão anterior
      // envenena prevChargingState e impede a notificação na próxima recarga real.
      if (!isRetained) {
        if (value === 'Carregando' && prev !== 'Carregando') {
          _chargeTempSamples = [];   // inicia nova coleta de temperatura
          chargeSessionStartMs = Date.now();
          chargeStartSoc = state.soc_pct || 0;
          addEvent('charge_start', `Recarga iniciada · SOC: ${chargeStartSoc.toFixed(0)}%`);
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

        } else if (value !== 'Carregando' && prev === 'Carregando') {
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
          if (value === 'Finalizado' && notifPrefs.charge_end) {
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
          }
        }
      }
      break;
    }
    case 'charge_power_kw':      state.charge_power_kw      = num(value); break;
    case 'charge_session_kwh':   state.charge_session_kwh   = num(value); break;
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
    case 'price_gas_per_l':      state.price_gas_per_l      = num(value); break;
    case 'price_kwh':            state.price_kwh            = num(value); break;
    case 'charge_current_a':     state.charge_current_a     = num(value); break;
    case 'battery_voltage_v': state.battery_voltage_v  = num(value); break;
    case 'battery_current_a': state.battery_current_a  = num(value); break;
    case 'motor_power_kw':    state.motor_power_kw      = num(value); break;
    case 'odometer_km':       state.odometer_km         = num(value); break;
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

    // SOC (publicado com retain em trip_a/soc_current pelo Android)
    case 'trip_a/soc_current':
      state.trip_a.soc_current = num(value);
      if (!haSocActive) state.soc_pct = num(value);   // fallback enquanto HA não configurado
      break;

    // Trip A
    case 'trip_a/distance_km':   state.trip_a.distance_km   = num(value); break;
    case 'trip_a/time_sec':      state.trip_a.time_sec       = value; break;
    case 'trip_a/kwh_per_100km': state.trip_a.kwh_per_100km  = num(value); break;
    case 'trip_a/km_per_l':      state.trip_a.km_per_l       = num(value); break;
    case 'trip_a/avg_speed_kmh': state.trip_a.avg_speed_kmh  = num(value); break;
    case 'trip_a/fuel_l':        state.trip_a.fuel_l         = num(value); break;
    case 'trip_a/energy_kwh':    state.trip_a.energy_kwh     = num(value); break;
    case 'trip_a/regen_kwh':     state.trip_a.regen_kwh      = num(value); break;
    case 'trip_a/soc_start':     state.trip_a.soc_start      = num(value); break;
    case 'trip_a/tank_start_l':  state.trip_a.tank_start_l   = num(value); break;
    case 'trip_a/tank_now_l':    state.trip_a.tank_now_l     = num(value); break;
    case 'trip_a/cost_brl':      state.trip_a.cost_brl       = num(value); break;
    case 'trip_a/cost_per_km':   state.trip_a.cost_per_km    = num(value); break;

    // Trip B
    case 'trip_b/soc_current':
      state.trip_b.soc_current = num(value);
      if (!haSocActive) state.soc_pct = num(value);   // fallback enquanto HA não configurado
      break;
    case 'trip_b/distance_km':   state.trip_b.distance_km   = num(value); break;
    case 'trip_b/time_sec':      state.trip_b.time_sec       = value; break;
    case 'trip_b/kwh_per_100km': state.trip_b.kwh_per_100km  = num(value); break;
    case 'trip_b/km_per_l':      state.trip_b.km_per_l       = num(value); break;
    case 'trip_b/avg_speed_kmh': state.trip_b.avg_speed_kmh  = num(value); break;
    case 'trip_b/fuel_l':        state.trip_b.fuel_l         = num(value); break;
    case 'trip_b/energy_kwh':    state.trip_b.energy_kwh     = num(value); break;
    case 'trip_b/regen_kwh':     state.trip_b.regen_kwh      = num(value); break;
    case 'trip_b/soc_start':     state.trip_b.soc_start      = num(value); break;
    case 'trip_b/tank_start_l':  state.trip_b.tank_start_l   = num(value); break;
    case 'trip_b/tank_now_l':    state.trip_b.tank_now_l     = num(value); break;
    case 'trip_b/cost_brl':      state.trip_b.cost_brl       = num(value); break;
    case 'trip_b/cost_per_km':   state.trip_b.cost_per_km    = num(value); break;

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
        // Filtra entradas anteriores ao último "Limpar histórico" para impedir
        // que o Android restaure dados apagados ao reconectar via MQTT retained.
        const cutMs  = state.charges_cleared_at || 0;
        const charges = cutMs > 0 ? all.filter(c => (c.timestamp_ms || 0) > cutMs) : all;
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

    // Histórico de trips (tópico retained com JSON completo)
    case 'trips/history': {
      try {
        const parsed = JSON.parse(value);
        const all    = parsed.trips || [];
        // Filtra trips anteriores ao último "Limpar histórico"
        const cutMs  = state.trips_cleared_at || 0;
        const trips  = cutMs > 0
          ? all.filter(t => { try { return new Date(t.timestamp).getTime() > cutMs; } catch { return false; } })
          : all;
        if (trips.length > 0) {
          upsertTrips(trips);
          const skipped = all.length - trips.length;
          console.log(`✓ Histórico MQTT: ${trips.length} trips (total local: ${tripsMap.size})${skipped > 0 ? ` (${skipped} anteriores ao clear ignoradas)` : ''}`);
        }
      } catch (e) {
        console.error('Erro ao parsear trips/history:', e.message);
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
