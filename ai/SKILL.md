# C#/.NET/Azure Profile - Phase 5 Skill Set

This file owns the Phase 5 load sets, non-negotiables, and concern routing for the **C#/.NET/Azure profile**. Phase 1 is the universal core and runs without a profile loaded; profile-bound files start at Phase 2. Profile index: [../profiles/csharp-dotnet-azure.md](../profiles/csharp-dotnet-azure.md).

## Purpose

Use this skill set to scaffold new C#/.NET business applications with clean architecture, optional Gateway/Functions/Scheduler/Blazor/React/Uno UI, and Azure-ready deployment patterns.

## Phase 5 Decision Table

Fast-lookup answer to "what do I do next?" - refer to this before scrolling for prose.

| Situation | Action |
|---|---|
| Build green after a sub-phase | Move to next sub-phase. Update `HANDOFF.md`, close session. |
| Build red, fixable in one focused pass | Fix, rebuild. If still red, stop and write `HANDOFF.md`. |
| Build red, second pass purely propagates the same fix (rename/namespace/file-move cascade) | One extra pass allowed. If new failure modes appear, stop and write `HANDOFF.md`. |
| Build red after fix attempt(s) with new errors | Write `HANDOFF.md` with the blocker. Do not loop. |
| Domain assumption looks wrong (entity shape, relationship) | Stop. Confirm with developer before continuing. See **Mid-Session Rollback Protocol** below. |
| External dependency cannot be stubbed locally | Mark as `deployment-only` in `.scaffold/resource-implementation.yaml`, generate a no-op stub anyway, log blocker in `HANDOFF.md`, continue. |
| Sub-phase has produced 15+ generated files or 3+ build cycles | Checkpoint `HANDOFF.md` mid-session. Do not wait for the gate. |
| Multiple files touched by a single structural error | Don't patch-fix. Roll back, log, re-scaffold the slice. |
| Missing required input (`ProjectName`, `packageStrategy` + `packagePrefix`, `customNugetFeeds` when feed/hybrid, at least one entity) | Ask developer before proceeding. |
| Missing optional input (mode/profile/flag default) | Apply canonical default from [resource-implementation-schema.md](resource-implementation-schema.md), state assumption inline, record in `HANDOFF.md`. |

Detail sections (Fail-Fast Protocol, Git Checkpoint Protocol, Missing-Inputs Protocol, Mid-Session Rollback Protocol, Mixed-Store Slice Gate) live in [../support/OPERATIONS.md](../support/OPERATIONS.md) - this table is the index.

## Load-Set Sizing

Load-set discipline is derived from `scaffoldMode` - there is no separate operator-mode knob:

| `scaffoldMode` | Load set | Per-sub-phase validation |
|---|---|---|
| `api-only` (also MVS / single-entity / prototypes) | Current sub-phase **required** files only; skip on-demand and adjacent references unless the current task clearly needs them. | `dotnet build` + scoped test (skip `dotnet restore` unless package files changed or phase boundary). |
| `lite` / `full` (production scaffolds) | Required + on-demand for the sub-phase. Adjacent references (proof map, prompt catalog) preload only when relevant. | Full Core Loop per [../support/execution-gates.md](../support/execution-gates.md). |

This sizing does **not** change phase semantics, gates, or conflict-resolution order - it only determines how many files to load per session.

## Non-Negotiables

> The 1-page constitutional summary lives at [../GROUND-RULES.md](../GROUND-RULES.md) with stable identifiers (`GR-01`...`GR-16`). The detail below is the implementation reference; the `GR-NN` tags after each bullet name the rule it enforces.

