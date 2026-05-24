# Haval EcoTrip — App iOS companion (Live Activity)

App Swift mínimo cujo único papel é hospedar uma **Live Activity** no iPhone
que mostra a recarga em tempo real (SOC, potência, energia, tempo restante)
no lock screen e no Dynamic Island.

**Modo atual: app-driven (grátis)** — o app faz polling do bridge a cada 5s
e atualiza a Live Activity localmente via `Activity.update()`. Funciona
perfeito enquanto o iPhone está desbloqueado / app em foreground. Quando
bloqueia, iOS pode matar o app em ~30s e a Activity congela com o último
estado até o user desbloquear.

**Pra ter push remoto** (Activity atualiza com o app morto), precisa de
Apple Developer Program pago (US$ 99/ano) pra gerar AuthKey APNs. O
backend do bridge (`apns_live_activity.js`) já está pronto pra esse modo
— basta trocar `pushType: nil` por `.token` no `ActivityManager.swift` e
configurar `APNS_*` no `.env` da bridge. Free Apple ID NÃO consegue criar
AuthKeys APNs.

Custo no modo atual: R$ 0. Apple ID free, Xcode (gratuito), AltStore pra
reinstalar automaticamente quando o sideload expirar em 7 dias.

---

## Pra você (o amador): o que precisa fazer manualmente

> Só essas etapas exigem suas mãos. O projeto Xcode JÁ está pronto.

### 1. Instalar o Xcode (Mac App Store)

1. Abre o **App Store** no Mac mini
2. Busca por **Xcode** → **Get** / **Instalar** (~10 GB, demora 30-60 min)
3. Depois de instalar, abre o Xcode uma vez pra aceitar os termos
4. No terminal, roda:
   ```
   sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   ```

### 2. Logar a Apple ID no Xcode

1. Abre o Xcode → **Settings…** → **Accounts** (Cmd+,)
2. Toca em **+** → **Apple ID** → digita seu Apple ID e senha
3. Espera aparecer "Personal Team" na lista — é a free dev account

### 3. Abrir o projeto no Xcode

```
open /Users/consorciolimpagyn/haval-ecotrip/ios-app/HavalEcoTrip.xcodeproj
```

No Xcode:

1. Clica no nome do projeto (raiz, ícone azul) → aba **Signing & Capabilities**
2. Pro target **HavalEcoTrip**: marca **Automatically manage signing** e
   seleciona seu **Team** (vai aparecer "Your Name (Personal Team)")
3. Pro target **HavalEcoTripWidget**: mesma coisa
4. Se aparecer erro "Failed to register bundle identifier", muda o
   bundle ID pra outro reverse-DNS único (ex:
   `br.com.consorciolimpagyn.havalecotrip2`). E atualiza no `.env` também.

### 4. Conectar o iPhone e Run

1. Conecta o iPhone no Mac via cabo
2. iPhone vai pedir "Trust This Computer" — confirma
3. No Xcode, no menu de devices (top bar), seleciona seu iPhone
4. **Cmd+R** pra fazer build + install
5. **Primeiro install só:** no iPhone vai aparecer "Untrusted Developer".
   Ajustes → Geral → Gerenciamento de VPN e Dispositivos → seu Apple ID
   → **Confiar**
6. Abre o app no iPhone, preenche:
   - **URL**: `https://mac-mini.tailacc6e7.ts.net`
   - **Token**: pega do PWA (abre o PWA no Safari iPhone, ativa Web
     Inspector pelo Mac em Safari → Develop → seu iPhone → console:
     `localStorage.bridge_token`)
7. Toca **Iniciar Live Activity**
8. Bloqueia o iPhone — a activity deve aparecer no lock screen
9. Quando o carro carregar, os updates começam a chegar via APNs.

### 5. Renovação automática via AltStore (opcional)

Free sideload expira em 7 dias. AltStore reassina automaticamente quando
o iPhone está na mesma WiFi do Mac:

1. <https://altstore.io> → baixa AltServer pro Mac
2. Instala, segue o wizard de pareamento com o iPhone
3. Roda AltServer em background no Mac mini
4. Dali pra frente: a cada 7 dias o app é reassinado sozinho

Alternativa: simplesmente abrir Xcode e Cmd+R toda semana.

