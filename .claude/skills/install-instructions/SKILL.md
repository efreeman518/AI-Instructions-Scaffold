---
name: install-instructions
description: "Install or update this repo's instruction payload into a target C#/.NET app, or verify an existing install. Source-repo maintainer skill - run from the AI-Instructions-Scaffold clone, never from a scaffolded app. Trigger: /install-instructions."
trigger: /install-instructions
---

# /install-instructions

Maintainer skill for the AI-Instructions-Scaffold **source repo only** (it lives in `.claude/skills/`, which the installer does not copy, so it never ships into a scaffolded app). Copies the runtime payload into a consumer app's `.instructions/` and merges the harness entrypoints at the app root via `scripts/install-to-project.py`.

## When to use

- Push the current instruction set into a new or existing app repo.
- Re-verify an install after manual edits or a selective copy.

## Run

Run from the repo root with a machine/user Python launcher (`py -3` works here; full fallback chain in `support/python-setup.md`).

```powershell
# Fresh install or re-install (content-aware: unchanged files skipped, changed files overwritten and listed)
py -3 scripts/install-to-project.py --target "<app-repo-root>" --verify

# Plan only / smoke-check an existing target
py -3 scripts/install-to-project.py --target "<app-repo-root>" --dry-run
py -3 scripts/install-to-project.py --target "<app-repo-root>" --verify-only
```

## Notes

- **Never install into `AI-Instructions-ReferenceApp`.** The reference app is the payload-free proof sibling of this repo - it validates the docs by example, it does not consume them. Installing there vendors a duplicate of the source of truth one directory over. Valid targets are real consumer apps only.
- **One mode for fresh and existing targets:** installs are content-aware and idempotent - identical files are skipped, differing target files are overwritten and listed (source is SSOT per GR-07). Root `HANDOFF.md` is always left untouched. `--update` is a deprecated no-op kept for compatibility.
- `AGENTS.md`, `CLAUDE.md`, `.github/copilot-instructions.md` are merged inside `<!-- ai-scaffold: start -->` / `<!-- ai-scaffold: end -->` markers - app content outside the markers is preserved.
- The script refuses to install into the source repo itself (`target == repo root`), except `--verify-only`.
- `tests/`, `.git/`, `.venv/`, `.tmp/`, `.vscode/`, `.githooks/`, `__pycache__` are excluded; `.claude/skills/` and root maintainer docs are never in the payload.
- After install, configure the EF package feed when `packageStrategy` is `feed`/`hybrid` (see `README.md` -> After install).
- Flags: `--update`, `--verify`, `--verify-only`, `--dry-run`, `--instructions-only`. Full table: `README.md` section "Install into a new app".
- Never edit a target's `.instructions/` in place; fold changes here in the source first, then reinstall - see `/fold-feedback`.
