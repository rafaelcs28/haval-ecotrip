'use strict';

const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const http = require('node:http');
const test = require('node:test');
const express = require('express');
const { WebSocket } = require('ws');

const {
  VideoRelay,
  VideoCommandBroker,
  parseHvc1,
  parseHvt1,
  MAX_BUFFERED_BYTES,
} = require('../video-relay');

class FakeSocket extends EventEmitter {
  constructor() {
    super();
    this.readyState = WebSocket.OPEN;
    this.bufferedAmount = 0;
    this.sent = [];
    this.closed = [];
  }

  send(data, options, callback) {
    this.sent.push({ data, options });
    callback?.();
  }

  close(code, reason) {
    if (this.readyState === WebSocket.CLOSED) return;
    this.readyState = WebSocket.CLOSED;
    this.closed.push({ code, reason });
    this.emit('close', code, Buffer.from(reason || ''));
  }

  terminate() {
    this.close(4000, 'terminated');
  }
}

function hvc1({ type = 2, keyframe = false, payload = Buffer.from([0, 0, 0, 1, 0x61]) } = {}) {
  const frame = Buffer.alloc(24 + payload.length);
  frame.write('HVC1', 0, 'ascii');
  frame.writeUInt8(1, 4);
  frame.writeUInt8(type, 5);
  frame.writeUInt16BE(keyframe ? 1 : 0, 6);
  frame.writeUInt32BE(7, 8);
  frame.writeBigUInt64BE(66_667n, 12);
  frame.writeUInt32BE(payload.length, 20);
  payload.copy(frame, 24);
  return frame;
}

function fixture(options = {}) {
  let now = 1_700_000_000_000;
  let randomByte = 1;
  const commands = [];
  const logs = [];
  const relay = new VideoRelay({
    now: () => now,
    randomBytes: size => Buffer.alloc(size, randomByte++),
    logger: (event, fields) => logs.push({ event, fields }),
    sendCarCommand: async (command, payload) => commands.push({ command, payload }),
    ...options,
  });
  return {
    relay,
    commands,
    logs,
    advance(ms) { now += ms; },
  };
}

async function create(relay) {
  return relay.createSession({ publicUrl: 'https://bridge.example' });
}

function attach(relay, role, sessionId, token, socket = new FakeSocket()) {
  relay.attach(role, {
    url: `/ws/video/live/${role === 'producer' ? 'car' : 'viewer'}?session=${sessionId}`,
    headers: { authorization: `Bearer ${token}` },
  }, socket);
  return socket;
}

test('REST session creation requires owner auth and sends only producer credentials to the car', async t => {
  const { relay, commands } = fixture();
  const app = express();
  app.use(express.json());
  const requireOwner = (req, res, next) => req.headers.authorization === 'Bearer owner'
    ? next()
    : res.status(401).json({ error: 'unauthorized' });
  relay.installRoutes(app, { requireAuth: requireOwner, publicUrl: () => 'https://bridge.example' });
  const server = http.createServer(app);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;

  const denied = await fetch(`${base}/api/video/live/session`, { method: 'POST' });
  assert.equal(denied.status, 401);

  const accepted = await fetch(`${base}/api/video/live/session`, {
    method: 'POST',
    headers: { authorization: 'Bearer owner', 'content-type': 'application/json' },
    body: '{}',
  });
  assert.equal(accepted.status, 201);
  const body = await accepted.json();
  assert.match(body.sessionId, /^[A-Za-z0-9_-]+$/);
  assert.equal(body.producerToken, undefined);
  assert.notEqual(body.viewerToken, commands[0].payload.producerToken);
  assert.match(body.viewerUrl, /^wss:\/\/bridge\.example\/ws\/video\/live\/viewer\?/);
  assert.equal(commands[0].command, 'video_live_start');
  assert.equal(commands[0].payload.requestId, body.sessionId);
  assert.equal(commands[0].payload.sessionUrl.includes(commands[0].payload.producerToken), false);
  assert.equal(body.viewerUrl.includes(body.viewerToken), false);
  assert.equal(JSON.stringify(commands[0]).includes(body.viewerToken), false);
});

test('tokens are scoped, expire after 60 seconds, and cannot create duplicate roles', async () => {
  const { relay, advance } = fixture();
  const session = await create(relay);

  const wrongRole = attach(relay, 'producer', session.sessionId, session.viewerToken);
  assert.equal(wrongRole.closed[0].code, 4003);

  const wrongSession = attach(relay, 'producer', 'another-session', session.producerToken);
  assert.equal(wrongSession.closed[0].code, 4003);

  const producer = attach(relay, 'producer', session.sessionId, session.producerToken);
  assert.equal(producer.closed.length, 0);
  const duplicate = attach(relay, 'producer', session.sessionId, session.producerToken);
  assert.equal(duplicate.closed[0].code, 4005);

  relay.closeSession(session.sessionId, 'test');
  const expiredSession = await create(relay);
  advance(60_001);
  const expired = attach(relay, 'viewer', expiredSession.sessionId, expiredSession.viewerToken);
  assert.equal(expired.closed[0].code, 4002);
});

test('plain HTTP WebSocket upgrade is rejected because video credentials are TLS-only', async t => {
  const { relay } = fixture();
  const session = await create(relay);
  const server = http.createServer();
  server.on('upgrade', (request, socket, head) => relay.handleUpgrade(request, socket, head));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());

  const socket = new WebSocket(
    `ws://127.0.0.1:${server.address().port}/ws/video/live/car?session=${session.sessionId}`,
    { headers: { authorization: `Bearer ${session.producerToken}` } },
  );
  t.after(() => socket.terminate());
  const status = await new Promise((resolve, reject) => {
    socket.once('open', () => reject(new Error('insecure video socket opened')));
    socket.once('unexpected-response', (_request, response) => resolve(response.statusCode));
    socket.once('error', reject);
  });
  assert.equal(status, 426);
});

test('public session URL must be HTTPS and is always emitted as WSS', async () => {
  const { relay, commands } = fixture();
  await assert.rejects(
    relay.createSession({ publicUrl: 'http://bridge.example' }),
    error => error.code === 'invalid_video_public_url',
  );
  assert.equal(commands.length, 0);
  assert.equal(relay.sessions.size, 0);
});

test('forwarded HTTPS is trusted only from an allowlisted proxy address', async () => {
  const { relay } = fixture({ trustedProxyAddresses: ['10.0.0.2'] });
  const session = await create(relay);
  let upgrades = 0;
  relay.producerWss.handleUpgrade = () => { upgrades += 1; };
  const raw = () => ({ output: '', destroyed: false, write(value) { this.output += value; }, destroy() { this.destroyed = true; } });
  const request = remoteAddress => ({
    url: `/ws/video/live/car?session=${session.sessionId}`,
    headers: { authorization: `Bearer ${session.producerToken}`, 'x-forwarded-proto': 'https' },
    socket: { remoteAddress },
  });

  const forged = raw();
  relay.handleUpgrade(request('203.0.113.7'), forged, Buffer.alloc(0));
  assert.match(forged.output, /^HTTP\/1\.1 426 /);
  assert.equal(upgrades, 0);

  relay.handleUpgrade(request('10.0.0.2'), raw(), Buffer.alloc(0));
  assert.equal(upgrades, 1);
});

