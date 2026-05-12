'use strict';

// ── Estado local ──────────────────────────────────────────────────────────────
let state = {};
let lastUpdateMs = null;
let wsRetryDelay = 1000;
let ws = null;
let tickInterval = null;

// ── Auth ──────────────────────────────────────────────────────────────────────
let bridgeToken = localStorage.getItem('bridge_token') || '';

// SHA-256 via Web Crypto API (requer HTTPS ou localhost)
// Em HTTP retorna o texto puro como fallback — o servidor aceita os dois
async function sha256hex(str) {
  try {
    if (typeof crypto !== 'undefined' && crypto.subtle) {
      const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(str));
      return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');
    }
  } catch (_) {}
  return str;  // fallback HTTP: envia texto puro
}

function showLogin(errorMsg) {
  const overlay = document.getElementById('login-overlay');
  if (overlay) overlay.style.display = 'flex';
  const err = document.getElementById('login-error');
  if (err) { err.style.display = errorMsg ? '' : 'none'; err.textContent = errorMsg || ''; }
  setTimeout(() => document.getElementById('login-input')?.focus(), 100);
}

function hideLogin() {
  const overlay = document.getElementById('login-overlay');
  if (overlay) overlay.style.display = 'none';
}

async function doLogin() {
  const input    = document.getElementById('login-input');
  const password = (input?.value || '').trim();
  try {
    // Converte a senha para SHA-256 antes de enviar — servidor nunca vê o texto puro
    const tokenHash = password ? await sha256hex(password) : '';
    const headers   = tokenHash ? { 'Authorization': 'Bearer ' + tokenHash } : {};
    const r = await fetch('/api/state', { headers });
    if (r.ok) {
      bridgeToken = tokenHash;
      if (tokenHash) localStorage.setItem('bridge_token', tokenHash);
      else localStorage.removeItem('bridge_token');
      hideLogin();
      connect();
    } else {
      showLogin('Senha incorreta.');
    }
  } catch (_) {
    showLogin('Sem conexão com o servidor.');
  }
}

// Permite enviar com Enter no campo de senha
document.addEventListener('DOMContentLoaded', () => {
  document.getElementById('login-input')?.addEventListener('keydown', e => {
    if (e.key === 'Enter') doLogin();
  });
  initActionsPanel();
});

// ── Actions panel — criado 100% em JS para sobreviver a cache antigo de index.html
function initActionsPanel() {
  const CARDS = [
    { title: '⚙️ Motor', items: [
      { label: '▶ Ligar',    cls: 'green',  action: 'engine_on',      confirm: '⚙️ Ligar motor?',           msg: 'O motor térmico será ligado remotamente.',       color: '#22c55e' },
      { label: '■ Desligar', cls: 'red',    action: 'engine_off',     confirm: '⚙️ Desligar motor?',        msg: 'O motor térmico será desligado remotamente.',    color: '#ef4444' },
    ]},
    { title: '🚗 Portas', items: [
      { label: '🔓 Abrir',  cls: 'orange', action: 'lock_open',      confirm: '🔓 Abrir portas?',          msg: 'As portas serão destrancadas remotamente.',      color: '#f97316' },
      { label: '🔒 Fechar', cls: 'teal',   action: 'lock_close',     confirm: '🔒 Fechar portas?',         msg: 'As portas serão trancadas remotamente.',         color: '#2dd4bf' },
    ]},
    { title: '🪟 Vidros', items: [
      { label: '↕ Abrir todos',  cls: 'orange', action: 'windows_open',  confirm: '🪟 Abrir vidros?',   msg: 'Todos os vidros serão abertos remotamente.',  color: '#f97316' },
      { label: '↕ Fechar todos', cls: 'teal',   action: 'windows_close', confirm: '🪟 Fechar vidros?',  msg: 'Todos os vidros serão fechados remotamente.', color: '#2dd4bf' },
    ]},
    { title: '🧳 Porta-malas', items: [
      { label: '↑ Abrir',  cls: 'orange', action: 'trunk_open',     confirm: '🧳 Abrir porta-malas?',     msg: 'A porta-malas será aberta remotamente.',         color: '#f97316' },
      { label: '↓ Fechar', cls: 'teal',   action: 'trunk_close',    confirm: '🧳 Fechar porta-malas?',    msg: 'A porta-malas será fechada remotamente.',        color: '#2dd4bf' },
    ]},
    { title: '☀️ Teto solar', items: [
      { label: '↑ Abrir',  cls: 'orange', action: 'sunroof_open',   confirm: '☀️ Abrir teto solar?',      msg: 'O teto solar será aberto remotamente.',          color: '#f97316' },
      { label: '↓ Fechar', cls: 'teal',   action: 'sunroof_close',  confirm: '☀️ Fechar teto solar?',     msg: 'O teto solar será fechado remotamente.',         color: '#2dd4bf' },
    ]},
    { title: '❄️ Ar condicionado', items: [
      { label: '❄️ Ativar ar condicionado', cls: 'blue full', action: 'ac_on', confirm: '❄️ Ligar AC?', msg: 'O ar condicionado será ativado remotamente.', color: '#60a5fa' },
    ]},
    { title: '⚡ Recarga', items: [
      { label: '✕ Interromper recarga',  cls: 'red full',   action: 'charge_stop',    confirm: '⚡ Interromper recarga?',            msg: 'A recarga será interrompida remotamente.',       color: '#ef4444' },
      { label: '📋 Atualizar histórico', cls: 'muted full', action: 'charge_history', confirm: '📋 Atualizar histórico de recarga?', msg: 'O histórico de recarga será sincronizado.',      color: '#94a3b8' },
    ]},
  ];

  // Garante que o panel existe mesmo com index.html antigo em cache
  let panel = document.getElementById('panel-actions');
  if (!panel) {
    panel = document.createElement('div');
    panel.id = 'panel-actions';
    panel.className = 'panel';
    const content = document.getElementById('content');
    if (content) content.appendChild(panel);
  }

  // Garante que o tab existe mesmo com index.html antigo em cache
  if (!document.querySelector('[data-panel="actions"]')) {
    const adminTab = document.querySelector('[data-panel="admin"]');
    if (adminTab) {
      const btn = document.createElement('button');
      btn.className = 'tab';
      btn.dataset.panel = 'actions';
      btn.innerHTML = '<span class="tab-icon">🔧</span><span class="tab-label">Ações</span>';
      btn.addEventListener('click', () => switchTab(btn));
      adminTab.parentNode.insertBefore(btn, adminTab);
    }
  }

  // Renderiza os cards de ação
  panel.innerHTML = CARDS.map(card => `
    <div class="card">
      <div class="card-title">${card.title}</div>
      <div class="action-grid">
        ${card.items.map(item => `
          <button class="action-btn ${item.cls}"
            onclick="remoteAction('${item.action}',${JSON.stringify(item.confirm)},${JSON.stringify(item.msg)},'${item.color}')">
            ${item.label}
          </button>`).join('')}
      </div>
    </div>`).join('');
}

// Wrapper de fetch que injeta o token e redireciona 401 para o login
// skipLoginRedirect: true → não redireciona, só lança o erro (usado em change-password)
function apiFetch(url, opts = {}, skipLoginRedirect = false) {
  if (bridgeToken) {
    opts.headers = { ...(opts.headers || {}), 'Authorization': 'Bearer ' + bridgeToken };
  }
  return fetch(url, opts).then(r => {
    if (r.status === 401) {
      if (!skipLoginRedirect) showLogin('Sessão expirada. Digite a senha novamente.');
      throw new Error('unauthorized');
    }
    return r;
  });
}

// Merge profundo: sobrescreve apenas as chaves presentes em source (sem apagar as demais)
function deepMerge(target, source) {
  for (const [k, v] of Object.entries(source)) {
    if (v !== null && v !== undefined) {
      if (typeof v === 'object' && !Array.isArray(v) && target[k] && typeof target[k] === 'object') {
        deepMerge(target[k], v);
      } else {
        target[k] = v;
      }
    }
  }
}

// ── Service Worker & Push ─────────────────────────────────────────────────────
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/sw.js').then(async reg => {
    // Tenta subscrever push sem bloquear a inicialização
    try { await subscribePush(); } catch (_) {}
  }).catch(() => {});

  // Recarrega a página automaticamente quando um SW novo toma controle
  navigator.serviceWorker.addEventListener('message', e => {
    if (e.data?.type === 'SW_UPDATED') location.reload();
  });
  // Garante reload se o controlador mudar (ex: primeiro SW ou skipWaiting)
  let refreshing = false;
  navigator.serviceWorker.addEventListener('controllerchange', () => {
    if (!refreshing) { refreshing = true; location.reload(); }
  });
}

