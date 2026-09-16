'use strict';
/**
 * Cliente direto da nuvem SAJ (eSolar / Elekeeper) — sem passar pelo Home Assistant.
 *
 * Existe porque em 15/09/2026 o Catalão ficou ~3h fora do monitoramento por uma
 * falha que não era da usina nem da nuvem: a SAJ subiu uma regra de WAF que
 * devolve 403 pro User-Agent padrão do `requests`, e a integração comunitária do
 * HA (erelke/ha-esolar) parou inteira. Aqui o caminho é nosso.
 *
 * Duas lições daquele incidente estão codificadas de propósito:
 *
 *  1. USER-AGENT DE NAVEGADOR. Sem isso, TODA chamada volta 403 — login
 *     inclusive — com uma página HTML em vez de JSON.
 *  2. 401/403 INVALIDA A SESSÃO. A integração do HA só tratava sessão inválida
 *     olhando `errCode`/`errMsg` do corpo JSON; um 403 de WAF nem JSON é, então
 *     o token morto ficava em disco parecendo válido e ela retentava com ele
 *     para sempre. Aqui qualquer 401/403 descarta o token e força novo login.
 *
 * Não substitui o HA: `server.js` usa esta fonte como PRIMÁRIA e cai pro HA se
 * ela falhar. Temperatura a SAJ não expõe (campo `invTemp` vem vazio), então
 * continua vindo do HA — e vira null, nunca 0, quando nenhum dos dois tem.
 */
const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const BASE = process.env.SAJ_BASE_URL || 'https://iop.saj-electric.com/dev-api/api/v1';
// Ambas extraídas do app.js do Elekeeper (mesmas que a integração do HA usa).
const SIGN_KEY = 'ktoKRLgQPjvNyUZO8lVc9kU1Bsip6XIe';
const PWD_KEY  = 'ec1840a7c53cf0709eb784be480379b6';
const UA = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
         + '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';
const TIMEOUT_MS = +(process.env.SAJ_TIMEOUT_MS || 15000);
const TOKEN_FILE = path.join(__dirname, 'saj_token.json');

let _tok = null;            // { token, head, expiraEm }
let _ultimoErro = null;
let _ultimoOkEm = 0;
try { _tok = JSON.parse(fs.readFileSync(TOKEN_FILE, 'utf8')); } catch (_) {}

const _rnd = (n) => {
  const a = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  return Array.from({ length: n }, () => a[Math.floor(Math.random() * a.length)]).join('');
};

/** Assinatura: SHA1(MD5(params ordenados + "&key=" + chave)) em maiúsculas. */
function _assina(p) {
  const chaves = Object.keys(p);
  const ordenado = chaves.slice().sort().map((k) => `${k}=${p[k]}`).join('&');
  const md5 = crypto.createHash('md5')
    .update(Buffer.from(ordenado + '&key=' + SIGN_KEY, 'latin1')).digest('hex');
  return { ...p, signature: crypto.createHash('sha1').update(md5).digest('hex').toUpperCase(),
           signParams: chaves.join(',') };
}
const _comuns = () => ({
  appProjectName: 'elekeeper',
  clientDate: new Date().toISOString().slice(0, 10),
  lang: 'en',
  timeStamp: Date.now(),
  random: _rnd(32),
  clientId: 'esolar-monitor-admin',
});
/** Senha vai AES-128-ECB + PKCS7, em hex (o padding padrão do Node já é PKCS7). */
function _cifraSenha(senha) {
  const c = crypto.createCipheriv('aes-128-ecb', Buffer.from(PWD_KEY, 'hex'), null);
  return Buffer.concat([c.update(Buffer.from(senha, 'utf8')), c.final()]).toString('hex');
}

function _salvaToken() {
  try { fs.writeFileSync(TOKEN_FILE, JSON.stringify(_tok), { mode: 0o600 }); } catch (_) {}
}
function _descartaToken(porque) {
  _tok = null;
  try { fs.unlinkSync(TOKEN_FILE); } catch (_) {}
  _ultimoErro = porque;
}

class SessaoInvalida extends Error {}