test('invalid upgrades are rejected before ws handleUpgrade and rate-limited per IP', async () => {
  const { relay, logs } = fixture({ invalidUpgradeLimit: 2, invalidUpgradeWindowMs: 60_000 });
  const session = await create(relay);
  let upgrades = 0;
  relay.producerWss.handleUpgrade = () => { upgrades += 1; };
  const outputs = [];
  for (let i = 0; i < 3; i++) {
    const raw = { output: '', write(value) { this.output += value; }, destroy() {} };
    relay.handleUpgrade({
      url: `/ws/video/live/car?session=${session.sessionId}`,
      headers: { authorization: 'Bearer invalid-secret' },
      socket: { encrypted: true, remoteAddress: '198.51.100.9' },
    }, raw, Buffer.alloc(0));
    outputs.push(raw.output);
  }

  assert.equal(upgrades, 0);
  assert.match(outputs[0], /^HTTP\/1\.1 401 /);
  assert.match(outputs[2], /^HTTP\/1\.1 429 /);
  assert.equal(relay.invalidAttempts.size <= 1, true);
  assert.equal(JSON.stringify(logs).includes('invalid-secret'), false);
});

test('valid proxy upgrade bypasses an invalid-attempt bucket poisoned by other clients', async () => {
  const proxyIp = '10.0.0.2';
  const { relay, logs } = fixture({
    trustedProxyAddresses: [proxyIp],
    invalidUpgradeLimit: 2,
    invalidUpgradeWindowMs: 60_000,
  });
  const session = await create(relay);
  let upgrades = 0;
  relay.producerWss.handleUpgrade = () => { upgrades += 1; };
  const request = token => ({
    url: `/ws/video/live/car?session=${session.sessionId}`,
    headers: { authorization: `Bearer ${token}`, 'x-forwarded-proto': 'https' },
    socket: { remoteAddress: proxyIp },
  });
  const raw = () => ({ output: '', write(value) { this.output += value; }, destroy() {} });
  relay.handleUpgrade(request('invalid-one'), raw(), Buffer.alloc(0));
  relay.handleUpgrade(request('invalid-two'), raw(), Buffer.alloc(0));
  const poisoned = raw();
  relay.handleUpgrade(request('invalid-three'), poisoned, Buffer.alloc(0));
  assert.match(poisoned.output, /^HTTP\/1\.1 429 /);

  relay.handleUpgrade(request(session.producerToken), raw(), Buffer.alloc(0));

  assert.equal(upgrades, 1);
  assert.equal(JSON.stringify(logs).includes(session.producerToken), false);
});

test('viewer join requests a keyframe and HVC1 bytes relay without payload logging', async () => {
  const { relay, logs } = fixture();
  const session = await create(relay);
  const producer = attach(relay, 'producer', session.sessionId, session.producerToken);
  const viewer = attach(relay, 'viewer', session.sessionId, session.viewerToken);
  assert.deepEqual(JSON.parse(producer.sent[0].data), { type: 'request_keyframe' });

  const marker = Buffer.from('secret-video-payload');
  const payload = Buffer.alloc(4 + marker.length);
  payload.writeUInt32BE(marker.length, 0);
  marker.copy(payload, 4);
  const frame = hvc1({ keyframe: true, payload });
  producer.emit('message', frame, true);
  assert.equal(viewer.sent.length, 1);
  assert.equal(viewer.sent[0].data, frame);
  assert.equal(viewer.sent[0].options.binary, true);
  assert.equal(JSON.stringify(logs).includes(marker.toString()), false);
  assert.equal(JSON.stringify(logs).includes(marker.toString('hex')), false);
});

test('producer joining after viewer still receives keyframe request', async () => {
  const { relay } = fixture();
  const session = await create(relay);
  attach(relay, 'viewer', session.sessionId, session.viewerToken);
  const producer = attach(relay, 'producer', session.sessionId, session.producerToken);

  assert.deepEqual(JSON.parse(producer.sent[0].data), { type: 'request_keyframe' });
});

test('malformed HVC1 closes producer with protocol error', async () => {
  const { relay } = fixture();
  const session = await create(relay);
  const producer = attach(relay, 'producer', session.sessionId, session.producerToken);
  attach(relay, 'viewer', session.sessionId, session.viewerToken);
  producer.emit('message', Buffer.from('not-hvc1'), true);
  assert.equal(producer.closed[0].code, 4004);
});

test('HVC1 CONFIG payload requires complete non-empty SPS and PPS', () => {
  const invalid = [
    Buffer.from([0, 0, 0, 1, 0x68]),
    Buffer.from([0, 2, 0x67]),
    Buffer.from([0, 1, 0x67, 0, 0]),
    Buffer.from([0, 1, 0x67, 0, 1, 0x68, 0]),
  ];
  for (const payload of invalid) {
    assert.throws(() => parseHvc1(hvc1({ type: 1, payload })), /HVC1/);
  }
  assert.equal(parseHvc1(hvc1({ type: 1, payload: Buffer.from([0, 1, 0x67, 0, 1, 0x68]) })).type, 1);
});

test('HVC1 ACCESS_UNIT payload requires complete non-empty length-prefixed NAL units', () => {
  const invalid = [
    Buffer.from([0, 0, 0, 0]),
    Buffer.from([0, 0, 0, 2, 0x65]),
    Buffer.from([0, 0, 0, 1, 0x65, 0]),
  ];
  for (const payload of invalid) {
    assert.throws(() => parseHvc1(hvc1({ payload })), /HVC1/);
  }
  const twoNals = Buffer.from([0, 0, 0, 1, 0x65, 0, 0, 0, 1, 0x61]);
  assert.equal(parseHvc1(hvc1({ keyframe: true, payload: twoNals })).keyframe, true);
});

test('backpressure drops frames, requests recovery, and never queues video bytes', async () => {
  const { relay, advance } = fixture();
  const session = await create(relay);
  const producer = attach(relay, 'producer', session.sessionId, session.producerToken);
  const viewer = attach(relay, 'viewer', session.sessionId, session.viewerToken);
  producer.sent.length = 0;
  advance(1_001);
  viewer.bufferedAmount = 1_048_577;

  producer.emit('message', hvc1(), true);
  producer.emit('message', hvc1({ type: 1, payload: Buffer.from([0, 1, 0x67, 0, 1, 0x68]) }), true);

  assert.equal(viewer.sent.length, 0);
  assert.equal(producer.readyState, WebSocket.OPEN);
  assert.deepEqual(JSON.parse(producer.sent.at(-1).data), { type: 'request_keyframe' });
  assert.deepEqual(relay.stats(session.sessionId), { queuedFrames: 0, droppedFrames: 2 });
});

test('buffer cap includes the incoming frame length', async () => {
  const { relay } = fixture();
  const session = await create(relay);
  const producer = attach(relay, 'producer', session.sessionId, session.producerToken);
  const viewer = attach(relay, 'viewer', session.sessionId, session.viewerToken);
  const frame = hvc1();
  viewer.bufferedAmount = MAX_BUFFERED_BYTES - frame.length + 1;

  producer.emit('message', frame, true);

  assert.equal(viewer.sent.length, 0);
  assert.equal(relay.stats(session.sessionId).droppedFrames, 1);
});

test('recovery forwards only CONFIG and next keyframe while keyframe requests are rate-limited', async () => {
  const { relay, advance } = fixture();
  const session = await create(relay);
  const producer = attach(relay, 'producer', session.sessionId, session.producerToken);
  const viewer = attach(relay, 'viewer', session.sessionId, session.viewerToken);
  producer.sent.length = 0;
  advance(1_001);
  viewer.bufferedAmount = MAX_BUFFERED_BYTES;
  producer.emit('message', hvc1(), true);
  producer.emit('message', hvc1(), true);
  assert.equal(producer.sent.length, 1);
  advance(1_001);
  producer.emit('message', hvc1(), true);
  assert.equal(producer.sent.length, 2);

  viewer.bufferedAmount = 0;
  const config = hvc1({ type: 1, payload: Buffer.from([0, 1, 0x67, 0, 1, 0x68]) });
  const delta = hvc1();
  const keyframe = hvc1({ keyframe: true, payload: Buffer.from([0, 0, 0, 1, 0x65]) });
  producer.emit('message', delta, true);
  producer.emit('message', config, true);
  producer.emit('message', delta, true);
  producer.emit('message', keyframe, true);
  producer.emit('message', delta, true);

  assert.deepEqual(viewer.sent.map(entry => entry.data), [config, keyframe, delta]);
});

