# Handoff: Haval Hub (iOS) — Redesenho "Energia como hero"

Pacote de implementação para Claude Code. Cobre o redesenho das 5 tabs + Live Activities,
na direção visual aprovada pelo dono ("1a — Energia como hero", com Drive "4a — Mapa hero").

## Visão geral

Redesenho do app iOS nativo (SwiftUI) de companion do Haval H6 PHEV. A hierarquia foi
invertida: **o dado de energia é o hero** (SOC gigante em peso ultraleve, DNA do cluster);
o carro sai do topo do Painel e vira presença contextual (anomalias, tile de estado).
Densidade de informação preservada; anomalia é promovida, informação saudável colapsa.

## Sobre os arquivos deste pacote

`Painel Redesign.dc.html` é **referência de design em HTML** — um canvas com todos os
mockups aprovados em frames de iPhone (402×874). **Não é código de produção.** A tarefa é
**recriar essas telas em SwiftUI puro** no codebase existente (`DesignSystem.swift`,
NativeDashView etc.), migração incremental tela a tela, seguindo as restrições do
documento original (`uploads/DESIGNHANDOFF-original.md`): iOS mínimo ~17, features iOS 26
gated com `if #available`, máx 5 tabs, MapKit, Swift Charts, tudo pt-BR.

Ids no canvas (badges verdes): **1a** Painel base · **3a–3d** matriz de estados do Painel ·
**4a** Drive · **5a–5c** Viagens/trajeto/Insights · **6a–6b** Recargas · **7a–7b** Config ·
**1d/2a** Live Activities · **2b–2d** vocabulário de estados (comando, conexão, carro).

## Fidelidade

**Alta (hifi).** Cores, tipografia, espaçamentos, raios e copy são finais — recriar
pixel-perfect com os componentes existentes do `DesignSystem.swift`, evoluindo-os
conforme a seção "Componentes". Números nos mocks são dados de exemplo.

---

## Design tokens

### Cor (evolução do enum DS atual — parentesco com PWA/cluster mantido)

| token | valor | uso |
|---|---|---|
| bg | `#000000` | fundo de todas as telas |
| panel | `#0d0d0f` | cards sólidos de dados |
| panel2 | `#16161a` | superfícies internas, chips, tracks de barra, tiles de ação |
| panel3 | `#2a2a2a` | segmento ativo de segmented, barras de gráfico neutras |
| text | `#f5f5f5` | texto primário e numerais |
| text2 | `#94a3b8` | secundário (novo — entre text e muted) |
| muted | `#6b7280` | micro-rótulos, unidades, timestamps |
| border | `rgba(255,255,255,.08)` | borda 1px de card |
| divider | `rgba(255,255,255,.05)` | hairline interna de listas |
| green | `#22c55e` (dim `#16a34a`) | ok/EV/ao vivo/ação primária; gradiente de fill `90deg #16a34a→#22c55e` |
| blue | `#38bdf8` | ações info (vidros, acordar) |
| orange | `#fb923c` | combustível/consumo/RPM/motor |
| teal | `#22d3ee` | consumo kWh, AC/clima, curva de recarga |
| yellow | `#facc15` | pendente, marcador de limite, caução (pneu baixo usa `#fbbf24`) |
| red | `#ef4444` | crítico: destravado, porta aberta, falha, bridge fora |

Tints de estado: cor a 10–15% de alpha no fill + borda a 30–45% (ex.: chip ativo
`bg rgba(34,197,94,.12)` + `border rgba(34,197,94,.3)` + label na cor).

### Tipografia (SF Pro / system)

| papel | spec |
|---|---|
| Hero numeral (SOC, velocidade) | 88pt, weight 200 (ultraLight), tracking −4, `monospacedDigit`, line-height .92 |
| Hero reduzido (anomalia) | 74pt / velocidade Drive overlay 64pt, weight 200 |
| Hero secundário (412 km, 84,6 kWh, R$ 214) | 56–62pt, weight 200, tracking −2,5 |
| Valor de card (kW, 1h24) | 22–30pt, weight 500–600, monospacedDigit |
| Valor de mini-métrica | 14–16pt semibold, monospacedDigit |
| Título de tela | 21pt bold, tracking −0,02em |
| Corpo/linha de card | 12–13,5pt, semibold p/ nomes |
| Secundário de linha | 10,5–11,5pt, text2/muted |
| Micro-rótulo | 8,5–9,5pt, weight 600–700, UPPERCASE, tracking .08–.12em, muted |
| Chip | 11pt semibold |
| Tab label | 9,5pt (ativo 600 green, inativo 500 muted) |

