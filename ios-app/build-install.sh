#!/usr/bin/env bash
# build-install.sh — regenera o projeto, builda e instala no iPhone conectado.
# Uso: ./build-install.sh
# Pré-requisitos: Xcode 26+, iPhone pareado, xcodegen no PATH (brew install xcodegen).
set -euo pipefail

cd "$(dirname "$0")"

echo "→ Regenerando projeto Xcode (xcodegen)…"
xcodegen generate

echo "→ Listando devices conectados…"
# xcodebuild precisa do ECID (formato 8hex-16hex) do iPhone, não do UUID
# do CoreDevice. xctrace list devices retorna no formato correto.
# Filtra fora Simulator e Mac, pega o primeiro iPhone real.
DEVICE_LINE=$(xcrun xctrace list devices 2>&1 | grep -v -i "simulator\|^Mac " | grep -i "iPhone\|iPad" | head -1)
DEVICE_ID=$(echo "$DEVICE_LINE" | sed -E 's/.*\(([0-9A-F]{8}-[0-9A-F]{16})\).*/\1/')
DEVICE_NAME=$(echo "$DEVICE_LINE" | sed -E 's/^(.+) \([0-9.]+\) \([0-9A-F-]+\)$/\1/')

if [ -z "$DEVICE_ID" ] || [ "$DEVICE_ID" = "$DEVICE_LINE" ]; then
  echo "✗ Nenhum iPhone conectado. Plugue o cabo e tenta de novo."
  exit 1
fi
echo "  device: $DEVICE_NAME ($DEVICE_ID)"

DERIVED=/tmp/HavalEcoTrip-build
rm -rf "$DERIVED"

echo "→ Building (xcodebuild)…"
xcodebuild \
  -project HavalEcoTrip.xcodeproj \
  -scheme HavalEcoTrip \
  -configuration Debug \
  -destination "id=$DEVICE_ID" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  build 2>&1 | tail -20

APP_PATH="$DERIVED/Build/Products/Debug-iphoneos/HavalEcoTrip.app"
if [ ! -d "$APP_PATH" ]; then
  echo "✗ Build não produziu .app em $APP_PATH"
  exit 1
fi

echo "→ Instalando no iPhone…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH"

echo "✓ Pronto. Abra o app no iPhone."
