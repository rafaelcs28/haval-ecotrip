'use strict';

require('dotenv').config({ path: require('path').join(__dirname, '.env') });
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

const TRIPS_FILE      = path.join(__dirname, 'trips.json');
const CHARGES_FILE    = path.join(__dirname, 'charges.json');
const STATE_FILE      = path.join(__dirname, 'state.json');
const AUTOTRIPS_DIR   = path.join(__dirname, 'autotrips');
const SNAPSHOTS_FILE  = path.join(__dirname, 'lifetime_snapshots.json');

if (!fs.existsSync(AUTOTRIPS_DIR)) fs.mkdirSync(AUTOTRIPS_DIR, { recursive: true });

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
let autoTripsArr = [];
try {
  const files = fs.readdirSync(AUTOTRIPS_DIR).filter(f => f.endsWith('.json'));
  for (const f of files) {
    try {
      const d = JSON.parse(fs.readFileSync(path.join(AUTOTRIPS_DIR, f), 'utf8'));
      if (d.autoTrip) autoTripsArr.push({ tripId: d.tripId, ...d.autoTrip });
    } catch (_) {}
  }
  autoTripsArr.sort((a, b) => (b.startMs || 0) - (a.startMs || 0));
  console.log(`✓ Auto-trips carregados: ${autoTripsArr.length}`);
} catch (e) { console.error('Aviso: erro ao carregar auto-trips:', e.message); }

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
  charging_state:      'Desconhecido',
  charge_power_kw:     0,
  charge_session_kwh:  0,
  charge_remaining_min:0,
  charge_current_a:    0,
  battery_voltage_v:0,
  battery_current_a:0,
  soc_pct:          0,
  engine_state:     null,   // null=desconhecido | '0'=desligado | '1'=ligado
  lock_state:       null,   // null=desconhecido | 'off'=trancado | 'on'=destrancado

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

app.use(express.json({ limit: '10mb' }));
app.use(express.static(path.join(__dirname, 'public')));

app.get('/api/state',  (_req, res) => res.json(state));
app.get('/api/trips',   (_req, res) => res.json(getTrips()));
app.get('/api/charges', (_req, res) => res.json(chargesArr));

// ── Admin: restart remoto ─────────────────────────────────────────────────────
// POST /api/admin/restart  body: { "token": "..." }
// Token configurável via variável de ambiente ADMIN_TOKEN (padrão: ecotrip-restart)
function adminCheckToken(req, res) {
  const token      = req.body?.token || req.query.token;
  const adminToken = process.env.ADMIN_TOKEN || 'ecotrip-restart';
  if (token !== adminToken) { res.status(401).json({ error: 'unauthorized' }); return false; }
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
  const repoDir   = path.join(__dirname, '..');
  exec('git pull', { cwd: repoDir }, (err, stdout, stderr) => {
    const out = (stdout || '').trim() || (stderr || '').trim() || '(sem saída)';
    if (err) {
      console.error('[admin] git pull falhou:', err.message);
      return res.json({ ok: false, msg: 'git pull falhou:\n' + out });
    }
    console.log('[admin] git pull OK:', out);
    res.json({ ok: true, msg: out + '\n\nReiniciando em 500ms...' });
    setTimeout(() => {
      console.log('[admin] Reiniciando após update');
      process.exit(0);
    }, 500);
  });
});

// ── Auto-trips + Telemetria ───────────────────────────────────────────────────

app.post('/api/autotrips', (req, res) => {
  try {
    const { tripId, autoTrip, samples } = req.body;
    if (!tripId || !autoTrip) return res.status(400).json({ error: 'missing fields' });

    // Sanitiza tripId (só dígitos — é o startMs em ms)
    const safeId = String(tripId).replace(/\D/g, '');
    if (!safeId) return res.status(400).json({ error: 'invalid tripId' });

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
    fs.writeFileSync(filePath, JSON.stringify({ tripId: safeId, autoTrip, samples: finalSamples }));

    const record = { tripId: safeId, ...autoTrip };
    const idx = autoTripsArr.findIndex(t => t.tripId === safeId);
    if (idx >= 0) autoTripsArr[idx] = record;
    else {
      autoTripsArr.unshift(record);
      autoTripsArr.sort((a, b) => (b.startMs || 0) - (a.startMs || 0));
    }

    console.log(`✓ AutoTrip: ${safeId} (${(samples || []).length} amostras)`);
    res.json({ ok: true });
  } catch (e) {
    console.error('Erro ao salvar auto-trip:', e.message);
    res.status(500).json({ error: e.message });
  }
});

app.get('/api/autotrips', (_req, res) => res.json(autoTripsArr.slice(0, 300)));

// Snapshots do lifetime para filtros de período no PWA (não depende de sync de auto-trips)
app.get('/api/lifetime/snapshots', (_req, res) => res.json(lifeSnapshots));

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
  broadcast('update', state);
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

    // Sensores de estado (publicados pelo HA via automação)
    case 'engine_state': state.engine_state = value; break;   // '0' | '1'
    case 'lock_state':   state.lock_state   = value; break;   // 'off' | 'on'

    // Telemetria ao vivo
    case 'speed_kmh':         state.speed_kmh          = num(value); break;
    case 'gear':              state.gear               = value || '--'; break;
    case 'inside_temp':       state.inside_temp        = num(value); break;
    case 'outside_temp':      state.outside_temp       = num(value); break;
    case 'charging_state':    state.charging_state     = value; break;
    case 'charge_power_kw':      state.charge_power_kw      = num(value); break;
    case 'charge_session_kwh':   state.charge_session_kwh   = num(value); break;
    case 'charge_remaining_min': state.charge_remaining_min = num(value); break;
    case 'charge_current_a':     state.charge_current_a     = num(value); break;
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
