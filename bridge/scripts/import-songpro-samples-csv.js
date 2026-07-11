#!/usr/bin/env node
// Importa CSV "detalhado" de deslocamentos (samples ponto-a-ponto). Cada linha
// é uma amostra; agrupa por ID do deslocamento e grava songpro_trip_samples/<id>.json
// com array compacto pro app carregar sob demanda. O CSV pode ter até ~1 sample/s
// nas viagens ativas.
//
// Uso: node scripts/import-songpro-samples-csv.js <path.csv>
const fs   = require('fs');
const path = require('path');

const DATA_DIR = process.env.ECOTRIP_DATA_DIR || path.join(__dirname, '..');
const CSV_PATH = process.argv[2];
if (!CSV_PATH) { console.error('uso: node scripts/import-songpro-samples-csv.js <path.csv>'); process.exit(1); }

const SAMPLES_DIR = path.join(DATA_DIR, 'songpro_trip_samples');
if (!fs.existsSync(SAMPLES_DIR)) fs.mkdirSync(SAMPLES_DIR, { recursive: true });

// Colunas conhecidas do export (posição 0-based após split ','):
// 0=tripId, 1=trip_start_unix, 2=sample_unix, 3=lat, 4=lng, 5=azimuth,
// 6=battery_pct, 7=speed_kmh, 8=altitude_m, 9=engine_power,
// 10=rpm_front, 11=rpm_rear, 12=batt_temp_max_c, 13=batt_v_max,
// 14=batt_temp_min_c, 15=batt_v_min, 16=ext_temp_c, 17=fuel_pct, 18=ice_rpm

const raw = fs.readFileSync(CSV_PATH, 'utf8').replace(/^﻿/, '');
const lines = raw.split(/\r?\n/).filter(l => l.trim());
lines.shift();   // header

const byTrip = new Map();
let malformed = 0;
for (const line of lines) {
  const c = line.split(',');
  if (c.length < 19) { malformed++; continue; }
  const tripId  = parseInt(c[0], 10);
  const startTs = parseInt(c[1], 10);
  const ts      = parseInt(c[2], 10);
  if (!Number.isFinite(tripId) || !Number.isFinite(ts)) { malformed++; continue; }
  const sample = {
    t:    ts - startTs,                   // segundos desde início da trip
    lat:  parseFloat(c[3]) || 0,
    lng:  parseFloat(c[4]) || 0,
    az:   parseFloat(c[5]) || 0,
    soc:  parseFloat(c[6]) || 0,
    spd:  parseFloat(c[7]) || 0,
    alt:  parseFloat(c[8]) || 0,
    pwr:  parseFloat(c[9]) || 0,
    rpmF: parseFloat(c[10]) || 0,
    rpmR: parseFloat(c[11]) || 0,
    btMax: parseFloat(c[12]) || 0,
    bvMax: parseFloat(c[13]) || 0,
    btMin: parseFloat(c[14]) || 0,
    bvMin: parseFloat(c[15]) || 0,
    extT: parseFloat(c[16]) || 0,
    fuel: parseFloat(c[17]) || 0,
    iceRpm: parseFloat(c[18]) || 0,
  };
  let arr = byTrip.get(tripId);
  if (!arr) { arr = []; byTrip.set(tripId, arr); }
  arr.push(sample);
}

// Grava um arquivo por trip
let written = 0, totalSamples = 0;
for (const [tripId, samples] of byTrip) {
  samples.sort((a, b) => a.t - b.t);
  const file = path.join(SAMPLES_DIR, `${tripId}.json`);
  fs.writeFileSync(file, JSON.stringify({
    tripId,
    startedAt: samples.length ? samples[0].t : 0,   // relative — always 0 after sort
    points: samples,
    count: samples.length,
    _imported_at: Date.now(),
    _source: path.basename(CSV_PATH),
  }));
  written++;
  totalSamples += samples.length;
}

// Também marca em songpro_records_trips.json quais trips têm samples disponíveis
const RECORDS_FILE = path.join(DATA_DIR, 'songpro_records_trips.json');
try {
  const recs = JSON.parse(fs.readFileSync(RECORDS_FILE, 'utf8'));
  let marked = 0;
  for (const r of recs) {
    if (r && byTrip.has(r.id)) { r.has_samples = true; marked++; }
  }
  fs.writeFileSync(RECORDS_FILE, JSON.stringify(recs, null, 2));
  console.log(`records: marcadas ${marked} trips com has_samples=true`);
} catch (e) {
  console.warn('não consegui atualizar records_trips.json:', e.message);
}

console.log(`samples CSV: ${lines.length} linhas · malformed=${malformed}`);
console.log(`trips com samples: ${written} · total samples: ${totalSamples}`);
console.log(`arquivos em: ${SAMPLES_DIR}/<tripId>.json`);
