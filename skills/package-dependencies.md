# Package Dependencies (Shared Base Types)

Use this file as a compact contract map for shared base-type packages/projects. The contracts described here are sourced one of three ways depending on `packageStrategy` (set in `.scaffold/resource-implementation.yaml`):

| `packageStrategy` | How layers are consumed |
|---|---|
| `feed` | All base contracts come from a private NuGet feed (e.g., `EF.*` from GitHub Packages). Project files use `<PackageReference Include="<packagePrefix>.<Layer>">`. |
| `local` | All base contracts are generated as packable projects under `src/Packages/<packagePrefix>.*` and consumed via `<ProjectReference>`. No private feed configured. |
| `hybrid` | Feed-supplied layers use `<PackageReference>`; layers listed in `localPackageLayers` use `<ProjectReference>` against `src/Packages/<packagePrefix>.<Layer>`. Same prefix in both cases. |

`EF` is the canonical example prefix used throughout these instructions, not a hard-coded default. Substitute your `packagePrefix` everywhere `EF.*` appears below.

## Sources

- Reference implementation (core): <https://github.com/efreeman518/EF.Packages>
- Reference implementation (enterprise): <https://github.com/efreeman518/EF.Packages.Enterprise>
- See [../patterns/expected-output-index.md](../patterns/expected-output-index.md).

These two repos define the canonical contract surface for all modes. In `local` or `hybrid` mode, the locally-generated `src/Packages/<packagePrefix>.*` projects must match the contracts in [`../support/ef-packages-reference.md`](../support/ef-packages-reference.md) (derived from these repos).