test('MQTT publish callback does not confirm command before correlated Camera result', async () => {
  let published;
  const broker = new VideoCommandBroker({
    timeoutMs: 100,
    publish: (command, payload, callback) => { published = { command, payload }; callback(null); },
  });
  let settled = false;
  const pending = broker.send('video_live_start', { requestId: 'req-1' }).finally(() => { settled = true; });
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(settled, false);
  assert.equal(published.command, 'video_live_start');

  broker.acceptResult('video_live_start', Buffer.from('{"ok":true,"requestId":"req-1"}'));
  await pending;
  assert.equal(settled, true);
});

test('Camera rejection and command timeout reject the pending MQTT command', async () => {
  const rejected = new VideoCommandBroker({
    timeoutMs: 100,
    publish: (_command, _payload, callback) => callback(null),
  });
  const rejectedPromise = rejected.send('video_live_stop', { requestId: 'req-2' });
  rejected.acceptResult('video_live_stop', Buffer.from('{"ok":false,"requestId":"req-2","error":"camera unavailable"}'));
  await assert.rejects(rejectedPromise, error => error.code === 'camera_rejected');

  const timedOut = new VideoCommandBroker({
    timeoutMs: 10,
    publish: (_command, _payload, callback) => callback(null),
  });
  await assert.rejects(
    timedOut.send('video_live_start', { requestId: 'req-3' }),
    error => error.code === 'camera_command_timeout',
  );
});

test('session creation times out and late command completion cannot return expired credentials', async () => {
  let startResolve;
  let startPayload;
  const relay = new VideoRelay({
    commandTimeoutMs: 15,
    sendCarCommand: (command, payload) => {
      startPayload = payload;
      if (command === 'video_live_stop') return Promise.resolve();
      return new Promise(resolve => { startResolve = resolve; });
    },
  });
  await assert.rejects(
    relay.createSession({ publicUrl: 'https://bridge.example' }),
    error => error.code === 'camera_command_timeout',
  );
  assert.equal(relay.hasSession(startPayload.requestId), false);
  startResolve();
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(relay.hasSession(startPayload.requestId), false);
});

test('late accepted start cannot return credentials after the session was closed', async () => {
  let resolveStart;
  let sessionId;
  const relay = new VideoRelay({
    commandTimeoutMs: 1_000,
    sendCarCommand: (command, payload) => {
      if (command === 'video_live_stop') return Promise.resolve();
      sessionId = payload.requestId;
      return new Promise(resolve => { resolveStart = resolve; });
    },
  });
  const pending = relay.createSession({ publicUrl: 'https://bridge.example' });
  await new Promise(resolve => setImmediate(resolve));
  await relay.closeSession(sessionId, 'test');
  resolveStart();
  await assert.rejects(pending, error => error.code === 'video_session_expired');
});

test('POST does not return 201 before Camera confirms start', async t => {
  let confirmStart;
  let markDispatched;
  const dispatched = new Promise(resolve => { markDispatched = resolve; });
  const relay = new VideoRelay({
    sendCarCommand: command => command === 'video_live_start'
      ? new Promise(resolve => { confirmStart = resolve; markDispatched(); })
      : Promise.resolve(),
  });
  const app = express();
  app.use(express.json());
  relay.installRoutes(app, {
    requireAuth: (_req, _res, next) => next(),
    publicUrl: () => 'https://bridge.example',
  });
  const server = http.createServer(app);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;
  let settled = false;
  const response = fetch(`${base}/api/video/live/session`, { method: 'POST', body: '{}' })
    .finally(() => { settled = true; });
  await dispatched;
  assert.equal(settled, false);

  confirmStart();
  assert.equal((await response).status, 201);
});

test('DELETE reports failure when Camera does not confirm stop', async t => {
  const relay = new VideoRelay({
    sendCarCommand: async command => {
      if (command === 'video_live_stop') {
        const error = new Error('rejected');
        error.code = 'camera_rejected';
        throw error;
      }
    },
  });
  const app = express();
  app.use(express.json());
  const auth = (_req, _res, next) => next();
  relay.installRoutes(app, { requireAuth: auth, publicUrl: () => 'https://bridge.example' });
  const server = http.createServer(app);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;
  const created = await fetch(`${base}/api/video/live/session`, { method: 'POST', body: '{}' }).then(r => r.json());

  const stopped = await fetch(`${base}/api/video/live/session/${created.sessionId}`, { method: 'DELETE' });

  assert.equal(stopped.status, 503);
  assert.deepEqual(await stopped.json(), { error: 'camera_rejected' });
});

test('viewer disconnect cleans both sockets and sends stop without credentials', async () => {
  const { relay, commands } = fixture();
  const session = await create(relay);
  const producer = attach(relay, 'producer', session.sessionId, session.producerToken);
  const viewer = attach(relay, 'viewer', session.sessionId, session.viewerToken);

  viewer.close(1000, 'done');
  await new Promise(resolve => setImmediate(resolve));

  assert.equal(relay.hasSession(session.sessionId), false);
  assert.equal(producer.closed.at(-1).code, 4000);
  assert.equal(commands.at(-1).command, 'video_live_stop');
  assert.deepEqual(commands.at(-1).payload, {
    requestId: `${session.sessionId}:stop`,
    sessionId: session.sessionId,
  });
});

test('parked live session expires after 30 minutes and closes sockets', async () => {
  const { relay, commands, advance } = fixture();
  const session = await create(relay);
  const producer = attach(relay, 'producer', session.sessionId, session.producerToken);
  const viewer = attach(relay, 'viewer', session.sessionId, session.viewerToken);
  advance(30 * 60_000 + 1);

  relay.sweep();
  await new Promise(resolve => setImmediate(resolve));

  assert.equal(relay.hasSession(session.sessionId), false);
  assert.equal(producer.closed.at(-1).code, 4000);
  assert.equal(viewer.closed.at(-1).code, 4000);
  assert.equal(commands.at(-1).command, 'video_live_stop');
});

test('incomplete session is removed when the 60-second connection window expires', async () => {
  const { relay, commands, advance } = fixture();
  const session = await create(relay);
  const producer = attach(relay, 'producer', session.sessionId, session.producerToken);
  advance(60_001);

  relay.sweep();
  await new Promise(resolve => setImmediate(resolve));

  assert.equal(relay.hasSession(session.sessionId), false);
  assert.equal(producer.closed.at(-1).code, 4000);
  assert.equal(commands.at(-1).command, 'video_live_stop');
});

