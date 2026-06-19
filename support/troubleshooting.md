# Troubleshooting - AI Agent Triage Rules

This file is intentionally lightweight. Use it to decide **what the AI should do next** when a build/test/run problem appears.

> **For compile/run commands and engineer actions, use [execution-gates.md](execution-gates.md) as the execution checklist.**

---

## Core Rule

AI agents generate code. Engineers own environment and runtime setup.

> All code generation and fixes apply to the **new project** only. If an error points to a `patterns/` file (see `ai/SKILL.md` section Non-Negotiables for the index), document the issue in `.scaffold/INSTRUCTION-GAPS.md` (in a consumer app) or `support/UPDATE-INSTRUCTIONS.md` (in this repo).

When an error appears:
1. Classify it (code-generation vs infrastructure/tooling)
2. Attempt **one** code-fix pass only when it is code-generation **in the new project**
3. If still failing (or infrastructure-related), log in `HANDOFF.md` and continue with non-blocked work

---

## Narrow Before Broad

After each material change, validate at the **smallest meaningful scope first**. Only escalate to broader builds, full-system runs, or browser sessions when the narrower check passes or cannot answer the question.

Validation ladder (prefer higher rows):

| Scope | When to use |
|---|---|
| Single file / `dotnet build` one project | After editing one project's code |
| `dotnet build` solution | After cross-project changes |
| `dotnet test --filter "TestCategory=Unit"` | After logic changes |
| `dotnet test` (full suite) | After wiring / DI / integration changes |
| Host startup / Aspire run | After config, startup, or infrastructure changes |
| Browser / E2E | Only after host-level checks pass |

Do not run a full-stack validation when a targeted build or endpoint check would isolate the issue faster.

---

## AI Fixes (One Pass Max)

The AI may fix:
- Missing `using`, `ProjectReference`, or package entries
- Missing DI registration, `DbSet<>`, endpoint map, or token substitution
- Namespace/path mismatches caused by scaffolding

Then run the phase validation command and continue only if green.

---

## Engineer-Owned Issues (Do Not Diagnose Deeply)

Flag immediately for the engineer when issues involve:
- NuGet auth/feeds, Docker/container startup, SQL connectivity
- Aspire env vars/ports, Functions runtime tools/config, Playwright install
- Certificates/credentials, cloud subscription access, deployment permissions

Reference the exact relevant section in [execution-gates.md](execution-gates.md).

---

## Distributed Host Debugging: Orchestration vs Application

When a multi-host app (Aspire, Gateway, API, Scheduler) fails at runtime, **separate orchestration failures from application failures** before investigating code.

