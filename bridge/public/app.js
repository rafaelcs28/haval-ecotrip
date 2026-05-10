'use strict';

// ── Estado local ──────────────────────────────────────────────────────────────
let state = {};
let lastUpdateMs = null;
let wsRetryDelay = 1000;
let ws = null;
let tickInterval = null;

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
        state = msg.data;
        lastUpdateMs = Date.now();
        renderAll();
        // Persiste no localStorage para leitura offline
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
  if (s === 'online')      { dot.classList.add('online');  }
  else if (s === 'offline'){ dot.classList.add('offline'); }
}

function tickLastUpdate() {
  const el = document.getElementById('last-update');
  if (!lastUpdateMs) { el.textContent = '--'; return; }
  const sec = Math.floor((Date.now() - lastUpdateMs) / 1000);
  if (sec < 10)       el.textContent = 'agora';
  else if (sec < 60)  el.textContent = `${sec}s atrás`;
  else if (sec < 3600)el.textContent = `${Math.floor(sec/60)}min atrás`;
  else                el.textContent = `${Math.floor(sec/3600)}h atrás`;
  // Status online/offline baseado no tempo
  if (state.car_online && sec < 30)  setStatus('online');
  else if (sec < 60)                 setStatus('connecting');
  else                               setStatus('offline');
}

// ── Helpers de formatação ─────────────────────────────────────────────────────
const f1  = v => (typeof v === 'number' ? v.toFixed(1)  : '--');
const f2  = v => (typeof v === 'number' ? v.toFixed(2)  : '--');
const pct = v => (typeof v === 'number' ? v.toFixed(0) + '%' : '--%');
const eff = v => {               // kWh/100km: cor de eficiência
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
  if (el) { el.className = el.className.replace(/\b(green|blue|teal|orange|yellow|muted)\b/g, ''); el.classList.add(cls); }
}

// ── Render ────────────────────────────────────────────────────────────────────
function renderAll() {
  renderDash();
  renderTrip('a', state.trip_a || {});
  renderTrip('b', state.trip_b || {});
  renderRolling(state.rolling || {});
  renderLifetime(state.lifetime || {});
}

function renderDash() {
  const s = state;
  setText('d-speed',   Math.round(s.speed_kmh  || 0));
  setText('d-gear',    s.gear || 'P');
  setText('d-inside',  s.inside_temp  ? f1(s.inside_temp)  + '°C' : '--');
  setText('d-outside', s.outside_temp ? f1(s.outside_temp) + '°C' : '--');

  // SOC — usamos soc_pct (publicado em trip_a/soc_current com retain)
  const soc  = s.soc_pct || s.trip_a?.soc_current || 0;
  setText('d-soc', pct(soc));
  const socBar = document.getElementById('d-soc-bar');
  if (socBar) socBar.style.width = Math.max(0, Math.min(100, soc)) + '%';

  // Combustível % — inferimos de tank_now_l / (tank_start_l + distância × consumo)
  // Usamos o % mais recente do Trip A (tank_now_l / 51L capacidade, approx)
  const tankNow = s.trip_a?.tank_now_l ?? s.trip_b?.tank_now_l ?? 0;
  const fuelPct = tankNow > 0 ? Math.min(100, (tankNow / 51) * 100) : 0;
  setText('d-fuel', fuelPct > 0 ? pct(fuelPct) : '--');
  const fuelBar = document.getElementById('d-fuel-bar');
  if (fuelBar) fuelBar.style.width = Math.max(0, Math.min(100, fuelPct)) + '%';

  // Recarga
  const isCharging = s.charge_power_kw > 0.1 || s.charging_state === 'Carregando';
  const chargeRow = document.getElementById('d-charge-row');
  if (chargeRow) chargeRow.style.display = isCharging ? 'block' : 'none';
  setText('d-charge-power', s.charge_power_kw > 0 ? f1(s.charge_power_kw) + ' kW' : '--');
  setText('d-charge-state', s.charging_state || '--');
}

