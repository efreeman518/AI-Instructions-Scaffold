# Profile: C#/.NET/Azure

The active stack profile for the scaffold. Owns Phases 2-5 (resource definition -> implementation plan -> contract scaffolding -> implementation skills). Consumes the universal Phase 1 artifacts (`.scaffold/domain-specification.yaml`, `UBIQUITOUS-LANGUAGE.md`, `DESIGN-DECISIONS.md`) unchanged.

This file is an **index**, not a skill. Use it to see which files in the repo belong to the profile vs. the universal core. For the operational entrypoint, start at [../START-AI.md](../START-AI.md).

## What this profile produces

A clean-architecture C#/.NET solution with:

- `.slnx` solution layout and central package management (`Directory.Packages.props`).
- Dual `DbContext` pattern (`{App}DbContextTrxn` / `{App}DbContextQuery`) over the shared `DbContextBase<Guid, Guid>` base type.
- Entity Framework Core data access with audit/tenant interceptors and integration tests using Testcontainers SQL.
- DDD aggregate boundaries enforced in the generated write surface (GR-15): aggregate roots get the full slice, while internal children (1:N owned, M:N junction) are mutated only through the root's `Add*`/`Remove*` methods, the `{Root}Updater`, and nested sub-resource routes - no standalone child write handlers/services/endpoints. See [../skills/domain-model.md](../skills/domain-model.md) section Aggregate Roots vs Internal Children.
- ASP.NET Core minimal-API host with `WebApplicationFactoryBase` test infrastructure.
- Aspire AppHost orchestration and Azure-ready hosting patterns.
- Optional hosts: YARP Gateway, Azure Functions, TickerQ scheduler, notifications, Blazor server/WASM, React/Vite SPA, Uno (desktop / WASM / mobile).
- Shared base-type contracts (`EntityBase`, `DbContextBase`, `DomainResult`, `IRepositoryBase`, `IRequestContext`) sourced as `<packagePrefix>.*` packages via one of three strategies: `feed`, `local`, or `hybrid`.
- Azure integrations as no-op stubs by default (Entra, Key Vault, AI Search, Foundry, ACS), promoted to live only when configured.

## Profile-owned files

Phase 2-5 content. Everything below assumes a C#/.NET/Azure target and references stack-specific tooling, packages, or types.

### `ai/`

