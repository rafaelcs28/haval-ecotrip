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
    if (changed) { _saveRenameTracking(); renderAutoTrips(); renderHistory(); }
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
    const r = await fetch(
      `https://nominatim.openstreetmap.org/reverse?format=json&lat=${lat}&lon=${lng}&zoom=10`,
      { headers: { 'Accept-Language': 'pt-BR' } }
    );
    const d = await r.json();
    const a = d.address || {};
    const city  = a.city || a.town || a.village || a.municipality || a.county || '';
    const state = a.state || '';
    geoCache[key] = city ? (state ? `${city}, ${state}` : city) : (state || '');
  } catch (_) {
    geoCache[key] = '';  // falhou — marca como tentado para não repetir
  }
  try { sessionStorage.setItem('geoCache', JSON.stringify(geoCache)); } catch (_) {}
  // Atualiza lista: sempre que o painel auto estiver visível (nomes automáticos) ou busca ativa
  if (document.querySelector('#panel-auto.active') || filterState.auto.search.trim()) renderAutoTrips();
  // Próximo item com 1.1s de intervalo (respeita política do Nominatim)
  if (_geoQueue.length) _geoTimer = setTimeout(_processGeoQueue, 1100);
}

// Retorna "CidadeOrigem → CidadeDestino" se forem diferentes e o trip não tiver nome.
// Usa apenas o primeiro segmento do geocode (antes da vírgula) para ficar compacto.
function getAutoName(t) {
  if (t.name) return null; // servidor já definiu nome completo
  const knownStart = t.knownStart || null;
  const knownEnd   = t.knownEnd   || null;
  const startFull  = geoCache[t.tripId];
  const endFull    = geoCache[t.tripId + ':end'];
  const startCity  = knownStart || (startFull ? startFull.split(',')[0].trim() : null);
  const endCity    = knownEnd   || (endFull   ? endFull.split(',')[0].trim()   : null);
  if (!startCity || !endCity) return null;
  if (!knownStart && !knownEnd && startCity === endCity) return null;
  return `${startCity} → ${endCity}`;
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
  ['sc-dados-body', 'sc-charge-limit-body', 'sc-backup-body', 'sc-servidor-body'].forEach(bodyId => {
    if (localStorage.getItem('sc_' + bodyId) !== '1') return;
    const body   = document.getElementById(bodyId);
    const btnId  = bodyId.replace('-body', '-btn');
    const btn    = document.getElementById(btnId);
    if (body) body.style.display = 'none';
    if (btn)  btn.textContent    = '▼';
    const header = btn?.closest('.sc-header');
    if (header) header.style.marginBottom = '0';
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
        const anyOpen = vals.some(v => String(v) !== '1');
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
        return String(v) === '3'
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
  if (callback) callback();
  // Leaflet precisa recalcular o tamanho ao tornar-se visível
  if (activePanel === 'dash' && dashMap) {
    setTimeout(() => dashMap.invalidateSize(), 50);
  }
}

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
        renderAll();
        try { localStorage.setItem('ecotrip_state', JSON.stringify({ state, ts: lastUpdateMs })); } catch(_) {}
      } else if (msg.type === 'AUTH_ERROR') {
        ws.close();
        showLogin('Senha incorreta ou expirada.');
        return;
      } else if (msg.type === 'charge_limit_result') {
        _onChargeLimitResult(msg.data?.result || '');
      } else if (msg.type === 'new_autotrip') {
        // Nova viagem automática — sincroniza só o novo, sem derrubar o cache inteiro
        const autoPanel = document.getElementById('panel-auto');
        syncAllCache({ silent: true }).then(() => {
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
  charges: { active: 'today', customFrom: '', customTo: '', location: null },
  hist:    { active: 'all',   customFrom: '', customTo: '', search: '' },
  auto:    { active: 'today', customFrom: '', customTo: '', search: '' },
  logs:    { active: 'all',   type: 'all',   customFrom: '', customTo: '' },
};
let cachedCharges = null;
let cachedEvents  = null;
let cachedTrips   = null;
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
  const totals = { trips: 0, auto: 0, charges: 0 };
  try {
    if (!silent) _syncProgressShow('⟳ Sincronizando…');

    // Trips manuais
    const lastTs   = (await _idbGetMeta('lastTripTs')) || '';
    const newTrips = await apiFetch('/api/trips' + (lastTs ? '?since=' + encodeURIComponent(lastTs) : ''))
      .then(r => r.json()).catch(() => []);
    if (Array.isArray(newTrips) && newTrips.length) {
      await _idbPutMany('trips', newTrips);
      totals.trips = newTrips.length;
      const maxTs = [...newTrips].map(t => t.timestamp || '').sort().pop();
      if (maxTs) await _idbSetMeta('lastTripTs', maxTs);
      if (!silent) _syncProgressShow('⟳ ' + totals.trips + ' trip' + (totals.trips !== 1 ? 's' : '') + ' baixado' + (totals.trips !== 1 ? 's' : '') + '…');
    }
    cachedTrips = (await _idbGetAll('trips'))
      .sort((a, b) => (b.timestamp || '') > (a.timestamp || '') ? 1 : -1);

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
  if (tabId === 'hist') renderHistory();
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
  const search = (tabId === 'hist' || tabId === 'auto') ? `
<div class="filter-search">
  <span class="filter-search-icon">🔍</span>
  <input type="search" id="filter-search-${tabId}" class="filter-search-input"
    placeholder="Buscar por nome…" value="${(f.search || '').replace(/"/g,'&quot;')}"
    oninput="setSearchQuery('${tabId}', this.value)">
</div>` : '';
  return `<div class="filter-chips">${c('all','Tudo')}${c('today','Hoje')}${c('7d','7 dias')}${c('30d','30 dias')}${c('month','Mês')}${c('custom','Custom')}</div>${dates}${search}`;
}

// ── Render ────────────────────────────────────────────────────────────────────
function renderAll() {
  renderDash();
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

  const usableKwh  = Math.max(0, (soc - EV_MIN_SOC) / 100 * BATT_KWH);
  const evKmCalc   = Math.round(usableKwh / (avgKwh100 / 100));
  const realEvKm   = s.range_ev_km || 0;   // valor real do sensor HA (0 = não disponível)
  const evRangeEl  = document.getElementById('d-ev-range');
  if (evRangeEl) {
    if (realEvKm > 0) {
      evRangeEl.style.display = '';
      setText('d-ev-km', realEvKm);
    } else if (soc > EV_MIN_SOC) {
      evRangeEl.style.display = '';
      setText('d-ev-km', '~' + evKmCalc);
    } else {
      evRangeEl.style.display = 'none';
    }
  }

  // Combustível (tank 51L)
  const TANK_CAP = 51;
  const tankNow = s.trip_a?.tank_now_l > 0 ? s.trip_a.tank_now_l
                : s.trip_b?.tank_now_l > 0 ? s.trip_b.tank_now_l : 0;
  const fuelPct = tankNow > 0 ? Math.min(100, (tankNow / TANK_CAP) * 100) : 0;
  setText('d-fuel', tankNow > 0 ? f1(tankNow) + ' L  (' + fuelPct.toFixed(0) + '%)' : '--');
  const fuelBar = document.getElementById('d-fuel-bar');
  if (fuelBar) fuelBar.style.width = Math.max(0, Math.min(100, fuelPct)) + '%';

  // Autonomia térmica: real (sensor HA) → fallback estimada
  const fuelKmCalc   = tankNow > 0 ? Math.round(tankNow * avgKmL) : 0;
  const realIceKm    = s.range_ice_km || 0;
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
  const panelDash = document.getElementById('panel-dash');
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

  // Teto solar (fechado = '3')
  carLayer('cl-sunroof', s.sunroof != null && s.sunroof !== '3' && s.sunroof !== 3);

  // AC
  const acOn = s.ac_state === 'on';
  carLayer('cl-ac-left',    acOn);
  carLayer('cl-ac-right',   acOn);
  carLayer('cl-ventilacao', acOn);
  const acChip = document.getElementById('d-ac-chip');
  if (acChip) acChip.style.color = acOn ? '#22d3ee' : '#475569';

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
  function renderTyre(pos, psi, tempC) {
    const psiEl  = document.getElementById(`d-tyre-${pos}-psi`);
    const tempEl = document.getElementById(`d-tyre-${pos}-temp`);
    const card   = document.getElementById(`d-tyre-${pos}`);
    if (!psiEl) return;
    const isLeft = pos === 'fl' || pos === 'rl';
    if (psi > 0) {
      psiEl.textContent = psi.toFixed(1);
      const tier = psi < 25 || psi > 40 ? 'critical'
                 : psi < 30             ? 'low'
                 :                        'ok';
      const cfg = {
        ok:       { color: '#22d3ee', borderColor: '#0e7490', bg: 'rgba(7,14,26,0.82)'  },
        low:      { color: '#fbbf24', borderColor: '#b45309', bg: 'rgba(30,18,0,0.82)'  },
        critical: { color: '#f87171', borderColor: '#dc2626', bg: 'rgba(50,8,8,0.82)'   },
      }[tier];
      psiEl.style.color = cfg.color;
      if (card) {
        if (isLeft) card.style.borderLeft  = `3px solid ${cfg.borderColor}`;
        else        card.style.borderRight = `3px solid ${cfg.borderColor}`;
        card.style.background = cfg.bg;
      }
    } else {
      psiEl.textContent = '--';
      psiEl.style.color = '#475569';
      if (card) {
        if (isLeft) card.style.borderLeft  = '3px solid #1e293b';
        else        card.style.borderRight = '3px solid #1e293b';
        card.style.background = 'rgba(7,14,26,0.82)';
      }
    }
    if (tempEl) tempEl.textContent = tempC > 0 ? `${tempC}°` : '--°';
  }
  renderTyre('fl', s.tyre_pressure_fl, s.tyre_temp_fl);
  renderTyre('fr', s.tyre_pressure_fr, s.tyre_temp_fr);
  renderTyre('rl', s.tyre_pressure_rl, s.tyre_temp_rl);
  renderTyre('rr', s.tyre_pressure_rr, s.tyre_temp_rr);

  // Velocímetro + trem de força — ambos dentro de d-powertrain, visível só com motor ligado
  const spdVal = document.getElementById('d-speed-val');
  if (engOn && spdVal) {
    const spd = Math.round(s.speed_kmh || 0);
    spdVal.textContent    = spd;
    spdVal.style.fontSize = spd >= 100 ? '13px' : spd >= 10 ? '18px' : '20px';
  }

  // Trem de força — barra de potência + kW elétrico + RPM ICE
  const pwrEl = document.getElementById('d-powertrain');
  if (pwrEl) {
    pwrEl.style.display = engOn ? 'block' : 'none';
    if (engOn) {
      const pct      = Math.max(-100, Math.min(100, Math.round(s.battery_power_pct || 0)));
      const isRegen  = pct < 0;
      const absPct   = Math.abs(pct);
      const regenBar   = document.getElementById('d-pwr-regen-bar');
      const consumeBar = document.getElementById('d-pwr-consume-bar');
      if (regenBar)   regenBar.style.width   = isRegen  ? (absPct / 2) + '%' : '0';
      if (consumeBar) consumeBar.style.width  = !isRegen ? (absPct / 2) + '%' : '0';
      const pctEl = document.getElementById('d-pwr-pct');
      if (pctEl) {
        pctEl.textContent = (pct > 0 ? '+' : '') + pct + '%';
        pctEl.style.color = isRegen ? 'var(--neon)' : '#fb923c';
      }
      const kw = s.motor_power_kw || 0;
      const kwEl = document.getElementById('d-pwr-kw');
      if (kwEl) {
        kwEl.textContent  = kw !== 0 ? Math.abs(kw).toFixed(1) : '--';
        kwEl.style.color  = kw < 0 ? 'var(--neon)' : kw > 0 ? '#4ade80' : '#475569';
      }
      const rpmEl = document.getElementById('d-pwr-rpm');
      if (rpmEl) {
        const rpm = s.engine_rpm || 0;
        rpmEl.textContent = rpm > 0 ? rpm.toLocaleString('pt-BR') : '--';
        rpmEl.style.color = rpm > 0 ? '#fb923c' : '#475569';
      }

      // Modo de condução — baseado em batt_power_pct (0–100)
      const driveModeEl = document.getElementById('d-drive-mode');
      if (driveModeEl) {
        const battPct = s.batt_power_pct || 0;
        const spd     = s.speed_kmh || 0;
        const moving  = spd > 3;
        driveModeEl.style.display = moving ? '' : 'none';
        if (moving) {
          const modes = [
            { max: 20,  label: '🌱 Eco',     bg: '#14532d', color: '#4ade80' },
            { max: 50,  label: '⚡ Normal',   bg: '#1e3a5f', color: '#93c5fd' },
            { max: 80,  label: '🔥 Esporte',  bg: '#7c2d12', color: '#fb923c' },
            { max: 101, label: '🚀 Máximo',   bg: '#7f1d1d', color: '#f87171' },
          ];
          const m = modes.find(m => battPct <= m.max) || modes[3];
          driveModeEl.textContent       = m.label;
          driveModeEl.style.background  = m.bg;
          driveModeEl.style.color       = m.color;
        }
      }


    }
  }

  // Mapa GPS — atualiza live a cada nova posição recebida via WebSocket
  if (s.gps_lat && s.gps_lng) updateDashMap(s.gps_lat, s.gps_lng, s.gps_ts, s.speed_kmh || 0);

  renderAlerts(s);
}

// ── Recargas ──────────────────────────────────────────────────────────────────
function loadCharges() {
  const list = document.getElementById('charges-list');
  if (cachedCharges !== null) {
    renderCharges();
  } else {
    list.innerHTML = '<div class="empty">Carregando...</div>';
  }
  syncAllCache({ silent: true }).then(() => { renderCharges(); _tryAutoTagChargeLocation(); })
    .catch(() => { if (!cachedCharges) list.innerHTML = filterChipsHTML('charges') + '<div class="empty">Erro ao carregar.</div>'; });
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

function renderCharges() {
  const list = document.getElementById('charges-list');
  if (!list) return;
  const [startMs, endMs] = getFilterRange('charges');
  const byDate = filterItems(cachedCharges || [], 'timestamp', startMs, endMs);

  // Filtro por local (aplicado sobre o resultado do filtro de data)
  const locFilter = filterState.charges.location;
  const charges   = locFilter
    ? byDate.filter(c => (c.location_name || null) === locFilter)
    : byDate;

  const socColor = d => d >= 50 ? 'green' : d >= 25 ? 'teal' : 'muted';

  let html = filterChipsHTML('charges') + _locationChipsHTML();
  if (!charges.length) {
    list.innerHTML = html + '<div class="empty">Nenhuma recarga no período.</div>';
    return;
  }

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

  html += charges.map(c => {
    const delta  = (c.soc_end || 0) - (c.soc_start || 0);
    const col    = socColor(delta);
    const ts     = c.timestamp_ms || 0;
    const ov   = _chargeCostOverride(ts);
    const kwh  = c.energy_kwh || 0;
    // Custo: override manual tem prioridade; padrão = price_kwh das configurações
    const cost = ov
      ? { total: ov.total, perKwh: ov.perKwh, isOv: true }
      : (priceKwh > 0 && kwh > 0 ? { total: kwh * priceKwh, perKwh: priceKwh, isOv: false } : null);
    const totalCostHtml = cost
      ? `<span id="chg-cost-${ts}" class="trip-cost"${cost.isOv ? ' style="border-bottom:1px dashed rgba(251,191,36,.5)"' : ''}>R$ ${f2(cost.total)}</span>`
      : `<span id="chg-cost-${ts}" class="trip-cost" style="display:none"></span>`;
    const unitHtml = cost
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
    return `<div class="trip-item" id="charge-card-${ts}">
  <div class="trip-header">
    <div style="flex:1;min-width:0">
      <div class="trip-name-row">
        <div class="trip-name">${fmtDate(c.timestamp)}</div>
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
      </div>
    </div>
  </div>
  <div id="charge-edit-${ts}" class="cost-edit-form" style="display:none">
    <div style="font-size:11px;color:#64748b;width:100%;margin-bottom:2px">Total pago (R$) — deixe 0 para usar o preço das configurações</div>
    <input class="charge-total-input" type="number" step="0.01" min="0" placeholder="ex: 12.50"${ov ? ` value="${ov.total}"` : ''}>
    <button class="cost-apply-btn" onclick="applyChargeCost(${ts},${kwh.toFixed(3)})">Salvar</button>
  </div>
  <div id="charger-edit-${ts}" class="cost-edit-form" style="display:none">
    <div style="font-size:11px;color:#64748b;width:100%;margin-bottom:2px">kWh marcado no carregador — para calcular a perda de carga</div>
    <input class="charge-total-input" type="number" step="0.01" min="0" placeholder="ex: 18.50"${chargerKwh > 0 ? ` value="${chargerKwh}"` : ''}>
    <button class="cost-apply-btn" onclick="applyChargerKwh(${ts})">Salvar</button>
  </div>
  <div class="trip-metrics">
    <div class="trip-metric"><div class="trip-metric-val" style="color:var(--teal)">${fmtDur(c.duration_sec)}</div><div class="trip-metric-lbl">duração</div></div>
    <div class="trip-metric"><div class="trip-metric-val" style="color:var(--blue)">${f1(c.avg_power_kw)} kW</div><div class="trip-metric-lbl">pot. média</div></div>
    <div class="trip-metric"><div class="trip-metric-val" style="color:var(--muted)">${pct(c.soc_start)}</div><div class="trip-metric-lbl">SOC início</div></div>
    <div class="trip-metric"><div class="trip-metric-val ${col}">${pct(c.soc_end)}</div><div class="trip-metric-lbl">SOC fim</div></div>
    <div class="trip-metric"><div class="trip-metric-val ${col}">+${delta.toFixed(0)}%</div><div class="trip-metric-lbl">Δ SOC</div></div>
    ${c.avg_temp_c != null ? `<div class="trip-metric"><div class="trip-metric-val muted">${c.avg_temp_c.toFixed(1)}°C</div><div class="trip-metric-lbl">🌡 temp ext</div></div>` : ''}
  </div>
  ${lossRow}
  <div class="charge-location-row" onclick="openLoc(${ts})">
    ${c.location_name
      ? `<span class="charge-loc-name">📍 ${c.location_name}</span><span class="charge-loc-edit">✏️</span>`
      : `<span class="charge-loc-add">📍 Adicionar local</span>`}
  </div>
</div>`;
  }).join('');

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

// ── Histórico ─────────────────────────────────────────────────────────────────
function loadHistory() {
  const list = document.getElementById('hist-list');
  if (cachedTrips !== null || cachedAutoTrips !== null) {
    renderHistory();                      // cache IndexedDB → renderiza imediatamente
  } else {
    list.innerHTML = '<div class="empty">Carregando...</div>';
  }
  syncAllCache({ silent: false }).then(() => {
    renderHistory();
    syncRenameStatus();
  }).catch(() => {
    if (!cachedTrips) list.innerHTML = filterChipsHTML('hist') + '<div class="empty">Erro ao carregar.</div>';
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
      avg_speed_kmh:   t.timeSec > 0 ? (t.distKm / (t.timeSec / 3600)) : 0,
      total_cost_brl:  0,
    }));
  }

  // Filtro de busca por nome
  const histQ = (filterState.hist.search || '').trim().toLowerCase();
  if (histQ) {
    trips = trips.filter(t => {
      const name = (t.name || t.label || '').toLowerCase();
      return name.includes(histQ);
    });
  }

  let html = filterChipsHTML('hist');
  if (!trips.length) {
    const hint = histQ
      ? `<div class="empty">Nenhuma viagem com "${filterState.hist.search}".</div>`
      : isFiltered
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
  const avgKwh100     = totDist > 0.1   ? totNetKwh / totDist * 100 : 0;
  const avgKml        = totFuel > 0.001 ? totDist   / totFuel       : 0;
  const avgCostPerKm  = totCost > 0 && totDist > 0.1 ? totCost / totDist : 0;

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
    ${avgCostPerKm > 0 ? `<div class="metric"><div class="metric-value yellow sm">${f3(avgCostPerKm)}</div><div class="metric-label">R$/km</div></div>` : ''}
  </div>
</div>`;

  html += trips.map(t => {
    const tripId   = t.timestamp || t.tripId || '';
    const tripType = t.label === 'Auto' ? 'auto' : 'manual';
    // Usa nome pendente do renameTracking como prioridade — evita que syncAllCache
    // com dados do servidor (nome ainda antigo) apague o badge ⏳
    const rnTrack     = renameTracking[String(tripId)];
    const displayName = (rnTrack?.name) || t.name || '';
    const fallbackName = t.label || 'Trip';
    const ov       = _tripCostOverride(String(tripId));
    const dispCost = ov ? ov.cost : (t.total_cost_brl || 0);
    const fuelLVal = t.fuel_l || 0;
    const netKwhVal= t.net_kwh || (t.kwh_per_100km > 0 && t.distance_km > 0 ? t.kwh_per_100km * t.distance_km / 100 : 0);
    const costBadge = `<span id="cost-badge-${tripId}" class="trip-cost"${dispCost <= 0 ? ' style="display:none"' : ov ? ' style="border-bottom:1px dashed rgba(251,191,36,.5)"' : ''}>${dispCost > 0 ? 'R$ ' + f2(dispCost) : ''}</span>`;
    const tsDisplay = typeof t.timestamp === 'number' ? fmtDate(new Date(t.timestamp).toISOString()) : fmtDate(t.timestamp);
    const rnStatus    = getRenameStatus(String(tripId));
    const statusBadge = rnStatus === 'pending'   ? '<span class="rename-status-pending" title="Aguardando confirmação do carro">⏳</span>'
                      : rnStatus === 'confirmed'  ? '<span class="rename-status-ok" title="Confirmado pelo carro">✓</span>'
                      : '';
    return `<div class="trip-item" id="trip-card-${tripId}">
  <div class="trip-header">
    <div style="flex:1;min-width:0">
      <div class="trip-name-row">
        ${displayName ? `<span class="trip-name">${displayName}</span>${statusBadge}` : ''}
        <button class="rename-btn" onclick="startRenameTrip('${tripId}','${tripType}')" title="${displayName ? 'Renomear' : 'Nomear'}">✏️</button>
        <button class="rename-btn" onclick="deleteTrip('${tripId}','${tripType}')" title="Apagar viagem" style="opacity:.35">🗑</button>
      </div>
      <div class="trip-date">${tsDisplay}</div>
    </div>
    <div style="display:flex;flex-direction:column;align-items:flex-end;gap:3px">
      ${costBadge}
      <button class="cost-edit-btn" onclick="toggleCostEdit('${tripId}')" title="Recalcular custo">💰</button>
    </div>
  </div>
  <div id="cost-edit-${tripId}" class="cost-edit-form" style="display:none">
    <input class="cost-gas-input" type="number" step="0.01" min="0" placeholder="R$/L gasolina"${ov?.gas > 0 ? ` value="${ov.gas}"` : ''}>
    <input class="cost-kwh-input" type="number" step="0.01" min="0" placeholder="R$/kWh energia"${ov?.kwh > 0 ? ` value="${ov.kwh}"` : ''}>
    <button class="cost-apply-btn" onclick="applyTripCost('${tripId}',${fuelLVal},${netKwhVal.toFixed(3)})">Recalcular</button>
  </div>
  <div class="trip-metrics">
    <div class="trip-metric"><div class="trip-metric-val blue">${f1(t.distance_km)} km</div><div class="trip-metric-lbl">dist.</div></div>
    <div class="trip-metric"><div class="trip-metric-val green">${t.kwh_per_100km > 0 ? f1(t.kwh_per_100km) : '--'}</div><div class="trip-metric-lbl">kWh/100km</div></div>
    <div class="trip-metric"><div class="trip-metric-val" style="color:var(--muted)">${(t.avg_speed_kmh || 0) > 0 ? f1(t.avg_speed_kmh) + ' km/h' : '--'}</div><div class="trip-metric-lbl">vel. méd.</div></div>
    <div class="trip-metric"><div class="trip-metric-val" style="color:#5B7394">${fmtTripTime(t.time_sec)}</div><div class="trip-metric-lbl">duração</div></div>
  </div>
  <div class="trip-metrics trip-metrics-row2">
    <div class="trip-metric"><div class="trip-metric-val teal">${(t.net_kwh || 0) > 0 ? f2(t.net_kwh) + ' kWh' : '--'}</div><div class="trip-metric-lbl">kWh liq.</div></div>
    <div class="trip-metric"><div class="trip-metric-val orange">${t.fuel_l > 0 ? f2(t.fuel_l) + ' L' : '--'}</div><div class="trip-metric-lbl">combust.</div></div>
    <div class="trip-metric"><div class="trip-metric-val green">${t.km_per_l > 0 ? f1(t.km_per_l) : '--'}</div><div class="trip-metric-lbl">km/L</div></div>
    ${dispCost > 0 && (t.distance_km || 0) > 0.1 ? `<div class="trip-metric"><div class="trip-metric-val yellow">${f3(dispCost / t.distance_km)}</div><div class="trip-metric-lbl">R$/km</div></div>` : ''}
  </div>
</div>`;
  }).join('');

  list.innerHTML = html;
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
    const geo        = geoCache[t.tripId];
    const geoLine    = geo ? `<div class="trip-geo">📍 ${geo}</div>` : '';
    const autoName    = getAutoName(t);
    const rnTrackH    = renameTracking[String(t.tripId)];
    const displayName = (rnTrackH?.name) || t.name || autoName || '';
    const nameStyle   = !rnTrackH?.name && !t.name && autoName ? 'color:#64748b;font-style:italic' : '';
    const rnStatus    = getRenameStatus(t.tripId);
    const statusBadge = rnStatus === 'pending'   ? '<span class="rename-status-pending" title="Aguardando confirmação do carro">⏳</span>'
                      : rnStatus === 'confirmed'  ? '<span class="rename-status-ok" title="Confirmado pelo carro">✓</span>'
                      : '';
    const atOv     = _tripCostOverride(t.tripId);
    const atFuelL  = t.fuelL  || 0;
    const atNetKwh = t.netKwh || 0;
    const tripCost = atOv ? atOv.cost
      : ((priceGas > 0 || priceKwh > 0) ? atFuelL * priceGas + atNetKwh * priceKwh : 0);
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
        <button class="rename-btn" onclick="startRenameTrip('${t.tripId}','auto')" title="${displayName ? 'Renomear' : 'Nomear'}">✏️</button>
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
let dashMap             = null;
let dashMarker          = null;
let _dashMapLastLat     = 0;
let _dashMapLastLng     = 0;
let _dashMapLastTs      = 0;
let _dashMapGeocodeTimer = null;
let _dashMapTsTimer     = null;
let _dashMapMoving      = false;   // controla auto-zoom ao mudar estado de movimento

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
  const isMoving = (speed || 0) > 3;

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
    // Primeira posição: zoom depende do estado de movimento
    dashMap.setView(pos, isMoving ? 17 : 15);
    _dashMapMoving = isMoving;
    _startDashMapTsTimer();
  } else {
    // Atualizações seguintes: pan suave; muda zoom só quando estado de movimento muda
    dashMap.panTo(pos, { animate: true, duration: 0.5 });
    if (isMoving !== _dashMapMoving) {
      dashMap.setZoom(isMoving ? 17 : 15, { animate: true });
      _dashMapMoving = isMoving;
    }
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

function getPrices() {
  return {
    gas: state.price_gas_per_l || 0,
    kwh: state.price_kwh       || 0,
  };
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
  // Prioridade: cost_override no objeto de recarga (vem do servidor) → localStorage (fallback)
  const fromCache = cachedCharges?.find(c => c.timestamp_ms === ts);
  if (fromCache?.cost_override?.total > 0) return fromCache.cost_override;
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
  const fromCache = cachedCharges?.find(c => c.timestamp_ms === ts);
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
      if (idx >= 0) cachedCharges[idx] = updated;
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
      if (idx >= 0) cachedCharges[idx] = updated;
      _idbPutMany('charges', [updated]).catch(() => {});
    }
  }).catch(() => {/* offline — localStorage como fallback */});
};

window.deleteCharge = async function(ts) {
  if (!confirm('Apagar esta recarga?\nEssa ação não pode ser desfeita.')) return;
  try {
    const r = await apiFetch(`/api/charges/${ts}`, { method: 'DELETE' });
    if (!r.ok) { showToast('✗ Erro ao apagar recarga'); return; }
    if (cachedCharges) cachedCharges = cachedCharges.filter(c => (c.timestamp_ms || 0) !== ts);
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
  cachedTrips = null; cachedAutoTrips = null; cachedCharges = null;
  await _idbClearAll();
  const t = await syncAllCache({ silent: false });
  renderHistory(); renderAutoTrips(); renderCharges();
  _cacheSetStatus('✓ ' + t.trips + ' trips · ' + t.auto + ' auto · ' + t.charges + ' rec baixados', true);
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
      cachedTrips = null; cachedAutoTrips = null; cachedCharges = null;
      await syncAllCache({ silent: true });
      _backupSetStatus(
        `✓ Restore concluído — ${data.trips} trips · ${data.autotrips} auto-trips · ${data.charges} recargas`,
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
  const trips = (cachedAutoTrips || []).filter(t => (t.distKm || 0) > 2);

  let html = '<div style="padding-bottom:12px">';

  // ── 1. Recordes pessoais ─────────────────────────────────────────────────
  html += _statsRecordsHTML(trips);

  // ── 2. Comparativo semanal ───────────────────────────────────────────────
  html += await _statsWeeklyHTML();

  // ── 3. Comparativo mensal ────────────────────────────────────────────────
  html += await _statsMonthlyHTML();

  // ── 4. Split elétrico / híbrido ──────────────────────────────────────────
  html += _statsElectricHTML(trips);

  // ── 5. Locais de recarga — ranking por eficiência ────────────────────────
  html += _statsChargingLocationsHTML(cachedCharges || []);

  html += '</div>';
  container.innerHTML = html;
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
  const tripsWithData = trips.filter(t => t.hybridTimeSec !== undefined && (t.distKm || 0) > 0);
  if (!tripsWithData.length) {
    return _statsCard('⚡ Split elétrico / híbrido',
      '<div style="color:#475569;font-size:12px">Dados disponíveis em viagens registradas a partir de agora. Cada nova viagem calculará automaticamente o tempo em modo elétrico vs híbrido.</div>');
  }

  const totalDist    = tripsWithData.reduce((s, t) => s + (t.distKm || 0), 0);
  const totalHybrid  = tripsWithData.reduce((s, t) => s + (t.hybridDistKm || 0), 0);
  const totalElec    = Math.max(0, totalDist - totalHybrid);
  const elecPct      = totalDist > 0 ? Math.round(totalElec / totalDist * 100) : 0;
  const hybPct       = 100 - elecPct;

  const bar = `<div style="height:10px;background:#0F1C2E;border-radius:5px;overflow:hidden;margin:8px 0">
    <div style="height:100%;width:${elecPct}%;background:linear-gradient(90deg,#39FF88,#4ade80);border-radius:5px 0 0 5px;display:inline-block"></div>
  </div>
  <div style="display:flex;justify-content:space-between;font-size:10px;color:#64748b;margin-bottom:10px">
    <span style="color:#4ade80">⚡ ${elecPct}% elétrico</span>
    <span style="color:#fb923c">🔥 ${hybPct}% híbrido</span>
  </div>`;

  const summary = `<div style="font-size:12px;color:#94a3b8;margin-bottom:10px">
    ${tripsWithData.length} viagens · ${totalDist.toFixed(1)} km totais ·
    ${totalElec.toFixed(1)} km elétrico · ${totalHybrid.toFixed(1)} km híbrido
  </div>`;

  // Últimas 5 viagens com split
  let rows = '<div style="font-size:11px;color:#475569;margin-bottom:4px">Últimas viagens:</div>';
  tripsWithData.slice(0, 5).forEach(t => {
    const hyb = t.hybridDistKm || 0;
    const elc = Math.max(0, t.distKm - hyb);
    const ep  = t.distKm > 0 ? Math.round(elc / t.distKm * 100) : 0;
    const d   = new Date(t.startMs || 0);
    const dt  = d.toLocaleDateString('pt-BR', { day: '2-digit', month: '2-digit' });
    rows += `<div style="display:flex;justify-content:space-between;align-items:center;padding:4px 0;border-bottom:1px solid #0F1520">
      <span style="font-size:11px;color:#64748b">${dt} · ${f1(t.distKm)} km</span>
      <span style="font-size:12px;font-weight:700;color:${ep > 70 ? '#4ade80' : ep > 40 ? '#60a5fa' : '#fb923c'}">⚡ ${ep}%</span>
    </div>`;
  });

  return _statsCard('⚡ Split elétrico / híbrido', bar + summary + rows);
}

// ── Ranking de locais de recarga por eficiência ───────────────────────────────
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
  const TIMEOUT = (confirmSpec?.timeout ?? 60) * 1000;

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

    if (confirmSpec) {
      // Comando aceito — aguarda confirmação do carro via WebSocket
      showToast('⏳ Aguardando confirmação do carro…');
      if (logEl) logEl.innerHTML = `<span style="color:#fbbf24">⏳ Aguardando carro…</span>`;

      _pendingConfirm[confirmSpec.key] = {
        expectedVal: confirmSpec.expectedVal,
        timer: setTimeout(() => {
          delete _pendingConfirm[confirmSpec.key];
          showToast('✗ Carro não confirmou em 60s');
          if (logEl) logEl.innerHTML = `<span style="color:#f87171">✗ Sem confirmação · ${hhmm()}</span>`;
        }, TIMEOUT),
        onSuccess: () => {
          showToast('✓ ' + successMsg);
          if (logEl) logEl.innerHTML = `<span style="color:#4ade80">✓ ${successMsg} · ${hhmm()}</span>`;
          if (navigator.vibrate) navigator.vibrate([80, 40, 80]);
        },
      };
    } else {
      // Ação sem confirmação (outros comandos remotos)
      showToast('✓ ' + successMsg);
      if (logEl) logEl.innerHTML = `<span style="color:#4ade80">✓ Enviado · ${hhmm()}</span>`;
      if (navigator.vibrate) navigator.vibrate(80);
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
    // Remove do cache em memória
    if (type === 'auto') {
      if (cachedAutoTrips) cachedAutoTrips = cachedAutoTrips.filter(t => String(t.tripId) !== String(tripId) && String(t.startMs) !== String(tripId));
    } else {
      if (cachedTrips) cachedTrips = cachedTrips.filter(t => String(t.timestamp) !== String(tripId));
    }
    // Remove do IndexedDB
    _openIDB().then(db => {
      const store = type === 'auto' ? 'autotrips' : 'trips';
      const key   = type === 'auto' ? String(tripId) : tripId;
      db.transaction(store, 'readwrite').objectStore(store).delete(key);
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
  // Lê nome atual do cache (evita problemas de escape em onclick)
  let currentName = '';
  let dateStr = '';
  if (type === 'auto') {
    const t = (cachedAutoTrips || []).find(t => t.tripId === String(tripId));
    if (t) { currentName = t.name || ''; dateStr = fmtDate(t.startMs); }
  } else {
    const t = (cachedTrips || []).find(t => String(t.timestamp) === String(tripId));
    if (t) {
      currentName = t.name || '';
      dateStr = typeof t.timestamp === 'number'
        ? fmtDate(new Date(t.timestamp).toISOString()) : fmtDate(t.timestamp);
    }
  }
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
    // Atualiza cache local
    if (type === 'auto') {
      const t = (cachedAutoTrips || []).find(t => t.tripId === tripId);
      if (t) t.name = newName;
    } else {
      const t = (cachedTrips || []).find(t => String(t.timestamp) === tripId);
      if (t) t.name = newName;
    }
    // Marca como pendente de confirmação do carro
    renameTracking[tripId] = { pendingId: data.id || '', name: newName, confirmed: false };
    _saveRenameTracking();
    // Re-renderiza para mostrar ⏳
    if (type === 'auto') renderAutoTrips(); else renderHistory();
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
