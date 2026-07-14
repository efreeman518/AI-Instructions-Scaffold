# Test Templates - Quality Gates (Phase 5d)

| | |
|---|---|
| **Generates** | `tests/Test.Architecture/**`, `tests/Test.PlaywrightUI/**`, `tests/Test.Mobile/**` (when Uno native mobile testing is enabled), `tests/Test.Load/**`, `tests/Test.Benchmarks/**`, `tests/Test.Mutation/**` |
| **Requires** | Core implementation phases complete (5a-5c) |
| **Phase** | 5d (Quality + Delivery) |
| **Protocol** | These tests are written AFTER implementation. Unit/endpoint/integration tests already exist from 5a/5b/5c. Phase 5d adds quality gates and runs a full regression. |

---

## Architecture Tests (NetArchTest)

### File: `tests/Test.Architecture/BaseTest.cs`

```csharp
public abstract class BaseTest
{
    protected static readonly Assembly DomainModelAssembly = typeof(Domain.Model.{Entity}).Assembly;
    protected static readonly Assembly DomainSharedAssembly = typeof(Domain.Shared.Constants).Assembly;
    protected static readonly Assembly ApplicationServicesAssembly = typeof(Application.Services.{Entity}Service).Assembly;
    protected static readonly Assembly ApiAssembly = typeof(Program).Assembly;
}
```

### Files:
- `tests/Test.Architecture/DomainDependencyTests.cs`
- `tests/Test.Architecture/ApplicationDependencyTests.cs`
- `tests/Test.Architecture/ApiDependencyTests.cs`

```csharp
[TestClass]
[TestCategory("Architecture")]
public class DomainDependencyTests : BaseTest
{
    [TestMethod]
    public void Given_DomainModelAssembly_When_DependenciesChecked_Then_NoDependencyOnApplication()
    {
        var result = Types.InAssembly(DomainModelAssembly)
            .ShouldNot()
            .HaveDependencyOnAny("Application", "Infrastructure", "EntityFrameworkCore")
            .GetResult();
        Assert.IsTrue(result.IsSuccessful);
    }
}

[TestClass]
[TestCategory("Architecture")]
public class ApplicationDependencyTests : BaseTest
{
    [TestMethod]
    public void Given_ApplicationAssembly_When_DependenciesChecked_Then_NoDependencyOnInfrastructure()
    {
        var result = Types.InAssembly(ApplicationServicesAssembly)
            .ShouldNot()
            .HaveDependencyOnAny("Infrastructure", "EntityFrameworkCore")
            .GetResult();
        Assert.IsTrue(result.IsSuccessful);
    }
}
```

### File: `tests/Test.Architecture/AggregateBoundaryTests.cs` (GR-15)

Enforces the aggregate boundary: an **owned child** (1:N owned entity or M:N junction with no life outside its root - e.g. a comment or checklist item on a task, or the join entity) gets **no** standalone Create/Update/Delete CQRS command/handler, no transactional repository contract, and no write method on its read service. This is the automated gate behind [../skills/domain-model.md](../skills/domain-model.md) section Aggregate Roots vs Internal Children - it catches the anemic-child anti-pattern (a `Create{Child}Handler` that never loads its root) that prose alone does not.

Maintain the `OwnedChildEntities` list as the slice classification step ([GR-15](../GROUND-RULES.md)) decides each entity. Independent aggregate roots and polymorphic standalone entities (owned by no single root) are excluded - they keep the full write slice. The first test guards the list against renames so the rule cannot silently pass on a typo.

> **Reflection, not route inspection.** Minimal API route registrations (`MapPost("/{id}/{children}", ...)`) are not type metadata, so this gate asserts on the **type surface** that backs a write - the command/handler, the `I{Child}RepositoryTrxn` contract, and the service write methods. A child cannot be persisted standalone without one of those, so blocking them blocks the standalone write endpoint by construction. The legal nested-route writes on the root use `Add/Update/Remove{Root}{Child}` names that never collide with the forbidden `{Verb}{Child}Command/Handler` names.

