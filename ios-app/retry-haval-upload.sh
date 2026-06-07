#!/bin/bash
# Reenvia o build do Haval Hub pro TestFlight, tentando a cada ciclo até a Apple
# liberar (limite diário de uploads). Agendado por launchd com StartInterval.
# Para sozinho quando o upload passa.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd /Users/consorciolimpagyn/haval-ecotrip/ios-app || exit 1
echo "=== retry $(date '+%Y-%m-%d %H:%M:%S') ==="
./renew-testflight.sh HavalEcoTrip > /tmp/haval-retry-last.log 2>&1
if grep -q "enviado" /tmp/haval-retry-last.log; then
  echo "✓ upload OK — removendo agendamento"
  rm -f "$HOME/Library/LaunchAgents/com.consorciolimpagyn.haval-retry.plist"
  launchctl bootout "gui/$(id -u)/com.consorciolimpagyn.haval-retry" 2>/dev/null || true
else
  echo "ainda bloqueado — tenta de novo no próximo ciclo (3h)"
fi
