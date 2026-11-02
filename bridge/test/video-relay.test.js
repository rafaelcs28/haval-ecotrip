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

  send(data, options) {
    this.sent.push({ data, options });
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
