# Expected Output File Index

Load on-demand as a reference during Phase 5a-5e to verify scaffolded file layout.

Expected file layout when scaffolding is complete. All paths relative to project root `src/`.

> **Scope:** Backend layers below are always emitted. Optional Phase 5c hosts (Blazor, React, Uno) extend this index - those sections only apply when the corresponding `enabledFeatures` flag is set in `HANDOFF.md` (`includeBlazorUI`, `includeReactUI`, `includeUnoUI`). For host-internal layout details, see [../skills/ui-blazor.md](../skills/ui-blazor.md), [../skills/ui-react.md](../skills/ui-react.md), and [../skills/ui-uno.md](../skills/ui-uno.md).

## Domain Layer
| Artifact | Path |
|---|---|
| Entity (root) | `Domain/Domain.Model/TodoItem.cs` |
| Entity (child) | `Domain/Domain.Model/Comment.cs` |
| Value object | `Domain/Domain.Model/DateRange.cs` |

## Data Access
| Artifact | Path |
|---|---|
| EF config (entity) | `Infrastructure/Infrastructure.Data/Configurations/TodoItemConfiguration.cs` |
| Write repository | `Infrastructure/Infrastructure.Repositories/TodoItemRepositoryTrxn.cs` |
| Read repository | `Infrastructure/Infrastructure.Repositories/TodoItemRepositoryQuery.cs` |
| Trxn DbContext | `Infrastructure/Infrastructure.Data/{App}DbContextTrxn.cs` |
| Query DbContext | `Infrastructure/Infrastructure.Data/{App}DbContextQuery.cs` |
| Updater | `Infrastructure/Infrastructure.Repositories/TodoItemUpdater.cs` |

## Application Layer
| Artifact | Path |
|---|---|
| Service | `Application/Application.Services/TodoItemService.cs` |
| DTO | `Application/Application.Models/TodoItemDto.cs` |
| Search filter | `Application/Application.Models/TodoItemSearchFilter.cs` |
| Mapper | `Application/Application.Mappers/TodoItemMapper.cs` |
| Contracts | `Application/Application.Contracts/` |
| Error constants | `Application/Application.Contracts/ErrorConstants.cs` |
| DefaultRequest | `Application/Application.Models/DefaultRequest.cs` (record) |
| DefaultResponse | `Application/Application.Models/DefaultResponse.cs` (record) |
| Structure validator | `Application/Application.Services/Rules/{Entity}StructureValidator.cs` |
| Service error messages | `Application/Application.Services/Rules/ServiceErrorMessages.cs` |
| Tenant info DTO | `Application/Application.Models/TenantInfoDto.cs` *(multi-tenant only)* |
| Tenant boundary validator | `Application/Application.Services/TenantBoundaryValidator.cs` *(multi-tenant only)* |
| Tenant boundary interface | `Application/Application.Contracts/ITenantBoundaryValidator.cs` *(multi-tenant only)* |
| Validation helper | `Application/Application.Services/Rules/ValidationHelper.cs` *(multi-tenant only)* |
| Tenant logging extensions | `Application/Application.Services/Rules/TenantBoundaryLoggingExtensions.cs` *(multi-tenant only)* |
| Tenant rules | `Application/Application.Services/Rules/TenantRules.cs` *(multi-tenant only)* |
| Message handler | `Application/Application.MessageHandlers/TodoItemCreatedEventHandler.cs` |
| Application style switch | `Application/Application.Contracts/ApplicationStyle.cs` *(when applicationStyle: switch)* |
| CQRS requests | `Application/Application.Cqrs/Features/{Entity}/{Entity}Requests.cs` *(when applicationStyle: cqrs or switch)* |
| CQRS handlers | `Application/Application.Cqrs/Features/{Entity}/{Entity}Handlers.cs` *(when applicationStyle: cqrs or switch)* |
| CQRS feature registration | `Application/Application.Cqrs/Features/{Entity}/{Entity}CqrsRegistrations.cs` *(when applicationStyle: cqrs or switch)* |
| CQRS shared helpers | `Application/Application.Cqrs/Features/Shared/CqrsHandlerSupport.cs` *(when applicationStyle: cqrs or switch)* |
| CQRS root registration | `Application/Application.Cqrs/Registration/CqrsApplicationRegistration.cs` *(when applicationStyle: cqrs or switch)* |

