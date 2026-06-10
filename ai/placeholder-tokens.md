# Placeholder Token Glossary

When generating code from templates and skill files, substitute these placeholder tokens with the actual values from the user's domain inputs. This glossary is the canonical reference for all tokens.

## Token Definitions

| Token | Source | Notes |
|-------|--------|-------|
| `{Project}` | `ProjectName` | Primary project and namespace prefix. Renders empty as a name prefix when `projectNamePrefix: none` (see Derivation Rule 8). |
| `{ProjectName}` | `ProjectName` | Markdown/document templates that should display the full project name. Always the literal `ProjectName`, never collapsed. Prefer `{Project}` for code templates. |
| `{Org}` | `OrganizationName` | Optional org prefix. If present (and `projectNamePrefix: solution-name`), full namespace becomes `{Org}.{Project}`. Not applied when `projectNamePrefix: none`. |
| `{App}` | Derived from `{Project}` | Application type prefix. Used in `{App}DbContextTrxn` and `{App}DbContextQuery`. Renders empty when `projectNamePrefix: none` (-> `DbContextTrxn` / `DbContextQuery`). |
| `{Host}` | Derived from `{Project}` or `{Org}.{Project}` | Host project prefix. Used in `{Host}.Api`, `{Host}.Gateway`, `{Host}.Scheduler`. Renders empty as a name prefix when `projectNamePrefix: none`. |
| `{Entity}` | Entity `name` | Entity class, file, and method name. |
| `{entity}` | Entity `name` with lower first character | Local variables, parameters, route values. |
| `{Entities}` | Pluralized entity name | Display and feature grouping name. |
| `{EntityPlural}` | Pluralized entity name | Alias of `{Entities}` used in CQRS feature namespaces (`{Project}.Application.Cqrs.Features.{EntityPlural}`). Same derivation as `{Entities}`. |
| `{entities}` | Lower-cased pluralized entity name | URL path or collection variable. |
| `{entity-route}` | Kebab-cased entity name | URL-safe route segment. |
| `{ChildEntity}` | Child entity `name` | Child entity class name. |
| `{childEntity}` | Child entity `name` with lower first character | Child variables and parameters. |
| `{ChildEntity}s` | Pluralized child entity name | Default child collection property. |
| `{Children}` | Child collection name | Use when the collection name differs from `{ChildEntity}s`. |
| `{Feature}` | Defaults to `{Entities}` | Uno feature folder/service grouping. |
| `{Gateway}` | Same as `{Host}` | Compose gateway project name as `{Gateway}.Gateway`. |
| `{SolutionName}` | Derived from `{Org}.{Project}` or `{Project}` | `.slnx` file name and solution prefix. **Always** derived this way - never collapsed by `projectNamePrefix`, so the solution file stays `{Project}.slnx` even when project names are bare. |
| `{entra-tenant-id}` | `authProvider` config | Azure Entra tenant GUID. |
| `{api-client-id}` | `authProvider` config | API app registration client ID. |
| `{Agent}` | Agent `name` | Agent class/service prefix. |
| `{agent-route}` | Kebab-cased agent name | Agent endpoint route segment. |
| `{Tool}` | Tool or function name | AI function tool class name. |
| `{SearchIndex}` | Search config index name | Azure AI Search index name. |
| `{ValueObject}` | Phase 1 language artifact | Value object term accepted in `.scaffold/UBIQUITOUS-LANGUAGE.md`. |
| `{Role}` | Phase 1 language artifact | Actor or authorization role term accepted in `.scaffold/UBIQUITOUS-LANGUAGE.md`. |
| `{State}` | Phase 1 language artifact | Lifecycle state term accepted in `.scaffold/UBIQUITOUS-LANGUAGE.md`. |
| `{PolicyName}` | Phase 1 language artifact | Domain policy/rule term accepted in `.scaffold/UBIQUITOUS-LANGUAGE.md`. |
| `{ExternalSystem}` | Phase 1 language artifact | External system term accepted in `.scaffold/UBIQUITOUS-LANGUAGE.md`. |

## Casing Conventions

> **Naming conflicts:** Avoid entity names that collide with C# framework types. Canonical list and safe alternatives: [domain-specification-schema.md - Entities section](domain-specification-schema.md#entities).

| Convention | Rule | Example |
|------------|------|---------|
| **PascalCase** | First letter of each word capitalized, no separators | `TodoItem`, `TeamMember` |
| **camelCase** | First letter lowercase, subsequent words capitalized | `todoItem`, `teamMember` |
| **kebab-case** | All lowercase, words separated by hyphens | `todo-item` |
| **UPPER_SNAKE** | All uppercase, words separated by underscores | Used only in environment variables, not in tokens |

## Derivation Rules

