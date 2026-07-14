# Add Vertical Slice

Add a new entity vertical slice to an existing C#/.NET solution.

**Entity and target:** $ARGUMENTS

All instruction files live under `.instructions/` in the project root. All file references below are relative to that folder.

> **Maintenance-repo note:** This command is designed to run in a target app where the instruction set has been installed at `.instructions/`. If `.instructions/` is missing in the current working directory, you are likely inside the AI-Instructions-Scaffold maintenance repo itself - stop and confirm with the developer rather than trying to add a slice here.

## Instructions

You are adding a complete entity slice (domain -> data -> application -> API -> tests) to an existing solution scaffolded with this instruction set.

1. Read `.instructions/support/vertical-slice-checklist.md` - follow the fast-path section.
2. Read `.instructions/ai/placeholder-tokens.md` for naming conventions.
3. Load the templates listed in the checklist's "Load Set for Slice" section (under `.instructions/templates/`).
4. If `.scaffold/resource-implementation.yaml` exists, read it for `scaffoldMode` and `testingProfile`.

## Pre-Flight

- Verify `dotnet build` passes on the existing solution.
- Locate `RegisterServices.cs`, both DbContext files, and `WebApplicationBuilderExtensions.cs`.
- Review existing entity patterns in the target project for consistency.
- If this slice introduces a new domain term, role, event, custom action, or design decision, append it to `.scaffold/UBIQUITOUS-LANGUAGE.md` / `.scaffold/DESIGN-DECISIONS.md` and update `.scaffold/domain-specification.yaml` **before** generating code. These artifacts are the living source of truth for the project (see `.instructions/README.md` section Phase-1 Artifact Lifecycle).

## Execution Order

Follow the canonical Slice Execution Order in `.instructions/support/vertical-slice-checklist.md`. Do not duplicate or override it here.

## Rules

- Generate production code in `src/`, test code in sibling `tests/`, and required solution/config changes at project root. Never modify files under `.instructions/`.
- Do not modify shared infrastructure - only add entity-specific files.
- Do not skip DI registration or endpoint mapping.
- Follow existing code patterns for consistency.

## Gate

See `.instructions/support/execution-gates.md` section Core Loop. Scope test filter to the new entity (`FullyQualifiedName~{Entity}`).

Report files created, wiring steps completed, and gate results.
