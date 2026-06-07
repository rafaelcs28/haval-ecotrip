// Espera um build específico (pelo número/version) aparecer no App Store Connect
// e ficar VALID. Resolve o caso em que o upload retorna "Upload succeeded" mas a
// Apple descarta/recusa o pacote no processamento sem nunca criar o registro.
//
// Uso: node asc-wait-build.mjs <bundleId> <buildVersion>
// Saída: 0 = VALID | 2 = INVALID/FAILED | 3 = não apareceu/timeout
// Credenciais via env (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH) com defaults.
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';

const KEY_ID = process.env.ASC_KEY_ID || '956AX2CY9V';
const ISSUER_ID = process.env.ASC_ISSUER_ID || 'ecb6f30a-c529-4c6c-a786-0b52d3c3783f';
const KEY_PATH = process.env.ASC_KEY_PATH || `${os.homedir()}/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8`;

const BUNDLE_ID = process.argv[2];
const VERSION = process.argv[3];
if (!BUNDLE_ID || !VERSION) { console.error('uso: asc-wait-build.mjs <bundleId> <buildVersion>'); process.exit(1); }

const TIMEOUT_MIN = Number(process.env.ASC_WAIT_MIN || 25);

const b64url = (b) => Buffer.from(b).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
function derToJose(d) { let o = 2; if (d[1] & 0x80) o = 2 + (d[1] & 0x7f); let rl = d[o + 1]; let r = d.slice(o + 2, o + 2 + rl); o = o + 2 + rl; let sl = d[o + 1]; let s = d.slice(o + 2, o + 2 + sl); const p = (b) => { b = b[0] === 0 ? b.slice(1) : b; const x = Buffer.alloc(32); b.copy(x, 32 - b.length); return x; }; return Buffer.concat([p(r), p(s)]); }
function jwt() { const k = fs.readFileSync(KEY_PATH, 'utf8'); const h = { alg: 'ES256', kid: KEY_ID, typ: 'JWT' }; const n = Math.floor(Date.now() / 1000); const pl = { iss: ISSUER_ID, iat: n, exp: n + 600, aud: 'appstoreconnect-v1' }; const si = `${b64url(JSON.stringify(h))}.${b64url(JSON.stringify(pl))}`; const der = crypto.sign('sha256', Buffer.from(si), { key: k, dsaEncoding: 'der' }); return `${si}.${b64url(derToJose(der))}`; }
async function api(p) { const r = await fetch(`https://api.appstoreconnect.apple.com${p}`, { headers: { Authorization: `Bearer ${jwt()}` } }); const t = await r.text(); try { return JSON.parse(t); } catch { return t; } }
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

const apps = await api(`/v1/apps?filter[bundleId]=${BUNDLE_ID}`);
const appId = apps?.data?.[0]?.id;
if (!appId) { console.error(`❌ app não encontrado p/ bundle ${BUNDLE_ID}`); process.exit(1); }

for (let i = 0; i < TIMEOUT_MIN; i++) {
  const b = await api(`/v1/builds?filter[app]=${appId}&filter[version]=${VERSION}&fields[builds]=version,processingState`);
  const st = b?.data?.[0]?.attributes?.processingState;
  if (st === 'VALID') { console.log(`✓ build ${VERSION} VALID no App Store Connect`); process.exit(0); }
  if (st === 'INVALID' || st === 'FAILED') { console.error(`❌ build ${VERSION} ${st} (processamento recusou)`); process.exit(2); }
  console.log(`  aguardando ${VERSION} processar… (${st || 'ainda não listado'}) ${i + 1}/${TIMEOUT_MIN}`);
  await sleep(60000);
}
console.error(`❌ build ${VERSION} não ficou VALID em ${TIMEOUT_MIN} min (provável descarte no processamento — reenvie)`);
process.exit(3);