Números sempre pt-BR: vírgula decimal, ponto de milhar, `R$ 1,58`, `27,5 °C`.

### Forma e espaçamento

- Raio: cards de dados 13–16; grupos de settings 15; card expandido 16; sheet 24 (topo); chips/pills/toggles 999; tiles de ação 13; icon-box de settings 7 (26×26).
- Padding de tela: 18px horizontal. Gaps verticais: 7–12px. Padding interno de card: 10–14px.
- Barras: SOC hero h10 (marcador de limite: tick amarelo 2px, −3px overflow vertical); combustível h5 w72; barras de card h6–8; power bar Drive h8–12.
- Hit targets ≥ 44pt (tiles de ação h62; botões flutuantes 44).

### Glass (regra de ouro mantida)

Glass **só em camada flutuante sobre mapa/cena**: header pills, botões flutuantes,
overlay do Drive (`rgba(18,18,20,.82)` + blur 16), tab bar (`rgba(10,10,10,.92)` + blur).
Cards densos de dados são **sólidos** `#0d0d0f`. iOS 26: `glassControl`/`glassPanel`;
fallback `ultraThinMaterial`.

### Motion

- `ecoBreathe` (ponto AO VIVO/carregando): scale 1→1.35 + opacity 1→.55, 2,2s ease-in-out loop.
- `ecoPulse` (pendente/LIVE/bridge fora): opacity 1→.35, 1,4–1,8s loop.
- `ecoSpin` (fan AC ativo): rotação 2,6s linear.
- Press: scale .97, ~.1s. Sheets: cubic-bezier(.4,0,.2,1) .25s.
- `Reduzir animações` (toggle em Aparência) e `accessibilityReduceMotion` desligam loops.

---

## Ícones

**Sem emoji.** SF Symbols equivalentes aos glifos dos mocks (stroke ~1.8):
tabs `gauge`, `steeringwheel`, `bolt.fill`, `map.fill`, `gearshape.fill`;
ações `lock`/`lock.open`, janela = custom (retângulo + seta ↓), `snowflake` (clima),
porta-malas = custom (traseira arredondada), motor = custom engine, `speaker.wave.2` (buzina);
estado `location`, `moon` (dormindo), `clock` (enviando), `checkmark`, `xmark`,
`chevron.right`, `waveform.path.ecg` (saúde/diagnóstico), `bell`, `exclamationmark.triangle`,
`faceid`, `person`, `square.and.arrow.down` (exportar), `magnifyingglass`, gráfico
`chart.bar`. Custom = desenhar Path simples, mesmos pesos.

---

## Telas

### 1 · Painel (base 1a; estados na matriz 3a–3d)

Ordem vertical (scroll se precisar, mas o estado padrão cabe na dobra):

1. **Header**: endereço reverse-geocode à esquerda (pin 13 + 12pt text2, truncado);
   à direita **LiveChip** (ver Estados de conexão).
2. **Hero de energia**: SOC 88pt/200 com `%` 24pt muted; à direita, alinhado à base:
   `122 km elétricos` (15pt semibold green) sobre `486 km total` (12pt muted).
3. **Barras**: SOC h10 com gradiente green e **marcador de limite** amarelo na posição
   do limite (80%); linha abaixo: mini-barra de combustível laranja (h5, w72) +
   `COMBUSTÍVEL 62% · 364 km` (10,5pt muted caps) | `LIMITE 80%` à direita.
4. **Chips de estado**: P / Desligado / Travado (+ Carregando quando plugado).
   Vocabulário completo no bloco 2d do canvas: Travado(green) Destravado(red)
   2 abertas(red) Teto aberto(yellow) Motor ligado(orange) D·3ª(neutro claro) AC(teal).
5. **Card Carregando** (só quando plugado): borda green .3, fundo
   `linear-gradient(135deg, rgba(34,197,94,.16), panel 62%)` + glow radial no canto;
   `CARREGANDO · WALLBOX CASA` micro green com ponto breathe; kW 30pt; `+8,2 kWh nesta
   sessão`; direita: `1h24` 22pt + `ATÉ 80%` micro.
6. **Mini-métricas** (grid 4): CABINE / EXTERNA / ODÔMETRO / BATERIA 12V — micro-rótulo,
   valor 15pt, sub 8,5pt com **frescor** (`há 4 min`/`agora`) ou unidade.