// Verbatim Camera VIDEO_PROTOCOL.md at e1d0d7fc268bd9a1e0de6838e4b86f2b640ac008.
const HVT = {
  data: '485654310101000000000001000000000000000000000003ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad616263',
  eof: '485654310102000000000001000000000000000300000000ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
  ack: '4856543101030000000000010000000000000003000000000000000000000000000000000000000000000000000000000000000000000000',
  error: '485654310104000000000001000000000000000000000003ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad616263',
  highAck: '4856543101030000000000018000000000000000000000000000000000000000000000000000000000000000000000000000000000000000',
  maxAck: '485654310103000000000001ffffffffffffffff000000000000000000000000000000000000000000000000000000000000000000000000',
};
const SHA_ABC = 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';
const SETTINGS = {
  automaticRecording: true, recordParkedLive: false, remoteLive: true, remoteDownloads: true,
  automaticDeletion: true, overlayMaster: true, overlayDateTime: true, overlaySpeed: true,
  overlayAcceleration: true, overlayDriveState: true, overlayDecelerationRegen: true,
  quality: 'standard', reserveGb: 1, overlayPosition: 'bottom_left',
};
const jsonBuffer = value => Buffer.from(JSON.stringify(value));
function catalog(revision = 1, trips) {
  return { ok: true, catalogRevision: revision, updatedAt: 1_700_000_000_000 + revision,
    trips: trips || [{ tripId: '42', source: 'automatic', startMs: 1000, endMs: 2000,
      byteSize: 3, completed: true, segments: [{ segmentId: 1, byteSize: 3, sha256: SHA_ABC }] }] };
}
function transferFixture(options = {}) {
  const f = fixture(options);
  assert.equal(f.relay.acceptCatalog(jsonBuffer(catalog())), true);
  return f;
}
async function transfer(relay, extra = {}) {
  return relay.createTransfer({ publicUrl: 'https://bridge.example', tripId: '42', segmentIds: ['1'], ...extra });
}
function transferSocket(relay, role, session, socket = new FakeSocket()) {
  relay.attach(role, {
    url: `/ws/video/transfer/${role === 'producer' ? 'car' : 'viewer'}?session=${session.sessionId}`,
    headers: { authorization: `Bearer ${session[`${role}Token`]}` },
  }, socket);
  return socket;
}
async function api(t, relay) {
  const app = express();
  app.use(express.json());
  relay.installRoutes(app, {
    requireAuth: (req, res, next) => req.headers.authorization === 'Bearer owner'
      ? next() : res.status(401).json({ error: 'unauthorized' }),
    publicUrl: () => 'https://bridge.example',
  });
  const server = http.createServer(app);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.closeAllConnections(); server.close(); clearInterval(relay.timer); });
  return async (path, method = 'GET', body, authorized = true) => fetch(
    `http://127.0.0.1:${server.address().port}${path}`, {
      method, headers: { 'content-type': 'application/json', ...(authorized ? { authorization: 'Bearer owner' } : {}) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    },
  );
}
function hvtFrame(type, payload = Buffer.alloc(0), offset = 0n, ordinal = 1) {
  const frame = Buffer.alloc(56 + payload.length);
  frame.write('HVT1'); frame[4] = 1; frame[5] = type;
  frame.writeUInt32BE(ordinal, 8); frame.writeBigUInt64BE(offset, 12);
  frame.writeUInt32BE(payload.length, 20);
  if (type === 1 || type === 4) require('node:crypto').createHash('sha256').update(payload).digest().copy(frame, 24);
  payload.copy(frame, 56);
  return frame;
}

test('HVT1 matches all six canonical fixtures and preserves full unsigned u64 offsets', () => {
  for (const [name, hex] of Object.entries(HVT)) {
    const parsed = parseHvt1(Buffer.from(hex, 'hex'));
    assert.equal(parsed.type, { data: 1, eof: 2, ack: 3, error: 4, highAck: 3, maxAck: 3 }[name]);
    assert.equal(parsed.ordinal, 1);
    assert.equal(parsed.offset, { data: 0n, eof: 3n, ack: 3n, error: 0n,
      highAck: 9223372036854775808n, maxAck: 18446744073709551615n }[name]);
  }
  const maxOrdinal = hvtFrame(3, Buffer.alloc(0), 0n, 4294967295);
  assert.equal(parseHvt1(maxOrdinal).ordinal, 4294967295);
});

test('HVT1 accepts the 262144 byte cap and signed-boundary crossing, rejects unsigned overflow', () => {
  assert.equal(parseHvt1(hvtFrame(1, Buffer.alloc(262144))).type, 1);
  assert.throws(() => parseHvt1(hvtFrame(1, Buffer.alloc(262145))));
  assert.equal(parseHvt1(hvtFrame(1, Buffer.from('abc'), 9223372036854775807n)).offset, 9223372036854775807n);
  assert.equal(parseHvt1(hvtFrame(1, Buffer.from('abc'), 18446744073709551612n)).offset, 18446744073709551612n);
  for (const offset of [18446744073709551613n, 18446744073709551614n, 18446744073709551615n]) {
    assert.throws(() => parseHvt1(hvtFrame(1, Buffer.from('abc'), offset)));
  }
});

test('HVT1 rejects malformed headers, lengths, hashes, flags, ACK digest, ERROR offset and UTF-8', () => {
  const data = Buffer.from(HVT.data, 'hex');
  const mutations = [[0, 0], [4, 2], [5, 5], [6, 1], [7, 1], [23, 2], [24, 0]];
  for (const [index, value] of mutations) {
    const bad = Buffer.from(data); bad[index] = value;
    assert.throws(() => parseHvt1(bad));
  }
  for (const bad of [data.subarray(0, 55), data.subarray(0, 58), Buffer.concat([data, Buffer.from([0])]),
    hvtFrame(1), hvtFrame(4), hvtFrame(4, Buffer.alloc(1025)),
    hvtFrame(4, Buffer.from([0xc0, 0x80])), hvtFrame(4, Buffer.from([0xed, 0xa0, 0x80])),
    hvtFrame(4, Buffer.from([0xe2, 0x82])), hvtFrame(4, Buffer.from('abc'), 1n),
    hvtFrame(2, Buffer.from('x')), hvtFrame(3, Buffer.from('x'))]) assert.throws(() => parseHvt1(bad));
  const ack = Buffer.from(HVT.ack, 'hex'); ack[55] = 1;
  assert.throws(() => parseHvt1(ack));
  assert.equal(parseHvt1(hvtFrame(4, Buffer.from('é'.repeat(512)))).type, 4);
});

test('catalog atomically replaces complete revisions, propagates retention and rejects stale or mixed revisions', () => {
  const writes = [];
  const { relay } = fixture({ persistMetadata: value => writes.push(JSON.stringify(value)) });
  assert.equal(relay.acceptCatalog(jsonBuffer(catalog())), true);
  const before = relay.getCatalog();
  const invalid = catalog(2); invalid.trips.push({ ...invalid.trips[0], tripId: '../active' });
  assert.equal(relay.acceptCatalog(jsonBuffer(invalid)), false);
  assert.deepEqual(relay.getCatalog(), before);
  assert.equal(writes.length, 1);
  assert.equal(relay.acceptCatalog(jsonBuffer({ ...catalog(), updatedAt: 1_700_000_000_000 })), false);
  assert.equal(relay.acceptCatalog(jsonBuffer(catalog(0))), false);
  assert.equal(relay.acceptCatalog(jsonBuffer(catalog(1, []))), false);
  assert.equal(relay.acceptCatalog(jsonBuffer(catalog(2, []))), true);
  assert.deepEqual(relay.getCatalog().trips, []);
});

test('catalog preserves legacy completed summaries, excludes active trips and marks stale metadata', () => {
  const { relay, advance } = fixture();
  const summary = { tripId: '43', source: 'manual', startMs: 1000, endMs: 2000, byteSize: 3, segments: 1 };
  const active = { ...summary, tripId: '44', endMs: null, completed: false };
  assert.equal(relay.acceptCatalog(jsonBuffer(catalog(1, [summary, active]))), true);
  assert.equal(relay.getCatalog().trips.length, 1);
  assert.equal(relay.getCatalog().trips[0].tripId, '43');
  assert.equal(relay.getCatalog().stale, false);
  advance(5 * 60_000 + 2);
  assert.equal(relay.getCatalog().stale, true);
});

