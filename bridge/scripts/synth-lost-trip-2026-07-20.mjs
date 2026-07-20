// Reconstrói a 2ª parte da viagem de 20/07 (07:37→10:35 BR) que se perdeu
// por reuso de tripId + arquivo autoritativo (bug estrutural).
// Trip 1 (autoritativa) = 93.4km · 76min · 21.6kWh · 0.55L
// Snapshot acumulado    = 328.2km · 235min · 31.37kWh · 30.25L
// Delta (2ª parte)      = 234.8km · 157min · 9.77kWh · 29.70L
import fs from 'node:fs';
import path from 'node:path';
const AUTOTRIPS_DIR = '/Users/consorciolimpagyn/haval-ecotrip/bridge/autotrips';

// 07:37:10 BR = 10:37:10 UTC = 1784543830000 ms
const startMs = 1784543830000;
// 10:35:12 BR = 13:35:12 UTC = 1784554512000
const endMs   = 1784554512000;

const trip1  = JSON.parse(fs.readFileSync(path.join(AUTOTRIPS_DIR, '1784537873084.json'), 'utf8')).autoTrip;
const totalDistKm  = 328.186;
const totalTimeSec = 14137;
const totalNetKwh  = 31.374;
const totalFuelL   = 30.25;

const distKm  = +(totalDistKm  - trip1.distKm ).toFixed(3);       // 234.788
const netKwh  = +(totalNetKwh  - trip1.netKwh ).toFixed(4);       // 9.774
const fuelL   = +(totalFuelL   - trip1.fuelL  ).toFixed(4);       // 29.700
const timeSec = Math.round((endMs - startMs) / 1000);             // 10682 (real, walltime)

const tripId = String(startMs);
const autoTrip = {
  startMs, endMs,
  distKm, netKwh, timeSec, fuelL,
  regenKwh: 0,
  energyKwh: +(netKwh + 0).toFixed(4),
  startSocPct: 12,   // fim da trip 1
  endSocPct:   22,   // SOC atual
  startFuelPct: 80,  // fim da trip 1
  endFuelPct:   0,   // desconhecido — deixa 0
  startLat: trip1.endLat, startLng: trip1.endLng,   // 2ª parte começa onde a 1ª terminou
  endLat: -18.169883, endLng: -47.944713,           // GPS atual (fim provável)
  maxSpeedKmh: 157.6,   // do snapshot
  avgSpeedKmh: distKm / (timeSec/3600),
  avgPowerKw: 7.99,
  parkedInPSec: 0,
  engineOffSec: 0,
  segments: [],
  name: 'Palmeiras → (retorno)',
};

const record = {
  tripId,
  autoTrip,
  samples: [],   // samples GPS ao vivo se perderam
  hybridTimeSec: null,
  hybridDistKm: null,
  _estimated: true,
  _estimatedFields: ['distKm','timeSec','netKwh','fuelL','endLat','endLng','samples'],
  _estimatedReason: 'APK morreu no meio (10:30 BR) e tripId foi reusado → samples ao vivo descartados pela proteção do _liveTripFlush. Métricas reconstruídas a partir do last_trip_snapshot acumulado (delta da trip 1 autoritativa). Sem trajeto no mapa.',
  _estimatedAppliedAt: new Date().toISOString(),
};

const fp = path.join(AUTOTRIPS_DIR, `${tripId}.json`);
if (fs.existsSync(fp)) {
  console.log('ATENÇÃO: arquivo já existe. Fazendo backup em .bak antes de sobrescrever.');
  fs.copyFileSync(fp, fp + '.bak');
}
fs.writeFileSync(fp, JSON.stringify(record, null, 2));
console.log(`✓ Trip sintetizada em ${fp}`);
console.log(`  ${autoTrip.name} · ${distKm.toFixed(1)}km · ${Math.round(timeSec/60)}min · ${netKwh.toFixed(1)}kWh · ${fuelL.toFixed(1)}L`);
