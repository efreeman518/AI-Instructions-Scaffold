# TaskFlow Proof Map

Use this file when you need to prove that an instruction, pattern, or scaffolded output already exists in the TaskFlow reference app.

**Local sibling clone preferred:** if `../AI-Instructions-ReferenceApp/` exists relative to the target project's parent, read TaskFlow files via the Read tool - paths in the proof table below are relative to the TaskFlow repo root, so prefix with `../AI-Instructions-ReferenceApp/`. Fall back to GitHub MCP only when the local clone is absent: <https://github.com/efreeman518/AI-Instructions-ReferenceApp>

Load this file on demand. Keep it out of the default phase context.

> **TaskFlow is a multi-tenant application.** It demonstrates tenant boundary validation, tenant query filters, tenant-scoped services, and global-admin bypass. When scaffolding a single-tenant app, the multi-tenant patterns shown in TaskFlow do not apply - see `// [MULTI-TENANT]` markers in the service template.

---

## How to Use It

1. Find the current phase or concern.
2. Jump to the matching TaskFlow area.
3. Verify structure, wiring, and naming there before inventing a new pattern.
4. Generate code for the target project. Reference-application consultation rules (when to consult, local clone vs MCP fallback, do-not-copy-wholesale) live in [reference-app.md](reference-app.md).

---

## Phase Proof Map

