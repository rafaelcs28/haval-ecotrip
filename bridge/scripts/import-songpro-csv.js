#!/usr/bin/env node
// Importa histórico de recargas do CSV "resumido" exportado pelo APK Song Pro
// (Electro). Constrói payload compatível com songpro_records_charges.json +
// entradas em songpro_charges.json (sp-official-<id>). Skipa IDs já presentes
// pra preservar dados mais ricos vindos por MQTT (points_count, odometer_km).
//
// Uso: node scripts/import-songpro-csv.js <path.csv>
const fs   = require('fs');
const path = require('path');

const DATA_DIR = process.env.ECOTRIP_DATA_DIR || path.join(__dirname, '..');
const CSV_PATH = process.argv[2];
if (!CSV_PATH) { console.error('uso: node scripts/import-songpro-csv.js <path.csv>'); process.exit(1); }

const CHARGES_FILE  = path.join(DATA_DIR, 'songpro_charges.json');
const RECORDS_FILE  = path.join(DATA_DIR, 'songpro_records_charges.json');
const RECONCILE_WINDOW_MS = 300_000;
const TZ_OFFSET_MS = -3 * 3600 * 1000;   // -03:00 (Brasília, sem DST)

function loadJson(p, def) { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch (_) { return def; } }
function saveJson(p, v)   { fs.writeFileSync(p, JSON.stringify(v, null, 2)); }

// Parse "DD/MM/YYYY HH:MM" como -03:00 → ms UTC
function parseLocalMs(dateStr, timeStr) {
  const [d, m, y] = dateStr.split('/').map(Number);
  const [hh, mm] = timeStr.split(':').map(Number);
  // Date.UTC monta em UTC; ajustamos manualmente pro fuso -03
  const utcMs = Date.UTC(y, m - 1, d, hh, mm, 0);
  return utcMs - TZ_OFFSET_MS;
}
function parseDurationSec(s) {
  if (!s || s === '--:--') return 0;
  const [h, m] = s.split(':').map(Number);
  return (h || 0) * 3600 + (m || 0) * 60;
}

const rawCsv = fs.readFileSync(CSV_PATH, 'utf8');
const lines = rawCsv.split(/\r?\n/).filter(l => l.trim());
const header = lines.shift();   // primeira linha = cabeçalho

const existingRecords = loadJson(RECORDS_FILE, []);
const existingCharges = loadJson(CHARGES_FILE, []);
const recordsById   = new Map(existingRecords.map(r => [r.id, r]));
const chargesByEnd  = existingCharges.slice().sort((a, b) => (a.endMs || 0) - (b.endMs || 0));

let addedRecords = 0, addedCharges = 0, skippedExisting = 0, skippedDup = 0;

for (const line of lines) {
  const cols = line.split(',');
  if (cols.length < 12) continue;
  const [id, data, hora, dur, kwh, avgKw, socStart, socEnd, socDelta, sohIni, sohFin, sohDelta] = cols;
  const officialId = parseInt(id, 10);
  if (!Number.isFinite(officialId)) continue;

  const startedMs = parseLocalMs(data, hora);
  const durationSec = parseDurationSec(dur);
  const endedMs = startedMs + durationSec * 1000;

  // Skip se já temos esse ID via MQTT (dado mais rico)
  if (recordsById.has(officialId)) { skippedExisting++; continue; }

  // Monta payload no formato MQTT response
  const payload = {
    type: 'charging_session',
    requested_id: officialId,
    request_id: null,
    generated_at: Math.floor(Date.now() / 1000),
    found: true,
    id: officialId,
    started_at_ms: startedMs,
    started_at: Math.floor(startedMs / 1000),
    ended_at: Math.floor(endedMs / 1000),
    duration_s: durationSec,
    energy_kwh: parseFloat(kwh) || 0,
    avg_power_kw: parseFloat(avgKw) || 0,
    soc_start: parseFloat(socStart) || 0,
    soc_end: parseFloat(socEnd) || 0,
    soc_added: parseFloat(socDelta) || 0,
    soh_initial: parseFloat(sohIni),
    soh_final: parseFloat(sohFin),
    soh_delta: parseFloat(sohDelta),
    odometer_km: null,
    points_count: null,
    _recv_ms: Date.now(),
    _source_import: path.basename(CSV_PATH),
  };
  existingRecords.push(payload);
  recordsById.set(officialId, payload);
  addedRecords++;

  // Match em songpro_charges (bridge computed) por endMs — se achou, enrich; senão cria sp-official
  const bridgeMatch = chargesByEnd.find(c => Math.abs((c.endMs || 0) - endedMs) < RECONCILE_WINDOW_MS);
  if (bridgeMatch) {
    if (!bridgeMatch.officialId) {
      Object.assign(bridgeMatch, {
        officialId,
        source: 'apk-official-import',
        energyKwh:   +payload.energy_kwh.toFixed(2),
        avgPowerKw:  +payload.avg_power_kw.toFixed(2),
        socStart:    Math.round(payload.soc_start),
        socEnd:      Math.round(payload.soc_end),
        sohInitial:  payload.soh_initial,
        sohFinal:    payload.soh_final,
        sohDelta:    payload.soh_delta,
      });
      addedCharges++;
    } else {
      skippedDup++;
    }
  } else {
    existingCharges.unshift({
      id: 'sp-official-' + officialId,
      officialId,
      source: 'apk-official-import',
      startMs: startedMs,
      endMs: endedMs,
      durationSec,
      lat: 0, lng: 0,
      locationId: null,
      pricePerKwh: 0,
      free: false,
      costEstimate: 0,
      energyKwh:  +payload.energy_kwh.toFixed(2),
      avgPowerKw: +payload.avg_power_kw.toFixed(2),
      socStart:   Math.round(payload.soc_start),
      socEnd:     Math.round(payload.soc_end),
      sohInitial: payload.soh_initial,
      sohFinal:   payload.soh_final,
      sohDelta:   payload.soh_delta,
      odometerKm:  null,
      pointsCount: null,
    });
    addedCharges++;
  }
}

// Ordena por endMs desc (mais recente primeiro)
existingRecords.sort((a, b) => (b.ended_at || 0) - (a.ended_at || 0));
existingCharges.sort((a, b) => (b.endMs || 0) - (a.endMs || 0));

// Backup
const ts = Math.floor(Date.now() / 1000);
if (fs.existsSync(RECORDS_FILE)) fs.copyFileSync(RECORDS_FILE, RECORDS_FILE + `.pre-import.${ts}`);
if (fs.existsSync(CHARGES_FILE)) fs.copyFileSync(CHARGES_FILE, CHARGES_FILE + `.pre-import.${ts}`);
saveJson(RECORDS_FILE, existingRecords);
saveJson(CHARGES_FILE, existingCharges);

console.log(`CSV: ${lines.length} linhas`);
console.log(`records_charges: +${addedRecords} novos · skip (já MQTT)=${skippedExisting} · total agora=${existingRecords.length}`);
console.log(`charges (bridge): +${addedCharges} · skip (dup officialId)=${skippedDup} · total agora=${existingCharges.length}`);
console.log(`backup: *.pre-import.${ts}`);
