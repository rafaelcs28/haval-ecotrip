// impulse-help.js — Q&A público sobre o manual de instalação do HAVAL IMPULSE.
//
// Fluxo:
//   1. Admin conecta o Google Drive via OAuth2 (scope drive.readonly) — refresh_token
//      salvo em impulse-help-token.json.
//   2. Admin clica "recarregar" (ou POST /api/impulse-help/refresh): bridge baixa o
//      doc via Drive API export (text/plain), grava em impulse_manual.md.
//   3. Público faz pergunta em /impulse-help.html → POST /api/impulse-help/ask →
//      bridge spawna `claude -p --model claude-opus-4-8` com prompt = manual + pergunta.
//
// Não usa Anthropic SDK direto: reutiliza CLI `claude` (mesmo padrão do it-agent.js),
// aproveitando auth local e prompt caching automático entre chamadas.

const fs   = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const { OAuth2Client } = require('google-auth-library');
const multer = require('multer');

const DATA_DIR      = process.env.DATA_DIR || __dirname;
const TOKEN_PATH    = path.join(DATA_DIR, 'impulse-help-token.json');
const MANUAL_PATH   = path.join(DATA_DIR, 'impulse_manual.md');
const CACHE_PATH    = path.join(DATA_DIR, 'impulse_qa_cache.json');
const UPLOADS_DIR   = path.join(DATA_DIR, 'uploads');
try { fs.mkdirSync(UPLOADS_DIR, { recursive: true }); } catch {}

const _extFromMime = m => ({
  'image/jpeg': '.jpg', 'image/jpg': '.jpg',
  'image/png': '.png', 'image/webp': '.webp',
  'image/heic': '.heic', 'image/heif': '.heif',
}[String(m).toLowerCase()] || '');
const upload = multer({
  storage: multer.diskStorage({
    destination: (_r, _f, cb) => cb(null, UPLOADS_DIR),
    filename: (_r, file, cb) => cb(null, require('crypto').randomBytes(12).toString('hex') + _extFromMime(file.mimetype)),
  }),
  limits: { fileSize: 8 * 1024 * 1024 },
  fileFilter: (_req, file, cb) => {
    const ok = /^image\/(jpe?g|png|webp|heic|heif)$/i.test(file.mimetype);
    cb(ok ? null : new Error('image_type_not_allowed'), ok);
  },
});

// OAuth do Impulse Help é separado do Google Sign-In do PWA (que usa GOOGLE_OAUTH_CLIENT_ID
// só pra verificar ID token). Aqui precisamos de client_id+secret com scope Drive.
const CLIENT_ID     = process.env.IMPULSE_GOOGLE_CLIENT_ID     || process.env.GOOGLE_OAUTH_CLIENT_ID;
const CLIENT_SECRET = process.env.IMPULSE_GOOGLE_CLIENT_SECRET || process.env.GOOGLE_OAUTH_CLIENT_SECRET;
const PUBLIC_URL    = (process.env.BRIDGE_PUBLIC_URL || 'https://carro.malha.dev').replace(/\/+$/, '');
const REDIRECT_URI  = `${PUBLIC_URL}/api/impulse-help/oauth/callback`;

const DOC_ID        = process.env.IMPULSE_MANUAL_DOC_ID || '1itZW5qKSydbrvmj3imQovewRKLYU_nI93mVteE2QRIc';
const CLAUDE_BIN    = process.env.CLAUDE_BIN || 'claude';
const CLAUDE_MODEL  = process.env.IMPULSE_HELP_MODEL || 'claude-opus-4-8';
const CLAUDE_EFFORT = process.env.IMPULSE_HELP_EFFORT || 'medium';

const enabled = !!(CLIENT_ID && CLIENT_SECRET);

function loadToken() {
  try { return JSON.parse(fs.readFileSync(TOKEN_PATH, 'utf8')); } catch { return null; }
}
function saveToken(t) {
  fs.writeFileSync(TOKEN_PATH, JSON.stringify(t, null, 2));
  try { fs.chmodSync(TOKEN_PATH, 0o600); } catch {}
}

