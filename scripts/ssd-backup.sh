#!/usr/bin/env bash
# Backup físico consolidado dos dados do Mac Mini no SSD externo (sempre montado).
# Cobre os 3 produtos: Haval bridge, Lari (whats-assistant) e Ellevar Clockin.
# Snapshots consistentes (sqlite3 .backup pra DBs em WAL) + GFS rotation.
# Escreve em volume LOCAL — não passa pelo TCC do iCloud (que bloqueia o launchd).
# Rodar manualmente:  ./scripts/ssd-backup.sh
# Rodar via launchd:   ~/Library/LaunchAgents/com.haval.ssd-backup.plist
set -uo pipefail

# ───────────────────── CONFIG ─────────────────────
SSD_MOUNT="/Volumes/SSD1TB"
SSD="$SSD_MOUNT/Backups"
ICLOUD="$HOME/Library/Mobile Documents/com~apple~CloudDocs/02. RAFAEL PESSOAL/Backup Haval EcoTrip"
HAVAL_SRC="/Users/consorciolimpagyn/haval-ecotrip/bridge"
LARI_DIR="/Users/consorciolimpagyn/whats-assistant"
CLOCKIN_DIR="/Users/consorciolimpagyn/ellevar-clockin"
MOSQ_ETC="/opt/homebrew/etc/mosquitto"
MOSQ_DB="/opt/homebrew/var/mosquitto/mosquitto.db"
RETENTION_DAILY=14
RETENTION_WEEKLY=8
RETENTION_MONTHLY=12
BRIDGE_API="http://localhost:3000"
SQLITE=/usr/bin/sqlite3
# ──────────────────────────────────────────────────

NOW=$(date +%Y-%m-%d_%H%M%S)
DATE=$(date +%Y-%m-%d)
WEEKDAY=$(date +%u)        # 1=segunda … 7=domingo
DAY_OF_MONTH=$(date +%d)

# 1) SSD montado e gravável? Se não, avisa e sai limpo (o monitor de saúde pega).
if [ ! -d "$SSD_MOUNT" ] || ! mkdir -p "$SSD" 2>/dev/null || ! touch "$SSD/.write_test" 2>/dev/null; then
  echo "[$(date +%FT%T)] SSD externo indisponível em $SSD_MOUNT — backup pulado"
  curl -s -X POST "$BRIDGE_API/api/admin/backup-failed" \
    -H 'Content-Type: application/json' \
    -d '{"detail":"SSD externo /Volumes/SSD1TB indisponível — backup físico pulado"}' \
    >/dev/null 2>&1 || true
  exit 0
fi
rm -f "$SSD/.write_test"

LOG="$SSD/ssd-backup.log"
log()  { echo "[$(date +%FT%T)] $*" | tee -a "$LOG"; }
warn() { log "⚠ $*"; FAILED+=("$*"); }
FAILED=()

log "═══ SSD backup iniciando ($NOW) ═══"

# prune_dir <dir> <keep> <glob>: mantém só os N mais recentes.
prune_dir() {
  local dir="$1" keep="$2" glob="$3" total
  total=$(find "$dir" -maxdepth 1 -name "$glob" 2>/dev/null | wc -l | tr -d ' ')
  [ "$total" -le "$keep" ] && return
  find "$dir" -maxdepth 1 -name "$glob" 2>/dev/null | sort | head -n "-$keep" \
    | while read -r f; do rm -rf "$f" && log "  rm $(basename "$f")"; done
}

# promote <src> <base>: copia pra weekly (domingo) / monthly (dia 1).
promote() {
  local src="$1" base="$2"
  [ "$WEEKDAY" = "7" ]      && { mkdir -p "$base/weekly";  cp -R "$src" "$base/weekly/"  && log "  → weekly"; }
  [ "$DAY_OF_MONTH" = "01" ] && { mkdir -p "$base/monthly"; cp -R "$src" "$base/monthly/" && log "  → monthly"; }
}

# ── 1) Haval bridge (tarball, exclui node_modules/logs/.git) ─────────────────
HAVAL_BASE="$SSD/haval-ecotrip"
mkdir -p "$HAVAL_BASE/daily"
HAVAL_TAR="$HAVAL_BASE/daily/haval-bridge_${NOW}.tar.gz"
log "Haval: compactando bridge/ → $(basename "$HAVAL_TAR")"
if tar -czf "$HAVAL_TAR" \
     --exclude='node_modules' --exclude='*.log' --exclude='.git' \
     --exclude='.DS_Store' --exclude='__pycache__' \
     -C "$(dirname "$HAVAL_SRC")" "$(basename "$HAVAL_SRC")" 2>>"$LOG" \
   && tar -tzf "$HAVAL_TAR" >/dev/null 2>&1; then
  log "  ✓ $(du -h "$HAVAL_TAR" | cut -f1)"
  promote "$HAVAL_TAR" "$HAVAL_BASE"
  prune_dir "$HAVAL_BASE/daily"   "$RETENTION_DAILY"   'haval-bridge_*.tar.gz'
  prune_dir "$HAVAL_BASE/weekly"  "$RETENTION_WEEKLY"  'haval-bridge_*.tar.gz'
  prune_dir "$HAVAL_BASE/monthly" "$RETENTION_MONTHLY" 'haval-bridge_*.tar.gz'
