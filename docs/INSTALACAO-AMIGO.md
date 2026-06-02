# Haval EcoTrip — Guia de Instalação (servidor próprio)

Guia completo pra rodar **tudo na sua casa/carro**, com **seu próprio servidor**. No fim você terá:

- 🖥️ **Servidor** (bridge + broker MQTT) na sua máquina (PC, mini‑PC, NAS…).
- 📱 **PWA no celular** — onde você **configura tudo** e gera o **código de pareamento**.
- 🚗 **App no carro (APK)** — você só **digita o código** e ele se configura sozinho.
- 📟 **App no tablet (cluster)** — o painel grande.

> Não usa o app do BYD nem Apple Push. Tudo funciona com PWA + cluster.

---

## 0. Como as peças conversam

```
  🚗 Carro (APK)  ──MQTT──►  📡 Broker (Mosquitto)  ◄──MQTT──  🖥️ Bridge (servidor)
                                                                     ▲ HTTP/HTTPS
                                          📱 Celular (PWA)     ──────┤  (config + pareamento)
                                          📟 Tablet (cluster)  ──────┘
```

- O **carro publica** a telemetria no **broker**; o **bridge** lê e serve a interface.
- Você **configura pelo celular** (PWA) e **pareia o carro por um código** — não digita broker no carro.
- **Regra de ouro:** o **prefixo MQTT** (`haval/ecotrip`) é o mesmo em todo lugar (o pareamento já cuida disso no carro).

---

## 1. Pré‑requisitos
- Uma máquina **sempre ligada** pro servidor (Docker — Linux/Mac/Windows; mini‑PC/NAS ideal).
- Carro **Haval/GWM compatível** com o app + **Shizuku** (Parte 4).
- **Celular** e **tablet Android**.
- (Opcional, acesso remoto) conta **Tailscale** grátis.

---

## 2. Servidor (bridge + broker) — Docker

### 2.1. Docker
- Linux: `curl -fsSL https://get.docker.com | sh`
- Mac/Windows: **Docker Desktop**.

### 2.2. Baixar o projeto
```bash
git clone https://github.com/rafaelcs28/haval-ecotrip.git
cd haval-ecotrip/bridge
cp .env.example .env
```

### 2.3. Editar o `.env`
```bash
nano .env
```
| Campo | O que pôr |
|---|---|
| `MQTT_HOST` | `mqtt://mosquitto` (broker do Docker) ou o host do seu broker |
| `MQTT_PORT` | `1883` |
| `MQTT_USER` / `MQTT_PASS` | usuário/senha do broker |
| `MQTT_PREFIX` | `haval/ecotrip` |
| `BRIDGE_TOKEN` | **senha de acesso** ao app (gere forte — abaixo) |
| `BRIDGE_PUBLIC_URL` | URL externa do servidor (ex. Tailscale `https://meu-servidor.tailXXXX.ts.net`). **Vai no pareamento** pro carro mandar dados de fim de viagem |
| `CAR_MQTT_HOST` / `CAR_MQTT_PORT` / `CAR_MQTT_TLS` | endereço do broker que o **carro** usa pela internet (DDNS/IP público + porta). Deixe vazio se o carro fica só na sua rede |
| `GWM_CHASSI` | chassi (`lgw`+14). Opcional aqui — dá pra pôr no PWA |

Senha forte: `node -e "console.log(require('crypto').randomBytes(24).toString('hex'))"`

### 2.4. Broker Mosquitto (se não tiver um)
No `docker-compose.yml`, **descomente** o bloco `mosquitto:` (no fim do arquivo) e crie a config:
```bash
mkdir -p mosquitto/config mosquitto/data mosquitto/log
cat > mosquitto/config/mosquitto.conf <<'EOF'
listener 1883
persistence true
persistence_location /mosquitto/data/
password_file /mosquitto/config/passwd
EOF
docker run --rm -v "$PWD/mosquitto/config:/mosquitto/config" eclipse-mosquitto:2 \
  mosquitto_passwd -b -c /mosquitto/config/passwd USUARIO SENHA
```
> Já tem broker (ex. do Home Assistant)? Pule e aponte `MQTT_HOST` pra ele.

### 2.5. Subir
```bash
docker compose up -d --build
docker compose logs -f bridge
```
Teste: `http://IP-DO-SERVIDOR:3000` → pede a senha (`BRIDGE_TOKEN`).
> **Atualizar:** `git pull && docker compose up -d --build` · **Parar:** `docker compose down`

---

## 3. Celular (PWA) — configurar e gerar o código

