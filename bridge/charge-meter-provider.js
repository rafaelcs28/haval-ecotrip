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
  listChargeMeterSessions,
};