function makeOAuth() {
  return new OAuth2Client(CLIENT_ID, CLIENT_SECRET, REDIRECT_URI);
}

// CSRF state store — expira em 5min.
const oauthStates = new Map();
setInterval(() => {
  const now = Date.now();
  for (const [k, exp] of oauthStates) if (exp < now) oauthStates.delete(k);
}, 60_000).unref();

async function fetchManualFromDrive() {
  const tok = loadToken();
  if (!tok?.refresh_token) throw new Error('sem_refresh_token');
  const oauth = makeOAuth();
  oauth.setCredentials({ refresh_token: tok.refresh_token });
  const { token: accessToken } = await oauth.getAccessToken();
  if (!accessToken) throw new Error('access_token_indisponivel');

  const url = `https://www.googleapis.com/drive/v3/files/${DOC_ID}/export?mimeType=text/plain`;
  const r = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}` } });
  if (!r.ok) {
    const body = await r.text();
    throw new Error(`drive_export_${r.status}: ${body.slice(0, 300)}`);
  }
  const text = await r.text();
  if (!text.trim()) throw new Error('manual_vazio');
  fs.writeFileSync(MANUAL_PATH, text);
  return { size: text.length, updated_at: Date.now() };
}

function readManual() {
  try {
    const stat = fs.statSync(MANUAL_PATH);
    const text = fs.readFileSync(MANUAL_PATH, 'utf8');
    return { text, size: text.length, updated_at: stat.mtimeMs };
  } catch {
    return { text: '', size: 0, updated_at: null };
  }
}

// Rate limit multi-janela (impulse-help é barato: ~35k tokens, limites generosos).
const limiter = require('./qa-rate-limit').createLimiter({
  name:        'impulse-help',
  perMin:      parseInt(process.env.IMPULSE_LIMIT_MIN  || '15',  10),
  perHour:     parseInt(process.env.IMPULSE_LIMIT_HOUR || '60',  10),
  perDay:      parseInt(process.env.IMPULSE_LIMIT_DAY  || '200', 10),
  globalDaily: parseInt(process.env.IMPULSE_LIMIT_GLOBAL_DAILY || '2000', 10),
});

// ── Cache de respostas ───────────────────────────────────────────────────────
let cache = { version: 1, entries: {} };
try {
  cache = JSON.parse(fs.readFileSync(CACHE_PATH, 'utf8'));
  if (!cache.entries) cache = { version: 1, entries: {} };
} catch { /* arquivo não existe ainda */ }

function saveCache() {
  try { fs.writeFileSync(CACHE_PATH, JSON.stringify(cache, null, 2)); }
  catch (e) { console.error('[impulse-help] falha salvando cache:', e.message); }
}

function normalizeQuestion(q) {
  return String(q)
    .toLowerCase()
    .normalize('NFD').replace(/[̀-ͯ]/g, '')  // remove acentos
    .replace(/[.?!;:,]+$/g, '')
    .replace(/\s+/g, ' ')
    .trim();
}

// ── Streaming NDJSON pro cliente ─────────────────────────────────────────────
function sendEvent(res, type, extra = {}) {
  res.write(JSON.stringify({ type, ...extra }) + '\n');
}

function buildPrompt(manual, question, history = [], imagePath = null) {
  const imageBlock = imagePath
    ? `\n=== IMAGEM ANEXADA PELO USUÁRIO ===\nO usuário anexou a imagem em: ${imagePath}\nAnalise a imagem — provavelmente é screenshot de uma tela do carro ou do celular durante a instalação. Descreve o que você viu (que tela é, quais botões, quais mensagens) antes de responder.\n=== FIM DA IMAGEM ===\n`
    : '';

  const historyBlock = history.length
    ? `\n=== HISTÓRICO DA CONVERSA ATÉ AGORA ===\n` +
      history.map((t, i) =>
        `[Turno ${i + 1}]\nUsuário: ${t.question}\nAssistente: ${t.answer}\n`
      ).join('\n') +
      `=== FIM DO HISTÓRICO ===\n\n` +
      `A pergunta abaixo é uma CONTINUAÇÃO da conversa. Se ela usar pronomes ou referências ("e se...", "então...") assume que se refere ao que foi discutido.\n`
    : '';

  return `Você é o assistente de instalação do app HAVAL IMPULSE.

