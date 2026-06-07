#!/usr/bin/env bash
# Renova um build no TestFlight (expira a cada 90 dias) — archive Release +
# upload pro App Store Connect. Avisa sucesso/falha via ntfy.
#
# Uso:
#   ./renew-testflight.sh HavalEcoTrip   # app principal (internal testing)
#   ./renew-testflight.sh BydRecarga     # Grasi Recarga (external + review)
#
# Pré-requisitos: API key em ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8,
# certificados de distribuição no keychain (Mac mini logado), Xcode + xcodegen.
set -uo pipefail
cd "$(dirname "$0")"

SCHEME="${1:?uso: renew-testflight.sh <HavalEcoTrip|BydRecarga>}"
BUILD_NUMBER="$(date +%y%m%d%H%M)"
ASC_KEY_ID="${ASC_KEY_ID:-956AX2CY9V}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-ecb6f30a-c529-4c6c-a786-0b52d3c3783f}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
ARCHIVE="/tmp/${SCHEME}-renew.xcarchive"
EXPORT="/tmp/${SCHEME}-renew-export"

# Aviso via push APNs (endpoint admin do bridge → só o iPhone do Rafael).
BRIDGE_LOCAL="${BRIDGE_LOCAL:-http://localhost:3000}"
ADMIN_TOKEN="$(grep -E '^ADMIN_TOKEN=' ../bridge/.env 2>/dev/null | cut -d= -f2-)"
notify() {
  [ -n "$ADMIN_TOKEN" ] || return 0
  curl -s -X POST "$BRIDGE_LOCAL/api/admin/notify" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
    -d "{\"title\":\"TestFlight ${SCHEME}\",\"body\":$(printf '%s' "$1" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}" \
    >/dev/null 2>&1 || true
}
fail()   { echo "❌ $1"; notify "❌ FALHA: ${SCHEME} (build ${BUILD_NUMBER}). $1"; exit 1; }

AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

[ -f "$ASC_KEY_PATH" ] || fail "API key não encontrada: $ASC_KEY_PATH"

echo "▶︎ [$SCHEME] xcodegen…"
xcodegen generate >/dev/null || fail "xcodegen falhou"

echo "▶︎ [$SCHEME] archive Release (build $BUILD_NUMBER)…"
rm -rf "$ARCHIVE"
xcodebuild -project HavalEcoTrip.xcodeproj -scheme "$SCHEME" \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${AUTH[@]}" archive >/tmp/${SCHEME}-archive.log 2>&1 || fail "archive falhou (ver /tmp/${SCHEME}-archive.log)"

echo "▶︎ [$SCHEME] export + upload…"
rm -rf "$EXPORT"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist -exportPath "$EXPORT" \
  "${AUTH[@]}" >/tmp/${SCHEME}-export.log 2>&1 || fail "upload falhou (ver /tmp/${SCHEME}-export.log)"

# O upload pode retornar "Upload succeeded" e a Apple descartar o pacote no
# processamento sem criar o build (aconteceu com o 2606062232). Confirmamos via
# ASC API que ESTE build apareceu e ficou VALID antes de declarar "enviado".
case "$SCHEME" in
  HavalEcoTrip) BUNDLE_ID="br.com.consorciolimpagyn.havalecotrip";;
  BydRecarga)   BUNDLE_ID="br.com.consorciolimpagyn.songpro";;
  *)            BUNDLE_ID="";;
esac
if [ -n "$BUNDLE_ID" ]; then
  echo "▶︎ [$SCHEME] aguardando processamento na Apple (build $BUILD_NUMBER)…"
  ASC_KEY_ID="$ASC_KEY_ID" ASC_ISSUER_ID="$ASC_ISSUER_ID" ASC_KEY_PATH="$ASC_KEY_PATH" \
    node scripts/asc-wait-build.mjs "$BUNDLE_ID" "$BUILD_NUMBER" \
    || fail "build $BUILD_NUMBER não ficou VALID na Apple (descarte/recusa no processamento). Reenvie."
fi

# Grasi (external com link público) precisa associar ao grupo + submeter review.
# HavalEcoTrip (internal) não precisa — internal testers já veem todos os builds.
if [ "$SCHEME" = "BydRecarga" ]; then
  echo "▶︎ [$SCHEME] associando ao grupo + beta review…"
  ASC_KEY_ID="$ASC_KEY_ID" ASC_ISSUER_ID="$ASC_ISSUER_ID" ASC_KEY_PATH="$ASC_KEY_PATH" \
    node scripts/asc-promote-grasi.mjs >/tmp/${SCHEME}-promote.log 2>&1 || echo "⚠ promote teve erro (ver log) — build subiu mesmo assim"
fi

echo "✅ [$SCHEME] build $BUILD_NUMBER enviado."
notify "✅ ${SCHEME} renovado (build ${BUILD_NUMBER}). Válido +90 dias."
