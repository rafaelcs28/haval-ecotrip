# Handoff pro Impulse — expor conectividade sem depender da assinatura

O EcoTrip implementou o consumo conforme o handoff original, mas o `query` volta
`SecurityException`: **as keystores dos dois apps são diferentes**, e a permissão
`READ_CONNECTIVITY_STATUS` é `signature`. Confirmado em 31/07/2026 — o EcoTrip
publica os dois digests em `uplink/status` pra provar.

Reassinar um dos apps resolveria, mas quebra a atualização in-place de quem já tem
o app instalado (o Android recusa update com chave diferente). Então segue duas
alternativas que **não** exigem mexer em keystore. **A opção A é uma linha.**

---

## Opção A — trocar o protectionLevel da permissão (recomendada)

No `AndroidManifest.xml` do Impulse:

```xml
<!-- era: android:protectionLevel="signature" -->
<permission
    android:name="br.com.redesurftank.havalshisuku.permission.READ_CONNECTIVITY_STATUS"
    android:protectionLevel="normal" />
```

`normal` é concedida automaticamente na instalação, sem diálogo, e não depende de
assinatura. Nada mais muda: URI, colunas, cache e broadcast seguem iguais, e o
EcoTrip já está pronto — passa a funcionar sem novo release do lado dele.

**Sobre o risco:** com `normal`, qualquer app que declare a permissão pode ler.
O que é exposto é nome da rede WiFi, modo de roteamento e estado do 4G — não há
credencial nem localização. Num head unit onde os apps são instalados pelo próprio
dono, o ganho de simplicidade compensa. Se ainda assim preferir restringir, veja
a opção B.

---

## Opção B — payload no broadcast que já existe (sem permissão nenhuma)

O Impulse já manda `br.com.redesurftank.havalshisuku.CONNECTIVITY_CHANGED`
**explícito** pro EcoTrip. Broadcast explícito não precisa de permissão — o
destino é endereçado por package.

Bastaria carregar os mesmos campos como extras:

```kotlin
val i = Intent("br.com.redesurftank.havalshisuku.CONNECTIVITY_CHANGED")
    .setPackage("br.com.redesurftank.ecotrip")
    .putExtra("displayText", status.displayText)          // null = esconder
    .putExtra("displayLevel", status.displayLevel)        // good|warn|bad|muted
    .putExtra("displayIcon", status.displayIcon)
    .putExtra("routingMode", status.routingMode)          // OFF|WLAN|4G|STARTING|ERROR
    .putExtra("routingWifiName", status.routingWifiName)
    .putExtra("hotspotRouting", status.hotspotRouting)
    .putExtra("mobileControlEnabled", status.mobileControlEnabled)
    .putExtra("mobile4gOn", status.mobile4gOn)
    .putExtra("mobileBlockReason", status.mobileBlockReason)
sendBroadcast(i)
```

Como isso é **push-only**, falta cobrir o EcoTrip subindo depois de um evento —
ele ficaria sem estado até a próxima mudança. Duas formas de resolver, qualquer
uma serve:

1. **Responder a um pedido.** O Impulse escuta
   `br.com.redesurftank.havalshisuku.REQUEST_CONNECTIVITY` (receiver exportado, sem
   permissão) e responde com o broadcast acima. O EcoTrip pede ao iniciar.
2. **Reenviar junto do estado periódico** que o Impulse já publica, se houver algum.

A opção 1 é preferível: o EcoTrip pede quando precisa, sem timer no Impulse.

---

## O que o EcoTrip já tem pronto

- Permissão declarada no manifest (`targetSdk 28`, então sem `<queries>`)
- Leitura do provider fora da main thread, com `SecurityException` tratada
- Receiver de `CONNECTIVITY_CHANGED` registrado (forma de 2 args, API 28)
- Republicação em `haval/ecotrip/uplink/status` (retido) → `state.uplink` no bridge
- Badge no header do Painel do app iOS, usando `displayText`/`displayLevel`/`displayIcon`
  direto — nenhum texto é remontado do nosso lado

Com a **opção A** nada precisa mudar no EcoTrip. Com a **opção B** o EcoTrip passa
a ler os extras do broadcast em vez do provider — mudança pequena e localizada,
mas exige um release nosso.

## Detalhe que vale manter em qualquer opção

`displayText == null` significando "esconder o card" é uma decisão boa e o EcoTrip
a respeita: propaga como `null` (não como string vazia) até o app iOS, que
simplesmente não desenha o badge. Se a opção B for escolhida, `putExtra` com null
preserva isso.