Regras:
- Responda SOMENTE com base no manual abaixo. Se a informação não estiver lá, diga "não encontrei isso no manual" e sugira em qual seção provavelmente está.
- Português do Brasil, direto, tom prestativo. Sem enrolação.
- Se a pergunta pedir passos, use lista numerada.
- Se o usuário estiver descrevendo um erro, comece diagnosticando (o que provavelmente causou) e só depois o passo pra resolver.
- Nunca invente comandos, versões, URLs ou nomes de arquivo. Se não estiver no manual, diz que não sabe.
- Se a pessoa perguntar sobre o "instalador automático" e ele estiver descrito no manual como opcional/instável, oriente pra rota manual.

=== MANUAL (fonte da verdade) ===
${manual}
=== FIM DO MANUAL ===
${historyBlock}${imageBlock}
Pergunta atual do usuário:
${question}`;
}

function streamClaude(res, manual, question, history = [], imagePath = null, timeoutMs = 120_000) {
  return new Promise((resolve) => {
    const startedAt = Date.now();
    let fullAnswer = '', firstChunkAt = 0, timedOut = false, stderrBuf = '', stdoutBuf = '';

    const child = spawn(CLAUDE_BIN, [
      '-p',
      '--model', CLAUDE_MODEL,
      '--effort', CLAUDE_EFFORT,
      '--output-format', 'stream-json',
      '--include-partial-messages',
      '--verbose',
    ]);
    const to = setTimeout(() => { timedOut = true; try { child.kill('SIGKILL'); } catch {} }, timeoutMs);

    function handleLine(line) {
      if (!line.trim()) return;
      let ev;
      try { ev = JSON.parse(line); } catch { return; }
      if (ev.type === 'stream_event' && ev.event?.type === 'content_block_delta') {
        const delta = ev.event.delta;
        if (delta?.type === 'text_delta' && typeof delta.text === 'string') {
          if (!firstChunkAt) firstChunkAt = Date.now();
          fullAnswer += delta.text;
          sendEvent(res, 'chunk', { text: delta.text });
        }
      } else if (ev.type === 'result' && ev.is_error) {
        sendEvent(res, 'error', { message: ev.result || 'claude_error' });
      }
    }

    child.stdout.on('data', d => {
      stdoutBuf += d.toString();
      const lines = stdoutBuf.split('\n');
      stdoutBuf = lines.pop();
      for (const line of lines) handleLine(line);
    });
    child.stderr.on('data', d => { stderrBuf += d.toString(); });

    child.on('error', e => {
      clearTimeout(to);
      sendEvent(res, 'error', { message: e.message });
      resolve({ ok: false });
    });
    child.on('close', code => {
      clearTimeout(to);
      if (stdoutBuf.trim()) handleLine(stdoutBuf);
      const elapsed = Date.now() - startedAt;
      if (timedOut) {
        sendEvent(res, 'error', { message: 'claude_timeout' });
        return resolve({ ok: false });
      }
      if (code !== 0 || !fullAnswer.trim()) {
        sendEvent(res, 'error', { message: `claude_exit_${code}: ${(stderrBuf || '').slice(0, 200)}` });
        return resolve({ ok: false });
      }
      sendEvent(res, 'done', { elapsed_ms: elapsed, ttfb_ms: firstChunkAt ? firstChunkAt - startedAt : null });
      resolve({ ok: true, answer: fullAnswer.trim(), elapsed_ms: elapsed });
    });

    res.on('close', () => {
      if (child.exitCode == null) { try { child.kill('SIGKILL'); } catch {} }
    });

    child.stdin.end(buildPrompt(manual, question, history, imagePath));
  });
}

function install(app, opts = {}) {
  const requireAuth = opts.requireAuth || ((_r, _s, next) => next());

  // Público — status/estado geral pra UI acender indicadores.
  app.get('/api/impulse-help/status', (_req, res) => {
    const m   = readManual();
    const tok = loadToken();
    res.json({
      oauth_enabled:      enabled,
      connected:          !!tok?.refresh_token,
      manual_size:        m.size,
      manual_updated_at:  m.updated_at,
      manual_preview:     m.text.slice(0, 400),
      doc_id:             DOC_ID,
      redirect_uri:       REDIRECT_URI,
      cache_entries:      Object.keys(cache.entries).length,
      rate_limit:         limiter.stats(),
    });
  });

  // Auth-gated — inicia OAuth. Retorna JSON com URL de consent (admin abre em nova aba).
  app.get('/api/impulse-help/oauth/start', requireAuth, (_req, res) => {
    if (!enabled) return res.status(503).json({
      error: 'oauth_disabled',
      hint:  'defina GOOGLE_OAUTH_CLIENT_ID e GOOGLE_OAUTH_CLIENT_SECRET no .env',
    });
    const state = require('crypto').randomBytes(16).toString('hex');
    oauthStates.set(state, Date.now() + 5 * 60_000);
    const url = makeOAuth().generateAuthUrl({
      access_type:     'offline',
      prompt:          'consent',   // força refresh_token mesmo em segundo consent
      scope:           ['https://www.googleapis.com/auth/drive.readonly'],
      include_granted_scopes: true,
      state,
    });
    res.json({ url });
  });

  // Público — callback do Google. Segurança via state param.
  app.get('/api/impulse-help/oauth/callback', async (req, res) => {
    const { code, state, error } = req.query || {};
    const done = (html) => res.set('Content-Type', 'text/html; charset=utf-8').send(
      `<!doctype html><meta charset=utf-8><title>Impulse Help — OAuth</title>` +
      `<body style="font-family:system-ui,-apple-system,sans-serif;padding:2rem;max-width:640px;margin:auto;line-height:1.5">${html}` +
      `<p style="margin-top:2rem"><a href="/impulse-help-admin.html">← voltar pro admin</a></p></body>`);

    if (error) return done(`<h2>Google devolveu erro</h2><pre>${String(error)}</pre>`);
    if (!code || !state) return done('<h2>Faltando code/state</h2>');
    const exp = oauthStates.get(String(state));
    if (!exp || exp < Date.now()) return done('<h2>State inválido/expirado</h2><p>Tenta conectar de novo.</p>');
    oauthStates.delete(String(state));

    try {
      const { tokens } = await makeOAuth().getToken(String(code));
      if (!tokens.refresh_token) {
        return done(
          `<h2>Google não devolveu refresh_token</h2>` +
          `<p>Provavelmente porque essa conta já autorizou o app antes.` +
          ` Vai em <a href="https://myaccount.google.com/permissions" target="_blank">myaccount.google.com/permissions</a>,` +
          ` remove o acesso do app, e conecta de novo.</p>`);
      }
      saveToken({ refresh_token: tokens.refresh_token, saved_at: Date.now() });
      let dl = '';
      try {
        const r = await fetchManualFromDrive();
        dl = `<p>Manual baixado: <b>${r.size} bytes</b>.</p>`;
      } catch (e) {
        dl = `<p style="color:#b00">Conectou, mas falhou baixar: ${String(e.message).replace(/</g, '&lt;')}</p>`;
      }
      done(`<h2>✔ Conectado ao Google Drive</h2>${dl}`);
    } catch (e) {
      done(`<h2>Falha trocando code por token</h2><pre>${String(e.message).replace(/</g, '&lt;')}</pre>`);
    }
  });

  // Auth-gated — força refetch do manual via Drive OAuth.
  app.post('/api/impulse-help/refresh', requireAuth, async (_req, res) => {
    try {
      const r = await fetchManualFromDrive();
      res.json({ ok: true, ...r });
    } catch (e) {
      res.status(500).json({ error: e.message });
    }
  });

  // Auth-gated — grava manual direto (fallback quando Drive API bloqueia export
  // por restrição de workspace). Body: { text }.
  app.post('/api/impulse-help/manual', requireAuth, (req, res) => {
    const text = String(req.body?.text || '').trim();
    if (!text)                return res.status(400).json({ error: 'empty_text' });
    if (text.length > 500_000) return res.status(400).json({ error: 'text_too_large', max: 500_000 });
    try {
      fs.writeFileSync(MANUAL_PATH, text);
      res.json({ ok: true, size: text.length, updated_at: Date.now() });
    } catch (e) {
      res.status(500).json({ error: e.message });
    }
  });

  // Público — Q&A streaming (NDJSON). Rate-limited. Suporta history (multi-turn),
  // force (bypass cache) e imagem opcional via multipart.
  app.post('/api/impulse-help/ask', upload.single('image'), async (req, res) => {
    const cleanupImage = () => {
      if (req.file?.path) { try { fs.unlinkSync(req.file.path); } catch {} }
    };
    const ip = req.ip || req.connection?.remoteAddress || 'unknown';
    const rl = limiter.check(ip);
    if (!rl.ok) {
      cleanupImage();
      res.set('Retry-After', String(rl.retry_after_sec));
      return res.status(429).json({ error: 'rate_limited', window: rl.window, retry_after_sec: rl.retry_after_sec, hint: rl.msg });
    }
    const q = String(req.body?.question || '').trim();
    if (!q)               { cleanupImage(); return res.status(400).json({ error: 'empty_question' }); }
    if (q.length > 1500)  { cleanupImage(); return res.status(400).json({ error: 'question_too_long', max: 1500 }); }
    const m = readManual();
    if (!m.text) { cleanupImage(); return res.status(503).json({ error: 'manual_not_loaded', hint: 'admin ainda não conectou/importou o manual' }); }

    // Histórico (chega como JSON string em multipart, ou array em JSON).
    let historyIn = req.body?.history;
    if (typeof historyIn === 'string') { try { historyIn = JSON.parse(historyIn); } catch { historyIn = []; } }
    if (!Array.isArray(historyIn)) historyIn = [];
    const history = historyIn
      .filter(t => t && typeof t.question === 'string' && typeof t.answer === 'string')
      .slice(-6)
      .map(t => ({ question: t.question.slice(0, 1500), answer: t.answer.slice(0, 5000) }));

    const imagePath = req.file?.path || null;
    const hasImage  = !!imagePath;

    const key      = normalizeQuestion(q);
    const forceRaw = req.body?.force;
    const force    = forceRaw === true || forceRaw === 'true' || forceRaw === '1';
    const hasHist  = history.length > 0;
    const cached   = (force || hasHist || hasImage) ? null : cache.entries[key];

    res.set({
      'Content-Type': 'application/x-ndjson; charset=utf-8',
      'Cache-Control': 'no-store',
      'X-Accel-Buffering': 'no',
    });
    res.flushHeaders?.();

    if (cached) {
      sendEvent(res, 'meta', { cached: true, cached_at: cached.cached_at });
      sendEvent(res, 'chunk', { text: cached.answer });
      sendEvent(res, 'done', { elapsed_ms: 0, from_cache: true });
      return res.end();
    }

    sendEvent(res, 'meta', { cached: false, turn: history.length + 1, has_image: hasImage });
    const r = await streamClaude(res, m.text, q, history, imagePath);
    res.end();

    if (r.ok && !hasHist && !hasImage) {
      cache.entries[key] = { question: q, answer: r.answer, cached_at: Date.now() };
      saveCache();
    }
    cleanupImage();
  });

  // Auth — limpar cache (todo ou pergunta específica).
  app.post('/api/impulse-help/cache/clear', requireAuth, (req, res) => {
    const q = String(req.body?.question || '').trim();
    if (q) {
      const key = normalizeQuestion(q);
      const had = key in cache.entries;
      delete cache.entries[key];
      if (had) saveCache();
      return res.json({ ok: true, cleared: had ? 1 : 0 });
    }
    const n = Object.keys(cache.entries).length;
    cache = { version: 1, entries: {} };
    saveCache();
    res.json({ ok: true, cleared: n });
  });

  console.log(`[impulse-help] oauth_enabled=${enabled}  redirect=${REDIRECT_URI}  doc=${DOC_ID}`);
}

module.exports = { install };
