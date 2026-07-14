# Expected Output File Index

Load on-demand as a reference during Phase 5a-5e to verify scaffolded file layout.

Expected file layout when scaffolding is complete. All paths are relative to the repo root.

> **Scope:** Backend layers below are always emitted. Optional Phase 5c hosts (Blazor, React, Uno) extend this index - those sections only apply when the corresponding `enabledFeatures` flag is set in `HANDOFF.md` (`includeBlazorUI`, `includeReactUI`, `includeUnoUI`). For host-internal layout details, see [../skills/ui-blazor.md](../skills/ui-blazor.md), [../skills/ui-react.md](../skills/ui-react.md), and [../skills/ui-uno.md](../skills/ui-uno.md).

## Domain Layer
| Artifact | Path |
|---|---|
| Entity (root) | `src/Domain/Domain.Model/TodoItem.cs` |
| Entity (child) | `src/Domain/Domain.Model/Comment.cs` |
| Value object | `src/Domain/Domain.Model/DateRange.cs` |

## Data Access
| Artifact | Path |
|---|---|
| EF config (entity) | `src/Infrastructure/Infrastructure.Data/Configurations/TodoItemConfiguration.cs` |
| Write repository | `src/Infrastructure/Infrastructure.Repositories/TodoItemRepositoryTrxn.cs` |
| Read repository | `src/Infrastructure/Infrastructure.Repositories/TodoItemRepositoryQuery.cs` |
| Trxn DbContext | `src/Infrastructure/Infrastructure.Data/{App}DbContextTrxn.cs` |
| Query DbContext | `src/Infrastructure/Infrastructure.Data/{App}DbContextQuery.cs` |
| Updater | `src/Infrastructure/Infrastructure.Repositories/TodoItemUpdater.cs` |

## Application Layer
| Artifact | Path |
|---|---|
| Service | `src/Application/Application.Services/TodoItemService.cs` |
| DTO | `src/Application/Application.Models/TodoItemDto.cs` |
| Search filter | `src/Application/Application.Models/TodoItemSearchFilter.cs` |
| Mapper | `src/Application/Application.Mappers/TodoItemMapper.cs` |
| Contracts | `src/Application/Application.Contracts/` |
| Error constants | `src/Application/Application.Contracts/ErrorConstants.cs` |
| DefaultRequest | `src/Application/Application.Models/DefaultRequest.cs` (record) |
| DefaultResponse | `src/Application/Application.Models/DefaultResponse.cs` (record) |
| Structure validator | `src/Application/Application.Services/Rules/{Entity}StructureValidator.cs` |
| Service error messages | `src/Application/Application.Services/Rules/ServiceErrorMessages.cs` |
| Tenant info DTO | `src/Application/Application.Models/TenantInfoDto.cs` *(multi-tenant only)* |
| Tenant boundary validator | `src/Application/Application.Services/TenantBoundaryValidator.cs` *(multi-tenant only)* |
| Tenant boundary interface | `src/Application/Application.Contracts/ITenantBoundaryValidator.cs` *(multi-tenant only)* |
| Validation helper | `src/Application/Application.Services/Rules/ValidationHelper.cs` *(multi-tenant only)* |
| Tenant logging extensions | `src/Application/Application.Services/Rules/TenantBoundaryLoggingExtensions.cs` *(multi-tenant only)* |
| Tenant rules | `src/Application/Application.Services/Rules/TenantRules.cs` *(multi-tenant only)* |
| Message handler | `src/Application/Application.MessageHandlers/TodoItemCreatedEventHandler.cs` |
| Application style switch | `src/Application/Application.Contracts/ApplicationStyle.cs` *(when applicationStyle: switch)* |
| CQRS requests | `src/Application/Application.Cqrs/Features/{Entity}/{Entity}Requests.cs` *(when applicationStyle: cqrs or switch)* |
| CQRS handlers | `src/Application/Application.Cqrs/Features/{Entity}/{Entity}Handlers.cs` *(when applicationStyle: cqrs or switch)* |
| CQRS feature registration | `src/Application/Application.Cqrs/Features/{Entity}/{Entity}CqrsRegistrations.cs` *(when applicationStyle: cqrs or switch)* |
| CQRS shared helpers | `src/Application/Application.Cqrs/Features/Shared/CqrsHandlerSupport.cs` *(when applicationStyle: cqrs or switch)* |
| CQRS root registration | `src/Application/Application.Cqrs/Registration/CqrsApplicationRegistration.cs` *(when applicationStyle: cqrs or switch)* |

