// car-help.js — Q&A público sobre o manual do proprietário do HAVAL H6 GT PHEV.
//
// Manual: PDF de 330 páginas extraído pra texto (car_manual.md, ~780KB).
// Fluxo: /api/car-help/ask retorna NDJSON streaming (um JSON por linha):
//   {"type":"meta","cached":bool,"cached_at":ms}
//   {"type":"chunk","text":"..."}         (repete N vezes)
//   {"type":"done","elapsed_ms":N}
//   {"type":"error","message":"..."}      (em caso de falha)
//
// Cache: persistido em car_qa_cache.json. Key = pergunta normalizada
// (lowercase + trim + espaços colapsados + pontuação final removida).
//
// Pra atualizar o manual:
//   pdftotext -layout "Manual GT PHEV.pdf" bridge/car_manual.md
//   (sem restart necessário)

const fs   = require('fs');
const path = require('path');
const { spawn } = require('child_process');
const multer = require('multer');

const DATA_DIR    = process.env.DATA_DIR || __dirname;
const MANUAL_PATH = path.join(DATA_DIR, 'car_manual.md');
const CACHE_PATH  = path.join(DATA_DIR, 'car_qa_cache.json');
const UPLOADS_DIR = path.join(DATA_DIR, 'uploads');
try { fs.mkdirSync(UPLOADS_DIR, { recursive: true }); } catch {}

// Upload de imagem opcional (máx 8MB). Salva com extensão correta pro claude
// abrir direto — sem extensão ele perde tempo re-detectando.
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

const CLAUDE_BIN    = process.env.CLAUDE_BIN || 'claude';
const CLAUDE_MODEL  = process.env.CAR_HELP_MODEL || 'claude-opus-4-8';
const CLAUDE_EFFORT = process.env.CAR_HELP_EFFORT || 'medium';

function readManual() {
  try {
    const stat = fs.statSync(MANUAL_PATH);
    const text = fs.readFileSync(MANUAL_PATH, 'utf8');
    return { text, size: text.length, updated_at: stat.mtimeMs };
  } catch {
    return { text: '', size: 0, updated_at: null };
  }
}

// ── Cache ────────────────────────────────────────────────────────────────────
let cache = { version: 1, entries: {} };
try {
  cache = JSON.parse(fs.readFileSync(CACHE_PATH, 'utf8'));
  if (!cache.entries) cache = { version: 1, entries: {} };
} catch { /* arquivo não existe ainda */ }

function saveCache() {
  try { fs.writeFileSync(CACHE_PATH, JSON.stringify(cache, null, 2)); }
  catch (e) { console.error('[car-help] falha salvando cache:', e.message); }
}

function normalizeQuestion(q) {
  return String(q)
    .toLowerCase()
    .normalize('NFD').replace(/[̀-ͯ]/g, '')  // remove acentos (com/sem = mesma key)
    .replace(/[.?!;:,]+$/g, '')                       // pontuação final
    .replace(/\s+/g, ' ')
    .trim();
}

// ── Rate limit (car-help é caro: ~200k tokens de input por query) ────────────
const limiter = require('./qa-rate-limit').createLimiter({
  name:        'car-help',
  perMin:      parseInt(process.env.CAR_HELP_LIMIT_MIN  || '5',   10),
  perHour:     parseInt(process.env.CAR_HELP_LIMIT_HOUR || '20',  10),
  perDay:      parseInt(process.env.CAR_HELP_LIMIT_DAY  || '50',  10),
  globalDaily: parseInt(process.env.CAR_HELP_LIMIT_GLOBAL_DAILY || '500', 10),
});

