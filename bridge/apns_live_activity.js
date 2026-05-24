// apns_live_activity.js
// Cliente APNs HTTP/2 mínimo para Live Activities (iOS 16.1+), sem deps externas.
// Faz JWT ES256 manual com `crypto` nativo + HTTP/2 nativo do Node 18+.
//
// Configuração via .env (todas obrigatórias quando ENABLED=true):
//   APNS_ENABLED=true              # liga o subsystem (off por padrão)
//   APNS_TEAM_ID=ABCDE12345         # Team ID da Apple Developer (mesmo p/ free)
//   APNS_KEY_ID=AAAA1111BB          # Key ID do AuthKey .p8
//   APNS_KEY_P8_PATH=/path/key.p8   # caminho do AuthKey ECDSA P-256
//   APNS_BUNDLE_ID=br.com.cl.haval  # bundle do app iOS
//   APNS_ENV=sandbox                # sandbox|production
//                                   # free dev account = sempre sandbox
//
// API exposta:
//   const apns = require('./apns_live_activity');
//   apns.init();                                      // lê .env, valida
//   apns.registerToken(activityId, pushTokenHex);     // chamado por /api/activity/start
//   apns.unregisterToken(activityId);                 // /api/activity/stop
//   apns.pushUpdate(contentState, { isFinal: false }); // envia pra TODOS os tokens
//   apns.tokenCount();
//
const fs    = require('fs');
const path  = require('path');
const crypto = require('crypto');
const http2 = require('http2');

const TOKENS_FILE = path.join(__dirname, 'activity_tokens.json');

let enabled = false;
let teamId = '', keyId = '', bundleId = '', env = 'sandbox';
let privateKeyPem = '';
let tokens = [];   // { activityId, pushToken, registeredMs, lastUsedMs }
let _jwt = '', _jwtIat = 0;

function _saveTokens() {
  try {
    fs.writeFileSync(TOKENS_FILE, JSON.stringify({ updatedAt: new Date().toISOString(), tokens }, null, 2));
  } catch (e) { console.error('[apns] falha salvar tokens:', e.message); }
}

function _loadTokens() {
  try {
    if (fs.existsSync(TOKENS_FILE)) {
      const data = JSON.parse(fs.readFileSync(TOKENS_FILE, 'utf8'));
      tokens = Array.isArray(data.tokens) ? data.tokens : [];
    }
  } catch (e) { console.error('[apns] falha carregar tokens:', e.message); }
}

function init() {
  enabled = process.env.APNS_ENABLED === 'true';
  if (!enabled) {
    console.log('[apns] desativado (APNS_ENABLED != true)');
    return;
  }
  teamId   = process.env.APNS_TEAM_ID    || '';
  keyId    = process.env.APNS_KEY_ID     || '';
  bundleId = process.env.APNS_BUNDLE_ID  || '';
  env      = process.env.APNS_ENV        || 'sandbox';
  const keyPath = process.env.APNS_KEY_P8_PATH || '';
  if (!teamId || !keyId || !bundleId || !keyPath) {
    console.warn('[apns] config incompleta — desabilitando.');
    enabled = false;
    return;
  }
  try {
    privateKeyPem = fs.readFileSync(keyPath, 'utf8');
  } catch (e) {
    console.warn('[apns] falha ler AuthKey:', e.message);
    enabled = false;
    return;
  }
  _loadTokens();
  console.log(`[apns] pronto · team=${teamId} bundle=${bundleId} env=${env} tokens=${tokens.length}`);
}

// JWT ES256 manual. Apple permite reusar o token por até 1h; melhor regenerar
// a cada 50min pra evitar 403:ExpiredProviderToken na borda.
function _getJwt() {
  const now = Math.floor(Date.now() / 1000);
  if (_jwt && (now - _jwtIat) < 50 * 60) return _jwt;
  const header  = Buffer.from(JSON.stringify({ alg: 'ES256', kid: keyId, typ: 'JWT' })).toString('base64url');
  const payload = Buffer.from(JSON.stringify({ iss: teamId, iat: now })).toString('base64url');
  const data    = `${header}.${payload}`;
  const sig     = crypto.sign('sha256', Buffer.from(data), { key: privateKeyPem, dsaEncoding: 'ieee-p1363' });
  _jwt = `${data}.${sig.toString('base64url')}`;
  _jwtIat = now;
  return _jwt;
}

