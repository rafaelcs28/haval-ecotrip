'use strict';

const crypto = require('node:crypto');
const { WebSocket, WebSocketServer } = require('ws');

const CONNECT_TTL_MS = 60_000;
const SESSION_TTL_MS = 30 * 60_000;
const MAX_BUFFERED_BYTES = 1024 * 1024;
const HVC1_HEADER_BYTES = 24;
const MAX_PAYLOAD_BYTES = 4 * 1024 * 1024;
const MAX_MESSAGE_BYTES = HVC1_HEADER_BYTES + MAX_PAYLOAD_BYTES;
const KEYFRAME_REQUEST_INTERVAL_MS = 1_000;
const DEFAULT_COMMAND_TIMEOUT_MS = 8_000;
const DEFAULT_INVALID_UPGRADE_LIMIT = 10;
const DEFAULT_INVALID_UPGRADE_WINDOW_MS = 60_000;
const MAX_INVALID_IPS = 1_024;

function codedError(code, message, statusCode) {
  const error = new Error(message);
  error.code = code;
  if (statusCode) error.statusCode = statusCode;
  return error;
}

function safeEqual(left, right) {
  const a = Buffer.from(String(left || ''));
  const b = Buffer.from(String(right || ''));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function websocketUrl(publicUrl, path, sessionId) {
  const url = new URL(publicUrl);
  if (url.protocol !== 'https:' || !url.hostname || url.username || url.password || url.hash) {
    throw codedError('invalid_video_public_url', 'video public URL must be HTTPS', 503);
  }
  url.protocol = 'wss:';
  url.pathname = `${url.pathname.replace(/\/$/, '')}${path}`;
  url.search = '';
  url.searchParams.set('session', sessionId);
  return url.toString();
}

function parseHvc1(data) {
  const frame = Buffer.isBuffer(data) ? data : Buffer.from(data);
  if (frame.length < HVC1_HEADER_BYTES || frame.length > MAX_MESSAGE_BYTES) {
    throw new Error('invalid frame length');
  }
  if (frame.toString('ascii', 0, 4) !== 'HVC1' || frame.readUInt8(4) !== 1) {
    throw new Error('unsupported HVC1 header');
  }
  const type = frame.readUInt8(5);
  const flags = frame.readUInt16BE(6);
  const payloadLength = frame.readUInt32BE(20);
  if ((type !== 1 && type !== 2) || payloadLength < 1 || payloadLength > MAX_PAYLOAD_BYTES) {
    throw new Error('invalid HVC1 type or payload length');
  }
  if ((type === 1 && flags !== 0) || (type === 2 && (flags & ~1) !== 0)) {
    throw new Error('invalid HVC1 flags');
  }
  if (frame.length !== HVC1_HEADER_BYTES + payloadLength) {
    throw new Error('HVC1 payload length mismatch');
  }
  let offset = HVC1_HEADER_BYTES;
  const end = frame.length;
  if (type === 1) {
    if (offset + 2 > end) throw new Error('HVC1 CONFIG missing SPS length');
    const spsLength = frame.readUInt16BE(offset); offset += 2;
    if (spsLength === 0 || offset + spsLength + 2 > end) throw new Error('HVC1 CONFIG invalid SPS');
    offset += spsLength;
    const ppsLength = frame.readUInt16BE(offset); offset += 2;
    if (ppsLength === 0 || offset + ppsLength !== end) throw new Error('HVC1 CONFIG invalid PPS');
  } else {
    let nalCount = 0;
    while (offset < end) {
      if (offset + 4 > end) throw new Error('HVC1 ACCESS_UNIT truncated NAL length');
      const nalLength = frame.readUInt32BE(offset); offset += 4;
      if (nalLength === 0 || offset + nalLength > end) throw new Error('HVC1 ACCESS_UNIT invalid NAL');
      offset += nalLength;
      nalCount += 1;
    }
    if (nalCount === 0 || offset !== end) throw new Error('HVC1 ACCESS_UNIT missing NAL');
  }
  return { frame, type, keyframe: type === 2 && flags === 1 };
}

class VideoCommandBroker {
  constructor({ publish, timeoutMs = DEFAULT_COMMAND_TIMEOUT_MS } = {}) {
    if (typeof publish !== 'function') throw new TypeError('publish is required');
    this.publish = publish;
    this.timeoutMs = timeoutMs;
    this.pending = new Map();
  }

  send(command, payload) {
    const requestId = String(payload?.requestId || '');
    if (!requestId || this.pending.has(requestId)) {
      return Promise.reject(codedError('invalid_camera_request', 'invalid or duplicate request ID'));
    }
    return new Promise((resolve, reject) => {
      const finish = (error, result) => {
        const entry = this.pending.get(requestId);
        if (!entry) return;
        clearTimeout(entry.timer);
        this.pending.delete(requestId);
        if (error) reject(error); else resolve(result);
      };
      const timer = setTimeout(() => finish(
        codedError('camera_command_timeout', 'Camera command acknowledgement timed out'),
      ), this.timeoutMs);
      timer.unref?.();
      this.pending.set(requestId, { command, finish, timer });
      try {
        this.publish(command, payload, error => {
          if (error) finish(codedError('mqtt_publish_failed', 'MQTT command publish failed'));
        });
      } catch (_) {
        finish(codedError('mqtt_publish_failed', 'MQTT command publish failed'));
      }
    });
  }

  acceptResult(command, data) {
    if (!Buffer.isBuffer(data) || data.length > 16 * 1024) return false;
    let result;
    try { result = JSON.parse(data.toString('utf8')); } catch (_) { return false; }
    const requestId = typeof result.requestId === 'string' ? result.requestId : '';
    const entry = this.pending.get(requestId);
    if (!entry || entry.command !== command) return false;
    if (result.ok === true) entry.finish(null, result);
    else entry.finish(codedError('camera_rejected', 'Camera rejected command'));
    return true;
  }
}

function normalizeAddress(value) {
  return String(value || '').replace(/^::ffff:/, '');
}

class VideoRelay {
  constructor({
    now = Date.now,
    randomBytes = crypto.randomBytes,
    logger = () => {},
    sendCarCommand = async () => {},
    commandTimeoutMs = DEFAULT_COMMAND_TIMEOUT_MS,
    trustedProxyAddresses = [],
    invalidUpgradeLimit = DEFAULT_INVALID_UPGRADE_LIMIT,
    invalidUpgradeWindowMs = DEFAULT_INVALID_UPGRADE_WINDOW_MS,
  } = {}) {
    this.now = now;
    this.randomBytes = randomBytes;
    this.logger = logger;
    this.sendCarCommand = sendCarCommand;
    this.commandTimeoutMs = commandTimeoutMs;
    this.trustedProxyAddresses = new Set(trustedProxyAddresses.map(normalizeAddress).filter(Boolean));
    this.invalidUpgradeLimit = invalidUpgradeLimit;
    this.invalidUpgradeWindowMs = invalidUpgradeWindowMs;
    this.invalidAttempts = new Map();
    this.sessions = new Map();
    this.producerWss = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE_BYTES });
    this.viewerWss = new WebSocketServer({ noServer: true, maxPayload: 1024 });
    this.producerWss.on('connection', (socket, request) => this.attach('producer', request, socket));
    this.viewerWss.on('connection', (socket, request) => this.attach('viewer', request, socket));
    this.timer = setInterval(() => this.sweep(), 10_000);
    this.timer.unref?.();
  }

  async createSession({ publicUrl }) {
    const producerPath = '/ws/video/live/car';
    const viewerPath = '/ws/video/live/viewer';
    websocketUrl(publicUrl, producerPath, 'validation');
    this.sweep();
    if (this.sessions.size !== 0) {
      const error = new Error('live session already active');
      error.statusCode = 409;
      error.code = 'live_session_active';
      throw error;
    }
    const createdAt = this.now();
    const sessionId = this.randomBytes(18).toString('base64url');
    const producerToken = this.randomBytes(32).toString('base64url');
    const viewerToken = this.randomBytes(32).toString('base64url');
    const session = {
      id: sessionId,
      createdAt,
      connectExpiresAt: createdAt + CONNECT_TTL_MS,
      expiresAt: createdAt + SESSION_TTL_MS,
      producerToken: { value: producerToken, consumed: false },
      viewerToken: { value: viewerToken, consumed: false },
      producer: null,
      viewer: null,
      droppedFrames: 0,
      recovering: false,
      lastKeyframeRequestAt: -Infinity,
      closing: false,
    };
    this.sessions.set(sessionId, session);
    const producerUrl = websocketUrl(publicUrl, producerPath, sessionId);
    const viewerUrl = websocketUrl(publicUrl, viewerPath, sessionId);
    try {
      await this.dispatchCommand('video_live_start', {
        requestId: sessionId,
        sessionUrl: producerUrl,
        producerToken,
        expiresAt: session.expiresAt,
      });
    } catch (error) {
      if (this.sessions.get(sessionId) === session) await this.closeSession(sessionId, 'start_failed');
      throw error;
    }
    if (this.sessions.get(sessionId) !== session || session.closing
        || this.now() > session.connectExpiresAt || this.now() > session.expiresAt) {
      if (this.sessions.get(sessionId) === session) await this.closeSession(sessionId, 'start_expired');
      throw codedError('video_session_expired', 'video session expired before confirmation', 409);
    }
    this.logger('video_session_created', { sessionId, expiresAt: session.expiresAt });
    return {
      sessionId,
      producerToken,
      viewerUrl,
      viewerToken,
      connectExpiresAt: session.connectExpiresAt,
      expiresAt: session.expiresAt,
    };
  }

  installRoutes(app, { requireAuth, publicUrl }) {
    app.post('/api/video/live/session', requireAuth, async (req, res) => {
      try {
        const session = await this.createSession({ publicUrl: publicUrl(req) });
        const { producerToken: _producerToken, ...ownerResponse } = session;
        res.status(201).json(ownerResponse);
      } catch (error) {
        res.status(error.statusCode || 503).json({ error: error.code || 'video_session_unavailable' });
      }
    });
    app.delete('/api/video/live/session/:id', requireAuth, async (req, res) => {
      if (!this.sessions.has(req.params.id)) return res.status(404).json({ error: 'video_session_not_found' });
      try {
        await this.closeSession(req.params.id, 'owner_stop', true);
        res.status(204).end();
      } catch (error) {
        res.status(503).json({ error: error.code || 'camera_command_failed' });
      }
    });
  }

  handleUpgrade(request, socket, head) {
    const pathname = new URL(request.url, 'http://localhost').pathname;
    const role = pathname === '/ws/video/live/car' ? 'producer'
      : pathname === '/ws/video/live/viewer' ? 'viewer' : null;
    if (!role) return false;
    const remoteAddress = normalizeAddress(request.socket?.remoteAddress);
    if (this.isUpgradeRateLimited(remoteAddress)) {
      this.rejectUpgrade(socket, 429, 'Too Many Requests');
      return true;
    }
    const forwardedProto = String(request.headers?.['x-forwarded-proto'] || '')
      .split(',')[0].trim().toLowerCase();
    const secure = request.socket?.encrypted === true
      || (this.trustedProxyAddresses.has(remoteAddress) && forwardedProto === 'https');
    if (!secure) {
      this.recordInvalidUpgrade(remoteAddress);
      this.rejectUpgrade(socket, 426, 'Upgrade Required');
      return true;
    }
    const authorization = this.authorize(role, request);
    if (!authorization.ok) {
      this.recordInvalidUpgrade(remoteAddress);
      this.rejectUpgrade(socket, authorization.httpStatus, authorization.httpReason);
      return true;
    }
    if (role === 'producer') {
      this.producerWss.handleUpgrade(request, socket, head, ws => this.producerWss.emit('connection', ws, request));
      return true;
    }
    this.viewerWss.handleUpgrade(request, socket, head, ws => this.viewerWss.emit('connection', ws, request));
    return true;
  }

  attach(role, request, socket) {
    const authorization = this.authorize(role, request);
    if (!authorization.ok) return this.reject(socket, authorization.closeCode, authorization.closeReason);
    const { session, ownToken } = authorization;

    ownToken.consumed = true;
    session[role] = socket;
    socket.on('close', () => {
      if (!session.closing && session[role] === socket) void this.closeSession(session.id, `${role}_disconnected`);
    });
    socket.on('error', () => {
      if (!session.closing && session[role] === socket) void this.closeSession(session.id, `${role}_error`);
    });
    if (role === 'producer') {
      socket.on('message', (data, isBinary) => this.onProducerMessage(session, data, isBinary));
      if (session.viewer) this.enterRecovery(session);
    } else {
      socket.on('message', () => this.reject(socket, 4004, 'viewer is receive-only'));
      this.enterRecovery(session);
    }
    this.logger('video_socket_connected', { sessionId: session.id, role });
  }

  onProducerMessage(session, data, isBinary) {
    if (!isBinary || session.closing) return this.reject(session.producer, 4004, 'binary HVC1 required');
    let parsed;
    try {
      parsed = parseHvc1(data);
    } catch (_) {
      return this.reject(session.producer, 4004, 'malformed HVC1');
    }
    const viewer = session.viewer;
    if (!viewer || viewer.readyState !== WebSocket.OPEN) return;
    if (viewer.bufferedAmount + parsed.frame.length > MAX_BUFFERED_BYTES) {
      session.droppedFrames += 1;
      this.enterRecovery(session);
      return;
    }
    if (session.recovering && parsed.type !== 1 && !parsed.keyframe) {
      session.droppedFrames += 1;
      this.requestKeyframe(session);
      return;
    }
    try {
      viewer.send(parsed.frame, { binary: true });
      if (parsed.keyframe) session.recovering = false;
    } catch (_) {
      void this.closeSession(session.id, 'viewer_send_error');
    }
  }

  requestKeyframe(session) {
    const producer = session.producer;
    if (!producer || producer.readyState !== WebSocket.OPEN) return;
    const now = this.now();
    if (now - session.lastKeyframeRequestAt < KEYFRAME_REQUEST_INTERVAL_MS) return;
    try { producer.send(JSON.stringify({ type: 'request_keyframe' })); } catch (_) {}
    session.lastKeyframeRequestAt = now;
  }

  enterRecovery(session) {
    session.recovering = true;
    this.requestKeyframe(session);
  }

  reject(socket, code, reason) {
    try { socket.close(code, reason); } catch (_) { try { socket.terminate(); } catch (_) {} }
  }

  async closeSession(sessionId, reason = 'ended', throwOnCommandFailure = false) {
    const session = this.sessions.get(sessionId);
    if (!session || session.closing) return false;
    session.closing = true;
    this.sessions.delete(sessionId);
    for (const role of ['producer', 'viewer']) {
      const socket = session[role];
      if (socket && socket.readyState !== WebSocket.CLOSED) this.reject(socket, 4000, 'session ended');
    }
    this.logger('video_session_closed', {
      sessionId,
      reason,
      droppedFrames: session.droppedFrames,
    });
    try {
      await this.dispatchCommand('video_live_stop', { requestId: `${sessionId}:stop`, sessionId });
    } catch (error) {
      this.logger('video_stop_command_failed', { sessionId, code: error.code || 'send_failed' });
      if (throwOnCommandFailure) throw error;
    }
    return true;
  }

  async dispatchCommand(command, payload) {
    let timer;
    const timeout = new Promise((_, reject) => {
      timer = setTimeout(() => reject(codedError(
        'camera_command_timeout', 'Camera command confirmation timed out', 503,
      )), this.commandTimeoutMs);
      timer.unref?.();
    });
    try {
      return await Promise.race([Promise.resolve().then(() => this.sendCarCommand(command, payload)), timeout]);
    } finally {
      clearTimeout(timer);
    }
  }

  authorize(role, request) {
    let sessionId = '';
    try { sessionId = new URL(request.url, 'http://localhost').searchParams.get('session') || ''; }
    catch (_) { return { ok: false, closeCode: 4001, closeReason: 'invalid token', httpStatus: 401, httpReason: 'Unauthorized' }; }
    const tokenMatch = /^Bearer\s+(.+)$/i.exec(String(request.headers?.authorization || ''));
    const token = tokenMatch ? tokenMatch[1].trim() : '';
    const session = this.sessions.get(sessionId);
    if (!session) {
      const elsewhere = [...this.sessions.values()].some(candidate =>
        safeEqual(token, candidate.producerToken.value) || safeEqual(token, candidate.viewerToken.value));
      return elsewhere
        ? { ok: false, closeCode: 4003, closeReason: 'scope mismatch', httpStatus: 403, httpReason: 'Forbidden' }
        : { ok: false, closeCode: 4008, closeReason: 'session unavailable', httpStatus: 404, httpReason: 'Not Found' };
    }
    const ownToken = role === 'producer' ? session.producerToken : session.viewerToken;
    const otherToken = role === 'producer' ? session.viewerToken : session.producerToken;
    if (safeEqual(token, otherToken.value)) return { ok: false, closeCode: 4003, closeReason: 'scope mismatch', httpStatus: 403, httpReason: 'Forbidden' };
    if (!safeEqual(token, ownToken.value)) return { ok: false, closeCode: 4001, closeReason: 'invalid token', httpStatus: 401, httpReason: 'Unauthorized' };
    if (session[role]) return { ok: false, closeCode: role === 'producer' ? 4005 : 4006, closeReason: 'duplicate role', httpStatus: 409, httpReason: 'Conflict' };
    if (this.now() > session.connectExpiresAt || ownToken.consumed) return { ok: false, closeCode: 4002, closeReason: 'token expired or consumed', httpStatus: 401, httpReason: 'Unauthorized' };
    return { ok: true, session, ownToken };
  }

  rejectUpgrade(socket, status, reason) {
    try { socket.write(`HTTP/1.1 ${status} ${reason}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`); } catch (_) {}
    try { socket.destroy(); } catch (_) {}
  }

  currentInvalidAttempts(remoteAddress) {
    const key = remoteAddress || 'unknown';
    const cutoff = this.now() - this.invalidUpgradeWindowMs;
    const attempts = (this.invalidAttempts.get(key) || []).filter(time => time > cutoff);
    if (attempts.length) this.invalidAttempts.set(key, attempts);
    else this.invalidAttempts.delete(key);
    return attempts;
  }

  isUpgradeRateLimited(remoteAddress) {
    return this.currentInvalidAttempts(remoteAddress).length >= this.invalidUpgradeLimit;
  }

  recordInvalidUpgrade(remoteAddress) {
    const key = remoteAddress || 'unknown';
    if (!this.invalidAttempts.has(key) && this.invalidAttempts.size >= MAX_INVALID_IPS) {
      this.invalidAttempts.delete(this.invalidAttempts.keys().next().value);
    }
    const attempts = this.currentInvalidAttempts(key);
    attempts.push(this.now());
    this.invalidAttempts.set(key, attempts);
  }

  sweep() {
    const now = this.now();
    for (const session of [...this.sessions.values()]) {
      if (now > session.expiresAt) void this.closeSession(session.id, 'expired');
      else if (now > session.connectExpiresAt && (!session.producer || !session.viewer)) {
        void this.closeSession(session.id, 'connect_timeout');
      }
    }
  }

  stats(sessionId) {
    const session = this.sessions.get(sessionId);
    return session ? { queuedFrames: 0, droppedFrames: session.droppedFrames } : null;
  }

  hasSession(sessionId) {
    return this.sessions.has(sessionId);
  }
}

module.exports = {
  VideoRelay,
  VideoCommandBroker,
  parseHvc1,
  CONNECT_TTL_MS,
  SESSION_TTL_MS,
  MAX_BUFFERED_BYTES,
};