- **Authority map (GR-12):** `START-AI.md` owns session boot, phase routing, and load rules. `support/execution-gates.md` owns validation gates and commands. This file (`ai/SKILL.md`) owns Phase 5 load sets, non-negotiables, and concern routing. Individual skills own implementation detail; templates own generated file shape.
- **Phase-1 artifacts are the binding source of truth (GR-01).** `.scaffold/domain-specification.yaml`, `.scaffold/UBIQUITOUS-LANGUAGE.md`, and `.scaffold/DESIGN-DECISIONS.md` are not snapshots - every session must keep them current. *Fix the artifact first, then the code; when drift exists, the artifact loses to code reality.* Update them **before** generating code that introduces a new term/decision; update them **after** code when drift is discovered. Canonical lifecycle (forward propagation, drift signal, mid-scaffold rollback): [../START-AI.md](../START-AI.md) section Phase-1 Artifact Lifecycle Rule and [../README.md](../README.md) section Phase-1 Artifact Lifecycle.
- **Conflict resolution order:** For routing/loading/session-boundary conflicts, follow `START-AI.md`. For validation command/gate conflicts, follow `support/execution-gates.md`. For implementation conflicts, use this file (`ai/SKILL.md`) > individual skill files > templates.
- **Composition patterns** (cross-project wiring) live in `patterns/`. Load only when the current sub-phase needs cross-project orchestration:
  - [../patterns/data-layer-wiring.md](../patterns/data-layer-wiring.md) - DB context pooling, OnModelCreating order, startup tasks, seed data, scaffold migration strategy. Phase 5a, 5b.
  - [../patterns/api-host-wiring.md](../patterns/api-host-wiring.md) - API startup sequence, request context resolution, conditional auth. Phase 5b.
  - [../patterns/infrastructure-wiring.md](../patterns/infrastructure-wiring.md) - Multi-cache config, Aspire resource wiring. Phase 5b; Phase 5c only when an enabled optional host needs the shared runtime wiring.
  - [../patterns/expected-output-index.md](../patterns/expected-output-index.md) - Expected file layout when scaffolding is complete. On-demand verification.
  Prefer template-owned implementation detail over duplicating wiring; use pattern files for orchestration decisions across projects only.
- **Load [../support/ef-packages-reference.md](../support/ef-packages-reference.md) before Phase 5a** to know which base types (DbContextBase, DomainResult, IRequestContext, etc.) are part of the shared base-contract set. These types are sourced as `<packagePrefix>.<Layer>` packages from `customNugetFeeds` when `packageStrategy: feed`, or as project references against `src/Packages/<packagePrefix>.<Layer>` when `packageStrategy: local` (and the listed layers when `packageStrategy: hybrid`). Do not regenerate these types into application/domain/host layers regardless of mode - they live in the `<packagePrefix>.*` layer only.
- **Reference app - TaskFlow.** When a skill or template is ambiguous, consult it. Rules for when/how to consult, local sibling preference, and the do-not-copy-wholesale constraint live in [../support/reference-app.md](../support/reference-app.md). Use [../support/taskflow-proof-map.md](../support/taskflow-proof-map.md) for the phase -> area index.
- Generate code only in the user's new project directory **(GR-07)**.
- Use `.slnx` (not legacy `.sln`) **(GR-03)**.
- Use central package management (`Directory.Packages.props`) **(GR-03)**.
- **One public type per file (GR-02)** - universal rule across generated app code and `src/Packages/<Prefix>.*` vendored sources alike. File name matches the type. Lumped files (multiple DTOs, message types, nested helpers) are split at generation time, not deferred. See [../skills/solution-structure.md](../skills/solution-structure.md) section Non-Negotiables for the exception list.
- After adding packages, update to latest stable and verify restore/build **(GR-08)**.
- Record instruction gaps in `.scaffold/INSTRUCTION-GAPS.md` (do not hot-edit installed `.instructions/` files mid-scaffold) **(GR-07)**. Create the `.scaffold/` directory at project root if absent. Instruction maintainers can later copy approved findings into [../support/UPDATE-INSTRUCTIONS.md](../support/UPDATE-INSTRUCTIONS.md).
- Prefer latest stable .NET SDK and package releases **(GR-08)**. MCP server setup: see [../README.md](../README.md).
- All mode/profile/flag defaults come from [resource-implementation-schema.md](resource-implementation-schema.md) (**Canonical Defaults**).
- **Verified signatures only (GR-14):** before writing call sites against vendored/NuGet package types (`src/Packages/<Prefix>.*`, `EF.*` contracts), derive member names and argument order from the actual interface/source, the package XML docs, or a compiled reference call site (reference app, or the first green handler/service in this codebase). Never infer either from naming conventions. Quick signature lookup: [../support/ef-packages-reference.md](../support/ef-packages-reference.md).

