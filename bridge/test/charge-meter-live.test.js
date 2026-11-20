'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { selectLiveChargeMeter } = require('../charge-meter-live');

test('selects the only active linked charger and calculates energy loss', () => {
  const result = selectLiveChargeMeter({
    configs: [{ provider: 'yellotmob', charger_id: '273', enabled: true }],
    sessionsByKey: { 'yellotmob:273': {
      provider: 'yellotmob', charger_id: '273', charger_name: 'Pão de Açúcar T-63',
      energy_kwh: 14.115, power_kw: null, provider_cost: 13.74, status: 'Charging',
    } },
    vehicleKwh: 12.48,
    atMs: Date.parse('2026-11-20T17:00:00Z'),
  });

  assert.equal(result.status, 'matched');
  assert.equal(result.item.energy_kwh, 14.115);
  assert.equal(result.item.cost_brl, 13.74);
  assert.equal(result.item.loss_kwh, 1.635);
  assert.equal(result.item.loss_pct, 11.5834);
});

test('does not guess when two linked chargers report active sessions', () => {
  const result = selectLiveChargeMeter({
    configs: [
      { provider: 'yellotmob', charger_id: '273', enabled: true },
      { provider: 'mhzmob', charger_id: '4', enabled: true },
    ],
    sessionsByKey: {
      'yellotmob:273': { energy_kwh: 4, status: 'Charging' },
      'mhzmob:4': { energy_kwh: 5, status: 'Charging' },
    },
    vehicleKwh: 3,
  });

  assert.deepEqual(result, { status: 'ambiguous', item: null });
});

test('calculates Zeeda live cost from the tariff effective at charge start', () => {
  const result = selectLiveChargeMeter({
    configs: [{
      provider: 'zeeda', charger_id: 'D4', enabled: true,
      tariffs: [{ effective_from_ms: 0, price_per_kwh: 0.18 }],
    }],
    sessionsByKey: { 'zeeda:d4': {
      provider: 'zeeda', charger_id: 'D4', charger_name: 'Jardins Lisboa',
      energy_kwh: 0.631, power_kw: 6.16, provider_cost: null, status: 'Charging',
    } },
    vehicleKwh: 0.7,
    atMs: 1_000,
  });

  assert.equal(result.item.cost_brl, 0.11);
  assert.equal(result.item.loss_kwh, 0);
  assert.equal(result.item.loss_pct, 0);
});

test('returns no item when no linked charger is active', () => {
  assert.deepEqual(selectLiveChargeMeter({
    configs: [{ provider: 'yellotmob', charger_id: '273', enabled: true }],
    sessionsByKey: { 'yellotmob:273': null },
    vehicleKwh: 3,
  }), { status: 'inactive', item: null });
});