Default scaffold and TaskFlow reference app keep DTOs and mappers in `Application.Models` and `Application.Mappers` so service and CQRS styles share one contract. A CQRS-only vertical slice may instead put feature-specific models, mappers, projections, and adapters under `Application.Cqrs/Features/{Entity}` when those shapes are not shared.

## API Host
| Artifact | Path |
|---|---|
| Program.cs | `Host/{Host}.Api/Program.cs` |
| Endpoints | `Host/{Host}.Api/Endpoints/TodoItemEndpoints.cs` |
| CQRS endpoints | `Host/{Host}.Api/Endpoints/Cqrs/TodoItemCqrsEndpoints.cs` *(when applicationStyle: cqrs or switch)* |
| RegisterApiServices | `Host/{Host}.Api/RegisterApiServices.cs` |
| Bootstrapper | `Host/{Host}.Bootstrapper/RegisterServices.cs` |

## Testing
| Artifact | Path |
|---|---|
| Test support - shared WAF base | `Test/Test.Support/WebApplicationFactoryBase.cs` (with `TestDbContextFactory<T>` + `WebApplicationFactoryHelpers`) |
| Test support - JSON options | `Test/Test.Support/JsonTestOptions.cs` |
| Test support - shared constants | `Test/Test.Support/TestConstants.cs`, `LocalSqlSettings.cs` |
| Test support - utilities | `Test/Test.Support/UnitTestBase.cs`, `InMemoryDbBuilder.cs`, `DbSupport.cs` |
| Test support - builders | `Test/Test.Support/Builders/{Entity}Builder.cs`, `{Entity}DtoBuilder.cs` (one of each per entity) |
| Unit (domain) | `Test/Test.Unit/Domain/{Entity}Tests.cs`, `{Entity}RulesTests.cs` |
| Unit (mapper, per entity) | `Test/Test.Unit/Mappers/{Entity}MapperTests.cs` |
| Unit (mapper parity, consolidated) | `Test/Test.Unit/Mappers/MapperProjectionParityTests.cs` |
| Unit (services) | `Test/Test.Unit/Services/{Entity}ServiceTests.cs` |
| Unit (CQRS) | `Test/Test.Unit/Cqrs/{Entity}CqrsValidationTests.cs` *(when applicationStyle: cqrs or switch)* |
| Unit (repositories) | `Test/Test.Unit/Repositories/{Entity}RepositoryTrxnTests.cs`, `{Entity}RepositoryQueryTests.cs` |
| Endpoint contract tests | `Test/Test.Endpoints/Endpoints/{Entity}EndpointsTests.cs` |
| CQRS endpoint switch tests | `Test/Test.Endpoints/CqrsEndpointModeTests.cs` *(when applicationStyle: switch)* |
| Endpoint factory | `Test/Test.Endpoints/CustomApiFactory.cs` (derives from `Test.Support/WebApplicationFactoryBase`) |
| E2E factory | `Test/Test.E2E/SqlApiFactory.cs` (Testcontainers SQL, static lifecycle) |
| E2E workflow tests | `Test/Test.E2E/{Entity}WorkflowTests.cs` |
| Integration (component) - store fixtures | `Test/Test.Integration/Infrastructure/SqlContainerFixture.cs`, `AzuriteContainerFixture.cs` (+ `RedisContainerFixture.cs` when used) |
| Integration (component) - assembly lifecycle | `Test/Test.Integration/Infrastructure/IntegrationTestSetup.cs` (starts store fixtures in parallel; captures `StartupError`) |
| Integration (component) - repo integration | `Test/Test.Integration/{Entity}RepositoryIntegrationTests.cs` (migrations + CRUD + tenant filter + M:N) |
| Integration (component) - audit repo (Azurite) | `Test/Test.Integration/AuditLogRepositoryAzuriteTests.cs` |
| Integration (component) - projection pipeline | `Test/Test.Integration/DomainEventPipelineTests.cs` |
| Aspire (mesh) - lazy host + lifecycle | `Test/Test.Aspire/AspireTestHost.cs` (lazy `EnsureStartedAsync`), `AspireMeshLifecycle.cs` (`[AssemblyCleanup]`) |
| Aspire (mesh) - API audit pipeline | `Test/Test.Aspire/ApiAuditPipelineTests.cs` |
| Aspire (mesh) - Function audit pipeline | `Test/Test.Aspire/FunctionAuditPipelineTests.cs` |
| Architecture | `Test/Test.Architecture/*DependencyTests.cs`, `CqrsArchitectureTests.cs` *(when applicationStyle: cqrs or switch)* |
| Playwright UI | `Test/Test.PlaywrightUI/Pages/{Entity}CrudTests.cs` (browser; runs against hosted stack) |
| Mobile UI smoke | `Test/Test.Mobile/*` (MSTest + Appium; opt-in Android/iOS native launch checks) *(when Uno mobile native testing is enabled)* |
| Load | `Test/Test.Load/{Entity}LoadTests.cs` |
| Benchmark | `Test/Test.Benchmarks/{Entity}Benchmarks.cs` |
| Mutation | `Test/Test.Mutation/Domain/{Entity}MutationSamples.cs`, `Test/Test.Mutation/stryker-config.json` |

