#!/usr/bin/env bash
# Backup diário do haval-ecotrip.
#   • iCloud Drive: rotação GFS (7 daily / 4 weekly / 12 monthly / ∞ yearly).
#   • GitHub privado (opcional): force-push do último tarball (1 arquivo, sem bloat).
# Rodar manualmente:   ./scripts/backup.sh
# Rodar via launchd:   ~/Library/LaunchAgents/com.haval.backup.plist (00:00 diário).
set -uo pipefail

# ───────────────────── CONFIG ─────────────────────
SOURCE="/Users/consorciolimpagyn/haval-ecotrip/bridge"
ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs/02. RAFAEL PESSOAL/Backup Haval EcoTrip"
GITHUB_MIRROR="$HOME/haval-ecotrip-backup-mirror"   # clone local do repo privado (criar manualmente)
RETENTION_DAILY=7
RETENTION_WEEKLY=4
RETENTION_MONTHLY=12
BRIDGE_API="http://localhost:3000"
# ──────────────────────────────────────────────────

LOG="$ICLOUD/backup.log"
mkdir -p "$ICLOUD"/{daily,weekly,monthly,yearly} || { echo "❌ não consigo criar $ICLOUD"; exit 1; }
touch "$LOG"

NOW=$(date +%Y-%m-%d_%H%M%S)
WEEKDAY=$(date +%u)       # 1=segunda … 7=domingo
DAY_OF_MONTH=$(date +%d)
MONTH=$(date +%m)
TARNAME="haval-ecotrip_${NOW}.tar.gz"
DAILY_PATH="$ICLOUD/daily/$TARNAME"

log()  { echo "[$(date +%Y-%m-%dT%H:%M:%S)] $*" | tee -a "$LOG"; }
fail() { log "❌ $*"; notify_fail "$*"; exit 1; }
notify_fail() {
  # Tenta avisar via push do bridge (se ele estiver no ar)
  curl -s -X POST "$BRIDGE_API/api/admin/backup-failed" \
    -H 'Content-Type: application/json' \
    -d "{\"detail\":$(printf '%s' "$1" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')}" \
    >/dev/null 2>&1 || true
}

log "═══ Backup iniciando ═══"

# 1) Cria tarball
log "Compactando $(basename "$SOURCE")/ → $TARNAME"
tar -czf "$DAILY_PATH" \
  --exclude='node_modules' \
  --exclude='*.log' \
  --exclude='.git' \
  --exclude='.DS_Store' \
  --exclude='__pycache__' \
  -C "$(dirname "$SOURCE")" "$(basename "$SOURCE")" 2>>"$LOG" \
  || fail "tar falhou"

# 2) Verifica integridade
tar -tzf "$DAILY_PATH" >/dev/null 2>&1 || fail "tarball corrompido"

SIZE=$(du -h "$DAILY_PATH" | cut -f1)
log "✓ daily/ $TARNAME ($SIZE)"

# 3) Promote: domingo → weekly | dia 1 → monthly | 1/jan → yearly
if [ "$WEEKDAY" = "7" ]; then
  cp "$DAILY_PATH" "$ICLOUD/weekly/" && log "→ weekly/"
fi
if [ "$DAY_OF_MONTH" = "01" ]; then
  cp "$DAILY_PATH" "$ICLOUD/monthly/" && log "→ monthly/"
fi
if [ "$DAY_OF_MONTH" = "01" ] && [ "$MONTH" = "01" ]; then
  cp "$DAILY_PATH" "$ICLOUD/yearly/" && log "→ yearly/"
fi

# 4) Prune (mantém só os N mais recentes em cada categoria; yearly = ilimitado)
prune_dir() {
  local dir="$1" keep="$2"
  local total
  total=$(find "$dir" -maxdepth 1 -name "haval-ecotrip_*.tar.gz" -type f 2>/dev/null | wc -l | tr -d ' ')
  [ "$total" -le "$keep" ] && return
  find "$dir" -maxdepth 1 -name "haval-ecotrip_*.tar.gz" -type f 2>/dev/null \
    | sort | head -n "-$keep" \
    | while read -r f; do
        rm -f "$f" && log "  rm $(basename "$f")"
      done
}
prune_dir "$ICLOUD/daily"   "$RETENTION_DAILY"
prune_dir "$ICLOUD/weekly"  "$RETENTION_WEEKLY"
prune_dir "$ICLOUD/monthly" "$RETENTION_MONTHLY"

# 5) GitHub mirror — só o ÚLTIMO tarball (force-push, sem bloat)
if [ -d "$GITHUB_MIRROR/.git" ]; then
  cp "$DAILY_PATH" "$GITHUB_MIRROR/latest.tar.gz"
  {
    echo "# Backup Haval EcoTrip (mirror)"
    echo
    echo "Último: \`$TARNAME\`"
    echo "Tamanho: $SIZE"
    echo "Quando: $NOW"
    echo
    echo "## Restaurar"
    echo '```bash'
    echo 'git clone <repo> mirror'
    echo 'cd mirror'
    echo 'tar -xzf latest.tar.gz -C /tmp'
    echo '# então copie /tmp/bridge → seu haval-ecotrip/bridge'
    echo '```'
  } > "$GITHUB_MIRROR/README.md"

  (cd "$GITHUB_MIRROR" && \
   git add -A >/dev/null 2>&1 && \
   git commit -m "Backup $NOW" >/dev/null 2>&1 && \
   git push origin main --force >>"$LOG" 2>&1 \
   && log "✓ GitHub mirror pushed" \
   || log "⚠ GitHub push falhou (continua)")
else
  log "ℹ GitHub mirror não configurado em $GITHUB_MIRROR (skip)"
fi

# 6) Manifest legível
{
  echo "# Manifest de Backups — Haval EcoTrip"
  echo "# Última atualização: $(date '+%Y-%m-%d %H:%M:%S')"
  echo
  for d in daily weekly monthly yearly; do
    echo "## $d/ ($(find "$ICLOUD/$d" -name 'haval-ecotrip_*.tar.gz' 2>/dev/null | wc -l | tr -d ' ') arquivos)"
    if ls -lh "$ICLOUD/$d"/*.tar.gz >/dev/null 2>&1; then
      ls -lh "$ICLOUD/$d"/*.tar.gz | awk '{print "  ",$9,"·",$5}' | sed "s|$ICLOUD/$d/||"
    fi
    echo
  done
} > "$ICLOUD/MANIFEST.txt"

log "═══ Backup OK ═══"
