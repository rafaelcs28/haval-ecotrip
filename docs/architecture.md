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
6. `TripVideoBridge` reconcilia a viagem automática com o APK Haval Camera por IPC explícito protegido por assinatura. Cada comando persistente só altera o estado confirmado do EcoTrip depois de um acknowledgement correlacionado por request/revision; a espera limitada ocorre no executor de câmera, nunca na main looper. O mesmo ID/start original permite reabrir no Camera uma viagem concluída que o EcoTrip retomou dentro da janela. O EcoTrip apenas encaminha catálogo com revisão persistida atomicamente, configurações confirmadas e telemetria CAN limitada; falhas da câmera não interrompem viagem nem telemetria do veículo.

## Dados e runtime

Arquivos de estado, históricos, tokens, certificados e configurações reais do bridge não são fonte versionada. A `.gitignore` define os dados recriados ou preservados somente no servidor. Mudanças de schema devem mapear leitores, escritores, compatibilidade e rollback antes da edição.

## Contratos críticos

- IDs, timestamps, unidades, tópicos MQTT e payloads JSON de viagens/recargas.
- Idempotência e ordenação ao sincronizar estado offline ou retido.
- Autenticação do bridge, pareamento e armazenamento seguro de credenciais.
- Confirmação do estado do veículo antes de comandos ou instalação de atualização.
- Assinaturas Android/Apple e identificadores de bundle/application ID.
- Haval Camera usa permissões Android `signature`, ações IPC versão 1 e o provider `br.com.redesurftank.havalcamera.video`; os dois APKs precisam da mesma assinatura de produção.

## Decisões

- Preservar as stacks atuais; exemplos Next.js/PostgreSQL do toolkit não se aplicam.
- Não impor limite rígido de 350 linhas ao legado. Arquivos grandes devem ser decompostos por responsabilidade quando houver testes e uma mudança relacionada.
- Manter builds fora do coordenador e submeter somente commits auditados.

## Riscos observados

- Não foi encontrada suíte automatizada de clientes nem script de teste no `bridge/package.json`.
- Há arquivos Kotlin e Swift grandes, aumentando o custo de revisão.
- Contratos distribuídos entre APK, bridge, PWA e apps Apple exigem revisão de consumidores antes de mudar nomes ou semântica.

## Manutenção

Atualize este mapa quando módulos, contratos, dependências ou destinos de build mudarem. Registre apenas estrutura implementada.

## Câmera LAN autenticada (Task 6)

`LocalApiServer` mantém HTTP/WS de telemetria e comandos existentes e adiciona somente as rotas abaixo. `CameraLanAuth` decide desafios/credenciais, `CameraLanRelay` valida HVC1 e limita a fila, e `CameraLanDownloads` decide catálogo/Range. Nenhuma dependência, permissão, manifesto ou configuração de build muda.

| Rota | Contrato |
| --- | --- |
| `GET /api/capabilities` | `cameraLiveLan`, `cameraDownloadLan`, `hvcVersion`, `hvtVersion`, todos inteiros. Versões = 1; ambas as capacidades de câmera = 0 se pacote, serviço/provider ou permissões de assinatura não estiverem disponíveis. |
| `POST /api/video/lan/challenge` | Sem segredo no request. Retorna `deviceId`, `nonce` hexadecimal de 128 bits e `expiresAt` em ms, com validade de 30 s. |
| `POST /api/video/lan/session` | JSON `deviceId`, `nonce`, `expiresAt`, `hmac` hexadecimal minúsculo e `scope` (`live` ou `download`). HMAC-SHA256 exato de `haval-camera-lan-v1|deviceId|nonce|expiresAt`, chave obtida do `MqttManager.bridgeToken` atual. Cada desafio é consumido na primeira tentativa. |
| `DELETE /api/video/lan/session/:id` | `Authorization: Bearer <controlToken>` encerra somente essa sessão. |
| `/ws/video/lan/car?session=ID` | Produtor exclusivo, origem loopback literal, bearer `producerToken` de uso único, enviado ao Camera somente por IPC assinado. |
| `/ws/video/lan/viewer?session=ID` | Viewer exclusivo, bearer `viewerToken` de uso único. |
| `GET /api/video/lan/catalog?session=ID` | Bearer `downloadToken`; somente viagens concluídas do provider. |
| `GET /api/video/lan/trips/:tripId/segments/:segmentId?session=ID` | Mesmo bearer de download, IDs decimais positivos canônicos, ordinal presente em `1..segments` do provider. Range simples suporta fechado, aberto e sufixo, responde 206 ou 416 com Content-Range. |

