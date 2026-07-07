#!/usr/bin/env node
'use strict';
// Agente de TI: consome /api/health do bridge, auto-corrige sintomas conhecidos
// (cooldown + teto de 2 tentativas), escala pro ntfy quando o fix falha, e pra
// alertas NOVOS/fora do whitelist pede um diagnóstico ao claude -p que SUGERE a
// ação via ntfy mas NUNCA executa. Fail-closed.
require('dotenv').config();
const https = require('https');
const http  = require('http');
const { execFile, spawn } = require('child_process');
const { tmpdir } = require('os');

const HEALTH_URL   = process.env.IT_AGENT_HEALTH_URL || 'http://127.0.0.1:3000/api/health';
const ADMIN_TOKEN  = process.env.ADMIN_TOKEN || '';
const NTFY_URL     = process.env.NTFY_URL || 'https://ntfy.sh/tailscale-watchdog-863a94c906c1428974be4d4fa5b3e572';
const POLL_MS      = parseInt(process.env.IT_AGENT_POLL_MS || '45000', 10);
const PM2_BIN      = process.env.PM2_BIN || '/usr/local/bin/pm2';
const BREW_BIN     = process.env.BREW_BIN || '/opt/homebrew/bin/brew';
const CLAUDE_BIN   = process.env.CLAUDE_BIN || '/usr/local/bin/claude';
const CLAUDE_MODEL = process.env.IT_AGENT_MODEL || 'claude-opus-4-8';

const ATTEMPT_CAP     = 2;
const CONFIRM_TICKS   = parseInt(process.env.IT_AGENT_CONFIRM_TICKS || '3', 10); // firing sustentado por N polls antes de agir (mata blip transiente)
const POST_FIX_COOLDOWN = parseInt(process.env.IT_AGENT_POST_FIX_MS || '900000', 10); // 15min: não re-age o mesmo fix, quebra loop restart→blip→restart
const CLAUDE_COOLDOWN = 6 * 60 * 60 * 1000; // 1 sugestão por sintoma / 6h

// pm2 que o agente NÃO reinicia: o bridge se auto-cura (_selfHealPm2) e é a
// fonte do health; o próprio agente não se mata.
const PM2_SKIP = new Set(['bridge', 'it-agent']);

const log = (...a) => console.log(new Date().toISOString(), ...a);

// Title vai em header HTTP (latin1) mas ntfy interpreta como UTF-8 -> acento
// vira mojibake. Transliteramos pra ASCII puro.
const hdrSafe = s => String(s)
  .normalize('NFD').replace(/[̀-ͯ]/g, '')  // tira acentos
  .replace(/[‐-―]/g, '-')
  .replace(/[^\x20-\x7E]/g, '');                     // só ASCII imprimível
function ntfy(title, body, priority = 'default', tags = []) {
  try {
    const buf = Buffer.from(body, 'utf8');
    const headers = { Title: hdrSafe(title), Priority: priority, 'Content-Type': 'text/plain; charset=utf-8', 'Content-Length': buf.length };
    if (tags.length) headers.Tags = tags.join(',');
    const req = https.request(NTFY_URL, { method: 'POST', headers }, r => r.resume());
    req.on('error', e => log('ntfy err', e.message));
    req.write(buf); req.end();
  } catch (e) { log('ntfy throw', e.message); }
}

function getHealth() {
  return new Promise((res, rej) => {
    const u = new URL(HEALTH_URL);
    const mod = u.protocol === 'https:' ? https : http;
    const req = mod.get(u, { headers: { Authorization: 'Bearer ' + ADMIN_TOKEN }, timeout: 10000 }, r => {
      let d = ''; r.on('data', c => d += c);
      r.on('end', () => { try { res(JSON.parse(d)); } catch (e) { rej(new Error('bad json: ' + d.slice(0, 120))); } });
    });
    req.on('timeout', () => { req.destroy(new Error('timeout')); });
    req.on('error', rej);
  });
}

function sh(cmd, args, timeout = 60000) {
  return new Promise(resolve => {
    execFile(cmd, args, { timeout, maxBuffer: 1024 * 1024 }, (err, out, errout) => {
      resolve({ ok: !err, out: (out || '').trim(), err: (errout || err && err.message || '').trim() });
    });
  });
}

