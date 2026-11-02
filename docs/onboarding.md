# Preparação local

## Pré-requisitos

- Git e acesso ao repositório autorizado.
- Acesso ao coordenador `/usr/local/bin/mac-mini-build` e à fila do Mac Mini.
- Para Android no runner: JDK 17, Android SDK e Gradle wrapper do projeto.
- Para Apple no Mac: Xcode e XcodeGen compatíveis com os projetos.
- Node.js para trabalho no bridge/PWA quando essa área estiver no escopo.
- `jq` e Bash para verificações de metadados/scripts.

Não copie caches, credenciais, keystores, certificados ou perfis de outro desenvolvedor.

## Primeira leitura

1. Leia [PRODUCT.md](../PRODUCT.md), [architecture.md](architecture.md) e [AGENTS.md](../AGENTS.md).
2. Confira `git status --short --branch` e não misture mudanças locais existentes.
3. Escolha somente o módulo necessário e identifique seus consumidores antes de editar contratos.
4. Defina o check possível antes da mudança; hardware, assinatura e produção não são ambientes de teste padrão.

## Verificações sem build

```sh
bash -n scripts/build-on-mac-mini.sh
node --check bridge/server.js
node --check bridge/gateway.js
```

Esses checks validam sintaxe, não comportamento, integração ou build.

## Build Android autorizado

Com um commit auditado e allowlisted:

```sh
scripts/build-on-mac-mini.sh COMMIT
mac-mini-build status JOB_ID
mac-mini-build fetch JOB_ID NOVO_DIRETORIO_VAZIO
```

Não rode `./gradlew`, Gradle ou Kotlin neste coordenador. Não faça fallback local se a fila falhar.

## Build Apple

Xcode também executa no Mac Mini autorizado. A fila aceita simulador com projeto e scheme explícitos e `CODE_SIGNING_ALLOWED=NO`. Archive de dispositivo, assinatura, TestFlight e publicação exigem fluxo e autorização próprios.

## Bridge e segredos

Use `bridge/env.template` como referência de nomes, nunca como local para valores reais. `.env`, tokens, certificados, dados pessoais, históricos e backups permanecem fora do Git. Não conecte produção para obter baseline.

## Agentes

Codex lê [AGENTS.md](../AGENTS.md). [CLAUDE.md](../CLAUDE.md) importa as mesmas instruções. Consulte [setup.md](setup.md) para skills, integrações e evidências.

## Problemas conhecidos

- Não há suíte automatizada detectada para os clientes.
- `bridge/package.json` não possui script de teste.
- Builds dependem da fila e de um commit Git auditado.
