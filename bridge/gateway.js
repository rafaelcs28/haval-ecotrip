'use strict';
// gateway.js — porta de entrada ÚNICA do multi-tenant.
//
// Uma URL/porta pra todo mundo (Funnel 443 → esta porta). A pessoa entra com a
// CONTA GOOGLE dela; identificamos pelo EMAIL e roteamos pra instância isolada
// dela (tenants/registry.json: email → { port, name }). NÃO há senha: a
// autenticação é delegada ao Google. 2FA (TOTP) é opcional por instância e passa
// direto (o backend pede `requires_2fa` e o gateway repassa o código).
//
// A verificação REAL do ID token + checagem de whitelist acontece no backend de
// cada tenant (/api/auth/google/login). Aqui só lemos o email do payload para
// ROTEAR (um token forjado cai num backend que o rejeita) e setamos um cookie
// assinado pra rotear as próximas requisições (inclui o WebSocket /ws).
//
// Env: GATEWAY_PORT (default 4000), GOOGLE_OAUTH_CLIENT_ID (pro botão na tela).

const http      = require('http');
const fs        = require('fs');
const path      = require('path');
const crypto    = require('crypto');
const httpProxy = require('http-proxy');
const cookieLib = require('cookie');

require('dotenv').config({ path: path.join(__dirname, '.env') });

const TENANTS_DIR   = path.join(__dirname, 'tenants');
const REGISTRY_FILE = path.join(TENANTS_DIR, 'registry.json');
const SECRET_FILE   = path.join(TENANTS_DIR, 'gateway_secret');
const LOGIN_FILE    = path.join(__dirname, 'gateway-login.html');
const PORT          = parseInt(process.env.GATEWAY_PORT || '4000', 10);
const GOOGLE_CLIENT_ID = process.env.GOOGLE_OAUTH_CLIENT_ID || '';
const { exec } = require('child_process');
// Admins (podem adicionar/remover pessoas pelo painel). Default: o dono.
const ADMIN_EMAILS = (process.env.GATEWAY_ADMIN_EMAILS || 'rafaelcs28@gmail.com')
  .split(',').map(s => s.trim().toLowerCase()).filter(Boolean);
const APP_URL = process.env.GATEWAY_PUBLIC_URL || 'https://mac-mini.tailacc6e7.ts.net';

// segredo p/ assinar o cookie de roteamento
let SECRET = '';
try { SECRET = fs.readFileSync(SECRET_FILE, 'utf8').trim(); } catch (_) {}
if (!SECRET) {
  SECRET = crypto.randomBytes(32).toString('hex');
  fs.mkdirSync(TENANTS_DIR, { recursive: true });
  fs.writeFileSync(SECRET_FILE, SECRET, { mode: 0o600 });
}

// registry: email → { port, name } (recarrega ao mudar o arquivo)
let registry = {};
function loadRegistry() {
  try {
    const raw = JSON.parse(fs.readFileSync(REGISTRY_FILE, 'utf8'));
    const norm = {};
    for (const [k, v] of Object.entries(raw)) norm[k.toLowerCase().trim()] = v;
    registry = norm;
    console.log(`[gw] registry: ${Object.keys(registry).length} tenant(s) — ${Object.keys(registry).join(', ')}`);
  } catch (e) { console.error('[gw] registry inválido:', e.message); }
}
loadRegistry();
try { fs.watch(REGISTRY_FILE, () => loadRegistry()); } catch (_) {}

const COOKIE = 'etenant';
function sign(email) {
  const mac = crypto.createHmac('sha256', SECRET).update(email).digest('base64url');
  return email + '.' + mac;
}
function verify(val) {
  if (!val) return null;
  const i = val.lastIndexOf('.');
  if (i < 0) return null;
  const email = val.slice(0, i), mac = val.slice(i + 1);
  const exp = crypto.createHmac('sha256', SECRET).update(email).digest('base64url');
  try {
    if (mac.length === exp.length && crypto.timingSafeEqual(Buffer.from(mac), Buffer.from(exp))) return email;
  } catch (_) {}
  return null;
}
function tenantOf(req) {
  const c = cookieLib.parse(req.headers.cookie || '');
  const email = verify(c[COOKIE]);
  if (email && registry[email]) return { email, ...registry[email] };
  return null;
}
function setCookie(res, req, email) {
  const secure = (req.headers['x-forwarded-proto'] || '').includes('https');
  res.setHeader('Set-Cookie', cookieLib.serialize(COOKIE, sign(email), {
    httpOnly: true, sameSite: 'lax', secure, path: '/', maxAge: 60 * 60 * 24 * 30,
  }));
}

const proxy = httpProxy.createProxyServer({ ws: true, xfwd: true });
proxy.on('error', (err, req, res) => {
  console.warn('[gw] proxy erro:', err.message);
  if (res && res.writeHead && !res.headersSent) { res.writeHead(502); res.end('bad gateway'); }
});