7. **Ações** (grid 3×2, tiles h62 panel): Travar(green) Vidros(blue) Clima(teal)
   Porta-malas(neutro) Motor(orange) Buzina(neutro) — ícone 19 + label 10,5pt.
   Máquina de estados no tile (ver Interações).
8. **Última viagem** (linha): micro `ÚLTIMA VIAGEM · 17:42`, `Casa → Escritório` 13pt,
   direita `12,4 km · 18 min · 13,9 kWh/100` + chevron. Substituída pelo **card Viagem
   em curso** quando dirigindo (3d): borda green, ponto breathe, `72 km/h · 8,2 km ·
   13,9 kWh/100` em 24pt, progresso do trajeto, `Acompanhar no Drive →`.
9. **Saúde + Planejar saída** (2 colunas): SAÚDE `96/100` com ícone pulse green;
   SAÍDA 07:40 `cabine a 22,0 °C às 07:30` + toggle.
10. **Grupo silencioso** (lista 2 linhas, panel): `Pneus — 36 · 36 · 36 · 36 psi ›` e
    `Manutenção em dia — revisão em 2.568 km ›` (11pt muted/text2).

**Estados (matriz 3a–3d):**
- **3b Anomalia**: card vermelho **acima do hero** (PNG do carro 52px, `DESTRAVADO ·
  HÁ 12 MIN`, descrição, distância até o carro, botão `Travar` red pill com texto preto);
  hero encolhe p/ 74pt; chips viram red; tile Travar ganha tint red; **pneus expandem**
  em faixa amarela com as 4 posições (baixa em destaque `33` bold yellow); última viagem
  sai da dobra.
- **3c Dormindo**: LiveChip vira `DORMINDO · HÁ 42 MIN` (moon, neutro); todo o bloco de
  telemetria (hero→minis) com `brightness .62 / saturação .7`; cada valor com `há 42 min`;
  linha `Última leitura 17:58 · comandos acordam o carro` + `Acordar` (blue) separa
  snapshot de comandos (que ficam 100% opacos).
- **3d Dirigindo**: chips D·3ª / Modo EV / AC 22,0° (fan girando); card viagem em curso
  substitui última viagem; minis trocam ODÔMETRO/12V por POTÊNCIA (kW laranja) e SCORE
  (green); ações sem sentido em movimento a 45% de opacidade; ponto verde no tab Drive.

### 2 · Drive (4a — mapa hero)

- Mapa MapKit dark fullscreen; vinheta radial de borda + gradiente de proteção no topo.
- Topo: LiveChip à esquerda; pill de destino centro-direita `→ Escritório · 8 min · 8,2 km`.
- Coluna flutuante direita (44px, glass): follow (seta, **fundo green + glifo preto**
  quando ativo), clima (snowflake teal), mic (escuta da cabine), controles.
- **Overlay inferior** (glass rgba(18,18,20,.82), raio 20, margem 12): velocidade 64pt/200
  + `km/h`; direita: kW 26pt colorido (laranja consumo / green regen com sinal −) sobre
  **power bar bidirecional** (130×8, zero central com tick branco .25, fill p/ direita
  laranja ou esquerda green; rótulos `REGEN`/`CONSUMO` 8pt) ; linha 2: chips `D · 3ª` +
  `Modo EV` | `13,9 kWh/100 · viagem` | **ScoreRing** 26px (anel green, dasharray ∝ score)
  + `SCORE`.
- RPM: aparece no overlay só com motor a combustão ativo (valor laranja, ver 4b p/ estilo).
- Tab bar Drive ativo.

### 3 · Viagens (5a) + Ver trajeto (5b) + Insights (5c)

**5a Tab**: título + toolbar (busca, Insights); hero `412` 62pt/200 + `km`; direita
`28 viagens · 82% em EV` (green) e `61,3 kWh · R$ 74,20`; chips de período
(Semana/**Junho**/Personalizado). Card da viagem de hoje **expandido**: cabeçalho
(nome, `hoje · 17:42 – 18:00 · 31° externa`, score chip 92), grid 4 (DISTÂNCIA/CONSUMO
teal/VEL. MÁX/CUSTO), **prévia do trajeto** (mini-mapa h76 com polyline colorida por
velocidade), ações `Ver trajeto →` (green bold) · Compartilhar · GPX. Demais viagens em
linhas de 2 níveis com score à direita (amarelo se <80) + chevron; rodapé
`Ver todas as 28 viagens ›`.

