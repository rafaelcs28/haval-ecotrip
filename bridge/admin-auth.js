// Área administrativa do monitor: senha + TOTP, e emissão de tokens do bridge
// com escopo.
//
// Por que existe: até aqui o bridge tinha UM token só (BRIDGE_TOKEN_HASH),
// compartilhado por app, cluster, OBD, atalhos e scripts. Qualquer vazamento
// obrigava a trocar tudo de uma vez, e não havia como dar acesso só-leitura pra
// um consumidor. Aqui os tokens passam a ter nome, escopo e revogação
// individual.
//
// Decisão de segurança: a página do monitor está pública em bridge.malha.dev, e
// emitir credencial a partir dela concentra risco. Então a área de tokens NÃO
// herda a sessão do monitor — exige senha + código TOTP na hora, e a sessão
// resultante é curta. Tokens da Cloudflare ficam de fora de propósito: emitir
// aqueles exigiria guardar no Mac Mini um token com "API Tokens: Edit", que é
// chave mestra da conta inteira (inclusive de outras zonas).

const fs     = require('fs');
const path   = require('path');
const crypto = require('crypto');

let authenticator = null;
try { authenticator = require('otplib').authenticator; } catch (_) {}

const SESSION_TTL_MS   = 30 * 60_000;   // sessão admin curta — é pra emitir token, não pra morar nela
const LOGIN_WINDOW_MS  = 15 * 60_000;
const LOGIN_MAX_FAILS  = 6;             // por janela, por IP
const SCRYPT_N         = 16384;

class AdminAuth {
  constructor(dataDir) {
    this.file       = path.join(dataDir, 'admin_auth.json');
    this.tokensFile = path.join(dataDir, 'bridge_tokens.json');
    this.state      = this._load(this.file,       { password: null, totp: null, createdMs: 0 });
    this.tokens     = this._load(this.tokensFile, []);
    // Sessões só em memória: restart do bridge derruba o acesso admin, que é o
    // comportamento desejado pra uma área que emite credencial.
    this.sessions = new Map();
    this.fails    = new Map();
  }

  _load(f, fallback) {
    try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch (_) { return fallback; }
  }
  _save(f, data) {
    try {
      fs.writeFileSync(f, JSON.stringify(data, null, 2), { mode: 0o600 });
      return true;
    } catch (e) { console.warn('[admin-auth] falha ao salvar', f, e.message); return false; }
  }

  // ── senha ──────────────────────────────────────────────────────────────────
  get configured() { return !!(this.state.password && this.state.totp); }

  _hashPassword(pw, salt) {
    return crypto.scryptSync(pw, salt, 64, { N: SCRYPT_N, r: 8, p: 1 }).toString('hex');
  }

  setPassword(pw) {
    if (!pw || String(pw).length < 10) return { ok: false, error: 'senha_curta' };  // 10+ porque é a porta da emissão de tokens
    const salt = crypto.randomBytes(16).toString('hex');
    this.state.password = { salt, hash: this._hashPassword(String(pw), salt), setMs: Date.now() };
    if (!this.state.createdMs) this.state.createdMs = Date.now();
    this._save(this.file, this.state);
    return { ok: true };
  }

  verifyPassword(pw) {
    const p = this.state.password;
    if (!p || !pw) return false;
    const calc = Buffer.from(this._hashPassword(String(pw), p.salt), 'hex');
    const want = Buffer.from(p.hash, 'hex');
    if (calc.length !== want.length) return false;
    return crypto.timingSafeEqual(calc, want);
  }

  // ── TOTP ───────────────────────────────────────────────────────────────────
  // Segredo fica pendente até o primeiro código bater: sem isso, um setup
  // interrompido no meio deixaria o 2FA "ligado" com segredo que ninguém tem.
  beginTotpSetup(label = 'malha.dev') {
    if (!authenticator) return { ok: false, error: 'otplib_ausente' };
    const secret = authenticator.generateSecret();
    this.state.totpPending = { secret, startedMs: Date.now() };
    this._save(this.file, this.state);
    const uri = authenticator.keyuri('admin', `Bridge ${label}`, secret);
    return { ok: true, secret, uri };
  }

  confirmTotpSetup(code) {
    if (!authenticator) return { ok: false, error: 'otplib_ausente' };
    const p = this.state.totpPending;
    if (!p) return { ok: false, error: 'sem_setup_pendente' };
    if (!authenticator.check(String(code || '').trim(), p.secret)) return { ok: false, error: 'codigo_invalido' };
    this.state.totp = { secret: p.secret, setMs: Date.now() };
    delete this.state.totpPending;
    this._save(this.file, this.state);
    return { ok: true };
  }

  /// Valida o código SEM consumir. Quem consome é `consumeTotp`, e só depois de
  /// os dois fatores fecharem — se marcasse aqui, um login com senha errada e
  /// código certo queimaria o código do dono (ele teria que esperar a próxima
  /// janela de 30s), e daria a um atacante uma forma barata de negar acesso.
  verifyTotp(code) {
    if (!authenticator || !this.state.totp) return false;
    const c = String(code || '').trim();
    if (!/^\d{6}$/.test(c)) return false;
    if (this.state.lastTotp === c) return false;   // já usado num login bem-sucedido
    return authenticator.check(c, this.state.totp.secret);
  }