```csharp
namespace Test.Architecture;

[TestClass]
[TestCategory("Architecture")]
public sealed class AggregateBoundaryTests : BaseTest
{
    // Owned children only (GR-15). Exclude independent roots ({Entity}, ...) and polymorphic
    // standalone entities owned by no single root. Add a child here when one is introduced.
    private static readonly Type[] OwnedChildEntities =
    [
        typeof({Project}.Domain.Model.{Child}),
        // typeof({Project}.Domain.Model.{OtherChild}),
    ];

    // Verb prefixes that denote a standalone child write. The legitimate aggregate-routed commands
    // are named Add/Update/Remove{Root}{Child}Command and never match these exact names.
    private static readonly string[] WriteVerbPrefixes = ["Create", "Update", "Delete", "Upsert", "Patch"];

    [TestMethod]
    public void OwnedChildEntities_AreRealDomainEntities()
    {
        var strays = OwnedChildEntities
            .Where(t => t.Assembly != DomainModelAssembly || !t.IsClass || t.IsAbstract)
            .Select(t => t.FullName)
            .ToList();
        Assert.IsEmpty(strays,
            $"Listed owned-child types are not concrete domain entities: {string.Join(", ", strays)}");
    }

    [TestMethod]
    public void OwnedChildren_HaveNoStandaloneWriteCommandsOrHandlers()
    {
        var forbidden = OwnedChildEntities
            .SelectMany(c => WriteVerbPrefixes
                .SelectMany(p => new[] { $"{p}{c.Name}Command", $"{p}{c.Name}Handler" }))
            .ToHashSet(StringComparer.Ordinal);

        var offenders = ApplicationCqrsAssembly.GetTypes()
            .Where(t => forbidden.Contains(t.Name))
            .Select(t => t.FullName)
            .ToList();
        Assert.IsEmpty(offenders,
            "Owned children must not have standalone write commands/handlers - route writes through the root: "
            + string.Join(", ", offenders));
    }

    [TestMethod]
    public void OwnedChildren_HaveNoTransactionalRepositoryContract()
    {
        var forbidden = OwnedChildEntities.Select(c => $"I{c.Name}RepositoryTrxn").ToHashSet(StringComparer.Ordinal);
        var offenders = ApplicationContractsAssembly.GetTypes()
            .Where(t => t.IsInterface && forbidden.Contains(t.Name))
            .Select(t => t.FullName)
            .ToList();
        Assert.IsEmpty(offenders,
            "Owned children must not expose a transactional repository contract (GR-15): " + string.Join(", ", offenders));
    }

    [TestMethod]
    public void OwnedChildren_ServiceContractsExposeReadsOnly()
    {
        var writeMethods = new HashSet<string>(
            ["CreateAsync", "UpdateAsync", "DeleteAsync", "UpsertAsync"], StringComparer.Ordinal);
        var offenders = new List<string>();
        foreach (var child in OwnedChildEntities)
        {
            var contract = ApplicationContractsAssembly.GetTypes()
                .FirstOrDefault(t => t.IsInterface && t.Name == $"I{child.Name}Service");
            if (contract is null) continue;
            offenders.AddRange(contract.GetMethods()
                .Where(m => writeMethods.Contains(m.Name))
                .Select(m => $"{contract.Name}.{m.Name}"));
        }
        Assert.IsEmpty(offenders,
            "Owned-child service contracts must be read-only (Search/Get only) per GR-15: " + string.Join(", ", offenders));
    }
}
```

> Requires `ApplicationContractsAssembly` and `ApplicationCqrsAssembly` on `BaseTest` (the CQRS assembly exists when `applicationStyle` is `cqrs` or `switch`). For a pure `service`-style scaffold with no CQRS layer, drop `OwnedChildren_HaveNoStandaloneWriteCommandsOrHandlers` and keep the repository-contract and service-surface assertions, which are style-independent.

**TaskFlow proof (local):** `../AI-Instructions-ReferenceApp/tests/Test.Architecture/AggregateBoundaryTests.cs`

---

## E2E Tests (Playwright)