test('catalog rejects invalid paths, sizes, digests, duplicate ordinals and unknown captured fields', () => {
  const { relay } = fixture();
  const invalid = [
    value => { value.trips[0].segments[0].fileName = '../secret.mp4'; },
    value => { value.trips[0].byteSize = -1; },
    value => { value.trips[0].segments[0].byteSize = Number.MAX_SAFE_INTEGER + 1; },
    value => { value.trips[0].segments[0].sha256 = 'invalid'; },
    value => { value.trips[0].segments.push(value.trips[0].segments[0]); },
    value => { value.trips[0].segments[0].body = 'captured-video'; },
    value => { value.payload = 'captured-video'; },
  ];
  for (const mutate of invalid) { const value = catalog(); mutate(value); assert.equal(relay.acceptCatalog(jsonBuffer(value)), false); }
  assert.equal(relay.acceptCatalog(Buffer.alloc(1024 * 1024 + 1)), false);
});

test('metadata persistence failure leaves the previous revision and restored metadata is validated', () => {
  let fail = false;
  const f = fixture({ persistMetadata: () => { if (fail) throw new Error('disk full'); } });
  assert.equal(f.relay.acceptCatalog(jsonBuffer(catalog())), true);
  fail = true;
  assert.equal(f.relay.acceptCatalog(jsonBuffer(catalog(2, []))), false);
  assert.equal(f.relay.getCatalog().catalogRevision, 1);
  const restored = fixture({ metadata: { catalog: catalog(), settings: null } }).relay;
  assert.equal(restored.getCatalog().trips.length, 1);
  const unsafe = catalog(); unsafe.trips[0].segments[0].payload = 'secret';
  assert.equal(fixture({ metadata: { catalog: unsafe } }).relay.getCatalog().trips.length, 0);
});

test('all new REST routes enforce owner authentication before accessing metadata or commands', async t => {
  const { relay, commands } = fixture();
  const request = await api(t, relay);
  for (const [path, method] of [['/api/video/catalog', 'GET'], ['/api/video/settings', 'GET'],
    ['/api/video/settings', 'PATCH'], ['/api/video/recordings', 'DELETE'],
    ['/api/video/transfer/session', 'POST'], ['/api/video/transfer/session/nope', 'DELETE']]) {
    assert.equal((await request(path, method, method === 'GET' ? undefined : {}, false)).status, 401);
  }
  assert.equal(commands.length, 0);
});

test('settings GET returns last confirmed snapshot and PATCH awaits the correlated authoritative result', async t => {
  let confirm;
  const { relay, commands } = fixture({ sendCarCommand: (command, payload) => {
    commands.push({ command, payload }); return new Promise(resolve => { confirm = resolve; });
  } });
  assert.equal(relay.acceptSettings(jsonBuffer({ ok: true, revision: 1, settings: SETTINGS })), true);
  const request = await api(t, relay);
  assert.equal((await (await request('/api/video/settings')).json()).revision, 1);
  let settled = false;
  const pending = request('/api/video/settings', 'PATCH', { expectedRevision: 1, patch: { reserveGb: 5 } })
    .finally(() => { settled = true; });
  while (!confirm) await new Promise(resolve => setImmediate(resolve));
  assert.equal(settled, false);
  assert.equal(relay.getSettings().settings.reserveGb, 1);
  assert.equal(commands[0].command, 'video_settings_update');
  confirm({ ok: true, revision: 2, applied: true, settings: { ...SETTINGS, reserveGb: 5 } });
  assert.equal((await pending).status, 200);
  assert.equal(relay.getSettings().settings.reserveGb, 5);
});

test('settings validates patch and conflicts return the unchanged latest confirmed snapshot', async t => {
  const { relay, commands } = fixture();
  relay.acceptSettings(jsonBuffer({ ok: true, revision: 3, settings: SETTINGS }));
  const request = await api(t, relay);
  for (const patch of [{}, { unknown: true }, { reserveGb: 2 }, { reserveGb: 1.5 }, { remoteLive: 'true' }, { quality: 'ultra' }]) {
    assert.equal((await request('/api/video/settings', 'PATCH', { expectedRevision: 3, patch })).status, 400);
  }
  const conflict = await request('/api/video/settings', 'PATCH', { expectedRevision: 2, patch: { reserveGb: 5 } });
  assert.equal(conflict.status, 409);
  assert.equal((await conflict.json()).revision, 3);
  assert.equal(commands.length, 0);
  assert.equal(relay.acceptSettings(jsonBuffer({ ok: true, revision: 2, settings: SETTINGS })), false);
  assert.equal(relay.acceptSettings(jsonBuffer({ ok: true, revision: 3, settings: { ...SETTINGS, reserveGb: 20 } })), false);
});

test('settings camera-side conflict reconciles metadata and offline/timeout never applies the requested patch', async t => {
  let response = { ok: true, applied: false, conflict: true, revision: 4, settings: SETTINGS };
  const { relay } = fixture({ sendCarCommand: async () => { if (response instanceof Error) throw response; return response; } });
  relay.acceptSettings(jsonBuffer({ ok: true, revision: 3, settings: SETTINGS }));
  const request = await api(t, relay);
  assert.equal((await request('/api/video/settings', 'PATCH', { expectedRevision: 3, patch: { reserveGb: 5 } })).status, 409);
  assert.equal(relay.getSettings().revision, 4);
  response = Object.assign(new Error('offline'), { code: 'mqtt_offline' });
  assert.equal((await request('/api/video/settings', 'PATCH', { expectedRevision: 4, patch: { reserveGb: 5 } })).status, 503);
  assert.equal(relay.getSettings().settings.reserveGb, 1);
});

test('recording deletion requires explicit confirmation and completed unleased trip membership', async t => {
  const { relay, commands } = transferFixture();
  const request = await api(t, relay);
  assert.equal((await request('/api/video/recordings', 'DELETE', { tripIds: ['42'] })).status, 400);
  assert.equal((await request('/api/video/recordings', 'DELETE', { tripIds: ['active'], confirmation: 'DELETE_COMPLETED' })).status, 400);
  await transfer(relay);
  assert.equal((await request('/api/video/recordings', 'DELETE', { tripIds: ['42'], confirmation: 'DELETE_COMPLETED' })).status, 409);
  assert.equal(commands.filter(entry => entry.command === 'video_delete').length, 0);
});

test('confirmed deletion waits for car and only authoritative catalog removes metadata', async t => {
  let confirm;
  const { relay, commands } = transferFixture({ sendCarCommand: (command, payload) => {
    commands.push({ command, payload }); return new Promise(resolve => { confirm = resolve; });
  } });
  const request = await api(t, relay);
  const pending = request('/api/video/recordings', 'DELETE', { tripIds: ['42'], confirmation: 'DELETE_COMPLETED' });
  while (!confirm) await new Promise(resolve => setImmediate(resolve));
  assert.equal(relay.getCatalog().trips.length, 1);
  assert.equal(commands[0].command, 'video_delete');
  confirm({ ok: true });
  assert.equal((await pending).status, 204);
  assert.equal(relay.getCatalog().trips.length, 1);
  relay.acceptCatalog(jsonBuffer(catalog(2, [])));
  assert.deepEqual(relay.getCatalog().trips, []);
});