## Phase 5 file table

Each Phase 5 sub-phase loads its own file set. The base context (`ai/SKILL.md`, `ai/placeholder-tokens.md`, `ai/tdd-protocol.md`, `support/ef-packages-reference.md`) is always loaded.

| Sub-phase | Required skills | Required templates | On-demand |
|---|---|---|---|
| **5a Foundation (TDD)** | `domain-model`, `data-persistence`, `testing` | `entity`, `ef-configuration`, `repository`, `domain-rules`, `appsettings`, `test-templates-domain`, `test-templates-repository`; **`updater-template` whenever any entity has child collections (1:N owned, M:N junction)** | `azure-data-storage` (shared shape) + `azure-blob-storage` / `azure-table-storage` / `azure-cosmos` (per non-SQL store used); `test-templates-integration` (balanced/comprehensive - fill the `{Entity}RepositoryIntegrationTests` shells generated in Phase 4); `patterns/data-layer-wiring` (cross-project wiring); `flowengine` (when `includeFlowEngine: true` - generate FE DbContext + migration here, before runtime wiring) |
| **5b App Core + Runtime/Edge (TDD for app/API, tests-after for runtime)** | `application-layer`, `bootstrapper`, `api`, `testing`, plus enabled runtime concerns: `gateway`, `multi-tenant`, `caching`, `aspire`, `configuration-secrets`, `observability`, `security` | `data-mapping`, `service`, `endpoint`, `message-handler`, `structure-validator`, `exception-handler`, `test-templates-service`, `test-templates-endpoint`, `test-templates-e2e` (multi-endpoint workflows), `health-check` | `test-templates-integration` (audit-repo + projection pipeline tests), `test-templates-aspire` (mesh API/Function audit pipelines; comprehensive); `patterns/api-host-wiring`, `patterns/infrastructure-wiring`; `resilience` (outbound HTTP policy defaults); `no-op-stub` (generating or replacing external-dependency stubs); `cqrs-handler`, `cqrs-endpoint`, `cqrs-validation`, `test-templates-cqrs` (when `applicationStyle: cqrs` or `applicationStyle: switch` - these replace the default `service`/`endpoint` shape); `flowengine` (when `includeFlowEngine: true` - emit `RegisterServices.FlowEngine.cs`, migration startup task, workflow-seeding, `MapFlowEngineAdmin(prefix: "/api/flowengine")`) |
| **5c Optional Hosts (tests-after)** | only the enabled host(s): `background-services`, `function-app`, `ui-uno` (index - load `ui-uno-shell`/`ui-uno-mvux`/`ui-uno-navigation`/`ui-uno-platforms` per task), `ui-blazor` (+ `ui-blazor-forms` on demand), `ui-react`, `notifications` | host-matching templates: `uno-mvux-model-template`, `uno-ui-client-layer`, `uno-xaml-page-template`, `test-templates-presentation`; `flowengine-trigger-template` (when `includeFlowEngine: true` and at least one trigger host enabled) | `uno-wasm-test-bridge-template` (Uno WASM Skia canvas renderer only); `ui-uno` is a dedicated-session set; React uses skill-owned file shape |
| **5d Quality + Delivery** | `testing-quality`, `iac`, `cicd` | `test-templates-quality` (architecture + Playwright + load + benchmarks + mutation), `dockerfile`, `tech-design-template` (generates `docs/tech-design.md` + `docs/tech-design.html`), `local-test-stack-template` (when `Test.Aspire`/`WasmUI`/`Test.Mobile` tiers exist); `flowengine-test-template` (when `includeFlowEngine: true` - five-tier guard tests per workflow JSON) | `testing` (only if revisiting unit/endpoint scaffolding); `test-templates-integration` / `test-templates-aspire` / `test-templates-e2e` (if these tiers were skipped in 5a/5b); `messaging`, `grpc`, `external-api` (if used) |
| **5e Integration (Auth + AI)** | `identity-management` (always); `ai-integration` (when `includeAiServices: true`) | `ai-search`, `agent` (when AI in scope) | scope AI further to search-only or agents-only as needed |