function registerToken(activityId, pushTokenHex) {
  if (!enabled) return;
  // Substitui se já existir com mesmo activityId; senão adiciona
  const idx = tokens.findIndex(t => t.activityId === activityId);
  const rec = {
    activityId,
    pushToken: pushTokenHex,
    registeredMs: Date.now(),
    lastUsedMs:   null,
  };
  if (idx >= 0) tokens[idx] = rec; else tokens.push(rec);
  _saveTokens();
  console.log(`[apns] token registrado (activity=${activityId.slice(0,8)}…, total=${tokens.length})`);
}

function unregisterToken(activityId) {
  if (!enabled) return;
  const before = tokens.length;
  tokens = tokens.filter(t => t.activityId !== activityId);
  if (tokens.length !== before) _saveTokens();
}

function tokenCount() { return tokens.length; }

function _apnsHost() {
  return env === 'production' ? 'api.push.apple.com' : 'api.sandbox.push.apple.com';
}

// Envia o mesmo content-state pra todos os pushTokens registrados.
// `isFinal=true` envia event=end e o iOS encerra a activity em ~4h.
async function pushUpdate(contentState, { isFinal = false } = {}) {
  if (!enabled || !tokens.length) return { sent: 0, skipped: 0 };
  const jwt = _getJwt();
  const client = http2.connect(`https://${_apnsHost()}`);
  let sent = 0, removed = 0;
  const body = JSON.stringify({
    aps: {
      timestamp: Math.floor(Date.now() / 1000),
      event: isFinal ? 'end' : 'update',
      'content-state': contentState,
      // alert opcional: dispara ding quando final. iOS mostra na lock screen.
      ...(isFinal ? {
        alert: { title: '✅ Recarga concluída', body: `SOC ${Math.round(contentState.soc)}% · ${contentState.sessionKwh.toFixed(1)} kWh` },
        sound: 'default',
      } : {}),
    },
  });
  const dead = [];
  await Promise.all(tokens.map(t => new Promise((resolve) => {
    const req = client.request({
      ':method':         'POST',
      ':path':           `/3/device/${t.pushToken}`,
      'authorization':   `bearer ${jwt}`,
      'apns-topic':      `${bundleId}.push-type.liveactivity`,
      'apns-push-type':  'liveactivity',
      'apns-priority':   '10',
      'content-type':    'application/json',
    });
    let status = 0, respBody = '';
    req.on('response', headers => { status = headers[':status']; });
    req.on('data', chunk => { respBody += chunk; });
    req.on('end', () => {
      if (status === 200) {
        sent++;
        t.lastUsedMs = Date.now();
      } else {
        console.warn(`[apns] HTTP ${status} para token ${t.pushToken.slice(0, 8)}…: ${respBody.slice(0, 120)}`);
        // 410 BadDeviceToken ou 403 InvalidProviderToken → remove
        if (status === 410 || (status === 400 && /BadDeviceToken/i.test(respBody))) {
          dead.push(t.activityId);
        }
      }
      resolve();
    });
    req.on('error', err => { console.warn('[apns] erro req:', err.message); resolve(); });
    req.end(body);
  })));
  client.close();
  if (dead.length) {
    tokens = tokens.filter(t => !dead.includes(t.activityId));
    removed = dead.length;
    _saveTokens();
  }
  if (sent || removed) _saveTokens();   // persiste lastUsedMs
  return { sent, skipped: tokens.length - sent, removed };
}

module.exports = { init, registerToken, unregisterToken, pushUpdate, tokenCount };
