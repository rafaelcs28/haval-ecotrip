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
const HVT1_HEADER_BYTES = 56;
const MAX_CHUNK_BYTES = 262144;
const MAX_U64 = (1n << 64n) - 1n;
const MAX_METADATA_BYTES = 1024 * 1024;
const METADATA_STALE_MS = 5 * 60_000;
const BOOLEAN_SETTINGS = ['automaticRecording', 'recordParkedLive', 'remoteLive', 'remoteDownloads',
  'automaticDeletion', 'overlayMaster', 'overlayDateTime', 'overlaySpeed',
  'overlayAcceleration', 'overlayDriveState', 'overlayDecelerationRegen'];
const SETTING_VALUES = { quality: ['economy', 'standard', 'high'], reserveGb: [1, 5, 10, 20],
  overlayPosition: ['top_left', 'top_right', 'bottom_left', 'bottom_right'] };

function validInteger(value, minimum = 0) {
  return Number.isSafeInteger(value) && value >= minimum;
}

function objectKeys(value, allowed) {
  return value !== null && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).every(key => allowed.includes(key));
}

function metadataJson(data) {
  if (!Buffer.isBuffer(data) || data.length > MAX_METADATA_BYTES) throw new Error('metadata too large');
  return JSON.parse(data.toString('utf8'));
}

function validSettings(settings, complete = false) {
  const keys = [...BOOLEAN_SETTINGS, ...Object.keys(SETTING_VALUES)];
  return objectKeys(settings, keys) && Object.keys(settings).length > 0
    && (!complete || Object.keys(settings).length === keys.length)
    && Object.entries(settings).every(([key, value]) => BOOLEAN_SETTINGS.includes(key)
      ? typeof value === 'boolean' : SETTING_VALUES[key].includes(value));
}

function normalizeCatalog(value) {
  if (!objectKeys(value, ['ok', 'catalogRevision', 'updatedAt', 'trips']) || value.ok !== true
      || !validInteger(value.catalogRevision) || !validInteger(value.updatedAt, 1)
      || !Array.isArray(value.trips) || value.trips.length > 4096) throw new Error('invalid catalog');
  const ids = new Set();
  const trips = [];
  for (const trip of value.trips) {
    if (!objectKeys(trip, ['tripId', 'source', 'startMs', 'endMs', 'durationMs', 'byteSize', 'completed', 'segmentCount', 'segments'])
        || typeof trip.tripId !== 'string' || !/^[1-9][0-9]{0,18}$/.test(trip.tripId)
        || !['automatic', 'manual'].includes(trip.source) || !validInteger(trip.startMs)
        || !validInteger(trip.byteSize) || ids.has(trip.tripId)
        || (trip.completed !== undefined && typeof trip.completed !== 'boolean')) throw new Error('invalid trip');
    ids.add(trip.tripId);
    if (trip.completed === false || trip.endMs === null) continue;
    if (!validInteger(trip.endMs, trip.startMs)
        || (trip.durationMs !== undefined && trip.durationMs !== trip.endMs - trip.startMs)) throw new Error('invalid trip time');
    let segmentCount;
    let segments;
    if (Array.isArray(trip.segments)) {
      if (trip.segments.length < 1 || trip.segments.length > 4096) throw new Error('invalid segments');
      segmentCount = trip.segmentCount === undefined ? trip.segments.length : trip.segmentCount;
      if (!validInteger(segmentCount, 1) || segmentCount > 4096
          || segmentCount !== trip.segments.length) throw new Error('invalid segment count');
      let bytes = 0;
      segments = trip.segments.map((segment, index) => {
        if (!objectKeys(segment, ['segmentId', 'byteSize', 'sha256', 'fileName', 'startMs', 'endMs', 'durationUs', 'codec'])
            || segment.segmentId !== index + 1 || !validInteger(segment.byteSize, 1)
            || typeof segment.sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(segment.sha256)
            || (segment.fileName !== undefined && segment.fileName !== `${String(segment.segmentId).padStart(6, '0')}.mp4`)) throw new Error('invalid segment');
        for (const key of ['startMs', 'endMs', 'durationUs']) {
          if (segment[key] !== undefined && !validInteger(segment[key])) throw new Error('invalid segment time');
        }
        if (segment.startMs !== undefined && segment.endMs !== undefined && segment.endMs < segment.startMs) throw new Error('invalid segment time');
        if (segment.codec !== undefined && (!objectKeys(segment.codec, ['mime', 'width', 'height', 'frameRate', 'bitrate'])
            || segment.codec.mime !== 'video/avc' || !['width', 'height', 'frameRate', 'bitrate'].every(key => validInteger(segment.codec[key], 1)))) throw new Error('invalid codec');
        bytes += segment.byteSize;
        if (!validInteger(bytes)) throw new Error('invalid total size');
        // Paths and codec extras are never retained by the remote catalog.
        return { segmentId: segment.segmentId, byteSize: segment.byteSize, sha256: segment.sha256 };
      });
      if (bytes !== trip.byteSize) throw new Error('catalog size mismatch');
    } else {
      segmentCount = trip.segmentCount === undefined ? trip.segments : trip.segmentCount;
      if (!validInteger(segmentCount, 1) || segmentCount > 4096
          || (trip.segments !== undefined && trip.segments !== segmentCount)) throw new Error('invalid segment count');
    }
    trips.push({ tripId: trip.tripId, source: trip.source, startMs: trip.startMs,
      endMs: trip.endMs, byteSize: trip.byteSize, completed: true, segmentCount,
      ...(segments === undefined ? {} : { segments }) });
  }
  return { ok: true, catalogRevision: value.catalogRevision, updatedAt: value.updatedAt, trips };
}

