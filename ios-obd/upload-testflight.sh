#!/usr/bin/env bash
# Archive Release + export IPA + upload (altool) do HavalOBD pro TestFlight.
# Usa altool no upload porque o `xcodebuild -exportArchive destination=upload`
# já travou por horas. App "Haval OBD" (bundle br.com.consorciolimpagyn.havalobd).
set -uo pipefail
cd "$(dirname "$0")"

BUILD_NUMBER="$(date +%y%m%d%H%M)"
ASC_KEY_ID="${ASC_KEY_ID:-956AX2CY9V}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-ecb6f30a-c529-4c6c-a786-0b52d3c3783f}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
ARCHIVE="/tmp/HavalOBD.xcarchive"
EXPORT="/tmp/HavalOBD-ipa"

AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

[ -f "$ASC_KEY_PATH" ] || { echo "❌ API key não encontrada: $ASC_KEY_PATH"; exit 1; }

echo "▶︎ [HavalOBD] xcodegen…"
xcodegen generate >/dev/null || { echo "❌ xcodegen falhou"; exit 1; }

echo "▶︎ [HavalOBD] archive Release (build $BUILD_NUMBER)…"
rm -rf "$ARCHIVE"
xcodebuild -project HavalOBD.xcodeproj -scheme HavalOBD \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${AUTH[@]}" archive >/tmp/HavalOBD-archive.log 2>&1 \
  || { echo "❌ archive falhou (ver /tmp/HavalOBD-archive.log)"; exit 1; }

echo "▶︎ [HavalOBD] export IPA…"
rm -rf "$EXPORT"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$EXPORT" \
  "${AUTH[@]}" >/tmp/HavalOBD-export.log 2>&1 \
  || { echo "❌ export falhou (ver /tmp/HavalOBD-export.log)"; exit 1; }

IPA="$(ls "$EXPORT"/*.ipa 2>/dev/null | head -1)"
[ -f "$IPA" ] || { echo "❌ IPA não gerado"; exit 1; }

echo "▶︎ [HavalOBD] upload (altool)…"
xcrun altool --upload-app -f "$IPA" -t ios \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" >/tmp/HavalOBD-altool.log 2>&1 \
  || { echo "❌ upload falhou (ver /tmp/HavalOBD-altool.log)"; exit 1; }

echo "✅ [HavalOBD] build $BUILD_NUMBER enviado."