// ---- remediações conhecidas ----------------------------------------------
// Cada uma retorna {ok, detail}. NÃO decide se deve rodar (isso é do orquestrador).
const FIXES = {
  async ts_down() {
    // relança o app Tailscale (CLI standalone não sobe daemon sozinho)
    await sh('/usr/bin/osascript', ['-e', 'quit app "Tailscale"'], 15000);
    await new Promise(r => setTimeout(r, 2500));
    const r = await sh('/usr/bin/open', ['-a', 'Tailscale'], 15000);
    return { ok: r.ok, detail: r.ok ? 'Tailscale relançado' : ('open falhou: ' + r.err) };
  },
  async mosquitto(opts = {}) {
    // reiniciar mosquitto derruba o MQTT do carro. Se o processo está VIVO, um
    // blip de porta é transiente (o próprio restart causa um) -> NÃO reinicia.
    const alive = await sh('/usr/bin/pgrep', ['-x', 'mosquitto'], 5000);
    if (opts.requireDead && alive.ok && alive.out) {
      return { ok: true, skipped: true, detail: 'mosquitto vivo (pid ' + alive.out.split('\n')[0] + '), blip de porta ignorado' };
    }
    const r = await sh(BREW_BIN, ['services', 'restart', 'mosquitto'], 60000);
    return { ok: r.ok, detail: r.ok ? 'mosquitto reiniciado' : ('brew falhou: ' + r.err) };
  },
  async pm2Restart(name) {
    const r = await sh(PM2_BIN, ['restart', name, '--update-env'], 30000);
    return { ok: r.ok, detail: r.ok ? `pm2 restart ${name}` : (`pm2 falhou: ` + r.err) };
  },
};

// mapeia um item de trabalho -> {key, run, label}
// alertas do bridge que têm fix determinístico:
const ALERT_FIX = {
  ts_down:      { key: 'ts_down',   label: 'Tailscale fora',              run: () => FIXES.ts_down() },
  // mqtt_down = bridge realmente sem broker por 2+ ciclos -> pode reiniciar mesmo vivo.
  mqtt_down:    { key: 'mosquitto', label: 'MQTT desconectado',           run: () => FIXES.mosquitto({ requireDead: false }) },
  // broker_ports = probe de porta flakey -> só reinicia se o processo morreu.
  broker_ports: { key: 'mosquitto', label: 'Mosquitto porta inacessivel', run: () => FIXES.mosquitto({ requireDead: true }) },
};

// alertas que o agente NÃO trata (outro dono / transiente / não-acionável) —
// não vira sugestão claude tampouco, pra não duplicar o ntfy do próprio bridge.
const IGNORE_ALERTS = new Set([
  'local_blind',      // _selfHealPm2 no bridge
  'restarts',         // só alerta
  'mqtt_slow',        // transiente
  'dns_mismatch',     // DuckDNS auto-atualiza
  'ext_monitor_down', // outage do HA da EMPRESA (máquina remota) — não-acionável daqui,
                      // e o bridge já manda "Monitor externo parado". Claude não ajuda.
]);

// alertas cujo disparo pode ser blip transiente: só vira sugestão claude se o
// check AO VIVO no /api/health ainda confirmar o problema. Evita mandar o dono
// caçar caixa que já voltou. fn(h) => true quando o problema está REALMENTE ativo.
const LIVE_CONFIRM = {
  ha_down: h => h && h.ha && h.ha.up === false,   // HA do CARRO (HAOS VM) de fato fora
};

// nomes legíveis pros alertas (título das notificações)
const ALERT_LABELS = {
  ha_down: 'Home Assistant sem resposta', ts_down: 'Tailscale fora',
  mqtt_down: 'MQTT desconectado', broker_ports: 'Porta do Mosquitto inacessivel',
  gw_down: 'Gateway LAN offline', funnel_down: 'Tailscale Funnel fora',
  cert_expiry: 'Certificado TLS expirando', cert_broker_expiry: 'Cert do broker expirando',
  mem_high: 'Memoria alta no bridge', rss_leak: 'Possivel memory leak no bridge',
  disk_full: 'Disco interno quase cheio', ssd_unmounted: 'SSD externo desmontado',
  ssd_full: 'SSD externo quase cheio', disk_int_eta: 'Disco interno vai encher',
  disk_ext_eta: 'SSD externo vai encher', icloud_pending: 'Backup iCloud parado',
  apns_attrition: 'Tokens APNs morrendo', apk_executor_dead: 'APK/Shizuku sem executar',
  ext_monitor_down: 'Monitor externo mudo', car_apk_stall: 'APK do carro travado',
  car_gwm_stall: 'GWM do carro travado', car_total_silence: 'Carro em silencio total',
};
const alertLabel = id => ALERT_LABELS[id] || id;

