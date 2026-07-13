# START-AI

Bootstrap for `.instructions/` payloads. Load this file first when scaffold work is requested. Do not preload the full instruction set.

## Harness Adapter Rule

- **CLI agents (`AGENTS.md`):** proceed only when scaffolding is explicitly requested.
- **GitHub Copilot:** `dotnet-scaffold` runs the phase router; `vertical-slice` loads `support/vertical-slice-checklist.md`; `scaffold-adopt` runs the brownfield adoption flow from `ai/adopt-codebase.md`.
- **Claude commands:** `/scaffold` runs the phase router; `/vertical-slice` loads the slice checklist; `/scaffold-adopt` runs the brownfield adoption flow from `ai/adopt-codebase.md`.
- **Generic assistants:** prompt with `Load .instructions/START-AI.md and run the scaffold router.` For brownfield adoption, prompt with `Load .instructions/ai/adopt-codebase.md and run the adoption flow against this solution.`
- **Path rule:** in an installed app, paths are under `.instructions/`; in this repo, paths are root-relative.

## Session Model

Each phase - and each Phase 5 sub-phase - runs in its own AI session. When complete, write/update `HANDOFF.md` in the target project root and close the session. The next session starts fresh from `START-AI.md` + `HANDOFF.md` only.

## Session Close

Before writing `HANDOFF.md` at session close, do a quick instruction-set check: did any instruction behavior turn out missing, ambiguous, or wrong this session - a skill that did not cover the case, a template token with no definition, a gate that misfired? If so, capture it as a one-line entry so it is not lost **(GR-07)**:

- **Installed app:** append to `.scaffold/INSTRUCTION-GAPS.md` at the project root (create `.scaffold/` if absent). Treat `.instructions/` files as read-only during scaffold work.
- **This instruction repo:** fold the fix directly into the owning instruction file (maintainer skill `/fold-feedback`).

This is a capture step, not a fix step (in a consumer app) - one line is enough; a maintainer triages and folds it back later. Then update `HANDOFF.md` and close.

## Initial Load Rule

Start each session with `START-AI.md` (this file) and `HANDOFF.md` in the target project root (if present - it is the resume contract). Then load only files needed for the current phase. Generate code only in the target project.

## File Loading Rule

Just-in-time. One phase per session; for Phase 5, one sub-phase per session. Load only the files listed for the current phase or sub-phase (see `ai/SKILL.md` section Phase 5 file table). Add on-demand files only when the current sub-phase clearly needs them. Close the session when the gate passes; the next session resumes from `START-AI.md` + `HANDOFF.md`.

This rule is the same regardless of the model's context window. Lost-in-the-middle is real even at 200K - loading every skill hurts output quality. See [`support/OPERATIONS.md`](support/OPERATIONS.md) section Context Budgets.

Load-set sizing is derived from `scaffoldMode` (`api-only` -> required-only; `lite`/`full` -> required + on-demand). See [`ai/SKILL.md`](ai/SKILL.md) section Load-Set Sizing.

## Compression Tool Rule

Context tools (`rtk`, Headroom, graph summaries, MCP compression) may optimize logs, diffs, search, and broad repo orientation. They must not replace direct reads of required scaffold instruction files.

When scaffold says load an instruction file, read source file text directly and preserve exact rules, tables, gates, templates, and conflict order. If context tight, reduce to current phase/sub-phase load set or stop with `HANDOFF.md`. Do not use lossy summary as active instruction context.

## Phase-1 Artifact Lifecycle Rule

`.scaffold/domain-specification.yaml`, `.scaffold/UBIQUITOUS-LANGUAGE.md`, and `.scaffold/DESIGN-DECISIONS.md` are the **binding source of truth** for the project. Every phase consumes them; every session must keep them current.

**Rule of thumb:** *Fix the artifact first, then the code. When drift exists, the artifact loses to code reality.*

- **New term, role, event, action, or design decision introduced this session** -> update the relevant Phase-1 artifact **before** generating the code that uses it.
- **Drift discovered** (code identifier or implemented decision diverges from artifact) -> update the artifact to match accepted reality, then continue.
- **Domain misunderstanding surfaces mid-Phase-5** -> stop, clarify with the developer, update Phase-1 artifacts, then re-scaffold the affected slice. See [`support/OPERATIONS.md`](support/OPERATIONS.md) section Mid-Session Rollback Protocol.

Canonical detail (what to update where, supersede vs rewrite, do-not-delete): [`README.md`](README.md) section Phase-1 Artifact Lifecycle. Verify currency at session close in `HANDOFF.md` (see [`support/HANDOFF.md`](support/HANDOFF.md) section Phase-1 Artifact Currency).