1. **`{App}` = `{Project}`** - always identical. Use `{App}` when the context is the application namespace (e.g., `{App}DbContextTrxn`). Use `{Project}` when the context is the project/solution name.
2. **`{Host}`** - if `OrganizationName` is provided: `{Org}.{Project}`. Otherwise: `{Project}`.
3. **`{Gateway}`** - same as `{Host}`. Compose the gateway project name as `{Gateway}.Gateway`.
4. **`{Feature}`** - defaults to `{Entities}` (plural entity name) unless explicitly provided. Groups UI services and models into feature folders (e.g., `Services/TodoItems/`).
5. **Pluralization** - use standard English pluralization rules. `TodoItem` -> `TodoItems`, `Category` -> `Categories`, `Reminder` -> `Reminders`.
6. **Route segments** - for URL paths, use the lowercase/kebab-case form. Multi-word entities: `TodoItem` -> `todo-item`, `TeamMember` -> `team-member`.
7. **Aspire project references** - In `AppHost/AppHost.cs`, `builder.AddProject<Projects.X>()` uses the C# identifier form of the `.csproj` path, where dots and hyphens become underscores. For example: project `TaskFlow.Api` -> `Projects.TaskFlow_Api`. This is automatic - just be aware when reading or writing AppHost code.
8. **`projectNamePrefix`** (Phase 1 `domain-specification.yaml`, default `solution-name`) - decides whether `{Project}`, `{Host}`, `{Gateway}`, and `{App}` carry the prefix when used as a **name prefix** (project name, folder, root namespace, or type-name prefix).
   - `solution-name` (default): every rule above applies unchanged. Layout matches the reference app - `{Project}.Domain.Model`, `{Host}.Api`, `{Gateway}.Gateway`, `{App}DbContextTrxn`.
   - `none`: as a name prefix, `{Project}.`, `{Host}.`, and `{Gateway}.` render as empty and `{App}` renders as empty. Projects, folders, and root namespaces become bare: `Domain.Model`, `Application.Services`, `Infrastructure.Data`, `Api`, `Bootstrapper`, `DbContextTrxn`, `DbContextQuery`. `OrganizationName` / `{Org}` is **not** applied. **Unaffected by `none`:** `{SolutionName}` (the `.slnx` is still `{Project}.slnx`, or `{Org}.{Project}.slnx` if an org was given) and `{ProjectName}` in document templates. Caveat: bare top-level namespaces are generic and can collide when an assembly is consumed alongside other solutions - acceptable per the Phase 1 decision, but record it.

---

## File Naming Conventions

Canonical file name patterns for generated artifacts. Use these consistently across all generated code.

| Artifact | Pattern |
|---|---|
| Entity | `{Entity}.cs` |
| EF config | `{Entity}Configuration.cs` |
| Write repo | `{Entity}RepositoryTrxn.cs` |
| Read repo | `{Entity}RepositoryQuery.cs` |
| Repo interface | `I{Entity}RepositoryTrxn.cs` / `I{Entity}RepositoryQuery.cs` |
| Updater | `{Entity}Updater.cs` |
| DTO | `{Entity}Dto.cs` |
| Search filter | `{Entity}SearchFilter.cs` |
| Mapper | `{Entity}Mapper.cs` |
| Service | `{Entity}Service.cs` |
| Service interface | `I{Entity}Service.cs` |
| Endpoint | `{Entity}Endpoints.cs` |
| Message handler | `{Event}Handler.cs` |
| Health check | `{Target}HealthCheck.cs` |
| Settings POCO | `{Entity}ServiceSettings.cs` |
| Structure validator | `{Entity}StructureValidator.cs` |
| Domain rules | `Rules/{RuleName}Rule.cs` |
| Dockerfile | `Dockerfile` |

---

## Canonical Event And Publisher Naming

Use these defaults when scaffolding event-driven flows:

1. Cross-process event payloads are integration contracts.
2. Place transport payload records in `Application.Contracts.Events`.
3. Use `IIntegrationEventPublisher` as the publish abstraction for external buses.
4. Name publisher implementations by transport, for example `ServiceBusIntegrationEventPublisher` and `NoOpIntegrationEventPublisher`.
5. Reserve `Domain.*` events for aggregate-local invariants and in-process domain dispatch.
6. Do not name external publisher abstractions as `IDomainEventPublisher`.

Default naming patterns:

| Artifact | Pattern |
|---|---|
| Integration event contract | `{Entity}{Action}Event` (in `Application.Contracts.Events`) |
| Integration publisher interface | `IIntegrationEventPublisher` |
| Service Bus publisher | `ServiceBusIntegrationEventPublisher` |
| No-op publisher | `NoOpIntegrationEventPublisher` |
