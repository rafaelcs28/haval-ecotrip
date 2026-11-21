# Handoff — redesign da Live Activity de recarga (Haval EcoTrip)

## Estado

- Repositório: `rafaelcs28/haval-ecotrip`.
- Branch: `feature/charge-la-redesign`, criado de `codex/multiple-charge-meters` (`2f1cdd9`).
- Commit: `1b4e099f90421651c67ac1cb69ca5600281ae76e`, já no GitHub.
- Arquivo alterado: somente `ios-app/HavalEcoTripWidget/ChargeActivityLiveActivity.swift`.
  Bridge, `ChargeActivityAttributes` e contrato de push sem mudança.
- Validação: Mac Mini, job `haval-ecotrip-git-1b4e099f90421651-20261121T175628Z-6326`
  (`xcode-native-test`, scheme `HavalEcoTrip`): widget compilado, 21 testes, `TEST SUCCEEDED`.
- Mock de referência: https://claude.ai/artifact/2kac7FxtfZxAo2H3AuV6mE (privado).

## Pendente

1. Archive Release + TestFlight: `ios-app/build-testflight.sh` no Mac com a chave ASC
   (fora da fila; exige assinatura).
2. Ver no iPhone: recarga em andamento, estado stale e recarga concluída.
3. Decidir merge de `feature/charge-la-redesign` em `codex/multiple-charge-meters`/`main`.

## O que mudou

### Tela bloqueada (em andamento)

- Cabeçalho: tile do raio + nome do carro; à direita, ponto + "atualizado HH:mm".
  Com `context.isStale` (o bridge já envia `staleDate` via `_chargeStale()`), ponto e
  texto ficam laranja: "sem atualização desde HH:mm". Saiu o relógio relativo
  "há 2 min, 43 secs".
- Hero: SOC 32 pt light verde | "pronto às HH:mm" 15 pt semibold, com
  "faltam 13 min · limite 100%" embaixo. Sem `remainingMin`: "sem previsão".
- Barra: preenchimento verde liso; trilho branco 12%; traço amarelo no limite (< 100%).
  Saíram a bolinha branca e o gradiente.
- Grade de 3 colunas (valor do carro em cima, valor da tomada embaixo):
  - `2,8 kW` / `tomada 3,2 kW`;
  - `+8,3 kWh` / `tomada 10,7 kWh`;
  - `R$ 1,93` / `perda 23%` (laranja). Sem custo, a perda vira o valor.
- Uma perda só: a da sessão (`ChargeEnergyComparison`); sem medidor de energia, a
  instantânea (`ChargePowerComparison`). Antes apareciam 11,1% e 22,8% ao mesmo tempo.
- Botões `chargeLAButtons` inalterados (Trancar/Destrancar, Limite N%).
- Removido o fundo `RadialGradient`.
- Orçamento de altura: a Live Activity na tela bloqueada tem ~160 pt; por isso a grade
  não tem rótulos (POTÊNCIA/ENERGIA/CUSTO) e os botões mantêm o tamanho do `LAActionButton`.

### Concluída

"Recarga concluída · N%" + "+kWh · R$ · perda N%" + hora.

### Dynamic Island

- Expandida: leading = anel + SOC; trailing = "pronto às HH:mm" + "faltam · limite";
  bottom = barra 6 pt, linha "kW · +kWh · R$ · perda %" e os botões.
- Compacta e mínima: inalteradas (trailing vazio de propósito, para a LA do BYD caber).

## Funções novas no arquivo

`chargeReadyText`, `chargeTimingLine`, `chargeSessionLossPercent`, `ChargeProgressBar`;
`ChargeLockScreenView` ganhou `isStale` (default `false`).

## Atualização — fluxo compacto (substitui a grade de 3 colunas)

Tela bloqueada: cabeçalho "Haval H6 PHEV · Carregando"; hero de uma linha "99%" |
"pronto às 15:02 · 6 min"; barra; duas linhas de fluxo:

- `Carregador 3,2 kW → Carro 2,8 kW` … `perda agora 13%` (laranja);
- `11,2 kWh fornecidos → 8,6 recebidos` … `perda 23% · R$ 2,02`.

Sem medidor do carregador, cada linha mostra só o lado do carro. Mock: quadro
"Fluxo compacto" no canvas. O cartão "Carregando" do app (DashV2) usa a mesma
leitura em tamanho maior: pílula "perda agora", divisor e "perda X kWh · N%" + custo.
