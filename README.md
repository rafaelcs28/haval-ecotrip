# EcoTrip Impulse

Monitoramento em tempo real para o **Haval H6 HEV** via app Android + PWA para iPhone.

---

## Arquitetura

```
App Android (no carro)
      │  publica a cada 5s via MQTT
      ▼
Broker MQTT  ◄──── retém últimos valores (retained)
      │
      ▼
Bridge Node.js  (VPS / servidor)
  ├── /ws          WebSocket → PWA iPhone (dados ao vivo)
  ├── /api/*       REST → PWA iPhone (histórico)
  └── /            Serve a PWA (arquivos estáticos)
      │
      ▼
PWA iPhone (Safari / "Adicionar à tela de início")
```

---

## Estrutura do repositório

```
haval-ecotrip/
├── app/                        # App Android (Kotlin / Jetpack Compose)
│   └── src/main/java/…/
│       ├── managers/
│       │   ├── MqttManager.kt   # Publicação MQTT
│       │   └── TripManager.kt   # Toda a lógica de trips, recarga, lifetime
│       ├── models/
│       │   ├── CarConstants.kt  # Mapeamento de sinais do carro
│       │   └── SharedPreferencesKeys.kt
│       └── ui/screens/          # Telas Compose
│
└── bridge/                     # Servidor Node.js
    ├── server.js                # Entry point — MQTT + WebSocket + REST + serve PWA
    ├── package.json
    ├── .env.example             # Template de configuração
    └── public/                  # PWA (iPhone)
        ├── index.html
        ├── app.js
        ├── style.css
        ├── manifest.json
        └── sw.js                # Service Worker (cache offline)
```

---

## App Android

