# Test Templates - Quality Gates (Phase 5d)

| | |
|---|---|
| **Generates** | `Test/Test.Architecture/**`, `Test/Test.PlaywrightUI/**`, `Test/Test.Mobile/**` (when Uno native mobile testing is enabled), `Test/Test.Load/**`, `Test/Test.Benchmarks/**`, `Test/Test.Mutation/**` |
| **Requires** | Core implementation phases complete (5a-5c) |
| **Phase** | 5d (Quality + Delivery) |
| **Protocol** | These tests are written AFTER implementation. Unit/endpoint/integration tests already exist from 5a/5b/5c. Phase 5d adds quality gates and runs a full regression. |

---

## Architecture Tests (NetArchTest)

### File: `Test/Test.Architecture/BaseTest.cs`

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
- `Test/Test.Architecture/DomainDependencyTests.cs`
- `Test/Test.Architecture/ApplicationDependencyTests.cs`
- `Test/Test.Architecture/ApiDependencyTests.cs`

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

---

## E2E Tests (Playwright)

> **Uno WASM vs MudBlazor:** The template below uses standard HTML selectors (MudBlazor / server-rendered Blazor). For Uno WASM with the managed-DOM renderer, use the boot-once shared-page pattern and coordinate-click helpers in [../skills/testing-quality.md](../skills/testing-quality.md) section Hosted Browser UI. For Uno WASM that renders to a **Skia canvas** (no per-control DOM), use the state bridge in [uno-wasm-test-bridge-template.md](uno-wasm-test-bridge-template.md) and tag tests `[TestCategory("WasmUI")]`.
>
> **Data-assertion rule:** Never assert specific row counts, page counts, or seeded titles (e.g. `"Showing 1 to 10 of 14"`, `"Build dashboard UI"`). These break against shared dev databases with accumulating test data. Assert structural UI strings only: headers, labels, empty-state text.
>
> **MudBlazor timing:** Always `waitFor` inputs before fill and use 15 s timeout for delete dialogs as defined in [../skills/testing-quality.md](../skills/testing-quality.md) section Hosted Browser UI.
>
> **Base URL:** Aspire assigns dynamic ports to UI hosts, especially React/Vite apps. Resolve the base URL at run time via `PlaywrightStackFixture` below - env var when an externally hosted stack is provided, otherwise self-host the AppHost and read the UI resource's actual endpoint. **Never generate a hard-coded URL fallback, and never generate `[Ignore]`d tests pointed at a guessed URL** - a Playwright suite that cannot find its stack degrades to `Assert.Inconclusive` with a precise message (GR-11), same as the Docker-gated tiers.

### File: `Test/Test.PlaywrightUI/PlaywrightStackFixture.cs`

When `useAspire: true`, the suite hosts the stack itself with `DistributedApplicationTestingBuilder` (package `Aspire.Hosting.Testing` + a project reference to the AppHost), waits for the UI resource, and reads its dynamic URL. `{ui-resource}` is the AppHost resource name of the UI under test (e.g. the React/Vite or Blazor resource). An explicit `{APP}_UI_BASE_URL` always wins, so CI can target a docker-compose stack or preview deployment without booting Aspire.

```csharp
[TestClass]
public class PlaywrightStackFixture
{
    private static DistributedApplication? _app;

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
            var builder = await DistributedApplicationTestingBuilder.CreateAsync<Projects.{App}_AppHost>();
            _app = await builder.BuildAsync();
            await _app.StartAsync();
            await _app.ResourceNotifications
                .WaitForResourceHealthyAsync("{ui-resource}")
                .WaitAsync(TimeSpan.FromMinutes(3));
            BaseUrl = _app.GetEndpoint("{ui-resource}").ToString().TrimEnd('/');
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

### File: `Test/Test.PlaywrightUI/Tests/{Entity}CrudTests.cs`

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

### File: `Test/Test.PlaywrightUI/PageObjects/{Entity}PageObject.cs`

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

Generate `Test/Test.Mobile` only when Uno native mobile testing is in scope. Keep this suite opt-in so normal `dotnet test` does not require an emulator, device, or Appium server.

Rules:

- Use MSTest if the scaffold's test stack is MSTest. Do not introduce NUnit only for mobile smoke tests.
- Android local runs require Appium CLI/server and the UiAutomator2 driver.
- Build the Android package from a full Uno restore graph:

```powershell
dotnet restore src/UI/{Project}.Uno/{Project}.Uno.csproj -p:BuildAllUnoTargets=true
dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride=$(LatestStableTfm)-android -p:UseMocks=true --no-restore -m:1
```

- Mark tests `[TestCategory("MobileUI")]`.
- **Generated only when `includeUnoUI` was selected; then runs by default with a local false-only opt-out** (see [Capability-Gated Test Tiers](../skills/testing.md#capability-gated-test-tiers-the-early-decision-drives-the-rest)): treat only a case-insensitive `{APP}_MOBILE_TESTS_ENABLED=false` as opt-out. When opted out, or when no emulator/device is online or Appium is not listening, mark `Assert.Inconclusive` with a precise setup message (run `eng/test/start-local-test-stack.ps1`) - never red, never a silent skip. Do not require an enable flag set to `true`.
- Android smoke acceptance: App launches, native surface renders, screenshot is non-empty, and page source can be captured for triage.
- Prefer screenshots and page-source artifacts for verification - canvas-rendered Uno controls may not expose rich accessibility nodes.
- Put a class-header comment with the exact manual run command and prerequisites (start `eng/test/start-local-test-stack.ps1`; opt out with `{APP}_MOBILE_TESTS_ENABLED=false`), per the [class-doc convention](../skills/testing.md#test-class-documentation-convention).
- iOS simulator/device execution is macOS-only. Windows may compile shared test code and record iOS execution as blocked unless a Mac host or macOS CI runner exists.

---

## Load Tests (NBomber)

### File: `Test/Test.Load/{Entity}LoadTests.cs`

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

### File: `Test/Test.Benchmarks/{Entity}Benchmarks.cs`

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
rtk dotnet new tool-manifest
rtk dotnet tool install dotnet-stryker
rtk dotnet tool restore
```

### File: `Test/Test.Mutation/Test.Mutation.csproj`

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
    <ProjectReference Include="..\..\Domain\{Project}.Domain.Model\{Project}.Domain.Model.csproj" />
    <ProjectReference Include="..\Test.Support\Test.Support.csproj" />
  </ItemGroup>

</Project>
```

### File: `Test/Test.Mutation/stryker-config.json`

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

### File: `Test/Test.Mutation/Domain/{Entity}MutationSamples.cs`

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
/// rtk dotnet tool restore
/// rtk dotnet test src/Test/Test.Mutation/Test.Mutation.csproj
/// </code>
/// Then run Stryker from src/Test/Test.Mutation:
/// <code>
/// rtk dotnet tool run dotnet-stryker
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
rtk dotnet test src/Test/Test.Mutation/Test.Mutation.csproj
```

From `src/Test/Test.Mutation`:

```powershell
rtk dotnet tool run dotnet-stryker
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
