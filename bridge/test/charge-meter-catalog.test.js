'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  chargeMeterConfigsFromPlace,
  chargeMeterKey,
  chargeMeterProviders,
  mergeLegacyChargeMeter,
  normalizeChargeMeterChargers,
  validateChargeMeterConfig,
  validateChargeMeterConfigs,
} = require('../charge-meter-catalog');

const zeeda = (id, price) => ({
  enabled: true,
  provider: 'zeeda',
  charger_id: id,
  charger_name: id,
  tariffs: [{ effective_from_ms: 1000, price_per_kwh: price }],
});

const yellotmob = id => ({
  enabled: true,
  provider: 'yellotmob',
  charger_id: id,
  charger_name: id,
  tariffs: [],
});

test('publishes Zeeda and YellotMob capabilities', () => {
  assert.deepEqual(chargeMeterProviders(), [
    { id: 'zeeda', name: 'Zeeda', requires_tariff: true },
    { id: 'yellotmob', name: 'YellotMob', requires_tariff: false },
  ]);
});

test('normalizes charger catalogs without leaking raw provider data', () => {
  assert.deepEqual(normalizeChargeMeterChargers('zeeda', [{
    deviceCode: 'D4', name: 'Jardins Lisboa', online: true, secret: 'omit',
  }]), [{ id: 'D4', name: 'Jardins Lisboa', online: true }]);
  assert.deepEqual(normalizeChargeMeterChargers('yellotmob', { items: [{
    id: 273, name: 'Pão de Açúcar T-63', raw: { address: 'omit' },
  }] }), [{ id: '273', name: 'Pão de Açúcar T-63' }]);
});

test('validates provider configuration before persistence', () => {
  assert.deepEqual(validateChargeMeterConfig({
    enabled: true,
    provider: 'zeeda',
    charger_id: 'D4',
    charger_name: 'Jardins Lisboa',
    tariffs: [{ effective_from_ms: 1000, price_per_kwh: 0.18 }],
  }), {
    enabled: true,
    provider: 'zeeda',
    charger_id: 'D4',
    charger_name: 'Jardins Lisboa',
    tariffs: [{ effective_from_ms: 1000, price_per_kwh: 0.18 }],
  });
  assert.throws(() => validateChargeMeterConfig({
    enabled: true, provider: 'zeeda', charger_id: 'D4', tariffs: [],
  }), /tarifa/);
  assert.throws(() => validateChargeMeterConfig({
    enabled: true, provider: 'unknown', charger_id: '1', tariffs: [],
  }), /provedor/);
});

test('validates mixed charger lists with independent Zeeda tariffs', () => {
  const result = validateChargeMeterConfigs([
    zeeda('Z-1', 0.18),
    zeeda('Z-2', 0.32),
    yellotmob('273'),
  ]);

  assert.equal(result.length, 3);
  assert.equal(result[0].tariffs[0].price_per_kwh, 0.18);
  assert.equal(result[1].tariffs[0].price_per_kwh, 0.32);
  assert.deepEqual(result[2].tariffs, []);
  assert.deepEqual(validateChargeMeterConfigs([]), []);
});

test('rejects normalized duplicate provider and charger pairs', () => {
  assert.equal(chargeMeterKey({ provider: ' ZEEDA ', charger_id: ' AbC ' }), 'zeeda:abc');
  assert.throws(() => validateChargeMeterConfigs([
    zeeda('AbC', 0.18),
    { ...zeeda(' abc ', 0.20), provider: 'ZEEDA' },
  ]), /duplicado/);
});

test('reads canonical lists and falls back to one legacy meter', () => {
  assert.deepEqual(chargeMeterConfigsFromPlace({ charge_meter: yellotmob('273') }), [yellotmob('273')]);
  assert.deepEqual(chargeMeterConfigsFromPlace({
    charge_meters: [],
    charge_meter: yellotmob('legacy'),
  }), []);
  assert.deepEqual(chargeMeterConfigsFromPlace({
    charge_meters: [zeeda('Z-1', 0.18), yellotmob('273')],
  }), [zeeda('Z-1', 0.18), yellotmob('273')]);
});

test('legacy writes replace only the first meter and preserve extras', () => {
  const existing = [zeeda('Z-1', 0.18), yellotmob('273')];
  const replacement = zeeda('Z-2', 0.32);

  assert.deepEqual(mergeLegacyChargeMeter(existing, replacement), [replacement, yellotmob('273')]);
  assert.deepEqual(mergeLegacyChargeMeter([], replacement), [replacement]);
  assert.deepEqual(existing, [zeeda('Z-1', 0.18), yellotmob('273')]);
});

test('legacy writes can promote an existing extra without creating a duplicate', () => {
  const first = zeeda('Z-1', 0.18);
  const promoted = yellotmob('273');
  const remaining = yellotmob('274');

  assert.deepEqual(
    mergeLegacyChargeMeter([first, promoted, remaining], promoted),
    [promoted, remaining]
  );
});