| Phase / Concern | TaskFlow area to inspect | What it proves |
|---|---|---|
| Phase 1 shared language | `.scaffold/UBIQUITOUS-LANGUAGE.md`, `.scaffold/DESIGN-DECISIONS.md`, `.scaffold/domain-specification.yaml`, `.scaffold/implementation-plan.md` | Shared terminology, rejected synonyms, decision dependencies, and vertical slice order are explicit before code generation. |
| Phase 4 contract scaffolding | `src/Domain/TaskFlow.Domain.Model`, `src/Application/TaskFlow.Application.Contracts`, `src/Application/TaskFlow.Application.Models`, `tests/Test.Support` | Entity shells, contracts, DTOs, builders, and test infrastructure exist before TDD starts. |
| Phase 5a domain model | `src/Domain/TaskFlow.Domain.Model` | `Create()` / `Update()` patterns, value objects, domain rules, and aggregate shape. |
| Phase 5a domain shared | `src/Domain/TaskFlow.Domain.Shared` | Shared enums, value-object base types, cross-aggregate primitives. |
| Phase 5a data persistence | `src/Infrastructure/TaskFlow.Infrastructure.Data`, `src/Infrastructure/TaskFlow.Infrastructure.Repositories` | Dual DbContext split, EF configuration, repository split, and save/query separation. |
| Phase 5b application layer | `src/Application/TaskFlow.Application.Services`, `src/Application/TaskFlow.Application.Mappers`, `src/Application/TaskFlow.Application.Cqrs/Features` | Service shape, result flow, mapper conventions, CQRS feature-folder handler shape, validator placement, `BuildResponse` helper, `ErrorConstants` usage, `nameof(Entity)`, `[LoggerMessage]` source-gen logging. TaskFlow shares models and mappers between service and CQRS as a demo compromise; stricter CQRS slices can consolidate feature-specific models and mappers under the feature. Multi-tenant: tenant boundary validation, tenant filter manipulation logging, `PreventTenantChange` in Update. |
| Phase 5b message handlers | `src/Application/TaskFlow.Application.MessageHandlers` | Domain-event and integration-event consumer pattern, separate from aggregate emission. |
| Phase 5b storage / external infrastructure | `src/Infrastructure/TaskFlow.Infrastructure.Storage` | Blob, Service Bus, and Cosmos repositories with no-op stubs for unconfigured states. |
| Phase 5b API endpoints | `src/Host/TaskFlow.Api` | Minimal API grouping, endpoint conventions, exception handling, and registration flow. |
| Phase 5b runtime wiring | `src/Host/TaskFlow.Api`, `src/Host/TaskFlow.Bootstrapper`, `src/Host/Aspire/AppHost` | Middleware order, DI composition, app host resources, runtime config, and deployment shape. |
| Phase 5b Aspire service defaults | `src/Host/Aspire/ServiceDefaults` | OpenTelemetry wiring, `/healthz` and `/readyz` defaults, shared host registration. |
| Phase 5b database migrator | `src/Host/TaskFlow.DatabaseMigrator`, `src/Infrastructure/TaskFlow.Infrastructure.Data/TaskFlowTickerQDbContext.cs`, `infra/modules/container-app-job.bicep`, `.github/workflows/deploy.yml` | Sole migration owner: ordered `AddEfCoreMigrationTarget` registrations, migrator-only timeouts, per-context history tables, app-owned third-party (TickerQ) migration context, AppHost `WaitForCompletion`, one-shot Container Apps Job gating runtime rollout. |
| Phase 5b gateway | `src/Host/TaskFlow.Gateway` | YARP routing, token forwarding, claims transformation, and CORS wiring. |
| Phase 5b caching | API + Bootstrapper + cache registrations | FusionCache + Redis backplane patterns and cache-key conventions. |
| Multitenancy | Request context handling in API + service layer | Tenant extraction, tenant boundary validation, global-admin bypass, tenant filter manipulation logging, `PreventTenantChange`, `ValidationHelper` delegation, `[LoggerMessage]` source-gen. |
| Phase 5c scheduler | `src/Host/TaskFlow.Scheduler` | TickerQ job registration, cron jobs, and scheduled handler structure. |
| Phase 5c functions | `src/Host/TaskFlow.Functions` | Function-project structure, trigger layout, and placeholder-host patterns. |
| Phase 5c Uno UI | `src/UI/TaskFlow.Uno` | UI project structure, feature grouping, and gateway-backed client flow. |
| Phase 5c Uno core | `src/UI/TaskFlow.Uno.Core` | Plain single-TFM class library extracted from the Uno project so business logic and Kiota client are unit-testable without the Uno SDK. |
| Phase 5c Blazor host | `src/UI/TaskFlow.Blazor` | Blazor alternative to Uno UI; same Gateway-backed client flow. |
| Phase 5c React UI | `src/UI/TaskFlow.React` | React + TypeScript Vite SPA alternative; same Gateway-backed client flow, Vite proxy/Aspire JavaScript host wiring, dark-mode persistence, and full workflow parity. |
| Phase 4 Test infrastructure | `tests/Test.Support/WebApplicationFactoryBase.cs`, `tests/Test.Support/Hosting/DockerRuntimePreflight.cs`, `tests/Test.Support/Aspire/AspireTestHostContext.cs`, `tests/Test.Endpoints/CustomApiFactory.cs`, `tests/Test.E2E/SqlApiFactory.cs`, `tests/Test.Integration/Infrastructure/SqlContainerFixture.cs` + `AzuriteContainerFixture.cs` + `IntegrationTestSetup.cs`, `tests/Test.Aspire/AspireTestHost.cs` + `AspireMeshLifecycle.cs` | Shared WAF base constrained to `DbContextBase<string, Guid?>`; thin derived factories per harness; generic bounded Docker capability check shared by component and Aspire-backed tiers; component store fixtures remain standalone; shared Aspire deadline/wait/diagnostics/cleanup policy is consumed by lazy mesh and browser/WASM adapters. |
| Phase 5a integration tier | `tests/Test.Integration/MigrationAndRepositoryTests.cs` | EF migrations apply against real SQL; CRUD + child includes + M:N junction navigation + tenant query filter + polymorphic-attachment index checks against the migrated schema. |
| Phase 5b component tier | `tests/Test.Integration/AuditLogRepositoryAzuriteTests.cs`, `tests/Test.Integration/DomainEventPipelineTests.cs` | Audit-repo against real Azurite via standalone `AzuriteContainerFixture` (partition/row key shapes); projection pipeline reads through query-side repos and emits view documents against a standalone SQL Testcontainer. |
| Phase 5b mesh tier | `tests/Test.Aspire/ApiAuditPipelineTests.cs`, `tests/Test.Aspire/FunctionAuditPipelineTests.cs` | Full HTTP request -> API/Function -> audit middleware -> Azurite read-back with polling helper, against the lazily-started Aspire AppHost graph (`AspireTestHost.EnsureStartedAsync`). |
| Phase 5b E2E tier | `tests/Test.E2E/SqlApiFactory.cs`, `tests/Test.E2E/TaskItemCrudE2ETests.cs` | Static Testcontainers SQL lifecycle on the derived `SqlApiFactory`; multi-endpoint workflows (CRUD round-trip, paged search across distinct pages, child-aggregate lifecycles) against real SQL. |
| Mapper parity (consolidated) | `tests/Test.Unit/Mappers/MapperProjectionParityTests.cs` | Single class pinning compile-projection / `ToDto` agreement for every mapper + inlined-child parity for aggregate roots + owned-type flattening parity. |
| Phase 5d quality (.NET test projects) | `tests/Test.Unit`, `tests/Test.Integration`, `tests/Test.Aspire`, `tests/Test.Endpoints`, `tests/Test.E2E`, `tests/Test.Architecture`, `tests/Test.Load`, `tests/Test.Benchmarks`, `tests/Test.Mutation`, `tests/Test.Support` | `dotnet test`-runnable test project layout, Stryker.NET mutation samples, and quality-gate coverage. |
| Phase 5d browser UI tests | `tests/Test.PlaywrightUI/PlaywrightAspireHost.cs`, `WasmAppHost.cs`, `TypeScriptPlaywrightSuiteTests.cs` | C# MSTest adapter self-hosts Aspire through the shared context, resolves named dynamic endpoints, runs a C# Gateway/Blazor smoke, and invokes one TypeScript Playwright project per child process for Blazor/React/Uno. One startup budget includes WASM restore/build and browser launch. |
| Phase 5d mobile UI tests | `tests/Test.Mobile`, `tests/Test.Mobile/run-mobile-tests.ps1`, `src/UI/TaskFlow.Uno/TaskFlow.Uno.csproj` | MSTest + Appium Android smoke tests are opt-in. The runner owns Android restore/build with `-p:BuildAllUnoTargets=true`, emulator readiness, Appium readiness, `TASKFLOW_MOBILE_TESTS_ENABLED=true`, `dotnet test`, and TRX output. Default `dotnet test` remains dependency-free inconclusive. Explicit runner lane fails fast on missing/broken APK, emulator, Appium, or UiAutomator2. |
| Phase 5e auth | `AuthConfiguration`, `ScaffoldAuthHandler`, gateway claims forwarding flow | Scaffold auth, Entra-ready wiring, and API claim enrichment path. |
| Phase 5e AI | `src/Infrastructure/TaskFlow.Infrastructure.AI`, `src/Host/TaskFlow.Bootstrapper/Registration/RegisterServices.AiChatClient.cs`, `tests/Test.Aspire/AiFoundryLiveSmokeTests.cs`, `tests/Test.FoundryLocal/FoundryLocalLiveSmokeTests.cs` | Azure Foundry -> Foundry Local -> no-op provider order, `/api/v1/ai/status`, split Azure HTTP mesh smoke vs RID-bound Foundry Local live lane, no-op fallback contract. |