// ── Streaming claude ─────────────────────────────────────────────────────────
function buildPrompt(manual, question, history = [], imagePath = null) {
  const imageBlock = imagePath
    ? `\n=== IMAGEM ANEXADA PELO USUÁRIO ===\nO usuário anexou a imagem em: ${imagePath}\nAnalise a imagem e use ela como contexto principal pra responder. Se a imagem mostrar um sintoma no carro (luz no painel, ícone, mensagem, componente), identifica primeiro o que é vendo na imagem, depois busca no manual o significado/procedimento. Descreve o que você viu antes de responder.\n=== FIM DA IMAGEM ===\n`
    : '';

  const historyBlock = history.length
    ? `\n=== HISTÓRICO DA CONVERSA ATÉ AGORA ===\n` +
      history.map((t, i) =>
        `[Turno ${i + 1}]\nUsuário: ${t.question}\nAssistente: ${t.answer}\n`
      ).join('\n') +
      `=== FIM DO HISTÓRICO ===\n\n` +
      `A pergunta abaixo é uma CONTINUAÇÃO da conversa. Se ela usar pronomes ou referências ("e se...", "então...", "e nesse caso...") assume que se refere ao que foi discutido. Se contradizer algo que você disse antes, admite a atualização.\n`
    : '';

  return `Você é o assistente do manual do proprietário do HAVAL H6 GT PHEV.

Prioridade das fontes (nessa ordem):
1. Manual do proprietário (fonte primária, abaixo).
2. Cálculo com base em dados do manual (ex: capacidade da bateria × potência do carregador → tempo de recarga).
3. Conhecimento geral sobre PHEVs / carros / manutenção — quando o manual não tem, mas é uma resposta razoável e útil.

Como responder:
- Português do Brasil, direto e prático. Sem enrolação.
- Se a pergunta pedir um procedimento (ex: "como troco X"), use passos numerados.
- Se o usuário descrever um sintoma (luz acesa, ruído, mensagem no painel), começa dizendo o que provavelmente significa segundo o manual e depois o que fazer.
- Quando a informação está direto no manual, responde firme.
- Quando você **calculou** algo a partir de dados do manual, mostra o cálculo curtinho (ex: "34 kWh de bateria ÷ 2,2 kW do cabo Level 1 ≈ 15h") e marca como **"estimativa"**.
- Quando usar conhecimento geral (fora do manual), começa a resposta com **"⚠️ Não achei no manual, mas em geral:"** e é conservador. Sempre sugere confirmar em rede autorizada.
- **PROIBIDO inventar** números específicos que exigem precisão: torques de parafuso, códigos de erro, viscosidade exata de óleo, pressão exata de pneu. Se o manual não traz, diz que precisa consultar concessionária. Faixas gerais ("geralmente 32-36 PSI pra pneu 235/55 R19") são OK se marcadas como estimativa.
- Para tabelas do manual (specs, capacidades), preserve os números exatos.

=== MANUAL DO PROPRIETÁRIO — HAVAL H6 GT PHEV ===
${manual}
=== FIM DO MANUAL ===
${historyBlock}${imageBlock}
Pergunta atual do usuário:
${question}`;
}

function sendEvent(res, type, extra = {}) {
  res.write(JSON.stringify({ type, ...extra }) + '\n');
}

function streamClaude(res, manual, question, history = [], imagePath = null, timeoutMs = 180_000) {
  return new Promise((resolve) => {
    const startedAt = Date.now();
    let fullAnswer = '', firstChunkAt = 0, timedOut = false, stderrBuf = '', stdoutBuf = '';

    // --output-format stream-json emite JSONL com eventos da API Anthropic:
    // { type: "stream_event", event: { type: "content_block_delta", delta: { text } } }
    // etc. A gente filtra e envia só os deltas de texto pro cliente.
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
      if (stdoutBuf.trim()) handleLine(stdoutBuf);   // flush última linha
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

    // Cliente desconectou → mata claude pra não gastar tokens à toa.
    res.on('close', () => {
      if (child.exitCode == null) { try { child.kill('SIGKILL'); } catch {} }
    });

    child.stdin.end(buildPrompt(manual, question, history, imagePath));
  });
}

// ── Rotas ────────────────────────────────────────────────────────────────────
function install(app, opts = {}) {
  const requireAuth = opts.requireAuth || ((_r, _s, next) => next());

  app.get('/api/car-help/status', (_req, res) => {
    const m = readManual();
    res.json({
      manual_size:        m.size,
      manual_updated_at:  m.updated_at,
      manual_preview:     m.text.slice(0, 400),
      title:              'Manual GT PHEV',
      cache_entries:      Object.keys(cache.entries).length,
      rate_limit:         limiter.stats(),
    });
  });

  // Streaming NDJSON. Aceita multipart/form-data com campo 'image' opcional
  // OU application/json (sem imagem). Se cache hit, devolve em 1 chunk.
  app.post('/api/car-help/ask', upload.single('image'), async (req, res) => {
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
    if (!m.text) { cleanupImage(); return res.status(503).json({ error: 'manual_not_loaded' }); }

    // Histórico: quando vem via multipart, chega como string JSON.
    let historyIn = req.body?.history;
    if (typeof historyIn === 'string') { try { historyIn = JSON.parse(historyIn); } catch { historyIn = []; } }
    if (!Array.isArray(historyIn)) historyIn = [];
    const history = historyIn
      .filter(t => t && typeof t.question === 'string' && typeof t.answer === 'string')
      .slice(-6)
      .map(t => ({ question: t.question.slice(0, 1500), answer: t.answer.slice(0, 5000) }));

    const imagePath = req.file?.path || null;
    const hasImage  = !!imagePath;

    // Cache hit → resposta instantânea. `force` bypassa. Cache só sem histórico/imagem.
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

    // Só cacheia respostas SEM histórico e SEM imagem.
    if (r.ok && !hasHist && !hasImage) {
      cache.entries[key] = { question: q, answer: r.answer, cached_at: Date.now() };
      saveCache();
    }
    cleanupImage();
  });

  // Auth: limpar cache (todo ou por pergunta).
  app.post('/api/car-help/cache/clear', requireAuth, (req, res) => {
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

  console.log(`[car-help] manual=${readManual().size} chars · cache=${Object.keys(cache.entries).length} entries`);
}

module.exports = { install };