## Aspire
| Artifact | Path |
|---|---|
| AppHost | `Host/Aspire/AppHost/AppHost.cs` |
| Service defaults | `Host/Aspire/ServiceDefaults/Extensions.cs` |

## Infrastructure
| Artifact | Path |
|---|---|
| Dockerfile (per host) | `Host/{Host}.Api/Dockerfile` |
| Health checks | `Host/{Host}.Api/HealthChecks/SqlHealthCheck.cs` |

## Blazor UI (Phase 5c, optional - `includeBlazorUI: true`)

Source: [../skills/ui-blazor.md](../skills/ui-blazor.md). Project root: `Host/{Project}.Blazor/`.

| Artifact | Path |
|---|---|
| Program.cs | `Host/{Project}.Blazor/Program.cs` |
| App root | `Host/{Project}.Blazor/App.razor` |
| Routes | `Host/{Project}.Blazor/Components/Routes.razor` |
| Imports | `Host/{Project}.Blazor/Components/_Imports.razor` |
| Layout | `Host/{Project}.Blazor/Components/Layout/MainLayout.razor` |
| Page (dashboard) | `Host/{Project}.Blazor/Components/Pages/Dashboard.razor` |
| Page (entity list, per entity) | `Host/{Project}.Blazor/Components/Pages/{Entity}List.razor` |
| Page (entity new/edit, per entity) | `Host/{Project}.Blazor/Components/Pages/{Entity}Page.razor` |
| Page (settings, error) | `Host/{Project}.Blazor/Components/Pages/Settings.razor`, `Error.razor` |
| Refit API client | `Host/{Project}.Blazor/Services/I{Project}ApiClient.cs` |
| Scoped state hub | `Host/{Project}.Blazor/Services/FloatService.cs` |
| Static assets | `Host/{Project}.Blazor/wwwroot/app.css` |
| Runtime config (WASM only) | `Host/{Project}.Blazor/wwwroot/appsettings.json` |

## Uno UI (Phase 5c, optional, dedicated session - `includeUnoUI: true`)

Source: [../skills/ui-uno.md](../skills/ui-uno.md), [../skills/ui-uno-shell.md](../skills/ui-uno-shell.md), [../skills/ui-uno-mvux.md](../skills/ui-uno-mvux.md), [../skills/ui-uno-navigation.md](../skills/ui-uno-navigation.md), [../skills/ui-uno-platforms.md](../skills/ui-uno-platforms.md). Project roots: `src/UI/{Project}.Uno/`, `src/UI/{Project}.Uno.Core/`, and `src/Host/{Project}.Uno.WasmHost/`.

