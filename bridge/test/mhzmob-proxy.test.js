'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { createMhzMobProxy } = require('../mhzmob-proxy');

function fakeExpress() {
  const routes = [];
  return {
    routes,
    Router() {
      return {
        get(path, handler) { routes.push({ method: 'GET', path, handler }); },
        use(handler) { routes.push({ method: 'USE', handler }); },
      };
    },
  };
}

function fakeResponse() {
  return {
    statusCode: 200,
    body: null,
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
}

test('proxies only the allowlisted MHZ MOB read routes', async () => {
  const express = fakeExpress();
  const calls = [];
  createMhzMobProxy({
    express,
    baseUrl: 'http://127.0.0.1:8792',
    fetchImpl: async url => {
      calls.push(String(url));
      return {
        ok: true,
        status: 200,
        headers: { get: () => 'application/json' },
        json: async () => ({ items: [{ id: '4', name: 'MHZ MOB - PREMIER' }] }),
      };
    },
  });
  const handler = express.routes.find(route => route.method === 'GET').handler;
  const response = fakeResponse();
  await handler({ method: 'GET', path: '/chargers', url: '/chargers' }, response);

  assert.equal(response.statusCode, 200);
  assert.deepEqual(response.body, { items: [{ id: '4', name: 'MHZ MOB - PREMIER' }] });
  assert.deepEqual(calls, ['http://127.0.0.1:8792/api/chargers']);

  const blocked = fakeResponse();
  await handler({ method: 'GET', path: '/admin', url: '/admin' }, blocked);
  assert.equal(blocked.statusCode, 404);
  assert.deepEqual(blocked.body, { error: 'not_found' });
});

test('bounds MHZ MOB upstream errors without leaking payloads', async () => {
  const express = fakeExpress();
  createMhzMobProxy({
    express,
    fetchImpl: async () => ({
      ok: false,
      status: 500,
      headers: { get: () => 'application/json' },
      json: async () => ({ error: 'secret failure', raw: { token: 'omit' } }),
    }),
  });
  const handler = express.routes.find(route => route.method === 'GET').handler;
  const response = fakeResponse();
  await handler({ method: 'GET', path: '/sessions', url: '/sessions' }, response);

  assert.equal(response.statusCode, 502);
  assert.deepEqual(response.body, { error: 'mhzmob_unavailable' });
});