test('transfer REST returns only viewer credential, validates selection and enforces one transfer', async t => {
  const { relay, commands } = transferFixture();
  const request = await api(t, relay);
  for (const body of [{ tripId: '../42', segmentIds: ['1'] }, { tripId: '42', segmentIds: ['2'] },
    { tripId: '42', segmentIds: ['1', '1'] }, { tripId: '42', segmentIds: [] }]) {
    assert.equal((await request('/api/video/transfer/session', 'POST', body)).status, 400);
  }
  const accepted = await request('/api/video/transfer/session', 'POST', { tripId: '42', segmentIds: ['1'] });
  assert.equal(accepted.status, 201);
  const body = await accepted.json();
  assert.equal(body.producerToken, undefined);
  assert.match(body.viewerUrl, /^wss:\/\/bridge.example\/ws\/video\/transfer\/viewer\?/);
  assert.equal(commands[0].command, 'video_transfer');
  assert.equal(commands[0].payload.viewerSession, body.sessionId);
  assert.notEqual(commands[0].payload.producerToken, body.viewerToken);
  assert.equal(JSON.stringify(commands).includes(body.viewerToken), false);
  assert.equal((await request('/api/video/transfer/session', 'POST', { tripId: '42', segmentIds: ['1'] })).status, 409);
});

test('transfer credentials are role/protocol scoped, single use, TLS-only and expire at 60 seconds', async () => {
  const { relay, advance } = transferFixture();
  const session = await transfer(relay);
  const wrong = transferSocket(relay, 'producer', { ...session, producerToken: session.viewerToken });
  assert.equal(wrong.closed[0].code, 4003);
  const cross = attach(relay, 'viewer', session.sessionId, session.viewerToken);
  assert.equal(cross.closed[0].code, 4003);
  transferSocket(relay, 'producer', session);
  const duplicate = transferSocket(relay, 'producer', session);
  assert.equal(duplicate.closed[0].code, 4005);
  const raw = { output: '', write(value) { this.output += value; }, destroy() {} };
  relay.handleUpgrade({ url: `/ws/video/transfer/viewer?session=${session.sessionId}`,
    headers: { authorization: `Bearer ${session.viewerToken}` }, socket: {} }, raw, Buffer.alloc(0));
  assert.match(raw.output, /^HTTP\/1.1 426/);
  advance(60_000);
  assert.equal(transferSocket(relay, 'viewer', session).closed[0].code, 4002);
});

test('transfer forwards DATA and viewer durable ACK only after successful viewer send, EOF completes', async () => {
  const { relay } = transferFixture();
  const session = await transfer(relay);
  const producer = transferSocket(relay, 'producer', session);
  const viewer = new FakeSocket();
  let finishSend;
  viewer.send = (data, options, callback) => { viewer.sent.push({ data, options }); finishSend = callback; };
  transferSocket(relay, 'viewer', session, viewer);
  const data = Buffer.from(HVT.data, 'hex');
  producer.emit('message', data, true);
  assert.equal(viewer.sent[0].data, data);
  assert.equal(producer.sent.filter(entry => Buffer.isBuffer(entry.data)).length, 0);
  finishSend();
  viewer.emit('message', Buffer.from(HVT.ack, 'hex'), true);
  assert.equal(producer.sent.at(-1).data.toString('hex'), HVT.ack);
  producer.emit('message', Buffer.from(HVT.eof, 'hex'), true);
  finishSend();
  assert.equal(producer.readyState, WebSocket.OPEN);
  viewer.emit('message', Buffer.from(HVT.ack, 'hex'), true);
  assert.equal(producer.closed.at(-1).code, 4000);
  assert.equal(viewer.closed.at(-1).code, 4000);
  assert.equal(relay.transfers.size, 0);
});

test('early ACK cannot advance or be relayed before the viewer send callback', async () => {
  const { relay } = transferFixture();
  const session = await transfer(relay);
  const producer = transferSocket(relay, 'producer', session);
  const viewer = new FakeSocket();
  viewer.send = () => {};
  transferSocket(relay, 'viewer', session, viewer);
  producer.emit('message', Buffer.from(HVT.data, 'hex'), true);
  viewer.emit('message', Buffer.from(HVT.ack, 'hex'), true);
  assert.equal(viewer.closed.at(-1).code, 4004);
  assert.equal(producer.sent.filter(entry => Buffer.isBuffer(entry.data)).length, 0);
});

test('transfer rejects unknown ordinal, offset gaps, out-of-bounds EOF and wrong whole-file digest', async () => {
  for (const bad of [hvtFrame(1, Buffer.from('abc'), 0n, 2), hvtFrame(1, Buffer.from('abc'), 1n),
    hvtFrame(1, Buffer.from('abcd')), Buffer.from(HVT.eof, 'hex'), Buffer.from('not-hvt')]) {
    const { relay } = transferFixture();
    const session = await transfer(relay);
    const producer = transferSocket(relay, 'producer', session);
    const viewer = transferSocket(relay, 'viewer', session);
    producer.emit('message', bad, true);
    assert.equal(producer.closed.at(-1).code, 4004);
    assert.equal(viewer.sent.length, 0);
  }
  const { relay } = transferFixture(); const session = await transfer(relay);
  const producer = transferSocket(relay, 'producer', session); const viewer = transferSocket(relay, 'viewer', session);
  producer.emit('message', Buffer.from(HVT.data, 'hex'), true);
  viewer.emit('message', Buffer.from(HVT.ack, 'hex'), true);
  producer.emit('message', hvtFrame(2, Buffer.alloc(0), 3n), true);
  assert.equal(producer.closed.at(-1).code, 4004);
});

test('viewer cannot ACK skipped bytes or send DATA, and producer cannot send ACK', async () => {
  for (const [role, data] of [['viewer', hvtFrame(3, Buffer.alloc(0), 2n)],
    ['viewer', Buffer.from(HVT.data, 'hex')], ['producer', Buffer.from(HVT.ack, 'hex')]]) {
    const { relay } = transferFixture(); const session = await transfer(relay);
    const producer = transferSocket(relay, 'producer', session); const viewer = transferSocket(relay, 'viewer', session);
    producer.emit('message', Buffer.from(HVT.data, 'hex'), true);
    (role === 'viewer' ? viewer : producer).emit('message', data, true);
    assert.equal((role === 'viewer' ? viewer : producer).closed.at(-1).code, 4004);
  }
});

test('disconnect retains only ACKed progress and reconnect rotates credentials on the same transfer', async () => {
  const { relay, commands } = transferFixture(); const session = await transfer(relay);
  const producer = transferSocket(relay, 'producer', session); const viewer = transferSocket(relay, 'viewer', session);
  producer.emit('message', Buffer.from(HVT.data, 'hex'), true);
  viewer.emit('message', Buffer.from(HVT.ack, 'hex'), true);
  viewer.close(1000, 'network loss');
  const resumed = await transfer(relay, { sessionId: session.sessionId });
  assert.equal(resumed.sessionId, session.sessionId);
  assert.notEqual(resumed.viewerToken, session.viewerToken);
  assert.equal(transferSocket(relay, 'viewer', session).closed[0].code, 4001);
  assert.deepEqual(commands.filter(entry => entry.command === 'video_transfer').at(-1).payload.offsets, { '1': '3' });
  assert.equal(transferSocket(relay, 'producer', resumed).closed.length, 0);
});

test('unacknowledged chunks and late send callbacks never advance reconnect offsets', async () => {
  const { relay, commands } = transferFixture(); const session = await transfer(relay);
  const producer = transferSocket(relay, 'producer', session); const viewer = new FakeSocket();
  let callback; viewer.send = (_data, _options, done) => { callback = done; };
  transferSocket(relay, 'viewer', session, viewer);
  producer.emit('message', Buffer.from(HVT.data, 'hex'), true);
  viewer.close(1000, 'lost');
  await transfer(relay, { sessionId: session.sessionId }); callback();
  assert.deepEqual(commands.filter(entry => entry.command === 'video_transfer').at(-1).payload.offsets, { '1': '0' });
});

