# Integração de medidores de recarga por local

## Intenção

Automatizar o preenchimento da energia medida na rede e do custo total das recargas do Haval EcoTrip. O EcoTrip continua sendo a fonte oficial do período e do local da recarga. O Bridge consulta o carregador configurado para aquele local, reúne todas as sessões ocorridas dentro do período, remove duplicatas e grava o total medido e o custo calculado pela tarifa vigente.

Os primeiros provedores serão Zeeda e YellotMob. A configuração deve aceitar provedores futuros sem exigir mudanças na tela do iPhone nem expor credenciais dos carregadores.

O trabalho atravessa dois repositórios já separados: `rafaelcs28/bridge` contém o gateway e a reconciliação; `haval-ecotrip` contém o Haval Hub. O adaptador Zeeda usa o gateway autenticado existente em `bridge`, que já limita os caminhos de carregadores, sessões e relatórios.

## Observações atuais

- O EcoTrip já registra `timestamp_ms`, `duration_sec`, `energy_kwh`, localização, `charger_kwh` e `cost_override` em cada recarga.
- O Haval Hub já permite editar manualmente medidor, custo e local.
- Locais conhecidos já possuem CRUD no Bridge e no Haval Hub.
- O Zeeda já expõe carregadores e sessões pelo gateway autenticado do Bridge.
- Uma recarga física pode virar várias sessões no Zeeda quando falta energia.
- O Zeeda também pode produzir duas representações sobrepostas da mesma sessão. Na amostra observada, duas linhas terminaram no mesmo instante e continham a mesma energia.
- O EcoTrip já une seus próprios trechos e representa a recarga física como um único período.
- O Bridge já calcula custo por tarifa fixa e preserva campos server-side durante sincronizações do APK.

## Decisões aprovadas

- O Bridge centraliza integrações e cálculos.
- O período consolidado do EcoTrip é a referência temporal.
- O vínculo fica no local conhecido: provedor, carregador e tarifa quando o provedor exigir.
- Zeeda usa tarifa configurável por local. YellotMob usa energia e custo total informados pela própria sessão.
- Todas as sessões válidas do carregador dentro do período são somadas.
- Duplicatas não são somadas.
- Valores manuais nunca são sobrescritos.
- Mudanças de tarifa valem para recargas futuras.
- Novos provedores seguem um contrato normalizado; o Haval Hub não conhece formatos específicos.

## Objetivos

- Listar no Haval Hub os provedores e carregadores disponíveis no Bridge.
- Configurar, em cada local conhecido, um provedor e um carregador. A tarifa aparece apenas para Zeeda.
- Preencher automaticamente `charger_kwh` com a soma medida na rede.
- Para Zeeda, calcular `cost_override.total = charger_kwh × tarifa vigente`.
- Para YellotMob, copiar energia e custo total consolidados das sessões do provedor.
- Continuar funcionando quando uma recarga foi dividida em várias sessões por falta de energia.
- Evitar soma dupla de sessões equivalentes ou sobrepostas.
- Registrar a origem dos valores para auditoria e proteção das edições manuais.
- Permitir nova tentativa quando o provedor estiver temporariamente indisponível.

## Não objetivos

- Controlar início, fim, corrente ou firmware dos carregadores.
- Expor tokens, URLs privadas ou credenciais dos provedores ao iPhone.
- Criar um construtor genérico de integrações HTTP no aplicativo.
- Ratear energia de uma sessão entre dois veículos ou duas recargas simultâneas.
- Recalcular automaticamente o histórico ao alterar uma tarifa.
- Substituir `energy_kwh`, que continua representando a energia recebida pelo carro.

## Antiobjetivos

- Não somar todas as linhas retornadas pelo provedor sem deduplicação.
- Não bloquear o POST de encerramento da recarga enquanto um provedor externo responde.
- Não perder valores manuais durante reenvio MQTT, merge ou reconciliação.
- Não gravar o preço atual em uma recarga antiga que aguardava reconciliação.
- Não acoplar a UI ao nome Zeeda ou ao formato da API Zeeda.

## Abordagens consideradas

### 1. Adaptadores no Bridge — escolhida

O Bridge mantém um registro de provedores. Cada adaptador lista carregadores e devolve sessões em um formato comum. O Haval Hub configura apenas IDs normalizados.

Vantagens: credenciais permanecem no servidor, automação funciona sem o iPhone aberto e novos provedores não alteram a UI. Custo: exige contrato e testes de reconciliação no Bridge.

### 2. URL genérica configurada no Haval Hub

Cada local teria URL, autenticação e caminhos JSON próprios.

Descartada: expõe segredos, aumenta validação e permite configurações incompatíveis.

### 3. Reconciliação no iPhone

O Haval Hub consultaria o provedor e atualizaria a recarga.

Descartada: depende do app aberto, não é confiável em segundo plano e duplica regras do Bridge.

## Modelo de configuração

Cada local conhecido ganha um bloco opcional `charge_meter`:

