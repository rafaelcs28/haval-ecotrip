# Haval EcoTrip — App iOS companion (Live Activity)

App Swift mínimo cujo único papel é hospedar uma **Live Activity** no iPhone
que mostra a recarga em tempo real (SOC, potência, energia, tempo restante)
no lock screen e no Dynamic Island.

O bridge (Mac mini) atualiza a Live Activity via **APNs HTTP/2 push direto**
— o app pode estar morto, basta o iPhone estar online.

Tudo grátis: free Apple Developer account, Xcode no Mac mini, AltStore pra
reinstalar automaticamente quando o sideload expirar em 7 dias.

---

## Estrutura dos arquivos neste diretório

```
ios-app/
├── HavalEcoTrip/                           # app principal (target iOS)
│   ├── HavalEcoTripApp.swift
│   ├── ContentView.swift
│   ├── Settings.swift
│   ├── ActivityManager.swift
│   └── Info-additions.plist               # chaves pra somar no Info.plist
└── HavalEcoTripWidget/                     # widget extension target
    ├── ChargeActivityAttributes.swift     # SHARED com o app — marcar ambos
    ├── ChargeActivityLiveActivity.swift   # layouts lock screen + Dynamic Island
    └── HavalEcoTripWidgetBundle.swift     # @main do widget bundle
```

---

## 1. Criar o projeto no Xcode

1. **Abre Xcode** no Mac mini → "Create New Project…"
2. **iOS → App** → Next
3. Configura:
   - Product Name: `HavalEcoTrip`
   - Team: a sua Apple ID free (vai aparecer depois de fazer Sign In na
     aba Xcode → Settings → Accounts)
   - Bundle Identifier: `br.com.consorciolimpagyn.havalecotrip` (qualquer
     reverse-DNS único — só não pode bater com app na App Store)
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Storage / Tests: desmarcados
4. Salva em `~/Developer/HavalEcoTrip` (qualquer lugar fora do repo).
5. **Adiciona o target da Widget Extension:**
   - File → New → Target… → iOS → **Widget Extension**
   - Product Name: `HavalEcoTripWidget`
   - **Marca** "Include Live Activity"
   - Bundle ID vai virar `br.com.consorciolimpagyn.havalecotrip.HavalEcoTripWidget`
6. Apaga os arquivos boilerplate que o Xcode criou (`ContentView.swift`,
   `HavalEcoTripApp.swift`, e tudo dentro de `HavalEcoTripWidget/`) — vamos
   substituir pelos nossos.

## 2. Copiar os arquivos deste repo

Arrasta os arquivos `.swift` daqui pros targets correspondentes no Xcode:

- `HavalEcoTrip/*.swift` → target **HavalEcoTrip** (marcar Target Membership)
- `HavalEcoTripWidget/HavalEcoTripWidgetBundle.swift` → target
  **HavalEcoTripWidget**
- `HavalEcoTripWidget/ChargeActivityLiveActivity.swift` → target
  **HavalEcoTripWidget**
- `HavalEcoTripWidget/ChargeActivityAttributes.swift` → **AMBOS** os targets
  (Target Membership: ✅ HavalEcoTrip ✅ HavalEcoTripWidget)

## 3. Editar o `Info.plist` do app principal

Abre `Info.plist` do target HavalEcoTrip e adiciona estas duas chaves
(copia do arquivo `Info-additions.plist`):

```xml
<key>NSSupportsLiveActivities</key>
<true/>
<key>NSSupportsLiveActivitiesFrequentUpdates</key>
<true/>
```

Sem isso, `Activity.request()` joga `activitiesEnabled is false`.

## 4. Criar o AuthKey APNs (grátis)

> A Apple permite gerar **AuthKey APNs** com qualquer Apple ID, sem precisar
> da assinatura paga de US$ 99/ano.

1. Abre <https://developer.apple.com/account/resources/authkeys/list>
2. Faz Sign In com sua Apple ID
3. Toca em **+** (criar key)
4. Marca **Apple Push Notifications service (APNs)**
5. Nome: `EcoTrip APNs` → Continue
6. Baixa o arquivo **`AuthKey_XXXXXXXXXX.p8`** (XXXXXXXXXX = Key ID, 10 chars)
7. Anota o **Key ID** e o **Team ID** (canto superior direito da página)
8. Copia o `.p8` pro Mac mini, em `/Users/consorciolimpagyn/haval-ecotrip/bridge/`

