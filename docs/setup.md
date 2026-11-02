# Setup e evidências

## Fonte e contexto

- Adoção executada em 2 de novembro de 2026.
- Vibe Coding Toolkit: commit `21b71b68679c11184f49c23168852014bf6dde8b`.
- Base do projeto: `6fdcd0719fc252c4bca96336f44175fd81a36a68`.
- Cliente: Codex CLI `0.163.0`; autenticação e provedor existentes preservados.
- Superpowers, Ponytail, Context7 e RTK foram descobertos nesta sessão; descoberta não equivale a uma integração ao vivo validada.
- Nenhum token, configuração pessoal, cache, assinatura ou dado de runtime foi copiado.

## Matriz de componentes

| Componente | Decisão | Escopo | Estado e evidência |
|---|---|---|---|
| Superpowers | Reusar skills de processo | Cliente | Descoberto e usado para planejar/executar esta adoção |
| Subagentes/model routing | Não criar roster fixo | Cliente | Execução inline; revisão independente continua preferível |
| RTK | Reusar hook global existente | Usuário | Instrução global carregada; nenhuma configuração de projeto adicionada |
| Ponytail | Menor mudança completa | Processo | Descoberto e aplicado sem alterar provedor/modelo |
| Caveman | Comunicação concisa quando solicitado | Cliente | Disponível; não exigido como modo persistente nesta adoção |
| ESLint/Biome gates | Não aplicar ao núcleo Kotlin/Swift/Node legado | Projeto | Nenhuma migração de lint criada |
| Graphify | Preparar exclusões | Projeto | `.graphifyignore` criado; grafo não gerado |
| Obsidian | Não necessário | Usuário | Documentação Git é a memória canônica |
| Memória do cliente | AGENTS + documentos canônicos | Projeto | Configurado; recuperação em sessão limpa pendente |
| Hooks de cliente | Não adicionar | Cliente | Hook RTK existente foi preservado sem duplicação |
| agent-browser | Não instalar para clientes nativos | Máquina | PWA pode justificar adoção futura em tarefa de UI |
| Context7 | Reusar skill/plugin descoberto | Cliente | Skill disponível; consulta ao vivo não foi necessária |
| Artifact/Vercel skills | Inaplicável ao stack principal | Projeto | Nenhuma skill local instalada |
| Chrome DevTools MCP | Opcional para PWA | Cliente | Não configurado nesta adoção |
| Codex workflow | AGENTS, docs e descoberta | Projeto | Configurado sem alterar opções pessoais |
| Next runtime/bundle | Inaplicável | Projeto | Não é Next.js |
| PostgreSQL guidance | Inaplicável | Projeto | Nenhum PostgreSQL observado |
| GitHub CI repair | Aplicável quando houver falha em PR | Projeto | `gh-fix-ci` não foi instalado localmente |
| Differential security review | Útil para contratos sensíveis | Projeto | Procedimento read-only documentado; não executado |
| shadcn/ui | Inaplicável | Projeto | UI usa Compose/SwiftUI/PWA própria |
| Sentry MCP | Inaplicável sem serviço escolhido | Cliente | Nenhum SDK/servidor adicionado |
| Harness2 nativo | Adotar método medido | Projeto | Procedimento em `docs/quality.md` |
| Harness2 CLI oficial | Não instalar | Externo | Exigiria dependências, isolamento, autenticação e possível custo |

## Documentação criada

- `README.md`, `PRODUCT.md`, `AGENTS.md`, `CLAUDE.md`.
- `docs/architecture.md`, `docs/design.md`, `docs/onboarding.md`, `docs/quality.md`, `docs/setup.md`.
- `.graphifyignore`, política e wrapper de build no Mac Mini.

## Verificações

| Item | Estado | Evidência |
|---|---|---|
| Origem do toolkit | Validado | Revisão fixa registrada acima |
| Estado Git | Validado | Mudanças preparadas em branch/clone isolado |
| Política de build | Validada por inspeção | `AGENTS.md`, script e `BUILD_ANDROID_ON_MAC_MINI.md` |
| Sintaxe do script | Validado | `bash -n scripts/build-on-mac-mini.sh` |
| Sintaxe Node selecionada | Validado | `node --check` nos entry points principais |
| Testes existentes | Ausentes | Nenhum teste de cliente ou script de teste do bridge encontrado |
| Android/iOS build | Não executado | Proibido no coordenador e fora do escopo desta adoção |
| Recuperação por sessão limpa | Pendente | Requer novo cliente após integração |

## Memória e continuidade

Codex carrega `AGENTS.md`; Claude Code importa o mesmo arquivo por `CLAUDE.md`. `PRODUCT.md` é a fonte de escopo; arquitetura, design, onboarding, qualidade e evidências têm responsabilidades separadas. Revalide fatos quando stack, contratos, destinos de build ou políticas mudarem.

## Pendências

1. Executar sessão limpa para confirmar descoberta das instruções.
2. Criar a primeira suíte de testes de domínio.
3. Validar integrações opcionais somente quando uma tarefa real exigir.
4. Reexecutar este setup quando o toolkit ou a arquitetura mudar, preservando customizações.

Nenhuma publicação, push, build, serviço externo ou alteração de produção faz parte desta adoção.
