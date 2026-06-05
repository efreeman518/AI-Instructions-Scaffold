# Contract Scaffolding - Phase 4

## Purpose

Generate the full solution structure, contract surface (interfaces, DTOs, entity shells), test infrastructure, and no-op DI stubs so that `dotnet build` succeeds on the entire solution - including test projects - before any real implementation begins in Phase 5.

This phase produces the compilable skeleton that enables TDD red/green cycles in Phase 5a and 5b.

## Inputs

- `.scaffold/domain-specification.yaml` (from Phase 1)
- `.scaffold/UBIQUITOUS-LANGUAGE.md` (from Phase 1)
- `.scaffold/DESIGN-DECISIONS.md` (from Phase 1)
- `.scaffold/resource-implementation.yaml` (from Phase 2)
- `.scaffold/implementation-plan.md` (from Phase 3)

## Pre-Gate

Before generating projects, verify shared base-type readiness for the configured `packageStrategy` (set in `.scaffold/resource-implementation.yaml`):

```powershell
dotnet restore
```

- If `packageStrategy: feed` or `hybrid` - fix `nuget.config` (and confirm `NUGET_AUTH_TOKEN` is set) before generating code. Do not scaffold local replacements for layers the feed provides.
- If `packageStrategy: local` or `hybrid` - confirm `packagePrefix` is set and every layer in `localPackageLayers` matches an entry in [`../support/ef-packages-reference.md`](../support/ef-packages-reference.md). These will be generated under `src/Packages/<packagePrefix>.<Layer>` as packable projects.

## Loaded Skills

- [solution-structure.md](../skills/solution-structure.md) - canonical folder layout, `.slnx`, dependency direction (and optional `src/Packages/`)
- [package-dependencies.md](../skills/package-dependencies.md) - shared base-type contracts and feed/local rules
- [placeholder-tokens.md](placeholder-tokens.md) - token substitution glossary
- [../support/ef-packages-reference.md](../support/ef-packages-reference.md) - base-type contract surface (do not regenerate into application/domain/host layers)

---

## What to Generate

### 1. Solution Structure

Follow `solution-structure.md` exactly:
- `.slnx`, `Directory.Packages.props`, `global.json`, `nuget.config`
- All project folders and `.csproj` files per the canonical layout
- Project references wired per the dependency direction contract
- Test projects: `Test.Support`, `Test.Unit`, `Test.Integration` (component), `Test.Aspire` (mesh), `Test.Endpoints`, `Test.E2E`, plus profile-specific projects (`Test.Architecture`, `Test.PlaywrightUI`, `Test.Load`, `Test.Benchmarks`, `Test.Mutation`) per `testingProfile`

### 2. Contracts (Per Entity)

For each entity defined in `.scaffold/resource-implementation.yaml`:

**Interfaces:**
```csharp
// Application.Contracts/Services/I{Entity}Service.cs
public interface I{Entity}Service
{
    Task<Result<DefaultResponse<{Entity}Dto>>> CreateAsync(DefaultRequest<{Entity}Dto> request, CancellationToken ct = default);
    Task<Result<DefaultResponse<{Entity}Dto>>> UpdateAsync(DefaultRequest<{Entity}Dto> request, CancellationToken ct = default);
    Task<Result> DeleteAsync(Guid id, CancellationToken ct = default);
    Task<Result<DefaultResponse<{Entity}Dto>>> GetAsync(Guid id, CancellationToken ct = default);
    Task<Result<PagedResponse<{Entity}Dto>>> SearchAsync(SearchRequest<{Entity}SearchFilter> request, CancellationToken ct = default);
}
```

```csharp
// Application.Contracts/Repositories/I{Entity}RepositoryTrxn.cs
// Application.Contracts/Repositories/I{Entity}RepositoryQuery.cs
```

Derive interface signatures from the entity's properties, relationships, and operations in `.scaffold/resource-implementation.yaml`. Use shared base types from `<packagePrefix>.*` (`IRepositoryBase`, `SearchRequest<T>`, `PagedResponse<T>`, etc.) - sourced from `customNugetFeeds` packages or `src/Packages/<packagePrefix>.*` projects per `packageStrategy`.

