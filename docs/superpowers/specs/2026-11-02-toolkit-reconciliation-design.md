# Toolkit reconciliation design

## Intent

Adopt the Vibe Coding Toolkit documentation and agent harness in the canonical Git repository without touching the dirty `main` checkout on the Mac Mini. The result must be one reversible commit that can be reviewed or discarded independently.

## Goals

- Preserve the existing product README and repository structure.
- Add durable product, architecture, design, onboarding, quality, setup, and agent documentation.
- Make build instructions consistent with the mandatory Mac Mini queue policy.
- Apply the commit to an isolated Mac Mini worktree without pushing or merging.

## Non-goals

- Do not import the sanitized snapshot wholesale.
- Do not include snapshot provenance files, stripped signing configuration, or the dirty bridge migration.
- Do not build, sign, publish, push, merge, or modify production services.
- Do not install global tools, paid services, Git hooks, or dependencies.

## Constraints

- Base commit: `6fdcd0719fc252c4bca96336f44175fd81a36a68`.
- Android, Gradle, Kotlin, and Xcode builds are forbidden on the coordinator.
- The dirty Mac Mini checkout remains unchanged.
- Secrets, runtime data, caches, logs, signing material, and generated artifacts remain excluded.

## Approaches

1. Copy the snapshot over the dirty Mac checkout: rejected because it would overwrite newer commits, signing configuration, and bridge migration work.
2. Commit directly in the dirty Mac checkout: rejected because unrelated changes would contaminate the commit.
3. Build one commit in an isolated clone and apply it to an isolated Mac worktree: selected because it is reviewable, reversible, and preserves both working trees.

## Acceptance

- The isolated branch contains only toolkit/harness documentation and README build-policy corrections.
- Markdown local links resolve, JSON/scripts used by checks parse, and no obvious secret pattern is introduced.
- The Mac Mini worktree receives the exact commit through a patch, while the original `main` checkout retains its prior status.
