# Multiple Charge Meters Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Permitir vários carregadores Zeeda e YellotMob, com tarifa Zeeda individual, em cada local conhecido sem perder configurações legadas.

**Architecture:** Expandir `charge_meter` para `charge_meters` como lista canônica, mantendo o primeiro item espelhado no campo legado. Bridge valida e persiste a lista atomicamente; iOS edita drafts independentes e envia a lista completa. A reconciliação percorre todas as configurações ativas e escolhe a sessão temporalmente compatível sem somar carregadores diferentes.

**Tech Stack:** Node.js 24, Express, `node:test`, Swift 6, SwiftUI, XCTest, Mac Mini build queue, App Store Connect.

**Spec:** `docs/superpowers/specs/2026-11-15-multiple-charge-meters-design.md`

## Global Constraints

- Aceitar vários Zeeda, vários YellotMob e mistura dos dois no mesmo local.
- Tarifa Zeeda é individual por carregador; YellotMob não aceita tarifa local.
- Rejeitar duplicata normalizada por `provider + charger_id`.
- Preservar `charge_meter`; nenhum rewrite ou remoção destrutiva em massa.
- Aplicativo antigo continua lendo o primeiro item; escrita legada atualiza o primeiro e preserva extras.
- Credenciais e payload `raw` nunca saem do Bridge.
- Valores manuais de energia ou custo nunca são sobrescritos.
- Builds iOS rodam somente na fila autorizada do Mac Mini.
- Produção recebe apenas patch revisado, backups e rollback explícito.

## Review Focus

- `charge_meters: []` deve limpar o espelho legado sem apagar outros campos do local; Task 1 testa.
- PUT legado após existir uma lista deve substituir apenas o primeiro item e preservar extras; Task 1 testa.
- IDs iguais com diferenças de caixa ou espaços devem ser duplicatas; Task 1 e Task 2 testam.
- Falha ao persistir deve restaurar lista e espelho em memória; Task 1 testa.
- Duas sessões válidas em carregadores diferentes não podem ser somadas; Task 4 testa seleção determinística.

---

### Task 1: Bridge schema and compatibility window

**Files:**
- Modify: `bridge/charge-meter-catalog.js`
- Modify: `bridge/server.js:12294-12314`
- Modify: `bridge/test/charge-meter-catalog.test.js`

**Interfaces:**
- Consumes: configuração singular validada por `validateChargeMeterConfig(raw)`.
- Produces: `validateChargeMeterConfigs(raw)`, `chargeMeterConfigsFromPlace(place)`, `mergeLegacyChargeMeter(existing, legacy)`, e resposta de local com `charge_meters` canônico mais `charge_meter` espelhado.

- [ ] **Step 1: Write failing Bridge migration tests**

Adicionar testes que comprovem: lista mista válida; dois Zeeda com tarifas diferentes; duplicata normalizada rejeitada; lista vazia válida; leitura do campo legado como lista; escrita legada substitui primeiro item e preserva extras.

- [ ] **Step 2: Run tests to verify RED**

Run: `node --test bridge/test/charge-meter-catalog.test.js`

Expected: FAIL porque helpers de lista ainda não existem.

- [ ] **Step 3: Implement list helpers**

Em `bridge/charge-meter-catalog.js`, adicionar:

```js
validateChargeMeterConfigs(raw) -> ChargeMeterConfig[]
chargeMeterConfigsFromPlace(place) -> ChargeMeterConfig[]
mergeLegacyChargeMeter(existing, legacy) -> ChargeMeterConfig[]
chargeMeterKey(config) -> `${provider}:${normalizedChargerId}`
```

Manter `validateChargeMeterConfig` como unidade de validação; não adicionar dependência.

- [ ] **Step 4: Update known-place PUT atomically**

`PUT /api/known-places/:id` aceita `charge_meters` ou `charge_meter`. Lista nova substitui a lista inteira. Campo legado atualiza só o primeiro item. Antes de salvar, capturar snapshot; em erro de persistência, restaurar o objeto inteiro e retornar 500. Depois de salvar, responder com os dois campos compatíveis.

- [ ] **Step 5: Run Bridge regression suite**

Run: `node --test bridge/test/charge-meter-catalog.test.js bridge/test/charge-location-links.test.js && node --check bridge/server.js`

Expected: todos passam; sem erro de sintaxe.

- [ ] **Step 6: Commit**

```bash
git add bridge/charge-meter-catalog.js bridge/server.js bridge/test/charge-meter-catalog.test.js
git commit -m "feat(bridge): support multiple chargers per place"
```

### Task 2: iOS model migration

**Files:**
- Modify: `ios-app/HavalEcoTrip/ConfigStore.swift:10-24,207-214`
- Modify: `ios-app/HavalEcoTrip/ChargeMeterModels.swift`
- Modify: `ios-app/HavalEcoTripTests/ChargeMeterModelsTests.swift`

