# MacroDroid ↔ bridge: destino nos dois sentidos

Duas macros independentes. Faça a 1 primeiro (é a que eu preciso pra ligar do meu lado).

---

## Preparo (uma vez)

**Habilitar webhook:** MacroDroid → ⚙️ Configurações → **Gatilhos remotos / Webhooks** →
ligar. Isso é o que gera as URLs `trigger.macrodroid.com`.

**Gerar token do bridge:** abra `https://bridge.malha.dev/health.html` → aba **Tokens** →
criar token com escopo **write**, nome `macrodroid`. Copie na hora (só aparece uma vez).
Só a macro 2 precisa dele.

---

## MACRO 1 — destino do carro/app abre no Waze

Essa é a que resolve o seu incômodo: você seta em um lugar e o Waze abre navegando.

**Gatilho**
1. Nova macro → **Gatilhos** → **+** → categoria **Conectividade** → **Webhook (URL)**
2. Em *Identificador*, escreva exatamente: `waze_dest`
3. Toque em **Copiar URL**. Vai ficar tipo
   `https://trigger.macrodroid.com/a1b2c3d4-.../waze_dest`
4. **Me manda essa URL** — é o único dado que eu preciso.

**Ação**
5. **Ações** → **+** → **Aplicativos** → **Abrir URL / Website**
6. URL:
   ```
   waze://?ll={lv=lat},{lv=lng}&navigate=yes
   ```
7. Salvar. Sem restrições, sem condições.

**Como eu vou chamar:** `…/waze_dest?lat=-16.622880&lng=-49.232928&name=Consórcio+Limpa+Gyn`

**Se o Waze abrir sem navegar** (ou abrir no lugar errado), o nome da variável do
webhook mudou de versão. Pra descobrir o certo: troque temporariamente a ação por
**Notificações → Mostrar notificação** com o texto `lat={lv=lat} lng={lv=lng}`, dispare
a URL no navegador e veja o que aparece. Se vier literal (`{lv=lat}` cru), o formato da
sua versão é outro — em algumas é `{v=lat}` ou as variáveis chegam nomeadas como
`wh_lat`. Me diz o que apareceu e eu ajusto o lado do bridge pra casar.

---

## MACRO 2 — destino do Waze/Maps vai pro carro

Esse sentido já existia no bridge e nunca teve app do outro lado. O MacroDroid faz o papel.

**Gatilho**
1. Nova macro → **Gatilhos** → **+** → **Dispositivo/Sistema** → **Compartilhar**
   (em algumas versões: *MacroDroid no menu de compartilhamento* / *Share received*)

**Ação**
2. **Ações** → **+** → **Conectividade** → **Requisição HTTP** (HTTP Request)
3. Método: **POST**
4. URL: `https://bridge.malha.dev/api/share-dest`
5. **Cabeçalhos**:
   ```
   Authorization: Bearer <TOKEN_QUE_VOCÊ_GEROU>
   Content-Type: application/json
   ```
6. Corpo (JSON):
   ```json
   {"text":"{lv=share_text}"}
   ```
   Se sua versão usar outro nome pra o texto compartilhado, troque `share_text` pela
   variável que o gatilho oferecer (a lista aparece no seletor de variáveis mágicas).

**Como usar:** no Waze ou Maps, no destino → **Compartilhar** → escolher **MacroDroid**.
O bridge resolve a coordenada e publica pro carro.

---

## O que cada sentido faz

| você faz | acontece |
|---|---|
| escolhe destino no app Haval Hub / atalho iOS | carro **e** Waze recebem |
| toca "Sim" na LA "Indo pra X?" ao sair de casa | carro **e** Waze recebem (antes só o carro) |
| compartilha um lugar do Waze/Maps → MacroDroid | carro recebe |

---

## Notas

- Do meu lado já está implementado e testado isolado; fica inerte até eu preencher
  `WAZE_WEBHOOK_URL` com a URL da macro 1.
- Falha no webhook **não** quebra o destino no carro — só loga. O carro nunca depende
  do celular estar acordado.
- Coordenada inválida (`0,0` ou não numérica) é descartada antes de chamar.
- O `name` vai no webhook mas o deep link do Waze não usa (ele navega por coordenada).
  Serve se você quiser mostrar numa notificação.
