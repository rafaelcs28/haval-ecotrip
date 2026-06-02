# EcoTrip Impulse — Haval H6

Plataforma de **telemetria, painel e controle em tempo real** pro **Haval H6 (PHEV/HEV)**. Um app roda no carro e publica os dados; um servidor (bridge) recebe, guarda histórico e serve as interfaces: **PWA no celular**, **cluster no tablet** e **apps iOS** (opcionais).

> 👉 **Quer só instalar (servidor próprio)?** Vá direto pro guia passo a passo: **[`docs/INSTALACAO-AMIGO.md`](docs/INSTALACAO-AMIGO.md)**.

---

## O que dá pra fazer
- **Ao vivo:** velocidade, potência, SOC, marcha, RPM, temperaturas, pneus, volante, modo de condução.
- **Viagem em curso:** distância, tempo, energia líquida (gasto − regen), consumo, custo R$/km, split EV/HEV.
- **Recarga:** potência, kWh efetivo, ETA, custo por sessão; histórico e linha do tempo.
- **Controles:** modo de condução, regeneração, one‑pedal, ESP, **A/C completo** (liga/desliga, compressor, temperatura, ventilador, recirculação, desembaçadores, ionizador, direção do ar) e **pisca‑alerta**.
- **Mapa** em tempo real (Leaflet) com a posição do carro.
- **Pré‑climatização** agendada, **Live Activities** (iOS) e **notificações push**.

---

## Arquitetura

```
  🚗 App no carro (APK)
        │  publica telemetria via MQTT (e serve LAN HTTP/WS via mDNS)
        ▼
  📡 Broker MQTT (Mosquitto)  ──── retém os últimos valores (retained)
        │
        ▼
  🖥️ Bridge Node.js  (servidor próprio: PC/mini‑PC/NAS/VPS)
     ├── /api/*   REST (estado, histórico, comandos, pareamento)
     ├── /ws      WebSocket ao vivo
     └── /        serve a PWA
        │
        ├───────────────► 📱 Celular (PWA) — configura tudo + gera código de pareamento
        ├───────────────► 📟 Tablet (app cluster) — painel grande (cloud + LAN direta)
        └───────────────► 🍏 Apps iOS (opcionais) — PWA wrapper + Live Activities
```

**Pareamento:** você configura o veículo **no PWA** e gera um **código de 6 dígitos**; no carro é só **Ajustes → Parear → digitar o código** (ele baixa broker/senha/URL sozinho — nada é digitado no carro).

---

## Componentes (estrutura do repositório)

```
haval-ecotrip/
├── app/        # APK do CARRO (Kotlin) — lê o CAN via Shizuku, publica MQTT,
│               #   serve HTTP/WS na LAN (mDNS _havalobd._tcp), POSTa viagens.
├── bridge/     # Servidor Node.js — MQTT→estado, REST+WS, serve a PWA,
│               #   pareamento, push/APNs, pré‑clima, IA (Ollama), backup.
│   ├── server.js
│   ├── public/             # PWA (celular) — dash, drive, conforto, posto, etc.
│   ├── .env.example
│   ├── docker-compose.yml  # subir bridge (+ Mosquitto opcional)
│   └── Dockerfile
├── cluster/    # APK do TABLET (Android) — WebView do cluster consumindo o
│               #   bridge (cloud + LAN ws://). Fit‑scaling, auto‑update.
├── ios-obd/    # App iPad "HavalOBD" — cluster nativo (WebView + Apple Maps).
├── ios-app/    # Apps iOS — HavalEcoTrip (wrapper PWA + Live Activities) e BydRecarga.
└── docs/       # Guias (INSTALACAO‑AMIGO.md, GUIA‑HOSPEDAGEM.md).
```

