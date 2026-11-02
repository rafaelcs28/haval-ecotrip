'use strict';

const crypto = require('node:crypto');
const { WebSocket, WebSocketServer } = require('ws');

const CONNECT_TTL_MS = 60_000;
const SESSION_TTL_MS = 30 * 60_000;
const MAX_BUFFERED_BYTES = 1024 * 1024;
const HVC1_HEADER_BYTES = 24;
const MAX_PAYLOAD_BYTES = 4 * 1024 * 1024;
const MAX_MESSAGE_BYTES = HVC1_HEADER_BYTES + MAX_PAYLOAD_BYTES;

function safeEqual(left, right) {
  const a = Buffer.from(String(left || ''));
  const b = Buffer.from(String(right || ''));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

function websocketUrl(publicUrl, path, sessionId) {
  const url = new URL(publicUrl);
  url.protocol = url.protocol === 'http:' ? 'ws:' : 'wss:';
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
  return { frame, type, keyframe: type === 2 && flags === 1 };
}

class VideoRelay {
  constructor({
    now = Date.now,
    randomBytes = crypto.randomBytes,
    logger = () => {},
    sendCarCommand = async () => {},
  } = {}) {
    this.now = now;
    this.randomBytes = randomBytes;
    this.logger = logger;
    this.sendCarCommand = sendCarCommand;
    this.sessions = new Map();
    this.producerWss = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE_BYTES });
    this.viewerWss = new WebSocketServer({ noServer: true, maxPayload: 1024 });
    this.producerWss.on('connection', (socket, request) => this.attach('producer', request, socket));
    this.viewerWss.on('connection', (socket, request) => this.attach('viewer', request, socket));
    this.timer = setInterval(() => this.sweep(), 10_000);
    this.timer.unref?.();
  }

  async createSession({ publicUrl }) {
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
      recoveryRequested: false,
      closing: false,
    };
    this.sessions.set(sessionId, session);
    const producerUrl = websocketUrl(publicUrl, '/ws/video/live/car', sessionId);
    const viewerUrl = websocketUrl(publicUrl, '/ws/video/live/viewer', sessionId);
    try {
      await this.sendCarCommand('video_live_start', {
        requestId: sessionId,
        sessionUrl: producerUrl,
        producerToken,
        expiresAt: session.expiresAt,
      });
    } catch (error) {
      this.sessions.delete(sessionId);
      throw error;
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
      await this.closeSession(req.params.id, 'owner_stop');
      res.status(204).end();
    });
  }

  handleUpgrade(request, socket, head) {
    const pathname = new URL(request.url, 'http://localhost').pathname;
    const forwardedProto = String(request.headers?.['x-forwarded-proto'] || '')
      .split(',')[0].trim().toLowerCase();
    const secure = request.socket?.encrypted === true || forwardedProto === 'https';
    if ((pathname === '/ws/video/live/car' || pathname === '/ws/video/live/viewer') && !secure) {
      socket.write('HTTP/1.1 426 Upgrade Required\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
      socket.destroy();
      return true;
    }
    if (pathname === '/ws/video/live/car') {
      this.producerWss.handleUpgrade(request, socket, head, ws => this.producerWss.emit('connection', ws, request));
      return true;
    }
    if (pathname === '/ws/video/live/viewer') {
      this.viewerWss.handleUpgrade(request, socket, head, ws => this.viewerWss.emit('connection', ws, request));
      return true;
    }
    return false;
  }

  attach(role, request, socket) {
    let query;
    try {
      query = new URL(request.url, 'http://localhost').searchParams;
    } catch (_) {
      return this.reject(socket, 4001, 'invalid token');
    }
    const sessionId = query.get('session') || '';
    const authorization = String(request.headers?.authorization || '');
    const tokenMatch = /^Bearer\s+(.+)$/i.exec(authorization);
    const token = tokenMatch ? tokenMatch[1].trim() : '';
    const session = this.sessions.get(sessionId);
    if (!session) {
      const tokenBelongsElsewhere = [...this.sessions.values()].some(candidate =>
        safeEqual(token, candidate.producerToken.value) || safeEqual(token, candidate.viewerToken.value));
      return this.reject(socket, tokenBelongsElsewhere ? 4003 : 4008,
        tokenBelongsElsewhere ? 'scope mismatch' : 'session unavailable');
    }
    const ownToken = role === 'producer' ? session.producerToken : session.viewerToken;
    const otherToken = role === 'producer' ? session.viewerToken : session.producerToken;
    if (safeEqual(token, otherToken.value)) return this.reject(socket, 4003, 'scope mismatch');
    if (!safeEqual(token, ownToken.value)) return this.reject(socket, 4001, 'invalid token');
    if (this.now() > session.connectExpiresAt) return this.reject(socket, 4002, 'token expired');
    if (session[role]) return this.reject(socket, role === 'producer' ? 4005 : 4006, 'duplicate role');
    if (ownToken.consumed) return this.reject(socket, 4002, 'token consumed');

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
      if (session.viewer) this.requestKeyframe(session);
    } else {
      socket.on('message', () => this.reject(socket, 4004, 'viewer is receive-only'));
      this.requestKeyframe(session);
    }
    this.logger('video_socket_connected', { sessionId, role });
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
    if (viewer.bufferedAmount > MAX_BUFFERED_BYTES) {
      session.droppedFrames += 1;
      if (!session.recoveryRequested) {
        session.recoveryRequested = true;
        this.requestKeyframe(session);
      }
      return;
    }
    try {
      viewer.send(parsed.frame, { binary: true });
      if (parsed.keyframe) session.recoveryRequested = false;
    } catch (_) {
      void this.closeSession(session.id, 'viewer_send_error');
    }
  }

  requestKeyframe(session) {
    const producer = session.producer;
    if (!producer || producer.readyState !== WebSocket.OPEN) return;
    try { producer.send(JSON.stringify({ type: 'request_keyframe' })); } catch (_) {}
  }

  reject(socket, code, reason) {
    try { socket.close(code, reason); } catch (_) { try { socket.terminate(); } catch (_) {} }
  }

  async closeSession(sessionId, reason = 'ended') {
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
      await this.sendCarCommand('video_live_stop', { requestId: `${sessionId}:stop`, sessionId });
    } catch (error) {
      this.logger('video_stop_command_failed', { sessionId, code: error.code || 'send_failed' });
    }
    return true;
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
  parseHvc1,
  CONNECT_TTL_MS,
  SESSION_TTL_MS,
  MAX_BUFFERED_BYTES,
};

