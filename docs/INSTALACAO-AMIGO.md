# Haval EcoTrip — Guia de Instalação (servidor próprio)

Guia completo pra rodar **tudo na sua casa/carro**, com **seu próprio servidor**. No fim você terá:

- 🖥️ **Servidor** (bridge + broker MQTT) rodando na sua máquina (PC, mini‑PC, NAS…).
- 🚗 **App no carro (APK)** publicando a telemetria do Haval.
- 📟 **App no tablet (APK do cluster)** mostrando o painel grande.
- 📱 **PWA no celular** (abre no navegador, vira app).

> Este guia **não usa o app do BYD** nem nada de Apple Push (Live Activities). Tudo funciona com PWA + cluster.

---

## 0. Como as peças conversam

```
  🚗 Carro (APK)  ──MQTT──►  📡 Broker (Mosquitto)  ◄──MQTT──  🖥️ Bridge (servidor)
                                                                     ▲ HTTP/HTTPS
                                          📟 Tablet (cluster)  ──────┤
                                          📱 Celular (PWA)     ──────┘
```

- O **carro publica** a telemetria no **broker**.
- O **bridge** lê o broker e serve a interface (PWA + cluster) por HTTP.
- **Tablet e celular** falam com o **bridge** (na mesma rede = rápido; de fora = via Tailscale).
- A **regra de ouro:** o **prefixo MQTT** (`haval/ecotrip`) tem que ser **idêntico** no carro e no servidor.

---

## 1. Pré‑requisitos

- Uma máquina **sempre ligada** pro servidor (Linux/Mac/Windows com Docker; um mini‑PC ou NAS é ideal).
- O carro é um **Haval/GWM compatível** com o app instalável + **Shizuku** (ver Parte 3).
- Um **tablet Android** e um **celular**.
- (Opcional, p/ acesso remoto) conta **Tailscale** grátis.

---

## 2. Servidor (bridge + broker) — via Docker

### 2.1. Instalar Docker
- Linux: `curl -fsSL https://get.docker.com | sh`
- Mac/Windows: instale o **Docker Desktop**.

### 2.2. Baixar o projeto
```bash
git clone https://github.com/rafaelcs28/haval-ecotrip.git
cd haval-ecotrip/bridge
```

### 2.3. Configurar o `.env`
```bash
cp .env.example .env
nano .env        # ou seu editor preferido
```
Preencha o essencial:

| Campo | O que pôr |
|---|---|
| `MQTT_HOST` | `mqtt://mosquitto` (se usar o broker do Docker abaixo) ou o host do seu broker |
| `MQTT_PORT` | `1883` |
| `MQTT_USER` / `MQTT_PASS` | usuário/senha do broker (recomendado) |
| `MQTT_PREFIX` | `haval/ecotrip` (anote — vai usar **igual** no carro) |
| `BRIDGE_TOKEN` | **senha de acesso** ao app. Gere uma forte (abaixo) |
| `GWM_CHASSI` | chassi do carro (`lgw`+14). Opcional — dá pra pôr depois na PWA |
| `PORT` | `3000` (HTTP) |

Gerar uma senha forte pro `BRIDGE_TOKEN`:
```bash
node -e "console.log(require('crypto').randomBytes(24).toString('hex'))"
```
> Guarde essa senha — é ela que você digita no tablet e no celular.

### 2.4. Ligar o broker Mosquitto (se não tiver um)
No `docker-compose.yml`, **descomente** o bloco `mosquitto:` (está comentado no fim do arquivo). Depois crie a config mínima:

```bash
mkdir -p mosquitto/config mosquitto/data mosquitto/log
cat > mosquitto/config/mosquitto.conf <<'EOF'
listener 1883
persistence true
persistence_location /mosquitto/data/
password_file /mosquitto/config/passwd
EOF
# cria o usuário (troque USUARIO/SENHA — os mesmos do .env e do carro)
docker run --rm -v "$PWD/mosquitto/config:/mosquitto/config" eclipse-mosquitto:2 \
  mosquitto_passwd -b -c /mosquitto/config/passwd USUARIO SENHA
```
> Se você **já tem** um broker (ex. o do Home Assistant), pule isto e aponte `MQTT_HOST` pra ele.

### 2.5. Subir
```bash
docker compose up -d --build
docker compose logs -f bridge      # acompanha (Ctrl+C pra sair)
```
Teste no navegador da mesma rede: `http://IP-DO-SERVIDOR:3000` → deve pedir login (a senha do `BRIDGE_TOKEN`).

> **Atualizar depois:** `git pull && docker compose up -d --build`
> **Parar:** `docker compose down`

---

## 3. App no carro (APK do Haval)