> **Uno Skia smoke rule:** Canvas-only fingerprint/pixel-delta checks are smoke only. Name them as smoke, tag them `[TestCategory("WasmUI")]`, and do not claim CRUD, nested-child, or persistence correctness unless bridge state proves each transition.

> **DOM UI only - Blazor/MudBlazor/managed DOM:** The template below uses standard HTML selectors. Do not copy it into Uno Skia work. For Uno WASM, detect the renderer first. Managed-DOM renderer may use the boot-once shared-page pattern and coordinate-click helpers in [../skills/testing-quality.md](../skills/testing-quality.md) section Hosted Browser UI. Skia canvas renderer has no per-control DOM: never generate `getByText` / role / DOM-text assertions. For Skia, [uno-wasm-test-bridge-template.md](uno-wasm-test-bridge-template.md) is the only functional template: generate the bridge plus canvas smoke, poll fields such as `page`, `section`, `hasToken`, `onboardingComplete`, `status`, and `error`, assert a rendered canvas larger than 100x100, tag tests `[TestCategory("WasmUI")]`, and add `[assembly: DoNotParallelize]`.
>
> **Data-assertion rule:** Never assert specific row counts, page counts, or seeded titles (e.g. `"Showing 1 to 10 of 14"`, `"Build dashboard UI"`). These break against shared dev databases with accumulating test data. Assert structural UI strings only: headers, labels, empty-state text.
>
> **MudBlazor timing:** Always `waitFor` inputs before fill and use 15 s timeout for delete dialogs as defined in [../skills/testing-quality.md](../skills/testing-quality.md) section Hosted Browser UI.
>
> **Base URL:** Aspire assigns dynamic ports to UI hosts, especially React/Vite apps. Resolve the base URL at run time via `PlaywrightStackFixture` below - env var when an externally hosted stack is provided, otherwise self-host the AppHost and read the UI resource's actual endpoint. **Never generate a hard-coded URL fallback, and never generate `[Ignore]`d tests pointed at a guessed URL** - a Playwright suite that cannot find its stack degrades to `Assert.Inconclusive` with a precise message (GR-11), same as the Docker-gated tiers. For Uno WASM, also pass the dynamically resolved Gateway endpoint into the app through the test-mode query string so the browser client does not fall back to a fixed dev port.

### File: `tests/Test.PlaywrightUI/PlaywrightStackFixture.cs`

When `useAspire: true`, the suite hosts the stack itself with `DistributedApplicationTestingBuilder` (package `Aspire.Hosting.Testing` + a project reference to the AppHost), waits for the UI resource, and reads its dynamic URL from a named endpoint. `{ui-resource}` is the AppHost resource name of the UI under test (e.g. the React/Vite or Blazor resource). An explicit `{APP}_UI_BASE_URL` always wins, so CI can target a docker-compose stack or preview deployment without booting Aspire.

```csharp
[TestClass]
public class PlaywrightStackFixture
{
    private static DistributedApplication? _app;
    private static readonly TimeSpan StartupTimeout = TimeSpan.FromMinutes(5);

    /// <summary>Startup failure captured by AssemblyInit; null when a base URL was resolved.</summary>
    public static Exception? StartupError { get; private set; }

    /// <summary>Resolved UI base URL. Only valid when <see cref="StartupError"/> is null.</summary>
    public static string BaseUrl { get; private set; } = null!;

    [AssemblyInitialize]
    public static async Task AssemblyInit(TestContext _)
    {
        // Externally hosted stack (CI, docker-compose, preview env) wins.
        var external = Environment.GetEnvironmentVariable("{APP}_UI_BASE_URL");
        if (!string.IsNullOrWhiteSpace(external)) { BaseUrl = external.TrimEnd('/'); return; }

        // Otherwise self-host the Aspire AppHost and read the dynamic UI endpoint.
        try
        {
            // Same flag the AppHost's IsAspireTesting() reads via Environment.GetEnvironmentVariable;
            // set it before CreateAsync so the graph boots in testing mode (ephemeral containers,
            // optional hosts off). Mirrors {APP}_ASPIRE_TESTING in the Aspire mesh fixture.
            Environment.SetEnvironmentVariable("{APP}_ASPIRE_TESTING", "true");
            var builder = await DistributedApplicationTestingBuilder.CreateAsync<Projects.{App}_AppHost>();
            _app = await builder.BuildAsync().WaitAsync(StartupTimeout);
            await _app.StartAsync().WaitAsync(StartupTimeout);
            await _app.ResourceNotifications
                .WaitForResourceHealthyAsync("{ui-resource}")
                .WaitAsync(StartupTimeout);

            using var endpointClient = _app.CreateHttpClient("{ui-resource}", "http");
            BaseUrl = endpointClient.BaseAddress?.ToString().TrimEnd('/')
                ?? throw new InvalidOperationException("No http endpoint found for {ui-resource}.");
        }
        catch (Exception ex)
        {
            // Missing Docker/AppHost marks the suite Inconclusive, never red (GR-11).
            StartupError = ex;
        }
    }

    [AssemblyCleanup]
    public static async Task AssemblyCleanup(TestContext _)
    {
        if (_app is not null) await _app.DisposeAsync();
    }
}
```