// ── Hard refresh — limpa todos os caches SW e recarrega ───────────────────────
async function hardRefresh() {
  if ('caches' in window) {
    const keys = await caches.keys();
    await Promise.all(keys.map(k => caches.delete(k)));
  }
  if ('serviceWorker' in navigator) {
    const reg = await navigator.serviceWorker.getRegistration();
    if (reg) await reg.update();
  }
  location.reload(true);
}

function urlBase64ToUint8Array(b64) {
  const pad = '='.repeat((4 - b64.length % 4) % 4);
  const raw = atob((b64 + pad).replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from(raw, c => c.charCodeAt(0));
}

async function subscribePush() {
  if (!('Notification' in window) || !('PushManager' in window)) return;
  // Só pede permissão se ainda não foi decidido
  let perm = Notification.permission;
  if (perm === 'denied') return;
  if (perm === 'default') perm = await Notification.requestPermission();
  if (perm !== 'granted') return;

  const reg = await navigator.serviceWorker.ready;
  // Reutiliza subscrição existente, se houver
  let sub = await reg.pushManager.getSubscription();
  if (!sub) {
    const { key } = await fetch('/api/push/vapid-key').then(r => r.json());
    sub = await reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(key),
    });
  }
  await fetch('/api/push/subscribe', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(sub),
  });
}

// ── Tabs ──────────────────────────────────────────────────────────────────────
function switchTab(btn, callback) {
  document.querySelectorAll('.tab').forEach(t => t.classList.remove('active'));
  document.querySelectorAll('.panel').forEach(p => p.classList.remove('active'));
  btn.classList.add('active');
  document.getElementById('panel-' + btn.dataset.panel).classList.add('active');
  if (callback) callback();
}

// ── WebSocket ─────────────────────────────────────────────────────────────────
function connect() {
  const proto  = location.protocol === 'https:' ? 'wss:' : 'ws:';
  const tkParam = bridgeToken ? '?token=' + encodeURIComponent(bridgeToken) : '';
  ws = new WebSocket(`${proto}//${location.host}/ws${tkParam}`);

  ws.onopen = () => {
    console.log('WS conectado');
    wsRetryDelay = 1000;
    setStatus('connecting');
  };

  ws.onmessage = (evt) => {
    try {
      const msg = JSON.parse(evt.data);
      if (msg.type === 'full_state' || msg.type === 'update') {
        // Detecta reinício do servidor → hard refresh automático
        if (msg.type === 'full_state' && msg.startedAt) {
          const prev = sessionStorage.getItem('srv_start');
          if (prev && prev !== String(msg.startedAt)) {
            // Servidor reiniciou — busca arquivos novos
            sessionStorage.setItem('srv_start', msg.startedAt);
            hardRefresh();
            return;
          }
          sessionStorage.setItem('srv_start', msg.startedAt);
        }
        deepMerge(state, msg.data);
        lastUpdateMs = Date.now();
        renderAll();
        try { localStorage.setItem('ecotrip_state', JSON.stringify({ state, ts: lastUpdateMs })); } catch(_) {}
      } else if (msg.type === 'AUTH_ERROR') {
        ws.close();
        showLogin('Senha incorreta ou expirada.');
        return;
      } else if (msg.type === 'new_autotrip') {
        // Nova viagem automática chegou do carro — invalida cache
        cachedAutoTrips = null;
        const autoPanel = document.getElementById('panel-auto');
        if (autoPanel && autoPanel.classList.contains('active')) {
          // Aba Auto aberta: recarrega direto, silenciosamente
          loadAutoTrips();
        } else {
          // Outra aba: mostra badge (ponto verde) no botão Auto
          const btn = document.querySelector('[data-panel="auto"]');
          if (btn && !btn.querySelector('.tab-notif')) {
            btn.style.position = 'relative';
            const dot = document.createElement('span');
            dot.className = 'tab-notif';
            dot.style.cssText = 'position:absolute;top:3px;right:6px;width:8px;height:8px;' +
              'background:#39FF88;border-radius:50%;border:2px solid #0f172a;pointer-events:none;';
            btn.appendChild(dot);
          }
        }
      }
    } catch (e) { console.error('WS parse error', e); }
  };

  ws.onerror  = () => {};
  ws.onclose  = (e) => {
    if (e.code === 4001) { showLogin('Acesso negado. Digite a senha.'); return; }
    setStatus('offline');
    const delay = Math.min(wsRetryDelay, 30000);
    wsRetryDelay = Math.min(wsRetryDelay * 1.5, 30000);
    console.log(`WS fechado. Reconectando em ${delay}ms…`);
    setTimeout(connect, delay);
  };
}

// ── Status / "última atualização" ─────────────────────────────────────────────
function setStatus(s) {
  const dot = document.getElementById('status-dot');
  dot.className = '';
  if (s === 'online')       dot.classList.add('online');
  else if (s === 'offline') dot.classList.add('offline');
}

function relTime(ms) {
  if (!ms) return '--';
  const sec = Math.floor((Date.now() - ms) / 1000);
  if (sec < 10)    return 'agora';
  if (sec < 60)    return `${sec}s atrás`;
  if (sec < 3600)  return `${Math.floor(sec/60)}min atrás`;
  if (sec < 86400) return `${Math.floor(sec/3600)}h atrás`;
  return `${Math.floor(sec/86400)}d atrás`;
}

function tickLastUpdate() {
  const elBridge = document.getElementById('last-update');
  elBridge.textContent = lastUpdateMs ? relTime(lastUpdateMs) : '--';

  const elCar = document.getElementById('car-update');
  if (elCar) {
    const iso = state.car_last_update;
    elCar.textContent = iso ? 'carro: ' + relTime(new Date(iso).getTime()) : 'carro: --';
  }

  const sec = lastUpdateMs ? Math.floor((Date.now() - lastUpdateMs) / 1000) : 9999;
  if (state.car_online && sec < 30)  setStatus('online');
  else if (sec < 60)                 setStatus('connecting');
  else                               setStatus('offline');
}

// ── Helpers de formatação ─────────────────────────────────────────────────────
const f1  = v => (typeof v === 'number' ? v.toFixed(1)  : '--');
const f2  = v => (typeof v === 'number' ? v.toFixed(2)  : '--');
const pct = v => (typeof v === 'number' ? v.toFixed(0) + '%' : '--%');
const eff = v => {
  if (!v || v <= 0) return 'muted';
  if (v < 20) return 'green';
  if (v < 30) return 'yellow';
  return 'orange';
};

function setText(id, text) {
  const el = document.getElementById(id);
  if (el) el.textContent = text;
}
function setClass(id, cls) {
  const el = document.getElementById(id);
  if (el) {
    el.className = el.className.replace(/\b(green|blue|teal|orange|yellow|muted)\b/g, '');
    el.classList.add(cls);
  }
}

// Formata segundos brutos (recargas, lifetime) → "01h:20'50""
function fmtDur(sec) {
  if (!sec || sec <= 0) return '--';
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60), s = Math.floor(sec % 60);
  if (h > 0) return `${String(h).padStart(2,'0')}h:${String(m).padStart(2,'0')}'${String(s).padStart(2,'0')}"`;
  return `${String(m).padStart(2,'0')}'${String(s).padStart(2,'0')}"`;
}

// Formata string pré-formatada do Android "3h, 20 min e 50s" → "03h:20'50""
function fmtTripTime(v) {
  if (!v || v === '--') return '--';
  if (typeof v === 'number') return fmtDur(v);            // fallback: segundos brutos
  const h = +(v.match(/(\d+)\s*h/)   || [0,0])[1];
  const m = +(v.match(/(\d+)\s*min/) || [0,0])[1];
  const s = +(v.match(/(\d+)\s*s\b/) || [0,0])[1];
  if (h === 0 && m === 0 && s === 0) return '--';
  if (h > 0) return `${String(h).padStart(2,'0')}h:${String(m).padStart(2,'0')}'${String(s).padStart(2,'0')}"`;
  return `${String(m).padStart(2,'0')}'${String(s).padStart(2,'0')}"`;
}
function fmtDate(ts) {
  try {
    const d = new Date(ts);
    return d.toLocaleDateString('pt-BR', { day:'2-digit', month:'2-digit', year:'2-digit' })
         + ' ' + d.toLocaleTimeString('pt-BR', { hour:'2-digit', minute:'2-digit' });
  } catch(_) { return ts || '--'; }
}

// ── Filtros ───────────────────────────────────────────────────────────────────
const filterState = {
  charges: { active: 'all', customFrom: '', customTo: '' },
  hist:    { active: 'all', customFrom: '', customTo: '' },
  auto:    { active: 'all', customFrom: '', customTo: '' },
};
let cachedCharges = null;
let cachedTrips   = null;