**Interfaces:**
- Consumes: `charge_meters` array with legacy `charge_meter` fallback.
- Produces: `KnownPlace.chargeMeters: [ChargeMeterConfig]`, `ChargeMeterConfig.key: String`, `ChargeMeterConfig.validateUnique(_:)`, and `ConfigStore.updatePlace(... chargeMeters: [ChargeMeterConfig])`.

- [ ] **Step 1: Write failing XCTest migration cases**

Testar: local novo decodifica três configs mistas; local legado vira lista de um; array vazio não usa fallback legado; duas chaves iguais com caixa/espaço são rejeitadas; JSON mantém tarifas individuais.

- [ ] **Step 2: Submit RED test to Mac Mini**

Commitar somente testes e submeter `xcode-native-test` pelo fluxo de `docs/BUILD_ANDROID_ON_MAC_MINI.md` usando snapshot Git sanitizado.

Expected: FAIL nos símbolos novos.

- [ ] **Step 3: Implement compatible Swift models**

Substituir `KnownPlace.chargeMeter` por `chargeMeters`, mantendo propriedade calculada `chargeMeter` que retorna o primeiro item para callers ainda não migrados. `ChargeMeterConfig.key` normaliza provedor e carregador apenas para comparação; JSON preserva ID original.

- [ ] **Step 4: Update ConfigStore writer**

`updatePlace` envia `charge_meters: chargeMeters.map(\.json)`. Não enviar `charge_meter`; Bridge mantém o espelho. Recarregar `places` somente após HTTP 2xx.

- [ ] **Step 5: Submit GREEN test to Mac Mini**

Expected: todos os XCTest passam, incluindo casos legados.

- [ ] **Step 6: Commit**

```bash
git add ios-app/HavalEcoTrip/ConfigStore.swift ios-app/HavalEcoTrip/ChargeMeterModels.swift ios-app/HavalEcoTripTests/ChargeMeterModelsTests.swift
git commit -m "feat(ios): model multiple charge meters"
```

### Task 3: Multi-charger editor

**Files:**
- Modify: `ios-app/HavalEcoTrip/ConfigSheets.swift:470-700`
- Test: `ios-app/HavalEcoTripTests/ChargeMeterModelsTests.swift`

**Interfaces:**
- Consumes: `KnownPlace.chargeMeters`, catálogos roláveis existentes e `ConfigStore.updatePlace(... chargeMeters:)`.
- Produces: drafts estáveis por UUID, adicionar/editar/remover por item e uma lista validada no Save.

- [ ] **Step 1: Add failing draft-list tests**

Criar helpers puros em `ChargeMeterModels.swift` somente se necessários para testar: conversão config↔draft não perde tarifas; remoção afeta só a chave escolhida; duplicata retorna `ChargeMeterConfigError.duplicateCharger`.

- [ ] **Step 2: Run RED XCTest on Mac Mini**

Expected: FAIL na validação de duplicata ou helper novo.

- [ ] **Step 3: Replace single editor state with list state**

`PlaceRow` carrega todos os itens. Cada item mostra provedor, carregador, estado e tarifa Zeeda. `Adicionar carregador` cria draft vazio. O seletor de provedor e carregador continua usando `ChargeMeterCatalogPicker` rolável.

- [ ] **Step 4: Add safe remove and save flow**

Remover configuração existente exige confirmação. Salvar valida cada item e duplicatas, então envia a lista inteira. Erro mantém a edição aberta e mostra mensagem sem perder drafts.

- [ ] **Step 5: Verify iOS build and tests**

Submit: `xcode-native-test` via Mac Mini queue.

Expected: build e todos os XCTest passam.

- [ ] **Step 6: Commit**

```bash
git add ios-app/HavalEcoTrip/ConfigSheets.swift ios-app/HavalEcoTrip/ChargeMeterModels.swift ios-app/HavalEcoTripTests/ChargeMeterModelsTests.swift
git commit -m "feat(ios): edit multiple chargers per place"
```

### Task 4: Multi-provider reconciliation core

**Files:**
- Create: `bridge/charge-meter-reconciliation.js`
- Create: `bridge/test/charge-meter-reconciliation.test.js`

**Interfaces:**
- Consumes: charge interval, `ChargeMeterConfig[]`, normalized Zeeda/YellotMob sessions, and existing manual fields.
- Produces: `reconcileChargeMeter({ charge, configs, sessionsByKey, nowMs }) -> result` with `charger_kwh`, provider cost or Zeeda tariff cost, selected meter key, status, and no mutation.

- [ ] **Step 1: Write failing reconciliation tests**

Cobrir: duas sessões Zeeda sequenciais do mesmo carregador somam; duplicata sobreposta não duplica; outro carregador não mistura; dois carregadores candidatos escolhem maior sobreposição temporal e depois término mais próximo; empate permanece pendente; tarifa individual vigente; YellotMob usa custo próprio; manual energy/cost permanece intacto.