### File: `tests/Test.PlaywrightUI/Tests/{Entity}CrudTests.cs`

```csharp
[assembly: Parallelize(Workers = 4, Scope = ExecutionScope.MethodLevel)]

[TestClass]
[TestCategory("PlaywrightUI")]
public class {Entity}CrudTests : PageTest
{
    private static string BaseUrl => PlaywrightStackFixture.BaseUrl;

    public override BrowserNewContextOptions ContextOptions() => new() { IgnoreHTTPSErrors = true };

    [TestInitialize]
    public async Task TestInitialize()
    {
        if (PlaywrightStackFixture.StartupError != null)
            Assert.Inconclusive($"Hosted stack unavailable: {PlaywrightStackFixture.StartupError.Message}");
        await Page.GotoAsync(BaseUrl);
    }

    [TestMethod]
    [DataRow("item1", "suffix1")]
    [DataRow("item2", "suffix2")]
    public async Task Given_NewEntity_When_AddEditDelete_Then_AllOperationsSucceed(string baseName, string appendName)
    {
        // Arrange
        var pageObject = new {Entity}PageObject(Page);
        await pageObject.NavigateAsync(BaseUrl);

        // Act - Create
        await Page.ClickAsync("#btn-add");
        await pageObject.FillNameAsync(baseName);
        await pageObject.ClickSaveAsync();

        // Assert - row appears in list
        Assert.IsTrue(await pageObject.ItemExistsInGridAsync(baseName));

        // Act - Edit
        await Page.Locator($"tr:has-text('{baseName}')").ClickAsync();
        await pageObject.FillNameAsync(baseName + appendName);
        await pageObject.ClickSaveAsync();

        // Assert - updated name in list
        Assert.IsTrue(await pageObject.ItemExistsInGridAsync(baseName + appendName));
        Assert.IsTrue(await pageObject.ItemNotInGridAsync(baseName));

        // Act - Delete
        await pageObject.ClickDeleteAsync(baseName + appendName);

        // Assert - removed from list
        Assert.IsTrue(await pageObject.ItemNotInGridAsync(baseName + appendName));
    }
}
```

### Page Objects

### File: `tests/Test.PlaywrightUI/PageObjects/{Entity}PageObject.cs`

```csharp
public class {Entity}PageObject(IPage page)
{
    public Task NavigateAsync(string baseUrl) => page.GotoAsync($"{baseUrl}/{entity}");
    public Task FillNameAsync(string name) => page.FillAsync("#edit-name", name);
    public Task ClickSaveAsync() => page.ClickAsync("#btn-save");
    public Task ClickDeleteAsync(string itemName) => page.Locator($"tr:has-text('{itemName}') >> button.delete").ClickAsync();

    public async Task<bool> ItemExistsInGridAsync(string itemName)
    {
        try
        {
            await page.Locator($"tr:has-text('{itemName}')").WaitForAsync(new() { Timeout = 5000 });
            return true;
        }
        catch (TimeoutException) { return false; }
    }

    public async Task<bool> ItemNotInGridAsync(string itemName)
    {
        try
        {
            await page.Locator($"tr:has-text('{itemName}')").WaitForAsync(new() { State = WaitForSelectorState.Hidden, Timeout = 5000 });
            return true;
        }
        catch (TimeoutException) { return false; }
    }
}
```

