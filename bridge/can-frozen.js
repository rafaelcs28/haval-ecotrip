/**
 * Decide se o barramento do carro está congelado com o carro andando.
 *
 * Mora fora do server.js por um motivo prático: este detector reinicia o app do
 * carro sozinho, e em 25/09 ele reiniciou duas vezes com o carro PARADO em casa.
 * Um erro desses custa a gravação de uma viagem e um susto no dono, então a
 * decisão precisa ser testável sem subir o bridge inteiro — `scripts/test-can-frozen.js`
 * roda os três casos que importam (os dois falsos positivos reais e um
 * congelamento de verdade).
 *
 * A função é pura: recebe a leitura do momento e a memória, devolve o veredito e
 * a memória nova. Quem executa o reinício continua no server.js.
 */

const R_TERRA_M = 6371000;
function haversineM(lat1, lon1, lat2, lon2) {
  const rad = Math.PI / 180;
  const dLat = (lat2 - lat1) * rad, dLon = (lon2 - lon1) * rad;
  const a = Math.sin(dLat / 2) ** 2
    + Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dLon / 2) ** 2;
  return 2 * R_TERRA_M * Math.asin(Math.sqrt(a));
}

/** Campos que o APK publica sem ler o CAN — não provam nada sobre o barramento. */
const CAN_NAO_PROVA = new Set([
  'heartbeat', 'last_update', 'app_version', 'status', 'status_message',
  'network/info', 'shizuku', 'gps_lat', 'gps_lng',
  // contadores que o APK toca sozinho enquanto carrega, mesmo sem CAN novo
  'charge_remaining_min', 'charge_session_kwh',
]);

/** Memória zerada — o estado que o detector carrega entre um tick e outro. */
function memoriaNova() {
  return {
    ancora: null,        // posição de quando a velocidade ainda era > 0
    trilha: [],          // posições com a velocidade em 0
    contradicaoMs: 0,    // desde quando a contradição se sustenta
    vivoMs: 0,           // última MUDANÇA de valor num campo do barramento
    ultimoValor: new Map(),
  };
}

/**
 * Registra uma mensagem do APK. Só a MUDANÇA de um campo lido do CAN conta como
 * prova de barramento vivo: valor repetido não distingue "leu de novo" de
 * "publicou o que tinha guardado", e retained é eco da sessão passada.
 */
function marcaCanVivo(mem, key, value, isRetained, now) {
  if (isRetained || key.startsWith('cmd/') || key.startsWith('ha/')) return;
  if (CAN_NAO_PROVA.has(key)) return;
  const ant = mem.ultimoValor.get(key);
  mem.ultimoValor.set(key, value);
  // Primeiro valor da sessão não conta — o burst de reconexão não é movimento.
  if (ant !== undefined && ant !== value) mem.vivoMs = now;
}

/**
 * Maior sequência de passos SEGUIDOS que implicam movimento de verdade.
 *
 * Seguidos, e não só contados, porque o fix de antena costuma ir e voltar: A→B→A
 * são dois passos rápidos e nenhum deslocamento. Dirigir não volta.
 *
 * O corte é velocidade implícita (m/s), não distância, pra não depender de quão
 * espaçados os pontos chegaram: 15 km/h separa trânsito parado de GPS pulando.
 */
function maiorSequencia(trilha, minKmh = 15) {
  let melhor = 0, atual = 0;
  for (let i = 1; i < trilha.length; i++) {
    const a = trilha[i - 1], b = trilha[i];
    const dt = (b.ms - a.ms) / 1000;
    if (dt <= 0) continue;
    const kmh = (haversineM(a.lat, a.lng, b.lat, b.lng) / dt) * 3.6;
    if (kmh > minKmh) { atual++; melhor = Math.max(melhor, atual); }
    else atual = 0;
  }
  return melhor;
}

/**
 * Anota a posição do carro no ritmo em que ela chega do APK (~1/s), não no do
 * tick de alerta (1/min). Com um ponto por minuto, 3 passos custam 3 minutos de
 * viagem perdida antes de qualquer suspeita; com o ritmo real, 30 segundos.
 *
 * Só acumula com a velocidade em zero — que é justamente o estado suspeito. Com
 * o carro andando a trilha não serve pra nada e é descartada.
 */
