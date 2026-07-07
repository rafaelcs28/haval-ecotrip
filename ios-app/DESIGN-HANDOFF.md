# Haval Hub (iOS) — Design Handoff para redesenho

Objetivo deste documento: dar a um designer (humano ou Claude) o contexto completo do
design atual do app pra propor um **redesenho mais inovador**, sem quebrar as
restrições técnicas listadas no fim.

---

## 1. O que é o produto

App iOS nativo (SwiftUI) de **companion de carro** para um Haval H6 PHEV (híbrido
plug-in). É o "app da montadora" que o dono construiu do zero porque o oficial é ruim.
Telemetria em tempo real vem do próprio carro: um APK custom roda no head-unit Android
do carro, lê o barramento CAN e publica via MQTT para um bridge Node.js caseiro (Mac
Mini), que serve o app via WebSocket + REST.

Diferencial vs apps de montadora: dados a ~1Hz em tempo real (velocidade, potência kW,
RPM, SOC, temperaturas, portas/vidros/teto), comandos remotos (travar, vidros, AC,
pré-climatização), trips automáticas com trajeto GPS, automações por geofence,
Live Activities ricas.

## 2. Usuários

- **Rafael (dono, primário)**: power user, quer densidade de informação, tudo em pt-BR,
  usa o app dezenas de vezes por dia. iPhone com iOS 26.
- **Grasi (esposa)**: usa um app satélite separado ("Grasi Recarga") — fora de escopo,
  mas o visual dos dois conversa.
- Multi-tenant futuro: até 3 pessoas hospedadas em instâncias isoladas.

## 3. Arquitetura de informação

5 tabs (limite consciente — iOS colapsa em "More" acima disso; telas extras são
drill-down por toolbar/sheet, nunca 6ª tab):

1. **Painel** (`gauge`) — home/estado do carro
2. **Drive** (`steeringwheel`) — mapa fullscreen + telemetria de condução ao vivo
3. **Recargas** (`bolt.fill`) — histórico/estatísticas de recarga e abastecimento
4. **Viagens** (`map.fill`) — histórico de trips com trajeto
5. **Config** (`gearshape.fill`) — ajustes

~30 sheets de drill-down (modal .sheet), ex.: Pré-climatização, Planejar saída,
Insights (análises), Saúde da bateria, Análise de recarga, Score de condução,
Eco score, Comparar rotas, Relatório mensal, Guarda-estacionamento, Notificações,
Assistente (chat com a Mari via WhatsApp-backend), Central de alertas, Range/alcance,
Compartilhar status, Timeline de eventos, Manutenção, Marcos/milestones.

### Tab 1 — Painel (NativeDashView)
- **Hero do carro**: HStack — PNG do carro à esquerda (140×170, imagem real do carro
  com camadas dinâmicas: portas abertas, luzes, AC ligado, trava), grid 2×2 de
  mini-cards à direita (Temp interna / Temp externa / Odômetro / Bateria 12V).
  Endereço atual (reverse-geocode) no topo do card. Existe um segundo estilo de hero
  selecionável ("padrão", estilo status-card sem PNG).
- Chips de estado (marcha, ligado/desligado, carregando).
- **Card de bateria**: LevelBadge SOC % + combustível + range EV/total, marcador de
  limite de carga na barra, stepper de limite (70/80/90/100).
- **Card "Carregando"** quando plugado: kW, tempo restante, kWh da sessão.
- **Actions row**: botões grandes (Travar, Vidros, Clima/AC, Porta-malas, Motor,
  Buzina/pisca) — DSActionButton glass com tint da cor.
- **Saúde do carro** (health score consolidado) e **Planejar saída** (pré-clima
  agendada com leitura de temp da cabine + clima local via OpenWeather).
- Última viagem (resumo) / Viagem em andamento (ao vivo).
- CollapsibleCards para seções secundárias (pneus/TPMS, manutenção, alertas) — só
  expandem em anomalia (borda amarela).

### Tab 2 — Drive (NativeDriveView)
- Mapa MapKit fullscreen (dark), carro centralizado, auto-follow com zoom adaptativo
  por velocidade, botões flutuantes glass (follow, controles, AC, mic escuta cabine).
- Overlay inferior translúcido (glassPanel): velocidade grande ajustada ao velocímetro,
  potência kW (verde regen / laranja consumo), consumo kWh/100km da viagem, RPM se
  motor a combustão ativo, score de condução ao vivo, chips (marcha, modo).
- É o "cockpit" quando alguém acompanha uma viagem em curso.

### Tab 3 — Recargas (NativeRecargasView)
- Segmented: Recargas | Abastecimento; sub-tabs Histórico | Estatísticas.
- Chips de período (semana/mês/custom com calendário).
- Cards de sessão expandíveis (kWh, custo R$, SOC de→até, duração, curva de potência).
- Estatísticas: kWh por mês (gráfico Charts), por carregador, custo médio.
- Toolbar: Saúde da bateria (SoH), Análise de recarga, Previsão de recarga.

### Tab 4 — Viagens (NativeViagensView)
- Resumo do período + busca + chips de período.
- Cards de trip expandíveis: origem→destino nomeados, km, tempo, kWh, consumo,
  velocidade máx, temp externa, score.
- "Ver trajeto": sheet com mapa + polyline colorida por velocidade + **timeline
  play/pause** (scrubber que anima o carro no trajeto com gráficos sincronizados).
- Compartilhar: cartão (imagem), GPX, **link web** (página hospedada no bridge com o
  mesmo player de timeline).