On-demand in any sub-phase: [../support/quick-reference.md](../support/quick-reference.md) - one-page lookup for project map, package roles, DI patterns, routes, and config keys.

Read the table once at the start of each Phase 5 sub-phase session, load the listed files, proceed.

## Phase 5 Sub-Phase Clarifications

Session bootstrap, phase routing, and the session-per-phase model are canonical in [../START-AI.md](../START-AI.md). Phase 4 must finish before any Phase 5 sub-phase starts (gate: `dotnet build` succeeds on the full solution). Phase 5a uses TDD; 5b is mixed (TDD for application/API, tests-after for runtime); 5c-5e use tests-after - see [tdd-protocol.md](tdd-protocol.md).

Before generating code in each Phase 5 sub-phase, ask the following clarification questions and record answers in `HANDOFF.md`. For values covered by canonical defaults, apply the default and state the assumption inline.

1. **5a - Foundation (TDD):**
   - **Ask clarification questions first:** domain rule specifics, invariant constraints, inheritance patterns, special validations, audit/versioning needs
   - Write domain/rule/repository tests first, then implement entities, EF configs, and repositories. Load `test-templates-domain.md` + `test-templates-repository.md`. Gate: see [../support/execution-gates.md](../support/execution-gates.md) section 5a.

2. **5b - App Core + Runtime/Edge (TDD for app/API, tests-after for runtime):**
   - **Ask clarification questions first:** service business logic, API pagination/filtering, response formats, error handling, idempotency. Plus runtime concerns: observability/tracing, health checks, rate limiting, caching, gateway routing.
   - Write service tests -> implement services. Write endpoint tests -> implement endpoints. Replace no-op DI stubs with real implementations. Then add enabled runtime concerns (gateway, caching, observability, security, multi-tenant) followed by their tests. Load `test-templates-service.md` + `test-templates-endpoint.md` + runtime skill files. Gate: see [../support/execution-gates.md](../support/execution-gates.md) section 5b (includes Aspire startup when enabled).

3. **5c - Optional Hosts (tests-after):**
   - **Ask clarification questions first:** for each enabled host, ask host-specific details (Function App triggers/bindings/outputs, Scheduler job types/schedules, Notification channels/templates, React UI design-system/API-base expectations, Uno UI target platforms/responsive needs)
   - Load only the host-specific files matching the enabled hosts in `.scaffold/resource-implementation.yaml`. Uno UI stays a dedicated session. Gate: see [../support/execution-gates.md](../support/execution-gates.md) section 5c (per-host status recorded in `HANDOFF.md`).

4. **5d - Quality + Delivery:**
   - **Ask clarification questions first:** code quality thresholds, load test requirements, benchmark baselines, mutation target scope, CI-CD pipeline specifics
   - Add architecture/load/benchmark/CI-CD gates and run full regression. Load `test-templates-quality.md`. Gate: see [../support/execution-gates.md](../support/execution-gates.md) section 5d.