**5b Sheet Ver trajeto**: grab handle; título + fechar; **mapa h~358** com polyline
segmentada por velocidade (teal lento / green fluindo / laranja rápido — legenda em pills
glass no canto); grid 3 métricas **no playhead** (VELOCIDADE/POTÊNCIA/CONSUMO);
**player**: botão 44 green (play/pause glifo preto), scrubber h8 com knob 14 branco,
tempos `17:42 | 17:53 · km 7,7 (green) | 18:00`, velocidade `2×`; **gráfico de velocidade**
(área green .14 + linha 2px) com **linha de playhead branca sincronizada**; base:
`Cartão` (pill green texto preto) · `GPX` · `Link web`.

**5c Insights** (push com back `‹ Viagens`): hero `R$ 214` 58pt/200 **green** +
`economizados vs gasolina em junho`; direita `energia R$ 74` / `gasolina seria R$ 288`;
grid 2: **ECO SCORE** anel 84px (87, `+3 vs maio`) | **KM POR MÊS** mini-barras (junho
green) + `412 km` vs `média 448`; card **CONSUMO × TEMPERATURA**: dispersão (pontos teal,
quentes laranja) + tendência tracejada + anotação `AC pesa ~9% acima de 30°`;
**ROTAS COMPARADAS** (2 linhas, vencedora green com −4%); lista Marcos
(chip `10.000 km em EV`) / Relatório mensal.

### 4 · Recargas (6a histórico, 6b estatísticas)

**6a**: título + ícone SoH; **segmented** Recargas|Abastecimento (container panel2 r11,
ativo panel3 r9); hero `84,6` 56pt/200 + `kWh`; direita `9 recargas em junho` green,
`R$ 98,10 · média R$ 1,16/kWh`; sub-chips Histórico/Estatísticas + `Junho` à direita.
**Sessão de hoje expandida** (borda green .28): cabeçalho (`Wallbox casa`, `hoje · 19:12 –
21:36 · AC 6,6 kW`, badge `+18,4 kWh`); **barra SOC de→até**: trecho 0–46% green .25,
46–80% gradiente green pleno, marcador amarelo no limite, rótulo `46% → 80%`; grid 4
(CUSTO/DURAÇÃO/MÉDIA teal/R$-KWH); **curva de potência** (área+linha teal, h86): plateau
CC 6,6 → taper CV, eixos `19:12/21:36`, `6,6 máx`. Linhas colapsadas mostram
`DC 40 kW · 31% → 74% · 34 min` e custo. Rodapé `Ver todas as 9 recargas ›`.

**6b Estatísticas**: card **KWH POR MÊS** (barras JAN–JUN, atual em gradiente green com
valor bold green, demais panel3, `média 89,6`); card **POR CARREGADOR** (3 linhas com
barra proporcional: casa green 68%, Shell teal 26%, outros cinza); grid 2 **CUSTO MÉDIO**
casa `R$ 0,96/kWh` vs DC `R$ 1,62/kWh` (laranja); lista: Saúde da bateria (`SoH 98,2%`
green) / Análise de recarga / Previsão (`80% às 21:40`).

### 5 · Config (7a) + Aparência (7b)

**7a**: título + chip `BRIDGE OK · 42 MS` (breathe); grupos com micro-rótulo CAPS acima
e linhas com **icon-box 26×26 tintado**:
- VEÍCULO: Haval H6 PHEV (PNG 30px, `2024 · head-unit conectado via MQTT`) ›; Limite de
  carga `80%` ›; Guarda-estacionamento (sub `alerta se o carro se mover sem você`, toggle off).
- ALERTAS: Notificações (`Live Activities on`) ›; Central de alertas (**badge red `2`**) ›.
- APARÊNCIA: Estilo do hero (`Energia`) ›; Liquid Glass (sub `iOS 26+ · só na camada
  flutuante`, toggle on).
- CONTA E SEGURANÇA: Exigir Face ID (on); Instância (`rafael · bridge local`) ›.
- DADOS: Exportar dados (`CSV · GPX`) ›; Diagnóstico (`WS 1 Hz · 42 ms`) ›.

