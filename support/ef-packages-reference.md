# Shared Base-Type Reference (canonical example: `EF.*`)

The scaffolded project depends on a set of shared base-type contracts (entity bases, repository bases, request context, results, paged response, specifications, messaging interfaces, etc.). The tables below describe those contracts and apply equally to every `packageStrategy`.

How those contracts are delivered depends on `packageStrategy` in `.scaffold/resource-implementation.yaml`:

| `packageStrategy` | Delivery |
|---|---|
| `feed` | All layers consumed as NuGet packages `<packagePrefix>.<Layer>` from `customNugetFeeds`. |
| `local` | All layers generated as packable projects under `src/Packages/<packagePrefix>.<Layer>` and consumed via `<ProjectReference>`. |
| `hybrid` | Feed-supplied layers consumed as NuGet packages; layers listed in `localPackageLayers` generated under `src/Packages/<packagePrefix>.<Layer>` and consumed via `<ProjectReference>`. Same prefix in both cases. |

Throughout this file, `EF` is the **canonical example prefix** (used by the reference app TaskFlow and the [efreeman518/EF.Packages](https://github.com/efreeman518/EF.Packages) repo). Substitute your `packagePrefix` everywhere you see `EF.<Layer>` below. The type signatures themselves are identical regardless of prefix.

Do not regenerate these types into your application/domain/host layers - they live in `<packagePrefix>.*` only, whether package or project.

> **Pre-flight:** When `packageStrategy: feed` or `hybrid`, configure the private feed in `nuget.config` before Phase 4; local environments need package read access exposed through `NUGET_AUTH_TOKEN` or an equivalent credential provider. When `packageStrategy: local`, no feed configuration is needed for these layers (only `nuget.org` is required). Verify with `dotnet restore` (exit code 0) in Phase 3 and after Phase 4 build. See [execution-gates.md](execution-gates.md).

---

## Key Types by Layer

These types are consumed throughout scaffolded code. Know where they come from so you don't recreate them.

> **Verified against the latest EF.Packages release.** If a type is not listed here, it either does not exist in EF.Packages or has not been verified. Check the actual assemblies (or the source repo linked above) before assuming a type exists.

### Domain Layer (EF.Domain, EF.Domain.Contracts)

| Type | Package | Used For |
|---|---|---|
| `EntityBase` | EF.Domain | Base class for all domain entities (Id, audit fields) |
| `AuditableBase<TAuditIdType>` | EF.Domain | Base class with audit trail fields |
| `CollectionUtility` | EF.Domain | Utility for collection operations |
| `IEntityBase<TKey>` | EF.Domain.Contracts | Entity base interface |
| `ITenantEntity<TTenant>` | EF.Domain.Contracts | Tenant-scoped entity marker; enables global query filters |
| `IAuditable<TAuditIdType>` | EF.Domain.Contracts | Audit trail interface (CreatedBy, ModifiedBy, timestamps) |
| `DomainResult<T>` | EF.Domain.Contracts | Railway-style result for domain operations. Properties: `Value`, `IsSuccess`, `IsFailure`, `IsNone`, `ErrorMessage` (aggregated string), `Errors` (`IReadOnlyList<DomainError>`). Static: `Success(T)`, `Failure(string error)`, `Failure(string code, string error)`, `Failure(IReadOnlyList<DomainError>)`, `Failure(Exception)`, `None()`. |
| `DomainResult` | EF.Domain.Contracts | Non-generic domain result. Same shape as `DomainResult<T>` minus `Value`/`IsNone`. |
| `DomainError` | EF.Domain.Contracts | Typed error. Properties: `Error` (the human message), `Code` (machine key), `Message` (alias for `Error`). Static factory: `DomainError.Create(string error, string code)`. Never access `.Message` from `Exception` - use `.Error` or `.Message` (same). **Propagation pattern:** `if (r.IsFailure) return Result<T>.Failure(r.ErrorMessage!);` or `Result<T>.Failure(r.Errors)`. |

### Data Access Layer (EF.Data, EF.Data.Contracts)

| Type | Package | Used For |
|---|---|---|
| `DbContextBase<TAuditIdType, TTenantIdType>` | EF.Data | Base DbContext with tenant filters, audit interceptor hooks, default type config |
| `RepositoryBase<TDbContext, TAuditIdType, TTenantIdType>` | EF.Data | Generic repository with CRUD, paging, search. Members: Create, Delete, DeleteAsync, ExistsAsync, GetEntityAsync, GetEntityByKeysAsync, GetEntityProjectionAsync, PrepareForUpdate, QueryPageAsync, QueryPageProjectionAsync, SaveChangesAsync, UpdateFull, UpsertAsync. **All members are generic over the entity** (`Create<T>(ref T)`, `GetEntityAsync<T>(...)`, ...), so one instance serves any entity. |
| `RepositoryTrxn<TEntity, TDbContext>` / `RepositoryQuery<TEntity, TDbContext>` | EF.Data | Generic per-entity repository impls over `RepositoryBase` for entities with no bespoke logic (`GetAsync`, `ListAsync` + inherited generic CRUD). Register open-generic via a closed-over-context subclass. See [repository-template.md](../templates/repository-template.md) -> Generic Repository Pair. |
| `IRepositoryBase` | EF.Data.Contracts | Base repository interface (non-generic). Exposes the generic-method CRUD/query surface (`Create<T>`, `Delete<T>`, `GetEntityAsync<T>`, `QueryPageProjectionAsync<T,TProject>`, `SaveChangesAsync`, ...). |
| `IRepositoryTrxn<TEntity>` / `IRepositoryQuery<TEntity>` | EF.Data.Contracts | Open-generic repository contracts (extend `IRepositoryBase`) for generic-coverable entities (join / append-only / simple CRUD). A bespoke `I{Entity}RepositoryQuery` extends `IRepositoryQuery<TEntity>` to add `Search`. Drives `repositoryContractStyle: hybrid`/`generic-only`. |
| `AuditInterceptor<TAuditIdType, TTenantIdType>` | EF.Data | EF SaveChanges interceptor for audit field population; on `SavedChangesAsync` it publishes collected audit entries through `IInternalMessageBus` |
| `ConnectionNoLockInterceptor` | EF.Data | Adds `SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED` for query contexts |
| `ReadUncommittedInterceptor` | EF.Data | Read uncommitted isolation level interceptor |
| `DbContextScopedFactory<TContext, TAuditIdType, TTenantIdType>` | EF.Data | Scoped wrapper around `IDbContextFactory<T>` for DI resolution |
| `OptimisticConcurrencyWinner` | EF.Data.Contracts | Enum for SaveChangesAsync conflict resolution strategy |
| `IQueryableExtensions` | EF.Data.Contracts | Extension methods for IQueryable |
| `AuditChangeAttribute` | EF.Data.Contracts | Attribute for audit change tracking |
| `RelatedDeleteBehavior` | EF.Data.Contracts | Enum for related entity delete behavior |
| `MigrationSupport` | EF.Data | Migration support utilities |
| `ResilientTransaction` | EF.Data | Resilient transaction wrapper |

### Common Infrastructure (EF.Common, EF.Common.Contracts)

| Type | Package | Used For |
|---|---|---|
| `IRequestContext<TUser, TTenant>` | EF.Common.Contracts | Scoped request context (CorrelationId, AuditId, TenantId, Roles, RoleExists()) |
| `RequestContext<TUser, TTenant>` | EF.Common.Contracts | Default implementation of IRequestContext. Constructor order: `(correlationId, auditId, tenantId, roles)` |
| `Result<T>` | EF.Common.Contracts | Application-layer result wrapper. Members: IsSuccess, IsFailure, IsNone, Value, ErrorMessage, Errors, Match, Map, Bind, BindOrContinue, OnSuccess, OnFailure, Tap. Static: `Success(T)`, `Failure(string error)`, `Failure(string code, string error)`, `Failure(IReadOnlyList<DomainError>)`, `Failure(Exception)`. **Not JSON-deserializable** - lacks parameterless constructor; use `JsonDocument` parsing in tests. When passed to `Results.Ok(result)` in endpoints, serializes to just the `Value` payload (not the full Result wrapper). |
| `Result` | EF.Common.Contracts | Non-generic result. Static: `Success()`, `Failure(string error)`, `Failure(string code, string error)`, `Failure(IReadOnlyList<DomainError>)`, `Failure(Exception)`, `Combine(Result[])`. |
| `PagedResponse<T>` | EF.Common.Contracts | Paged response with Data, Total, PageSize, PageIndex |
| `SearchRequest<TFilter>` | EF.Common.Contracts | Paged search request with PageSize, PageIndex, Sorts, Filter |
| `Sort` | EF.Common.Contracts | Sort descriptor (PropertyName, SortOrder) |
| `SortOrder` | EF.Common.Contracts | Enum: Ascending=0, Descending=1 |
| `IMessage` | EF.Common.Contracts | Marker interface for domain events/messages |
| `ISpecification<T>` / `Specification<T>` | EF.Common.Contracts | Specification pattern base |
| `StaticItem<TKey, TTenantKey>` | EF.Common.Contracts | Lookup item for dropdowns |
| `StaticList<T>` | EF.Common.Contracts | Typed collection for lookup data |
| `StaticData` | EF.Common.Contracts | Static data container |
| `AuditEntry<TAuditIdType, TTenantIdType>` | EF.Common.Contracts | Audit entry record carrying both audit identity and tenant identity |
| `AuditStatus` | EF.Common.Contracts | Audit status enum |
| `StaticLogging` | EF.Common | Pre-host logger factory for startup/shutdown logging |
| `PredicateBuilder` | EF.Common | Dynamic LINQ predicate builder |

### CQRS (EF.CQRS)

Add when `applicationStyle` is `cqrs` or `switch`. In local mode, generate this as `src/Packages/<packagePrefix>.CQRS` and consume it through `<ProjectReference>`.

| Type | Package | Used For |
|---|---|---|
| `IRequest<TResponse>` | EF.CQRS | Marker for commands and queries with a typed response |
| `ICommand<TResponse>` | EF.CQRS | Write request marker |
| `IQuery<TResponse>` | EF.CQRS | Read request marker |
| `IRequestHandler<TRequest,TResponse>` | EF.CQRS | Single request handler contract |
| `IRequestValidator<TRequest>` | EF.CQRS | Optional request validator contract |
| `RequestValidationResult` | EF.CQRS | Validator result with one or more errors |
| `IValidationResponseFactory<TResponse>` | EF.CQRS | Converts validation errors to the app response shape |
| `StaticFailureValidationResponseFactory<TResponse>` | EF.CQRS | Reflection-based factory for common static `Failure(...)` result shapes |
| `ValidationRequestHandlerDecorator<TRequest,TResponse>` | EF.CQRS | Validation decorator around handlers |
| `AddDecoratedRequestHandler<TRequest,TResponse,THandler>()` | EF.CQRS | DI helper that registers the concrete handler and decorated interface |

**Dispatch rule:** EF.CQRS has no MediatR dependency, dispatcher, request bus, or generic `Send` method. Minimal API endpoints inject the exact `IRequestHandler<TRequest,TResponse>` they call. Scaffold request records, handlers, validators, and per-feature registration fragments under `Application.Cqrs/Features/{Entity}`.

### Background Services (EF.BackgroundServices)

| Type | Package | Used For |
|---|---|---|
| `IInternalMessageBus` | EF.BackgroundServices | In-process message bus for domain event dispatch |
| `InternalMessageBus` | EF.BackgroundServices | Default implementation of IInternalMessageBus; dispatches through `IBackgroundTaskQueue`, not inline |
| `IMessageHandler<T>` | EF.BackgroundServices | Handler interface for messages (where T : IMessage) |
| `ScopedMessageHandlerAttribute` | EF.BackgroundServices | Attribute for scoped message handler discovery |
| `InternalMessageBusProcessMode` | EF.BackgroundServices | Dispatch mode for in-process bus fan-out / queue semantics |
| `CronBackgroundService<T>` | EF.BackgroundServices | Cron-scheduled background service |
| `ICronJobHandler<T>` | EF.BackgroundServices | Handler interface for cron jobs |
| `IBackgroundTaskQueue` | EF.BackgroundServices | Queue for background task processing |
| `ScopedBackgroundService` | EF.BackgroundServices | Base class for scoped background services |

#### Critical Wiring Notes

- `AuditInterceptor` does **not** persist audit rows itself. It publishes `AuditEntry<...>` messages through `IInternalMessageBus` after `SaveChangesAsync` succeeds.
- `InternalMessageBus.Publish(...)` is a synchronous fire-and-forget API over the channel queue. Do not invent `PublishAsync` or single-message overloads.
- `InternalMessageBus` depends on the channel-based `IBackgroundTaskQueue`; if the queue/hosted service is missing, `Publish(...)` succeeds but handlers never run.
- `[ScopedMessageHandler]` controls handler scope during dispatch only. Handlers still must be registered in DI and then wired into the bus after host build.

### Application Host (EF.Host, EF.AspNetCore)

| Type | Package | Used For |
|---|---|---|
| `IConfigurationBuilderExtensions` | EF.Host | Configuration builder extensions |
| `IHostApplicationBuilderExtensions` | EF.Host | Host builder extensions |
| `CorrelationIdStartupFilter` | EF.AspNetCore | Middleware to propagate/generate correlation IDs |
| `ValidationFilter<T>` | EF.AspNetCore | FluentValidation endpoint filter |
| `ProblemDetailsHelper` | EF.AspNetCore | ProblemDetails response builder helpers |
| `HealthCheckHelper` | EF.AspNetCore | Health check registration helpers |
| `MemoryHealthCheck` | EF.AspNetCore | Memory usage health check implementation |
| `HealthLoggingPublisher` | EF.AspNetCore | IHealthCheckPublisher that logs health status |
| `ChaosManager` / `IChaosManager` | EF.AspNetCore | Chaos engineering fault injection |
| `FilterActivityProcessor` | EF.AspNetCore | OpenTelemetry Activity processor with filter support |

> **Note:** `DefaultExceptionHandler` is **not** in EF.AspNetCore. Scaffold it per-project as a concrete `IExceptionHandler` implementation. See reference app `TaskFlow.Api/Middleware/GlobalExceptionHandler.cs`.

### Caching (EF.Cache)

| Type | Package | Used For |
|---|---|---|
| `CacheSettings` | EF.Cache | Config model bound from `CacheSettings[]` in appsettings |

### Authentication (EF.Auth)

Add when the app needs outbound auth (calling protected APIs) or role/scope-based authorization.

| Type | Package | Used For |
|---|---|---|
| `IOAuth2TokenProvider` | EF.Auth | Token acquisition contract |
| `OAuth2TokenProvider` | EF.Auth | Generic OAuth2 token provider |
| `OAuth2Options` | EF.Auth | OAuth2 configuration options |
| `Auth0TokenProvider` | EF.Auth | Auth0-specific token provider |
| `Auth0Options` | EF.Auth | Auth0 configuration |
| `AzureAdTokenProviderConfidentialClientApp` | EF.Auth | Azure AD MSAL confidential client token provider |
| `AzureADOptions` | EF.Auth | Azure AD configuration |
| `IAzureDefaultCredTokenProvider` | EF.Auth | Contract for DefaultAzureCredential token acquisition |
| `AzureDefaultCredTokenProvider` | EF.Auth | DefaultAzureCredential-based token provider |
| `BaseDefaultAzureCredsAuthMessageHandler` | EF.Auth | `DelegatingHandler` for outbound HTTP auth with Azure credentials |
| `RolesOrScopesAuthorizationHandler` | EF.Auth | Flexible role or scope-based ASP.NET Core authorization handler |
| `RolesOrScopesRequirement` | EF.Auth | Authorization requirement for role/scope check |

### Messaging (EF.Messaging)

Add when the app publishes or consumes Azure Service Bus, Event Grid, or Event Hub messages.

| Type | Package | Used For |
|---|---|---|
| `IServiceBusSender` | EF.Messaging | Contract for publishing to Service Bus |
| `ServiceBusSenderBase` | EF.Messaging | Abstract Service Bus sender (derive per-project) |
| `ServiceBusSenderSettingsBase` | EF.Messaging | Settings base for sender configuration |
| `ServiceBusProcessorBase` | EF.Messaging | Abstract Service Bus message processor (implement `IServiceBusReceiver`) |
| `ServiceBusProcessorSettingsBase` | EF.Messaging | Settings base for processor configuration |
| `IEventGridPublisher` | EF.Messaging | Contract for publishing Event Grid events |
| `EventGridPublisherBase` | EF.Messaging | Abstract Event Grid publisher (derive per-project) |
| `EventGridPublisherSettingsBase` | EF.Messaging | Settings base for publisher configuration |
| `EventGridEvent` | EF.Messaging | Event Grid event model |
| `IEventHubProducer` | EF.Messaging | Contract for sending to Event Hub |
| `EventHubProducerBase` | EF.Messaging | Abstract Event Hub producer |
| `EventHubProducerSettingsBase` | EF.Messaging | Settings base for producer configuration |
| `IEventHubProcessor` | EF.Messaging | Contract for consuming from Event Hub |
| `EventHubProcessorBase` | EF.Messaging | Abstract Event Hub processor |
| `EventHubProcessorSettingsBase` | EF.Messaging | Settings base for processor configuration |

### Azure Storage (EF.Storage)

Add when the app needs Blob Storage access. Do not hand-roll blob logic - extend `BlobRepositoryBase`.

| Type | Package | Used For |
|---|---|---|
| `IBlobRepository` | EF.Storage | Blob storage contract (upload, download, delete, SAS generation, container ops) |
| `BlobRepositoryBase` | EF.Storage | Abstract blob repository; extend with a project-specific class |
| `BlobRepositorySettingsBase` | EF.Storage | Settings base (requires `BlobServiceClientName`) |
| `ContainerInfo` | EF.Storage | Container configuration model |
| `ContainerPublicAccessType` | EF.Storage | Enum for container access level |

**Constructor constraint:** `BlobRepositoryBase(ILogger, IOptions<BlobRepositorySettingsBase>, IAzureClientFactory<BlobServiceClient>)` - the settings parameter uses the base type. Register via `services.Configure<BlobRepositorySettingsBase>(...)` or use covariant DI binding.

**Known stub state:** As of the feed packages this scaffold targets, `BlobRepositoryBase.Upload/Download/DeleteAsync` ship as `virtual` stubs that throw `NotImplementedException`. Derived project repos must override every method actually called by application code - do **not** rely on the base implementation just because `dotnet build` is green. The base stubs are tracked by the *scaffold-skipped surface* exception in [final-scaffold-checklist.md](final-scaffold-checklist.md), but the moment a real call site exists (a service method, an endpoint, a background job), the override is mandatory or it fails at runtime. See [../skills/azure-data-storage.md](../skills/azure-data-storage.md) -> *Project Repository Wrapper* for the override pattern.

### Azure Table Storage (EF.Table)

Add when the app needs Table Storage. Do not hand-roll table logic - extend `TableRepositoryBase`.

| Type | Package | Used For |
|---|---|---|
| `ITableRepository` | EF.Table | Table storage contract (get, create, upsert, delete, page query, stream) |
| `TableRepositoryBase` | EF.Table | Abstract table repository; extend with a project-specific class |
| `TableRepositorySettingsBase` | EF.Table | Settings base (requires `TableServiceClientName`) |
| `TableUpdateMode` | EF.Table | Enum: `Merge` (partial update) or `Replace` (full overwrite) |

**Constructor constraint:** `TableRepositoryBase(ILogger, IOptions<TableRepositorySettingsBase>, IAzureClientFactory<TableServiceClient>)` - same base-type settings pattern as `BlobRepositoryBase`.

### Azure Cosmos DB (EF.CosmosDb)

Add when the app needs Cosmos DB document storage.

| Type | Package | Used For |
|---|---|---|
| `ICosmosDbRepository` | EF.CosmosDb | Cosmos DB contract (save, get, delete, paged query, projection query) |
| `CosmosDbRepositoryBase` | EF.CosmosDb | Abstract Cosmos DB repository |
| `CosmosDbRepositorySettingsBase` | EF.CosmosDb | Settings base (requires `CosmosDbId`) |
| `CosmosDbEntity` | EF.CosmosDb | Base entity with `PartitionKey` property and `id` alias |

### Azure Key Vault (EF.KeyVault)

Add when the app retrieves secrets, keys, or certificates from Key Vault.

| Type | Package | Used For |
|---|---|---|
| `IKeyVaultManager` | EF.KeyVault | Secrets, keys, and certificates operations |
| `IKeyVaultCryptoUtility` | EF.KeyVault | Encrypt/decrypt helpers via Key Vault |

### gRPC (EF.Grpc)

Add when the app exposes or consumes gRPC services.

| Type | Package | Used For |
|---|---|---|
| `EF.Grpc` interceptors and registration helpers | EF.Grpc | Consistent gRPC error handling and Polly resilience wiring for gRPC clients |

### AI / OpenAI (EF.OpenAI, EF.AzureOpenAI)

Add when the app integrates OpenAI or Azure OpenAI directly (not via Agent Framework wrappers).

| Type | Package | Used For |
|---|---|---|
| `EF.OpenAI` types | EF.OpenAI | OpenAI API client integration helpers |
| `EF.AzureOpenAI` types | EF.AzureOpenAI | Azure OpenAI integration with caching support |

### Microsoft Graph (EF.MSGraph)

Add when the app calls Microsoft Graph APIs.

| Type | Package | Used For |
|---|---|---|
| `EF.MSGraph` client helpers | EF.MSGraph | Microsoft Graph API client and auth wiring |

---

## EF.Packages.Enterprise

**Feed:** `https://nuget.pkg.github.com/efreeman518/index.json` (same GitHub Packages feed, `EF.*` pattern mapping applies).

Enterprise packages are opt-in. Add them only when the project requires durable workflow orchestration or runtime filter expression building.

### Workflow Engine (EF.FlowEngine)

JSON-defined, durable workflow orchestration engine with pluggable backends (state store, locks, human tasks, outbox, circuit breaker).

**Core interfaces:**

| Type | Package | Used For |
|---|---|---|
| `IFlowEngine` | EF.FlowEngine | Main orchestration API: start, signal, resume, terminate, get status |
| `IWorkflowRegistry` | EF.FlowEngine | Workflow definition CRUD and status transitions |
| `IFlowClient` | EF.FlowEngine | Base contract for all execution clients |
| `IRequestResponseClient` | EF.FlowEngine | Synchronous HTTP/gRPC call nodes |
| `IQueryClient` | EF.FlowEngine | Data query nodes (EF Core via `EF.FlowEngine.Clients.Sql`) |
| `IMessageClient` | EF.FlowEngine | Async messaging nodes (Service Bus via `EF.FlowEngine.Clients.ServiceBus`) |
| `IAgentClient` | EF.FlowEngine | AI/LLM agent invocation nodes (OpenAI via `EF.FlowEngine.Clients.OpenAI`) |
| `IFlowEngineClient` | EF.FlowEngine | Cross-engine orchestration nodes |
| `IDistributedLockProvider` | EF.FlowEngine | Distributed locking (pluggable: SQL, Redis, Cosmos, Blob, InMemory) |
| `IExecutionStateStore` | EF.FlowEngine | Execution state persistence (pluggable: SQL, Redis, Cosmos, File) |
| `IHumanTaskStore` | EF.FlowEngine | Human task/approval management (pluggable: SQL, Redis, Cosmos) |
| `IOutboxStore` | EF.FlowEngine | Transactional outbox (pluggable: SQL) |
| `ICircuitBreakerStore` | EF.FlowEngine | Circuit breaker state (pluggable: SQL, Redis) |

**Key model types:**

| Type | Used For |
|---|---|
| `WorkflowDefinition` | Workflow schema (nodes + edges) |
| `NodeConfig` (and subtypes) | Per-node configuration: Decision, Fetch, Filter, Human, Loop, Parallel, Timer, Transform, Wait, Message, Agent, Document, etc. |
| `HumanTask` / `HumanTaskStatus` | Human approval/review task model |
| `OutboxEntry` / `OutboxEntryType` | Transactional outbox entry |
| `ExecStatus` | Execution status enum: Pending, Running, Completed, Failed, Suspended, Terminated |
| `DefinitionStatus` | Workflow definition status: Draft, Active, Archived |
| `FilterSet` / `SearchRequest` | Used by `IQueryClient` for declarative data queries |

**Built-in implementations (for testing/dev):**

| Type | Used For |
|---|---|
| `InMemoryWorkflowRegistry` | In-memory registry (unit tests / local dev) |
| `JsonFileWorkflowRegistry` | File-backed registry (local dev without DB) |
| `InMemoryDistributedLockProvider` | Single-process locking (unit tests) |
| `LoggerFlowEngineTelemetry` | Logging-based telemetry adapter |

**Pluggable backend packages:**

| Package | Purpose |
|---|---|
| `EF.FlowEngine.StateStore.Sql` | SQL-based execution state |
| `EF.FlowEngine.StateStore.Redis` | Redis-based execution state |
| `EF.FlowEngine.Locks.Sql` | SQL-based distributed locking |
| `EF.FlowEngine.Locks.Redis` | Redis-based distributed locking |
| `EF.FlowEngine.WorkflowRegistry.Sql` | SQL-backed workflow registry |
| `EF.FlowEngine.HumanTaskStore.Sql` | SQL-backed human task store |
| `EF.FlowEngine.Outbox.Sql` | SQL transactional outbox |
| `EF.FlowEngine.CircuitBreaker.Sql` | SQL circuit breaker state |
| `EF.FlowEngine.Clients.Http` | HTTP/REST client for `IRequestResponseClient` |
| `EF.FlowEngine.Clients.Sql` | EF Core client for `IQueryClient` |
| `EF.FlowEngine.Clients.ServiceBus` | Azure Service Bus client for `IMessageClient` |
| `EF.FlowEngine.Clients.OpenAI` | Azure OpenAI client for `IAgentClient` |
| `EF.FlowEngine.AdminApi` | REST management endpoints for workflow monitoring |
| `EF.FlowEngine.Testing` | Test helpers and fixtures |

### FlowEngine Data-Layout Variants

When `includeFlowEngine: true`, the integrator picks a `flowEngineDbStrategy`. The choice is **load-bearing** because FE's atomic-outbox guarantee depends on FE state + outbox living in the same DbContext / transaction scope.

| Variant | `flowEngineDbStrategy` | DB / Schema | Outbox guarantee | When to choose |
|---|---|---|---|---|
| **A** (default) | `same-db-separate-schema` | App DB, FE schema (`flowengine`), separate `__EFMigrationsHistory_FlowEngine` | **Atomic.** State save and outbox publish commit in one transaction. `message`/`integration`/`agent` nodes are exactly-effected once the workflow advances. | Default for any new scaffold. Operational simplicity wins. |
| **B** | `separate-db` | Dedicated FE database, FE schema | **Best-effort.** State and outbox are in the same FE DB so FE-internal atomicity holds - but cross-DB failure modes between FE and the app DB are no longer transactional from the app's perspective. | Compliance separation, independent scaling, or per-tenant FE isolation. |
| **C** | `separate-db` + cross-publisher relay | Dedicated FE database; FE `message` nodes routed through the app's existing at-least-once publisher | **Best-effort + relay** - degrades the same way as B, but the integrator wires FE outbox events to the app's transactional publisher to recover atomicity at the app boundary. | Variant B is required but cross-publisher relay is acceptable. |

**Failure mode in B/C.** A crash between FE state-save and FE outbox-publish is the same window FE closes for Variant A - but FE's atomic guarantee no longer extends across the app's boundary. Loss surface: `message`, `integration`, and `agent` node side effects. Not state.

**What the scaffold emits per variant.**

- Variant A: dedicated FE DbContext via interface composition (see [../skills/flowengine.md](../skills/flowengine.md)), FE schema constant, FE migration-history table constant, single connection string.
- Variant B/C: same DbContext shape, **separate connection string** (e.g., `ConnectionStrings:FlowEngine`), Aspire resource entry for the FE DB, and a warning entry in `HANDOFF.md` naming the outbox degradation. Variant C additionally requires the integrator to wire FE message nodes to the app's existing publisher - the scaffold emits a `// TODO: [CONFIGURE]` stub in `RegisterServices.FlowEngine.cs` where the relay would attach.

Record the choice (and, for B/C, the relay plan) in `.scaffold/DESIGN-DECISIONS.md`.

### Runtime Filter Builder (EF.FilterBuilder)

Translates declarative `FilterSet` JSON/objects into LINQ `Expression<Func<T, bool>>` at runtime. Use when API consumers or workflow steps need to specify query filters without server-side code changes.

| Type | Package | Used For |
|---|---|---|
| `FilterBuilder<T>` | EF.FilterBuilder | Converts `FilterSet` -> `Expression<Func<T, bool>>` |
| `FilterSet` | EF.FilterBuilder | Filter definition (recursive: Simple, Expression, Group) |
| `FilterSetType` | EF.FilterBuilder | Enum for filter node type |
| `SearchRequest` | EF.FilterBuilder | Paged search request with filters, sorts, and page settings |
| `SearchResponse<T>` | EF.FilterBuilder | Paginated search results |
| `Sort` | EF.FilterBuilder | Sort specification (property + direction) |
| `QueryableExtensions` | EF.FilterBuilder | `IQueryable<T>` extension methods for filter application |

### Testing (EF.Test.Unit, EF.Test.Integration)

| Type | Package | Used For |
|---|---|---|
| `UnitTestBase` | EF.Test.Unit | Base class for `Test.Unit` (mocked unit tests) |
| `IntegrationTestBase` | EF.Test.Integration | Base class with TestContainers + WebApplicationFactory; consumed by `Test.Endpoints`, `Test.E2E`, and `Test.Integration` |

**Naming asymmetry:** `EF.Test.Integration` is the EF package name and predates the project split; it provides the WebApplicationFactory base used by `Test.Endpoints` (per-endpoint contract), `Test.E2E` (workflow chains), and `Test.Integration` (service-level vs real external services). The package name is preserved for ecosystem compatibility.

---

## App-Level Types (NOT in EF.Packages)

These types appear in the service and endpoint templates but are **not provided by EF.Packages**. They must be created in the target project. Generate them during Phase 5b.

| Type | Where to Create | Used For |
|---|---|---|
| `DefaultRequest<T>` | Application.Models | Request wrapper for Create/Update service methods |
| `DefaultResponse<T>` | Application.Models | Response wrapper for Get/Create/Update service methods |
| `ApplicationStyle` / `ApplicationStyleResolver` | Application.Contracts | Runtime `Service` / `Cqrs` selector for `applicationStyle: switch`; reads `Application:Style` plus `<APP>_APPLICATION_STYLE` |
| `AppConstants` | Application.Contracts | Role names (ROLE_GLOBAL_ADMIN), cache names (DEFAULT_CACHE) |
| `ITenantBoundaryValidator` | Application.Contracts | Tenant boundary enforcement interface |
| `TenantBoundaryValidator` | Application.Services | Default implementation - GlobalAdmin bypass + tenant matching |
| `IEntityCacheProvider` | Application.Contracts | Abstraction for entity-level caching |
| `NoOpEntityCacheProvider` | Application.Services | No-op stub used until Phase 5c wires FusionCache |

> **Do not search EF.Packages for these types.** They are intentionally app-level to keep the shared library thin. The service template references them because every scaffolded project needs them.

---

## Phase Usage

- **5a:** EF.Common, EF.Domain, EF.Domain.Contracts, EF.Data, EF.Data.Contracts, EF.Common.Contracts
- **5b:** EF.AspNetCore, EF.Host, EF.FilterBuilder, EF.Cache, EF.CQRS when `applicationStyle` is `cqrs` or `switch`, optional auth/key vault packages
- **5c:** EF.BackgroundServices and messaging packages when enabled
- **5d:** EF.Test.Unit and EF.Test.Integration
- **5e:** EF.Auth and optional EF.MSGraph; EF.AzureOpenAI or EF.OpenAI (when AI in scope)

---

## Rules

- **Never regenerate types that exist in EF.Packages.** Check this reference before creating base classes, result types, or repository interfaces.
- All EF.Packages target the latest stable .NET TFM. Match the target app's TFM to the EF.Packages release in use.
- Packages use **central package management** - pin versions only in `Directory.Packages.props`.
- Private feed must be in `nuget.config` with `<packageSourceMapping>` entries for `EF.*` packages.
- Project files must not put `Version="..."` on `EF.*` `<PackageReference>` entries.
- If source contains local definitions for `EntityBase`, `RepositoryBase`, `DbContextBase`, `Result`, `PagedResponse`, `SearchRequest`, `IRequestContext`, `IInternalMessageBus`, or `IMessageHandler`, stop and replace them with package references.
