# Quick Reference - Cheat Sheet

High-signal lookup for structure, dependencies, DI patterns, and common routes/config keys during scaffolding.

> **File naming conventions** are in [../ai/placeholder-tokens.md](../ai/placeholder-tokens.md#file-naming-conventions).
> **Tech-design diagrams** (`docs/tech-design.md`, `docs/tech-design.html`) follow the source-plus-SVG pattern - see [tech-design-diagrams.md](tech-design-diagrams.md).

---

## Core Project Map

| Project | Namespace | Location |
|---|---|---|
| `{Host}.Api` | `{Host}.Api` | `src/Host/{Host}.Api/` |
| `{Gateway}.Gateway` | `{Gateway}.Gateway` | `src/Host/{Gateway}.Gateway/` |
| `{Host}.Scheduler` | `{Host}.Scheduler` | `src/Host/{Host}.Scheduler/` |
| `{Host}.Bootstrapper` | `{Host}.Bootstrapper` | `src/Host/{Host}.Bootstrapper/` |
| `{Host}.BackgroundServices` | `{Host}.BackgroundServices` | `src/Host/{Host}.BackgroundServices/` |
| `{Host}.UI` | `{Host}.UI` | `src/UI/{Host}.UI/` |
| `{App}.Functions` | `{App}.Functions` | `src/Host/{App}.Functions/` |
| `Domain.*` | `Domain.*` | `src/Domain/` |
| `Application.*` | `Application.*` | `src/Application/` |
| `Infrastructure.*` | `Infrastructure.*` | `src/Infrastructure/` |
| `Aspire.*` | `Aspire.*` | `src/Host/Aspire/` |
| `Test.*` | `Test.*` | `tests/` |

---

## Core Package Roles

| Package | Primary Purpose |
|---|---|
| `EF.Domain` | entities, tenant contracts, domain result primitives |
| `EF.Domain.Contracts` | DTO/domain result contracts |
| `EF.Data` | EF repo/config base abstractions |
| `EF.Common` | `Result`, helpers, predicates |
| `EF.Common.Contracts` | request context, paging/search contracts |
| `EF.BackgroundServices` | internal message bus, handlers, background queue |
| `EF.Host` | host startup/task abstractions |

---

## Event Taxonomy (Do Not Mix)

| Event Type | Layer | Transport | Naming/Contract |
|---|---|---|---|
| Domain event | `Domain.*` | In-process only | Raised from aggregate invariants |
| Integration event | `Application.Contracts.Events` | Cross-process bus (Service Bus/Event Grid) | Published through `IIntegrationEventPublisher` |

Rules:
- If a message crosses process boundaries, define it in `Application.Contracts.Events`.
- Do not keep bus payload records under `Domain.*.Events`.
- Keep event serializer payloads transport-stable (avoid domain-only navigation/value object coupling).

---

## Base Type Lookup

| Type | Purpose |
|---|---|
| `EntityBase` | common Id + rowversion base entity |
| `ITenantEntity<TTenantId>` | tenant ownership contract |
| `DomainResult<T>` | domain-level success/failure monad |
| `EntityBaseConfiguration<TEntity, TId>` | base EF configuration rules |
| `RepositoryBase<TContext, TAuditId, TTenantId>` | common repository operations |
| `IRequestContext<TAuditId, TTenantId>` | scoped audit/tenant/role context |
| `IInternalMessageBus` | internal publish/subscribe pipeline |
| `IMessageHandler<T>` | event handler contract |

**RequestContext constructor order:** `new RequestContext<string, Guid?>(correlationId, auditId, tenantId, roles)`. Canonical signature: [ef-packages-reference.md](ef-packages-reference.md) (GR-14).

---

## DI + Bus Wiring Pattern

Keep registrations in `RegisterServices.cs` under Bootstrapper:

```csharp
private static IServiceCollection AddSupportServices(this IServiceCollection services)
{
    services.AddChannelBackgroundTaskQueueWithShutdownHandling();
    services.AddSingleton<IInternalMessageBus, InternalMessageBus>();
    return services;
}

private static void AddApplicationServices(IServiceCollection services)
{
    services.AddScoped<I{Entity}Service, {Entity}Service>();
    services.AddScoped<IMessageHandler<{EventName}>, {EventName}Handler>();
    services.AddSingleton<IIntegrationEventPublisher, ServiceBusIntegrationEventPublisher>();
}

public static void AutoRegisterMessageHandlers(this IHost host)
{
    var msgBus = host.Services.GetRequiredService<IInternalMessageBus>();
    msgBus.AutoRegisterHandlers(host.Services, typeof({EventName}Handler).Assembly);
}
```

Call `AutoRegisterMessageHandlers()` after `Build()`. `AuditInterceptor` publishes through `IInternalMessageBus`, and that bus dispatches through the channel background queue rather than inline.
```

---

## Endpoint Pattern

Canonical generated routes, handlers, and registration shape: [endpoint-template.md](../templates/endpoint-template.md). Host-owned versioning, group authorization, binding/error policy, and service/CQRS route switching: [api.md](../skills/api.md).

---

## DbContext Reminder

Both contexts define the same `DbSet<{Entity}>`; query context is configured for no-tracking.

---

## Aspire AppHost Pattern

Minimal shape - each pooled DbContext gets its own `WithReference(..., connectionName:)`, Redis is `Redis1`, and the migrator completes before DB-touching hosts:

```csharp
var api = builder.AddProject<Projects.{Host}_Api>("{host}api")
    .WithReference(db, connectionName: "{Project}DbContextTrxn")
    .WithReference(db, connectionName: "{Project}DbContextQuery")
    .WithReference(redis, connectionName: "Redis1")
    .WaitForCompletion(migrator)
    .WithExternalHttpEndpoints();
```

Use underscores in `Projects.{Host}_Api` style identifiers. Canonical full graph (SQL/Redis params, migrator, Scheduler, Gateway, Vite, rules): [../patterns/infrastructure-wiring.md](../patterns/infrastructure-wiring.md) section Aspire Resource Wiring.

---

## Local Explorer Tool Install Cheat Sheet

> **Subject to change.** Vendor URLs, install paths, and UI flows drift. Verified at the date stamped in repo history; re-confirm before publishing scaffold output. Tool versions, marketplace names, and bundle structures change without notice.

Tools below are the **recommended human-facing inspectors** for each local Aspire resource. The agent does not install these - the human developer does, once per workstation.

| Tool | Inspects | Vendor URL | Install | First connect |
|---|---|---|---|---|
| **VS Code SQL extension (`mssql`)** | SQL Server | [marketplace.visualstudio.com/items?itemName=ms-mssql.mssql](https://marketplace.visualstudio.com/items?itemName=ms-mssql.mssql) | VS Code Extensions view -> search `mssql` -> Install | Activity Bar SQL icon -> Add Connection -> `localhost,38433` / SQL Login / `sa` / `{sql-password}` |
| **Microsoft Azure Storage Explorer** | Azurite (Blob/Queue/Table) | [azure.microsoft.com/products/storage/storage-explorer](https://azure.microsoft.com/en-us/products/storage/storage-explorer/) | Download installer for your OS -> run | Auto-detects Azurite on default ports `10000`/`10001`/`10002` under Local & Attached -> Storage Accounts -> Emulator (Default Ports). Manual: plug icon -> Local storage emulator. HTTPS Azurite requires importing the self-signed cert via Edit -> SSL Certificates. |
| **RedisInsight (Aspire-managed)** | Redis | Bundled - no install | `WithRedisInsight(...)` in AppHost - container ships with Aspire | Open `http://localhost:5540`. Aspire pre-wires the Redis connection - no manual setup. |
| **Messentra** | Service Bus emulator | [messentra.com](https://www.messentra.com/) | Download installer for your OS (Win/macOS/Linux) | Options -> add connection with `Endpoint=sb://localhost;...;UseDevelopmentEmulator=true;` -> save -> Explorer `+` -> select saved connection |
| **Cosmos Data Explorer** | Cosmos preview emulator | Bundled - no install | `WithDataExplorer(1234)` in AppHost - served from the emulator | Open `http://localhost:1234`. If it spins, check Cosmos resource health first - the explorer comes from the emulator itself. |

**Connection-string defaults** (full forms in [../skills/aspire.md](../skills/aspire.md) -> *Local Explorer Tooling*):

- Azurite: `UseDevelopmentStorage=true` (or the full `DefaultEndpointsProtocol=http;AccountName=devstoreaccount1;...` string)
- Service Bus SDK: `Endpoint=sb://localhost;...;UseDevelopmentEmulator=true;`
- Service Bus admin client: `Endpoint=sb://localhost:5300;...;UseDevelopmentEmulator=true;`
- SQL host: `Server=localhost,38433;Database={project}db;User Id=sa;Password={sql-password};Encrypt=True;TrustServerCertificate=True;`

---

## Local Explorer Ports (Non-Test Runs)

Pinned ports for local Aspire runs (SQL `38433`, Redis `6379`, RedisInsight `5540`, Azurite `10000`/`10001`/`10002`, Service Bus AMQP `5672` / management `5300`, Cosmos gateway `8081` / Data Explorer `1234`). Tests use dynamic ports - gate via `if (!isTesting)`. Canonical matrix with per-resource decision rules: [../skills/aspire.md](../skills/aspire.md) -> *Local Explorer Tooling*.

---

## Common Config Keys

| Key | Purpose |
|---|---|
| `ConnectionStrings:{App}DbContextTrxn` | SQL write connection |
| `ConnectionStrings:{App}DbContextQuery` | SQL read/query connection |
| `ConnectionStrings:Redis1` | cache/backplane connection |
| `Gateway_EntraExt` | gateway auth config |
| `Api_EntraID` | API auth config |
| `ServiceAuth:{clusterId}` | service-to-service token config |
| `CacheDurations` | cache TTL settings |
| `OpenApiSettings:Enable` | OpenAPI docs toggle |