1. Abra `http://IP-DO-SERVIDOR:3000` (ou a URL Tailscale) → **entre** com a senha.
2. **Adicionar à tela inicial** (vira app).
3. **Ajustes → Veículo / 📡 Conexão** e preencha:
   - **Chassi** do carro (`lgw`+14).
   - **Broker** (host/porta/usuário/senha/**prefixo** `haval/ecotrip`/TLS) — o que sua instância usa pra ler.
   - **📡 Broker público (pro carro no 4G)** — o endereço que o **carro** alcança pela internet (DDNS/IP + porta). É o que vai no pareamento. (Se o carro fica só na sua rede, pode repetir o host local.)
   - **Home Assistant** (URL + token) — *opcional*, só pra comandos remotos (motor, pré‑clima) e estados iniciais.
4. **📲 Parear o carro → "Gerar código de pareamento"** → anote o código de **6 caracteres** (vale 10 min).

> O pareamento empacota **broker + senha + URL do bridge** num código. O carro busca tudo sozinho — você nunca digita broker/senha no carro.

---

## 4. Carro (APK) — instalar e parear

### 4.1. Shizuku (acesso aos dados do carro)
Na multimídia do Haval: instale o **Shizuku**, ligue a **Depuração sem fio** e **inicie o Shizuku** por ela. Ele precisa estar **rodando** pro app ler o CAN do carro.

### 4.2. Instalar o app
Na multimídia, abra `https://github.com/rafaelcs28/haval-ecotrip/releases` → baixe o **APK mais recente** → permita **fontes desconhecidas** → instale.

### 4.3. Parear (sem digitar broker!)
No app do carro → **Ajustes → Parear** → digite o **código** gerado no celular (Parte 3.4) → confirmar.
O carro baixa a config (broker, senha, prefixo, URL do bridge) e começa a publicar. Em segundos o servidor recebe a telemetria.

> **Local vs 4G:** se o carro fica na sua rede Wi‑Fi, o broker local basta. Pra funcionar **na rua**, o broker precisa estar **exposto com TLS** (porta 8883 + certificado) e o `CAR_MQTT_*` apontando pra ele — veja a Parte 6.

---

## 5. Tablet — app do cluster (APK)
1. No tablet: `https://github.com/rafaelcs28/haval-ecotrip/releases` → tag **`cluster-vX.Y`** (mais recente) → instale.
2. Abra → **⚙** (canto sup. direito) → **Base URL** = `http://IP-DO-SERVIDOR:3000` (ou Tailscale) + **Senha** (`BRIDGE_TOKEN`) → Salvar.
3. **LAN direta:** na mesma rede do carro, o tablet acha o carro sozinho (mDNS) e fica em tempo real. **Atualizar:** ⚙ → Atualizar app.

---

## 6. Acesso remoto (fora de casa) — Tailscale
1. Instale o **Tailscale** no servidor e nos aparelhos (mesma conta).
2. Use a URL da tailnet (ex. `https://meu-servidor.tailXXXX.ts.net`) como **Base URL** (tablet/PWA) e em **`BRIDGE_PUBLIC_URL`** no `.env`.
3. (Opcional) **Funnel** ou **DDNS + Let's Encrypt** dão HTTPS público — necessário pro **carro na rua** (broker TLS 8883) e pro **push da PWA**.
> Tudo na **rede de casa** (HTTP local) funciona 100% sem isso. Tailscale só entra pra acessar de fora.

---

## 7. Backup, atualização e problemas
- **Backup:** dados ficam em `bridge/` (viagens, recargas, configs). Backup = copiar a pasta (ou `scripts/backup.sh`).
- **Atualizar servidor:** `git pull && docker compose up -d --build`. **APK carro:** baixar release nova. **Tablet:** ⚙ → Atualizar app.

**"offline" / não conecta:**
- Gerou e digitou o **código de pareamento** no carro? (código expira em 10 min)
- O **carro alcança o broker** (host/porta certos; TLS se remoto)?
- `docker compose logs -f bridge` mostra MQTT chegando?
- **Base URL** + **senha** no tablet/PWA conferem? (Base URL = bridge na porta 3000, **não** o broker)

---

### Resumo do que cada um faz
- **Servidor:** `docker compose up` (bridge + Mosquitto) + `.env`.
- **Celular (PWA):** configura Veículo/Conexão → **gera o código de pareamento**.
- **Carro:** APK + Shizuku → **Ajustes → Parear → digita o código**.
- **Tablet:** APK do cluster → ⚙ (Base URL + senha).
