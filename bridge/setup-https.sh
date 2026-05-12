#!/usr/bin/env bash
# ── EcoTrip Bridge — Setup HTTPS local com mkcert ────────────────────────────
# Gera certificado confiável para acesso HTTPS na rede local.
# Requer: brew install mkcert
#
# Após rodar este script:
#   1. Reinicie o bridge: pm2 restart ecotrip-bridge  (ou: node server.js)
#   2. Acesse: https://<IP-MAC-MINI>:3443  no iPhone
#
# Para o iPhone confiar no certificado:
#   1. Abra ~/.local/share/mkcert/rootCA.pem  →  AirDrop para o iPhone
#   2. iPhone → Configurações → Geral → VPN e Gerenciamento de Dispositivo
#      → instale o perfil "mkcert development CA"
#   3. Configurações → Geral → Sobre → Ajustes de Confiança do Certificado
#      → ative "mkcert development CA"
#   4. Pronto! Acesse https://<IP>:3443 no Safari → PWA → Push Notifications ✓

set -e

BRIDGE_DIR="$(cd "$(dirname "$0")" && pwd)"

# Verifica dependências
if ! command -v mkcert &> /dev/null; then
  echo "❌ mkcert não encontrado. Instale com: brew install mkcert"
  exit 1
fi

# Instala CA no keychain do macOS (só na 1ª vez)
echo "🔒 Instalando CA local no keychain do macOS..."
mkcert -install

# Descobre IP da rede local
LAN_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "")
HOSTNAME=$(hostname)

# Monta lista de SANs
SANS="$HOSTNAME localhost 127.0.0.1"
[ -n "$LAN_IP" ] && SANS="$SANS $LAN_IP"

echo "🔐 Gerando certificado para: $SANS"

# Gera cert no diretório do bridge
cd "$BRIDGE_DIR"
mkcert $SANS

# Renomeia para os nomes esperados pelo server.js
# mkcert gera algo como: hostname+3.pem e hostname+3-key.pem
CERT_FILE=$(ls *.pem 2>/dev/null | grep -v key | head -1)
KEY_FILE=$(ls *-key.pem 2>/dev/null | head -1)

if [ -z "$CERT_FILE" ] || [ -z "$KEY_FILE" ]; then
  echo "❌ Arquivos .pem não encontrados após geração"
  exit 1
fi

mv "$CERT_FILE" cert.pem
mv "$KEY_FILE"  key.pem

echo ""
echo "✅  Certificado gerado em: $BRIDGE_DIR"
echo "    cert.pem  →  $CERT_FILE"
echo "    key.pem   →  $KEY_FILE"
echo ""
echo "📱 Para o iPhone confiar:"
CAROOT=$(mkcert -CAROOT)
echo "    AirDrop este arquivo para o iPhone: $CAROOT/rootCA.pem"
echo "    Depois: Configurações → Geral → VPN e Gerenciamento → instale o perfil"
echo "    Depois: Configurações → Geral → Sobre → Ajustes de Confiança → ative mkcert"
echo ""
echo "🔁 Reinicie o bridge: pm2 restart ecotrip-bridge"
if [ -n "$LAN_IP" ]; then
  echo "🌐 Acesse no iPhone: https://$LAN_IP:3443"
fi