function getFilterRange(tabId) {
  const f   = filterState[tabId];
  const now = Date.now();
  const tod = new Date(); tod.setHours(0, 0, 0, 0);
  switch (f.active) {
    case 'today': return [tod.getTime(), Infinity];
    case '7d':    return [now - 7  * 86400000, Infinity];
    case '30d':   return [now - 30 * 86400000, Infinity];
    case 'month': { const m = new Date(); m.setDate(1); m.setHours(0,0,0,0); return [m.getTime(), Infinity]; }
    case 'custom': {
      const from = f.customFrom ? new Date(f.customFrom).getTime()              : 0;
      const to   = f.customTo   ? new Date(f.customTo + 'T23:59:59').getTime() : Infinity;
      return [from, to];
    }
    default: return [0, Infinity]; // 'all'
  }
}

function filterItems(arr, tsField, startMs, endMs) {
  if (startMs === 0 && endMs === Infinity) return arr;
  return arr.filter(item => {
    const ms = new Date(item[tsField]).getTime();
    return ms >= startMs && ms <= endMs;
  });
}

function setFilter(tabId, filter) {
  filterState[tabId].active = filter;
  if (tabId === 'charges') renderCharges();
  if (tabId === 'hist')    renderHistory();
  if (tabId === 'auto')    renderAutoTrips();
}

function setFilterDates(tabId) {
  const fe = document.getElementById(`filter-${tabId}-from`);
  const te = document.getElementById(`filter-${tabId}-to`);
  if (fe) filterState[tabId].customFrom = fe.value;
  if (te) filterState[tabId].customTo   = te.value;
  setFilter(tabId, 'custom');
}

function filterChipsHTML(tabId) {
  const a = filterState[tabId].active;
  const f = filterState[tabId];
  const c = (id, lbl) =>
    `<button class="filter-chip${a===id?' active':''}" onclick="setFilter('${tabId}','${id}')">${lbl}</button>`;
  const dates = a === 'custom' ? `
<div class="filter-dates">
  <input type="date" id="filter-${tabId}-from" value="${f.customFrom}" onchange="setFilterDates('${tabId}')">
  <span class="filter-sep">até</span>
  <input type="date" id="filter-${tabId}-to" value="${f.customTo}" onchange="setFilterDates('${tabId}')">
</div>` : '';
  return `<div class="filter-chips">${c('all','Tudo')}${c('today','Hoje')}${c('7d','7 dias')}${c('30d','30 dias')}${c('month','Mês')}${c('custom','Custom')}</div>${dates}`;
}

// ── Render ────────────────────────────────────────────────────────────────────
function renderAll() {
  renderDash();
  renderTrip('a', state.trip_a || {});
  renderTrip('b', state.trip_b || {});
  renderCarVersion();
}

function renderCarVersion() {
  const el = document.getElementById('car-version-badge');
  if (!el) return;
  const v = state.car_app_version;
  if (v) { el.textContent = 'carro v' + v; el.classList.add('visible'); }
  else   { el.classList.remove('visible'); }
}

