'use strict';

const assert = require('node:assert/strict');
const { EventEmitter } = require('node:events');
const http = require('node:http');
const test = require('node:test');
const express = require('express');
const { WebSocket } = require('ws');

const { VideoRelay } = require('../video-relay');

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

function fixture() {
  let now = 1_700_000_000_000;
  let randomByte = 1;
  const commands = [];
  const logs = [];
  const relay = new VideoRelay({
    now: () => now,
    randomBytes: size => Buffer.alloc(size, randomByte++),
    logger: (event, fields) => logs.push({ event, fields }),
    sendCarCommand: async (command, payload) => commands.push({ command, payload }),
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

test('viewer join requests a keyframe and HVC1 bytes relay without payload logging', async () => {
  const { relay, logs } = fixture();
  const session = await create(relay);
  const producer = attach(relay, 'producer', session.sessionId, session.producerToken);
  const viewer = attach(relay, 'viewer', session.sessionId, session.viewerToken);
  assert.deepEqual(JSON.parse(producer.sent[0].data), { type: 'request_keyframe' });

  const marker = Buffer.from('secret-video-payload');
  const frame = hvc1({ keyframe: true, payload: marker });
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

test('backpressure drops frames, requests recovery, and never queues video bytes', async () => {
  const { relay } = fixture();
  const session = await create(relay);
  const producer = attach(relay, 'producer', session.sessionId, session.producerToken);
  const viewer = attach(relay, 'viewer', session.sessionId, session.viewerToken);
  producer.sent.length = 0;
  viewer.bufferedAmount = 1_048_577;

  producer.emit('message', hvc1(), true);
  producer.emit('message', hvc1({ type: 1, payload: Buffer.from([0, 1, 0x67, 0, 1, 0x68]) }), true);

  assert.equal(viewer.sent.length, 0);
  assert.equal(producer.readyState, WebSocket.OPEN);
  assert.deepEqual(JSON.parse(producer.sent.at(-1).data), { type: 'request_keyframe' });
  assert.deepEqual(relay.stats(session.sessionId), { queuedFrames: 0, droppedFrames: 2 });
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
