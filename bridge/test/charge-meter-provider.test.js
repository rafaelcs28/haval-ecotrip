'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { getCurrentChargeMeterSession, listChargeMeterSessions } = require('../charge-meter-provider');

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

test('loads MHZ MOB through its Bridge namespace and ignores the upstream provider field', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url: String(url), authorization: options.headers.Authorization });
    const cursor = new URL(url).searchParams.get('cursor');
    return new Response(JSON.stringify(cursor === '0' ? {
      items: [{
        provider: 'yellotmob',
        external_session_id: 'transaction:2084',
        charger_id: '4',
        charger_name: 'MHZ MOB - PREMIER',
        started_at: '2026-10-17T13:20:23.367Z',
        ended_at: '2026-10-17T13:45:56.367Z',
        energy_kwh: 20.722,
        provider_cost: 32.88,
        status: 'Pago',
        raw_updated_at: null,
        raw: { token: 'omit' },
      }],
      next_cursor: 100,
    } : {
      items: [],
      next_cursor: null,
    }), { status: 200, headers: { 'content-type': 'application/json' } });
  };

  const sessions = await listChargeMeterSessions('mhzmob', '4', from, to, {
    fetchImpl,
    mhzmobUrl: 'http://127.0.0.1:3000',
    mhzmobToken: 'bridge-hash',
  });

  assert.equal(calls[0].url, `http://127.0.0.1:3000/api/mhzmob/sessions?charger=4&from=${encodeURIComponent(from)}&to=${encodeURIComponent(to)}&limit=100&cursor=0`);
  assert.deepEqual(calls.map(call => new URL(call.url).searchParams.get('cursor')), ['0', '100']);
  assert.ok(calls.every(call => call.authorization === 'Bearer bridge-hash'));
  assert.deepEqual(sessions, [{
    provider: 'mhzmob',
    external_session_id: 'transaction:2084',
    charger_id: '4',
    charger_name: 'MHZ MOB - PREMIER',
    started_at: '2026-10-17T13:20:23.367Z',
    ended_at: '2026-10-17T13:45:56.367Z',
    energy_kwh: 20.722,
    power_kw: null,
    provider_cost: 32.88,
    status: 'Pago',
    raw_updated_at: null,
  }]);
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

test('keeps YellotMob Charging active when power is absent', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url: String(url), headers: options.headers });
    return new Response(JSON.stringify({
      item: {
        provider: 'yellotmob', external_session_id: 'charging:472330', charger_id: '273',
        charger_name: 'Pão de Açúcar T-63', started_at: '2026-11-20T17:09:01.000Z',
        ended_at: null, energy_kwh: 11.106, power_kw: null, provider_cost: 10.03,
        status: 'Charging', raw_updated_at: null, raw: { token: 'omit' },
      },
    }), { status: 200, headers: { 'content-type': 'application/json' } });
  };

  const item = await getCurrentChargeMeterSession('yellotmob', '273', {
    fetchImpl, yellotmobUrl: 'http://127.0.0.1:8790',
  });

  assert.equal(calls[0].url, 'http://127.0.0.1:8790/api/current-session?charger=273');
  assert.deepEqual(calls[0].headers, {});
  assert.deepEqual(item, {
    provider: 'yellotmob', external_session_id: 'charging:472330', charger_id: '273',
    charger_name: 'Pão de Açúcar T-63', started_at: '2026-11-20T17:09:01.000Z',
    ended_at: null, energy_kwh: 11.106, power_kw: null, provider_cost: 10.03,
    status: 'Charging', raw_updated_at: null,
  });
});

test('normalizes active Zeeda live data and rejects stale session energy when inactive', async () => {
  const payloads = [{
    deviceCode: 'D4', name: 'Jardins Lisboa', online: true, connectorStatus: '2.0',
    currentPowerKw: 6.16, sessionEnergyKwh: 0.631, elapsedSeconds: 377, secret: 'omit',
  }, {
    deviceCode: 'D4', name: 'Jardins Lisboa', online: true, connectorStatus: '0.0',
    currentPowerKw: 0, sessionEnergyKwh: 18.982, elapsedSeconds: 23618,
  }];
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url: String(url), authorization: options.headers.Authorization });
    return new Response(JSON.stringify(payloads.shift()), { status: 200 });
  };
  const options = {
    fetchImpl, zeedaUrl: 'http://127.0.0.1:8788', zeedaToken: 'bridge-hash',
  };

  const active = await getCurrentChargeMeterSession('zeeda', 'D4', options);
  const inactive = await getCurrentChargeMeterSession('zeeda', 'D4', options);

  assert.equal(calls[0].url, 'http://127.0.0.1:8788/api/zeeda/chargers/D4/live');
  assert.ok(calls.every(call => call.authorization === 'Bearer bridge-hash'));
  assert.deepEqual(active, {
    provider: 'zeeda', external_session_id: '', charger_id: 'D4',
    charger_name: 'Jardins Lisboa', started_at: null, ended_at: null,
    energy_kwh: 0.631, power_kw: 6.16, provider_cost: null,
    status: 'Charging', raw_updated_at: null,
  });
  assert.equal(inactive, null);
});

test('loads active MHZ MOB through the authenticated Bridge namespace', async () => {
  const calls = [];
  const fetchImpl = async (url, options) => {
    calls.push({ url: String(url), authorization: options.headers.Authorization });
    return new Response(JSON.stringify({ item: {
      provider: 'yellotmob', external_session_id: 'charging:8', charger_id: '4',
      charger_name: 'MHZ MOB - PREMIER', energy_kwh: 3.2, power_kw: 7.4,
      provider_cost: 5.1, status: 'Charging', raw: { token: 'omit' },
    } }), { status: 200 });
  };

  const item = await getCurrentChargeMeterSession('mhzmob', '4', {
    fetchImpl, mhzmobUrl: 'http://127.0.0.1:3000', mhzmobToken: 'bridge-hash',
  });

  assert.equal(calls[0].url, 'http://127.0.0.1:3000/api/mhzmob/current-session?charger=4');
  assert.equal(calls[0].authorization, 'Bearer bridge-hash');
  assert.equal(item.provider, 'mhzmob');
  assert.equal(Object.hasOwn(item, 'raw'), false);
});