else
  warn "Haval: tar falhou"; rm -f "$HAVAL_TAR"
fi

# ── 2) Lari (snapshot consistente das 2 DBs + coleções do Radicale) ──────────
LARI_BASE="$SSD/whats-assistant"
LARI_DEST="$LARI_BASE/daily/$DATE"
mkdir -p "$LARI_DEST"
lari_ok=1
for db in assistant assistant-rafael; do
  if [ -f "$LARI_DIR/data/$db.db" ]; then
    "$SQLITE" "$LARI_DIR/data/$db.db" ".backup '$LARI_DEST/$db.db'" 2>>"$LOG" \
      || { warn "Lari: .backup $db falhou"; lari_ok=0; }
  fi
done
if [ -d "$LARI_DIR/radicale/collections" ]; then
  tar -czf "$LARI_DEST/radicale-collections.tgz" -C "$LARI_DIR/radicale" collections 2>>"$LOG" \
    || { warn "Lari: tar radicale falhou"; lari_ok=0; }
fi
[ "$lari_ok" = 1 ] && log "Lari: ✓ $(du -sh "$LARI_DEST" | cut -f1) → $DATE"
promote "$LARI_DEST" "$LARI_BASE"
prune_dir "$LARI_BASE/daily"   "$RETENTION_DAILY"   '20*'
prune_dir "$LARI_BASE/weekly"  "$RETENTION_WEEKLY"  '20*'
prune_dir "$LARI_BASE/monthly" "$RETENTION_MONTHLY" '20*'

# ── 3) Clockin (snapshot consistente da DB em WAL + anexos) ──────────────────
CK_BASE="$SSD/ellevar-clockin"
CK_DEST="$CK_BASE/daily/$DATE"
mkdir -p "$CK_DEST"
ck_ok=1
if [ -f "$CLOCKIN_DIR/data/clockin.sqlite" ]; then
  "$SQLITE" "$CLOCKIN_DIR/data/clockin.sqlite" ".backup '$CK_DEST/clockin.sqlite'" 2>>"$LOG" \
    || { warn "Clockin: .backup falhou"; ck_ok=0; }
fi
# Anexos (atestados/PDFs) — arquivos, não DB.
for sub in leave-attachments pdfs; do
  [ -d "$CLOCKIN_DIR/data/$sub" ] && rsync -a --delete "$CLOCKIN_DIR/data/$sub/" "$CK_DEST/$sub/" 2>>"$LOG" \
    || true
done
[ "$ck_ok" = 1 ] && log "Clockin: ✓ $(du -sh "$CK_DEST" | cut -f1) → $DATE"
promote "$CK_DEST" "$CK_BASE"
prune_dir "$CK_BASE/daily"   "$RETENTION_DAILY"   '20*'
prune_dir "$CK_BASE/weekly"  "$RETENTION_WEEKLY"  '20*'
prune_dir "$CK_BASE/monthly" "$RETENTION_MONTHLY" '20*'

# ── 4) MQTT / Mosquitto (config + passwd + persistência) → SSD e iCloud ──────
# Snapshot dos dados do broker: mosquitto.conf, passwd e mosquitto.db (retidos
# clientes/subscriptions/retained). Tarball com GFS, espelhado nos 2 destinos.
ICLOUD_OK=1
mkdir -p "$ICLOUD" 2>/dev/null && touch "$ICLOUD/.write_test" 2>/dev/null || ICLOUD_OK=0
[ "$ICLOUD_OK" = 1 ] && rm -f "$ICLOUD/.write_test" || warn "iCloud indisponível (TCC?) — espelho pulado"

# destinos para os itens espelhados (SSD sempre; iCloud se gravável)
MIRROR_DESTS=("$SSD")
[ "$ICLOUD_OK" = 1 ] && MIRROR_DESTS+=("$ICLOUD")

