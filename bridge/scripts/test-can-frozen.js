#!/usr/bin/env node
/**
 * Os três casos que decidem se o detector pode reiniciar o app do carro sozinho.
 *
 * Os dois primeiros são reconstituições dos falsos positivos de 25/09 (05:52 e
 * 07:19), tirados do log do bridge e das amostras em autotrips/: nas duas vezes
 * o carro estava parado em casa e o app foi reiniciado mesmo assim. O terceiro é
 * o congelamento de verdade, que precisa continuar sendo pego.
 *
 * Uso: node scripts/test-can-frozen.js
 */
const cf = require('../can-frozen');

const CASA = { lat: -16.732578, lng: -49.274858 };
const MIN = 60_000;

/** Move `m` metros pro norte a partir de um ponto. */
function norte(p, m) { return { lat: p.lat + m / 111_320, lng: p.lng }; }

/**
 * Roda a linha do tempo minuto a minuto. Entre um tick de alerta e o seguinte, o
 * GPS do carro chega ~1x/s — o teste reproduz isso interpolando os pontos, senão
 * a trilha nunca se parece com a de verdade.
 */
function roda(nome, ticks) {
  const mem = cf.memoriaNova();
  let reiniciou = null, alertou = null, ant = null;
  for (const t of ticks) {
    if (t.canMuda) cf.marcaCanVivo(mem, t.canMuda[0], t.canMuda[1], false, t.now);
    // GPS de 10 em 10 s desde o tick anterior. `salto` marca descontinuidade:
    // o fix de antena não desliza até a posição nova, ele pula de uma vez — e
    // interpolar um salto o faria passar por uma viagem no teste.
    if (ant) {
      const n = Math.max(1, Math.round((t.now - ant.now) / 10_000));
      for (let i = 1; i <= n; i++) {
        const f = i / n;
        const saltou = t.salto && i < n;
        cf.registraPos(mem,
          saltou ? ant.lat : ant.lat + (t.lat - ant.lat) * f,
          saltou ? ant.lng : ant.lng + (t.lng - ant.lng) * f,
          ant.vel + (t.vel - ant.vel) * f,
          ant.now + (t.now - ant.now) * f);
      }
    }
    ant = t;
    const v = cf.tick({
      now: t.now, vel: t.vel, lat: t.lat, lng: t.lng,
      odoKm: t.odoKm || 0, apkAge: t.apkAge ?? 2000,
    }, mem);
    if (v.congelado && !alertou) alertou = t.now;
    if (v.deveReiniciar && !reiniciou) reiniciou = t.now;
  }
  return { nome, alertou, reiniciou };
}

const T0 = 1790331600000;   // 25/09 07:20, hora do 2º falso positivo
const casos = [];

// ── 1. Falso positivo de 25/09 07:19 ────────────────────────────────────────
// O dono chega em casa, estaciona às 07:16:45 e desce. O GNSS perde o céu na
// garagem e o Android devolve fix de antena ~800 m fora; a trava vai de 3 pra 1
// quando ele desliga e sai. O detector antigo reiniciou o app 3 min depois.
{
  const t = [];
  // chegando: velocidade caindo, posição convergindo pra casa
  for (let i = 0; i < 3; i++) {
    t.push({ now: T0 - (6 - i) * MIN, vel: 30 - i * 10, ...norte(CASA, 400 - i * 150),
             canMuda: ['speed_kmh', String(30 - i * 10)] });
  }
  // parado em casa; trava e porta mexem (o dono saindo do carro)
  t.push({ now: T0 - 3 * MIN, vel: 0, ...CASA, canMuda: ['debug/door_status_raw', '{1,0,0,0,0,0}'] });
  t.push({ now: T0 - 2 * MIN, vel: 0, ...CASA, canMuda: ['debug/lock_status_raw', '1'] });
  // salto de antena: UM passo de 800 m e para. Roda até +8 min pra a janela de
  // reinício (3 min de contradição) caber inteira dentro do teste.
  t.push({ now: T0 - 1 * MIN, vel: 0, ...norte(CASA, 800), salto: true });
  for (let i = 0; i <= 8; i++) t.push({ now: T0 + i * MIN, vel: 0, ...norte(CASA, 800) });
  casos.push(roda('falso positivo 07:19 (estacionou, GPS saltou, CAN vivo)', t));
}

// ── 2. Mesmo salto, mas sem nada mexendo no barramento ──────────────────────
// Carro parado e quieto por muito tempo: o veto de "CAN vivo" já expirou, então
// quem tem que segurar é a trilha — um salto não é uma viagem.
{
  const t = [];
  t.push({ now: T0 - 20 * MIN, vel: 10, ...norte(CASA, 300), canMuda: ['speed_kmh', '10'] });
  for (let i = 19; i >= 1; i--) t.push({ now: T0 - i * MIN, vel: 0, ...CASA });
  t.push({ now: T0, vel: 0, ...norte(CASA, 900), salto: true });
  for (let i = 1; i <= 8; i++) t.push({ now: T0 + i * MIN, vel: 0, ...norte(CASA, 900) });
  casos.push(roda('salto de GPS sozinho, barramento quieto', t));
}

// ── 3. Congelamento de verdade ──────────────────────────────────────────────
// Carro andando: o GPS avança ~1 km por tick, a velocidade não sai do zero e
// nenhum campo do barramento muda. É pra pegar — e pegar em ~3 min.
{
  const t = [];
  t.push({ now: T0 - 2 * MIN, vel: 12, ...CASA, canMuda: ['speed_kmh', '12'] });
  for (let i = 0; i <= 8; i++) t.push({ now: T0 + i * MIN, vel: 0, ...norte(CASA, 1000 * (i + 1)) });
  casos.push(roda('congelamento real (1 km/tick, velocidade 0, CAN mudo)', t));
}

const esperado = [false, false, true];
let falhou = false;
casos.forEach((c, i) => {
  const ok = !!c.reiniciou === esperado[i];
  if (!ok) falhou = true;
  const quando = c.reiniciou ? `+${Math.round((c.reiniciou - T0) / MIN)}min` : 'nunca';
  console.log(`${ok ? 'ok  ' : 'FALHA'} ${c.nome}`);
  console.log(`      alerta=${c.alertou ? 'sim' : 'não'}  reinício=${quando}`
    + `  (esperado: ${esperado[i] ? 'reiniciar' : 'não reiniciar'})`);
});
process.exit(falhou ? 1 : 0);