- [ ] **Step 2: Run tests to verify RED**

Run: `node --test bridge/test/charge-meter-reconciliation.test.js`

Expected: FAIL porque módulo não existe.

- [ ] **Step 3: Implement pure reconciliation**

Usar margem de consulta de 10 minutos, mas exigir interseção temporal conforme spec. Deduplicar antes de agrupar. Nunca somar sessões de chaves diferentes. Retornar `ambiguous` sem escrever quando o desempate não for seguro.

- [ ] **Step 4: Run reconciliation tests**

Expected: todos passam sem rede ou dados de produção.

- [ ] **Step 5: Commit**

```bash
git add bridge/charge-meter-reconciliation.js bridge/test/charge-meter-reconciliation.test.js
git commit -m "feat(bridge): reconcile multiple charge meters"
```

### Task 5: Provider adapters and reconciliation endpoint

**Files:**
- Create: `bridge/charge-meter-provider.js`
- Create: `bridge/test/charge-meter-provider.test.js`
- Modify: `bridge/server.js`

**Interfaces:**
- Consumes: local Zeeda gateway `127.0.0.1:8788`, YellotMob adapter `127.0.0.1:8790`, `chargeMeterConfigsFromPlace`, and Task 4 reconciler.
- Produces: `listChargeMeterSessions(provider, chargerId, fromIso, toIso)`, `POST /api/charges/:timestamp/reconcile-meter`, and retry metadata on the charge.

- [ ] **Step 1: Write provider normalization tests with fetch stubs**

Testar paginação YellotMob até `next_cursor=null`, Zeeda array, timeout/upstream error, remoção de `raw`, e chamadas separadas por charger ID.

- [ ] **Step 2: Run tests to verify RED**

Run: `node --test bridge/test/charge-meter-provider.test.js`

- [ ] **Step 3: Implement provider client**

Usar somente URLs loopback, `AbortSignal.timeout(5_000)`, token hash apenas no gateway Zeeda e nenhum segredo na resposta ou log.

- [ ] **Step 4: Add authenticated reconciliation endpoint**

Resolver o local por coordenada e fallback de nome legado. Consultar cada config ativa, chamar Task 4, aplicar resultado somente em campos vazios, persistir atomicamente e retornar estado por config. Em falha externa, manter recarga e marcar retry sem bloquear encerramento.

- [ ] **Step 5: Add bounded retry scheduling**

Repetir pendências a cada 5 minutos por até 72 horas usando timestamps persistidos na própria recarga. O timer apenas agenda o endpoint interno; reinício do Bridge retoma pelas marcas persistidas.

- [ ] **Step 6: Run full Bridge suite**

Run: `node --test bridge/test/charge-meter-*.test.js bridge/test/charge-location-links.test.js && node --check bridge/server.js`

Expected: todos passam.

- [ ] **Step 7: Commit**

```bash
git add bridge/charge-meter-provider.js bridge/charge-meter-reconciliation.js bridge/server.js bridge/test/charge-meter-provider.test.js
git commit -m "feat(bridge): reconcile configured chargers"
```

### Task 6: Integrated verification and publication

**Files:**
- Modify: `PRODUCT.md`
- Modify: `docs/architecture.md`
- Modify: `docs/quality.md`

**Interfaces:**
- Consumes: Tasks 1-5.
- Produces: reviewed branch, reversible Bridge deployment, and TestFlight build.

- [ ] **Step 1: Update responsible documentation**

Registrar `charge_meters`, compatibilidade legada, seleção temporal, retry e comandos de rollback.

- [ ] **Step 2: Run clean verification**

Run Node suite, `node --check`, `git diff --check`, and Mac Mini `xcode-native-test` against the exact immutable commit.

- [ ] **Step 3: Review whole branch**

Revisor fresco verifica perda de dados, mixed-version behavior, duplicatas, concorrência de save, exposição de credenciais, seleção temporal e preservação manual. Corrigir somente findings comprovados e repetir suites afetadas.

- [ ] **Step 4: Deploy Bridge reversibly**

Criar backups de `/opt/bridge/server.js`, módulos novos, `known_places.json` e `charges.json`. Aplicar somente arquivos revisados, validar sintaxe, reiniciar PM2 uma vez e provar endpoints com autenticação sem gravar configuração real.

- [ ] **Step 5: Verify compatibility in production**

Ler local legado e local com lista; testar rejeição de duplicata sem mutação; reconciliar uma recarga de teste somente após confirmação explícita do alvo.

- [ ] **Step 6: Publish TestFlight**

Criar checkout limpo no Mac, gerar projeto, validar `NSCameraUsageDescription`, arquivar via Terminal gráfico, verificar assinatura e aguardar `VALID` no App Store Connect.

- [ ] **Step 7: Integrate chosen branch outcome**

Seguir `superpowers:finishing-a-development-branch`; não fazer merge, PR ou exclusão sem a escolha do usuário.