**DTOs:**
```csharp
// Application.Models/{Entity}Dto.cs
public class {Entity}Dto : IEntityBaseDto
{
    public Guid? Id { get; set; }
    // properties from resource-implementation.yaml
}

// Application.Models/{Entity}SearchFilter.cs
public class {Entity}SearchFilter
{
    public string? SearchTerm { get; set; }
    // filter-specific properties
}
```

**Enums:**
```csharp
// Domain.Shared/Enums/{Entity}Flags.cs (if defined)
```

### Integration Events

When externally published. Externally published event records belong in `Application.Contracts.Events`, not `Domain`. Generate one record per event the entity will publish across process boundaries:

```csharp
// Application.Contracts.Events/{Entity}CreatedIntegrationEvent.cs
public record {Entity}CreatedIntegrationEvent(Guid Id, Guid TenantId, /* fields safe to publish */);
```

Domain-only events (raised inside aggregates, handled in-process before integration mapping) stay in `Domain`. Do not publish `Domain` namespace events directly over transport - see [../skills/messaging.md](../skills/messaging.md) section Event Boundary Rule.

### 3. Entity Shells

Generate entity classes with the correct shape but no domain logic:

```csharp
// Domain.Model/{Entity}/{Entity}.cs
public class {Entity} : EntityBase, ITenantEntity<Guid>
{
    // Properties (from resource-implementation.yaml)
    public Guid TenantId { get; init; }
    public string Name { get; private set; } = null!;
    // ... all properties

    // SHELL: Phase 5a will implement domain logic
    private {Entity}() { }

    public static DomainResult<{Entity}> Create(Guid tenantId, string name)
        => throw new NotImplementedException("Shell - implement in Phase 5a");

    public DomainResult<{Entity}> Update(string? name = null)
        => throw new NotImplementedException("Shell - implement in Phase 5a");
}
```

**Shell rules:**
- Include all properties with correct types and access modifiers
- Include private parameterless constructor (EF requirement)
- Factory `Create()` and mutation `Update()` methods throw `NotImplementedException`
- Add comment `// SHELL: Phase 5a will implement domain logic` at top of class
- Child entity shells follow the same pattern
- Do NOT implement domain rules, validation, or business logic

### 4. Test Infrastructure

**Test.Support:**
- `UnitTestBase.cs` - shared `MockRepository` (see `test-templates.md` Common Setup as on-demand reference)
- `InMemoryDbBuilder.cs` - fluent in-memory/SQLite DB builder
- `DbSupport.cs` - test DB wiring for integration tests
- `Utility.cs` - config builder + random string helper
- `TestConstants.cs` - `DefaultTenantId`, `SystemUserId`
- `JsonTestOptions.cs` - shared `JsonSerializerOptions` mirroring the API host's `ConfigureHttpJsonOptions` (case-insensitive + `JsonStringEnumConverter`). Required so endpoint / E2E tests deserialize string enums consistently. See [test-templates-endpoint.md](../templates/test-templates-endpoint.md) section Shared JSON Options.
- `LocalSqlSettings.cs` - exposes a single `SharedSaPassword` constant used by the Aspire test host fixture to drive `Parameters:sql-password` (matches the AppHost parameter name). Keep this in `Test.Support` so both `Test.E2E` and `Test.Integration` consume the same value.
- `WebApplicationFactoryBase.cs` - abstract `WebApplicationFactory<TProgram>` that removes pooled-EF + interceptor + scoped-factory plumbing and re-registers test-mode contexts. Constrained to `DbContextBase<string, Guid?>` (the EF.Packages canonical audit/tenant shape). Both `Test.Endpoints/CustomApiFactory` and `Test.E2E/SqlApiFactory` derive from it - see [test-templates-endpoint.md](../templates/test-templates-endpoint.md) section Shared WebApplicationFactoryBase for the full file shape.

**Test Data Builders (per entity):**
```csharp
// Test.Support/Builders/{Entity}Builder.cs
public class {Entity}Builder
{
    private Guid _tenantId = TestConstants.DefaultTenantId;
    private string _name = "Test {Entity}";

    public {Entity}Builder WithTenantId(Guid tenantId) { _tenantId = tenantId; return this; }
    public {Entity}Builder WithName(string name) { _name = name; return this; }

    // SHELL: Returns null! until Phase 5a activates entity.Create()
    public {Entity} Build() => null!;
}
```