  /// Marca o código como gasto. TOTP vale 30s, então sem isso o mesmo código
  /// serviria de novo dentro da janela.
  consumeTotp(code) {
    this.state.lastTotp = String(code || '').trim();
    this._save(this.file, this.state);
  }

  // ── rate limit de login ────────────────────────────────────────────────────
  _failKey(ip) { return String(ip || 'unknown'); }

  blocked(ip) {
    const e = this.fails.get(this._failKey(ip));
    if (!e) return false;
    if (Date.now() - e.since > LOGIN_WINDOW_MS) { this.fails.delete(this._failKey(ip)); return false; }
    return e.n >= LOGIN_MAX_FAILS;
  }
  noteFail(ip) {
    const k = this._failKey(ip);
    const e = this.fails.get(k);
    if (!e || Date.now() - e.since > LOGIN_WINDOW_MS) this.fails.set(k, { n: 1, since: Date.now() });
    else e.n += 1;
  }
  clearFails(ip) { this.fails.delete(this._failKey(ip)); }

  // ── sessão admin ───────────────────────────────────────────────────────────
  createSession(ip) {
    const sid = crypto.randomBytes(32).toString('hex');
    this.sessions.set(sid, { ip, createdMs: Date.now(), expiresMs: Date.now() + SESSION_TTL_MS });
    this._gcSessions();
    return { sid, expiresMs: Date.now() + SESSION_TTL_MS };
  }

  validSession(sid) {
    const s = sid && this.sessions.get(sid);
    if (!s) return null;
    if (Date.now() > s.expiresMs) { this.sessions.delete(sid); return null; }
    return s;
  }

  dropSession(sid) { this.sessions.delete(sid); }
  _gcSessions() {
    const now = Date.now();
    for (const [k, v] of this.sessions) if (now > v.expiresMs) this.sessions.delete(k);
  }

  // ── tokens do bridge ───────────────────────────────────────────────────────
  // Escopos aplicados por método HTTP, que é o que dá pra garantir de forma
  // confiável sem auditar centenas de rotas uma a uma:
  //   read  → só GET/HEAD
  //   write → GET/HEAD + POST/PUT/PATCH/DELETE
  //   admin → tudo, incluindo a própria área administrativa
  static SCOPES = ['read', 'write', 'admin'];

  issueToken({ name, scope }) {
    const nm = String(name || '').trim().slice(0, 60);
    if (!nm) return { ok: false, error: 'nome_obrigatorio' };
    if (!AdminAuth.SCOPES.includes(scope)) return { ok: false, error: 'escopo_invalido' };
    // O token em claro aparece UMA vez; guardamos só o sha256, igual senha.
    const raw = crypto.randomBytes(32).toString('hex');
    const rec = {
      id: crypto.randomBytes(8).toString('hex'),
      name: nm,
      scope,
      hash: crypto.createHash('sha256').update(raw).digest('hex'),
      createdMs: Date.now(),
      lastUsedMs: 0,
      revokedMs: 0,
    };
    this.tokens.push(rec);
    this._save(this.tokensFile, this.tokens);
    return { ok: true, token: raw, record: this._public(rec) };
  }

  revokeToken(id) {
    const t = this.tokens.find(x => x.id === id);
    if (!t) return { ok: false, error: 'nao_encontrado' };
    if (t.revokedMs) return { ok: true, already: true };
    t.revokedMs = Date.now();
    this._save(this.tokensFile, this.tokens);
    return { ok: true };
  }

  deleteToken(id) {
    const n = this.tokens.length;
    this.tokens = this.tokens.filter(x => x.id !== id);
    if (this.tokens.length === n) return { ok: false, error: 'nao_encontrado' };
    this._save(this.tokensFile, this.tokens);
    return { ok: true };
  }

  _public(t) {
    return { id: t.id, name: t.name, scope: t.scope, createdMs: t.createdMs,
             lastUsedMs: t.lastUsedMs, revokedMs: t.revokedMs };
  }
  list() { return this.tokens.map(t => this._public(t)).sort((a, b) => b.createdMs - a.createdMs); }

  /// Casa um Bearer com os tokens emitidos. Devolve o registro ou null.
  /// Grava lastUsedMs no máximo 1x/min pra não escrever em disco a cada request.
  match(raw) {
    if (!raw) return null;
    const h = crypto.createHash('sha256').update(String(raw)).digest('hex');
    const hb = Buffer.from(h, 'hex');
    for (const t of this.tokens) {
      if (t.revokedMs) continue;
      const tb = Buffer.from(t.hash, 'hex');
      if (tb.length === hb.length && crypto.timingSafeEqual(tb, hb)) {
        const now = Date.now();
        if (now - (t.lastUsedMs || 0) > 60_000) { t.lastUsedMs = now; this._save(this.tokensFile, this.tokens); }
        return t;
      }
    }
    return null;
  }

  /// Escopo permite o método? Base da autorização por token.
  static scopeAllows(scope, method) {
    const m = String(method || 'GET').toUpperCase();
    if (scope === 'admin') return true;
    if (scope === 'read')  return m === 'GET' || m === 'HEAD' || m === 'OPTIONS';
    if (scope === 'write') return true;
    return false;
  }
}

module.exports = { AdminAuth };
