# EcoTrip Bridge

Servidor Node.js que recebe telemetria do APK do carro via MQTT, persiste em arquivos JSON, e serve o PWA + APIs REST + WebSocket.

## Stack

- Node.js 20+ (testado em 20 e 22)
- MQTT broker (Mosquitto local ou do Home Assistant)
- Home Assistant com `gwm_brasil_custom_component` (opcional, mas recomendado pra estados iniciais)
- pm2 pra rodar como serviço (opcional)

## Requisitos antes de começar

1. **Carro Haval H6 PHEV34** com o APK EcoTrip Impulse instalado no head unit. Build a partir do repo principal (tag `v5.x`).
2. **Acesso MQTT**: broker rodando em algum lugar da sua rede que tanto o APK do carro quanto o bridge consigam alcançar. Tipicamente o broker integrado do Home Assistant ou Mosquitto isolado.
3. **Home Assistant** (opcional) com o `custom_component` GWM Brasil ativo — fornece o chassi e dados iniciais via REST.
4. **Chassi do veículo** em minúsculas (encontre no app GWM Brasil ou documento).

## Setup em ~15 min

### Opção A — Docker (recomendado, sem instalar Node)

Pré-requisitos: Docker Desktop ou Docker Engine + Compose.

```bash
git clone https://github.com/rafaelcs28/haval-ecotrip.git
cd haval-ecotrip/bridge
cp .env.example .env
# edita o .env com seus valores — leia os comentários inline
docker compose up -d --build
```

Acesse: `http://localhost:3000`.

```bash
# Logs em tempo real
docker compose logs -f bridge

# Reiniciar (depois de mudar .env)
docker compose restart bridge

# Atualizar pra última versão do repo
git pull && docker compose up -d --build

# Parar / remover
docker compose down
```

### Opção B — Node nativo

```bash
git clone https://github.com/rafaelcs28/haval-ecotrip.git
cd haval-ecotrip/bridge
npm install
cp .env.example .env
# edita o .env com seus valores
node server.js
# ou via pm2: pm2 start server.js --name ecotrip-bridge
```

## Configuração mínima do .env

Pra rodar funcional, no mínimo:

```
MQTT_HOST=mqtt://192.168.X.X       # IP do seu broker
MQTT_USER=usuario_mqtt              # (se broker requer auth)
MQTT_PASS=senha_mqtt
GWM_CHASSI=lgwxxxxxxxxxxx           # SEU chassi em minúsculas
BRIDGE_TOKEN=senha_forte_aqui       # protege a PWA
```

Tudo o resto é opcional ou tem default sensato.

## HTTPS público (pra acessar fora de casa)

O bridge serve HTTP em `PORT` e HTTPS auto-signed em `HTTPS_PORT` (cert.pem/key.pem). Pra ter HTTPS válido (sem warning) sem precisar de domínio próprio, recomendado **Tailscale Funnel**:

```bash
brew install --cask tailscale-app
# Abre o app, faz login, ativa Funnel via console:
# https://login.tailscale.com → Settings → Features → enable Funnel
tailscale funnel --bg 3000
# Te dá uma URL como https://seu-mac.tailNNNN.ts.net pública com HTTPS válido
```

Outras opções: Cloudflare Tunnel + domínio, ngrok pago, Let's Encrypt + DDNS.

## APK no carro

Duas opções:

**A. Usar a APK pré-buildada do GitHub Releases**:
1. Baixa o `.apk` mais recente de https://github.com/rafaelcs28/haval-ecotrip/releases
2. Instala no head unit (sideload via Shizuku)
3. Em Settings do APK, configure:
   - **MQTT host/port/user/pass** apontando pro SEU broker
   - **MQTT prefix** = `haval/ecotrip` (igual ao .env)
   - **Bridge URL** = `http://IP_DO_SEU_BRIDGE:PORT` (ou URL Tailscale)
   - **Bridge Token** = mesma senha do .env

**B. Buildar próprio** (recomendado se quiser OTA do próprio repo):
1. Forka o repo no GitHub
2. Edita `app/build.gradle.kts`: troca `GITHUB_REPO` pro seu fork
3. Build local via Android Studio OU push de tag `vX.Y` → GitHub Actions builda APK automaticamente

## Persistência

Tudo em arquivos JSON dentro de `bridge/`:

| Arquivo | Conteúdo |
|---|---|
| `state.json` | Estado em tempo real (SOC, GPS, etc) |
| `autotrips/*.json` | Uma viagem por arquivo (metadata + telemetria) |
| `charges.json` | Sessões de recarga |
| `charge_telemetry/*.json` | Timeline detalhada por sessão de recarga |
| `refuels.json` | Abastecimentos |
| `events.json` | Log de eventos (eco-score, geofences, etc) |
| `lifetime_snapshots.json` | Snapshots diários pra stats |
| `known_places.json` | Locais conhecidos (casa, trabalho) |
| `maintenance.json` | Intervalos + histórico |
| `radars.json` | Base de radares baixada do OSM (refresh semanal) |
| `radars_ignored.json` | Radares marcados como inexistentes |
| `deleted_ids.json` | Tombstones de deleção |
| `auth.json` | Secret TOTP + códigos backup (se 2FA ativo) |

Backup completo: PWA → Settings → "Backup completo (servidor)" gera um JSON único com tudo. Restore via mesmo painel.

## Comandos úteis

```bash
# Logs em tempo real
pm2 logs ecotrip-bridge --raw

# Status
pm2 status

# Reiniciar
pm2 restart ecotrip-bridge

# Inspecionar MQTT
eval "$(grep -E '^MQTT_(USER|PASS)=' .env)"
mosquitto_sub -h SEU_BROKER -u "$MQTT_USER" -P "$MQTT_PASS" -t '#' -v

# Forçar download de radares (Brasil inteiro, ~3 min)
curl -X POST http://localhost:3000/api/radars/refresh \
  -H "Authorization: Bearer $(grep BRIDGE_TOKEN_HASH .env | cut -d= -f2)"
```

## Troubleshooting

**"GWM_CHASSI não configurado"** no boot → adicione no .env e reinicie.

**MQTT não conecta** → verifica `MQTT_HOST`, firewall, e se o broker aceita conexões da rede do bridge.

**APK não envia dados** → verifica que MQTT_PREFIX bate entre APK Settings e .env. Use `mosquitto_sub -t 'haval/ecotrip/#'` pra ver se está chegando.

**PWA mostra "Sem conexão"** → cert HTTPS inválido bloqueia WebSocket; usa HTTP ou Tailscale Funnel pra resolver.

**Login Google "Acesso bloqueado"** → no Google Console: tela de consentimento OAuth → Usuários de teste → adiciona seu email.

## Limitações conhecidas

- Single-tenant: 1 bridge = 1 carro. Pra cada carro/usuário, suba uma instância separada.
- Tila/Storage: arquivos JSON funcionam até alguns anos de uso (~100 MB), mas não escalam pra muitos veículos.
- O integration GWM Brasil é uma fonte secundária — alguns dados só chegam pelo MQTT do APK.

## Licença

Uso pessoal/educacional. Sem garantia.
