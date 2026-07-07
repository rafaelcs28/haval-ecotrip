# Handoff: Live Activities — revisão (9a viagem km-hero, 9b destravado)

Complemento ao `README.md`. A Rodada 9 **substitui** as LAs de deslocamento da seção
"Live Activities" do README (antiga 2a) e **adiciona** a LA de carro destravado.
Mockups nos ids `9a` e `9b` do canvas `Painel Redesign.dc.html`.

Tokens, tipografia e motion: iguais ao README principal.

---

## 9a · LA Viagem em curso — km como hero (substitui 2a)

Mudança de hierarquia: **distância percorrida** é o hero; velocidade desce para a
régua de micro-métricas.

### Tela bloqueada (raio 24, gradiente green 135deg sobre panel, borda green .28)
- Header: app icon 22 + `Haval · Viagem em curso` | ponto breathe + `agora`.
- Linha hero: `8,2` **44pt/200** tracking −2 monospaced + `km` 14pt muted +
  `de 12,4` 12pt text2. À direita: `→ Escritório` 14pt semibold sobre
  `chega 17:56 · faltam 4,2 km` 11pt text2.
- Barra de progresso do trajeto (h6, fill green %percorrido, ponto branco 10px com
  glow green na posição) + rótulos `CASA` / `ESCRITÓRIO` (9pt caps muted).
- Régua de micro-métricas (space-between, 10,5pt text2 monospaced):
  `72 km/h` · `18 min` · `13,9 kWh/100` · `SOC 71%`.

### Dynamic Island
- **Expandida**: leading = seta nav em circle-tint green 40px; centro =
  `8,2 km · → Escritório` 13pt semibold + `faltam 4,2 km · chega 17:56` 11,5pt text2;
  trailing = `LIVE` pulsando + `SOC 71%`.
- **Compacta**: leading seta green · trailing **`8,2 km`** green monospaced
  (atualiza a cada ~500 m; é o número que cresce).
- **Minimal**: seta green.

Update: a cada 30 s ou 500 m percorridos. Fim de viagem → transição para resumo
(km total, tempo, kWh/100, score) que se dispensa em ~10 s.

---

## 9b · LA Carro destravado (nova)

Gramática de **anomalia** — mesma do card 3b do Painel: red, o que está aberto,
há quanto tempo, distância do usuário, e **ação Travar inline** (App Intent — trava
sem abrir o app).

### Tela bloqueada (raio 24, gradiente red .14 → panel 58%, borda red .38)
- Header: app icon + `Haval · Estac. Flamboyant G2` (localização curta) | tag
  `ATENÇÃO` (10pt, caps, red, **ecoPulse**).
- Corpo (linha, gap 13): PNG do carro 56px (drop-shadow) | coluna:
  `Destravado` **26pt/300 red**, `Porta traseira esq. aberta` 11,5pt text,
  `há 12 min · você a 1,2 km` 10,5pt text2 monospaced | coluna trailing:
  **botão `Travar`** (pill red, texto preto 13pt bold, padding 9×18) + micro-hint
  `fecha vidros junto` 8,5pt muted.
- Rodapé (hairline .06 acima): `Vidros fechados · teto fechado` | `Ver no mapa →`.

### Estado pós-ação (a mesma LA muda no lugar)
1. Tocou Travar → botão vira `Enviando…` (tint yellow, ecoPulse) — máquina 2b.
2. Confirmado → o card inteiro troca para a variante **verde de confirmação**:
   circle-check green 34px, `Travado · o carro confirmou` 13pt semibold,
   `porta fechada · respondeu em 2,4 s` 10,5pt text2, hora à direita.
   **Auto-dispensa em ~5 s** (`ActivityContent` com stale date).
3. Falha → borda red mais forte, botão vira `Tentar` (red), sub `carro não respondeu`.

### Dynamic Island
- **Expandida**: leading cadeado aberto em circle-tint red 40; centro
  `Destravado há 12 min` 13pt red + `porta traseira esq. aberta` 11,5pt text2;
  trailing botão `Travar` (pill red, texto preto).
- **Compacta**: cadeado aberto red · **contador `12 min`** red monospaced (tempo
  destravado — cresce, cria urgência).
- **Minimal**: cadeado red.

### Regras de disparo
- Inicia quando: destravado + usuário se afasta > ~200 m do carro, OU destravado
  parado > 5 min, OU qualquer porta/porta-malas aberto com usuário longe.
- Escalada: aos 15 min sem ação → notificação crítica adicional.
- Encerra: carro travado (por qualquer meio) → variante confirmação → dispensa.

## Dados consumidos
`locked`, `doors[]`, `trunk`, `windows`, `roof`, `unlockedSince` (timestamp),
`userDistanceToCar` (CoreLocation), `parkedLocationShort` (reverse geocode curto),
resultado do comando com latência. Viagem: `tripDistance`, `tripDistanceTotal`
(rota conhecida/estimada), `eta`, `remainingKm`, `speed`, `tripMinutes`,
`consumption`, `soc`.

## Referência visual
Canvas `Painel Redesign.dc.html`, seção "Rodada 9" (ids `9a`, `9b`).
