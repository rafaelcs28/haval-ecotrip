# Charge Location Linking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Listar locais já usados em recargas e vinculá-los, com confirmação, a locais conhecidos antes de configurar provider e carregador.

**Architecture:** O Bridge amplia o endpoint legado `/api/charge-locations`, descobre candidatos a partir de `chargesArr` e persiste `known_place_id`. O iOS consome esse catálogo dentro de Locais conhecidos e confirma vínculo ou criação. Nomes continuam apenas visuais; IDs sustentam o vínculo.

**Tech Stack:** Node.js 24, Express, `node:test`, Swift 5.10, SwiftUI, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-15-charge-location-linking-design.md`

## Global Constraints

- Nunca criar ou vincular local automaticamente.
- Nunca usar igualdade de nomes como vínculo definitivo.
- Não duplicar locais com o mesmo identificador persistido.
- Recargas antigas permanecem inalteradas até conciliação explícita.
- Falha do catálogo não remove vínculos existentes.
- Builds Xcode rodam somente na fila autorizada do Mac Mini.

## Review Focus

- Local sem coordenadas: deve permitir vínculo existente e recusar criação.
- `known_place_id` removido: deve voltar a aparecer como não vinculado.
- Mesmo nome com coordenadas distintas: preservar itens já persistidos; não remapear vínculos.
- Nomes diferentes no mesmo ponto: consolidar somente na descoberta inicial por distância de até 100 m.
- Dados legados de `charge_locations.json`: preservar ID, nome e coordenadas.

---

### Task 1: Catálogo e vínculo no Bridge

**Files:**
- Create: `bridge/charge-location-links.js`
- Create: `bridge/test/charge-location-links.test.js`
- Modify: `bridge/server.js:3539-3650`
- Modify: `bridge/server.js:11476-11505`
- Modify: `docs/quality.md`

**Interfaces:**
- Consumes: `chargesArr`, `chargeLocations`, `knownPlaces`, `haversineM` e persistência JSON existentes.
- Produces: `discoverChargeLocations(stored: object[], charges: object[], makeId: () => string|number): { locations: object[], changed: boolean }`, `resolveChargeLocationLinks(stored: object[], knownPlaces: object[]): { locations: object[], changed: boolean }`, `GET /api/charge-locations`, `POST /api/charge-locations/:id/link` e `POST /api/charge-locations/:id/create-known-place`.

- [ ] **Step 1: Documentar o novo check Node em `docs/quality.md`**

Adicionar `node --test bridge/test/charge-location-links.test.js` aos checks permitidos.

- [ ] **Step 2: Escrever testes falhando do catálogo**

Cobrir: descoberta pelo histórico; preservação do item legado; dedupe inicial por até 100 m; coordenadas ausentes; vínculo válido; vínculo órfão voltando a `null`; IDs persistidos sem depender do nome.

- [ ] **Step 3: Executar o teste e confirmar RED**

Run: `node --test bridge/test/charge-location-links.test.js`

Expected: FAIL porque `bridge/charge-location-links.js` ainda não existe.

- [ ] **Step 4: Implementar funções puras em `bridge/charge-location-links.js`**

Descobrir apenas recargas com `location_name`; copiar `location_lat` e `location_lng` válidos; preservar entradas persistidas; aceitar `makeId` para IDs novos; nunca alterar recargas.

- [ ] **Step 5: Executar teste e confirmar GREEN**

Run: `node --test bridge/test/charge-location-links.test.js`

Expected: PASS, zero falhas.

- [ ] **Step 6: Integrar funções e rotas em `bridge/server.js`**

`GET` sincroniza candidatos antes de responder e persiste somente quando houver inclusão ou limpeza de vínculo órfão. `link` valida os dois IDs. `create-known-place` exige coordenadas, cria após a chamada explícita e grava o vínculo. Exclusão de local conhecido limpa vínculos associados.

- [ ] **Step 7: Verificar Bridge**

Run: `node --test bridge/test/charge-location-links.test.js && node --check bridge/server.js`

Expected: testes PASS e sintaxe válida.

- [ ] **Step 8: Commit**

```bash
git add bridge/charge-location-links.js bridge/test/charge-location-links.test.js bridge/server.js docs/quality.md
git commit -m "feat(bridge): link charging locations to known places"
```

### Task 2: Contrato iOS e cliente HTTP

**Files:**
- Modify: `ios-app/HavalEcoTrip/ChargeMeterModels.swift`
- Modify: `ios-app/HavalEcoTrip/ConfigStore.swift`
- Modify: `ios-app/HavalEcoTripTests/ChargeMeterModelsTests.swift`

**Interfaces:**
- Consumes: catálogo e rotas da Task 1.
- Produces: `ChargeLocationCandidate` com `id: String`, `name: String`, `lat: Double?`, `lng: Double?`, `knownPlaceId: String?` e `canCreateKnownPlace: Bool`; `ConfigStore.loadChargeLocations() async -> [ChargeLocationCandidate]?`; `linkChargeLocation(_ id: String, to knownPlaceId: String) async -> Bool`; `createKnownPlace(from location: ChargeLocationCandidate, radius: Double) async -> String?`.

- [ ] **Step 1: Escrever testes Swift falhando**

Testar decode de candidato vinculado e não vinculado; ID numérico ou string; coordenadas opcionais; `canCreateKnownPlace == false` sem latitude/longitude.

- [ ] **Step 2: Executar no Mac Mini e confirmar RED**

Run: `/usr/local/bin/mac-mini-build submit-git PROJECT xcode-native-test REF ios-app/HavalEcoTrip.xcodeproj HavalEcoTrip`

Expected: FAIL porque `ChargeLocationCandidate` não existe.

- [ ] **Step 3: Implementar modelo e métodos no store**

Decodificar sem depender do nome. Métodos HTTP retornam sucesso explícito, recarregam `places` e preservam estado anterior quando a rede falhar.

- [ ] **Step 4: Executar no Mac Mini e confirmar GREEN**

Run: mesmo job `xcode-native-test` com novo commit imutável.

Expected: todos os testes `HavalEcoTripTests` passam.

- [ ] **Step 5: Commit**

```bash
git add ios-app/HavalEcoTrip/ChargeMeterModels.swift ios-app/HavalEcoTrip/ConfigStore.swift ios-app/HavalEcoTripTests/ChargeMeterModelsTests.swift
git commit -m "feat(ios): consume charging location links"
```

### Task 3: Confirmação e vínculo em Locais conhecidos

**Files:**
- Modify: `ios-app/HavalEcoTrip/ConfigSheets.swift:225-470`
- Modify: `PRODUCT.md`
- Modify: `docs/architecture.md`

**Interfaces:**
- Consumes: `ChargeLocationCandidate` e métodos do `ConfigStore` da Task 2.
- Produces: seção “Locais de recarga não vinculados”, diálogo de confirmação e atualização da lista após sucesso.

- [ ] **Step 1: Adicionar seção de candidatos não vinculados**

Carregar catálogo junto com `knownPlaces`. Mostrar uma linha por candidato sem `known_place_id`. Falha de rede mostra mensagem sem remover locais conhecidos.

- [ ] **Step 2: Implementar escolha com confirmação**

Permitir selecionar local conhecido existente. Antes do POST, mostrar nome do local de recarga e destino escolhido. Após sucesso, remover o candidato da seção.

- [ ] **Step 3: Implementar criação com confirmação**

Mostrar “Criar local conhecido” somente quando houver coordenadas. Confirmar nome, raio padrão de 200 m e ação. Depois, abrir/realçar o novo local para configurar provider e carregador.

- [ ] **Step 4: Atualizar documentação responsável**

Registrar fluxo, endpoints, ausência de vínculo por nome e confirmação obrigatória.

- [ ] **Step 5: Verificar suite iOS no Mac Mini**

Run: job `xcode-native-test` com commit imutável da branch.

Expected: build de testes concluído e zero falhas.

- [ ] **Step 6: Revisar diff e contratos conectados**

Run: `git diff --check origin/main...HEAD`, `node --test bridge/test/charge-location-links.test.js` e `node --check bridge/server.js`.

Expected: zero erros.

- [ ] **Step 7: Commit**

```bash
git add ios-app/HavalEcoTrip/ConfigSheets.swift PRODUCT.md docs/architecture.md
git commit -m "feat(ios): confirm charging location links"
```

### Task 4: Verificação integrada e entrega

**Files:**
- Verify only.

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces: evidência de contrato, testes e branch pronta para publicação posterior.

- [ ] **Step 1: Exercitar contrato com dados sintéticos fora de produção**

Validar candidato novo, vínculo existente, criação confirmada, coordenadas ausentes e vínculo órfão. Não usar dados reais como teste destrutivo.

- [ ] **Step 2: Executar todos os checks permitidos**

Run: `node --test bridge/test/charge-location-links.test.js`, `node --check bridge/server.js`, `node --check bridge/gateway.js`, `git diff --check origin/main...HEAD` e job final `xcode-native-test` no Mac Mini.

Expected: zero falhas.

- [ ] **Step 3: Revisão final**

Confirmar que nenhum nome controla vínculo, nenhuma criação ocorre sem confirmação e nenhum valor manual de recarga é alterado.

### Task 5: Publicação TestFlight

**Files:**
- Verify and publish only.

**Interfaces:**
- Consumes: branch revisada e checks verdes da Task 4.
- Produces: novo build Haval Hub disponível no TestFlight.

- [ ] **Step 1: Criar checkout limpo no Mac Mini**

Usar o HEAD imutável da branch publicada no GitHub. Não usar working tree suja nem copiar credenciais.

- [ ] **Step 2: Arquivar e inspecionar**

Executar archive Release pelo Terminal gráfico. Confirmar versão, build, `NSCameraUsageDescription` e assinatura dentro do `.xcarchive`.

- [ ] **Step 3: Enviar e validar na Apple**

Enviar com `ios-app/ExportOptions.plist` e aguardar o build específico ficar `VALID` no App Store Connect.