5. **5e - Integration (Auth + AI):**
   - **Ask clarification questions first:** authentication provider, custom claims/roles, B2B vs B2C, token expiry. If AI in scope: AI search scope/filters, agent capabilities, content ingestion, cost/latency.
 - Finalize identity (replace earlier stubs with config-driven scaffold principal). When `includeAiServices: true`, scaffold AI search and/or agents - load only the templates matching the enabled capability - and scaffold the `AiProviderInfo` + `GET /ai/status` provider signal by default (the live-AI lane gate and an ops signal; owner [../skills/ai-integration.md](../skills/ai-integration.md)). Gate: see [../support/execution-gates.md](../support/execution-gates.md) section 5e. Live search/agent checks run only when endpoints are provisioned; Foundry Local live proof belongs in `Test.FoundryLocal`, not `Test.Aspire`.

## Template Usage

Use templates for generated artifacts and keep naming aligned with [placeholder-tokens.md](placeholder-tokens.md).

- Backend templates: entity/config/repository/dto/mapper/service/endpoint/rules/message-handler/structure-validator/exception-handler
- UI templates: MVUX model/XAML page/UI model/UI service; React UI uses [../skills/ui-react.md](../skills/ui-react.md) until dedicated React templates exist
- Tests: load only the phase-specific split test template for the current sub-phase; use `templates/test-templates.md` only as an on-demand reference. Uno MVUX presentation tests use `test-templates-presentation` in Phase 5c and generate into `Test.UI`, not `Test.Unit`.

## Vertical Slice Shortcut

For an existing solution, use:
- [../support/vertical-slice-checklist.md](../support/vertical-slice-checklist.md)
- Relevant `templates/`

Generate one complete slice, validate, then move to next slice.

## Key Principles

- Clean architecture boundaries
- Bootstrapper-based shared DI wiring
- Static mappers + EF-safe projectors
- `DomainResult`-style railway flow
- Tenant-safe defaults where enabled
- SQL defaults: `nvarchar(N)`, `decimal(10,4)`, `datetime2`
- Stub external dependencies for local compile/run **(GR-06)** - generate compilable no-op implementations with `// TODO: [CONFIGURE]` comments at every integration point (stub class, DI registration, appsettings section)
- **Every external dependency must declare one scaffold-time mode (GR-05)** before Phase 5 code is generated for it. Valid modes:
  - `emulator` - Aspire-hosted or local emulator available (SQL, Redis, Azure Storage Emulator, Service Bus emulator)
  - `lazy-optional` - config-driven; service activates only when config section is present/non-empty; absent = no-op passthrough
  - `no-op stub` - compile-time stub that satisfies the interface and returns safe defaults; no cloud call made
  - `deployment-only` - live integration deferred to deployment; **a no-op stub must still be generated** so the solution compiles and runs locally. Stub must satisfy the interface, return safe defaults, and carry a `// TODO: [CONFIGURE]` comment. Blocker logged in `HANDOFF.md`.
