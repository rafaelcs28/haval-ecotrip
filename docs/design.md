# Design e acessibilidade

## Direção

As interfaces são usadas na central do carro, PWA, iPhone e iPad. A direção observada combina painel automotivo escuro, métricas de leitura rápida, estados do veículo e ações diretas. O idioma principal é português.

Na central, legibilidade e baixa distração têm prioridade. No telefone, históricos, detalhes, configurações e confirmações podem usar fluxos completos. No iPad/OBD, o painel precisa funcionar com telemetria rápida e conectividade degradada.

## Fontes de verdade

- Android Compose: `app/src/main/java/br/com/redesurftank/ecotrip/ui/theme/Theme.kt` e `ui/components`.
- PWA/cluster: CSS e componentes em `bridge/public` e assets HTML/CSS dos clientes.
- iOS: `ios-app/HavalEcoTrip/DesignSystem.swift` e componentes SwiftUI dos fluxos.
- Grasi Recarga: `ios-app/BydRecarga/BydDesignSystem.swift`.
- Imagens e ícones Apple: catálogos `Assets.xcassets`.

Não duplique cores, tipografia ou espaçamento neste documento; altere a fonte de código responsável.

## Interação e acessibilidade

- Ações críticas informam efeito, andamento, sucesso e falha.
- Controles têm rótulos acessíveis; ícones isolados exigem descrição equivalente.
- Preserve contraste, tamanhos tocáveis, foco visível, Dynamic Type quando compatível e navegação por tecnologias assistivas.
- Movimento não pode ser a única forma de comunicar estado; respeite redução de movimento.
- Em contexto automotivo, evite confirmação ambígua e entrada textual durante condução.
- Estados offline, sincronizando, dados antigos e fallback LAN/nuvem devem ser distintos.

## Estados a revisar

- Carregando, vazio, erro, offline e dado desatualizado.
- Comando aceito, rejeitado, expirado ou sem confirmação do carro.
- Troca entre LAN, bridge remoto, MQTT e BLE.
- Viagem/recarga em andamento, interrompida e reconstruída.
- Permissões negadas para localização, microfone, Bluetooth, notificações e calendário.

## Evidência atual

Esta adoção não executou revisão visual ou de acessibilidade porque não incluiu build. Os itens acima são critérios, não declaração de conformidade.

## Manutenção

Mudanças de interação atualizam o componente/tokens responsáveis e este guia quando a regra geral mudar.
