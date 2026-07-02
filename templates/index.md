# Template Index

Quick lookup: "I need to scaffold X" -> load these files.

## Phase 1 Discovery Artifacts

| Artifact | Template / Instruction |
|---|---|
| Shared understanding interview | `ai/shared-understanding-interview.md` |
| Domain vocabulary | `ubiquitous-language-template.md` |
| Decision dependency log | `design-decisions-template.md` |

## Backend Vertical Slice (Entity End-to-End)

| Artifact | Template | Required Skill |
|---|---|---|
| Entity class | `entity-template.md` | `skills/domain-model.md` |
| EF configuration | `ef-configuration-template.md` | `skills/data-persistence.md` |
| Repository (read/write) | `repository-template.md` | `skills/data-persistence.md` |
| Domain rules | `domain-rules-template.md` | `skills/domain-model.md` |
| DTOs + Mappers | `data-mapping-template.md` | `skills/application-layer.md` |
| Service + interface | `service-template.md` | `skills/application-layer.md` |
| Endpoint | `endpoint-template.md` | `skills/api.md` |
| Structure validator | `structure-validator-template.md` | `skills/application-layer.md` |
| Exception handler | `exception-handler-template.md` | `skills/api.md` |
| Message handler | `message-handler-template.md` | `skills/application-layer.md` |
| Updater | `updater-template.md` | `skills/data-persistence.md` |
| appsettings | `appsettings-template.md` | `skills/configuration-secrets.md` |
| CQRS handler + registration (`applicationStyle: cqrs` or `switch`) | `cqrs-handler-template.md` | `skills/application-layer.md` |
| CQRS endpoint (direct handler mapping) | `cqrs-endpoint-template.md` | `skills/api.md` |
| CQRS command validator | `cqrs-validation-template.md` | `skills/application-layer.md` |

## Tests (Split by Phase)

| Artifact | Template | Phase | Required Skill |
|---|---|---|---|
| Domain entity + rule tests | `test-templates-domain.md` | 5a | `skills/testing.md` |
| Repository tests (in-memory unit) | `test-templates-repository.md` | 5a | `skills/testing.md` |
| Integration (component): one class vs one store (standalone Testcontainers) | `test-templates-integration.md` | 5a / 5b | `skills/testing.md` |
| Aspire (mesh): full AppHost graph over HTTP (lazy-started) | `test-templates-aspire.md` | 5b | `skills/testing.md` |
| Service + mapper tests | `test-templates-service.md` | 5b | `skills/testing.md` |
| Endpoint contract tests + WAF base | `test-templates-endpoint.md` | 5b (base in 4) | `skills/testing.md` |
| Multi-endpoint workflow E2E (Testcontainers SQL) | `test-templates-e2e.md` | 5b | `skills/testing.md` |
| MVUX presentation model tests | `test-templates-presentation.md` | 5c | `skills/testing.md` + `skills/ui-uno-mvux.md` |
| Architecture / Load / Benchmarks / Playwright / Mutation | `test-templates-quality.md` | 5d | `skills/testing-quality.md` |
| CQRS handler + validation + architecture tests (`applicationStyle: cqrs` or `switch`) | `test-templates-cqrs.md` | 5b | `skills/testing.md` |
| Complete reference (all tests) | `test-templates.md` | on-demand | `skills/testing.md` |

Testing skills (two files only):

- `skills/testing.md` - Phase 5a/5b/5c TDD, harness tiers, integration hosts, template map.
- `skills/testing-quality.md` - Phase 5d quality gates, mutation testing, and hosted Playwright UI.

## Contracts + TDD

| Artifact | Instruction File | Phase |
|---|---|---|
| Contract scaffolding (interfaces, DTOs, shells) | `ai/contract-scaffolding.md` | 4 |
| No-op DI stubs (all modes) | `no-op-stub-template.md` | 4 / 5b |
| TDD red/green protocol | `ai/tdd-protocol.md` | 5a/5b |