> ⚠ O `.p8` só pode ser baixado uma vez. Guarda em backup.

## 5. Configurar o bridge

Edita `bridge/.env` (cria se não existir):

```
APNS_ENABLED=true
APNS_TEAM_ID=ABCDE12345
APNS_KEY_ID=AAAA1111BB
APNS_BUNDLE_ID=br.com.consorciolimpagyn.havalecotrip
APNS_KEY_P8_PATH=/Users/consorciolimpagyn/haval-ecotrip/bridge/AuthKey_AAAA1111BB.p8
APNS_ENV=sandbox
```

> **Importante**: free dev account = sempre `APNS_ENV=sandbox`. Sandbox é
> totalmente funcional; só não distribui pela App Store. Se um dia pagar a
> assinatura, muda pra `production` (a mesma key funciona nos dois).

Reinicia o bridge:

```
pm2 restart ecotrip-bridge
pm2 logs ecotrip-bridge --lines 5
# deve aparecer: [apns] pronto · team=… bundle=… env=sandbox tokens=0
```

## 6. Build e sideload no iPhone

1. Conecta o iPhone no Mac via cabo (Trust This Computer)
2. No Xcode, no menu de devices (top bar), seleciona o seu iPhone
3. Cmd+R pra fazer build + install
4. Primeira vez: iPhone vai pedir confirmação em **Ajustes → Geral →
   Gerenciamento de VPN e Dispositivos → seu Apple ID → Confiar**
5. App abre. Preenche:
   - **URL**: `https://mac-mini.tailacc6e7.ts.net`
   - **Token**: pega do PWA — abre <https://mac-mini.tailacc6e7.ts.net>
     no Safari, ativa "Inspecionar Web" no Mac, console: `localStorage.bridge_token`
6. Toca em **Iniciar Live Activity**
7. Bloqueia o iPhone — a activity deve aparecer no lock screen
8. Quando o carro começar a carregar, os dados começam a chegar via APNs.

## 7. Renovação automática via AltStore (opcional mas recomendado)

App sideloaded com free account **expira em 7 dias**. Pra reinstalar
automaticamente:

1. Baixa **AltStore**: <https://altstore.io>
2. Instala o AltServer no Mac mini
3. Roda o AltServer em background (login automático)
4. Pareia o iPhone com o AltStore (Wi-Fi sync)
5. AltStore reassina o app a cada 7 dias quando o iPhone está na mesma
   rede do Mac. Sem fazer nada.

Alternativa manual: simplesmente abrir o Xcode e fazer Cmd+R toda semana.

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
   - apnsLive.pushUpdate (NOVO: APNs HTTP/2 pra todos os pushTokens)
   ↓
8. iPhone recebe push da Apple → atualiza Live Activity SEM acordar o app
   ↓
9. Recarga termina → manda event=end + alerta com som
```

---

## Limitações conhecidas

- **Free account sideload expira em 7 dias** — use AltStore
- **iOS limita Live Activities a ~8h ativas** — Apple decide se prolonga
  com base em recência de updates. Recargas de >8h podem ser cortadas;
  o bridge envia um novo `event:end` quando termina pra encerrar limpo.
- **Sandbox APNs pode ter latência ~5s** ocasionalmente
- **iOS 16.1+ obrigatório** pra Live Activities; iOS 17+ pra Dynamic Island
  no iPhone 14 Pro / 15 / 15 Pro
- **Múltiplos iPhones**: cada um chama `/api/activity/start` com seu
  próprio pushToken. O bridge envia atualização pra todos.

## Troubleshooting

| Sintoma | Causa provável | Fix |
|---|---|---|
| "Activity já ativa" mas nada na lock screen | Activity stale | Toque em "Parar" e depois "Iniciar" |
| `activitiesEnabled is false` | Falta `NSSupportsLiveActivities` no Info.plist | Item 3 acima |
| `[apns] HTTP 403 InvalidProviderToken` | Team ID, Key ID, ou .p8 errado | Confere `.env` e o caminho do `.p8` |
| `[apns] HTTP 400 BadDeviceToken` | Sandbox/production mismatch | Free account = sandbox; muda `APNS_ENV` |
| `[apns] HTTP 410 Unregistered` | Push token expirou (normal) | Bridge remove sozinho; user toca "Iniciar" de novo |
| App não compila — "Live Activity requires…" | iOS deployment target < 16.1 | Project → Build Settings → iOS Deployment Target → 16.1 |
