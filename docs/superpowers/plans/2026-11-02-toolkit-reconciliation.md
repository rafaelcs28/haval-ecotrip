# Toolkit Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Create one audit-friendly commit that adopts the toolkit documentation and safe build instructions, then apply it to an isolated Mac Mini worktree.

**Architecture:** Work in a clean clone at the current remote `main`, preserve the existing README, and transfer the resulting commit as a Git patch. The dirty Mac Mini checkout remains untouched; the patch lands on a separate branch/worktree.

**Tech Stack:** Git, Markdown, Bash, rsync/SSH.

**Spec:** `docs/superpowers/specs/2026-11-02-toolkit-reconciliation-design.md`

## Global Constraints

- Base commit is `6fdcd0719fc252c4bca96336f44175fd81a36a68`.
- Do not build, sign, publish, push, merge, or modify production services.
- Do not copy snapshot provenance, stripped signing configuration, or bridge migration changes.
- Keep the original Mac Mini checkout unchanged.

## Review Focus

- Existing README product/install information must not be lost.
- No local Android/Gradle/Kotlin/Xcode build instruction may remain canonical.
- Documentation must describe the tracked bridge accurately without claiming runtime data is versioned.
- Snapshot-only limitations must not be presented as canonical repository state.
- New files must not contain credentials, signing paths, or personal absolute paths.

---

### Task 1: Project harness documentation

**Files:**
- Create: `AGENTS.md`, `CLAUDE.md`, `PRODUCT.md`, `.graphifyignore`
- Create: `docs/architecture.md`, `docs/design.md`, `docs/onboarding.md`, `docs/quality.md`, `docs/setup.md`
- Create: `docs/BUILD_ANDROID_ON_MAC_MINI.md`, `scripts/build-on-mac-mini.sh`

**Interfaces:**
- Consumes: repository layout and existing build policy.
- Produces: canonical project context loaded by Codex/Claude and linked from README.

- [ ] Create project-specific documentation without template placeholders.
- [ ] Validate local Markdown links, required files, script syntax, and obvious secret patterns.
- [ ] Commit the task.

### Task 2: Preserve and reconcile README

**Files:**
- Modify: `README.md`

**Interfaces:**
- Consumes: documentation paths from Task 1.
- Produces: product entry point with queue-only build instructions and documentation map.

- [ ] Replace local Gradle/release-signing instructions with the authorized Mac Mini queue flow.
- [ ] Add links to the canonical toolkit documents without removing product/install details.
- [ ] Verify the README still covers architecture, components, bridge, APIs, MQTT, and installation.
- [ ] Commit the task.

### Task 3: Transfer and verify the commit on the Mac Mini

**Files:**
- Create outside repository: Git format-patch artifact.
- Create on Mac Mini: isolated worktree and branch `codex/toolkit-reconciliation`.

**Interfaces:**
- Consumes: commits from Tasks 1-2.
- Produces: matching isolated branch on the Mac Mini, no push or merge.

- [ ] Run complete documentation/static validation and review the exact diff.
- [ ] Export commits as a patch and apply them to a new Mac Mini worktree.
- [ ] Verify commit IDs/content and confirm the original checkout status is unchanged.