`deviceId` é o `Settings.Secure.ANDROID_ID` da instalação EcoTrip, estável para app/assinatura/usuário; não é o identificador de processo MQTT. O cliente deve vincular a identidade esperada antes de autenticar. O valor ausente ou token bridge vazio desabilita emissão de desafios. mDNS anuncia os mesmos quatro campos de capacidades no registro; o endpoint HTTP revalida pacote/permissões a cada consulta (autoridade para mudanças após registro).

Sessões duram 5 minutos (inferior ao máximo IPC de 30 minutos). Há no máximo uma live e 16 sessões totais, 128 desafios pendentes. A resposta live contém `sessionId`, `expiresAt`, `scope`, `viewerToken`, `controlToken` e `viewerPath` relativo ao endpoint descoberto; nunca contém `producerToken` ou o segredo bridge. Download retorna `downloadToken` e `controlToken` distintos. Bearers aleatórios de 256 bits são distintos do HMAC, role/session scoped e guardados somente como SHA-256 em memória; mídia live consome cada bearer uma vez. A admissão final do WebSocket compara o ID solicitado à sessão capturada e consome a credencial atomicamente; substituição durante o handshake não pode anexar uma credencial antiga à sessão nova. Download/control podem ser reutilizados dentro da sessão/validade, para Range e encerramento. Nenhum segredo, prova ou byte de vídeo é persistido/logado pelo novo caminho. As respostas usam `Cache-Control: no-store`. Bodies de autenticação têm limite de 4096 bytes; query de mídia aceita somente `session=ID`, nunca credenciais.

`TripVideoBridge` emite `START_LIVE` com `ws://127.0.0.1:PORT/ws/video/lan/car?session=ID`, ID extra, bearer curto e validade; `STOP_LIVE` preserva a identidade da viagem. Não recebe frames nem muda o contrato WSS remoto. O estado live local participa do guard de gravação/live; reconciliação e comandos remotos permanecem existentes.

HVC1 mantém header de 24 bytes e payload exato de 1..4.194.304 bytes. Tipos, flags, PTS, comprimentos SPS/PPS e AVCC são validados sem decodificação. O input limitado valida o comprimento WS antes da alocação do NanoWSD, incluindo a soma de fragmentos e o máximo de 1024 fragmentos por mensagem (também limita fragmentos vazios). CONFIG antecede deltas; entrada do viewer e pressão solicitam keyframe. A fila conta mensagens em envio e nunca excede 1 MiB/30 mensagens; frames válidos maiores que a fila são descartados. Após descarte, deltas aguardam CONFIG/keyframe. Escritas usam threads próprias fora do lock do relay. Escrita bloqueada por mais de 3 s encerra a sessão/credenciais, fecha input/socket para destravar o escritor, e permite nova autenticação. Expiração é verificada a cada 250 ms. O input de vídeo tolera o timeout HTTP de leitura (5 s), pois viewers podem apenas receber; EOF, erro real e fechamento pelo dono da sessão continuam encerrando a leitura. O timeout de HTTP/telemetria permanece inalterado. Nenhum comando STOP_TRIP é emitido por falha de LAN.

Downloads não aceitam caminho de arquivo. A URI é construída apenas com IDs validados e autoridade fixa; o provider recusa ativo/parcial e mantém lease até o descritor fechar. A resposta possui `finally` para fechamento em sucesso/falha de envio; o stream limitado também fecha em erro de leitura e suporta fechamento idempotente. Range inválido libera o descritor imediatamente. Testes de domínio usam bytes sintéticos; comportamento Binder/assinatura, rede física e liberação do lease no processo Camera continuam exigindo validação em dispositivo autorizado.

Verificação deste trabalho: executar `scripts/build-on-mac-mini.sh COMMIT` no repositório Git canônico para assembly e submeter o mesmo commit a `mac-mini-build submit-git /root/projects/haval-ecotrip-git android-test-debug COMMIT` para a suíte. A versão atual do script usa somente `android-debug`. Evidências ficam fora da árvore de fonte.
