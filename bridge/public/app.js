'use strict';

// ── Estado local ──────────────────────────────────────────────────────────────
let state = {};
let lastUpdateMs = null;
let wsRetryDelay = 1000;
let ws = null;
let tickInterval = null;

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
  navigator.serviceWorker.register('/sw.js').then(async () => {
    // Tenta subscrever push sem bloquear a inicialização
    try { await subscribePush(); } catch (_) {}
  }).catch(() => {});
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
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(`${proto}//${location.host}/ws`);

  ws.onopen = () => {
    console.log('WS conectado');
    wsRetryDelay = 1000;
    setStatus('connecting');
  };

  ws.onmessage = (evt) => {
    try {
      const msg = JSON.parse(evt.data);
      if (msg.type === 'full_state' || msg.type === 'update') {
        deepMerge(state, msg.data);
        lastUpdateMs = Date.now();
        renderAll();
        try { localStorage.setItem('ecotrip_state', JSON.stringify({ state, ts: lastUpdateMs })); } catch(_) {}
      }
    } catch (e) { console.error('WS parse error', e); }
  };

  ws.onerror  = () => {};
  ws.onclose  = () => {
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
  life:    { active: 'all', customFrom: '', customTo: '' },
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
  if (tabId === 'life')    renderLifetimeTab();
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
  // Lifetime: atualiza live só se a aba estiver ativa e sem filtro aplicado
  const lifePanel = document.getElementById('panel-life');
  if (lifePanel && lifePanel.classList.contains('active') && filterState.life.active === 'all') {
    renderLifetimeTab();
  }
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
  setText('d-inside',  s.inside_temp  ? f1(s.inside_temp)  + '°C' : '--');
  setText('d-outside', s.outside_temp ? f1(s.outside_temp) + '°C' : '--');

  // SOC
  const soc = s.soc_pct || s.trip_a?.soc_current || 0;
  setText('d-soc', pct(soc));
  const socBar = document.getElementById('d-soc-bar');
  if (socBar) socBar.style.width = Math.max(0, Math.min(100, soc)) + '%';

  // Autonomia elétrica estimada (bateria útil: SOC atual → 12% mínimo, ~25,8 kWh brutos)
  const BATT_KWH = 25.8, EV_MIN_SOC = 12;
  const avgKwh100 = s.rolling?.kwh_per_100km > 2 ? s.rolling.kwh_per_100km
                  : s.trip_a?.kwh_per_100km  > 2 ? s.trip_a.kwh_per_100km : 18;
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

  // Motor — ícone power: cinza=desligado, vermelho=ligado
  const eng      = s.engine_state;
  const engIcon  = document.getElementById('d-engine-icon');
  const engLabel = document.getElementById('d-engine-label');
  if (engIcon && engLabel) {
    if (eng === '1' || eng === 1) {
      engIcon.style.color  = 'var(--red)';
      engLabel.textContent = 'Ligado';
      engLabel.style.color = 'var(--red)';
    } else if (eng === '0' || eng === 0) {
      engIcon.style.color  = 'var(--muted)';
      engLabel.textContent = 'Desligado';
      engLabel.style.color = 'var(--muted)';
    } else {
      engIcon.style.color  = 'var(--muted)';
      engLabel.textContent = '--';
      engLabel.style.color = 'var(--muted)';
    }
  }

  // Trava — ícone porta de carro: fechada=teal, aberta=laranja
  const lck       = s.lock_state;
  const lockIcon  = document.getElementById('d-lock-icon');
  const lockLabel = document.getElementById('d-lock-label');
  const dClosed   = document.getElementById('d-door-closed');
  const dOpen     = document.getElementById('d-door-open');
  if (lockIcon && lockLabel) {
    if (lck === 'off') {
      lockIcon.style.color  = 'var(--teal)';
      lockLabel.textContent = 'Trancado';
      lockLabel.style.color = 'var(--teal)';
      if (dClosed) dClosed.style.display = '';
      if (dOpen)   dOpen.style.display   = 'none';
    } else if (lck === 'on') {
      lockIcon.style.color  = 'var(--orange)';
      lockLabel.textContent = 'Aberto';
      lockLabel.style.color = 'var(--orange)';
      if (dClosed) dClosed.style.display = 'none';
      if (dOpen)   dOpen.style.display   = '';
    } else {
      lockIcon.style.color  = 'var(--muted)';
      lockLabel.textContent = '--';
      lockLabel.style.color = 'var(--muted)';
      if (dClosed) dClosed.style.display = '';
      if (dOpen)   dOpen.style.display   = 'none';
    }
  }

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
  fetch('/api/charges')
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
    fetch('/api/trips').then(r => r.json()).then(d => { cachedTrips = Array.isArray(d) ? d : []; }).catch(() => { cachedTrips = []; }),
    fetch('/api/autotrips').then(r => r.json()).then(d => { cachedAutoTrips = Array.isArray(d) ? d : []; }).catch(() => { cachedAutoTrips = []; }),
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
    <div class="metric"><div class="metric-value orange sm">${f2(totFuel)} L</div><div class="metric-label">combustível</div></div>
    <div class="metric"><div class="metric-value green sm">${avgKwh100 > 0 ? f1(avgKwh100) : '--'}</div><div class="metric-label">kWh/100km</div></div>
    <div class="metric"><div class="metric-value green sm">${avgKml > 0 ? f1(avgKml) : '--'}</div><div class="metric-label">km/L</div></div>
    ${totCost > 0 ? `<div class="metric"><div class="metric-value yellow sm">R$ ${f2(totCost)}</div><div class="metric-label">custo total</div></div>` : ''}
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

// ── Lifetime ──────────────────────────────────────────────────────────────────
let cachedLifeSnapshots = null;

function loadLifetime() {
  cachedAutoTrips    = null;
  cachedLifeSnapshots = null;
  renderLifetimeTab();
  // Pré-carrega recargas
  if (cachedCharges === null) {
    fetch('/api/charges').then(r=>r.json()).then(d=>{cachedCharges=Array.isArray(d)?d:[];}).catch(()=>{});
  }
  // Pré-carrega snapshots (fonte primária dos filtros — funciona sem sync de auto-trips)
  fetch('/api/lifetime/snapshots').then(r=>r.json()).then(d=>{
    cachedLifeSnapshots = Array.isArray(d) ? d : [];
    if (filterState.life.active !== 'all') renderLifetimeTab();
  }).catch(()=>{ cachedLifeSnapshots = []; });
  // Pré-carrega auto-trips também (dados extras se sincronizados)
  fetch('/api/autotrips').then(r=>r.json()).then(d=>{
    cachedAutoTrips = Array.isArray(d) ? d : [];
  }).catch(()=>{ cachedAutoTrips = []; });
}

function renderLifetimeTab() {
  const list = document.getElementById('life-list');
  if (!list) return;

  const isFiltered = filterState.life.active !== 'all';
  let html = filterChipsHTML('life');

  if (!isFiltered) {
    // ── Vista live: dados MQTT em tempo real ──────────────────────────────────
    const l = state.lifetime || {};
    html += `<div class="card">
  <div class="card-title">Lifetime — Total acumulado</div>
  <div class="metrics-row">
    <div class="metric"><div class="metric-value blue lg">${f1(l.distance_km)} km</div><div class="metric-label">km totais</div></div>
    <div class="metric"><div class="metric-value muted sm">${fmtTripTime(l.time_sec)}</div><div class="metric-label">Tempo condução</div></div>
  </div>
  <div class="divider"></div>
  <div class="metrics-row">
    <div class="metric"><div class="metric-value green">${l.net_kwh   > 0 ? f2(l.net_kwh)   + ' kWh' : '--'}</div><div class="metric-label">kWh líquido</div></div>
    <div class="metric"><div class="metric-value teal">${l.regen_kwh  > 0 ? f2(l.regen_kwh)  + ' kWh' : '--'}</div><div class="metric-label">kWh regen.</div></div>
    <div class="metric"><div class="metric-value orange">${l.fuel_l   > 0 ? f2(l.fuel_l)    + ' L'   : '--'}</div><div class="metric-label">L combustível</div></div>
  </div>
  <div class="divider"></div>
  <div class="metrics-row">
    <div class="metric"><div class="metric-value teal">${l.charge_kwh > 0 ? f2(l.charge_kwh) + ' kWh' : '--'}</div><div class="metric-label">kWh carregados</div></div>
    <div class="metric"><div class="metric-value muted">${l.charge_sec || '--'}</div><div class="metric-label">Tempo recarga</div></div>
    <div class="metric"><div class="metric-value yellow">${l.cost_brl   > 0 ? 'R$ ' + f2(l.cost_brl) : '--'}</div><div class="metric-label">R$ total est.</div></div>
  </div>
</div>`;
  } else {
    // ── Vista filtrada: usa snapshots do lifetime como baseline (funciona sem sync)
    // Snapshots são salvos no bridge a cada 5 min quando dados MQTT chegam.
    // Lógica: delta = current_live - snapshot_mais_recente_antes_do_período
    const [filterStart, filterEnd] = getFilterRange('life');

    // Aguarda snapshots e recargas carregarem
    if (cachedLifeSnapshots === null || cachedCharges === null) {
      html += '<div class="empty">Carregando dados...</div>';
      list.innerHTML = html;
      Promise.all([
        cachedLifeSnapshots === null
          ? fetch('/api/lifetime/snapshots').then(r=>r.json()).then(d=>{cachedLifeSnapshots=Array.isArray(d)?d:[];})
          : Promise.resolve(),
        cachedCharges === null
          ? fetch('/api/charges').then(r=>r.json()).then(d=>{cachedCharges=Array.isArray(d)?d:[];})
          : Promise.resolve(),
      ]).then(() => renderLifetimeTab()).catch(() => {});
      return;
    }

    // Baseline = snapshot mais recente ANTES do início do período
    const snaps = cachedLifeSnapshots || [];
    const baseline = snaps.filter(s => s.ts <= filterStart).sort((a,b) => b.ts - a.ts)[0];

    const cur = state.lifetime || {};
    const charges = filterItems(cachedCharges || [], 'timestamp', filterStart, filterEnd);

    if (!baseline) {
      // Sem snapshot antes do período: bridge acabou de ser instalado/iniciado
      const chargeKwh = charges.reduce((s,c) => s + (c.energy_kwh   || 0), 0);
      const chargeSec = charges.reduce((s,c) => s + (c.duration_sec || 0), 0);
      const avgChgKw  = chargeSec > 0 ? chargeKwh / (chargeSec / 3600) : 0;
      html += `<div class="card">
  <div class="card-title" style="color:var(--yellow)">⏳ Coletando dados…</div>
  <div style="font-size:12px;color:var(--text-secondary);margin-bottom:8px">
    Os snapshots são gerados a cada 5 min com o carro conectado.<br>
    Em breve os filtros mostrarão os dados de condução.
  </div>`;
      if (chargeKwh > 0) {
        html += `<div class="divider"></div>
  <div class="metrics-row">
    <div class="metric"><div class="metric-value teal">${f2(chargeKwh)} kWh</div><div class="metric-label">kWh carregados</div></div>
    <div class="metric"><div class="metric-value muted sm">${fmtDur(chargeSec)}</div><div class="metric-label">tempo recarga</div></div>
    <div class="metric"><div class="metric-value blue">${avgChgKw > 0 ? f1(avgChgKw) + ' kW' : '--'}</div><div class="metric-label">pot. média</div></div>
  </div>`;
      }
      html += '</div>';
      list.innerHTML = html;
      return;
    }

    // Delta condução = current_live - baseline
    const distKm   = Math.max(0, (cur.distance_km || 0) - baseline.distance_km);
    const netKwh   = Math.max(0, (cur.net_kwh     || 0) - baseline.net_kwh);
    const regenKwh = Math.max(0, (cur.regen_kwh   || 0) - baseline.regen_kwh);
    const fuelL    = Math.max(0, (cur.fuel_l      || 0) - baseline.fuel_l);
    const timeSec  = Math.max(0, (Number(cur.time_sec) || 0) - baseline.time_sec);

    const chargeKwh = charges.reduce((s,c) => s + (c.energy_kwh   || 0), 0);
    const chargeSec = charges.reduce((s,c) => s + (c.duration_sec || 0), 0);

    const avgKwh100 = distKm    > 0.1   ? netKwh    / distKm * 100      : 0;
    const avgKml    = fuelL     > 0.001 ? distKm    / fuelL             : 0;
    const avgSpd    = timeSec   > 0     ? distKm    / (timeSec / 3600)  : 0;
    const avgChgKw  = chargeSec > 0     ? chargeKwh / (chargeSec / 3600): 0;

    const baseDate = new Date(baseline.ts).toLocaleString('pt-BR', { day:'2-digit', month:'2-digit', hour:'2-digit', minute:'2-digit' });
    const chargesStr = charges.length > 0
      ? ` · ${charges.length} recarga${charges.length !== 1 ? 's' : ''}`
      : '';

    html += `<div class="card">
  <div class="card-title">Período${chargesStr} <span style="font-size:10px;color:var(--text-secondary)">desde ${baseDate}</span></div>
  <div class="metrics-row">
    <div class="metric"><div class="metric-value blue lg">${f1(distKm)} km</div><div class="metric-label">distância</div></div>
    <div class="metric"><div class="metric-value muted sm">${fmtDur(timeSec)}</div><div class="metric-label">condução</div></div>
    ${avgSpd > 0 ? `<div class="metric"><div class="metric-value muted sm">${f1(avgSpd)} km/h</div><div class="metric-label">vel. média</div></div>` : ''}
  </div>
  <div class="divider"></div>
  <div class="metrics-row">
    <div class="metric"><div class="metric-value green">${netKwh > 0 ? f2(netKwh) + ' kWh' : '--'}</div><div class="metric-label">kWh líquido</div></div>
    <div class="metric"><div class="metric-value teal">${regenKwh > 0 ? f2(regenKwh) + ' kWh' : '--'}</div><div class="metric-label">kWh regen.</div></div>
    <div class="metric"><div class="metric-value green">${avgKwh100 > 0 ? f1(avgKwh100) : '--'}</div><div class="metric-label">kWh/100km</div></div>
  </div>
  ${fuelL > 0.001 ? `<div class="divider"></div>
  <div class="metrics-row">
    <div class="metric"><div class="metric-value orange">${f2(fuelL)} L</div><div class="metric-label">combustível</div></div>
    <div class="metric"><div class="metric-value orange">${avgKml > 0 ? f1(avgKml) + ' km/L' : '--'}</div><div class="metric-label">efic. combust.</div></div>
  </div>` : ''}
  ${chargeKwh > 0 ? `<div class="divider"></div>
  <div class="metrics-row">
    <div class="metric"><div class="metric-value teal">${f2(chargeKwh)} kWh</div><div class="metric-label">kWh carregados</div></div>
    <div class="metric"><div class="metric-value muted sm">${fmtDur(chargeSec)}</div><div class="metric-label">tempo recarga</div></div>
    <div class="metric"><div class="metric-value blue">${avgChgKw > 0 ? f1(avgChgKw) + ' kW' : '--'}</div><div class="metric-label">pot. média</div></div>
  </div>` : ''}
</div>`;
  }

  list.innerHTML = html;
}

// ── Auto-Trips ────────────────────────────────────────────────────────────────
let cachedAutoTrips = null;

function loadAutoTrips() {
  // Sempre recarrega ao abrir a aba — garante que dados novos apareçam após sync do carro
  cachedAutoTrips = null;
  const list = document.getElementById('auto-list');
  list.innerHTML = '<div class="empty">Carregando...</div>';
  fetch('/api/autotrips')
    .then(r => r.json())
    .then(data => { cachedAutoTrips = Array.isArray(data) ? data : []; renderAutoTrips(); })
    .catch(() => { list.innerHTML = '<div class="empty">Erro ao carregar.</div>'; });
}

function renderAutoTrips() {
  const list = document.getElementById('auto-list');
  if (!list) return;
  const trips = cachedAutoTrips || [];

  if (!trips.length) {
    list.innerHTML = '<div class="empty">Nenhuma viagem automática registrada.</div>';
    return;
  }

  list.innerHTML = trips.map(t => {
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
    return `<div class="trip-item">
  <div class="trip-header">
    <div>
      <div class="trip-name">${startDate}</div>
      <div class="trip-date">${dur}</div>
    </div>
    <button class="charge-badge" style="cursor:pointer;border:none" onclick="openTripDetail('${t.tripId}')">🗺 Ver rota</button>
  </div>
  <div class="trip-metrics">
    <div class="trip-metric"><div class="trip-metric-val blue">${distKm}</div><div class="trip-metric-lbl">dist.</div></div>
    <div class="trip-metric"><div class="trip-metric-val green">${netKwh}</div><div class="trip-metric-lbl">kWh liq.</div></div>
    <div class="trip-metric"><div class="trip-metric-val orange">${fuelL}</div><div class="trip-metric-lbl">combust.</div></div>
    <div class="trip-metric"><div class="trip-metric-val teal">${socDelta}</div><div class="trip-metric-lbl">SOC</div></div>
  </div>${extraRow}
</div>`;
  }).join('');
}

// ── Dashboard map — última localização do carro ───────────────────────────────
let dashMap         = null;
let dashMarker      = null;

function initDashMap() {
  fetch('/api/location')
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

  fetch(`/api/telemetry/${tripId}`)
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
  // Destruir mapa para forçar reinit na próxima abertura
  if (leafletMap) { leafletMap.remove(); leafletMap = null; }
  if (chartSpd)   { chartSpd.destroy();  chartSpd  = null; }
  if (chartEv)    { chartEv.destroy();   chartEv   = null; }
  if (chartRpm)   { chartRpm.destroy();  chartRpm  = null; }
  routePolyline  = null;
  playbackMarker = null;
  currentSamples = [];
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
  document.getElementById('snap-spd').textContent  = f1(s.spd) + ' km/h';
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

connect();
tickInterval = setInterval(tickLastUpdate, 1000);
tickLastUpdate();

// Carrega localização do carro no mapa do dashboard (requer Leaflet carregado)
window.addEventListener('load', () => { setTimeout(initDashMap, 500); });

// ── Stats por período ─────────────────────────────────────────────────────────
let statsFilter  = 'today';
let statsSnaps   = null;

async function loadStats() {
  if (!statsSnaps) {
    try { statsSnaps = await fetch('/api/lifetime/snapshots').then(r => r.json()); }
    catch (_) { statsSnaps = []; }
  }
  renderStats();
}

function setStatsFilter(f) { statsFilter = f; renderStats(); }

function statsBaselineMs() {
  const now = Date.now();
  const tod = new Date(); tod.setHours(0, 0, 0, 0);
  switch (statsFilter) {
    case 'today': return tod.getTime();
    case '7d':    return now - 7  * 86400000;
    case '30d':   return now - 30 * 86400000;
    case 'month': { const m = new Date(); m.setDate(1); m.setHours(0, 0, 0, 0); return m.getTime(); }
    default:      return 0;
  }
}

function renderStats() {
  const chips = document.getElementById('stats-chips');
  const el    = document.getElementById('stats-content');
  if (!chips || !el) return;

  const fs = [['today','Hoje'],['7d','7 dias'],['30d','30 dias'],['month','Mês']];
  chips.innerHTML = `<div class="filter-chips">${
    fs.map(([id, lbl]) =>
      `<button class="filter-chip${statsFilter===id?' active':''}" onclick="setStatsFilter('${id}')">${lbl}</button>`
    ).join('')
  }</div>`;

  const cur = state.lifetime || {};
  if (!(cur.distance_km > 0)) {
    el.innerHTML = '<div class="empty">Sem dados de lifetime. Aguardando dados do carro.</div>';
    return;
  }

  const startMs = statsBaselineMs();
  const snaps   = statsSnaps || [];
  const base    = snaps.filter(s => s.ts <= startMs).sort((a, b) => b.ts - a.ts)[0] || null;

  if (!base && snaps.length > 0) {
    el.innerHTML = '<div class="empty">Sem dados suficientes para este período.<br><small>Snapshots são salvos a cada 5 min com o carro ligado.</small></div>';
    return;
  }

  const d = k => Math.max(0, (parseFloat(cur[k]) || 0) - (base ? (parseFloat(base[k]) || 0) : 0));

  const dDist    = d('distance_km');
  const dNet     = d('net_kwh');
  const dEnergy  = d('energy_kwh');
  const dRegen   = d('regen_kwh');
  const dFuel    = d('fuel_l');
  const dTime    = d('time_sec');
  const dCharge  = d('charge_kwh');
  const dChargeT = d('charge_sec');

  const avgSpd   = dTime > 0    ? dDist / (dTime / 3600)  : 0;
  const kwh100   = dDist > 0.1  ? dNet  / dDist * 100     : 0;
  const kmL      = dFuel > 0.001 ? dDist / dFuel           : 0;
  const avgChKw  = dChargeT > 0  ? dCharge / (dChargeT / 3600) : 0;

  const metricHTML = (val, unit, lbl, cls) =>
    `<div class="metric"><div class="metric-value ${cls} sm">${val}${unit ? '<span style="font-size:9px;margin-left:2px">'+unit+'</span>' : ''}</div><div class="metric-label">${lbl}</div></div>`;

  el.innerHTML = `
<div class="card">
  <div class="card-title">🚗 Condução</div>
  <div class="metrics-row">
    ${metricHTML(f1(dDist),  'km',     'Distância',   'blue')}
    ${metricHTML(fmtDur(dTime), '',    'Tempo',       'muted')}
    ${metricHTML(f1(avgSpd), 'km/h',   'Vel. média',  'muted')}
  </div>
  <div class="divider"></div>
  <div class="metrics-row">
    ${metricHTML(f1(kwh100), 'kWh',    'kWh/100km',   kwh100 > 0 && kwh100 < 20 ? 'green' : kwh100 < 26 ? 'yellow' : 'red')}
    ${metricHTML(f1(kmL),    'km/L',   'km/L',        kmL > 15 ? 'green' : kmL > 9 ? 'yellow' : 'red')}
    ${metricHTML(f2(dFuel),  'L',      'Combustível', 'orange')}
  </div>
  <div class="divider"></div>
  <div class="metrics-row">
    ${metricHTML(f2(dNet),    'kWh',   'kWh líq.',    'green')}
    ${metricHTML(f2(dEnergy), 'kWh',   'Energia bruta','muted')}
    ${metricHTML(f2(dRegen),  'kWh',   'Regeneração', 'teal')}
  </div>
</div>
${dCharge > 0.01 ? `<div class="card">
  <div class="card-title">⚡ Recargas</div>
  <div class="metrics-row">
    ${metricHTML(f2(dCharge), 'kWh',   'Injetado',    'teal')}
    ${metricHTML(fmtDur(dChargeT), '', 'Tempo total', 'muted')}
    ${metricHTML(f1(avgChKw), 'kW',    'Potência méd.','teal')}
  </div>
</div>` : ''}`;
}

// ── Admin / Configurações ─────────────────────────────────────────────────────

const ADMIN_TOKEN_KEY = 'ecotrip_admin_token';

function initAdmin() {
  const saved = localStorage.getItem(ADMIN_TOKEN_KEY);
  if (saved) document.getElementById('admin-token').value = saved;
}

function adminGetToken() {
  const t = document.getElementById('admin-token').value.trim();
  if (t) localStorage.setItem(ADMIN_TOKEN_KEY, t);
  return t || 'ecotrip-restart';
}

function adminSetStatus(msg, ok) {
  const el = document.getElementById('admin-status');
  el.textContent = msg;
  el.style.color = ok === true ? '#4ade80' : ok === false ? '#f87171' : '#94a3b8';
}

async function adminAction(path, label) {
  adminSetStatus('⏳ ' + label + '…', null);
  try {
    const r    = await fetch(path, {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ token: adminGetToken() }),
    });
    const data = await r.json().catch(() => ({}));
    if (r.ok && data.ok) {
      adminSetStatus('✓ ' + (data.msg || 'OK'), true);
    } else {
      adminSetStatus('✗ ' + (data.error || `HTTP ${r.status}`), false);
    }
  } catch (e) {
    adminSetStatus('✗ Sem resposta — servidor pode estar reiniciando…', false);
  }
}

function adminRestart() { adminAction('/api/admin/restart', 'Reiniciando'); }
function adminUpdate()  { adminAction('/api/admin/update',  'Atualizando'); }
