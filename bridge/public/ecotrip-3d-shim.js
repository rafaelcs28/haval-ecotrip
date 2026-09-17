//  ecotrip-3d-shim.js — alimenta o viewer 3D (Haval-H6-3D, netseek) com dados do
//  bridge do EcoTrip, no lugar do broadcast do Impulse que só existe no carro.
//
//  Não altera uma linha do viewer. O `telemetryClient.js` dele já define
//  `window.onCarDataUpdate(key, value)` como entrada do lado Android — é nesse
//  mesmo ponto que empurro, então pro viewer não há diferença entre rodar no
//  head unit e rodar aqui.
//
//  As chaves são o namespace do Impulse (`car.basic.*`), o mesmo que o EcoTrip já
//  lê — as duas pontas vêm da mesma fonte. O que muda é o NOME do campo no meio
//  do caminho, e é só isso que este arquivo resolve.
//
//  Config injetada pelo hospedeiro antes deste script:
//    window.__ECOTRIP_BASE__  = 'https://…'   (origem do bridge; vazio = mesma)
//    window.__ECOTRIP_TOKEN__ = '…'           (Bearer; o app iOS injeta o dele)
(function () {
  'use strict';

  var BASE  = window.__ECOTRIP_BASE__  || '';
  var TOKEN = window.__ECOTRIP_TOKEN__ || '';

  // ── Tradução ──────────────────────────────────────────────────────────────
  // Renomear campo não basta: o viewer tem o vocabulário do CAR do Impulse, e o
  // nosso state guarda tudo normalizado em 'on'/'off'/letra. Mandar 'off' onde
  // ele espera número, ou o nosso -1 de "não sei", desenha lixo com cara de dado.

  /** -1 é sentinela de "sem leitura" no APK. Não vira 0, vira ausência. */
  function num(v) {
    var n = parseFloat(v);
    return (isFinite(n) && n >= 0) ? n : null;
  }
  function ligado(v) { return v === 'on' || v === '1' || v === 1 || v === true; }

  // Vidro: 0=movendo, 1=fechado, 2=aberto, 3=parcial (documentado pelo autor).
  // Fechado é 1, NÃO 0 — o 0 é transitório, e confundir os dois é o erro que ele
  // registra ter deixado o Impulse escrevendo num comando morto por meses.
  function vidro(v)   { return ligado(v) ? 2 : 1; }
  function porta(v)   { return ligado(v) ? 1 : 0; }
  // Teto solar é PERCENTUAL de abertura (0–100), não booleano. Só temos on/off.
  function teto(v)    { return ligado(v) ? 100 : 0; }
  // door_lock_status cru: 0=destrancado, 1 e 3=trancado.
  function tranca(v)  { return ligado(v) ? 1 : 0; }
  // Marcha é NUMÉRICA lá (CAR_GEAR_PARK = 3). O viewer só testa "está em P?",
  // então P vira 3 e qualquer outra vira 0 — inventar código pra R/N/D seria
  // chutar semântica que o código dele não define.
  function marcha(v) {
    var t = String(v).toUpperCase();
    if (!t || t === '-1') return null;        // sentinela: não sei, não afirmo
    return t === 'P' ? 3 : 0;
  }

  var ESCALAR = {
    'car.basic.vehicle_speed':          function (st) { return num(st.speed_kmh); },
    'car.basic.gear_status':            function (st) { return st.gear == null ? null : marcha(st.gear); },
    'car.basic.sunroof_status':         function (st) { return st.sunroof == null ? null : teto(st.sunroof); },
    'car.basic.door_lock_status':       function (st) { return st.lock_state == null ? null : tranca(st.lock_state); },
    'car.basic.driving_ready_state':    function (st) { return st.driving_ready == null ? null : (ligado(st.driving_ready) ? 1 : 0); },
    'car.basic.steering_wheel_angle':   function (st) { return st.steering_angle == null ? null : parseFloat(st.steering_angle); },
    'car.basic.remain_fuel_percentage': function (st) { return num(st.fuel_pct_can); },
  };

  // ── Vetores por slot ───────────────────────────────────────────────────────
  // CAR_DOOR_SLOTS do viewer: {fl:0, fr:1, rl:2, rr:3, trunk:5}. O porta-malas é
  // o slot 5, não o 4 — o vetor tem buraco no meio e encurtá-lo desloca tudo.
  var PORTAS = [['door_fl',0], ['door_fr',1], ['door_rl',2], ['door_rr',3], ['door_trunk',5]];
  var VIDROS = [['window_fl',0], ['window_fr',1], ['window_rl',2], ['window_rr',3]];

  function vetor(st, slots, conv, tam) {
    var fora = new Array(tam), viu = false;
    for (var i = 0; i < tam; i++) fora[i] = 0;
    for (var j = 0; j < slots.length; j++) {
      var campo = slots[j][0], idx = slots[j][1], v = st[campo];
      if (v === undefined || v === null) continue;
      viu = true; fora[idx] = conv(v);
    }
    return viu ? fora.join(',') : null;   // sem NENHUM campo, não afirmo nada
  }

  var ultimo = {};
  /** Espelha o que já foi empurrado num data-attribute. Serve pra inspecionar do
   *  Safari do iPad (onde não há console fácil) e pro teste headless conferir que
   *  o shim de fato alimentou o viewer, em vez de só não ter dado erro. */
  function espelha() {
    try {
      document.documentElement.setAttribute('data-ecotrip',
        JSON.stringify({ n: Object.keys(ultimo).length, chaves: ultimo }));
    } catch (e) {}
  }
  function empurra(k, v) {
    if (v === null || v === undefined) return;
    var s = String(v);
    if (ultimo[k] === s) return;          // só na mudança: o viewer redesenha a cada push
    ultimo[k] = s;
    if (typeof window.onCarDataUpdate === 'function') window.onCarDataUpdate(k, s);
    espelha();
  }

  function aplica(st) {
    if (!st || typeof st !== 'object') return;
    for (var k in ESCALAR) { try { empurra(k, ESCALAR[k](st)); } catch (e) {} }
    empurra('car.basic.door_status',   vetor(st, PORTAS, porta, 6));
    empurra('car.basic.window_status', vetor(st, VIDROS, vidro, 4));
    // Noite: o viewer troca o ambiente 3D por isto. Derivado da hora local, que
    // é melhor que nada — o carro não publica esse sinal pra cá.
    var h = new Date().getHours();
    empurra('isNight', (h >= 18 || h < 6) ? 'true' : 'false');
  }

  function cab() { return TOKEN ? { Authorization: 'Bearer ' + TOKEN } : {}; }

  function puxaEstado() {
    fetch(BASE + '/api/state?_=' + Date.now(), { cache: 'no-store', headers: cab() })
      .then(function (r) { return r.ok ? r.json() : null; })
      .then(aplica)
      .catch(function () {});
  }

  // WS pra tempo real; o fetch acima cobre o primeiro quadro e as reconexões.
  // O viewer tem o próprio listener em ws://127.0.0.1:8888 (endereço do carro),
  // que aqui simplesmente falha — deixo quieto em vez de mexer no arquivo dele.
  var ws = null, tentativa = 0;
  function conecta() {
    var origem = BASE || location.origin;
    // O /ws do bridge autentica por query string, não por header — WebSocket do
    // navegador não deixa mandar Authorization.
    var url = origem.replace(/^http/, 'ws') + '/ws'
            + (TOKEN ? '?token=' + encodeURIComponent(TOKEN) : '');
    try { ws = new WebSocket(url); } catch (e) { return agenda(); }
    ws.onopen    = function () { tentativa = 0; puxaEstado(); };
    ws.onmessage = function (ev) {
      try {
        var m = JSON.parse(ev.data);
        if (m && m.data && typeof m.data === 'object') aplica(m.data);
      } catch (e) {}
    };
    ws.onclose = agenda;
    ws.onerror = function () { try { ws.close(); } catch (e) {} };
  }
  function agenda() {
    // Backoff até 30s: o iPad suspende o WebView e reconectar em loop apertado
    // só gasta bateria.
    var espera = Math.min(30000, 1000 * Math.pow(2, tentativa++));
    setTimeout(conecta, espera);
  }

  // Dentro do app iOS quem alimenta é o NATIVO, que já fala LAN direta com o carro
  // (ws://<carro>:8088/ws/state) e tem o dado mais cru e mais rápido. O shim então
  // não abre rede nenhuma: duas rotas pro mesmo campo é a receita de discordância,
  // e a página, servida por HTTPS, nem conseguiria alcançar o carro em http — o
  // WebKit barra como mixed content. Aqui ele fica só como receptor.
  if (window.__ECOTRIP_NATIVE__) {
    window.__ecotripShim = { aplica: aplica, estado: function () { return ultimo; },
                             modo: 'nativo' };
    return;
  }

  puxaEstado();
  conecta();
  setInterval(puxaEstado, 30000);   // rede de segurança se o WS ficar meio-aberto
  window.__ecotripShim = { aplica: aplica, estado: function () { return ultimo; } };
})();
