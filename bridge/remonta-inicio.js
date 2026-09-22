#!/usr/bin/env node
'use strict';
/**
 * Remonta o começo perdido de UMA viagem usando o histórico do celular do dono.
 *
 * Existe porque o caminho automático (`_completaInicioComCelular`) não pegou a
 * viagem de 22/09: a âncora dele é `_engine_on_ms`, e o reinício da multimídia —
 * que é a receita de recuperação quando o barramento congela — reescreve esse
 * carimbo segundos antes de a viagem abrir. O portão de 3 min nunca abriu.
 *
 * Faz o MESMO que a função do bridge, com os mesmos limites:
 *   · prefixa os pontos do celular, recua o `startMs` e soma a distância;
 *   · NÃO inventa telemetria. spd/rpm/potência do trecho ficam 0, porque ninguém
 *     mediu — e número inventado contaminaria consumo, nota e split EV/HEV;
 *   · marca `_estimated` pra a origem do dado ficar declarada.
 *
 * Uso:  node remonta-inicio.js <tripId> <desde ISO|ms> [--aplica]
 * Sem --aplica é simulação: mostra o que faria e não grava nada.
 */
const fs = require('fs');
const path = require('path');

const DIR = path.join(__dirname, 'autotrips');
const [,, tripId, desdeArg, ...flags] = process.argv;
const APLICA = flags.includes('--aplica');
if (!tripId || !desdeArg) {
  console.error('uso: node remonta-inicio.js <tripId> <desde ISO|ms> [--aplica]');
  process.exit(1);
}
const desdeMs = /^\d+$/.test(desdeArg) ? +desdeArg : new Date(desdeArg).getTime();

function haversineM(a, b, c, d) {
  const R = 6371000, r = x => x * Math.PI / 180;
  const dL = r(c - a), dG = r(d - b);
  const h = Math.sin(dL/2)**2 + Math.cos(r(a))*Math.cos(r(c))*Math.sin(dG/2)**2;
  return 2 * R * Math.asin(Math.sqrt(h));
}

const fp = path.join(DIR, `${tripId}.json`);
const doc = JSON.parse(fs.readFileSync(fp, 'utf8'));
const at = doc.autoTrip || {};
const samples = Array.isArray(doc.samples) ? doc.samples : [];
if (doc._estimated) { console.error('já remontada antes — abortando pra não somar duas vezes'); process.exit(2); }
if (!at.startMs || !at.startLat) { console.error('viagem sem início conhecido'); process.exit(2); }

// Histórico do celular: NDJSON por device, 1 amostra/min, 90 dias. Junta todos os
// arquivos `hav-*` — é o telefone do dono que anda com o carro.
const bruto = [];
for (const f of fs.readdirSync(path.join(__dirname, 'phone-history'))) {
  if (!f.startsWith('hav-') || !f.endsWith('.ndjson')) continue;
  for (const l of fs.readFileSync(path.join(__dirname, 'phone-history', f), 'utf8').split('\n')) {
    if (!l.trim()) continue;
    try { bruto.push(JSON.parse(l)); } catch (_) {}
  }
}
const pts = bruto
  .filter(p => p && p.ts >= desdeMs && p.ts < at.startMs && Number.isFinite(p.lat) && Number.isFinite(p.lng))
  .sort((a, b) => a.ts - b.ts);
if (pts.length < 2) { console.error(`só ${pts.length} ponto(s) do celular na janela — insuficiente`); process.exit(3); }

let extraM = 0;
for (let i = 1; i < pts.length; i++) extraM += haversineM(pts[i-1].lat, pts[i-1].lng, pts[i].lat, pts[i].lng);
extraM += haversineM(pts.at(-1).lat, pts.at(-1).lng, at.startLat, at.startLng);

const novoStart = pts[0].ts;
const off = Math.round((at.startMs - novoStart) / 1000);

console.log(`viagem ${tripId}`);
console.log(`  hoje:    ${new Date(at.startMs).toLocaleString('pt-BR')} · ${(+at.distKm||0).toFixed(2)} km · ${Math.round((+at.timeSec||0)/60)} min`);
console.log(`  pontos do celular: ${pts.length} (${new Date(pts[0].ts).toLocaleTimeString('pt-BR')} → ${new Date(pts.at(-1).ts).toLocaleTimeString('pt-BR')})`);
console.log(`  trecho remontado:  +${(extraM/1000).toFixed(2)} km · +${Math.round(off/60)} min`);
console.log(`  fica:    ${new Date(novoStart).toLocaleString('pt-BR')} · ${((+at.distKm||0)+extraM/1000).toFixed(2)} km · ${Math.round(((+at.timeSec||0)+off)/60)} min`);
if (!APLICA) { console.log('\n(simulação — rode com --aplica pra gravar)'); process.exit(0); }

for (const sm of samples) sm.t = (sm.t || 0) + off;
samples.unshift(...pts.map(p => ({
  t: Math.round((p.ts - novoStart) / 1000), lat: p.lat, lng: p.lng,
  spd: 0, rpm: 0, evKw: 0, pwr: 0, soc: at.startSocPct || 0, src: 'phone',
})));
at.startMs = novoStart;
at.startLat = pts[0].lat; at.startLng = pts[0].lng;
at.distKm = +(((+at.distKm||0) + extraM/1000).toFixed(3));
at.timeSec = (+at.timeSec||0) + off;
doc.autoTrip = at; doc.samples = samples;
doc._estimated = true;
doc._estimatedFields = ['startMs', 'startLat', 'startLng', 'distKm', 'timeSec'];
doc._estimatedReason = 'trecho inicial remontado do histórico do celular — barramento do carro mudo';
fs.writeFileSync(fp, JSON.stringify(doc));
console.log('\ngravado. Reenvie pelo /api/autotrips ou reinicie o bridge pra o índice recarregar.');