function renderTrip(id, t) {
  const p = id; // 'a' ou 'b'
  setText(`${p}-dist`,   f1(t.distance_km) + ' km');
  setText(`${p}-time`,   t.time_sec  || '--');
  setText(`${p}-speed`,  f1(t.avg_speed_kmh));
  setText(`${p}-kwh100`, t.kwh_per_100km > 0 ? f1(t.kwh_per_100km) : '--');
  setText(`${p}-kml`,    t.km_per_l    > 0 ? f1(t.km_per_l)     : '--');
  setText(`${p}-fuel`,   t.fuel_l      > 0 ? f2(t.fuel_l) + ' L' : '--');
  setText(`${p}-energy`, t.energy_kwh  > 0 ? f2(t.energy_kwh)    : '--');
  setText(`${p}-regen`,  t.regen_kwh   > 0 ? f2(t.regen_kwh)     : '--');
  setText(`${p}-cost`,   t.cost_brl    > 0 ? 'R$ ' + f2(t.cost_brl) : '--');
  setText(`${p}-soc-start`, pct(t.soc_start));
  setText(`${p}-soc-now`,   pct(t.soc_current));
  setText(`${p}-tank-now`,  t.tank_now_l > 0 ? f1(t.tank_now_l) + ' L' : '--');
  setClass(`${p}-kwh100`, eff(t.kwh_per_100km));
}

function renderRolling(r) {
  setText('r-dist',   f1(r.distance_km) + ' km');
  setText('r-fuel',   r.fuel_l > 0 ? f2(r.fuel_l) + ' L' : '--');
  setText('r-kwh100', r.kwh_per_100km > 0 ? f1(r.kwh_per_100km) : '--');
  setText('r-kml',    r.km_per_l      > 0 ? f1(r.km_per_l)     : '--');
}

function renderLifetime(l) {
  setText('l-dist',        f1(l.distance_km)  + ' km');
  setText('l-time',        l.time_sec   || '--');
  setText('l-net',         l.net_kwh    > 0 ? f2(l.net_kwh)   + ' kWh' : '--');
  setText('l-regen',       l.regen_kwh  > 0 ? f2(l.regen_kwh) + ' kWh' : '--');
  setText('l-fuel',        l.fuel_l     > 0 ? f2(l.fuel_l)    + ' L'   : '--');
  setText('l-charge',      l.charge_kwh > 0 ? f2(l.charge_kwh)+ ' kWh' : '--');
  setText('l-charge-time', l.charge_sec || '--');
  setText('l-cost',        l.cost_brl   > 0 ? 'R$ ' + f2(l.cost_brl)   : '--');
}

// ── Recargas ──────────────────────────────────────────────────────────────────
function loadCharges() {
  const list = document.getElementById('charges-list');
  list.innerHTML = '<div class="empty">Carregando...</div>';

  fetch('/api/charges')
    .then(r => r.json())
    .then(charges => {
      if (!charges || charges.length === 0) {
        list.innerHTML = '<div class="empty">Nenhuma recarga registrada ainda.</div>';
        return;
      }

      // Totais
      const totalKwh  = charges.reduce((s, c) => s + (c.energy_kwh || 0), 0);
      const totalSec  = charges.reduce((s, c) => s + (c.duration_sec || 0), 0);
      const avgPwr    = totalSec > 0 ? (totalKwh / (totalSec / 3600)) : 0;

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

      const socDeltaColor = (delta) =>
        delta >= 50 ? 'green' : delta >= 25 ? 'teal' : 'muted';

      const summary = `
<div class="charge-summary-card">
  <div class="card-title">Resumo — ${charges.length} sessão${charges.length !== 1 ? 'ões' : ''}</div>
  <div class="metrics-row">
    <div class="metric">
      <div class="metric-value teal">${f2(totalKwh)} kWh</div>
      <div class="metric-label">total carregado</div>
    </div>
    <div class="metric">
      <div class="metric-value muted">${fmtDur(totalSec)}</div>
      <div class="metric-label">tempo total</div>
    </div>
    <div class="metric">
      <div class="metric-value blue">${f1(avgPwr)} kW</div>
      <div class="metric-label">potência média</div>
    </div>
  </div>
</div>`;

      const items = charges.map(c => {
        const delta = (c.soc_end || 0) - (c.soc_start || 0);
        const color = socDeltaColor(delta);
        return `
<div class="trip-item">
  <div class="trip-header">
    <div>
      <div class="trip-name">${fmtDate(c.timestamp)}</div>
    </div>
    <span class="charge-kwh-badge">${f2(c.energy_kwh)} kWh</span>
  </div>
  <div class="trip-metrics">
    <div class="trip-metric">
      <div class="trip-metric-val" style="color:var(--teal)">${fmtDur(c.duration_sec)}</div>
      <div class="trip-metric-lbl">duração</div>
    </div>
    <div class="trip-metric">
      <div class="trip-metric-val" style="color:var(--blue)">${f1(c.avg_power_kw)} kW</div>
      <div class="trip-metric-lbl">pot. média</div>
    </div>
    <div class="trip-metric">
      <div class="trip-metric-val" style="color:var(--muted)">${pct(c.soc_start)}</div>
      <div class="trip-metric-lbl">SOC início</div>
    </div>
    <div class="trip-metric">
      <div class="trip-metric-val ${color}">${pct(c.soc_end)}</div>
      <div class="trip-metric-lbl">SOC fim</div>
    </div>
    <div class="trip-metric">
      <div class="trip-metric-val ${color}">+${delta.toFixed(0)}%</div>
      <div class="trip-metric-lbl">Δ SOC</div>
    </div>
  </div>
</div>`;
      }).join('');

      list.innerHTML = summary + items;
    })
    .catch(() => {
      list.innerHTML = '<div class="empty">Erro ao carregar recargas. Verifique a conexão.</div>';
    });
}

