# Minimum Viable Scaffold (MVS)

The shortest path from "empty repo" to "passing API with one entity" using this instruction set. Use this when you want to ship something working before deciding on optional hosts, UI, gateway, AI, or messaging.

## What MVS produces

- A single .NET API host with one entity (CRUD + search), one DbContext pair (Trxn + Query), repositories, mapper, validator, service, endpoints, and unit + endpoint tests.
- `scaffoldMode: api-only`. No Gateway, no Uno/Blazor/React UI, no Function App, no Scheduler, no AI services, no messaging.
- Every external dependency declared `lazy-optional` so the app boots locally without cloud setup.
- Auth runs in scaffold mode (config-driven principal). Live identity provider is deferred.

You should reach a green `dotnet build` + `dotnet test` and working `/healthz` plus `/readyz` probes in under a day of focused work. Everything beyond that is incremental.

## When to use MVS vs the full workflow

| Situation | Use |
|---|---|
| First time using this scaffold; want to feel the loop end-to-end | MVS |
| Internal tool, prototype, or proof-of-concept | MVS |
| Production app with known scope (gateway, UI, scheduler, etc.) | Full [phase router](../START-AI.md) |
| Adding to an already-scaffolded app | [vertical-slice-checklist.md](vertical-slice-checklist.md) |

MVS is a profile, not a separate path. After MVS finishes you can promote to a richer profile by editing `.scaffold/resource-implementation.yaml` and running additional Phase 5 sub-phases.

## Prerequisites