function registraPos(mem, lat, lng, vel, now) {
  const temGps = Number.isFinite(lat) && Number.isFinite(lng) && !!(lat || lng);
  if (vel > 0.5 || !temGps) { mem.trilha = []; return; }
  const ult = mem.trilha[mem.trilha.length - 1];
  if (ult && now - ult.ms < 8_000) return;          // no máximo 1 ponto/8s
  mem.trilha.push({ ms: now, lat, lng });
  // Janela de 10 min: passo velho não fala do agora.
  const corte = now - 10 * 60_000;
  while (mem.trilha.length && mem.trilha[0].ms < corte) mem.trilha.shift();
  if (mem.trilha.length > 120) mem.trilha.shift();
}

/**
 * Um tick da avaliação.
 *
 * @param {object} leitura  { now, vel, lat, lng, odoKm, apkAge }
 * @param {object} mem      memória de `memoriaNova()`, mutada no lugar
 * @returns {object} veredito
 */
function tick(leitura, mem) {
  const { now, vel, lat, lng, odoKm, apkAge } = leitura;
  const temGps = Number.isFinite(lat) && Number.isFinite(lng) && !!(lat || lng);

  // Âncora: onde o carro estava quando a velocidade ainda existia.
  if (vel > 0.5 || !temGps) {
    mem.ancora = temGps ? { lat, lng, ms: now, odo: odoKm || 0 } : null;
  } else if (!mem.ancora) {
    mem.ancora = { lat, lng, ms: now, odo: odoKm || 0 };
  }

  const andou = mem.ancora ? haversineM(mem.ancora.lat, mem.ancora.lng, lat, lng) : 0;
  const odoDelta = mem.ancora ? (odoKm || 0) - mem.ancora.odo : 0;

  // A trilha é alimentada por registraPos(), no ritmo do GPS. Aqui só se lê.
  const passos = maiorSequencia(mem.trilha);
  const andouProgressivo = passos >= 3;

  // Barramento entregando nos últimos 2 min ⇒ não está congelado, ponto. Numa
  // parada real de leitura NADA muda, então este veto se levanta sozinho 2 min
  // depois — o preço é atrasar a detecção verdadeira nesse tanto.
  const canVivo = mem.vivoMs > 0 && (now - mem.vivoMs) < 120_000;

  // 600 m OU 1 km de odômetro: abaixo disso é deriva de GPS parado. O odômetro
  // dispensa a trilha porque ele é do próprio barramento — se ele andou, andou.
  const contradiz = !!mem.ancora && vel <= 0.5 && !canVivo
    && (andou > 600 || odoDelta >= 1) && (andouProgressivo || odoDelta >= 1)
    && apkAge < 60_000;

  // O relógio conta a CONTRADIÇÃO, não o tempo parado. Antes os dois prazos
  // ("2 min pra não disparar num semáforo", "3 min antes de reiniciar") eram
  // medidos da âncora — que é armada quando o carro PARA. Estacionar 3 min já
  // vencia os dois, e o primeiro salto de GPS reiniciava o app na hora.
  const começou = contradiz && !mem.contradicaoMs;
  const acabou  = !contradiz && !!mem.contradicaoMs;
  if (!contradiz) mem.contradicaoMs = 0;
  else if (!mem.contradicaoMs) mem.contradicaoMs = now;

  const sustentado = mem.contradicaoMs ? now - mem.contradicaoMs : 0;
  return {
    andou, odoDelta, passos, canVivo, contradiz, sustentado,
    começou, acabou,
    quietoS: mem.vivoMs ? Math.round((now - mem.vivoMs) / 1000) : -1,
    congelado: contradiz && sustentado > 120_000,
    deveReiniciar: contradiz && sustentado > 180_000,
    ancora: mem.ancora,
  };
}

module.exports = { memoriaNova, marcaCanVivo, registraPos, tick, haversineM, maiorSequencia, CAN_NAO_PROVA };