# Snapshot temporário do broker (cp local, rápido).
MQTT_STAGE="$(mktemp -d)/mqtt"
mkdir -p "$MQTT_STAGE"
mqtt_ok=1
cp "$MOSQ_ETC/mosquitto.conf" "$MQTT_STAGE/" 2>>"$LOG" || { warn "MQTT: cp mosquitto.conf falhou"; mqtt_ok=0; }
[ -f "$MOSQ_ETC/passwd" ] && { cp "$MOSQ_ETC/passwd" "$MQTT_STAGE/" 2>>"$LOG" || { warn "MQTT: cp passwd falhou"; mqtt_ok=0; }; }
[ -f "$MOSQ_DB" ] && { cp "$MOSQ_DB" "$MQTT_STAGE/" 2>>"$LOG" || { warn "MQTT: cp mosquitto.db falhou"; mqtt_ok=0; }; }
MQTT_TAR_NAME="mosquitto_${NOW}.tar.gz"
MQTT_TMP_TAR="$(dirname "$MQTT_STAGE")/$MQTT_TAR_NAME"
if [ "$mqtt_ok" = 1 ] && tar -czf "$MQTT_TMP_TAR" -C "$(dirname "$MQTT_STAGE")" "$(basename "$MQTT_STAGE")" 2>>"$LOG" \
   && tar -tzf "$MQTT_TMP_TAR" >/dev/null 2>&1; then
  for dest in "${MIRROR_DESTS[@]}"; do
    MQ_BASE="$dest/mosquitto"
    mkdir -p "$MQ_BASE/daily"
    cp "$MQTT_TMP_TAR" "$MQ_BASE/daily/$MQTT_TAR_NAME" 2>>"$LOG" \
      && { chmod 600 "$MQ_BASE/daily/$MQTT_TAR_NAME" 2>/dev/null; log "MQTT: ✓ $(du -h "$MQTT_TMP_TAR" | cut -f1) → $(basename "$dest")"; } \
      || warn "MQTT: cópia p/ $dest falhou"
    promote "$MQ_BASE/daily/$MQTT_TAR_NAME" "$MQ_BASE"
    prune_dir "$MQ_BASE/daily"   "$RETENTION_DAILY"   'mosquitto_*.tar.gz'
    prune_dir "$MQ_BASE/weekly"  "$RETENTION_WEEKLY"  'mosquitto_*.tar.gz'
    prune_dir "$MQ_BASE/monthly" "$RETENTION_MONTHLY" 'mosquitto_*.tar.gz'
  done
else
  warn "MQTT: snapshot/tar falhou"
fi
rm -rf "$(dirname "$MQTT_STAGE")"

# ── 5) Backup-do-backup do Clockin (espelha a pasta de snapshots) → SSD/iCloud ─
# Clockin já roda sua própria rotação de clockin-*.sqlite em data/backups/.
# Aqui guardamos uma cópia física desses snapshots nos 2 destinos (mirror).
CK_BK_SRC="$CLOCKIN_DIR/data/backups"
if [ -d "$CK_BK_SRC" ]; then
  for dest in "${MIRROR_DESTS[@]}"; do
    CK_BK_DEST="$dest/ellevar-clockin/backups-mirror"
    mkdir -p "$CK_BK_DEST"
    if rsync -a --delete "$CK_BK_SRC/" "$CK_BK_DEST/" 2>>"$LOG"; then
      log "Clockin-backups: ✓ $(du -sh "$CK_BK_DEST" | cut -f1) → $(basename "$dest")"
    else
      warn "Clockin-backups: rsync p/ $dest falhou"
    fi
  done
else
  log "Clockin-backups: $CK_BK_SRC não existe — pulado"
fi

# ── 6) Manifest legível ──────────────────────────────────────────────────────
{
  echo "# Backup físico Mac Mini → SSD externo"
  echo "# Última atualização: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "# Espaço livre no SSD: $(df -h "$SSD" | awk 'NR==2{print $4}')"
  echo
  for p in haval-ecotrip whats-assistant ellevar-clockin mosquitto; do
    echo "## $p/daily ($(find "$SSD/$p/daily" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l | tr -d ' ') itens)"
    ls -lht "$SSD/$p/daily" 2>/dev/null | awk 'NR>1{print "  ",$9,"·",$5}' | head -5
    echo
  done
  echo "## ellevar-clockin/backups-mirror ($(find "$SSD/ellevar-clockin/backups-mirror" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ') snapshots, $(du -sh "$SSD/ellevar-clockin/backups-mirror" 2>/dev/null | cut -f1))"
  echo "# iCloud espelhado: $([ -d "$ICLOUD/mosquitto" ] && echo sim || echo não)"
} > "$SSD/MANIFEST.txt"

if [ ${#FAILED[@]} -gt 0 ]; then
  detail="SSD backup com falhas: $(IFS='; '; echo "${FAILED[*]}")"
  log "═══ SSD backup terminou COM FALHAS (${#FAILED[@]}) ═══"
  curl -s -X POST "$BRIDGE_API/api/admin/backup-failed" \
    -H 'Content-Type: application/json' \
    -d "{\"detail\":$(printf '%s' "$detail" | python3 -c 'import sys,json;print(json.dumps(sys.stdin.read()))')}" \
    >/dev/null 2>&1 || true
  exit 1
fi
log "═══ SSD backup OK ═══"
