'use strict';

const PROVIDERS = [
  { id: 'zeeda', name: 'Zeeda', requires_tariff: true },
  { id: 'yellotmob', name: 'YellotMob', requires_tariff: false },
];

function chargeMeterProviders() {
  return PROVIDERS.map(provider => ({ ...provider }));
}

function normalizeChargeMeterChargers(provider, payload) {
  const rows = Array.isArray(payload)
    ? payload
    : payload?.items || payload?.chargers || payload?.data || [];
  return (Array.isArray(rows) ? rows : []).flatMap(row => {
    const id = provider === 'zeeda' ? row?.deviceCode ?? row?.id : row?.id;
    if (id == null || !String(id).trim()) return [];
    const charger = {
      id: String(id),
      name: String(row?.name || id),
    };
    if (typeof row?.online === 'boolean') charger.online = row.online;
    return [charger];
  });
}

function validateChargeMeterConfig(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) throw new Error('configuração inválida');
  const provider = String(raw.provider || '').trim().toLowerCase();
  if (!PROVIDERS.some(item => item.id === provider)) throw new Error('provedor inválido');
  const chargerId = String(raw.charger_id || '').trim();
  if (!chargerId) throw new Error('carregador obrigatório');
  const tariffs = provider === 'zeeda'
    ? (Array.isArray(raw.tariffs) ? raw.tariffs : []).map(item => {
      const effectiveFromMs = Number(item?.effective_from_ms);
      const pricePerKwh = Number(item?.price_per_kwh);
      if (!Number.isFinite(effectiveFromMs) || effectiveFromMs < 0
          || !Number.isFinite(pricePerKwh) || pricePerKwh < 0) throw new Error('tarifa inválida');
      return { effective_from_ms: effectiveFromMs, price_per_kwh: pricePerKwh };
    })
    : [];
  if (raw.enabled !== false && provider === 'zeeda' && !tariffs.length) throw new Error('tarifa obrigatória');
  return {
    enabled: raw.enabled !== false,
    provider,
    charger_id: chargerId,
    charger_name: String(raw.charger_name || chargerId).trim() || chargerId,
    tariffs,
  };
}

module.exports = {
  chargeMeterProviders,
  normalizeChargeMeterChargers,
  validateChargeMeterConfig,
};