test('live has priority and pauses existing or newly connected transfer without retaining chunks', async () => {
  const { relay } = transferFixture(); const session = await transfer(relay);
  const producer = transferSocket(relay, 'producer', session); const viewer = transferSocket(relay, 'viewer', session);
  const live = await create(relay);
  assert.deepEqual(JSON.parse(producer.sent.at(-1).data), { type: 'pause', reason: 'live' });
  producer.emit('message', Buffer.from(HVT.data, 'hex'), true);
  assert.equal(viewer.sent.length, 0);
  await relay.closeSession(live.sessionId);
  assert.deepEqual(JSON.parse(producer.sent.at(-1).data), { type: 'resume', offsets: { '1': '0' } });
  producer.emit('message', Buffer.from(HVT.data, 'hex'), true);
  assert.equal(viewer.sent.length, 1);
});

test('transfer backpressure and send errors close sockets without ACK or queued chunks', async () => {
  for (const mode of ['buffer', 'callback', 'throw']) {
    const { relay } = transferFixture(); const session = await transfer(relay);
    const producer = transferSocket(relay, 'producer', session); const viewer = transferSocket(relay, 'viewer', session);
    if (mode === 'buffer') viewer.bufferedAmount = MAX_BUFFERED_BYTES;
    if (mode === 'callback') viewer.send = (_data, _options, done) => done(new Error('failed'));
    if (mode === 'throw') viewer.send = () => { throw new Error('failed'); };
    producer.emit('message', Buffer.from(HVT.data, 'hex'), true);
    assert.equal(producer.sent.filter(entry => Buffer.isBuffer(entry.data)).length, 0);
    assert.equal(viewer.closed.at(-1).code, mode === 'buffer' ? 4007 : 4000);
  }
});

test('valid ERROR ends attempt normally and never logs its text or acknowledges bytes', async () => {
  const { relay, logs } = transferFixture(); const session = await transfer(relay);
  const producer = transferSocket(relay, 'producer', session); transferSocket(relay, 'viewer', session);
  producer.emit('message', Buffer.from(HVT.error, 'hex'), true);
  assert.equal(producer.closed.at(-1).code, 4000);
  assert.equal(JSON.stringify(logs).includes('abc'), false);
  assert.equal(producer.sent.filter(entry => Buffer.isBuffer(entry.data)).length, 0);
});

test('transfer cancellation, expired sessions, and retention invalidate credentials and clean sockets', async t => {
  const { relay, advance, commands } = transferFixture(); const session = await transfer(relay);
  const producer = transferSocket(relay, 'producer', session); transferSocket(relay, 'viewer', session);
  const request = await api(t, relay);
  assert.equal((await request(`/api/video/transfer/session/${session.sessionId}`, 'DELETE')).status, 204);
  assert.equal(producer.closed.at(-1).code, 4000);
  assert.equal(relay.transfers.size, 0);
  assert.equal(commands.at(-1).command, 'video_transfer_cancel');
  const next = await transfer(relay); transferSocket(relay, 'producer', next);
  advance(60_001); relay.sweep();
  assert.equal(relay.transfers.size, 0);
  const last = await transfer(relay); transferSocket(relay, 'producer', last); transferSocket(relay, 'viewer', last);
  advance(30 * 60_000 + 1); relay.sweep();
  assert.equal(relay.transfers.size, 0);
  const retained = await transfer(relay); const car = transferSocket(relay, 'producer', retained);
  relay.acceptCatalog(jsonBuffer(catalog(2, [])));
  assert.equal(car.closed.at(-1).code, 4000);
  assert.equal(relay.transfers.size, 0);
});

