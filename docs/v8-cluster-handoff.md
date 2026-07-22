# V8 Cluster — Handoff de redesign

Tela dedicada dentro do app Haval Hub (APK Android que roda na multimídia do Haval H6 PHEV). Estilo cluster de muscle car / V8 esportivo. Foco: **experiência sensorial** (dirigindo, o passageiro vê e reconhece "V8 real"), não painel de config.

## Contexto

- Roda **no HMI central do carro** (não no cluster do motorista). É a tela grande de infoentretenimento.
- O motor real é elétrico + gasolina PHEV, mas o app **simula som + rotação de V8** via `V8SoundEngine`. Esta tela é o **visual** que acompanha o som — mostra o V8 virtual sendo dirigido.
- Já existe uma primeira versão implementada (`V8ClusterScreen.kt`). É o ponto de partida; pode ser reinventada do zero se quiser.

## Device

- **Multimídia Haval H6 GT PHEV** — tela horizontal ampla, resolução aproximadamente **1920×720 px** (proporção ~2.67:1). **Não é 16:9** — é bem mais horizontal, tipo painel de dashboard.
- Sempre **landscape**. App força orientation lock.
- **Sem status bar** (fullscreen quando ativo). O motorista vê a tela dele; passageiro do meio vê essa.

## Dados disponíveis ao vivo (todos, ~15Hz refresh)

| Campo | Fonte | Range típico | Observação |
|---|---|---|---|
| **RPM** | V8SoundEngine simulado | 650 (idle) → 6200 (redline) | Configurável — pode variar por preset |
| **Redline** | Config | 4000–8000 | Zona vermelha começa em 85% do redline |
| **Marcha** | Câmbio virtual | 1..N (N=1..8) | Se N=1 é "linear" (sem marchas) |
| **Total de marchas** | Config | 1..8 | Default 6 |
| **Throttle** | Simulado (potência normalizada) | -1 a +1 | Negativo = regen (freio motor) |
| **Velocidade** | CAN bus real do carro | 0 → 180 km/h | Sempre inteiro |
| **SOC bateria** | CAN | 0 → 100% | ≤15% é crítico |
| **Potência motor** | CAN | -80 → +160 kW | Negativa quando regenerando |
| **Combustível** | CAN | 0 → 100% | Nível do tanque de gasolina |
| **Temperatura externa** | CAN | -10 → 50°C | Bruto do sensor |
| **Gasto instantâneo** | CAN (disponível se pedir) | L/100km ou kWh/km | Não usado hoje, mas dá pra puxar |
| **Motor térmico ativo** | CAN (engine_speed>0) | boolean | 0 = só EV, >0 = combustão rodando |
| **AWD ativo** | CAN | boolean | Se o eixo traseiro (elétrico) está engajado |

Se você quiser mostrar algo que não está aí, avisa que a gente puxa — quase todo dado do CAN é acessível.

## Comportamento / animações

- **Troca de marcha (upshift/downshift)**: hoje tem um "flash" vermelho de 300ms no box da marcha. Pode ser algo mais elaborado: flip 3D, cross-fade, corte com "hint" de próxima marcha, etc.
- **Agulha do tacômetro**: hoje segue o rpm ao vivo (interpola frame a frame no engine). Cor muda por carga.
- **Redline**: hoje é uma zona vermelha estática no arco. Pode ter shake, glow pulsante ou aviso especial quando o rpm entrar ali.
- **Throttle bar**: linear hoje. Pode virar boost gauge estilo turbo, medidor circular, etc.
- **Regen**: hoje muda cor da agulha (azul). Pode ter feedback visual mais forte (marcador "REGEN" grande, motor a combustão apagando, etc).
- **Kickdown**: downshift agressivo. Poderia ter alerta visual ("KICK!").
- **SOC crítico** (≤15%): hoje só fica vermelho o número. Pode ter aviso mais dramático.

## Fluxo de estados

