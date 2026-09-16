#!/usr/bin/env bash
# Lista os builds recentes no App Store Connect (bundle do Haval).
# Existe porque o ASC dropa upload em silêncio quando passa de ~20 builds/24h:
# "upload succeeded" e o build nunca aparece. A única forma de saber é perguntar.
#
# Uso: ./asc-builds.sh [quantidade]     (default 10)
set -euo pipefail
cd "$(dirname "$0")"
ASC_KEY_ID="${ASC_KEY_ID:-956AX2CY9V}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-ecb6f30a-c529-4c6c-a786-0b52d3c3783f}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
LIMIT="${1:-10}"
[ -f "$ASC_KEY_PATH" ] || { echo "chave não encontrada: $ASC_KEY_PATH"; exit 1; }

# JWT ES256 sem biblioteca: openssl assina, python normaliza DER -> R||S cru.
JWT=$(python3 - "$ASC_KEY_ID" "$ASC_ISSUER_ID" "$ASC_KEY_PATH" <<'PY'
import base64, json, subprocess, sys, time
kid, iss, keypath = sys.argv[1], sys.argv[2], sys.argv[3]
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b'=')
hdr = b64(json.dumps({"alg":"ES256","kid":kid,"typ":"JWT"},separators=(',',':')).encode())
now = int(time.time())
pay = b64(json.dumps({"iss":iss,"iat":now,"exp":now+600,"aud":"appstoreconnect-v1"},
                     separators=(',',':')).encode())
signing = hdr + b'.' + pay
der = subprocess.run(['openssl','dgst','-sha256','-sign',keypath],
                     input=signing, capture_output=True, check=True).stdout
# DER SEQUENCE { INTEGER r, INTEGER s } -> 32 bytes cada, big-endian
def ints(d):
    assert d[0] == 0x30
    i = 2 if d[1] < 0x80 else 3 + (d[1] & 0x7f) - 1
    out = []
    for _ in range(2):
        assert d[i] == 0x02
        ln = d[i+1]; v = d[i+2:i+2+ln].lstrip(b'\x00')
        out.append(v.rjust(32, b'\x00')); i += 2 + ln
    return out
r, s = ints(der)
print((signing + b'.' + b64(r + s)).decode())
PY
)

curl -s -H "Authorization: Bearer $JWT" \
  "https://api.appstoreconnect.apple.com/v1/builds?limit=$LIMIT&sort=-uploadedDate" \
  | python3 -c "
import sys, json, datetime
d = json.load(sys.stdin)
if 'errors' in d:
    print('ERRO:', json.dumps(d['errors'])[:300]); raise SystemExit(1)
rows = d.get('data', [])
print(f'{len(rows)} builds mais recentes (todos os apps da conta):')
now = datetime.datetime.now(datetime.timezone.utc)
últimas24 = 0
for b in rows:
    a = b['attributes']
    up = a.get('uploadedDate') or ''
    try:
        t = datetime.datetime.fromisoformat(up.replace('Z', '+00:00'))
        idade = (now - t).total_seconds() / 3600
        if idade < 24: últimas24 += 1
        quando = t.astimezone().strftime('%d/%m %H:%M') + f'  ({idade:.1f}h)'
    except Exception:
        quando = up
    print(f\"  build {a.get('version','?'):<12} {a.get('processingState','?'):<10} {quando}\")
print(f'\nnas últimas 24h: {últimas24}  (o ASC começa a dropar em silêncio perto de ~20)')
"
