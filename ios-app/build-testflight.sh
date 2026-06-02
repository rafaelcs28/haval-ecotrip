#!/usr/bin/env bash
# Archive Release + upload pro TestFlight (App Store Connect).
# Funciona de qualquer rede — o iPhone atualiza pelo app TestFlight depois.
#
# Pré-requisitos (uma vez):
#   1. App criado no App Store Connect (bundle br.com.consorciolimpagyn.havalecotrip).
#   2. Chave da App Store Connect API (Users and Access > Integrations):
#        - guarde o .p8 em ~/.appstoreconnect/private_keys/AuthKey_<KEYID>.p8
#        - exporte as variáveis abaixo (ou edite os defaults).
#
# Uso:
#   export ASC_KEY_ID=XXXXXXXXXX
#   export ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#   ./build-testflight.sh [BUILD_NUMBER]
#   (sem BUILD_NUMBER usa a data/hora: AAMMDDhhmm, sempre crescente)
set -euo pipefail
cd "$(dirname "$0")"

BUILD_NUMBER="${1:-$(date +%y%m%d%H%M)}"
# Defaults da conta (só identificadores; o segredo é o .p8, que é gitignorado).
ASC_KEY_ID="${ASC_KEY_ID:-956AX2CY9V}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-ecb6f30a-c529-4c6c-a786-0b52d3c3783f}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
[ -f "$ASC_KEY_PATH" ] || { echo "❌ chave não encontrada: $ASC_KEY_PATH"; exit 1; }

ARCHIVE="build/HavalEcoTrip.xcarchive"
AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

echo "▶︎ Gerando projeto (xcodegen)…"
xcodegen generate

echo "▶︎ Archive Release (build $BUILD_NUMBER)…"
xcodebuild -project HavalEcoTrip.xcodeproj -scheme HavalEcoTrip \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  "${AUTH[@]}" archive

echo "▶︎ Export + upload pro App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export \
  "${AUTH[@]}"

echo "✅ Build $BUILD_NUMBER enviado. Aparece no TestFlight em alguns minutos"
echo "   (App Store Connect > seu app > TestFlight). Depois é só atualizar pelo app TestFlight no iPhone."
