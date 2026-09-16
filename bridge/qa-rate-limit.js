// qa-rate-limit.js — Rate limit multi-janela pra endpoints Q&A que gastam tokens.
//
// Cada limiter tem 3 janelas por IP: minuto / hora / dia. Além disso, um cap
// global diário (kill-switch — se for atingido, ninguém consegue mais até a
// virada do dia). Tudo configurável via env vars ou options.
//
// Log NDJSON de bloqueios em bridge/qa_rate_log.ndjson pra auditoria.

const fs   = require('fs');
const path = require('path');

const LOG_PATH = path.join(process.env.DATA_DIR || __dirname, 'qa_rate_log.ndjson');

function logBlock(entry) {
  try {
    fs.appendFileSync(LOG_PATH, JSON.stringify({ ts: Date.now(), ...entry }) + '\n');
  } catch {}
}

/**
 * @param {object} cfg
 * @param {string} cfg.name         — identificador do limiter (ex: 'car-help')
 * @param {number} cfg.perMin       — máx requests por IP nos últimos 60s
 * @param {number} cfg.perHour      — máx requests por IP nos últimos 3600s
 * @param {number} cfg.perDay       — máx requests por IP nos últimos 86400s
 * @param {number} cfg.globalDaily  — cap global diário (todos os IPs somados)
 */
function createLimiter(cfg) {
  const {
    name = 'unnamed',
    perMin, perHour, perDay,
    globalDaily,
  } = cfg;

  // Timestamps por IP. Manter compacto: rejeita se lista já tem >perDay itens (soft limit).
  const hits = new Map();  // ip → [ts1, ts2, ...]
  let globalToday = { day: currentDay(), count: 0 };

  function currentDay() {
    // Reset em UTC-3 (BRT). Simplificado: fatia por dia local.
    const d = new Date();
    return `${d.getFullYear()}-${d.getMonth()+1}-${d.getDate()}`;
  }

  // GC: remove IPs sem atividade nas últimas 24h.
  setInterval(() => {
    const cut = Date.now() - 86_400_000;
    for (const [ip, arr] of hits) {
      const trimmed = arr.filter(t => t > cut);
      if (!trimmed.length) hits.delete(ip);
      else if (trimmed.length !== arr.length) hits.set(ip, trimmed);
    }
    // Reset diário global.
    const today = currentDay();
    if (globalToday.day !== today) globalToday = { day: today, count: 0 };
  }, 5 * 60_000).unref();

  /**
   * @param {string} ip
   * @returns {{ok:true} | {ok:false, window:string, retry_after_sec:number, msg:string}}
   */
  function check(ip) {
    const now = Date.now();
    const today = currentDay();
    if (globalToday.day !== today) globalToday = { day: today, count: 0 };

    // Kill switch global.
    if (globalDaily && globalToday.count >= globalDaily) {
      logBlock({ limiter: name, ip, reason: 'global_daily', global_count: globalToday.count, cap: globalDaily });
      return { ok: false, window: 'global_daily', retry_after_sec: secsTilMidnight(),
        msg: `Limite diário global atingido (${globalDaily}). Espera até amanhã.` };
    }

    const arr = (hits.get(ip) || []).filter(t => t > now - 86_400_000);
    const inLastMin  = arr.filter(t => t > now - 60_000).length;
    const inLastHour = arr.filter(t => t > now - 3_600_000).length;
    const inLastDay  = arr.length;

    if (perMin && inLastMin >= perMin) {
      logBlock({ limiter: name, ip, reason: 'per_min', count: inLastMin, cap: perMin });
      return { ok: false, window: 'minuto', retry_after_sec: 60,
        msg: `Máximo ${perMin} perguntas por minuto. Espera 1min.` };
    }
    if (perHour && inLastHour >= perHour) {
      logBlock({ limiter: name, ip, reason: 'per_hour', count: inLastHour, cap: perHour });
      return { ok: false, window: 'hora', retry_after_sec: 3600,
        msg: `Máximo ${perHour} perguntas por hora. Espera 1h.` };
    }
    if (perDay && inLastDay >= perDay) {
      logBlock({ limiter: name, ip, reason: 'per_day', count: inLastDay, cap: perDay });
      return { ok: false, window: 'dia', retry_after_sec: secsTilMidnight(),
        msg: `Máximo ${perDay} perguntas por dia. Espera até amanhã.` };
    }

    arr.push(now);
    hits.set(ip, arr);
    globalToday.count++;
    return { ok: true };
  }

  function stats() {
    return {
      name,
      ips_tracked: hits.size,
      global_today: globalToday,
      limits: { perMin, perHour, perDay, globalDaily },
    };
  }

  return { check, stats };
}

function secsTilMidnight() {
  const now = new Date();
  const next = new Date(now); next.setHours(24, 0, 0, 0);
  return Math.floor((next - now) / 1000);
}

module.exports = { createLimiter };
