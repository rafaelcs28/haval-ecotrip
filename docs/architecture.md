# Código e arquitetura

## Stack observada

- Android: Kotlin 2.2.10, Android Gradle Plugin 8.12.1, Java/JVM 11, Jetpack Compose e Android SDK 36.
- Bridge/PWA: Node.js, Express, MQTT, WebSocket e JavaScript/HTML/CSS.
- iOS/iPadOS: Swift 5.10, SwiftUI, WidgetKit/ActivityKit e projetos descritos por XcodeGen.
- Comunicação: HTTP, WebSocket LAN, MQTT, mDNS/Bonjour e Bluetooth/ELM327 no módulo OBD.
- Build autorizado: fila isolada no Mac Mini; Android Debug e Xcode Simulator sem assinatura de distribuição.

## Mapa do código

```text
app/         APK principal do carro: telemetria, viagens, recargas, automações e UI
bridge/      servidor Node.js, MQTT, REST/WS, persistência e PWA
cluster/     APK Android do cluster
companion/   APK Android auxiliar de navegação/relay
ios-app/     Haval Hub, widgets, Live Activities, extensões e Grasi Recarga
ios-obd/     app iPad/OBD, BLE, cluster e publicação para o bridge
scripts/     backup, operação e submissão auditada ao Mac Mini
docs/        instalação, operação, arquitetura, qualidade e evidências
```

## Fluxo principal

1. `CarDataManager`, `TripManager`, `AutomationManager`, `MqttManager` e serviços Android recebem sinais do veículo e formam o estado da aplicação.
2. `LocalApiServer` expõe estado/comandos na LAN; telas Compose e WebViews consomem snapshots in-process.
3. MQTT e o bridge sincronizam estado, históricos e comandos. O bridge serve REST, WebSocket e a PWA.
4. No iOS, `CarStore`, `BridgeRouter`, stores especializados e views SwiftUI consomem o bridge e gerenciam estado local, notificações e Live Activities.
5. O iPad/OBD pode receber dados do bridge ou BLE/ELM327 e enviar telemetria por MQTT/HTTP; a descoberta LAN reduz latência e possui fallback remoto.

Locais conhecidos usam `charge_meters` como lista canônica e mantêm `charge_meter` como espelho legado do primeiro item. Cada par normalizado `provider + charger_id` é único. Zeeda mantém tarifa por carregador e vigência; YellotMob fornece energia e custo da sessão.

O aplicativo agrupa a lista por provedor apenas na interface. O Bridge consulta os adaptadores locais Zeeda (`127.0.0.1:8788`) e YellotMob (`127.0.0.1:8790`), remove payloads brutos e concilia somente sessões sobrepostas ao período da recarga. Sessões sequenciais do mesmo carregador podem ser somadas; carregadores diferentes nunca são somados. Maior sobreposição temporal e término mais próximo resolvem concorrência; empate permanece pendente. Falhas repetem a cada 5 minutos por até 72 horas. Energia e custo já preenchidos têm precedência independente.

A Live Activity aceita `charge_charger_power_kw` opcional para comparar potência do carregador com a potência recebida pelo carro.

O Bridge deriva candidatos persistidos de `chargesArr` em `GET /api/charge-locations`. O Haval Hub exige confirmação para `POST /api/charge-locations/:id/link` ou `POST /api/charge-locations/:id/create-known-place`. `known_place_id` mantém o vínculo; nomes são apenas apresentação.

## Dados e runtime

Arquivos de estado, históricos, tokens, certificados e configurações reais do bridge não são fonte versionada. A `.gitignore` define os dados recriados ou preservados somente no servidor. Mudanças de schema devem mapear leitores, escritores, compatibilidade e rollback antes da edição.

Deploy do Bridge exige backup de `server.js`, dos módulos `charge-meter-*`, `known_places.json` e `charges.json`. Rollback restaura esses arquivos juntos e reinicia o mesmo processo uma vez. Aplicativo antigo continua lendo `charge_meter`; os itens adicionais permanecem preservados em `charge_meters`.

## Contratos críticos

- IDs, timestamps, unidades, tópicos MQTT e payloads JSON de viagens/recargas.
- Idempotência e ordenação ao sincronizar estado offline ou retido.
- Autenticação do bridge, pareamento e armazenamento seguro de credenciais.
- Confirmação do estado do veículo antes de comandos ou instalação de atualização.
- Assinaturas Android/Apple e identificadores de bundle/application ID.

## Decisões

- Preservar as stacks atuais; exemplos Next.js/PostgreSQL do toolkit não se aplicam.
- Não impor limite rígido de 350 linhas ao legado. Arquivos grandes devem ser decompostos por responsabilidade quando houver testes e uma mudança relacionada.
- Manter builds fora do coordenador e submeter somente commits auditados.

## Riscos observados

- O cliente iOS possui testes unitários incrementais em `HavalEcoTripTests`; o Bridge possui testes Node focados em locais e medidores.
- Há arquivos Kotlin e Swift grandes, aumentando o custo de revisão.
- Contratos distribuídos entre APK, bridge, PWA e apps Apple exigem revisão de consumidores antes de mudar nomes ou semântica.

## Manutenção

Atualize este mapa quando módulos, contratos, dependências ou destinos de build mudarem. Registre apenas estrutura implementada.
