# Handoff de redesenho — Bridge Health

Documento pra quem vai redesenhar a página. Quem implementa depois sou eu (Claude
Code), direto no arquivo real. Leia a seção **Contrato técnico** antes de decidir
qualquer coisa: ela é o que separa um mock que eu implanto em 20 minutos de um que
exige reescrever a camada de dados.

---

## 1. O que é

Página única de monitoramento (`bridge/public/health.html`, 1824 linhas, HTML+CSS+JS
inline, sem build, sem framework) servida pelo próprio bridge Node que ela monitora.

O que ela vigia: um Mac Mini rodando em casa 24/7 e tudo que pendura nele — o bridge
do carro (Haval PHEV conectado), 3 plantas solares, 2 estações portáteis Bluetti que
seguram o Mac e a Starlink do sítio, broker MQTT, túnel Cloudflare, Tailscale, Home
Assistant, app de ponto eletrônico, assistentes de WhatsApp, APNs/Live Activities e
backups.

**Contexto de uso real** (isso deveria guiar o desenho mais que qualquer coisa):

- 90% dos acessos são **no celular, em pé, com 5 segundos de atenção**, geralmente
  depois de um push de alerta chegar. A pergunta é sempre a mesma: *"o que quebrou e
  preciso agir agora?"*
- 10% é no desktop, sentado, investigando algo — aí quero ver bastante coisa junto.
- Dono único (solo dev). Não é dashboard de equipe, não precisa onboarding, não
  precisa explicar termos. Jargão é bem-vindo.
- Já existe camada de alerta por push (ntfy) pra urgência. A página é pra
  **confirmar, contextualizar e investigar** — não é o canal primário de alarme.

---

## 2. O que quero do redesenho

Em ordem de importância:

1. **Triagem ao bater o olho.** Hoje preciso ler para descobrir se está tudo bem.
   Quero saber em 2 segundos, sem abrir nada, se está tudo verde ou o que está
   ruim — e onde. Se algo está ruim, quero chegar nele sem procurar.
2. **Abrir e fechar.** Manter a ideia de detalhe sob demanda (hoje é
   `<details>/<summary>` com estado persistido por card). O que muda é o critério do
   que fica visível fechado.
3. **Adequar ao dispositivo.** Celular = mais compacto/minificado, o essencial.
   Desktop = mais aberto, várias colunas, mais dado simultâneo. Hoje é a mesma
   coluna de 480px nos dois, o que desperdiça o desktop e ainda assim fica longo no
   celular.
4. **Parecer página de monitoramento**, não lista de configurações. Hoje são 21
   caixas iguais empilhadas, com peso visual idêntico entre "o carro está sem
   telemetria há 3h" e "versão do Node".

Não é pedido de rebranding. Paleta escura e densidade técnica estão certas — o
problema é hierarquia e estrutura.

---

## 3. Restrições técnicas duras (não negociáveis)

| Restrição | Por quê |
|---|---|
| **Um arquivo só**, HTML+CSS+JS inline | Servido por `express.static` do bridge; não tem build step, bundler ou pipeline de assets |
| **Zero rede externa**: nada de CDN, Google Fonts, CSS/JS remoto, imagem remota | A página tem que abrir quando a internet da casa caiu — é exatamente aí que ela é mais necessária |
| **Sem dependência nova** (sem Tailwind, React, Chart.js…) | Mesmo motivo. CSS na mão. Gráfico, se tiver, é `<canvas>` na mão (já existe um sparkline assim) |
| **Fontes do sistema** (`-apple-system, sans-serif`) | Idem |
| **Dark only** | Uso noturno, tela do iPhone. Não precisa light mode |
| **Safari iOS é o alvo nº 1** | `env(safe-area-inset-*)` já usado; evitar CSS que o Safari ainda não suporta |
| **Números tabulares** (`font-variant-numeric: tabular-nums`) | Valor que muda a cada 5s não pode dançar na tela |
| **Sem emoji novo como ícone semântico** | Já tem alguns e eu não gosto; prefira bolinha de cor, forma ou texto |

Sobre ícones: não posso baixar icon set. Se quiser ícone, tem que ser SVG inline
escrito à mão (poucos, simples) ou nada.

---

## 4. Inventário completo — 21 cards

Ordem atual da página, de cima pra baixo. `[A]` = aberto por padrão hoje.

