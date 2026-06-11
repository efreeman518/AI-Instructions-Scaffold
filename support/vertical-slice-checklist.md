# Vertical Slice - Generated Files Checklist

Use this checklist after generating a new entity slice to ensure no required files or wiring steps were missed.

Placeholder tokens: [../ai/placeholder-tokens.md](../ai/placeholder-tokens.md).

---

## Add Entity to Existing Project - Fast Path

Use this when adding a new entity to an **already-scaffolded** solution. Skip full phase loading - load only what the slice needs.

### Pre-Flight

- [ ] Solution builds clean: `dotnet build`
- [ ] Identify existing: `RegisterServices.cs`, `{App}DbContextTrxn`, `{App}DbContextQuery`, `WebApplicationBuilderExtensions.cs`
- [ ] Confirm `scaffoldMode` and `testingProfile` from `.scaffold/resource-implementation.yaml`
- [ ] If this slice introduces a new domain term, role, event, custom action, or design decision, append it to `.scaffold/UBIQUITOUS-LANGUAGE.md` / `.scaffold/DESIGN-DECISIONS.md` and update `.scaffold/domain-specification.yaml` **before** generating code (see [../README.md](../README.md) section Phase-1 Artifact Lifecycle)
- [ ] Scan `.scaffold/*` for `[OPEN QUESTION: ...]` markers (**GR-10**) within the slice's entity scope; halt the slice if any blocking marker remains, or downgrade to a non-blocking deferred decision before generation
- [ ] Inspect existing neighboring slices before asking questions. If the code answers naming, folder placement, route shape, or DI pattern, follow the code and record only assumptions that affect generated artifacts.
- [ ] For each assumption, record evidence, risk if wrong, confidence, and outcome in `.scaffold/DESIGN-DECISIONS.md` section Assumptions.
- [ ] Trace the slice before generation: accepted language term -> `domain-specification.yaml` entity/action/rule -> `resource-implementation.yaml` store/host/dependency -> test category.
- [ ] **Classify the entity (GR-15): aggregate root or internal child?** An aggregate root has its own identity/lifecycle and is referenced by id (full slice). An internal child (1:N owned or M:N junction that only exists inside one root - e.g. a comment or checklist item on a task) gets a **reduced slice**: no standalone create/update/delete command, handler, service write method, or write endpoint. Its writes flow through the root's `Add*`/`Remove*` methods, the `{Root}Updater`, and nested sub-resource routes on the root. See [../skills/domain-model.md](../skills/domain-model.md) section Aggregate Roots vs Internal Children.

### Load Set for Slice

1. `ai/SKILL.md` (base reference)
2. `ai/placeholder-tokens.md`
3. Backend templates: `entity-template.md`, `ef-configuration-template.md`, `repository-template.md`, `data-mapping-template.md`, `service-template.md`, `endpoint-template.md`, `structure-validator-template.md`
4. If `applicationStyle` is `cqrs` or `switch`: `cqrs-handler-template.md`, `cqrs-endpoint-template.md`, `cqrs-validation-template.md`, `test-templates-cqrs.md`
5. If domain rules needed: `domain-rules-template.md`
6. **If child collections (1:N owned or M:N junction): `updater-template.md` is required** - the repository's `UpdateFromDto` delegates to a DbContext extension method that uses `CollectionUtility.SyncCollectionWithResult` to add/update/remove children in one call. Without this, aggregate edits silently drop client-side removals.
7. Test templates per profile (see section Test Slice below): `test-templates-domain.md`, `test-templates-repository.md`, `test-templates-service.md`, `test-templates-endpoint.md`, and for balanced+ profiles `test-templates-integration.md` + `test-templates-e2e.md`
8. If Uno UI enabled: `uno-mvux-model-template.md`, `uno-xaml-page-template.md`, `uno-ui-client-layer.md`
9. If Blazor UI enabled: `skills/ui-blazor.md` - add a Refit method group, entity list page, and entity new/edit page
10. If React UI enabled: `skills/ui-react.md` - add API hooks, entity list page, detail/edit page, and form components