// ── Histórico ─────────────────────────────────────────────────────────────────
function loadHistory() {
  const list = document.getElementById('hist-list');
  list.innerHTML = '<div class="empty">Carregando...</div>';

  fetch('/api/trips')
    .then(r => r.json())
    .then(trips => {
      if (!trips || trips.length === 0) {
        list.innerHTML = '<div class="empty">Nenhuma viagem salva ainda.</div>';
        return;
      }
      const fmt = (ts) => {
        try {
          const d = new Date(ts);
          return d.toLocaleDateString('pt-BR', { day:'2-digit', month:'2-digit', year:'2-digit' })
               + ' '
               + d.toLocaleTimeString('pt-BR', { hour:'2-digit', minute:'2-digit' });
        } catch(_) { return ts || '--'; }
      };
      list.innerHTML = trips.map(t => {
        const name = t.name || t.label || 'Viagem';
        const cost = t.total_cost_brl > 0 ? `<span class="trip-cost">R$ ${f2(t.total_cost_brl)}</span>` : '';
        return `
<div class="trip-item">
  <div class="trip-header">
    <div>
      <span class="trip-badge">${t.label || 'Trip'}</span>
      <div class="trip-name" style="margin-top:3px">${name}</div>
      <div class="trip-date">${fmt(t.timestamp)}</div>
    </div>
    ${cost}
  </div>
  <div class="trip-metrics">
    <div class="trip-metric">
      <div class="trip-metric-val blue">${f1(t.distance_km)} km</div>
      <div class="trip-metric-lbl">dist.</div>
    </div>
    <div class="trip-metric">
      <div class="trip-metric-val green">${t.kwh_per_100km > 0 ? f1(t.kwh_per_100km) : '--'}</div>
      <div class="trip-metric-lbl">kWh/100km</div>
    </div>
    <div class="trip-metric">
      <div class="trip-metric-val green">${t.km_per_l > 0 ? f1(t.km_per_l) : '--'}</div>
      <div class="trip-metric-lbl">km/L</div>
    </div>
    <div class="trip-metric">
      <div class="trip-metric-val orange">${t.fuel_l > 0 ? f2(t.fuel_l) + ' L' : '--'}</div>
      <div class="trip-metric-lbl">combust.</div>
    </div>
    <div class="trip-metric">
      <div class="trip-metric-val" style="color:#5B7394">${t.time_sec || '--'}</div>
      <div class="trip-metric-lbl">duração</div>
    </div>
  </div>
</div>`;
      }).join('');
    })
    .catch(() => {
      list.innerHTML = '<div class="empty">Erro ao carregar histórico. Verifique a conexão.</div>';
    });
}

// ── Inicialização ─────────────────────────────────────────────────────────────

// Tenta restaurar último estado do cache (offline)
try {
  const cached = localStorage.getItem('ecotrip_state');
  if (cached) {
    const { state: cachedState, ts } = JSON.parse(cached);
    state = cachedState;
    lastUpdateMs = ts;
    renderAll();
  }
} catch(_) {}

// Conecta WebSocket
connect();

// Tick a cada segundo para atualizar "última atualização"
tickInterval = setInterval(tickLastUpdate, 1000);
tickLastUpdate();