---

## Mobile UI Tests (MSTest + Appium, optional)

Generate `tests/Test.Mobile` and `tests/Test.Mobile/run-mobile-tests.ps1` only when Uno native mobile testing is in scope. Keep test methods opt-in so normal `dotnet test` does not require an emulator, device, APK build, or Appium server.

Rules:

- Use MSTest if the scaffold's test stack is MSTest. Do not introduce NUnit only for mobile smoke tests.
- Test methods must not start Appium, start an Android Emulator, or build APKs. They only connect to the prepared device/server.
- Default `dotnet test tests/Test.Mobile/Test.Mobile.csproj --filter TestCategory=MobileUI` with `{APP}_MOBILE_TESTS_ENABLED` unset/false must return `Assert.Inconclusive` without touching Appium or emulator.
- `run-mobile-tests.ps1` owns Android restore/build, emulator readiness, Appium readiness, `{APP}_MOBILE_TESTS_ENABLED=true`, `dotnet test`, and TRX output. Explicit runner lanes fail fast red if APK, emulator/device, Appium, or UiAutomator2 is missing/broken.
- Android local runs require Appium CLI/server and the UiAutomator2 driver.
- The runner builds the Android package from a full Uno restore graph:

```powershell
dotnet restore src/UI/{Project}.Uno/{Project}.Uno.csproj -p:BuildAllUnoTargets=true
dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride=$(LatestStableTfm)-android -p:UseMocks=true --no-restore -m:1
```

