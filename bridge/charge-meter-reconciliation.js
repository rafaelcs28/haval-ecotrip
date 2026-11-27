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

function previousChargeMeterClaims(charges, beforeTimestamp) {
  return (Array.isArray(charges) ? charges : []).flatMap(charge => {
    if (Number(charge?.timestamp_ms) >= Number(beforeTimestamp)) return [];
    if (charge?.charge_meter_reconcile?.status !== 'matched' || !charge?.charge_meter_key) return [];
    return (Array.isArray(charge.charge_meter_claims) ? charge.charge_meter_claims : []).map(claim => ({
      meter_key: charge.charge_meter_key,
      ...claim,
    }));
  });
}

function mergeChargeMeterClaims(...charges) {
  const merged = new Map();
  for (const charge of charges) {
    for (const claim of Array.isArray(charge?.charge_meter_claims) ? charge.charge_meter_claims : []) {
      const meterKey = claim?.meter_key || charge?.charge_meter_key;
      const sessionId = claim?.session_id;
      if (!meterKey || !sessionId) continue;
      const key = `${meterKey}\0${sessionId}`;
      const current = merged.get(key) || {
        meter_key: meterKey,
        session_id: sessionId,
        energy_kwh: 0,
        cost_brl: 0,
        cost_known: true,
      };
      current.energy_kwh += Number(claim.energy_kwh) || 0;
      if (claim.cost_brl == null || !Number.isFinite(Number(claim.cost_brl))) current.cost_known = false;
      else current.cost_brl += Number(claim.cost_brl);
      merged.set(key, current);
    }
  }
  return [...merged.values()].map(({ cost_known: costKnown, ...claim }) => ({
    ...claim,
    energy_kwh: round(claim.energy_kwh, 6),
    cost_brl: costKnown ? round(claim.cost_brl, 2) : null,
  }));
}

function reconcileChargeMeter({ charge, configs, sessionsByKey, previousClaims = [] }) {
  const chargeEnd = Number(charge?.timestamp_ms);
  const durationMs = Number(charge?.duration_sec) * 1000;
  if (!Number.isFinite(chargeEnd) || !(durationMs > 0)) return { status: 'invalid_charge' };
  const chargeRange = { start: chargeEnd - durationMs, end: chargeEnd };
  const candidates = [];
  const claimed = new Map();
  for (const claim of Array.isArray(previousClaims) ? previousClaims : []) {
    if (!claim?.meter_key || !claim?.session_id) continue;
    const key = `${claim.meter_key}\0${claim.session_id}`;
    const previous = claimed.get(key) || { energy: 0, cost: 0, costKnown: true };
    previous.energy += Number(claim.energy_kwh) || 0;
    if (claim.cost_brl == null || !Number.isFinite(Number(claim.cost_brl))) previous.costKnown = false;
    else previous.cost += Number(claim.cost_brl);
    claimed.set(key, previous);
  }

  for (const config of Array.isArray(configs) ? configs : []) {
    if (config?.enabled === false) continue;
    const key = chargeMeterKey(config);
    const sessions = deduplicateSessions(Array.isArray(sessionsByKey?.[key]) ? sessionsByKey[key] : [])
      .flatMap(session => {
        const bounds = sessionBounds(session);
        const overlap = bounds ? overlapMs(bounds, chargeRange) : 0;
        const gap = bounds ? gapMs(bounds, chargeRange) : Infinity;
        const energy = Number(session?.energy_kwh);
        const sessionId = String(session?.external_session_id || '');
        const prior = claimed.get(`${key}\0${sessionId}`) || { energy: 0, cost: 0, costKnown: true };
        const continuation = sessionId && prior.energy > 0 && energy > prior.energy;
        const netEnergy = round(energy - prior.energy, 6);
        const providerCost = session?.provider_cost == null ? null : Number(session.provider_cost);
        const netCost = Number.isFinite(providerCost) && prior.costKnown
          ? round(providerCost - prior.cost, 2) : null;
        return bounds && (overlap > 0 || gap <= 10 * 60_000 || continuation) && netEnergy > 0
          ? [{ session, sessionId, bounds, overlap, gap, energy: netEnergy, cost: netCost }] : [];
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
  const energy = Number(charge?.charger_kwh) > 0 && charge?.charge_meter_auto_fields?.charger_kwh !== true
    ? Number(charge.charger_kwh) : providerEnergy;
  let cost = charge?.cost_override != null && charge?.charge_meter_auto_fields?.cost_override !== true
    ? charge.cost_override : null;
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
    const providerCosts = winner.sessions.map(item => item.cost);
    if (providerCosts.every(value => value != null && Number.isFinite(Number(value)) && Number(value) >= 0)) {
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
    meter_claims: winner.sessions.map(item => ({
      meter_key: winner.key,
      session_id: item.sessionId,
      energy_kwh: item.energy,
      cost_brl: item.cost,
    })),
  };
  if (cost != null) result.cost_override = cost;
  return result;
}

module.exports = {
  chargeMeterQueryWindow,
  deduplicateSessions,
  mergeChargeMeterClaims,
  resolveProviderReconciliation,
  reconcileChargeMeter,
  previousChargeMeterClaims,
  shouldFillChargeMeterEnergy,
  shouldRetryChargeMeter,
  terminalChargeMeterStatus,
};