- **Schema ownership for third-party operational stores:** When a dependency (scheduler, queue dashboard, job runner, etc.) persists data through its own EF-backed or SQL-backed operational tables, determine **who owns schema creation** before writing startup code. Check for: (a) library-managed auto-create (e.g., `EnsureCreated` at startup), (b) library-provided migrations or SQL scripts you must run, (c) a design-time factory the library expects in your project, or (d) manual migration ownership where you must add `DbSet`/configurations for the library's tables. Record the answer in `resource-implementation.yaml` under `externalDependencyModes`. Do not assume a library will create its tables just because its startup code runs without error - missing schema often surfaces as seeding or runtime failures, not startup crashes.
- **Scaffold is complete when: solution builds, unit/endpoint tests pass, and the app boots end-to-end without any manual cloud setup (GR-11).** Manual cloud provisioning (Entra, Key Vault, Foundry, ACS) must use `lazy-optional` or `no-op stub` mode and cannot block scaffold completion.
- No commercial-licensed test packages. Use MSTest built-in assertions as the baseline. See [../skills/testing.md](../skills/testing.md) for approved assertion options.
- **Minimize third-party packages (GR-04).** Default to BCL + `Microsoft.Extensions.*` + the reference-app stack already in TaskFlow (Yarp, Scalar, ZiggyCreatures FusionCache, StackExchange.Redis, Moq, NetArchTest, NBomber, Testcontainers, BenchmarkDotNet, dotnet-stryker, MudBlazor, Refit, Azure.*, Aspire). When `includeReactUI: true`, the React allowlist is React, Vite, TypeScript, React Router, TanStack Query, Material UI, lucide-react, and Playwright. Treat those lists as the allowlist; any other package requires developer confirmation, with the bar being "**high value** the reference-app stack cannot deliver." Prefer a small in-house extension method - promoted to a shared `src/Packages/<packagePrefix>.<Layer>` project when reusable - over a new dependency. See [../skills/package-dependencies.md](../skills/package-dependencies.md) section Minimize Third-Party Dependencies.
- Keep Aspire config and IaC names aligned
- Start with minimal viable profiles, promote later
- **Ship a Development-only idempotent seeder early.** For scaffold, demo, or local-development modes, generate an idempotent seeder (safe to run on every boot - check-then-insert, no duplicates) that inserts the minimum user/profile/domain records the **primary actor's main flow** needs, so that `dotnet run` on the AppHost shows real data and a working flow on first boot. The seeder is part of the Phase 5 deliverable, not optional polish. Do not spend time hardening first-run UX around empty datasets - seed first, polish later. This is the data backing the end-to-end vertical-slice acceptance gate below (Definition of Done #4).

## Scaffold Definition of Done

> Indexed as **GR-11** in [../GROUND-RULES.md](../GROUND-RULES.md). The list below is the canonical detail; the ground-rule entry is the short-form citation.

A scaffolded solution is **not complete** until all of the following hold. Treat these as hard gates - if any fail, fix before declaring the scaffold finished, or record the deviation in `HANDOFF.md` with the specific dependency or sub-phase that's blocking.

1. **`dotnet build` is green on the full solution** (every project under `src/`, including all test projects). No warnings as errors that the scaffold introduces; warnings inherited from the package strategy are acceptable but flagged in `HANDOFF.md`.
2. **`dotnet test` is green for every test category the scaffold produces.** Specifically:
   - `Unit`, `UI`, `Presentation`, `Endpoint`, `Architecture`, `Mapper` - all pass.
   - `Integration`, `E2E`, `PlaywrightUI`, `Load`, `Benchmark`, `Mutation` - pass when their backing infrastructure/tooling is available; otherwise the affected test methods (not whole assemblies) must mark themselves `Assert.Inconclusive` with a reason, or carry `[Ignore("Reason: <external dep not yet wired>")]`. A test assembly that aborts in `[AssemblyInitialize]` because infrastructure failed to start is **not** acceptable - apply the assembly-initializer safety pattern from [../skills/testing.md](../skills/testing.md) section Assembly Initializer Safety.
   - No flaky-pass: a green run must be reproducible. If a test passes intermittently, treat it as failed.