Default scaffold and TaskFlow reference app keep DTOs and mappers in `Application.Models` and `Application.Mappers` so service and CQRS styles share one contract. A CQRS-only vertical slice may instead put feature-specific models, mappers, projections, and adapters under `Application.Cqrs/Features/{Entity}` when those shapes are not shared.

## API Host
| Artifact | Path |
|---|---|
| Program.cs | `src/Host/{Host}.Api/Program.cs` |
| Endpoints | `src/Host/{Host}.Api/Endpoints/TodoItemEndpoints.cs` |
| CQRS endpoints | `src/Host/{Host}.Api/Endpoints/Cqrs/TodoItemCqrsEndpoints.cs` *(when applicationStyle: cqrs or switch)* |
| RegisterApiServices | `src/Host/{Host}.Api/RegisterApiServices.cs` |
| Bootstrapper | `src/Host/{Host}.Bootstrapper/RegisterServices.cs` |

## Testing
| Artifact | Path |
|---|---|
| Test support - shared WAF base | `tests/Test.Support/WebApplicationFactoryBase.cs` (thin adapter over `EfWebApplicationFactoryBase` from EF.IntegrationTesting) |
| Test support - JSON options | `tests/Test.Support/JsonTestOptions.cs` |
| Test support - shared constants | `tests/Test.Support/TestConstants.cs` (`LocalSqlSettings.cs` lives in the AppHost project) |
| Test support - utilities | `tests/Test.Support/InMemoryDbBuilder.cs` (unit tests are flat classes - no shared unit-test base) |
| Test support - builders | `tests/Test.Support/Builders/{Entity}Builder.cs`, `{Entity}DtoBuilder.cs` (one of each per entity) |
| Unit (domain) | `tests/Test.Unit/Domain/{Entity}Tests.cs`, `{Entity}RulesTests.cs` |
| Unit (mapper, per entity) | `tests/Test.Unit/Mappers/{Entity}MapperTests.cs` |
| Unit (mapper parity, consolidated) | `tests/Test.Unit/Mappers/MapperProjectionParityTests.cs` |
| Unit (services) | `tests/Test.Unit/Services/{Entity}ServiceTests.cs` |
| Unit (CQRS) | `tests/Test.Unit/Cqrs/{Entity}CqrsValidationTests.cs` *(when applicationStyle: cqrs or switch)* |
| Unit (repositories) | `tests/Test.Unit/Repositories/{Entity}RepositoryTrxnTests.cs`, `{Entity}RepositoryQueryTests.cs` |
| UI (headless presentation) | `tests/Test.UI/Presentation/{Entity}PresentationModelTests.cs` *(when UI model/presentation coverage exists)* |
| Endpoint contract tests | `tests/Test.Endpoints/Endpoints/{Entity}EndpointsTests.cs` |
| CQRS endpoint switch tests | `tests/Test.Endpoints/CqrsEndpointModeTests.cs` *(when applicationStyle: switch)* |
| Endpoint factory | `tests/Test.Endpoints/CustomApiFactory.cs` (derives from `tests/Test.Support/WebApplicationFactoryBase`) |
| E2E factory | `tests/Test.E2E/SqlApiFactory.cs` (Testcontainers SQL, static lifecycle) |
| E2E workflow tests | `tests/Test.E2E/{Entity}WorkflowTests.cs` |
| Integration (component) - store fixtures | `tests/Test.Integration/Infrastructure/SqlContainerFixture.cs`, `AzuriteContainerFixture.cs` (+ `RedisContainerFixture.cs` when used) |
| Integration (component) - assembly lifecycle | `tests/Test.Integration/Infrastructure/IntegrationTestSetup.cs` (starts store fixtures in parallel; captures `StartupError`) |
| Integration (component) - repo integration | `tests/Test.Integration/{Entity}RepositoryIntegrationTests.cs` (migrations + CRUD + tenant filter + M:N) |
| Integration (component) - audit repo (Azurite) | `tests/Test.Integration/AuditLogRepositoryAzuriteTests.cs` |
| Integration (component) - projection pipeline | `tests/Test.Integration/DomainEventPipelineTests.cs` |
| Aspire (mesh) - lazy host + lifecycle | `tests/Test.Aspire/AspireTestHost.cs` (lazy `EnsureStartedAsync`), `AspireMeshLifecycle.cs` (`[AssemblyCleanup]`) |
| Aspire (mesh) - API audit pipeline | `tests/Test.Aspire/ApiAuditPipelineTests.cs` |
| Aspire (mesh) - Function audit pipeline | `tests/Test.Aspire/FunctionAuditPipelineTests.cs` |
| Architecture | `tests/Test.Architecture/*DependencyTests.cs`, `CqrsArchitectureTests.cs` *(when applicationStyle: cqrs or switch)* |
| Playwright UI | `tests/Test.PlaywrightUI/Pages/{Entity}CrudTests.cs` (browser; runs against hosted stack) |
| Mobile UI smoke | `tests/Test.Mobile/run-mobile-tests.ps1`, `tests/Test.Mobile/*` (MSTest + Appium; opt-in Android/iOS native launch checks) *(when Uno mobile native testing is enabled)* |
| Load | `tests/Test.Load/{Entity}LoadTests.cs` |
| Benchmark | `tests/Test.Benchmarks/{Entity}Benchmarks.cs` |
| Mutation | `tests/Test.Mutation/Domain/{Entity}MutationSamples.cs`, `tests/Test.Mutation/stryker-config.json` |