---

## O que JÁ está pronto no projeto

```
ios-app/
├── HavalEcoTrip.xcodeproj/         # ← projeto Xcode pronto (gerado por XcodeGen)
├── project.yml                     # spec do XcodeGen (regen com: xcodegen generate)
├── HavalEcoTrip/                   # target app principal
│   ├── HavalEcoTripApp.swift
│   ├── ContentView.swift
│   ├── Settings.swift
│   ├── ActivityManager.swift
│   └── Info.plist                  # ← gerado, já tem NSSupportsLiveActivities
└── HavalEcoTripWidget/             # target Widget Extension
    ├── ChargeActivityAttributes.swift   # shared com app (membership dupla configurada)
    ├── ChargeActivityLiveActivity.swift # layouts lock screen + Dynamic Island
    ├── HavalEcoTripWidgetBundle.swift
    └── Info.plist
```

Configuração já incluída:
- Bundle ID: `br.com.consorciolimpagyn.havalecotrip`
- Bundle ID widget: `br.com.consorciolimpagyn.havalecotrip.HavalEcoTripWidget`
- Deployment target: iOS 16.1 (mínimo pra ActivityKit)
- `NSSupportsLiveActivities` no Info.plist
- ChargeActivityAttributes nos DOIS targets (membership configurada)
- Bridge endpoints `/api/activity/start` e `/api/activity/stop`
- Bridge `apns_live_activity.js` (cliente APNs HTTP/2 zero-deps)

## Re-gerar o projeto Xcode (se editar Swift fora do Xcode)

Se você editar arquivos `.swift` pelo VSCode ou similar e quiser que o Xcode
reconheça mudanças estruturais (arquivos novos, target membership):

```
brew install xcodegen     # uma vez
cd ios-app
xcodegen generate
```

O `.xcodeproj` é regenerado preservando settings de Signing.

---

## Como o fluxo end-to-end funciona (modo app-driven)

```
1. User toca "Iniciar Live Activity" no app
   ↓
2. App cria a Activity localmente (pushType: nil)
   ↓
3. App inicia loop de polling a cada 5s
   ↓
4. Loop: GET /api/state → pega charging_state, soc_pct, charge_power_kw,
   charge_session_kwh, charge_remaining_min
   ↓
5. App chama Activity.update(contentState) localmente
   ↓
6. Live Activity atualiza na lock screen / Dynamic Island
   ↓
7. Quando user toca "Parar" → Activity.end()
```

**Limitação**: enquanto o iPhone está desbloqueado / app em foreground,
updates de 5 em 5s. Quando o iPhone bloqueia, iOS suspende o app em ~30s
e os updates param — a Activity continua exibida com o ÚLTIMO estado
até o user desbloquear. Pra ter updates contínuos com app morto, precisa
do programa Developer pago (APNs push).

---

## Limitações conhecidas

- **Free account sideload expira em 7 dias** — use AltStore
- **iOS limita Live Activities a ~8h ativas** — Apple decide se prolonga
  com base em recência de updates. Recargas longas podem ser cortadas;
  bridge envia novo `event:end` quando termina pra encerrar limpo.
- **Sandbox APNs pode ter latência ~5s** ocasionalmente
- **iOS 16.1+ obrigatório**; iOS 17+ pra Dynamic Island no iPhone 14 Pro/15
- **Múltiplos iPhones**: cada um chama `/api/activity/start` com seu
  pushToken. Bridge envia atualização pra todos.

## Troubleshooting

| Sintoma | Causa provável | Fix |
|---|---|---|
| "Activity já ativa" mas nada na lock screen | Activity stale | Toca "Parar" e depois "Iniciar" |
| Build erro: "Signing for HavalEcoTrip requires a development team" | Team não selecionado | Item 5 acima |
| `[apns] HTTP 403 InvalidProviderToken` | Team ID, Key ID, ou .p8 errado | Confere `.env` |
| `[apns] HTTP 400 BadDeviceToken` | Sandbox/production mismatch | Free = sandbox; muda `APNS_ENV` |
| `[apns] HTTP 410 Unregistered` | Push token expirou (normal) | Bridge remove sozinho; toca "Iniciar" de novo |
