# HANDOFF — Relayout da tela "Controles" (carro · head unit) → 2 telas

**Para:** Claude (design)
**De:** dev
**Arquivo fonte (anexo):** `cockpit.html` (tela atual, completa — CSS + HTML + script).
**Objetivo:** dividir a tela em **2 telas** (Controle 1 e 2) pra os botões ficarem **maiores**, trocando entre elas com **swipe de 2 dedos lateral**.

---

## 0. Contexto técnico

- Roda num **WebView dentro do app Android do head unit** (Haval H6), tela widescreen.
- **Não** é o iPad. É o app do carro. Comandos vão **in-process** pro carro (sem rede).
- O WebView **já recebe a área segura**: a janela do app é inserida pelo sistema, então o WebView = **1792×660 px** (a dock de 128px à esquerda e a barra de status de 60px no topo são do sistema, ficam **fora** do WebView). Densidade 1.0 → **1px = 1dp**. Pode desenhar direto em 1792×660.
- O `.cockpit` é `100vw × 100vh` (= preenche o WebView = a área segura). **Não reservar faixas** (`--sys-left/--sys-top = 0`).

## 1. REGRA DE OURO (não quebrar o app)

O `<script>` (a partir da linha ~866 no `cockpit.html`) é o motor: faz `applyNativeSnapshot(state)` (reflete telemetria → UI) e dispara os comandos. **NÃO MEXER no `<script>`.**

Você pode mudar **só**: o `<style>` e o `<body>` (estrutura/layout/CSS). Mas:
- **Preserve TODOS os `id=`** listados na §3 — o script lê/escreve neles.
- **Preserve os `onclick`/`oninput`/`onchange`** de cada controle (mesmos nomes de função e argumentos).
- **Preserve os elementos-sentinela ocultos** (mapa `#cluster-map`, fluxo de energia oculto, `#toast`, popups `#mode-popup`/`#hev-popup`, `#soc-pct-mini`, os spans ocultos `#clock/#version/#conn-dot/#conn-lbl`). Pode mover no DOM, mas não apagar.
- Pode **reagrupar, redistribuir entre as 2 telas, redimensionar e reestilizar** os controles à vontade.

## 2. Layout atual (1 tela)

Grid: 3 colunas de controles (Condução · Climatização · Veículo) + faixa inferior "Viagem em curso". Sem cabeçalhos de coluna. A barra do app (badge de conexão + botões config/recargas/viagens/update) fica no **canto inferior direito** da faixa de viagem (`.trip-controls`).

## 3. Inventário de controles — IDs, ação e leitura (CONTRATO)

> "Envia" = `__cmd` disparado no toque. "Lê" = chave do `state` que o `applyNativeSnapshot` usa pra refletir.

### Condução
| Controle | id / handler | Envia (`__cmd` · valores) | Lê (state) |
|---|---|---|---|
| Modo de condução | `#seg-mode` botões `data-mode` (Eco/Normal/Sport) · **segurar** abre `#mode-popup` (todos: +AWD/Neve/Lama/Areia) | `terrain_mode` · Normal0 Sport1 Eco2 Neve3 Areia4 Lama5 AWD11 | `terrain_mode` |
| Modo de direção | `#seg-steer` `setSteer(this,'conforto/normal/sport')` | `steer_mode` · Normal0 Sport1 Conforto2 | `steer_mode` |
| Tração | `#seg-power`: `#hev-btn` (toque=HEV; **tocar de novo** abre `#hev-popup` Inteligente/Prioritário+% ) · `setPower(this,'prio_ev/ev')` | `drive_mode` 0HEV/1PriorEV/3EV (+`power_reserve` 1/2 +`charge_soc_target` 20..80) | `drive_mode`,`power_reserve`,`charge_soc_target` |
| Regeneração | `#seg-regen` `setRegen(this,'baixo/normal/alto')` | `regen_level` · Normal0 Alto1 Baixo2 | `regen_level` |
| Pisca-alerta | `#ctrl-haz` `toggleHazard()` (`#ctrl-haz-st`) | `hazard` 0/1 | — |
| One-pedal | `#ctrl-onepedal` `toggleOnePedal()` (`#ctrl-onepedal-st`) | `one_pedal` 0/1 | `one_pedal` |
| ESP | `#ctrl-esp` `toggleESP()` (`#ctrl-esp-st`) | `esp` 0/1 | `esp_enable` |