## Aspire
| Artifact | Path |
|---|---|
| AppHost | `src/Host/Aspire/AppHost/AppHost.cs` |
| Service defaults | `src/Host/Aspire/ServiceDefaults/Extensions.cs` |

## Infrastructure
| Artifact | Path |
|---|---|
| Dockerfile (per host) | `src/Host/{Host}.Api/Dockerfile` |
| Health checks | `src/Host/{Host}.Api/HealthChecks/SqlHealthCheck.cs` |

## Blazor UI (Phase 5c, optional - `includeBlazorUI: true`)

Source: [../skills/ui-blazor.md](../skills/ui-blazor.md). Project root: `src/UI/{Project}.Blazor/`.

| Artifact | Path |
|---|---|
| Program.cs | `src/UI/{Project}.Blazor/Program.cs` |
| App root | `src/UI/{Project}.Blazor/App.razor` |
| Routes | `src/UI/{Project}.Blazor/Components/Routes.razor` |
| Imports | `src/UI/{Project}.Blazor/Components/_Imports.razor` |
| Layout | `src/UI/{Project}.Blazor/Components/Layout/MainLayout.razor` |
| Page (dashboard) | `src/UI/{Project}.Blazor/Components/Pages/Dashboard.razor` |
| Page (entity list, per entity) | `src/UI/{Project}.Blazor/Components/Pages/{Entity}List.razor` |
| Page (entity new/edit, per entity) | `src/UI/{Project}.Blazor/Components/Pages/{Entity}Page.razor` |
| Page (settings, error) | `src/UI/{Project}.Blazor/Components/Pages/Settings.razor`, `Error.razor` |
| Refit API client | `src/UI/{Project}.Blazor/Services/I{Project}ApiClient.cs` |
| Scoped state hub | `src/UI/{Project}.Blazor/Services/FloatService.cs` |
| Static assets | `src/UI/{Project}.Blazor/wwwroot/app.css` |
| Runtime config (WASM only) | `src/UI/{Project}.Blazor/wwwroot/appsettings.json` |

## Uno UI (Phase 5c, optional, dedicated session - `includeUnoUI: true`)

Source: [../skills/ui-uno.md](../skills/ui-uno.md), [../skills/ui-uno-shell.md](../skills/ui-uno-shell.md), [../skills/ui-uno-mvux.md](../skills/ui-uno-mvux.md), [../skills/ui-uno-navigation.md](../skills/ui-uno-navigation.md), [../skills/ui-uno-platforms.md](../skills/ui-uno-platforms.md). Project roots: `src/UI/{Project}.Uno/`, `src/UI/{Project}.Uno.Core/`, `src/UI/{Project}.Uno.Presentation/`, and `src/Host/{Project}.Uno.WasmHost/`.