```csharp
// Test.Support/Builders/{Entity}DtoBuilder.cs - fully functional
public class {Entity}DtoBuilder
{
    private Guid _id = Guid.NewGuid();
    private string _name = "Test {Entity}";

    public {Entity}DtoBuilder WithId(Guid id) { _id = id; return this; }
    public {Entity}DtoBuilder WithName(string name) { _name = name; return this; }

    public {Entity}Dto Build() => new() { Id = _id, Name = _name };
}
```

**WebApplicationFactory plumbing (generated in Phase 4, consumed by `Test.Endpoints` and `Test.E2E`):**

The shared base is the **single source of truth** for swapping the production DbContext + interceptors + pooled factories with a test-mode store. Both `Test.Endpoints` (in-memory) and `Test.E2E` (Testcontainers SQL) derive thin specializations. Phase 4 generates all three files so the solution builds end-to-end before Phase 5 begins.

- `Test/Test.Support/WebApplicationFactoryBase.cs` - generic base class + `TestDbContextFactory<T>` + `WebApplicationFactoryHelpers` (reflection-based context creation that bypasses `required` member enforcement, descriptor removal helpers). Full file shape: [test-templates-endpoint.md](../templates/test-templates-endpoint.md) section Shared WebApplicationFactoryBase.
- `Test/Test.Endpoints/CustomApiFactory.cs` - derived factory using `UseInMemoryDatabase`. ~10 lines - overrides only `BuildTrxnOptions` / `BuildQueryOptions`.
- `Test/Test.E2E/SqlApiFactory.cs` - derived factory using `UseSqlServer(..., sql => sql.UseCompatibilityLevel(170))` against a Testcontainers SQL container, with static `StartContainerAsync` / `StopContainerAsync` lifecycle helpers. Full file shape: [test-templates-e2e.md](../templates/test-templates-e2e.md) section SqlApiFactory.
- `Test/Test.Integration/Infrastructure/SqlContainerFixture.cs` + `AzuriteContainerFixture.cs` (+ `RedisContainerFixture.cs` when Redis is used) - standalone per-store Testcontainers fixtures for the **component** tier; `SqlContainerFixture` builds `{App}DbContextTrxn` / `{App}DbContextQuery` against its own container. No Aspire. Full file shapes: [test-templates-integration.md](../templates/test-templates-integration.md).
- `Test/Test.Integration/Infrastructure/IntegrationTestSetup.cs` - `[AssemblyInitialize]` starts the store fixtures in parallel (each capturing `StartupError`); `[AssemblyCleanup]` disposes them.
- `Test/Test.Aspire/AspireTestHost.cs` - lazy assembly-scoped fixture that starts the full Aspire AppHost graph (API + Functions + SQL + Azurite) via `EnsureStartedAsync`, plus `Test/Test.Aspire/AspireMeshLifecycle.cs` (`[AssemblyCleanup]`). Full file shapes: [test-templates-aspire.md](../templates/test-templates-aspire.md).
- `EndpointTestBase` (optional) - HTTP client helper used by endpoint test classes.

**Empty test project shells:**
- `Test.Unit/` - project file with MSTest + Moq references, no test classes yet (Phase 5a adds them)
- `Test.Integration/` (component) - project file with MSTest + `Testcontainers.MsSql` + `Testcontainers.Azurite` + `Azure.Data.Tables` + `EF.IntegrationTesting`; references `Test.Support` and the Application/Infrastructure projects the tests use - **no `AppHost`, no `Aspire.Hosting.Testing`**. Contains the `Infrastructure/*ContainerFixture` + `IntegrationTestSetup` shells from above. Phase 5a populates `{Entity}RepositoryIntegrationTests`; Phase 5b populates `DomainEventPipelineTests`, `AuditLogRepositoryAzuriteTests`. See [test-templates-integration.md](../templates/test-templates-integration.md).
- `Test.Aspire/` (mesh) - project file with MSTest + `Aspire.Hosting.Testing` + `Aspire.Hosting.Azure.Storage` + `Azure.Data.Tables` + `EF.IntegrationTesting`; references `AppHost`, the API host, `Test.Support`, and the Application contracts/models the HTTP payloads need. Contains the `AspireTestHost` + `AspireMeshLifecycle` shells. Phase 5b populates `ApiAuditPipelineTests`, `FunctionAuditPipelineTests`. See [test-templates-aspire.md](../templates/test-templates-aspire.md).
- `Test.Endpoints/` - project file with MSTest + `Microsoft.AspNetCore.Mvc.Testing`, derived `CustomApiFactory`, no test classes yet (Phase 5b adds endpoint contract tests via WAF)
- `Test.E2E/` - project file with MSTest + `Microsoft.AspNetCore.Mvc.Testing` + Testcontainers, derived `SqlApiFactory`, no test classes yet (Phase 5b adds multi-endpoint workflow tests against Testcontainers SQL - see [test-templates-e2e.md](../templates/test-templates-e2e.md))
- `Test.Mutation/` - comprehensive profile project file with MSTest, references to focused target projects, and `stryker-config.json`; no test classes yet (Phase 5d adds focused mutation samples via Stryker.NET - see [test-templates-quality.md](../templates/test-templates-quality.md))

