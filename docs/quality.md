# Qualidade

## Checks disponíveis

```sh
bash -n scripts/build-on-mac-mini.sh
node --check bridge/server.js
node --check bridge/gateway.js
cd bridge && npm test
```

Os checks `node --check` validam somente sintaxe. `npm test` executa 66 testes do bridge com dados sintéticos; não conecta produção. Android e Apple compilam somente na fila autorizada.

## Builds

Android, Gradle, Kotlin e Xcode executam exclusivamente no Mac Mini. O fluxo Android exige commit Git imutável, auditoria de conteúdo e digest allowlisted. Consulte [BUILD_ANDROID_ON_MAC_MINI.md](BUILD_ANDROID_ON_MAC_MINI.md).

## Estratégia e cobertura de testes

- Bridge: 66 testes Node para contratos de catálogo, autenticação, relay, settings e transferência.
- EcoTrip Android: 70 testes unitários; a fila `android-test-debug` executa a suíte e monta Debug no mesmo commit imutável.
- iOS: 107 testes em `CameraVideoTests`; a fila também monta o scheme completo `HavalEcoTrip` para simulador com `CODE_SIGNING_ALLOWED=NO` no mesmo commit.
- Haval Camera: suíte JVM e `android-camera-verify` executam testes, Debug/nativo, release autorizado de verificação, lint vital, assinatura/alinhamento e integridade de ZIP. Isso verifica o pacote, não a câmera física.

Permanecem gates exclusivamente físicos: captura/mux OEM no Android 9 do veículo, Binder/provider entre APKs instalados e assinados, descoberta e perda de Wi-Fi reais, retomada Range, reprodução H.264/WebRTC e UI no iPhone, SDP real, sincronismo A/V, Stop remoto, perdas de Wi-Fi/Tailscale, 4G, armazenamento após perda de energia, consumo de recursos e temperatura. Nenhum build de simulador, APK montado ou teste sintético deve ser descrito como aprovação desses gates.

Um bug deve ter reprodução e, quando viável, teste de regressão que falhe antes da correção. Não use produção como ambiente de teste.

## Organização do legado

O limite de 350 linhas do toolkit é uma métrica de atenção, não bloqueio retroativo. Refatore por responsabilidade apenas junto de comportamento compreendido e verificável; não divida arquivos mecanicamente.

## Revisão

- Mudanças pequenas: revisar diff, chamadores diretos e check afetado.
- Telemetria, autenticação, comandos, OTA ou sincronização: revisar consumidores Android/iOS/PWA/bridge e estados de falha.
- Alterações não triviais: revisão independente quando disponível. Na ausência, registrar a limitação.
- Finalizar somente quando achados relevantes estiverem resolvidos ou aceitos e as verificações possíveis estiverem registradas.

## Segurança

Use o prompt de security review do Vibe Coding Toolkit para revisão read-only de baseline ou diff. Relatórios detalhados ficam fora do repositório. Correções, testes ativos, produção e publicação exigem autorização própria.

Áreas sensíveis: tokens do bridge, MQTT, WebSocket LAN, WebViews com interface JavaScript, upload/atualização APK, comandos do veículo, localização, áudio e compartilhamento entre apps.

## Harness nativo

O método Harness2 foi adaptado sem CLI externo: objetivo e critérios antes da mudança, reprodução, menor alteração completa, checks disponíveis e registro de limites. O CLI oficial não foi instalado.

Após mudanças em `AGENTS.md`, skills ou integrações, uma sessão limpa deve confirmar leitura da política de build, recusa de Gradle local e encaminhamento correto para a fila.

## Dependências e entrega

Auditorias de dependências são checks separados e não equivalem a build/testes. Git hooks, push blockers e exigência de branch não são padrões do projeto.