## UI (choose one)

Scaffold Uno Platform (multi-target WASM + mobile + desktop), Blazor (Server or WebAssembly), or React/Vite SPA. All call the Gateway; siblings can ship side-by-side under `src/UI/` when explicitly enabled. See each skill for selection guidance.

### Uno Platform

> **Design Standard:** Each main entity gets two pages - `{Entity}ListPage` (list/search) and `{Entity}Page` (unified add/edit + children). No separate detail or create pages. See templates for the pattern.

> `skills/ui-uno.md` is the index; the depth lives in four sub-skills loaded per task: `skills/ui-uno-shell.md` (app shell, host setup), `skills/ui-uno-mvux.md` (MVUX models/feeds), `skills/ui-uno-navigation.md` (routing, dirty-guard), `skills/ui-uno-platforms.md` (WASM/mobile build + Playwright). The Phase 5c load set is in [../ai/SKILL.md](../ai/SKILL.md) section Phase 5 file table.

| Artifact | Template | Required Skill |
|---|---|---|
| Models + Services | `uno-ui-client-layer.md` | `skills/ui-uno.md` (+ `ui-uno-mvux`) |
| MVUX model (List + Page) | `uno-mvux-model-template.md` | `skills/ui-uno.md` (+ `ui-uno-mvux`) |
| MVUX model unit tests | `test-templates-presentation.md` | `skills/testing.md` + `skills/ui-uno-mvux.md` |
| XAML page (List + Entity) | `uno-xaml-page-template.md` | `skills/ui-uno.md` (+ `ui-uno-shell`/`ui-uno-navigation`) |
| WASM canvas test bridge (Skia renderer only) | `uno-wasm-test-bridge-template.md` | `skills/ui-uno-platforms.md` + `skills/testing-quality.md` |

### Blazor

> **Design Standard:** MudBlazor shell + pages in `Components/Pages/`. Scoped `FloatService` for cross-page state and progress (no cascading parameters). Refit client interface for gateway calls. See `skills/ui-blazor.md` for the full pattern.

| Artifact | Instruction File |
|---|---|
| Spine (Program.cs, FloatService, Refit interface, dev tenant header, MainLayout, auth, checklist) | `skills/ui-blazor.md` |
| Forms & interactions (init-only edit forms, unsaved-changes prompt, aggregate children, uploads, server paging, confirm-dialog fallback) - on demand | `skills/ui-blazor-forms.md` |

### React/Vite

> **Design Standard:** Vite + React + TypeScript SPA under `src/UI/{Project}.React`, React Router, TanStack Query, a typed API client, and Gateway-backed `/api` calls. See `skills/ui-react.md` for the full pattern.

| Artifact | Instruction File |
|---|---|
| Complete pattern (Vite config, API client, routes, pages, Playwright rules) | `skills/ui-react.md` |

## AI Integration

| Artifact | Template | Required Skill |
|---|---|---|
| Search service | `ai-search-template.md` | `skills/ai-integration.md` |
| Agent service | `agent-template.md` | `skills/ai-integration.md` |

## Workflow Orchestration (FlowEngine)

Generated when `includeFlowEngine: true` in `.scaffold/resource-implementation.yaml`. The DbContext + registration recipe lives in the skill; the templates own trigger sites and test scaffolding.

| Artifact | Template | Required Skill |
|---|---|---|
| Workflow trigger (Service Bus / inline / TickerQ) | `flowengine-trigger-template.md` | `skills/flowengine.md` |
| Workflow JSON guard tests (five-tier) | `flowengine-test-template.md` | `skills/flowengine.md` |

## Infrastructure

| Artifact | Template | Required Skill |
|---|---|---|
| Health checks | `health-check-template.md` | `skills/observability.md` |
| Dockerfile | `dockerfile-template.md` | `skills/solution-structure.md` + `skills/aspire.md` |

## Local Test Orchestration