### 5. No-Op DI Stubs

For every interface, generate a no-op implementation:

```csharp
// Infrastructure/{Project}.Infrastructure.Stubs/NoOp{Entity}Service.cs
public class NoOp{Entity}Service : I{Entity}Service
{
    public Task<Result<DefaultResponse<{Entity}Dto>>> CreateAsync(DefaultRequest<{Entity}Dto> request, CancellationToken ct = default)
        => Task.FromResult(Result<DefaultResponse<{Entity}Dto>>.Success(new DefaultResponse<{Entity}Dto>()));

    // ... all interface methods with safe default returns
}
```

**No-Op method bodies must return safe defaults - never `throw new NotImplementedException()`.** This holds even for entities the scaffold contracts but does not activate (`TryAddSingleton`/`TryAddScoped` fallback wiring). Throwing inside a No-Op breaks the final-scaffold checklist and converts a silently inactive entity into a runtime crash if anything ever does resolve it. Use these safe-default shapes:

- `Result<T>` -> `Result<T>.Success(default!)` or a constructed empty payload
- `Task` -> `Task.CompletedTask`
- `Task<T>` -> `Task.FromResult(default(T)!)`
- `IEnumerable<T>` / `IList<T>` -> `Array.Empty<T>()` / `new List<T>()`
- `bool` -> `false`

Throwing is permitted **only** when no safe default exists for the return shape (e.g., a non-nullable abstract type with no parameterless ctor) - in which case the file becomes part of the scaffold-skipped surface allowed by `support/final-scaffold-checklist.md`.

Register in `RegisterServices.cs`:
```csharp
// Bootstrapper/RegisterServices.cs - no-op stubs (replaced with real implementations in Phase 5a/5b)
services.AddScoped<I{Entity}RepositoryTrxn, NoOp{Entity}RepositoryTrxn>();
services.AddScoped<I{Entity}RepositoryQuery, NoOp{Entity}RepositoryQuery>();
services.AddScoped<I{Entity}Service, NoOp{Entity}Service>();
```

### 6. DbContext Shells

```csharp
// Infrastructure.Data/{App}DbContextTrxn.cs
public class {App}DbContextTrxn : DbContextBase<Guid, Guid>
{
    public DbSet<{Entity}> {Entities} => Set<{Entity}>();
    // ... per entity
    // SHELL: OnModelCreating with empty configuration (Phase 5a adds EF configs)
}

// Infrastructure.Data/{App}DbContextQuery.cs
public class {App}DbContextQuery : {App}DbContextTrxn
{
    // read-only context configuration (Phase 5a finalizes)
}
```

---

## Entity Ordering

Generate entities in dependency order: parent entities first, then children. Use the relationship graph from `.scaffold/resource-implementation.yaml` to determine ordering. An entity with no parent dependencies is generated first.

---

## Gate

```powershell
dotnet restore
dotnet build
dotnet test --filter "TestCategory=Unit|TestCategory=Endpoint"
```

The entire solution - including all test projects - must compile successfully. `dotnet restore` must succeed against the configured private feed (with `NUGET_AUTH_TOKEN` set). At Phase 4, the only tests present are the trivially-passing shells emitted alongside the contract - they must all pass (no project should fail to discover tests, fail to assembly-init, or leave the runner red). Tests that exercise external infrastructure (`[TestCategory("Integration")]`, `[TestCategory("E2E")]`) are populated in Phase 5 and may use `Assert.Inconclusive` / `[Ignore]` with a reason until the dependency is wired.