test('metadata persistence contains no video bytes, chunks, sockets, credentials or session progress', async t => {
  const fs = require('node:fs'); const path = require('node:path');
  const directory = fs.mkdtempSync(path.join(require('node:os').tmpdir(), 'video-metadata-test-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  const file = path.join(directory, 'video_metadata.json');
  const { relay, logs } = transferFixture({ persistMetadata: metadata => {
    fs.writeFileSync(`${file}.tmp`, JSON.stringify(metadata)); fs.renameSync(`${file}.tmp`, file);
  } });
  const before = fs.readFileSync(file);
  const session = await transfer(relay); const producer = transferSocket(relay, 'producer', session);
  const viewer = transferSocket(relay, 'viewer', session);
  producer.emit('message', Buffer.from(HVT.data, 'hex'), true);
  viewer.emit('message', Buffer.from(HVT.ack, 'hex'), true);
  assert.deepEqual(fs.readdirSync(directory), ['video_metadata.json']);
  assert.deepEqual(fs.readFileSync(file), before);
  const serialized = JSON.stringify([JSON.parse(before), logs]);
  for (const forbidden of ['abc', HVT.data, session.producerToken, session.viewerToken, 'Buffer', 'pending']) {
    assert.equal(serialized.includes(forbidden), false);
  }
  const state = relay.transfers.get(session.sessionId);
  assert.equal(state.pending, null);
  assert.equal(Object.values(state).some(Buffer.isBuffer), false);
});

test('catalog accepts exact Camera completed segment metadata and strips local-only fields', () => {
  const { relay } = fixture(); const value = catalog();
  Object.assign(value.trips[0].segments[0], { fileName: '000001.mp4', startMs: 1000, endMs: 2000,
    durationUs: 1000000, codec: { mime: 'video/avc', width: 1280, height: 720, frameRate: 15, bitrate: 4000000 } });
  assert.equal(relay.acceptCatalog(jsonBuffer(value)), true);
  assert.deepEqual(relay.getCatalog().trips[0].segments, [{ segmentId: 1, byteSize: 3, sha256: SHA_ABC }]);
});

test('a long-running transfer reconnects after the original token deadline using fresh credentials', async () => {
  const { relay, advance } = transferFixture(); const session = await transfer(relay);
  transferSocket(relay, 'producer', session); const viewer = transferSocket(relay, 'viewer', session);
  advance(2 * 60_000);
  viewer.close(1000, 'network loss');
  const resumed = await transfer(relay, { sessionId: session.sessionId });
  assert.equal(resumed.sessionId, session.sessionId);
  assert.equal(resumed.expiresAt, session.expiresAt);
  assert.equal(transferSocket(relay, 'viewer', resumed).closed.length, 0);
});

test('live stop confirmation precedes transfer resume', async () => {
  let confirmStop;
  const { relay } = transferFixture({ sendCarCommand: command => command === 'video_live_stop'
    ? new Promise(resolve => { confirmStop = resolve; }) : Promise.resolve() });
  const session = await transfer(relay); const producer = transferSocket(relay, 'producer', session);
  transferSocket(relay, 'viewer', session);
  const live = await create(relay);
  const pending = relay.closeSession(live.sessionId);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(JSON.parse(producer.sent.at(-1).data).type, 'pause');
  confirmStop(); await pending;
  assert.equal(JSON.parse(producer.sent.at(-1).data).type, 'resume');
});

test('new transfer remains paused while a live stop is still unconfirmed', async () => {
  let confirmStop;
  const { relay } = transferFixture({ sendCarCommand: command => command === 'video_live_stop'
    ? new Promise(resolve => { confirmStop = resolve; }) : Promise.resolve() });
  const live = await create(relay);
  const stopping = relay.closeSession(live.sessionId);
  const session = await transfer(relay); const producer = transferSocket(relay, 'producer', session);
  assert.deepEqual(JSON.parse(producer.sent.at(-1).data), { type: 'pause', reason: 'live' });
  confirmStop(); await stopping;
  assert.equal(JSON.parse(producer.sent.at(-1).data).type, 'resume');
});

test('broker ignores malformed JSON result values without settling a pending settings request', async () => {
  const broker = new VideoCommandBroker({ publish: (_command, _payload, callback) => callback(null) });
  for (const value of [null, [], 'string', 7, true]) {
    assert.equal(broker.acceptResult('video_settings_update', jsonBuffer(value)), false);
  }
  const pending = broker.send('video_settings_update', { requestId: 'settings-1' });
  assert.equal(broker.acceptResult('video_transfer', jsonBuffer({ ok: true, requestId: 'settings-1' })), false);
  broker.acceptResult('video_settings_update', jsonBuffer({ ok: true, requestId: 'settings-1' }));
  await pending;
});

test('real transfer WebSockets accept the full 1024-byte ERROR payload from either role', async t => {
  const { once } = require('node:events');
  const { relay } = transferFixture({ trustedProxyAddresses: ['127.0.0.1'] });
  const server = http.createServer();
  server.on('upgrade', (req, socket, head) => relay.handleUpgrade(req, socket, head));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => { server.close(); clearInterval(relay.timer); });
  const session = await transfer(relay);
  const viewer = new WebSocket(`ws://127.0.0.1:${server.address().port}/ws/video/transfer/viewer?session=${session.sessionId}`, {
    headers: { authorization: `Bearer ${session.viewerToken}`, 'x-forwarded-proto': 'https' },
  });
  t.after(() => viewer.terminate()); await once(viewer, 'open');
  const ended = once(viewer, 'close');
  viewer.send(hvtFrame(4, Buffer.alloc(1024, 97)));
  assert.equal((await ended)[0], 4000);
});

test('transfer start timeout, cancel failure, and late start confirmation clean all session state', async t => {
  let confirm;
  const { relay } = transferFixture({ commandTimeoutMs: 15, sendCarCommand: command => command === 'video_transfer'
    ? new Promise(resolve => { confirm = resolve; }) : Promise.resolve() });
  // Keep the process alive while the deliberately unref'ed command timeout runs.
  const keepAlive = setInterval(() => {}, 1000); t.after(() => clearInterval(keepAlive));
  await assert.rejects(transfer(relay), error => error.code === 'camera_command_timeout');
  assert.equal(relay.transfers.size, 0); confirm();
  await new Promise(resolve => setImmediate(resolve)); assert.equal(relay.transfers.size, 0);
  const failure = transferFixture({ sendCarCommand: async command => {
    if (command === 'video_transfer_cancel') throw Object.assign(new Error('offline'), { code: 'mqtt_offline' });
  } });
  const session = await transfer(failure.relay); const producer = transferSocket(failure.relay, 'producer', session);
  const request = await api(t, failure.relay);
  assert.equal((await request(`/api/video/transfer/session/${session.sessionId}`, 'DELETE')).status, 503);
  assert.equal(producer.readyState, WebSocket.CLOSED); assert.equal(failure.relay.transfers.size, 0);
});

test('multi-segment completion and fresh resume preserve completed ordinals separately from byte offsets', async () => {
  const { relay, commands } = fixture(); const value = catalog();
  value.trips[0].byteSize = 6;
  value.trips[0].segments.push({ segmentId: 2, byteSize: 3, sha256: SHA_ABC });
  relay.acceptCatalog(jsonBuffer(value));
  const session = await transfer(relay, { segmentIds: ['1', '2'] });
  const producer = transferSocket(relay, 'producer', session); const viewer = transferSocket(relay, 'viewer', session);
  for (const hex of [HVT.data, HVT.eof]) {
    producer.emit('message', Buffer.from(hex, 'hex'), true);
    viewer.emit('message', Buffer.from(HVT.ack, 'hex'), true);
  }
  assert.equal(relay.transfers.size, 1);
  viewer.close(1000, 'lost');
  const resumed = await transfer(relay, { sessionId: session.sessionId, segmentIds: ['1', '2'] });
  assert.deepEqual(commands.filter(entry => entry.command === 'video_transfer').at(-1).payload.completedSegmentIds, ['1']);
  const car = transferSocket(relay, 'producer', resumed); const phone = transferSocket(relay, 'viewer', resumed);
  const ack = Buffer.from(HVT.ack, 'hex'); ack.writeUInt32BE(2, 8);
  for (const hex of [HVT.data, HVT.eof]) {
    const frame = Buffer.from(hex, 'hex'); frame.writeUInt32BE(2, 8);
    car.emit('message', frame, true); phone.emit('message', ack, true);
  }
  assert.equal(relay.transfers.size, 0);
});

test('late ACK send failure from a disconnected attempt cannot close newly authorized sockets', async () => {
  const { relay } = transferFixture(); const session = await transfer(relay);
  const producer = transferSocket(relay, 'producer', session); const viewer = transferSocket(relay, 'viewer', session);
  let failOldSend;
  producer.send = (_data, _options, callback) => { failOldSend = callback; };
  producer.emit('message', Buffer.from(HVT.data, 'hex'), true);
  viewer.emit('message', Buffer.from(HVT.ack, 'hex'), true);
  viewer.close(1000, 'lost');
  const resumed = await transfer(relay, { sessionId: session.sessionId });
  const car = transferSocket(relay, 'producer', resumed); const phone = transferSocket(relay, 'viewer', resumed);
  failOldSend(new Error('old attempt failed'));
  assert.equal(car.readyState, WebSocket.OPEN); assert.equal(phone.readyState, WebSocket.OPEN);
});

test('settings PATCH timeout and rejected deletion preserve authoritative metadata', async t => {
  const { relay } = transferFixture({ commandTimeoutMs: 15, sendCarCommand: command => {
    if (command === 'video_settings_update') return new Promise(() => {});
    throw Object.assign(new Error('rejected'), { code: 'camera_rejected' });
  } });
  relay.acceptSettings(jsonBuffer({ ok: true, revision: 1, settings: SETTINGS }));
  const request = await api(t, relay);
  assert.equal((await request('/api/video/settings', 'PATCH', { expectedRevision: 1, patch: { reserveGb: 5 } })).status, 503);
  assert.equal(relay.getSettings().settings.reserveGb, 1);
  assert.equal((await request('/api/video/recordings', 'DELETE', { tripIds: ['42'], confirmation: 'DELETE_COMPLETED' })).status, 503);
  assert.equal(relay.getCatalog().trips.length, 1); assert.equal(relay.deletingTrips.size, 0);
});

test('consumer rejects full-u64 ACK skips without rounding and mismatched resumed selection', async () => {
  const { relay } = transferFixture(); const session = await transfer(relay);
  const producer = transferSocket(relay, 'producer', session); const viewer = transferSocket(relay, 'viewer', session);
  producer.emit('message', Buffer.from(HVT.data, 'hex'), true);
  viewer.emit('message', Buffer.from(HVT.maxAck, 'hex'), true);
  assert.equal(viewer.closed.at(-1).code, 4004);
  await assert.rejects(transfer(relay, { sessionId: session.sessionId, tripId: '43' }), error => error.statusCode === 400);
  assert.equal(relay.transfers.size, 1);
});

test('a corrupt null metadata file cannot prevent relay startup', () => {
  const { relay } = fixture({ metadata: null });
  assert.deepEqual(relay.getCatalog().trips, []);
  assert.equal(relay.getSettings(), null);
});
