# Haval EcoTrip — App iOS companion (Live Activity)

App Swift mínimo cujo único papel é hospedar uma **Live Activity** no iPhone
que mostra a recarga em tempo real (SOC, potência, energia, tempo restante)
no lock screen e no Dynamic Island.

O bridge (Mac mini) atualiza a Live Activity via **APNs HTTP/2 push direto**
— o app pode estar morto, basta o iPhone estar online.

Tudo grátis: Apple ID free, Xcode (gratuito), AltStore pra reinstalar
automaticamente quando o sideload expirar em 7 dias.

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

### 3. Gerar AuthKey APNs (grátis)

> Apple permite gerar Authentication Key APNs com qualquer Apple ID, sem
> precisar da assinatura paga.

1. Abre <https://developer.apple.com/account/resources/authkeys/list>
2. Sign In com sua Apple ID
3. Toca em **+** (criar key)
4. Marca **Apple Push Notifications service (APNs)**
5. Nome: `EcoTrip APNs` → Continue → Register
6. Baixa o arquivo `AuthKey_XXXXXXXXXX.p8` (XXXXXXXXXX = Key ID, 10 chars)
7. Anota o **Key ID** (na página) e o **Team ID** (canto superior direito)
8. Move o `.p8` pra `/Users/consorciolimpagyn/haval-ecotrip/bridge/`:
   ```
   mv ~/Downloads/AuthKey_*.p8 /Users/consorciolimpagyn/haval-ecotrip/bridge/
   ```

> ⚠ O `.p8` só pode ser baixado uma vez. Guarda backup.

### 4. Configurar o bridge com APNs

Edita `/Users/consorciolimpagyn/haval-ecotrip/bridge/.env`:

```
APNS_ENABLED=true
APNS_TEAM_ID=ABCDE12345
APNS_KEY_ID=AAAA1111BB
APNS_BUNDLE_ID=br.com.consorciolimpagyn.havalecotrip
APNS_KEY_P8_PATH=/Users/consorciolimpagyn/haval-ecotrip/bridge/AuthKey_AAAA1111BB.p8
APNS_ENV=sandbox
```

(Bundle ID deve bater com o do projeto Xcode — já é esse por padrão.)

Reinicia:
```
pm2 restart ecotrip-bridge
pm2 logs ecotrip-bridge --lines 5
# espera ver: [apns] pronto · team=… bundle=… env=sandbox tokens=0
```

### 5. Abrir o projeto no Xcode

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

### 6. Conectar o iPhone e Run

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

### 7. Renovação automática via AltStore (opcional)

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

## Como o fluxo end-to-end funciona

```
1. User toca "Iniciar Live Activity" no app
   ↓
2. iOS gera pushToken pra essa Activity
   ↓
3. App envia (pushToken, activityId) → POST /api/activity/start no bridge
   ↓
4. Bridge salva em activity_tokens.json
   ↓
5. Carro começa a carregar (charging_state vira "Carregando")
   ↓
6. Bridge chama sendChargeLiveUpdate() a cada 60s ou em mudança significativa
   ↓
7. sendChargeLiveUpdate() faz:
   - sendPush (Web Push pro PWA — já existia)
   - apnsLive.pushUpdate (APNs HTTP/2 pra todos os pushTokens iOS)
   ↓
8. iPhone recebe push da Apple → atualiza Live Activity SEM acordar o app
   ↓
9. Recarga termina → manda event=end + alerta com som
```

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
