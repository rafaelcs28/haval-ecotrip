'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { listChargeMeterSessions } = require('../charge-meter-provider');

const from = '2026-11-15T12:00:00.000Z';
const to = '2026-11-15T13:00:00.000Z';

test('paginates YellotMob sessions and removes raw payloads', async () => {
  const urls = [];
  const fetchImpl = async url => {
    urls.push(String(url));
    const cursor = new URL(url).searchParams.get('cursor');
    return new Response(JSON.stringify(cursor === '0' ? {
      items: [{
        provider: 'yellotmob', external_session_id: 'transaction:1', charger_id: '273',
        charger_name: 'T-63', started_at: from, ended_at: to, energy_kwh: 22.502,
        provider_cost: 31.11, status: 'Pago', raw_updated_at: null, raw: { address: 'secret' },
      }],
      next_cursor: 100,
    } : {
      items: [{
        provider: 'yellotmob', external_session_id: 'transaction:2', charger_id: '273',
        charger_name: 'T-63', started_at: from, ended_at: to, energy_kwh: 3,
        provider_cost: 4, status: 'Pago', raw: { token: 'secret' },
      }],
      next_cursor: null,
    }), { status: 200, headers: { 'content-type': 'application/json' } });
  };

  const sessions = await listChargeMeterSessions('yellotmob', '273', from, to, {
    fetchImpl,
    yellotmobUrl: 'http://127.0.0.1:8790',
  });

  assert.equal(sessions.length, 2);
  assert.equal(Object.hasOwn(sessions[0], 'raw'), false);
  assert.deepEqual(sessions.map(item => item.external_session_id), ['transaction:1', 'transaction:2']);
  assert.deepEqual(urls.map(url => new URL(url).searchParams.get('cursor')), ['0', '100']);
});

test('normalizes paginated Zeeda sessions with loopback gateway auth', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url: String(url), authorization: options.headers.Authorization, signal: options.signal });
    return new Response(JSON.stringify({
      items: [{
        id: 9, deviceCode: 'D4', vendorTransactionId: 'tx-9',
        startedAtMs: Date.parse(from), endedAtMs: Date.parse(to), energyKwh: 9.018,
        averagePowerKw: 6.2, status: 'completed', secret: 'omit',
      }],
      nextCursor: null,
    }), { status: 200, headers: { 'content-type': 'application/json' } });
  };

  const sessions = await listChargeMeterSessions('zeeda', 'D4', from, to, {
    fetchImpl,
    zeedaUrl: 'http://127.0.0.1:8788',
    zeedaToken: 'bridge-hash',
  });

  assert.deepEqual(sessions, [{
    provider: 'zeeda',
    external_session_id: 'transaction:tx-9',
    charger_id: 'D4',
    charger_name: 'D4',
    started_at: from,
    ended_at: to,
    energy_kwh: 9.018,
    power_kw: 6.2,
    provider_cost: null,
    status: 'completed',
    raw_updated_at: null,
  }]);
  const query = new URL(calls[0].url).searchParams;
  assert.equal(query.get('charger'), 'D4');
  assert.equal(query.get('from'), String(Date.parse(from)));
  assert.equal(query.get('to'), String(Date.parse(to)));
  assert.equal(calls[0].authorization, 'Bearer bridge-hash');
  assert.ok(calls[0].signal instanceof AbortSignal);
});

test('maps upstream failures to a stable error without response data', async () => {
  await assert.rejects(
    listChargeMeterSessions('yellotmob', '273', from, to, {
      fetchImpl: async () => new Response(JSON.stringify({ token: 'do-not-leak' }), { status: 500 }),
    }),
    error => error.code === 'provider_unavailable'
      && error.message === 'yellotmob indisponível'
      && !error.message.includes('do-not-leak')
  );

  await assert.rejects(
    listChargeMeterSessions('zeeda', 'D4', from, to, {
      fetchImpl: async () => { throw new Error('socket secret'); },
    }),
    error => error.code === 'provider_unavailable' && !error.message.includes('socket secret')
  );
});

test('keeps charger requests separate', async () => {
  const chargers = [];
  const fetchImpl = async url => {
    chargers.push(new URL(url).searchParams.get('charger'));
    return new Response(JSON.stringify({ items: [], next_cursor: null }), { status: 200 });
  };

  await Promise.all([
    listChargeMeterSessions('yellotmob', '273', from, to, { fetchImpl }),
    listChargeMeterSessions('yellotmob', '274', from, to, { fetchImpl }),
  ]);

  assert.deepEqual(chargers.sort(), ['273', '274']);
});
