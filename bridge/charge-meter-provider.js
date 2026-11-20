'use strict';

class ChargeMeterProviderError extends Error {
  constructor(provider) {
    super(`${provider} indisponível`);
    this.code = 'provider_unavailable';
  }
}

function normalizeYellotMob(item, provider = 'yellotmob') {
  return {
    provider,
    external_session_id: String(item?.external_session_id || ''),
    charger_id: String(item?.charger_id || ''),
    charger_name: String(item?.charger_name || item?.charger_id || ''),
    started_at: item?.started_at ?? null,
    ended_at: item?.ended_at ?? null,
    energy_kwh: Number(item?.energy_kwh),
    power_kw: item?.power_kw == null ? null : Number(item.power_kw),
    provider_cost: item?.provider_cost == null ? null : Number(item.provider_cost),
    status: item?.status ?? null,
    raw_updated_at: item?.raw_updated_at ?? null,
  };
}

function normalizeZeeda(item) {
  const transactionId = item?.vendorTransactionId ?? item?.id;
  return {
    provider: 'zeeda',
    external_session_id: `transaction:${transactionId}`,
    charger_id: String(item?.deviceCode || ''),
    charger_name: String(item?.deviceCode || ''),
    started_at: Number.isFinite(Number(item?.startedAtMs)) ? new Date(Number(item.startedAtMs)).toISOString() : null,
    ended_at: Number.isFinite(Number(item?.endedAtMs)) ? new Date(Number(item.endedAtMs)).toISOString() : null,
    energy_kwh: Number(item?.energyKwh),
    power_kw: item?.averagePowerKw == null ? null : Number(item.averagePowerKw),
    provider_cost: null,
    status: item?.status ?? null,
    raw_updated_at: null,
  };
}

function normalizeCurrentZeeda(item, chargerId) {
  const status = String(item?.connectorStatus ?? '').trim().toLowerCase();
  const powerKw = Number(item?.currentPowerKw);
  const active = item?.online !== false
    && (powerKw > 0.05 || status === '2' || status === '2.0'
      || status.includes('charging') || status.includes('carregando') || status.includes('occupied'));
  if (!active) return null;
  return {
    provider: 'zeeda',
    external_session_id: '',
    charger_id: String(item?.deviceCode || chargerId),
    charger_name: String(item?.name || item?.deviceCode || chargerId),
    started_at: null,
    ended_at: null,
    energy_kwh: Number(item?.sessionEnergyKwh),
    power_kw: Number.isFinite(powerKw) ? powerKw : null,
    provider_cost: null,
    status: 'Charging',
    raw_updated_at: null,
  };
}

async function getCurrentChargeMeterSession(provider, chargerId, options = {}) {
  const fetchImpl = options.fetchImpl || global.fetch;
  const normalizedProvider = String(provider || '').trim().toLowerCase();
  const zeeda = normalizedProvider === 'zeeda';
  const mhzmob = normalizedProvider === 'mhzmob';
  if (!zeeda && !mhzmob && normalizedProvider !== 'yellotmob') {
    throw new ChargeMeterProviderError(normalizedProvider || 'provedor');
  }
  const baseUrl = zeeda
    ? options.zeedaUrl || 'http://127.0.0.1:8788'
    : mhzmob
      ? options.mhzmobUrl || 'http://127.0.0.1:3000'
      : options.yellotmobUrl || 'http://127.0.0.1:8790';
  const endpoint = zeeda
    ? `/api/zeeda/chargers/${encodeURIComponent(chargerId)}/live`
    : mhzmob ? '/api/mhzmob/current-session' : '/api/current-session';

  try {
    const url = new URL(endpoint, baseUrl);
    if (!zeeda) url.searchParams.set('charger', String(chargerId));
    const headers = zeeda || mhzmob
      ? { Authorization: `Bearer ${zeeda ? options.zeedaToken || '' : options.mhzmobToken || ''}` }
      : {};
    const response = await fetchImpl(url, { headers, signal: AbortSignal.timeout(5_000) });
    if (!response.ok) throw new Error('upstream');
    const payload = await response.json();
    if (zeeda) return normalizeCurrentZeeda(payload, chargerId);
    if (!payload?.item || String(payload.item.status || '').toLowerCase() !== 'charging') return null;
    return normalizeYellotMob(payload.item, normalizedProvider);
  } catch {
    throw new ChargeMeterProviderError(normalizedProvider);
  }
}

async function listChargeMeterSessions(provider, chargerId, fromIso, toIso, options = {}) {
  const fetchImpl = options.fetchImpl || global.fetch;
  const normalizedProvider = String(provider || '').trim().toLowerCase();
  const zeeda = normalizedProvider === 'zeeda';
  const mhzmob = normalizedProvider === 'mhzmob';
  if (!zeeda && !mhzmob && normalizedProvider !== 'yellotmob') throw new ChargeMeterProviderError(normalizedProvider || 'provedor');
  const baseUrl = zeeda
    ? options.zeedaUrl || 'http://127.0.0.1:8788'
    : mhzmob
      ? options.mhzmobUrl || 'http://127.0.0.1:3000'
      : options.yellotmobUrl || 'http://127.0.0.1:8790';
  const endpoint = zeeda ? '/api/zeeda/sessions' : mhzmob ? '/api/mhzmob/sessions' : '/api/sessions';
  const items = [];
  let cursor = zeeda ? null : 0;

  try {
    for (let page = 0; page < 100; page++) {
      const url = new URL(endpoint, baseUrl);
      url.searchParams.set('charger', String(chargerId));
      url.searchParams.set('from', zeeda ? String(Date.parse(fromIso)) : fromIso);
      url.searchParams.set('to', zeeda ? String(Date.parse(toIso)) : toIso);
      url.searchParams.set('limit', '100');
      if (cursor != null) url.searchParams.set('cursor', String(cursor));
      const headers = zeeda || mhzmob
        ? { Authorization: `Bearer ${zeeda ? options.zeedaToken || '' : options.mhzmobToken || ''}` }
        : {};
      const response = await fetchImpl(url, { headers, signal: AbortSignal.timeout(5_000) });
      if (!response.ok) throw new Error('upstream');
      const payload = await response.json();
      const rows = Array.isArray(payload?.items) ? payload.items : [];
      items.push(...rows.map(zeeda ? normalizeZeeda : item => normalizeYellotMob(item, normalizedProvider)));
      cursor = zeeda ? payload?.nextCursor : payload?.next_cursor;
      if (cursor == null) return items;
    }
    throw new Error('pagination');
  } catch {
    throw new ChargeMeterProviderError(normalizedProvider);
  }
}

module.exports = {
  ChargeMeterProviderError,
  getCurrentChargeMeterSession,
  listChargeMeterSessions,
};
