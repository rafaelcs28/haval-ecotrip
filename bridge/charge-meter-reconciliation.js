'use strict';

const { chargeMeterKey } = require('./charge-meter-catalog');
const CHARGE_METER_QUERY_LOOKBACK_MS = 24 * 60 * 60_000;
const CHARGE_METER_QUERY_MARGIN_MS = 10 * 60_000;

function chargeMeterQueryWindow(charge) {
  const endMs = Number(charge?.timestamp_ms);
  const startMs = endMs - Number(charge?.duration_sec || 0) * 1000;
  return {
    // Provider APIs filter by session start, so include sessions already running when vehicle telemetry began.
    fromIso: new Date(startMs - CHARGE_METER_QUERY_LOOKBACK_MS).toISOString(),
    toIso: new Date(endMs + CHARGE_METER_QUERY_MARGIN_MS).toISOString(),
  };
}

function toMs(value) {
  if (typeof value === 'number') return Number.isFinite(value) ? value : NaN;
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : NaN;
}

function sessionBounds(session) {
  const start = toMs(session?.started_at);
  const end = toMs(session?.ended_at);
  return Number.isFinite(start) && Number.isFinite(end) && end > start ? { start, end } : null;
}

function overlapMs(left, right) {
  return Math.max(0, Math.min(left.end, right.end) - Math.max(left.start, right.start));
}

function gapMs(left, right) {
  if (overlapMs(left, right) > 0) return 0;
  return Math.max(left.start - right.end, right.start - left.end, 0);
}

function isDuplicate(left, right) {
  const a = sessionBounds(left);
  const b = sessionBounds(right);
  if (!a || !b || overlapMs(a, b) <= 0 || Math.abs(a.end - b.end) > 120_000) return false;
  const leftEnergy = Number(left.energy_kwh);
  const rightEnergy = Number(right.energy_kwh);
  if (!Number.isFinite(leftEnergy) || !Number.isFinite(rightEnergy)) return false;
  return Math.abs(leftEnergy - rightEnergy) <= Math.max(0.05, Math.max(leftEnergy, rightEnergy) * 0.01);
}

function preference(session) {
  const transaction = String(session?.external_session_id || '').startsWith('transaction:') ? 1 : 0;
  const updated = toMs(session?.raw_updated_at);
  const complete = ['external_session_id', 'started_at', 'ended_at', 'energy_kwh', 'provider_cost']
    .reduce((count, key) => count + (session?.[key] != null ? 1 : 0), 0);
  return [transaction, Number.isFinite(updated) ? updated : 0, complete];
}

function comparePreference(left, right) {
  const a = preference(left);
  const b = preference(right);
  for (let index = 0; index < a.length; index++) {
    if (a[index] !== b[index]) return b[index] - a[index];
  }
  return 0;
}

function deduplicateSessions(sessions) {
  const kept = [];
  for (const session of [...sessions].sort(comparePreference)) {
    if (!kept.some(existing => isDuplicate(existing, session))) kept.push(session);
  }
  return kept;
}

function currentTariff(config, atMs) {
  return (Array.isArray(config?.tariffs) ? config.tariffs : [])
    .filter(item => Number(item?.effective_from_ms) <= atMs && Number.isFinite(Number(item?.price_per_kwh)))
    .sort((left, right) => Number(left.effective_from_ms) - Number(right.effective_from_ms))
    .at(-1)?.price_per_kwh;
}

function round(value, digits) {
  return Number(Number(value).toFixed(digits));
}

function shouldRetryChargeMeter(status, nowMs, deadlineMs) {
  return status !== 'matched' && Number(nowMs) < Number(deadlineMs);
}

function shouldFillChargeMeterEnergy(current, candidate) {
  return !(Number(current) > 0) && Number(candidate) > 0;
}

function resolveProviderReconciliation(result, providerStates) {
  const failed = (Array.isArray(providerStates) ? providerStates : [])
    .some(state => state?.status === 'provider_unavailable');
  return failed && !result?.meter_key ? { status: 'pending_provider' } : result;
}

