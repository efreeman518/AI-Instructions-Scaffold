# Scaffold New C#/.NET Application

Scaffold a new C#/.NET business application using the phased instruction set under `.instructions/`.

**Target project:** $ARGUMENTS

All instruction files (skills, templates, support docs, schemas, scripts) live under `.instructions/` in the project root. All file references below are relative to that folder.

> **Maintenance-repo note:** This command is designed to run in a target app where the instruction set has been installed at `.instructions/`. If `.instructions/` is missing in the current working directory, you are likely inside the scaffold-ai maintenance repo itself - stop and confirm with the developer rather than trying to scaffold here. (See `START-AI.md` section Harness Adapter Rule for the dual-path rule.)

## Instructions

You are executing the phased scaffolding workflow. Follow these steps exactly:

1. Read `.instructions/START-AI.md` - it is the canonical bootstrap. Follow it precisely.
2. Check for `HANDOFF.md` in the project root (NOT inside `.instructions/`).
   - If present: read `workflowStatus` first. `complete` exits the scaffold workflow into ordinary maintenance; `active` resumes from `currentPhase` / `currentSubPhase`. For a legacy file without the field, follow the fallback in `START-AI.md`.
   - If absent: new project - run the Phase Router.
3. Load only the files listed for the current phase in the Phase Router. For Phase 5, use the Phase 5 file table in `.instructions/ai/SKILL.md`.

## Rules

- Generate production code in `src/`, test code in sibling `tests/`, and solution/config files at project root. Never modify files under `.instructions/`.
- Conflict precedence: see `.instructions/ai/SKILL.md` section Non-Negotiables (canonical).
- Checkpoint after 15+ generated files or 3+ build/fix cycles - update `HANDOFF.md` (project root).
- After each phase gate passes, update `HANDOFF.md` and stop.
- Record instruction gaps in `.scaffold/INSTRUCTION-GAPS.md` (create `.scaffold/` at project root if absent). Do not modify instruction files.
- Session model and load rules: see `.instructions/START-AI.md` section Session Model. TaskFlow rules: see `.instructions/support/reference-app.md`, plus `.instructions/ai/SKILL.md` Non-Negotiables.

## Phases

Canonical phase list (files, outputs, gates) lives in `.instructions/START-AI.md` section Phase Router. Do not duplicate it here.

Run the Session Start Router now.