O APK de release está disponível em [Releases](https://github.com/rafaelcs28/haval-ecotrip/releases).

Para compilar localmente:

```bash
# Requer Android Studio / SDK com compileSdk 36
./gradlew assembleRelease
# APK gerado em: app/build/outputs/apk/release/app-release.apk
```

### Assinatura (release)

Crie `local.properties` na raiz com:

```properties
SIGNING_STORE_FILE=/caminho/para/keystore.jks
SIGNING_STORE_PASSWORD=...
SIGNING_KEY_ALIAS=...
SIGNING_KEY_PASSWORD=...
```

### Configuração no app

Após instalar no Android do carro, configure em **Configurações**:
- Endereço do broker MQTT
- Usuário / senha do broker
- URL do Bridge (ex: `https://ecotrip.seudominio.com`)
- Preço da gasolina (R$/L) e energia (R$/kWh)

---

## Bridge — Servidor Node.js

### Pré-requisitos

- Node.js ≥ 18
- Um broker MQTT acessível pela internet (ver seção abaixo)

### Instalação local (desenvolvimento)

```bash
cd bridge
npm install
cp .env.example .env
# edite .env com as credenciais do broker
npm run dev      # reinicia automaticamente ao salvar
```

Acesse `http://localhost:3000` no navegador.

### Variáveis de ambiente (`.env`)

| Variável | Padrão | Descrição |
|---|---|---|
| `MQTT_HOST` | `mqtt://localhost` | URL do broker (ex: `mqtts://broker.com`) |
| `MQTT_PORT` | `1883` | Porta MQTT (TLS: `8883`) |
| `MQTT_USER` | *(vazio)* | Usuário do broker |
| `MQTT_PASS` | *(vazio)* | Senha do broker |
| `MQTT_PREFIX` | `haval/ecotrip` | Prefixo dos tópicos — deve ser igual ao configurado no app |
| `PORT` | `3000` | Porta HTTP do servidor |
| `ADMIN_TOKEN` | `ecotrip-restart` | Token para endpoints admin (`/api/admin/*`) |

### Arquivos de dados (gerados automaticamente)

O servidor cria estes arquivos na pasta `bridge/` em produção:

| Arquivo/pasta | Conteúdo |
|---|---|
| `trips.json` | Histórico de trips manuais A/B |
| `charges.json` | Histórico de sessões de recarga |
| `state.json` | Último estado completo do carro |
| `autotrips/` | Um `.json` por viagem automática |
| `lifetime_snapshots.json` | Snapshots de acumulados |
| `vapid_keys.json` | Chaves para Push Notifications (geradas automaticamente) |
| `push_subscriptions.json` | Assinaturas de push dos dispositivos |

> **Backup**: faça backup periódico desses arquivos. São os dados históricos do usuário.

---

## Deploy em VPS

### 1. Criar o servidor

Recomendações:
- **Hetzner CAX11** — €3,29/mês (ARM, 2 vCPU, 4 GB RAM) — melhor custo-benefício
- **Oracle Cloud Always Free** — gratuito permanente (requer cadastro com cartão)
- **DigitalOcean Droplet** — $4/mês

Sistema operacional: **Ubuntu 24.04 LTS**.

---

### 2. Broker MQTT no mesmo VPS (Mosquitto)

```bash
sudo apt update && sudo apt install -y mosquitto mosquitto-clients

# Configuração básica com autenticação
sudo mosquitto_passwd -c /etc/mosquitto/passwd ecotrip
# (define a senha no prompt)

sudo nano /etc/mosquitto/conf.d/ecotrip.conf
```

Conteúdo do arquivo de configuração:

```
listener 1883
allow_anonymous false
password_file /etc/mosquitto/passwd
persistence true
persistence_location /var/lib/mosquitto/
```

```bash
sudo systemctl enable --now mosquitto
sudo ufw allow 1883/tcp   # libera porta MQTT
```

> **Alternativa gerenciada**: [HiveMQ Cloud](https://www.hivemq.com/mqtt-cloud-broker/) tem plano gratuito (100 conexões, TLS incluído). Evita manter broker próprio.

---

### 3. Node.js + Bridge

```bash
# Instala Node.js 22 LTS
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt install -y nodejs

# Instala PM2 (gerenciador de processos — auto-restart, logs, boot)
sudo npm install -g pm2

# Clona o repositório
git clone https://github.com/rafaelcs28/haval-ecotrip.git
cd haval-ecotrip/bridge

# Instala dependências
npm install --production

# Cria o arquivo de configuração
cp .env.example .env
nano .env   # preencha com as credenciais do broker e token admin

# Inicia com PM2
pm2 start server.js --name ecotrip-bridge

# Configura para iniciar automaticamente no boot
pm2 startup    # executa o comando que ele imprimir
pm2 save
```

Comandos úteis do PM2:

```bash
pm2 logs ecotrip-bridge       # ver logs em tempo real
pm2 restart ecotrip-bridge    # reiniciar
pm2 status                    # status de todos os processos
```

---

### 4. HTTPS com Caddy (recomendado)

O Caddy obtém e renova certificado TLS automaticamente via Let's Encrypt.

```bash
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install caddy

sudo nano /etc/caddy/Caddyfile
```

Conteúdo do `Caddyfile`:

```
ecotrip.seudominio.com {
    reverse_proxy localhost:3000
}
```

```bash
sudo systemctl enable --now caddy
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
```

Após isso a PWA estará disponível em `https://ecotrip.seudominio.com`.

> **DNS**: aponte um registro A do seu domínio para o IP do VPS antes de iniciar o Caddy.

---

### 5. Configurar o app do carro

No app Android, em Configurações:
- **URL do Bridge**: `https://ecotrip.seudominio.com`
- **MQTT Host**: IP do VPS (ex: `mqtt://1.2.3.4`) ou domínio do broker gerenciado
- **MQTT Usuário/Senha**: as credenciais criadas no passo 2

---

### 6. Instalar a PWA no iPhone

1. Abra `https://ecotrip.seudominio.com` no Safari
2. Toque no ícone de compartilhar (⬆)
3. **"Adicionar à Tela de Início"**
4. O app fica disponível como ícone nativo, com cache offline

---

## Atualização do servidor

```bash
cd haval-ecotrip
git pull
cd bridge && npm install --production
pm2 restart ecotrip-bridge
```

> Os arquivos de dados (`trips.json`, `charges.json`, etc.) não são versionados e não são afetados pelo `git pull`.

---

## Endpoints da API

| Método | Endpoint | Descrição |
|---|---|---|
| `GET` | `/api/state` | Estado atual completo do carro |
| `GET` | `/api/trips` | Histórico de trips manuais |
| `GET` | `/api/charges` | Histórico de recargas |
| `GET` | `/api/auto-trips` | Viagens automáticas |
| `GET` | `/api/vapidPublicKey` | Chave pública para Push Notifications |
| `POST` | `/api/push/subscribe` | Registrar dispositivo para push |
| `POST` | `/api/auto-trips` | Receber viagens do app Android |
| `POST` | `/api/admin/clear-history` | Apagar todo o histórico (requer `Authorization: Bearer <ADMIN_TOKEN>`) |
| `POST` | `/api/admin/restart` | Reiniciar o servidor (requer token) |
| `WS` | `/ws` | WebSocket — stream de dados ao vivo |

---

## Tópicos MQTT publicados pelo app

Prefixo padrão: `haval/ecotrip/`

| Tópico | Tipo | Descrição |
|---|---|---|
| `speed_kmh` | Float | Velocidade atual |
| `gear` | String | Marcha (P/R/N/D) |
| `soc_pct` | Float | Bateria % |
| `fuel_pct` | Float | Combustível % |
| `inside_temp` / `outside_temp` | Float | Temperaturas |
| `charging_state` | String | Estado de recarga |
| `charge_power_kw` | Float | Potência de carga |
| `charge_session_kwh` | Float | kWh injetados na sessão atual |
| `charge_remaining_min` | Int | Minutos restantes para carga completa |
| `trip_a/*` / `trip_b/*` | Float | Métricas dos trips manuais |
| `rolling/*` | Float | Métricas desde a última partida |
| `lifetime/*` | Float | Acumulados totais |
| `price_gas_per_l` | Float | Preço da gasolina configurado no app |
| `price_kwh` | Float | Preço da energia configurado no app |
| `status` | String | `online` / `offline` (retained) |

---

## Licença

Uso pessoal. Desenvolvido para Haval H6 HEV (versão HEV 2023+).