```json
{
  "provider": "zeeda",
  "charger_id": "id-estavel-do-provedor",
  "charger_name": "Nome exibido",
  "enabled": true,
  "tariffs": [
    {
      "effective_from_ms": 1794697200000,
      "price_per_kwh": 0.18
    }
  ]
}
```

`charger_name` é apenas apresentação. O pareamento usa `provider + charger_id`. A lista de tarifas preserva o preço aplicável no término da recarga. Salvar um novo preço cria uma nova vigência; não altera entradas anteriores.

Locais sem `charge_meter` continuam com o comportamento atual. Backups existentes continuam válidos porque o campo é opcional.

## Contrato normalizado de provedores

O Bridge define uma interface interna pequena:

```text
listChargers() -> [{ id, name, online? }]
listSessions(chargerId, fromMs, toMs) -> [{
  id, transactionId?, chargerId, startedAtMs, endedAtMs,
  energyKwh, totalCost?, updatedAtMs?
}]
```

Os adaptadores Zeeda e YellotMob usam integrações autenticadas no Bridge. Credenciais e endereços upstream permanecem apenas no Bridge.

Endpoints consumidos pelo Haval Hub:

```text
GET /api/charge-meter/providers
GET /api/charge-meter/providers/:provider/chargers
PUT /api/known-places/:id
POST /api/charges/:timestamp/reconcile-meter
```

O `PUT` de local aceita o bloco `charge_meter` após validar provedor, carregador, tarifa e vigência. Campos desconhecidos ou IDs indisponíveis não são gravados silenciosamente.

## Janela oficial da recarga

Para uma recarga do EcoTrip:

```text
endMs   = timestamp_ms
startMs = timestamp_ms - duration_sec × 1000
```

O local é resolvido primeiro pelas coordenadas contra os locais conhecidos. O nome exato é fallback para registros antigos sem coordenadas.

O Bridge consulta o provedor usando uma margem pequena antes e depois do período para absorver diferenças de relógio. Só entram sessões do carregador configurado que tenham energia positiva e interseção temporal real com o período oficial.

A margem inicial será de 10 minutos em cada ponta. Ela amplia apenas a consulta; uma sessão só entra se sobrepuser o período oficial ou terminar dentro dessa margem após o fim. Esses valores ficam como constantes testadas no Bridge, não como controles no aplicativo.

## Deduplicação e agrupamento

Ordem de deduplicação:

1. Mesmo `transactionId` do provedor: uma sessão.
2. Sem `transactionId`: mesmo carregador, diferença de energia de no máximo `max(0,05 kWh, 1%)`, diferença de término de até 120 segundos e intervalos sobrepostos ou contidos: uma sessão.
3. Sessões sequenciais ou separadas por uma queda de energia permanecem distintas e são somadas.

Quando duas duplicatas carregam metadados diferentes, vence primeiro a que possui `transactionId`, depois a atualização mais recente e depois a que possui mais campos válidos. Diferença de energia acima da tolerância impede classificá-las como duplicatas. Energia nunca é somada entre duplicatas.

Após deduplicar, Zeeda usa:

```text
charger_kwh = soma das energyKwh válidas
tarifa      = entrada vigente em endMs
total       = arredondar(charger_kwh × tarifa, 2)
```

YellotMob soma `energyKwh` e `totalCost` das sessões deduplicadas. Não exige tarifa local e não recalcula o valor cobrado.

A reconciliação grava também os IDs das sessões usadas e o intervalo consultado. Isso permite explicar e repetir o cálculo.

## Precedência e proveniência

Campos automáticos recebem metadados:

```json
{
  "charger_kwh": 9.018,
  "charger_kwh_source": {
    "kind": "provider",
    "provider": "zeeda",
    "charger_id": "...",
    "session_ids": ["..."],
    "reconciled_at_ms": 1794760000000
  },
  "cost_override": {
    "total": 1.62,
    "perKwh": 0.18,
    "basis": "charger_kwh",
    "source": "provider"
  }
}
```

Regras:

- Valor existente sem proveniência é tratado como manual.
- PATCH manual marca explicitamente a origem como `manual`.
- Reconciliação pode atualizar apenas valores vazios ou valores automáticos da mesma configuração.
- Valor manual nunca é sobrescrito.
- Medidor e custo têm precedência independente. Medidor manual com custo vazio permite calcular o custo sobre o medidor manual. Custo manual com medidor vazio permite preencher apenas o medidor.
- Sincronização MQTT e merge preservam valor e proveniência server-side.

O merge do EcoTrip acontece antes da reconciliação. Valores automáticos dos trechos absorvidos são descartados e recalculados sobre o período consolidado. Valores manuais continuam seguindo o merge atual e permanecem manuais; se o merge envolver locais ou carregadores diferentes, a reconciliação automática fica pendente para revisão em vez de escolher um carregador.

## Execução e recuperação

O encerramento ou atualização de uma recarga agenda reconciliação assíncrona após a persistência local. A resposta ao APK não espera o provedor.

