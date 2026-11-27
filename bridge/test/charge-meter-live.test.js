'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  chargeMeterContentFields,
  hasFreshVehicleChargeContext,
  meterForLiveUpdate,
  selectLiveChargeMeter,
  shouldRecoverApkCharging,
} = require('../charge-meter-live');

test('builds the same external meter fields for final and interrupted updates', () => {
  assert.deepEqual(chargeMeterContentFields({
    power_kw: 6.2,
    energy_kwh: 24.902,
    cost_brl: 27.05,
  }), {
    chargerPowerKw: 6.2,
    chargerSessionKwh: 24.902,
    costBrl: 27.05,
  });
  assert.deepEqual(chargeMeterContentFields(null), {
    chargerPowerKw: null,
    chargerSessionKwh: null,
    costBrl: null,
  });
});

test('requires fresh charging and GPS readings before polling linked chargers', () => {
  const now = 1_800_000_000_000;
  assert.equal(hasFreshVehicleChargeContext({
    chargingState: 'Carregando', chargingSeenMs: now - 30_000, gpsSeenMs: now - 20_000, nowMs: now,
  }), true);
  assert.equal(hasFreshVehicleChargeContext({
    chargingState: 'Carregando', chargingSeenMs: now - 6 * 60_000, gpsSeenMs: now - 20_000, nowMs: now,
  }), false);
  assert.equal(hasFreshVehicleChargeContext({
    chargingState: 'Carregando', chargingSeenMs: now - 30_000, gpsSeenMs: 0, nowMs: now,
  }), false);
  assert.equal(hasFreshVehicleChargeContext({
    chargingState: 'Desconectado', chargingSeenMs: now - 30_000, gpsSeenMs: now - 20_000, nowMs: now,
  }), false);
});

test('keeps polling while the APK heartbeat is fresh after charging state stops repeating', () => {
  const now = 1_800_000_000_000;
  assert.equal(hasFreshVehicleChargeContext({
    chargingState: 'Carregando',
    chargingSeenMs: now - 7 * 60_000,
    chargingSource: 'apk',
    apkSeenMs: now - 10_000,
    gpsSeenMs: now - 5_000,
    nowMs: now,
  }), true);
  assert.equal(hasFreshVehicleChargeContext({
    chargingState: 'Carregando',
    chargingSeenMs: now - 7 * 60_000,
    chargingSource: 'apk',
    apkSeenMs: now - 6 * 60_000,
    gpsSeenMs: now - 5_000,
    nowMs: now,
  }), false);
});

test('recovers charging after stale cloud state overwrites live APK state on restart', () => {
  const now = 1_800_000_000_000;
  assert.equal(shouldRecoverApkCharging({
    chargingState: 'Desconectado',
    apkChargingState: 'Carregando',
    apkSeenMs: now - 5_000,
    chargePowerKw: 6.1,
    isRetained: false,
    nowMs: now,
  }), true);
  assert.equal(shouldRecoverApkCharging({
    chargingState: 'Desconectado',
    apkChargingState: 'Carregando',
    apkSeenMs: now - 5_000,
    chargePowerKw: 6.1,
    isRetained: true,
    nowMs: now,
  }), false);
});

test('keeps the last external meter in the final live update only', () => {
  const meter = { charger_id: '273', energy_kwh: 24.902, cost_brl: 27.05 };
  assert.equal(meterForLiveUpdate(meter, true, false), meter);
  assert.equal(meterForLiveUpdate(meter, false, true), meter);
  assert.equal(meterForLiveUpdate(meter, false, false), null);
});

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