| # | Card | Conteúdo (linhas rótulo→valor) |
|---|---|---|
| 1 | **Processo** `[A]` | Status · Uptime bridge · Iniciado em · Node · APK version |
| 2 | **Mac** `[A]` | Uptime · Memória em uso · Memória disponível · Disco livre · SSD externo · Tendência disco · Tendência SSD · Tendência RSS bridge · sparkline de memória |
| 3 | **Processos** `[A]` | Tabela ordenável estilo Activity Monitor (top 30: pid, CPU%, mem%, RSS, user, comando) + barras de memória |
| 4 | **Conexões** | MQTT broker · MQTT latência · Último dado APK · Chave APK · Carro acordado · Chave (live) · Último dado GWM · Clientes WS · Clientes áudio |
| 5 | **Solar Catalão** | 11 linhas da planta (gerando agora, direção, hoje, pico, horas sol pleno, mês, total vida, CO₂, última sync, nascer/pôr) **+ 2 blocos de inversor** de 7 linhas cada (potência, energia hoje, temperatura, rede, string 1, string 2, alarmes) |
| 6 | **Solar Ivonei** | Status · Gerando · Hoje · Mês · Total vida · Nascer/pôr · Inv 1 · Inv 2 |
| 7 | **Solar Palmeiras** | Status · Gerando · Hoje · Mês · Total vida · Nascer/pôr · Inv |
| 8 | **Estações portáteis** | 2 blocos idênticos (Casa / Sítio) de 8 linhas: Status · Bateria · Autonomia · Modo · Entrada rede · Entrada solar · Saída AC · Saída DC. Mais uma **faixa de aviso** condicional ("login da Bluetti vence em N dias → clique pra religar") |
| 9 | **Família** | Lista de pessoas + localização |
| 10 | **Clockin** | HTTP · Saúde · Versão · Latência · Último backup · Funcionários · Push (admin/disp.) · Problemas |
| 11 | **Haval** | Status · APK últ. dado · GWM últ. dado · Ativo há · Alertas ativos · Última telemetria · SOC · Potência · Carregando · Executor APK/Shizuku · Automações 24h |
| 12 | **Grasi (BYD)** | Última telemetria · SOC · Potência · Carregando |
| 13 | **Assistentes (WhatsApp)** | Lista de 2 instâncias com estado |
| 14 | **Backups** | iCloud sincronizado + lista de 5 backups (nome, idade, tamanho, ok/falha) |
| 15 | **APNs / Live Activities** | Estado · Ambiente · Tokens (start/upd/alert) · Atrito (mortos 24h/total) · Último envio · Último erro |
| 16 | **Tokens** | O mais complexo: fluxo de senha + 2FA (definir senha, gerar QR, confirmar, entrar, sair), sessão, gerar/copiar token, lista de tokens emitidos com revogar. **27 ids.** É um mini-painel de admin dentro do card |
| 17 | **Cloudflare** | Túnel · Conexões de edge · cloudflared local · Hostnames · URL do servidor · URL dos links do carro · Funnel (ts.net) · Acessos por host + botão `zerar` |
| 18 | **Rede** | 17 linhas: Tailscale · Funnel ingress · Gateway LAN · Mosquitto 1883/1884/8883 · Home Assistant · Monitor externo (+último ping) · IP público · DuckDNS resolve · DNS correto · Cert TLS · Cert broker MQTT · Banda ↓/↑ · Link local · Verificado |
| 19 | **Starlink · Sítio** | Conectividade · Ping · Perda de pacote · Download/Upload · Tráfego sessão · Consumo · Diagnóstico · Quedas hoje · Fora do ar hoje · Quedas 7d · Fora do ar 7d · Quedas 30d · Fora do ar 30d · Contando desde · Uptime do dish · Última leitura + botão `Zerar contadores` |
| 20 | **HA do Sítio** | Último push · Guards · chips de Serviços · chips de Uptime 7d · lista de transições |
| 21 | **Erros / crashes** | Lista de eventos (hora, tipo, mensagem) + botão `✕ Limpar` |

**Topo da página, acima dos cards:** título "Bridge Health", botão `Expandir tudo`,
botão `↻`, linha de "última atualização", e um **grid de 4 stat boxes** (1h / 24h /
7d / 30d) com contagem de restarts e erros por janela.

---

## 5. Estados que cada valor pode ter

Isto é o que mais falta hoje — a página tem 3 cores mas os estados são 5:

