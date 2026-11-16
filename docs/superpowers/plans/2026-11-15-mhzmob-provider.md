# MHZ MOB Provider Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adicionar MHZ MOB ao editor e à conciliação existentes e publicar o Haval Hub no TestFlight.

**Architecture:** Estender o registro genérico de provedores. O Bridge consulta o namespace `/api/mhzmob` com seu token e reaproveita a normalização/custo YellotMob. SwiftUI permanece genérico.

**Tech Stack:** Node.js 24, `node:test`, SwiftUI, XCTest, Mac Mini, TestFlight.

**Spec:** `docs/superpowers/specs/2026-11-15-mhzmob-provider-design.md`

## Global Constraints

- Nenhuma credencial MHZ no app, código-fonte ou logs.
- `mhzmob` não exige tarifa.
- Não expor `raw`.
- Builds Xcode somente no Mac Mini autorizado.

## Review Focus

- Payload MHZ informa `provider: yellotmob`, mas deve conciliar pela chave `mhzmob:charger`.
- Catálogo genérico deve usar `/api/mhzmob/chargers`, não o domínio do fornecedor.
- Custo zero e campos ausentes não podem ser inventados.
- YellotMob e Zeeda existentes não podem mudar.
- Produção contém proxy MHZ externo a esta branch; deploy deve preservar esse módulo.

### Task 1: Registro, catálogo e sessões MHZ

**Files:**
- Modify: `bridge/charge-meter-catalog.js`
- Modify: `bridge/charge-meter-provider.js`
- Modify: `bridge/charge-meter-reconciliation.js`
- Modify: `bridge/server.js`
- Test: `bridge/test/charge-meter-catalog.test.js`
- Test: `bridge/test/charge-meter-provider.test.js`
- Test: `bridge/test/charge-meter-reconciliation.test.js`

**Interfaces:**
- Consumes: `/api/mhzmob/chargers` e `/api/mhzmob/sessions` autenticados.
- Produces: provedor `mhzmob`, catálogo genérico e custo conciliado.

- [x] Escrever testes RED para registro, URL/paginação, remoção de `raw` e custo MHZ.
- [x] Implementar somente os ramos `mhzmob` nos helpers existentes.
- [x] Rodar toda a suíte `charge-meter-*` e `node --check`.
- [x] Commitar.

### Task 2: Validação e publicação

**Files:**
- Modify: `PRODUCT.md`
- Modify: `docs/architecture.md`

**Interfaces:**
- Consumes: Task 1.
- Produces: Bridge em produção e build TestFlight válido.

- [x] Atualizar documentação responsável.
- [x] Validar endpoints reais, incluindo 401 sem token.
- [x] Revisar diff e preservar proxy MHZ presente em produção.
- [x] Fazer deploy com backup e rollback.
- [x] Rodar XCTest no Mac Mini.
- [x] Arquivar e aguardar build `VALID` no App Store Connect.
