#!/usr/bin/env bash
# Restore de backup. Uso:
#   ./scripts/restore.sh                    # último diário
#   ./scripts/restore.sh <caminho.tar.gz>   # arquivo específico
#   ./scripts/restore.sh --list             # lista backups disponíveis
set -uo pipefail

ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs/02. RAFAEL PESSOAL/Backup Haval EcoTrip"
REPO_ROOT="/Users/consorciolimpagyn/haval-ecotrip"

# --list: mostra todos os backups disponíveis
if [ "${1:-}" = "--list" ]; then
  for d in daily weekly monthly yearly; do
    echo "── $d/ ──"
    ls -lh "$ICLOUD/$d"/*.tar.gz 2>/dev/null | awk '{print " ",$9,"·",$5,"·",$6,$7,$8}' || echo "  (vazio)"
  done
  exit 0
fi

SOURCE="${1:-}"
if [ -z "$SOURCE" ]; then
  SOURCE=$(ls -t "$ICLOUD/daily"/*.tar.gz 2>/dev/null | head -1)
  [ -z "$SOURCE" ] && { echo "❌ Nenhum backup em $ICLOUD/daily"; exit 1; }
  echo "→ Usando o mais recente: $SOURCE"
fi
[ -f "$SOURCE" ] || { echo "❌ arquivo não encontrado: $SOURCE"; exit 1; }

# Verifica integridade ANTES de mexer em qualquer coisa
echo "Verificando integridade do tarball…"
tar -tzf "$SOURCE" >/dev/null 2>&1 || { echo "❌ tarball corrompido"; exit 1; }
echo "✓ OK"

echo ""
echo "⚠  Isso vai SOBRESCREVER $REPO_ROOT/bridge"
echo "   Estado atual será movido pra bridge.before_restore_<timestamp>/"
read -p "   Continuar? (s/n): " ok
[ "$ok" = "s" ] || { echo "Cancelado."; exit 0; }

# Para o bridge antes
echo "Parando ecotrip-bridge…"
pm2 stop ecotrip-bridge 2>/dev/null || true

# Move o bridge atual pra backup local (pra não perder se algo der errado)
TS=$(date +%Y%m%d_%H%M%S)
if [ -d "$REPO_ROOT/bridge" ]; then
  mv "$REPO_ROOT/bridge" "$REPO_ROOT/bridge.before_restore_$TS"
  echo "→ bridge atual movido pra bridge.before_restore_$TS"
fi

# Extrai
tar -xzf "$SOURCE" -C "$REPO_ROOT/"
echo "✓ extraído de $(basename "$SOURCE")"

# Reinicia
pm2 start ecotrip-bridge --update-env >/dev/null && echo "✓ ecotrip-bridge online"
echo ""
echo "✓ Restore concluído. Se tudo OK, apague bridge.before_restore_$TS"