1. **OK** — verde ou neutro
2. **Atenção** — amarelo (degradado mas funcionando: latência alta, bateria baixa,
   cert vencendo, obstrução)
3. **Crítico** — vermelho (caiu, AC desligado, sem comunicação)
4. **Sem dado / desconhecido** — hoje aparece `—`, visualmente igual a "zero", o
   que é ruim: "0 W" e "não sei" não podem ter o mesmo peso
5. **Velho** (stale) — o dado existe mas é de 40 minutos atrás. Vários cards
   dependem disso (carro dormindo, Starlink sem link, monitor externo) e hoje isso
   se lê como se fosse atual

Precisa de tratamento visual pros 5. Especialmente **4 e 5**.

---

## 6. Interações que já existem (manter)

- Cada card é `<details>`; **aberto/fechado persiste em `localStorage`** por card
  (chave `health_open`)
- Botão `Expandir tudo` / `Recolher tudo` alterna todos
- Auto-refresh escalonado: payload principal a cada 5s; solar/Starlink/família a
  cada 60s; Cloudflare 45s; Bluetti 30s
- Tabela de processos é **ordenável por coluna** (clique no header)
- Ações destrutivas com `confirm()`: limpar erros, zerar contadores da Starlink,
  zerar acessos por host, revogar token
- Autenticação: token do bridge pedido por `prompt()` no primeiro acesso e guardado
  em `localStorage`; card Tokens tem sessão admin própria (senha + TOTP) em
  `sessionStorage`

---

## 7. Design tokens atuais

```
--bg:     #0f0f0f      fundo da página
--panel:  #1a1a1a      fundo do card
--border: rgba(255,255,255,.07)
--text:   #e2e8f0
--muted:  #64748b      rótulos
--green:  #a3e635
--red:    #f87171
--yellow: #fbbf24
```

Tipografia: título 17px/700 · título de card 11px/700 uppercase letter-spacing .8px ·
rótulo 12px muted · valor 13px/600 tabular · nota 10-11px.
Card: radius 14px, padding 13px 15px. Linha: flex space-between, borda inferior 1px.
Página: `max-width: 480px`, coluna única, gap 12px.

Pode trocar tudo isso se justificar. O que **não** quero é ficar mais claro ou mais
"produto SaaS" — é ferramenta de operação.

---

## 8. Diagnóstico do que está bagunçado

Minha leitura, pra você não ter que adivinhar:

1. **Nenhuma hierarquia.** 21 cards com peso visual idêntico. "Carro sem telemetria"
   e "versão do Node" competem igual.
2. **Sem visão de saúde geral.** Não existe um lugar que diga "3 problemas, aqui".
   Os 4 stat boxes do topo mostram restarts/erros — que é histórico, não estado.
3. **Fechado não informa.** O resumo do `<summary>` existe em alguns cards e em
   outros não, e onde existe não é padronizado. Então fechado eu não sei se está bem,
   e preciso abrir — o que anula o colapso.
4. **Ordem é histórica, não por importância.** Foi crescendo por acréscimo. Solar
   (3 cards, ~50 linhas) vem antes do carro e da rede.
5. **Coluna de 480px no desktop** — 70% da tela vazia, e a página fica com metros de
   scroll.
6. **Assuntos parecidos espalhados.** Cloudflare, Rede, Starlink, HA do Sítio e
   Conexões são todos "conectividade" e estão em 5 caixas separadas, em posições
   distantes.
7. **Card Tokens é outro bicho.** É formulário/admin dentro de uma página de leitura.
   Provavelmente devia sair pra outro lugar ou virar uma gaveta separada.
8. **Densidade uniforme.** Tudo é linha rótulo→valor. Nada de barra, mini-gráfico,
   chip, matriz — mesmo onde caberia melhor (portas, serviços, strings do inversor).

---

## 9. O que eu preciso de volta

1. **Um HTML único** (CSS inline, JS só o necessário pra interação de layout) que
   eu possa usar como referência de estrutura e estilo. Não precisa ter dado real
   nem fetch — pode ser markup estático com valores de exemplo (uso os da seção 11).
2. **Layout mobile e desktop** definidos: onde quebra, quantas colunas, o que
   colapsa/expande por padrão em cada um.
3. **Um componente de triagem** no topo: como eu vejo "está tudo bem" ou "isto aqui
   está ruim" sem abrir card. Se for um resumo com contagem + atalhos, mostre o
   estado com 0, com 1 e com vários problemas.
