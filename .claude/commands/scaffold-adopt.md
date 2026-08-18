# Adopt Existing C#/.NET Codebase

Generate Phase-1 artifacts (`.scaffold/domain-specification.yaml`, `.scaffold/UBIQUITOUS-LANGUAGE.md`, `.scaffold/DESIGN-DECISIONS.md`) from an **existing** C#/.NET solution by code inspection. Use this command when adopting the scaffold workflow onto a brownfield project so that `/vertical-slice` and the regular Phase 2+ flow become usable.

**Target project:** $ARGUMENTS

All instruction files live under `.instructions/` in the project root. All file references below are relative to that folder.

> **Maintenance-repo note:** This command is designed to run in a target app where the instruction set has been installed at `.instructions/`. If `.instructions/` is missing in the current working directory, you are likely inside the scaffold-ai maintenance repo itself - stop and confirm with the developer rather than trying to adopt here.

## Instructions

You are executing the brownfield adoption workflow - a code-driven replacement for Phase 1.

1. Read `.instructions/START-AI.md` section Phase-1 Artifact Lifecycle Rule. The drift principle (*the artifact loses to code reality*) governs this entire session: existing code is authoritative.
2. Read `.instructions/ai/adopt-codebase.md` - it is the canonical execution guide.
3. Confirm with the developer that the solution builds (`dotnet build` exits 0) and that they accept code-as-authority for any conflict with prior intent.
4. If `.scaffold/` already contains any of the three artifacts, ask whether to replace, merge, or abort before continuing.
5. Walk the Inspection Order in `.instructions/ai/adopt-codebase.md` section Inspection Order. After each pass, recap findings and ask the developer to confirm or correct.
6. For each inferred design decision, run the Decision Confirmation Loop in `.instructions/ai/adopt-codebase.md` section Decision Confirmation Loop.
7. Write the three artifacts under `.scaffold/` per the schema/templates referenced in `.instructions/ai/adopt-codebase.md` section Output Artifacts.
8. Write `HANDOFF.md` at project root with `workflowStatus: active`, `currentPhase: 2`, `currentSubPhase: ""`, `contractsScaffolded: false`, and a section Completed note: "Phase 1 adopted from existing codebase via `ai/adopt-codebase.md` inference."
9. Stop. The next session resumes at Phase 2 (Resource Definition) exactly as for a greenfield project.

## Pre-Flight

Run every checkbox in `.instructions/ai/adopt-codebase.md` section Pre-Flight before reading any source files. Do not proceed on a red build.

## Rules

- Generate only the three `.scaffold/` artifacts and `HANDOFF.md`. **Do not modify any source code, project files, or solution files.**
- Do not invent features. If the scaffold's canonical patterns expect something the code lacks (gateway, multi-tenancy, observability), record it as a deferred `D-###` decision with `inferred-from: absence`, not as a generated stub.
- Do not retroactively recommend refactors. Surface violations of canonical patterns as design decisions; do not edit code to fix them.
- Conflict precedence: see `.instructions/ai/SKILL.md` section Non-Negotiables (canonical).
- Record instruction gaps (e.g., "the adopt skill needs guidance for X pattern that wasn't covered") in `.scaffold/INSTRUCTION-GAPS.md`. Do not modify instruction files.

## Gate

See `.instructions/ai/adopt-codebase.md` section Gate. `domain-specification.yaml` must validate against its schema; `UBIQUITOUS-LANGUAGE.md` and `DESIGN-DECISIONS.md` must follow their templates and cover every entity, public language term, and visible architectural decision in the solution before declaring done.