// topologia REAL — o claude usa isso pra não inventar comando que não existe aqui.
const INFRA_CONTEXT = `Infra (Mac Mini Apple Silicon, macOS):
- Processos Node sob pm2: bridge (server.js), gwm-bridge (GWM->MQTT), ecotrip-gateway, ellevar-clockin, it-agent. Reinício: pm2 restart <nome>.
- Broker MQTT = Mosquitto NATIVO via Homebrew (brew services restart mosquitto). NAO é pm2/docker. Listeners 1883/1884/8883.
- EXISTEM DOIS Home Assistant DISTINTOS, não confunda:
  (1) HA do CARRO = HAOS numa VM UTM neste Mac (bundle no SSD externo /Volumes/SSD1TB), UI em 192.168.1.30:8123. É o que o alerta 'ha_down' checa. NAO é pm2/systemctl/serviço macOS — reinicia na VM UTM ou na UI do HA. NUNCA sugira 'pm2 home-assistant' nem 'systemctl'.
  (2) HA da EMPRESA = máquina REMOTA (fora deste Mac) que vigia o Mac de fora via heartbeat POST. É o que o alerta 'ext_monitor_down' representa. NÃO é acionável a partir deste Mac — se ele emudeceu, o problema é na rede/energia do lado da empresa. NÃO sugira mexer na VM UTM nem no SSD por causa de ext_monitor_down.
- Tailscale = app GUI do macOS (Tailscale.app), não daemon CLI. Restart = relançar o app.
- Backups/SSD externo montado em /Volumes/SSD1TB. iCloud sync via launchd.
O agente JÁ auto-corrige: mosquitto (se processo morto), Tailscale (relança app), pm2 <proc> caído. Então NÃO sugira essas — só o que sobra.`;

// ---- estado ----------------------------------------------------------------
// key -> { confirms, attempts, lastAttemptAt, escalated, episodeNotified }
const fixState = new Map();
// id -> lastClaudeAt
const claudeState = new Map();
// id -> consecutive firing ticks (gate de confirmação pro caminho claude)
const claudeConfirms = new Map();

function fs_(key) {
  let s = fixState.get(key);
  if (!s) { s = { confirms: 0, attempts: 0, lastAttemptAt: 0, escalated: false, episodeNotified: false }; fixState.set(key, s); }
  return s;
}

// chamado a cada tick em que o sintoma está firing. Só age quando (a) confirmado
// por CONFIRM_TICKS polls seguidos, (b) fora do cooldown pós-fix, (c) abaixo do teto.
async function attemptFix(key, label, runFn) {
  const s = fs_(key);
  s.label = label;
  const now = Date.now();
  s.confirms++;
  if (s.confirms < CONFIRM_TICKS) { log('confirming', key, s.confirms + '/' + CONFIRM_TICKS); return; }
  if (s.attempts >= ATTEMPT_CAP) {
    if (!s.escalated) {
      s.escalated = true;
      ntfy(`Nao consegui corrigir: ${label}`, `Tentei ${ATTEMPT_CAP}x e o problema persiste. Precisa de intervencao manual.`, 'urgent', ['rotating_light', 'robot']);
      log('escalated', key);
    }
    return;
  }
  if (now - s.lastAttemptAt < POST_FIX_COOLDOWN) return; // não re-age: quebra loop restart->blip->restart
  s.attempts++; s.lastAttemptAt = now;
  log('fix attempt', key, 'try', s.attempts, '-', label);
  const r = await runFn();
  log('fix result', key, r.ok, r.skipped ? '(skip) ' : '', r.detail);
  if (r.skipped) { s.attempts--; return; } // não gastou tentativa nem notifica
  if (!r.ok) {
    ntfy(`Falha ao corrigir: ${label}`, `${r.detail}. Vou tentar de novo (${s.attempts}/${ATTEMPT_CAP}).`, 'high', ['warning', 'robot']);
  } else if (!s.episodeNotified) {
    s.episodeNotified = true;
    ntfy(`Corrigindo: ${label}`, `${r.detail}.`, 'default', ['robot']);
  }
}

function resetFix(key) {
  const s = fixState.get(key);
  if (s && (s.attempts || s.escalated)) {
    log('recovered', key);
    // só avisa recuperação se tinha escalado (o dono foi incomodado); resolvido no 1º fix é silencioso
    if (s.escalated) ntfy(`Resolvido: ${s.label || key}`, 'Voltou ao normal.', 'default', ['white_check_mark', 'robot']);
  }
  fixState.delete(key);
}