4. **Padrão de card fechado**: o que aparece no `summary` — precisa ser regra
   uniforme, não caso a caso.
5. **Os 5 estados da seção 5** especificados visualmente, com exemplo de cada.
6. **Agrupamento proposto** dos 21 cards (o que junta, o que vira aba/seção, o que
   sai da página). Fique livre pra propor menos caixas.
7. **Tokens** (cores, tamanhos, espaçamentos) em `:root`, pra eu manter consistência
   ao adicionar card novo depois — isso acontece toda semana.

Não precisa: light mode, animação elaborada, sistema de ícones, i18n (é PT-BR só),
acessibilidade de leitor de tela (uso pessoal, mas contraste bom eu quero).

---

## 10. Contrato técnico — leia antes de mudar estrutura

O JS atual preenche a página por **`document.getElementById(id).innerHTML`**, com
~200 ids fixos (ex.: `sl-ping`, `bl-casa-battery`, `head-starlink`, `s-h24-r`). Cada
card tem uma função de update que fala com um endpoint.

Então:

- **Se você mantiver os ids**, eu implanto o redesenho quase só trocando markup e CSS.
- **Se renomear ou reestruturar** (o que é legítimo, e provavelmente necessário pro
  agrupamento), me entregue uma **tabela `id antigo → id novo`** ou deixe os ids nos
  elementos equivalentes. Sem isso eu tenho que reescrever as 8 funções de update
  mais o `load()` inteiro, e o risco de deixar campo órfão silencioso é alto.
- Valores chegam **já formatados, como HTML** (às vezes com `<span style="color:…">`
  dentro). Se o desenho depender de estado semântico em atributo
  (ex.: `data-state="warn"`), diga isso explicitamente — é uma mudança que eu faço,
  mas preciso saber que é intencional.
- Endpoints existentes (não mude nomes, eu que sirvo eles):
  `/api/health` (37 chaves, 17KB, o grande), `/api/proc-list`, `/api/solar-status`,
  `/api/ivonei-status`, `/api/palmeiras-status`, `/api/bluetti-status`,
  `/api/starlink-status`, `/api/cloudflare-status`, `/api/family-locations`,
  `/api/host-hits`, `/api/admin/*`.

---

## 11. Dados de exemplo (reais, de agora)

Use nos mocks pra o desenho ser testado com o tamanho real dos valores — inclusive
os feios.

```
Processo:    online · uptime 2h14 · Node v24.12.0 · APK v6.133
Mac:         uptime 12d · mem 9,8/16 GB · disco livre 41 GB · SSD 812 GB
             tendência disco -1,2 GB/dia · RSS bridge 143 MB (+8 MB/dia)
Conexões:    MQTT ok · latência 23 ms · último APK 4s · carro dormindo
             último GWM 1min · WS 3 · áudio 0
Solar:       gerando 4,2 kW · hoje 18,7 kWh · mês 412 kWh · vida 21,3 MWh
             inv A 2,1 kW / 47°C / strings 3,4-3,3-3,5 A · alarmes 0
Bluetti:     Casa 100% · rede 54 W · AC 54 W · modo Standard UPS · autonomia 67h
             Sítio SEM COMUNICAÇÃO (dado zerado há 5 dias)
Haval:       SOC 62% · não carregando · última telemetria 3min · alertas 0
Starlink:    conectado · ping 31 ms · perda 0,0% · 0,02/0,03 Mbit/s · 43 W
             quedas hoje 2 · 7d 262 quedas/5,0h · 30d 353 quedas/13,1h
             uptime do dish 7,5d · última leitura agora
Rede:        Tailscale ok · Funnel ok · Mosquitto 1883/1884/8883 ok
             cert TLS 67 dias · cert broker 41 dias · IP 189.x.x.x · DNS ok
Backups:     5 backups, todos ok, mais velho 9h · iCloud sincronizado
Erros:       vazio hoje · 3 restarts em 7d
```

Estados ruins que precisam caber no desenho sem quebrar:

```
"Bluetti Sítio — sem comunicação"          (crítico + explicação longa)
"login da Bluetti vence em 6 dias"          (faixa clicável de ação)
"Starlink: 262 quedas em 7 dias"            (número grande, ruim, mas não é alarme agora)
"recorder cobre 9,4d"                       (nota de ressalva colada num valor)
"último erro: APNs 410 BadDeviceToken"      (string técnica longa, quebra linha)
```
