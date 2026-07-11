#!/usr/bin/env node
// Calcula driveScore pra viagens backfilled (que vieram sem score). Se tiver
// samples em songpro_trip_samples/, roda o cálculo completo (econ + harshAcc/Brake).
// Se não, econ-only (baseline 17.5 kWh/100km) com smoothness=100 (sem evidência).
const fs   = require('fs');
const path = require('path');

const DATA_DIR = process.env.ECOTRIP_DATA_DIR || path.join(__dirname, '..');
const TRIPS   = path.join(DATA_DIR, 'songpro_trips.json');
const SAMPLES = path.join(DATA_DIR, 'songpro_trip_samples');
const BASELINE_KWH_100 = 17.5;

function econScore(kwh100km) {
  if (kwh100km == null || !Number.isFinite(+kwh100km)) return 70;
  const delta = +kwh100km - BASELINE_KWH_100;
  return Math.max(0, Math.min(100, 100 - delta * (60 / BASELINE_KWH_100)));
}
function fromSamples(samples, distKm) {
  let ha = 0, hb = 0;
  for (let i = 1; i < samples.length; i++) {
    const dt = samples[i].t - samples[i - 1].t;
    if (dt <= 0 || dt > 5) continue;
    const a = (samples[i].spd - samples[i - 1].spd) / dt;
    if (a > 9)          ha++;
    else if (a < -11)   hb++;
  }
  const perKm = distKm > 0.5 ? (ha + hb) / distKm : 0;
  const smooth = Math.max(0, 100 - perKm * 18);
  return { smooth, ha, hb };
}

const trips = JSON.parse(fs.readFileSync(TRIPS, 'utf8'));
let updated = 0, withSamples = 0, econOnly = 0, skipped = 0;

for (const t of trips) {
  if (t.driveScore != null && t.driveScore > 0) { skipped++; continue; }
  if (!t.distKm || t.distKm < 1) { skipped++; continue; }
  const econ = econScore(t.econKwh100km);
  let smooth = 100, ha = 0, hb = 0;
  const samplesFile = path.join(SAMPLES, `${t.officialId}.json`);
  if (fs.existsSync(samplesFile)) {
    try {
      const s = JSON.parse(fs.readFileSync(samplesFile, 'utf8'));
      const sm = fromSamples(s.points || [], t.distKm);
      smooth = sm.smooth; ha = sm.ha; hb = sm.hb;
      withSamples++;
    } catch (e) {
      econOnly++;
    }
  } else {
    econOnly++;
  }
  t.driveScore  = Math.round(0.55 * econ + 0.45 * smooth);
  t.harshAcc    = ha;
  t.harshBrake  = hb;
  t.scoreSource = fs.existsSync(samplesFile) ? 'samples' : 'econ-only';
  updated++;
}

const bkp = TRIPS + '.pre-score.' + Math.floor(Date.now()/1000);
fs.copyFileSync(TRIPS, bkp);
fs.writeFileSync(TRIPS, JSON.stringify(trips, null, 2));

const avg = trips.filter(t => t.driveScore != null).reduce((a, t) => a + t.driveScore, 0) / trips.filter(t => t.driveScore != null).length;
console.log(`viagens processadas: ${updated} · com samples: ${withSamples} · econ-only: ${econOnly} · skipped: ${skipped}`);
console.log(`score médio: ${avg.toFixed(1)}`);
console.log(`backup: ${bkp}`);