### Climatização
| Controle | id / handler | Envia | Lê |
|---|---|---|---|
| A/C | `#ctrl-ac` `toggleAC()` (`#ctrl-ac-st`) | `hvac/ac_enable` 0/1 | `ac_state` |
| Circulação | `#ctrl-recirc` `toggleRecirc()` (`#ctrl-recirc-st`,`#ctrl-recirc-ic`) | `hvac/cycle_mode` 0recirc/1externo | `hvac_cycle_mode` |
| SYNC | `#ctrl-sync` `toggleSync()` | `hvac/sync` 0/1 | `hvac_sync_enable` |
| AUTO | `#ctrl-auto` `toggleAuto()` | `hvac/auto` 0/1 | `hvac_auto_enable` |
| Desemb. diant. | `#ctrl-deff` `toggleDef('f')` | `hvac/front_defrost` 0/1 | `hvac_front_defrost` |
| Desemb. tras. | `#ctrl-defr` `toggleDef('r')` | `hvac/rear_defrost` 0/1 | `hvac_rear_defrost` |
| Ionizador | `#ctrl-anion` `toggleAnion()` | `hvac/anion` 0/1 | `hvac_anion` |
| Max A/C | `#ctrl-acmax` `toggleAcMax()` | `hvac/acmax` 0/1 | `hvac_acmax` |
| Temp motorista | slider `oninput="setTempSlider('d',v)"` (`#ctrl-temp-d`) | `hvac/driver_temp` °C 16–32 | `hvac_driver_temp` |
| Temp passageiro | slider `setTempSlider('p',v)` (`#ctrl-temp-p`) | `hvac/passenger_temp` | `hvac_passenger_temp` |
| Ventilação | slider `setFanSlider(v)` (`#ctrl-fan`) | `hvac/fan_speed` 0–7 | `hvac_fan_speed` |
| Direção do ar | `#seg-air` `setAir(this,0..4)` | `hvac/blower_mode` Rosto0/R+Pés1/Pés2/Pés+Vidro3/Degelo4 | `hvac_blower_mode` |
| Leitura (display) | `#ro-pm25` `#ro-tout` `#ro-tin` | — (só leitura) | `hvac_pm25`,`outside_temp`,`inside_temp` |

### Veículo
| Controle | id / handler | Envia | Lê |
|---|---|---|---|
| Vidros (4 individuais) | `.wc-win[data-win=0..3]` `cycleWin(i)` cicla Fechado→Metade→Aberto (`#win-0..3-st`) | `vehicle/window` `{window:0..3,status:1/3/0}` (1fech 3metade 0aberto) | — (não reflete) |
| Vidros (todos) | `#seg-windows` `setWindows(this,'fechado/entreaberto/aberto')` | `vehicle/window_all` 1/3/0 | — |
| Cortina | slider `setCurtain(v)` (`#ctrl-curtain`) | `vehicle/shade` 0..100 | `shade_level` |
| Teto solar | slider `#sld-sunroof` `setSunroof(v)` (`#ctrl-sunroof`) + botão `#ctrl-sunroof-vent` `sunroofVent()` | `vehicle/skylight` 0fech/10..100%/200ventilação | `skylight_level` |
| Bancos (vent.) | `.vfader[data-side=d/p]` arraste vertical `setSeatSlider('d/p',0..3)` (`#ctrl-seat-d/p-st`) | `hvac/seat_vent_drv` / `hvac/seat_vent_pass` 0..3 | `seat_vent_drv`,`seat_vent_pass` |

### Viagem em curso (faixa) — só leitura
IDs: `#trip-dist #trip-time #trip-kwh #trip-regen-kwh #trip-regen-pct #trip-fuel #trip-ce #trip-kml #trip-cost #trip-cost-km #trip-ev-pct #trip-ev-km #trip-hev-pct #trip-hev-km` + cabeçalho `#trip-dest`.
Barra do app (`.trip-controls`): `#source-badge` (conexão), `#car-dot`/`#car-lbl`, botões `#upd-btn #rec-btn #via-btn #cfg-btn`.

### Potência / Velocidade / Bateria / Combustível
**Removidos** desta tela (não há mais). Os ids `#power-val #speed-val #soc-* #fuel-*` foram tirados; o script tolera ausência. (Se quiser trazer de volta numa das 2 telas, dá — os ids estão documentados, é só recriar.)

## 4. As 2 telas + swipe (o que eu quero)

- **Controle 1** e **Controle 2** — distribuir os controles acima entre as duas pra **caber maior**. Sugestão (você decide o melhor): Tela 1 = Condução + Climatização; Tela 2 = Veículo (vidros/teto/cortina/bancos grandes) + (espaço pra trazer Bateria/Combustível/Velocidade se quiser). A faixa "Viagem em curso" pode ficar fixa nas duas, ou só numa.
- **Troca por swipe de 2 dedos** na horizontal. (Implementação sugerida: 2 panes lado a lado num track com `transform: translateX`, e um gesto de 2 toques — `touchstart` com `e.touches.length===2` medindo o deltaX. Indicador de página (2 bolinhas) embaixo ajuda.)
- Botões **maiores** é o objetivo central — aproveite o espaço liberado por ter 2 telas.

## 5. Guard de comandos físicos (manter)
Teto/cortina/vidros só podem enviar comando em **evento confiável do usuário** (já tem um `sendPhysCmd` que bloqueia envio fora de gesto `isTrusted`). Mantenha: telemetria só reflete, nunca dispara `__cmd`.

## 6. Entregável
Me devolva o `cockpit.html` reestilizado (style + body com as 2 telas + swipe), **sem tocar no `<script>`** e **preservando todos os ids/handlers** da §3. Eu aplico e gero o build OTA.