### Slice Execution Order

> **Internal-child branch (GR-15):** if the Pre-Flight classification marked this entity an internal child of an aggregate root, generate steps 1-3 and 5-8 (entity, EF config, DbSet, updater wiring on the root, DTO, mapper), add `Add{Child}`/`Remove{Child}` (or `AssociateTag`/`RemoveTag`) methods to the **root** entity, and **skip** the standalone write artifacts in steps 9-14 (structure validator for writes, service write methods, CQRS create/update/delete requests+handlers+registrations, and the standalone CRUD endpoint). Instead add nested sub-resource routes to the root's endpoint(s): `POST/PUT/DELETE /{roots}/{id}/{children}[/{childId}]` (and `POST/DELETE /{roots}/{id}/tags/{tagId}` for a junction), whose handlers/service methods load the root, call its domain method, and save. Optionally keep a read-only query (`GetById`/`Search`) + query endpoint for the child. The steps below are the full aggregate-root path.

1. Create entity + enum/flags in `Domain.Model`
2. Create EF configuration in `Infrastructure.Data`
3. Add `DbSet<{Entity}>` to both DbContexts
4. Repositories (per `repositoryContractStyle`, default `hybrid`): a **generic-coverable** entity (join / append-only / simple CRUD) needs **no** per-entity repo - it resolves the already-registered open-generic `IRepositoryTrxn<{Entity}>` / `IRepositoryQuery<{Entity}>`. A **bespoke** entity (multi-include loads, `UpdateFromDto`, paged `Search`, polymorphic/hierarchy queries) gets a per-entity interface + impl (Trxn and/or Query); a split aggregate may use the generic Trxn plus a bespoke Query that extends `IRepositoryQuery<{Entity}>`. Under `per-entity` style, always create both. See [repository-template.md](../templates/repository-template.md) -> Generic Repository Pair.
5. **If child collections: create `{Entity}Updater.cs` under `Infrastructure.Repositories/Updaters/`** - DbContext extension method using `CollectionUtility.SyncCollectionWithResult`. Repository's `UpdateFromDto` delegates here.
6. Create DTO + SearchFilter in `Application.Models`
7. Create mapper in `Application.Mappers` (canonical `Projection` + compiled `ToDto` + `ToEntity`; child collections inlined in `Projection` - EF can't translate child `.ToDto()` calls)
8. Add a method to `MapperProjectionParityTests.cs` for the new mapper
9. Create StructureValidator in `Application.Services/Rules`
10. Create service + interface (use `repoTrxn.UpdateFromDto(entity, dto, RelatedDeleteBehavior.RelationshipAndEntity)` in `UpdateAsync` for aggregate roots so client-side child removals hard-delete)
11. If `applicationStyle` is `cqrs` or `switch`: create `Application.Cqrs/Features/{Entity}/` requests, handlers, optional command validators, structure validator, and `{Entity}CqrsRegistrations`; keep small helpers in `Application.Cqrs/Features/Shared/`
12. If `applicationStyle` is `cqrs` or `switch`: keep DTOs and mappers shared by default, matching TaskFlow; for CQRS-only feature contracts, consolidate feature-specific models, mappers, projections, validators, and handlers under `Application.Cqrs/Features/{Entity}`
13. Create endpoint
14. If `applicationStyle` is `cqrs` or `switch`: create `Endpoints/Cqrs/{Entity}CqrsEndpoints.cs` with the same route templates and DTO envelopes as the service endpoint
15. Wire DI in `RegisterServices.cs` (repos + service, plus CQRS application registration when enabled)
16. Map endpoints in `WebApplicationBuilderExtensions.cs`; for `switch`, map only service or CQRS routes based on `ApplicationStyleResolver`
17. Run migration: `dotnet ef migrations add Add{Entity} ...`
18. Write one vertical tracer test through the public contract or endpoint, confirm red, implement to green, then expand remaining tests in the order matching the profile: Unit -> Endpoint -> Integration (real SQL via a standalone Testcontainer in `Test.Integration`) -> E2E (multi-endpoint workflow).

### Wiring Checklist

- [ ] `DbSet<{Entity}>` added to `{App}DbContextTrxn` and `{App}DbContextQuery`
- [ ] Repos + service registered in `RegisterServices.cs`
- [ ] `Map{Entity}Endpoints()` called in `WebApplicationBuilderExtensions.cs`
- [ ] If `applicationStyle` is `cqrs` or `switch`: CQRS feature registration is included in `CqrsHandlerRegistrationCatalog`
- [ ] If `applicationStyle` is `cqrs` or `switch`: shared DTO/mapper placement is intentional, or feature-specific DTO/mapper placement is consolidated under `Application.Cqrs/Features/{Entity}`
- [ ] If `applicationStyle` is `switch`: `WebApplicationBuilderExtensions.cs` maps exactly one CRUD endpoint set at runtime
- [ ] **[Multi-tenant only]** `ITenantBoundaryValidator` registered (once, not per entity)
- [ ] Aspire AppHost updated (only if new project added to solution)

### Validation

Gate commands: [execution-gates.md](execution-gates.md) section Core Loop. Scope test filter to the new entity (`FullyQualifiedName~{Entity}`). For recurring test failures, see [troubleshooting.md](troubleshooting.md).

### Prompt Pattern

```
Add a new {Entity} vertical slice to the existing {Project} solution.
Follow vertical-slice-checklist.md fast-path.
```

---

## Slice Modes

- **Single-entity slice**: one primary entity with local relationships.
- **Composite slice**: one feature spanning multiple coupled entities/stores.

Use composite mode when business behavior cannot be completed safely as one isolated entity (for example order + reservation + refund, entitlement + purchase + content visibility).

---

## Backend Slice (Required)

> The table below is the **aggregate-root** slice. For an **internal child** (GR-15), keep the Domain entity, EF config, optional updater, DTO/SearchFilter, and mapper rows; keep the structure validator and repository/service/CQRS/endpoint rows only for **reads** (`GetById`/`Search`). Drop the create/update/delete handlers, service write methods, and standalone write endpoint - those operations become nested sub-resource routes on the aggregate root's endpoint instead.

For entity `{Entity}`:

| Layer | File Path | Template | Required |
|---|---|---|---|
| Domain | `src/Domain/{Project}.Domain.Model/Entities/{Entity}.cs` | [entity-template.md](../templates/entity-template.md) | yes |
| Domain (optional) | `src/Domain/{Project}.Domain.Model/Enums/{Entity}Status.cs` | - | if flags/status enum used |
| Domain (optional) | `src/Domain/{Project}.Domain.Model/Rules/{Entity}Rules.cs` | [domain-rules-template.md](../templates/domain-rules-template.md) | if rules/state machine/policy matrix used |
| Domain (optional) | `src/Domain/{Project}.Domain.Model/Rules/{Entity}*TransitionRule.cs` | [domain-rules-template.md](../templates/domain-rules-template.md) | if state transitions are constrained |
| Data | `src/Infrastructure/{Project}.Infrastructure.Data/EntityConfigurations/{Entity}Configuration.cs` | [ef-configuration-template.md](../templates/ef-configuration-template.md) | yes |
| Data | `src/Infrastructure/{Project}.Infrastructure.Repositories/{Entity}RepositoryTrxn.cs` | [repository-template.md](../templates/repository-template.md) | bespoke writes only (else generic pair) |
| Data | `src/Infrastructure/{Project}.Infrastructure.Repositories/{Entity}RepositoryQuery.cs` | [repository-template.md](../templates/repository-template.md) | bespoke reads only (else generic pair) |
| Data (optional) | `src/Infrastructure/{Project}.Infrastructure.Repositories/Updaters/{Entity}Updater.cs` | [updater-template.md](../templates/updater-template.md) | if child collections |
| App | `src/Application/{Project}.Application.Models/{Entity}/{Entity}Dto.cs` | [data-mapping-template.md](../templates/data-mapping-template.md) | yes |
| App | `src/Application/{Project}.Application.Models/{Entity}/{Entity}SearchFilter.cs` | [data-mapping-template.md](../templates/data-mapping-template.md) | yes |
| App | `src/Application/{Project}.Application.Contracts/Services/I{Entity}Service.cs` | [service-template.md](../templates/service-template.md) | yes |
| App | `src/Application/{Project}.Application.Contracts/Repositories/I{Entity}RepositoryTrxn.cs` | [repository-template.md](../templates/repository-template.md) | bespoke writes only (`per-entity`: always) |
| App | `src/Application/{Project}.Application.Contracts/Repositories/I{Entity}RepositoryQuery.cs` | [repository-template.md](../templates/repository-template.md) | bespoke reads only (`per-entity`: always) |
| App | `src/Application/{Project}.Application.Contracts/Mappers/{Entity}Mapper.cs` | [data-mapping-template.md](../templates/data-mapping-template.md) | yes |
| App | `src/Application/{Project}.Application.Services/Services/{Entity}Service.cs` | [service-template.md](../templates/service-template.md) | yes |
| App (optional) | `src/Application/{Project}.Application.Services/Validators/{Entity}Validator.cs` | - | if custom validator used |
| App (CQRS) | `src/Application/{Project}.Application.Cqrs/Features/{Entity}/{Entity}Requests.cs` | [cqrs-handler-template.md](../templates/cqrs-handler-template.md) | if cqrs or switch |
| App (CQRS) | `src/Application/{Project}.Application.Cqrs/Features/{Entity}/{Entity}Handlers.cs` | [cqrs-handler-template.md](../templates/cqrs-handler-template.md) | if cqrs or switch |
| App (CQRS) | `src/Application/{Project}.Application.Cqrs/Features/{Entity}/{Entity}CqrsRegistrations.cs` | [cqrs-handler-template.md](../templates/cqrs-handler-template.md) | if cqrs or switch |
| App (CQRS optional) | `src/Application/{Project}.Application.Cqrs/Features/{Entity}/{Entity}CommandValidators.cs` | [cqrs-validation-template.md](../templates/cqrs-validation-template.md) | if command validators used |
| App (CQRS shared) | `src/Application/{Project}.Application.Cqrs/Features/Shared/CqrsHandlerSupport.cs` | [cqrs-handler-template.md](../templates/cqrs-handler-template.md) | if cqrs or switch |
| App (CQRS shared) | `src/Application/{Project}.Application.Cqrs/Registration/CqrsApplicationRegistration.cs` | [cqrs-handler-template.md](../templates/cqrs-handler-template.md) | if cqrs or switch |
| API | `src/Host/{Host}.Api/Endpoints/{Entity}Endpoints.cs` | [endpoint-template.md](../templates/endpoint-template.md) | yes |
| API (CQRS) | `src/Host/{Host}.Api/Endpoints/Cqrs/{Entity}CqrsEndpoints.cs` | [cqrs-endpoint-template.md](../templates/cqrs-endpoint-template.md) | if cqrs or switch |

---

## Required Wiring Updates

| File | Required Update |
|---|---|
| `src/Host/{Host}.Bootstrapper/RegisterServices.cs` | register repos + service (+ validators if used) |
| `src/Host/{Host}.Api/WebApplicationBuilderExtensions.cs` | add `Map{Entity}Endpoints()` |
| `src/Application/{Project}.Application.Cqrs/Registration/CqrsHandlerRegistrationCatalog.cs` | aggregate `{Entity}CqrsRegistrations` when cqrs or switch |
| `src/Host/{Host}.Api/WebApplicationBuilderExtensions.cs` | add CQRS route switch when `applicationStyle: switch` |
| `src/Infrastructure/{Project}.Infrastructure.Data/{App}DbContextTrxn.cs` | add `DbSet<{Entity}>` |
| `src/Infrastructure/{Project}.Infrastructure.Data/{App}DbContextQuery.cs` | add `DbSet<{Entity}>` |

Migration command:

```bash
dotnet ef migrations add Add{Entity} --project src/Infrastructure/{Project}.Infrastructure.Data --startup-project src/Host/{Host}.Api
```

---

## Test Slice (Recommended)

| File Path | Template | Profile |
|---|---|---|
| `src/Test/Test.Unit/Domain/{Entity}Tests.cs` | [test-templates-domain.md](../templates/test-templates-domain.md) | all |
| `src/Test/Test.Unit/Domain/{Entity}RulesTests.cs` (when rules exist) | [test-templates-domain.md](../templates/test-templates-domain.md) | all |
| `src/Test/Test.Unit/Services/{Entity}ServiceTests.cs` | [test-templates-service.md](../templates/test-templates-service.md) | all |
| `src/Test/Test.Unit/Repositories/{Entity}RepositoryTrxnTests.cs` | [test-templates-repository.md](../templates/test-templates-repository.md) | all |
| `src/Test/Test.Unit/Repositories/{Entity}RepositoryQueryTests.cs` | [test-templates-repository.md](../templates/test-templates-repository.md) | all |
| `src/Test/Test.Unit/Mappers/{Entity}MapperTests.cs` | [test-templates-service.md](../templates/test-templates-service.md) | all |
| `src/Test/Test.Unit/Mappers/MapperProjectionParityTests.cs` (add a method per entity) | [test-templates-service.md](../templates/test-templates-service.md) | all |
| `src/Test/Test.Endpoints/Endpoints/{Entity}EndpointsTests.cs` | [test-templates-endpoint.md](../templates/test-templates-endpoint.md) | all |
| `src/Test/Test.Unit/Cqrs/{Entity}CqrsValidationTests.cs` | [test-templates-cqrs.md](../templates/test-templates-cqrs.md) | if cqrs or switch |
| `src/Test/Test.Integration/{Entity}RepositoryIntegrationTests.cs` | [test-templates-integration.md](../templates/test-templates-integration.md) | balanced+ |
| `src/Test/Test.E2E/{Entity}WorkflowTests.cs` | [test-templates-e2e.md](../templates/test-templates-e2e.md) | balanced+ |
| `src/Test/Test.Architecture/` updates | [test-templates-quality.md](../templates/test-templates-quality.md) | balanced+ |

### Required Test Gate by Profile

- `minimal`: Unit + Endpoint pass; mapper parity test exists.
- `balanced`: Minimal + `{Entity}RepositoryIntegrationTests` (real SQL via a standalone Testcontainer in `Test.Integration`) + `{Entity}WorkflowTests` (multi-endpoint workflow against Testcontainers SQL) + Architecture pass.
- `comprehensive`: Balanced + Load + Benchmark + Mutation (where enabled) + audit-pipeline / projection-pipeline integration tests where the entity participates in either.

For composite slices, include at least one integration scenario that traverses all participating entities.

---

## Uno UI Slice (Only if `includeUnoUI: true`)

Required UI artifacts:

- `Business/Models/{Entity}.cs`
- `Business/Services/{Feature}/I{Entity}Service.cs`
- `Business/Services/{Feature}/{Entity}Service.cs`
- `Presentation/{Entity}ListModel.cs`
- `Presentation/{Entity}DetailModel.cs`
- `Presentation/Create{Entity}Model.cs`
- `Views/{Entity}ListPage.xaml` + `.xaml.cs`
- `Views/{Entity}DetailPage.xaml` + `.xaml.cs`
- `Views/Create{Entity}Page.xaml` + `.xaml.cs`

Also update `App.xaml.host.cs`:

- register UI services,
- register navigation routes.

Templates: [uno-ui-client-layer.md](../templates/uno-ui-client-layer.md), [uno-mvux-model-template.md](../templates/uno-mvux-model-template.md), [uno-xaml-page-template.md](../templates/uno-xaml-page-template.md).

---

## React UI Slice (Only if `includeReactUI: true`)

Required UI artifacts:

- `src/api/types.ts` updated for the entity contract if no generated client exists
- `src/api/{project}Api.ts` method group for search/get/create/update/delete
- `src/features/{entity}/{Entity}ListPage.tsx`
- `src/features/{entity}/{Entity}DetailPage.tsx`
- `src/features/{entity}/{Entity}Form.tsx`
- `src/features/{entity}/{entity}Queries.ts`
- route entry in `src/app/routes.tsx`

Also update Playwright coverage when the UI surface is user-facing:

- add the entity route to shell/navigation smoke if needed,
- extend CRUD coverage for create/read/update/delete,
- include child collection assertions when the aggregate has children.

Skill: [ui-react.md](../skills/ui-react.md).

---

## Post-Generation Verification

### DI and Routing

- [ ] Repository wiring matches `repositoryContractStyle`: a generic-coverable entity resolves the open-generic `IRepositoryTrxn<{Entity}>` / `IRepositoryQuery<{Entity}>` (registered once - no per-entity registration); a bespoke entity has `I{Entity}Repository* -> {Entity}Repository*` registered (`per-entity` style: both registered for every entity)
- [ ] `I{Entity}Service` -> `{Entity}Service` registered
- [ ] `Map{Entity}Endpoints()` wired in API builder extensions
- [ ] If `applicationStyle` is `cqrs` or `switch`: request/handler/registration files are colocated under `Application.Cqrs/Features/{Entity}`
- [ ] If `applicationStyle` is `switch`: service and CQRS endpoint contract tests pass under both `Service` and `Cqrs`
- [ ] **[Multi-tenant only]** `ITenantBoundaryValidator` -> `TenantBoundaryValidator` registered (once for all entities)

### Data Access

- [ ] `DbSet<{Entity}>` in both Trxn and Query contexts
- [ ] `{Entity}Configuration` applies expected relationships/indexes
- [ ] migration generated and applied (or startup migration path validated)

### Build and Tests

- [ ] `dotnet build` passes
- [ ] `dotnet test` passes
- [ ] One vertical tracer behavior for the slice is covered through a public service contract, endpoint, UI action, or workflow boundary
- [ ] endpoint slice reachable in OpenAPI/Scalar when enabled

### Domain Rules / Policy

- [ ] Domain rule artifacts exist when Phase 1 rules/state machine/policy matrix are defined
- [ ] Transition/guard rules are wired into service or domain operations

### Mixed-Store / Reconciliation (if applicable)

For slices spanning SQL + Cosmos/Table/Blob + messaging, see [OPERATIONS.md](OPERATIONS.md) section Mixed-Store Slice Gate. Required:

- [ ] Authoritative store vs projection store boundary is explicit (writes always go to authoritative first; projections sync via domain events).
- [ ] Reconciliation job exists for drift detection and replay-safe correction.
- [ ] Replay window/late-arrival handling validated in tests.
- [ ] Projection reads never serve stale data for consistency-critical operations.

For implementation patterns (SQL + Cosmos composite, reconciliation job shape), see [data-persistence-advanced.md](data-persistence-advanced.md).

### Timeline / Support Trace (if applicable)

- [ ] Immutable timeline/audit projection is emitted for support/dispute critical workflows
- [ ] Timeline query/read endpoint (or equivalent query path) is available

### Content Lifecycle (if applicable)

- [ ] Draft and published snapshot semantics are modeled
- [ ] Scheduled publish is idempotent
- [ ] Rollback target/version policy is defined

### UI (if enabled)

- [ ] UI service DI and routes added
- [ ] list/detail/create pages render

---

DI registration shape and migration command live in the Fast Path section above; gate commands are canonical in [execution-gates.md](execution-gates.md) section Core Loop.