function readJson(req) {
  return new Promise((resolve) => {
    let b = '';
    req.on('data', c => { b += c; if (b.length > 1e6) req.destroy(); });
    req.on('end', () => { try { resolve(JSON.parse(b || '{}')); } catch { resolve({}); } });
  });
}
function sendJson(res, code, obj) { res.writeHead(code, { 'content-type': 'application/json' }); res.end(JSON.stringify(obj)); }

// Lê o email do payload do ID token — SÓ pra rotear. O backend verifica de verdade.
function emailFromCredential(cred) {
  try {
    const p = JSON.parse(Buffer.from(String(cred).split('.')[1] || '', 'base64').toString('utf8'));
    return (p.email || '').toLowerCase().trim();
  } catch { return ''; }
}

// Encaminha o login (Google/Apple) ao backend do tenant (que verifica + checa whitelist + 2FA).
function backendLogin(port, urlPath, body) {
  return new Promise((resolve) => {
    const data = JSON.stringify(body);
    const r = http.request({
      host: '127.0.0.1', port, path: urlPath, method: 'POST',
      headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(data) },
    }, (resp) => {
      let b = ''; resp.on('data', c => b += c);
      resp.on('end', () => { let j = {}; try { j = JSON.parse(b || '{}'); } catch {} resolve({ status: resp.statusCode, body: j }); });
    });
    r.on('error', () => resolve({ status: 502, body: { error: 'backend_unreachable' } }));
    r.write(data); r.end();
  });
}

// ── Admin: provisionar / remover tenants ──────────────────────────────────
function isAdmin(req) {
  const t = tenantOf(req);
  return !!(t && ADMIN_EMAILS.includes(t.email.toLowerCase()));
}
const _envGet = (k, def = '') => process.env[k] || def;
const _rnd = (n) => crypto.randomBytes(n).toString('hex');
function _writeRegistry(reg) { fs.writeFileSync(REGISTRY_FILE, JSON.stringify(reg, null, 2) + '\n'); loadRegistry(); }

// Modelo B: o admin cria SÓ email + apelido. MQTT/HA/chassi ficam em branco — a
// pessoa configura sozinha (Ajustes → Veículo → Conexão), apontando pro broker da
// PRÓPRIA Home Assistant. O admin não gera credenciais nem vê dados da pessoa.
async function provisionTenant({ name, email }) {
  name  = String(name  || '').toLowerCase().trim();
  email = String(email || '').toLowerCase().trim();
  if (!/^[a-z0-9_]+$/.test(name))   throw new Error('apelido inválido (use a-z, 0-9, _)');
  if (!/^[^@]+@[^@]+$/.test(email)) throw new Error('email inválido');
  let reg = {}; try { reg = JSON.parse(fs.readFileSync(REGISTRY_FILE, 'utf8')); } catch (_) {}
  if (reg[email]) throw new Error('email já cadastrado');
  const dir = path.join(TENANTS_DIR, name);
  if (fs.existsSync(path.join(dir, '.env'))) throw new Error('já existe um tenant com esse apelido');
  const port = Math.max(3000, ...Object.values(reg).map(v => +v.port || 0)) + 1;
  const apiToken = _rnd(32);
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, '.env'), [
    `# Tenant: ${name} <${email}> — painel admin ${new Date().toISOString()}`,
    `PORT=${port}`,
    `GOOGLE_OAUTH_CLIENT_ID=${_envGet('GOOGLE_OAUTH_CLIENT_ID')}`,
    `GOOGLE_IOS_CLIENT_ID=${_envGet('GOOGLE_IOS_CLIENT_ID')}`,
    `GOOGLE_ALLOWED_EMAILS=${email}`,
    `APPLE_ALLOWED_EMAILS=${email}`,
    // A pessoa preenche tudo abaixo no auto-serviço (broker da HA dela, via Tailscale):
    `MQTT_HOST=`, `MQTT_PORT=1883`, `MQTT_USER=`, `MQTT_PASS=`, `MQTT_PREFIX=haval/${name}`,
    `GWM_CHASSI=`, `HA_URL=`, `HA_TOKEN=`,
    `BRIDGE_TOKEN_HASH=${apiToken}`,
    `APNS_ENABLED=${_envGet('APNS_ENABLED')}`, `APNS_TEAM_ID=${_envGet('APNS_TEAM_ID')}`,
    `APNS_KEY_ID=${_envGet('APNS_KEY_ID')}`, `APNS_KEY_P8_PATH=${_envGet('APNS_KEY_P8_PATH')}`,
    `APNS_BUNDLE_ID=${_envGet('APNS_BUNDLE_ID')}`, `APNS_ENV=${_envGet('APNS_ENV')}`, '',
  ].join('\n'), { mode: 0o600 });
  reg[email] = { port, name }; _writeRegistry(reg);
  return new Promise((resolve) => {
    exec(`pm2 start server.js --name ecotrip-${name} --update-env && pm2 save`,
      { cwd: __dirname, env: { ...process.env, ECOTRIP_DATA_DIR: dir } },
      (err, _out, serr) => resolve({
        ok: true, name, email, port, app_url: APP_URL,
        instance: err ? ('⚠️ falha ao subir: ' + (serr || err.message)) : 'instância iniciada (pm2 ecotrip-' + name + ')',
      }));
  });
}