function terminalChargeMeterStatus(status, nowMs, deadlineMs) {
  if (status === 'matched' || shouldRetryChargeMeter(status, nowMs, deadlineMs)) return status;
  return 'failed';
}

function reconcileChargeMeter({ charge, configs, sessionsByKey }) {
  const chargeEnd = Number(charge?.timestamp_ms);
  const durationMs = Number(charge?.duration_sec) * 1000;
  if (!Number.isFinite(chargeEnd) || !(durationMs > 0)) return { status: 'invalid_charge' };
  const chargeRange = { start: chargeEnd - durationMs, end: chargeEnd };
  const candidates = [];

  for (const config of Array.isArray(configs) ? configs : []) {
    if (config?.enabled === false) continue;
    const key = chargeMeterKey(config);
    const sessions = deduplicateSessions(Array.isArray(sessionsByKey?.[key]) ? sessionsByKey[key] : [])
      .flatMap(session => {
        const bounds = sessionBounds(session);
        const overlap = bounds ? overlapMs(bounds, chargeRange) : 0;
        const gap = bounds ? gapMs(bounds, chargeRange) : Infinity;
        const energy = Number(session?.energy_kwh);
        return bounds && (overlap > 0 || gap <= 10 * 60_000) && energy > 0
          ? [{ session, bounds, overlap, gap, energy }] : [];
      });
    if (!sessions.length) continue;
    candidates.push({
      config,
      key,
      sessions,
      overlap: sessions.reduce((sum, item) => sum + item.overlap, 0),
      gap: Math.min(...sessions.map(item => item.gap)),
      endDistance: Math.abs(Math.max(...sessions.map(item => item.bounds.end)) - chargeEnd),
    });
  }

  if (!candidates.length) return { status: 'pending' };
  candidates.sort((left, right) => right.overlap - left.overlap || left.gap - right.gap || left.endDistance - right.endDistance);
  const winner = candidates[0];
  const tied = candidates.filter(candidate =>
    candidate.overlap === winner.overlap && candidate.gap === winner.gap
      && candidate.endDistance === winner.endDistance);
  if (tied.length > 1) return { status: 'ambiguous', candidates: tied.map(candidate => candidate.key) };

  const providerEnergy = round(winner.sessions.reduce((sum, item) => sum + item.energy, 0), 6);
  const energy = Number(charge?.charger_kwh) > 0 ? Number(charge.charger_kwh) : providerEnergy;
  let cost = charge?.cost_override ?? null;
  let status = 'matched';

  if (cost == null && winner.config.provider === 'zeeda') {
    const tariff = Number(currentTariff(winner.config, chargeRange.start));
    if (Number.isFinite(tariff) && tariff >= 0) {
      cost = tariff === 0
        ? { total: 0, perKwh: 0, free: true }
        : { total: round(energy * tariff, 2), perKwh: tariff };
    } else {
      status = 'missing_tariff';
    }
  } else if (cost == null && ['yellotmob', 'mhzmob'].includes(winner.config.provider)) {
    const providerCosts = winner.sessions.map(item => item.session.provider_cost);
    if (providerCosts.every(value => value != null && Number.isFinite(Number(value)))) {
      const total = round(providerCosts.reduce((sum, value) => sum + Number(value), 0), 2);
      cost = total === 0
        ? { total: 0, perKwh: 0, free: true }
        : { total, perKwh: round(total / providerEnergy, 4) };
    } else {
      status = 'pending';
    }
  }

  const result = {
    status,
    meter_key: winner.key,
    charger_kwh: energy,
  };
  if (cost != null) result.cost_override = cost;
  return result;
}

module.exports = {
  chargeMeterQueryWindow,
  deduplicateSessions,
  resolveProviderReconciliation,
  reconcileChargeMeter,
  shouldFillChargeMeterEnergy,
  shouldRetryChargeMeter,
  terminalChargeMeterStatus,
};