3. **The Aspire AppHost starts cleanly.** `dotnet run --project Host/Aspire/AppHost` reaches the dashboard with every registered resource in the **Running** state and no exceptions in resource logs. Health probes (`/healthz`, `/readyz`) return 200 on every API/host project once each declares itself ready. External dependencies in `emulator`, `lazy-optional`, `no-op stub`, or `deployment-only` mode count as healthy when their stub/emulator path responds - live cloud credentials are not required.
4. **Every UI host starts cleanly - Aspire-registered AND standalone.**
   - **Aspire-registered UI hosts** (Blazor server, Blazor WASM host, React/Vite host, Uno host when added to AppHost): when the AppHost starts in (3), the UI resource reaches **Running**, the dashboard logs are exception-free, navigating to the root URL renders the layout (no white screen, no DI exception, no missing Refit/client crash), interactivity is live (Blazor: the interactive render mode is opted into, not static SSR; Uno: commands fire, chrome renders), and **the primary actor's main flow works end-to-end against the running stack with seeded data** - the primary list/detail surface shows the records the seeder inserted (not an empty list), and at least one primary-actor action (create/submit/the core verb) completes successfully. A green unit-test suite does **not** satisfy this gate. Empty datasets are acceptable only for secondary/admin surfaces, never for the primary flow.
   - **Standalone UI hosts** run cleanly with their canonical launch command:
     - Blazor: `dotnet run --project Host/{Project}.Blazor` reaches `Application started`, `/healthz` returns 200, the root URL renders without exception in console logs.
     - React/Vite: `npm ci`, `npm run lint`, `npm run build`, then `npm run dev -- --host 127.0.0.1`; the root URL renders and one API-backed page loads through the configured Gateway/API base.
     - Uno WASM: target `bin` and target `obj` are cleaned for validation, `dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride=<tfm>-browserwasm -p:EnableUnoWasm=true -m:1` passes, the ASP.NET Core WASM wrapper host serves without WASM load errors, the shell renders, and one `WasmUI` smoke runs when that tier is generated.
     - Uno Desktop / Mobile: the head project builds and launches via its platform target; the shell renders. Smoke check only - full platform-specific QA is out of scope for scaffold completion.
   - Backend connectivity from UI: the canonical Refit/Kiota/React API client resolves the configured Gateway/API URL via `appsettings`, Vite proxy config, or `VITE_API_BASE_URL`. If the API is up, a UI page that calls one read endpoint returns data (or a typed empty state) - not a console exception.
5. **All UI/API/Function host startup logs are quiet by Information-level.** Aspire dashboard logs should show no `Error`/`Critical` entries from project-owned categories during a healthy start. Acceptable: framework warnings (AspNetCore initialization, EF model validation messages already filtered in [../skills/testing.md](../skills/testing.md)). Unacceptable: stack traces from `Program.cs`, DI resolution failures, missing config exceptions, `NotImplementedException` from a no-op stub being unexpectedly resolved.
6. **External-dependency deferrals are recorded.** Any `[Ignore]` test, `Assert.Inconclusive` branch, or `deployment-only` external dep is named in `HANDOFF.md` with: (a) what it gates, (b) what step unblocks it (e.g., "wire Entra tenant ID"), (c) the test/assembly that flips green once unblocked. A scaffold may declare itself complete with deferrals present; it may not declare itself complete with un-explained deferrals.
7. **Phase-1 artifacts reflect the scaffolded code.** `.scaffold/domain-specification.yaml`, `.scaffold/UBIQUITOUS-LANGUAGE.md`, and `.scaffold/DESIGN-DECISIONS.md` cover every entity, term, role, event, action, and design decision introduced during scaffolding - no silent additions, no superseded entries left contradicting the code. Verify by spot-checking the entity list in the spec against generated `Domain.Model` entities, and the language file against public type/property names. Record the check in `HANDOFF.md` section Phase-1 Artifact Currency. Per [../START-AI.md](../START-AI.md) section Phase-1 Artifact Lifecycle Rule, on any divergence the artifact loses to code reality - update the artifact before declaring done.

The scaffold author runs gates 1-5 from the target project root and pastes the relevant tail of each output into `HANDOFF.md` section Scaffold Acceptance before closing the final Phase 5 session.

---

## References

- Session model, phase router, conflict order: [../START-AI.md](../START-AI.md)
- Validation gates and commands: [../support/execution-gates.md](../support/execution-gates.md)
- Operational protocols (fail-fast, git checkpoint, missing-inputs, rollback, mixed-store gate, context budgets): [../support/OPERATIONS.md](../support/OPERATIONS.md)
- HANDOFF template: [../support/HANDOFF.md](../support/HANDOFF.md)
- Copy-paste phase prompts (human convenience): [../support/prompt-catalog.md](../support/prompt-catalog.md)