// claude -p: SUGERE, não executa. Fail-OPEN: se o agente não der diagnóstico
// (timeout/erro/vazio), manda um aviso simples mesmo assim — o bridge silencia
// os alertas AGENT_OWNED contando com este caminho, então ficar mudo aqui te
// deixaria cego. Melhor um ping cru sem sugestão do que nenhum.
function claudeSuggest(id, ctx) {
  const s = claudeState.get(id) || 0;
  if (Date.now() - s < CLAUDE_COOLDOWN) return;
  claudeState.set(id, Date.now());
  const label = alertLabel(id);
  const prompt = `Você é o SRE de plantão de uma infra caseira. Um monitor disparou um alerta SEM correção automática mapeada. Dê UMA recomendação curta e ACIONÁVEL (máx 2 frases, PT-BR técnico) com o(s) comando(s) exato(s) a rodar NESTA infra. Não invente comandos que não se aplicam. Nada destrutivo.

${INFRA_CONTEXT}

Alerta: ${id} (${label})
Detalhe: ${JSON.stringify(ctx)}`;
  const child = execFile(CLAUDE_BIN, ['-p', '--model', CLAUDE_MODEL, '--effort', 'medium'],
    { timeout: 90000, maxBuffer: 1024 * 1024, cwd: tmpdir(), env: { ...process.env, USER: process.env.USER || 'node', LOGNAME: process.env.LOGNAME || 'node' } },
    (err, out) => {
      const txt = (out || '').trim();
      if (err) log('claude err', id, err.message);
      if (!err && txt) {
        ntfy(`Diagnostico: ${label}`, `${txt.slice(0, 480)}\n\n(sugestao do agente, nao executada)`, 'high', ['mag', 'robot']);
      } else {
        // fail-open: agente não respondeu — avisa cru pra você não ficar cego.
        ntfy(`Alerta: ${label}`, `Persistiu por ${CONFIRM_TICKS} ciclos e o agente não conseguiu diagnosticar. Detalhe: ${JSON.stringify(ctx).slice(0, 300)}`, 'high', ['warning']);
      }
    });
  child.stdin.on('error', () => {});
  child.stdin.write(prompt); child.stdin.end();
}

// ---- loop ------------------------------------------------------------------
async function tick() {
  let h;
  try { h = await getHealth(); }
  catch (e) { log('health fetch falhou', e.message); return; }

  const alerts = h.alerts || {};
  const procs  = h.processes || [];

  // dedupe por key: mqtt_down e broker_ports compartilham 'mosquitto'. mqtt_down
  // (sinal mais forte, requireDead:false) vence a colisão.
  const active = new Map(); // key -> { label, run }
  for (const [id, st] of Object.entries(alerts)) {
    if (!st || !st.firing) continue;
    const map = ALERT_FIX[id];
    if (!map) continue;
    if (!active.has(map.key) || id === 'mqtt_down') active.set(map.key, { label: map.label, run: map.run });
  }
  for (const p of procs) {
    if (PM2_SKIP.has(p.name)) continue;
    if (p.status && p.status !== 'online') {
      active.set('pm2:' + p.name, { label: `pm2 ${p.name} (${p.status})`, run: () => FIXES.pm2Restart(p.name) });
    }
  }

  // 1) age em cada key ativa (uma vez por tick), 2) reseta as que não estão mais ativas
  for (const [key, w] of active) await attemptFix(key, w.label, w.run);
  for (const key of [...fixState.keys()]) if (!active.has(key)) resetFix(key);

  // 3) alertas firing sem fix conhecido e fora do ignore -> sugestão claude.
  //    Mesmo gate de confirmação: blip transiente não gera diagnóstico.
  const novelFiring = new Set();
  for (const [id, st] of Object.entries(alerts)) {
    if (!st || !st.firing || ALERT_FIX[id] || IGNORE_ALERTS.has(id)) continue;
    // blip transiente: alerta marcado firing mas o check ao vivo já não confirma
    // → não gera diagnóstico (ex.: ha_down com health.ha.up === true).
    const confirm = LIVE_CONFIRM[id];
    if (confirm && !confirm(h)) { claudeConfirms.delete(id); continue; }
    novelFiring.add(id);
    const c = (claudeConfirms.get(id) || 0) + 1;
    claudeConfirms.set(id, c);
    if (c >= CONFIRM_TICKS) claudeSuggest(id, { id, ...st });
  }
  for (const id of [...claudeConfirms.keys()]) if (!novelFiring.has(id)) claudeConfirms.delete(id);
}

log('it-agent iniciado. poll', POLL_MS + 'ms', 'health', HEALTH_URL);
if (!ADMIN_TOKEN) { log('AVISO: ADMIN_TOKEN vazio — /api/health vai dar 401'); }
tick();
setInterval(() => { tick().catch(e => log('tick err', e.message)); }, POLL_MS);
