# Handoff: Drive — Sheets de Clima (8a) e Controles (8b)

Complemento ao `README.md` deste pacote. Cobre os dois sheets abertos pelos botões
flutuantes da coluna direita do Drive (tela 4a): **Clima** (snowflake teal) e
**Controles** (novo botão, ícone de carro/controles). Mockups nos ids `8a` e `8b` do
canvas `Painel Redesign.dc.html`.

Tokens, tipografia, motion e máquina de estados de comando: iguais ao README principal.
Este doc só descreve o que é específico das duas telas.

---

## Comportamento comum aos dois sheets

- **Apresentação**: sheet parcial (SwiftUI `.sheet` com detent médio/alto customizado)
  sobre o Drive; **o mapa continua vivo atrás** — visível na faixa superior, com a pill
  de navegação (`→ Escritório · 8 min · 72 km/h`, glass) permanecendo funcional.
- **Container**: fundo sólido `panel #0d0d0f`, raio 24 no topo, borda superior
  `rgba(255,255,255,.1)`, sombra `0 -12px 36px rgba(0,0,0,.55)`, grab handle
  (36×4, `rgba(255,255,255,.14)`), padding horizontal 18.
- **Header do sheet**: título 16pt bold à esquerda + **chip de estado ao vivo**
  (Clima: `Ligado` teal com fan girando · Controles: `Travado` green com cadeado);
  botão fechar 30px (círculo panel2 + xmark) à direita. No Clima, entre o chip e o
  fechar: `cabine 25,5° · externa 31°` (11pt muted, monospaced).
- Todos os comandos seguem a **máquina de estados 2b** (padrão → enviando amarelo
  pulsando → confirmado/falhou). Nada de spinner genérico.

---

## 8a · Sheet Clima

Estrutura vertical (de cima pra baixo):

1. **Hero de temperatura** (setpoint):
   - Centro: `22,0` 76pt/200 tracking −3 monospaced + `°C` 18pt muted; sub-linha
     `resfriando · chega em ~4 min` (10,5pt **teal** quando resfriando; laranja
     `aquecendo · …` quando aquecendo; muted `mantendo` quando estável).
   - Steppers circulares 52px (panel2, borda .1): `−` em **blue #38bdf8**, `+` em
     **orange #fb923c**, glifo 24pt/400. Press: scale .97; long-press repete.
   - Range 16–30 °C, passo 0,5. Envio com debounce ~800 ms após o último toque
     (não spamma o MQTT); enquanto aguarda confirmação o valor fica com sub-linha
     amarela `enviando…`.
2. **VENTILAÇÃO** (micro-rótulo CAPS + `nível 3 de 7` à direita):
   7 segmentos h26 raio 7, gap 5 — preenchidos em **teal #22d3ee**, vazios panel2 com
   borda .07. Toque no segmento define o nível (arrastar também). Nível 0 = tudo vazio.
3. **Linha de modos** (grid 4, tiles h56 raio 13):
   - `A/C` — texto 13pt bold; ativo = tint teal (fill .15, borda .4, label teal).
   - `Recircular` — ícone + label 9pt; toggle simples.
   - `Desembaçar` — para-brisa com ondas; ativo = tint teal.
   - `AUTO` — texto; ativo = tint green (o carro gerencia fan+distribuição).
   Estado inativo: panel2, borda .08, conteúdo text2.
4. **Assentos** (grid 2 cards panel2 raio 13):
   micro-rótulo `ASSENTO · MOTORISTA` / `ASSENTO · PASSAG.`; estado
   `Aquecer · nível 2` (**orange**; ventilar seria teal; `Desligado` muted);
   à direita, 3 barrinhas de nível (5×8/12/16, raio 2) preenchidas na cor do modo,
   vazias panel3. Toque cicla: off → aquecer 1→2→3 → ventilar 1→2→3 → off.
5. **Presets** (2 pills h~34):
   `Máx frio 5 min` (tint teal — liga A/C máx + fan 7 por 5 min, depois volta) e
   `Sincronizar zonas` (neutra panel2). Preset ativo mostra countdown na própria pill
   (`Máx frio · 3:40`).

Fecho: padding-bottom 28 (home indicator).

**Estados**: carro dormindo → sheet abre com banner 1 linha `Comandos vão acordar o
carro` (blue) e telemetria dimmed; comando enviado acorda. AC desligado → hero fica
muted (valor cinza-claro), chip `Desligado` neutro, tile A/C vira o CTA primário.

## 8b · Sheet Controles

1. **Diagrama do carro** (h~190, centrado):
   - `assets/haval-h6.png` vista superior 150px, glow radial green sutil atrás,
     drop-shadow.
   - **Pills de estado ancoradas** a cada abertura (9,5pt semibold, raio 999):
     4 vidros (cantos) + teto (topo centro). Estados: `fechado` (glass neutro
     `rgba(31,31,31,.85)` + borda .08, text2) · `aberto`/`33 %` (tint yellow ou red se
     porta) · `fechando…`/`abrindo…` (tint yellow + **ecoPulse**).
   - Portas/porta-malas abertos: pill red na posição correspondente (mesma gramática
     do card de anomalia 3b).
2. **Ações de vidros** (grid 2, tiles h58 raio 13, ícone 18 + 2 linhas de texto):
   `Fechar vidros` / `Abrir vidros` (sub `todos · 100%`). Tile em execução vira o
   estado enviando: tint yellow, ícone clock, `Fechando vidros…` + sub
   `aguardando o carro`, ecoPulse. Blue quando neutro (ação de vidro = blue).
3. **Travas e acessos** (grid 4, tiles h58): `Travar` (green) · `Destravar` (neutro;
   exige Face ID se configurado) · `Porta-malas` · `Teto solar`.
4. **Sinalização e motor** (grid 3, tiles h50, layout horizontal ícone+label):
   `Piscar faróis` (yellow) · `Buzinar` (neutro) · `Motor` (orange; long-press para
   ligar remoto, com confirmação).
5. **Toast persistente de comando em curso** (pill glass, borda yellow .3):
   `Fechar vidros · enviado há 2 s` + **`Cancelar`** à direita. Vive enquanto houver
   comando aguardando verify; contador atualiza por segundo; sucesso troca por toast
   green de confirmação (`Vidros fechados · 3,1 s`) que some em ~2 s; falha troca por
   toast red com `Tentar`.

**Estados**: dirigindo → ações sem sentido em movimento (abrir porta-malas, teto)
a 45% opacity + disabled; destravado → chip do header vira `Destravado` red.

---

## Dados consumidos (além do README)

Clima: `acOn`, `acTarget`, `acMode` (cool/heat/idle), `fanLevel` (0–7), `recirc`,
`defrost`, `autoMode`, `seatDriver` {mode, level}, `seatPass` {mode, level},
`tempCabin`, `tempExt`, `etaSetpoint` (min estimados). Controles: `windows[4]`
(pct + moving), `roof` (estado + moving), `doors[]`, `trunk`, `locked`,
`engineRemote`, comandos pendentes com timestamp de envio (para o contador do toast).

## Referência visual

Canvas `Painel Redesign.dc.html`, seção "Rodada 8" (ids `8a`, `8b`). Frames 402×874.
