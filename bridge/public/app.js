'use strict';

const APP_BUILD = 'b164';   // bump a cada deploy para confirmar versão no admin

// ── Estado local ──────────────────────────────────────────────────────────────
let state = {};
let _actStatusFns  = [];   // statusFn por índice de card (preenchido por initActionsPanel)
let _actionLogMap  = {};   // action → id do div de log
// Confirmações de ação remota pendentes: { [stateKey]: { expectedVal, timer, onSuccess } }
const _pendingConfirm = {};

/**
 * Verifica se algum estado recebido via WS resolve uma confirmação pendente.
 * Usa == (loose) para lidar com engine_state que pode chegar como string ou número.
 */
function _checkPendingConfirm(data) {
  if (!data) return;
  for (const key of Object.keys(_pendingConfirm)) {
    const newVal = data[key];
    if (newVal === undefined) continue;
    const p = _pendingConfirm[key];
    // eslint-disable-next-line eqeqeq
    if (newVal == p.expectedVal) {
      clearTimeout(p.timer);
      delete _pendingConfirm[key];
      p.onSuccess();
    }
  }
}
let lastUpdateMs = null;
let wsRetryDelay = 1000;
let wsReconnectTimeout = null;
let ws = null;
let tickInterval = null;
let activePanel  = 'dash';

// ── Geocode cache (sessionStorage, zoom=10 → cidade) ─────────────────────────
let geoCache = {};
try { geoCache = JSON.parse(sessionStorage.getItem('geoCache') || '{}'); } catch (_) {}
let _geoQueue  = [];   // { tripId, lat, lng }
let _geoTimer  = null; // setTimeout handle da fila

// ── Status de rename (localStorage) ──────────────────────────────────────────
// renameTracking[tripId] = { pendingId: string, name: string, confirmed: bool }
let renameTracking = {};
try { renameTracking = JSON.parse(localStorage.getItem('renameTracking') || '{}'); } catch (_) {}
function _saveRenameTracking() {
  try { localStorage.setItem('renameTracking', JSON.stringify(renameTracking)); } catch (_) {}
}
function getRenameStatus(tripId) {
  const t = renameTracking[String(tripId)];
  if (!t) return 'none';
  return t.confirmed ? 'confirmed' : 'pending';
}
// Consulta /api/pending-renames e marca como confirmed os que o carro já aplicou
async function syncRenameStatus() {
  try {
    const data = await apiFetch('/api/pending-renames').then(r => r.json());
    const serverPendingIds = new Set(data.map(r => r.id));
    let changed = false;
    for (const [tripId, track] of Object.entries(renameTracking)) {
      if (!track.confirmed && track.pendingId && !serverPendingIds.has(track.pendingId)) {
        renameTracking[tripId] = { ...track, confirmed: true };
        changed = true;
      }
    }
    if (changed) { _saveRenameTracking(); renderAutoTrips(); }
  } catch (_) {}
}


function queueGeocode(tripId, lat, lng, key = tripId) {
  if (!lat || !lng || lat === 0 || lng === 0) return;
  if (geoCache[key] !== undefined) return;              // já tentado
  if (_geoQueue.some(q => q.key === key)) return;       // já na fila
  _geoQueue.push({ key, lat, lng });
  if (!_geoTimer) _geoTimer = setTimeout(_processGeoQueue, 50);
}

async function _processGeoQueue() {
  _geoTimer = null;
  if (!_geoQueue.length) return;
  const { key, lat, lng } = _geoQueue.shift();
  try {
    // zoom=14 retorna `suburb`/`neighbourhood` (bairro) além da cidade. Com
    // zoom=10 só vinha a cidade — "Casa → Goiânia" ficava genérico demais.
    const r = await fetch(
      `https://nominatim.openstreetmap.org/reverse?format=json&lat=${lat}&lon=${lng}&zoom=14`,
      { headers: { 'Accept-Language': 'pt-BR' } }
    );
    const d = await r.json();
    const a = d.address || {};
    const city   = a.city || a.town || a.village || a.municipality || a.county || '';
    // Bairros no Brasil: `suburb` é o mais comum. Demais como fallback.
    const suburb = a.suburb || a.neighbourhood || a.quarter || a.city_district || '';
    // Formato: "Bairro, Cidade" quando temos os dois; só "Cidade" caso contrário.
    geoCache[key] = suburb && city
      ? `${suburb}, ${city}`
      : (city || '');
  } catch (_) {
    geoCache[key] = '';  // falhou — marca como tentado para não repetir
  }
  try { sessionStorage.setItem('geoCache', JSON.stringify(geoCache)); } catch (_) {}
  // Atualiza lista: sempre que o painel auto estiver visível (nomes automáticos) ou busca ativa
  if (document.querySelector('#panel-auto.active') || filterState.auto.search.trim()) renderAutoTrips();
  // Próximo item com 1.1s de intervalo (respeita política do Nominatim)
  if (_geoQueue.length) _geoTimer = setTimeout(_processGeoQueue, 1100);
}

// Retorna "Origem → Destino" se forem diferentes e o trip não tiver nome.
// Origem/destino usam local conhecido (knownStart/knownEnd) ou o geocode no
// formato "Bairro, Cidade" — preserva o nome completo agora que temos bairro.
function getAutoName(t) {
  if (t.name) return null; // servidor já definiu nome completo
  const knownStart = t.knownStart || null;
  const knownEnd   = t.knownEnd   || null;
  const startFull  = geoCache[t.tripId];
  const endFull    = geoCache[t.tripId + ':end'];
  const startName  = knownStart || (startFull || null);
  const endName    = knownEnd   || (endFull   || null);
  if (!startName || !endName) return null;
  if (!knownStart && !knownEnd && startName === endName) return null;
  return `${startName} → ${endName}`;
}

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
  _restoreSettingsSections();
  initActionsPanel();
  initNotifPanel();
  loadKnownLocations();
  loadKnownPlaces();
  _fetchNotifCache();
  checkAutoBackup();
  // Mostra build atual no admin para confirmar versão carregada
  const as = document.getElementById('admin-status');
  if (as && as.textContent.trim() === 'Pronto.') as.textContent = 'Pronto. (' + APP_BUILD + ')';
  // Restaura a aba ativa de qualquer reload dentro da mesma sessão.
  try {
    const saved = sessionStorage.getItem('ecotrip_active_panel');
    if (saved && saved !== 'dash') {
      const btn = document.querySelector(`.tab[data-panel="${saved}"]`);
      if (btn) btn.click();
    }
  } catch (_) {}
});

// ── Notification preferences panel ───────────────────────────────────────────
const NOTIF_ITEMS = [
  { key: 'charge_start',  icon: '⚡', label: 'Recarga iniciada' },
  { key: 'charge_end',    icon: '✅', label: 'Recarga concluída' },
  { key: 'charge_ending', icon: '🔔', label: 'Fim de recarga próximo', minuteKey: 'charge_ending_min' },
  { key: 'door_open',    icon: '🚪', label: 'Porta aberta',    sub: 'qualquer porta' },
  { key: 'door_close',   icon: '🚪', label: 'Porta fechada',   sub: 'qualquer porta' },
  { key: 'trunk_open',   icon: '🧳', label: 'Porta-malas aberta' },
  { key: 'trunk_close',  icon: '🧳', label: 'Porta-malas fechada' },
  { key: 'engine_on',    icon: '🔑', label: 'Motor ligado' },
  { key: 'engine_off',   icon: '🔑', label: 'Motor desligado' },
  { key: 'app_update',   icon: '📱', label: 'Atualização do app', sub: 'nova versão instalada no carro' },
  { key: 'trip_end',    icon: '🏁', label: 'Viagem concluída',   sub: 'ao finalizar auto-trip' },
  { key: 'geofence_arrival',   icon: '📍', label: 'Chegada em local conhecido', sub: 'casa, trabalho, etc.' },
  { key: 'geofence_departure', icon: '🚗', label: 'Saída de local conhecido',   sub: 'ao deixar a zona' },
];

let _notifPrefs = {};

async function initNotifPanel() {
  try {
    _notifPrefs = await apiFetch('/api/push/prefs').then(r => r.json());
  } catch (_) { _notifPrefs = {}; }
  _renderNotifToggles();
  _updatePushPermStatus();
}

function _renderNotifToggles() {
  const el = document.getElementById('notif-toggles');
  if (!el) return;
  el.innerHTML = NOTIF_ITEMS.map(({ key, icon, label, sub, minuteKey }) => `
    <div class="notif-row">
      <label class="notif-label" for="ntog-${key}">
        <span>${icon}</span>
        <span>${label}${sub ? `<span class="notif-label-sub">${sub}</span>` : ''}</span>
      </label>
      <label class="toggle-wrap">
        <input type="checkbox" id="ntog-${key}" ${_notifPrefs[key] ? 'checked' : ''}
          onchange="saveNotifPref('${key}', this.checked)${minuteKey ? `; document.getElementById('ntog-${minuteKey}-row').style.display = this.checked ? '' : 'none'` : ''}">
        <span class="toggle-slider"></span>
      </label>
    </div>
    ${minuteKey ? `
    <div class="notif-minutes-row" id="ntog-${minuteKey}-row" style="display:${_notifPrefs[key] ? '' : 'none'}">
      <span class="notif-label-sub">Avisar com</span>
      <input type="number" id="ntog-${minuteKey}" class="notif-minutes-input"
        min="1" max="20" value="${_notifPrefs[minuteKey] ?? 5}"
        onchange="saveNotifPref('${minuteKey}', Math.max(1,Math.min(20,+this.value)))">
      <span class="notif-label-sub">min de antecedência</span>
    </div>` : ''}`).join('');
}

window.saveNotifPref = async function(key, value) {
  _notifPrefs[key] = value;
  try {
    await apiFetch('/api/push/prefs', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ key, value }),
    });
  } catch (_) {
    showToast('✗ Erro ao salvar preferência');
  }
};

// ── Colapsar / expandir seções de configurações (genérico) ────────────────────
window.toggleSection = function(bodyId, btnId) {
  const body = document.getElementById(bodyId);
  const btn  = document.getElementById(btnId);
  if (!body || !btn) return;
  const willCollapse = body.style.display !== 'none';
  body.style.display = willCollapse ? 'none' : '';
  btn.textContent    = willCollapse ? '▼' : '▲';
  localStorage.setItem('sc_' + bodyId, willCollapse ? '1' : '0');
  // ajusta margem do header quando não há body visível
  const header = btn.closest('.sc-header');
  if (header) header.style.marginBottom = willCollapse ? '0' : '';
};
function _restoreSettingsSections() {
  // Descobre todas as sections via DOM (em vez de lista hardcoded) — assim
  // novas seções adicionadas no HTML herdam a persistência sem precisar
  // mexer aqui. Lê de localStorage cada `sc_<bodyId>`.
  document.querySelectorAll('.sc-header[onclick*="toggleSection"]').forEach(hdr => {
    const m = (hdr.getAttribute('onclick') || '').match(/toggleSection\('([^']+)','([^']+)'\)/);
    if (!m) return;
    const [, bodyId, btnId] = m;
    if (localStorage.getItem('sc_' + bodyId) !== '1') return;
    const body = document.getElementById(bodyId);
    const btn  = document.getElementById(btnId);
    if (body) body.style.display = 'none';
    if (btn)  btn.textContent    = '▼';
    hdr.style.marginBottom = '0';
  });
}

// ── Colapsar / expandir opções de notificação ─────────────────────────────────
let _notifBodyCollapsed = localStorage.getItem('notifBodyCollapsed') === '1';
window.toggleNotifSection = function() {
  _notifBodyCollapsed = !_notifBodyCollapsed;
  localStorage.setItem('notifBodyCollapsed', _notifBodyCollapsed ? '1' : '0');
  const body = document.getElementById('notif-body');
  const btn  = document.getElementById('notif-collapse-btn');
  if (body) body.style.display = _notifBodyCollapsed ? 'none' : '';
  if (btn)  btn.textContent    = _notifBodyCollapsed ? '▼' : '▲';
};
// Aplica estado salvo ao carregar
(function _applyNotifCollapseState() {
  if (!_notifBodyCollapsed) return;
  const body = document.getElementById('notif-body');
  const btn  = document.getElementById('notif-collapse-btn');
  if (body) body.style.display = 'none';
  if (btn)  btn.textContent    = '▼';
})();

function _updatePushPermStatus() {
  const activateWrap = document.getElementById('notif-activate-wrap');
  const togglesWrap  = document.getElementById('notif-toggles-wrap');
  const statusEl     = document.getElementById('notif-perm-status');
  const btnEl        = document.getElementById('notif-perm-btn');
  if (!activateWrap) return;

  // No iPhone, Web Push exige: HTTPS + standalone (instalado) + iOS 16.4+
  const isStandalone   = window.navigator.standalone === true ||
                         window.matchMedia('(display-mode: standalone)').matches;
  const isSecure       = window.isSecureContext;

  if (!isSecure) {
    if (statusEl) statusEl.textContent = '🔒 Requer HTTPS. Acesse via https:// para ativar notificações.';
    if (btnEl) btnEl.style.display = 'none';
    return;
  }
  if (!isStandalone) {
    if (statusEl) statusEl.textContent = '📲 Adicione à tela inicial primeiro:\nSafari → Compartilhar → "Adicionar à Tela de Início"';
    if (btnEl) btnEl.style.display = 'none';
    return;
  }
  if (!('Notification' in window) || !('PushManager' in window)) {
    if (statusEl) statusEl.textContent = '⚠️ Requer iOS 16.4 ou superior.';
    if (btnEl) btnEl.style.display = 'none';
    return;
  }

  const perm = Notification.permission;
  if (perm === 'granted') {
    activateWrap.style.display = 'none';
    if (togglesWrap) togglesWrap.style.display = '';
    _renderNotifToggles();
  } else {
    activateWrap.style.display = '';
    if (togglesWrap) togglesWrap.style.display = 'none';
    if (perm === 'denied') {
      if (btnEl) btnEl.style.display = 'none';
      if (statusEl) { statusEl.textContent = '✗ Bloqueado nas configurações do sistema.'; statusEl.style.color = 'var(--red)'; }
    } else {
      if (btnEl) btnEl.style.display = '';
      if (statusEl) statusEl.textContent = '';
    }
  }
}

window.requestPushPermission = async function() {
  try {
    await subscribePush();
    _updatePushPermStatus();
    showToast('✓ Notificações ativadas');
  } catch (err) {
    console.error('Push subscribe error:', err);
    showToast('✗ ' + (err?.message || 'Não foi possível ativar notificações'));
  }
};

// ── Central de notificações ───────────────────────────────────────────────────
let _notifCache      = null;   // último array buscado
let _notifLatestSeen = 0;      // último notif_latest_ts processado
let _notifReadTs     = parseInt(localStorage.getItem('notif_read_ts') || '0', 10);

async function _fetchNotifCache() {
  try {
    _notifCache = await apiFetch('/api/push/history').then(r => r.json());
  } catch (_) { _notifCache = _notifCache || []; }
  _updateBellBadge();
}

function _updateBellBadge() {
  const badge = document.getElementById('notif-bell-badge');
  if (!badge) return;
  const unread = (_notifCache || []).filter(n => n.ts > _notifReadTs).length;
  if (unread > 0) {
    badge.textContent  = unread > 9 ? '9+' : String(unread);
    badge.style.display = '';
  } else {
    badge.style.display = 'none';
  }
}

// Chamado pelo renderAll() — detecta novo notif_latest_ts via WS
function _checkNotifBadge() {
  const latest = state.notif_latest_ts || 0;
  if (latest !== _notifLatestSeen) {
    _notifLatestSeen = latest;
    _fetchNotifCache();
  }
}

window.openNotifHistory = function() {
  const overlay = document.getElementById('notif-overlay');
  if (!overlay) return;
  overlay.style.display = 'flex';
  // Renderiza cache imediatamente (com itens não lidos destacados)
  if (_notifCache) _renderNotifItems(_notifCache);
  else document.getElementById('notif-overlay-body').innerHTML =
    '<div style="font-size:12px;color:#3D5166;text-align:center;padding:20px 0">Carregando…</div>';
  // Busca versão mais recente e marca como lido
  apiFetch('/api/push/history').then(r => r.json()).then(data => {
    _notifCache = data;
    _renderNotifItems(data);          // renderiza antes de atualizar _notifReadTs
    _notifReadTs = Date.now();
    localStorage.setItem('notif_read_ts', String(_notifReadTs));
    _updateBellBadge();
  }).catch(() => {});
};

window.closeNotifHistory = function() {
  const overlay = document.getElementById('notif-overlay');
  if (overlay) overlay.style.display = 'none';
};

window.clearNotifHistory = async function() {
  try {
    await apiFetch('/api/push/history/clear', { method: 'POST' });
    _notifCache  = [];
    _notifReadTs = Date.now();
    localStorage.setItem('notif_read_ts', String(_notifReadTs));
    _renderNotifItems([]);
    _updateBellBadge();
    showToast('Histórico limpo');
  } catch (_) {
    showToast('✗ Erro ao limpar histórico');
  }
};

function _renderNotifItems(items) {
  const el = document.getElementById('notif-overlay-body');
  if (!el) return;
  if (!items || items.length === 0) {
    el.innerHTML = '<div style="font-size:12px;color:#3D5166;text-align:center;padding:32px 0">Nenhuma notificação registrada.</div>';
    return;
  }
  el.innerHTML = items.map(n => {
    const unread = n.ts > _notifReadTs;
    const d  = new Date(n.ts);
    const dd = d.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' });
    const tt = d.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
    return `<div style="display:flex;gap:10px;align-items:flex-start;padding:10px 0;border-bottom:1px solid #0F1520${unread ? ';background:rgba(77,187,255,.04);border-radius:6px;padding-left:6px' : ''}">
      ${unread ? '<span style="width:6px;height:6px;border-radius:50%;background:#4DBBFF;flex-shrink:0;margin-top:5px"></span>' : '<span style="width:6px;flex-shrink:0"></span>'}
      <div style="flex:1;min-width:0">
        <div style="display:flex;align-items:baseline;gap:8px;justify-content:space-between">
          <div style="font-size:13px;font-weight:${unread ? '700' : '600'};color:${unread ? '#EEF4FF' : '#C9D8EE'};line-height:1.3">${n.title}</div>
          <div style="font-size:10px;color:#3D5166;white-space:nowrap;flex-shrink:0">${dd} ${tt}</div>
        </div>
        ${n.body ? `<div style="font-size:11px;color:#5B7394;margin-top:2px">${n.body}</div>` : ''}
      </div>
    </div>`;
  }).join('');
}

// ── Actions panel — criado 100% em JS para sobreviver a cache antigo de index.html
function initActionsPanel() {
  const CARDS = [
    { title: '⚙️ Motor',
      statusFn: s => {
        const v = s.engine_state;
        if (v == null) return null;
        return (v === '1' || v === 1)
          ? { text: 'Ligado',    color: '#f87171' }
          : { text: 'Desligado', color: '#4ade80' };
      },
      items: [
        { label: '▶ Ligar',    cls: 'green', action: 'engine_on',  confirm: '⚙️ Ligar motor?',    msg: 'O motor térmico será ligado remotamente.',    color: '#22c55e' },
        { label: '■ Desligar', cls: 'red',   action: 'engine_off', confirm: '⚙️ Desligar motor?', msg: 'O motor térmico será desligado remotamente.', color: '#ef4444' },
      ]},
    { title: '🚗 Portas',
      statusFn: s => {
        const v = s.lock_state;
        if (v == null) return null;
        return v === 'on'
          ? { text: 'Abertas',  color: '#f87171' }
          : { text: 'Fechadas', color: '#4ade80' };
      },
      items: [
        { label: '🔓 Abrir',  cls: 'orange', action: 'lock_open',  confirm: '🔓 Abrir portas?',  msg: 'As portas serão destrancadas remotamente.', color: '#f97316' },
        { label: '🔒 Fechar', cls: 'teal',   action: 'lock_close', confirm: '🔒 Fechar portas?', msg: 'As portas serão trancadas remotamente.',     color: '#2dd4bf' },
      ]},
    { title: '🪟 Vidros',
      statusFn: s => {
        const vals = [s.window_fl, s.window_fr, s.window_rl, s.window_rr].filter(v => v != null);
        if (!vals.length) return null;
        // bridge agora armazena 'on'/'off' (não mais '1' do HA antigo)
        const anyOpen = vals.some(v => v === 'on');
        return anyOpen
          ? { text: 'Abertos',  color: '#f87171' }
          : { text: 'Fechados', color: '#4ade80' };
      },
      items: [
        { label: '↕ Abrir todos',  cls: 'orange', action: 'windows_open',  confirm: '🪟 Abrir vidros?',  msg: 'Todos os vidros serão abertos remotamente.',  color: '#f97316' },
        { label: '↕ Fechar todos', cls: 'teal',   action: 'windows_close', confirm: '🪟 Fechar vidros?', msg: 'Todos os vidros serão fechados remotamente.', color: '#2dd4bf' },
      ]},
    { title: '🧳 Porta-malas',
      statusFn: s => {
        const v = s.door_trunk;
        if (v == null) return null;
        return v === 'on'
          ? { text: 'Aberto',  color: '#f87171' }
          : { text: 'Fechado', color: '#4ade80' };
      },
      items: [
        { label: '↑ Abrir',  cls: 'orange', action: 'trunk_open',  confirm: '🧳 Abrir porta-malas?',  msg: 'A porta-malas será aberta remotamente.',  color: '#f97316' },
        { label: '↓ Fechar', cls: 'teal',   action: 'trunk_close', confirm: '🧳 Fechar porta-malas?', msg: 'A porta-malas será fechada remotamente.', color: '#2dd4bf' },
      ]},
    { title: '☀️ Teto solar',
      statusFn: s => {
        const v = s.sunroof;
        if (v == null) return null;
        // bridge agora armazena 'on'/'off' (não mais '3' do HA antigo)
        return v === 'off'
          ? { text: 'Fechado', color: '#4ade80' }
          : { text: 'Aberto',  color: '#f87171' };
      },
      items: [
        { label: '↑ Abrir',  cls: 'orange', action: 'sunroof_open',  confirm: '☀️ Abrir teto solar?',  msg: 'O teto solar será aberto remotamente.',  color: '#f97316' },
        { label: '↓ Fechar', cls: 'teal',   action: 'sunroof_close', confirm: '☀️ Fechar teto solar?', msg: 'O teto solar será fechado remotamente.', color: '#2dd4bf' },
      ]},
    { title: '❄️ Ar condicionado',
      statusFn: s => {
        const v = s.ac_state;
        if (v == null) return null;
        return v === 'on'
          ? { text: 'Ligado',     color: '#60a5fa' }
          : { text: 'Desligado',  color: '#4ade80' };
      },
      items: [
        { label: '❄️ Ativar ar condicionado', cls: 'blue full', action: 'ac_on', confirm: '❄️ Ligar AC?', msg: 'O ar condicionado será ativado remotamente.', color: '#60a5fa' },
      ]},
    { title: '⚡ Recarga',
      statusFn: null,
      items: [
        { label: '✕ Interromper recarga', cls: 'red full', action: 'charge_stop', confirm: '⚡ Interromper recarga?', msg: 'A recarga será interrompida remotamente.', color: '#ef4444' },
      ]},
  ];

  // Preenche mapa action→logId e lista de statusFns
  _actStatusFns = [];
  _actionLogMap = {};
  CARDS.forEach((card, i) => {
    _actStatusFns.push(card.statusFn || null);
    card.items.forEach(item => { _actionLogMap[item.action] = `act-log-${i}`; });
  });

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
  panel.innerHTML = CARDS.map((card, i) => `
    <div class="card">
      <div class="act-card-header">
        <div class="card-title" style="margin-bottom:0">${card.title}</div>
        ${card.statusFn ? `<span id="act-st-${i}" class="act-status"><span class="act-dot" style="background:#475569"></span><span>--</span></span>` : ''}
      </div>
      <div class="action-grid">
        ${card.items.map(item => `
          <button class="action-btn ${item.cls}"
            onclick="remoteAction('${item.action}','${item.confirm}','${item.msg}','${item.color}')">
            ${item.label}
          </button>`).join('')}
      </div>
      <div class="act-log" id="act-log-${i}"></div>
    </div>`).join('');
}

// Atualiza os badges de status na aba Ações com o estado atual
function updateActionStatuses(s) {
  _actStatusFns.forEach((fn, i) => {
    if (!fn) return;
    const el = document.getElementById(`act-st-${i}`);
    if (!el) return;
    const r = fn(s);
    if (!r) {
      el.innerHTML = '<span class="act-dot" style="background:#475569"></span><span>--</span>';
      el.style.color = '#475569';
    } else {
      el.innerHTML = `<span class="act-dot" style="background:${r.color}"></span><span>${r.text}</span>`;
      el.style.color = r.color;
    }
  });
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
let refreshing = false;   // escopo de módulo — usado também em hardRefresh()
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
  navigator.serviceWorker.addEventListener('controllerchange', () => {
    if (!refreshing) { refreshing = true; location.reload(); }
  });
}

// ── Hard refresh — limpa todos os caches SW e recarrega ───────────────────────
async function hardRefresh() {
  // Evita que o controllerchange (disparado pelo unregister) chame location.reload()
  // enquanto hardRefresh ainda está em andamento — isso causava dupla-navegação no iOS PWA
  refreshing = true;
  // A aba ativa é persistida em switchTab() — sobrevive a este reload e a qualquer
  // outro que aconteça depois (ex: controllerchange do SW).

  // 1. Apaga todos os caches do SW
  if ('caches' in window) {
    const keys = await caches.keys();
    await Promise.all(keys.map(k => caches.delete(k)));
  }
  // 2. Desregistra todos os SWs para que o próximo load seja sem interceptação
  if ('serviceWorker' in navigator) {
    const regs = await navigator.serviceWorker.getRegistrations();
    await Promise.all(regs.map(r => r.unregister()));
  }
  // 3. Volta para '/' limpa — sem ?_r= para não sujar a URL salva pelo PWA no iPhone
  window.location.replace('/');
}

function urlBase64ToUint8Array(b64) {
  const pad = '='.repeat((4 - b64.length % 4) % 4);
  const raw = atob((b64 + pad).replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from(raw, c => c.charCodeAt(0));
}

async function subscribePush() {
  if (!('Notification' in window) || !('PushManager' in window)) {
    _updatePushPermStatus();
    return;
  }
  let perm = Notification.permission;
  if (perm === 'denied') return;
  if (perm === 'default') perm = await Notification.requestPermission();
  if (perm !== 'granted') return;

  const reg = await navigator.serviceWorker.ready;

  // Busca a VAPID key atual do servidor e compara com a que foi usada na subscrição
  const { key: currentVapidKey } = await apiFetch('/api/push/vapid-key').then(r => r.json());
  if (!currentVapidKey) throw new Error('VAPID key não disponível');
  const storedVapidKey = localStorage.getItem('push_vapid_key');

  let sub = await reg.pushManager.getSubscription();

  // Se a VAPID key mudou (e.g. regenerada no servidor), descarta a subscrição antiga
  if (sub && storedVapidKey && storedVapidKey !== currentVapidKey) {
    console.log('VAPID key mudou — re-subscribing push');
    await sub.unsubscribe();
    // Limpa subscrições antigas no servidor também
    await apiFetch('/api/push/reset-subs', { method: 'POST' }).catch(() => {});
    sub = null;
  }

  if (!sub) {
    sub = await reg.pushManager.subscribe({
      userVisibleOnly: true,
      applicationServerKey: urlBase64ToUint8Array(currentVapidKey),
    });
    localStorage.setItem('push_vapid_key', currentVapidKey);
  }

  await apiFetch('/api/push/subscribe', {
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
  activePanel = btn.dataset.panel;
  document.getElementById('panel-' + activePanel).classList.add('active');
  // Persiste a aba ativa pra sobreviver a reloads (sw controllerchange,
  // hardRefresh, etc). sessionStorage morre ao fechar o PWA — comportamento
  // ideal: dentro da sessão restaura, em nova sessão volta pro default.
  try { sessionStorage.setItem('ecotrip_active_panel', activePanel); } catch (_) {}
  if (callback) callback();
  // Leaflet precisa recalcular o tamanho ao tornar-se visível
  if (activePanel === 'dash' && dashMap) {
    setTimeout(() => dashMap.invalidateSize(), 50);
  }
  // HF mode: ativa publish a 250ms enquanto cluster/conforto aberto.
  _updateHfMode();
}

// ── HF mode (alta frequência sob demanda) ────────────────────────────────────
// Quando o usuário está em cluster ou conforto, faz heartbeat pro bridge a cada
// 5s. Bridge publica cmd/hf_mode 1 no MQTT, APK reduz publishInterval pra 250ms.
// Watchdog do bridge desliga sozinho se não houver heartbeat por 10s.
let _hfHeartbeatTimer = null;
const HF_PANELS = new Set(['drive', 'comfort']);
function _hfPing(active) {
  apiFetch('/api/hf_mode', {
    method:  'POST',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ active }),
  }).catch(() => {/* offline — sem problema, bridge tem watchdog */});
}
function _updateHfMode() {
  const shouldBeOn = HF_PANELS.has(activePanel);
  if (shouldBeOn) {
    if (_hfHeartbeatTimer) return;          // já ativo
    _hfPing(true);
    _hfHeartbeatTimer = setInterval(() => _hfPing(true), 5000);
  } else {
    if (!_hfHeartbeatTimer) return;
    clearInterval(_hfHeartbeatTimer);
    _hfHeartbeatTimer = null;
    _hfPing(false);
  }
}
// Garante que ao sair da página (close tab, navega fora) o HF é desligado
window.addEventListener('beforeunload', () => {
  if (_hfHeartbeatTimer) {
    clearInterval(_hfHeartbeatTimer);
    _hfHeartbeatTimer = null;
    navigator.sendBeacon?.('/api/hf_mode', new Blob(
      [JSON.stringify({ active: false })],
      { type: 'application/json' },
    ));
  }
});

// ── WebSocket ─────────────────────────────────────────────────────────────────
function connect() {
  wsReconnectTimeout = null;
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
        // Detecta fim de recarga → tenta auto-tag de localização via GPS
        const newChgState = msg.data?.charging_state;
        if (newChgState && _prevChargingState === 'Carregando' && newChgState !== 'Carregando') {
          _tryAutoTagChargeLocation();
        }
        if (newChgState) _prevChargingState = newChgState;

        deepMerge(state, msg.data);
        _checkPendingConfirm(msg.data);
        lastUpdateMs = Date.now();
        // Throttle do render via rAF: agrupa múltiplos updates em um único repaint
        // (fast lane publica speed/RPM/power a 40 Hz — sem isso o main thread engasga).
        _scheduleRender();
        // Debounce do localStorage save: persistir state a 40 Hz era a causa de
        // travadas de segundos no iPhone (setItem é síncrono, ~10–30ms cada).
        _scheduleStatePersist();
      } else if (msg.type === 'AUTH_ERROR') {
        ws.close();
        showLogin('Senha incorreta ou expirada.');
        return;
      } else if (msg.type === 'charge_limit_result') {
        _onChargeLimitResult(msg.data?.result || '');
      } else if (msg.type === 'new_refuel') {
        // Abastecimento detectado pelo bridge — recarrega lista
        _loadRefuels().then(() => {
          const panel = document.getElementById('panel-charges');
          if (panel && panel.classList.contains('active')) renderCharges();
        });
      } else if (msg.type === 'new_autotrip') {
        // Nova viagem automática — sincroniza só o novo, sem derrubar o cache inteiro
        const autoPanel = document.getElementById('panel-auto');
        syncAllCache({ silent: true }).then(() => {
          // Atualiza o card de "Última viagem" no dash
          renderDash();
          if (autoPanel && autoPanel.classList.contains('active')) {
            renderAutoTrips();
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
        });
      } else if (msg.type === 'new_event') {
        if (cachedEvents) {
          cachedEvents.unshift(msg.data);
          if (cachedEvents.length > 2000) cachedEvents.pop();
          if (activePanel === 'logs') renderLogs();
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
    wsReconnectTimeout = setTimeout(connect, delay);
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
    elCar.textContent = iso ? relTime(new Date(iso).getTime()) : '--';
  }

  const sec = lastUpdateMs ? Math.floor((Date.now() - lastUpdateMs) / 1000) : 9999;
  if (state.car_online && sec < 30)  setStatus('online');
  else if (sec < 60)                 setStatus('connecting');
  else                               setStatus('offline');
}

// ── Helpers de formatação ─────────────────────────────────────────────────────
const f1  = v => (typeof v === 'number' ? v.toFixed(1)  : '--');
const f2  = v => (typeof v === 'number' ? v.toFixed(2)  : '--');
const f3  = v => (typeof v === 'number' ? v.toFixed(3)  : '--');
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
function setHTML(id, html) {
  const el = document.getElementById(id);
  if (el) el.innerHTML = html;
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
// Tempo compacto em 2 componentes com unidades minúsculas (para cards do dash)
// < 60min → "45<min>"  |  < 24h → "1<h >40<min>"  |  ≥ 24h → "2<d >3<h>"
function fmtDashTime(v) {
  const du = s => `<span class="dash-unit">${s}</span>`;
  let sec = 0;
  if (typeof v === 'number') { sec = v; }
  else if (typeof v === 'string' && v !== '--') {
    const h = +(v.match(/(\d+)\s*h/)   || [0,0])[1];
    const m = +(v.match(/(\d+)\s*min/) || [0,0])[1];
    const s = +(v.match(/(\d+)\s*s\b/) || [0,0])[1];
    sec = h * 3600 + m * 60 + s;
  }
  if (!sec) return '--';
  const days = Math.floor(sec / 86400);
  const hrs  = Math.floor((sec % 86400) / 3600);
  const mins = Math.floor((sec % 3600) / 60);
  if (days > 0) return days + du('d ') + hrs  + du('h');
  if (hrs  > 0) return hrs  + du('h ') + mins + du('min');
  return mins + du('min');
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
  charges:     { active: 'today', customFrom: '', customTo: '', location: null, type: 'all' },
  auto:        { active: 'today', customFrom: '', customTo: '', search: '' },
  logs:        { active: 'all',   type: 'all',   customFrom: '', customTo: '' },
  stats:       { active: 'all',   customFrom: '', customTo: '' },
};
let cachedCharges = null;
let cachedRefuels = null;
// Versão monotônica das caches — bumped a cada mutação de cachedCharges/cachedRefuels.
// Usado pra invalidar índices derivados (Map<ts,charge>, timeline de preços) sem
// precisar stringify do conteúdo a cada lookup.
let _cachesVersion        = 0;
let _chargesByTs          = null;
let _chargesByTsVersion   = -1;
function _bumpCachesVersion() { _cachesVersion++; }
function _getChargesByTs() {
  if (_chargesByTsVersion !== _cachesVersion) {
    _chargesByTs = new Map();
    if (cachedCharges) for (const c of cachedCharges) _chargesByTs.set(c.timestamp_ms || 0, c);
    _chargesByTsVersion = _cachesVersion;
  }
  return _chargesByTs;
}
let _tankAvgPriceL = 0;     // R$/L médio atual no tanque (vem do bridge)
let _batteryAvgPriceKwh = 0;// R$/kWh médio atual na bateria
let cachedEvents  = null;
// cachedTrips removido — Trip A/B descontinuados.
let _knownLocations    = [];
let _locPickerTs       = 0;
let _locPickerLat      = null;
let _locPickerLng      = null;
let _locSelectedKnownId = null;  // id do local conhecido selecionado no picker
let _locKnownPlaces    = [];    // cache dos locais conhecidos carregados no picker
let _prevChargingState = null;   // para detectar fim de recarga no WS

// ── Cache local — IndexedDB ────────────────────────────────────────────────
const _IDB_NAME = 'ecotrip-trips';
const _IDB_VER  = 1;
let _idb = null;

function _openIDB() {
  if (_idb) return Promise.resolve(_idb);
  return new Promise((res, rej) => {
    const r = indexedDB.open(_IDB_NAME, _IDB_VER);
    r.onupgradeneeded = e => {
      const db = e.target.result;
      if (!db.objectStoreNames.contains('trips'))    db.createObjectStore('trips',    { keyPath: 'timestamp' });
      if (!db.objectStoreNames.contains('autotrips'))db.createObjectStore('autotrips',{ keyPath: 'tripId' });
      if (!db.objectStoreNames.contains('charges'))  db.createObjectStore('charges',  { keyPath: 'timestamp_ms' });
      if (!db.objectStoreNames.contains('meta'))     db.createObjectStore('meta');
    };
    r.onsuccess = e => { _idb = e.target.result; res(_idb); };
    r.onerror   = e => rej(e.target.error);
  });
}
function _idbGetAll(store) {
  return _openIDB().then(db => new Promise((res, rej) => {
    const req = db.transaction(store, 'readonly').objectStore(store).getAll();
    req.onsuccess = () => res(req.result || []);
    req.onerror   = e => rej(e.target.error);
  }));
}
function _idbPutMany(store, items) {
  if (!items.length) return Promise.resolve();
  return _openIDB().then(db => new Promise((res, rej) => {
    const tx = db.transaction(store, 'readwrite');
    const os = tx.objectStore(store);
    items.forEach(item => os.put(item));
    tx.oncomplete = res;
    tx.onerror    = e => rej(e.target.error);
  }));
}
function _idbGetMeta(key) {
  return _openIDB().then(db => new Promise((res, rej) => {
    const req = db.transaction('meta', 'readonly').objectStore('meta').get(key);
    req.onsuccess = () => res(req.result ?? null);
    req.onerror   = e => rej(e.target.error);
  }));
}
function _idbSetMeta(key, val) {
  return _openIDB().then(db => new Promise((res, rej) => {
    const tx = db.transaction('meta', 'readwrite');
    tx.objectStore('meta').put(val, key);
    tx.oncomplete = res;
    tx.onerror    = e => rej(e.target.error);
  }));
}
function _idbClearAll() {
  return _openIDB().then(db => new Promise((res, rej) => {
    const tx = db.transaction(['trips','autotrips','charges','meta'], 'readwrite');
    ['trips','autotrips','charges','meta'].forEach(s => tx.objectStore(s).clear());
    tx.oncomplete = res;
    tx.onerror    = e => rej(e.target.error);
  }));
}

function _idbClearStore(store) {
  return _openIDB().then(db => new Promise((res, rej) => {
    const tx = db.transaction(store, 'readwrite');
    tx.objectStore(store).clear();
    tx.oncomplete = res;
    tx.onerror    = e => rej(e.target.error);
  }));
}

function _idbDelete(store, key) {
  return _openIDB().then(db => new Promise((res, rej) => {
    const tx = db.transaction(store, 'readwrite');
    tx.objectStore(store).delete(key);
    tx.oncomplete = res;
    tx.onerror    = e => rej(e.target.error);
  }));
}

async function loadKnownLocations() {
  try {
    _knownLocations = await apiFetch('/api/charge-locations').then(r => r.json());
  } catch (_) { _knownLocations = []; }
}

// ── Barra de progresso de sync ─────────────────────────────────────────────
function _syncProgressShow(msg) {
  let el = document.getElementById('sync-progress');
  if (!el) {
    el = document.createElement('div');
    el.id = 'sync-progress';
    el.style.cssText = 'padding:6px 12px;font-size:12px;color:#7FBADC;text-align:center;opacity:.85';
  }
  el.textContent = msg;
  const active = document.querySelector('.panel.active [id$="-list"]');
  if (active && !active.contains(el)) active.prepend(el);
}
function _syncProgressHide() {
  document.getElementById('sync-progress')?.remove();
}

// ── Sync incremental das 3 coleções ───────────────────────────────────────
async function syncAllCache({ silent = false } = {}) {
  const totals = { auto: 0, charges: 0 };
  try {
    if (!silent) _syncProgressShow('⟳ Sincronizando…');

    // Trip A/B descontinuados — não sincroniza mais.

    // Auto-trips
    const lastMs  = (await _idbGetMeta('lastAutoMs')) || 0;
    const newAuto = await apiFetch('/api/autotrips' + (lastMs > 0 ? '?since=' + lastMs : ''))
      .then(r => r.json()).catch(() => []);
    if (Array.isArray(newAuto) && newAuto.length) {
      await _idbPutMany('autotrips', newAuto);
      totals.auto = newAuto.length;
      const maxMs = Math.max(...newAuto.map(t => t.startMs || 0));
      if (maxMs > 0) await _idbSetMeta('lastAutoMs', maxMs);
      newAuto.forEach(t => {
        if (t.startLat && t.startLat !== 0) queueGeocode(t.tripId, t.startLat, t.startLng);
        if (t.endLat   && t.endLat   !== 0) queueGeocode(t.tripId, t.endLat,   t.endLng, t.tripId + ':end');
      });
      if (!silent) _syncProgressShow('⟳ +' + totals.auto + ' auto-trip' + (totals.auto !== 1 ? 's' : '') + '…');
    }
    cachedAutoTrips = (await _idbGetAll('autotrips'))
      .sort((a, b) => (b.startMs || 0) - (a.startMs || 0));

    // Recargas — cursor usa max(timestamp_ms, _updated_ms) para capturar
    // tanto novas recargas quanto atualizações em recargas antigas (local, custo, kWh)
    const lastChg = (await _idbGetMeta('lastChargeMs')) || 0;
    const newChg  = await apiFetch('/api/charges' + (lastChg > 0 ? '?since=' + lastChg : ''))
      .then(r => r.json()).catch(() => []);
    if (Array.isArray(newChg) && newChg.length) {
      await _idbPutMany('charges', newChg);
      totals.charges = newChg.length;
      // Avança cursor para o maior entre timestamp_ms e _updated_ms
      const maxChg = Math.max(...newChg.map(c => Math.max(c.timestamp_ms || 0, c._updated_ms || 0)));
      if (maxChg > 0) await _idbSetMeta('lastChargeMs', maxChg);
    }
    cachedCharges = (await _idbGetAll('charges'))
      .sort((a, b) => (b.timestamp_ms || 0) - (a.timestamp_ms || 0));
    _bumpCachesVersion();

    // Grava timestamp da última sync bem-sucedida
    await _idbSetMeta('lastSyncTs', Date.now());

    // Feedback
    const total = totals.trips + totals.auto + totals.charges;
    if (!silent) {
      if (total > 0) {
        const parts = [];
        if (totals.trips)   parts.push(totals.trips   + ' trip' + (totals.trips   !== 1 ? 's' : ''));
        if (totals.auto)    parts.push(totals.auto    + ' auto-trip' + (totals.auto    !== 1 ? 's' : ''));
        if (totals.charges) parts.push(totals.charges + ' recarga' + (totals.charges !== 1 ? 's' : ''));
        _syncProgressShow('✓ ' + parts.join(', ') + ' baixados');
        setTimeout(_syncProgressHide, 3000);
      } else {
        _syncProgressHide();
      }
    }
  } catch (e) {
    console.warn('syncAllCache:', e);
    if (!silent) _syncProgressHide();
  }
  return totals;
}

// Popula o resumo simples no card "Histórico & Backup". Fonte única = servidor.
// Se cache local divergir, mostra dica discreta de atualização (auto via Reconciliar).
async function renderHistCounts() {
  const el = document.getElementById('hist-counts');
  if (!el) return;
  try {
    const c = await apiFetch('/api/counts').then(r => r.json());
    const refuels = cachedRefuels ? cachedRefuels.length : '?';
    let extra = '';
    // Detecta divergência IDB ↔ servidor pra sugerir reconciliar
    try {
      const [lA, lC] = await Promise.all([
        _idbGetAll('autotrips').then(a => a.length),
        _idbGetAll('charges').then(a => a.length),
      ]);
      if ((lA > 0 || lC > 0) && (lA !== c.autotrips || lC !== c.charges)) {
        extra = `<div style="margin-top:6px;font-size:10px;color:#fbbf24">⚠️ Cache local difere do histórico (${lA} vs ${c.autotrips} viagens). Use "Reconciliar" pra ajustar.</div>`;
      }
    } catch (_) {}
    el.innerHTML =
      `<div>🛣️ <strong>${c.autotrips}</strong> viagens</div>` +
      `<div>⚡ <strong>${c.charges}</strong> recargas</div>` +
      `<div>⛽ <strong>${refuels}</strong> abastecimentos</div>` +
      extra;
  } catch (e) {
    el.textContent = 'Não foi possível carregar (offline?)';
  }
}
window.renderHistCounts = renderHistCounts;

async function adminCacheStatus() {
  _cacheSetStatus('⏳ Verificando...', null);
  try {
    const [lTrips, lAuto, lChg, lastTs] = await Promise.all([
      _idbGetAll('trips').then(a => a.length),
      _idbGetAll('autotrips').then(a => a.length),
      _idbGetAll('charges').then(a => a.length),
      _idbGetMeta('lastSyncTs'),
    ]);

    let sTrips = '?', sAuto = '?', sChg = '?';
    try {
      const c = await apiFetch('/api/counts').then(r => r.json());
      sTrips = c.trips; sAuto = c.autotrips; sChg = c.charges;
    } catch (_) { sTrips = sAuto = sChg = 'offline'; }

    const syncTime = lastTs
      ? new Date(lastTs).toLocaleString('pt-BR', { day:'2-digit', month:'2-digit', hour:'2-digit', minute:'2-digit' })
      : 'nunca';

    const allMatch = lTrips === sTrips && lAuto === sAuto && lChg === sChg;
    _cacheSetStatus(
      '📱 Local:    ' + lTrips + ' trips · ' + lAuto + ' auto · ' + lChg + ' rec\n' +
      '🌐 Servidor: ' + sTrips + ' trips · ' + sAuto + ' auto · ' + sChg + ' rec\n' +
      '🕐 Última sync: ' + syncTime,
      allMatch ? true : null
    );
  } catch (e) {
    _cacheSetStatus('Erro: ' + e.message, false);
  }
}

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
  if (tabId === 'charges')     renderCharges();
  if (tabId === 'auto')        renderAutoTrips();
  if (tabId === 'stats')       loadStats();
}

function setFilterDates(tabId) {
  const fe = document.getElementById(`filter-${tabId}-from`);
  const te = document.getElementById(`filter-${tabId}-to`);
  if (fe) filterState[tabId].customFrom = fe.value;
  if (te) filterState[tabId].customTo   = te.value;
  setFilter(tabId, 'custom');
}

// ── Filtro por local (aba recargas) ───────────────────────────────────────────
let _chargesLocList = [];  // índice estável para onclick (evita escape de strings)

window.setChargesLocation = function(idx) {
  filterState.charges.location = idx < 0 ? null : (_chargesLocList[idx] ?? null);
  renderCharges();
};

function _locationChipsHTML() {
  // Extrai locais únicos de TODAS as recargas (independente do filtro de data)
  const all = cachedCharges || [];
  const seen = new Set();
  _chargesLocList = [];
  for (const c of all) {
    const n = c.location_name || null;
    if (n && !seen.has(n)) { seen.add(n); _chargesLocList.push(n); }
  }
  _chargesLocList.sort((a, b) => a.localeCompare(b, 'pt-BR'));
  if (!_chargesLocList.length) return '';

  const cur = filterState.charges.location;
  const chip = (label, idx) => {
    const active = (idx < 0 && cur === null) || (idx >= 0 && _chargesLocList[idx] === cur);
    return `<button class="filter-chip${active ? ' active' : ''}" onclick="setChargesLocation(${idx})">${label}</button>`;
  };
  let chips = chip('Todos locais', -1);
  _chargesLocList.forEach((n, i) => { chips += chip('📍 ' + n, i); });
  return `<div class="filter-chips" style="margin-top:4px">${chips}</div>`;
}

window.setSearchQuery = function(tabId, value) {
  filterState[tabId].search = value;
  if (tabId === 'auto') renderAutoTrips();
  // Restaura foco e cursor ao fim (necessário pois innerHTML é recriado)
  const inp = document.getElementById(`filter-search-${tabId}`);
  if (inp && document.activeElement !== inp) {
    inp.focus();
    try { inp.setSelectionRange(value.length, value.length); } catch (_) {}
  }
};

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
  const search = (tabId === 'auto') ? `
<div class="filter-search">
  <span class="filter-search-icon">🔍</span>
  <input type="search" id="filter-search-${tabId}" class="filter-search-input"
    placeholder="Buscar por nome…" value="${(f.search || '').replace(/"/g,'&quot;')}"
    oninput="setSearchQuery('${tabId}', this.value)">
</div>` : '';
  return `<div class="filter-chips">${c('all','Tudo')}${c('today','Hoje')}${c('7d','7 dias')}${c('30d','30 dias')}${c('month','Mês')}${c('custom','Custom')}</div>${dates}${search}`;
}

// ── Render ────────────────────────────────────────────────────────────────────
// Coalesce de updates: a fast lane do app publica speed/RPM/power a 40 Hz; sem
// throttle, o main thread no iPhone fica saturado e a UI trava por segundos.
let _renderPending = false;
function _scheduleRender() {
  if (_renderPending) return;
  _renderPending = true;
  requestAnimationFrame(() => {
    _renderPending = false;
    renderAll();
  });
}

// localStorage.setItem é síncrono e custoso (~10-30ms no iPhone Safari). Persistir
// a cada msg WS travava o thread. Debounce de 500ms reduz pra 2 escritas/seg
// (~20-60ms/seg de I/O — invisível), e em caso de reload o WS reenvia o full_state
// em <500ms, mascarando a defasagem.
let _persistTimer = null;
function _scheduleStatePersist() {
  if (_persistTimer) return;
  _persistTimer = setTimeout(() => {
    _persistTimer = null;
    try { localStorage.setItem('ecotrip_state', JSON.stringify({ state, ts: lastUpdateMs })); } catch(_) {}
  }, 500);
}

function renderAll() {
  renderDash();
  renderDrivePanel();
  renderCarVersion();
  updateActionStatuses(state);
  _checkNotifBadge();
}

function renderCarVersion() {
  const el = document.getElementById('car-version-badge');
  if (!el) return;
  const v = state.car_app_version;
  if (v) { el.textContent = 'v' + v; el.classList.add('visible'); }
  else   { el.classList.remove('visible'); }
}

function renderDash() {
  const s = state;
  setText('d-car-temp-in',  s.inside_temp  ? f1(s.inside_temp)  + '°' : '--°');
  setText('d-car-temp-out', s.outside_temp ? f1(s.outside_temp) + '°' : '--°');

  // Odômetro total
  const odo = s.odometer_km || 0;
  setText('d-odometer', odo > 0 ? Math.round(odo).toLocaleString('pt-BR') : '--');

  // Marcha — badge no header do card do carro
  const gearEl  = document.getElementById('d-gear-badge');
  if (gearEl) {
    const gRaw   = (s.gear || '').toString().trim();
    const g      = gRaw.toUpperCase();
    const invalid = gRaw === '-1' || gRaw === '' || gRaw === '--';
    if (invalid) {
      gearEl.style.display = 'none';
    } else {
      gearEl.style.display = '';
      const gCfg = ({
        P: { bg: '#1e293b', color: '#64748b' },
        D: { bg: '#052e16', color: '#4ade80' },
        R: { bg: '#2a1200', color: '#fb923c' },
        N: { bg: '#1e293b', color: '#94a3b8' },
      })[g] || { bg: '#1e293b', color: '#475569' };
      gearEl.style.background = gCfg.bg;
      gearEl.style.color      = gCfg.color;
      gearEl.textContent      = g;
    }
  }

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
  const soc = s.soc_pct || 0;
  setText('d-soc', pct(soc));
  const socBar = document.getElementById('d-soc-bar');
  if (socBar) socBar.style.width = Math.max(0, Math.min(100, soc)) + '%';

  // ── Autonomia elétrica + térmica estimadas ────────────────────────────────
  // Pack total H6 PHEV = 34 kWh. EV_MIN_SOC = 12% (reserva mínima — abaixo
  // disso o motor térmico já entra). Usável de 100% a 12% = ~30 kWh.
  const BATT_KWH      = 34, EV_MIN_SOC = 12;
  // Floor de 14 kWh/100km: abaixo disso o motor térmico estava carregando
  // a bateria (gerador), o que contamina o consumo elétrico com valores
  // artificialmente baixos — esse dado não reflete autonomia real em EV puro.
  const EV_KWH_FLOOR    = 12;
  const EV_KWH_FALLBACK = 20;   // conservador: 1 kWh = 5 km
  const KML_FALLBACK    = 12;   // 12 km/L

  const rollingDist = s.rolling?.distance_km || 0;

  // Média elétrica — rolling window. Só usa se ≥10 km e consumo realista
  // (acima do floor — evita inflar com regen + gerador térmico).
  const rollingKwh100 = rollingDist > 10 && (s.rolling?.kwh_per_100km || 0) >= EV_KWH_FLOOR
                        ? s.rolling.kwh_per_100km : null;
  const avgKwh100 = rollingKwh100 ?? EV_KWH_FALLBACK;

  // Média térmica — só usa se queimou ≥ 1L (evita km/L inflado em viagens
  // quase totalmente elétricas).
  const rollingKml = (s.rolling?.fuel_l || 0) > 1 && (s.rolling?.km_per_l || 0) > 2
                     ? s.rolling.km_per_l : null;
  const avgKmL = rollingKml ?? KML_FALLBACK;

  const usableKwh  = Math.max(0, (soc - EV_MIN_SOC) / 100 * BATT_KWH);
  let evKmCalc   = Math.round(usableKwh / (avgKwh100 / 100));
  // Correção por temperatura externa (frio reduz range; quente neutro).
  // Heurística: abaixo de 15°C reduz ~1.5% por °C abaixo. Acima de 30°C
  // reduz ~1% por °C acima (uso de AC pesado). Em climas BR é raro frio.
  const extT = parseFloat(s.outside_temp);
  if (Number.isFinite(extT)) {
    let factor = 1;
    if (extT < 15) factor = 1 - Math.min(0.30, (15 - extT) * 0.015);
    else if (extT > 30) factor = 1 - Math.min(0.15, (extT - 30) * 0.010);
    evKmCalc = Math.round(evKmCalc * factor);
  }
  // Autonomia oficial vinda do TCU do carro (mesma fonte usada na aba Drive/cluster).
  // O sensor range_ev_km do HA dava valores divergentes — autonomy_ev_km é a fonte
  // de verdade.
  const realEvKm   = Math.round(+s.autonomy_ev_km || 0);
  const evRangeEl  = document.getElementById('d-ev-range');
  if (evRangeEl) {
    if (realEvKm > 0 && evKmCalc > 0 && soc > EV_MIN_SOC) {
      // Mostra AMBOS: oficial do carro + estimado pelo consumo real
      evRangeEl.style.display = '';
      const diff = realEvKm - evKmCalc;
      const diffPct = realEvKm > 0 ? Math.abs(diff) / realEvKm * 100 : 0;
      const diffCls = diffPct > 15 ? (diff > 0 ? 'color:#fb923c' : 'color:#4ade80') : 'color:var(--teal)';
      const evEl = document.getElementById('d-ev-km');
      if (evEl) evEl.parentElement.innerHTML =
        `<span id="d-ev-km">${realEvKm}</span> km elétricos · <span style="${diffCls}">~${evKmCalc} reais</span>`;
    } else if (realEvKm > 0) {
      evRangeEl.style.display = '';
      setText('d-ev-km', realEvKm);
    } else if (soc > EV_MIN_SOC) {
      evRangeEl.style.display = '';
      setText('d-ev-km', '~' + evKmCalc);
    } else {
      evRangeEl.style.display = 'none';
    }
  }

  // Combustível (tank 55L — H6 PHEV) — fuel_l vem direto da GWM Brasil em litros
  const TANK_CAP = 55;
  const tankNow = s.fuel_l > 0 ? +s.fuel_l : 0;
  const fuelPct = tankNow > 0 ? Math.min(100, (tankNow / TANK_CAP) * 100) : 0;
  setText('d-fuel', tankNow > 0 ? f1(tankNow) + ' L  (' + fuelPct.toFixed(0) + '%)' : '--');
  const fuelBar = document.getElementById('d-fuel-bar');
  if (fuelBar) fuelBar.style.width = Math.max(0, Math.min(100, fuelPct)) + '%';

  // Autonomia térmica: real (sensor HA) → fallback estimada
  const fuelKmCalc   = tankNow > 0 ? Math.round(tankNow * avgKmL) : 0;
  const realIceKm    = Math.round(+s.autonomy_ice_km || 0);
  const fuelRangeEl  = document.getElementById('d-fuel-range');
  if (fuelRangeEl) {
    if (realIceKm > 0) {
      fuelRangeEl.style.display = '';
      setText('d-fuel-km', realIceKm);
    } else if (fuelKmCalc > 0) {
      fuelRangeEl.style.display = '';
      setText('d-fuel-km', '~' + fuelKmCalc);
    } else {
      fuelRangeEl.style.display = 'none';
    }
  }

  // Recarga — integrada no card d-bfc-card (card único)
  const isCharging = s.charging_state === 'Carregando';
  const bfcCard = document.getElementById('d-bfc-card');
  if (bfcCard) bfcCard.classList.toggle('chrg-active', isCharging);
  // Propaga estado de recarga pro painel inteiro — permite CSS reduzir altura
  // do mapa enquanto carregando, liberando espaço pro card de bateria expandido.
  const panelDash = document.getElementById('panel-dash');
  if (panelDash) {
    const wasCharging = panelDash.classList.contains('charging');
    panelDash.classList.toggle('charging', isCharging);
    // Mapa Leaflet não recalcula sozinho quando o container muda — chama após a transição
    if (wasCharging !== isCharging && dashMap) {
      setTimeout(() => dashMap.invalidateSize(), 280);
    }
  }
  // Alterna seções dentro do card unificado
  const _vis = (id, show) => { const el = document.getElementById(id); if (el) el.style.display = show ? '' : 'none'; };
  _vis('bfc-normal-hdr',   !isCharging);
  _vis('bfc-chrg-hdr',      isCharging);
  _vis('bfc-soc-normal',   !isCharging);
  _vis('bfc-soc-charging',  isCharging);
  _vis('bfc-chrg-limit',    isCharging);
  if (isCharging) {
    const cu = u => `<span class="chrg-unit">${u}</span>`;
    setHTML('d-chrg-power',   s.charge_power_kw   > 0 ? f1(s.charge_power_kw)    + cu(' kW')  : '--');
    setHTML('d-chrg-session', s.charge_session_kwh > 0 ? f2(s.charge_session_kwh) + cu(' kWh') : '--');
    setHTML('d-chrg-avg',     s.charge_avg_power_kw > 0 ? f1(s.charge_avg_power_kw) + cu(' kW') : '--');
    setHTML('d-chrg-peak',    s.charge_max_power_kw > 0 ? f1(s.charge_max_power_kw) + cu(' kW') : '--');
    const rem = s.charge_remaining_min || 0;
    if (rem > 0) {
      const remStr = rem > 59
        ? Math.floor(rem / 60) + cu('h ') + (rem % 60) + cu('min')
        : rem + cu(' min');
      setHTML('d-chrg-remain', remStr);
      const finish = new Date(Date.now() + rem * 60000);
      setText('d-chrg-finish',
        finish.getHours().toString().padStart(2,'0') + ':' +
        finish.getMinutes().toString().padStart(2,'0'));
    } else {
      setHTML('d-chrg-remain', '--');
      setText('d-chrg-finish', '--');
    }
    // Barra de progresso SOC
    const soc = s.soc_pct || 0;
    const lim = s.charge_limit_pct != null ? s.charge_limit_pct : 100;
    const barFill = document.getElementById('d-chrg-bar-fill');
    if (barFill) barFill.style.width = Math.min(Math.max(soc, 0), 100) + '%';
    const marker = document.getElementById('d-chrg-bar-marker');
    if (marker) marker.style.left = Math.min(lim, 100) + '%';
    // Marcador sutil do SOC de início — só mostra se temos o valor e ele faz sentido
    const startSoc = s.charge_start_soc_pct || 0;
    const startMarker = document.getElementById('d-chrg-bar-start');
    if (startMarker) {
      if (startSoc > 0 && startSoc < 100 && startSoc < soc) {
        startMarker.style.left = Math.min(startSoc, 100) + '%';
        startMarker.style.display = '';
      } else {
        startMarker.style.display = 'none';
      }
    }
    setText('d-chrg-soc-cur', Math.round(soc) + '%');
    setText('d-chrg-soc-lim', '▶ ' + Math.round(lim) + '%');
    _renderChargeLimit(s.charge_limit_pct);
  }
  // Limite de carga SOC no painel de configurações — atualiza sempre (independe de carregando)
  _renderChargeLimit(s.charge_limit_pct);

  // ── Camadas PNG do carro ─────────────────────────────────────────────────────
  function carLayer(id, show) {
    const el = document.getElementById(id);
    if (el) el.style.display = show ? 'block' : 'none';
  }

  const eng   = s.engine_state;
  const engOn = eng === '1' || eng === 1;

  // Layout do dashboard: motor ligado → mapa sobe, alertas descem
  if (panelDash) panelDash.classList.toggle('engine-on', engOn);

  // Faróis — ligados com o motor (farol alto via sensor futuro high_beam)
  carLayer('cl-farol',      engOn && s.high_beam !== 'on');
  carLayer('cl-farol-alto', s.high_beam === 'on');
  const engBtn   = document.getElementById('d-engine-btn');
  const engLabel = document.getElementById('d-car-engine-label');
  if (engLabel) {
    if (engOn) {
      engLabel.textContent = '⚙ ON';
      engLabel.style.color = '#4ade80';
      if (engBtn) { engBtn.style.background = '#0d2b1a'; engBtn.style.borderColor = '#166534'; }
    } else if (eng === '0' || eng === 0) {
      engLabel.textContent = '⚙ OFF';
      engLabel.style.color = '#475569';
      if (engBtn) { engBtn.style.background = ''; engBtn.style.borderColor = ''; }
    } else {
      engLabel.textContent = '⚙ --';
      engLabel.style.color = '#334155';
      if (engBtn) { engBtn.style.background = ''; engBtn.style.borderColor = ''; }
    }
  }

  // Trava
  const lck = s.lock_state;
  carLayer('cl-trava', lck === 'off');
  const lockBtn   = document.getElementById('d-lock-btn');
  const lockLabel = document.getElementById('d-car-lock-label');
  if (lockLabel) {
    if (lck === 'off') {
      // 'off' = TRANCADO (layer cl-trava ativa)
      lockLabel.textContent = '🔒 Travado';
      lockLabel.style.color = '#4ade80';
      if (lockBtn) { lockBtn.style.background = '#0d2b1a'; lockBtn.style.borderColor = '#166534'; }
    } else if (lck === 'on') {
      // 'on' = DESTRANCADO
      lockLabel.textContent = '🔓 Destravado';
      lockLabel.style.color = '#f87171';
      if (lockBtn) { lockBtn.style.background = '#450a0a'; lockBtn.style.borderColor = '#dc2626'; }
    } else {
      lockLabel.textContent = '🔒 --';
      lockLabel.style.color = '#334155';
      if (lockBtn) { lockBtn.style.background = ''; lockBtn.style.borderColor = ''; }
    }
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

  // Teto solar — bridge agora armazena 'on'/'off' (não mais valor HA cru '3')
  carLayer('cl-sunroof', s.sunroof === 'on');

  // AC — ícone com texto colorido + glow quando ligado
  const acOn = s.ac_state === 'on';
  carLayer('cl-ac-left',    acOn);
  carLayer('cl-ac-right',   acOn);
  carLayer('cl-ventilacao', acOn);
  const acChip = document.getElementById('d-ac-chip');
  if (acChip) {
    if (acOn) {
      acChip.style.color = '#22d3ee';
      acChip.style.textShadow = '0 0 8px rgba(34,211,238,0.55)';
    } else {
      acChip.style.color = '#475569';
      acChip.style.textShadow = '';
    }
  }

  // Ventilação dos bancos — 4 níveis (0=off, 1=fraco, 2=médio, 3=forte)
  // Cor + opacity + glow refletem a intensidade. Vermelho não usado pois é "ruim" semanticamente;
  // gradient cyan→lime cresce em brilho conforme nivel sobe.
  // Tabela: [opacity, strokeColor, glowShadow]
  const SEAT_VENT_STYLE = {
    0: { opacity: 0.30, color: '#334155', shadow: 'none' },                                  // desligado
    1: { opacity: 0.85, color: '#7dd3fc', shadow: '0 0 4px rgba(125,211,252,0.55)' },        // fraco — light cyan
    2: { opacity: 1.00, color: '#22d3ee', shadow: '0 0 6px rgba(34,211,238,0.65)' },         // médio — bright cyan
    3: { opacity: 1.00, color: '#5eead4', shadow: '0 0 10px rgba(94,234,212,0.85)' },        // forte — teal-lime glow
  };
  function applySeatVent(elId, rawLevel) {
    const el = document.getElementById(elId);
    if (!el) return;
    const lvl = parseInt(rawLevel, 10);
    const valid = Number.isFinite(lvl) && lvl >= 0 && lvl <= 3;
    const style = SEAT_VENT_STYLE[valid ? lvl : 0];
    el.style.opacity = style.opacity;
    el.style.filter  = style.shadow === 'none' ? 'none' : `drop-shadow(${style.shadow})`;
    el.querySelectorAll('.vent-line').forEach(p => p.setAttribute('stroke', style.color));
  }
  applySeatVent('d-seat-drv',  s.seat_vent_drv);
  applySeatVent('d-seat-pass', s.seat_vent_pass);

  // ── Aba Conforto: cabine top-down ─────────────────────────────────────────
  // AC vents glow + ondas animadas quando ligado
  document.querySelectorAll('.cmf-ac-vent').forEach(v => v.classList.toggle('on', acOn));
  const cmfWaves = document.getElementById('cmf-ac-waves');
  if (cmfWaves) cmfWaves.style.display = acOn ? '' : 'none';
  const cmfAcText = document.getElementById('cmf-ac-text');
  if (cmfAcText) {
    cmfAcText.textContent = acOn ? 'Ligado' : 'Desligado';
    cmfAcText.style.color = acOn ? '#22d3ee' : '#475569';
  }

  // Seat ventilation: ilumina N fileiras de dots (1 fileira por nível, de baixo pra cima)
  // Nível 0 = nenhuma · Nível 1 = fila inferior · Nível 2 = inferior+meio · Nível 3 = todas
  function applyCabinSeat(groupId, textId, rawLevel) {
    const group = document.getElementById(groupId);
    const text  = document.getElementById(textId);
    if (!group) return;
    const lvl = parseInt(rawLevel, 10);
    const valid = Number.isFinite(lvl) && lvl >= 0 && lvl <= 3;
    const v = valid ? lvl : 0;
    // Skip se o usuário está mexendo no banco (drag/pending) — preserva preview
    const busy = (typeof _hvacIsBusy === 'function') && _hvacIsBusy(textId);
    if (!busy) _updateSeatDots(groupId, v);
    if (text) {
      const labels = ['Desligado', 'Fraco', 'Médio', 'Forte'];
      const colors = ['#475569',   '#7dd3fc', '#22d3ee', '#5eead4'];
      if (typeof _hvacCheckPending === 'function') _hvacCheckPending(textId, v);
      if (!busy) {
        text.textContent = labels[v];
        text.style.color = colors[v];
      }
    }
  }
  applyCabinSeat('cmf-vent-drv-dots',  'cmf-drv-text',  s.seat_vent_drv);
  applyCabinSeat('cmf-vent-pass-dots', 'cmf-pass-text', s.seat_vent_pass);

  // ── Quantidade de linhas de "vento" saindo dos vents ─────────────────────
  // Cada vent tem 6 paths: core (data-min=0) | mid (=3) | wide (=6).
  // JS liga path.classList.on se acOn && fan_speed >= data-min.
  // Pulso é constante (duração/amplitude fixas); o que varia é a QUANTIDADE.
  {
    const fanLvlRaw = parseInt(s.hvac_fan_speed, 10);
    const fanLvl = Number.isFinite(fanLvlRaw) ? Math.max(0, fanLvlRaw) : 0;
    document.querySelectorAll('.cmf-ww').forEach(w => {
      const min = parseInt(w.dataset.min, 10);
      w.classList.toggle('on', acOn && fanLvl >= min);
    });
  }

  // ── Temperaturas ambiente — exibidas na "tela multimídia" do painel SVG ──
  // Estilo cluster: INT em azul, EXT em âmbar, dentro do retângulo da tela.
  const tIn  = parseFloat(s.inside_temp);
  const tOut = parseFloat(s.outside_temp);
  setText('cmf-svg-temp-in',  Number.isFinite(tIn)  ? tIn.toFixed(1)  + '°' : '--°');
  setText('cmf-svg-temp-out', Number.isFinite(tOut) ? tOut.toFixed(1) + '°' : '--°');

  // ── Climate Panel (acima da cabine): 2 temps + SYNC + AUTO + FAN ─────────
  // Quando AC off: esconde controles e mostra apenas indicador "AC desligado".
  const climatePanel = document.querySelector('.climate-panel');
  if (climatePanel) climatePanel.classList.toggle('off', !acOn);
  // Temperatura motorista
  const tempDrvEl = document.getElementById('cmf-ac-temp-drv');
  if (tempDrvEl) {
    const tDrv = parseFloat(s.hvac_driver_temp);
    const zoneDrv = tempDrvEl.closest('.climate-zone');
    if (Number.isFinite(tDrv)) {
      if (typeof _hvacCheckPending === 'function') _hvacCheckPending('cmf-ac-temp-drv', tDrv);
      if (typeof _hvacIsBusy !== 'function' || !_hvacIsBusy('cmf-ac-temp-drv')) {
        tempDrvEl.textContent = `${tDrv.toFixed(1)}°C`;
      }
      if (zoneDrv) zoneDrv.classList.toggle('active', acOn);
    } else {
      if (typeof _hvacIsBusy !== 'function' || !_hvacIsBusy('cmf-ac-temp-drv')) tempDrvEl.textContent = '--°C';
      if (zoneDrv) zoneDrv.classList.remove('active');
    }
  }
  // Temperatura passageiro (entidade ainda pendente — exibe '--°C' até chegar)
  const tempPassEl = document.getElementById('cmf-ac-temp-pass');
  if (tempPassEl) {
    const tPass = parseFloat(s.hvac_passenger_temp);
    const zonePass = tempPassEl.closest('.climate-zone');
    if (Number.isFinite(tPass)) {
      if (typeof _hvacCheckPending === 'function') _hvacCheckPending('cmf-ac-temp-pass', tPass);
      if (typeof _hvacIsBusy !== 'function' || !_hvacIsBusy('cmf-ac-temp-pass')) {
        tempPassEl.textContent = `${tPass.toFixed(1)}°C`;
      }
      if (zonePass) zonePass.classList.toggle('active', acOn);
    } else {
      if (typeof _hvacIsBusy !== 'function' || !_hvacIsBusy('cmf-ac-temp-pass')) tempPassEl.textContent = '--°C';
      if (zonePass) zonePass.classList.remove('active');
    }
  }
  // SYNC chain icon
  const syncOn = String(s.hvac_sync_enable) === '1';
  const syncEl = document.getElementById('cmf-ac-sync');
  if (syncEl) {
    if (typeof _hvacCheckPending === 'function') _hvacCheckPending('cmf-ac-sync', syncOn ? 1 : 0);
    syncEl.classList.toggle('on', syncOn);
  }
  // AUTO badge
  const autoOn = String(s.hvac_auto_enable) === '1';
  const autoEl = document.getElementById('cmf-ac-auto');
  if (autoEl) {
    if (typeof _hvacCheckPending === 'function') _hvacCheckPending('cmf-ac-auto', autoOn ? 1 : 0);
    autoEl.classList.toggle('on', autoOn);
  }
  // FAN bars + value
  const fanLvl = parseInt(s.hvac_fan_speed, 10);
  const fanValid = Number.isFinite(fanLvl) && fanLvl >= 0;
  const fanEl = document.getElementById('cmf-ac-fan');
  if (fanEl) fanEl.classList.toggle('on', fanValid && fanLvl > 0);
  document.querySelectorAll('.climate-fan-bar').forEach(bar => {
    const lvl = parseInt(bar.dataset.level, 10);
    bar.classList.toggle('on', fanValid && lvl <= fanLvl);
  });
  const fanValEl = document.getElementById('cmf-ac-fan-val');
  if (fanValEl) {
    if (typeof _hvacCheckPending === 'function' && fanValid) _hvacCheckPending('cmf-ac-fan-val', fanLvl);
    if (typeof _hvacIsBusy !== 'function' || !_hvacIsBusy('cmf-ac-fan-val')) {
      fanValEl.textContent = fanValid ? String(fanLvl) : '--';
    }
  }

  // Pill AC do rodapé com resumo enxuto
  const acTextEl = document.getElementById('cmf-ac-text');
  if (acTextEl) {
    const tDrv = parseFloat(s.hvac_driver_temp);
    const parts = [];
    if (Number.isFinite(tDrv))   parts.push(`${tDrv.toFixed(1)}°C`);
    if (autoOn)                  parts.push('AUTO');
    if (syncOn)                  parts.push('SYNC');
    if (fanValid && fanLvl > 0)  parts.push(`Fan ${fanLvl}`);
    let sub = document.getElementById('cmf-ac-subtext');
    if (!sub) {
      sub = document.createElement('div');
      sub.id = 'cmf-ac-subtext';
      sub.style.cssText = 'font-size:10px;font-weight:500;color:#64748b;margin-top:2px;letter-spacing:0.2px';
      acTextEl.parentNode.appendChild(sub);
    }
    sub.textContent = parts.join(' · ');
  }

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

  // Pneus — pílula compacta com psi colorido por faixa, temp em texto neutro
  function renderTyre(pos, psi, tempC) {
    const psiEl  = document.getElementById(`d-tyre-${pos}-psi`);
    const tempEl = document.getElementById(`d-tyre-${pos}-temp`);
    if (!psiEl) return;
    if (psi > 0) {
      psiEl.textContent = psi.toFixed(1);
      psiEl.style.color = psi < 25 || psi > 40 ? '#f87171'   // crítico
                       : psi < 30             ? '#fbbf24'    // baixo
                       :                        '#22d3ee';   // ok
    } else {
      psiEl.textContent = '--';
      psiEl.style.color = '#475569';
    }
    if (tempEl) tempEl.textContent = tempC > 0 ? `${tempC}°` : '--°';
  }
  renderTyre('fl', s.tyre_pressure_fl, s.tyre_temp_fl);
  renderTyre('fr', s.tyre_pressure_fr, s.tyre_temp_fr);
  renderTyre('rl', s.tyre_pressure_rl, s.tyre_temp_rl);
  renderTyre('rr', s.tyre_pressure_rr, s.tyre_temp_rr);

  // Velocímetro + trem de força + modo de condução — migrados pra aba Drive
  // (cluster cinematográfico). Aqui no Dash apenas garante container oculto.
  const pwrEl = document.getElementById('d-powertrain');
  if (pwrEl) pwrEl.style.display = 'none';

  // Mapa GPS — atualiza live a cada nova posição recebida via WebSocket
  if (s.gps_lat && s.gps_lng) updateDashMap(s.gps_lat, s.gps_lng, s.gps_ts, s.speed_kmh || 0);

  renderAlerts(s);
  renderTripCard(s, engOn);
}

// ── Cards de viagem — desde última partida + viagem atual/última ─────────────
function renderTripCard(s, engOn) {
  const rollCard = document.getElementById('d-roll-card');
  const curCard  = document.getElementById('d-curtrip-card');
  if (!rollCard || !curCard) return;

  const r = s.rolling || {};
  const rollDist = +r.distance_km || 0;
  const rollCons = +r.kwh_per_100km || 0;
  const rollKmL  = +r.km_per_l || 0;
  const rollFuel = +r.fuel_l || 0;
  const rollCost = +r.cost_brl || 0;
  const last = (cachedAutoTrips && cachedAutoTrips[0]) || null;

  // ── Card 1: Desde última partida ──────────────────────────────────────────
  const hasRoll = rollDist > 0.05 || rollCost > 0 || rollFuel > 0;
  rollCard.style.display = hasRoll ? '' : 'none';
  if (hasRoll) {
    setText('d-roll-dist', rollDist > 0 ? rollDist.toFixed(1) : '0,0');
    let consTxt = '--';
    if (rollCons > 0)      consTxt = rollCons.toFixed(1) + ' kWh/100';
    else if (rollKmL > 0)  consTxt = rollKmL.toFixed(1) + ' km/L';
    setText('d-roll-cons', consTxt);
    setText('d-roll-fuel', rollFuel > 0 ? rollFuel.toFixed(2) + ' L' : '0 L');
    setText('d-roll-cost', rollCost > 0 ? 'R$ ' + rollCost.toFixed(2) : 'R$ 0,00');
    const costPerKm = rollDist > 0.1 && rollCost > 0 ? (rollCost / rollDist) : 0;
    setText('d-roll-cost-km', costPerKm > 0 ? 'R$ ' + costPerKm.toFixed(2) : '--');
  }

  // ── Card 2: Viagem em andamento (motor on) ou Última viagem (motor off) ───
  const titleEl = document.getElementById('d-curtrip-title');
  const iconEl  = document.getElementById('d-curtrip-icon');
  const whenEl  = document.getElementById('d-curtrip-when');
  const gridLast = document.getElementById('d-curtrip-grid-last');
  const gridLive = document.getElementById('d-curtrip-grid-live');

  if (engOn) {
    curCard.style.display = '';
    curCard.classList.add('in-progress');
    if (iconEl)  iconEl.textContent  = '🚗';
    if (titleEl) titleEl.textContent = 'Viagem em andamento';
    if (whenEl)  whenEl.textContent  = '';
    if (gridLast) gridLast.style.display = 'none';
    if (gridLive) gridLive.style.display = '';

    // Médias da viagem em andamento — vem do APK via tópico retained current_trip.
    // Fallback: usa rolling enquanto não tem dado (ou APK antigo sem publish).
    const ct = s.current_trip;
    const tripDist = ct?.distKm ?? rollDist;
    setText('d-curtrip-dist', tripDist > 0 ? tripDist.toFixed(1) : '0,0');
    setText('d-live-avgv',    ct?.avgSpeedKmh > 0 ? Math.round(ct.avgSpeedKmh) + ' km/h' : '--');
    setText('d-live-maxv',    ct?.maxSpeedKmh > 0 ? Math.round(ct.maxSpeedKmh) + ' km/h' : '--');
    const ap = ct?.avgPowerKw || 0;
    setText('d-live-avgpwr',  ap > 0.05 ? ap.toFixed(1) + ' kW' : '--');
    setText('d-live-soc',     s.soc_pct != null ? Math.round(+s.soc_pct) + '%' : '--');
    setText('d-live-kwh',     ct?.netKwh > 0 ? ct.netKwh.toFixed(2) + ' kWh' : '--');
    setText('d-live-fuel',    ct?.fuelL  > 0.01 ? ct.fuelL.toFixed(2)  + ' L'   : '--');
  } else if (last) {
    curCard.style.display = '';
    curCard.classList.remove('in-progress');
    if (iconEl)  iconEl.textContent  = '🛣️';
    if (titleEl) titleEl.textContent = (last.name && last.name.trim()) ? last.name : 'Última viagem';
    if (whenEl && last.startMs) {
      whenEl.textContent = fmtRelativeShort(last.startMs);
    } else if (whenEl) {
      whenEl.textContent = '';
    }
    if (gridLast) gridLast.style.display = '';
    if (gridLive) gridLive.style.display = 'none';

    const dist = +last.distKm || 0;
    setText('d-curtrip-dist', dist > 0 ? dist.toFixed(1) : '0,0');

    const secs = +last.timeSec || 0;
    setText('d-last-time', secs > 0 ? fmtDuration(secs) : '--');

    const ss = Math.round(+last.startSocPct || 0);
    const es = Math.round(+last.endSocPct   || 0);
    setText('d-last-soc', (ss || es) ? `${ss} → ${es}%` : '--');

    const avgV = secs > 0 ? (dist / (secs / 3600)) : 0;
    setText('d-last-avgv', avgV > 0 ? avgV.toFixed(0) + ' km/h' : '--');
    setText('d-last-maxv', last.maxSpeedKmh ? Math.round(+last.maxSpeedKmh) + ' km/h' : '--');

    const energy = +last.energyKwh || 0;
    const regen  = +last.regenKwh  || 0;
    setText('d-last-energy', energy > 0 ? energy.toFixed(1) + ' kWh' : '--');
    setText('d-last-regen',  regen  > 0 ? regen.toFixed(1)  + ' kWh' : '--');
  } else {
    curCard.style.display = 'none';
  }
}

// Duração em formato "1h 23m" / "23 min" / "45s"
function fmtDuration(secs) {
  if (secs < 60) return Math.round(secs) + 's';
  const mins = Math.round(secs / 60);
  if (mins < 60) return mins + ' min';
  const hrs = Math.floor(mins / 60);
  const rem = mins % 60;
  return `${hrs}h ${rem}m`;
}

// Tempo relativo curto: "agora", "5 min", "2h", "ontem", "DD/MM"
function fmtRelativeShort(ms) {
  const diff = Date.now() - ms;
  if (diff < 60000) return 'agora';
  const mins = Math.floor(diff / 60000);
  if (mins < 60) return mins + ' min atrás';
  const hrs = Math.floor(mins / 60);
  if (hrs < 24) return hrs + 'h atrás';
  if (hrs < 48) return 'ontem';
  const d = new Date(ms);
  return d.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' });
}

// ── Recargas + Abastecimentos ────────────────────────────────────────────────
function loadCharges() {
  const list = document.getElementById('charges-list');
  if (cachedCharges !== null) {
    renderCharges();
  } else {
    list.innerHTML = '<div class="empty">Carregando...</div>';
  }
  // Carrega charges (via cache) + refuels do bridge em paralelo
  Promise.all([
    syncAllCache({ silent: true }),
    _loadRefuels(),
  ]).then(() => { renderCharges(); _tryAutoTagChargeLocation(); })
    .catch(() => { if (!cachedCharges) list.innerHTML = filterChipsHTML('charges') + '<div class="empty">Erro ao carregar.</div>'; });
}

async function _loadRefuels() {
  try {
    const r = await apiFetch('/api/refuels');
    if (!r.ok) return;
    const d = await r.json();
    cachedRefuels = d.refuels || [];
    _bumpCachesVersion();
    _tankAvgPriceL = +d.tank_avg_price_per_l || 0;
  } catch (_) {}
}

// Captura GPS e salva nas recargas recentes sem localização (últimas 8h)
// Atualiza cache mesmo sem nome — coordenadas ficam prontas para o picker
function _tryAutoTagChargeLocation() {
  if (!navigator.geolocation) return;
  if (!cachedCharges?.length) return;
  const cutoff   = Date.now() - 8 * 3600 * 1000;
  const needsGps = cachedCharges.filter(c => !c.location_lat && (c.timestamp_ms || 0) > cutoff);
  if (!needsGps.length) return;

  navigator.geolocation.getCurrentPosition(pos => {
    const { latitude: lat, longitude: lng } = pos.coords;
    let anyRendered = false;
    needsGps.forEach(charge => {
      apiFetch(`/api/charges/${charge.timestamp_ms}/location`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ lat, lng }),
      }).then(r => r.json()).then(updated => {
        // Atualiza coords sempre, nome só se matched
        charge.location_lat = updated.location_lat ?? lat;
        charge.location_lng = updated.location_lng ?? lng;
        if (updated.location_name) charge.location_name = updated.location_name;
        _idbPutMany('charges', [charge]).catch(() => {});
        if (!anyRendered && activePanel === 'charges') { anyRendered = true; renderCharges(); }
      }).catch(() => {});
    });
  }, null, { timeout: 15000, maximumAge: 120000 });
}

// Chips de filtro de tipo (Todos / ⚡ Recargas / ⛽ Abastecimentos)
function _typeFilterChipsHTML() {
  const t = filterState.charges.type || 'all';
  const c = (id, lbl) =>
    `<button class="filter-chip${t===id?' active':''}" onclick="setChargesType('${id}')">${lbl}</button>`;
  return `<div class="filter-chips" style="margin-bottom:6px">${c('all','Todos')}${c('recarga','⚡ Recargas')}${c('refuel','⛽ Abastecimentos')}</div>`;
}
window.setChargesType = function(type) {
  filterState.charges.type = type;
  renderCharges();
};

// Renderiza card de abastecimento (formato similar ao de recarga)
function _renderRefuelCard(r) {
  const ts = r.timestamp_ms || 0;
  const pending = !!r.pending;
  const date = fmtDate(new Date(ts).toISOString());
  const liters = +r.liters_added || 0;
  const ppl    = +r.price_per_liter || 0;
  const total  = +r.total_cost || (ppl * liters);
  const tankAfter = +r.tank_avg_after || 0;
  return `<div class="trip-item ${pending ? 'refuel-pending' : ''}" id="refuel-card-${r.id}">
  <div class="trip-header">
    <div style="flex:1;min-width:0">
      <div class="trip-name-row">
        <div class="trip-name">⛽ ${date}</div>
        ${pending ? '<span class="refuel-pending-badge">Pendente</span>' : ''}
        <button class="rename-btn" onclick="deleteRefuel('${r.id}')" title="Apagar" style="opacity:.35">🗑</button>
      </div>
      ${pending
        ? `<div style="font-size:11px;color:#fbbf24;margin-top:2px">Informe o preço pra calcular o mix do tanque</div>`
        : `<div style="display:flex;gap:6px;align-items:center;margin-top:2px">
            <span class="trip-cost">R$ ${f2(total)}</span>
            <span style="font-size:10px;color:#64748b">${f2(ppl)} R$/L · tanque: R$ ${f3(tankAfter)}/L</span>
           </div>`}
    </div>
    <div style="display:flex;flex-direction:column;align-items:flex-end;gap:3px">
      <span class="charge-kwh-badge" style="background:rgba(251,146,60,0.15);color:#fb923c;border-color:rgba(251,146,60,0.3)">${f1(liters)} L</span>
      <button class="cost-edit-btn" onclick="toggleRefuelEdit('${r.id}')" title="Editar preço">💰</button>
    </div>
  </div>
  <div id="refuel-edit-${r.id}" class="cost-edit-form" style="display:${pending ? 'flex' : 'none'};flex-wrap:wrap;gap:6px">
    <div style="font-size:11px;color:#64748b;width:100%">Preço por litro (R$/L) ou total (R$). Litros: ${f2(liters)} L</div>
    <input id="refuel-ppl-${r.id}" class="charge-total-input" type="number" step="0.01" min="0" placeholder="R$/L ex: 6.00"${ppl > 0 ? ` value="${f2(ppl)}"` : ''}>
    <input id="refuel-total-${r.id}" class="charge-total-input" type="number" step="0.01" min="0" placeholder="Total R$"${total > 0 ? ` value="${f2(total)}"` : ''}>
    <button class="cost-apply-btn" onclick="applyRefuelPrice('${r.id}')">Salvar</button>
  </div>
</div>`;
}

window.toggleRefuelEdit = function(id) {
  const el = document.getElementById('refuel-edit-' + id);
  if (el) el.style.display = el.style.display === 'none' ? 'flex' : 'none';
};

window.applyRefuelPrice = async function(id) {
  const ppl   = parseFloat(document.getElementById('refuel-ppl-' + id)?.value || '0');
  const total = parseFloat(document.getElementById('refuel-total-' + id)?.value || '0');
  const body  = ppl > 0 ? { price_per_liter: ppl } : total > 0 ? { total_cost: total } : null;
  if (!body) { showToast('Informe R$/L ou total'); return; }
  try {
    const r = await apiFetch('/api/refuels/' + id, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const d = await r.json();
    if (!r.ok || !d.ok) throw new Error(d.error || 'erro');
    _tankAvgPriceL = +d.tank_avg_price_per_l || 0;
    await _loadRefuels();
    renderCharges();
    showToast('✓ Preço salvo');
  } catch (e) { showToast('✗ ' + e.message); }
};

window.deleteRefuel = async function(id) {
  if (!confirm('Apagar este abastecimento?')) return;
  try {
    const r = await apiFetch('/api/refuels/' + id, { method: 'DELETE' });
    if (!r.ok) throw new Error('erro');
    await _loadRefuels();
    renderCharges();
  } catch (_) { showToast('✗ Falha ao apagar'); }
};

function renderCharges() {
  const list = document.getElementById('charges-list');
  if (!list) return;
  const [startMs, endMs] = getFilterRange('charges');
  const byDate = filterItems(cachedCharges || [], 'timestamp', startMs, endMs);

  // Filtro por local (aplicado sobre o resultado do filtro de data)
  const locFilter = filterState.charges.location;
  let charges     = locFilter
    ? byDate.filter(c => (c.location_name || null) === locFilter)
    : byDate;

  // Filtro por tipo (todos / só recarga / só abastecimento)
  const typeFilter = filterState.charges.type || 'all';
  const showCharges  = typeFilter === 'all' || typeFilter === 'recarga';
  const showRefuels  = typeFilter === 'all' || typeFilter === 'refuel';

  // Filtra refuels pelo MESMO range de data
  const refuelsAll = cachedRefuels || [];
  const refuelsDate = refuelsAll.filter(r => {
    const ms = r.timestamp_ms || 0;
    return ms >= startMs && ms <= endMs;
  });

  const finalCharges = showCharges ? charges : [];
  const finalRefuels = showRefuels ? refuelsDate : [];

  const socColor = d => d >= 50 ? 'green' : d >= 25 ? 'teal' : 'muted';

  let html = filterChipsHTML('charges') + _typeFilterChipsHTML() + (showCharges ? _locationChipsHTML() : '');
  if (!finalCharges.length && !finalRefuels.length) {
    const empty = typeFilter === 'refuel' ? 'Nenhum abastecimento no período.' : 'Nenhuma recarga no período.';
    list.innerHTML = html + `<div class="empty">${empty}</div>`;
    return;
  }
  // Reaponta `charges` pro filtrado por tipo
  charges = finalCharges;

  const priceKwh  = state.price_kwh || 0;
  const totalKwh  = charges.reduce((s,c) => s + (c.energy_kwh   || 0), 0);
  const totalSec  = charges.reduce((s,c) => s + (c.duration_sec || 0), 0);
  const avgPwr    = totalSec > 0 ? totalKwh / (totalSec / 3600) : 0;
  const totalCost = charges.reduce((s, c) => {
    const ov  = _chargeCostOverride(c.timestamp_ms || 0);
    const kwh = c.energy_kwh || 0;
    return s + (ov ? ov.total : priceKwh * kwh);
  }, 0);
  const hasCost = totalCost > 0;

  // ── Perda de carga (kWh carregador vs kWh injetado no carro) ────────────────
  const chargerMap    = _chargerKwhMap();
  const withLoss      = charges.filter(c => _resolveChargerKwh(c, chargerMap) > 0);
  const totalChrgrKwh = withLoss.reduce((s, c) => s + _resolveChargerKwh(c, chargerMap), 0);
  const totalLossKwh  = withLoss.reduce((s, c) => s + Math.max(0, _resolveChargerKwh(c, chargerMap) - (c.energy_kwh || 0)), 0);
  const avgLossPct    = totalChrgrKwh > 0 ? (totalLossKwh / totalChrgrKwh * 100) : 0;
  const hasLossData   = withLoss.length > 0;

  const cu = s => `<span class="chrg-unit">${s}</span>`;
  html += `<div class="charge-summary-card">
  <div class="card-title">Resumo — ${charges.length} sessão${charges.length !== 1 ? 'ões' : ''}</div>
  <div class="metrics-row">
    <div class="metric"><div class="metric-value teal sm">${f2(totalKwh)}${cu(' kWh')}</div><div class="metric-label">total carregado</div></div>
    <div class="metric"><div class="metric-value muted sm">${fmtDashTime(totalSec)}</div><div class="metric-label">tempo total</div></div>
    <div class="metric"><div class="metric-value blue sm">${f1(avgPwr)}${cu(' kW')}</div><div class="metric-label">pot. média</div></div>
    ${hasCost ? `<div class="metric"><div class="metric-value green sm">${cu('R$ ')}${f2(totalCost)}</div><div class="metric-label">custo total</div></div>` : ''}
  </div>
  ${hasLossData ? `<div class="metrics-row" style="margin-top:6px;border-top:1px solid rgba(248,113,113,0.18);padding-top:6px">
    <div class="metric"><div class="metric-value sm" style="color:#f87171">${f2(totalLossKwh)}${cu(' kWh')}</div><div class="metric-label">perda total</div></div>
    <div class="metric"><div class="metric-value sm" style="color:#f87171">${f1(avgLossPct)}%</div><div class="metric-label">% perda média</div></div>
    <div class="metric"><div class="metric-value muted sm">${withLoss.length}/${charges.length}</div><div class="metric-label">c/ dado carregador</div></div>
  </div>` : ''}
</div>`;

  // Acumula cards num array {ts, html} — depois mescla com refuels e ordena por data
  const _allCards = [];
  charges.forEach(c => {
    const delta  = (c.soc_end || 0) - (c.soc_start || 0);
    const col    = socColor(delta);
    const ts     = c.timestamp_ms || 0;
    const ov   = _chargeCostOverride(ts);
    const kwh  = c.energy_kwh || 0;
    // Campos editados manualmente no PWA (override no bridge).
    // `_overridden_fields` vem do bridge applyChargeOverrides; o avg_power_kw é derivado
    // de energy_kwh ou duration_sec, então também marca como editado nesse caso.
    const ovFields  = new Set(c._overridden_fields || []);
    const ovd       = (field) => ovFields.has(field);
    const ovdAvgPwr = ovd('energy_kwh') || ovd('duration_sec');
    // Mescla cor base + indicador de edição (dashed) num único style attribute
    const metricStyle = (color, edited) =>
      ` style="color:var(--${color})${edited ? ';border-bottom:1px dashed rgba(251,191,36,.5)' : ''}"`;
    const editedBadge = ovFields.size > 0
      ? '<span title="Recarga editada manualmente" style="font-size:9px;color:#fbbf24;margin-left:4px">✏️</span>'
      : '';
    // Custo da recarga em si: override manual tem prioridade (incl. recarga grátis).
    // Sem override, usa o preço seed (SEED_KWH_PRICE_PWA) — representa "não informado".
    const isFreeOv = ov?.free === true;
    const cost = ov
      ? { total: ov.total || 0, perKwh: ov.perKwh || 0, isOv: true, isFree: isFreeOv }
      : (kwh > 0 ? { total: kwh * SEED_KWH_PRICE_PWA, perKwh: SEED_KWH_PRICE_PWA, isOv: false, isFree: false } : null);
    const totalLabel = cost?.isFree ? '🎁 Grátis' : (cost ? 'R$ ' + f2(cost.total) : '');
    const totalCostStyle = cost?.isFree
      ? ' style="color:#4ade80;font-weight:600;border-bottom:1px dashed rgba(74,222,128,.5)"'
      : (cost?.isOv ? ' style="border-bottom:1px dashed rgba(251,191,36,.5)"' : '');
    const totalCostHtml = cost
      ? `<span id="chg-cost-${ts}" class="trip-cost"${totalCostStyle}>${totalLabel}</span>`
      : `<span id="chg-cost-${ts}" class="trip-cost" style="display:none"></span>`;
    const unitHtml = cost && !cost.isFree
      ? `<span id="chg-unit-${ts}" style="font-size:10px;color:#64748b">${f3(cost.perKwh)} R$/kWh</span>`
      : `<span id="chg-unit-${ts}" style="font-size:10px;color:#64748b;display:none"></span>`;
    const chargerKwh = _getChargerKwh(ts);
    const lossKwh    = chargerKwh > 0 ? Math.max(0, chargerKwh - kwh) : 0;
    const lossPct    = chargerKwh > 0 ? (lossKwh / chargerKwh * 100)  : 0;
    const lossRow    = chargerKwh > 0 ? `
  <div class="trip-metrics" style="border-top:1px solid rgba(248,113,113,0.18);margin-top:4px;padding-top:4px">
    <div class="trip-metric"><div class="trip-metric-val muted">${f2(chargerKwh)} kWh</div><div class="trip-metric-lbl">🔌 carregador</div></div>
    <div class="trip-metric"><div class="trip-metric-val" style="color:#f87171">${f2(lossKwh)} kWh</div><div class="trip-metric-lbl">perda</div></div>
    <div class="trip-metric"><div class="trip-metric-val" style="color:#f87171">${lossPct.toFixed(1)}%</div><div class="trip-metric-lbl">% perda</div></div>
  </div>` : '';
    _allCards.push({ ts, html: `<div class="trip-item" id="charge-card-${ts}">
  <div class="trip-header">
    <div style="flex:1;min-width:0">
      <div class="trip-name-row">
        <div class="trip-name">${fmtDate(c.timestamp)}${editedBadge}</div>
        <button class="rename-btn" onclick="deleteCharge(${ts})" title="Apagar recarga" style="opacity:.35">🗑</button>
      </div>
      <div style="display:flex;gap:6px;align-items:center;margin-top:2px">${totalCostHtml}${unitHtml}</div>
    </div>
    <div style="display:flex;flex-direction:column;align-items:flex-end;gap:3px">
      <span class="charge-kwh-badge">${f2(kwh)} kWh</span>
      <div style="display:flex;gap:4px">
        <button class="cost-edit-btn" onclick="openChargeTimeline(${ts})" title="Ver linha do tempo">📈</button>
        <button class="cost-edit-btn" onclick="openMergeChargeModal(${ts})" title="Unir recargas">🔗</button>
        <button class="cost-edit-btn" onclick="toggleChargerEdit(${ts})" title="kWh do carregador">🔌</button>
        <button class="cost-edit-btn" onclick="toggleChargeEdit(${ts})" title="Editar custo">💰</button>
        <button class="cost-edit-btn" onclick="toggleChargeMetaEdit(${ts})" title="Corrigir dados (SOC, energia, duração)">✏️</button>
      </div>
    </div>
  </div>
  <div id="charge-edit-${ts}" class="cost-edit-form" style="display:none">
    <div style="font-size:11px;color:#64748b;width:100%;margin-bottom:2px">Total pago (R$) — deixe 0 para usar o preço das configurações</div>
    <input class="charge-total-input" type="number" step="0.01" min="0" placeholder="ex: 12.50"${ov && !isFreeOv ? ` value="${ov.total}"` : ''}>
    <button class="cost-apply-btn" onclick="applyChargeCost(${ts},${kwh.toFixed(3)})">Salvar</button>
    <button class="cost-apply-btn" onclick="markChargeFree(${ts})" style="background:#16a34a;color:#fff">Grátis 🎁</button>
  </div>
  <div id="charger-edit-${ts}" class="cost-edit-form" style="display:none">
    <div style="font-size:11px;color:#64748b;width:100%;margin-bottom:2px">kWh marcado no carregador — para calcular a perda de carga</div>
    <input class="charge-total-input" type="number" step="0.01" min="0" placeholder="ex: 18.50"${chargerKwh > 0 ? ` value="${chargerKwh}"` : ''}>
    <button class="cost-apply-btn" onclick="applyChargerKwh(${ts})">Salvar</button>
  </div>
  <div id="charge-meta-edit-${ts}" class="cost-edit-form" style="display:none;flex-direction:column;align-items:stretch;gap:6px">
    <div style="font-size:11px;color:#64748b">Corrige leituras erradas do carro. Edições ficam só no servidor — o app do carro continua reportando o valor original.</div>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:6px">
      <label style="display:flex;flex-direction:column;gap:2px;font-size:10px;color:#94a3b8">SOC início (%)
        <input class="charge-meta-soc-start" type="number" step="1" min="0" max="100" value="${(+c.soc_start || 0).toFixed(0)}">
      </label>
      <label style="display:flex;flex-direction:column;gap:2px;font-size:10px;color:#94a3b8">SOC fim (%)
        <input class="charge-meta-soc-end" type="number" step="1" min="0" max="100" value="${(+c.soc_end || 0).toFixed(0)}">
      </label>
      <label style="display:flex;flex-direction:column;gap:2px;font-size:10px;color:#94a3b8">Energia injetada (kWh)
        <input class="charge-meta-kwh" type="number" step="0.01" min="0" value="${(+c.energy_kwh || 0).toFixed(2)}">
      </label>
      <label style="display:flex;flex-direction:column;gap:2px;font-size:10px;color:#94a3b8">Duração (HH:MM)
        <input class="charge-meta-dur" type="text" pattern="\\d+:\\d{2}" placeholder="HH:MM" value="${_fmtDurHHMM(c.duration_sec || 0)}">
      </label>
    </div>
    <div style="display:flex;gap:6px;justify-content:flex-end">
      ${ovFields.size > 0 ? `<button class="cost-apply-btn" style="background:#475569" onclick="revertChargeMeta(${ts})">Reverter</button>` : ''}
      <button class="cost-apply-btn" onclick="applyChargeMeta(${ts})">Salvar</button>
    </div>
  </div>
  <div class="trip-metrics">
    <div class="trip-metric"><div class="trip-metric-val"${metricStyle('teal', ovd('duration_sec'))}>${fmtDur(c.duration_sec)}</div><div class="trip-metric-lbl">duração${ovd('duration_sec') ? ' ✏️' : ''}</div></div>
    <div class="trip-metric"><div class="trip-metric-val"${metricStyle('blue', ovdAvgPwr)}>${f1(c.avg_power_kw)} kW</div><div class="trip-metric-lbl">pot. média${ovdAvgPwr ? ' ✏️' : ''}</div></div>
    <div class="trip-metric"><div class="trip-metric-val"${metricStyle('muted', ovd('soc_start'))}>${pct(c.soc_start)}</div><div class="trip-metric-lbl">SOC início${ovd('soc_start') ? ' ✏️' : ''}</div></div>
    <div class="trip-metric"><div class="trip-metric-val ${col}"${ovd('soc_end') ? ' style="border-bottom:1px dashed rgba(251,191,36,.5)"' : ''}>${pct(c.soc_end)}</div><div class="trip-metric-lbl">SOC fim${ovd('soc_end') ? ' ✏️' : ''}</div></div>
    <div class="trip-metric"><div class="trip-metric-val ${col}">+${delta.toFixed(0)}%</div><div class="trip-metric-lbl">Δ SOC</div></div>
    ${c.avg_temp_c != null ? `<div class="trip-metric"><div class="trip-metric-val muted">${c.avg_temp_c.toFixed(1)}°C</div><div class="trip-metric-lbl">🌡 temp ext</div></div>` : ''}
  </div>
  ${lossRow}
  <div class="charge-location-row" onclick="openLoc(${ts})">
    ${c.location_name
      ? `<span class="charge-loc-name">📍 ${c.location_name}</span><span class="charge-loc-edit">✏️</span>`
      : `<span class="charge-loc-add">📍 Adicionar local</span>`}
  </div>
</div>` });
  });

  // ── Resumo de abastecimentos (separado do de recargas) ──────────────────
  if (showRefuels && finalRefuels.length > 0) {
    const totalL    = finalRefuels.reduce((s, r) => s + (+r.liters_added || 0), 0);
    const withPrice = finalRefuels.filter(r => +r.price_per_liter > 0);
    const totalR    = withPrice.reduce((s, r) => s + (+r.total_cost || 0), 0);
    const avgR      = withPrice.length > 0
      ? withPrice.reduce((s, r) => s + (+r.liters_added * +r.price_per_liter), 0) /
        withPrice.reduce((s, r) => s + (+r.liters_added || 0), 0)
      : 0;
    const pending = finalRefuels.filter(r => r.pending).length;

    html += `<div class="charge-summary-card" style="margin-top:14px;border-color:rgba(251,146,60,0.25)">
      <div class="card-title" style="color:#fb923c">⛽ Abastecimentos — ${finalRefuels.length}${pending ? ` (${pending} pendente${pending>1?'s':''})` : ''}</div>
      <div class="metrics-row">
        <div class="metric"><div class="metric-value sm" style="color:#fb923c">${f1(totalL)}<span class="chrg-unit"> L</span></div><div class="metric-label">total</div></div>
        ${avgR > 0 ? `<div class="metric"><div class="metric-value muted sm">${f2(avgR)}<span class="chrg-unit"> R$/L</span></div><div class="metric-label">médio</div></div>` : ''}
        ${totalR > 0 ? `<div class="metric"><div class="metric-value green sm"><span class="chrg-unit">R$ </span>${f2(totalR)}</div><div class="metric-label">custo total</div></div>` : ''}
        ${_tankAvgPriceL > 0 ? `<div class="metric"><div class="metric-value teal sm">${f3(_tankAvgPriceL)}<span class="chrg-unit"> R$/L</span></div><div class="metric-label">tanque atual</div></div>` : ''}
      </div>
    </div>`;

    // Adiciona refuels ao mesmo array — vão ser ordenados intercalados por ts
    for (const r of finalRefuels) {
      _allCards.push({ ts: r.timestamp_ms || 0, html: _renderRefuelCard(r) });
    }
  }

  // Ordena tudo (recargas + abastecimentos) por timestamp descendente e renderiza
  _allCards.sort((a, b) => b.ts - a.ts);
  html += _allCards.map(x => x.html).join('');

  list.innerHTML = html;
}

// ── Logs de eventos ───────────────────────────────────────────────────────────
const LOG_TYPE_GROUPS = {
  all:     [],
  engine:  ['engine_on','engine_off'],
  lock:    ['lock_open','lock_close'],
  doors:   ['door_open','door_close'],
  trunk:   ['trunk_open','trunk_close'],
  windows: ['window_open','window_close','sunroof_open','sunroof_close'],
  trips:   ['trip_start','trip_end'],
  ac:      ['ac_on','ac_off'],
  charge:  ['charge_start','charge_end'],
};
const LOG_TYPE_LABELS = {
  all: 'Todos', engine: 'Motor', lock: 'Travas',
  doors: 'Portas', trunk: 'Mala', windows: 'Vidros', trips: 'Viagens', ac: 'Clima', charge: '⚡ Recarga',
};
const LOG_ICONS = {
  engine_on: '🔑', engine_off: '🔑',
  lock_open: '🔓', lock_close: '🔒',
  door_open: '🚪', door_close: '🚪',
  trunk_open: '🧳', trunk_close: '🧳',
  window_open: '🪟', window_close: '🪟',
  sunroof_open: '☀️', sunroof_close: '🌙',
  trip_start: '🚗', trip_end: '🏁',
  ac_on: '❄️', ac_off: '❄️',
  charge_start: '⚡', charge_end: '✅',
};

function loadLogs() {
  filterState.logs.active = 'today';
  filterState.logs.type   = 'all';
  const list = document.getElementById('logs-list');
  if (!list) return;
  if (cachedEvents) renderLogs();
  else list.innerHTML = '<div class="empty">Carregando…</div>';
  apiFetch('/api/events')
    .then(r => r.json())
    .then(data => {
      if (!Array.isArray(data)) return;
      cachedEvents = data;
      renderLogs();
    })
    .catch(() => {
      if (!cachedEvents) list.innerHTML = '<div class="empty">Erro ao carregar.</div>';
    });
}

function renderLogs() {
  const list = document.getElementById('logs-list');
  if (!list || !cachedEvents) return;

  const f       = filterState.logs;
  const typeGrp = LOG_TYPE_GROUPS[f.type] || [];
  const today   = new Date(); today.setHours(0,0,0,0);
  const nowMs   = Date.now();

  // Date range
  let fromMs = 0, toMs = Infinity;
  if (f.active === 'today')    { fromMs = today.getTime(); }
  else if (f.active === '7d')  { fromMs = nowMs - 7*86400000; }
  else if (f.active === '30d') { fromMs = nowMs - 30*86400000; }
  else if (f.active === 'month') {
    const m = new Date(); m.setDate(1); m.setHours(0,0,0,0);
    fromMs = m.getTime();
  } else if (f.active === 'custom') {
    if (f.customFrom) fromMs = new Date(f.customFrom).getTime();
    if (f.customTo)   toMs   = new Date(f.customTo).getTime() + 86400000 - 1;
  }

  const filtered = cachedEvents.filter(ev => {
    if (ev.type === 'trip_end') return false;   // ruído — viagem termina, autotrip já registra
    if (ev.ts < fromMs || ev.ts > toMs) return false;
    if (typeGrp.length && !typeGrp.includes(ev.type)) return false;
    return true;
  });

  // Type filter chips
  const typeKeys = Object.keys(LOG_TYPE_LABELS);
  let chipsHtml = '<div class="filter-chips" style="margin-bottom:4px">';
  typeKeys.forEach(k => {
    chipsHtml += `<button class="chip ${f.type===k?'active':''}" onclick="setLogsTypeFilter('${k}')">${LOG_TYPE_LABELS[k]}</button>`;
  });
  chipsHtml += '</div>';

  // Date chips
  const dateOpts = [['all','Todos'],['today','Hoje'],['7d','7 dias'],['30d','30 dias'],['month','Mês']];
  let dateChips = '<div class="filter-chips" style="margin-bottom:6px">';
  dateOpts.forEach(([k,l]) => {
    dateChips += `<button class="chip ${f.active===k?'active':''}" onclick="setLogsDateFilter('${k}')">${l}</button>`;
  });
  dateChips += '</div>';

  if (!filtered.length) {
    list.innerHTML = chipsHtml + dateChips + '<div class="empty">Nenhum evento.</div>';
    return;
  }

  let html = chipsHtml + dateChips;

  // Group by day
  let lastDay = '';
  filtered.forEach(ev => {
    const d = new Date(ev.ts);
    const dayStr = d.toLocaleDateString('pt-BR', { day:'2-digit', month:'2-digit', year:'numeric' });
    if (dayStr !== lastDay) {
      html += `<div class="log-day-header">${dayStr}</div>`;
      lastDay = dayStr;
    }
    const timeStr = d.toLocaleTimeString('pt-BR', { hour:'2-digit', minute:'2-digit', second:'2-digit' });
    const icon = LOG_ICONS[ev.type] || '•';
    html += `<div class="log-entry">
      <span class="log-icon">${icon}</span>
      <span class="log-label">${ev.label}</span>
      <span class="log-time">${timeStr}</span>
    </div>`;
  });

  list.innerHTML = html;
}

function setLogsTypeFilter(type) {
  filterState.logs.type = type;
  renderLogs();
}
function setLogsDateFilter(filter) {
  filterState.logs.active = filter;
  renderLogs();
}

// ── Auto-Trips ────────────────────────────────────────────────────────────────
let cachedAutoTrips = null;

function loadAutoTrips() {
  document.querySelector('[data-panel="auto"] .tab-notif')?.remove();
  const list = document.getElementById('auto-list');
  if (cachedAutoTrips !== null) {
    renderAutoTrips();                    // cache IndexedDB → renderiza imediatamente
  } else {
    list.innerHTML = '<div class="empty">Carregando...</div>';
  }
  syncAllCache({ silent: false }).then(() => {
    renderAutoTrips();
    syncRenameStatus();
  }).catch(() => {
    if (!cachedAutoTrips) list.innerHTML = '<div class="empty">Erro ao carregar.</div>';
  });
}

function renderAutoTrips() {
  const list = document.getElementById('auto-list');
  if (!list) return;

  const [filterStart, filterEnd] = getFilterRange('auto');
  let trips = filterItems(cachedAutoTrips || [], 'startMs', filterStart, filterEnd);

  // Filtro de busca por nome / data / localização (AND com filtro de datas)
  const autoQ = (filterState.auto.search || '').trim().toLowerCase();
  let pendingGeo = 0;
  if (autoQ) {
    trips = trips.filter(t => {
      const name    = (t.name || '').toLowerCase();
      const dateStr = fmtDate(t.startMs).toLowerCase();
      const geo     = (geoCache[t.tripId] ?? null);
      if (geo === null && t.startLat && t.startLat !== 0) pendingGeo++; // ainda geocodando
      const geoStr  = (geo || '').toLowerCase();
      return name.includes(autoQ) || dateStr.includes(autoQ) || geoStr.includes(autoQ);
    });
  }

  let html = filterChipsHTML('auto');

  // Badge de geocodificação em progresso
  if (autoQ && pendingGeo > 0) {
    html += `<div class="geo-loading">🔍 Buscando localização de ${pendingGeo} viagem${pendingGeo !== 1 ? 'ns' : ''}…</div>`;
  }

  if (!trips.length) {
    const hint = autoQ
      ? `<div class="empty">Nenhuma viagem com "${filterState.auto.search}"${pendingGeo > 0 ? ' — resultado parcial, aguarde' : ''}.</div>`
      : '<div class="empty">Nenhuma viagem automática no período.</div>';
    list.innerHTML = html + hint;
    return;
  }

  // Enfileira geocodes de destino para trips que ainda não têm (sem rate limit extra —
  // queueGeocode já ignora entradas já presentes ou na fila)
  trips.forEach(t => {
    if (t.endLat && t.endLat !== 0) queueGeocode(t.tripId, t.endLat, t.endLng, t.tripId + ':end');
  });

  // Resumo — mesma estrutura 2 linhas do hist
  const { gas: priceGas, kwh: priceKwh } = getPrices();
  const KWH_PER_L = 8.9;

  // Calcula eco score 0-100 de uma viagem combinando 5 componentes.
  // Retorna null se a viagem não tem dado suficiente.
  function _computeEcoScore(t, effInfo) {
    const dist = +t.distKm || 0;
    if (dist < 1) return null;
    const timeSec = +t.timeSec || 0;
    if (timeSec < 30) return null;

    // 1) Elétrico (35 pts): % do trecho em modo EV puro
    const elecPct = Math.max(0, Math.min(1, 1 - ((t.hybridDistKm || 0) / dist)));
    const s1 = elecPct * 35;

    // 2) Regen (25 pts): razão regen/consumo bruto. 25% = full.
    const energy = +t.energyKwh || 0;
    const regen  = +t.regenKwh  || 0;
    const regenRatio = energy > 0.05 ? regen / energy : 0;
    const s2 = Math.min(25, regenRatio * 100);

    // 3) Velocidade média (15 pts): zona ideal 30-70 km/h
    const avgKmh = dist / (timeSec / 3600);
    let s3;
    if (avgKmh >= 30 && avgKmh <= 70)      s3 = 15;
    else if (avgKmh >= 20 && avgKmh <= 90) s3 = 8;
    else if (avgKmh >= 10 && avgKmh <= 110) s3 = 4;
    else                                    s3 = 0;

    // 4) Suavidade (10 pts): inverso do pico de potência (%)
    const maxP = +t.maxPowerPct || 0;
    const s4 = Math.max(0, 10 - (maxP / 10));

    // 5) vs trecho (15 pts): pega de effInfo se houver
    let s5 = 7.5;  // neutro quando não há histórico
    if (effInfo) {
      // pct +20% → 15 pts, 0% → 7.5, -20% → 0
      s5 = Math.max(0, Math.min(15, 7.5 + (effInfo.pct * 0.375)));
    }

    return Math.round(s1 + s2 + s3 + s4 + s5);
  }

  function _ecoScoreDetail(t, effInfo) {
    const dist = +t.distKm || 0;
    const elecPct = Math.max(0, Math.min(100, 100 * (1 - ((t.hybridDistKm || 0) / dist))));
    const energy = +t.energyKwh || 0;
    const regen  = +t.regenKwh  || 0;
    const regenRatio = energy > 0.05 ? regen / energy * 100 : 0;
    const avgKmh = (+t.timeSec || 0) > 0 ? dist / ((+t.timeSec || 0) / 3600) : 0;
    const parts = [
      `${elecPct.toFixed(0)}% elétrico`,
      `${regenRatio.toFixed(0)}% regen`,
      `${avgKmh.toFixed(0)} km/h méd.`,
    ];
    if (effInfo) parts.push(`${effInfo.pct >= 0 ? '+' : ''}${effInfo.pct.toFixed(0)}% vs trecho`);
    return parts.join(' · ');
  }

  // Pré-cálculo: índice de eficiência por trajeto (start/end ~200m, ±10% km).
  // Pra cada trip, acha viagens "irmãs" do mesmo trecho e calcula a média km/L eq;
  // o badge mostra quantos % esta viagem está acima/abaixo da média do trecho.
  function _haversineM(la1, ln1, la2, ln2) {
    const R = 6371000, toRad = d => d * Math.PI / 180;
    const dLat = toRad(la2 - la1), dLng = toRad(ln2 - ln1);
    const a = Math.sin(dLat/2)**2 + Math.cos(toRad(la1))*Math.cos(toRad(la2))*Math.sin(dLng/2)**2;
    return 2 * R * Math.asin(Math.sqrt(a));
  }
  function _tripKmLEq(t) {
    if (!t || (t.distKm || 0) < 0.5) return null;
    const totalEqL = (t.netKwh || 0) / KWH_PER_L + (t.fuelL || 0);
    if (totalEqL < 0.001) return null;
    return t.distKm / totalEqL;
  }
  // Pré-computa as "irmãs" pra cada trip que tem coords + dist + eficiência.
  // Antes era O(N²) com haversine — em 5k trips eram 25M comparações + trig.
  // Agora: bucket por start_lat/start_lng arredondado (~110m cada). Pra cada
  // trip só checa o próprio bucket + 8 vizinhos = O(N·k), k ≈ trips por região.
  const _effIndex = {};
  const BUCKET_DEG  = 0.001;   // ~110m no equador, similar em latitudes do Brasil
  const validTrips  = [];
  const tripKmL     = new Map();
  for (const t of trips) {
    const kmL = _tripKmLEq(t);
    if (kmL === null || !t.startLat || !t.endLat) continue;
    tripKmL.set(t.tripId, kmL);
    validTrips.push(t);
  }
  const buckets = new Map();
  const bx = t => Math.floor(t.startLat / BUCKET_DEG);
  const by = t => Math.floor(t.startLng / BUCKET_DEG);
  for (const t of validTrips) {
    const key = bx(t) + ':' + by(t);
    let arr = buckets.get(key);
    if (!arr) { arr = []; buckets.set(key, arr); }
    arr.push(t);
  }
  for (const t of validTrips) {
    const myKmL = tripKmL.get(t.tripId);
    const tx = bx(t), ty = by(t);
    const siblings = [];
    for (let dx = -1; dx <= 1; dx++) {
      for (let dy = -1; dy <= 1; dy++) {
        const neighbor = buckets.get((tx + dx) + ':' + (ty + dy));
        if (!neighbor) continue;
        for (const o of neighbor) {
          if (o.tripId === t.tripId) continue;
          if (Math.abs(t.distKm - o.distKm) / t.distKm > 0.10) continue;
          if (_haversineM(t.startLat, t.startLng, o.startLat, o.startLng) > 200) continue;
          if (_haversineM(t.endLat,   t.endLng,   o.endLat,   o.endLng)   > 200) continue;
          siblings.push(tripKmL.get(o.tripId));
        }
      }
    }
    if (siblings.length < 1) continue;
    const avg = siblings.reduce((s, x) => s + x, 0) / siblings.length;
    if (avg <= 0) continue;
    _effIndex[t.tripId] = {
      pct: (myKmL - avg) / avg * 100,
      sampleCount: siblings.length,
      avgKmL: avg,
      myKmL,
    };
  }
  const totDist   = trips.reduce((s, t) => s + (t.distKm  || 0), 0);
  const totFuel   = trips.reduce((s, t) => s + (t.fuelL   || 0), 0);
  const totNetKwh = trips.reduce((s, t) => s + (t.netKwh  || 0), 0);
  const avgKwh100 = totDist > 0.1   ? totNetKwh / totDist * 100 : 0;
  const avgEqKmL  = totDist > 0.1 && (totNetKwh > 0 || totFuel > 0.001)
    ? totDist / (totNetKwh / KWH_PER_L + totFuel) : 0;
  const totCost   = (priceGas > 0 || priceKwh > 0)
    ? totFuel * priceGas + totNetKwh * priceKwh : 0;
  const avgCostPerKm = totCost > 0 && totDist > 0.1 ? totCost / totDist : 0;

  html += `<div class="charge-summary-card" style="border-color:rgba(77,187,255,.2)">
  <div class="card-title">Resumo — ${trips.length} viagem${trips.length !== 1 ? 'ns' : ''}</div>
  <div class="metrics-row">
    <div class="metric"><div class="metric-value blue sm">${f1(totDist)} km</div><div class="metric-label">distância</div></div>
    <div class="metric"><div class="metric-value green sm">${avgKwh100 > 0 ? f1(avgKwh100) : '--'}</div><div class="metric-label">kWh/100km</div></div>
    <div class="metric"><div class="metric-value green sm">${avgEqKmL > 0 ? f1(avgEqKmL) : '--'}</div><div class="metric-label">km/L eq</div></div>
  </div>
  <div class="metrics-row" style="margin-top:4px">
    <div class="metric"><div class="metric-value orange sm">${totFuel > 0.001 ? f2(totFuel) + ' L' : '--'}</div><div class="metric-label">combustível</div></div>
    <div class="metric"><div class="metric-value teal sm">${totNetKwh > 0.01 ? f2(totNetKwh) + ' kWh' : '--'}</div><div class="metric-label">bat. consumida</div></div>
    <div class="metric"><div class="metric-value yellow sm">${totCost > 0 ? 'R$ ' + f2(totCost) : '--'}</div><div class="metric-label">custo</div></div>
    ${avgCostPerKm > 0 ? `<div class="metric"><div class="metric-value yellow sm">${f3(avgCostPerKm)}</div><div class="metric-label">R$/km</div></div>` : ''}
  </div>
</div>`;

  html += trips.map(t => {
    const startDate  = fmtDate(t.startMs);
    const dur        = fmtDur(Math.round((t.endMs - t.startMs) / 1000));
    const distKm     = t.distKm      > 0    ? f1(t.distKm) + ' km'  : '--';
    const netKwh     = t.netKwh      > 0    ? f2(t.netKwh) + ' kWh' : '--';
    const fuelL      = t.fuelL       > 0    ? f2(t.fuelL)  + ' L'   : '--';
    const kwh100     = t.distKm > 0.1 && t.netKwh > 0 ? f1(t.netKwh / t.distKm * 100) : null;
    const kmPerL     = t.fuelL > 0.001 ? f1(t.distKm / t.fuelL) : null;
    const eqKmL      = t.distKm > 0.1 && ((t.netKwh || 0) > 0 || t.fuelL > 0.001)
      ? f1(t.distKm / ((t.netKwh || 0) / KWH_PER_L + (t.fuelL || 0))) : null;
    const socDelta   = t.startSocPct > 0    ? `${t.startSocPct.toFixed(0)}%→${t.endSocPct.toFixed(0)}%` : '--';
    const maxSpd     = t.maxSpeedKmh > 0    ? `${Math.round(t.maxSpeedKmh)} km/h` : null;
    const avgSpd     = t.timeSec > 0        ? `${Math.round(t.distKm / (t.timeSec / 3600))} km/h` : null;
    const tempStr    = t.outsideTempC != null ? `${Math.round(t.outsideTempC)}°C`  : null;
    const hasGps     = t.startLat && (t.startLat !== 0 || t.startLng !== 0);
    const mapsUrl    = hasGps ? `https://www.google.com/maps/dir/${t.startLat},${t.startLng}/${t.endLat},${t.endLng}` : null;
    // Subtítulo "📍 Bairro, Cidade" só aparece se a origem NÃO é local conhecido.
    // Quando t.knownStart existe (ex.: "Casa"), o título já mostra o nome — o bairro
    // do GPS seria redundante e parecia que "Casa" estava virando bairro.
    const geo        = geoCache[t.tripId];
    const showGeo    = !!geo && !t.knownStart;
    const geoLine    = showGeo ? `<div class="trip-geo">📍 ${geo}</div>` : '';
    const autoName    = getAutoName(t);
    const rnTrackH    = renameTracking[String(t.tripId)];
    const displayName = (rnTrackH?.name) || t.name || autoName || '';
    const nameStyle   = !rnTrackH?.name && !t.name && autoName ? 'color:#64748b;font-style:italic' : '';
    const rnStatus    = getRenameStatus(t.tripId);
    const statusBadge = rnStatus === 'pending'   ? '<span class="rename-status-pending" title="Aguardando confirmação do carro">⏳</span>'
                      : rnStatus === 'confirmed'  ? '<span class="rename-status-ok" title="Confirmado pelo carro">✓</span>'
                      : '';
    // Indicador de eficiência vs média do mesmo trecho (start/end ~200m, ±10% km)
    const effInfo = _effIndex[t.tripId];
    let effBadge = '';
    if (effInfo) {
      const pct = effInfo.pct;
      // Banda neutra ±2% (≈ ruído de medida)
      const cls = pct >= 2 ? 'better' : pct <= -2 ? 'worse' : 'neutral';
      const arrow = pct >= 2 ? '↑' : pct <= -2 ? '↓' : '≈';
      const sign  = pct > 0 ? '+' : '';
      const tip   = `vs média de ${effInfo.sampleCount + 1} viagens deste trecho (${effInfo.avgKmL.toFixed(1)} km/L eq)`;
      effBadge = `<span class="trip-eff-badge ${cls}" title="${tip}">${arrow} ${sign}${pct.toFixed(0)}%</span>`;
    }

    // Eco score 0-100 — combina elétrico, regen, vel.média, suavidade e vs trecho
    const score = _computeEcoScore(t, effInfo);
    let ecoBadge = '';
    if (score !== null) {
      const cls   = score >= 85 ? 'eco-excellent' : score >= 70 ? 'eco-good' : score >= 50 ? 'eco-ok' : 'eco-bad';
      const icon  = score >= 85 ? '🌿' : score >= 70 ? '🌱' : score >= 50 ? '🌾' : '🥀';
      const tip   = `Eco score: ${score} · ${_ecoScoreDetail(t, effInfo)}`;
      ecoBadge = `<span class="trip-eco-badge ${cls}" title="${tip}">${icon} ${score}</span>`;
    }
    const atOv     = _tripCostOverride(t.tripId);
    const atFuelL  = t.fuelL  || 0;
    const atNetKwh = t.netKwh || 0;
    // Preços vigentes NO MOMENTO da viagem (lookup na timeline) —
    // refuels/charges posteriores ao trip não afetam seu custo, mas
    // refuels/charges registrados retroativamente SIM (data correta).
    const { gas: _tPriceGas, kwh: _tPriceKwh } = pricesAt(t.startMs);
    const tripCost = atOv ? atOv.cost
      : ((_tPriceGas > 0 || _tPriceKwh > 0) ? atFuelL * _tPriceGas + atNetKwh * _tPriceKwh : 0);
    const costStr = `<span id="cost-badge-${t.tripId}" class="trip-cost"${tripCost <= 0 ? ' style="display:none"' : atOv ? ' style="border-bottom:1px dashed rgba(251,191,36,.5)"' : ''}>${tripCost > 0 ? 'R$ ' + f2(tripCost) : ''}</span>`;
    // Row 2: consumo — só exibe se tiver pelo menos um campo com dado
    const hasRow2  = netKwh !== '--' || fuelL !== '--' || kwh100 || eqKmL || tempStr;
    const row2     = hasRow2 ? `
  <div class="trip-metrics trip-metrics-row2">
    ${kwh100 ? `<div class="trip-metric"><div class="trip-metric-val green">${kwh100}</div><div class="trip-metric-lbl">kWh/100km</div></div>` : ''}
    ${netKwh !== '--' ? `<div class="trip-metric"><div class="trip-metric-val teal">${netKwh}</div><div class="trip-metric-lbl">kWh liq.</div></div>` : ''}
    ${fuelL !== '--' ? `<div class="trip-metric"><div class="trip-metric-val orange">${fuelL}</div><div class="trip-metric-lbl">combust.</div></div>` : ''}
    ${eqKmL ? `<div class="trip-metric"><div class="trip-metric-val green">${eqKmL}</div><div class="trip-metric-lbl">km/L eq</div></div>` : ''}
    ${tripCost > 0 && t.distKm > 0.1 ? `<div class="trip-metric"><div class="trip-metric-val yellow">${f3(tripCost / t.distKm)}</div><div class="trip-metric-lbl">R$/km</div></div>` : ''}
    ${tempStr ? `<div class="trip-metric"><div class="trip-metric-val blue">${tempStr}</div><div class="trip-metric-lbl">temp. ext.</div></div>` : ''}
  </div>` : '';
    return `<div class="trip-item" id="trip-card-${t.tripId}">
  <div class="trip-header">
    <div style="flex:1;min-width:0">
      <div class="trip-name-row">
        ${displayName ? `<span class="trip-name"${nameStyle ? ` style="${nameStyle}"` : ''}>${displayName}</span>${statusBadge}` : ''}
        ${ecoBadge}${effBadge}
        <button class="rename-btn" onclick="startRenameTrip('${t.tripId}','auto')" title="${displayName ? 'Renomear' : 'Nomear'}">✏️</button>
        ${effInfo ? `<button class="rename-btn" onclick="openCompareModal('${t.tripId}')" title="Comparar com outra viagem do mesmo trecho" style="opacity:.6">🔀</button>` : ''}
        <button class="rename-btn" onclick="deleteTrip('${t.tripId}','auto')" title="Apagar viagem" style="opacity:.35">🗑</button>
      </div>
      <div class="trip-date">${startDate} · ${dur}${geoLine ? ' · ' + geo : ''}</div>
    </div>
    <div style="display:flex;flex-direction:column;align-items:flex-end;gap:3px">
      ${costStr}
      <div style="display:flex;gap:4px">
        <button class="cost-edit-btn" onclick="openMergeModal('${t.tripId}')" title="Unir viagens">🔗</button>
        <button class="cost-edit-btn" onclick="toggleCostEdit('${t.tripId}')" title="Recalcular custo">💰</button>
      </div>
    </div>
  </div>
  <div id="cost-edit-${t.tripId}" class="cost-edit-form" style="display:none">
    <input class="cost-gas-input" type="number" step="0.01" min="0" placeholder="R$/L gasolina"${atOv?.gas > 0 ? ` value="${atOv.gas}"` : ''}>
    <input class="cost-kwh-input" type="number" step="0.01" min="0" placeholder="R$/kWh energia"${atOv?.kwh > 0 ? ` value="${atOv.kwh}"` : ''}>
    <button class="cost-apply-btn" onclick="applyTripCost('${t.tripId}',${atFuelL.toFixed(3)},${atNetKwh.toFixed(3)})">Recalcular</button>
  </div>
  <div class="trip-metrics">
    <div class="trip-metric"><div class="trip-metric-val blue">${distKm}</div><div class="trip-metric-lbl">dist.</div></div>
    ${avgSpd  ? `<div class="trip-metric"><div class="trip-metric-val" style="color:var(--muted)">${avgSpd}</div><div class="trip-metric-lbl">vel. méd.</div></div>` : ''}
    ${maxSpd  ? `<div class="trip-metric"><div class="trip-metric-val" style="color:var(--muted)">${maxSpd}</div><div class="trip-metric-lbl">vel. máx.</div></div>` : ''}
    <div class="trip-metric"><div class="trip-metric-val teal">${socDelta}</div><div class="trip-metric-lbl">SOC</div></div>
    <div class="trip-metric"><div class="trip-metric-val" style="color:#5B7394">${dur}</div><div class="trip-metric-lbl">duração</div></div>
  </div>${row2}
  <div class="trip-actions">
    <button class="trip-action-btn" onclick="openTripDetail('${t.tripId}')">🗺 Ver rota</button>
    <button class="trip-action-btn" style="color:#94a3b8" onclick="shareTripCard('${t.tripId}')">📸 Snapshot</button>
    ${mapsUrl ? `<a class="trip-action-btn" href="${mapsUrl}" target="_blank">📍 Maps</a>` : ''}
  </div>
</div>`;
  }).join('');

  list.innerHTML = html;
}

// ── Unir auto-trips ───────────────────────────────────────────────────────────
function openMergeModal(tripBId) {
  const trips = cachedAutoTrips || [];
  const tripB = trips.find(t => t.tripId === tripBId);
  if (!tripB) return;

  document.getElementById('merge-modal')?.remove();
  const modal = document.createElement('div');
  modal.id = 'merge-modal';
  modal.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.88);z-index:9999;overflow-y:auto;padding:16px;-webkit-overflow-scrolling:touch';

  const fmtT = t => {
    const nm = (renameTracking[String(t.tripId)]?.name) || t.name || getAutoName(t) || '';
    return (nm ? `<strong>${nm}</strong> · ` : '') + fmtDate(t.startMs) + ' · ' + f1(t.distKm||0) + ' km · ' + fmtDur(Math.round(((t.endMs||t.startMs)-(t.startMs||0))/1000));
  };

  // Candidatos ordenados por proximidade temporal ao início de B
  const candidates = trips
    .filter(t => t.tripId !== tripBId)
    .sort((a,b) => Math.abs((a.endMs||a.startMs)-tripB.startMs) - Math.abs((b.endMs||b.startMs)-tripB.startMs));

  let rows = '';
  for (const t of candidates.slice(0, 40)) {
    const total = f1((tripB.distKm||0)+(t.distKm||0));
    rows += `<button onclick="confirmMerge('${tripBId}','${t.tripId}')"
      style="width:100%;background:#0f172a;border:1px solid #1e293b;border-radius:8px;padding:10px 12px;text-align:left;cursor:pointer;color:#e2e8f0;font-size:12px;line-height:1.4;margin-bottom:6px">
      <div>${fmtT(t)}</div>
      <div style="color:#4ade80;font-size:11px;margin-top:3px">→ total após união: ${total} km</div>
    </button>`;
  }

  modal.innerHTML = `<div style="max-width:500px;margin:0 auto">
    <div style="color:#7FBADC;font-weight:700;font-size:14px;margin-bottom:12px">🔗 Unir com outra viagem</div>
    <div style="background:#0f172a;border:1px solid #22d3ee44;border-radius:10px;padding:10px 12px;margin-bottom:14px">
      <div style="font-size:10px;color:#64748b;margin-bottom:4px;letter-spacing:.06em">VIAGEM SELECIONADA</div>
      <div style="font-size:13px;color:#e2e8f0">${fmtT(tripB)}</div>
    </div>
    <div style="font-size:10px;color:#64748b;letter-spacing:.06em;margin-bottom:8px">ESCOLHA A OUTRA VIAGEM</div>
    ${rows}
    <button onclick="document.getElementById('merge-modal').remove()"
      style="width:100%;margin-top:8px;padding:11px;background:#1e293b;border:1px solid #334155;border-radius:8px;color:#94a3b8;font-size:13px;cursor:pointer">
      Cancelar
    </button>
  </div>`;
  document.body.appendChild(modal);
}

function confirmMerge(tripBId, tripAId) {
  const trips = cachedAutoTrips || [];
  const A = trips.find(t => t.tripId === tripAId);
  const B = trips.find(t => t.tripId === tripBId);
  if (!A || !B) return;
  const nmA = (renameTracking[String(tripAId)]?.name) || A.name || getAutoName(A) || fmtDate(A.startMs);
  const nmB = (renameTracking[String(tripBId)]?.name) || B.name || getAutoName(B) || fmtDate(B.startMs);
  const total = f1((A.distKm||0)+(B.distKm||0));
  if (!confirm(`Unir as duas viagens?\n\n• ${nmA}  (${f1(A.distKm||0)} km)\n• ${nmB}  (${f1(B.distKm||0)} km)\n\nResultado: ${total} km\n\nEsta ação não pode ser desfeita.`)) return;
  document.getElementById('merge-modal')?.remove();
  executeMerge(tripAId, tripBId);
}

async function executeMerge(tripAId, tripBId) {
  try {
    const r = await apiFetch('/api/autotrips/merge', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ tripAId, tripBId }),
    });
    const d = await r.json();
    if (!d.ok) { alert('Erro ao unir viagens: ' + (d.error || '?')); return; }

    // Atualiza IDB: remove a viagem que foi absorvida, upsert a viagem unificada
    const lateId = (d.trip.startMs === (cachedAutoTrips||[]).find(t=>t.tripId===tripAId)?.startMs)
      ? tripBId : tripAId;
    await _idbDelete('autotrips', lateId);
    if (d.trip) await _idbPutMany('autotrips', [d.trip]);

    cachedAutoTrips = (await _idbGetAll('autotrips'))
      .sort((a,b) => (b.startMs||0)-(a.startMs||0));
    renderAutoTrips();
  } catch (e) {
    alert('Erro de rede: ' + e.message);
  }
}

// ── Alertas do carro ─────────────────────────────────────────────────────────
const ALERT_TEXTS = {
  'NO_ALERTS':                   null,   // null = suprimir
  'ERR_FORMATTING_ADDRESS':      'Erro ao formatar endereço.',
  'ERR_GENERATE_RESPONSE':       'Houve um erro ao gerar a resposta.',
  'ALERT_HIGH_VOLTAGE_DISCONNECT': 'A bateria de alta tensão está totalmente carregada. Desconecte o carregador.',
  'SUNROOF_OPEN':                'O teto solar está aberto.',
  'UNLOCKED':                    'As portas não estão trancadas — o veículo pode ser aberto.',
  'ENGINE_ON_AND_UNLOCKED':      'O motor está ligado e o veículo está destravado.',
  'FUEL_LOW':                    'Combustível abaixo de 15 litros. Reabasteça.',
  'AC_ON_WITH_ENGINE_OFF':       'AC ligado com motor desligado — pode drenar a bateria 12V.',
  'REVIEW_PREFIX':               'Veículo dentro do limite para agendar revisão.',
};

// ── Limite de carga SOC ───────────────────────────────────────────────────────
let _clLimitTimer = null;

function _renderChargeLimit(pct) {
  // Atualiza ambos os painéis (charging card + settings)
  const label = pct != null ? pct + '%' : '--%';
  setText('d-chrg-limit', label);
  setText('s-chrg-limit', label);
  document.querySelectorAll('.clb').forEach(b => {
    b.classList.toggle('clb-active', parseInt(b.textContent) === pct);
  });
}

function _clSetStatus(msg) {
  ['d-chrg-limit-status', 's-chrg-limit-status'].forEach(id => {
    const el = document.getElementById(id);
    if (el) el.textContent = msg;
  });
}

async function setChargeLimit(pct) {
  _clSetStatus('⏳ Enviando…');
  document.querySelectorAll('.clb').forEach(b => b.disabled = true);
  try {
    const r = await apiFetch('/api/charge-limit', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ pct }),
    });
    const data = await r.json().catch(() => ({}));
    if (!r.ok || !data.ok) {
      _clSetStatus('✗ ' + (data.error || 'Erro'));
    } else {
      _clSetStatus('⏳ Aguardando carro…');
      clearTimeout(_clLimitTimer);
      _clLimitTimer = setTimeout(() => {
        _clSetStatus('⚠️ Sem resposta — carro pode estar dormindo');
      }, 60000);
    }
  } catch (e) {
    _clSetStatus('✗ Sem conexão com o servidor');
  } finally {
    document.querySelectorAll('.clb').forEach(b => b.disabled = false);
  }
}

function _onChargeLimitResult(result) {
  clearTimeout(_clLimitTimer);
  if (result.startsWith('ok:')) {
    const pct = parseInt(result.replace('ok:', ''));
    _clSetStatus('✓ Limite aplicado: ' + pct + '%');
    _renderChargeLimit(pct);
  } else {
    _clSetStatus('✗ ' + result.replace('error:', ''));
  }
  setTimeout(() => _clSetStatus(''), 6000);
}

function renderAlerts(s) {
  const card = document.getElementById('d-alerts-card');
  const body = document.getElementById('d-alerts-body');
  if (!card || !body) return;

  const raw = s.status_message || '';
  const skip = ['', 'NO_ALERTS', 'unknown', 'unavailable'];
  if (skip.includes(raw.trim())) { card.style.display = 'none'; return; }

  const lines = [];
  raw.split('|').forEach(item => {
    const parts = item.split('@');
    const code  = parts[0].trim();
    if (!code) return;

    if (code in ALERT_TEXTS) {
      const txt = ALERT_TEXTS[code];
      if (txt) lines.push(txt);  // null = NO_ALERTS → não exibe
    } else if (code === 'VEHICLE_CHARGING_TIME' && parts.length >= 2) {
      lines.push(`Carregando — conclusão estimada em ${parts[1]}.`);
    } else if (code === 'WINDOW_OPEN' && parts.length >= 2) {
      lines.push(`O ${parts[1]} está aberto.`);
    } else if (code === 'DOOR_OPEN' && parts.length >= 2) {
      lines.push(`A ${parts[1]} está aberta.`);
    } else if (code === 'TRUNK_OPEN' && parts.length >= 2) {
      lines.push(`O ${parts[1]} está aberto.`);
    } else if (code === 'BATTERY_12V_CRITICAL' && parts.length >= 2) {
      lines.push(`🔴 Bateria 12V em ${parts[1]}% — ligue o motor imediatamente.`);
    } else if (code === 'BATTERY_12V_ALERT' && parts.length >= 2) {
      lines.push(`🟠 Bateria 12V em ${parts[1]}%.`);
    } else if (code === 'TIRE_PRESSURE' && parts.length >= 4) {
      lines.push(`${parts[1]}: ${parts[2]} psi · ${parts[3]}°C.`);
    } else if (code === 'TIRE_PRESSURE_DEFAULTS' && parts.length >= 3) {
      lines.push(`Pressão recomendada: ${parts[1]}–${parts[2]} psi.`);
    } else if (code === 'SERVICE_WITH_TOLERANCE' && parts.length >= 2) {
      lines.push(`Revisão: restam ${parts[1]} km antes da perda da garantia.`);
    } else {
      lines.push(item.trim());
    }
  });

  if (!lines.length) { card.style.display = 'none'; return; }

  card.style.display = '';
  body.innerHTML = lines.map(l =>
    `<div style="display:flex;align-items:flex-start;gap:8px;font-size:13px;color:#cbd5e1;line-height:1.45">
      <span style="color:var(--orange);flex-shrink:0;margin-top:1px">•</span>
      <span>${l}</span>
    </div>`
  ).join('');
}

// ── Dashboard map — última localização do carro ───────────────────────────────
// Zoom inteligente dos mapas: 3 modos baseado na velocidade.
//   parked  (≤3 km/h):  zoom 15 — área local
//   urban   (3..50):    zoom 17 — visão detalhada de ruas
//   highway (>50):      zoom 14 — afasta pra ver o caminho na estrada
// Histerese: ao cair de highway, só desce o zoom após 30s ininterruptos abaixo
// de 50 (cada pico ≥50 reseta). Subir pra highway é imediato.
const MAP_HIGHWAY_KMH       = 50;
const MAP_HIGHWAY_HOLD_MS   = 30000;
const MAP_ZOOM_HIGHWAY      = 14;
const MAP_ZOOM_URBAN        = 17;
const MAP_ZOOM_PARKED       = 15;
function _updateMapZoomForSpeed(map, kmh, stateRef) {
  const now       = Date.now();
  const isHighway = kmh > MAP_HIGHWAY_KMH;
  if (isHighway) {
    stateRef.lastHighwayMs = now;
    if (stateRef.zoomMode !== 'highway') {
      stateRef.zoomMode = 'highway';
      map.setZoom(MAP_ZOOM_HIGHWAY, { animate: true });
    }
    return;
  }
  // Abaixo de 50 — se ainda estava em highway, espera o cooldown
  if (stateRef.zoomMode === 'highway') {
    if (now - (stateRef.lastHighwayMs || 0) >= MAP_HIGHWAY_HOLD_MS) {
      const next = kmh > 3 ? 'urban' : 'parked';
      stateRef.zoomMode = next;
      map.setZoom(next === 'urban' ? MAP_ZOOM_URBAN : MAP_ZOOM_PARKED, { animate: true });
    }
    return;
  }
  // Transições urban ↔ parked: imediatas (comportamento original)
  const next = kmh > 3 ? 'urban' : 'parked';
  if (next !== stateRef.zoomMode) {
    stateRef.zoomMode = next;
    map.setZoom(next === 'urban' ? MAP_ZOOM_URBAN : MAP_ZOOM_PARKED, { animate: true });
  }
}

let dashMap             = null;
let _dashMapZoomState   = { zoomMode: null, lastHighwayMs: 0 };
let dashMarker          = null;
let _dashMapLastLat     = 0;
let _dashMapLastLng     = 0;
let _dashMapLastTs      = 0;
let _dashMapGeocodeTimer = null;
let _dashMapTsTimer     = null;

function _startDashMapTsTimer() {
  clearInterval(_dashMapTsTimer);
  _dashMapTsTimer = setInterval(() => {
    if (_dashMapLastTs) setText('d-map-ts', relTime(_dashMapLastTs) + ' atrás');
  }, 30_000);
}

function updateDashMap(lat, lng, ts, speed) {
  if (!lat || !lng || lat === 0 || lng === 0) return;

  const card = document.getElementById('d-map-card');
  if (card) card.style.display = '';
  const el = document.getElementById('d-car-map');
  if (!el) return;

  const pos      = [lat, lng];
  const kmh      = +speed || 0;

  // Cria o mapa Leaflet uma única vez
  if (!dashMap) {
    dashMap = L.map(el, {
      zoomControl:        false,
      attributionControl: false,
      dragging:           true,
      scrollWheelZoom:    false,
    });
    L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
      maxZoom: 19,
      attribution: '© OpenStreetMap © CARTO',
    }).addTo(dashMap);
    // Primeira posição: escolhe zoom inicial baseado na velocidade
    const initialZoom = kmh > MAP_HIGHWAY_KMH ? MAP_ZOOM_HIGHWAY
                      : kmh > 3               ? MAP_ZOOM_URBAN
                      :                          MAP_ZOOM_PARKED;
    dashMap.setView(pos, initialZoom);
    _dashMapZoomState.zoomMode = kmh > MAP_HIGHWAY_KMH ? 'highway' : kmh > 3 ? 'urban' : 'parked';
    _dashMapZoomState.lastHighwayMs = kmh > MAP_HIGHWAY_KMH ? Date.now() : 0;
    _startDashMapTsTimer();
  } else {
    dashMap.panTo(pos, { animate: true, duration: 0.5 });
    _updateMapZoomForSpeed(dashMap, kmh, _dashMapZoomState);
  }

  if (dashMarker) dashMarker.setLatLng(pos);
  else {
    dashMarker = L.marker(pos, {
      icon: L.divIcon({
        className: '',
        html: '<div class="map-pulse-dot"></div>',
        iconSize: [14, 14],
        iconAnchor: [7, 7],
      }),
    }).addTo(dashMap);
    dashMarker.bindPopup('🚗 Haval H6 PHEV34');
  }

  if (ts) {
    _dashMapLastTs = ts;
    setText('d-map-ts', relTime(ts) + ' atrás');
  }

  // Reverse geocoding — só quando a posição muda de forma significativa (>50 m ~= 0.0005°)
  const moved = Math.abs(lat - _dashMapLastLat) > 0.0005 || Math.abs(lng - _dashMapLastLng) > 0.0005;
  if (moved) {
    _dashMapLastLat = lat;
    _dashMapLastLng = lng;
    clearTimeout(_dashMapGeocodeTimer);
    _dashMapGeocodeTimer = setTimeout(() => {
      fetch(`https://nominatim.openstreetmap.org/reverse?format=json&lat=${lat}&lon=${lng}&zoom=16`)
        .then(r => r.json())
        .then(geo => {
          const a = geo.address || {};
          const parts = [
            a.road,
            a.suburb || a.neighbourhood || a.quarter,
            a.city || a.town || a.village || a.municipality,
          ].filter(Boolean);
          const label = parts.length ? parts.join(', ')
                      : (geo.display_name || '').split(',').slice(0, 2).join(',').trim();
          setText('d-map-address', label);
        })
        .catch(() => {});
    }, 2000);  // debounce 2s para não spammar Nominatim
  }
}

// Inicialização: tenta posição da última viagem via API (fallback se GPS ao vivo não chegou ainda)
function initDashMap() {
  apiFetch('/api/location')
    .then(r => r.json())
    .then(data => { if (data.lat && data.lng) updateDashMap(data.lat, data.lng, data.ts); })
    .catch(() => {});
}

// ── Trip detail: mapa Leaflet + gráficos Chart.js ─────────────────────────────
let leafletMap      = null;
let routePolyline   = null;
let playbackMarker  = null;
let chartSpd        = null;
let chartEv         = null;
let chartRpm        = null;
let chartPwr        = null;
let chartSoc        = null;
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
      renderSpeedBands(currentSamples);
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
  if (chartPwr)   { chartPwr.destroy();  chartPwr  = null; }
  if (chartSoc)   { chartSoc.destroy();  chartSoc  = null; }
  routePolyline  = null;
  playbackMarker = null;
  currentSamples = [];
  // Restaura o HTML original do body — garante que #trip-map e canvases
  // existam frescos na próxima abertura (evita erro de Leaflet + canvases sujos)
  const body = document.getElementById('trip-detail-body');
  if (body && tripBodyOriginalHTML) body.innerHTML = tripBodyOriginalHTML;
}

// ── Linha do tempo de recarga ─────────────────────────────────────────────────
let _chrgChartPower = null;
let _chrgChartKwh   = null;
let _chrgChartSoc   = null;
let _chrgChartTemp  = null;

function openChargeTimeline(ts) {
  const overlay = document.getElementById('charge-timeline');
  overlay.style.display = 'flex';

  // Título: data da recarga
  const charge = (cachedCharges || []).find(c => (c.timestamp_ms || 0) === ts);
  const title  = charge ? fmtDate(charge.timestamp) : String(ts);
  document.getElementById('charge-timeline-title').textContent = title;

  const body = document.getElementById('charge-timeline-body');

  apiFetch(`/api/charges/${ts}/samples`)
    .then(r => r.json())
    .then(samples => {
      if (!Array.isArray(samples) || !samples.length) {
        body.innerHTML = '<div class="empty" style="padding:40px">Nenhuma amostra disponível.<br><span style="font-size:11px;color:#5B7394">A linha do tempo é registrada automaticamente na próxima recarga após atualizar o app.</span></div>';
        return;
      }

      // Labels em minutos
      const labels  = samples.map(s => (s.t / 60).toFixed(1));
      const mkChart = (id, dataset, color, fill = false) => {
        const ctx = document.getElementById(id).getContext('2d');
        return new Chart(ctx, {
          type: 'line',
          data: {
            labels,
            datasets: [{
              data:        dataset,
              borderColor: color,
              borderWidth: 2,
              pointRadius: 0,
              fill:        fill ? { target: 'origin', above: color + '33' } : false,
              tension:     0.3,
            }],
          },
          options: {
            animation: false,
            responsive: true, maintainAspectRatio: false,
            scales: {
              x: {
                display: true,
                ticks: { color: '#5B7394', font: { size: 9 }, maxTicksLimit: 8 },
                grid:  { color: '#0F1520' },
                title: { display: true, text: 'min', color: '#5B7394', font: { size: 9 } },
              },
              y: {
                display: true,
                ticks: { color: '#5B7394', font: { size: 9 }, maxTicksLimit: 5 },
                grid:  { color: '#0F1520' },
              },
            },
            plugins: { legend: { display: false }, tooltip: { enabled: false } },
          },
        });
      };

      // Destrói charts anteriores
      [_chrgChartPower, _chrgChartKwh, _chrgChartSoc, _chrgChartTemp].forEach(c => c?.destroy());

      _chrgChartPower = mkChart('chart-chrg-power', samples.map(s => parseFloat(s.powerKw   || 0)), '#7FBADC', true);
      _chrgChartKwh   = mkChart('chart-chrg-kwh',   samples.map(s => parseFloat(s.sessionKwh || 0)), '#39FF88', true);
      _chrgChartSoc   = mkChart('chart-chrg-soc',   samples.map(s => parseFloat(s.socPct    || 0)), '#a78bfa', false);

      // Temperatura: mostra só se houver pelo menos uma leitura não-null
      const temps = samples.map(s => s.tempC != null ? parseFloat(s.tempC) : null);
      const hasTemp = temps.some(t => t !== null);
      document.getElementById('chart-chrg-temp-lbl').style.display  = hasTemp ? '' : 'none';
      document.getElementById('chart-chrg-temp-wrap').style.display = hasTemp ? '' : 'none';
      if (hasTemp) {
        _chrgChartTemp = mkChart('chart-chrg-temp', temps, '#F97316', false);
      }
    })
    .catch(() => {
      body.innerHTML = '<div class="empty" style="padding:40px">Erro ao carregar amostras.</div>';
    });
}

function closeChargeTimeline() {
  document.getElementById('charge-timeline').style.display = 'none';
  [_chrgChartPower, _chrgChartKwh, _chrgChartSoc, _chrgChartTemp].forEach(c => c?.destroy());
  _chrgChartPower = null; _chrgChartKwh = null; _chrgChartSoc = null; _chrgChartTemp = null;
}

// ── Unir recargas ─────────────────────────────────────────────────────────────
function openMergeChargeModal(ts) {
  const charges = cachedCharges || [];
  const chargeB = charges.find(c => (c.timestamp_ms || 0) === ts);
  if (!chargeB) return;

  document.getElementById('merge-charge-modal')?.remove();
  const modal = document.createElement('div');
  modal.id = 'merge-charge-modal';
  modal.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.88);z-index:9999;overflow-y:auto;padding:16px;-webkit-overflow-scrolling:touch';

  const fmtC = c => {
    const kwh  = f2(c.energy_kwh || 0);
    const soc  = `${(c.soc_start||0).toFixed(0)}% → ${(c.soc_end||0).toFixed(0)}%`;
    const loc  = c.location_name ? ` · 📍 ${c.location_name}` : '';
    return `<strong>${fmtDate(c.timestamp)}</strong> · ${kwh} kWh · ${soc}${loc}`;
  };

  // Candidatos ordenados por proximidade temporal — mais próximos primeiro
  const candidates = charges
    .filter(c => (c.timestamp_ms || 0) !== ts)
    .sort((a, b) =>
      Math.abs((a.timestamp_ms || 0) - ts) - Math.abs((b.timestamp_ms || 0) - ts)
    );

  let rows = '';
  for (const c of candidates.slice(0, 30)) {
    const tsMerge = c.timestamp_ms || 0;
    const totalKwh = f2((chargeB.energy_kwh || 0) + (c.energy_kwh || 0));
    const [socStart, socEnd] = (c.timestamp_ms || 0) < ts
      ? [`${(c.soc_start||0).toFixed(0)}%`, `${(chargeB.soc_end||0).toFixed(0)}%`]
      : [`${(chargeB.soc_start||0).toFixed(0)}%`, `${(c.soc_end||0).toFixed(0)}%`];
    rows += `<button onclick="confirmMergeCharge(${ts},${tsMerge})"
      style="width:100%;background:#0f172a;border:1px solid #1e293b;border-radius:8px;padding:10px 12px;text-align:left;cursor:pointer;color:#e2e8f0;font-size:12px;line-height:1.4;margin-bottom:6px">
      <div>${fmtC(c)}</div>
      <div style="color:#7FBADC;font-size:11px;margin-top:3px">→ resultado: ${totalKwh} kWh · SOC ${socStart} → ${socEnd}</div>
    </button>`;
  }
  if (!rows) rows = '<div style="color:#5B7394;font-size:12px;padding:8px 0">Nenhuma outra recarga disponível para unir.</div>';

  modal.innerHTML = `<div style="max-width:500px;margin:0 auto">
    <div style="color:#7FBADC;font-weight:700;font-size:14px;margin-bottom:12px">🔗 Unir com outra recarga</div>
    <div style="background:#0f172a;border:1px solid #22d3ee44;border-radius:10px;padding:10px 12px;margin-bottom:14px">
      <div style="font-size:10px;color:#64748b;margin-bottom:4px;letter-spacing:.06em">RECARGA SELECIONADA</div>
      <div style="font-size:13px;color:#e2e8f0">${fmtC(chargeB)}</div>
    </div>
    <div style="font-size:10px;color:#64748b;letter-spacing:.06em;margin-bottom:8px">ESCOLHA A OUTRA RECARGA</div>
    ${rows}
    <div style="font-size:10px;color:#475569;margin-top:12px;padding:10px;background:#0f172a;border-radius:8px;line-height:1.5">
      ⚠️ A fusão soma duração e energia injetada, preserva local, kWh do carregador, custo e temperatura.
      O SOC inicial virá da recarga mais antiga e o SOC final da mais nova. Esta ação não pode ser desfeita.
    </div>
    <button onclick="document.getElementById('merge-charge-modal').remove()"
      style="width:100%;margin-top:10px;padding:11px;background:#1e293b;border:1px solid #334155;border-radius:8px;color:#94a3b8;font-size:13px;cursor:pointer">
      Cancelar
    </button>
  </div>`;
  document.body.appendChild(modal);
}

function confirmMergeCharge(tsB, tsA) {
  const charges = cachedCharges || [];
  const A = charges.find(c => (c.timestamp_ms || 0) === tsA);
  const B = charges.find(c => (c.timestamp_ms || 0) === tsB);
  if (!A || !B) return;
  const dateA   = fmtDate(A.timestamp);
  const dateB   = fmtDate(B.timestamp);
  const totalKwh = f2((A.energy_kwh || 0) + (B.energy_kwh || 0));
  const [early, late] = (A.timestamp_ms || 0) < (B.timestamp_ms || 0) ? [A, B] : [B, A];
  if (!confirm(
    `Unir as duas recargas?\n\n` +
    `• ${fmtDate(early.timestamp)}  (${f2(early.energy_kwh||0)} kWh)\n` +
    `• ${fmtDate(late.timestamp)}  (${f2(late.energy_kwh||0)} kWh)\n\n` +
    `Resultado: ${totalKwh} kWh · SOC ${(early.soc_start||0).toFixed(0)}% → ${(late.soc_end||0).toFixed(0)}%\n\n` +
    `Esta ação não pode ser desfeita.`
  )) return;
  document.getElementById('merge-charge-modal')?.remove();
  executeMergeCharge(tsA, tsB);
}

async function executeMergeCharge(tsA, tsB) {
  try {
    const r = await apiFetch('/api/charges/merge', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ tsA, tsB }),
    });
    const d = await r.json();
    if (!d.ok) { alert('Erro ao unir recargas: ' + (d.error || '?')); return; }

    // Atualiza IDB: remove a recarga absorvida, upsert a unificada
    const mergedTs  = d.merged.timestamp_ms;
    const removedTs = mergedTs === tsA ? tsB : tsA;
    await _idbDelete('charges', removedTs);
    await _idbPutMany('charges', [d.merged]);

    cachedCharges = (await _idbGetAll('charges'))
      .sort((a, b) => (b.timestamp_ms || 0) - (a.timestamp_ms || 0));
    _bumpCachesVersion();
    renderCharges();
  } catch (e) {
    alert('Erro ao unir recargas: ' + e.message);
  }
}

// ── Eficiência por faixa de velocidade ───────────────────────────────────────
function calcSpeedBands(samples) {
  const bands = [
    { label: '0 – 50 km/h',   icon: '🐢', min: 0,   max: 50,       distKm: 0, kwhPos: 0 },
    { label: '50 – 100 km/h', icon: '🚗', min: 50,  max: 100,      distKm: 0, kwhPos: 0 },
    { label: '100+ km/h',     icon: '🏎', min: 100, max: Infinity,  distKm: 0, kwhPos: 0 },
  ];
  for (let i = 1; i < samples.length; i++) {
    const a = samples[i - 1], b = samples[i];
    const dt = (b.t || 0) - (a.t || 0);
    if (dt <= 0 || dt > 30) continue;
    const avgSpd = ((a.spd || 0) + (b.spd || 0)) / 2;
    const distKm = avgSpd / 3600 * dt;
    const kwhPos = Math.max(0, a.evKw || 0) / 3600 * dt;  // só consumo, sem regen
    const band = bands.find(bnd => avgSpd >= bnd.min && avgSpd < bnd.max);
    if (band) { band.distKm += distKm; band.kwhPos += kwhPos; }
  }
  return bands;
}

function renderSpeedBands(samples) {
  const bands = calcSpeedBands(samples);
  const totalDist = bands.reduce((s, b) => s + b.distKm, 0);
  if (totalDist < 0.1) return;

  let inner = '';
  for (const band of bands) {
    if (band.distKm < 0.05) continue;
    const kwh100 = band.distKm > 0 ? (band.kwhPos / band.distKm * 100).toFixed(1) : '—';
    const eqKmL  = band.distKm > 0 && band.kwhPos > 0
      ? (band.distKm / (band.kwhPos / 8.9)).toFixed(1) : '—';
    const pct = Math.round(band.distKm / totalDist * 100);
    inner += `<div style="flex:1;background:#0f172a;border:1px solid #1e293b;border-radius:10px;padding:10px 8px;text-align:center">
  <div style="font-size:22px;margin-bottom:4px">${band.icon}</div>
  <div style="font-size:10px;color:#475569;margin-bottom:8px;line-height:1.2">${band.label}</div>
  <div style="font-size:20px;font-weight:700;color:#4ade80">${kwh100}</div>
  <div style="font-size:9px;color:#64748b;margin-bottom:6px">kWh/100km</div>
  <div style="font-size:17px;font-weight:700;color:#22d3ee">${eqKmL}</div>
  <div style="font-size:9px;color:#64748b;margin-bottom:4px">km/L eq</div>
  <div style="font-size:9px;color:#334155">${band.distKm.toFixed(1)} km · ${pct}%</div>
</div>`;
  }

  const section = document.createElement('div');
  section.className = 'chart-section';
  section.style.marginTop = '0';
  section.innerHTML = `<div class="chart-label">Eficiência por faixa de velocidade</div>
<div style="display:flex;gap:8px;padding:8px 0">${inner}</div>`;
  const body = document.getElementById('trip-detail-body');
  if (body) body.appendChild(section);
}

// ── Snapshot 9:16 — helpers de tiles OSM ────────────────────────────────────
function _tileX(lng, z) { return ((lng + 180) / 360) * Math.pow(2, z); }
function _tileY(lat, z) {
  const r = lat * Math.PI / 180;
  return (1 - Math.log(Math.tan(r) + 1 / Math.cos(r)) / Math.PI) / 2 * Math.pow(2, z);
}
async function _fetchTile(z, x, y) {
  try {
    const resp = await apiFetch(`/api/tiles/${z}/${x}/${y}`);
    if (!resp.ok) return null;
    const blob = await resp.blob();
    const url  = URL.createObjectURL(blob);
    return await new Promise(res => {
      const img = new Image();
      img.onload  = () => { URL.revokeObjectURL(url); res(img); };
      img.onerror = () => { URL.revokeObjectURL(url); res(null); };
      img.src = url;
    });
  } catch (_) { return null; }
}
async function _drawOSMMap(ctx, gps, mx, my, mw, mh) {
  if (gps.length < 2) {
    ctx.font = '13px system-ui, sans-serif';
    ctx.fillStyle = '#64748b'; ctx.textAlign = 'center';
    ctx.fillText('GPS indisponível', mx + mw / 2, my + mh / 2 - 7);
    return;
  }
  // Bounding box + 25% padding
  let mnLat = Infinity, mxLat = -Infinity, mnLng = Infinity, mxLng = -Infinity;
  gps.forEach(p => {
    mnLat = Math.min(mnLat, p.lat); mxLat = Math.max(mxLat, p.lat);
    mnLng = Math.min(mnLng, p.lng); mxLng = Math.max(mxLng, p.lng);
  });
  const dLat = (mxLat - mnLat) || 0.002, dLng = (mxLng - mnLng) || 0.002;
  mnLat -= dLat * 0.25; mxLat += dLat * 0.25;
  mnLng -= dLng * 0.25; mxLng += dLng * 0.25;
  // Best zoom (cap 16, max 16 tiles)
  let z = Math.floor(Math.log2(mw * 360 / ((mxLng - mnLng) * 256)));
  z = Math.max(1, Math.min(z, 16));
  for (let tries = 0; tries < 10 && z > 1; tries++) {
    const ntx = Math.floor(_tileX(mxLng, z)) - Math.floor(_tileX(mnLng, z)) + 1;
    const nty = Math.floor(_tileY(mnLat, z)) - Math.floor(_tileY(mxLat, z)) + 1;
    if (ntx * nty <= 16) break;
    z--;
  }
  const fxMin = _tileX(mnLng, z), fyMin = _tileY(mxLat, z);
  const fxMax = _tileX(mxLng, z), fyMax = _tileY(mnLat, z);
  const txMin = Math.floor(fxMin), tyMin = Math.floor(fyMin);
  const txMax = Math.floor(fxMax), tyMax = Math.floor(fyMax);
  const scale   = mw / ((fxMax - fxMin) * 256);
  const toCanX  = fx => mx + (fx - fxMin) * 256 * scale;
  const toCanY  = fy => my + (fy - fyMin) * 256 * scale;
  const lngToC  = lng => toCanX(_tileX(lng, z));
  const latToC  = lat => toCanY(_tileY(lat, z));
  // Clip to map rect
  ctx.save();
  ctx.beginPath(); ctx.rect(mx, my, mw, mh); ctx.clip();
  // Draw OSM tiles
  const tileSize = 256 * scale;
  const nty = tyMax - tyMin + 1;
  const ntiles = (txMax - txMin + 1) * nty;
  await Promise.all(
    Array.from({ length: ntiles }, (_, i) => {
      const tx = txMin + Math.floor(i / nty);
      const ty = tyMin + (i % nty);
      return _fetchTile(z, tx, ty).then(img => {
        if (img) ctx.drawImage(img, toCanX(tx), toCanY(ty), tileSize, tileSize);
      });
    })
  );
  // Route (speed-colored) — green / orange / red (no yellow — poor contrast on OSM tiles)
  const spdClr = s => s < 40 ? '#22c55e' : s < 80 ? '#f97316' : s < 120 ? '#ef4444' : '#991b1b';
  ctx.lineWidth = 3.5; ctx.lineJoin = 'round'; ctx.lineCap = 'round';
  for (let i = 1; i < gps.length; i++) {
    const a = gps[i - 1], b = gps[i];
    ctx.strokeStyle = spdClr(a.spd || 0);
    ctx.beginPath();
    ctx.moveTo(lngToC(a.lng), latToC(a.lat));
    ctx.lineTo(lngToC(b.lng), latToC(b.lat));
    ctx.stroke();
  }
  // Start / end markers
  [[gps[0], '#4ade80'], [gps[gps.length - 1], '#60a5fa']].forEach(([p, c]) => {
    const px = lngToC(p.lng), py = latToC(p.lat);
    ctx.fillStyle = c; ctx.beginPath(); ctx.arc(px, py, 7, 0, Math.PI * 2); ctx.fill();
    ctx.strokeStyle = '#fff'; ctx.lineWidth = 2; ctx.stroke();
  });
  // Speed legend (bottom-left)
  const legY = my + mh - 20;
  [['#22c55e', '<40'], ['#f97316', '40–80'], ['#ef4444', '80–120'], ['#991b1b', '120+']].reduce((lx, [c, lbl]) => {
    ctx.fillStyle = 'rgba(11,15,26,.80)'; ctx.fillRect(lx - 2, legY - 2, 52, 16);
    ctx.fillStyle = c; ctx.fillRect(lx, legY + 5, 10, 4);
    ctx.font = '8px system-ui, sans-serif'; ctx.fillStyle = '#f1f5f9'; ctx.textAlign = 'left';
    ctx.fillText(lbl, lx + 13, legY + 2);
    return lx + 54;
  }, mx + 4);
  ctx.restore();
}
function _drawBands(ctx, samples, x, y, w) {
  const bands    = calcSpeedBands(samples);
  const totalDist = bands.reduce((s, b) => s + b.distKm, 0);
  // Section label
  ctx.font = '8px system-ui, sans-serif'; ctx.fillStyle = '#64748b'; ctx.textAlign = 'left';
  ctx.fillText('EFICIÊNCIA POR FAIXA DE VELOCIDADE', x, y);
  y += 18;
  if (totalDist < 0.1) {
    ctx.font = '11px system-ui, sans-serif'; ctx.fillStyle = '#334155'; ctx.textAlign = 'center';
    ctx.fillText('Dados insuficientes', x + w / 2, y + 8);
    return;
  }
  const BAR_X   = x + 106;
  const BAR_MAX = Math.floor(w * 0.38);
  const ROW_H   = 36;
  const xKwh    = x + w - 68;  // kWh/100km — coluna esquerda da direita
  const xKmL    = x + w;       // km/L eq   — borda direita
  for (const band of bands) {
    const pct    = Math.round(band.distKm / totalDist * 100);
    const kwh100 = band.distKm > 0.01 ? band.kwhPos / band.distKm * 100 : 0;
    const eqKmL  = band.distKm > 0.01 && band.kwhPos > 0.001 ? band.distKm / (band.kwhPos / 8.9) : 0;
    const barFill = Math.round(BAR_MAX * pct / 100);
    // Icon + label
    ctx.font = '14px system-ui, sans-serif'; ctx.fillStyle = '#e2e8f0'; ctx.textAlign = 'left';
    ctx.fillText(band.icon, x, y + 2);
    ctx.font = '9px system-ui, sans-serif'; ctx.fillStyle = '#94a3b8';
    ctx.fillText(band.label, x + 22, y + 3);
    // Progress bar track + fill
    ctx.fillStyle = '#1e293b'; ctx.fillRect(BAR_X, y + 7, BAR_MAX, 5);
    if (barFill > 0) { ctx.fillStyle = '#22d3ee'; ctx.fillRect(BAR_X, y + 7, barFill, 5); }
    ctx.font = '8px system-ui, sans-serif'; ctx.fillStyle = '#475569'; ctx.textAlign = 'left';
    ctx.fillText(`${band.distKm.toFixed(1)} km · ${pct}%`, BAR_X, y + 20);
    // kWh/100km (coluna esquerda da direita)
    ctx.font = 'bold 14px system-ui, sans-serif'; ctx.fillStyle = '#4ade80'; ctx.textAlign = 'right';
    ctx.fillText(kwh100 > 0 ? kwh100.toFixed(1) : '—', xKwh, y + 2);
    ctx.font = '8px system-ui, sans-serif'; ctx.fillStyle = '#64748b';
    ctx.fillText('kWh/100km', xKwh, y + 19);
    // km/L eq (borda direita)
    ctx.font = 'bold 14px system-ui, sans-serif'; ctx.fillStyle = '#22d3ee'; ctx.textAlign = 'right';
    ctx.fillText(eqKmL > 0 ? eqKmL.toFixed(1) : '—', xKmL, y + 2);
    ctx.font = '8px system-ui, sans-serif'; ctx.fillStyle = '#64748b';
    ctx.fillText('km/L eq', xKmL, y + 19);
    y += ROW_H;
  }
}

// ── Snapshot 9:16 da viagem (mapa OSM + faixas de eficiência + métricas) ──────
async function shareTripCard(tripId) {
  const trip = (cachedAutoTrips || []).find(t => t.tripId === tripId);
  if (!trip) return;

  const btn = [...document.querySelectorAll('.charge-badge')]
    .find(b => b.onclick?.toString().includes(tripId) && b.textContent.includes('Snapshot'));
  if (btn) { btn.textContent = '⏳'; btn.disabled = true; }

  try {
    const samples = await apiFetch(`/api/telemetry/${tripId}`)
      .then(r => r.json()).then(d => d.samples || []).catch(() => []);
    const gps   = samples.filter(s => s.lat !== 0 && s.lng !== 0);
    const title = trip.name || getAutoName(trip) || '';

    // ── Dimensões ─────────────────────────────────────────────────────────
    const W    = 450, H = 800, sc = 2, PAD = 20, CW = W - PAD * 2;
    const H_GRAD    = 4;
    const H_HEADER  = 36;
    const H_TITLE   = title ? 26 : 0;
    const H_DIV     = 1;
    const VPAD      = 10;          // padding each side of a divider
    const H_METRICS = 68;           // 2 linhas × 30px + 8px margem
    const H_BANDS   = 18 + 3 * 36; // section label + 3 band rows
    const H_FOOTER  = 26;
    // overhead (everything except map)
    const H_OVH = H_GRAD + H_HEADER + H_TITLE
      + 3 * (VPAD + H_DIV + VPAD)
      + H_METRICS + H_BANDS + H_FOOTER;
    const H_MAP = H - H_OVH;

    const canvas = document.createElement('canvas');
    canvas.width  = W * sc;
    canvas.height = H * sc;
    const ctx = canvas.getContext('2d');
    ctx.scale(sc, sc);
    ctx.textBaseline = 'top';

    // ── Fundo ────────────────────────────────────────────────────────────────
    ctx.fillStyle = '#0B0F1A';
    ctx.fillRect(0, 0, W, H);

    // Barra gradiente
    const grd = ctx.createLinearGradient(0, 0, W, 0);
    grd.addColorStop(0, '#3b82f6'); grd.addColorStop(1, '#10b981');
    ctx.fillStyle = grd; ctx.fillRect(0, 0, W, H_GRAD);

    // ── Cabeçalho ────────────────────────────────────────────────────────────
    let y = H_GRAD;
    ctx.font = 'bold 14px system-ui, sans-serif';
    ctx.fillStyle = '#3b82f6'; ctx.textAlign = 'left';
    ctx.fillText('⚡ EcoTrip', PAD, y + 10);

    const dur = fmtDur(Math.round((trip.endMs - trip.startMs) / 1000));
    ctx.font = '10px system-ui, sans-serif'; ctx.fillStyle = '#475569'; ctx.textAlign = 'right';
    ctx.fillText(fmtDate(trip.startMs) + '  ·  ' + dur, W - PAD, y + 12);
    y += H_HEADER;

    if (title) {
      ctx.font = 'bold 16px system-ui, sans-serif';
      ctx.fillStyle = '#e2e8f0'; ctx.textAlign = 'left';
      ctx.fillText(title, PAD, y + 4);
      y += H_TITLE;
    }

    // ── Divisor → mapa ───────────────────────────────────────────────────────
    ctx.fillStyle = '#1e293b'; ctx.fillRect(PAD, y + VPAD, CW, H_DIV);
    y += VPAD + H_DIV + VPAD;

    // Fundo claro enquanto tiles carregam (tom padrão do OSM)
    ctx.fillStyle = '#e8e4dc'; ctx.fillRect(PAD, y, CW, H_MAP);
    await _drawOSMMap(ctx, gps, PAD, y, CW, H_MAP);
    y += H_MAP;

    // ── Divisor → métricas ───────────────────────────────────────────────────
    ctx.fillStyle = '#1e293b'; ctx.fillRect(PAD, y + VPAD, CW, H_DIV);
    y += VPAD + H_DIV + VPAD;

    const { gas: priceGas, kwh: priceKwh } = getPrices();
    const _dist  = trip.distKm  || 0;
    const _net   = trip.netKwh  || 0;
    const _fuel  = trip.fuelL   || 0;
    const kwh100 = _dist > 0.1 && _net > 0 ? (_net / _dist * 100).toFixed(1) : '—';
    const eqDen  = _net / 8.9 + _fuel;
    const eqKmL  = _dist > 0.1 && eqDen > 0.001 ? f1(_dist / eqDen) : '—';
    const cost   = _fuel * priceGas + _net * priceKwh;
    const cPkm   = cost > 0.01 && _dist > 0.1 ? f3(cost / _dist) : '—';

    // Linha 1: Km · SOC · Energia · Combustível
    const row1 = [
      { v: f1(_dist),                                                                   lbl: 'km',          col: '#60a5fa' },
      { v: trip.startSocPct > 0 ? `${Math.round(trip.startSocPct)}→${Math.round(trip.endSocPct)}%` : '—',
                                                                                        lbl: 'SOC',         col: '#2dd4bf' },
      { v: _net > 0    ? f2(_net)  + ' kWh' : '—',                                    lbl: 'energia líq.', col: '#4ade80' },
      { v: _fuel > 0.01 ? f2(_fuel) + ' L'  : '—',                                    lbl: 'combustível', col: '#fb923c' },
    ];
    // Linha 2: km/L eq · kWh/100km · Custo total · R$/km
    const row2 = [
      { v: eqKmL,                             lbl: 'km/L eq',    col: '#22d3ee' },
      { v: kwh100,                             lbl: 'kWh/100km', col: '#4ade80' },
      { v: cost > 0.01 ? 'R$' + f2(cost) : '—', lbl: 'custo total', col: '#fbbf24' },
      { v: cPkm,                               lbl: 'R$/km',     col: '#fbbf24' },
    ];
    const drawMetricRow = (row, ry) => {
      const cw = CW / row.length;
      row.forEach((m, i) => {
        const mx = PAD + i * cw;
        ctx.font = 'bold 15px system-ui, sans-serif'; ctx.fillStyle = m.col; ctx.textAlign = 'left';
        ctx.fillText(m.v, mx, ry);
        ctx.font = '9px system-ui, sans-serif'; ctx.fillStyle = '#475569';
        ctx.fillText(m.lbl, mx, ry + 17);
      });
    };
    drawMetricRow(row1, y);
    drawMetricRow(row2, y + 30);
    y += H_METRICS;

    // ── Divisor → faixas ─────────────────────────────────────────────────────
    ctx.fillStyle = '#1e293b'; ctx.fillRect(PAD, y + VPAD, CW, H_DIV);
    y += VPAD + H_DIV + VPAD;

    _drawBands(ctx, samples, PAD, y, CW);
    y += H_BANDS;

    // ── Rodapé ───────────────────────────────────────────────────────────────
    ctx.font = '9px system-ui, sans-serif'; ctx.fillStyle = '#334155'; ctx.textAlign = 'center';
    ctx.fillText('Haval EcoTrip Impulse', W / 2, y + 8);

    // ── Compartilhar / download ───────────────────────────────────────────────
    await new Promise(resolve => {
      canvas.toBlob(async blob => {
        const name = `ecotrip-snapshot-${trip.tripId}.png`;
        const file = new File([blob], name, { type: 'image/png' });
        try {
          if (navigator.share && navigator.canShare?.({ files: [file] })) {
            await navigator.share({ files: [file], title: title || 'EcoTrip Snapshot' });
          } else {
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url; a.download = name;
            document.body.appendChild(a); a.click();
            setTimeout(() => { URL.revokeObjectURL(url); a.remove(); }, 1500);
          }
        } catch (_) {}
        resolve();
      }, 'image/png');
    });
  } finally {
    if (btn) { btn.textContent = '📸 Snapshot'; btn.disabled = false; }
  }
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

  // Polyline colorida por velocidade (verde < 40 · laranja < 80 · vermelho < 120 · verm. escuro ≥ 120)
  const spdColor = spd => spd < 40 ? '#22c55e' : spd < 80 ? '#f97316' : spd < 120 ? '#ef4444' : '#991b1b';
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
  if (chartPwr)  chartPwr.destroy();
  if (chartSoc)  chartSoc.destroy();

  chartSpd = mkChart('chart-spd', samples.map(s => s.spd),        '#4DBBFF', 'km/h');
  chartEv  = mkChart('chart-ev',  samples.map(s => s.evKw),       '#39FF88', 'kW');
  chartRpm = mkChart('chart-rpm', samples.map(s => s.rpm),        '#FF5F1F', 'RPM');
  chartPwr = mkChart('chart-pwr', samples.map(s => s.pwr ?? 0),   '#a78bfa', '%');

  // SOC% — só mostra o gráfico se a viagem tiver dados de SOC
  const socData = samples.map(s => s.soc ?? 0);
  const hasSoc  = socData.some(v => v > 0);
  const socLbl  = document.getElementById('chart-soc-label');
  if (socLbl)  socLbl.style.display  = hasSoc ? '' : 'none';
  const socWrap = document.querySelector('#chart-soc')?.parentElement;
  if (socWrap) socWrap.style.display = hasSoc ? '' : 'none';
  chartSoc = hasSoc ? mkChart('chart-soc', socData, '#c084fc', '%') : null;
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
  const pwrVal = s.pwr ?? 0;
  const pwrEl  = document.getElementById('snap-pwr');
  if (pwrEl) {
    pwrEl.textContent = (pwrVal >= 0 ? '+' : '') + pwrVal + '%';
    pwrEl.className   = 'snap-val ' + (pwrVal < -5 ? 'green' : pwrVal > 5 ? 'orange' : 'muted');
  }
  const socEl = document.getElementById('snap-soc');
  if (socEl) {
    const socVal = s.soc ?? 0;
    socEl.textContent = socVal > 0 ? socVal + '%' : '--';
    socEl.className   = 'snap-val ' + (socVal > 60 ? 'green' : socVal > 30 ? 'yellow' : socVal > 0 ? 'red' : 'muted');
  }
  const mm = Math.floor(s.t / 60), ss = s.t % 60;
  document.getElementById('snap-time').textContent = `${String(mm).padStart(2,'0')}'${String(ss).padStart(2,'0')}"`;

  // Marcador no mapa
  if (playbackMarker && (s.lat !== 0 || s.lng !== 0)) {
    playbackMarker.setLatLng([s.lat, s.lng]);
  }

  // Linha vertical nos gráficos via updateChart
  [chartSpd, chartEv, chartRpm, chartPwr].forEach(ch => {
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

// iOS PWA: reconecta imediatamente ao trazer o app pro foreground
document.addEventListener('visibilitychange', () => {
  if (!document.hidden && (!ws || ws.readyState !== WebSocket.OPEN)) {
    if (wsReconnectTimeout) { clearTimeout(wsReconnectTimeout); wsReconnectTimeout = null; }
    wsRetryDelay = 1000;
    connect();
  }
});

// Carrega localização do carro no mapa do dashboard (requer Leaflet carregado)
window.addEventListener('load', () => { setTimeout(initDashMap, 500); });

// ── Preços (gasolina + energia) — vêm do app Android via MQTT ────────────────

// Preços globais "ao vivo" (médio atual do tanque/bateria). Mantido pra
// compatibilidade e seed dos cálculos quando timestamp não é passado.
function getPrices() {
  return {
    gas: state.price_gas_per_l || 0,
    kwh: state.price_kwh       || 0,
  };
}

// ── Timeline de preços — recalcula custo retroativo de viagens ────────────
// Sempre que um refuel/charge é adicionado/editado/apagado, a média ponderada
// muda. Pra que viagens passadas usem o preço que ESTAVA valendo na época,
// construímos uma linha do tempo com {ts, gas_avg, kwh_avg}. Cada viagem
// procura o preço vigente no seu startMs.
const SEED_GAS_PRICE_PER_L_PWA = 6.50;
const SEED_KWH_PRICE_PWA       = 0.55;
const BATTERY_CAPACITY_KWH_PWA = 34;

let _priceTimelinesCache = null;
let _priceTimelinesKey   = null;  // hash dos inputs pra invalidar quando mudar

function _buildPriceTimelines() {
  // Cache key — versão monotônica das caches (bumped por _bumpCachesVersion).
  // Antes era JSON.stringify de todos os refuels+charges a cada chamada — em 5k trips
  // × 6k itens isso era dezenas de MB de string alocados por render.
  const key = _cachesVersion;
  if (_priceTimelinesCache && _priceTimelinesKey === key) return _priceTimelinesCache;

  // Gas timeline
  const gas = [{ ts: 0, price: SEED_GAS_PRICE_PER_L_PWA }];
  let gAvg = SEED_GAS_PRICE_PER_L_PWA, gLastAfter = 0;
  const refuelsOrd = [...(cachedRefuels || [])].sort((a, b) => (a.timestamp_ms || 0) - (b.timestamp_ms || 0));
  for (const r of refuelsOrd) {
    if (!(+r.price_per_liter > 0)) { gLastAfter = +r.fuel_l_after || gLastAfter; continue; }
    const before = +r.fuel_l_before || 0;
    const after  = +r.fuel_l_after  || (before + (+r.liters_added || 0));
    const added  = +r.liters_added  || Math.max(0, after - before);
    const oldL   = Math.max(0, Math.min(before, gLastAfter > 0 ? gLastAfter : before));
    const total  = oldL + added;
    if (total > 0.1) gAvg = (oldL * gAvg + added * +r.price_per_liter) / total;
    gLastAfter = after;
    gas.push({ ts: r.timestamp_ms || 0, price: gAvg });
  }

  // kWh timeline (similar; só sessões com cost override mudam o avg)
  const kwh = [{ ts: 0, price: SEED_KWH_PRICE_PWA }];
  let kAvg = SEED_KWH_PRICE_PWA;
  const chargesOrd = [...(cachedCharges || [])].sort((a, b) => (a.timestamp_ms || 0) - (b.timestamp_ms || 0));
  for (const c of chargesOrd) {
    const energy = +c.energy_kwh || 0;
    if (energy < 0.05) continue;
    const ovr = c.cost_override;
    const pricePerKwh = ovr?.free === true ? 0
                       : ovr && +ovr.perKwh > 0 ? +ovr.perKwh
                       : ovr && +ovr.total  > 0 ? (+ovr.total / energy)
                       : SEED_KWH_PRICE_PWA;
    const socStart  = +c.soc_start || 0;
    const kWhBefore = socStart * BATTERY_CAPACITY_KWH_PWA / 100;
    const kWhAfter  = kWhBefore + energy;
    kAvg = (kWhBefore * kAvg + energy * pricePerKwh) / kWhAfter;
    kwh.push({ ts: c.timestamp_ms || 0, price: kAvg });
  }

  _priceTimelinesCache = { gas, kwh };
  _priceTimelinesKey   = key;
  return _priceTimelinesCache;
}

function _priceAt(timeline, ms) {
  // Busca binária — timeline é construída em ordem cronológica.
  // Procura o último ponto cujo ts <= ms (upper bound − 1).
  let lo = 0, hi = timeline.length;
  while (lo < hi) {
    const mid = (lo + hi) >>> 1;
    if (timeline[mid].ts <= ms) lo = mid + 1;
    else hi = mid;
  }
  return timeline[lo > 0 ? lo - 1 : 0].price;
}

// Retorna {gas, kwh} no preço que estava vigente em `ms`. Fallback pra
// getPrices() (médio atual) quando ms não fornecido ou inválido.
function pricesAt(ms) {
  if (!ms) return getPrices();
  const t = _buildPriceTimelines();
  return { gas: _priceAt(t.gas, ms), kwh: _priceAt(t.kwh, ms) };
}

// ── Custo por trip — override local (localStorage) ───────────────────────────

function _tripCostOverride(tripId) {
  try { return JSON.parse(localStorage.getItem('eco_cost_' + tripId) || 'null'); } catch { return null; }
}

window.toggleCostEdit = function(tripId) {
  const el = document.getElementById('cost-edit-' + tripId);
  if (el) el.style.display = el.style.display === 'none' ? '' : 'none';
};

window.applyTripCost = function(tripId, fuelL, netKwh) {
  const el = document.getElementById('cost-edit-' + tripId);
  if (!el) return;
  const gas  = parseFloat(el.querySelector('.cost-gas-input')?.value  || '0');
  const kwh  = parseFloat(el.querySelector('.cost-kwh-input')?.value  || '0');
  if (gas < 0 || kwh < 0 || (gas === 0 && kwh === 0)) return;
  const cost = (fuelL || 0) * gas + (netKwh || 0) * kwh;
  localStorage.setItem('eco_cost_' + tripId, JSON.stringify({ cost, gas, kwh }));
  const badge = document.getElementById('cost-badge-' + tripId);
  if (badge) {
    badge.textContent = 'R$ ' + f2(cost);
    badge.style.display = '';
    badge.style.borderBottom = '1px dashed rgba(251,191,36,.5)';
  }
  el.style.display = 'none';
};

// ── Custo de recargas — override local ───────────────────────────────────────

function _chargeCostOverride(ts) {
  // Prioridade: cost_override no objeto de recarga (vem do servidor) → localStorage (fallback).
  // Aceita também recarga gratuita (free===true), que tem total=0 explicitamente.
  const fromCache = _getChargesByTs().get(ts);
  const ov = fromCache?.cost_override;
  if (ov?.free === true || ov?.total > 0) return ov;
  try { return JSON.parse(localStorage.getItem('eco_chg_cost_' + ts) || 'null'); } catch { return null; }
}

// ── Perda de carga — kWh do carregador externo ────────────────────────────────
// Fonte de verdade: campo charger_kwh no objeto de recarga (servidor + IDB).
// localStorage é apenas cache imediato; no próximo sync o servidor prevalece.
function _chargerKwhMap() {
  try { return JSON.parse(localStorage.getItem('ecotrip-charger-kwh') || '{}'); } catch { return {}; }
}
function _getChargerKwh(ts) {
  // Prioridade: objeto em cachedCharges (vem do servidor) → localStorage (fallback offline)
  const fromCache = _getChargesByTs().get(ts);
  if (fromCache?.charger_kwh > 0) return fromCache.charger_kwh;
  return _chargerKwhMap()[ts] || 0;
}
/**
 * Resolve charger_kwh para um objeto de recarga:
 *   1. c.charger_kwh    — fonte do servidor (sincronizado via IndexedDB)
 *   2. chargerMap[ts]   — localStorage (digitado neste dispositivo, pré-sync)
 * Usar em loops que já têm o chargerMap em memória para evitar N leituras de localStorage.
 */
function _resolveChargerKwh(c, chargerMap) {
  if ((c.charger_kwh || 0) > 0) return c.charger_kwh;
  return (chargerMap[c.timestamp_ms] || 0);
}
function _setChargerKwh(ts, val) {
  // 1. localStorage — disponível imediatamente (mesmo offline)
  const m = _chargerKwhMap();
  if (val > 0) m[ts] = val; else delete m[ts];
  localStorage.setItem('ecotrip-charger-kwh', JSON.stringify(m));
  // 2. Servidor — persiste entre reinstalls do PWA
  apiFetch(`/api/charges/${ts}/charger_kwh`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ charger_kwh: val > 0 ? val : null }),
  }).then(r => r.json()).then(updated => {
    // Atualiza cache em memória e IDB para consistência imediata
    if (cachedCharges && updated?.timestamp_ms) {
      const idx = cachedCharges.findIndex(c => c.timestamp_ms === ts);
      if (idx >= 0) { cachedCharges[idx] = updated; _bumpCachesVersion(); }
      _idbPutMany('charges', [updated]).catch(() => {});
    }
  }).catch(() => {/* offline — localStorage como fallback */});
}

window.toggleChargeEdit = function(ts) {
  const el = document.getElementById('charge-edit-' + ts);
  if (el) el.style.display = el.style.display === 'none' ? '' : 'none';
};

window.toggleChargerEdit = function(ts) {
  const el = document.getElementById('charger-edit-' + ts);
  if (el) el.style.display = el.style.display === 'none' ? '' : 'none';
};

window.applyChargerKwh = function(ts) {
  const el = document.getElementById('charger-edit-' + ts);
  if (!el) return;
  const val = parseFloat(el.querySelector('.charge-total-input')?.value || '0') || 0;
  _setChargerKwh(ts, val);
  el.style.display = 'none';
  renderCharges();
};

window.markChargeFree = function(ts) {
  const el = document.getElementById('charge-edit-' + ts);
  if (el) el.style.display = 'none';
  // Limpa override local (vai ser sobrescrito pelo do servidor) e persiste flag no bridge.
  localStorage.removeItem('eco_chg_cost_' + ts);
  apiFetch(`/api/charges/${ts}/cost`, {
    method:  'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body:    JSON.stringify({ free: true }),
  }).then(r => r.json()).then(updated => {
    if (cachedCharges && updated?.timestamp_ms) {
      const idx = cachedCharges.findIndex(c => c.timestamp_ms === ts);
      if (idx >= 0) { cachedCharges[idx] = updated; _bumpCachesVersion(); }
      _idbPutMany('charges', [updated]).catch(() => {});
    }
    renderCharges();
  }).catch(() => {/* offline — fica pendente até voltar */});
};

window.applyChargeCost = function(ts, energyKwh) {
  const el = document.getElementById('charge-edit-' + ts);
  if (!el) return;
  const total = parseFloat(el.querySelector('.charge-total-input')?.value || '0');
  const totalBadge = document.getElementById('chg-cost-' + ts);
  const unitBadge  = document.getElementById('chg-unit-' + ts);
  const perKwh = total > 0 && energyKwh > 0 ? total / energyKwh : 0;

  if (total <= 0) {
    // Limpa override → volta ao preço padrão das configurações
    localStorage.removeItem('eco_chg_cost_' + ts);
    const defKwh   = state.price_kwh || 0;
    const defTotal = defKwh > 0 ? defKwh * energyKwh : 0;
    if (defTotal > 0) {
      if (totalBadge) { totalBadge.textContent = 'R$ ' + f2(defTotal); totalBadge.style.display = ''; totalBadge.style.borderBottom = 'none'; }
      if (unitBadge)  { unitBadge.textContent  = f3(defKwh) + ' R$/kWh'; unitBadge.style.display = ''; }
    } else {
      if (totalBadge) totalBadge.style.display = 'none';
      if (unitBadge)  unitBadge.style.display  = 'none';
    }
  } else {
    localStorage.setItem('eco_chg_cost_' + ts, JSON.stringify({ total, perKwh }));
    if (totalBadge) { totalBadge.textContent = 'R$ ' + f2(total); totalBadge.style.display = ''; totalBadge.style.borderBottom = '1px dashed rgba(251,191,36,.5)'; }
    if (unitBadge)  { unitBadge.textContent  = f3(perKwh) + ' R$/kWh'; unitBadge.style.display = ''; }
  }
  el.style.display = 'none';

  // Persiste no servidor — sobrevive a reinstall do PWA
  apiFetch(`/api/charges/${ts}/cost`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ total: total > 0 ? total : 0, per_kwh: perKwh }),
  }).then(r => r.json()).then(updated => {
    if (cachedCharges && updated?.timestamp_ms) {
      const idx = cachedCharges.findIndex(c => c.timestamp_ms === ts);
      if (idx >= 0) { cachedCharges[idx] = updated; _bumpCachesVersion(); }
      _idbPutMany('charges', [updated]).catch(() => {});
    }
  }).catch(() => {/* offline — localStorage como fallback */});
};

// ── Helpers de duração HH:MM (usados pela edição de metadados de recarga) ────
function _fmtDurHHMM(sec) {
  const s = Math.max(0, Math.round(+sec || 0));
  const h = Math.floor(s / 3600);
  const m = Math.round((s % 3600) / 60);
  return `${h}:${String(m).padStart(2, '0')}`;
}
function _parseDurHHMM(str) {
  if (!str) return null;
  const s = String(str).trim();
  // Aceita: "HH:MM", "H:MM", "HH:MM:SS"
  const mm = s.match(/^(\d+):(\d{1,2})(?::(\d{1,2}))?$/);
  if (!mm) return null;
  const h = parseInt(mm[1], 10);
  const m = parseInt(mm[2], 10);
  const sec = mm[3] ? parseInt(mm[3], 10) : 0;
  if (m >= 60 || sec >= 60) return null;
  return h * 3600 + m * 60 + sec;
}

window.toggleChargeMetaEdit = function(ts) {
  const el = document.getElementById('charge-meta-edit-' + ts);
  if (el) el.style.display = el.style.display === 'none' ? 'flex' : 'none';
};

window.applyChargeMeta = async function(ts) {
  const el = document.getElementById('charge-meta-edit-' + ts);
  if (!el) return;
  const socStart = parseFloat(el.querySelector('.charge-meta-soc-start')?.value);
  const socEnd   = parseFloat(el.querySelector('.charge-meta-soc-end')?.value);
  const kwh      = parseFloat(el.querySelector('.charge-meta-kwh')?.value);
  const durStr   = el.querySelector('.charge-meta-dur')?.value || '';
  const durSec   = _parseDurHHMM(durStr);

  if (durStr && durSec === null) {
    showToast('✗ Duração inválida (use HH:MM)');
    return;
  }
  if (Number.isFinite(socStart) && Number.isFinite(socEnd) && socEnd < socStart) {
    showToast('✗ SOC fim não pode ser menor que SOC início');
    return;
  }

  // Envia só os campos preenchidos com valor finito (vazio mantém o que está)
  const body = {};
  if (Number.isFinite(socStart)) body.soc_start    = socStart;
  if (Number.isFinite(socEnd))   body.soc_end      = socEnd;
  if (Number.isFinite(kwh))      body.energy_kwh   = kwh;
  if (durSec !== null)           body.duration_sec = durSec;

  try {
    const r = await apiFetch(`/api/charges/${ts}/edit`, {
      method:  'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(body),
    });
    if (!r.ok) { showToast('✗ Erro ao salvar edição'); return; }
    const updated = await r.json();
    if (cachedCharges && updated?.timestamp_ms) {
      const idx = cachedCharges.findIndex(c => c.timestamp_ms === ts);
      if (idx >= 0) { cachedCharges[idx] = updated; _bumpCachesVersion(); }
      _idbPutMany('charges', [updated]).catch(() => {});
    }
    el.style.display = 'none';
    renderCharges();
    showToast('✓ Recarga editada');
  } catch (e) {
    if (e.message !== 'unauthorized') showToast('✗ Erro ao salvar edição');
  }
};

window.revertChargeMeta = async function(ts) {
  if (!confirm('Reverter todas as edições manuais desta recarga?\nVolta aos valores reportados pelo carro.')) return;
  try {
    const r = await apiFetch(`/api/charges/${ts}/edit`, {
      method:  'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify({ clear: true }),
    });
    if (!r.ok) { showToast('✗ Erro ao reverter'); return; }
    const updated = await r.json();
    if (cachedCharges && updated?.timestamp_ms) {
      const idx = cachedCharges.findIndex(c => c.timestamp_ms === ts);
      if (idx >= 0) { cachedCharges[idx] = updated; _bumpCachesVersion(); }
      _idbPutMany('charges', [updated]).catch(() => {});
    }
    renderCharges();
    showToast('✓ Edições revertidas');
  } catch (e) {
    if (e.message !== 'unauthorized') showToast('✗ Erro ao reverter');
  }
};

window.deleteCharge = async function(ts) {
  if (!confirm('Apagar esta recarga?\nEssa ação não pode ser desfeita.')) return;
  try {
    const r = await apiFetch(`/api/charges/${ts}`, { method: 'DELETE' });
    if (!r.ok) { showToast('✗ Erro ao apagar recarga'); return; }
    if (cachedCharges) { cachedCharges = cachedCharges.filter(c => (c.timestamp_ms || 0) !== ts); _bumpCachesVersion(); }
    _openIDB().then(db => {
      db.transaction('charges', 'readwrite').objectStore('charges').delete(ts);
    }).catch(() => {});
    localStorage.removeItem('eco_chg_cost_' + ts);
    document.getElementById('charge-card-' + ts)?.remove();
    showToast('✓ Recarga apagada');
  } catch (e) {
    if (e.message !== 'unauthorized') showToast('✗ Erro ao apagar recarga');
  }
};

// ── Admin / Configurações ─────────────────────────────────────────────────────

function adminSetStatus(msg, ok) {
  const el = document.getElementById('admin-status');
  el.textContent = msg;
  el.style.color = ok === true ? '#4ade80' : ok === false ? '#f87171' : '#94a3b8';
}
function _cacheSetStatus(msg, ok) {
  const el = document.getElementById('cache-status');
  if (!el) return;
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

// Sincroniza servidor: tudo que NÃO está em cache local é apagado +
// tombstoneado. Usado pra "limpar permanentemente" itens que voltavam por
// MQTT antes do tombstone system.
async function adminSyncWithLocal() {
  adminSetStatus('Carregando cache local…', null);
  // Carrega do IndexedDB e refuels do servidor — admin não passa pela
  // aba Auto/Posto, então cachedAutoTrips/cachedCharges podem estar null.
  if (cachedAutoTrips === null) {
    try { cachedAutoTrips = (await _idbGetAll('autotrips')).sort((a,b) => (b.startMs||0)-(a.startMs||0)); } catch (_) { cachedAutoTrips = []; }
  }
  if (cachedCharges === null) {
    try { cachedCharges = await _idbGetAll('charges'); } catch (_) { cachedCharges = []; }
    _bumpCachesVersion();
  }
  // Refuels não tem IDB, só /api/refuels
  if (cachedRefuels === null) await _loadRefuels();

  const localAt = (cachedAutoTrips || []).length;
  const localCh = (cachedCharges   || []).length;
  const localRf = (cachedRefuels   || []).length;

  if (localAt + localCh + localRf === 0) {
    adminSetStatus('✗ Cache local vazio. Abra as abas Auto e Posto antes de sincronizar.', false);
    return;
  }

  if (!confirm(
    `Sincronizar servidor com este celular?\n\n` +
    `Atualmente no app:\n  • ${localAt} viagens\n  • ${localCh} recargas\n  • ${localRf} abastecimentos\n\n` +
    `Tudo que estiver no servidor e NÃO neste celular será apagado permanentemente ` +
    `(marcado como deletado pra não voltar via MQTT).\n\n` +
    `Essa ação é IRREVERSÍVEL — quer continuar?`
  )) { adminSetStatus('', null); return; }

  const keep_autotrips = (cachedAutoTrips || []).map(t => String(t.tripId || t.startMs));
  const keep_charges   = (cachedCharges   || []).map(c => +c.timestamp_ms || 0).filter(x => x > 0);
  const keep_refuels   = (cachedRefuels   || []).map(r => String(r.id || '')).filter(x => x);

  adminSetStatus('Sincronizando…', null);
  try {
    const r = await apiFetch('/api/admin/sync', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ keep_autotrips, keep_charges, keep_refuels }),
    });
    const d = await r.json();
    if (!r.ok || !d.ok) throw new Error(d.error || 'erro');
    adminSetStatus(
      `✓ Sincronizado: removidas ${d.removed_autotrips} viagens, ` +
      `${d.removed_charges} recargas, ${d.removed_refuels} abastecimentos do servidor.`,
      true
    );
  } catch (e) {
    adminSetStatus('✗ ' + e.message, false);
  }
}
window.adminSyncWithLocal = adminSyncWithLocal;

async function adminClearHistory() {
  const pw = prompt('Digite a senha para confirmar a exclusão do histórico:');
  if (pw === null) return;                          // cancelou
  const hash = await sha256hex(pw);
  if (hash !== bridgeToken) {
    adminSetStatus('✗ Senha incorreta — histórico não apagado.', false);
    return;
  }
  if (!confirm('Senha confirmada.\n\nApagar TODO o histórico do servidor?\n(trips manuais, auto-trips e recargas)\n\nEssa ação não pode ser desfeita.')) return;
  adminAction('/api/admin/clear-history', 'Apagando histórico');
}

async function adminClearSnapshots() {
  if (!confirm('Zerar o histórico de comparativos?\n\nIsso apaga apenas os snapshots usados para os gráficos semanal e mensal.\nOs dados lifetime reais (km, kWh, etc.) NÃO são afetados.\n\nNovos snapshots chegarão a cada 5 min enquanto o carro enviar dados.')) return;
  adminAction('/api/lifetime/snapshots/clear', 'Limpando snapshots');
}

async function adminRedownloadCache() {
  if (!confirm('Apagar cache local e baixar todos os dados do servidor?\nIsso pode demorar alguns segundos.')) return;
  _cacheSetStatus('⏳ Baixando...', null);
  cachedAutoTrips = null; cachedCharges = null; _bumpCachesVersion();
  await _idbClearAll();
  const t = await syncAllCache({ silent: false });
  renderAutoTrips(); renderCharges();
  _cacheSetStatus('✓ ' + t.auto + ' viagens · ' + t.charges + ' recargas baixados', true);
}

// ── Exportar dados locais (IndexedDB → JSON download) ─────────────────────────
async function adminExportData() {
  _cacheSetStatus('⏳ Exportando…', null);
  try {
    const [trips, autotrips, charges] = await Promise.all([
      _idbGetAll('trips'),
      _idbGetAll('autotrips'),
      _idbGetAll('charges'),
    ]);
    const data = {
      exportedAt: new Date().toISOString(),
      version:    1,
      trips,
      autotrips,
      charges,
    };
    const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
    const url  = URL.createObjectURL(blob);
    const a    = document.createElement('a');
    a.href     = url;
    a.download = 'ecotrip-backup-' + new Date().toISOString().slice(0, 10) + '.json';
    document.body.appendChild(a);
    a.click();
    setTimeout(() => { URL.revokeObjectURL(url); a.remove(); }, 1500);
    _cacheSetStatus('✓ Exportados: ' + trips.length + ' trips · ' + autotrips.length + ' auto · ' + charges.length + ' recargas', true);
  } catch (e) {
    _cacheSetStatus('❌ Erro ao exportar: ' + e.message, false);
  }
}

// ── Exportar CSV de auto-trips ────────────────────────────────────────────────
async function adminExportCsv() {
  _cacheSetStatus('⏳ Exportando CSV…', null);
  try {
    const trips = await _idbGetAll('autotrips');
    if (!trips.length) { _cacheSetStatus('ℹ️ Nenhum auto-trip para exportar', null); return; }

    const { gas: priceGas, kwh: priceKwh } = getPrices();
    const esc = v => `"${String(v ?? '').replace(/"/g, '""')}"`;
    const header = ['Data', 'Hora início', 'Hora fim', 'Duração (min)', 'km',
      'km/h méd.', 'kWh liq.', 'kWh/100km', 'Combust. (L)', 'km/L',
      'SOC início (%)', 'SOC fim (%)', 'Custo (R$)', 'Origem', 'Destino', 'Nome'].join(',');
    const rows = trips
      .sort((a, b) => (b.startMs || 0) - (a.startMs || 0))
      .map(t => {
        const dtSec = ((t.endMs || t.startMs) - t.startMs) / 1000;
        const avgSpd = t.timeSec > 0 ? (t.distKm / (t.timeSec / 3600)).toFixed(1) : '';
        const kwh100 = t.distKm > 0 && (t.netKwh || 0) > 0
          ? (t.netKwh / t.distKm * 100).toFixed(2) : '';
        const kmL   = (t.fuelL || 0) > 0.01 ? (t.distKm / t.fuelL).toFixed(2) : '';
        const cost  = ((t.fuelL || 0) * priceGas + (t.netKwh || 0) * priceKwh).toFixed(2);
        const origin = (geoCache[t.tripId] || '').split(',')[0].trim();
        const dest   = (geoCache[t.tripId + ':end'] || '').split(',')[0].trim();
        const d = new Date(t.startMs);
        return [
          esc(d.toLocaleDateString('pt-BR')),
          esc(d.toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })),
          esc(new Date(t.endMs || t.startMs).toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' })),
          Math.round(dtSec / 60),
          (t.distKm || 0).toFixed(2), avgSpd,
          (t.netKwh || 0).toFixed(3), kwh100,
          (t.fuelL || 0).toFixed(3), kmL,
          (t.startSocPct || 0).toFixed(1), (t.endSocPct || 0).toFixed(1),
          cost, esc(origin), esc(dest), esc(t.name || ''),
        ].join(',');
      });

    const bom  = '﻿';  // BOM para Excel/Numbers reconhecer UTF-8
    const blob = new Blob([bom + [header, ...rows].join('\r\n')], { type: 'text/csv;charset=utf-8' });
    const url  = URL.createObjectURL(blob);
    const a    = document.createElement('a');
    a.href     = url;
    a.download = 'ecotrip-viagens-' + new Date().toISOString().slice(0, 10) + '.csv';
    document.body.appendChild(a); a.click();
    setTimeout(() => { URL.revokeObjectURL(url); a.remove(); }, 1500);
    _cacheSetStatus('✓ CSV exportado: ' + trips.length + ' viagens', true);
  } catch (e) {
    _cacheSetStatus('❌ Erro: ' + e.message, false);
  }
}

// ── Backup & Restore completo (servidor) ─────────────────────────────────────
function _backupSetStatus(msg, ok) {
  const el = document.getElementById('backup-status');
  if (!el) return;
  el.style.display = 'block';
  el.style.color = ok === true ? '#4ade80' : ok === false ? '#f87171' : '#94a3b8';
  el.textContent = msg;
}

async function adminBackupServer() {
  _backupSetStatus('⏳ Gerando backup…', null);
  try {
    const r = await apiFetch('/api/backup');
    if (!r.ok) {
      const err = await r.json().catch(() => ({}));
      _backupSetStatus('✗ ' + (err.error || `Erro ${r.status}`), false);
      return;
    }
    const blob = await r.blob();
    const date = new Date().toISOString().slice(0, 10);
    const url  = URL.createObjectURL(blob);
    const a    = document.createElement('a');
    a.href     = url;
    a.download = `ecotrip-backup-${date}.json`;
    document.body.appendChild(a); a.click();
    setTimeout(() => { URL.revokeObjectURL(url); a.remove(); }, 1500);
    // Registra timestamp (evita aviso de backup automático pendente)
    localStorage.setItem('ecotrip_last_backup_ms', String(Date.now()));
    document.getElementById('auto-backup-banner')?.style && (document.getElementById('auto-backup-banner').style.display = 'none');
    _backupSetStatus('✓ Backup baixado com sucesso', true);
  } catch (e) {
    _backupSetStatus('✗ Sem resposta do servidor', false);
  }
}

async function adminRestoreServer(input) {
  const file = input.files?.[0];
  input.value = '';       // permite re-selecionar o mesmo arquivo
  if (!file) return;

  _backupSetStatus(`⏳ Lendo ${file.name}…`, null);
  let backup;
  try {
    backup = JSON.parse(await file.text());
  } catch (_) {
    _backupSetStatus('✗ Arquivo inválido — não é um JSON válido', false);
    return;
  }

  if (backup.version !== 2) {
    _backupSetStatus('✗ Versão incompatível. Use um backup gerado pelo botão "Backup completo (servidor)".', false);
    return;
  }

  const at = backup.autotrips?.length ?? 0;
  const tr = backup.trips?.length ?? 0;
  const ch = backup.charges?.length ?? 0;

  if (!confirm(
    `Restaurar backup de ${backup.exportedAt?.slice(0, 10) || '?'}?\n\n` +
    `Isso irá substituir TODOS os dados atuais do servidor:\n` +
    `• ${tr} trips manuais\n• ${at} auto-trips\n• ${ch} recargas\n\n` +
    `Esta ação não pode ser desfeita.`
  )) return;

  _backupSetStatus('⏳ Restaurando… não feche o app.', null);
  try {
    const r = await apiFetch('/api/restore', {
      method:  'POST',
      headers: { 'Content-Type': 'application/json' },
      body:    JSON.stringify(backup),
    });
    const data = await r.json();
    if (r.ok) {
      // Força re-sync do cache local para refletir os dados restaurados
      await _idbClearAll();
      cachedAutoTrips = null; cachedCharges = null; _bumpCachesVersion();
      await syncAllCache({ silent: true });
      _backupSetStatus(
        `✓ Restore concluído — ${data.autotrips} viagens · ${data.charges} recargas`,
        true
      );
    } else {
      _backupSetStatus('✗ ' + (data.error || `Erro ${r.status}`), false);
    }
  } catch (e) {
    _backupSetStatus('✗ Sem resposta do servidor — verifique a conexão', false);
  }
}

// ── Backup automático semanal ─────────────────────────────────────────────────
const BACKUP_INTERVAL_MS = 7 * 86_400_000;

function checkAutoBackup() {
  const lastMs = parseInt(localStorage.getItem('ecotrip_last_backup_ms') || '0', 10);
  if (Date.now() - lastMs < BACKUP_INTERVAL_MS) return;
  const banner = document.getElementById('auto-backup-banner');
  if (banner) banner.style.display = '';
}

async function doAutoBackup() {
  await adminExportData();
  localStorage.setItem('ecotrip_last_backup_ms', String(Date.now()));
  const banner = document.getElementById('auto-backup-banner');
  if (banner) banner.style.display = 'none';
}

// ── Stats Tab ─────────────────────────────────────────────────────────────────
async function loadStats() {
  const container = document.getElementById('panel-stats');
  if (!container) return;
  container.innerHTML = '<div class="empty" style="padding:24px">Carregando…</div>';

  // Garante que o cache local está populado
  if (!cachedAutoTrips) await syncAllCache({ silent: true });
  if (cachedRefuels === null) await _loadRefuels();
  const allTrips   = (cachedAutoTrips || []).filter(t => (t.distKm || 0) > 2);
  const allCharges = cachedCharges || [];
  const allRefuels = cachedRefuels || [];

  // Filtro global da aba — aplica em todos os cards (semanal e mensal são
  // intrinsecamente atrelados ao período da semana/mês e ficam só visíveis
  // quando filtro = "Tudo" ou "Mês").
  const [fStart, fEnd] = getFilterRange('stats');
  const isAll = filterState.stats.active === 'all';
  const inRange = (ms) => ms >= fStart && ms <= fEnd;
  const trips   = isAll ? allTrips   : allTrips.filter(t => inRange(t.startMs || 0));
  const charges = isAll ? allCharges : allCharges.filter(c => inRange(c.timestamp_ms || 0));
  const refuels = isAll ? allRefuels : allRefuels.filter(r => inRange(r.timestamp_ms || 0));

  let html = '<div style="padding-bottom:12px">';

  // ── Filtro de período (topo da aba) ───────────────────────────────────────
  const filterLabel = isAll ? 'Todo o histórico' :
    (filterState.stats.active === 'today'  ? 'Hoje' :
     filterState.stats.active === '7d'     ? 'Últimos 7 dias' :
     filterState.stats.active === '30d'    ? 'Últimos 30 dias' :
     filterState.stats.active === 'month'  ? 'Mês atual' : 'Período custom');
  html += `<div style="background:#0c1019;border:1px solid #0f1520;border-radius:12px;padding:10px 14px;margin-bottom:12px">
    <div style="font-size:10px;color:#475569;letter-spacing:.06em;text-transform:uppercase;margin-bottom:6px">Período · ${filterLabel}</div>
    ${filterChipsHTML('stats')}
    <div style="font-size:10px;color:#64748b;margin-top:4px">
      ${trips.length} viagem${trips.length !== 1 ? 's' : ''} · ${charges.length} recarga${charges.length !== 1 ? 's' : ''}
    </div>
  </div>`;

  // ── 0. Preços médios (atual + período) ───────────────────────────────────
  html += _statsPricesHTML(charges, refuels);

  // ── 1. Recordes pessoais ─────────────────────────────────────────────────
  html += _statsRecordsHTML(trips);

  // ── 2. Comparativo semanal (só faz sentido sem filtro ou Mês) ─────────────
  if (isAll || filterState.stats.active === 'month') {
    html += await _statsWeeklyHTML();
    html += await _statsMonthlyHTML();
  }

  // ── 3. Split elétrico / híbrido ──────────────────────────────────────────
  html += _statsElectricHTML(trips);

  // ── 4. Comparativo EV vs ICE (economia acumulada) ────────────────────────
  html += _statsEvVsIceHTML(trips);

  // ── 5. Saúde da bateria (SOH estimado) ───────────────────────────────────
  html += _statsBatterySohHTML(charges);

  // ── 6. Heatmap de uso (onde mais andou) ──────────────────────────────────
  html += _statsHeatmapHTML(trips);

  // ── 7. Locais de recarga — ranking por eficiência ────────────────────────
  html += _statsChargingLocationsHTML(charges);

  html += '</div>';
  container.innerHTML = html;
  // Inicializa heatmap após o DOM ser pintado
  setTimeout(_initStatsHeatmap, 100);
}

function _statsCard(title, body) {
  return `<div style="background:#0C1019;border:1px solid #0F1520;border-radius:12px;padding:14px 16px;margin-bottom:12px">
    <div style="font-size:13px;font-weight:700;color:#EEF4FF;margin-bottom:12px">${title}</div>
    ${body}
  </div>`;
}

function _statsRow(icon, label, value, sub) {
  return `<div style="display:flex;align-items:center;gap:10px;padding:6px 0;border-bottom:1px solid #0F1520">
    <span style="font-size:16px;width:22px;text-align:center;flex-shrink:0">${icon}</span>
    <div style="flex:1;min-width:0">
      <div style="font-size:11px;color:#64748b">${label}</div>
      ${sub ? `<div style="font-size:9px;color:#475569;margin-top:1px">${sub}</div>` : ''}
    </div>
    <div style="font-size:13px;font-weight:700;color:#f1f5f9;text-align:right;white-space:nowrap">${value}</div>
  </div>`;
}

// Preços médios — atual (mix atual do tanque/bateria, vem do state) e do período
// filtrado (ponderado pelos litros abastecidos e kWh recarregados no recorte).
function _statsPricesHTML(charges, refuels) {
  // ── Atual (mix ponderado de TODO histórico — refletido em state) ────────
  const curGas = state.price_gas_per_l || 0;
  const curKwh = state.price_kwh       || 0;

  // ── Período: média ponderada do que ENTROU (abasteceu / recarregou) ─────
  let gasSpend = 0, gasL = 0;
  for (const r of refuels) {
    const p = +r.price_per_liter || 0;
    const l = +r.liters_added    || 0;
    if (p > 0 && l > 0) { gasSpend += p * l; gasL += l; }
  }
  const periodGas = gasL > 0 ? gasSpend / gasL : 0;

  let kwhSpend = 0, kwhTotal = 0;
  for (const c of charges) {
    const e = +c.energy_kwh || 0;
    if (e < 0.05) continue;
    const ov = c.cost_override;
    let pricePerKwh;
    if (ov?.free === true)                           pricePerKwh = 0;
    else if (ov && +ov.perKwh > 0)                   pricePerKwh = +ov.perKwh;
    else if (ov && +ov.total > 0)                    pricePerKwh = +ov.total / e;
    else                                              pricePerKwh = SEED_KWH_PRICE_PWA;
    kwhSpend += pricePerKwh * e;
    kwhTotal += e;
  }
  const periodKwh = kwhTotal > 0 ? kwhSpend / kwhTotal : 0;

  // ── Render ──────────────────────────────────────────────────────────────
  const fmtGas = v => v > 0 ? 'R$ ' + v.toFixed(2)  + ' /L'   : '—';
  const fmtKwh = v => v > 0 ? 'R$ ' + v.toFixed(4)  + ' /kWh' : v === 0 ? 'R$ 0,0000 /kWh' : '—';

  const body =
    _statsRow('⛽', 'Gasolina · atual no tanque',
              fmtGas(curGas),
              'média ponderada de todo histórico — publicado no carro') +
    _statsRow('⛽', 'Gasolina · período',
              fmtGas(periodGas),
              `média ponderada de ${refuels.length} abastecimento${refuels.length !== 1 ? 's' : ''} no filtro`) +
    _statsRow('⚡', 'Energia · atual na bateria',
              fmtKwh(curKwh),
              'média ponderada de todo histórico — publicado no carro') +
    _statsRow('⚡', 'Energia · período',
              fmtKwh(periodKwh),
              `média ponderada de ${charges.length} recarga${charges.length !== 1 ? 's' : ''} no filtro`);

  return _statsCard('💰 Custo unitário', body);
}

function _statsRecordsHTML(trips) {
  if (!trips.length) return _statsCard('🏆 Recordes pessoais', '<div style="color:#475569;font-size:12px">Nenhuma viagem com mais de 2 km ainda.</div>');

  const KWH_PER_L = 8.9; // equivalência energética da gasolina (kWh/L)
  const { gas: _pg, kwh: _pk } = getPrices();

  // Mais eficiente elétrica: só viagens 100% elétricas (fuelL ≈ 0)
  const byEff = trips
    .filter(t => (t.fuelL || 0) < 0.05 && t.distKm > 0 && (t.netKwh || 0) > 0)
    .reduce((b, t) => {
      const v = t.netKwh / t.distKm * 100;
      return (!b || v < (b.netKwh / b.distKm * 100)) ? t : b;
    }, null);

  // Mais eficiente híbrida: viagens com combustível, consumo equivalente em kWh_eq/100km
  // equiv = (netKwh + fuelL × 8,9) / distKm × 100 — menor é melhor
  const byHybridEff = trips
    .filter(t => (t.fuelL || 0) >= 0.05 && t.distKm > 0 && (t.netKwh || 0) >= 0)
    .reduce((b, t) => {
      const v = ((t.netKwh || 0) + t.fuelL * KWH_PER_L) / t.distKm * 100;
      return (!b || v < (((b.netKwh || 0) + b.fuelL * KWH_PER_L) / b.distKm * 100)) ? t : b;
    }, null);

  const byDist = trips.reduce((b, t) => (!b || (t.distKm || 0) > (b.distKm || 0)) ? t : b, null);

  // Maior regeneração: só viagens 100% elétricas (fuelL ≈ 0) com > 5 km
  // Métrica: regenKwh / energyKwh (bruto) — melhor quem regenerou mais proporcionalmente
  const byRegen = trips
    .filter(t => (t.fuelL || 0) < 0.05 && (t.distKm || 0) > 5 && (t.energyKwh || 0) > 0)
    .reduce((b, t) => {
      const pct = (t.regenKwh || 0) / t.energyKwh;
      return (!b || pct > (b.regenKwh || 0) / b.energyKwh) ? t : b;
    }, null);

  const byFuel = trips.filter(t => (t.fuelL || 0) > 0.05 && (t.distKm || 0) > 30)
    .reduce((b, t) => (!b || t.distKm / t.fuelL > b.distKm / b.fuelL) ? t : b, null);

  const shortDate = ms => {
    if (!ms) return '';
    const d = new Date(ms);
    return d.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' });
  };
  // Nome do trip: renameTracking tem prioridade (igual ao renderAutoTrips)
  const tName = t => {
    const rn = renameTracking[String(t.tripId)];
    return (rn?.name) || t.name || '';
  };
  // Sub-linha: [nome · ] data · dist km [ · extra]
  const tSub = (t, distExtra, extra) => {
    const name = tName(t);
    const base = shortDate(t.startMs) + ' · ' + f1(t.distKm) + ' km' + (distExtra ? ' · ' + distExtra : '');
    return (name ? name + ' · ' : '') + base + (extra ? ' · ' + extra : '');
  };

  let rows = '';
  if (byEff) rows += _statsRow('⚡', 'Mais eficiente elétrica',
    f1(byEff.netKwh / byEff.distKm * 100) + ' kWh/100km',
    tSub(byEff));
  if (byHybridEff) {
    const equiv = ((byHybridEff.netKwh || 0) + byHybridEff.fuelL * KWH_PER_L) / byHybridEff.distKm * 100;
    rows += _statsRow('🔥', 'Mais eficiente híbrida',
      f1(equiv) + ' kWh_eq/100km',
      tSub(byHybridEff, f2(byHybridEff.netKwh || 0) + ' kWh + ' + f2(byHybridEff.fuelL) + ' L'));
  }
  if (byDist) rows += _statsRow('📏', 'Mais longa',
    f1(byDist.distKm) + ' km',
    tSub(byDist));
  if (byRegen) {
    const regenPct = Math.round((byRegen.regenKwh || 0) / byRegen.energyKwh * 100);
    rows += _statsRow('♻️', 'Maior regeneração',
      regenPct + '% do bruto',
      tSub(byRegen, null, f2(byRegen.regenKwh) + ' kWh'));
  }
  if (byFuel) rows += _statsRow('⛽', 'Melhor viagem com gasolina',
    f1(byFuel.distKm / byFuel.fuelL) + ' km/L',
    tSub(byFuel, null, f2(byFuel.fuelL) + ' L'));
  if (!rows) rows = '<div style="color:#475569;font-size:12px">Dados insuficientes.</div>';

  // ── Top 3 menor R$/km ─────────────────────────────────────────────────────
  let top3Rows = '';
  if (_pg > 0 || _pk > 0) {
    const medals = ['🥇', '🥈', '🥉'];
    const top3 = trips
      .filter(t => (t.distKm || 0) > 5)
      .map(t => {
        const cost = (t.fuelL || 0) * _pg + Math.max(0, t.netKwh || 0) * _pk;
        return cost > 0 ? { t, cPkm: cost / t.distKm, cost } : null;
      })
      .filter(Boolean)
      .sort((a, b) => a.cPkm - b.cPkm)
      .slice(0, 3);
    if (top3.length) {
      top3.forEach(({ t, cPkm, cost }, i) => {
        top3Rows += _statsRow(
          medals[i],
          `${i + 1}º menor custo/km`,
          'R$ ' + f3(cPkm) + '/km',
          tSub(t, null, 'R$ ' + f2(cost))
        );
      });
    }
  }
  const top3Card = top3Rows
    ? _statsCard('💰 Top 3 — menor R$/km <span style="font-size:10px;color:#475569;font-weight:400">(> 5 km)</span>', top3Rows)
    : '';

  return _statsCard('🏆 Recordes pessoais (' + trips.length + ' viagens)', rows) + top3Card;
}

// ── Coluna de período (compartilhada entre semanal e mensal) ─────────────────
function _statsPeriodCol(title, subtitle, from, to) {
  if (!from || !to) return `<div style="flex:1">
    <div style="font-size:10px;font-weight:700;color:#94a3b8;margin-bottom:2px">${title}</div>
    <div style="font-size:9px;color:#475569;margin-bottom:6px">${subtitle}</div>
    <div style="font-size:11px;color:#475569">sem dados</div>
  </div>`;
  const km  = Math.max(0, (to.distance_km || 0) - (from.distance_km || 0));
  const net = Math.max(0, (to.net_kwh     || 0) - (from.net_kwh     || 0));
  const ren = Math.max(0, (to.regen_kwh   || 0) - (from.regen_kwh   || 0));
  const fue = Math.max(0, (to.fuel_l      || 0) - (from.fuel_l      || 0));
  const eff = km > 0.5 ? (net / km * 100) : 0;
  return `<div style="flex:1">
    <div style="font-size:10px;font-weight:700;color:#94a3b8;margin-bottom:2px">${title}</div>
    <div style="font-size:9px;color:#475569;margin-bottom:6px">${subtitle}</div>
    <div style="font-size:18px;font-weight:800;color:#60a5fa;line-height:1">${km.toFixed(1)}</div>
    <div style="font-size:9px;color:#475569;margin-bottom:6px">km</div>
    <div style="font-size:11px;color:#4ade80">${net.toFixed(1)} kWh</div>
    ${ren > 0.1 ? `<div style="font-size:10px;color:#39FF88">↩ ${ren.toFixed(1)} kWh regen</div>` : ''}
    ${fue > 0.05 ? `<div style="font-size:11px;color:#fb923c">${fue.toFixed(2)} L</div>` : ''}
    ${eff > 0 ? `<div style="font-size:10px;color:#94a3b8">${eff.toFixed(1)} kWh/100km</div>` : ''}
  </div>`;
}

async function _statsWeeklyHTML() {
  let snaps = [];
  try { snaps = await apiFetch('/api/lifetime/snapshots').then(r => r.json()); } catch (_) {}
  if (!snaps.length) return _statsCard('📅 Comparativo semanal', '<div style="color:#475569;font-size:12px">Snapshots insuficientes.</div>');

  const fmtD = ms => new Date(ms).toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' });

  // Segunda-feira às 00:00 local
  function mondayMs(refMs) {
    const d = new Date(refMs);
    d.setHours(0, 0, 0, 0);
    const day = d.getDay();
    d.setDate(d.getDate() - (day === 0 ? 6 : day - 1));
    return d.getTime();
  }

  const now      = Date.now();
  const thisMon  = mondayMs(now);
  const lastMon  = thisMon - 7 * 86400000;
  const elapsed  = now - thisMon;                  // ms decorridos desde seg atual

  const snapBefore = ts => {
    const arr = snaps.filter(s => s.ts < ts);
    return arr.length ? arr[arr.length - 1] : null;
  };
  const latest           = snaps[snaps.length - 1];
  const atThisMon        = snapBefore(thisMon);
  const atLastMon        = snapBefore(lastMon);
  const atSamePtLastWeek = snapBefore(lastMon + elapsed); // mesmo ponto na semana passada

  const body = `<div style="display:flex;gap:16px">
    ${_statsPeriodCol('Esta semana',    fmtD(thisMon) + ' → hoje',           atThisMon,  latest)}
    <div style="width:1px;background:#0F1520;flex-shrink:0"></div>
    ${_statsPeriodCol('Semana passada', fmtD(lastMon) + ' → ' + fmtD(lastMon + elapsed), atLastMon, atSamePtLastWeek)}
  </div>`;

  return _statsCard('📅 Comparativo semanal', body);
}

async function _statsMonthlyHTML() {
  let snaps = [];
  try { snaps = await apiFetch('/api/lifetime/snapshots').then(r => r.json()); } catch (_) {}
  if (!snaps.length) return _statsCard('📆 Comparativo mensal', '<div style="color:#475569;font-size:12px">Snapshots insuficientes.</div>');

  const fmtD = ms => new Date(ms).toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' });

  const snapBefore = ts => {
    const arr = snaps.filter(s => s.ts < ts);
    return arr.length ? arr[arr.length - 1] : null;
  };
  const latest = snaps[snaps.length - 1];
  const now    = Date.now();

  // Dia 01 do mês atual às 00:00
  const d1 = new Date(now);
  d1.setDate(1); d1.setHours(0, 0, 0, 0);
  const thisMonth1st = d1.getTime();
  const elapsed      = now - thisMonth1st;   // ms decorridos desde dia 01

  // Dia 01 do mês anterior
  const d2 = new Date(d1);
  d2.setMonth(d2.getMonth() - 1);
  const prevMonth1st    = d2.getTime();
  const samePtPrevMonth = prevMonth1st + elapsed; // mesmo ponto no mês anterior

  const atThisMonth1st   = snapBefore(thisMonth1st);
  const atPrevMonth1st   = snapBefore(prevMonth1st);
  const atSamePtPrevMonth= snapBefore(samePtPrevMonth);

  const body = `<div style="display:flex;gap:16px">
    ${_statsPeriodCol('Este mês',    fmtD(thisMonth1st) + ' → hoje',                   atThisMonth1st,  latest)}
    <div style="width:1px;background:#0F1520;flex-shrink:0"></div>
    ${_statsPeriodCol('Mês passado', fmtD(prevMonth1st) + ' → ' + fmtD(samePtPrevMonth), atPrevMonth1st, atSamePtPrevMonth)}
  </div>`;

  return _statsCard('📆 Comparativo mensal', body);
}

function _statsElectricHTML(trips) {
  // Universo lifetime — todas viagens com dado de split (independe do filtro
  // global, mostra sempre o acumulado total no topo do card).
  const tripsLifetimeAll = (cachedAutoTrips || [])
    .filter(t => (t.distKm || 0) > 2 && t.hybridTimeSec !== undefined);
  if (!tripsLifetimeAll.length) {
    return _statsCard('⚡ Split elétrico / híbrido',
      '<div style="color:#475569;font-size:12px">Dados disponíveis em viagens registradas a partir de agora. Cada nova viagem calculará automaticamente o tempo em modo elétrico vs híbrido.</div>');
  }

  // Lifetime
  const lifetimeDist   = tripsLifetimeAll.reduce((s, t) => s + (t.distKm || 0), 0);
  const lifetimeHybrid = tripsLifetimeAll.reduce((s, t) => s + (t.hybridDistKm || 0), 0);
  const lifetimeElec   = Math.max(0, lifetimeDist - lifetimeHybrid);
  const sinceMs        = tripsLifetimeAll.reduce((m, t) => Math.min(m, t.startMs || Infinity), Infinity);
  const sinceDate      = isFinite(sinceMs)
    ? new Date(sinceMs).toLocaleDateString('pt-BR', { day:'2-digit', month:'2-digit', year:'numeric' })
    : null;

  // Período (trips já vem filtrado pelo filtro global)
  const tripsFiltered = trips.filter(t => t.hybridTimeSec !== undefined && (t.distKm || 0) > 0);
  const periodDist   = tripsFiltered.reduce((s, t) => s + (t.distKm || 0), 0);
  const periodHybrid = tripsFiltered.reduce((s, t) => s + (t.hybridDistKm || 0), 0);
  const periodElec   = Math.max(0, periodDist - periodHybrid);
  const periodElecPct = periodDist > 0 ? Math.round(periodElec / periodDist * 100) : 0;
  const periodHybPct  = 100 - periodElecPct;
  const isAllFilter  = filterState.stats.active === 'all';

  const odoBlock = `<div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:6px">
    <div style="background:rgba(74,222,128,0.06);border:1px solid rgba(74,222,128,0.18);border-radius:10px;padding:10px 12px">
      <div style="font-size:9px;font-weight:700;letter-spacing:1.2px;color:#4ade80;text-transform:uppercase">⚡ Elétrico</div>
      <div style="font-size:22px;font-weight:800;color:#4ade80;letter-spacing:-0.5px;font-variant-numeric:tabular-nums;margin-top:2px">${lifetimeElec.toFixed(1)}<span style="font-size:11px;color:#5B7394;font-weight:500;margin-left:3px">km</span></div>
    </div>
    <div style="background:rgba(251,146,60,0.06);border:1px solid rgba(251,146,60,0.18);border-radius:10px;padding:10px 12px">
      <div style="font-size:9px;font-weight:700;letter-spacing:1.2px;color:#fb923c;text-transform:uppercase">🔥 Híbrido</div>
      <div style="font-size:22px;font-weight:800;color:#fb923c;letter-spacing:-0.5px;font-variant-numeric:tabular-nums;margin-top:2px">${lifetimeHybrid.toFixed(1)}<span style="font-size:11px;color:#5B7394;font-weight:500;margin-left:3px">km</span></div>
    </div>
  </div>
  ${sinceDate ? `<div style="font-size:10px;color:#475569;text-align:center;margin-bottom:12px;letter-spacing:0.3px">lifetime desde ${sinceDate} · ${tripsLifetimeAll.length} viagens · ${lifetimeDist.toFixed(1)} km totais</div>` : ''}`;

  // Bloco do período só aparece se filtro ≠ Tudo (senão seria duplicado com odômetros lifetime)
  const periodBlock = isAllFilter ? '' : `<div style="margin-top:10px;border-top:1px solid #0F1520;padding-top:10px">
    <div style="font-size:10px;color:#475569;letter-spacing:0.5px;text-transform:uppercase;margin-bottom:6px">Período selecionado</div>
    <div style="height:10px;background:#0F1C2E;border-radius:5px;overflow:hidden;margin-bottom:6px">
      <div style="height:100%;width:${periodElecPct}%;background:linear-gradient(90deg,#39FF88,#4ade80);border-radius:5px 0 0 5px;display:inline-block"></div>
    </div>
    <div style="display:flex;justify-content:space-between;font-size:11px;margin-bottom:8px">
      <span style="color:#4ade80;font-weight:600">⚡ ${periodElec.toFixed(1)} km · ${periodElecPct}%</span>
      <span style="color:#fb923c;font-weight:600">🔥 ${periodHybrid.toFixed(1)} km · ${periodHybPct}%</span>
    </div>
    <div style="font-size:11px;color:#64748b">${tripsFiltered.length} viagens · ${periodDist.toFixed(1)} km</div>
  </div>`;

  return _statsCard('⚡ Split elétrico / híbrido', odoBlock + periodBlock);
}

// ── Ranking de locais de recarga por eficiência ───────────────────────────────
// ── Comparativo EV vs ICE — economia acumulada ────────────────────────────
// Compara o que VOCÊ gastou (gasolina real + kWh real) com o cenário
// hipotético "só ICE" — todos os km da viagem queimando gasolina ao
// consumo médio oficial do H6 PHEV em modo combustão (10 km/L cidade).
function _statsEvVsIceHTML(trips) {
  const valid = trips.filter(t => (t.distKm || 0) > 1);
  if (valid.length < 5) return '';

  const totalKm  = valid.reduce((s, t) => s + (+t.distKm  || 0), 0);
  const totalL   = valid.reduce((s, t) => s + (+t.fuelL   || 0), 0);
  const totalKwh = valid.reduce((s, t) => s + Math.max(0, +t.netKwh || 0), 0);

  const { gas: priceGas, kwh: priceKwh } = getPrices();
  const realCost = totalL * priceGas + totalKwh * priceKwh;

  // Consumo de referência só-ICE pro Haval H6 PHEV (cidade)
  const ICE_REF_KM_PER_L = 10;
  const iceL    = totalKm / ICE_REF_KM_PER_L;
  const iceCost = iceL * priceGas;

  const saved    = iceCost - realCost;
  const savedPct = iceCost > 0 ? (saved / iceCost) * 100 : 0;
  const cls      = saved > 0 ? 'green' : 'orange';

  return _statsCard('💰 EV vs ICE — quanto você economizou', `
    <div style="font-size:11px;color:#64748b;margin-bottom:8px">
      Base: ${valid.length} viagens · ${totalKm.toFixed(0)} km totais.
      Referência ICE: ${ICE_REF_KM_PER_L} km/L (Haval H6 PHEV em modo combustão).
    </div>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:10px">
      <div style="background:#0a0f1c;border:1px solid #1e293b;border-radius:8px;padding:10px">
        <div style="font-size:9px;color:#475569;letter-spacing:1px;text-transform:uppercase">Você gastou</div>
        <div style="font-size:18px;font-weight:800;color:#4ade80;margin-top:3px">R$ ${f2(realCost)}</div>
        <div style="font-size:10px;color:#64748b;margin-top:2px">${f1(totalL)} L + ${f1(totalKwh)} kWh</div>
      </div>
      <div style="background:#0a0f1c;border:1px solid #1e293b;border-radius:8px;padding:10px">
        <div style="font-size:9px;color:#475569;letter-spacing:1px;text-transform:uppercase">Se fosse só ICE</div>
        <div style="font-size:18px;font-weight:800;color:#fb923c;margin-top:3px">R$ ${f2(iceCost)}</div>
        <div style="font-size:10px;color:#64748b;margin-top:2px">${f1(iceL)} L (estimado)</div>
      </div>
    </div>
    <div style="background:rgba(${saved > 0 ? '74,222,128' : '251,146,60'},0.10);border:1px solid rgba(${saved > 0 ? '74,222,128' : '251,146,60'},0.30);border-radius:8px;padding:10px;text-align:center">
      <div style="font-size:10px;color:#64748b;letter-spacing:1px;text-transform:uppercase">${saved > 0 ? 'Economia com o elétrico' : 'Custo extra do elétrico'}</div>
      <div style="font-size:22px;font-weight:800;color:var(--${cls});margin-top:3px">${saved >= 0 ? '−' : '+'} R$ ${f2(Math.abs(saved))}</div>
      <div style="font-size:11px;color:#94a3b8;margin-top:2px">${saved > 0 ? '−' : '+'}${Math.abs(savedPct).toFixed(0)}% vs combustão pura</div>
    </div>
  `);
}

// ── SOH estimado — capacidade aparente da bateria por recarga ────────────
// Pra cada recarga relevante (ΔSOC >= 30%), calcula energy_kwh / ΔSOC × 100 =
// capacidade total estimada. Compara média das mais recentes vs mais antigas
// pra detectar degradação. Nominal: 34 kWh.
function _statsBatterySohHTML(charges) {
  const NOMINAL_KWH = 34;
  const valid = (charges || []).filter(c => {
    const ds = (+c.soc_end || 0) - (+c.soc_start || 0);
    return ds >= 30 && (+c.energy_kwh || 0) > 5;
  });
  if (valid.length < 3) return '';   // amostra muito pequena pra confiar

  const capacities = valid.map(c => {
    const ds = c.soc_end - c.soc_start;
    return {
      ts: c.timestamp_ms || 0,
      cap: (c.energy_kwh / ds) * 100,
    };
  }).filter(x => x.cap > 10 && x.cap < 60)  // clamp valores absurdos
    .sort((a, b) => a.ts - b.ts);

  if (capacities.length < 3) return '';

  // Médias: recentes (até 5) vs antigas (até 5)
  const recent = capacities.slice(-Math.min(5, Math.floor(capacities.length/2)));
  const older  = capacities.slice(0,  Math.min(5, Math.floor(capacities.length/2)));
  const avgRecent = recent.reduce((s, x) => s + x.cap, 0) / recent.length;
  const avgOlder  = older.reduce((s, x) => s + x.cap, 0) / older.length;
  const soh = (avgRecent / NOMINAL_KWH) * 100;
  const trend = avgRecent - avgOlder;
  const sohCls = soh >= 95 ? 'green' : soh >= 85 ? 'teal' : 'orange';

  // Mini gráfico (pontos no tempo)
  const minC = Math.min(...capacities.map(x => x.cap));
  const maxC = Math.max(...capacities.map(x => x.cap));
  const yRange = Math.max(0.5, maxC - minC);
  const w = 280, h = 40;
  const tMin = capacities[0].ts;
  const tMax = capacities[capacities.length-1].ts;
  const tRange = Math.max(1, tMax - tMin);
  const pts = capacities.map(p => {
    const x = ((p.ts - tMin) / tRange) * w;
    const y = h - ((p.cap - minC) / yRange) * (h - 4) - 2;
    return `${x.toFixed(1)},${y.toFixed(1)}`;
  });
  const trendBadge = Math.abs(trend) < 0.3 ? 'estável'
                   : trend > 0 ? `+${trend.toFixed(1)} kWh ↑` : `${trend.toFixed(1)} kWh ↓`;
  const trendCls = Math.abs(trend) < 0.3 ? 'muted' : trend > 0 ? 'green' : 'orange';

  return _statsCard('🔋 Saúde da bateria (SOH estimado)', `
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:10px">
      <div style="background:#0a0f1c;border:1px solid #1e293b;border-radius:8px;padding:10px">
        <div style="font-size:9px;color:#475569;letter-spacing:1px;text-transform:uppercase">Capacidade atual</div>
        <div style="font-size:18px;font-weight:800;color:var(--${sohCls});margin-top:3px">${avgRecent.toFixed(1)} kWh</div>
        <div style="font-size:10px;color:#64748b;margin-top:2px">de ${NOMINAL_KWH} kWh nominais</div>
      </div>
      <div style="background:#0a0f1c;border:1px solid #1e293b;border-radius:8px;padding:10px">
        <div style="font-size:9px;color:#475569;letter-spacing:1px;text-transform:uppercase">SOH</div>
        <div style="font-size:18px;font-weight:800;color:var(--${sohCls});margin-top:3px">${soh.toFixed(0)}%</div>
        <div style="font-size:10px;color:var(--${trendCls});margin-top:2px">vs antigas: ${trendBadge}</div>
      </div>
    </div>
    <svg viewBox="0 0 ${w} ${h}" width="100%" height="${h}" preserveAspectRatio="none" style="display:block;background:#0a0f1c;border:1px solid #1e293b;border-radius:8px">
      <polyline points="${pts.join(' ')}" fill="none" stroke="#22d3ee" stroke-width="1.5" stroke-linejoin="round"/>
      ${capacities.map((p, i) => {
        const [x, y] = pts[i].split(',');
        return `<circle cx="${x}" cy="${y}" r="2" fill="#22d3ee"/>`;
      }).join('')}
    </svg>
    <div style="font-size:10px;color:#475569;margin-top:6px;line-height:1.5">
      Estimativa baseada em ${capacities.length} recargas com Δ SOC ≥ 30%.
      Range observado: ${minC.toFixed(1)} – ${maxC.toFixed(1)} kWh.
    </div>
  `);
}

// ── Heatmap de uso ─────────────────────────────────────────────────────────
// Mapa Leaflet com círculos translúcidos em cada ponto de início/fim de
// viagem. Sobreposição cria efeito visual de "heat" sem precisar de plugin.
let _statsHeatmapData = null;  // { points: [{lat,lng,w}], ... }
function _statsHeatmapHTML(trips) {
  const withGps = trips.filter(t =>
    t.startLat && t.startLng && t.endLat && t.endLng &&
    (t.startLat !== 0 || t.startLng !== 0));
  if (withGps.length < 5) return '';

  // Cada viagem contribui 2 pontos (start + end). Peso = log(distKm) pra
  // não inflar viagens curtas locais demais.
  const points = [];
  for (const t of withGps) {
    const w = Math.max(0.4, Math.min(2, Math.log10(1 + (t.distKm || 0))));
    points.push({ lat: t.startLat, lng: t.startLng, w });
    points.push({ lat: t.endLat,   lng: t.endLng,   w });
  }
  _statsHeatmapData = { points };

  return _statsCard(`🗺 Mapa de uso — ${withGps.length} viagens`, `
    <div style="font-size:11px;color:#64748b;margin-bottom:8px">
      Pontos quentes mostram onde você mais começa/termina viagens.
    </div>
    <div id="stats-heatmap" style="height:300px;border-radius:8px;overflow:hidden;background:#0a0f1c"></div>
  `);
}

let _statsHeatmapMap = null;
function _initStatsHeatmap() {
  const el = document.getElementById('stats-heatmap');
  if (!el || !_statsHeatmapData) return;
  if (_statsHeatmapMap) {
    _statsHeatmapMap.remove();
    _statsHeatmapMap = null;
  }
  const pts = _statsHeatmapData.points;
  if (!pts.length) return;
  // Bounds
  const lats = pts.map(p => p.lat), lngs = pts.map(p => p.lng);
  const sw = [Math.min(...lats), Math.min(...lngs)];
  const ne = [Math.max(...lats), Math.max(...lngs)];

  _statsHeatmapMap = L.map(el, {
    zoomControl: true,
    attributionControl: false,
    scrollWheelZoom: false,
  });
  L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
    maxZoom: 18,
  }).addTo(_statsHeatmapMap);
  _statsHeatmapMap.fitBounds([sw, ne], { padding: [20, 20], maxZoom: 14 });

  // Desenha círculos translúcidos. Sobreposição = mais "quente".
  for (const p of pts) {
    L.circle([p.lat, p.lng], {
      radius: 150 * p.w,
      color: '#fb923c',
      fillColor: '#fb923c',
      fillOpacity: 0.12,
      weight: 0,
    }).addTo(_statsHeatmapMap);
  }
}

function _statsChargingLocationsHTML(charges) {
  if (!charges.length) return '';

  const chargerMap = _chargerKwhMap();
  const priceKwh   = state.price_kwh || 0;

  // Agrupa por local (null → '(sem local registrado)')
  const groups = {};
  for (const c of charges) {
    const loc = c.location_name || '(sem local registrado)';
    if (!groups[loc]) groups[loc] = { sessions: 0, chargeKwh: 0, chargerKwh: 0, chargeKwhWithData: 0, durationSec: 0, costBrl: 0, withCharger: 0, tempSum: 0, tempCount: 0 };
    const g = groups[loc];
    g.sessions++;
    g.chargeKwh   += c.energy_kwh   || 0;
    g.durationSec += c.duration_sec || 0;
    // Fonte correta: c.charger_kwh (servidor/IDB) → localStorage
    const ck = _resolveChargerKwh(c, chargerMap);
    if (ck > 0) {
      g.chargerKwh      += ck;
      g.chargeKwhWithData += c.energy_kwh || 0;  // só sessões COM dado de carregador
      g.withCharger++;
    }
    // custo: override manual ou price_kwh
    const ov = _chargeCostOverride(c.timestamp_ms || 0);
    g.costBrl += ov ? ov.total : (priceKwh * (c.energy_kwh || 0));
    // temperatura média
    if (c.avg_temp_c != null) { g.tempSum += c.avg_temp_c; g.tempCount++; }
  }

  // Calcula métricas e ordena: com dado de perda primeiro (menor % perda), depois por kWh
  const locs = Object.entries(groups).map(([name, g]) => {
    // Perda calculada apenas sobre sessões que têm AMBOS os valores (carregador + carro)
    const lossKwh  = g.chargerKwh > 0 ? Math.max(0, g.chargerKwh - g.chargeKwhWithData) : 0;
    const lossPct  = g.chargerKwh > 0 ? lossKwh / g.chargerKwh * 100 : null;
    const effPct   = g.chargerKwh > 0 ? (1 - lossKwh / g.chargerKwh) * 100 : null;
    const avgPwr   = g.durationSec > 0 ? g.chargeKwh / (g.durationSec / 3600) : 0;
    const costPkwh = g.chargerKwh > 0 ? g.costBrl / g.chargerKwh
                   : g.chargeKwh > 0  ? g.costBrl / g.chargeKwh : 0;
    const avgTemp  = g.tempCount > 0 ? Math.round((g.tempSum / g.tempCount) * 10) / 10 : null;
    return { name, ...g, lossKwh, lossPct, effPct, avgPwr, costPkwh, avgTemp };
  }).sort((a, b) => {
    if (a.lossPct !== null && b.lossPct !== null) return a.lossPct - b.lossPct;
    if (a.lossPct !== null) return -1;
    if (b.lossPct !== null) return 1;
    return b.chargeKwh - a.chargeKwh;
  });

  if (!locs.length) return '';

  const medals = ['🥇', '🥈', '🥉'];
  let rows = '';
  locs.forEach((loc, i) => {
    // Linha de perda / eficiência
    let lossStr;
    if (loc.lossPct !== null) {
      const color = loc.lossPct < 5 ? '#4ade80' : loc.lossPct < 10 ? '#fbbf24' : '#f87171';
      lossStr = `<span style="color:${color};font-weight:700">${f1(loc.lossPct)}% perda</span>`
              + ` · <span style="color:${color}">${f1(loc.effPct)}% efic.</span>`
              + ` · ${loc.withCharger}/${loc.sessions} c/ dado`;
    } else {
      lossStr = `<span style="color:#475569">sem dado de carregador</span> · ${loc.sessions} sessões`;
    }

    // Sub-linha: kWh, potência, custo, temperatura
    const kwhStr  = `${f2(loc.chargeKwh)} kWh injetados`;
    const pwrStr  = loc.avgPwr > 0 ? ` · ${f1(loc.avgPwr)} kW médio` : '';
    const costStr = loc.costPkwh > 0 ? ` · R$ ${f3(loc.costPkwh)}/kWh` : '';
    const tempStr = loc.avgTemp != null ? ` · 🌡 ${loc.avgTemp}°C médio` : '';

    const icon = loc.lossPct !== null && i < 3 ? medals[i] : '📍';
    rows += _statsRow(icon, loc.name, `${f2(loc.chargeKwh)} kWh`,
      kwhStr + pwrStr + costStr + tempStr + '<br>' + lossStr);
  });

  // Nota informativa se algum local não tem dado de perda
  const missingData = locs.some(l => l.lossPct === null);
  const note = missingData
    ? `<div style="font-size:10px;color:#475569;margin-top:10px;padding-top:8px;border-top:1px solid #0F1520">
        🔌 Use o botão 🔌 em cada recarga para inserir o kWh do carregador e calcular a perda.
       </div>`
    : '';

  return _statsCard('🔌 Locais de recarga — eficiência de carga', rows + note);
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

/**
 * @param {string}      action      - ex: 'lock_open', 'engine_on'
 * @param {string}      successMsg  - mensagem de sucesso
 * @param {object|null} confirmSpec - { key: 'lock_state', expectedVal: 'on', timeout?: 60000 }
 *                                    Se fornecido, aguarda mudança de estado via WS antes de
 *                                    confirmar sucesso. Se não mudar em time, mostra falha.
 */
async function sendRemoteAction(action, successMsg, confirmSpec = null) {
  const logEl  = document.getElementById(_actionLogMap[action] || '');
  const hhmm   = () => new Date().toLocaleTimeString('pt-BR', { hour: '2-digit', minute: '2-digit' });
  // Cloud GWM Brasil tem latência de ~1-2min entre press do botão e
  // atualização do estado refletida pela integração HA. 180s cobre isso.
  const TIMEOUT_SEC = confirmSpec?.timeout ?? 180;
  const TIMEOUT     = TIMEOUT_SEC * 1000;

  // Cancela confirmação anterior para o mesmo campo (evita timer duplicado)
  if (confirmSpec && _pendingConfirm[confirmSpec.key]) {
    clearTimeout(_pendingConfirm[confirmSpec.key].timer);
    delete _pendingConfirm[confirmSpec.key];
  }

  if (logEl) logEl.innerHTML = '<span style="color:#94a3b8">Enviando…</span>';
  showToast('Enviando comando…');

  try {
    const r    = await apiFetch(`/api/action/${action}`, { method: 'POST' });
    const data = await r.json().catch(() => ({}));

    if (!r.ok || !data.ok) {
      const err = data.error || `Erro ${r.status}`;
      showToast('✗ ' + err);
      if (logEl) logEl.innerHTML = `<span style="color:#f87171">✗ ${err} · ${hhmm()}</span>`;
      return;
    }

    // HTTP 200 do bridge = HA aceitou o press. Mostra "Enviado" imediato.
    const sentAt = hhmm();
    showToast('✓ Comando enviado');
    if (logEl) logEl.innerHTML = `<span style="color:#4ade80">✓ Enviado · ${sentAt}</span>`;
    if (navigator.vibrate) navigator.vibrate(80);

    // Se houver confirmSpec, segue escutando o estado físico em background.
    // Se vier mudança em TIMEOUT_SEC, upgrade visual pra "Confirmado pelo carro".
    // Se der timeout, mantém o "Enviado" — não é falha, só não confirmou fisicamente.
    if (confirmSpec) {
      _pendingConfirm[confirmSpec.key] = {
        expectedVal: confirmSpec.expectedVal,
        timer: setTimeout(() => {
          delete _pendingConfirm[confirmSpec.key];
          // Sem mudança visual — comando já foi marcado como Enviado
        }, TIMEOUT),
        onSuccess: () => {
          showToast('✓ ' + successMsg + ' (confirmado)');
          if (logEl) logEl.innerHTML = `<span style="color:#4ade80">✓ ${successMsg} (confirmado) · ${hhmm()}</span>`;
          if (navigator.vibrate) navigator.vibrate([80, 40, 80]);
        },
      };
    }

  } catch (err) {
    const msg = err.message === 'unauthorized' ? 'Sem permissão' : 'Falha ao enviar';
    showToast('✗ ' + msg);
    if (logEl) logEl.innerHTML = `<span style="color:#f87171">✗ ${msg} · ${hhmm()}</span>`;
  }
}

// ── Renomear trip — modal estilo Android ─────────────────────────────────────
let _renameState = null;  // { tripId, type, currentName }

window.deleteTrip = async function(tripId, type) {
  if (!confirm('Apagar esta viagem?\nEssa ação não pode ser desfeita.')) return;
  const endpoint = type === 'auto'
    ? `/api/autotrips/${encodeURIComponent(String(tripId))}`
    : `/api/trips/${encodeURIComponent(String(tripId))}`;
  try {
    const r = await apiFetch(endpoint, { method: 'DELETE' });
    // 404 = já não existe no servidor; trata como sucesso e limpa local
    if (!r.ok && r.status !== 404) {
      const body = await r.json().catch(() => ({}));
      console.error('deleteTrip error', r.status, body);
      showToast('✗ Erro ' + r.status + ' ao apagar viagem');
      return;
    }
    // Remove do cache em memória (só auto agora — trip A/B descontinuado)
    if (cachedAutoTrips) cachedAutoTrips = cachedAutoTrips.filter(t => String(t.tripId) !== String(tripId) && String(t.startMs) !== String(tripId));
    // Remove do IndexedDB
    _openIDB().then(db => {
      db.transaction('autotrips', 'readwrite').objectStore('autotrips').delete(String(tripId));
    }).catch(() => {});
    // Remove card do DOM
    document.getElementById('trip-card-' + tripId)?.remove();
    showToast('✓ Viagem apagada');
  } catch (e) {
    console.error('deleteTrip exception', e);
    if (e.message !== 'unauthorized') showToast('✗ Erro ao apagar viagem');
  }
};

window.startRenameTrip = function(tripId, type) {
  // Trip A/B descontinuado — só auto agora
  let currentName = '';
  let dateStr = '';
  const t = (cachedAutoTrips || []).find(t => t.tripId === String(tripId));
  if (t) { currentName = t.name || ''; dateStr = fmtDate(t.startMs); }
  _renameState = { tripId: String(tripId), type, currentName };
  const modal = document.getElementById('d-rename-modal');
  const titleEl = document.getElementById('d-rename-modal-title');
  const dateEl  = document.getElementById('d-rename-modal-date');
  const inputEl = document.getElementById('d-rename-modal-input');
  if (!modal) return;
  titleEl.textContent = currentName ? 'Renomear viagem' : 'Nomear viagem';
  dateEl.textContent  = dateStr;
  inputEl.value       = currentName;
  modal.style.display = 'flex';
  setTimeout(() => { inputEl.focus(); try { inputEl.select(); } catch (_) {} }, 80);
};

window.doRenameCancel = function() {
  const modal = document.getElementById('d-rename-modal');
  if (modal) modal.style.display = 'none';
  _renameState = null;
};

window.doRenameConfirm = async function() {
  if (!_renameState) return;
  const { tripId, type, currentName } = _renameState;
  const newName = (document.getElementById('d-rename-modal-input')?.value || '').trim();
  doRenameCancel();   // fecha o modal
  if (!newName || newName === currentName) return;
  try {
    const r    = await apiFetch('/api/rename', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ tripId, type, name: newName }),
    });
    const data = await r.json();
    // Atualiza cache local (auto-trips only)
    const t = (cachedAutoTrips || []).find(t => t.tripId === tripId);
    if (t) t.name = newName;
    // Marca como pendente de confirmação do carro
    renameTracking[tripId] = { pendingId: data.id || '', name: newName, confirmed: false };
    _saveRenameTracking();
    renderAutoTrips();
    showToast('⏳ Nome salvo — aguardando o carro confirmar');
  } catch (_) {
    showToast('✗ Erro ao salvar nome');
  }
};

// ── Location picker ───────────────────────────────────────────────────────────
window.openLoc = function(ts) {
  _locPickerTs  = ts;
  _locPickerLat = null;
  _locPickerLng = null;
  _locSelectedKnownId = null;
  const charge = cachedCharges?.find(c => c.timestamp_ms === ts);
  const modal  = document.getElementById('loc-picker');
  if (!modal) return;

  document.getElementById('loc-picker-date').textContent = charge ? fmtDate(charge.timestamp || '') : '';
  const nameInput = document.getElementById('loc-name-input');
  nameInput.value = charge?.location_name || '';

  // Popula datalist (campo livre) com locais favoritos legados
  const dl = document.getElementById('loc-datalist');
  dl.innerHTML = _knownLocations.map(l => `<option value="${l.name}">`).join('');

  // Se já tem GPS salvo, preenche e indica no botão
  const gpsBtn = document.getElementById('loc-gps-btn');
  if (charge?.location_lat && charge?.location_lng) {
    _locPickerLat = charge.location_lat;
    _locPickerLng = charge.location_lng;
    document.getElementById('loc-gps-status').textContent = '';
    if (gpsBtn) gpsBtn.textContent = `✅ GPS: ${charge.location_lat.toFixed(4)}, ${charge.location_lng.toFixed(4)}`;
    document.getElementById('loc-save-known').checked = false;
  } else {
    document.getElementById('loc-gps-status').textContent = '';
    if (gpsBtn) gpsBtn.textContent = '📍 Capturar minha localização atual';
    document.getElementById('loc-save-known').checked = false;
  }

  // Carrega e renderiza chips de locais conhecidos
  _renderLocKnownChips(charge?.location_name || null);

  modal.style.display = 'flex';
  setTimeout(() => nameInput.focus(), 80);
};

function _renderLocKnownChips(activeNameHint) {
  const container = document.getElementById('loc-known-chips');
  const separator = document.getElementById('loc-known-sep');
  if (!container) return;

  apiFetch('/api/known-places').then(r => r.ok ? r.json() : []).then(raw => {
    const places = [...raw].sort((a, b) =>
      a.name.localeCompare(b.name, 'pt-BR', { sensitivity: 'base' })
    );
    _locKnownPlaces = places;
    if (!places.length) {
      container.innerHTML = '';
      if (separator) separator.style.display = 'none';
      return;
    }
    if (separator) separator.style.display = 'flex';
    container.innerHTML = places.map(p => {
      const active = activeNameHint && p.name.trim().toLowerCase() === activeNameHint.trim().toLowerCase();
      if (active) { _locPickerLat = p.lat; _locPickerLng = p.lng; _locSelectedKnownId = p.id; }
      // Passa só o id numérico — sem strings no onclick, evita quebra de aspas HTML
      return `<button class="loc-kp-chip${active ? ' loc-kp-chip--active' : ''}"
        onclick="locPickKnown(${p.id})"
        id="loc-kp-chip-${p.id}">${p.name}</button>`;
    }).join('');
  }).catch(() => {
    _locKnownPlaces = [];
    container.innerHTML = '';
    if (separator) separator.style.display = 'none';
  });
}

window.closeLoc = function() {
  const modal = document.getElementById('loc-picker');
  if (modal) modal.style.display = 'none';
  _locPickerTs = 0; _locPickerLat = null; _locPickerLng = null; _locSelectedKnownId = null;
};

// Seleciona chip de local conhecido — preenche nome e coordenadas
window.locPickKnown = function(id) {
  const place = _locKnownPlaces.find(p => p.id === id);
  if (!place) return;
  // Marca chip ativo, desmarca os outros
  document.querySelectorAll('#loc-known-chips .loc-kp-chip').forEach(el => {
    el.classList.toggle('loc-kp-chip--active', el.id === `loc-kp-chip-${id}`);
  });
  _locSelectedKnownId = id;
  _locPickerLat = place.lat;
  _locPickerLng = place.lng;
  document.getElementById('loc-name-input').value = place.name;
  document.getElementById('loc-gps-status').textContent = '';
  document.getElementById('loc-save-known').checked = false;
};

window.locCapGps = function() {
  // Desseleciona chip — GPS manual sobrepõe local conhecido
  _locSelectedKnownId = null;
  document.querySelectorAll('#loc-known-chips .loc-kp-chip').forEach(el => el.classList.remove('loc-kp-chip--active'));
  const btn = document.getElementById('loc-gps-btn');
  const status = document.getElementById('loc-gps-status');
  if (!navigator.geolocation) { status.textContent = 'GPS não disponível neste dispositivo.'; return; }
  if (btn) btn.textContent = '⏳ Capturando…';
  status.textContent = '';
  navigator.geolocation.getCurrentPosition(pos => {
    _locPickerLat = pos.coords.latitude;
    _locPickerLng = pos.coords.longitude;
    status.textContent = `GPS capturado ✓`;
    if (btn) btn.textContent = `📍 ${_locPickerLat.toFixed(5)}, ${_locPickerLng.toFixed(5)}`;

    // Sugerir local próximo se já existe
    const nameInput = document.getElementById('loc-name-input');
    if (!nameInput.value) {
      // Haversine client-side (approximation para sugestão)
      let best = null, bestD = Infinity;
      for (const l of _knownLocations) {
        if (!l.lat || !l.lng) continue;
        const dLat = (l.lat - _locPickerLat) * Math.PI / 180;
        const dLng = (l.lng - _locPickerLng) * Math.PI / 180;
        const a = Math.sin(dLat/2)**2 + Math.cos(_locPickerLat*Math.PI/180)*Math.cos(l.lat*Math.PI/180)*Math.sin(dLng/2)**2;
        const d = 6371000 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
        if (d < 200 && d < bestD) { best = l; bestD = d; }
      }
      if (best) {
        nameInput.value = best.name;
        status.textContent += ` · Sugestão: ${best.name}`;
      }
    }
  }, err => {
    if (btn) btn.textContent = '📍 Capturar minha localização atual';
    status.textContent = err.code === 1 ? 'Permissão negada.' : 'Não foi possível obter GPS.';
  }, { timeout: 15000, maximumAge: 30000 });
};

window.saveLoc = async function() {
  const name      = document.getElementById('loc-name-input').value.trim();
  const saveKnown = document.getElementById('loc-save-known').checked;
  const ts        = _locPickerTs;
  if (!ts) return;

  try {
    const body = { name, save_known: saveKnown };
    if (_locPickerLat != null) body.lat = _locPickerLat;
    if (_locPickerLng != null) body.lng = _locPickerLng;

    const updated = await apiFetch(`/api/charges/${ts}/location`, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    }).then(r => r.json());

    // Atualiza cache local
    if (cachedCharges) {
      const idx = cachedCharges.findIndex(c => c.timestamp_ms === ts);
      if (idx !== -1) {
        cachedCharges[idx].location_name = updated.location_name ?? null;
        cachedCharges[idx].location_lat  = updated.location_lat  ?? null;
        cachedCharges[idx].location_lng  = updated.location_lng  ?? null;
        _bumpCachesVersion();
        _idbPutMany('charges', [cachedCharges[idx]]).catch(() => {});
      }
    }

    if (saveKnown) {
      await loadKnownLocations();   // reload legacy list
      await loadKnownPlaces();      // reload known places (novo sistema)
    }
    closeLoc();
    renderCharges();
    showToast('📍 Local salvo');
  } catch (e) {
    showToast('✗ Erro ao salvar local');
  }
};

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
      engOn ? 'Motor desligado' : 'Motor ligado',
      { key: 'engine_state', expectedVal: engOn ? '0' : '1' },
    ),
  });
};

// ── Locais Conhecidos ─────────────────────────────────────────────────────────
let _kpMap = null;          // mini mapa Leaflet no modal
let _kpMarker = null;       // marcador no mapa
let _kpCircle = null;       // círculo de raio
let _kpEditId = null;       // id do local em edição (null = novo)
let _kpData = [];           // cache local da lista

async function loadKnownPlaces() {
  try {
    const r = await apiFetch('/api/known-places');
    if (r.ok) _kpData = await r.json();
  } catch (_) {}   // mantém _kpData anterior se rede falhar
  _renderKnownPlacesList();
}

function _renderKnownPlacesList() {
  const el = document.getElementById('kp-list');
  if (!el) return;
  if (!_kpData.length) {
    el.innerHTML = '<div class="empty" style="padding:12px 0">Nenhum local cadastrado.</div>';
    return;
  }
  const sorted = [..._kpData].sort((a, b) =>
    a.name.localeCompare(b.name, 'pt-BR', { sensitivity: 'base' })
  );
  el.innerHTML = sorted.map(p => `
    <div class="kp-item">
      <div class="kp-item-info">
        <div class="kp-item-name">📍 ${p.name}</div>
        <div class="kp-item-sub">${p.radius_m} m raio</div>
      </div>
      <div class="kp-item-actions">
        <button class="kp-btn-edit" onclick="openKpModal(${p.id})">✏️</button>
        <button class="kp-btn-del"  onclick="deleteKnownPlace(${p.id})">🗑</button>
      </div>
    </div>`).join('');
}

window.openKpModal = function(id) {
  _kpEditId = id || null;
  const place = id ? _kpData.find(p => p.id === id) : null;
  document.getElementById('kp-modal-title').textContent = place ? 'Editar local' : 'Novo local';
  document.getElementById('kp-name-input').value    = place?.name      || '';
  document.getElementById('kp-radius-input').value  = place?.radius_m  || 200;
  document.getElementById('kp-radius-val').textContent = (place?.radius_m || 200) + ' m';
  document.getElementById('kp-search-input').value  = '';   // limpa busca sempre
  document.getElementById('kp-modal').style.display = 'flex';

  // Inicializa mapa Leaflet
  setTimeout(() => {
    const lat = place?.lat || -23.55;
    const lng = place?.lng || -46.63;
    if (!_kpMap) {
      _kpMap = L.map('kp-map', { zoomControl: true }).setView([lat, lng], 15);
      L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
        attribution: '© OSM', maxZoom: 19,
      }).addTo(_kpMap);
      _kpMap.on('click', e => _kpSetPin(e.latlng.lat, e.latlng.lng));
    } else {
      _kpMap.setView([lat, lng], 15);
    }
    if (place) _kpSetPin(lat, lng, parseInt(document.getElementById('kp-radius-input').value));
    else { if (_kpMarker) { _kpMarker.remove(); _kpMarker = null; } if (_kpCircle) { _kpCircle.remove(); _kpCircle = null; } }
    setTimeout(() => _kpMap.invalidateSize(), 100);
  }, 80);
};

function _kpSetPin(lat, lng, radius) {
  const r = radius || parseInt(document.getElementById('kp-radius-input').value) || 200;
  if (_kpMarker) _kpMarker.setLatLng([lat, lng]);
  else _kpMarker = L.marker([lat, lng]).addTo(_kpMap);
  if (_kpCircle) _kpCircle.setLatLng([lat, lng]).setRadius(r);
  else _kpCircle = L.circle([lat, lng], { radius: r, color: '#22d3ee', fillOpacity: 0.12 }).addTo(_kpMap);
  _kpMap.setView([lat, lng], 15);
}

window.kpRadiusChange = function(val) {
  document.getElementById('kp-radius-val').textContent = val + ' m';
  if (_kpMarker) {
    const ll = _kpMarker.getLatLng();
    _kpSetPin(ll.lat, ll.lng, parseInt(val));
  }
};

window.kpUseGps = function() {
  if (!navigator.geolocation) { showToast('GPS não disponível'); return; }
  showToast('📍 Obtendo localização…');
  navigator.geolocation.getCurrentPosition(
    pos => _kpSetPin(pos.coords.latitude, pos.coords.longitude),
    ()  => showToast('✗ Não foi possível obter GPS'),
    { timeout: 10000, maximumAge: 30000 }
  );
};

window.kpSearchAddress = async function() {
  const q = document.getElementById('kp-search-input').value.trim();
  if (!q) return;
  try {
    showToast('🔍 Buscando…');
    const r = await fetch(
      `https://nominatim.openstreetmap.org/search?format=json&q=${encodeURIComponent(q)}&limit=1&accept-language=pt-BR`,
      { headers: { 'User-Agent': 'EcotripBridge/1.0' } }
    );
    const results = await r.json();
    if (!results.length) { showToast('Endereço não encontrado'); return; }
    const { lat, lon } = results[0];
    _kpSetPin(parseFloat(lat), parseFloat(lon));
  } catch (_) { showToast('✗ Erro na busca'); }
};

window.closeKpModal = function() {
  document.getElementById('kp-modal').style.display = 'none';
  document.getElementById('kp-search-input').value = '';
  _kpEditId = null;
};

window.saveKnownPlace = async function() {
  const name = document.getElementById('kp-name-input').value.trim();
  if (!name) { showToast('Digite um nome para o local'); return; }
  if (!_kpMarker) { showToast('Marque a localização no mapa'); return; }
  const ll  = _kpMarker.getLatLng();
  const r   = parseInt(document.getElementById('kp-radius-input').value) || 200;
  const body = { name, lat: ll.lat, lng: ll.lng, radius_m: r };
  // Desabilita botão para evitar duplo-submit
  const btn = document.querySelector('#kp-modal button[onclick="saveKnownPlace()"]');
  if (btn) btn.disabled = true;
  try {
    const resp = await apiFetch(
      _kpEditId ? `/api/known-places/${_kpEditId}` : '/api/known-places',
      { method: _kpEditId ? 'PUT' : 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) }
    );
    if (resp.status === 409) { showToast('Já existe um local com esse nome'); return; }
    if (!resp.ok) { showToast('✗ Erro ao salvar'); return; }
    showToast(_kpEditId ? '✓ Local atualizado' : '✓ Local salvo');
    closeKpModal();
    loadKnownPlaces();
  } catch (_) { showToast('✗ Erro de conexão'); }
  finally { if (btn) btn.disabled = false; }
};

window.deleteKnownPlace = async function(id) {
  if (!confirm('Apagar este local?\nViagens futuras não serão mais nomeadas automaticamente.')) return;
  try {
    await apiFetch(`/api/known-places/${id}`, { method: 'DELETE' });
    loadKnownPlaces();
  } catch (_) { showToast('✗ Erro ao apagar'); }
};

// ── Lock — toque para trancar/destrancar remotamente ─────────────────────────
window.lockClick = function() {
  const lck = state.lock_state;
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
      { key: 'lock_state', expectedVal: locked ? 'on' : 'off' },
    ),
  });
};

// ── Drive panel: HUD em camadas sobre mapa ──────────────────────────────────
// Mapa Leaflet instanciado uma única vez ao abrir a aba. Atualizações de
// posição reaproveitam o panTo. Power chart roda em buffer próprio (2 Hz, 30s).
let driveMap = null;
let _driveMapZoomState = { zoomMode: null, lastHighwayMs: 0 };
let driveMarker = null;
let _drivePowerBuf = [];           // {t: ms, kw: number} — máx 60 pontos
let _drivePowerSampleTimer = null;
let _drivePowerScale = 50;         // limite ±kW do eixo do chart (auto-ajusta)
let _drvPeakSpeed = 0;             // pico de velocidade desde a aba abrir
let _drvPeakPower = 0;             // pico de potência abs(kW) desde a aba abrir
const DRIVE_POWER_WINDOW_MS = 30000;
const DRIVE_POWER_SAMPLE_MS = 500;
// Anéis SVG concêntricos:
// - interno: raio 86, arc 270° = 405.3
// - externo (tach): raio 94, arc 270° = 443.0
const DRIVE_RING_TOTAL = 405.3;
const DRIVE_TACH_TOTAL = 443.0;
const DRIVE_POWER_MAX  = 80;       // potência máx pro anel interno (kW)
const DRIVE_RPM_MAX    = 6500;     // redline aproximada do GW4B15D
const DRIVE_RPM_REDLINE = 5500;    // a partir daqui pinta vermelho

window.initDrivePanel = function() {
  const el = document.getElementById('drv-map');
  if (!el) return;

  // Reseta picos cada vez que entra na aba
  _drvPeakSpeed = 0;
  _drvPeakPower = 0;

  // Cria mapa só na primeira vez
  if (!driveMap) {
    driveMap = L.map(el, {
      zoomControl:        false,
      attributionControl: false,
      dragging:           false,
      scrollWheelZoom:    false,
      doubleClickZoom:    false,
      touchZoom:          false,
      keyboard:           false,
      tap:                false,
    });
    L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
      maxZoom: 19,
      attribution: '',
    }).addTo(driveMap);
    // Posição inicial: usa a última conhecida do state
    const lat = +state.gps_lat || 0;
    const lng = +state.gps_lng || 0;
    if (lat && lng) driveMap.setView([lat, lng], 16);
    else driveMap.setView([-15.78, -47.93], 4);  // fallback Brasil
  }

  // Garante que o tile layer renderize após o panel virar visível
  setTimeout(() => driveMap?.invalidateSize(), 80);

  // Começa amostragem do power chart (só enquanto a aba está aberta)
  _drivePowerStart();

  // Render imediato
  renderDrivePanel();
};

// Iniciar/parar a coleta do power chart conforme a aba está visível
function _drivePowerStart() {
  if (_drivePowerSampleTimer) return;
  _drivePowerSampleTimer = setInterval(() => {
    const isActive = document.getElementById('panel-drive')?.classList.contains('active');
    if (!isActive) return;  // pausa amostragem fora da aba
    const kw = +state.motor_power_kw || 0;
    _drivePowerBuf.push({ t: Date.now(), kw });
    // Mantém só os últimos 30s
    const cutoff = Date.now() - DRIVE_POWER_WINDOW_MS;
    while (_drivePowerBuf.length && _drivePowerBuf[0].t < cutoff) _drivePowerBuf.shift();
    _renderDriveChart();
  }, DRIVE_POWER_SAMPLE_MS);
}

function _renderDriveChart() {
  const lineEl = document.getElementById('drv-chart-line');
  const fillEl = document.getElementById('drv-chart-fill');
  const scaleEl = document.getElementById('drv-chart-scale');
  if (!lineEl || !fillEl) return;
  if (_drivePowerBuf.length < 2) {
    lineEl.setAttribute('d', '');
    fillEl.setAttribute('d', '');
    return;
  }
  // Escala auto: max abs(kw) na janela, com mínimo de 20 kW e hysteresis (não cai rápido)
  const maxAbs = Math.max(20, ...(_drivePowerBuf.map(p => Math.abs(p.kw))));
  // Atualiza escala apenas se variou significativamente (suaviza)
  if (Math.abs(maxAbs - _drivePowerScale) > _drivePowerScale * 0.2) {
    _drivePowerScale = Math.ceil(maxAbs / 10) * 10;
  } else if (maxAbs > _drivePowerScale) {
    _drivePowerScale = Math.ceil(maxAbs / 10) * 10;
  }
  if (scaleEl) scaleEl.textContent = `±${_drivePowerScale} kW`;

  const w = 300, h = 78, mid = h / 2;
  const tMin = _drivePowerBuf[0].t;
  const tMax = Math.max(_drivePowerBuf[_drivePowerBuf.length - 1].t, tMin + 1);
  const tRange = Math.max(tMax - tMin, 1000);
  let d = '';
  _drivePowerBuf.forEach((p, i) => {
    const x = ((p.t - tMin) / tRange) * w;
    const y = mid - (p.kw / _drivePowerScale) * (mid - 2);
    d += (i === 0 ? `M ${x.toFixed(1)} ${y.toFixed(1)}` : ` L ${x.toFixed(1)} ${y.toFixed(1)}`);
  });
  lineEl.setAttribute('d', d);
  // Fill area até o eixo central
  const lastX = ((_drivePowerBuf[_drivePowerBuf.length-1].t - tMin) / tRange) * w;
  const firstX = 0;
  fillEl.setAttribute('d', d + ` L ${lastX.toFixed(1)} ${mid} L ${firstX.toFixed(1)} ${mid} Z`);
}

// Atualiza HUD inteiro — chamado por renderAll (já passa por rAF)
function renderDrivePanel() {
  const panel = document.getElementById('panel-drive');
  if (!panel) return;
  const isActive = panel.classList.contains('active');
  // Só renderiza se a aba está visível (poupa CPU)
  if (!isActive && !driveMap) return;

  const s = state;
  // Speed: o car bus às vezes manda -1 quando inválido — clampa pra 0
  const speed = Math.max(0, +s.speed_kmh || 0);
  const speedR = Math.round(speed);
  const speedEl = document.getElementById('drv-speed');
  if (speedEl) {
    speedEl.textContent = speedR;
    speedEl.classList.toggle('idle', speedR === 0);
  }

  // Tracking de picos desde abertura da aba (resetam ao mudar de aba e voltar)
  if (speed > _drvPeakSpeed) _drvPeakSpeed = speed;
  // Anel: preenche proporcional a |motor_power_kw|, cor muda com regen
  const mp = +s.motor_power_kw || 0;
  const mpAbs = Math.abs(mp);
  if (mpAbs > _drvPeakPower) _drvPeakPower = mpAbs;
  // Atualiza linha de picos (mostra só se houver algum valor relevante)
  const peakRow = document.getElementById('drv-peak-row');
  if (peakRow) {
    if (_drvPeakSpeed > 1 || _drvPeakPower > 1) {
      peakRow.style.display = '';
      setText('drv-peak-speed', Math.round(_drvPeakSpeed) + ' km/h');
      setText('drv-peak-power', _drvPeakPower.toFixed(1) + ' kW');
    } else {
      peakRow.style.display = 'none';
    }
  }
  const ring = document.getElementById('drv-ring');
  if (ring) {
    const pct = Math.min(1, Math.abs(mp) / DRIVE_POWER_MAX);
    ring.setAttribute('stroke-dashoffset', (DRIVE_RING_TOTAL * (1 - pct)).toFixed(1));
    ring.classList.toggle('regen', mp < -0.5);
  }

  // Gear
  const gearEl = document.getElementById('drv-gear');
  if (gearEl) {
    const g = (s.gear || '').toString().toUpperCase().trim();
    const isValid = g && g !== '-1' && g !== '--';
    gearEl.textContent = isValid ? g : '--';
    gearEl.classList.toggle('idle', !isValid || g === 'P' || g === 'N');
    gearEl.classList.toggle('reverse', g === 'R');
  }

  // Tacômetro externo: arco proporcional ao RPM do ICE.
  // O APK publica engine_rpm em kRPM (ex: "2.4" = 2400 RPM) — multiplica por 1000.
  // Se algum dia mudar pra cru ou outras versões vierem em RPM direto, o valor
  // vai ser >= 50, então só converte abaixo desse threshold (heurística segura).
  const rpmRaw = Math.max(0, +s.engine_rpm || 0);
  const rpm = rpmRaw > 0 && rpmRaw < 50 ? Math.round(rpmRaw * 1000) : Math.round(rpmRaw);
  const isRedline = rpm >= DRIVE_RPM_REDLINE;
  const tach = document.getElementById('drv-tach');
  if (tach) {
    const pct = Math.min(1, rpm / DRIVE_RPM_MAX);
    tach.setAttribute('stroke-dashoffset', (DRIVE_TACH_TOTAL * (1 - pct)).toFixed(1));
    tach.classList.toggle('redline', isRedline);
  }
  // Valor numérico embaixo do "km/h", em laranja (vermelho na redline)
  const rpmInline = document.getElementById('drv-rpm-inline');
  if (rpmInline) {
    if (rpm > 0) {
      rpmInline.style.display = '';
      rpmInline.classList.toggle('redline', isRedline);
      setText('drv-rpm-val', rpm.toLocaleString('pt-BR'));
    } else {
      rpmInline.style.display = 'none';
    }
  }

  // Power chip
  const chip = document.getElementById('drv-power-chip');
  const valEl = document.getElementById('drv-power-val');
  const chPow = +s.charge_power_kw || 0;
  const isCharging = s.charging_state === 'Carregando' || chPow > 0.5;
  if (chip && valEl) {
    chip.classList.remove('regen', 'charging');
    if (isCharging) {
      chip.classList.add('charging');
      valEl.textContent = `↓ ${chPow.toFixed(1)} kW`;
    } else if (mp < -0.5) {
      chip.classList.add('regen');
      valEl.textContent = `↺ ${Math.abs(mp).toFixed(1)} kW`;
    } else if (Math.abs(mp) < 0.05) {
      valEl.textContent = `0.0 kW`;
    } else {
      valEl.textContent = `${(mp > 0 ? '+' : '')}${mp.toFixed(1)} kW`;
    }
  }

  // SOC + autonomia
  setText('drv-soc',    s.soc_pct != null ? Math.round(+s.soc_pct) + '%' : '--%');
  setText('drv-ev-km',  s.autonomy_ev_km  != null ? Math.round(+s.autonomy_ev_km)  : '--');
  // Combustível (vem do app, fuel_pct ou similar — fallback null)
  const fuelPct = +s.fuel_pct || +s.fuel_level || 0;
  setText('drv-fuel',   fuelPct > 0 ? Math.round(fuelPct) + '%' : '--%');
  setText('drv-ice-km', s.autonomy_ice_km != null ? Math.round(+s.autonomy_ice_km) : '--');
  // Consumo da janela (kWh/100km ou km/L)
  const r = s.rolling || {};
  const rKwh = +r.kwh_per_100km || 0;
  const rKmL = +r.km_per_l || 0;
  const rDist = +r.distance_km || 0;
  let consTxt = '--';
  if (rKwh > 0)      consTxt = rKwh.toFixed(1) + ' kWh/100';
  else if (rKmL > 0) consTxt = rKmL.toFixed(1) + ' km/L';
  setText('drv-cons', consTxt);
  setText('drv-rolldist', rDist > 0 ? rDist.toFixed(1) : '0.0');

  // Endereço + temps
  setText('drv-address', s.current_address || '--');
  setText('drv-temp-out', s.outside_temp != null ? (+s.outside_temp).toFixed(1) : '--');
  setText('drv-temp-in',  s.inside_temp  != null ? (+s.inside_temp).toFixed(1)  : '--');

  // Mapa: pan suave pra posição atual + zoom inteligente com histerese
  if (driveMap && s.gps_lat && s.gps_lng) {
    const lat = +s.gps_lat, lng = +s.gps_lng;
    const kmh = speedR;
    const initialZoom = kmh > MAP_HIGHWAY_KMH ? MAP_ZOOM_HIGHWAY
                      : kmh > 3               ? MAP_ZOOM_URBAN
                      :                          MAP_ZOOM_PARKED;
    if (!driveMarker) {
      driveMarker = L.marker([lat, lng], {
        icon: L.divIcon({
          className: '',
          html: '<div class="map-pulse-dot"></div>',
          iconSize: [14, 14],
          iconAnchor: [7, 7],
        }),
      }).addTo(driveMap);
      driveMap.setView([lat, lng], initialZoom);
      _driveMapZoomState.zoomMode = kmh > MAP_HIGHWAY_KMH ? 'highway' : kmh > 3 ? 'urban' : 'parked';
      _driveMapZoomState.lastHighwayMs = kmh > MAP_HIGHWAY_KMH ? Date.now() : 0;
    } else {
      driveMarker.setLatLng([lat, lng]);
      driveMap.panTo([lat, lng], { animate: true, duration: 0.5 });
      _updateMapZoomForSpeed(driveMap, kmh, _driveMapZoomState);
    }
  }
}

// ── HVAC: gesture vertical pra alterar valores no painel Conforto ────────────
// Touch up = aumenta, touch down = diminui. Cada PX_PER_STEP px = 1 step.
// Durante o drag, renderDash ignora updates desse elemento (via classe).
// Após release: envia POST, mantém "hvac-pending" até WS confirmar ou timeout.

const HVAC_DRAG_PX_PER_STEP = 18;
const HVAC_PENDING_TIMEOUT_MS = 30000;
let _hvacDragState = null;
const _hvacPending = {};  // { elementId: { until, expectedVal, fmt } }

// Preenche os pontinhos de ventilação do banco no SVG conforme nível 0..3.
function _updateSeatDots(groupId, lvl) {
  const group = document.getElementById(groupId);
  if (!group) return;
  const v = Math.max(0, Math.min(3, parseInt(lvl, 10) || 0));
  group.querySelectorAll('.cmf-vd').forEach(dot => {
    const row = parseInt(dot.dataset.row, 10);
    dot.classList.remove('on-1', 'on-2', 'on-3');
    if (v >= row) dot.classList.add(`on-${v}`);
  });
}

// Touch handler genérico:
// - touchId: elemento que recebe gestos (pode ser uma zona invisível em SVG)
// - displayId: elemento que mostra preview/pending (default = touchId)
// - onUpdate(val): callback opcional disparado a cada step do drag (ex: pra
//   atualizar pontinhos de ventilação dos bancos em tempo real)
// O pending tracking sempre usa displayId — assim renderDash sabe quem está busy.
function _attachHvacGesture(touchId, control, getCurrent, fmt, min, max, step, axis = 'y', displayId = null, onUpdate = null) {
  const el = document.getElementById(touchId);
  const displayEl = displayId ? document.getElementById(displayId) : el;
  const trackId = displayId || touchId;
  if (!el || el.dataset.hvacGesture === '1') return;
  el.dataset.hvacGesture = '1';
  el.style.touchAction = 'none';
  el.style.userSelect = 'none';
  el.style.webkitUserSelect = 'none';
  if (el.style) el.style.cursor = axis === 'x' ? 'ew-resize' : 'ns-resize';

  function startDrag(clientX, clientY) {
    const cur = getCurrent();
    if (!Number.isFinite(cur)) return false;
    _hvacDragState = {
      elementId: trackId, el: displayEl, touchEl: el, control, fmt, min, max, step, axis,
      startX: clientX, startY: clientY,
      startVal: cur, previewVal: cur,
    };
    if (displayEl) displayEl.classList.add('hvac-dragging');
    return true;
  }
  function moveDrag(clientX, clientY) {
    if (!_hvacDragState || _hvacDragState.touchEl !== el) return;
    const delta = _hvacDragState.axis === 'x'
      ? (clientX - _hvacDragState.startX)
      : (_hvacDragState.startY - clientY);
    const steps = Math.round(delta / HVAC_DRAG_PX_PER_STEP);
    let val = _hvacDragState.startVal + steps * _hvacDragState.step;
    val = Math.max(_hvacDragState.min, Math.min(_hvacDragState.max, val));
    val = Math.round(val / _hvacDragState.step) * _hvacDragState.step;
    if (val === _hvacDragState.previewVal) return;  // sem mudança, evita rerender
    _hvacDragState.previewVal = val;
    if (displayEl) displayEl.textContent = fmt(val);
    if (onUpdate) onUpdate(val);
  }
  async function endDrag() {
    if (!_hvacDragState || _hvacDragState.touchEl !== el) return;
    const s = _hvacDragState;
    _hvacDragState = null;
    const d = displayEl;  // display target

    if (Math.abs(s.previewVal - s.startVal) < 0.001) {
      if (d) d.classList.remove('hvac-dragging');
      return;
    }

    if (d) {
      d.classList.remove('hvac-dragging');
      d.classList.add('hvac-pending');
    }
    _hvacPending[trackId] = {
      until: Date.now() + HVAC_PENDING_TIMEOUT_MS,
      expectedVal: s.previewVal,
      fmt,
      timer: setTimeout(() => {
        if (d) d.classList.remove('hvac-pending');
        delete _hvacPending[trackId];
        showToast('✗ Carro não confirmou em ' + (HVAC_PENDING_TIMEOUT_MS/1000) + 's');
      }, HVAC_PENDING_TIMEOUT_MS),
    };

    try {
      const r = await apiFetch(`/api/hvac/${control}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ value: s.previewVal }),
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok || !data.ok) {
        clearTimeout(_hvacPending[trackId]?.timer);
        if (d) d.classList.remove('hvac-pending');
        delete _hvacPending[trackId];
        showToast('✗ ' + (data.error || `Erro ${r.status}`));
        if (d) d.textContent = fmt(s.startVal);
      } else {
        _hvacApplySyncSideEffect(control, s.previewVal, fmt);
      }
    } catch (err) {
      clearTimeout(_hvacPending[trackId]?.timer);
      if (d) d.classList.remove('hvac-pending');
      delete _hvacPending[trackId];
      showToast('✗ Falha ao enviar');
      if (d) d.textContent = fmt(s.startVal);
    }
  }

  el.addEventListener('touchstart', (e) => {
    if (!startDrag(e.touches[0].clientX, e.touches[0].clientY)) return;
    e.preventDefault();
  }, { passive: false });
  el.addEventListener('touchmove', (e) => {
    // Compara contra touchEl (o elemento que recebe os eventos) e NÃO contra .el
    // (que pode ser o display separado quando displayId é passado, caso dos bancos).
    if (!_hvacDragState || _hvacDragState.touchEl !== el) return;
    moveDrag(e.touches[0].clientX, e.touches[0].clientY);
    e.preventDefault();
  }, { passive: false });
  el.addEventListener('touchend', endDrag);
  el.addEventListener('touchcancel', endDrag);

  // Fallback mouse (desktop)
  el.addEventListener('mousedown', (e) => {
    if (!startDrag(e.clientX, e.clientY)) return;
    e.preventDefault();
    const onMove = (ev) => moveDrag(ev.clientX, ev.clientY);
    const onUp = () => {
      window.removeEventListener('mousemove', onMove);
      window.removeEventListener('mouseup', onUp);
      endDrag();
    };
    window.addEventListener('mousemove', onMove);
    window.addEventListener('mouseup', onUp);
  });
}

// Helper pro renderDash: testa se elemento está em drag/pending pra evitar
// sobrescrever o textContent (que mostra o valor preview ou pending).
function _hvacIsBusy(elementId) {
  if (_hvacDragState && _hvacDragState.elementId === elementId) return true;
  if (_hvacPending[elementId]) return true;
  return false;
}

// Confere se valor recém-chegado via WS bate com o pending (= carro confirmou).
function _hvacCheckPending(elementId, actualVal) {
  const p = _hvacPending[elementId];
  if (!p) return;
  if (Math.abs(actualVal - p.expectedVal) < 0.05) {
    clearTimeout(p.timer);
    delete _hvacPending[elementId];
    const el = document.getElementById(elementId);
    const txt = p.fmt(actualVal);
    if (el) {
      el.classList.remove('hvac-pending');
      if (txt) el.textContent = txt;  // toggles passam fmt vazio — não mexe no DOM
    }
    showToast(txt ? '✓ Aplicado: ' + txt : '✓ Aplicado');
  }
}

// Toggle por tap (booleano) — usado em sync, auto, AC enable, etc.
function _attachHvacToggle(elementId, control, getCurrent, fmtPending) {
  const el = document.getElementById(elementId);
  if (!el || el.dataset.hvacToggle === '1') return;
  el.dataset.hvacToggle = '1';
  el.style.cursor = 'pointer';
  el.style.userSelect = 'none';
  el.style.webkitUserSelect = 'none';
  el.style.webkitTapHighlightColor = 'transparent';

  async function onTap(e) {
    e.preventDefault();
    e.stopPropagation();
    const cur = getCurrent();   // boolean ou 0/1
    const newVal = cur ? 0 : 1;
    el.classList.add('hvac-pending');
    _hvacPending[elementId] = {
      until: Date.now() + HVAC_PENDING_TIMEOUT_MS,
      expectedVal: newVal,
      fmt: fmtPending || (() => ''),
      timer: setTimeout(() => {
        el.classList.remove('hvac-pending');
        delete _hvacPending[elementId];
        showToast('✗ Carro não confirmou em ' + (HVAC_PENDING_TIMEOUT_MS/1000) + 's');
      }, HVAC_PENDING_TIMEOUT_MS),
    };
    try {
      const r = await apiFetch(`/api/hvac/${control}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ value: newVal }),
      });
      const data = await r.json().catch(() => ({}));
      if (!r.ok || !data.ok) {
        clearTimeout(_hvacPending[elementId]?.timer);
        el.classList.remove('hvac-pending');
        delete _hvacPending[elementId];
        showToast('✗ ' + (data.error || `Erro ${r.status}`));
      }
    } catch (err) {
      clearTimeout(_hvacPending[elementId]?.timer);
      el.classList.remove('hvac-pending');
      delete _hvacPending[elementId];
      showToast('✗ Falha ao enviar');
    }
  }
  el.addEventListener('click', onTap);
}

// Side-effect: quando sync está ligado, mudar temp do motorista muda passageiro
// também (e vice-versa). Marca o "outro" elemento como pending pra não dar a
// falsa impressão de que não atualizou — o WS confirma quando o carro publicar.
function _hvacApplySyncSideEffect(control, value, fmt) {
  if (String(state.hvac_sync_enable) !== '1') return;
  if (control !== 'driver_temp' && control !== 'passenger_temp') return;
  const otherId = control === 'driver_temp' ? 'cmf-ac-temp-pass' : 'cmf-ac-temp-drv';
  const otherEl = document.getElementById(otherId);
  if (!otherEl) return;
  // Já tinha pending? cancela o antigo.
  if (_hvacPending[otherId]) clearTimeout(_hvacPending[otherId].timer);
  otherEl.classList.add('hvac-pending');
  otherEl.textContent = fmt(value);
  _hvacPending[otherId] = {
    until: Date.now() + HVAC_PENDING_TIMEOUT_MS,
    expectedVal: value,
    fmt,
    timer: setTimeout(() => {
      otherEl.classList.remove('hvac-pending');
      delete _hvacPending[otherId];
    }, HVAC_PENDING_TIMEOUT_MS),
  };
}

// Setup uma vez quando DOM estiver pronto
window.addEventListener('load', () => {
  setTimeout(() => {
    // ── Temperaturas — drag vertical, step 0.5°C
    _attachHvacGesture('cmf-ac-temp-drv',  'driver_temp',
      () => parseFloat(state.hvac_driver_temp),
      v => `${v.toFixed(1)}°C`, 16, 32, 0.5);
    _attachHvacGesture('cmf-ac-temp-pass', 'passenger_temp',
      () => parseFloat(state.hvac_passenger_temp),
      v => `${v.toFixed(1)}°C`, 16, 32, 0.5);

    // ── Fan speed — drag HORIZONTAL (direita=aumenta, esquerda=reduz), step 1 (0..7)
    _attachHvacGesture('cmf-ac-fan-val',   'fan_speed',
      () => parseInt(state.hvac_fan_speed, 10),
      v => String(v), 0, 7, 1, 'x');

    // ── Ventilação dos bancos — swipe vertical NO BANCO do SVG.
    // Display: label embaixo da cabine. Pontinhos do banco preenchem ao vivo.
    const seatLabels = ['Desligado', 'Fraco', 'Médio', 'Forte'];
    _attachHvacGesture('cmf-seat-drv-touch', 'seat_vent_drv',
      () => parseInt(state.seat_vent_drv, 10),
      v => seatLabels[v] || String(v), 0, 3, 1, 'y', 'cmf-drv-text',
      v => _updateSeatDots('cmf-vent-drv-dots', v));
    _attachHvacGesture('cmf-seat-pass-touch', 'seat_vent_pass',
      () => parseInt(state.seat_vent_pass, 10),
      v => seatLabels[v] || String(v), 0, 3, 1, 'y', 'cmf-pass-text',
      v => _updateSeatDots('cmf-vent-pass-dots', v));

    // ── Tap-to-toggle: sync e auto
    _attachHvacToggle('cmf-ac-sync', 'sync',
      () => String(state.hvac_sync_enable) === '1');
    _attachHvacToggle('cmf-ac-auto', 'auto',
      () => String(state.hvac_auto_enable) === '1');
  }, 300);
});

// ── Weather (Open-Meteo) ─────────────────────────────────────────────────────
// API gratuita sem chave. Cache 30min + raio 5km pra evitar fetch redundante.
let _weatherCache = null;
let _weatherFetching = false;

function _weatherEmoji(code) {
  if (code === 0)       return '☀️';
  if (code <= 3)        return '🌤️';
  if (code <= 48)       return '🌫️';
  if (code <= 67)       return '🌧️';
  if (code <= 77)       return '🌨️';
  if (code <= 82)       return '🌦️';
  if (code <= 99)       return '⛈️';
  return '🌡️';
}

async function _fetchWeather(lat, lng) {
  if (_weatherCache &&
      Math.abs(_weatherCache.lat - lat) < 0.05 &&
      Math.abs(_weatherCache.lng - lng) < 0.05 &&
      Date.now() - _weatherCache.ts < 30 * 60 * 1000) {
    return _weatherCache.data;
  }
  if (_weatherFetching) return null;
  _weatherFetching = true;
  try {
    const url = `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lng}&current=temperature_2m,precipitation,weather_code,wind_speed_10m&timezone=auto`;
    const r = await fetch(url);
    const d = await r.json();
    if (d && d.current) {
      _weatherCache = { ts: Date.now(), lat, lng, data: d.current };
      return d.current;
    }
  } catch (_) {}
  finally { _weatherFetching = false; }
  return null;
}

function _renderWeatherCell(elementId, fallbackTempC, current) {
  const el = document.getElementById(elementId);
  if (!el) return;
  if (current) {
    const t = current.temperature_2m != null ? Math.round(current.temperature_2m) : null;
    const emoji = _weatherEmoji(current.weather_code);
    const precip = +current.precipitation || 0;
    let txt = `${emoji} ${t != null ? t + '°' : '--'}`;
    if (precip > 0.1) txt += ` · ${precip.toFixed(1)}mm`;
    el.textContent = txt;
  } else if (Number.isFinite(fallbackTempC)) {
    el.textContent = '🌡️ ' + fallbackTempC.toFixed(1) + '°';
  } else {
    el.textContent = '--';
  }
}

// Chamado no renderTripCard quando viagem em andamento. Render imediato com
// cache (se houver), e dispara fetch async pra atualizar quando vier resposta.
function _refreshLiveWeather(s) {
  const lat = +s.gps_lat || 0;
  const lng = +s.gps_lng || 0;
  const fallbackTemp = parseFloat(s.outside_temp);
  // Sem GPS, mostra só temp do carro
  if (!lat || !lng) {
    _renderWeatherCell('d-live-weather', fallbackTemp, null);
    return;
  }
  // Renderiza imediato com cache (se válido)
  _renderWeatherCell('d-live-weather', fallbackTemp, _weatherCache?.data || null);
  // Dispara fetch async — atualiza DOM quando vier (não bloqueia)
  _fetchWeather(lat, lng).then(d => {
    if (d) _renderWeatherCell('d-live-weather', fallbackTemp, d);
  });
}

// ── Comparativo lado-a-lado de viagens do mesmo trecho ──────────────────────
window.openCompareModal = function(tripAId) {
  const trips = cachedAutoTrips || [];
  const tripA = trips.find(t => t.tripId === tripAId);
  if (!tripA) return;

  // Recompute "irmãs" do trecho — mesmas regras do effIndex
  function hav(la1, ln1, la2, ln2) {
    const R = 6371000, toRad = d => d * Math.PI / 180;
    const dLat = toRad(la2 - la1), dLng = toRad(ln2 - ln1);
    const a = Math.sin(dLat/2)**2 + Math.cos(toRad(la1))*Math.cos(toRad(la2))*Math.sin(dLng/2)**2;
    return 2 * R * Math.asin(Math.sqrt(a));
  }
  const similar = trips.filter(t => {
    if (t.tripId === tripAId) return false;
    if (!t.startLat || !t.endLat) return false;
    if (Math.abs(t.distKm - tripA.distKm) / tripA.distKm > 0.10) return false;
    if (hav(tripA.startLat, tripA.startLng, t.startLat, t.startLng) > 200) return false;
    if (hav(tripA.endLat,   tripA.endLng,   t.endLat,   t.endLng)   > 200) return false;
    return true;
  }).sort((a, b) => (b.startMs || 0) - (a.startMs || 0));

  document.getElementById('compare-modal')?.remove();
  const modal = document.createElement('div');
  modal.id = 'compare-modal';
  modal.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.88);z-index:9999;overflow-y:auto;padding:16px;-webkit-overflow-scrolling:touch';

  if (similar.length === 0) {
    modal.innerHTML = `<div style="max-width:500px;margin:24px auto;color:#94a3b8;text-align:center">
      <div style="font-size:14px;margin-bottom:12px">Nenhuma outra viagem deste trecho registrada.</div>
      <button onclick="document.getElementById('compare-modal').remove()" style="padding:11px 22px;background:#1e293b;border:1px solid #334155;border-radius:8px;color:#94a3b8;font-size:13px;cursor:pointer">Fechar</button>
    </div>`;
    document.body.appendChild(modal);
    return;
  }

  const aLabel = (renameTracking[String(tripA.tripId)]?.name) || tripA.name || getAutoName(tripA) || 'Viagem';
  const aDate  = fmtDate(tripA.startMs);
  let rows = '';
  for (const t of similar.slice(0, 30)) {
    const nm = (renameTracking[String(t.tripId)]?.name) || t.name || getAutoName(t) || 'Viagem';
    const dt = fmtDate(t.startMs);
    rows += `<button onclick="showComparison('${tripA.tripId}','${t.tripId}')"
      style="width:100%;background:#0f172a;border:1px solid #1e293b;border-radius:8px;padding:10px 12px;text-align:left;cursor:pointer;color:#e2e8f0;font-size:12px;line-height:1.4;margin-bottom:6px">
      <div><strong>${nm}</strong></div>
      <div style="color:#64748b;font-size:11px;margin-top:2px">${dt} · ${f1(t.distKm || 0)} km</div>
    </button>`;
  }

  modal.innerHTML = `<div style="max-width:500px;margin:0 auto">
    <div style="color:#22d3ee;font-weight:700;font-size:14px;margin-bottom:12px">🔀 Comparar viagens</div>
    <div style="background:#0f172a;border:1px solid #22d3ee44;border-radius:10px;padding:10px 12px;margin-bottom:14px">
      <div style="font-size:10px;color:#64748b;margin-bottom:4px;letter-spacing:.06em">VIAGEM A</div>
      <div style="font-size:13px;color:#e2e8f0"><strong>${aLabel}</strong></div>
      <div style="font-size:11px;color:#64748b;margin-top:2px">${aDate} · ${f1(tripA.distKm || 0)} km</div>
    </div>
    <div style="font-size:10px;color:#64748b;letter-spacing:.06em;margin-bottom:8px">ESCOLHA A VIAGEM B (mesmo trecho)</div>
    ${rows}
    <button onclick="document.getElementById('compare-modal').remove()"
      style="width:100%;margin-top:8px;padding:11px;background:#1e293b;border:1px solid #334155;border-radius:8px;color:#94a3b8;font-size:13px;cursor:pointer">
      Cancelar
    </button>
  </div>`;
  document.body.appendChild(modal);
};

window.showComparison = function(tripAId, tripBId) {
  const trips = cachedAutoTrips || [];
  const a = trips.find(t => t.tripId === tripAId);
  const b = trips.find(t => t.tripId === tripBId);
  if (!a || !b) return;

  function metric(label, va, vb, fmt, bigger='better') {
    const aN = +va, bN = +vb;
    const validA = Number.isFinite(aN);
    const validB = Number.isFinite(bN);
    let aCls = '', bCls = '';
    if (validA && validB && Math.abs(aN - bN) > 0.001 && bigger !== 'neutral') {
      const aWins = bigger === 'better' ? aN > bN : aN < bN;
      aCls = aWins ? 'cmp-win' : 'cmp-loss';
      bCls = aWins ? 'cmp-loss' : 'cmp-win';
    }
    return `<div class="cmp-metric">
      <div class="cmp-metric-label">${label}</div>
      <div class="cmp-metric-vals">
        <span class="cmp-val ${aCls}">${validA ? fmt(aN) : '--'}</span>
        <span class="cmp-val ${bCls}">${validB ? fmt(bN) : '--'}</span>
      </div>
    </div>`;
  }

  const KWH_PER_L = 8.9;
  const kmL = (t) => (t.distKm > 0.1 && ((t.netKwh || 0) > 0 || (t.fuelL || 0) > 0.001))
    ? t.distKm / ((t.netKwh || 0) / KWH_PER_L + (t.fuelL || 0)) : NaN;
  const kwh100 = (t) => t.distKm > 0.1 && (t.netKwh || 0) > 0 ? (t.netKwh / t.distKm) * 100 : NaN;
  const avgKmh = (t) => (t.timeSec || 0) > 0 ? t.distKm / (t.timeSec / 3600) : NaN;
  const regenRatio = (t) => (t.energyKwh || 0) > 0.05 ? (t.regenKwh || 0) / t.energyKwh * 100 : NaN;
  const elecPct = (t) => t.distKm > 0 ? (1 - (t.hybridDistKm || 0) / t.distKm) * 100 : NaN;
  const ecoScore = (t) => {
    // Inline: usa as mesmas regras do _computeEcoScore
    const dist = +t.distKm || 0; if (dist < 1 || (+t.timeSec || 0) < 30) return NaN;
    const ep = Math.max(0, Math.min(1, 1 - ((t.hybridDistKm || 0) / dist)));
    const rr = (t.energyKwh || 0) > 0.05 ? (t.regenKwh || 0) / t.energyKwh : 0;
    const av = dist / ((+t.timeSec || 0) / 3600);
    const s1 = ep * 35, s2 = Math.min(25, rr * 100);
    let s3 = av >= 30 && av <= 70 ? 15 : av >= 20 && av <= 90 ? 8 : av >= 10 && av <= 110 ? 4 : 0;
    const s4 = Math.max(0, 10 - ((+t.maxPowerPct || 0) / 10));
    return Math.round(s1 + s2 + s3 + s4 + 7.5);
  };

  const aName = (renameTracking[String(a.tripId)]?.name) || a.name || getAutoName(a) || 'Viagem A';
  const bName = (renameTracking[String(b.tripId)]?.name) || b.name || getAutoName(b) || 'Viagem B';

  const sec2dur = (s) => {
    const m = Math.round(s / 60), h = Math.floor(m / 60), rem = m % 60;
    return h > 0 ? `${h}h ${rem}m` : `${m} min`;
  };

  const html = `<div style="max-width:600px;margin:0 auto">
    <div style="color:#22d3ee;font-weight:700;font-size:14px;margin-bottom:14px">🔀 Comparativo</div>
    <div class="cmp-headers">
      <div class="cmp-head">
        <div class="cmp-head-name">${aName}</div>
        <div class="cmp-head-date">${fmtDate(a.startMs)}</div>
      </div>
      <div class="cmp-vs">VS</div>
      <div class="cmp-head">
        <div class="cmp-head-name">${bName}</div>
        <div class="cmp-head-date">${fmtDate(b.startMs)}</div>
      </div>
    </div>
    <div class="cmp-metrics">
      ${metric('Distância',     a.distKm,           b.distKm,           v => f1(v) + ' km',    'neutral')}
      ${metric('Duração',       a.timeSec,          b.timeSec,          v => sec2dur(v),       'less')}
      ${metric('Vel. média',    avgKmh(a),          avgKmh(b),          v => v.toFixed(0) + ' km/h', 'neutral')}
      ${metric('Vel. máxima',   a.maxSpeedKmh,      b.maxSpeedKmh,      v => v.toFixed(0) + ' km/h', 'neutral')}
      ${metric('SOC início',    a.startSocPct,      b.startSocPct,      v => v.toFixed(0) + '%',    'neutral')}
      ${metric('SOC fim',       a.endSocPct,        b.endSocPct,        v => v.toFixed(0) + '%',    'better')}
      ${metric('% elétrico',    elecPct(a),         elecPct(b),         v => v.toFixed(0) + '%',    'better')}
      ${metric('Energia consumida', a.energyKwh,    b.energyKwh,        v => v.toFixed(2) + ' kWh', 'less')}
      ${metric('Energia regenerada', a.regenKwh,    b.regenKwh,         v => v.toFixed(2) + ' kWh', 'better')}
      ${metric('% regen',       regenRatio(a),      regenRatio(b),      v => v.toFixed(0) + '%',    'better')}
      ${metric('Combustível',   a.fuelL,            b.fuelL,            v => v.toFixed(2) + ' L',   'less')}
      ${metric('kWh/100km',     kwh100(a),          kwh100(b),          v => v.toFixed(1),          'less')}
      ${metric('km/L eq',       kmL(a),             kmL(b),             v => v.toFixed(1),          'better')}
      ${metric('Eco score',     ecoScore(a),        ecoScore(b),        v => String(Math.round(v)), 'better')}
    </div>
    <button onclick="document.getElementById('compare-modal').remove()"
      style="width:100%;margin-top:14px;padding:11px;background:#1e293b;border:1px solid #334155;border-radius:8px;color:#94a3b8;font-size:13px;cursor:pointer">
      Fechar
    </button>
  </div>`;

  let modal = document.getElementById('compare-modal');
  if (!modal) {
    modal = document.createElement('div');
    modal.id = 'compare-modal';
    modal.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.88);z-index:9999;overflow-y:auto;padding:16px;-webkit-overflow-scrolling:touch';
    document.body.appendChild(modal);
  }
  modal.innerHTML = html;
};

// ── Manutenções: card do dash + admin ──────────────────────────────────────
let _maintCache = null;   // { intervals, history, next, current_odometer_km }
let _maintTimer = null;

async function _loadMaintenance() {
  try {
    const r = await apiFetch('/api/maintenance');
    if (!r.ok) return;
    _maintCache = await r.json();
    _renderMaintCard();
  } catch (_) {}
}

function _renderMaintCard() {
  const card = document.getElementById('d-maint-card');
  const list = document.getElementById('d-maint-list');
  if (!card || !list || !_maintCache) return;

  const items = _maintCache.next || [];
  if (!items.length) { card.style.display = 'none'; return; }
  card.style.display = '';

  const f0 = (n) => Math.round(n).toLocaleString('pt-BR');
  list.innerHTML = items.map(it => {
    // Texto principal: km e/ou dias, conforme configurado
    const parts = [];
    if (it.has_km) {
      const rk = it.remaining_km;
      parts.push(rk <= 0 ? `Atrasada ${f0(Math.abs(rk))} km` : `em ${f0(rk)} km`);
    }
    if (it.has_time) {
      const rd = it.remaining_days;
      parts.push(rd <= 0 ? `${Math.abs(rd)} dias atrasada` : `em ${rd} ${rd === 1 ? 'dia' : 'dias'}`);
    }
    const remTxt = parts.join(' · ') || '—';

    // Barra: usa o menor dos percentuais (km ou tempo) — mais agressivo visual
    let pctKm = 0, pctTime = 0;
    if (it.has_km) {
      const span = it.every_km, consumed = Math.max(0, Math.min(span, span - it.remaining_km));
      pctKm = span > 0 ? (consumed / span) * 100 : 0;
    }
    if (it.has_time && it.every_months > 0) {
      const totalDays = it.every_months * 30;
      const consumed = Math.max(0, Math.min(totalDays, totalDays - it.remaining_days));
      pctTime = totalDays > 0 ? (consumed / totalDays) * 100 : 0;
    }
    const pct = Math.min(100, Math.max(pctKm, pctTime));

    const lastDate = it.last_date_ms
      ? new Date(it.last_date_ms).toLocaleDateString('pt-BR', { day:'2-digit', month:'2-digit', year:'numeric' })
      : '--';
    const nextDateStr = it.next_date_ms
      ? new Date(it.next_date_ms).toLocaleDateString('pt-BR', { day:'2-digit', month:'2-digit', year:'numeric' })
      : '';
    const nextLine = it.has_km
      ? `Próxima: ${f0(it.next_km)} km${nextDateStr ? ' ou ' + nextDateStr : ''}`
      : `Próxima: ${nextDateStr}`;

    return `<div class="maint-row ${it.status}">
      <span class="maint-icon">${it.icon || '🔧'}</span>
      <div class="maint-body">
        <div class="maint-body-row1">
          <span class="maint-label">${it.label}</span>
          <span class="maint-rem-km">${remTxt}</span>
        </div>
        <div class="maint-bar-track"><div class="maint-bar-fill" style="width:${pct.toFixed(1)}%"></div></div>
        <div class="maint-body-row2">
          <span>Última: ${f0(it.last_km)} km · ${lastDate}</span>
          <span>${nextLine}</span>
        </div>
      </div>
    </div>`;
  }).join('');
}

// Refresh inicial + a cada 5min, e quando odometer mudar significativamente
function _initMaintenance() {
  _loadMaintenance();
  if (_maintTimer) clearInterval(_maintTimer);
  _maintTimer = setInterval(_loadMaintenance, 5 * 60 * 1000);
}
window.addEventListener('load', () => setTimeout(_initMaintenance, 800));

// ── Admin: gerenciar manutenções ─────────────────────────────────────────
window.openMaintAdmin = async function() {
  await _loadMaintenance();
  if (!_maintCache) { showToast('Erro ao carregar manutenções'); return; }

  document.getElementById('maint-admin-modal')?.remove();
  const modal = document.createElement('div');
  modal.id = 'maint-admin-modal';
  modal.style.cssText = 'position:fixed;inset:0;background:rgba(0,0,0,.92);z-index:9999;overflow-y:auto;padding:16px;-webkit-overflow-scrolling:touch';

  const odom = _maintCache.current_odometer_km || 0;
  const intervalsHtml = (_maintCache.intervals || []).map(itv => {
    const sub = [];
    if (+itv.every_km     > 0) sub.push(`a cada ${itv.every_km.toLocaleString('pt-BR')} km`);
    if (+itv.every_months > 0) sub.push(`${itv.every_months} ${itv.every_months === 1 ? 'mês' : 'meses'}`);
    const alerts = [];
    if (+itv.every_km     > 0) alerts.push(`${itv.alert_km || 500} km antes`);
    if (+itv.every_months > 0) alerts.push(`${itv.alert_days || 15} dias antes`);
    return `
    <div class="maint-admin-item">
      <div style="flex:1;min-width:0">
        <div class="maint-admin-name">${itv.icon || '🔧'} ${itv.label}</div>
        <div class="maint-admin-sub">${sub.join(' · ')}${alerts.length ? ' · alerta ' + alerts.join(' / ') : ''}</div>
      </div>
      <div class="maint-admin-actions">
        <button onclick="editMaintInterval('${itv.id}')">✏️</button>
        <button onclick="deleteMaintInterval('${itv.id}','${itv.label.replace(/'/g,'')}')">🗑</button>
      </div>
    </div>`;
  }).join('');

  const histHtml = (_maintCache.history || []).map(h => {
    const itv = _maintCache.intervals.find(i => i.id === h.type_id);
    const dt = new Date(h.date_ms).toLocaleDateString('pt-BR', { day:'2-digit', month:'2-digit', year:'numeric' });
    return `<div class="maint-admin-item">
      <div style="flex:1;min-width:0">
        <div class="maint-admin-name">${itv?.icon || '🔧'} ${itv?.label || h.type_id} · ${h.odometer_km.toLocaleString('pt-BR')} km</div>
        <div class="maint-admin-sub">${dt}${h.notes ? ' · ' + h.notes : ''}</div>
      </div>
      <div class="maint-admin-actions">
        <button onclick="editMaintHistory('${h.id}')">✏️</button>
        <button onclick="deleteMaintHistory('${h.id}')">🗑</button>
      </div>
    </div>`;
  }).join('');

  modal.innerHTML = `<div style="max-width:560px;margin:0 auto">
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:14px">
      <div style="color:#4ade80;font-weight:700;font-size:14px">🔧 Manutenções</div>
      <button onclick="document.getElementById('maint-admin-modal').remove()" style="background:none;border:none;color:#64748b;font-size:22px;cursor:pointer">✕</button>
    </div>
    <div style="font-size:11px;color:#64748b;margin-bottom:14px">Odômetro atual: <strong style="color:#e2e8f0">${odom.toLocaleString('pt-BR')} km</strong></div>

    <div style="font-size:10px;color:#475569;letter-spacing:.06em;margin-bottom:6px">REGISTRAR MANUTENÇÃO FEITA</div>
    <div class="maint-admin-item" style="display:block">
      <select id="maint-new-type" style="width:100%;padding:10px;background:#0c1019;border:1px solid #1e293b;border-radius:6px;color:#e2e8f0;font-size:12px;margin-bottom:8px">
        ${(_maintCache.intervals || []).map(i => `<option value="${i.id}">${i.icon} ${i.label}</option>`).join('')}
      </select>
      <input id="maint-new-odo" type="number" placeholder="Odômetro km (ex: ${odom > 0 ? Math.round(odom) : 30000})" style="width:100%;padding:10px;background:#0c1019;border:1px solid #1e293b;border-radius:6px;color:#e2e8f0;font-size:12px;margin-bottom:8px" value="${odom > 0 ? Math.round(odom) : ''}">
      <input id="maint-new-date" type="date" value="${new Date().toISOString().slice(0,10)}" style="width:100%;padding:10px;background:#0c1019;border:1px solid #1e293b;border-radius:6px;color:#e2e8f0;font-size:12px;margin-bottom:8px">
      <input id="maint-new-notes" type="text" placeholder="Observações (opcional)" style="width:100%;padding:10px;background:#0c1019;border:1px solid #1e293b;border-radius:6px;color:#e2e8f0;font-size:12px;margin-bottom:10px">
      <button onclick="addMaintHistory()" style="width:100%;padding:11px;background:#0d2b1a;border:1px solid #166534;color:#4ade80;border-radius:8px;cursor:pointer;font-size:13px;font-weight:600">+ Registrar</button>
    </div>

    <div style="font-size:10px;color:#475569;letter-spacing:.06em;margin:18px 0 6px">INTERVALOS (TIPOS)</div>
    ${intervalsHtml}
    <button onclick="editMaintInterval(null)" style="width:100%;padding:11px;background:#1e293b;border:1px solid #334155;color:#94a3b8;border-radius:8px;cursor:pointer;font-size:12px;margin-bottom:18px">+ Novo intervalo</button>

    <div style="font-size:10px;color:#475569;letter-spacing:.06em;margin-bottom:6px">HISTÓRICO</div>
    ${histHtml || '<div style="color:#475569;font-size:12px;text-align:center;padding:12px">Nenhum registro.</div>'}

    <button onclick="document.getElementById('maint-admin-modal').remove()" style="width:100%;margin-top:14px;padding:11px;background:#1e293b;border:1px solid #334155;color:#94a3b8;border-radius:8px;cursor:pointer;font-size:13px">Fechar</button>
  </div>`;
  document.body.appendChild(modal);
};

window.addMaintHistory = async function() {
  const type_id = document.getElementById('maint-new-type').value;
  const odometer_km = parseFloat(document.getElementById('maint-new-odo').value);
  const dateStr = document.getElementById('maint-new-date').value;
  const notes = document.getElementById('maint-new-notes').value;
  if (!(odometer_km > 0)) { showToast('Informe o odômetro'); return; }
  const date_ms = dateStr ? new Date(dateStr).getTime() : Date.now();
  try {
    const r = await apiFetch('/api/maintenance/history', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ type_id, odometer_km, date_ms, notes }),
    });
    const d = await r.json();
    if (!r.ok || !d.ok) throw new Error(d.error || 'erro');
    showToast('✓ Manutenção registrada');
    await _loadMaintenance();
    openMaintAdmin();
  } catch (e) { showToast('✗ ' + e.message); }
};

window.deleteMaintHistory = async function(id) {
  if (!confirm('Apagar este registro?')) return;
  try {
    const r = await apiFetch('/api/maintenance/history/' + id, { method: 'DELETE' });
    if (!r.ok) throw new Error('erro');
    await _loadMaintenance();
    openMaintAdmin();
  } catch (_) { showToast('✗ Falha ao apagar'); }
};

window.editMaintHistory = async function(id) {
  const rec = (_maintCache?.history || []).find(h => h.id === id);
  if (!rec) return;
  const newOdo = parseFloat(prompt('Novo odômetro (km):', Math.round(rec.odometer_km)));
  if (!(newOdo > 0)) return;
  const curDate = new Date(rec.date_ms || Date.now()).toISOString().slice(0, 10);
  const newDateStr = prompt('Nova data (YYYY-MM-DD):', curDate);
  if (!newDateStr) return;
  const newDateMs = new Date(newDateStr).getTime();
  if (!(newDateMs > 0)) { showToast('✗ Data inválida'); return; }
  const newNotes = prompt('Observações:', rec.notes || '');
  try {
    const r = await apiFetch('/api/maintenance/history/' + id, {
      method: 'PATCH',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ odometer_km: newOdo, date_ms: newDateMs, notes: newNotes || '' }),
    });
    const d = await r.json();
    if (!r.ok || !d.ok) throw new Error(d.error || 'erro');
    showToast('✓ Registro atualizado — próximas recalculadas');
    await _loadMaintenance();
    openMaintAdmin();
  } catch (e) { showToast('✗ ' + e.message); }
};

window.editMaintInterval = async function(id) {
  const existing = id ? (_maintCache?.intervals || []).find(i => i.id === id) : null;
  const newId    = existing ? id : prompt('ID curto (ex: oleo, freios)', '');
  if (!newId) return;
  const label    = prompt('Nome', existing?.label || '');
  if (!label) return;
  const everyKm    = parseFloat(prompt('Intervalo em KM (0 pra não usar)', existing?.every_km || 12000)) || 0;
  const everyMths  = parseFloat(prompt('Intervalo em MESES (0 pra não usar)', existing?.every_months || 12)) || 0;
  if (!(everyKm > 0) && !(everyMths > 0)) {
    showToast('Informe ao menos um (km ou meses)'); return;
  }
  const alertKm   = everyKm > 0   ? parseFloat(prompt('Alertar quantos km antes?',   existing?.alert_km   || 1000)) || 500 : 0;
  const alertDays = everyMths > 0 ? parseFloat(prompt('Alertar quantos dias antes?', existing?.alert_days || 15))   || 15  : 0;
  const icon     = prompt('Ícone (emoji)', existing?.icon || '🔧') || '🔧';
  try {
    const r = await apiFetch('/api/maintenance/intervals', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ id: newId.trim(), label, every_km: everyKm, every_months: everyMths, alert_km: alertKm, alert_days: alertDays, icon }),
    });
    const d = await r.json();
    if (!r.ok || !d.ok) throw new Error(d.error || 'erro');
    showToast('✓ Intervalo salvo');
    await _loadMaintenance();
    openMaintAdmin();
  } catch (e) { showToast('✗ ' + e.message); }
};

window.deleteMaintInterval = async function(id, label) {
  if (!confirm(`Apagar o intervalo "${label}"?\nO histórico relacionado não será apagado.`)) return;
  try {
    const r = await apiFetch('/api/maintenance/intervals/' + encodeURIComponent(id), { method: 'DELETE' });
    if (!r.ok) throw new Error('erro');
    await _loadMaintenance();
    openMaintAdmin();
  } catch (_) { showToast('✗ Falha ao apagar'); }
};

// ── PWA Shortcuts — dispara ação ao abrir o app via atalho do iOS ─────────
// O manifest.json define ?shortcut=lock_open, ?shortcut=ac_on, etc.
// Esse handler intercepta o param ao carregar e dispara a ação correspondente.
window.addEventListener('load', () => {
  const params = new URLSearchParams(location.search);
  const sc = params.get('shortcut');
  if (!sc) return;
  // Limpa a URL (não queremos repetir ao recarregar)
  history.replaceState({}, '', location.pathname);
  setTimeout(() => {
    if (sc === 'drive') {
      const btn = document.querySelector('[data-panel="drive"]');
      btn?.click();
      return;
    }
    // Ações remotas: lock_open, ac_on, engine_on, etc.
    const ACTION_LABELS = {
      lock_open: 'Destrancar portas',
      ac_on:     'Ligar AC',
      engine_on: 'Ligar motor',
    };
    const label = ACTION_LABELS[sc];
    if (label && typeof sendRemoteAction === 'function') {
      sendRemoteAction(sc, label);
    }
  }, 800);  // dá tempo do WS conectar
});

// ── Tema (Dark / Light / Auto) ──────────────────────────────────────────────
// Persistido em localStorage. "auto" segue prefers-color-scheme do iOS.
function _getThemePref() {
  return localStorage.getItem('eco_theme') || 'dark';
}
function _applyTheme() {
  const pref = _getThemePref();
  const root = document.documentElement;
  root.classList.remove('theme-light', 'theme-dark');
  let effective = pref;
  if (pref === 'auto') {
    effective = matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark';
  }
  if (effective === 'light') root.classList.add('theme-light');
  else                       root.classList.add('theme-dark');
}
window.setTheme = function(pref) {
  localStorage.setItem('eco_theme', pref);
  _applyTheme();
  showToast('🎨 Tema: ' + pref);
  // Atualiza visual dos botões no admin
  document.querySelectorAll('[data-theme-btn]').forEach(b => {
    b.classList.toggle('active', b.dataset.themeBtn === pref);
  });
};
// Aplica no boot e a cada mudança de prefers-color-scheme (modo auto)
_applyTheme();
matchMedia('(prefers-color-scheme: light)').addEventListener('change', () => {
  if (_getThemePref() === 'auto') _applyTheme();
});