> **AI lookup rule:** This file provides a compact contract map. When you need full API signatures, constructor parameters, or method overloads for any base type (e.g., `TableRepositoryBase`, `IBlobRepository`, `ICosmosDbRepository`, `IKeyVaultManager`), use the GitHub MCP server to read the source from [EF.Packages](https://github.com/efreeman518/EF.Packages) or [EF.Packages.Enterprise](https://github.com/efreeman518/EF.Packages.Enterprise) - they remain the canonical contract definition regardless of consumption mode.

## Latest, Not Pinned (Global Rule)

**All SDKs, packages, and components default to latest stable.** Never pin a specific version in instruction examples or templates. Resolve the latest stable version at scaffold time and write that into `Directory.Packages.props` / `global.json` / `Sdk="...@<version>"`.

In instruction docs:

- Use the `<latest-stable>` placeholder in xml/json snippets (e.g., `Sdk="Aspire.AppHost.Sdk/<latest-stable>"`, `<TargetFramework>$(LatestStableTfm)</TargetFramework>`).
- Do **not** write a hard-coded `Version="9.2.0"` or `net9.0` into a template - it goes stale silently and contradicts this rule on every PR diff.
- Do **not** cite versions in prose either ("first-class since Aspire 9.3", "fixed in EF 1.0.104", "MudBlazor 9.x point releases"). Describe the current behavior as present truth - the baseline tracks latest, so the current API is the only one that matters.
- Do **not** add version-history or backwards-compat framing ("resolved in X", "pre-X bug", "obsolete in X", "verified <date>", "regression guard for the old behavior"). State what the API does now; drop how it got there. ("Legacy" is fine only when it names a non-version concept - the `.sln` format, the `datetime` SQL type - never a package version.)

**Documented exceptions only.** A pinned version is permitted **only** when accompanied by a one-line reason inline (NU1605/NU1011 conflict, breaking-change quarantine, vendor compatibility note). Any pin without justification is a bug - replace with `<latest-stable>`.

SDK upgrade discipline:

- Treat major-version SDK bumps (e.g., a major Aspire bump, or .NET N -> N+1) as **deliberate, scheduled tasks**, not routine work.
- Consult the vendor's official upgrade guide via MS Learn before bumping.
- A file-naming or convention change introduced by a newer SDK MAY be adopted on the current SDK if it is purely cosmetic and compatible - call out the rationale in the relevant skill file.

## Minimize Third-Party Dependencies (Mandatory)

**Default: do not add a new third-party package.** Prefer the BCL, `Microsoft.Extensions.*`, ASP.NET Core built-ins, and the reference-app stack already wired in TaskFlow. If a recurring pattern is missing, write a small extension method in the appropriate layer instead of pulling in a library.

### Pre-approved third-party packages

These are already part of the reference app and may be added without developer discussion when the pattern requires them. Use the canonical wiring from the reference app - do not re-evaluate the choice each time:

| Package family | Purpose | Skill |
|---|---|---|
| `Yarp.ReverseProxy` | API gateway / reverse proxy | [gateway.md](gateway.md) |
| `Scalar.AspNetCore` | OpenAPI UI | [api.md](api.md) |
| `ZiggyCreatures.FusionCache.*` | Hybrid cache + Redis backplane | [caching.md](caching.md) |
| `StackExchange.Redis` | Redis client (backplane / direct) | [caching.md](caching.md) |
| `Moq` | Test doubles | [testing.md](testing.md) |
| `NetArchTest.Rules` | Architecture tests | [testing.md](testing.md) |
| `NBomber` | Load tests | [testing.md](testing.md) |
| `Testcontainers.*` | Real-infra integration/E2E tests | [testing.md](testing.md) |
| `BenchmarkDotNet` | Microbenchmarks | [testing.md](testing.md) |
| `dotnet-stryker` (local tool) | Mutation testing runner | [testing-quality.md](testing-quality.md) |
| `MudBlazor` | Blazor component library | [ui-blazor.md](ui-blazor.md) |
| `Refit` / `Refit.HttpClientFactory` | Typed HTTP clients | [external-api.md](external-api.md) |
| `Azure.*` (Identity, Storage, KeyVault, Cosmos, ServiceBus, EventGrid, EventHubs, AI) | Azure SDK | [azure-data-storage.md](azure-data-storage.md), [security.md](security.md), [messaging.md](messaging.md), [ai-integration.md](ai-integration.md) |
| `Aspire.*` (Hosting + client integrations like `Aspire.Azure.AI.Inference` + `Aspire.Hosting.Testing`) | Orchestration + integration tests | [bootstrapper.md](bootstrapper.md), [aspire.md](aspire.md), [testing.md](testing.md) |
| `Microsoft.Extensions.AI` / `Microsoft.Agents.AI` (+ `.OpenAI`) | `IChatClient` + Microsoft Agent Framework agents | [ai-integration.md](ai-integration.md) |

Add only the specific sub-package needed (e.g., `Azure.Storage.Blobs`, not the entire SDK). Versions stay in `Directory.Packages.props` per the Latest, Not Pinned rule. Consuming a Foundry **project** or **server-hosted/pre-existing agent** from app code adds `Azure.AI.Projects` + `Microsoft.Agents.AI.Foundry` (the `AIProjectClient.AsAIAgent(...)` path). `Aspire.Hosting.Foundry`, `Aspire.Azure.AI.Inference`, and `Microsoft.Agents.AI.Foundry` are preview-only (no stable release); pin them with a one-line inline reason - the documented version-pinning exception.

### Any other package - discuss first

Anything **not in the pre-approved table above** is not approved by default. The NuGet ecosystem is large; this section deliberately does not enumerate disallowed packages because the list would be endless and brittle. The rule is the opposite - **the pre-approved table is the allowlist**.

Before adding any other package, pause and discuss with the developer. The bar is "**high value** that the reference-app stack cannot deliver." Justification must answer:

1. What built-in (BCL / `Microsoft.Extensions.*` / ASP.NET Core) or reference-app pattern fails to cover this?
2. Why is a small in-house extension method insufficient?
3. What is the maintenance, license, and transitive-dependency cost?
4. Could equivalent behavior live as a thin extension package under `src/Packages/<packagePrefix>.<Layer>` (so it benefits other scaffolded apps) instead of as a third-party dependency?

If a candidate clears that bar, propose it explicitly to the developer with a one-paragraph rationale. Examples of common categories where teams reach for a package but the reference-app stack already covers the need: input validation, object mapping, assertion DSLs, alternate mocking frameworks, alternate JSON serializers. Default response in these categories: **write the extension or use what's already there.**

### Build a shared package instead (preferred path)

When a pattern recurs three or more times and no pre-approved package covers it cleanly, the answer is almost always **a small in-house extension**, not a NuGet dependency:

1. Add the helper to the appropriate layer - `EF.Common` (cross-cutting), `EF.Domain` (domain-pure), or a project-local `*Extensions.cs` for app-specific behavior. If the pattern is reusable across scaffolded apps, promote it to a packable project under `src/Packages/<packagePrefix>.<Layer>` so future apps inherit it via the standard package strategy.
2. Keep it minimal - one responsibility per extension method; no fluent builders that mimic a third-party DSL.
3. Cover it with a unit test that pins the contract.
4. Record the decision in `HANDOFF.md` so future sessions do not re-litigate the package-vs-extension trade-off.

The goal is a small, owned dependency surface - every package added is one the team commits to tracking for CVEs, license changes, and major-version breakage.

## Feed + Version Rules (Mandatory)

### When `packageStrategy: feed` or `hybrid` (feed-supplied layers only)

1. `nuget.config` must include `nuget.org` and all `customNugetFeeds` from [resource-implementation-schema.md](../ai/resource-implementation-schema.md).
2. **Both private feeds** must be declared when Enterprise packages (`<packagePrefix>.FlowEngine`, `<packagePrefix>.FilterBuilder`) are used - for the canonical `EF.*` example they ship from the same GitHub Packages org:
   - `https://nuget.pkg.github.com/efreeman518/index.json` (covers `EF.*` pattern for both Core and Enterprise)
3. Use central package versions in `Directory.Packages.props` for every feed-supplied `<packagePrefix>.<Layer>`.
4. After adding packages, restore and update to latest stable versions.
5. Re-verify with `dotnet restore` and `dotnet build`.
6. **Private feed auth:** GitHub Packages and other authenticated feeds require a PAT or token. Local dev stores credentials in `nuget.config` (user-level, not committed). CI/CD must pass credentials via environment variable or `dotnet nuget` auth step - see [cicd.md](cicd.md) for workflow setup. A 401 on restore means the feed credential is missing or expired. When the dev already has the feed configured with working credentials in the user-global `nuget.config`, author a secret-free repo `nuget.config` (source entry only, no `<packageSourceCredentials>`) so the project file does not shadow those global creds - see the probe-first Step 2 in [../support/operator-setup.md](../support/operator-setup.md) section Shared Base-Type Readiness.

### When `packageStrategy: local` or `hybrid` (locally-generated layers only)

1. No `nuget.config` private-feed entry is required for layers in `localPackageLayers`. `nuget.org` is still mandatory.
2. Each generated project under `src/Packages/<packagePrefix>.<Layer>/` sets `IsPackable=true`, `<PackageId>=<packagePrefix>.<Layer>`, `<Version>=0.1.0` (overridable).
3. Application/domain/host projects consume locally-generated layers via `<ProjectReference Include="..\..\Packages\<packagePrefix>.<Layer>\<packagePrefix>.<Layer>.csproj" />` - no `<PackageVersion>` entry in `Directory.Packages.props`.
4. Transitive NuGet dependencies of the generated projects (e.g., `Microsoft.EntityFrameworkCore`) still go through `Directory.Packages.props` central versions.
5. To publish later: `dotnet pack src/Packages/<packagePrefix>.<Layer>` produces a `.nupkg` that can be pushed to any feed. After the layer is published and consumed via `<PackageReference>`, move the layer from `localPackageLayers` into the feed-supplied set and delete the local project.

If `applicationStyle` is `cqrs` or `switch`, include `CQRS` in `localPackageLayers` for `packageStrategy: local`/`hybrid`. The generated project is `src/Packages/<packagePrefix>.CQRS/<packagePrefix>.CQRS.csproj` and is referenced by `{Project}.Application.Cqrs` and CQRS-focused tests via `<ProjectReference>`.

> **CPM + floating versions = NU1011.** When `ManagePackageVersionsCentrally=true`, every `<PackageVersion>` entry must use an exact version (e.g. `Version="<latest-stable>"` resolved at scaffold time). Wildcard/floating versions (e.g. `1.0.*`, `*`) are prohibited and cause restore to fail with NU1011. To use floating versions, set `ManagePackageVersionsCentrally=false` and add `Version="*"` directly to each `<PackageReference>`. This rule applies regardless of `packageStrategy`.

---

## Critical Domain Contracts

### `EF.Domain`

```csharp
public interface IDomainId<TSelf> where TSelf : IDomainId<TSelf>
{
    Guid Value { get; }
    static abstract TSelf From(Guid value);
}
```

```csharp
public interface IEntityBase<TId> { TId Id { get; init; } }
```

```csharp
public abstract class EntityBase<TId> : IEntityBase<TId>
    where TId : IDomainId<TId>
{
    public TId Id { get; init; }     // typed domain ID, value set from Guid.CreateVersion7()
    public byte[]? RowVersion { get; set; }
}
```

```csharp
public abstract class AuditableBase<TAuditIdType, TId> : EntityBase<TId>
    where TId : IDomainId<TId>
{
    public DateTime CreatedDate { get; set; }
    public TAuditIdType CreatedBy { get; set; }
    public DateTime? UpdatedDate { get; set; }
    public TAuditIdType? UpdatedBy { get; set; }
}
```

```csharp
public interface ITenantEntity<TTenantIdType> where TTenantIdType : struct
{
    TTenantIdType TenantId { get; init; }
}
```

Critical invariants:
- Entity IDs use `Guid.CreateVersion7()`.
- Keep optimistic concurrency via `RowVersion`.
- Tenant entities implement `ITenantEntity<T>`.

### `EF.Domain.Contracts`

```csharp
public record DomainError(string Error, string? Code = null);
```

`DomainResult` / `DomainResult<T>`:
- success/failure states
- `Errors: IReadOnlyList<DomainError>`
- map/bind/match/tap helpers for railway flow

Also available:
- `IEntityBaseDto` (`Guid? Id`)
- `DomainException`
- `[Mask]` attribute for redaction

---

## Data Layer Contracts

### `EF.Data`

`DbContextBase<TAuditIdType, TTenantIdType>` provides:
- audit/tenant context fields
- tenant filter helpers
- concurrency-aware `SaveChangesAsync(OptimisticConcurrencyWinner winner, ...)`

`EntityBaseConfiguration<TEntity, TId>` standardizes:
- key mapping (`Id`)
- `ValueGeneratedNever()`
- row-version configuration

### `EF.Data.Contracts`

`IRepositoryBase` supports:
- CRUD (`Create`, `PrepareForUpdate`, `UpdateFull`, `Delete`, `DeleteAsync`)
- existence and key lookups
- single query and paged queries
- projection queries and async streaming
- save changes with/without concurrency winner
- include/split-query options

Other key types:
- `OptimisticConcurrencyWinner` (`ClientWins`, `DBWins`, `Throw`)
- `SplitQueryThresholdOptions`
- `AuditInterceptor`
- `DbContextScopedFactory`
- queryable helpers (`IQueryableExtensions`)

---

## Common Contracts

### `EF.Common.Contracts`

- `Result` / `Result<T>` (same shape as domain result, but `Errors: IReadOnlyList<string>`)
- `IRequestContext<TAuditIdType, TTenantIdType>`
- `RequestContext<...>` implementation - constructor order is `(correlationId, auditId, tenantId, roles)`
- `PagedResponse<T>` - properties: `PageSize` (int), `PageIndex` (int), `Total` (int), `Data` (IReadOnlyList&lt;T&gt;)
- `SearchRequest<TFilter>` - record with: `PageSize` (int), `PageIndex` (int), `Sorts` (IEnumerable&lt;Sort&gt;?), `Filter` (TFilter?)
- `Sort` - constructor: `Sort(string propertyName, SortOrder sortOrder)` - properties: `PropertyName`, `SortOrder`
- `SortOrder` - enum: `Ascending = 0`, `Descending = 1`
- `IMessage`
- `AuditEntry<TAuditIdType, TTenantIdType>` + `AuditStatus`

### `EF.Common`

- `ResultExtensions.ToResult(...)` for domain->application conversion
- expression/predicate helpers for EF-safe composition
- `CollectionUtility` (non-domain sync helpers)
- `NotFoundException`

---

### `EF.CQRS`

Add when `applicationStyle` is `cqrs` or `switch`.

| Type | Used For |
|---|---|
| `IRequest<TResponse>` | Marker for commands and queries with a typed response |
| `ICommand<TResponse>` | Write request marker |
| `IQuery<TResponse>` | Read request marker |
| `IRequestHandler<TRequest,TResponse>` | Single request handler contract |
| `IRequestValidator<TRequest>` | Optional request validator contract |
| `RequestValidationResult` | Validator result with one or more errors |
| `IValidationResponseFactory<TResponse>` | Converts validation errors to the app response shape |
| `ValidationRequestHandlerDecorator<TRequest,TResponse>` | Decorates handlers with validation before execution |
| `AddDecoratedRequestHandler<TRequest,TResponse,THandler>()` | Registers handler plus validation decorator |

No MediatR, dispatcher, request bus, or generic `Send` API is part of this package. CQRS endpoints inject the specific `IRequestHandler<TRequest,TResponse>` they need.

---

## Background and Messaging

### `EF.BackgroundServices`

```csharp
public interface IBackgroundTaskQueue
{
    ValueTask QueueBackgroundWorkItem(Func<IServiceProvider, CancellationToken, ValueTask> workItem);
    ValueTask QueueScopedBackgroundWorkItem<TScoped>(Func<TScoped, CancellationToken, ValueTask> workItem) where TScoped : notnull;
    ValueTask<Func<IServiceProvider, CancellationToken, ValueTask>> DequeueAsync(CancellationToken cancellationToken);
}
```

### `EF.BackgroundServices.InternalMessageBus`

```csharp
public interface IInternalMessageBus
{
    void AutoRegisterHandlers(IServiceProvider serviceProvider, params Assembly[] assemblies);
    void RegisterMessageHandler<T>(IMessageHandler<T> handler) where T : IMessage;
    void Publish<T>(InternalMessageBusProcessMode mode, ICollection<T> messages) where T : IMessage;
}

public interface IMessageHandler<in T> where T : IMessage
{
    Task HandleAsync(T message, CancellationToken cancellationToken = default);
}
```

**Namespace warning:** `IInternalMessageBus` / `IMessageHandler<T>` come from `EF.BackgroundServices.InternalMessageBus`.

**Dispatch warning:** `Publish(...)` queues work onto the registered `IBackgroundTaskQueue`; it is not an inline handler invocation, and there is no `PublishAsync` / single-message overload.

### `EF.Messaging`

Core abstractions used by scaffolding:
- `IServiceBusSender`
- `IEventGridPublisher`
- `IEventHubProducer`

Use package base classes for sender/publisher/processor implementations.

---

## Data Service Extensions

### `EF.CosmosDb`

- Base entity: `CosmosDbEntity` (`PartitionKey`, `id` alias)
- Main abstraction: `ICosmosDbRepository`
  - save/get/delete
  - paged query + projection
  - stream query variants

### `EF.Storage`

`IBlobRepository` supports:
- upload/download/delete/exists
- SAS URI generation
- container client retrieval
- blob leasing helpers

### `EF.Table`

`ITableRepository` supports:
- get/upsert/delete entity
- paged query and streaming

### `EF.KeyVault`

- `IKeyVaultManager`: secrets/keys/certs operations
- `IKeyVaultCryptoUtility`: encrypt/decrypt helpers

### `EF.Grpc`

Provides interceptors and registration helpers for consistent gRPC error handling.

### `EF.FilterBuilder`

`FilterSet` / `Filter` contracts to generate dynamic query filters.

**Enterprise packages** (from <https://github.com/efreeman518/EF.Packages.Enterprise>):

### `EF.FlowEngine`

Durable, JSON-defined workflow orchestration engine. Add only when the requirement is a long-running, branching, or resumable process that a code-hosted agent cannot meet.

- `IFlowEngine`: start, signal, resume, terminate, status
- `IWorkflowRegistry`: workflow definition CRUD
- `IFlowClient` subtypes: `IRequestResponseClient`, `IQueryClient`, `IMessageClient`, `IAgentClient`, `IFlowEngineClient`
- `IDistributedLockProvider`, `IExecutionStateStore`, `IHumanTaskStore`, `IOutboxStore`, `ICircuitBreakerStore`
- Pluggable backend packages: `EF.FlowEngine.StateStore.*`, `EF.FlowEngine.Locks.*`, `EF.FlowEngine.WorkflowRegistry.*`, `EF.FlowEngine.HumanTaskStore.*`, `EF.FlowEngine.Clients.*`
- See [../support/ef-packages-reference.md](../support/ef-packages-reference.md) for full type list.

---

## Public Packages Used with EF.*

- `Refit.HttpClientFactory`
- `Microsoft.Extensions.Http.Resilience`

Pattern reference: [external-api.md](external-api.md)

---

## Generation Checklist

- [ ] `nuget.config` includes `nuget.org`; for `packageStrategy: feed`/`hybrid` it also includes every entry in `customNugetFeeds`
- [ ] For `packageStrategy: feed`/`hybrid`: local `NUGET_AUTH_TOKEN` or approved credential provider is configured for the private feed
- [ ] For `packageStrategy: feed`/`hybrid`: `python .instructions/scripts/configure-ef-packages-feed.py --root . --feed-url <feed-url> --username <github-user> --prefix <packagePrefix>` has been run or equivalent config has been manually verified
- [ ] For `packageStrategy: local`/`hybrid`: every layer in `localPackageLayers` has a corresponding `src/Packages/<packagePrefix>.<Layer>` project planned with `IsPackable=true` and `<PackageId>=<packagePrefix>.<Layer>`
- [ ] `dotnet restore` exits 0 before Phase 4 (with `NUGET_AUTH_TOKEN` set when `feed`/`hybrid`)
- [ ] `Directory.Packages.props` owns versions
- [ ] `global.json` pins SDK with roll-forward policy
- [ ] Correct package placement across Domain/Data/Application/Infrastructure hosts
- [ ] Latest stable versions resolved successfully
- [ ] `dotnet restore` re-runs cleanly after projects are generated
- [ ] `EntityBase.Id` behavior preserved (`Guid.CreateVersion7()`)
- [ ] Domain/application error types are not mixed:
  - `DomainResult.Errors` -> `IReadOnlyList<DomainError>`
  - `Result.Errors` -> `IReadOnlyList<string>`
- [ ] Internal message bus namespaces are correct
- [ ] If `applicationStyle` is `cqrs` or `switch`: `<packagePrefix>.CQRS` is sourced by feed or local project, and no MediatR/dispatcher package was added
- [ ] Azure client factories and package-required DI wiring are registered

## Pitfalls

- Adding a package outside the allowlist without recording the decision in `.scaffold/DESIGN-DECISIONS.md` (**GR-04**) - drift compounds: each undocumented dependency makes the next one easier to slip in, and license/security review has no audit trail.
- Hard-coding a package version in instructions, templates, or `Directory.Packages.props` examples - violates the latest-stable rule (**GR-08**). Use `<latest-stable>` placeholders and let scaffold-time resolution pin the version.
- Adding MediatR or a similar dispatcher when `applicationStyle` is `cqrs` or `switch` - the scaffold ships `<packagePrefix>.CQRS` for exactly that role; layering MediatR on top fragments the request pipeline.
- Pinning a private-feed PAT into `nuget.config` instead of `%NUGET_AUTH_TOKEN%` / `$NUGET_AUTH_TOKEN` - leaks the credential into source control on the next push.
- Skipping `dotnet restore` verification after generating `src/Packages/<packagePrefix>.*` projects in `local`/`hybrid` mode - the first hint of a missing layer otherwise surfaces as a build error mid-Phase-5 with no easy diff to read.
