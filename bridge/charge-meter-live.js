'use strict';

const { chargeMeterKey } = require('./charge-meter-catalog');

function round(value, digits) {
  return Number(Number(value).toFixed(digits));
}

function tariffAt(config, atMs) {
  return (Array.isArray(config?.tariffs) ? config.tariffs : [])
    .filter(item => Number(item?.effective_from_ms) <= atMs && Number.isFinite(Number(item?.price_per_kwh)))
    .sort((left, right) => Number(left.effective_from_ms) - Number(right.effective_from_ms))
    .at(-1)?.price_per_kwh;
}

function hasFreshVehicleChargeContext({
  chargingState,
  chargingSeenMs,
  chargingSource,
  apkSeenMs,
  gpsSeenMs,
  nowMs = Date.now(),
  maxAgeMs = 5 * 60_000,
}) {
  if (chargingState !== 'Carregando') return false;
  const effectiveChargingSeenMs = chargingSource === 'apk' ? apkSeenMs : chargingSeenMs;
  return [effectiveChargingSeenMs, gpsSeenMs].every(value => {
    const age = Number(nowMs) - Number(value);
    return Number(value) > 0 && age >= 0 && age <= maxAgeMs;
  });
}

function shouldRecoverApkCharging({
  chargingState,
  apkChargingState,
  apkSeenMs,
  chargePowerKw,
  isRetained,
  nowMs = Date.now(),
  maxAgeMs = 5 * 60_000,
}) {
  const apkAge = Number(nowMs) - Number(apkSeenMs);
  return !isRetained
    && chargingState !== 'Carregando'
    && apkChargingState === 'Carregando'
    && Number(chargePowerKw) > 0.3
    && Number(apkSeenMs) > 0
    && apkAge >= 0
    && apkAge <= maxAgeMs;
}

function meterForLiveUpdate(item, charging, final) {
  return charging || final ? item : null;
}

function chargeMeterContentFields(item) {
  return {
    chargerPowerKw: item?.power_kw ?? null,
    chargerSessionKwh: item?.energy_kwh ?? null,
    costBrl: item?.cost_brl ?? null,
  };
}

function selectLiveChargeMeter({ configs, sessionsByKey, vehicleKwh, atMs = Date.now() }) {
  const active = (Array.isArray(configs) ? configs : []).flatMap(config => {
    if (config?.enabled === false) return [];
    const session = sessionsByKey?.[chargeMeterKey(config)];
    return session ? [{ config, session }] : [];
  });
  if (!active.length) return { status: 'inactive', item: null };
  if (active.length > 1) return { status: 'ambiguous', item: null };

  const { config, session } = active[0];
  const energy = Number(session.energy_kwh);
  const vehicle = Number(vehicleKwh);
  const loss = Number.isFinite(energy) && Number.isFinite(vehicle)
    ? Math.max(0, energy - vehicle) : null;
  let cost = session.provider_cost == null ? null : Number(session.provider_cost);
  if (config.provider === 'zeeda' && Number.isFinite(energy)) {
    const tariff = Number(tariffAt(config, atMs));
    cost = Number.isFinite(tariff) ? round(energy * tariff, 2) : null;
  }
  return {
    status: 'matched',
    item: {
      provider: config.provider,
      charger_id: String(session.charger_id || config.charger_id),
      charger_name: String(session.charger_name || config.charger_name || config.charger_id),
      power_kw: session.power_kw == null ? null : Number(session.power_kw),
      energy_kwh: Number.isFinite(energy) ? energy : null,
      cost_brl: Number.isFinite(cost) ? cost : null,
      loss_kwh: loss == null ? null : round(loss, 6),
      loss_pct: loss == null || !(energy > 0) ? null : round(loss / energy * 100, 4),
      status: 'Charging',
      updated_at_ms: Date.now(),
    },
  };
}

module.exports = {
  chargeMeterContentFields,
  hasFreshVehicleChargeContext,
  meterForLiveUpdate,
  selectLiveChargeMeter,
  shouldRecoverApkCharging,
};