> O **app do tablet** (`cluster/`) e o **app do carro** (`app/`) são distribuídos como APK nos [Releases](https://github.com/rafaelcs28/haval-ecotrip/releases) (tags `vX.Y` = carro; `cluster-vX.Y` = tablet).

---

## Início rápido (servidor próprio, Docker)

```bash
git clone https://github.com/rafaelcs28/haval-ecotrip.git
cd haval-ecotrip/bridge
cp .env.example .env          # edite: MQTT_*, BRIDGE_TOKEN, BRIDGE_PUBLIC_URL, CAR_MQTT_*
docker compose up -d --build  # sobe o bridge (descomente 'mosquitto:' no compose se precisar de broker)
```
Abra `http://IP-DO-SERVIDOR:3000`, entre com a senha (`BRIDGE_TOKEN`), e siga o **[guia de instalação](docs/INSTALACAO-AMIGO.md)** (configurar veículo → gerar código → parear o carro → tablet → celular).

---

## App do carro (APK)

- Baixe o APK em [Releases](https://github.com/rafaelcs28/haval-ecotrip/releases).
- Requer **Shizuku** rodando na multimídia (acesso ao CAN do carro).
- **Configuração = pareamento** (não se digita broker no carro): no PWA gere o código e no carro use **Ajustes → Parear**.

Compilar localmente:
```bash
export JAVA_HOME=".../openjdk@17/..."
./gradlew :app:assembleRelease     # APK em app/build/outputs/apk/release/
```
Assinatura: crie `local.properties` na raiz com `SIGNING_STORE_FILE`, `SIGNING_STORE_PASSWORD`, `SIGNING_KEY_ALIAS`, `SIGNING_KEY_PASSWORD`.

---

## App do tablet (cluster)

APK Android que roda o **mesmo cluster do iPad** numa WebView, consumindo o bridge:
- **Cloud** (HTTP/HTTPS) e **LAN direta** (descobre o carro por mDNS e usa `ws://…/ws/state` ~10 fps).
- **Fit‑scaling** adaptativo (qualquer tela — tablet, dobrável), **auto‑update** (⚙ → Atualizar app).
- Config: **⚙ → Base URL + senha** (a do `BRIDGE_TOKEN`).

Baixe a tag `cluster-vX.Y` em Releases. Compilar: `./gradlew :cluster:assembleRelease`.

---

## Bridge — servidor Node.js

### Pré‑requisitos
- **Docker** (recomendado) **ou** Node.js ≥ 18.
- Um **broker MQTT** (Mosquitto local/HA, ou gerenciado).

### Rodar sem Docker (dev)
```bash
cd bridge && npm install && cp .env.example .env
npm run dev        # http://localhost:3000
```

### Variáveis de ambiente (`.env`) — principais
| Variável | Descrição |
|---|---|
| `MQTT_HOST` / `MQTT_PORT` | broker que o **bridge** lê (ex. `mqtt://mosquitto`, `mqtts://broker`) |
| `MQTT_USER` / `MQTT_PASS` | credenciais do broker |
| `MQTT_PREFIX` | prefixo dos tópicos (`haval/ecotrip`) — vai no pareamento |
| `BRIDGE_TOKEN` | **senha de acesso** (texto puro; o bridge calcula o hash) |
| `BRIDGE_PUBLIC_URL` | URL externa do bridge (Tailscale/DDNS) — **enviada no pareamento** pro carro mandar viagens |
| `CAR_MQTT_HOST` / `_PORT` / `_TLS` | endereço do broker que o **carro** usa pela internet (4G). Vazio = usa o local |
| `GWM_CHASSI` | chassi (`lgw`+14) — opcional aqui (dá pra pôr no PWA) |
| `HA_URL` / `HA_TOKEN` | Home Assistant (opcional) — estados iniciais + comandos remotos |
| `PORT` / `HTTPS_PORT` | portas HTTP/HTTPS |
| `GOOGLE_OAUTH_CLIENT_ID` / `*_ALLOWED_EMAILS` | login Google no PWA (opcional) |

> Segredos (`.env`, `*.p8`, `auth.json`, certs) **nunca** são versionados (ver `.gitignore`). Dados pessoais (viagens/recargas) ficam só na pasta `bridge/` do seu servidor.

### Segurança
- Todas as rotas `/api/*` (exceto push e `/api/pair/redeem`) exigem `Authorization: Bearer <senha-ou-hash>`.
- O `requireAuth` aceita a **senha em texto** ou o **SHA‑256** dela — por isso o tablet/PWA usam só a senha.
- Login por senha + opcional **Google** e **2FA (TOTP)**. Troca de senha pela própria PWA.
- Recomendado **HTTPS** (Caddy/Tailscale) pra senha trafegar criptografada e push da PWA funcionar.

### Dados gerados (na pasta `bridge/`)
`state.json`, `charges.json`, `autotrips/`, `lifetime_snapshots.json`, `drive_history.json`, `preclimat.json`, `vapid_keys.json`, `push_subscriptions.json`… → **faça backup** (ou use `scripts/backup.sh`). Não são versionados.

---

## Deploy avançado (VPS + Mosquitto + Caddy)

<details>
<summary>Passos detalhados (Ubuntu + PM2 + Caddy)</summary>

**Broker (Mosquitto):**
```bash
sudo apt install -y mosquitto mosquitto-clients
sudo mosquitto_passwd -c /etc/mosquitto/passwd ecotrip
printf 'listener 1883\nallow_anonymous false\npassword_file /etc/mosquitto/passwd\npersistence true\npersistence_location /var/lib/mosquitto/\n' | sudo tee /etc/mosquitto/conf.d/ecotrip.conf
sudo systemctl enable --now mosquitto
```

**Bridge com PM2:**
```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - && sudo apt install -y nodejs
sudo npm install -g pm2
cd haval-ecotrip/bridge && npm install --production && cp .env.example .env && nano .env
pm2 start server.js --name ecotrip-bridge && pm2 startup && pm2 save
```

**HTTPS (Caddy):**
```
ecotrip.seudominio.com {
    reverse_proxy localhost:3000
}
```

> **Armadilha — broker em VM `vmnet-bridged`** (UTM/QEMU/Parallels): o host pode não alcançar a VM pelo IP "público" da LAN (limitação do `vmnet` da Apple) → `ECONNRESET`/`Keepalive timeout`. **Fix:** adicione um 2º adapter em **Shared Network (NAT)**, descubra o IP `192.168.64.x` e use em `MQTT_HOST`.
</details>

---

## API (principais endpoints)
| Método | Endpoint | Descrição |
|---|---|---|
| `GET` | `/api/state` | estado atual completo |
| `GET` | `/api/charges` · `/api/auto-trips` | histórico de recargas / viagens |
| `POST` | `/api/pair/generate` | gera código de pareamento (autenticado) |
| `POST` | `/api/pair/redeem` | carro resgata o código e recebe a config (sem login) |
| `POST` | `/api/hvac/<control>` · `/api/hazard` · `/api/drive-mode` … | comandos |
| `POST` | `/api/auto-trips` | carro envia a viagem ao fim |
| `WS` | `/ws` | stream ao vivo |

`/api/*` exige `Authorization: Bearer <token>` quando `BRIDGE_TOKEN` está setado (exceto push e `pair/redeem`).

---

## Tópicos MQTT (prefixo `haval/ecotrip/`)
`speed_kmh`, `gear`, `soc_pct`, `motor_power_kw`, `engine_rpm`, `inside_temp`/`outside_temp`, `charging_state`, `charge_power_kw`, `charge_session_kwh`, `charge_remaining_min`, `gps_lat`/`gps_lng`, `hvac_*` (ac_enable, power_mode, fan_speed, temp, blower, defrost…), `lifetime/*`, `status` (online/offline, retained). Comandos chegam em `…/cmd/<nome>`.

---

## Atualização do servidor
```bash
cd haval-ecotrip && git pull
# Docker:  cd bridge && docker compose up -d --build
# PM2:     cd bridge && npm install --production && pm2 restart ecotrip-bridge
```
Os dados (`bridge/*.json`, `autotrips/`) não são versionados — `git pull` não os afeta.

---

## Licença
Uso pessoal/educacional. Desenvolvido para o Haval H6 (PHEV34 / HEV).