**7b Aparência**: seletor **Estilo do hero** = 2 cartões-miniatura selecionáveis
(Energia com borda green 1,5px + check; "Carro + status" com radio vazio) desenhando
miniaturas reais; **PRÉVIA ao vivo** logo abaixo (hero 1a em 56pt reagindo à escolha);
grupo EFEITOS: Liquid Glass (on) / Reduzir animações (off, sub `desliga pulsos e loops`) /
Tema `Escuro · fixo` (sem chevron — declarado, não editável).

### 6 · Live Activities (1d recarga/pré-clima, 2a deslocamento)

Mesma gramática: fundo `#0d0d0f` (recarga com gradiente green no canto), raio 24 (tela
bloqueada) / 44 (Dynamic Island), numerais leves monospaced, micro-rótulos CAPS.
- **Recarga**: header (app icon 22 + `Haval · Wallbox casa` | breathe + `há 30 s`);
  linha `6,6 kW` 34pt · `74% → 80%` (74 green) · `1h24 RESTANTE`; barra com marcador;
  rodapé `+8,2 kWh · R$ 9,84` | `pronto ~ 21:40`.
- **Pré-clima** (DI expandida): fan teal girando em circle-tint 40; `Pré-climatização
  ligada` + `Cabine 27,5° → 22,0° · pronta às 07:38`; `LIVE` green pulsando + hora.
- **Viagem em curso** (tela bloqueada): velocidade 40pt + destino/chegada; **barra de
  progresso do trajeto** com ponto branco (glow green) + rótulos CASA/ESCRITÓRIO;
  rodapé `8,2 km · 18 min` | `13,9 kWh/100` | `SOC 71%`.
  DI expandida: seta nav green em circle-tint + `→ Escritório · 8 min` + telemetria;
  DI compacta: seta green | `8 min` green.

---

## Interações e estados transversais

### Máquina de estados de comando (2b) — obrigatória em toda ação remota
`padrão → enviando (1–3 s) → confirmado | falhou`
- Enviando: tint yellow + borda .4 + ícone clock + `Enviando…` + **ecoPulse**; o próprio
  tile/botão muda — nunca spinner genérico.
- Confirmado: tint green + check + novo estado (`Travado`); toast opcional
  `Travado · o carro confirmou` com latência (`2,1 s`); reverte ao normal ~2 s.
- Falhou: tint red + xmark + `Falhou`; **tocar = retry**; toast glass com borda red
  `Carro não respondeu · Travar` + botão `Tentar` (green bold).

### Conexão e frescor (2c)
- **AO VIVO**: WS ok e dado < 30 s — chip green com ponto breathe.
- **DORMINDO · HÁ X MIN**: chip neutro com moon; telemetria dimmed (brightness .62,
  saturação .7); todo valor não-vivo carrega `há X min`; linha `Acordar` (blue).
- **BRIDGE FORA**: chip red pulsando + banner red `Sem conexão com o bridge · mostrando
  snapshot de 18:02 · reconectando…`; dados congelados visíveis (nunca esconder).
- Reconexão: tentar a cada 5 s.

### Regra de promoção por anomalia
Estado saudável = 1–2 linhas silenciosas no rodapé. Anomalia = sobe: pneu baixo → faixa
amarela expandida; destravado/porta aberta → card vermelho no topo com ação inline.
CollapsibleCards atuais migram pra esse padrão.

## Gerenciamento de estado (mapeamento WS ~1 Hz)

Campos consumidos: soc, rangeEv, rangeTotal, fuelPct, rangeFuel, chargeLimit, charging
{kW, kWhSession, minToLimit, custo}, gear, ignition, locked, doors[], windows, roof,
tempCabin(+ts), tempExt, odo, batt12v, tpms[4](+ts), speed, powerKw (sinal!), rpm,
driveMode, acOn/acTarget, scoreLive, trip {atual, última}, health, bridgeLatency,
timestamps por leitura. Derivados: frescor por campo, estado de conexão, flags de anomalia.

## Assets

- `assets/haval-h6.png` — vista superior (usado em: card anomalia 52px, tile 1c 96px,
  linha Veículo 30px, miniatura 7b 34px). PNGs de camadas existentes do app continuam
  valendo para o estilo de hero "Carro + status".
- Ícone do app existente (raio verde/laranja) nas Live Activities (22px).

## Arquivos

- `Painel Redesign.dc.html` — canvas com todos os mockups (abrir no projeto original
  para ver ao vivo; frames 402×874).
- `uploads/DESIGNHANDOFF-original.md` — contexto de produto e restrições técnicas.
- `assets/haval-h6.png`.