function renderDash() {
  const s = state;
  setText('d-car-temp-in',  s.inside_temp  ? f1(s.inside_temp)  + '°' : '--°');
  setText('d-car-temp-out', s.outside_temp ? f1(s.outside_temp) + '°' : '--°');

  // Odômetro total
  const odo = s.odometer_km || 0;
  setText('d-odometer', odo > 0 ? Math.round(odo).toLocaleString('pt-BR') : '--');

  // Bateria 12V — cor por faixa de carga
  const b12 = s.batt_12v_pct || 0;
  setText('d-batt12v', b12 > 0 ? Math.round(b12) + '%' : '--%');
  const b12Color = b12 >= 90 ? '#39FF88'   // verde
                 : b12 >= 80 ? '#FFD60A'   // amarelo
                 : b12 >= 70 ? '#FF5F1F'   // laranja
                 : b12 >  0  ? '#f87171'   // vermelho
                 :             '#475569';  // sem dado
  const b12Bar = document.getElementById('d-batt12v-bar');
  if (b12Bar) {
    b12Bar.style.width      = Math.max(0, Math.min(100, b12)) + '%';
    b12Bar.style.background = b12 > 0 ? b12Color : '';
  }
  const b12ValEl = document.getElementById('d-batt12v');
  if (b12ValEl) b12ValEl.style.color = b12Color;

  // SOC
  const soc = s.soc_pct || s.trip_a?.soc_current || 0;
  setText('d-soc', pct(soc));
  const socBar = document.getElementById('d-soc-bar');
  if (socBar) socBar.style.width = Math.max(0, Math.min(100, soc)) + '%';

  // ── Autonomia elétrica + térmica estimadas ────────────────────────────────
  const BATT_KWH      = 25.8, EV_MIN_SOC = 12;
  // Floor de 14 kWh/100km: abaixo disso o motor térmico estava carregando
  // a bateria (gerador), o que contamina o consumo elétrico com valores
  // artificialmente baixos — esse dado não reflete autonomia real em EV puro.
  const EV_KWH_FLOOR    = 12;
  const EV_KWH_FALLBACK = 20;   // conservador: 1 kWh = 5 km
  const KML_FALLBACK    = 12;   // 12 km/L

  const rollingDist = s.rolling?.distance_km || 0;
  const tripaDist   = s.trip_a?.distance_km  || 0;

  // Média elétrica — Trip A como base; rolling como refinamento só se
  // > 10 km E valor realista para modo EV puro (>= floor)
  const tripAKwh100   = tripaDist  > 10 && (s.trip_a?.kwh_per_100km  || 0) >= EV_KWH_FLOOR
                        ? s.trip_a.kwh_per_100km  : null;
  const rollingKwh100 = rollingDist > 10 && (s.rolling?.kwh_per_100km || 0) >= EV_KWH_FLOOR
                        ? s.rolling.kwh_per_100km : null;
  const avgKwh100 = rollingKwh100 ?? tripAKwh100 ?? EV_KWH_FALLBACK;

  // Média térmica — só usa se queimou ≥ 1L de combustível; evita km/L
  // inflado de viagens quase totalmente elétricas (ex: 15 km e 0,05L → 300 km/L)
  const tripAKml   = (s.trip_a?.fuel_l  || 0) > 1 && (s.trip_a?.km_per_l  || 0) > 2
                     ? s.trip_a.km_per_l  : null;
  const rollingKml = (s.rolling?.fuel_l || 0) > 1 && (s.rolling?.km_per_l || 0) > 2
                     ? s.rolling.km_per_l : null;
  const avgKmL = rollingKml ?? tripAKml ?? KML_FALLBACK;

  const usableKwh = Math.max(0, (soc - EV_MIN_SOC) / 100 * BATT_KWH);
  const evKm      = Math.round(usableKwh / (avgKwh100 / 100));
  const evRangeEl = document.getElementById('d-ev-range');
  if (evRangeEl) {
    evRangeEl.style.display = soc > EV_MIN_SOC ? '' : 'none';
    if (soc > EV_MIN_SOC) setText('d-ev-km', evKm + ' km');
  }

  // Combustível (tank 51L)
  const TANK_CAP = 51;
  const tankNow = s.trip_a?.tank_now_l > 0 ? s.trip_a.tank_now_l
                : s.trip_b?.tank_now_l > 0 ? s.trip_b.tank_now_l : 0;
  const fuelPct = tankNow > 0 ? Math.min(100, (tankNow / TANK_CAP) * 100) : 0;
  setText('d-fuel', tankNow > 0 ? f1(tankNow) + ' L  (' + fuelPct.toFixed(0) + '%)' : '--');
  const fuelBar = document.getElementById('d-fuel-bar');
  if (fuelBar) fuelBar.style.width = Math.max(0, Math.min(100, fuelPct)) + '%';

  // Autonomia térmica estimada
  const fuelKm      = tankNow > 0 ? Math.round(tankNow * avgKmL) : 0;
  const fuelRangeEl = document.getElementById('d-fuel-range');
  if (fuelRangeEl) {
    fuelRangeEl.style.display = fuelKm > 0 ? '' : 'none';
    if (fuelKm > 0) setText('d-fuel-km', fuelKm + ' km');
  }

  // Recarga — card dedicado (só aparece quando charging_state === 'Carregando')
  const isCharging = s.charging_state === 'Carregando';
  const chargingCard = document.getElementById('d-charging-card');
  if (chargingCard) chargingCard.style.display = isCharging ? '' : 'none';
  if (isCharging) {
    setText('d-chrg-power',   s.charge_power_kw   > 0 ? f1(s.charge_power_kw)    + ' kW'  : '--');
    setText('d-chrg-session', s.charge_session_kwh > 0 ? f2(s.charge_session_kwh) + ' kWh' : '--');
    const rem = s.charge_remaining_min || 0;
    setText('d-chrg-remain', rem > 0
      ? (rem > 59 ? Math.floor(rem / 60) + 'h ' + (rem % 60) + 'min' : rem + ' min')
      : '--');
  }

  // Trip A mini
  const ta = s.trip_a || {};
  setText('d-trip-dist', ta.distance_km   > 0 ? f1(ta.distance_km) + ' km' : '--');
  setText('d-trip-time', fmtTripTime(ta.time_sec));
  setText('d-trip-kwh',  ta.kwh_per_100km > 0 ? f1(ta.kwh_per_100km)       : '--');
  setText('d-trip-kml',  ta.km_per_l      > 0 ? f1(ta.km_per_l)            : '--');
  setText('d-trip-cost', ta.cost_brl      > 0 ? 'R$ ' + f2(ta.cost_brl)   : '--');
  setClass('d-trip-kwh', eff(ta.kwh_per_100km));

  // Trip B mini
  const tb = s.trip_b || {};
  setText('d-tripb-dist', tb.distance_km   > 0 ? f1(tb.distance_km) + ' km' : '--');
  setText('d-tripb-time', fmtTripTime(tb.time_sec));
  setText('d-tripb-kwh',  tb.kwh_per_100km > 0 ? f1(tb.kwh_per_100km)       : '--');
  setText('d-tripb-kml',  tb.km_per_l      > 0 ? f1(tb.km_per_l)            : '--');
  setText('d-tripb-cost', tb.cost_brl      > 0 ? 'R$ ' + f2(tb.cost_brl)   : '--');
  setClass('d-tripb-kwh', eff(tb.kwh_per_100km));

  // ── Camadas PNG do carro ─────────────────────────────────────────────────────
  function carLayer(id, show) {
    const el = document.getElementById(id);
    if (el) el.style.display = show ? 'block' : 'none';
  }

  const eng   = s.engine_state;
  const engOn = eng === '1' || eng === 1;

  // Faróis — ligados com o motor (farol alto via sensor futuro high_beam)
  carLayer('cl-farol',      engOn && s.high_beam !== 'on');
  carLayer('cl-farol-alto', s.high_beam === 'on');
  const engLabel = document.getElementById('d-car-engine-label');
  if (engLabel) {
    // ⚙️ sempre visível — vermelho=ligado | cinza=desligado | muito-cinza=desconhecido
    engLabel.textContent = '⚙️';
    engLabel.style.filter = engOn              ? 'sepia(1) saturate(8) hue-rotate(310deg)'
                          : (eng === '0' || eng === 0) ? 'grayscale(1) opacity(.45)'
                          :                               'grayscale(1) opacity(.18)';
  }

  // Trava
  const lck = s.lock_state;
  carLayer('cl-trava', lck === 'off');
  const lockLabel = document.getElementById('d-car-lock-label');
  if (lockLabel) {
    // 🔒/🔓 sempre visível — teal=trancado | laranja=destrancado | muito-cinza=desconhecido
    if      (lck === 'off') { lockLabel.textContent = '🔒'; lockLabel.style.filter = 'sepia(1) saturate(6) hue-rotate(130deg)'; }
    else if (lck === 'on')  { lockLabel.textContent = '🔓'; lockLabel.style.filter = 'sepia(1) saturate(8) hue-rotate(340deg)'; }
    else                     { lockLabel.textContent = '🔒'; lockLabel.style.filter = 'grayscale(1) opacity(.18)'; }
  }

  // Portas — alterna fechada/aberta (sempre uma delas visível)
  function doorLayer(pos, state) {
    const open = state === 'on';
    carLayer(`cl-door-${pos}-c`, !open);
    carLayer(`cl-door-${pos}-o`,  open);
  }
  doorLayer('fl', s.door_fl);
  doorLayer('fr', s.door_fr);
  doorLayer('rl', s.door_rl);
  doorLayer('rr', s.door_rr);
  carLayer('cl-trunk', s.door_trunk === 'on');

  // Teto solar (fechado = '3')
  carLayer('cl-sunroof', s.sunroof != null && s.sunroof !== '3' && s.sunroof !== 3);

  // AC
  const acOn = s.ac_state === 'on';
  carLayer('cl-ac-left',    acOn);
  carLayer('cl-ac-right',   acOn);
  carLayer('cl-ventilacao', acOn);

  // Vidros (1=fechado, 2=aberto, 3=entreaberto)
  carLayer('cl-win-fl-open', s.window_fl === '2' || s.window_fl === 2);
  carLayer('cl-win-fl-ajar', s.window_fl === '3' || s.window_fl === 3);
  carLayer('cl-win-fr-open', s.window_fr === '2' || s.window_fr === 2);
  carLayer('cl-win-fr-ajar', s.window_fr === '3' || s.window_fr === 3);
  carLayer('cl-win-rl-open', s.window_rl === '2' || s.window_rl === 2);
  carLayer('cl-win-rl-ajar', s.window_rl === '3' || s.window_rl === 3);
  carLayer('cl-win-rr-open', s.window_rr === '2' || s.window_rr === 2);
  carLayer('cl-win-rr-ajar', s.window_rr === '3' || s.window_rr === 3);

  // Recarga
  const chg = s.charging_state || '';
  carLayer('cl-charge-on',   chg === 'Carregando');
  carLayer('cl-charge-wait', chg === 'Aguardando');
  carLayer('cl-charge-no',   chg === 'Não Carregando' || chg === 'NaoCarregando');

  // Pneus
  function renderTyre(pos, kpa, tempC) {
    const psi = kpa > 0 ? kpa / 6.895 : 0;
    const psiEl  = document.getElementById(`d-tyre-${pos}-psi`);
    const tempEl = document.getElementById(`d-tyre-${pos}-temp`);
    const card   = document.getElementById(`d-tyre-${pos}`);
    if (!psiEl) return;
    if (psi > 0) {
      psiEl.textContent = psi.toFixed(1);
      const alert = psi < 34 || psi > 40;
      psiEl.style.color = alert ? '#f87171' : '#60a5fa';
      if (card) {
        card.style.border      = alert ? '1.5px solid #f87171'         : '1.5px solid #334155';
        card.style.background  = alert ? 'rgba(127,29,29,0.80)'        : 'rgba(9,18,36,0.85)';
      }
    } else {
      psiEl.textContent = '--';
      psiEl.style.color = '#475569';
    }
    if (tempEl) tempEl.textContent = tempC > 0 ? tempC + '°C' : '--°C';
  }
  renderTyre('fl', s.tyre_pressure_fl, s.tyre_temp_fl);
  renderTyre('fr', s.tyre_pressure_fr, s.tyre_temp_fr);
  renderTyre('rl', s.tyre_pressure_rl, s.tyre_temp_rl);
  renderTyre('rr', s.tyre_pressure_rr, s.tyre_temp_rr);

  // Desde última partida (rolling)
  const r = s.rolling || {};
  setText('d-roll-dist', r.distance_km   > 0 ? f1(r.distance_km) + ' km' : '--');
  setText('d-roll-fuel', r.fuel_l        > 0 ? f2(r.fuel_l) + ' L'       : '--');
  setText('d-roll-kwh',  r.kwh_per_100km > 0 ? f1(r.kwh_per_100km)       : '--');
  setText('d-roll-kml',  r.km_per_l      > 0 ? f1(r.km_per_l)            : '--');
  setText('d-roll-cost', r.cost_brl      > 0 ? 'R$ ' + f2(r.cost_brl)   : '--');
  setClass('d-roll-kwh', eff(r.kwh_per_100km));
}

function renderTrip(id, t) {
  const p = id;
  setText(`${p}-dist`,      f1(t.distance_km) + ' km');
  setText(`${p}-time`,      fmtTripTime(t.time_sec));
  setText(`${p}-speed`,     f1(t.avg_speed_kmh));
  setText(`${p}-kwh100`,    t.kwh_per_100km > 0 ? f1(t.kwh_per_100km) : '--');
  setText(`${p}-kml`,       t.km_per_l    > 0 ? f1(t.km_per_l)     : '--');
  setText(`${p}-fuel`,      t.fuel_l      > 0 ? f2(t.fuel_l) + ' L' : '--');
  setText(`${p}-energy`,    t.energy_kwh  > 0 ? f2(t.energy_kwh)    : '--');
  setText(`${p}-regen`,     t.regen_kwh   > 0 ? f2(t.regen_kwh)     : '--');
  setText(`${p}-cost`,      t.cost_brl    > 0 ? 'R$ ' + f2(t.cost_brl) : '--');
  setText(`${p}-soc-start`, pct(t.soc_start));
  setText(`${p}-soc-now`,   pct(t.soc_current));
  setText(`${p}-tank-now`,  t.tank_now_l > 0 ? f1(t.tank_now_l) + ' L' : '--');
  setClass(`${p}-kwh100`, eff(t.kwh_per_100km));
}

// ── Recargas ──────────────────────────────────────────────────────────────────
function loadCharges() {
  if (cachedCharges !== null) { renderCharges(); return; }
  const list = document.getElementById('charges-list');
  list.innerHTML = '<div class="empty">Carregando...</div>';
  apiFetch('/api/charges')
    .then(r => r.json())
    .then(data => { cachedCharges = Array.isArray(data) ? data : []; renderCharges(); })
    .catch(() => { list.innerHTML = filterChipsHTML('charges') + '<div class="empty">Erro ao carregar.</div>'; });
}

