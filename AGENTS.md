# Haval EcoTrip agent instructions

Read [PRODUCT.md](PRODUCT.md), [docs/architecture.md](docs/architecture.md), and the relevant code before changing behavior. Keep observations, assumptions, decisions, and evidence distinct. Update the responsible document when behavior, commands, boundaries, or configuration change.

## Build policy

- Never run Android, Gradle, Kotlin, or Xcode builds on the coordinator host.
- Android Debug builds use [docs/BUILD_ANDROID_ON_MAC_MINI.md](docs/BUILD_ANDROID_ON_MAC_MINI.md) and `scripts/build-on-mac-mini.sh COMMIT`.
- Submit only audited immutable Git commits. Never send uncommitted files, build outputs, caches, logs, `.env` files, signing material, service configuration, credentials, or runtime data.
- Do not fall back to a local build when the Mac Mini queue is unavailable. Report the outage and wait.
- Android release signing is outside the queue workflow. Xcode queue jobs are simulator-only with `CODE_SIGNING_ALLOWED=NO`.
- Do not claim a build or test passed unless it actually ran on the authorized host.

## Working agreements

- Preserve Android/Kotlin, iOS/Swift, bridge/API, MQTT, LAN, signing, and OTA contracts.
- Reproduce bugs and identify the responsible boundary before fixing them. Add a regression check when feasible.
- Prefer the smallest complete change. Avoid unrelated cleanup and never weaken validation, security, or accessibility to obtain a green result.
- Broad migrations, destructive data operations, production changes, signing, publication, and paid services require explicit scope.
- For nontrivial changes, inspect connected callers and contracts. Use independent review when available; otherwise record the limitation.
- Do not add Git hooks, push blockers, branch requirements, or global tools by default.

## Documentation map

- [README.md](README.md): entry point and installation overview.
- [PRODUCT.md](PRODUCT.md): product scope and acceptance criteria.
- [docs/architecture.md](docs/architecture.md): components, data flow, and boundaries.
- [docs/design.md](docs/design.md): UI sources and accessibility criteria.
- [docs/onboarding.md](docs/onboarding.md): local preparation and first workflow.
- [docs/quality.md](docs/quality.md): checks, review, and known gaps.
- [docs/setup.md](docs/setup.md): toolkit decisions, evidence, and pending work.
