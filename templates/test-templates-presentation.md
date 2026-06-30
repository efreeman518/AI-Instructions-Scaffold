# Presentation Test Templates

Fast headless UI tests for Uno MVUX presentation models and UI services. Use in Phase 5c when `includeUnoUI: true`.

| | |
|---|---|
| **Files** | `src/Test/Test.UI/Presentation/{Entity}PresentationModelTests.cs` |
| **Production target** | `src/UI/{Project}.Uno.Presentation/Presentation/*.cs` |
| **References** | `Test.UI` references `{Project}.Uno.Core` and `{Project}.Uno.Presentation`, never `{Project}.Uno` |
| **Required packages** | Main `Uno.Extensions.Reactive` only when `SourceContext` is not available transitively; do not add `Uno.Extensions.Reactive.Testing` |

## Purpose

Presentation models and UI services are app logic, not pure domain/application unit tests. They must be testable in the fast `Test.UI` lane without building the `Uno.Sdk` app head or installing platform workloads.

`{Project}.Uno.Core` owns:

- `Business/Models`
- `Business/Services`
- `Client/` API client wrappers

`{Project}.Uno.Presentation` owns `Presentation/` MVUX partial records and UI state/feed logic. `{Project}.Uno` owns XAML views, app startup, route registration, styles, converters, strings, and platform assets only.

## Package Rule

Do not add `Uno.Extensions.Reactive.Testing`. As of 2026-06-23, NuGet shows `Uno.Extensions.Reactive.Testing` behind the current 7.x `Uno.Extensions.Reactive` line:

- `https://api.nuget.org/v3-flatcontainer/uno.extensions.reactive.testing/index.json`
- `https://api.nuget.org/v3-flatcontainer/uno.extensions.reactive/index.json`

Use `SourceContext.GetOrCreate(model).AsCurrent()` from namespace `Uno.Extensions.Reactive.Core`, then await states and feeds directly.

## Project Reference

```xml
<ItemGroup>
  <ProjectReference Include="..\..\UI\{Project}.Uno.Core\{Project}.Uno.Core.csproj" />
  <ProjectReference Include="..\..\UI\{Project}.Uno.Presentation\{Project}.Uno.Presentation.csproj" />
</ItemGroup>
```

Do not reference:

```xml
<ProjectReference Include="..\..\UI\{Project}.Uno\{Project}.Uno.csproj" />
<PackageReference Include="Uno.Extensions.Reactive.Testing" />
```

## Stub HTTP Handler

Use a real API client and service over a stub `HttpMessageHandler`. This verifies JSON envelopes and service mapping without starting the Gateway.

```csharp
private sealed class StubHttpMessageHandler : HttpMessageHandler
{
    private readonly Queue<HttpResponseMessage> _responses = new();
    public List<HttpRequestMessage> Requests { get; } = [];

    public void EnqueueJson(string json, HttpStatusCode statusCode = HttpStatusCode.OK)
    {
        _responses.Enqueue(new HttpResponseMessage(statusCode)
        {
            Content = new StringContent(json, Encoding.UTF8, "application/json")
        });
    }

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request,
        CancellationToken cancellationToken)
    {
        Requests.Add(request);
        return Task.FromResult(_responses.Dequeue());
    }
}
```

Stub CRUD responses with the shared `DefaultResponse<T>` envelope:

```json
{ "item": { "id": "00000000-0000-0000-0000-000000000001", "title": "Draft" } }
```

Stub search responses with the shared paged shape:

```json
{
  "data": [
    { "id": "00000000-0000-0000-0000-000000000001", "title": "Draft" }
  ],
  "pageIndex": 1,
  "pageSize": 10,
  "totalCount": 1
}
```

## SourceContext Harness

