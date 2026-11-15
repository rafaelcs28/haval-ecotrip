'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { reconcileChargeMeter, shouldRetryChargeMeter } = require('../charge-meter-reconciliation');

const MINUTE = 60_000;
const base = Date.parse('2026-11-15T12:00:00.000Z');

const charge = (overrides = {}) => ({
  timestamp_ms: base + 60 * MINUTE,
  duration_sec: 60 * 60,
  ...overrides,
});

const zeeda = (id, price = 0.18) => ({
  enabled: true,
  provider: 'zeeda',
  charger_id: id,
  charger_name: id,
  tariffs: [{ effective_from_ms: base - MINUTE, price_per_kwh: price }],
});

const yellotmob = id => ({
  enabled: true,
  provider: 'yellotmob',
  charger_id: id,
  charger_name: id,
  tariffs: [],
});

const session = (id, startMinute, endMinute, energy, extra = {}) => ({
  external_session_id: id,
  started_at: new Date(base + startMinute * MINUTE).toISOString(),
  ended_at: new Date(base + endMinute * MINUTE).toISOString(),
  energy_kwh: energy,
  ...extra,
});

test('sums sequential sessions from the same charger after a power interruption', () => {
  const result = reconcileChargeMeter({
    charge: charge(),
    configs: [zeeda('Z-1')],
    sessionsByKey: {
      'zeeda:z-1': [session('a', 0, 20, 3), session('b', 25, 60, 6)],
    },
  });

  assert.equal(result.status, 'matched');
  assert.equal(result.meter_key, 'zeeda:z-1');
  assert.equal(result.charger_kwh, 9);
  assert.deepEqual(result.cost_override, { total: 1.62, perKwh: 0.18 });
});

test('deduplicates overlapping copies of one provider session', () => {
  const result = reconcileChargeMeter({
    charge: charge(),
    configs: [zeeda('Z-1')],
    sessionsByKey: {
      'zeeda:z-1': [
        session('charging:8', 0, 60, 9.018),
        session('transaction:8', 0, 60, 9.02, { raw_updated_at: new Date(base + 61 * MINUTE).toISOString() }),
      ],
    },
  });

  assert.equal(result.charger_kwh, 9.02);
});

test('never mixes sessions from different charger keys', () => {
  const result = reconcileChargeMeter({
    charge: charge(),
    configs: [zeeda('Z-1'), zeeda('Z-2', 0.32)],
    sessionsByKey: {
      'zeeda:z-1': [session('a', 0, 40, 5)],
      'zeeda:z-2': [session('b', 45, 60, 4)],
    },
  });

  assert.equal(result.meter_key, 'zeeda:z-1');
  assert.equal(result.charger_kwh, 5);
});

test('selects greatest overlap then closest end time', () => {
  const greatestOverlap = reconcileChargeMeter({
    charge: charge(),
    configs: [zeeda('Z-1'), zeeda('Z-2')],
    sessionsByKey: {
      'zeeda:z-1': [session('a', 0, 40, 5)],
      'zeeda:z-2': [session('b', 20, 55, 4)],
    },
  });
  assert.equal(greatestOverlap.meter_key, 'zeeda:z-1');

  const closestEnd = reconcileChargeMeter({
    charge: charge(),
    configs: [zeeda('Z-1'), zeeda('Z-2')],
    sessionsByKey: {
      'zeeda:z-1': [session('a', 0, 30, 5)],
      'zeeda:z-2': [session('b', 30, 60, 4)],
    },
  });
  assert.equal(closestEnd.meter_key, 'zeeda:z-2');
});

test('leaves an exact competing match ambiguous', () => {
  const result = reconcileChargeMeter({
    charge: charge(),
    configs: [zeeda('Z-1'), zeeda('Z-2')],
    sessionsByKey: {
      'zeeda:z-1': [session('a', 0, 60, 5)],
      'zeeda:z-2': [session('b', 0, 60, 4)],
    },
  });

  assert.deepEqual(result, { status: 'ambiguous', candidates: ['zeeda:z-1', 'zeeda:z-2'] });
});

test('uses the individual Zeeda tariff effective when the charge started', () => {
  const config = zeeda('Z-1', 0.18);
  config.tariffs.push({ effective_from_ms: base + 30 * MINUTE, price_per_kwh: 0.50 });

  const result = reconcileChargeMeter({
    charge: charge(),
    configs: [config],
    sessionsByKey: { 'zeeda:z-1': [session('a', 0, 60, 10)] },
  });

  assert.deepEqual(result.cost_override, { total: 1.8, perKwh: 0.18 });
});

test('uses YellotMob energy and provider cost', () => {
  const result = reconcileChargeMeter({
    charge: charge(),
    configs: [yellotmob('273')],
    sessionsByKey: {
      'yellotmob:273': [session('transaction:466628', 0, 60, 22.502, { provider_cost: 31.11 })],
    },
  });

  assert.equal(result.charger_kwh, 22.502);
  assert.deepEqual(result.cost_override, { total: 31.11, perKwh: 1.3825 });
});

test('preserves manual energy and cost independently', () => {
  const manualCost = { total: 7, perKwh: 0.7 };
  const both = reconcileChargeMeter({
    charge: charge({ charger_kwh: 10, cost_override: manualCost }),
    configs: [zeeda('Z-1')],
    sessionsByKey: { 'zeeda:z-1': [session('a', 0, 60, 9)] },
  });
  assert.equal(both.charger_kwh, 10);
  assert.deepEqual(both.cost_override, manualCost);

  const energyOnly = reconcileChargeMeter({
    charge: charge({ charger_kwh: 10 }),
    configs: [zeeda('Z-1')],
    sessionsByKey: { 'zeeda:z-1': [session('a', 0, 60, 9)] },
  });
  assert.equal(energyOnly.charger_kwh, 10);
  assert.deepEqual(energyOnly.cost_override, { total: 1.8, perKwh: 0.18 });
});

test('retries an unconfigured recent charge so later configuration can reconcile it', () => {
  assert.equal(shouldRetryChargeMeter('not_configured', base, base + MINUTE), true);
  assert.equal(shouldRetryChargeMeter('matched', base, base + MINUTE), false);
  assert.equal(shouldRetryChargeMeter('pending', base + MINUTE, base + MINUTE), false);
});