| Artifact | Path |
|---|---|
| Uno project | `src/UI/{Project}.Uno/{Project}.Uno.csproj` |
| Testable core project | `src/UI/{Project}.Uno.Core/{Project}.Uno.Core.csproj` |
| Testable presentation project | `src/UI/{Project}.Uno.Presentation/{Project}.Uno.Presentation.csproj` |
| WASM wrapper host | `src/Host/{Project}.Uno.WasmHost/{Project}.Uno.WasmHost.csproj` |
| App entry | `src/UI/{Project}.Uno/App.xaml`, `App.xaml.cs`, `App.xaml.host.cs`, `Program.cs` |
| App config | `src/UI/{Project}.Uno/appsettings.json` (+ environment variants) |
| Shell | `src/UI/{Project}.Uno/Views/Shell.xaml`, `Shell.xaml.cs`; `src/UI/{Project}.Uno.Presentation/Presentation/ShellModel.cs` |
| Business model (per entity) | `src/UI/{Project}.Uno.Core/Business/Models/{Entity}.cs` |
| Business service (per feature) | `src/UI/{Project}.Uno.Core/Business/Services/{Feature}/I{Entity}Service.cs`, `{Entity}Service.cs` |
| Kiota client (generated) | `src/UI/{Project}.Uno.Core/Client/` |
| MVUX model list (per entity) | `src/UI/{Project}.Uno.Presentation/Presentation/{Entity}ListModel.cs` |
| MVUX model new/edit (per entity) | `src/UI/{Project}.Uno.Presentation/Presentation/{Entity}PageModel.cs` |
| Page list (per entity) | `src/UI/{Project}.Uno/Views/{Entity}ListPage.xaml` + `.xaml.cs` |
| Page new/edit (per entity) | `src/UI/{Project}.Uno/Views/{Entity}Page.xaml` + `.xaml.cs` |
| Styles / strings / converters | `src/UI/{Project}.Uno/Styles/`, `Strings/`, `Converters/` |
| Android platform glue | `src/UI/{Project}.Uno/Platforms/Android/AndroidManifest.xml`, `Main.Android.cs`, `MainActivity.Android.cs`, `Resources/` |
| iOS platform glue | `src/UI/{Project}.Uno/Platforms/iOS/Info.plist`, `Entitlements.plist`, `Main.iOS.cs`, `PrivacyInfo.xcprivacy` |
| WASM platform glue | `src/UI/{Project}.Uno/Platforms/WebAssembly/WasmScripts/AppManifest.js` |

## React UI (Phase 5c, optional - `includeReactUI: true`)

Source: [../skills/ui-react.md](../skills/ui-react.md). Project root: `src/UI/{Project}.React/`.

| Artifact | Path |
|---|---|
| Package manifest | `src/UI/{Project}.React/package.json` |
| Vite config | `src/UI/{Project}.React/vite.config.ts` |
| App entry | `src/UI/{Project}.React/src/main.tsx`, `src/UI/{Project}.React/src/app/App.tsx` |
| Routes | `src/UI/{Project}.React/src/app/routes.tsx` |
| API client | `src/UI/{Project}.React/src/api/{project}Api.ts` |
| API types | `src/UI/{Project}.React/src/api/types.ts` |
| Page (dashboard) | `src/UI/{Project}.React/src/features/dashboard/DashboardPage.tsx` |
| Page (entity list, per entity) | `src/UI/{Project}.React/src/features/{entity}/{Entity}ListPage.tsx` |
| Page (entity detail/edit, per entity) | `src/UI/{Project}.React/src/features/{entity}/{Entity}DetailPage.tsx` |
| Form (per entity) | `src/UI/{Project}.React/src/features/{entity}/{Entity}Form.tsx` |
| Query hooks (per entity) | `src/UI/{Project}.React/src/features/{entity}/{entity}Queries.ts` |
| Shared layout/theme | `src/UI/{Project}.React/src/shared/layout/`, `src/UI/{Project}.React/src/shared/theme/` |
