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

// ── Service Worker ────────────────────────────────────────────────────────────
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/sw.js').catch(() => {});
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

function fmtDur(sec) {
  if (!sec || sec <= 0) return '--';
  const h = Math.floor(sec / 3600), m = Math.floor((sec % 3600) / 60);
  return h > 0 ? `${h}h ${m}min` : `${m}min`;
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

  // Combustível (tank 51L)
  const TANK_CAP = 51;
  const tankNow = s.trip_a?.tank_now_l > 0 ? s.trip_a.tank_now_l
                : s.trip_b?.tank_now_l > 0 ? s.trip_b.tank_now_l : 0;
  const fuelPct = tankNow > 0 ? Math.min(100, (tankNow / TANK_CAP) * 100) : 0;
  setText('d-fuel', tankNow > 0 ? f1(tankNow) + ' L  (' + fuelPct.toFixed(0) + '%)' : '--');
  const fuelBar = document.getElementById('d-fuel-bar');
  if (fuelBar) fuelBar.style.width = Math.max(0, Math.min(100, fuelPct)) + '%';

  // Recarga
  const isCharging = s.charge_power_kw > 0.1 || s.charging_state === 'Carregando';
  const chargeRow = document.getElementById('d-charge-row');
  if (chargeRow) chargeRow.style.display = isCharging ? 'block' : 'none';
  setText('d-charge-power', s.charge_power_kw > 0 ? f1(s.charge_power_kw) + ' kW' : '--');
  setText('d-charge-state', s.charging_state || '--');

  // Trip A mini
  const ta = s.trip_a || {};
  setText('d-trip-dist', ta.distance_km   > 0 ? f1(ta.distance_km) + ' km' : '--');
  setText('d-trip-time', ta.time_sec      || '--');
  setText('d-trip-kwh',  ta.kwh_per_100km > 0 ? f1(ta.kwh_per_100km)       : '--');
  setText('d-trip-kml',  ta.km_per_l      > 0 ? f1(ta.km_per_l)            : '--');
  setText('d-trip-cost', ta.cost_brl      > 0 ? 'R$ ' + f2(ta.cost_brl)   : '--');
  setClass('d-trip-kwh', eff(ta.kwh_per_100km));

  // Trip B mini
  const tb = s.trip_b || {};
  setText('d-tripb-dist', tb.distance_km   > 0 ? f1(tb.distance_km) + ' km' : '--');
  setText('d-tripb-time', tb.time_sec      || '--');
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
  setClass('d-roll-kwh', eff(r.kwh_per_100km));
}

function renderTrip(id, t) {
  const p = id;
  setText(`${p}-dist`,      f1(t.distance_km) + ' km');
  setText(`${p}-time`,      t.time_sec  || '--');
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
  if (cachedTrips !== null) { renderHistory(); return; }
  const list = document.getElementById('hist-list');
  list.innerHTML = '<div class="empty">Carregando...</div>';
  fetch('/api/trips')
    .then(r => r.json())
    .then(data => { cachedTrips = Array.isArray(data) ? data : []; renderHistory(); })
    .catch(() => { list.innerHTML = filterChipsHTML('hist') + '<div class="empty">Erro ao carregar.</div>'; });
}

function renderHistory() {
  const list = document.getElementById('hist-list');
  if (!list) return;
  const [startMs, endMs] = getFilterRange('hist');
  const trips = filterItems(cachedTrips || [], 'timestamp', startMs, endMs);

  let html = filterChipsHTML('hist');
  if (!trips.length) {
    list.innerHTML = html + '<div class="empty">Nenhuma viagem no período.</div>';
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
    return `<div class="trip-item">
  <div class="trip-header">
    <div>
      <span class="trip-badge">${t.label || 'Trip'}</span>
      <div class="trip-name" style="margin-top:3px">${name}</div>
      <div class="trip-date">${fmtDate(t.timestamp)}</div>
    </div>
    ${cost}
  </div>
  <div class="trip-metrics">
    <div class="trip-metric"><div class="trip-metric-val blue">${f1(t.distance_km)} km</div><div class="trip-metric-lbl">dist.</div></div>
    <div class="trip-metric"><div class="trip-metric-val green">${t.kwh_per_100km > 0 ? f1(t.kwh_per_100km) : '--'}</div><div class="trip-metric-lbl">kWh/100km</div></div>
    <div class="trip-metric"><div class="trip-metric-val green">${t.km_per_l > 0 ? f1(t.km_per_l) : '--'}</div><div class="trip-metric-lbl">km/L</div></div>
    <div class="trip-metric"><div class="trip-metric-val orange">${t.fuel_l > 0 ? f2(t.fuel_l) + ' L' : '--'}</div><div class="trip-metric-lbl">combust.</div></div>
    <div class="trip-metric"><div class="trip-metric-val" style="color:#5B7394">${t.time_sec || '--'}</div><div class="trip-metric-lbl">duração</div></div>
  </div>
</div>`;
  }).join('');

  list.innerHTML = html;
}