## Session Start Router

```
Is HANDOFF.md present?
  YES -> Resume from currentPhase/currentSubPhase. Skip Phase Router.
  NO  -> New project          -> Phase Router
        New entity            -> load support/vertical-slice-checklist.md fast-path only
        Brownfield adoption   -> load ai/adopt-codebase.md (replaces Phase 1)
```

First scaffold? The pruned API-only path with paste-ready prompts is [support/minimum-viable-scaffold.md](support/minimum-viable-scaffold.md).

**Brownfield adoption (C#/.NET/Azure profile only).** When `src/` already contains a buildable C#/.NET solution and no `.scaffold/` artifacts exist (or they're stale), use the adoption flow instead of the Phase 1 interview. The adoption flow derives Phase-1 artifacts from code inspection, then hands off into the regular workflow at Phase 2. Detail: [`ai/adopt-codebase.md`](ai/adopt-codebase.md).

## Tooling Check

Prefer CLIs over MCP over online resources. Use Microsoft Docs or Context7 when current docs are needed; add GitHub, Azure, Playwright, or Fetch only when the current phase needs repo, cloud, UI, or external document access. If a server is unavailable, note it in `HANDOFF.md` and continue. If `.scaffold/implementation-plan.md` exists, reload its **Tooling & Environment Readiness** section at session start and verify CLIs marked for the current phase are installed. Model tier is operator- and harness-controlled and defaults to high-capability for this one-time scaffold; see [README.md](README.md) section Model Tier by Phase for the per-phase tiers. If the harness cannot select a model, ignore and continue.

**Multi-agent orchestration (optional).** If your harness can spawn subagents (and ideally isolate their writes in git worktrees), parts of a single phase may be fanned out across agents - never across phase boundaries. The orchestrator is this session; it owns all shared writes and the gate. Fan out by independent work-item (one per host/entity/slice) only after the shared core they consume is complete and frozen; optionally follow the merged result with an independent read-only reviewer. Most harnesses cannot do this; if yours cannot, run sequentially. Detail and the pre-dispatch checklist: [`support/multi-agent.md`](support/multi-agent.md).

**Context graph tooling (optional).** If graphify is initialized for this repo (`graphify-out/graph.json` exists), prefer querying it over grepping raw files for orientation; if not, proceed normally. Choose the layer by LOC ratio - full (AST + semantic) when the knowledge layer (`.scaffold/` + `docs/*.md`) is at least the size of application `src`, structure-only when code dominates - and rebuild at phase boundaries (code wins: fix the artifact, then re-extract). `.instructions/` and `HANDOFF.md` are excluded from the graph corpus and the measurement: the former is generic scaffold payload (loaded directly by path when a workflow step needs it), the latter transient resume state. Layer-selection table, ignore file, harness enablement, build and post-commit hook commands: [`support/context-tooling.md`](support/context-tooling.md).

## Ground Rules

The 1-page index of binding rules with stable `GR-NN` identifiers lives at [`GROUND-RULES.md`](GROUND-RULES.md). Each phase gate and skill cites the `GR-NN` it enforces. Detail enforcement still lives in `ai/SKILL.md`, `support/execution-gates.md`, and the individual skill files - the index is the cite-by-id summary, not a new layer of authority.

## Conflict Resolution Order

See `ai/SKILL.md` section Non-Negotiables (canonical). [`GROUND-RULES.md`](GROUND-RULES.md) **GR-12** is the cite-by-id summary.

## Profiles

Phase 1 is the **universal core** - domain discovery, ubiquitous language, design decisions in pure business language with no stack assumptions. Phases 2-5 run under a **stack profile** that maps the Phase 1 output to concrete resources, plans, contracts, and implementation skills.

The only profile shipped today is **C#/.NET/Azure**, indexed at [`profiles/csharp-dotnet-azure.md`](profiles/csharp-dotnet-azure.md) (in this repo) or `.instructions/profiles/csharp-dotnet-azure.md` (in installed apps). Every Phase 2-5 file referenced below is part of that profile.

## Phase Router

Each phase = one session. Load only the files listed for the current phase.

- **Phase 1 (Domain Discovery - universal):** `ai/shared-understanding-interview.md`, `ai/domain-specification-schema.md`, `templates/ubiquitous-language-template.md`, `templates/design-decisions-template.md`. Walk every interview branch until the developer confirms, defaults, or defers each. Output: `.scaffold/domain-specification.yaml`, `.scaffold/UBIQUITOUS-LANGUAGE.md`, `.scaffold/DESIGN-DECISIONS.md` in target project (create the `.scaffold/` directory at project root if absent). Worked example: [support/phase-1-worked-example.md](support/phase-1-worked-example.md) (interview pacing, branch recaps, mid-interview corrections). Gate: developer reviews each artifact against its schema. -> `HANDOFF.md` (project root) -> close.
- **Phase 2 (Resource Definition - C#/.NET/Azure profile):** `ai/resource-implementation-schema.md` + `.scaffold/DESIGN-DECISIONS.md`. Ask clarification questions for unresolved resource decisions, API surface, external integrations, scaling, caching, messaging, optional workloads. Output: `.scaffold/resource-implementation.yaml` with `applicationStyle` declared explicitly and `externalDependencyModes` declared for every external dep. Gate: developer review. -> `HANDOFF.md` -> close.
- **Phase 3 (Implementation Plan - C#/.NET/Azure profile):** `ai/implementation-plan.md` + Phase 1/2 schemas + project YAMLs (under `.scaffold/`). Pre-flight branches on `packageStrategy` (resolved in Phase 2):
  - `feed` or `hybrid` - configure the private NuGet feed with the verified Python launcher from `support/python-setup.md`: `python {instructionsRoot}/scripts/configure-ef-packages-feed.py --root . --feed-url <url> --username <github-user> --prefix <packagePrefix>` (`{instructionsRoot}` is `.instructions` in an installed app and `.` in this repo); confirm `NUGET_AUTH_TOKEN` or an approved credential provider is available.
  - `local` - no feed wiring required. Phase 4 generates `src/Packages/<packagePrefix>.*` projects from `localPackageLayers` and the solution references them via `<ProjectReference>`.
  - `hybrid` only - Phase 4 also generates `src/Packages/<packagePrefix>.*` projects for every layer in `localPackageLayers`; layers covered by the feed remain `<PackageReference>` against `customNugetFeeds`.

  In every mode: verify `dotnet ef` is available. Prefer repo-local tooling (`dotnet new tool-manifest` then `dotnet tool install dotnet-ef` if missing); an existing user-global `dotnet-ef` is acceptable. Identify required CLIs/MCP servers per phase; populate the **Tooling & Environment Readiness** section of the plan. Output: `.scaffold/implementation-plan.md`. Gate: feed pre-flight passes (`configure-ef-packages-feed.py --check-only` exit 0 for feed/hybrid; nothing to restore yet - no solution exists until Phase 4, where the build gate proves the full restore) + developer review of `.scaffold/implementation-plan.md`. -> `HANDOFF.md` -> close.
- **Phase 4 (Contract Scaffolding - C#/.NET/Azure profile):** `ai/contract-scaffolding.md`, `skills/solution-structure.md`, `skills/package-dependencies.md`, `ai/placeholder-tokens.md`, `support/ef-packages-reference.md`. Generates: solution structure, interfaces, DTOs, entity shells, test infrastructure, no-op DI stubs. Gate: `dotnet build` succeeds on full solution including test projects. Set `currentPhase: 5`, `currentSubPhase: 5a`, and `contractsScaffolded: true` in `HANDOFF.md`. -> close.
- **Phase 5 (Implementation - C#/.NET/Azure profile):** one session per sub-phase (5a-5e: Foundation, App Core + Runtime, Optional Hosts, Quality + Delivery, Integration). Base: `ai/SKILL.md` + `ai/placeholder-tokens.md` + `ai/tdd-protocol.md` + `support/ef-packages-reference.md`. Per-sub-phase file lists are in `ai/SKILL.md` (Phase 5 file table). Gate per sub-phase: `dotnet build` + `dotnet test` (filter as appropriate). After the final enabled sub-phase, walk through `support/final-scaffold-checklist.md` manually.

## Reference Application

A companion reference app **TaskFlow** demonstrates every pattern these instructions produce. Canonical detail (repo URL, AI access rules, do-not-copy-wholesale rule, when to consult): see [`support/reference-app.md`](support/reference-app.md) and [`support/taskflow-proof-map.md`](support/taskflow-proof-map.md) for the phase -> area index. For regression-checking instruction changes against a canonical small scaffold, see [`support/golden-path-sample.md`](support/golden-path-sample.md).

## Event Boundary Rule

See [skills/messaging.md](skills/messaging.md) section Event Boundary Rule (canonical) and [ai/contract-scaffolding.md](ai/contract-scaffolding.md) section Integration Events for Phase 4 contract placement.
