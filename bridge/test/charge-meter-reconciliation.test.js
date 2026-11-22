'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const reconciliation = require('../charge-meter-reconciliation');
const {
  resolveProviderReconciliation,
  reconcileChargeMeter,
  shouldFillChargeMeterEnergy,
  shouldRetryChargeMeter,
  terminalChargeMeterStatus,
} = require('../charge-meter-reconciliation');

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

const mhzmob = id => ({
  enabled: true,
  provider: 'mhzmob',
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

test('queries far enough back to include a provider session already in progress', () => {
  assert.equal(typeof reconciliation.chargeMeterQueryWindow, 'function');
  const window = reconciliation.chargeMeterQueryWindow(charge());

  assert.ok(Date.parse(window.fromIso) <= base - 26 * MINUTE);
  assert.equal(Date.parse(window.toIso), base + 70 * MINUTE);
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

test('accepts a provider interval displaced by up to ten minutes', () => {
  const result = reconcileChargeMeter({
    charge: charge({ duration_sec: 28 * 60 }),
    configs: [yellotmob('273')],
    sessionsByKey: {
      'yellotmob:273': [session('transaction:472330', -7, 29, 24.902, { provider_cost: 27.05 })],
    },
  });

  assert.equal(result.status, 'matched');
  assert.equal(result.charger_kwh, 24.902);
  assert.deepEqual(result.cost_override, { total: 27.05, perKwh: 1.0863 });
});

test('does not match a provider interval more than ten minutes away', () => {
  const result = reconcileChargeMeter({
    charge: charge({ duration_sec: 28 * 60 }),
    configs: [yellotmob('273')],
    sessionsByKey: {
      'yellotmob:273': [session('transaction:old', -20, 21, 24.902, { provider_cost: 27.05 })],
    },
  });

  assert.equal(result.status, 'pending');
});

test('uses MHZ MOB energy and provider cost', () => {
  const result = reconcileChargeMeter({
    charge: charge(),
    configs: [mhzmob('4')],
    sessionsByKey: {
      'mhzmob:4': [session('transaction:2084', 0, 60, 20.722, { provider_cost: 32.88 })],
    },
  });

  assert.equal(result.charger_kwh, 20.722);
  assert.deepEqual(result.cost_override, { total: 32.88, perKwh: 1.5867 });
});

test('keeps MHZ MOB pending when provider cost is absent', () => {
  const result = reconcileChargeMeter({
    charge: charge(),
    configs: [mhzmob('4')],
    sessionsByKey: {
      'mhzmob:4': [session('transaction:2084', 0, 60, 20.722, { provider_cost: null })],
    },
  });

  assert.equal(result.status, 'pending');
  assert.equal(result.charger_kwh, 20.722);
  assert.equal(result.cost_override, undefined);
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

test('fills missing meter energy but preserves a manual value', () => {
  assert.equal(shouldFillChargeMeterEnergy(undefined, 24.902), true);
  assert.equal(shouldFillChargeMeterEnergy(null, 24.902), true);
  assert.equal(shouldFillChargeMeterEnergy(25, 24.902), false);
});

test('retries an unconfigured recent charge so later configuration can reconcile it', () => {
  assert.equal(shouldRetryChargeMeter('not_configured', base, base + MINUTE), true);
  assert.equal(shouldRetryChargeMeter('matched', base, base + MINUTE), false);
  assert.equal(shouldRetryChargeMeter('pending', base + MINUTE, base + MINUTE), false);
});

test('keeps a valid match when another linked provider is unavailable', () => {
  const matched = { status: 'matched', meter_key: 'yellotmob:273', charger_kwh: 24.902 };
  const states = [
    { meter_key: 'yellotmob:273', status: 'found' },
    { meter_key: 'mhzmob:4', status: 'provider_unavailable' },
  ];
  assert.equal(resolveProviderReconciliation(matched, states), matched);
  assert.deepEqual(resolveProviderReconciliation({ status: 'pending' }, states), { status: 'pending_provider' });
});

test('marks an unresolved reconciliation failed after its deadline', () => {
  assert.equal(terminalChargeMeterStatus('pending_provider', base, base + MINUTE), 'pending_provider');
  assert.equal(terminalChargeMeterStatus('pending_provider', base + MINUTE, base + MINUTE), 'failed');
  assert.equal(terminalChargeMeterStatus('matched', base + MINUTE, base + MINUTE), 'matched');
});