function renderCharges() {
  const list = document.getElementById('charges-list');
  if (!list) return;
  const [startMs, endMs] = getFilterRange('charges');
  const charges = filterItems(cachedCharges || [], 'timestamp', startMs, endMs);
  const socColor = d => d >= 50 ? 'green' : d >= 25 ? 'teal' : 'muted';

  let html = filterChipsHTML('charges');
  if (!charges.length) {
    list.innerHTML = html + '<div class="empty">Nenhuma recarga no período.</div>';
    return;
  }

  const totalKwh = charges.reduce((s,c) => s + (c.energy_kwh   || 0), 0);
  const totalSec = charges.reduce((s,c) => s + (c.duration_sec || 0), 0);
  const avgPwr   = totalSec > 0 ? totalKwh / (totalSec / 3600) : 0;

  html += `<div class="charge-summary-card">
  <div class="card-title">Resumo — ${charges.length} sessão${charges.length !== 1 ? 'ões' : ''}</div>
  <div class="metrics-row">
    <div class="metric"><div class="metric-value teal sm">${f2(totalKwh)} kWh</div><div class="metric-label">total carregado</div></div>
    <div class="metric"><div class="metric-value muted sm">${fmtDur(totalSec)}</div><div class="metric-label">tempo total</div></div>
    <div class="metric"><div class="metric-value blue sm">${f1(avgPwr)} kW</div><div class="metric-label">pot. média</div></div>
  </div>
</div>`;

  html += charges.map(c => {
    const delta = (c.soc_end || 0) - (c.soc_start || 0);
    const col   = socColor(delta);
    return `<div class="trip-item">
  <div class="trip-header">
    <div><div class="trip-name">${fmtDate(c.timestamp)}</div></div>
    <span class="charge-kwh-badge">${f2(c.energy_kwh)} kWh</span>
  </div>
  <div class="trip-metrics">
    <div class="trip-metric"><div class="trip-metric-val" style="color:var(--teal)">${fmtDur(c.duration_sec)}</div><div class="trip-metric-lbl">duração</div></div>
    <div class="trip-metric"><div class="trip-metric-val" style="color:var(--blue)">${f1(c.avg_power_kw)} kW</div><div class="trip-metric-lbl">pot. média</div></div>
    <div class="trip-metric"><div class="trip-metric-val" style="color:var(--muted)">${pct(c.soc_start)}</div><div class="trip-metric-lbl">SOC início</div></div>
    <div class="trip-metric"><div class="trip-metric-val ${col}">${pct(c.soc_end)}</div><div class="trip-metric-lbl">SOC fim</div></div>
    <div class="trip-metric"><div class="trip-metric-val ${col}">+${delta.toFixed(0)}%</div><div class="trip-metric-lbl">Δ SOC</div></div>
  </div>
</div>`;
  }).join('');

  list.innerHTML = html;
}

// ── Histórico ─────────────────────────────────────────────────────────────────
function loadHistory() {
  // Sempre busca dados frescos ao abrir a aba (trips manuais e auto-trips podem ter chegado)
  cachedTrips     = null;
  cachedAutoTrips = null;
  const list = document.getElementById('hist-list');
  list.innerHTML = '<div class="empty">Carregando...</div>';
  Promise.all([
    apiFetch('/api/trips').then(r => r.json()).then(d => { cachedTrips = Array.isArray(d) ? d : []; }).catch(() => { cachedTrips = []; }),
    apiFetch('/api/autotrips').then(r => r.json()).then(d => { cachedAutoTrips = Array.isArray(d) ? d : []; }).catch(() => { cachedAutoTrips = []; }),
  ]).then(() => renderHistory()).catch(() => {
    list.innerHTML = filterChipsHTML('hist') + '<div class="empty">Erro ao carregar.</div>';
  });
}

function renderHistory() {
  const list = document.getElementById('hist-list');
  if (!list) return;
  const [filterStart, filterEnd] = getFilterRange('hist');
  const isFiltered = filterState.hist.active !== 'all';

  let trips;
  if (!isFiltered) {
    // Sem filtro: mostra trips manuais (Trip A/B salvos ao Zerar) em ordem cronológica
    trips = filterItems(cachedTrips || [], 'timestamp', filterStart, filterEnd);
  } else {
    // Com filtro: usa auto-trips (criados a cada P→D/R, muito mais granulares)
    // Os campos são camelCase vindos do Android: distKm, fuelL, netKwh, timeSec
    trips = (cachedAutoTrips || []).filter(t => {
      const ms = t.startMs || 0;
      return ms >= filterStart && ms <= filterEnd;
    }).map(t => ({
      // Normaliza para o formato esperado pelo card de renderização
      name:            t.name || '',
      label:           'Auto',
      timestamp:       t.startMs,
      distance_km:     t.distKm   || 0,
      fuel_l:          t.fuelL    || 0,
      kwh_per_100km:   t.distKm > 0.1 ? (t.netKwh / t.distKm * 100) : 0,
      km_per_l:        t.fuelL   > 0.001 ? (t.distKm / t.fuelL) : 0,
      net_kwh:         t.netKwh  || 0,
      regen_kwh:       t.regenKwh || 0,
      time_sec:        t.timeSec  || 0,
      total_cost_brl:  0,
    }));
  }

  let html = filterChipsHTML('hist');
  if (!trips.length) {
    const hint = isFiltered
      ? '<div class="empty">Nenhuma viagem automática no período.<br><small style="color:#5B7394">Auto-trips são criados a cada vez que o carro é colocado em marcha.</small></div>'
      : '<div class="empty">Nenhuma viagem no período.</div>';
    list.innerHTML = html + hint;
    return;
  }

  const totDist   = trips.reduce((s,t) => s + (t.distance_km    || 0), 0);
  const totFuel   = trips.reduce((s,t) => s + (t.fuel_l         || 0), 0);
  const totCost   = trips.reduce((s,t) => s + (t.total_cost_brl || 0), 0);
  const totNetKwh = trips.reduce((s,t) => {
    const d = t.distance_km||0, k = t.kwh_per_100km||0;
    return s + (k > 0 && d > 0 ? k * d / 100 : 0);
  }, 0);
  const avgKwh100 = totDist > 0.1   ? totNetKwh / totDist * 100 : 0;
  const avgKml    = totFuel > 0.001 ? totDist   / totFuel       : 0;

  html += `<div class="charge-summary-card" style="border-color:rgba(77,187,255,.2)">
  <div class="card-title">Resumo — ${trips.length} viagem${trips.length !== 1 ? 'ns' : ''}</div>
  <div class="metrics-row">
    <div class="metric"><div class="metric-value blue sm">${f1(totDist)} km</div><div class="metric-label">distância</div></div>
    <div class="metric"><div class="metric-value green sm">${avgKwh100 > 0 ? f1(avgKwh100) : '--'}</div><div class="metric-label">kWh/100km</div></div>
    <div class="metric"><div class="metric-value green sm">${avgKml > 0 ? f1(avgKml) : '--'}</div><div class="metric-label">km/L</div></div>
  </div>
  <div class="metrics-row" style="margin-top:4px">
    <div class="metric"><div class="metric-value orange sm">${f2(totFuel)} L</div><div class="metric-label">combustível</div></div>
    <div class="metric"><div class="metric-value teal sm">${totNetKwh > 0 ? f2(totNetKwh) + ' kWh' : '--'}</div><div class="metric-label">bat. consumida</div></div>
    <div class="metric"><div class="metric-value yellow sm">${totCost > 0 ? 'R$ ' + f2(totCost) : '--'}</div><div class="metric-label">custo</div></div>
  </div>
</div>`;

  html += trips.map(t => {
    const name = t.name || t.label || 'Viagem';
    const cost = t.total_cost_brl > 0 ? `<span class="trip-cost">R$ ${f2(t.total_cost_brl)}</span>` : '';
    const tsDisplay = typeof t.timestamp === 'number' ? fmtDate(new Date(t.timestamp).toISOString()) : fmtDate(t.timestamp);
    return `<div class="trip-item">
  <div class="trip-header">
    <div>
      <span class="trip-badge">${t.label || 'Trip'}</span>
      <div class="trip-name" style="margin-top:3px">${name}</div>
      <div class="trip-date">${tsDisplay}</div>
    </div>
    ${cost}
  </div>
  <div class="trip-metrics">
    <div class="trip-metric"><div class="trip-metric-val blue">${f1(t.distance_km)} km</div><div class="trip-metric-lbl">dist.</div></div>
    <div class="trip-metric"><div class="trip-metric-val green">${t.kwh_per_100km > 0 ? f1(t.kwh_per_100km) : '--'}</div><div class="trip-metric-lbl">kWh/100km</div></div>
    <div class="trip-metric"><div class="trip-metric-val green">${t.km_per_l > 0 ? f1(t.km_per_l) : '--'}</div><div class="trip-metric-lbl">km/L</div></div>
    <div class="trip-metric"><div class="trip-metric-val orange">${t.fuel_l > 0 ? f2(t.fuel_l) + ' L' : '--'}</div><div class="trip-metric-lbl">combust.</div></div>
    <div class="trip-metric"><div class="trip-metric-val" style="color:#5B7394">${fmtTripTime(t.time_sec)}</div><div class="trip-metric-lbl">duração</div></div>
  </div>
</div>`;
  }).join('');

  list.innerHTML = html;
}