1. **Carro parado, motor ligado, marcha lenta**: RPM idle (650), gear "N", velocidade 0. Barra de throttle zerada. É o que aparece na maior parte do tempo antes de sair.
2. **Aceleração leve**: RPM sobe suave dentro da marcha atual, velocidade sobe. Agulha verde.
3. **Aceleração forte / WOT (wide open throttle)**: RPM sobe rápido, chega perto do redline, upshift automático → RPM cai pra ~55% da nova marcha, sobe de novo. Agulha vermelha na zona.
4. **Cruzeiro em alta**: última marcha, RPM baixo (~2000-3000), velocidade alta. Motor "descansando".
5. **Regen / freio motor**: throttle negativo, agulha azul, RPM cai. Barra de throttle vira azul e cresce pro lado inverso (ou ícone especial).
6. **Kickdown**: pisou fundo em rpm baixo → downshift, RPM salta pra ~75%. Marcha muda pra baixo com "flash".

## Referências visuais (inspiração)

- **Dodge Challenger Hellcat cluster** — velocímetro digital central gigante, arco de tacômetro, feel "muscle americano"
- **Mustang GT500 track apps** — cores agressivas, glow vermelho, layout modular
- **Ford GT digital cluster** — minimalismo tech, tudo animado
- **Aston Martin DB11 SVJ / Ferrari SF90** — analógico + digital híbrido, sem excessos
- **BMW M Performance** — clean, dados densos mas legíveis à distância

Não precisa copiar. Só pra referência de "vibe".

## Constraints técnicas

- **Renderização**: Jetpack Compose + Canvas (código já pronto). Você pode usar formas customizadas, arcs, paths, gradients, blur, shadows, animações.
- **Sem imagens raster** por padrão — se quiser texturas/backgrounds imagéticos, mandar em PNG/WebP e viramos assets. Vetor (SVG) é ideal — vira ImageVector Compose.
- **Fontes**: hoje usa `FontFamily.Monospace` pros números. Se quiser fonte específica (ex: font digital tipo LCD, ou display italic tipo muscle), mandar TTF/OTF.
- **Framerate**: até 60fps, mas Compose Canvas típico opera a 15-30fps sem ruído perceptível. Não usar animações que dependam de 60fps.
- **Sem WebGL/3D**: renderização é 2D. Efeitos 3D são fake (perspectiva desenhada).
- **Cor de fundo**: pode ser gradient, mas evitar imagens grandes (memória). Sólido ou gradient é ideal.

## Formato de entrega

Aceito qualquer um destes formatos (do mais útil pro menos):

1. **Mockup Figma** com specs (medidas, cores hex, gradient stops, tipografia). Link + acesso view.
2. **PNG + specs** — mockup em PNG na resolução alvo (1920×720) + doc separado com hex/px/font.
3. **PDF/Sketch** exportado.

Pra cada elemento, preciso saber:
- Posição e tamanho (px ou proporção)
- Cores (hex) — inclusive gradient stops
- Tipografia — família, weight, tamanho, letter-spacing
- Estado default vs estados especiais (troca de marcha, redline, regen, crítico)
- Animações desejadas (duração, easing, o que anima)

Se quiser propor mais de um layout (ex: 2 opções), melhor ainda — eu escolho ou o dono do carro escolhe.

## Perguntas abertas (você decide)

- **Layout**: tacômetro à esquerda / velocímetro à direita é obrigatório? Pode inverter, empilhar, ou fazer velocímetro central gigante com tacô como anel externo (estilo Ford GT).
- **Marcha**: box separado ou embutido no tacômetro/velocímetro?
- **Strip inferior**: hoje tem SOC/kW/gasol./temp. Manter, cortar, mudar priorização? O que **NÃO** cabe deixamos de mostrar.
- **Preset por horário/modo?** — ideia opcional: cluster muda de "modo esporte" (vermelho agressivo) pra "modo cruise" (mais sóbrio, azul) baseado no throttle recente. Se você achar interessante, propõe. Se acha exagero, ignora.

## Arquivo de referência (v0)

Código atual da tela: `app/src/main/java/br/com/redesurftank/ecotrip/ui/screens/V8ClusterScreen.kt` — 335 linhas, tudo Compose Canvas. Pode reutilizar código como base ou descartar.

---

**Contatos técnicos** (dúvidas sobre dados/APIs disponíveis, comportamentos, constraints): responder direto neste mesmo canal que ajusto pra você.

**Prazo**: sem urgência — quando quiser mandar. Preferência é layout **1**.
