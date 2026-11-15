'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  chargeMeterProviders,
  normalizeChargeMeterChargers,
  validateChargeMeterConfig,
} = require('../charge-meter-catalog');

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
