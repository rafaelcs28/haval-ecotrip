#!/usr/bin/env bash
# new-tenant.sh — provisiona uma instância ISOLADA do bridge para outra pessoa.
#
# Modelo: login Google-only (sem senha). A identidade é o EMAIL Google. O porteiro
# (gateway.js) roteia por email pra instância isolada da pessoa. Todos acessam a
# MESMA URL (Funnel 443 → gateway). 2FA (TOTP) é opcional, a pessoa ativa na UI dela.
#
# Cada tenant roda o MESMO código (bridge/), com ECOTRIP_DATA_DIR=tenants/<nome>/
# → dados (state/trips/charges/tokens APNs/.env) SEPARADOS. MQTT isolado por prefixo
# + usuário/ACL no broker. A pessoa roda em casa: o APK do carro + a Home Assistant
# + GWM dela (publica gwmbrasil_<chassi> no SEU broker via TLS).
#
# Uso:  ./new-tenant.sh <nome> <email> <chassi> <porta>
#   nome    slug curto [a-z0-9_]  (ex: joao)         → prefixo haval/joao, pm2 ecotrip-joao
#   email   email Google da pessoa (login)           → whitelist + roteamento
#   chassi  chassi do carro (igual ao da HA/GWM)      → tópicos gwmbrasil_<chassi>
#   porta   porta HTTP LOCAL da instância (ex: 3001)  (não exposta; só o gateway é)
#
set -euo pipefail
cd "$(dirname "$0")"

NAME="${1:-}"; EMAIL="${2:-}"; CHASSI="${3:-}"; PORT="${4:-}"
if [[ -z "$NAME" || -z "$EMAIL" || -z "$CHASSI" || -z "$PORT" ]]; then
  echo "uso: ./new-tenant.sh <nome> <email> <chassi> <porta>"; exit 1
fi
[[ "$NAME" =~ ^[a-z0-9_]+$ ]] || { echo "erro: nome só pode ter [a-z0-9_]"; exit 1; }
[[ "$PORT" =~ ^[0-9]+$ ]]     || { echo "erro: porta inválida"; exit 1; }
[[ "$EMAIL" =~ ^[^@]+@[^@]+$ ]] || { echo "erro: email inválido"; exit 1; }
EMAIL="$(echo "$EMAIL" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
CHASSI="$(echo "$CHASSI" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"

DATA_DIR="$(pwd)/tenants/$NAME"
ENV_FILE="$DATA_DIR/.env"
REGISTRY="$(pwd)/tenants/registry.json"
[[ -e "$ENV_FILE" ]] && { echo "erro: $ENV_FILE já existe — apague antes de recriar"; exit 1; }
mkdir -p "$DATA_DIR"

# --- segredos ---------------------------------------------------------------
# Token opaco da API (Bearer). Garante que o backend EXIGE auth; a pessoa nunca o
# vê — recebe via login Google. NÃO é senha.
API_TOKEN_HASH="$(openssl rand -hex 32)"
MQTT_USER="ecotrip_${NAME}"
MQTT_PASSWORD="$(openssl rand -hex 18)"
MQTT_PREFIX="haval/${NAME}"

# --- valores compartilhados herdados do .env principal ----------------------
get() { grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2-; }
MQTT_HOST_LOCAL="$(get MQTT_HOST)"; MQTT_HOST_LOCAL="${MQTT_HOST_LOCAL:-mqtt://192.168.64.3}"
MQTT_PORT_LOCAL="$(get MQTT_PORT)"; MQTT_PORT_LOCAL="${MQTT_PORT_LOCAL:-1883}"
GOOGLE_CLIENT_ID="$(get GOOGLE_OAUTH_CLIENT_ID)"
GOOGLE_IOS_CID="$(get GOOGLE_IOS_CLIENT_ID)"
APNS_ENABLED="$(get APNS_ENABLED)"; APNS_TEAM_ID="$(get APNS_TEAM_ID)"
APNS_KEY_ID="$(get APNS_KEY_ID)";   APNS_BUNDLE_ID="$(get APNS_BUNDLE_ID)"
APNS_ENV="$(get APNS_ENV)";         APNS_KEY_P8_PATH="$(get APNS_KEY_P8_PATH)"

cat > "$ENV_FILE" <<EOF
# Tenant: $NAME <$EMAIL> — gerado por new-tenant.sh em $(date -u +%Y-%m-%dT%H:%M:%SZ)
PORT=$PORT

