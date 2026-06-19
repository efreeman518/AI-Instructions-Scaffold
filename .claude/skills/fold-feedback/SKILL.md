---
name: fold-feedback
description: "Fold external feedback or a target app's .scaffold/INSTRUCTION-GAPS.md into the correct owner instruction file in this source repo, validate, then reinstall to affected apps. Source-repo maintainer skill. Trigger: /fold-feedback."
trigger: /fold-feedback
---

# /fold-feedback

Maintainer skill for the **source repo only**. Intake new guidance - a coding agent's feedback, or a scaffolded app's `.scaffold/INSTRUCTION-GAPS.md` - and fold it into the instruction set as single-source-of-truth, then reinstall to consumer apps.

## When to use

- A scaffolded app surfaced an instruction gap, or a coding agent gave feedback to fold back.
- You are propagating an instruction change out to consumer apps.

## Steps

1. **Read the input.** The feedback text, or a target's `.scaffold/INSTRUCTION-GAPS.md`. Restate it as concrete rules before touching any file.
2. **Find the canonical owner.** Authority hierarchy (GR-12): `START-AI.md` -> `support/execution-gates.md` -> `ai/SKILL.md` -> `skills/*` -> `templates/*`. Volatile facts and shared rules live once in the owner; every other file carries a one-line pointer, never a restatement (SSOT principles in `maintenance/INSTRUCTION-SET-MAINTENANCE.md`).
3. **Edit source instruction files only.** Never edit a target app's installed `.instructions/` (GR-07). Match the house voice: compressed, no em dash / emoji, `->` for arrows, no version numbers in baseline docs.
4. **Validate.** `py -3 scripts/validate-instructions.py`; re-run the canary check; if you consolidated a topic, add a canary in `maintenance/INSTRUCTION-SET-MAINTENANCE.md`.
5. **Reinstall.** For each affected app: `py -3 scripts/install-to-project.py --target "<app>" --update --verify` (see `/install-instructions`).
6. **Flag divergence.** If a folded change describes a pattern the reference app (`AI-Instructions-ReferenceApp`) does not yet implement, say so plainly rather than leaving the docs and proof silently out of sync.