Developer reviews the scaffolded shape against the verification checklist below.

---

## Post-Gate

1. Git checkpoint (commit the contract scaffold).
2. Update `HANDOFF.md`:
   - `currentPhase: "5"`
   - `currentSubPhase: "5a"`
   - `contractsScaffolded: true`
   - Record the entity ordering used and any deviations from `.scaffold/resource-implementation.yaml`.
3. Close session.

---

## What NOT to Generate

- **No domain logic** - entity `Create()`/`Update()` methods are shells
- **No EF configurations** - `OnModelCreating` is empty (Phase 5a)
- **No repository implementations** - only interfaces + no-op stubs (Phase 5a)
- **No service implementations** - only interfaces + no-op stubs (Phase 5b)
- **No API endpoints** - endpoint classes are Phase 5b
- **No mapper implementations** - mappers are Phase 5b
- **No test methods** - test projects exist but are empty (Phase 5a/5b write tests)

---

## Verification

- [ ] `.slnx` exists and includes all projects
- [ ] `dotnet build` succeeds from solution root
- [ ] Every entity from `.scaffold/resource-implementation.yaml` has: interface, DTO, entity shell, builders
- [ ] All no-op stubs satisfy their interfaces (no abstract/unimplemented methods)
- [ ] Test.Support contains `UnitTestBase`, `InMemoryDbBuilder`, `DbSupport`, `Utility`, `TestConstants`, `JsonTestOptions`, `LocalSqlSettings`, `WebApplicationFactoryBase`
- [ ] `Test.Endpoints/CustomApiFactory.cs` and `Test.E2E/SqlApiFactory.cs` derive from `WebApplicationFactoryBase<Program, {App}DbContextTrxn, {App}DbContextQuery>` (do not duplicate the swap-out logic)
- [ ] `Test.Integration/Infrastructure/SqlContainerFixture.cs` + `AzuriteContainerFixture.cs` + `IntegrationTestSetup.cs` (component) and `Test.Aspire/AspireTestHost.cs` + `AspireMeshLifecycle.cs` (mesh) exist (even when no tests reference them yet - Phase 5 fills them)
- [ ] Test data `{Entity}DtoBuilder` returns valid DTOs
- [ ] `RegisterServices.cs` wires all no-op stubs
- [ ] No domain logic in entity shells (only `throw new NotImplementedException`)
- [ ] No local reimplementation of `<packagePrefix>.*` shared base types into application/domain/host layers (they live in feed packages or `src/Packages/<packagePrefix>.*` only)
- [ ] `dotnet restore` exits 0. For `feed`/`hybrid`: `NUGET_AUTH_TOKEN` is set and all feed-supplied `<packagePrefix>.*` packages resolve. For `local`/`hybrid`: every layer in `localPackageLayers` exists as a project under `src/Packages/<packagePrefix>.<Layer>` and is referenced via `<ProjectReference>`
- [ ] `dotnet test --filter "TestCategory=Unit|TestCategory=Endpoint"` exits 0 (Phase 4 shells must pass - no red, no aborted assemblies)
- [ ] Aspire AppHost starts cleanly: `dotnet run --project Host/Aspire/AppHost` reaches `Application started` for every registered resource with no exceptions in the dashboard, and `/healthz` returns 200 on every host project. Stub-mode external deps (`emulator`, `lazy-optional`, `no-op stub`, `deployment-only`) are acceptable; live cloud auth is not required.
- [ ] Developer reviews the scaffolded shape against the items above
- [ ] Token placeholders follow [placeholder-tokens.md](placeholder-tokens.md)

### Application Style Branch

Read `applicationStyle` from `.scaffold/resource-implementation.yaml` before generating Phase 4 contracts. Default is `service`.

- `service`: generate `I{Entity}Service`, service implementation stubs, and service endpoint templates.
- `cqrs`: generate command/query request records, one handler per request, `AddDecoratedRequestHandler<TRequest,TResponse,THandler>()`, CQRS endpoint templates, and custom validation decorators. Keep repository contracts shared; do not add CQRS-specific repositories unless they add domain value.
- `switch`: generate both service and CQRS endpoint templates plus `ApplicationStyle` / `ApplicationStyleResolver`; route mapping selects one endpoint set through `Application:Style` or `<APP>_APPLICATION_STYLE`.