// ── Auto-Trips ────────────────────────────────────────────────────────────────
let cachedAutoTrips = null;

function loadAutoTrips() {
  // Sempre recarrega ao abrir a aba — garante que dados novos apareçam após sync do carro
  cachedAutoTrips = null;
  // Limpa badge de notificação (se houver)
  document.querySelector('[data-panel="auto"] .tab-notif')?.remove();
  const list = document.getElementById('auto-list');
  list.innerHTML = '<div class="empty">Carregando...</div>';
  apiFetch('/api/autotrips')
    .then(r => r.json())
    .then(data => { cachedAutoTrips = Array.isArray(data) ? data : []; renderAutoTrips(); })
    .catch(() => { list.innerHTML = '<div class="empty">Erro ao carregar.</div>'; });
}

function renderAutoTrips() {
  const list = document.getElementById('auto-list');
  if (!list) return;

  const [filterStart, filterEnd] = getFilterRange('auto');
  const trips = filterItems(cachedAutoTrips || [], 'startMs', filterStart, filterEnd);

  let html = filterChipsHTML('auto');

  if (!trips.length) {
    list.innerHTML = html + '<div class="empty">Nenhuma viagem automática no período.</div>';
    return;
  }

  // Resumo — mesma estrutura 2 linhas do hist
  const { gas: priceGas, kwh: priceKwh } = getPrices();
  const totDist   = trips.reduce((s, t) => s + (t.distKm  || 0), 0);
  const totFuel   = trips.reduce((s, t) => s + (t.fuelL   || 0), 0);
  const totNetKwh = trips.reduce((s, t) => s + (t.netKwh  || 0), 0);
  const avgKwh100 = totDist > 0.1   ? totNetKwh / totDist * 100 : 0;
  const avgKmL    = totFuel > 0.001 ? totDist   / totFuel       : 0;
  const totCost   = (priceGas > 0 || priceKwh > 0)
    ? totFuel * priceGas + totNetKwh * priceKwh : 0;

  html += `<div class="charge-summary-card" style="border-color:rgba(77,187,255,.2)">
  <div class="card-title">Resumo — ${trips.length} viagem${trips.length !== 1 ? 'ns' : ''}</div>
  <div class="metrics-row">
    <div class="metric"><div class="metric-value blue sm">${f1(totDist)} km</div><div class="metric-label">distância</div></div>
    <div class="metric"><div class="metric-value green sm">${avgKwh100 > 0 ? f1(avgKwh100) : '--'}</div><div class="metric-label">kWh/100km</div></div>
    <div class="metric"><div class="metric-value green sm">${avgKmL > 0 ? f1(avgKmL) : '--'}</div><div class="metric-label">km/L</div></div>
  </div>
  <div class="metrics-row" style="margin-top:4px">
    <div class="metric"><div class="metric-value orange sm">${totFuel > 0.001 ? f2(totFuel) + ' L' : '--'}</div><div class="metric-label">combustível</div></div>
    <div class="metric"><div class="metric-value teal sm">${totNetKwh > 0.01 ? f2(totNetKwh) + ' kWh' : '--'}</div><div class="metric-label">bat. consumida</div></div>
    <div class="metric"><div class="metric-value yellow sm">${totCost > 0 ? 'R$ ' + f2(totCost) : '--'}</div><div class="metric-label">custo</div></div>
  </div>
</div>`;

  html += trips.map(t => {
    const startDate  = fmtDate(t.startMs);
    const dur        = fmtDur(Math.round((t.endMs - t.startMs) / 1000));
    const distKm     = t.distKm      > 0    ? f1(t.distKm) + ' km'  : '--';
    const netKwh     = t.netKwh      > 0    ? f2(t.netKwh) + ' kWh' : '--';
    const fuelL      = t.fuelL       > 0    ? f2(t.fuelL)  + ' L'   : '--';
    const socDelta   = t.startSocPct > 0    ? `${t.startSocPct.toFixed(0)}%→${t.endSocPct.toFixed(0)}%` : '--';
    const maxSpd     = t.maxSpeedKmh > 0    ? `${Math.round(t.maxSpeedKmh)} km/h` : null;
    const tempStr    = t.outsideTempC != null ? `${Math.round(t.outsideTempC)}°C`  : null;
    const hasGps     = t.startLat && (t.startLat !== 0 || t.startLng !== 0);
    const mapsUrl    = hasGps ? `https://www.google.com/maps/dir/${t.startLat},${t.startLng}/${t.endLat},${t.endLng}` : null;
    const extraRow   = (maxSpd || tempStr) ? `
  <div class="trip-metrics" style="margin-top:4px">
    ${maxSpd  ? `<div class="trip-metric"><div class="trip-metric-val">${maxSpd}</div><div class="trip-metric-lbl">vel. máx.</div></div>` : ''}
    ${tempStr ? `<div class="trip-metric"><div class="trip-metric-val blue">${tempStr}</div><div class="trip-metric-lbl">temp. ext.</div></div>` : ''}
    ${mapsUrl ? `<div class="trip-metric"><a href="${mapsUrl}" target="_blank" style="color:#60a5fa;text-decoration:none;font-size:18px">📍</a><div class="trip-metric-lbl">mapa</div></div>` : ''}
  </div>` : (mapsUrl ? `<div style="text-align:right;margin-top:2px"><a href="${mapsUrl}" target="_blank" style="color:#60a5fa;font-size:11px">📍 mapa</a></div>` : '');
    const tripCost = (priceGas > 0 || priceKwh > 0)
      ? (t.fuelL || 0) * priceGas + (t.netKwh || 0) * priceKwh : 0;
    const costStr = tripCost > 0 ? `<span class="trip-cost">R$ ${f2(tripCost)}</span>` : '';
    return `<div class="trip-item">
  <div class="trip-header">
    <div>
      <div class="trip-name">${startDate}</div>
      <div class="trip-date">${dur}</div>
    </div>
    <div style="display:flex;flex-direction:column;align-items:flex-end;gap:4px">
      ${costStr}
      <button class="charge-badge" style="cursor:pointer;border:none" onclick="openTripDetail('${t.tripId}')">🗺 Ver rota</button>
    </div>
  </div>
  <div class="trip-metrics">
    <div class="trip-metric"><div class="trip-metric-val blue">${distKm}</div><div class="trip-metric-lbl">dist.</div></div>
    <div class="trip-metric"><div class="trip-metric-val green">${netKwh}</div><div class="trip-metric-lbl">kWh liq.</div></div>
    <div class="trip-metric"><div class="trip-metric-val orange">${fuelL}</div><div class="trip-metric-lbl">combust.</div></div>
    <div class="trip-metric"><div class="trip-metric-val teal">${socDelta}</div><div class="trip-metric-lbl">SOC</div></div>
  </div>${extraRow}
</div>`;
  }).join('');

  list.innerHTML = html;
}

// ── Dashboard map — última localização do carro ───────────────────────────────
let dashMap         = null;
let dashMarker      = null;

function initDashMap() {
  apiFetch('/api/location')
    .then(r => r.json())
    .then(data => {
      if (!data.lat || !data.lng) return;   // sem GPS disponível
      const card = document.getElementById('d-map-card');
      if (card) card.style.display = '';
      const el = document.getElementById('d-car-map');
      if (!el) return;

      // Cria o mapa só uma vez
      if (!dashMap) {
        dashMap = L.map(el, {
          zoomControl:       false,
          attributionControl: false,
          dragging:          true,
          scrollWheelZoom:   false,
        });
        L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 18 }).addTo(dashMap);
      }

      const pos = [data.lat, data.lng];
      dashMap.setView(pos, 15);

      if (dashMarker) dashMarker.setLatLng(pos);
      else {
        dashMarker = L.circleMarker(pos, {
          radius: 9, fillColor: '#39FF88', fillOpacity: 1, color: '#fff', weight: 2,
        }).addTo(dashMap);
        dashMarker.bindPopup('🚗 Haval H6 PHEV34');
      }

      if (data.ts) {
        setText('d-map-ts', relTime(data.ts) + ' atrás');
      }

      // Reverse geocoding — endereço da última posição (Nominatim / OSM)
      fetch(`https://nominatim.openstreetmap.org/reverse?format=json&lat=${data.lat}&lon=${data.lng}&zoom=16`)
        .then(r => r.json())
        .then(geo => {
          const a = geo.address || {};
          const parts = [
            a.road,
            a.suburb || a.neighbourhood || a.quarter,
            a.city   || a.town || a.village || a.municipality,
          ].filter(Boolean);
          const label = parts.length ? parts.join(', ')
                      : (geo.display_name || '').split(',').slice(0, 2).join(',').trim();
          setText('d-map-address', label);
        })
        .catch(() => {});
    })
    .catch(() => {});   // sem localização — mapa permanece oculto
}