- [`ai/resource-implementation-schema.md`](../ai/resource-implementation-schema.md) - Phase 2: maps domain to `packageStrategy`, `customNugetFeeds`, `localPackageLayers`, Aspire resources, SQL/CosmosDB/Table/Blob datastores.
- [`ai/implementation-plan.md`](../ai/implementation-plan.md) - Phase 3: NuGet feed wiring, `dotnet ef` tooling, Aspire, Function App, React/Vite, Uno platforms.
- [`ai/contract-scaffolding.md`](../ai/contract-scaffolding.md) - Phase 4: `.slnx`, `Directory.Packages.props`, `DbContextBase<Guid, Guid>`, EF interceptors, `WebApplicationFactoryBase`, Testcontainers SQL.
- [`ai/SKILL.md`](../ai/SKILL.md) - Phase 5 load sets, sub-phase routing, non-negotiables, scaffold definition of done. Title reads "C#/.NET/Azure Profile - Phase 5 Skill Set."
- [`ai/adopt-codebase.md`](../ai/adopt-codebase.md) - brownfield adoption (replaces Phase 1 interview by reading existing C# code: `Domain.Model`, EF configurations, DI registrations, `nuget.config`, Aspire `AppHost`).
- [`ai/tdd-protocol.md`](../ai/tdd-protocol.md) - TDD cadence used by Phase 5a/5b. C#-bound in command examples but logically reusable.
- [`ai/placeholder-tokens.md`](../ai/placeholder-tokens.md) - token catalog used by templates. C#-bound by virtue of the tokens it defines.

### `skills/`

All files. Each is a stack-specific how-to (EF data persistence, ASP.NET Core API, Bootstrapper DI, Aspire wiring, multi-tenant, caching, resilience, security, identity, observability, configuration-secrets, gateway, messaging, gRPC, external-api, AI integration, AI search, agent, Blazor, React/Vite UI, Uno UI shell/MVUX/platforms, function-app, background-services, notifications, FlowEngine, IaC, CI/CD, testing, testing-quality, domain-model, application-layer, solution-structure, package-dependencies).

### `templates/`

All files. Code-shape templates for generated C# artifacts (entity, EF config, repository, DTO, mapper, service, endpoint, domain rules, message handler, exception handler, structure validator, updater, Uno MVUX model, Uno XAML page, Uno UI client layer, health check, Dockerfile, FlowEngine trigger/test, every test template tier). The two **universal** templates live outside this set - see "Universal core" below.

### `patterns/`

All files. Cross-project wiring for the C#/.NET solution shape: data-layer-wiring, api-host-wiring, infrastructure-wiring, expected-output-index.

### `support/`

C#-specific operator content:

- [`support/ef-packages-reference.md`](../support/ef-packages-reference.md) - base-type catalog (EntityBase, DbContextBase, DomainResult, IRepositoryBase, IRequestContext).
- [`support/execution-gates.md`](../support/execution-gates.md) - `dotnet build` / `dotnet test` / `dotnet run` gates per phase.
- [`support/vertical-slice-checklist.md`](../support/vertical-slice-checklist.md) - single-entity fast path.
- [`support/final-scaffold-checklist.md`](../support/final-scaffold-checklist.md) - solution-level acceptance.
- [`support/taskflow-proof-map.md`](../support/taskflow-proof-map.md) - pointer to the TaskFlow reference app (Aspire + dual DbContext + YARP + Uno + Blazor + React).
- [`support/reference-app.md`](../support/reference-app.md) - consultation rules for TaskFlow.
- [`support/OPERATIONS.md`](../support/OPERATIONS.md) - fail-fast, git checkpoint, missing-inputs, rollback, mixed-store gate. C#-bound through its examples; the operational concepts are reusable.
- [`support/phase-1-worked-example.md`](../support/phase-1-worked-example.md) - transcript from the TaskFlow Phase 1 interview. Phase 1 itself is universal, but this example is a C#-bound illustration.

### `schemas/`

- `schemas/resource-implementation.schema.json` - validates the Phase 2 output; encodes `packageStrategy`, `customNugetFeeds`, `localPackageLayers`, Aspire resource shape.
- `schemas/domain-specification.schema.json` is **universal** - see below.

### `scripts/`

- `scripts/configure-ef-packages-feed.py` - sets up `nuget.config` for private NuGet feeds. C#-bound.
- `scripts/install-to-project.py`, `scripts/validate-instructions.py` are profile-agnostic (operate on the instruction tree itself).

### Harness commands and agents

All currently profile-scoped because the scaffold only ships this profile:

- `.claude/commands/scaffold.md`, `.claude/commands/vertical-slice.md`, `.claude/commands/scaffold-adopt.md`.
- `.github/agents/dotnet-scaffold.agent.md`, `.github/agents/vertical-slice.agent.md`, `.github/agents/scaffold-adopt.agent.md`.

## Universal core (NOT in this profile)

These files are stack-agnostic and should stay so. A second profile would consume them unchanged.

- [`ai/shared-understanding-interview.md`](../ai/shared-understanding-interview.md) - Phase 1 interview (entities, events, roles, workflows, business rules in pure business language).
- [`ai/domain-specification-schema.md`](../ai/domain-specification-schema.md) - Phase 1 output schema. **Known leak:** carries one C#-specific section warning against entity names that collide with C# framework types (`Task`, `Thread`, `Type`, `File`, `Path`, etc.). Left in place. If a second profile ships, extract this warning into the profile and replace it with a generic "consult the active profile for stack-specific naming rules" pointer.
- [`ai/shared-understanding-interview.md`](../ai/shared-understanding-interview.md) - Phase 1 interview. **Known leak:** a "Heads-up - Phase 2 will open with packaging strategy" callout mentions private NuGet feeds, `EF.*` packages, and `src/Packages/<Prefix>.*` (Phase-2/C# concepts). Left in place. Same extraction path as the schema leak above if a second profile ships.
- [`templates/ubiquitous-language-template.md`](../templates/ubiquitous-language-template.md) - domain vocabulary template.
- [`templates/design-decisions-template.md`](../templates/design-decisions-template.md) - design-decision log template.
- `schemas/domain-specification.schema.json` - JSON Schema for the Phase 1 output.
- Phase-1 portions of [`START-AI.md`](../START-AI.md) (Session Model, Initial Load Rule, File Loading Rule, Phase-1 Artifact Lifecycle Rule, Phase 1 entry in the Phase Router).
- Phase-1 portions of [`README.md`](../README.md) (Phase-1 Artifact Lifecycle section, Phase 1 row of the Phases table).

## How another profile would plug in

A new profile (e.g. `profiles/typescript-node.md`, `profiles/python-fastapi.md`) would:

1. Define its own Phase 2 schema (the equivalent of `resource-implementation-schema.md`) that consumes the universal Phase 1 YAML and emits a stack-specific resource map.
2. Define its own Phase 3 implementation plan, Phase 4 contract scaffolding, and Phase 5 skill set.
3. List its files in a profile index analogous to this one.
4. Add a routing entry in `START-AI.md` section Profiles so the agent can pick the active profile.

The universal Phase 1 artifacts (`.scaffold/domain-specification.yaml`, `UBIQUITOUS-LANGUAGE.md`, `DESIGN-DECISIONS.md`) are the contract between Phase 1 and any profile. A profile reads them; it does not rewrite them.

**No commitment exists today to build a second profile.** This document is the doc that would let someone (or future-us) do it without restructuring the repo.

## Brownfield and vertical-slice are profile-bound

[`ai/adopt-codebase.md`](../ai/adopt-codebase.md) and [`support/vertical-slice-checklist.md`](../support/vertical-slice-checklist.md), plus their three harness commands/agents, all assume the C#/.NET/Azure profile (they read `Domain.Model`, EF configurations, DI registrations, `.slnx` shape, etc.). Generalizing them is a candidate for later if a second profile ships - not in scope today.