- Toolbar → **Insights** (NativeInsightsView, drill-down): economia R$ vs gasolina
  (hero), eco score, consumo × temperatura, km por mês, rotas comparadas, marcos,
  relatório mensal.

### Tab 5 — Config (NativeConfigView)
- Listas agrupadas: Veículo, Alertas e notificações, Aparência (estilo do hero,
  Liquid Glass), Conta e segurança (Face ID gate), Dados, Guarda-estacionamento.

## 4. Linguagem visual atual

**Tema**: dark-only, quase-preto. Herdada do cluster/PWA (o ecossistema tem PWA web e
cluster de instrumentos com o mesmo tema — coerência entre superfícies importa).

Paleta (DS enum em `DesignSystem.swift`):

| token  | hex       | uso |
|--------|-----------|-----|
| bg     | #000000   | fundo |
| panel  | #0d0d0f   | cards |
| panel2 | #16161a   | superfícies internas / barras |
| text   | #f5f5f5   | texto |
| muted  | #6b7280   | rótulos, secundário |
| border | white 8%  | bordas de card |
| green  | #22c55e   | ok / regen / EV |
| blue   | #38bdf8   | ações / info |
| orange | #fb923c   | consumo / atenção |
| teal   | #22d3ee   | recarga |
| yellow | #facc15   | alerta |
| red    | #ef4444   | crítico |

**Tipografia**: SF system; valores numéricos em `.rounded` semibold + monospacedDigit;
rótulos em CAPS caption com tracking 0.3–0.5. Formatação pt-BR (vírgula decimal,
ponto de milhar, R$).

**Forma**: cards RoundedRectangle radius 18 contínuo, borda 1px branca 8%; botões
radius 12–14; chips Capsule.

**Componentes base** (todos em `DesignSystem.swift`):
- `DSCard` — card padrão (título CAPS + ícone muted), variantes glass/compact/bg custom
- `DSMetric` — valor grande + unidade + rótulo CAPS
- `DSActionButton` — botão de ação grande com tint de cor, spinner de busy
- `LevelBadge` — ícone + valor + barra capsule de nível com marcador
- `DSChip` — pill de estado
- `CollapsibleCard` — recolhível, força aberto + borda amarela em anomalia
- `DSChoiceRow` — seletor segmentado grande

**Liquid Glass (iOS 26+)**: aplicado com moderação via modifiers centrais
(`glassControl`, `glassPanel`, superfície dos action buttons), com fallback
ultraThinMaterial para iOS < 26. Regra de ouro do dono: glass só em camada
flutuante sobre mapa/chrome — **cards densos de dados permanecem sólidos** (#0d0d0f)
pra legibilidade.

**Assets do carro**: PNGs reais do carro (vista frontal-lateral) com camadas
compostas por estado (portas, trava, luzes, AC esquerda/direita). É um elemento de
identidade forte — o dono gosta de ver "o carro dele" reagindo.

**Fora do app**: 5 Live Activities (recarga, pré-clima, viagem ao vivo, motor ligado,
segurança/destravado) via APNs push-to-start, widget de home screen. O redesign pode
propor evolução delas também.

## 5. Preferências do dono (histórico de feedback real)

- **Densidade > respiro**: reclamou quando cards ocuparam espaço do mapa; pediu
  paddings compactos; aprovou grid 2×2 de mini-cards ao lado do PNG.
- Detesta informação redundante (removeu "Bateria alvo" por "não fazer sentido";
  removeu botão Alcance; matou coluna de tabela que não usava).
- Curte visualização viva: timeline play/pause dos trajetos, carro animado no mapa,
  LA atualizando a cada 30s durante pré-clima.
- Gosta de ver opções visuais ANTES de implementar ("simula e me manda opções").
  Quando recebeu 3 variantes de layout, escolheu a mais densa (grid 2×2).
- pt-BR em toda a UI. Sem emoji na UI.
- Tema escuro é inegociável (uso noturno no carro).

## 6. Restrições técnicas do redesign

1. **SwiftUI puro**, iOS mínimo suportado ~17, com features iOS 26 gated
   (`if #available(iOS 26,*)`) e fallback. Nada de UIKit novo.
2. **Máx 5 tabs.** Telas novas = drill-down (sheet/navigation), não tab.
3. Dados chegam por WebSocket ~1Hz + REST do bridge; latência de comando 1–3s com
   verify — o design deve comportar estados "enviando/confirmando/falhou".
4. Estados offline/parcial existem: carro dormindo (dados stale com timestamp),
   sem rede, bridge fora. Mostrar frescor do dado é requisito (ex.: temp da cabine
   "há 4 min").
5. Paleta pode evoluir, mas precisa manter parentesco com PWA + cluster (mesmo
   ecossistema) e funcionar em dark.
6. PNGs do carro são fixos (vistas prontas em camadas); não há modelo 3D.
7. Charts nativos (Swift Charts) disponíveis; MapKit para mapas.
8. Tudo pt-BR, números formatados à brasileira.

## 7. O que se espera da proposta

- Direção visual **mais inovadora/atual** (o layout atual é "cards empilhados" —
  funcional mas convencional), mantendo densidade de informação.
- Repensar a hierarquia do Painel: o que merece hero, o que vira ambient info.
- Ideias para diferenciar Drive (cockpit) como experiência, não só overlay de mapa.
- Sistema de design coeso (tokens, componentes) que os componentes atuais possam
  migrar gradualmente — a migração é incremental, tela a tela.
- Mockups/descrições por tela + tokens propostos. Variantes A/B/C quando houver
  trade-off relevante, pra escolha rápida.