// ── Trip detail: mapa Leaflet + gráficos Chart.js ─────────────────────────────
let leafletMap      = null;
let routePolyline   = null;
let playbackMarker  = null;
let chartSpd        = null;
let chartEv         = null;
let chartRpm        = null;
let currentSamples  = [];

// HTML original do body do detalhe — restaurado a cada fechamento para garantir
// que o #trip-map e os canvases existam frescos na próxima abertura
let tripBodyOriginalHTML = null;
window.addEventListener('load', () => {
  const body = document.getElementById('trip-detail-body');
  if (body) tripBodyOriginalHTML = body.innerHTML;
});

function openTripDetail(tripId) {
  const overlay = document.getElementById('trip-detail');
  overlay.style.display = 'flex';

  // Título
  const trip = (cachedAutoTrips || []).find(t => t.tripId === tripId);
  const title = trip ? fmtDate(trip.startMs) + ' · ' + fmtDur(Math.round((trip.endMs - trip.startMs)/1000)) : tripId;
  document.getElementById('trip-detail-title').textContent = title;

  // Resetar slider
  const slider = document.getElementById('playback-slider');
  slider.value = 0;

  apiFetch(`/api/telemetry/${tripId}`)
    .then(r => r.json())
    .then(data => {
      currentSamples = data.samples || [];
      if (!currentSamples.length) {
        document.getElementById('trip-detail-body').innerHTML =
          '<div class="empty" style="padding:40px">Nenhuma amostra de telemetria disponível.</div>';
        return;
      }
      slider.max   = currentSamples.length - 1;
      slider.value = 0;
      initTripMap(currentSamples);
      initTripCharts(currentSamples);
      onPlaybackMove(0);
    })
    .catch(() => {
      document.getElementById('trip-detail-body').innerHTML =
        '<div class="empty" style="padding:40px">Erro ao carregar telemetria.</div>';
    });
}

function closeTripDetail() {
  document.getElementById('trip-detail').style.display = 'none';
  // Destruir instâncias para liberar memória
  if (leafletMap) { leafletMap.remove(); leafletMap = null; }
  if (chartSpd)   { chartSpd.destroy();  chartSpd  = null; }
  if (chartEv)    { chartEv.destroy();   chartEv   = null; }
  if (chartRpm)   { chartRpm.destroy();  chartRpm  = null; }
  routePolyline  = null;
  playbackMarker = null;
  currentSamples = [];
  // Restaura o HTML original do body — garante que #trip-map e canvases
  // existam frescos na próxima abertura (evita erro de Leaflet + canvases sujos)
  const body = document.getElementById('trip-detail-body');
  if (body && tripBodyOriginalHTML) body.innerHTML = tripBodyOriginalHTML;
}

function initTripMap(samples) {
  const mapEl = document.getElementById('trip-map');
  if (leafletMap) { leafletMap.remove(); leafletMap = null; }

  // Filtra amostras com GPS válido
  const gpsPoints = samples.filter(s => s.lat !== 0 || s.lng !== 0);

  leafletMap = L.map(mapEl, { zoomControl: true, attributionControl: false });
  L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
    maxZoom: 19,
  }).addTo(leafletMap);

  if (gpsPoints.length < 2) {
    leafletMap.setView([-15.78, -47.93], 4); // Brasil
    L.popup().setLatLng([-15.78, -47.93])
      .setContent('<b style="color:#333">GPS indisponível nesta viagem</b>')
      .openOn(leafletMap);
    return;
  }

  // Polyline colorida por velocidade (verde < 40 · amarelo < 80 · laranja < 120 · vermelho ≥ 120)
  const spdColor = spd => spd < 40 ? '#39FF88' : spd < 80 ? '#FFD60A' : spd < 120 ? '#FF5F1F' : '#FF5555';
  for (let i = 1; i < gpsPoints.length; i++) {
    const a = gpsPoints[i-1], b = gpsPoints[i];
    L.polyline([[a.lat, a.lng],[b.lat, b.lng]], { color: spdColor(a.spd), weight: 4, opacity: 0.85 }).addTo(leafletMap);
  }

  // Marcador de início (verde) e fim (vermelho)
  const first = gpsPoints[0], last = gpsPoints[gpsPoints.length-1];
  const iconSvg = (color, label) => L.divIcon({
    html: `<div style="width:22px;height:22px;border-radius:50%;background:${color};border:2px solid #fff;display:flex;align-items:center;justify-content:center;font-size:9px;font-weight:700;color:#000">${label}</div>`,
    iconSize: [22,22], iconAnchor: [11,11],
  });
  L.marker([first.lat, first.lng], { icon: iconSvg('#39FF88','S') }).addTo(leafletMap);
  L.marker([last.lat,  last.lng],  { icon: iconSvg('#FF5555','F') }).addTo(leafletMap);

  // Marcador de playback (azul, começa no início)
  playbackMarker = L.circleMarker([first.lat, first.lng], {
    radius: 8, fillColor: '#4DBBFF', fillOpacity: 1, color: '#fff', weight: 2,
  }).addTo(leafletMap);

  // Ajusta zoom para o trajeto
  const bounds = L.latLngBounds(gpsPoints.map(s => [s.lat, s.lng]));
  leafletMap.fitBounds(bounds, { padding: [20, 20] });
  routePolyline = gpsPoints;
}

function initTripCharts(samples) {
  const labels = samples.map(s => s.t);
  const mkChart = (id, dataset, borderColor, yLabel) => {
    const ctx = document.getElementById(id).getContext('2d');
    return new Chart(ctx, {
      type: 'line',
      data: { labels, datasets: [{ data: dataset, borderColor, borderWidth: 1.5, pointRadius: 0, fill: false, tension: 0.2 }] },
      options: {
        animation: false,
        responsive: true, maintainAspectRatio: false,
        scales: {
          x: { display: false },
          y: {
            display: true,
            ticks: { color: '#5B7394', font: { size: 9 }, maxTicksLimit: 4 },
            grid:  { color: '#0F1520' },
          },
        },
        plugins: { legend: { display: false }, tooltip: { enabled: false } },
      },
    });
  };

  if (chartSpd)  chartSpd.destroy();
  if (chartEv)   chartEv.destroy();
  if (chartRpm)  chartRpm.destroy();

  chartSpd = mkChart('chart-spd', samples.map(s => s.spd),  '#4DBBFF', 'km/h');
  chartEv  = mkChart('chart-ev',  samples.map(s => s.evKw), '#39FF88', 'kW');
  chartRpm = mkChart('chart-rpm', samples.map(s => s.rpm),  '#FF5F1F', 'RPM');
}

function onPlaybackMove(idx) {
  const i = parseInt(idx, 10);
  if (!currentSamples.length || i >= currentSamples.length) return;
  const s = currentSamples[i];

  // Snapshot de valores
  const spdEl = document.getElementById('snap-spd');
  if (spdEl) {
    spdEl.textContent = f1(s.spd) + ' km/h';
    const spd = s.spd || 0;
    spdEl.className = 'snap-val ' + (spd > 120 ? 'red' : spd > 80 ? 'orange' : spd > 60 ? 'yellow' : 'green');
  }
  document.getElementById('snap-ev').textContent   = f1(s.evKw) + ' kW';
  document.getElementById('snap-rpm').textContent  = s.rpm + ' rpm';
  const mm = Math.floor(s.t / 60), ss = s.t % 60;
  document.getElementById('snap-time').textContent = `${String(mm).padStart(2,'0')}'${String(ss).padStart(2,'0')}"`;

  // Marcador no mapa
  if (playbackMarker && (s.lat !== 0 || s.lng !== 0)) {
    playbackMarker.setLatLng([s.lat, s.lng]);
  }

  // Linha vertical nos gráficos via updateChart
  [chartSpd, chartEv, chartRpm].forEach(ch => {
    if (!ch) return;
    // Remove annotation anterior e redesenha cursor via dataset secundário
    if (!ch.data.datasets[1]) {
      ch.data.datasets.push({
        data: ch.data.labels.map((_, li) => li === i ? ch.data.datasets[0].data[i] : null),
        borderColor: 'rgba(255,255,255,0.4)',
        borderWidth: 1,
        pointRadius: ch.data.labels.map((_, li) => li === i ? 4 : 0),
        pointBackgroundColor: '#fff',
        fill: false, tension: 0,
      });
    } else {
      ch.data.datasets[1].data = ch.data.labels.map((_, li) => li === i ? ch.data.datasets[0].data[li] : null);
      ch.data.datasets[1].pointRadius = ch.data.labels.map((_, li) => li === i ? 4 : 0);
    }
    ch.update('none');
  });
}