Same as the [README Prerequisites](../README.md#prerequisites), with these MVS-specific simplifications:

- **Skip:** Uno templates, `uno-check`, Kiota, Functions Core Tools.
- **Required:** `.NET SDK`, `git`, Python (for installer), Docker (only if you keep Aspire enabled - MVS keeps it off by default). Package feed access is conditional on `packageStrategy` (chosen in Phase 2): `feed`/`hybrid` needs read access to the configured private feed (e.g., GitHub Packages for the canonical `EF.*` example); `local` needs only `nuget.org`.

## Install

```powershell
# from a clone of this instruction repo
py -3 scripts/install-to-project.py --target C:\path\to\your-app --verify
```

The `--verify` flag confirms all entrypoints landed correctly. See [install-to-project.py](../scripts/install-to-project.py) for the full smoke-check list.

## The MVS prompt overlays

Six AI sessions: one per phase for Phases 1-4, plus separate sessions for Phase 5a and Phase 5b (Phase 5 always runs one sub-phase per session). MVS skips 5c, 5d, and 5e - see section Why this works.

Generic phase prompts live in [prompt-catalog.md](prompt-catalog.md). For each session, paste that phase's prompt, append the MVS overlay below, fill placeholders, run the gate, update `HANDOFF.md`, and close. This file owns only the API-only, single-entity deltas.

### Phase 1 - Domain Discovery (one entity)

Paste the Phase 1 prompt from [prompt-catalog.md](prompt-catalog.md), then append:

```text
Mode: minimum-viable-scaffold (API-only, one entity, no optional hosts).
Set the generic prompt's entity list to exactly one entity: {EntityName} with fields {field1: type, field2: type, ...}.
Run shared-understanding-interview.md but skip branches that don't apply to a single-entity API
(messaging, scheduling, multi-host, multi-tenant unless explicitly required).
Record the MVS profile in .scaffold/DESIGN-DECISIONS.md.
```

**Done when:** `.scaffold/domain-specification.yaml` defines exactly one entity. `.scaffold/DESIGN-DECISIONS.md` records that this is an MVS profile.

### Phase 2 - Resource Definition (api-only)

Paste the Phase 2 prompt from [prompt-catalog.md](prompt-catalog.md), then append:

```text
First, resolve packageStrategy + packagePrefix (Discovery question #1):
  - feed: provide feed URL(s) + prefix (e.g., EF). Walk ef-packages-reference.md to confirm coverage; promote to hybrid if anything is missing.
  - local: provide prefix only; the scaffold generates src/Packages/<Prefix>.* for every layer in ef-packages-reference.md.
  - hybrid: feed URL(s) + prefix + localPackageLayers for layers the feed lacks.
Set scaffoldMode: api-only. Set testingProfile: minimal.
Disable: gateway, uno-ui, blazor-ui, function-app, scheduler, aspire, multi-tenant, ai-services, messaging.
Set every external dependency mode to lazy-optional.
```

**Done when:** `.scaffold/resource-implementation.yaml` has `scaffoldMode: api-only` and every optional flag is `false`. No external dep is in `deployment-only` or `emulator` mode.

### Phase 3 - Implementation Plan

Paste the Phase 3 prompt from [prompt-catalog.md](prompt-catalog.md), then append:

```text
Tooling section: list only CLIs needed for an api-only scaffold (dotnet, dotnet-ef). Skip MCP discovery beyond Microsoft Docs + Context7.
```

**Done when:** the plan is reviewed, its Tooling section has no unresolved items, and the feed pre-flight passes for `feed`/`hybrid`. No solution exists to restore until Phase 4.

### Phase 4 - Contract Scaffolding

Paste the Phase 4 prompt from [prompt-catalog.md](prompt-catalog.md), then append:

```text
MVS scope: api-only. Skip projects for Gateway, Aspire AppHost, Function App, Uno/Blazor/React UI, Scheduler.
Expected solution: API host, Application/Domain/Infrastructure projects, Test.Support, Test.Unit, Test.Endpoints.
```

**Done when:** `dotnet build` is green and the solution contains the API host, Application/Domain/Infrastructure projects, the three test projects, and any `src/Packages/<Prefix>.*` projects required by `packageStrategy`. No optional hosts.

### Phase 5 - Implementation (5a + 5b only for MVS)

MVS skips 5c (no optional hosts), 5d (no architecture/load/benchmark gates beyond `minimal` profile), and 5e (auth stays in scaffold mode; no AI services).

#### 5a - Foundation (TDD)

Use the Phase 5 session-start prompt plus the 5a block from [prompt-catalog.md](prompt-catalog.md), then append:

```text
Replace no-op repository stubs with real implementations in RegisterServices.cs.
```

#### 5b - App Core + API (TDD)

Use the Phase 5 session-start prompt plus the 5b block from [prompt-catalog.md](prompt-catalog.md), then append:

```text
Load only the api-only required entries from the 5b row.
Skip runtime concerns: gateway, multi-tenant, caching, aspire, observability, security.
Skip the Aspire portion of the 5b gate - Aspire is disabled in MVS.
```

**Done when:** `dotnet build` green, `dotnet test --filter "TestCategory=Unit|TestCategory=Endpoint"` green, the API host starts, and `/healthz` plus `/readyz` return 200.

## "You are done" check

Run from the solution root:

```powershell
dotnet build
dotnet test --filter "TestCategory=Unit|TestCategory=Endpoint"
dotnet run --project src\Host\{Host}.Api -- --urls "http://localhost:5100"
# in another shell, or via your HTTP client:
# GET http://localhost:5100/healthz -> 200 OK
# GET http://localhost:5100/readyz -> 200 OK
# POST http://localhost:5100/v1/{entity-route} -> 201 + Location header
```

If all three pass, MVS is complete.

## Promoting beyond MVS

When you're ready to add scope:

- **New entity:** [vertical-slice-checklist.md](vertical-slice-checklist.md) fast-path.
- **Add a runtime concern** (caching, gateway, multi-tenant, observability, security): edit `.scaffold/resource-implementation.yaml` to enable the flag, run a 5b session loading only the new skill file.
- **Add an optional host** (Function App, Scheduler, Uno UI, Blazor UI, React UI): enable the flag in `.scaffold/resource-implementation.yaml`, run a dedicated 5c session per host.
- **Live auth or AI services:** enable in `.scaffold/resource-implementation.yaml`, run a 5e session.
- **Quality gates** (architecture tests, load, benchmarks): bump `testingProfile` and run a 5d session.

## Why this works

MVS is the same instruction set, scoped down. Every gate, every artifact, every conflict-precedence rule still applies - the only difference is that `.scaffold/resource-implementation.yaml` flags most optional surfaces off, so the per-sub-phase load sets shrink, and 5c/5d/5e can be deferred until the API is real.

If you find yourself wanting Gateway or UI or messaging mid-MVS, stop the MVS path and switch to the full [phase router](../START-AI.md). Mixing them produces incomplete artifacts.