function parseHvt1(frame) {
  if (!Buffer.isBuffer(frame) || frame.length < HVT1_HEADER_BYTES
      || frame.length > HVT1_HEADER_BYTES + MAX_CHUNK_BYTES
      || !frame.subarray(0, 4).equals(Buffer.from('HVT1')) || frame[4] !== 1
      || frame.readUInt16BE(6) !== 0) throw new Error('invalid HVT1 header');
  const type = frame[5];
  const ordinal = frame.readUInt32BE(8);
  const offset = frame.readBigUInt64BE(12);
  const length = frame.readUInt32BE(20);
  if (frame.length !== HVT1_HEADER_BYTES + length) throw new Error('invalid HVT1 length');
  const digest = frame.subarray(24, 56);
  if (type === 1 || type === 4) {
    if (length < 1 || length > (type === 1 ? MAX_CHUNK_BYTES : 1024)
        || (type === 1 && offset > MAX_U64 - BigInt(length)) || (type === 4 && offset !== 0n)
        || !crypto.createHash('sha256').update(frame.subarray(56)).digest().equals(digest)) throw new Error('invalid HVT1 payload');
    if (type === 4) new TextDecoder('utf-8', { fatal: true }).decode(frame.subarray(56));
  } else if (type === 2 || type === 3) {
    if (length !== 0 || (type === 3 && !digest.equals(Buffer.alloc(32)))) throw new Error('invalid HVT1 control');
  } else throw new Error('invalid HVT1 type');
  return { type, ordinal, offset, length, sha256: digest.toString('hex') };
}

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
    if (!result || typeof result !== 'object' || Array.isArray(result)) return false;
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
    metadata = {},
    persistMetadata = () => {},
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
    this.transfers = new Map();
    this.stoppingLive = new Map();
    this.deletingTrips = new Set();
    this.persistMetadata = persistMetadata;
    this.metadata = { catalog: null, settings: null };
    if (!objectKeys(metadata, ['catalog', 'settings'])) metadata = {};
    try { if (metadata.catalog) this.metadata.catalog = normalizeCatalog(metadata.catalog); } catch (_) {}
    if (metadata.settings && validInteger(metadata.settings.revision)
        && validSettings(metadata.settings.settings, true) && validInteger(metadata.settings.updatedAt, 1)) {
      this.metadata.settings = { revision: metadata.settings.revision,
        settings: { ...metadata.settings.settings }, updatedAt: metadata.settings.updatedAt };
    }
    this.producerWss = new WebSocketServer({ noServer: true, maxPayload: MAX_MESSAGE_BYTES });
    this.viewerWss = new WebSocketServer({ noServer: true, maxPayload: HVT1_HEADER_BYTES + 1024 });
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
    this.updateTransferPriority();
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
    const route = (method, path, handler) => app[method](path, requireAuth, async (req, res) => {
      try { await handler(req, res); }
      catch (error) { res.status(error.statusCode || 503).json({ error: error.code || 'camera_command_failed' }); }
    });
    route('get', '/api/video/catalog', (_req, res) => res.json(this.getCatalog()));
    route('get', '/api/video/settings', (_req, res) => {
      const settings = this.getSettings();
      if (!settings) return res.status(503).json({ error: 'video_settings_unavailable' });
      res.json(settings);
    });
    route('patch', '/api/video/settings', async (req, res) => {
      const { expectedRevision, patch } = req.body || {};
      if (!validInteger(expectedRevision) || !validSettings(patch)) {
        return res.status(400).json({ error: 'invalid_video_settings' });
      }
      const current = this.getSettings();
      if (!current) return res.status(503).json({ error: 'video_settings_unavailable' });
      if (expectedRevision !== current.revision) return res.status(409).json({ ...current, conflict: true });
      const result = await this.dispatchCommand('video_settings_update', {
        requestId: this.randomBytes(18).toString('base64url'), expectedRevision, patch,
      });
      if (!result || result.ok !== true || !this.acceptSettings(Buffer.from(JSON.stringify(result)))) {
        throw codedError('invalid_camera_settings', 'invalid Camera settings response', 503);
      }
      res.status(result.applied === true && result.conflict !== true ? 200 : 409).json(this.getSettings());
    });
    route('delete', '/api/video/recordings', async (req, res) => {
      const { tripIds, confirmation } = req.body || {};
      if (confirmation !== 'DELETE_COMPLETED' || !Array.isArray(tripIds) || tripIds.length < 1
          || tripIds.length > 256 || new Set(tripIds).size !== tripIds.length
          || !tripIds.every(id => typeof id === 'string' && this.metadata.catalog?.trips.some(trip => trip.tripId === id))) {
        return res.status(400).json({ error: 'invalid_video_deletion' });
      }
      if (tripIds.some(id => this.deletingTrips.has(id) || [...this.transfers.values()].some(session => session.tripId === id))) {
        return res.status(409).json({ error: 'video_trip_in_use' });
      }
      tripIds.forEach(id => this.deletingTrips.add(id));
      try {
        await this.dispatchCommand('video_delete', { requestId: this.randomBytes(18).toString('base64url'),
          tripIds, confirmation });
        res.status(204).end();
      } finally { tripIds.forEach(id => this.deletingTrips.delete(id)); }
    });
    route('post', '/api/video/transfer/session', async (req, res) => {
      const session = await this.createTransfer({ ...req.body, publicUrl: publicUrl(req) });
      const { producerToken: _producerToken, ...response } = session;
      res.status(201).json(response);
    });
    route('delete', '/api/video/transfer/session/:id', async (req, res) => {
      if (!this.transfers.has(req.params.id)) return res.status(404).json({ error: 'video_session_not_found' });
      await this.closeTransfer(req.params.id, true);
      res.status(204).end();
    });
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
    const role = /^\/ws\/video\/(live|transfer)\/car$/.test(pathname) ? 'producer'
      : /^\/ws\/video\/(live|transfer)\/viewer$/.test(pathname) ? 'viewer' : null;
    if (!role) return false;
    const remoteAddress = normalizeAddress(request.socket?.remoteAddress);
    const forwardedProto = String(request.headers?.['x-forwarded-proto'] || '')
      .split(',')[0].trim().toLowerCase();
    const secure = request.socket?.encrypted === true
      || (this.trustedProxyAddresses.has(remoteAddress) && forwardedProto === 'https');
    if (!secure) {
      if (this.isUpgradeRateLimited(remoteAddress)) {
        this.rejectUpgrade(socket, 429, 'Too Many Requests');
        return true;
      }
      this.recordInvalidUpgrade(remoteAddress);
      this.rejectUpgrade(socket, 426, 'Upgrade Required');
      return true;
    }
    const authorization = this.authorize(role, request);
    if (!authorization.ok) {
      if (this.isUpgradeRateLimited(remoteAddress)) {
        this.rejectUpgrade(socket, 429, 'Too Many Requests');
        return true;
      }
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

    if (session.kind === 'transfer') return this.attachTransfer(role, session, ownToken, socket);

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

  getCatalog() {
    const catalog = this.metadata.catalog || { catalogRevision: 0, updatedAt: 0, trips: [] };
    return { ...structuredClone(catalog), stale: this.now() - catalog.updatedAt > METADATA_STALE_MS };
  }

  getSettings() {
    const settings = this.metadata.settings;
    return settings ? { ...structuredClone(settings), stale: this.now() - settings.updatedAt > METADATA_STALE_MS } : null;
  }

  replaceMetadata(key, value) {
    const next = { ...this.metadata, [key]: value };
    this.persistMetadata(structuredClone(next));
    this.metadata = next;
  }

  acceptCatalog(data) {
    try {
      const next = normalizeCatalog(metadataJson(data));
      const previous = this.metadata.catalog;
      if (next.updatedAt > this.now() + CONNECT_TTL_MS || (previous
          && (next.catalogRevision < previous.catalogRevision || next.updatedAt < previous.updatedAt
          || (next.catalogRevision === previous.catalogRevision
            && JSON.stringify(next.trips) !== JSON.stringify(previous.trips))))) return false;
      this.replaceMetadata('catalog', next);
      for (const session of this.transfers.values()) {
        const trip = next.trips.find(candidate => candidate.tripId === session.tripId);
        if (!trip || !Array.isArray(trip.segments) || [...session.progress].some(([ordinal, progress]) => {
          const segment = trip.segments.find(candidate => candidate.segmentId === ordinal);
          return !segment || BigInt(segment.byteSize) !== progress.size || segment.sha256 !== progress.sha256;
        })) void this.closeTransfer(session.id);
      }
      return true;
    } catch (_) { return false; }
  }

  acceptSettings(data) {
    try {
      const value = metadataJson(data);
      if (!objectKeys(value, ['ok', 'requestId', 'applied', 'conflict', 'revision', 'settings', 'updatedAt'])
          || value.ok !== true || !validInteger(value.revision) || !validSettings(value.settings, true)) return false;
      const previous = this.metadata.settings;
      const updatedAt = value.updatedAt === undefined ? this.now() : value.updatedAt;
      if (!validInteger(updatedAt, 1) || updatedAt > this.now() + CONNECT_TTL_MS || (previous
          && (value.revision < previous.revision || updatedAt < previous.updatedAt
          || (value.revision === previous.revision
            && Object.keys(value.settings).some(key => value.settings[key] !== previous.settings[key]))))) return false;
      this.replaceMetadata('settings', { revision: value.revision, settings: { ...value.settings }, updatedAt });
      return true;
    } catch (_) { return false; }
  }

  async createTransfer({ publicUrl, tripId, segmentIds, sessionId }) {
    websocketUrl(publicUrl, '/ws/video/transfer/car', 'validation');
    this.sweep();
    const trip = this.metadata.catalog?.trips.find(candidate => candidate.tripId === tripId);
    if (!trip || !Array.isArray(segmentIds) || segmentIds.length < 1 || segmentIds.length > 256
        || new Set(segmentIds).size !== segmentIds.length || !segmentIds.every(id => typeof id === 'string'
          && /^[1-9][0-9]{0,9}$/.test(id) && Number(id) <= 0xffffffff)) {
      throw codedError('invalid_video_selection', 'invalid recording selection', 400);
    }
    if (!Array.isArray(trip.segments)) throw codedError('video_segment_metadata_unavailable', 'segment metadata unavailable', 409);
    const segments = segmentIds.map(id => trip.segments.find(segment => String(segment.segmentId) === id));
    if (segments.some(segment => !segment)) throw codedError('invalid_video_selection', 'segment unavailable', 400);
    if (this.metadata.settings?.settings.remoteDownloads === false) throw codedError('video_downloads_disabled', 'downloads disabled', 409);
    if (this.deletingTrips.has(tripId)) throw codedError('video_trip_in_use', 'trip deletion in progress', 409);
    let session;
    if (sessionId !== undefined) {
      session = this.transfers.get(sessionId);
      if (!session || session.tripId !== tripId || JSON.stringify(session.segmentIds) !== JSON.stringify(segmentIds)) {
        throw codedError('invalid_video_resume', 'resume identity mismatch', 409);
      }
      if (session.starting || session.producer || session.viewer) throw codedError('video_transfer_active', 'transfer active', 409);
    } else {
      if (this.transfers.size !== 0) throw codedError('video_transfer_active', 'transfer active', 409);
      const id = this.randomBytes(18).toString('base64url');
      session = { id, kind: 'transfer', tripId, segmentIds: [...segmentIds],
        progress: new Map(segments.map(segment => [segment.segmentId,
          { size: BigInt(segment.byteSize), sha256: segment.sha256, nextOffset: 0n, complete: false }])),
        expiresAt: this.now() + SESSION_TTL_MS, producer: null, viewer: null, closing: false,
        pending: null, paused: true };
      this.transfers.set(id, session);
    }
    session.starting = true;
    session.paused = true;
    session.connectExpiresAt = Math.min(this.now() + CONNECT_TTL_MS, session.expiresAt);
    session.producerToken = { value: this.randomBytes(32).toString('base64url'), consumed: false };
    session.viewerToken = { value: this.randomBytes(32).toString('base64url'), consumed: false };
    const attempt = session.producerToken;
    try {
      await this.dispatchCommand('video_transfer', {
        requestId: this.randomBytes(18).toString('base64url'), sessionId: session.id,
        viewerSession: session.id, tripId, segmentIds: [...segmentIds],
        sessionUrl: websocketUrl(publicUrl, '/ws/video/transfer/car', session.id),
        producerToken: session.producerToken.value, expiresAt: session.expiresAt,
        offsets: this.transferOffsets(session), paused: session.paused,
        completedSegmentIds: [...session.progress].filter(([, progress]) => progress.complete).map(([ordinal]) => String(ordinal)),
      });
    } catch (error) {
      await this.closeTransfer(session.id);
      throw error;
    } finally { session.starting = false; }
    if (this.transfers.get(session.id) !== session || session.closing || session.producerToken !== attempt
        || this.now() >= session.connectExpiresAt || this.now() >= session.expiresAt) {
      await this.closeTransfer(session.id);
      throw codedError('video_session_expired', 'transfer expired before confirmation', 409);
    }
    return { sessionId: session.id, producerToken: session.producerToken.value,
      viewerToken: session.viewerToken.value,
      viewerUrl: websocketUrl(publicUrl, '/ws/video/transfer/viewer', session.id),
      connectExpiresAt: session.connectExpiresAt, expiresAt: session.expiresAt, offsets: this.transferOffsets(session) };
  }

  transferOffsets(session) {
    return Object.fromEntries([...session.progress].map(([ordinal, progress]) => [ordinal, progress.nextOffset.toString()]));
  }

  attachTransfer(role, session, ownToken, socket) {
    ownToken.consumed = true;
    session[role] = socket;
    socket.on('close', () => {
      if (!session.closing && session[role] === socket) this.disconnectTransfer(session);
    });
    socket.on('error', () => {
      if (!session.closing && session[role] === socket) this.disconnectTransfer(session);
    });
    socket.on('message', (data, binary) => {
      if (session.closing || session[role] !== socket) return;
      this.onTransferMessage(session, role, data, binary);
    });
    this.updateTransferPriority();
    if (role === 'producer') this.transferControl(session, session.paused
      ? { type: 'pause', reason: this.sessions.size > 0 || this.stoppingLive.size > 0 ? 'live' : 'viewer' }
      : { type: 'resume', offsets: this.transferOffsets(session) });
  }

  disconnectTransfer(session, code = 4000) {
    const sockets = [session.producer, session.viewer];
    session.producer = null;
    session.viewer = null;
    session.pending = null;
    session.connectExpiresAt = Math.min(this.now() + CONNECT_TTL_MS, session.expiresAt);
    for (const token of [session.producerToken, session.viewerToken]) token.consumed = true;
    for (const socket of sockets) if (socket) this.reject(socket, code, 'transfer attempt ended');
  }

  transferControl(session, message) {
    const producer = session.producer;
    if (producer?.readyState !== WebSocket.OPEN) return;
    try {
      producer.send(JSON.stringify(message), error => {
        if (error && session.producer === producer) this.disconnectTransfer(session);
      });
    } catch (_) { this.disconnectTransfer(session); }
  }

  updateTransferPriority() {
    const live = this.sessions.size > 0 || this.stoppingLive.size > 0;
    for (const session of this.transfers.values()) {
      const paused = live || session.viewer?.readyState !== WebSocket.OPEN;
      if (session.paused === paused || (!paused && session.pending)) continue;
      session.paused = paused;
      this.transferControl(session, paused ? { type: 'pause', reason: live ? 'live' : 'viewer' }
        : { type: 'resume', offsets: this.transferOffsets(session) });
    }
  }

  onTransferMessage(session, role, frame, binary) {
    let parsed;
    try {
      if (!binary) throw new Error('binary required');
      parsed = parseHvt1(frame);
      const progress = session.progress.get(parsed.ordinal);
      if (!progress) throw new Error('unknown ordinal');
      if (parsed.type === 4) {
        // ERROR text is untrusted: never log or persist it.
        const peer = session[role === 'producer' ? 'viewer' : 'producer'];
        if (peer?.readyState === WebSocket.OPEN && peer.bufferedAmount + frame.length <= MAX_BUFFERED_BYTES) {
          try { peer.send(frame, { binary: true }); } catch (_) {}
        }
        this.disconnectTransfer(session);
        return;
      }
      if (role === 'viewer') {
        const pending = session.pending;
        if (parsed.type !== 3 || !pending || !pending.delivered || parsed.ordinal !== pending.ordinal
            || parsed.offset !== pending.nextOffset) throw new Error('invalid ACK');
        if (session.producer?.readyState !== WebSocket.OPEN) return this.disconnectTransfer(session);
        if (session.producer.bufferedAmount + frame.length > MAX_BUFFERED_BYTES) return this.disconnectTransfer(session, 4007);
        // Only the viewer can acknowledge durable writes; send completion alone is insufficient.
        progress.nextOffset = parsed.offset;
        if (pending.type === 2) progress.complete = true;
        session.pending = null;
        const producer = session.producer;
        try { producer.send(frame, { binary: true }, error => {
          if (error && session.producer === producer) this.disconnectTransfer(session);
        }); }
        catch (_) { return this.disconnectTransfer(session); }
        if ([...session.progress.values()].every(value => value.complete)) void this.closeTransfer(session.id);
        else this.updateTransferPriority();
        return;
      }
      if (parsed.type !== 1 && parsed.type !== 2) throw new Error('producer type');
      if (progress.complete || parsed.offset !== progress.nextOffset) throw new Error('unexpected offset');
      if (parsed.type === 1 && parsed.offset + BigInt(parsed.length) > progress.size) throw new Error('segment bounds');
      if (parsed.type === 2 && (parsed.offset !== progress.size || parsed.sha256 !== progress.sha256)) throw new Error('invalid EOF');
      // A chunk already in flight when live starts is dropped without ACK or retention.
      if (session.paused) return;
      if (session.pending) throw new Error('unacknowledged chunk');
      const viewer = session.viewer;
      if (viewer?.readyState !== WebSocket.OPEN) return this.disconnectTransfer(session);
      if (viewer.bufferedAmount + frame.length > MAX_BUFFERED_BYTES) return this.disconnectTransfer(session, 4007);
      const pending = { ordinal: parsed.ordinal, type: parsed.type,
        nextOffset: parsed.offset + BigInt(parsed.length), delivered: false };
      session.pending = pending;
      try {
        viewer.send(frame, { binary: true }, error => {
          if (session.pending !== pending || session.viewer !== viewer) return;
          if (error) this.disconnectTransfer(session);
          else pending.delivered = true;
        });
      } catch (_) { this.disconnectTransfer(session); }
    } catch (_) {
      this.disconnectTransfer(session, 4004);
    }
  }

  async closeTransfer(sessionId, throwOnCommandFailure = false) {
    const session = this.transfers.get(sessionId);
    if (!session || session.closing) return false;
    session.closing = true;
    this.transfers.delete(sessionId);
    this.disconnectTransfer(session);
    try {
      await this.dispatchCommand('video_transfer_cancel', {
        requestId: this.randomBytes(18).toString('base64url'), sessionId,
      });
    } catch (error) {
      if (throwOnCommandFailure) throw error;
    }
    return true;
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
    this.stoppingLive.set(sessionId, session.expiresAt);
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
      this.stoppingLive.delete(sessionId);
      this.updateTransferPriority();
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
    const transfer = new URL(request.url, 'http://localhost').pathname.startsWith('/ws/video/transfer/');
    const session = (transfer ? this.transfers : this.sessions).get(sessionId);
    if (!session) {
      const elsewhere = [...this.sessions.values(), ...this.transfers.values()].some(candidate =>
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
    if (this.now() >= session.connectExpiresAt || this.now() >= session.expiresAt || ownToken.consumed) return { ok: false, closeCode: 4002, closeReason: 'token expired or consumed', httpStatus: 401, httpReason: 'Unauthorized' };
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
    for (const [id, expiresAt] of this.stoppingLive) {
      if (now >= expiresAt) this.stoppingLive.delete(id);
    }
    this.updateTransferPriority();
    for (const session of [...this.transfers.values()]) {
      if (now >= session.expiresAt || (now >= session.connectExpiresAt && (!session.producer || !session.viewer))) {
        void this.closeTransfer(session.id);
      }
    }
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
  parseHvt1,
  CONNECT_TTL_MS,
  SESSION_TTL_MS,
  MAX_BUFFERED_BYTES,
};