// ── Lifetime ──────────────────────────────────────────────────────────────────
function loadLifetime() {
  renderLifetimeTab();
  // Pré-carrega trips + recargas para filtros funcionarem imediatamente
  if (cachedCharges === null) {
    fetch('/api/charges').then(r=>r.json()).then(d=>{cachedCharges=Array.isArray(d)?d:[];}).catch(()=>{});
  }
  if (cachedTrips === null) {
    fetch('/api/trips').then(r=>r.json()).then(d=>{cachedTrips=Array.isArray(d)?d:[];}).catch(()=>{});
  }
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
    <div class="metric"><div class="metric-value muted">${l.time_sec || '--'}</div><div class="metric-label">Tempo condução</div></div>
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
    // ── Vista filtrada: computado de trips + recargas ─────────────────────────
    const [startMs, endMs] = getFilterRange('life');
    const trips   = filterItems(cachedTrips   || [], 'timestamp', startMs, endMs);
    const charges = filterItems(cachedCharges || [], 'timestamp', startMs, endMs);

    // Se dados ainda não foram carregados, busca e re-renderiza
    if (cachedCharges === null || cachedTrips === null) {
      html += '<div class="empty">Carregando dados...</div>';
      list.innerHTML = html;
      Promise.all([
        cachedCharges === null ? fetch('/api/charges').then(r=>r.json()).then(d=>{cachedCharges=Array.isArray(d)?d:[];}) : Promise.resolve(),
        cachedTrips   === null ? fetch('/api/trips').then(r=>r.json()).then(d=>{cachedTrips=Array.isArray(d)?d:[];})     : Promise.resolve(),
      ]).then(() => renderLifetimeTab()).catch(() => {});
      return;
    }

    if (trips.length === 0 && charges.length === 0) {
      list.innerHTML = html + '<div class="empty">Nenhum dado no período.</div>';
      return;
    }

    const distKm    = trips.reduce((s,t) => s + (t.distance_km    || 0), 0);
    const fuelL     = trips.reduce((s,t) => s + (t.fuel_l         || 0), 0);
    const costBrl   = trips.reduce((s,t) => s + (t.total_cost_brl || 0), 0);
    const netKwh    = trips.reduce((s,t) => {
      const d = t.distance_km||0, k = t.kwh_per_100km||0;
      return s + (k > 0 && d > 0 ? k * d / 100 : 0);
    }, 0);
    const chargeKwh = charges.reduce((s,c) => s + (c.energy_kwh   || 0), 0);
    const chargeSec = charges.reduce((s,c) => s + (c.duration_sec || 0), 0);
    const avgKwh100 = distKm    > 0.1   ? netKwh    / distKm * 100       : 0;
    const avgKml    = fuelL     > 0.001 ? distKm    / fuelL              : 0;
    const avgChgKw  = chargeSec > 0     ? chargeKwh / (chargeSec / 3600) : 0;

    html += `<div class="card">
  <div class="card-title">Período — ${trips.length} viagem${trips.length !== 1 ? 'ns' : ''} · ${charges.length} recarga${charges.length !== 1 ? 's' : ''}</div>
  <div class="metrics-row">
    <div class="metric"><div class="metric-value blue lg">${f1(distKm)} km</div><div class="metric-label">distância</div></div>
    <div class="metric"><div class="metric-value orange">${f2(fuelL)} L</div><div class="metric-label">combustível</div></div>
  </div>
  <div class="divider"></div>
  <div class="metrics-row">
    <div class="metric"><div class="metric-value green">${netKwh > 0 ? f2(netKwh) + ' kWh' : '--'}</div><div class="metric-label">kWh consumido</div></div>
    <div class="metric"><div class="metric-value green">${avgKwh100 > 0 ? f1(avgKwh100) : '--'}</div><div class="metric-label">kWh/100km</div></div>
    <div class="metric"><div class="metric-value green">${avgKml > 0 ? f1(avgKml) : '--'}</div><div class="metric-label">km/L</div></div>
  </div>
  <div class="divider"></div>
  <div class="metrics-row">
    <div class="metric"><div class="metric-value teal">${chargeKwh > 0 ? f2(chargeKwh) + ' kWh' : '--'}</div><div class="metric-label">kWh carregados</div></div>
    <div class="metric"><div class="metric-value muted">${fmtDur(chargeSec)}</div><div class="metric-label">tempo recarga</div></div>
    <div class="metric"><div class="metric-value blue">${avgChgKw > 0 ? f1(avgChgKw) + ' kW' : '--'}</div><div class="metric-label">pot. média</div></div>
  </div>
  ${costBrl > 0 ? `<div class="divider"></div>
  <div class="metrics-row">
    <div class="metric"><div class="metric-value yellow">R$ ${f2(costBrl)}</div><div class="metric-label">custo viagens</div></div>
  </div>` : ''}
</div>`;
  }

  list.innerHTML = html;
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