```csharp
using Uno.Extensions.Reactive.Core;

[TestClass]
[TestCategory("UI")]
public sealed class {Entity}PresentationModelTests
{
    private StubHttpMessageHandler _handler = null!;
    private {Project}ApiClient _apiClient = null!;
    private I{Entity}ApiService _service = null!;
    private TestNavigator _navigator = null!;
    private IMessenger _messenger = null!;

    [TestInitialize]
    public void Setup()
    {
        _handler = new StubHttpMessageHandler();
        var http = new HttpClient(_handler) { BaseAddress = new Uri("https://gateway.test") };
        _apiClient = new {Project}ApiClient(http);
        _messenger = new StrongReferenceMessenger();
        _service = new {Entity}ApiService(_apiClient, _messenger);
        _navigator = new TestNavigator();
    }

    [TestMethod]
    [TestCategory("Presentation")]
    public async Task Given_SearchResponse_When_ListFeedRead_Then_ItemsLoaded()
    {
        _handler.EnqueueJson("""
        {
          "data": [
            { "id": "00000000-0000-0000-0000-000000000001", "title": "Draft" }
          ],
          "pageIndex": 1,
          "pageSize": 10,
          "totalCount": 1
        }
        """);

        var model = new {Entity}ListModel(_navigator, _service, _messenger);

#pragma warning disable CS8602, CS8620, CS8621, CS8714
        using (SourceContext.GetOrCreate(model).AsCurrent())
        {
            var items = await model.Items;
            Assert.AreEqual(1, items.Count);
            Assert.AreEqual("Draft", items[0].Title);
        }
#pragma warning restore CS8602, CS8620, CS8621, CS8714
    }
}
```

Keep nullable-warning suppressions around the `SourceContext` awaiter seam only. Do not suppress nullable warnings across the production MVUX model.

## Test Navigator

Use a small observable test double for navigation. Do not pull in the Uno app head to observe route calls.

```csharp
private sealed class TestNavigator : INavigator
{
    public string? LastRoute { get; private set; }
    public object? LastData { get; private set; }

    public ValueTask<NavigationResponse?> NavigateRouteAsync(
        object sender,
        string route,
        object? data = null,
        CancellationToken cancellation = default)
    {
        LastRoute = route;
        LastData = data;
        return ValueTask.FromResult<NavigationResponse?>(null);
    }

    public ValueTask<NavigationResponse?> NavigateBackAsync(
        object sender,
        object? data = null,
        CancellationToken cancellation = default)
    {
        LastRoute = "..";
        LastData = data;
        return ValueTask.FromResult<NavigationResponse?>(null);
    }
}
```

If the concrete `INavigator` signature differs in the installed Uno version, adapt this test double to the package signature. Do not replace it with a reference to `{Project}.Uno`.

## Required Coverage

For each entity with MVUX presentation models, add focused tests for:

- list load and search/paging shape,
- create, update, delete command service calls,
- version-counter feed refresh after mutation,
- messenger-driven cross-model refresh,
- buffered child item behavior before parent save,
- child create/delete in edit mode,
- navigation route and route-data calls,
- injected shell/theme/form-guard behavior.

## Categories

- Class-level category: `[TestCategory("UI")]`.
- Method-level category when useful for filtering: `[TestCategory("Presentation")]`.
- Do not use `[TestCategory("Unit")]` for MVUX, UI service, theme/catalog, shell, or presentation-model tests.
- Keep browser-hosted UI in `Test.PlaywrightUI` with `PlaywrightUI` or `WasmUI`; keep native Appium in `Test.Mobile` with `MobileUI`.

## Rules

- `Test.Unit` stays pure domain/application service tests.
- `Test.UI` references `{Project}.Uno.Core` and `{Project}.Uno.Presentation` only.
- `Test.UI` never references `{Project}.Uno` or any `Uno.Sdk` app head.
- Presentation tests use `SourceContext.GetOrCreate(model).AsCurrent()`.
- Stub HTTP uses the same envelope contracts as the running API.
- Tests assert observable state, route calls, requests, and messenger effects.
- Static `App.*` calls in a model are a testability failure. Replace them with injected abstractions before writing tests.