- Mark tests `[TestCategory("MobileUI")]`.
- Add method-level `[Timeout]` to every mobile test so Appium hangs cannot consume the lane.
- Native mobile scope stays small: app launch, native surface, first-viewport accessibility, one reliable text-entry smoke. Do not drive deep CRUD, search persistence, child collections, or long-scroll Skia forms with Appium/UiAutomator2.
- Use `MobileBy.AccessibilityId` for exact `AutomationProperties.Name` lookups. Avoid broad XPath except fallback probing.
- Write tests against the mobile helpers below, not repeated raw `driver.PageSource` asserts. Oracle and assertion strategy (screenshot-primary, non-empty artifact, no accessibility-tree asserts for Skia) live in [testing-quality.md](../skills/testing-quality.md#uno-mobile-test-split) - follow it, do not restate it here.
- Put a class-header comment with exact manual runner commands and prerequisites, per the [class-doc convention](../skills/testing.md#test-class-documentation-convention).
- iOS simulator/device execution is macOS-only. Windows may compile shared test code and record iOS execution as blocked unless a Mac host or macOS CI runner exists.

Generate a `MobileTestHelpers` support type so tests stay declarative and never hold raw driver plumbing:

```csharp
// Signatures only - implementation lives in Test.Mobile support.
public static class MobileTestHelpers
{
    // Build capabilities (resolved appActivity/appWaitActivity, UiAutomator2 settings) and open a session.
    public static AndroidDriver StartMobileSession();
    // Force-stop + relaunch the app package for a clean per-test surface.
    public static void ResetAndroidApp(AndroidDriver driver);
    // Primary oracle: write a PNG to the TRX artifact dir; return its path. Assert the file is non-empty.
    public static string SaveScreenshot(AndroidDriver driver, string name);
    // Best-effort: return page source or null; never throw, never hang the lane.
    public static string? TryReadPageSource(AndroidDriver driver);
}
```

Runner commands to scaffold:

```powershell
powershell -NoProfile -File tests/Test.Mobile/run-mobile-tests.ps1
powershell -NoProfile -File tests/Test.Mobile/run-mobile-tests.ps1 -SkipBuild
powershell -NoProfile -File tests/Test.Mobile/run-mobile-tests.ps1 -VisibleEmulator
powershell -NoProfile -File tests/Test.Mobile/run-mobile-tests.ps1 -VisibleEmulator -AvdName Android_Emulator_35
powershell -NoProfile -File tests/Test.Mobile/run-mobile-tests.ps1 -SkipBuild -Filter "FullyQualifiedName~{Project}Mobile_AppLaunches_AndRendersNativeSurface"
powershell -NoProfile -File tests/Test.Mobile/run-mobile-tests.ps1 -AndroidSdk "C:\Program Files (x86)\Android\android-sdk" -AppiumServerUrl "http://127.0.0.1:4723/"
```

---

## Load Tests (NBomber)

### File: `tests/Test.Load/{Entity}LoadTests.cs`

```csharp
[TestClass]
[TestCategory("Load")]
public class {Entity}LoadTests
{
    [TestMethod]
    public void Given_SearchEndpoint_When_LoadApplied_Then_MeetsPerformanceBaseline()
    {
        var scenario = Scenario.Create("search", async context =>
        {
            var response = await _httpClient.GetAsync("api/v1/{entity}?pageIndex=1&pageSize=20");
            return response.IsSuccessStatusCode ? Response.Ok() : Response.Fail();
        })
        .WithLoadSimulations(Simulation.InjectPerSec(rate: 20, during: TimeSpan.FromSeconds(60)));

        NBomberRunner.RegisterScenarios(scenario).Run();
    }
}
```

---

## Benchmarks (BenchmarkDotNet)

### File: `tests/Test.Benchmarks/{Entity}Benchmarks.cs`

```csharp
[MemoryDiagnoser]
public class {Entity}Benchmarks
{
    private {Entity}Service _service = null!;

    [GlobalSetup]
    public void Setup() { /* seed in-memory context and create service */ }

    [Benchmark]
    public async Task Given_SearchRequest_When_Executed_Then_MeasurePerformance()
        => await _service.SearchAsync(new SearchRequest<{Entity}SearchFilter> { PageIndex = 1, PageSize = 20 });
}
```

---

## Mutation Tests (Stryker.NET)

Mutation tests are still MSTest classes. Stryker.NET is the separate runner: it mutates the configured target project, reruns the filtered MSTest suite, and writes a report under `StrykerOutput`.

Install Stryker.NET as a repo-local dotnet tool. If `.config/dotnet-tools.json` does not exist yet, create it first.

```powershell
dotnet new tool-manifest
dotnet tool install dotnet-stryker
dotnet tool restore
```

### File: `tests/Test.Mutation/Test.Mutation.csproj`

```xml
<Project Sdk="Microsoft.NET.Sdk">

  <PropertyGroup>
    <IsTestProject>true</IsTestProject>
  </PropertyGroup>

  <ItemGroup>
    <PackageReference Include="MSTest" />
  </ItemGroup>

  <ItemGroup>
    <Using Include="Microsoft.VisualStudio.TestTools.UnitTesting" />
  </ItemGroup>

  <ItemGroup>
    <ProjectReference Include="..\..\src\Domain\{Project}.Domain.Model\{Project}.Domain.Model.csproj" />
    <ProjectReference Include="..\Test.Support\Test.Support.csproj" />
  </ItemGroup>

</Project>
```

### File: `tests/Test.Mutation/stryker-config.json`

Replace `{TargetFramework}` with the concrete TFM generated for the solution.

```json
{
  "stryker-config": {
    "solution": "../../{SolutionName}.slnx",
    "project": "{Project}.Domain.Model.csproj",
    "configuration": "Debug",
    "target-framework": "{TargetFramework}",
    "mutation-level": "Standard",
    "test-case-filter": "TestCategory=Mutation",
    "reporters": [
      "progress",
      "html",
      "cleartext"
    ],
    "thresholds": {
      "high": 80,
      "low": 60,
      "break": 0
    },
    "mutate": [
      "**/{Entity}.cs",
      "**/Rules/{Entity}*.cs"
    ]
  }
}
```

### File: `tests/Test.Mutation/Domain/{Entity}MutationSamples.cs`

```csharp
using {Project}.Domain.Model;
using {Project}.Domain.Shared.Constants;
using Test.Support;

namespace Test.Mutation.Domain;

/// <summary>
/// Mutation tests are normal MSTest tests. Stryker.NET mutates the configured target project
/// and reruns this filtered MSTest suite to decide which mutants are killed or survived.
/// Run the suite from repo root:
/// <code>
/// dotnet tool restore
/// dotnet test tests/Test.Mutation/Test.Mutation.csproj
/// </code>
/// Then run Stryker from tests/Test.Mutation:
/// <code>
/// dotnet tool run dotnet-stryker
/// </code>
/// The HTML mutation report is written under StrykerOutput.
/// </summary>
[TestClass]
[TestCategory("Mutation")]
public class {Entity}MutationSamples
{
    [TestMethod]
    public void Given_NameAtMinimumLength_When_EntityCreated_Then_Succeeds()
    {
        var name = new string('a', DomainConstants.RULE_DEFAULT_NAME_LENGTH_MIN);

        var result = {Entity}.Create(TestConstants.DefaultTenantId, name);

        Assert.IsTrue(result.IsSuccess);
        Assert.AreEqual(name, result.Value!.Name);
    }

    [TestMethod]
    public void Given_NameBelowMinimumLength_When_EntityCreated_Then_FailsWithMinimumLengthMessage()
    {
        var name = new string('a', DomainConstants.RULE_DEFAULT_NAME_LENGTH_MIN - 1);

        var result = {Entity}.Create(TestConstants.DefaultTenantId, name);

        Assert.IsTrue(result.IsFailure);
        StringAssert.Contains(
            string.Join(";", result.Errors),
            $"Name must be at least {DomainConstants.RULE_DEFAULT_NAME_LENGTH_MIN} characters.");
    }
}
```

Run commands:

```powershell
dotnet test tests/Test.Mutation/Test.Mutation.csproj
```

From `tests/Test.Mutation`:

```powershell
dotnet tool run dotnet-stryker
```

Add `**/StrykerOutput/` to `.gitignore`.

---

## Integration, Aspire & E2E Tests (moved to dedicated templates)

The Integration (`Test.Integration` component), Aspire (`Test.Aspire` mesh), and E2E (`Test.E2E`) tiers are scaffolded during Phase 5a/5b - not Phase 5d. The patterns live in their own templates:

- [test-templates-integration.md](test-templates-integration.md) - component: `SqlContainerFixture` / `AzuriteContainerFixture` + `IntegrationTestSetup`, `{Entity}RepositoryIntegrationTests`, `AuditLogRepositoryAzuriteTests`, `DomainEventPipelineTests`.
- [test-templates-aspire.md](test-templates-aspire.md) - mesh: `AspireTestHost` (lazy) + `AspireMeshLifecycle`, `ApiAuditPipelineTests`, `FunctionAuditPipelineTests`.
- [test-templates-e2e.md](test-templates-e2e.md) - `SqlApiFactory`, `{Entity}WorkflowTests` (full CRUD + paged search + child-aggregate workflows against Testcontainers SQL).

Phase 5d treats these tiers as **regression scope**, not generation scope: run them as part of the final quality gate (`dotnet test --filter "TestCategory=Integration|TestCategory=E2E"`) but do not re-generate fixtures here. If a sub-phase skipped its tier earlier (e.g., `api-only` scaffold), load the matching template on-demand and back-fill.

> **Docker requirement:** Integration / E2E tiers need Docker Desktop running (Testcontainers + Azurite). In CI, run them with `--filter "TestCategory=Integration|TestCategory=E2E"` separately from unit/endpoint tests so a missing daemon fails fast instead of cascading.

---

## Phase 5e Regression Run

After writing quality gate tests, run the full suite to verify no regressions from 5a/5b/5c/5d:

```powershell
dotnet test
```

Profile gates:
- `minimal`: Unit + Endpoint pass
- `balanced`: Unit + Endpoint + Integration + Architecture pass
- `comprehensive`: Balanced + E2E/Load/Benchmark/Mutation pass
