#!/usr/bin/env node
// Dedupe songpro_{charges,trips}.json vs songpro_records_{charges,trips}.json.
// Pra cada bridge-live sem officialId com match em sp-official-<id> por ±300s,
// transfere location/preço/custo pro sp-official-* e remove o bridge-live.
// Órfãos (bridge-live sem match) reportados; drop opcional via --drop-orphans.
const fs = require('fs');
const path = require('path');

const DATA_DIR = process.env.ECOTRIP_DATA_DIR || path.join(__dirname, '..');
const CHARGES  = path.join(DATA_DIR, 'songpro_charges.json');
const TRIPS    = path.join(DATA_DIR, 'songpro_trips.json');
const dropOrphans = process.argv.includes('--drop-orphans');
const WINDOW_MS = 300_000;

function loadJson(p, fallback) {
  try { return JSON.parse(fs.readFileSync(p, 'utf8')); }
  catch (_) { return fallback; }
}
function saveJson(p, v) { fs.writeFileSync(p, JSON.stringify(v, null, 2)); }

function dedupe(recs, label, kwhField) {
  const withOff  = recs.filter(x => x && x.officialId);
  const withoutOff = recs.filter(x => x && !x.officialId);
  const officialByEndMs = withOff.slice().sort((a, b) => (a.endMs || 0) - (b.endMs || 0));

  let merged = 0;
  const orphans = [];
  const toDrop = new Set();
  for (const w of withoutOff) {
    const end = w.endMs || 0;
    let best = null, bestDelta = Infinity;
    for (const o of officialByEndMs) {
      const d = Math.abs((o.endMs || 0) - end);
      if (d < bestDelta) { bestDelta = d; best = o; }
    }
    if (best && bestDelta < WINDOW_MS && best.officialId != null) {
      // Transfere dados de local do bridge pro official
      if (w.locationId && !best.locationId) best.locationId = w.locationId;
      if (w.lat && !best.lat)               best.lat = w.lat;
      if (w.lng && !best.lng)               best.lng = w.lng;
      if (w.pricePerKwh && !best.pricePerKwh) best.pricePerKwh = w.pricePerKwh;
      if (typeof w.free === 'boolean' && best.free == null) best.free = w.free;
      if (best.locationId && best.pricePerKwh) {
        const kwh = +(best.energyKwh || 0);
        best.costEstimate = +(kwh * (+best.pricePerKwh || 0)).toFixed(2);
      }
      toDrop.add(w.id);
      merged++;
      console.log(`  merge ${label} bridge=${w.id} → official=${best.officialId} (Δ${Math.round(bestDelta/1000)}s)`);
    } else {
      orphans.push(w);
    }
  }

  const kept = recs.filter(x => x && !toDrop.has(x.id));
  const orphanIds = new Set(orphans.map(o => o.id));
  let finalRecs = kept;
  if (dropOrphans) {
    finalRecs = kept.filter(x => !orphanIds.has(x.id));
    console.log(`  → ${label} dropados ${orphans.length} órfãos (--drop-orphans)`);
  }
  return { finalRecs, merged, orphans, dropped: dropOrphans ? orphans.length : 0 };
}

console.log('== charges ==');
const charges = loadJson(CHARGES, []);
const cRes = dedupe(charges, 'charges', 'energyKwh');
console.log('== trips ==');
const trips = loadJson(TRIPS, []);
const tRes = dedupe(trips, 'trips', 'distKm');

saveJson(CHARGES, cRes.finalRecs);
saveJson(TRIPS,   tRes.finalRecs);

console.log('');
console.log(`charges: ${charges.length} → ${cRes.finalRecs.length} · merged=${cRes.merged} · órfãos=${cRes.orphans.length}${dropOrphans ? ' (dropados)' : ' (mantidos)'}`);
console.log(`trips:   ${trips.length} → ${tRes.finalRecs.length} · merged=${tRes.merged} · órfãos=${tRes.orphans.length}${dropOrphans ? ' (dropados)' : ' (mantidos)'}`);
if (!dropOrphans && (cRes.orphans.length || tRes.orphans.length)) {
  console.log('');
  console.log('Órfãos mantidos (sem match no APK — bridge só, provavelmente antes do feature ID existir):');
  for (const o of cRes.orphans) console.log(`  charge ${o.id} · endMs=${o.endMs} · ${o.energyKwh}kWh · SOC ${o.socStart}→${o.socEnd}`);
  for (const o of tRes.orphans) console.log(`  trip   ${o.id} · endMs=${o.endMs} · ${o.distKm}km · SOC ${o.startSoc}→${o.endSoc}`);
  console.log('');
  console.log('Rode com --drop-orphans pra apagar os órfãos também.');
}
