#!/bin/bash
# Reenvia o build do Grasi Recarga pro TestFlight, tentando a cada ciclo até a
# Apple liberar (limite diário de uploads). Agendado por launchd com StartInterval.
# Para sozinho quando o upload passa. O renew-testflight.sh avisa ✅/❌ via push.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
cd /Users/consorciolimpagyn/haval-ecotrip/ios-app || exit 1
echo "=== retry $(date '+%Y-%m-%d %H:%M:%S') ==="
./renew-testflight.sh BydRecarga > /tmp/grasi-retry-last.log 2>&1
if grep -q "enviado" /tmp/grasi-retry-last.log; then
  echo "✓ upload OK — removendo agendamento"
  rm -f "$HOME/Library/LaunchAgents/com.consorciolimpagyn.grasi-retry.plist"
  launchctl bootout "gui/$(id -u)/com.consorciolimpagyn.grasi-retry" 2>/dev/null || true
else
  echo "ainda bloqueado — tenta de novo no próximo ciclo (3h)"
fi