| Artifact | Path |
|---|---|
| Uno project | `src/UI/{Project}.Uno/{Project}.Uno.csproj` |
| Testable core project | `src/UI/{Project}.Uno.Core/{Project}.Uno.Core.csproj` |
| WASM wrapper host | `src/Host/{Project}.Uno.WasmHost/{Project}.Uno.WasmHost.csproj` |
| App entry | `src/UI/{Project}.Uno/App.xaml`, `App.xaml.cs`, `App.xaml.host.cs`, `Program.cs` |
| App config | `src/UI/{Project}.Uno/appsettings.json` (+ environment variants) |
| Shell | `src/UI/{Project}.Uno/Views/Shell.xaml`, `Shell.xaml.cs`, `Presentation/ShellModel.cs` |
| Business model (per entity) | `src/UI/{Project}.Uno.Core/Business/Models/{Entity}.cs` |
| Business service (per feature) | `src/UI/{Project}.Uno.Core/Business/Services/{Feature}/I{Entity}Service.cs`, `{Entity}Service.cs` |
| Kiota client (generated) | `src/UI/{Project}.Uno.Core/Client/` |
| MVUX model list (per entity) | `src/UI/{Project}.Uno/Presentation/{Entity}ListModel.cs` |
| MVUX model new/edit (per entity) | `src/UI/{Project}.Uno/Presentation/{Entity}Model.cs` |
| Page list (per entity) | `src/UI/{Project}.Uno/Views/{Entity}ListPage.xaml` + `.xaml.cs` |
| Page new/edit (per entity) | `src/UI/{Project}.Uno/Views/{Entity}Page.xaml` + `.xaml.cs` |
| Styles / strings / converters | `src/UI/{Project}.Uno/Styles/`, `Strings/`, `Converters/` |
| Android platform glue | `src/UI/{Project}.Uno/Platforms/Android/AndroidManifest.xml`, `Main.Android.cs`, `MainActivity.Android.cs`, `Resources/` |
| iOS platform glue | `src/UI/{Project}.Uno/Platforms/iOS/Info.plist`, `Entitlements.plist`, `Main.iOS.cs`, `PrivacyInfo.xcprivacy` |
| WASM platform glue | `src/UI/{Project}.Uno/Platforms/WebAssembly/WasmScripts/AppManifest.js` |

## React UI (Phase 5c, optional - `includeReactUI: true`)

Source: [../skills/ui-react.md](../skills/ui-react.md). Project root: `UI/{Project}.React/`.

| Artifact | Path |
|---|---|
| Package manifest | `UI/{Project}.React/package.json` |
| Vite config | `UI/{Project}.React/vite.config.ts` |
| App entry | `UI/{Project}.React/src/main.tsx`, `UI/{Project}.React/src/app/App.tsx` |
| Routes | `UI/{Project}.React/src/app/routes.tsx` |
| API client | `UI/{Project}.React/src/api/{project}Api.ts` |
| API types | `UI/{Project}.React/src/api/types.ts` |
| Page (dashboard) | `UI/{Project}.React/src/features/dashboard/DashboardPage.tsx` |
| Page (entity list, per entity) | `UI/{Project}.React/src/features/{entity}/{Entity}ListPage.tsx` |
| Page (entity detail/edit, per entity) | `UI/{Project}.React/src/features/{entity}/{Entity}DetailPage.tsx` |
| Form (per entity) | `UI/{Project}.React/src/features/{entity}/{Entity}Form.tsx` |
| Query hooks (per entity) | `UI/{Project}.React/src/features/{entity}/{entity}Queries.ts` |
| Shared layout/theme | `UI/{Project}.React/src/shared/layout/`, `UI/{Project}.React/src/shared/theme/` |
