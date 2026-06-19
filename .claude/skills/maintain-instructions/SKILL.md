---
name: maintain-instructions
description: "Run the instruction-set SSOT / drift audit after an instruction refactor - validate, canary tripwire, duplication triage, consolidate to one owner. Source-repo maintainer skill. Trigger: /maintain-instructions."
trigger: /maintain-instructions
---

# /maintain-instructions

Maintainer skill for the **source repo only**. The canonical procedure is `maintenance/INSTRUCTION-SET-MAINTENANCE.md` - this skill is the entry point and quick summary; do not duplicate that file's content here (it is itself the SSOT for the audit).

## When to use

- After any change that moved, merged, split, or reworded guidance across multiple files.
- Periodically: before cutting a release, or whenever a "broken until X" deviation is added.

## Procedure (summary - full detail in `maintenance/INSTRUCTION-SET-MAINTENANCE.md`)

1. **Structural check (always first):** `py -3 scripts/validate-instructions.py` - must report all checks passed (links, section anchors, Phase 5 load-set, template coverage, golden-path schemas). Fix failures before continuing.
2. **SSOT canary check:** run the canary tripwire block in `maintenance/INSTRUCTION-SET-MAINTENANCE.md` step 2 - each canary string must live in exactly one owner file. Two hits means drift crept back.
3. **Deep duplication scan:** grep distinctive method names / phrases across `skills/ patterns/ support/ templates/ ai/`; for each cluster decide consolidate vs legitimate per-phase minimum.
4. **Triage with the SSOT principles:** one canonical owner per concept; volatile facts live once + pointers elsewhere; phase-scoped files keep only their phase's minimum inline.
5. **Fix one topic** (authority hierarchy GR-12: `START-AI.md` -> `support/execution-gates.md` -> `ai/SKILL.md` -> skills -> templates). Replace other copies with a one-line pointer; add a new canary for the consolidated topic.
6. **Verify:** re-run the validator, `py -3 scripts/install-to-project.py --target "<a-scaffolded-app>" --verify`, the target's own validator, and re-run the canary check.

One topic per pass. The standing work queue (backlog, ranked by frequency x volatility) is in `maintenance/INSTRUCTION-SET-MAINTENANCE.md`.
