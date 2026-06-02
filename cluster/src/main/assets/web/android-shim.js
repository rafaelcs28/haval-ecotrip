// android-shim.js — faz o cluster.html (feito pro iPad) rodar no app Android.
// 1) Define window.webkit.messageHandlers.obd → cluster acha que está "nativo".
// 2) window._nativeBridge igual ao do Swift (update → applyNativeSnapshot).
// 3) Poll /api/state do bridge (cloud) e alimenta o cluster.
// 4) Traduz os comandos (postMessage) pra POSTs nos endpoints do bridge.
// Config (URL + senha) vem do Kotlin via a interface JS window.AndroidCfg.
// LAN direta (ws://) entra no M2.
(function () {
  'use strict';

  // Só tema ESCURO. Basemap dark_all (clareado via filtro mais adiante).
  // Definido ANTES de tudo (shim roda no <head>) pra valer antes do mapa criar.
  window._mapTileUrl = 'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png';

  function cfg(k, def) {
    try { if (window.AndroidCfg && window.AndroidCfg[k]) return String(window.AndroidCfg[k]()); } catch (_) {}
    return def || '';
  }
  function base() { return cfg('getBridgeUrl', '').replace(/\/+$/, ''); }
  function authHeaders() {
    // requireAuth do bridge aceita Bearer <senha> (faz sha256(token)===hash).
    return { 'Authorization': 'Bearer ' + cfg('getPassword', ''), 'Content-Type': 'application/json' };
  }

  // 1) webkit shim → roteia comandos do cluster pra cá
  window.webkit = window.webkit || {};
  window.webkit.messageHandlers = window.webkit.messageHandlers || {};
  window.webkit.messageHandlers.obd = { postMessage: function (msg) { handleCmd(msg); } };

  // 2) _nativeBridge (espelha o injetado pelo Swift no iPad)
  window._nativeBridge = {
    source: 'android-cluster',
    _latest: {},
    update: function (payload) {
      if (!payload || typeof payload !== 'object') return;
      Object.assign(this._latest, payload);
      if (typeof window.applyNativeSnapshot === 'function') window.applyNativeSnapshot(this._latest);
    },
    postAction: function (action, data) { handleCmd(Object.assign({ action: action }, data || {})); }
  };

  function setConnOk(ok) { try { if (typeof window.setConn === 'function') window.setConn(ok); } catch (_) {} }

  // ── LAN direta (ws://) — quando o tablet está na mesma rede do carro. A URL
  // vem do Kotlin (NsdManager descobre _havalobd._tcp → ws://host:port/ws/state).
  // Vantagem sobre o cloud: ~10Hz, sem latência. Cai pro cloud quando ausente.
  var lanWs = null, lanOk = false, lanLastMs = 0;
  function lanUrl() { return cfg('getLanWsUrl', ''); }
  function lanFresh() { return lanOk && (Date.now() - lanLastMs) < 5000; }
  function connectLan() {
    var u = lanUrl();
    if (!u || lanWs) return;
    try {
      lanWs = new WebSocket(u);
      lanWs.onopen = function () { lanOk = true; };
      lanWs.onmessage = function (ev) {
        try {
          var s = JSON.parse(ev.data);
          s.source = 'havalobd-apk-local';   // cluster trata como LAN-fast (prioridade)
          lanLastMs = Date.now();
          window._nativeBridge.update(s);
          setConnOk(true);
        } catch (_) {}
      };
      lanWs.onclose = function () { lanOk = false; lanWs = null; };
      lanWs.onerror = function () { try { lanWs.close(); } catch (_) {} lanOk = false; lanWs = null; };
    } catch (_) { lanWs = null; }
  }
  setInterval(connectLan, 3000);
  connectLan();

  // 3) Poll do estado (cloud) — roda SEMPRE. A LAN cobre a telemetria rápida
  // (o cluster dá prioridade via LAN_FAST_KEYS), mas o cloud traz os campos
  // ENRIQUECIDOS que a LAN não tem: gps_lat/gps_lng (mapa), viagem, preços,
  // autonomia. Sem isso o mapa fica sem localização.
  var POLL_MS = 1000;
  async function poll() {
    var b = base();
    if (!b) { setConnOk(false); return; }
    try {
      var r = await fetch(b + '/api/state', { headers: authHeaders() });
      if (!r.ok) { setConnOk(false); return; }
      var s = await r.json();
      s.source = 'android-cloud';
      window._nativeBridge.update(s);
      setConnOk(true);
    } catch (e) { setConnOk(false); }
  }
  setInterval(poll, POLL_MS);
  poll();

  // 4) Comandos — LAN (ws {"__cmd","value"}) quando conectado, senão cloud (POST).
  function cmdMap(msg) {
    var v = msg.value;
    switch (msg.action) {
      case 'drive_mode_set':        return { cmd: 'drive_mode',        path: '/api/drive-mode',        body: { mode:  parseInt(v) || 0 },  value: parseInt(v) || 0 };
      case 'power_reserve_set':     return { cmd: 'power_reserve',     path: '/api/power-reserve',     body: { mode:  parseInt(v) || 1 },  value: parseInt(v) || 1 };
      case 'charge_soc_target_set': return { cmd: 'charge_soc_target', path: '/api/charge-soc-target', body: { pct:   parseInt(v) || 50 }, value: parseInt(v) || 50 };
      case 'terrain_mode_set':      return { cmd: 'terrain_mode',      path: '/api/terrain-mode',      body: { mode:  parseInt(v) || 0 },  value: parseInt(v) || 0 };
      case 'regen_level_set':       return { cmd: 'regen_level',       path: '/api/regen-level',       body: { level: parseInt(v) || 0 },  value: parseInt(v) || 0 };
      case 'steer_mode_set':        return { cmd: 'steer_mode',        path: '/api/steer-mode',        body: { mode:  parseInt(v) || 0 },  value: parseInt(v) || 0 };
      case 'one_pedal_set':         return { cmd: 'one_pedal',         path: '/api/one-pedal',         body: { enable: v === 'true' ? 1 : 0 }, value: v === 'true' ? 1 : 0 };
      case 'esp_set':               return { cmd: 'esp',               path: '/api/esp',               body: { enable: v === 'true' ? 1 : 0 }, value: v === 'true' ? 1 : 0 };
      case 'hvac_ac':               return { cmd: 'hvac/ac_enable',    path: '/api/hvac/ac_enable',    body: { value: v }, value: v };
      case 'hvac_set':              return { cmd: 'hvac/' + (msg.control || ''), path: '/api/hvac/' + (msg.control || ''), body: { value: v }, value: v };
      case 'hvac_power':            return { cmd: 'hvac/power',        path: '/api/hvac/power',        body: { value: v }, value: v };
      case 'hazard':                return { cmd: 'hazard',            path: '/api/hazard',            body: { value: v }, value: v };
      default:                      return null;
    }
  }
  async function post(path, body) {
    var b = base(); if (!b) return;
    try { await fetch(b + path, { method: 'POST', headers: authHeaders(), body: JSON.stringify(body || {}) }); }
    catch (e) {}
  }
  function handleCmd(msg) {
    if (!msg || !msg.action) return;
    if (msg.action === 'open_nav_modal' || msg.action === 'open_nav') {
      try { if (window.AndroidCfg && window.AndroidCfg.openNav) window.AndroidCfg.openNav(); } catch (_) {}
      return;
    }
    var m = cmdMap(msg); if (!m) return;
    if (lanOk && lanWs) {   // LAN rápido
      try { lanWs.send(JSON.stringify({ __cmd: m.cmd, value: m.value })); return; } catch (_) {}
    }
    post(m.path, m.body);   // reserva cloud
  }

  // 5) Fit-scaling: escala o cluster (desenho iPad ~4:3) pra caber em QUALQUER
  // tela Android preservando proporção (letterbox preto). Cobre dobrar/desdobrar
  // do Z Fold e qualquer aparelho. Só roda no Android (este shim é Android-only).
  var FIT_DW = 1366, FIT_DH = 1024;   // canvas de desenho (paisagem ~4:3, estilo iPad 13")
  function applyAndroidFit() {
    if (!document.body) return;
    var st = document.getElementById('android-fit-style');
    if (!st) {
      st = document.createElement('style'); st.id = 'android-fit-style';
      // html = "palco" preto que centraliza o body (canvas fixo).
      // + a coluna Controles rola se o conteúdo passar da altura (métrica de
      //   fonte no Android difere do iOS) — nunca corta permanentemente.
      // Overlays (viagem + velocidade/potência) = sempre "chip escuro com texto
      // CLARO", nos dois temas. O backdrop dá a sombra na região; o --text:claro
      // dentro deles garante a legibilidade (no tema claro o --text global é escuro).
      var overlayBackdrop =
        // Chip escuro SÓLIDO (sem blur, pra não embaçar o mapa) só atrás da viagem.
        'body.native .trip-overlay{background:rgba(0,0,0,.55)!important;border-radius:16px!important;'
        + 'padding:8px 14px!important;backdrop-filter:none!important;-webkit-backdrop-filter:none!important;'
        + '--text:#f5f5f5!important;--muted:#cbd5e1!important;}'
        // Velocidade/potência: SEM caixa — só sombra CRISP no texto (sem borrão).
        + 'body.native .pwr-overlay{background:transparent!important;--text:#f5f5f5!important;}'
        + 'body.native .pwr-overlay .pwr-spd,body.native .pwr-overlay .pwr-unit,'
        + 'body.native .pwr-overlay .pwr-sub,body.native .pwr-overlay .pwr-sub *{'
        + 'text-shadow:0 1px 3px rgba(0,0,0,.95)!important;}';
      // Só ESCURO: mapa dark_all com mais contraste (ruas mais visíveis) + os overlays.
      var themeCss =
        'body.native .leaflet-tile-pane{filter:brightness(1.55) contrast(1.9)!important;}'
        // tira a vinheta/scrim escura do mapa (era a "sombra embaçada" no topo)
        + 'body.native .map-widget::after{background:none!important;}'
        // botões de zoom: cinza (preto sumia no mapa escuro)
        + 'body.native .leaflet-control-zoom a{background:#3a3f47!important;color:#fff!important;'
        + 'border-color:rgba(255,255,255,.25)!important;}'
        + overlayBackdrop;
      st.textContent = 'html{width:100%!important;height:100%!important;margin:0!important;'
        + 'overflow:hidden!important;background:#000!important;display:flex!important;'
        + 'align-items:center!important;justify-content:center!important;}'
        + 'body.native .widget.quick-widget{overflow-y:auto!important;-webkit-overflow-scrolling:touch;}'
        + 'body.native .widget.quick-widget::-webkit-scrollbar{width:0;height:0;}'
        + themeCss;
      (document.head || document.documentElement).appendChild(st);
    }
    var b = document.body.style;
    b.setProperty('width',  FIT_DW + 'px', 'important');
    b.setProperty('min-height', '0', 'important');
    b.setProperty('flex', '0 0 auto', 'important');
    b.setProperty('transform-origin', 'center center', 'important');
    // 1) baseline (não colapsa o grid) + sem transform pra medir o conteúdo real
    b.setProperty('height', FIT_DH + 'px', 'important');
    b.setProperty('transform', 'none', 'important');
    // 2) altura real do conteúdo: tanto body quanto .row-bot ficam constrangidos
    //    (overflow:hidden), então quem estoura é o .quick-widget (coluna Controles).
    //    scrollHeight dele = a altura REAL que o conteúdo precisa.
    var qw = document.querySelector('.quick-widget');
    var rb = document.querySelector('.row-bot');
    var measured = qw ? (qw.scrollHeight + 40)
                 : (rb ? (rb.offsetTop + rb.offsetHeight) : document.body.scrollHeight);
    var contentH = Math.max(FIT_DH, measured);
    b.setProperty('height', contentH + 'px', 'important');
    // 3) escala por largura E altura reais → cabe tudo, sem corte
    var s = Math.min(window.innerWidth / FIT_DW, window.innerHeight / contentH);
    b.setProperty('transform', 'scale(' + s + ')', 'important');
    window.__fitCH = contentH; window.__fitS = s;
  }
  window.addEventListener('resize', applyAndroidFit);
  window.addEventListener('orientationchange', function () { setTimeout(applyAndroidFit, 120); });
  document.addEventListener('DOMContentLoaded', applyAndroidFit);
  // re-aplica em loop curto pós-load (o cluster reposiciona layout/mapa tardiamente)
  window.addEventListener('load', function () {
    var n = 0, t = setInterval(function () { applyAndroidFit(); if (++n >= 12) clearInterval(t); }, 250);
    applyAndroidFit();
  });

  console.log('[android-shim] ativo · bridge=' + base());
})();
