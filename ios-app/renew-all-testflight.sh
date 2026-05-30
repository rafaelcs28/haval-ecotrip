#!/usr/bin/env bash
# Renova os DOIS apps no TestFlight (HavalEcoTrip + Grasi Recarga).
# Chamado pelo launchd a cada 2 meses. Loga em /tmp/testflight-renew.log.
cd "$(dirname "$0")"
echo "===== $(date) — renovação TestFlight ====="
git pull --ff-only 2>&1 || true
./renew-testflight.sh HavalEcoTrip
./renew-testflight.sh BydRecarga
echo "===== fim $(date) ====="