| Artifact | Template | Required Skill |
|---|---|---|
| `eng/test/start-local-test-stack.ps1` + `.vscode/tasks.json` | `local-test-stack-template.md` | `skills/testing.md` + `skills/testing-quality.md` |

Generate when any of `Test.Aspire`, the `WasmUI` bridge tier, or `Test.Mobile` is in scope. Brings up the Aspire/WASM local stack in a re-runnable process-env-only script; generated mobile work uses `src/Test/Test.Mobile/run-mobile-tests.ps1` for Android build, emulator/Appium readiness, enable flag, `dotnet test`, and TRX output.

## Documentation

| Artifact | Template | Required Reference |
|---|---|---|
| Technical design doc (`docs/tech-design.md` + `docs/tech-design.html` viewer) | `tech-design-template.md` | `support/tech-design-diagrams.md` (source-plus-SVG pattern + viewer controls) |

## Phase-to-Template Mapping

| Phase | Templates to Load |
|---|---|
| **4 - Contracts** | Solution structure + contracts (see `ai/contract-scaffolding.md`) - also emits `Test.Support/WebApplicationFactoryBase`, `Test.Endpoints/CustomApiFactory`, `Test.E2E/SqlApiFactory`, `Test.Integration/Infrastructure/*ContainerFixture` + `IntegrationTestSetup` (component), `Test.Aspire/AspireTestHost` + `AspireMeshLifecycle` (mesh) shells, and `Test.FoundryLocal` when AI/Foundry Local is in scope - profile-gated tiers (`Test.E2E`, `Test.Aspire`) only when generated per the `skills/testing.md` Capability-Gated table |
| **5a - Foundation (TDD)** | `entity-template`, `ef-configuration-template`, `repository-template`, `domain-rules-template`, `appsettings-template`, **`updater-template` (required when entity has child collections)**, **`test-templates-domain`**, **`test-templates-repository`**, **`test-templates-integration`** (balanced+) |
| **5b - App Core + Runtime (TDD for app/API, tests-after for runtime)** | `data-mapping-template`, `service-template`, `endpoint-template`, `structure-validator-template`, `exception-handler-template`, `message-handler-template` (if events), `health-check-template`, **`test-templates-service`**, **`test-templates-endpoint`**, **`test-templates-e2e`** (balanced+), `test-templates-integration` (audit-repo + projection pipeline tests), `test-templates-aspire` (mesh API/Function audit pipelines, comprehensive); `cqrs-handler-template`, `cqrs-endpoint-template`, `cqrs-validation-template`, `test-templates-cqrs` (when `applicationStyle: cqrs` or `switch`) |
| **5c - Optional Hosts** | `uno-ui-client-layer`, `uno-mvux-model-template`, `uno-xaml-page-template`, `test-templates-presentation` (Uno); `skills/ui-react.md` (React); host-specific templates per enabled host; **`flowengine-trigger-template`** (when `includeFlowEngine: true` and Functions or Scheduler enabled) |
| **5d - Quality + Delivery** | **`test-templates-quality`** (architecture + Playwright + Load + Benchmarks + Mutation; Integration / E2E tiers are scaffolded earlier - 5d runs them as regression), `dockerfile-template`, **`flowengine-test-template`** (when `includeFlowEngine: true`), **`tech-design-template`** (generates `docs/tech-design.md` + `docs/tech-design.html`; see [../support/tech-design-diagrams.md](../support/tech-design-diagrams.md) for the render gate), **`local-test-stack-template`** (when `Test.Aspire`/`WasmUI`/`Test.Mobile` tiers exist) |
| **5e - Integration (Auth + AI)** | `ai-search-template`, `agent-template` (when AI in scope) |

> **Note:** Use the Phase Router in `START-AI.md` and the Phase 5 file table in `ai/SKILL.md` for authoritative per-phase file lists. This index is a human/AI quick-reference for "I need to scaffold X -> load template Y".
