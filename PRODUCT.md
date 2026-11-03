# Haval EcoTrip / Haval Hub

## Problema e objetivo

O projeto centraliza telemetria, histórico, recargas, viagens, automações e controles de um Haval H6 PHEV em diferentes telas: central Android do carro, PWA, iPhone, widgets/Live Activities e iPad/OBD. O objetivo é manter o estado do veículo acessível e permitir ações úteis mesmo quando internet, bridge ou um dos dispositivos estiver temporariamente indisponível.

## Público e papéis

- Proprietário/condutor: acompanha o veículo e executa comandos.
- Usuários convidados ou da família: acessam fluxos específicos compartilhados.
- Dispositivos embarcados: coletam telemetria e executam automações locais.

Este é um produto pessoal. Não há evidência de um SaaS público ou de requisitos de multiempresa.

## Fluxos atuais

1. O APK coleta estado do carro, mantém viagem/recarga e publica telemetria.
2. O bridge Node.js consome MQTT, persiste históricos e atende REST, WebSocket e PWA.
3. Haval Hub apresenta painel, viagens, recargas, automações e controles.
4. A rede local usa descoberta mDNS e WebSocket para baixa latência, com fallback remoto.
5. Automações são configuradas pelos clientes e executadas pelo carro.
6. Widgets e Live Activities mantêm estados relevantes visíveis no iPhone.
7. O iPad/OBD coleta ou consome telemetria e oferece cluster, navegação e controles.
8. O Haval Camera grava viagens em processo separado; EcoTrip encaminha catálogo e mídia por sessão LAN autenticada, e o iPhone prefere LAN com fallback remoto somente após confirmação explícita.
9. A tela iOS de câmeras ao vivo oferece Haval e Dashcam como fontes exclusivas. A Dashcam usa WHEP/WebRTC pelo endpoint Tailscale fixo, com autenticação existente e pin TLS.

## Escopo

- Aplicativos Android `app`, `cluster` e `companion`.
- Bridge, PWA e scripts em `bridge`.
- Aplicativos e extensões Apple em `ios-app` e `ios-obd`.
- Contratos HTTP, MQTT, WebSocket LAN, pareamento e telemetria.
- Atualização e distribuição somente pelos fluxos autorizados e assinados.

## Fora do escopo padrão

- Credenciais, tokens, certificados, keystores, perfis de assinatura e dados pessoais.
- Migração de stack, publicação, alteração de banco ou adoção de serviços pagos sem decisão específica.
- Compatibilidade genérica com outros veículos sem hardware e contratos comprovados.

## Requisitos e restrições

- Interface principal em português e uso automotivo, com ações claras e baixa distração.
- Compatibilidade com a central Android existente; níveis de API reduzidos em alguns módulos são decisões funcionais, não versões a elevar automaticamente.
- Operação degradada: filas, histórico local e fallback de rede não podem ser removidos sem revisar o fluxo completo.
- Comandos sensíveis preservam autenticação, validação de estado e tratamento de falhas.
- Builds Android/Kotlin/Gradle e Xcode usam o Mac Mini autorizado, nunca o coordenador.
- Assinaturas e segredos permanecem fora do repositório e do arquivo enviado à fila.

## Cobertura atual e pendências conhecidas

- O bridge possui 66 testes Node para contratos de catálogo, autenticação, relay e transferência de vídeo.
- O EcoTrip Android possui 70 testes unitários, incluindo autenticação/relay/download LAN da câmera; o target iOS `CameraVideoTests` possui 107 testes de protocolo, sessão, rota, WebRTC, download, persistência e limpeza.
- O Haval Camera possui suíte JVM e verificação de pacote no Mac Mini para catálogo, retenção, lifecycle, protocolo e relay. Essa evidência automatizada não valida o sensor físico.
- Continuam exclusivamente dependentes de hardware: captura e mux no Android 9 do veículo, Binder/provider entre APKs assinados, Bonjour/Wi-Fi real, interrupção de Range, reprodução H.264/WebRTC no iPhone, SDP real, sincronismo A/V, latência/consumo em 4G, durabilidade após perda de energia e comportamento térmico.
- Arquivos grandes indicam dívida de organização, mas refatorações devem ser incrementais e guiadas por comportamento reproduzível.

## Critérios de aceitação

- Telemetria e comandos mantêm contratos compatíveis entre carro, bridge, PWA, iPhone e iPad.
- Viagens e recargas não são duplicadas ou perdidas após desconexão e retomada.
- Automações executam somente quando todas as condições configuradas são satisfeitas.
- Falha de LAN ou nuvem apresenta estado compreensível e usa o fallback previsto sem duplicar comandos.
- Atualizações instaláveis preservam a identidade de assinatura exigida pelo dispositivo.

## Próxima entrega

Executar os gates físicos pendentes em veículo estacionado e dispositivos autorizados, sem transformar builds de simulador ou testes sintéticos em alegação de compatibilidade de hardware.

## Manutenção

Atualize este documento quando objetivo, escopo, papéis ou critérios mudarem. Evidências técnicas ficam em [docs/setup.md](docs/setup.md) e decisões de estrutura em [docs/architecture.md](docs/architecture.md).