### 3.1. Shizuku (acesso aos dados do carro)
O app lê os dados do carro via **Shizuku**. Na multimídia do Haval:
1. Instale o **Shizuku** (Play Store / APK).
2. Ative a **Depuração sem fio** (Opções do desenvolvedor) e **inicie o Shizuku** por ela (ou via ADB). O Shizuku precisa estar **rodando** pro app funcionar.

### 3.2. Instalar o app do carro
1. Na multimídia, abra: `https://github.com/rafaelcs28/haval-ecotrip/releases` → baixe o **APK mais recente** (ex. `ecotrip-impulse-vX.YZ-bNN.apk`).
2. Permita **instalar de fontes desconhecidas** e instale.

### 3.3. Apontar pro seu broker
No app do carro → **Ajustes → MQTT**:

| Campo | Valor |
|---|---|
| **Host** | IP/DDNS do seu broker |
| **Porta** | `1883` (ou `8883` se usar TLS) |
| **TLS** | desligado p/ LAN local · ligado se broker exposto na internet |
| **Usuário / Senha** | os do Mosquitto (Parte 2.4) |
| **Prefixo** | **o mesmo** do `.env` (`haval/ecotrip`) |

Salve. Em segundos o servidor começa a receber a telemetria.

> **Local vs remoto:** se o carro fica na sua rede Wi‑Fi (garagem), use o **IP local** do servidor — simples e rápido. Pra funcionar **na rua** (4G), o broker precisa estar **exposto na internet com TLS** (porta 8883 + certificado) — veja a Parte 6.

---

## 4. Tablet — app do cluster (APK)

1. No tablet, baixe o APK do cluster: `https://github.com/rafaelcs28/haval-ecotrip/releases` → tag **`cluster-vX.Y`** (mais recente).
2. Permita fontes desconhecidas e instale o **Haval Cluster**.
3. Abra → toque no **⚙** (canto superior direito) → preencha:
   - **Base URL:** `http://IP-DO-SERVIDOR:3000` (mesma rede) ou a URL Tailscale (remoto).
   - **Senha:** a senha do `BRIDGE_TOKEN`.
4. Salvar. O cluster carrega.
   - **LAN direta:** se o tablet estiver na **mesma rede do carro**, ele acha o carro sozinho (mDNS) e fica em tempo real (~10 fps). Em ⚙ aparece o status da LAN.
   - **Atualizar o app depois:** ⚙ → **Atualizar app** (baixa a versão nova do GitHub sozinho).

---

## 5. Celular — PWA

1. Abra no navegador: `http://IP-DO-SERVIDOR:3000` (ou a URL Tailscale).
2. **Entre** com a senha (`BRIDGE_TOKEN`).
3. **Adicionar à tela inicial** (menu do navegador) → vira um app.

> Notificações push da PWA funcionam em HTTPS (Parte 6). Em HTTP simples, a PWA funciona mas sem push.

---

## 6. Acesso remoto (fora de casa) — Tailscale (recomendado)

Pra usar o app **longe de casa** sem abrir portas no roteador:
1. Instale o **Tailscale** no servidor e nos seus aparelhos (mesma conta).
2. Use a URL do servidor na tailnet (ex. `https://meu-servidor.tailXXXX.ts.net`) como **Base URL** no tablet/PWA.
3. (Opcional) **Tailscale Funnel** ou um **DDNS + Let's Encrypt** dão **HTTPS** público — necessário pro **carro na rua** (broker TLS 8883) e pra **push da PWA**.

> Mínimo viável: tudo na **rede de casa** (HTTP local) funciona 100% sem nada disso. Tailscale só entra pra acessar de fora.

---

## 7. Backup, atualização e problemas

- **Backup:** todos os dados ficam em `bridge/` (autotrips, recargas, configs). Backup = copiar essa pasta. Há também `scripts/backup.sh`.
- **Atualizar o servidor:** `cd haval-ecotrip && git pull && cd bridge && docker compose up -d --build`.
- **Atualizar APKs:** carro = baixar a release nova; tablet = ⚙ → Atualizar app.

**Não conecta / "offline":**
- O **prefixo MQTT** está **idêntico** no carro e no `.env`? (causa nº 1)
- O carro alcança o **host/porta** do broker? (mesma rede, ou TLS exposto se remoto)
- `docker compose logs -f bridge` mostra mensagens MQTT chegando?
- A **Base URL** no tablet/PWA está certa e a **senha** confere?

**Tablet "carro offline" mas dados no servidor ok:** confira se a Base URL é a do **bridge** (porta 3000), não a do broker MQTT.

---

Pronto. Resumo do que cada um instala:
- **Servidor:** `docker compose up` (bridge + Mosquitto).
- **Carro:** APK + Shizuku + Ajustes→MQTT apontando pro seu broker.
- **Tablet:** APK do cluster + ⚙ (Base URL + senha).
- **Celular:** PWA (abrir a URL + login + adicionar à tela).
