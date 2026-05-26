#!/usr/bin/env bash
# auto-reinstall.sh — reinstala o app no iPhone via WiFi quando faz 6+ dias.
# Rode via cron diariamente (ver comentário no final do arquivo).
# Não faz nada se o iPhone não estiver na rede local.
set -euo pipefail

STAMP="$HOME/.haval_ios_last_install"
NOW=$(date +%s)
LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
DAYS=$(( (NOW - LAST) / 86400 ))

if [ "$DAYS" -lt 6 ]; then
  echo "[auto-reinstall] $(date): ok, faltam $((6 - DAYS)) dias para renovar."
  exit 0
fi

# Verifica se o iPhone está acessível na rede
DEVICE_LINE=$(xcrun xctrace list devices 2>/dev/null \
  | grep -v -i "simulator\|^Mac " \
  | grep -i "iPhone\|iPad" | head -1 || true)
DEVICE_ID=$(echo "$DEVICE_LINE" | sed -E 's/.*\(([0-9A-F]{8}-[0-9A-F]{16})\).*/\1/' || true)

if [ -z "$DEVICE_ID" ] || [ "$DEVICE_ID" = "$DEVICE_LINE" ]; then
  echo "[auto-reinstall] $(date): iPhone não encontrado na rede — tentará amanhã."
  exit 0
fi

echo "[auto-reinstall] $(date): renovando provisioning profile ($DAYS dias)…"
cd "$(dirname "$0")"
./build-install.sh && echo "$NOW" > "$STAMP"
echo "[auto-reinstall] $(date): instalação concluída."

# Para ativar: adicione ao cron com `crontab -e`
# Roda todo dia às 9h:
#   0 9 * * * /Users/consorciolimpagyn/haval-ecotrip/ios-app/auto-reinstall.sh >> /tmp/haval-auto-reinstall.log 2>&1
