#!/usr/bin/env bash
# build-install.sh — regenera o projeto, builda e instala no iPhone conectado.
# Uso: ./build-install.sh
# Pré-requisitos: Xcode 26+, iPhone pareado, xcodegen no PATH (brew install xcodegen).
set -euo pipefail

cd "$(dirname "$0")"

echo "→ Regenerando projeto Xcode (xcodegen)…"
xcodegen generate

echo "→ Listando devices conectados…"
DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
  | awk '/connected/ {print $NF; exit}')

if [ -z "$DEVICE_ID" ]; then
  echo "✗ Nenhum iPhone conectado. Plugue o cabo e tenta de novo."
  exit 1
fi
echo "  device: $DEVICE_ID"

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
