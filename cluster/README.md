# Haval Cluster — app Android (tablet)

App Android que roda o **cluster** (o mesmo painel do iPad) numa WebView fullscreen, consumindo o **bridge**. Pensado pra um tablet fixo no carro/casa, mas se adapta a qualquer tela (incl. dobráveis).

## O que faz
- **WebView kiosk** (fullscreen, landscape, tela sempre ligada) carregando o `cluster.html` empacotado.
- **Dados do bridge** por **2 caminhos**:
  - **Cloud** (HTTP/HTTPS) — sempre; traz também os campos enriquecidos (mapa/GPS, viagem em curso, preços, autonomia).
  - **LAN direta** — descobre o carro por **mDNS** (`_havalobd._tcp`) e usa `ws://host:port/ws/state` (~10 fps, sem latência). Cai pro cloud quando fora da rede do carro.
- **Comandos** (A/C, modo, pisca‑alerta, etc.) via LAN quando conectado, senão por POST no bridge.
- **Fit‑scaling adaptativo** — escala o painel pra caber em qualquer tela, preservando proporção.
- **Auto‑update** — ⚙ → "Atualizar app" baixa a versão nova do GitHub (tags `cluster-vX.Y`).

## Instalar (usuário)
1. Baixe o APK em [Releases](https://github.com/rafaelcs28/haval-ecotrip/releases) → tag **`cluster-vX.Y`** (a mais recente).
2. Permita **instalar de fontes desconhecidas** e instale.
3. Abra → **⚙** (canto superior direito) → preencha:
   - **Base URL:** `http://IP-DO-SERVIDOR:3000` (mesma rede) ou a URL Tailscale (remoto).
   - **Senha:** a do `BRIDGE_TOKEN` do servidor (a mesma do PWA).
4. Salvar. (Daí pra frente, atualize por **⚙ → Atualizar app**.)

## Compilar
```bash
# na raiz do repo (precisa do Android SDK; JAVA_HOME = openjdk 17)
export JAVA_HOME=".../openjdk@17/.../Home"
./gradlew :cluster:assembleRelease
# APK em: cluster/build/outputs/apk/release/cluster-release.apk
```
Assinatura: usa o mesmo `local.properties` do módulo do carro
(`SIGNING_STORE_FILE`, `SIGNING_STORE_PASSWORD`, `SIGNING_KEY_ALIAS`, `SIGNING_KEY_PASSWORD`).

## Como funciona por dentro
- `MainActivity.kt` — WebView + config (SharedPreferences) exposta ao JS via `window.AndroidCfg`
  (`getBridgeUrl`, `getPassword`, `getLanWsUrl`), descoberta mDNS (NsdManager) e auto‑update.
- `assets/web/cluster.html` — cópia do cluster do iPad, com `<script android-shim.js>` injetado.
- `assets/web/android-shim.js` — a ponte: finge o `webkit.messageHandlers.obd` (pra o cluster
  rodar em modo "nativo"), faz poll `/api/state` + conexão LAN ws, traduz comandos pros endpoints
  do bridge, e aplica o fit‑scaling + tema escuro do mapa.

> Atualizar o `cluster.html` quando o do iPad mudar: copie de `ios-obd/HavalOBD/WebAssets/cluster.html`
> pra `cluster/src/main/assets/web/cluster.html` e re‑injete a linha `<script src="android-shim.js"></script>`
> (antes do `<link ... leaflet.css>`).
