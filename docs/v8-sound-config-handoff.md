# V8 Sound Config — Handoff de redesign

Tela de **configuração** do simulador de som V8. Onde o dono do carro afina o som (agressividade do escapamento, estalos, curva de rotação, câmbio virtual, etc). Diferente do V8 Cluster — essa aqui é **densa em controles**, não cinematográfica.

**Problema atual**: layout "bagunçado" — muita coisa empilhada, agrupamentos pouco intuitivos, difícil escanear e afinar. Redesign deve resolver isso.

## Contexto

- Roda no mesmo lugar do V8 Cluster: **HMI central do Haval H6 GT PHEV**, tela horizontal ~1920×720.
- Uso típico: dono para o carro, abre a tela, mexe em sliders/switches enquanto ouve o motor idle nas caixas. Ajusta até "soar certo", depois sai.
- **Uso mãos-no-volante** parado — dedos grossos, HMI capacitivo. Alvos de toque devem ser generosos (>44dp mínimo, ideal 56dp+).
- **Reação ao vivo**: cada slider aplica na hora — o som muda enquanto arrasta.

## Fluxo de uso real

1. Abrir tela → escolher **preset** de motor (V8 Mexido / V8 Muscle / V10 Super / V12 / 6-cil / 4-cil turbo). Preset seta 12 params de "caráter" de uma vez.
2. Ligar o **switch principal** (Motor V8 on/off) → som começa nas caixas do carro.
3. **Afinar** sliders individuais. Dono típico ajusta 2-3 coisas por sessão, não todos ao mesmo tempo. Volta várias vezes ao longo do tempo.
4. Deixar assim. Sai da tela.

## Controles atuais (24 no total)

### Estado geral
1. **Switch on/off** (Motor V8) — liga/desliga o som
2. **Tacômetro visual ao vivo** — mostra RPM/marcha atual pra feedback
3. **Preset picker** — 6 opções em chips (V8 Mexido, V8 Muscle, V10 Super, V12, 6 em linha, 4-cil turbo)

### Card "MIX"
4. **Volume geral** — 0-100%
5. **Volume no regen (freio-motor)** — 0-100%
6. **Timbre (grave ↔ brilhante)** — 800-6000 Hz (corte do low-pass)

### Card "ESCAPAMENTO"
7. **Rasp / grit** — 0-100% (rugosidade "mexido")
8. **Ronco / lope** — 0-1.5 (amplitude da meia-ordem, o "vrum" grave típico de V8)
9. **Agressividade sob carga** — 0-100% (harmônicas altas quando pisa)
10. **Estalos ao soltar (overrun)** — 0-100% (pipoco no lift/regen)
11. **Estalos ao acelerar forte (WOT)** — 0-100% (pipoco na aceleração)

### Card "ROTAÇÃO"
12. **Marcha lenta** — 400-1200 rpm
13. **Corte (redline)** — 4000-8000 rpm
14. **Rotação por km/h** — 10-90 (inclinação do câmbio virtual)
15. **Empurrão do acelerador** — 0-5000 rpm (quanto o pedal empurra rpm acima do cruzeiro)
16. **Potência p/ acelerador no fundo** — 30-200 kW (kW = WOT normalizado)

### Card "CÂMBIO VIRTUAL"
17. **Marchas** — 1-8 (1 = câmbio linear único, 2+ = câmbio automático simulado)
18. **Ponto de upshift** — 60-98% do redline (quando trocar pra cima)
19. **Kickdown** — switch on/off (desce marcha em aceleração forte)

### Não-visível na tela (mas existe no código)
- **firing_order** — V8=4, V10=5, V12=6, I6=3, I4=2 (setado por preset, não editável direto)

## Problemas que quero resolver

1. **Densidade**: 19 controles + preset + switch + tacômetro em uma tela vertical scrollável. Fica cansativo.
2. **Hierarquia**: alguns controles são "day-1" (volume, preset), outros são "tuning avançado" (empurrão, potência WOT). Hoje todos parecem iguais.
3. **Descobertabilidade**: o dono não sabe o que cada slider faz sem ler o label. Labels textuais ajudam mas não explicam "por que mexer nisso". Falta ícone/preview/exemplo visual.
4. **Feedback**: tacômetro tá lá em cima. Se você mexe no "Empurrão do acelerador" mas o carro tá parado (idle), você não escuta o efeito. Falta preview interativo (botão "testar aceleração" que simula 3s de WOT?).
5. **Presets escondidos**: chips de preset são 6 opções pequenas em FlowRow. Poderia ser mais visual (thumbnails com nome + descrição + som típico).

## O que quero que o design faça

**Repense a hierarquia**. Sugestão minha (mas você decide):

