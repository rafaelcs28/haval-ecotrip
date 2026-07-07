# Handoff — Tela inicial "Tesla" (app do carro / head unit)

Documento pra redesenhar o **layout "Tesla"** da tela inicial do EcoTrip Impulse
(APK Android que roda na central do Haval H6 PHEV). Quem implementa sou eu — você
entrega **maquete visual + especificação** (medidas, hierarquia, cores). Pode
entregar como HTML/print/figma-ascii; eu porto pra Compose.

> ⚠️ Esta tela é **nativa (Jetpack Compose)**, não é WebView/HTML. Então não
> precisa pensar em DOM/CSS — pense em layout, proporção e medidas. Os valores
> abaixo já são os reais (dp/sp).

---

## 1. Alvo e constraints

| Item | Valor |
|---|---|
| Dispositivo | Central multimídia do Haval H6 (Android 9) |
| Tela física | 1920×720 px, landscape |
| **Área útil (onde a tela desenha)** | **1792×660 dp** — fora ficam a dock de navegação do sistema (128px à esquerda) e a status bar (60px no topo) |
| Densidade | 1.0 → **1 dp = 1 px** |
| Orientação | Sempre landscape, sem rotação |
| Entrada | Toque (dedos), sem mouse/teclado. Sol direto → **tema escuro de alto contraste** |
| Padding atual do layout | 40 dp horizontal, 8 dp vertical (conteúdo ~1712×644) |

A tela é a "favorita" do carrossel: 2 dedos lateralmente trocam pra tela de
Controles. O design deve continuar legível de **relance, dirigindo** (números
grandes, pouca densidade).

---

## 2. Layout atual (o que existe hoje)

```
┌────────────────────────────────────────────────────────────────────┐ 1792×660
│ HAVAL H6 PHEV                              27°   [v6.80][🔋][🚗][⚙]  │ header
│ ─────────────────────────────────────────────────────────────────── │ divisor 1px (#222226)
│ ┌ ➜ Trindade            Chegada 14:32 · Faltam 18,3 km · SOC 47% ┐  │ banner nav* (#161618)
│ └────────────────────────────────────────────────────────────────┘  │
│                                                                      │
│ ┌── ESQUERDA (weight 1) ──┐      ┌── DIREITA (weight 1.25) ───────┐  │
│ │                         │      │ VIAGEM ATUAL                   │  │
│ │    [ CARRO H6 ]         │      │ 23,4 km           (96sp)       │  │
│ │   vista de cima         │      │ ┌──────┐┌────────┐┌─────────┐ │  │
│ │  (InteractiveCar)       │      │ │Tempo ││Vel.méd ││Consumo  │ │  │
│ │                         │      │ └──────┘└────────┘└─────────┘ │  │
│ │ 62%  ·95 km autonomia EV│      │ ┌──────┐┌────────┐┌─────────┐ │  │
│ │ [██████████░░░░░] bateria│      │ │Energia││Custo  ││Combust. │ │  │
│ └─────────────────────────┘      │ └──────┘└────────┘└─────────┘ │  │
│                                   └────────────────────────────────┘  │
└────────────────────────────────────────────────────────────────────┘
```
\* banner de navegação só aparece quando há rota ativa (`navActive`). Quando
aparece, as fontes da direita encolhem (km 96→66sp, células 40→32sp) pra não
espremer.