**Step 1 - Confirm the substrate is running:**
- Docker containers started? (`docker ps`)
- Aspire dashboard reachable? (check the URL from `dotnet run` output - do not reuse a prior session's URL)
- All registered resources show healthy in the dashboard?
- Gateway/proxy routes respond (even with 401/404)?

**Step 2 - Only then investigate application-level concerns:**
- API returns expected status codes?
- Auth tokens/claims correct?
- Seed/migration data present?
- Config values (connection strings, feature flags) populated?

If Step 1 fails, the problem is infrastructure - flag for the engineer per [execution-gates.md](execution-gates.md). Do not debug application code when the host substrate is not ready.

---

## Docker / Container Runtime (Aspire + Testcontainers)

The Aspire mesh tier (`Test.Aspire`) and the Testcontainers tiers (`Test.Integration`, `Test.E2E`) need a working container runtime. Diagnose it by **capability, not product**.

**Detect by capability, not by Docker Desktop.** Any runtime exposing a working Docker CLI + socket is valid - Docker Desktop, WSL Docker Engine, Rancher Desktop, or a Podman-compatible Docker socket. Confirm capability, not which product is installed:

```powershell
docker version              # client and server both report
docker info                 # daemon reachable
docker run --rm hello-world # pull + run actually works
```

If those three succeed, the runtime is usable - do not special-case the product.

**Resource pressure is the first suspect for flapping health.** Aspire mesh containers (SQL Server, Service Bus emulator, Azurite) are memory-hungry. Recommended floor: **4 CPU, 8 GB RAM, 4 GB swap**. When SQL or Service Bus health checks flap, time out, or pass only intermittently, suspect container resource pressure **before** changing test logic, timeouts, or assertions - an under-provisioned runtime looks exactly like a flaky test.

**WSL-only Docker:** check `~/.wslconfig` and raise the floor:

```ini
[wsl2]
memory=8GB
processors=4
swap=4GB
```

After editing `.wslconfig`, the change is not live until the WSL VM and the Docker engine restart:

```powershell
wsl --shutdown
# then restart Docker Desktop / the Docker service / the daemon
```

**Order of remediation - never reboot or edit Docker Desktop settings first.** Confirm capability (`docker info`), then resources (`.wslconfig` / engine limits), then the WSL/engine restart above - in that order. Never edit Docker Desktop settings unless the user explicitly asks, and never require a machine reboot as the first fix.

---

## Standalone Dev (Without Aspire / Docker)

Aspire AppHost injects connection strings at runtime via environment variables. When running individual host projects directly (`dotnet run` or VS F5 without AppHost), those env vars are absent and the app fails with SQL connectivity errors.

For each host that needs a database, add real values to `appsettings.Development.json`:

```json
{
  "ConnectionStrings": {
    "{App}DbContextTrxn": "Server=(localdb)\\MSSQLLocalDB;Database={App};Trusted_Connection=True;TrustServerCertificate=True;MultipleActiveResultSets=true",
    "{App}DbContextQuery": "Server=(localdb)\\MSSQLLocalDB;Database={App};Trusted_Connection=True;TrustServerCertificate=True;MultipleActiveResultSets=true"
  }
}
```

For Functions, use `local.settings.json` `ConnectionStrings` section (same values).

LocalDB (`MSSQLLocalDB` instance) ships with Visual Studio. Start it with `sqllocaldb start MSSQLLocalDB` if it is not running. EF migrations run automatically on first API startup.

> **Security:** `appsettings.Development.json` with LocalDB strings is safe to commit. Never commit cloud/staging connection strings - use user secrets or environment variables instead.

**Step 3 - After fixing an infrastructure startup issue, verify at the data plane:**
Process liveness and clean logs are necessary but not sufficient. When a fix targets a component that creates or seeds backing data (migrations, seed tasks, scheduler tables, queue metadata), perform one direct data-plane check before declaring the fix complete:
- **Database:** query for expected tables, seed rows, or schema objects
- **Queue/bus:** confirm the queue or topic exists and is reachable
- **Storage:** verify the container or blob artifact was created

This prevents false-positive fixes where the crash is resolved but the intended persistence or seeding outcome was never achieved.

---

## Third-Party Operational Store Schema Triage

When a third-party library (scheduler, queue, dashboard, job runner) uses EF-backed or SQL-backed operational tables and startup or seeding fails:

1. **Identify the schema owner.** Does the library auto-create its tables at startup? Does it ship migrations or SQL scripts you must run? Does it expect a design-time factory in your project? Or does it assume tables already exist?
2. **Do not conflate startup success with schema presence.** Many libraries start without error even when their backing tables are missing - failures appear later during seeding, first job execution, or dashboard queries, and are easily misread as connection or configuration issues.
3. **Verify the schema directly.** Query `INFORMATION_SCHEMA.TABLES` or the database tool of your choice to confirm the expected tables exist before investigating application-level failures.

---

## WASM Static Web Assets Manifest Crash

**Symptom:** Uno WASM app crashes on startup with `DirectoryNotFoundException` or `FileNotFoundException` referencing a deleted folder (e.g., `playwright-screenshots/`, `test-results/`).

**Root cause:** The static web assets manifest (`staticwebassets.build.json` in `obj/`) caches references to all directories present at build time. If a directory is deleted after a build but before a clean rebuild, the manifest still references it, and `WasmAppHost` crashes trying to serve assets from the missing path.

**Fix:**
1. Clean `bin/` and `obj/` folders: `Remove-Item -Recurse -Force bin, obj`
2. Rebuild: `dotnet build`
3. If the deleted folder was test output or tooling artifacts, add it to `.gitignore` to prevent recurrence.

**Prevention:** Never create transient output directories (test results, screenshots, build artifacts) inside the Uno app project. Configure tools to write outputs into their own project directories (e.g., Playwright `outputDir` pointing to `src/Test/Test.PlaywrightUI/test-results`). Use an absolute, CWD-independent path so the location is deterministic regardless of where the tool is invoked: `$(MSBuildThisFileDirectory)` for MSBuild-driven output, or walk up to the `*.slnx`/`*.sln` marker for standalone runners. When building a path from a discovered source root, include the correct tree segment (`src/Test/...`) so artifacts land under the test tree, not a sibling folder at the repo root. Keep any environment-variable override as the first choice; only fix the fallback path.

## WASM Runtime/Class Library Mismatch

**Symptom:** Browser console reports `Your mono runtime and class libraries are out of sync` and names `System.Private.CoreLib.dll`.

**Likely root cause:** Mixed browserwasm output. The target `bin/<configuration>/<tfm>-browserwasm` was rebuilt, but target `obj/<configuration>/<tfm>-browserwasm` still contains stale WebCIL/runtime intermediates.

**Fix:**
1. Delete both target directories:
   ```powershell
   Remove-Item -Recurse -Force src/UI/{Project}.Uno/bin/Debug/{tfm}-browserwasm
   Remove-Item -Recurse -Force src/UI/{Project}.Uno/obj/Debug/{tfm}-browserwasm
   ```
2. Restore/build the Uno project:
   ```powershell
   dotnet restore src/UI/{Project}.Uno/{Project}.Uno.csproj -p:BuildAllUnoTargets=true -p:EnableUnoWasm=true
   dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride={tfm}-browserwasm -p:EnableUnoWasm=true --no-restore -m:1
   ```

Do not switch renderers, change launch ports, or rewrite app startup before ruling this out.

---

## Aspire Multi-Consumer Database Wiring

**Symptom:** A project that should connect to an Aspire-managed database fails with connection errors, while other consumers of the same database work fine.

**Root cause:** Each Aspire resource consumer needs its own `.WithReference()` call. When two projects need the same database but use different connection string names (e.g., API uses `{App}DbContextTrxn` and Functions uses `{App}DbContextQuery`), each must specify its connection name explicitly:

```csharp
var taskflowDb = builder.AddSqlServer("sql")
    .WithImageTag("2025-latest")
    .AddDatabase("taskflow-db");

var api = builder.AddProject<Projects.TaskFlow_Api>("api")
    .WithReference(taskflowDb);  // uses default connection name

var functions = builder.AddProject<Projects.TaskFlow_Functions>("functions")
    .WithReference(taskflowDb, connectionName: "TaskFlowDbContextQuery");  // explicit name
```

Without the explicit `connectionName`, the Functions project falls back to `appsettings.json` (which may reference LocalDB or a non-existent server).
4. **Avoid CREATE-on-every-restart patterns.** When using `GenerateCreateScript()` + batch execution to bootstrap third-party schemas, gate it behind an existence check (see [data-persistence-advanced.md](data-persistence-advanced.md) -> Third-Party Operational Store Schemas). Running CREATE statements against existing tables produces `fail:` EF log spam on every restart with persistent data volumes.
5. **Record the schema ownership model** in `HANDOFF.md` and `.scaffold/resource-implementation.yaml` so future sessions do not re-diagnose the same issue.

---

## Upstream Issue Diagnosis Discipline

When consulting upstream GitHub issues, PRs, or release notes to diagnose a third-party library failure:

1. **Extract the specific failure class** the upstream material addresses before applying its fix. Design-time migration problems, host-lifecycle startup problems, schema-default problems, and runtime missing-table problems are **separate fault domains** - treat them as distinct until proven otherwise.
2. **Match, don't pattern-match.** An upstream issue is relevant only if its failure mode matches your local failure mode, not just the library or feature area. A migration-generation fix does not resolve a runtime missing-table error, even if both involve the same library.
3. **Use upstream material to refine the diagnosis, not to short-circuit it.** If an upstream issue narrows the problem to a specific version, config flag, or code path, use that to focus your investigation - do not copy the fix verbatim without verifying the preconditions match.

---

## Domain Ambiguity Defaults

When inputs are unclear, prefer pragmatic defaults and continue:
- Relationship unclear -> default to one-to-many and note assumption
- Missing properties -> add `Name`; add `TenantId` when tenant-scoped
- Lite mode + Gateway requested -> keep Lite baseline; suggest Gateway as a later increment

---

## Common Test Failures

Single source of truth for recurring scaffolding test failures and known fixes.
For phase gates and validation commands, see [execution-gates.md](execution-gates.md).

### Quick Reference

| Symptom | Root Cause | Fix |
|---|---|---|
| Search returns empty/0 results | `SearchRequest.PageSize` defaults to 0 | Send a nonzero `PageSize` (e.g. 100) and a `PageIndex` valid for the base the repo expects - see the `PageIndex pitfall` note in [repository-template.md](../templates/repository-template.md) |
| Search returns 500 / negative OFFSET | `PageIndex = 0` reaches `ComposeIQueryable` (which does `pageIndex - 1`) without a guard | Guard in the repo with `Math.Max(1, request.PageIndex)`; see the `PageIndex pitfall` note in [repository-template.md](../templates/repository-template.md) |
| Tenant-scoped queries return empty | `IRequestContext.TenantId` is null in test host | Override request context with fixed `TestTenantId` |
| All writes return `NotImplementedException` | Wrong `SaveChangesAsync` overload used | Use `SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins, ct)` |
| Delete test passes but entity still exists | `Delete(entity)` not called | Call `repoTrxn.Delete(entity)` before save |
| FK violation in assign/reference tests | FK uses random GUID not existing row | Create related records first |
| Rate-limited 429 in integration tests | API rate limiter enabled in test host | Override limiter to `GetNoLimiter` in test factory |
| `CS0104` RequestContext ambiguity | `Test.Support` and `EF.Common.Contracts` both define type | Use fully qualified `EF.Common.Contracts.RequestContext<...>` |
| Audit save succeeds but handler side effect never happens | `AuditInterceptor` publishes to `IInternalMessageBus`, but the host is missing channel-queue support, the handler is not in DI, or handler assemblies were never registered into the bus | Register `AddChannelBackgroundTaskQueueWithShutdownHandling()` + `IInternalMessageBus` before DbContexts, add each `IMessageHandler<T>` to DI, then call `app.AutoRegisterMessageHandlers()` after `Build()`. See [bootstrapper.md](../skills/bootstrapper.md) and [message-handler-template.md](../templates/message-handler-template.md). |
| `IInternalMessageBus` resolution error in test factory | `AuditInterceptor` registered by Bootstrapper, not removed by test DB swap | Remove `AuditInterceptor<string, Guid?>` and all pool/factory descriptors. See [test-templates-endpoint.md](../templates/test-templates-endpoint.md) -> *Shared WebApplicationFactoryBase*. |
| `Cannot consume scoped from singleton IDbContextPool` in tests | `AddDbContext` registers scoped options; original pooled factory registration still present | Remove `IDbContextPool<T>` descriptors (match by `ServiceType.FullName.Contains("DbContextPool")`) before re-registering |
| `DbContextOptions must be DbContextOptions<T>` in tests | Multiple contexts sharing non-generic `DbContextOptions` constructor | Build typed options per context via `new DbContextOptionsBuilder<T>().UseInMemoryDatabase(name).Options` |
| `CS9035` required member `AuditId` not set | `DbContextBase` declares `required` members; `new` operator enforces at compile time | Use `ConstructorInfo.Invoke()` via reflection to bypass - see `TestDbContextFactory` in [test-templates-endpoint.md](../templates/test-templates-endpoint.md) |
| Create returns 201 but validation test expects 400 | DTO fields not applied to entity after create | Call `entity.Update(...)` after factory create |
| Create/Update NullReferenceException in tests | `UpdateFromDto` not mocked | Mock `repoTrxn.UpdateFromDto(...)` to return `DomainResult<T>.Success(entity)` |
| `CS1929` ReturnsAsync type mismatch on search mock | Query repo interface returns `PagedResponse<EntityDto>` but test uses `PagedResponse<Entity>` | Change mock to use DTO type - repos project to DTOs via `QueryPageProjectionAsync` |
| Manual Skip/Take/Count in query repo | Not using `QueryPageProjectionAsync` from RepositoryBase | Replace with `QueryPageProjectionAsync` + mapper projector + `BuildFilter`/`BuildOrderBy` methods |
| Schema changes not reflected in TestContainer | Previous schema persists | `EnsureDeletedAsync()` before `EnsureCreatedAsync()` |
| Aspire mesh failure buried in unreadable TRX | Resource logging floods test output | It is off by default. Read state from `ResourceNotifications` (`DumpResourceState`); re-enable raw logs only for this run with the diagnostic override `{APP}_ASPIRE_RESOURCE_LOGGING=true`. See [test-templates-aspire.md](../templates/test-templates-aspire.md) -> *Resource logging off by default*. |
| ProblemDetails stack traces leak in CI | Debug diagnostics enabled in all builds | Wrap diagnostic customization in `#if DEBUG` |
| StructureValidator not found | Missing static validator namespace import | Add `using {Namespace}.Application.Services.Validation;` |
| WASM build `DirectoryNotFoundException` (`unoresizetizer`) | Resizetizer manifest-path issue | See fix snippet in `skills/ui-uno-platforms.md` -> *UnoSplashScreen WASM Build Failure* |
| WASM browser reports mono runtime/class libraries out of sync | Target `obj/<config>/<tfm>-browserwasm` contains stale WebCIL/runtime intermediates after only `bin` was rebuilt | Delete both target `bin` and target `obj`; restore/build with `TargetFrameworkOverride=<tfm>-browserwasm` and `-m:1` |
| WasmUI tests look dead in Test Explorer | Harness requires `{APP}_WASM_TESTS_ENABLED=true` instead of default-on false-only opt-out | Treat only `{APP}_WASM_TESTS_ENABLED=false` as opt-out; missing Docker is `Assert.Inconclusive`, Docker present starts Aspire |
| WasmUI startup hangs with no useful failure | Long steps lack per-step timeouts/progress logs and browser diagnostics | Add bounded startup steps plus console/page error/request/HTML/script/canvas/body/bridge-state diagnostics |
| WasmUI passes locally but fails under VS coverage/profiler | Test runner profiler env vars leak into child `dotnet restore` / `dotnet build` | Clear `CORECLR_*`, `COR_*`, and Coverlet profiler vars for child processes; set profiling disabled flags |
| `NotSupportedException` deserializing `Result<T>` in tests | `Result<T>` lacks parameterless constructor | Use `JsonDocument` parsing instead of `ReadFromJsonAsync<Result<T>>()`. Search endpoints serialize just the `PagedResponse<T>` value, not the wrapper. |
| Aspire dashboard never opens / blank terminal | Missing `Properties/launchSettings.json` in AppHost | Create launchSettings.json with OTLP endpoints - see [aspire.md](../skills/aspire.md) -> Preflight |
| `MSB4057` "GetTargetPath" target missing | Uno.Sdk project referenced directly from AppHost | Remove the direct Uno ProjectReference/AddProject and register the ASP.NET Core `{Project}.Uno.WasmHost` wrapper instead |
| Functions storage/messaging clients refuse `127.0.0.1:10000/10001/10002` | `local.settings.json` fallbacks (`UseDevelopmentStorage=true`, empty Service Bus strings) beat Aspire-injected env values; Azurite under Aspire uses dynamic ports | Give Functions its own `.WithReference(...)` / host storage wiring and resolve shared client connection strings env-first before `local.settings.json` fallbacks. See [function-app.md](../skills/function-app.md) -> Aspire Integration and [aspire.md](../skills/aspire.md) -> Azure Service Bus Topics and Subscriptions. |
| Audit rows show wrong user id / correlation id looks like the audit id | `RequestContext` constructor arguments were passed in the wrong order | Use `new RequestContext<string, Guid?>(correlationId, auditId, tenantId, roles)`. See [api-host-wiring.md](../patterns/api-host-wiring.md) -> Request Context Resolution. |
| Event contracts drift between layers (Domain vs Application) | Bus payload records defined in `Domain.*.Events` and/or publisher still named `IDomainEventPublisher` | Move cross-process payloads to `Application.Contracts.Events` and publish through `IIntegrationEventPublisher`. Keep domain events in Domain only for aggregate-local invariants/dispatch. |
| EF `fail:` log spam on every scheduler/host restart | `GenerateCreateScript()` runs CREATE against existing tables | Gate with `INFORMATION_SCHEMA.TABLES` existence check - see [data-persistence-advanced.md](data-persistence-advanced.md) -> Third-Party Operational Store Schemas |
| `MSB3027` file lock / build fails with PID holding DLL | Orphaned `dotnet.exe` from prior run | `Get-Process -Name dotnet` then `Stop-Process -Name dotnet -Force` |
| SQL container starts but auth fails under Aspire | `sql-password` parameter not in user secrets | `dotnet user-secrets set "Parameters:sql-password" "<pw>" --project AppHost` |
| UI pager shows wrong "current page" / Next returns same rows | A hand-rolled client `PagedResponse.PageIndex` setter adds/removes an offset against the server-echoed value | Reuse `EF.Common.Contracts` `PagedResponse<T>` instead of redefining it; pass `pageIndex` through unchanged. Verify the API's base empirically. See [ui-uno-mvux.md](../skills/ui-uno-mvux.md) -> *Pagination contract* |
| Checklist/child state (e.g. `IsCompleted`) lost on new-parent save | UI does separate `ParentService.Create` then per-child `ChildService.Create` loop; server's `Child.Create(...)` factory doesn't accept the field | Bundle children into parent DTO for a single-payload save; Updater `createFunc` calls `Update()` after `Create()` for fields not in the factory signature. See [updater-template.md](../templates/updater-template.md) -> *createFunc must apply ALL DTO fields* and [ui-uno-mvux.md](../skills/ui-uno-mvux.md) -> *Buffered Child Items in Create Mode* |
| Menu click stays on stacked sub-page (detail) / no-ops | Navigating against the wrong navigator: a rooted `/Main/{sibling}` walks up to Shell's `FrameNavigator` (already on Main) and no-ops, while a relative route on the parent can report success without flipping sibling `Visibility` | Target the **inner** Visibility-region navigator (`RootGrid.Navigator()`) with a **relative** route, then run `ForceSiblingVisibility` and pop each FrameView's inner Frame. Never use a rooted `/Main/X` for sibling switching. See [ui-uno-navigation.md](../skills/ui-uno-navigation.md) -> *Menu Navigation: Always Land On Top Page* |
| `Assert.IsGreaterThanOrEqualTo` reports "Actual value <1> is not greater than or equal to expected value <2>" | Args inverted - signature is `(lowerBound, value)` (asserts `value >= lowerBound`) | Reorder: `Assert.IsGreaterThanOrEqualTo(lowerBound: 1, value: summary.OverdueTasks)` |
| Mock-data assertion break when seed rows are added (`Expected:<3> Actual:<14>`) | Tests hardcode absolute counts/positions against a moving mock seed | Prefer `IsNotEmpty`, `Assert.Contains`, or assertions on a specific entity Id; reserve exact counts for sealed fixtures |
| Aspire test suite hangs indefinitely | `[assembly: DoNotParallelize]` + no `[Timeout]` on a single hanging test blocks entire run | Add `[Timeout(300000)]` (5 min) to every Aspire integration test method; `[Timeout(120000)]` for Testcontainers-SQL-only tests |
| Aspire mesh tests take 5-10 min or hang on startup | `TASKFLOW_ASPIRE_TESTING` env var not set before `DistributedApplicationTestingBuilder.CreateAsync` - full environment (CosmosDB emulator etc.) starts | Set the env var inside `Test.Aspire`'s `AspireTestHost.EnsureStartedAsync` (via the `EnvironmentVariableScope` it opens) **before** `CreateAsync`; provide `AppHost/appsettings.Testing.json` with required parameters |
| Multiple Aspire environments started per test run (slow: ~60-90 s per class) | `DistributedApplication` started per class instead of shared | Start once via the shared lazy `AspireTestHost.EnsureStartedAsync` (called from each mesh class's `[ClassInitialize]`, guarded by a `SemaphoreSlim`); expose `static DistributedApplication? AspireApp` - mesh classes reference it directly |
| Functions in Aspire integration tests connect to LocalDB instead of test SQL container | `local.settings.json` connection strings override Aspire-injected env vars | Remove DB connection strings from `local.settings.json`; leave only Azurite strings (e.g., `UseDevelopmentStorage=true`) |
| `CS1061` on `CreateHttpClient` / `GetConnectionStringAsync` after removing local `DistributedApplication` field | Extension methods live in `Aspire.Hosting.Testing`; removing the field caused the `using` to be deleted | Keep `using Aspire.Hosting.Testing;` in every file that calls those extension methods |
| Functions Aspire resource missing / test hangs on `func.exe` not found | `func.exe` (Azure Functions Core Tools) not on PATH; resource added unconditionally | Detect availability with `EnsureFuncToolAvailable()` in `DatabaseFixture`; set `TASKFLOW_INCLUDE_FUNCTIONS=true` only when found; tests that need Functions call `Assert.Inconclusive` when resource absent |
| Cosmos Data Explorer at `http://localhost:1234` spins forever | Emulator itself not healthy - the Data Explorer is served from the Cosmos container | Inspect Cosmos resource health and container logs first; do not assume the explorer is broken until the gateway/emulator is healthy. See [../skills/aspire.md](../skills/aspire.md) -> *Cosmos Preview Emulator + Data Explorer* |
| Storage Explorer / RedisInsight / SQL tool fails to connect after Aspire restart | Host ports not pinned - Aspire reassigned dynamic ports on the new run | Pin host ports in AppHost for non-test runs; gate explorer wiring on `if (!isTesting)`. See [../skills/aspire.md](../skills/aspire.md) -> *Local Explorer Tooling* |
| Parallel test runs / CI fail with "port already in use" on SQL/Redis/Azurite | Explorer port pins leaked into test graph | Wrap pinned ports and explorer containers in `if (!isTesting)`. Tests must use Aspire-injected connection strings, not pinned ports |
| SQL / Service Bus health checks flap or time out intermittently under Aspire | Container resource pressure (under-provisioned runtime), not test logic | Raise the runtime floor (4 CPU / 8 GB / 4 GB swap); for WSL set `~/.wslconfig` then `wsl --shutdown` + restart Docker. See *Docker / Container Runtime*. Do not loosen timeouts/assertions first |
| Testcontainers / Aspire tests fail only on a non-Docker-Desktop runtime | Fixture or test probes for Docker Desktop specifically | Use a generic capability check (`docker info` / Testcontainers connect), not a product-specific probe. WSL Docker Engine, Rancher Desktop, Podman socket are all valid |

### Detailed Fix Patterns

#### 1) Tenant Query Filter in Tests

```csharp
services.AddScoped<IRequestContext<string, Guid?>>(provider =>
    new EF.Common.Contracts.RequestContext<string, Guid?>(
        Guid.NewGuid().ToString(), "Test.Endpoints", TestTenantId, []));
```

#### 2) SearchRequest Defaults

Always send explicit paging:

```csharp
new SearchRequest<MyFilter>
{
    PageSize = 100,
    PageIndex = 1,
    Filter = new MyFilter()
}
```

#### 3) Rate Limiter Override in Test Host

```csharp
services.AddRateLimiter(options =>
{
    options.GlobalLimiter = PartitionedRateLimiter.Create<HttpContext, string>(
        _ => RateLimitPartition.GetNoLimiter("test"));
});
```

#### 4) SaveChangesAsync Overload

```csharp
await repoTrxn.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins, ct);
```

#### 5) ProblemDetails Debug Leak Guard

```csharp
builder.Services.AddProblemDetails(options =>
{
#if DEBUG
    options.CustomizeProblemDetails = ctx =>
    {
        // debug-only exception detail
    };
#endif
});
```

---

## Razor vs C# Namespace Scoping

`global using` in a `.cs` GlobalUsings.cs file applies only to C# source files - it does NOT affect Razor component C# code blocks.
For every namespace used inside a `.razor` file, add an explicit `@using Namespace.Here` in the nearest `_Imports.razor`.
Rule of thumb: if a type is used both in `.cs` service layer code AND in `.razor` pages, it needs entries in BOTH `GlobalUsings.cs` AND `_Imports.razor`.

---

## Inspecting private NuGet package API surfaces

When a private package's public API is unknown or differs from docs/conventions:

1. Locate the DLL: find it under `%USERPROFILE%\.nuget\packages\{package}\{version}\lib\`.
2. Create a throwaway console project targeting the latest stable .NET TFM:
   ```
   dotnet new console -o C:\Temp\InspectLib
   ```
3. Add a `<Reference>` to the DLL in the `.csproj`.
   Preload any dependency assemblies (e.g., `Microsoft.Extensions.Logging.Abstractions`) with `Assembly.LoadFrom()` before calling `GetParameters()`.
4. Use `Assembly.LoadFrom(path)`, wrap `GetTypes()` in a `ReflectionTypeLoadException` catch, then iterate types/members.
5. `dotnet run` and inspect the output.

> **Note:** `Assembly.ReflectionOnlyLoadFrom()` is not supported on modern .NET - use full load + exception handling instead.
> Binary text extraction (grep for strings in the DLL bytes) is useful as a quick fallback to spot type names before writing reflection code.

---

## Session State

When blocked, log in `HANDOFF.md` (see [template](HANDOFF.md)):
- Symptom + classification (`code-generation` or `infrastructure`)
- Current phase
- Next engineer action (link to [execution-gates.md](execution-gates.md))

If instruction gaps are discovered:
- In an installed consumer app, append to `.scaffold/INSTRUCTION-GAPS.md`. Do not modify `.instructions/` files.
- In this instruction repository, append to `support/UPDATE-INSTRUCTIONS.md`.