// ── Inicialização ─────────────────────────────────────────────────────────────

// Tenta restaurar último estado do cache (offline)
try {
  const cached = localStorage.getItem('ecotrip_state');
  if (cached) {
    const { state: cachedState, ts } = JSON.parse(cached);
    deepMerge(state, cachedState);
    lastUpdateMs = ts;
    renderAll();
  }
} catch(_) {}

// Inicia conexão; se o servidor recusar por auth, o WS fecha com 4001 e mostramos o login
connect();
tickInterval = setInterval(tickLastUpdate, 1000);
tickLastUpdate();

// Carrega localização do carro no mapa do dashboard (requer Leaflet carregado)
window.addEventListener('load', () => { setTimeout(initDashMap, 500); });

// ── Preços (gasolina + energia) — vêm do app Android via MQTT ────────────────

function getPrices() {
  return {
    gas: state.price_gas_per_l || 0,
    kwh: state.price_kwh       || 0,
  };
}

// ── Admin / Configurações ─────────────────────────────────────────────────────

function adminSetStatus(msg, ok) {
  const el = document.getElementById('admin-status');
  el.textContent = msg;
  el.style.color = ok === true ? '#4ade80' : ok === false ? '#f87171' : '#94a3b8';
}

async function adminAction(path, label) {
  adminSetStatus('⏳ ' + label + '…', null);
  try {
    const r    = await apiFetch(path, { method: 'POST', headers: { 'Content-Type': 'application/json' } });
    const data = await r.json().catch(() => ({}));
    if (r.ok && data.ok) {
      adminSetStatus('✓ ' + (data.msg || 'OK'), true);
    } else {
      adminSetStatus('✗ ' + (data.error || `HTTP ${r.status}`), false);
    }
  } catch (e) {
    if (e.message !== 'unauthorized')
      adminSetStatus('✗ Sem resposta — servidor pode estar reiniciando…', false);
  }
}

function adminRestart() { adminAction('/api/admin/restart', 'Reiniciando'); }
function adminUpdate()  { adminAction('/api/admin/update',  'Atualizando'); }

function adminClearHistory() {
  if (!confirm('Apagar todo o histórico do servidor?\n(trips manuais, auto-trips e recargas)\n\nEssa ação não pode ser desfeita.')) return;
  adminAction('/api/admin/clear-history', 'Apagando histórico');
}

function adminLogout() {
  localStorage.removeItem('bridge_token');
  bridgeToken = '';
  ws?.close();
  showLogin();
}

function togglePwVisibility(inputId, btn) {
  const input = document.getElementById(inputId);
  if (!input) return;
  const hidden = input.type === 'password';
  input.type = hidden ? 'text' : 'password';
  btn.textContent = hidden ? '🙈' : '👁';
}

function setCpStatus(msg, ok) {
  const el = document.getElementById('cp-status');
  if (el) { el.textContent = msg; el.style.color = ok ? '#4ade80' : ok === false ? '#f87171' : '#94a3b8'; }
}

async function changePassword() {
  const newPw  = (document.getElementById('cp-new')?.value     || '').trim();
  const confPw = (document.getElementById('cp-confirm')?.value || '').trim();
  if (!newPw)           { setCpStatus('Digite a nova senha.', false); return; }
  if (newPw !== confPw) { setCpStatus('Senhas não conferem.', false); return; }
  setCpStatus('Alterando…', null);
  try {
    const newHash = await sha256hex(newPw);
    const r    = await apiFetch('/api/admin/change-password', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ newHash }),
    }, true /* não redireciona para login em 401 */);
    const data = await r.json().catch(() => ({}));
    if (r.ok && data.ok) {
      // Atualiza token salvo localmente com o novo hash
      bridgeToken = newHash;
      localStorage.setItem('bridge_token', newHash);
      document.getElementById('cp-new').value     = '';
      document.getElementById('cp-confirm').value = '';
      setCpStatus('✓ Senha alterada com sucesso.', true);
    } else {
      setCpStatus('✗ ' + (data.error || `HTTP ${r.status}`), false);
    }
  } catch (e) {
    setCpStatus('✗ ' + (e.message === 'unauthorized' ? 'Sessão expirada — entre novamente.' : 'Erro ao comunicar com o servidor.'), false);
  }
}

// ── Remote Action Helpers (modal + toast + fetch) ────────────────────────────
let _remoteCb         = null;
let _remoteToastTimer = null;

function openRemoteModal({ title, msg, btnColor, onConfirm }) {
  const t = document.getElementById('d-remote-modal-title');
  const m = document.getElementById('d-remote-modal-msg');
  const b = document.getElementById('d-remote-confirm-btn');
  if (t) t.textContent = title;
  if (m) m.textContent = msg;
  if (b) b.style.background = btnColor || '#22c55e';
  _remoteCb = onConfirm || null;
  const modal = document.getElementById('d-remote-modal');
  if (modal) modal.style.display = 'flex';
}

window.remoteModalCancel = function() {
  const modal = document.getElementById('d-remote-modal');
  if (modal) modal.style.display = 'none';
  _remoteCb = null;
};

window.remoteModalConfirm = function() {
  const modal = document.getElementById('d-remote-modal');
  if (modal) modal.style.display = 'none';
  const cb = _remoteCb;
  _remoteCb = null;
  cb?.();
};

function showToast(msg) {
  const el = document.getElementById('d-toast');
  if (!el) return;
  el.textContent   = msg;
  el.style.opacity = '1';
  if (_remoteToastTimer) clearTimeout(_remoteToastTimer);
  _remoteToastTimer = setTimeout(() => { el.style.opacity = '0'; }, 3000);
}
window.showToast = showToast;

async function sendRemoteAction(action, successMsg) {
  showToast('Enviando comando…');
  try {
    const r    = await apiFetch(`/api/action/${action}`, { method: 'POST' });
    const data = await r.json().catch(() => ({}));
    if (r.ok && data.ok) {
      showToast('✓ ' + successMsg);
      if (navigator.vibrate) navigator.vibrate(80);
    } else {
      showToast('✗ ' + (data.error || `Erro ${r.status}`));
    }
  } catch (err) {
    showToast('✗ ' + (err.message === 'unauthorized' ? 'Sem permissão' : 'Falha ao enviar'));
  }
}

// ── Generic remote action (actions tab) ──────────────────────────────────────
window.remoteAction = function(action, title, msg, btnColor) {
  openRemoteModal({
    title,
    msg,
    btnColor: btnColor || '#22c55e',
    onConfirm: () => sendRemoteAction(action, title.replace('?', '')),
  });
};

// ── Engine — toque para ligar/desligar remotamente ───────────────────────────
window.engineClick = function() {
  const eng = state.engine_state;
  const dbg = document.getElementById('d-remote-debug');
  if (dbg) dbg.textContent = `engine_state=${eng} @ ${new Date().toLocaleTimeString('pt-BR')}`;
  if (eng == null || (eng !== '0' && eng !== 0 && eng !== '1' && eng !== 1)) {
    showToast('Estado do motor ainda não recebido');
    return;
  }
  const engOn = eng === '1' || eng === 1;
  openRemoteModal({
    title:     engOn ? '⚙️ Desligar motor?' : '⚙️ Ligar motor?',
    msg:       engOn ? 'O motor térmico será desligado remotamente.'
                     : 'O motor térmico será ligado remotamente.',
    btnColor:  engOn ? '#ef4444' : '#22c55e',
    onConfirm: () => sendRemoteAction(
      engOn ? 'engine_off' : 'engine_on',
      engOn ? 'Comando enviado: desligar' : 'Comando enviado: ligar',
    ),
  });
};

// ── Lock — toque para trancar/destrancar remotamente ─────────────────────────
window.lockClick = function() {
  const lck = state.lock_state;
  const dbg = document.getElementById('d-remote-debug');
  if (dbg) dbg.textContent = `lock_state=${lck} @ ${new Date().toLocaleTimeString('pt-BR')}`;
  if (lck == null || (lck !== 'off' && lck !== 'on')) {
    showToast('Estado da trava ainda não recebido');
    return;
  }
  // 'off' = trancado (trava fechada = ícone 🔒)
  const locked = lck === 'off';
  openRemoteModal({
    title:     locked ? '🔓 Destrancar portas?' : '🔒 Trancar portas?',
    msg:       locked ? 'As portas serão destrancadas remotamente.'
                      : 'As portas serão trancadas remotamente.',
    btnColor:  locked ? '#f97316' : '#39FF88',
    onConfirm: () => sendRemoteAction(
      locked ? 'lock_open' : 'lock_close',
      locked ? 'Portas destrancadas' : 'Portas trancadas',
    ),
  });
};
