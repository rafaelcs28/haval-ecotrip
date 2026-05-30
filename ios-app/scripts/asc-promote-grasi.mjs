// Promove o último build do Grasi Recarga: espera processar (VALID), associa
// ao grupo externo "Grasi" e submete pro Beta App Review. Idempotente.
// Credenciais via env (ASC_KEY_ID, ASC_ISSUER_ID) com defaults; .p8 no path padrão.
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';

const KEY_ID = process.env.ASC_KEY_ID || '956AX2CY9V';
const ISSUER_ID = process.env.ASC_ISSUER_ID || 'ecb6f30a-c529-4c6c-a786-0b52d3c3783f';
const KEY_PATH = process.env.ASC_KEY_PATH || `${os.homedir()}/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8`;
const APP_ID = process.env.GRASI_APP_ID || '6775046559';
const GROUP_NAME = 'Grasi';

const b64url = (b) => Buffer.from(b).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
function derToJose(d) { let o = 2; if (d[1] & 0x80) o = 2 + (d[1] & 0x7f); let rl = d[o + 1]; let r = d.slice(o + 2, o + 2 + rl); o = o + 2 + rl; let sl = d[o + 1]; let s = d.slice(o + 2, o + 2 + sl); const p = (b) => { b = b[0] === 0 ? b.slice(1) : b; const x = Buffer.alloc(32); b.copy(x, 32 - b.length); return x; }; return Buffer.concat([p(r), p(s)]); }
function jwt() { const k = fs.readFileSync(KEY_PATH, 'utf8'); const h = { alg: 'ES256', kid: KEY_ID, typ: 'JWT' }; const n = Math.floor(Date.now() / 1000); const pl = { iss: ISSUER_ID, iat: n, exp: n + 600, aud: 'appstoreconnect-v1' }; const si = `${b64url(JSON.stringify(h))}.${b64url(JSON.stringify(pl))}`; const der = crypto.sign('sha256', Buffer.from(si), { key: k, dsaEncoding: 'der' }); return `${si}.${b64url(derToJose(der))}`; }
async function api(m, p, body) { const r = await fetch(`https://api.appstoreconnect.apple.com${p}`, { method: m, headers: { Authorization: `Bearer ${jwt()}`, 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined }); const t = await r.text(); let j; try { j = JSON.parse(t); } catch { j = t; } return { status: r.status, json: j }; }
const sleep = (ms) => new Promise(r => setTimeout(r, ms));

// 1. Espera o build mais novo ficar VALID (até 15 min)
let build = null;
for (let i = 0; i < 30; i++) {
  const b = await api('GET', `/v1/builds?filter[app]=${APP_ID}&sort=-uploadedDate&limit=1`);
  const b0 = b.json?.data?.[0];
  if (b0 && b0.attributes.processingState === 'VALID') { build = b0; break; }
  console.log(`aguardando build processar… (${b0?.attributes?.processingState || '?'})`);
  await sleep(30000);
}
if (!build) { console.error('❌ build não ficou VALID a tempo'); process.exit(1); }
const buildId = build.id;
console.log(`✓ build v${build.attributes.version} VALID id=${buildId}`);

// 2. Grupo "Grasi"
const g = await api('GET', `/v1/betaGroups?filter[app]=${APP_ID}&filter[name]=${GROUP_NAME}&limit=1`);
const groupId = g.json?.data?.[0]?.id;
if (!groupId) { console.error('❌ grupo Grasi não encontrado'); process.exit(1); }

// 3. Associa build ao grupo (204 = ok; 409 = já associado, ok também)
const assoc = await api('POST', `/v1/betaGroups/${groupId}/relationships/builds`, { data: [{ type: 'builds', id: buildId }] });
console.log(`associar build↔grupo: ${assoc.status}`);

// 4. Submete pro Beta App Review
const sub = await api('POST', '/v1/betaAppReviewSubmissions', { data: { type: 'betaAppReviewSubmissions', relationships: { build: { data: { type: 'builds', id: buildId } } } } });
if (sub.status === 201) console.log('✓ enviado pro Beta Review');
else console.log(`beta review: ${sub.status} ${JSON.stringify(sub.json).slice(0, 200)}`);