### Uno MVUX Presentation (proven)

MVUX presentation records live in the testable `src/UI/TaskFlow.Uno.Presentation/Presentation` library, separate from the `Uno.Sdk` head. Inspect that library to verify the shape:

- Every MVUX record sits in the one `TaskFlow.Uno.Presentation` assembly (avoids duplicate generated `BindableXxx` wrapper types); Kiota/client code stays in `TaskFlow.Uno.Core`; `Uno.Sdk` is only on `TaskFlow.Uno`.
- Static `App.*` model calls are replaced by injected abstractions such as `IAppShellActions` and `IThemePreferenceService`.
- Presentation tests live in `tests/Test.UI/Presentation` (see [../templates/test-templates-presentation.md](../templates/test-templates-presentation.md)).

---

## Direct Proof Links

Use these links first. If a branch or path has moved, search inside the same repository for the path suffix or type name; do not invent a new pattern.

| Concern | Direct link |
|---|---|
| Ubiquitous language | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/blob/main/.scaffold/UBIQUITOUS-LANGUAGE.md> |
| Design decisions | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/blob/main/.scaffold/DESIGN-DECISIONS.md> |
| Domain model | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Domain/TaskFlow.Domain.Model> |
| Domain shared | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Domain/TaskFlow.Domain.Shared> |
| Application contracts | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Application/TaskFlow.Application.Contracts> |
| Application models | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Application/TaskFlow.Application.Models> |
| Application services | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Application/TaskFlow.Application.Services> |
| Application mappers | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Application/TaskFlow.Application.Mappers> |
| Application CQRS features | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Application/TaskFlow.Application.Cqrs/Features> |
| Application message handlers | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Application/TaskFlow.Application.MessageHandlers> |
| Data infrastructure | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Infrastructure/TaskFlow.Infrastructure.Data> |
| Database migrator host | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Host/TaskFlow.DatabaseMigrator> |
| Repositories | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Infrastructure/TaskFlow.Infrastructure.Repositories> |
| Storage / external infrastructure | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Infrastructure/TaskFlow.Infrastructure.Storage> |
| AI infrastructure | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Infrastructure/TaskFlow.Infrastructure.AI> |
| API host | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Host/TaskFlow.Api> |
| Bootstrapper | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Host/TaskFlow.Bootstrapper> |
| Aspire AppHost | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Host/Aspire/AppHost> |
| Aspire service defaults | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Host/Aspire/ServiceDefaults> |
| Gateway | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Host/TaskFlow.Gateway> |
| Scheduler | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Host/TaskFlow.Scheduler> |
| Functions | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/Host/TaskFlow.Functions> |
| Uno UI | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/UI/TaskFlow.Uno> |
| Uno core (testable) | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/UI/TaskFlow.Uno.Core> |
| Blazor host | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/UI/TaskFlow.Blazor> |
| React UI | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/UI/TaskFlow.React> |
| Test support | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/tests/Test.Support> |
| Unit tests | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/tests/Test.Unit> |
| Architecture tests | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/tests/Test.Architecture> |
| Endpoint tests | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/tests/Test.Endpoints> |
| E2E tests | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/tests/Test.E2E> |
| Playwright UI tests (TaskFlow uses Node; scaffold may use Node or C# MSTest) | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/tests/Test.PlaywrightUI> |
| Mobile UI tests (MSTest + Appium) | <https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/tests/Test.Mobile> |

---

## High-Value Proof Checks

- **Current reference proof snapshot:** the last verified runs predate the folder reorganization. Re-run `tests\Test.Mobile\run-mobile-tests.ps1 -SkipBuild`, `dotnet test tests\Test.Mobile\Test.Mobile.csproj --no-build -m:1 --filter TestCategory=MobileUI`, and `dotnet test TaskFlow.slnx --no-build -m:1` before treating those results as current. Authoritative build/test counts live only in the reference app's `.scaffold/REFERENCE-STATUS.md` (<https://github.com/efreeman518/AI-Instructions-ReferenceApp/blob/main/.scaffold/REFERENCE-STATUS.md>) - not restated here.

- **Multi-tenant proof:** TaskFlow demonstrates full multi-tenancy - `ITenantEntity<TenantId>` (typed domain ID), `ITenantBoundaryValidator`, `ValidationHelper`, `TenantBoundaryLoggingExtensions`, tenant query filters, tenant stamping, and global-admin bypass. Not all scaffolds require multi-tenancy.
- **Service pattern proof:** TaskFlow services use `BuildResponse` helper, `ErrorConstants.ERROR_ITEM_NOTFOUND`, `nameof(Entity)`, `[LoggerMessage]` source-gen logging, and `DefaultRequest<T>`/`DefaultResponse<T>` as `record` types.
- **Dual DbContext proof:** TaskFlow uses `TaskFlowDbContextTrxn` for writes and `TaskFlowDbContextQuery` for read-only/no-tracking access.
- **Repository proof:** TaskFlow splits repository contracts and implementations into transaction and query variants.
- **Middleware proof:** The API pipeline is ordered as security headers -> correlation ID -> exception handling -> rate limiting -> auth -> gateway claim enrichment -> authorization -> endpoints.
- **Gateway proof:** The gateway forwards bearer tokens and original claims through an encoded header.
- **Scheduler proof:** TickerQ jobs are registered as explicit scheduled handlers, not hidden inside random hosted services.
- **Scaffold-auth proof:** Local/dev completion does not require live cloud auth; scaffold auth supplies trusted claims until Phase 5e finalizes identity.

---

## When To Load This File

- A skill or template describes a pattern but the concrete shape is still ambiguous.
- You need to verify that the instruction set already has a working example.
- You want a fast pointer into TaskFlow without searching the whole repo.

## Application Style Proof

TaskFlow now proves both application styles:

- Service endpoints: existing `I{Entity}Service` route mapping.
- CQRS endpoints: equivalent routes mapped directly to command/query handlers.
- Shared contracts: Domain, Infrastructure, UI clients, DTOs, and route contracts remain stable.
- Route versioning: public domain API routes are `/api/v1/*`; operational/admin/health surfaces stay unversioned (`/health/*`, `/alive`, `/healthz`, `/api/flowengine/*`, Functions host health `/api/health`).
- Guardrails: avoid central request dispatchers, request buses, and generic `Send()` entrypoints; no CQRS-specific repository layer.
- Reason: endpoint -> request -> handler wiring stays explicit and can be checked by tests/code review.
