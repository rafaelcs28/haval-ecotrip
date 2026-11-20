# Live Charge Meter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Expor medidor externo ao vivo de Zeeda, YellotMob e MHZ MOB no app e na Live Activity.

**Architecture:** Normalizar a sessão ativa no adaptador existente, manter cache por local no Bridge e transportar campos opcionais pelo `/api/state` e ActivityKit. Reutilizar os cards e cálculos atuais.

**Tech Stack:** Node.js 24, Express, `node:test`, Swift 5.10, SwiftUI, ActivityKit, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-20-live-charge-meter-design.md`

## Global Constraints

- Não expor `raw`, tokens ou credenciais.
- Não usar `started_at` para decidir atividade.
- Não alterar conciliação concluída nem campos manuais.
- Xcode roda somente no Mac Mini autorizado.

## Review Focus

- `power_kw: null` não pode esconder uma sessão `Charging`.
- Carregador ativo distante não pode vencer o local do Haval.
- Haval fora de `Carregando` não pode herdar sessão externa de outro carro.
- Zeeda inativo pode manter energia antiga e não pode parecer ativo.
- Duas sessões ativas no mesmo local não podem ser misturadas.
- Custo zero é válido; custo ausente permanece ausente.
- Payload antigo sem campos externos deve continuar decodificando.

### Task 1: Contrato atual dos provedores

**Files:**
- Modify: `bridge/charge-meter-provider.js`
- Test: `bridge/test/charge-meter-provider.test.js`

**Interfaces:**
- Consumes: endpoints atuais Zeeda, YellotMob e MHZ MOB.
- Produces: `getCurrentChargeMeterSession(provider, chargerId, options)`.

- [ ] Escrever testes RED para Yellot sem potência, Zeeda ativo/inativo, MHZ autenticado e remoção de `raw`.
- [ ] Implementar normalização mínima e tratamento uniforme de falhas.
- [ ] Rodar testes focados e suíte Bridge.
- [ ] Commitar.

### Task 2: Cache vivo e estado do Bridge

**Files:**
- Create: `bridge/charge-meter-live.js`
- Create: `bridge/test/charge-meter-live.test.js`
- Modify: `bridge/charge-meter-reconciliation.js`
- Modify: `bridge/server.js`
- Modify: `PRODUCT.md`
- Modify: `docs/architecture.md`

**Interfaces:**
- Consumes: `getCurrentChargeMeterSession` da Task 1 e vínculos de `known_places.json`.
- Produces: campos `charge_charger_*` no `/api/state` e content-state APNs.

- [ ] Escrever testes RED para seleção única, ambiguidade, custo Zeeda e perda energética.
- [ ] Implementar helper puro e cache de 15 segundos somente durante carga.
- [ ] Expor rota autenticada genérica e campos vivos sem alterar reconciliação final.
- [ ] Rodar suíte Bridge e `node --check`.
- [ ] Commitar.

### Task 3: App e Live Activity

**Files:**
- Modify: `ios-app/HavalEcoTripWidget/ChargeActivityAttributes.swift`
- Modify: `ios-app/HavalEcoTripWidget/ChargeActivityLiveActivity.swift`
- Modify: `ios-app/HavalEcoTrip/ActivityManager.swift`
- Modify: `ios-app/HavalEcoTrip/BackgroundRefresh.swift`
- Modify: `ios-app/HavalEcoTrip/HavalEcoTripApp.swift`
- Modify: `ios-app/HavalEcoTrip/CarStore.swift`
- Modify: `ios-app/HavalEcoTrip/DashV2View.swift`
- Modify: `ios-app/HavalEcoTrip/NativeDashView.swift`
- Test: `ios-app/HavalEcoTripTests/ChargeMeterModelsTests.swift`

**Interfaces:**
- Consumes: campos opcionais `charge_charger_*` da Task 2.
- Produces: comparação visual de potência, energia, perda e custo.

- [ ] Escrever XCTest RED para perda energética e payload sem dados externos.
- [ ] Transportar campos por todos os caminhos de atualização da Live Activity.
- [ ] Mostrar dados no card atual e tela bloqueada.
- [ ] Rodar XCTest no Mac Mini, arquivar, enviar e aguardar `VALID` no TestFlight.
- [ ] Commitar e publicar a branch.