async function removeTenant(email) {
  email = String(email || '').toLowerCase().trim();
  if (ADMIN_EMAILS.includes(email)) throw new Error('não dá pra remover um admin');
  let reg = {}; try { reg = JSON.parse(fs.readFileSync(REGISTRY_FILE, 'utf8')); } catch (_) {}
  const t = reg[email];
  if (!t) throw new Error('email não encontrado');
  delete reg[email]; _writeRegistry(reg);
  return new Promise((resolve) => {
    exec(`pm2 delete ecotrip-${t.name} && pm2 save`, { cwd: __dirname }, () =>
      resolve({ ok: true, removed: email, name: t.name, note: `instância parada; dados em tenants/${t.name}/ preservados` }));
  });
}

let LOGIN_HTML = '<!doctype html><meta charset=utf-8><title>Login</title><p>login indisponível</p>';
function loadLoginHtml() {
  try { LOGIN_HTML = fs.readFileSync(LOGIN_FILE, 'utf8').replace(/__GOOGLE_CLIENT_ID__/g, GOOGLE_CLIENT_ID); }
  catch (e) { console.error('[gw] gateway-login.html não lido:', e.message); }
}
loadLoginHtml();

const server = http.createServer(async (req, res) => {
  const url = req.url || '/';

  // login federado (Google/Apple) → roteia por email, backend verifica + 2FA
  if (req.method === 'POST' && (url === '/gw/google' || url === '/gw/apple')) {
    const { credential, totp_code } = await readJson(req);
    const email = emailFromCredential(credential);
    const t = registry[email];
    if (!t) return sendJson(res, 403, { error: 'email_not_allowed', email });
    const backendPath = url === '/gw/apple' ? '/api/auth/apple/login' : '/api/auth/google/login';
    const r = await backendLogin(t.port, backendPath, { credential, totp_code });
    if (r.status === 200 && r.body.ok) { setCookie(res, req, email); return sendJson(res, 200, r.body); }
    return sendJson(res, r.status || 401, r.body);
  }

  if (url === '/gw/logout') {
    res.setHeader('Set-Cookie', cookieLib.serialize(COOKIE, '', { path: '/', maxAge: 0 }));
    res.writeHead(302, { location: '/' }); return res.end();
  }

  // ── Painel de admin ──────────────────────────────────────────────────────
  // /gw/admin/me responde pra qualquer logado (a PWA usa pra mostrar/ocultar o painel).
  if (req.method === 'GET' && url === '/gw/admin/me') {
    const me = tenantOf(req);
    return sendJson(res, 200, { admin: !!(me && ADMIN_EMAILS.includes(me.email.toLowerCase())), email: me?.email || null });
  }
  if (url.startsWith('/gw/admin')) {
    if (!isAdmin(req)) return sendJson(res, 403, { error: 'not_admin' });
    if (req.method === 'GET' && url === '/gw/admin/tenants') {
      const list = Object.entries(registry).map(([email, v]) =>
        ({ email, name: v.name, port: v.port, admin: ADMIN_EMAILS.includes(email) }));
      return sendJson(res, 200, { tenants: list });
    }
    if (req.method === 'POST' && url === '/gw/admin/tenants') {
      try { return sendJson(res, 200, await provisionTenant(await readJson(req))); }
      catch (e) { return sendJson(res, 400, { error: e.message }); }
    }
    if (req.method === 'DELETE' && url.startsWith('/gw/admin/tenants/')) {
      const email = decodeURIComponent(url.slice('/gw/admin/tenants/'.length));
      try { return sendJson(res, 200, await removeTenant(email)); }
      catch (e) { return sendJson(res, 400, { error: e.message }); }
    }
    return sendJson(res, 404, { error: 'admin_route' });
  }

  // já autenticado → proxy pra instância isolada do tenant
  const t = tenantOf(req);
  if (t) return proxy.web(req, res, { target: `http://127.0.0.1:${t.port}` });

  // sem cookie válido: navegação HTML → tela de login Google; senão 401
  const accept = req.headers['accept'] || '';
  if (req.method === 'GET' && accept.includes('text/html')) {
    res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' });
    return res.end(LOGIN_HTML);
  }
  return sendJson(res, 401, { error: 'not_authenticated' });
});

server.on('upgrade', (req, socket, head) => {
  const t = tenantOf(req);
  if (!t) { socket.destroy(); return; }
  proxy.ws(req, socket, head, { target: `http://127.0.0.1:${t.port}` });
});

server.listen(PORT, () => {
  console.log(`[gw] porteiro multi-tenant (Google-only) na porta ${PORT}`);
  if (!GOOGLE_CLIENT_ID) console.warn('[gw] ⚠️  GOOGLE_OAUTH_CLIENT_ID vazio — botão Google não vai renderizar.');
});
