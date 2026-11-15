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

function chargeMeterKey(config) {
  return `${String(config?.provider || '').trim().toLowerCase()}:${String(config?.charger_id || '').trim().toLowerCase()}`;
}

function validateChargeMeterConfigs(raw) {
  if (!Array.isArray(raw)) throw new Error('lista de carregadores inválida');
  const configs = raw.map(validateChargeMeterConfig);
  const keys = new Set();
  for (const config of configs) {
    const key = chargeMeterKey(config);
    if (keys.has(key)) throw new Error('carregador duplicado');
    keys.add(key);
  }
  return configs;
}

function chargeMeterConfigsFromPlace(place) {
  if (Object.prototype.hasOwnProperty.call(place || {}, 'charge_meters')) {
    return Array.isArray(place.charge_meters) ? place.charge_meters.map(config => ({ ...config })) : [];
  }
  return place?.charge_meter ? [{ ...place.charge_meter }] : [];
}

function mergeLegacyChargeMeter(existing, legacy) {
  const configs = Array.isArray(existing) ? existing : [];
  const legacyKey = chargeMeterKey(legacy);
  return [
    { ...legacy },
    ...configs.slice(1)
      .filter(config => chargeMeterKey(config) !== legacyKey)
      .map(config => ({ ...config })),
  ];
}

module.exports = {
  chargeMeterConfigsFromPlace,
  chargeMeterKey,
  chargeMeterProviders,
  mergeLegacyChargeMeter,
  normalizeChargeMeterChargers,
  validateChargeMeterConfig,
  validateChargeMeterConfigs,
};
