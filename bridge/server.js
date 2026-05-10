'use strict';

require('dotenv').config();
const express  = require('express');
const { WebSocketServer, WebSocket } = require('ws');
const mqtt     = require('mqtt');
const fs       = require('fs');
const path     = require('path');
const http     = require('http');

// ── Configuração ──────────────────────────────────────────────────────────────

const MQTT_HOST   = process.env.MQTT_HOST   || 'mqtt://localhost';
const MQTT_PORT   = parseInt(process.env.MQTT_PORT || '1883', 10);
const MQTT_USER   = process.env.MQTT_USER   || '';
const MQTT_PASS   = process.env.MQTT_PASS   || '';
const MQTT_PREFIX = process.env.MQTT_PREFIX || 'haval/ecotrip';
const PORT        = parseInt(process.env.PORT || '3000', 10);

const TRIPS_FILE   = path.join(__dirname, 'trips.json');
const CHARGES_FILE = path.join(__dirname, 'charges.json');
const STATE_FILE   = path.join(__dirname, 'state.json');

// ── Estado em memória (espelha todos os tópicos MQTT) ─────────────────────────
// Valores iniciais = defaults. Serão sobrescritos pelo state.json persistido
// e depois pelos tópicos MQTT retained (ao conectar) e live (quando carro liga).

const state = {
  car_online:        false,
  bridge_online:     true,
  last_update_ms:    null,
  car_last_update:   null,
  car_app_version:   null,

  speed_kmh:        0,
  gear:             '--',
  inside_temp:      0,
  outside_temp:     0,
  charging_state:   'Desconhecido',
  charge_power_kw:  0,
  charge_current_a: 0,
  battery_voltage_v:0,
  battery_current_a:0,
  soc_pct:          0,

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
    kwh_per_100km: 0, km_per_l: 0, distance_km: 0, fuel_l: 0,
  },
  lifetime: {
    energy_kwh: 0, regen_kwh: 0, net_kwh: 0, distance_km: 0,
    time_sec: '--', fuel_l: 0, charge_kwh: 0, charge_sec: '--', cost_brl: 0,
  },
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

// ── Express + HTTP ────────────────────────────────────────────────────────────

const app    = express();
const server = http.createServer(app);

app.use(express.static(path.join(__dirname, 'public')));

app.get('/api/state',  (_req, res) => res.json(state));
app.get('/api/trips',   (_req, res) => res.json(getTrips()));
app.get('/api/charges', (_req, res) => res.json(chargesArr));
app.get('/api/config', (_req, res) => res.json({
  mqtt_host:   MQTT_HOST,
  mqtt_prefix: MQTT_PREFIX,
  version:     require('./package.json').version,
}));

// ── WebSocket ─────────────────────────────────────────────────────────────────

const wss     = new WebSocketServer({ server, path: '/ws' });
const clients = new Set();

wss.on('connection', (ws) => {
  clients.add(ws);
  ws.send(JSON.stringify({ type: 'full_state', data: state }));
  ws.on('close', () => clients.delete(ws));
  ws.on('error', () => clients.delete(ws));
});

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

mqttClient.on('message', (topic, payload) => {
  const value = payload.toString().trim();
  const key   = topic.startsWith(MQTT_PREFIX + '/')
    ? topic.slice(MQTT_PREFIX.length + 1)
    : topic;

  applyMqttMessage(key, value);
  broadcast('update', { state });
});

// ── Roteamento dos tópicos MQTT → state ──────────────────────────────────────

function num(v) { const n = parseFloat(v); return isNaN(n) ? 0 : n; }

function applyMqttMessage(key, value) {
  state.last_update_ms = Date.now();

  switch (key) {
    // Status
    case 'status':
      state.car_online = (value === 'online');
      break;
    case 'last_update':
      state.car_last_update = value;   // ISO timestamp publicado pelo Android (retain=true)
      break;
    case 'app_version':
      state.car_app_version = value;   // versão do APK no carro (retain=true)
      break;

    // Telemetria ao vivo
    case 'speed_kmh':         state.speed_kmh          = num(value); break;
    case 'gear':              state.gear               = value || '--'; break;
    case 'inside_temp':       state.inside_temp        = num(value); break;
    case 'outside_temp':      state.outside_temp       = num(value); break;
    case 'charging_state':    state.charging_state     = value; break;
    case 'charge_power_kw':   state.charge_power_kw    = num(value); break;
    case 'charge_current_a':  state.charge_current_a   = num(value); break;
    case 'battery_voltage_v': state.battery_voltage_v  = num(value); break;
    case 'battery_current_a': state.battery_current_a  = num(value); break;

    // SOC (publicado com retain em trip_a/soc_current)
    case 'trip_a/soc_current':
      state.soc_pct           = num(value);
      state.trip_a.soc_current = num(value);
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
      state.soc_pct            = num(value);
      state.trip_b.soc_current  = num(value);
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

    // Lifetime
    case 'lifetime/energy_kwh':  state.lifetime.energy_kwh  = num(value); break;
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
        const charges = parsed.charges || [];
        if (charges.length > 0) {
          chargesArr = charges;          // substitui inteiro (fonte de verdade = Android)
          scheduleChargesFlush();
          console.log(`✓ Recargas MQTT: ${charges.length} sessão(ões)`);
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
        const trips  = parsed.trips || [];
        if (trips.length > 0) {
          upsertTrips(trips);
          console.log(`✓ Histórico MQTT: ${trips.length} trips (total local: ${tripsMap.size})`);
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
  console.log(`\n🚗  EcoTrip Bridge v${require('./package.json').version}`);
  console.log(`    PWA:       http://localhost:${PORT}`);
  console.log(`    WebSocket: ws://localhost:${PORT}/ws`);
  console.log(`    MQTT:      ${MQTT_HOST} (prefix: ${MQTT_PREFIX})\n`);
});

process.on('SIGINT',  () => { mqttClient.end(); process.exit(0); });
process.on('SIGTERM', () => { mqttClient.end(); process.exit(0); });