async function _login() {
  const user = process.env.SAJ_USER, senha = process.env.SAJ_PASS;
  if (!user || !senha) throw new Error('SAJ_USER/SAJ_PASS ausentes no .env');
  const corpo = new URLSearchParams({
    ..._assina(_comuns()),
    username: user, password: _cifraSenha(senha), rememberMe: 'false', loginType: '1',
  });
  const r = await fetch(BASE + '/sys/login', {
    method: 'POST', body: corpo,
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'User-Agent': UA },
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (r.status === 401 || r.status === 403) {
    throw new Error(`login recusado pelo servidor (HTTP ${r.status}) — checar bloqueio de WAF/User-Agent`);
  }
  const j = await r.json();
  if (j.errCode !== 0 || !j.data?.token) throw new Error(`login falhou: ${j.errMsg ?? j.errCode}`);
  // `expiresIn` vem em segundos; guarda 5min de folga pra não usar no limite.
  _tok = { token: j.data.token, head: j.data.tokenHead || 'Bearer ',
           expiraEm: Date.now() + (+j.data.expiresIn || 3600) * 1000 - 300000 };
  _salvaToken();
  return _tok;
}

async function _autorizacao() {
  if (_tok && _tok.expiraEm > Date.now()) return _tok.head + _tok.token;
  const t = await _login();
  return t.head + t.token;
}

/** GET assinado. 401/403 => sessão inválida (descarta token e deixa o chamador repetir). */
async function _get(caminho, extra = {}) {
  const auth = await _autorizacao();
  const q = new URLSearchParams(_assina({ ..._comuns(), ...extra }));
  const r = await fetch(`${BASE}${caminho}?${q}`, {
    headers: { Authorization: auth, 'User-Agent': UA },
    signal: AbortSignal.timeout(TIMEOUT_MS),
  });
  if (r.status === 401 || r.status === 403) {
    _descartaToken(`HTTP ${r.status} em ${caminho}`);
    throw new SessaoInvalida(`HTTP ${r.status} em ${caminho}`);
  }
  if (!r.ok) throw new Error(`HTTP ${r.status} em ${caminho}`);
  const j = await r.json();
  // errCode 10002 = "Please login first": token recusado no corpo, mesmo com 200.
  if (j.errCode === 10002) {
    _descartaToken('errCode 10002 (please login first)');
    throw new SessaoInvalida('errCode 10002');
  }
  if (j.errCode !== 0) throw new Error(`errCode ${j.errCode}: ${j.errMsg}`);
  return j.data;
}

/** Repete uma vez após sessão inválida — a segunda tentativa já nasce com token novo. */
async function _getComRelogin(caminho, extra) {
  try { return await _get(caminho, extra); }
  catch (e) {
    if (!(e instanceof SessaoInvalida)) throw e;
    return _get(caminho, extra);
  }
}

const _num = (v) => {
  if (v == null || v === '') return null;          // vazio é AUSÊNCIA, não zero
  const n = +v;
  return Number.isFinite(n) ? n : null;
};
/** "15/09/2026 12:00:00" -> epoch ms (a SAJ manda dd/MM/yyyy). */
function _dataSaj(s) {
  const m = /^(\d{2})\/(\d{2})\/(\d{4})\s+(\d{2}):(\d{2}):(\d{2})$/.exec(String(s || ''));
  if (!m) return null;
  return new Date(+m[3], +m[2] - 1, +m[1], +m[4], +m[5], +m[6]).getTime();
}

/**
 * Lê a usina inteira. Devolve null quando não conseguiu falar com a nuvem — o
 * chamador cai pro HA. NUNCA devolve zeros de mentira.
 */
async function lePlanta(plantUid = process.env.SAJ_PLANT_UID) {
  try {
    let uid = plantUid;
    if (!uid) {
      const lista = await _getComRelogin('/monitor/plant/getEndUserPlantList', { pageNo: 1, pageSize: 100 });
      uid = (lista?.list || lista?.rows || [])[0]?.plantUid;
      if (!uid) throw new Error('nenhuma planta na conta');
    }
    const dev = await _getComRelogin('/monitor/device/getDeviceList',
      { plantUid: uid, pageSize: 100, pageNo: 1, searchOfficeIdArr: '1' });
    const lista = dev?.list || dev?.rows || [];
    if (!lista.length) throw new Error('nenhum dispositivo na planta');

    const invs = lista.map((d) => ({
      sn: d.deviceSn,
      modelo: d.deviceModel ?? null,
      power: _num(d.powerNow),
      energy_today: _num(d.todayEnergy),
      energy_month: _num(d.monthEnergy),
      energy_total: _num(d.totalEnergy),
      // runningState 1 = operando; deviceStatus traz o texto ("On-grid").
      online: d.runningState != null ? String(d.runningState) === '1' : null,
      status: d.deviceStatus ?? null,
    }));

    // Soma só o que foi lido: se NINGUÉM reportou, é null — planta sem leitura
    // não é planta em zero (mesma regra do resto do bridge).
    const soma = (k) => {
      const v = invs.map((i) => i[k]).filter((x) => x != null);
      return v.length ? +v.reduce((a, x) => a + x, 0).toFixed(2) : null;
    };
    _ultimoOkEm = Date.now();
    _ultimoErro = null;
    return {
      fonte: 'saj-cloud',
      plant_uid: uid,
      online: invs.some((i) => i.online === true),
      pv_power: soma('power'),
      energy_today: soma('energy_today'),
      energy_month: soma('energy_month'),
      energy_total: soma('energy_total'),
      invs_reportando: invs.filter((i) => i.power != null).length,
      invs_total: invs.length,
      invs,
      ts: Date.now(),
    };
  } catch (e) {
    _ultimoErro = e.message;
    return null;
  }
}

function status() {
  return {
    configurado: !!(process.env.SAJ_USER && process.env.SAJ_PASS),
    tem_token: !!_tok,
    token_expira_em: _tok?.expiraEm || null,
    ultimo_ok_em: _ultimoOkEm || null,
    idade_s: _ultimoOkEm ? Math.round((Date.now() - _ultimoOkEm) / 1000) : null,
    ultimo_erro: _ultimoErro,
  };
}

module.exports = { lePlanta, status, _dataSaj };
