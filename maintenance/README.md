# Maintaining AI-Instructions-Scaffold (source repo only)

Maintainer guide for **this** repository - the single source of truth for the instruction set. None of this ships to scaffolded apps: the `maintenance/` folder and the `.claude/skills/` maintainer skills are not in `scripts/install-to-project.py`'s copy allowlist, so they never appear under a target's `.instructions/`. (Same reason they are not linked from the shipped `README.md`/`CLAUDE.md` - a link would dangle in every target app.)

> **Source repo vs installed app.** In this repo the instruction files live at the root (`skills/`, `ai/`, `patterns/`, `support/`, `templates/`, `schemas/`, `profiles/`). In a scaffolded app they live under `.instructions/`. The scaffold workflows (`/scaffold`, `/scaffold-adopt`, `/vertical-slice`) are for the *app* and ship to it; the maintainer workflows below are for *this repo* and have no presence in an installed app.

## Repository layout - what ships

The ship boundary is an explicit allowlist in `scripts/install-to-project.py` (cross-checked by `scripts/validate-instructions.py` via `EXPECTED_RUNTIME_DIRS`). Nothing ships unless it is on that list - the allowlist *is* the boundary, so there is no separate `installer/` folder.

**Ships** (copied into a target app):

- Payload -> `<app>/.instructions/`: `START-AI.md`, `GROUND-RULES.md`, `README.md`, `CLAUDE.md`, and the dirs `ai/`, `patterns/`, `profiles/`, `schemas/`, `skills/`, `support/`, `templates/`, `scripts/` (the `INSTRUCTIONS_FILES` + `INSTRUCTIONS_DIRS` lists).
- Harness entrypoints -> app root / `.github/` / `.claude/`: `AGENTS.md`, `CLAUDE.md`, `.github/copilot-instructions.md` (merged inside sentinel markers), `.claude/commands/`, `.github/agents/` (the `AGENT_COPIES` list). These sit at the repo root because they are also *this* repo's own agent config - they cannot move into a folder.

**Never ships** (source-repo only):

- `maintenance/` (this folder), `.claude/skills/` (the maintainer skills), `tests/`, `.github/workflows/`, and tooling (`.gitignore`, `.vscode/`, `.venv/`, `.tmp/`).

When adding a file, decide which side it is on first: shippable -> a payload root above (and update the validator's `EXPECTED_RUNTIME_DIRS` if it is a new top-level dir); source-repo only -> `maintenance/` or `.claude/skills/`.

## Maintainer workflows

For Claude Code these are skills under `.claude/skills/` (auto-discovered, source-repo only). For Codex / Copilot, read this file and run the same commands - their root harness entrypoints ship to targets, so the maintainer workflows deliberately live here instead.

| Task | Claude skill | Command |
|---|---|---|
| Install / update the payload into an app | `/install-instructions` | `py -3 scripts/install-to-project.py --target "<app>" [--update] --verify` |
| SSOT / drift audit after a refactor | `/maintain-instructions` | `py -3 scripts/validate-instructions.py`, then the audit in [INSTRUCTION-SET-MAINTENANCE.md](INSTRUCTION-SET-MAINTENANCE.md) |
| Fold feedback / a gap back into the set | `/fold-feedback` | edit the owner file -> validate -> reinstall |
| End-to-end golden-path regression | `/golden-path` | `py -3 tests/golden-path/run-golden-path.py --dry-run` |

## Ground rules for instruction edits

- Edit instruction files **here**, never a target app's installed `.instructions/` (GR-07). Patch source, then reinstall.
- One canonical owner per concept; volatile facts live once + pointers elsewhere (SSOT - see [INSTRUCTION-SET-MAINTENANCE.md](INSTRUCTION-SET-MAINTENANCE.md)).
- Match the house voice: compressed, no em dash / emoji, `->` for arrows, no version numbers in baseline docs.
- After any edit: `py -3 scripts/validate-instructions.py` must pass; reinstall affected apps with `--update --verify`.

## Python launcher

Use a machine/user-global Python (the repo `.venv` is not a reliable launcher). `py -3` works on Windows where the launcher is installed; see [support/python-setup.md](../support/python-setup.md) for the full fallback chain. Run maintainer scripts from the repo root, and use the same launcher for every `scripts/*.py` and `tests/golden-path/*.py` invocation.

## Related maintainer docs (also source-repo only, not shipped)

- [INSTRUCTION-SET-MAINTENANCE.md](INSTRUCTION-SET-MAINTENANCE.md) - the SSOT / drift audit procedure, canary tripwire, and backlog.
- `scripts/install-to-project.py` - installer. `scripts/validate-instructions.py` - validator. `scripts/configure-ef-packages-feed.py` - target-app EF feed setup. `tests/golden-path/run-golden-path.py` - regression harness.