### Estrutura (de cima pra baixo)
1. **Header** (Row): título `HAVAL H6 PHEV` (22sp, #8E8E93, letterSpacing 3) +
   espaço + temperatura externa `27°` (24sp) + **ações** (ícones à direita).
2. **Divisor** 1px (#222226).
3. **Banner de navegação** (condicional): `➜ {destino}` + 3 células à direita
   (Chegada HH:MM/min, Faltam km, SOC na chegada — cor do SOC muda por faixa).
4. **Corpo** (Row, 36dp de gap):
   - **Esquerda (weight 1):** carro interativo (ocupa o topo, weight 1) +
     linha `62%` (44sp) + `· 95 km autonomia EV` (24sp) + barra de bateria
     (22dp alt., gradiente verde, largura = SOC%).
   - **Direita (weight 1.25):** rótulo `VIAGEM ATUAL` (24sp) + número grande
     `23,4 km` (96sp) + grade 2×3 de células (`TeslaCell`: label 21sp +
     valor 40sp + subtítulo opcional 20sp).

### Células da grade (valores e cores hoje)
| Célula | Valor | Subtítulo | Cor do valor |
|---|---|---|---|
| Tempo | `38 min` | — | branco |
| Velocidade média | `37 km/h` | — | branco |
| Consumo | `14,2 kWh/100` | — | verde #28C98A |
| Energia usada | `3,3 kWh` | `regen 0,8 kWh` (azul) | branco |
| Custo | `R$ 1,92` | `R$ 0,082 / km` (verde) | branco |
| Combustível | `0,0 L · EV` | `SOC 78% → 62%` | laranja #FF5F1F |

---

## 3. Dados disponíveis (`HomeData`)

Tudo isso já existe e pode ser usado/reorganizado livremente. Números em pt-BR
(milhar com `.`, decimal com `,`).

**Viagem atual:**
- `distKm` (Float) · `timeStr` (ex.: "38 min" / "1h 12min") · `avgSpeedKmh` (Int)
- `maxSpeedKmh` (Int) · `kwh100` (consumo kWh/100km) · `effPct` (0..1, anel de eficiência)
- `netKwh` · `regenKwh` · `regenPct` (Int) · `fuelL` (litros) · `costBrl` · `costPerKm`

**Bateria / energia:**
- `socPct` (Int, %) · `startSocPct` (SOC no início) · `rangeEvKm` (autonomia EV)
- `modeEv` (Bool, rodando 100% elétrico) · `outsideTempC` (Int)

**Estado do corpo do carro (pro desenho):**
- portas: `doorFL/FR/RL/RR` · `trunk` (porta-malas) · `sunroof` · `locked`
- vidros: `winFL/FR/RL/RR` · `frontLight` (faróis) · `turnLeft`/`turnRight` (setas/alerta)

**Navegação (quando ativa):**
- `navActive` (Bool) · `navName` (destino) · `navDistKm` · `navEtaMin` ·
  `navEtaClock` ("14:32") · `navArrivalSoc` (% previsto na chegada) ·
  `navStops` (paradas intermediárias: nome, ETA, SOC; concluída fica riscada)

Valores de exemplo (`HomeData.sample`): dist 23,4 km · 38 min · 37 km/h ·
14,2 kWh/100 · SOC 78→62% · autonomia 95 km · destino "Trindade" ETA 14:32 SOC 47%.

---

## 4. Carro interativo (`InteractiveCar`)

Render real do **H6 visto de cima**, montado por camadas PNG sobrepostas
(lataria base + portas/vidros/teto/porta-malas abertos + faróis + setas âmbar
piscando + selo de "trancado"). Reflete o estado real do `HomeData`. Trate como
um bloco visual que recebe um `Modifier` de tamanho — pode reposicionar/
redimensionar, mas o conteúdo interno (carro + estados) é fixo. Proporção da
imagem é vista-de-cima (mais alta que larga).

---

## 5. Paleta (tema do app)

| Token | Hex | Uso |
|---|---|---|
| Fundo Tesla | `#101012` → `#000000` | gradiente vertical |
| NeonLime | `#39FF88` | acento principal / OTA |
| AuroraTeal | `#00E5CC` | acento secundário |
| Verde (sucesso/eco) | `#28C98A` | consumo, custo, bateria |
| PlasmaBlue | `#4DBBFF` | regen / dado elétrico |
| MoltenOrange | `#FF5F1F` | combustível / alerta SOC baixo |
| WarnYellow | `#FFD60A` | SOC apertado |
| Branco texto | `#EEF4FF` | valores principais |
| Cinza Tesla | `#8E8E93` | labels |
| GlassCard | `#0C1019` | cards "glass" (usado no layout By Claude) |

SOC por faixa: <30% laranja `#FF5F1F` · <50% amarelo `#FFB648` · ≥50% verde `#28C98A`.

---

## 6. O que entregar

1. **Maquete** do novo Tesla (HTML, print de figma, ou ascii anotado) na área
   **1792×660**, tema escuro.
2. **Especificação**: hierarquia, medidas (dp/sp), cores por elemento, e o que
   muda quando o **banner de navegação** está ativo vs. inativo.
3. Deixe claro o que **sai/entra/reorganiza** em relação ao atual. Pode propor
   novos arranjos dos dados do §3, mas não invente dados que não existem lá.

Quando me mandar de volta, eu implemento em Compose, gero APK via tag e o carro
atualiza por OTA.