- **Nível 1 (sempre visível, topo)**: Switch on/off + Preset atual + Volume geral. É 90% do uso.
- **Nível 2 (tabs ou seções colapsáveis)**: MIX, ESCAPAMENTO, ROTAÇÃO, CÂMBIO. Cada uma exposta só quando o dono quer afinar.
- **Nível 3 (avançado, opcional escondido)**: params raros como "Empurrão do acelerador", "Potência p/ acelerador no fundo". Ficam num expander "AVANÇADO" ou similar.

**Ou reorganize completamente** se tiver ideia melhor. Ex: 
- Layout master-detail (esquerda: seções; direita: sliders da seção selecionada)
- Radial dial no meio pra params críticos
- Preset em card grande dominante com "afinar" abrindo drawer

## Device / constraints

- **Tela**: ~1920×720 landscape, HMI Haval H6 GT PHEV. Sem status bar.
- **Toque**: dedos grossos, HMI capacitivo. Alvos ≥56dp preferível.
- **Framework**: Jetpack Compose (código já pronto, componentes reutilizáveis: `ParamCard`, `ParamSlider`, `Switch`).
- **Tacômetro ao vivo**: já existe no código, pode reposicionar/redesenhar.

### Dados ao vivo pra usar em feedback visual
| Campo | Fonte | Uso sugerido |
|---|---|---|
| RPM atual | V8SoundEngine.displayRpm | Tacômetro, medidor visual |
| Marcha atual | V8SoundEngine.displayGear | Badge no header |
| Throttle | V8SoundEngine.displayThrottle | Barra de acelerador |
| Regen ativo | V8SoundEngine.displayRegen | Ícone/estado |
| Preset atual | V8SoundEngine.currentPreset | Highlight do preset selecionado |

## Presets — descrição pra você escolher visual

| Nome | Cara | Uso típico |
|---|---|---|
| **V8 Mexido** | Muscle americano com escape aberto, muito pipoco, rasp forte | Padrão default |
| **V8 Muscle** | V8 grande sem mods, low idle, ronco grave dominante | Cruise city |
| **V10 Super** | Alto, agudo, sem lope (Lamborghini/Audi R8) | Sport driving |
| **V12** | Grave uniforme, redline alto, muito refinado (Ferrari/Aston) | Cruise autoestrada |
| **6 em linha** | Suave, harmônicos limpos (BMW M3 clássico, Skyline) | JDM feel |
| **4-cil turbo** | Idle alto, whistle, pop-and-crackle exagerado | Modo tuner |

Se quiser reduzir/adicionar presets, propõe.

## Formato de entrega

Mesmo do handoff do V8 Cluster:
1. **Figma** com specs (medidas, cores, tipografia, hover/tap states, animações)
2. **PNG + specs** (mockup 1920×720 + doc separado)
3. **PDF/Sketch**

Pra cada estado quero ver:
- Layout inicial (fresco, nada selecionado)
- Preset selecionado (destacado)
- Uma seção expandida com sliders visíveis
- Um slider sendo arrastado (feedback visual)
- Modo "avançado" aberto (se propuser)

## Constraints técnicas

- **Sliders**: Material3 Slider padrão. Se quiser slider customizado (com trilho colorido tipo gradient, thumb maior, ticks visuais), mandar spec detalhado.
- **Ícones**: prefira Material Icons ou SVG que eu importo. Se propuser ícone custom pra cada param, mandar SVG.
- **Fonte**: Compose padrão. Fonte custom → mandar TTF/OTF.
- **Animações**: Compose animate*AsState / animatable. Não fazer física complexa.
- **Sem WebView/HTML**: tudo Compose nativo.
- **Persistência**: já resolvida no código. Você não se preocupa — cada mudança grava automático.

## Arquivo de referência (v0)

Código atual: `app/src/main/java/br/com/redesurftank/ecotrip/ui/screens/V8SoundScreen.kt` (361 linhas).

Componentes reutilizáveis já existentes:
- `ParamCard(title, content)` — box com título + conteúdo
- `ParamSlider(label, value, min, max, accent, formatter, onChange)` — slider label + valor formatado
- `Tachometer(rpm, redline, regen, throttle, accent)` — tacômetro Compose Canvas

Podem ser reaproveitados ou redesenhados.

## Perguntas abertas

- **Tacômetro nesta tela**: útil pra feedback ao afinar ou ocupa espaço demais? Talvez mini-tacômetro no header em vez do grande atual?
- **Preview de som**: valeria botão "TESTAR WOT" que faz o engine simular 3s de aceleração sem o carro se mover? Ajuda a afinar sem ter que dirigir.
- **Dark/light**: cluster do V8 é escuro (muscle). Config tem que combinar ou pode ser mais "tech neutro" (fundo escuro, accents brancos)?
- **Modo "só pro passageiro"**: durante a direção, muita config é distração. Fazer uma versão "safe driving" que só expõe volume + preset? Ou trava a tela toda enquanto anda?

---

**Prazo**: sem urgência. Preferência é Figma com specs.

**Contato**: dúvidas técnicas ou de dados aqui, respondo/ajusto.