# Login federado: só este email é aceito nesta instância (Google e/ou Apple).
GOOGLE_OAUTH_CLIENT_ID=$GOOGLE_CLIENT_ID
GOOGLE_IOS_CLIENT_ID=$GOOGLE_IOS_CID
GOOGLE_ALLOWED_EMAILS=$EMAIL
# Apple: aud = bundle (herda APNS_BUNDLE_ID). Se a pessoa usar "Ocultar Meu Email",
# o email vira um relay @privaterelay.appleid.com — veja no log e adicione aqui (vírgula).
APPLE_ALLOWED_EMAILS=$EMAIL

# Bridge ↔ broker LOCAL (mesma máquina → plaintext ok). Credenciais DESTE tenant.
MQTT_HOST=$MQTT_HOST_LOCAL
MQTT_PORT=$MQTT_PORT_LOCAL
MQTT_USER=$MQTT_USER
MQTT_PASS=$MQTT_PASSWORD
MQTT_PREFIX=$MQTT_PREFIX

# Carro/HA da pessoa publicam em gwmbrasil_<chassi>
GWM_CHASSI=$CHASSI

# Home Assistant DA PESSOA (preencha quando ela te passar URL + token de longa duração).
# Sem isso, comandos remotos (motor/pré-clima/tranca) ficam indisponíveis pra ela.
HA_URL=
HA_TOKEN=

# Token opaco da API (Bearer). A pessoa NUNCA digita isto — recebe via login Google.
BRIDGE_TOKEN_HASH=$API_TOKEN_HASH

# APNs compartilhado (mesmo app/chave; tokens são por dispositivo e ficam neste DATA_DIR)
APNS_ENABLED=$APNS_ENABLED
APNS_TEAM_ID=$APNS_TEAM_ID
APNS_KEY_ID=$APNS_KEY_ID
APNS_KEY_P8_PATH=$APNS_KEY_P8_PATH
APNS_BUNDLE_ID=$APNS_BUNDLE_ID
APNS_ENV=$APNS_ENV
EOF
chmod 600 "$ENV_FILE"

# --- registra no porteiro (email → porta) -----------------------------------
node -e '
const fs=require("fs");
const f=process.argv[1], email=process.argv[2], port=+process.argv[3], name=process.argv[4];
let r={}; try{ r=JSON.parse(fs.readFileSync(f,"utf8")); }catch(_){}
r[email]={port,name};
fs.writeFileSync(f, JSON.stringify(r,null,2)+"\n");
' "$REGISTRY" "$EMAIL" "$PORT" "$NAME"

FUNNEL_HOST="mac-mini.tailacc6e7.ts.net"

cat <<EOF

✅ Tenant "$NAME" <$EMAIL> provisionado.
   DATA_DIR : $DATA_DIR
   .env     : $ENV_FILE   (chmod 600, fora do git)
   registry : $EMAIL → porta $PORT

──────────────────────────────────────────────────────────────────────────────
PRÓXIMOS PASSOS
──────────────────────────────────────────────────────────────────────────────

1) BROKER — criar usuário + ACL (rodar NO broker, $MQTT_HOST_LOCAL):
   mosquitto_passwd -b /etc/mosquitto/passwd $MQTT_USER '$MQTT_PASSWORD'
   # no acl file, adicione:
       user $MQTT_USER
       topic readwrite $MQTT_PREFIX/#
       topic readwrite gwmbrasil_$CHASSI/#
   # recarregue:  sudo systemctl reload mosquitto

2) BRIDGE — subir a instância isolada (pm2):
   ECOTRIP_DATA_DIR="$DATA_DIR" pm2 start server.js --name ecotrip-$NAME --update-env
   pm2 save
   # o porteiro (gateway) detecta o novo email automaticamente (recarrega registry.json)

3) ENTREGAR PARA A PESSOA ($EMAIL):
   • Acesse: https://$FUNNEL_HOST   →   "Entrar com Google" (use a conta $EMAIL)
   • (2FA opcional: a pessoa ativa depois, na UI, em Ajustes → Segurança)
   • APK do carro → Ajustes → MQTT:
       Host: <SEU broker público>   Porta: 8883   TLS: ON
       Usuário: $MQTT_USER          Senha: $MQTT_PASSWORD
       Prefixo: $MQTT_PREFIX
   • Home Assistant dela → integração MQTT no MESMO broker (8883/TLS, mesmas
     credenciais). E te enviar HA_URL + token de longa duração → cole no $ENV_FILE
     e:  pm2 restart ecotrip-$NAME --update-env

⚠️  Confirme que $EMAIL é exatamente o email que ela usa no Google.
──────────────────────────────────────────────────────────────────────────────
EOF