Se o provedor falhar ou ainda não tiver fechado a última sessão, a recarga fica pendente. Um job leve revisita recargas pendentes recentes. O botão `Atualizar do medidor` chama o endpoint manual e mostra o resultado.

O estado pendente é persistido na própria recarga, com tentativa, erro resumido e próxima execução. O Bridge tenta novamente a cada 5 minutos por até 72 horas. Depois disso mantém o estado `failed`, sem alterar campos, e aceita nova tentativa manual a qualquer momento.

Se houver energia medida mas nenhuma tarifa vigente, o Bridge grava apenas `charger_kwh` e sua proveniência. O custo permanece vazio e o estado informa `missing_tariff`; cadastrar uma tarifa com vigência adequada permite reconciliar o custo depois.

A reconciliação é idempotente: repetir com o mesmo conjunto de sessões produz os mesmos campos e não duplica custo.

## Haval Hub

Em `Configurações → Locais conhecidos → Editar`:

- toggle `Preencher recargas pelo medidor`;
- seletor de provedor;
- seletor de carregador, carregado pelo Bridge;
- campo `Tarifa (R$/kWh)` somente para Zeeda;
- resumo da vigência atual.

Na edição de recarga:

- manter campos manuais existentes;
- mostrar origem automática quando presente;
- oferecer `Atualizar do medidor`;
- informar quantas sessões foram agrupadas.

Falha ao listar provedores não apaga configuração existente. O usuário ainda pode editar medidor e custo manualmente.

Durante uma recarga, o Bridge publica `charge_charger_power_kw` com a leitura normalizada e recente do provedor. A Live Activity compara esse valor com `charge_power_kw` do carro e mostra ambos. Quando os dois forem válidos, mostra também `perda % = max(0, (carregador − carro) / carregador × 100)`. Zeeda e YellotMob seguem o mesmo campo normalizado. Leitura ausente ou expirada não mostra comparação nem perda.

## Compatibilidade e migração

- Nenhuma migração destrutiva.
- `charge_meter` e campos de proveniência são opcionais.
- Clientes antigos ignoram campos novos.
- Registros com `charger_kwh` ou custo existentes são tratados como manuais.
- Tarifas novas não recalculam recargas antigas.
- A configuração inicial de Jardins Lisboa e Limpa Gyn será feita pela API/UI após implantação, sem IDs hardcoded no código.

## Segurança

- Endpoints de configuração e reconciliação exigem autenticação administrativa já usada pelo Bridge.
- O proxy continua com allowlist de caminhos.
- Respostas ao iPhone não incluem tokens, arquivos de credenciais nem URL upstream.
- O Bridge valida números finitos, tarifa não negativa, IDs e limites temporais.

## Testes e evidência

Bridge:

- soma duas sessões sequenciais separadas por queda de energia;
- deduplica sessões sobrepostas com mesmo término e energia;
- não mistura outro carregador;
- ignora sessão fora do período;
- seleciona tarifa vigente no término;
- não sobrescreve valor manual;
- repete reconciliação sem mudar o resultado;
- mantém recarga pendente quando o provedor falha;
- preserva configuração antiga sem `charge_meter`.

Haval Hub:

- decodifica local com e sem configuração;
- lista provedores e carregadores;
- salva tarifa com vírgula decimal;
- mantém configuração visível quando o provedor está offline;
- envia reconciliação manual e atualiza a recarga.

Builds iOS rodam somente no Mac Mini autorizado. Testes Node podem rodar no ambiente do Bridge se não acessarem dados ou credenciais de produção.

## Implantação e rollback

1. Implantar Bridge com campos opcionais, adaptador Zeeda e testes.
2. Configurar os dois locais pelo endpoint autenticado e validar em modo de leitura/reconciliação manual.
3. Implantar Haval Hub com a UI genérica.
4. Ativar reconciliação automática.

`charge_meter.enabled` nasce `false`. Esse campo é o gate de produção: listar, configurar e reconciliar manualmente continuam possíveis; o job automático só considera locais explicitamente ativados.

Rollback: desativar `charge_meter.enabled` nos locais. Os valores já gravados permanecem auditáveis; não há remoção de histórico. Reverter o Haval Hub não quebra o Bridge porque os campos novos são opcionais.

## Critérios de aceitação

- Uma recarga EcoTrip que contém duas sessões Zeeda por queda de energia recebe a soma correta do medidor.
- Duas linhas Zeeda que representam a mesma sessão não duplicam energia.
- Jardins Lisboa calcula o total pela tarifa configurada vigente, sem valor hardcoded.
- Alterar a tarifa não muda recargas concluídas antes da nova vigência.
- Um valor manual de medidor ou custo permanece intacto após reconciliação e sync.
- A indisponibilidade do Zeeda não impede o EcoTrip de encerrar ou salvar a recarga.
- Um novo provedor pode ser adicionado no Bridge sem mudar o modelo ou a tela do Haval Hub.
