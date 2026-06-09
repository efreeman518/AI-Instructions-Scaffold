# Blazor UI

## Purpose

Scaffold a Blazor UI (Server or WebAssembly) that calls the **Gateway** (YARP), not backend APIs directly. This is an alternative to [ui-uno.md](ui-uno.md) and [ui-react.md](ui-react.md) - pick one or offer explicit siblings under `src/UI/`.

- **UI**: MudBlazor shell + components
- **State**: `FloatService` (scoped singleton) shared across layout and pages - **not** cascading parameters
- **Client**: Refit (`Refit.HttpClientFactory`) against the Gateway base URL
- **Auth**: MSAL WebAssembly for WASM builds; JWT bearer cookie/claims for Server. Scaffold auth-off and add after first vertical slice works

Reference app: [TaskFlow.Blazor](https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/UI/TaskFlow.Blazor) and the Caller Portal ([Portal.UI1](https://github.com/efreeman518/Portal/tree/main/src/Portal/Portal.UI1)) - canonical source of the FloatService + Refit + MudBlazor layering.

## Render Mode Choice

| Mode | When |
|---|---|
| **Blazor Server** (`Microsoft.NET.Sdk.Web` + `AddInteractiveServerComponents`) | Default for internal / LAN apps, fastest to scaffold, single deployable unit, server owns HttpClient -> no browser CORS against Gateway |
| **Blazor WebAssembly** (`Microsoft.NET.Sdk.BlazorWebAssembly`) | Public-facing app that should scale independently of backend, offline-capable, or when you're already shipping assets to a CDN |

The rest of this file applies to both modes unless called out. WebAssembly-only concerns are marked **[WASM]**.

## Required Structure

```text
{Project}.Blazor/
  Program.cs
  App.razor                # <HeadOutlet/> + root Routes + <script src="_framework/blazor.web.js">
  Components/
    _Imports.razor
    Routes.razor           # <Router AppAssembly=...> with DefaultLayout=MainLayout
    Layout/
      MainLayout.razor     # MudLayout + AppBar + Drawer + NavMenu, wires FloatService.StateHasChanged
    Pages/
      Dashboard.razor
      {Entity}List.razor
      {Entity}Page.razor   # unified new/edit via @page "/xs/new" + "/xs/{Id:guid}"
      Settings.razor
      Error.razor
  Services/
    I{Project}ApiClient.cs # Refit interface, one per backend resource group
    FloatService.cs        # scoped state/progress/event hub
  wwwroot/
    app.css
    appsettings.json       # [WASM] - configuration is loaded at runtime from here
```

## Packages (Central Versions)

Add to `Directory.Packages.props`:

```xml
<PackageVersion Include="MudBlazor" Version="<latest-stable>" />
<PackageVersion Include="Refit" Version="<latest-stable>" />
<PackageVersion Include="Refit.HttpClientFactory" Version="<latest-stable>" />
```

Resolve `<latest-stable>` at scaffold time. See [package-dependencies.md](package-dependencies.md) -> *Latest, Not Pinned*.

csproj references:

```xml
<ItemGroup>
  <PackageReference Include="MudBlazor" />
  <PackageReference Include="Refit" />
  <PackageReference Include="Refit.HttpClientFactory" />
  <PackageReference Include="Microsoft.Extensions.Http.Resilience" />
</ItemGroup>

<ItemGroup>
  <!-- Direct project reference to shared DTOs avoids duplicating contracts. -->
  <ProjectReference Include="..\..\Application\{Project}.Application.Models\{Project}.Application.Models.csproj" />
  <ProjectReference Include="..\..\Domain\{Project}.Domain.Shared\{Project}.Domain.Shared.csproj" />
</ItemGroup>
```

Use the EF.Common.Contracts `SearchRequest<T>` / `PagedResponse<T>` already pulled in by `{Project}.Application.Models` - do not redefine them in the Blazor project.

## Project File Rules (`.csproj`)

- **Server**: `<Project Sdk="Microsoft.NET.Sdk.Web">`
- **WASM**: `<Project Sdk="Microsoft.NET.Sdk.BlazorWebAssembly">` + `<BlazorWebAssemblyLoadAllGlobalizationData>true</BlazorWebAssemblyLoadAllGlobalizationData>` when localization is in scope
- `TargetFramework` matches the solution's `Directory.Build.props` value (use the latest stable TFM the rest of the solution targets - do not hard-code).

## Program.cs - Server

```csharp
using System.Text.Json;
using System.Text.Json.Serialization;
using MudBlazor;
using MudBlazor.Services;
using Refit;
using {Project}.Blazor.Components;
using {Project}.Blazor.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services.AddRazorComponents().AddInteractiveServerComponents();

builder.Services.AddMudServices(cfg =>
{
    cfg.SnackbarConfiguration.PositionClass = Defaults.Classes.Position.BottomRight;
    cfg.SnackbarConfiguration.PreventDuplicates = true;
});

builder.Services.AddScoped<FloatService>();

var jsonOptions = new JsonSerializerOptions
{
    PropertyNameCaseInsensitive = true,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    Converters = { new JsonStringEnumConverter() }
};

var gatewayUrl = builder.Configuration["Gateway:BaseUrl"]
    ?? throw new InvalidOperationException("Gateway:BaseUrl not configured.");

builder.Services
    .AddRefitClient<I{Project}ApiClient>(new RefitSettings
    {
        ContentSerializer = new SystemTextJsonContentSerializer(jsonOptions)
    })
    .ConfigureHttpClient(c =>
    {
        c.BaseAddress = new Uri(gatewayUrl);
        c.DefaultRequestHeaders.Add("Accept", "application/json");
    })
    // Add auth handler here once auth is wired (see Auth section).
    .AddStandardResilienceHandler();

var app = builder.Build();
if (!app.Environment.IsDevelopment()) { app.UseExceptionHandler("/Error", createScopeForErrors: true); app.UseHsts(); }
app.UseHttpsRedirection();
app.UseStaticFiles();
app.UseAntiforgery();
app.MapRazorComponents<App>().AddInteractiveServerRenderMode();
app.Run();
```

## Program.cs - WebAssembly

Differences from Server:

- `builder = WebAssemblyHostBuilder.CreateDefault(args)` - no `ConfigureWebHost`
- Load `appsettings.json` from `wwwroot` via `HttpClient.GetStringAsync("appsettings.json")`
- Use `AddMsalAuthentication` for Entra External ID (see Auth section)
- Register a `DelegatingHandler` that acquires an access token from `IAccessTokenProvider` and sets `Authorization: Bearer <token>`. Attach via `.AddHttpMessageHandler<ApiAuthHandler>()` on the Refit client

No `UseAntiforgery`/`UseHttpsRedirection` - WASM host is a static SPA.

## App.razor & Routes.razor (Server)

```razor
@* App.razor *@
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <base href="/" />
    <link rel="stylesheet" href="_content/MudBlazor/MudBlazor.min.css" />
    <link rel="stylesheet" href="app.css" />
    <HeadOutlet @rendermode="InteractiveServer" />
    <title>{Project}</title>
</head>
<body>
    <Routes @rendermode="InteractiveServer" />
    <script src="_content/MudBlazor/MudBlazor.min.js"></script>
    <script src="_framework/blazor.web.js"></script>
</body>
</html>
```

```razor
@* Routes.razor *@
<Router AppAssembly="typeof(Program).Assembly">
    <Found Context="routeData">
        <RouteView RouteData="routeData" DefaultLayout="typeof(Layout.MainLayout)" />
        <FocusOnNavigate RouteData="routeData" Selector="h1" />
    </Found>
</Router>
```

**Non-negotiable:** `@rendermode="InteractiveServer"` on both `HeadOutlet` and `Routes`. Without it the page renders statically - buttons, forms, MudBlazor dialogs all no-op with no error.

## `_Imports.razor`

```razor
@using System.Net.Http
@using System.Net.Http.Json
@using Microsoft.AspNetCore.Components.Forms
@using Microsoft.AspNetCore.Components.Routing
@using Microsoft.AspNetCore.Components.Web
@using static Microsoft.AspNetCore.Components.Web.RenderMode
@using Microsoft.AspNetCore.Components.Web.Virtualization
@using Microsoft.JSInterop
@using MudBlazor
@using EF.Common.Contracts
@using {Project}.Application.Models
@using {Project}.Blazor
@using {Project}.Blazor.Components
@using {Project}.Blazor.Components.Layout
@using {Project}.Blazor.Services
@using {Project}.Domain.Shared.Enums
```

## FloatService - Scoped State Hub

Use **FloatService (scoped singleton)** to share state across layout and pages instead of cascading parameters. The layout holds a reference; pages inject it; pages publish cross-page events through it.

### Responsibilities

- **ModuleName** - current area label painted into the AppBar
- **RequestIsActive** - boolean derived from an interlocked counter; layout binds a progress spinner to it
- **ExecuteWithProgressAsync\<T\>** - wraps an async call, increments the counter, catches and surfaces exceptions via `ISnackbar.Add(..., Severity.Error)`, returns `default` on failure
- **Events** - one `Action` per entity family (`TaskItemsChanged`, `CategoriesChanged`, ...). Pages that mutate data raise the event; unrelated pages subscribing refresh themselves
- **StateHasChanged callback** - layout assigns `FloatService.StateHasChanged = StateHasChanged` in `OnInitialized` and clears it in `Dispose`. This lets FloatService tell the AppBar to repaint when the in-flight counter flips

```csharp
public class FloatService(ISnackbar snackbar)
{
    private int _pending;
    public string ModuleName { get; set; } = "";
    public bool RequestIsActive => _pending > 0;
    public Action? StateHasChanged { get; set; }
    public event Action? TaskItemsChanged;
    public void NotifyTaskItemsChanged() => TaskItemsChanged?.Invoke();

    public async Task<T?> ExecuteWithProgressAsync<T>(Func<Task<T>> call, string? errorMessage = null)
    {
        try
        {
            Interlocked.Increment(ref _pending); StateHasChanged?.Invoke();
            return await call();
        }
        catch (Exception ex)
        {
            snackbar.Add(errorMessage ?? ex.Message, Severity.Error);
            return default;
        }
        finally { Interlocked.Decrement(ref _pending); StateHasChanged?.Invoke(); }
    }
}
```

**Page pattern:**

```csharp
[Inject] protected FloatService FloatService { get; set; } = default!;
[Inject] protected I{Project}ApiClient Api { get; set; } = default!;

protected override async Task OnInitializedAsync()
{
    FloatService.ModuleName = "Tasks";
    FloatService.TaskItemsChanged += OnExternalChange;
    await LoadAsync();
}

private async Task LoadAsync()
{
    var page = await FloatService.ExecuteWithProgressAsync(
        () => Api.SearchTaskItemsAsync(new SearchRequest<TaskItemSearchFilter>
        {
            Filter = new(), PageIndex = 0, PageSize = 50
        }),
        "Failed to load tasks.");
    _items = page?.Data ?? new();
}

public void Dispose() => FloatService.TaskItemsChanged -= OnExternalChange;
```

**Non-negotiables:**
- Register as **Scoped** - `AddScoped<FloatService>()`. Singleton would bleed state across users (Server) or circuits.
- Do **not** close over `this` in event subscriptions without `Dispose` unsubscribing - pages leak otherwise.
- Cross-page updates go through events, not through direct page-to-page calls.

## Refit Client Pattern

One interface per resource group, decorated with `[Post]/[Get]/[Put]/[Delete]` attributes. Use the shared `DefaultRequest<T>`/`DefaultResponse<T>` envelope from `{Project}.Application.Models` and `SearchRequest<T>`/`PagedResponse<T>` from `EF.Common.Contracts`.

```csharp
public interface I{Project}ApiClient
{
    [Post("/api/task-items/search")]
    Task<PagedResponse<TaskItemDto>> SearchTaskItemsAsync(
        [Body] SearchRequest<TaskItemSearchFilter> request, CancellationToken ct = default);

    [Get("/api/task-items/{id}")]
    Task<DefaultResponse<TaskItemDto>> GetTaskItemAsync(Guid id, CancellationToken ct = default);

    [Post("/api/task-items")]
    Task<DefaultResponse<TaskItemDto>> CreateTaskItemAsync(
        [Body] DefaultRequest<TaskItemDto> request, CancellationToken ct = default);

    [Put("/api/task-items/{id}")]
    Task<DefaultResponse<TaskItemDto>> UpdateTaskItemAsync(
        Guid id, [Body] DefaultRequest<TaskItemDto> request, CancellationToken ct = default);

    [Delete("/api/task-items/{id}")]
    Task DeleteTaskItemAsync(Guid id, CancellationToken ct = default);
}
```

### Request / Response Envelope Rules

(Same contract as the Uno client - keep both clients in lock-step.)

- **Create / Update** expect `{"item": {dto}}`. Wrap: `new DefaultRequest<T> { Item = dto }`. Sending the bare DTO deserializes `Item` as `null` and the server returns an NRE.
- **Get / Create / Update** return `{"item": {dto}}`. Unwrap: `response.Item`.
- **Search** accepts `SearchRequest<TFilter>` directly (not wrapped) and returns `PagedResponse<T>` with `data` (items) and `total` (count).
- **Pagination is 1-based on the wire** - `PageIndex` starts at 1, **not** 0. The server silently coerces 0 to 1 and you get page 1 on every request.

See [ui-uno-mvux.md](ui-uno-mvux.md) -> *Client-API Contract Rules* for the detailed payload diagrams; the same contract applies.

### Refit JSON Serializer

Pass a `SystemTextJsonContentSerializer` with `PropertyNameCaseInsensitive = true`, `JsonIgnoreCondition.WhenWritingNull`, and `JsonStringEnumConverter`. Enums flow over the wire as string names, which matches the API and keeps payloads human-readable.

## Dev Tenant Header

When the API host is multi-tenant **and** auth is off (the default scaffold first-vertical-slice state), Refit calls land at the API with no `userTenantId` claim. The EF tenant query filter then evaluates to `TenantId == null` against every row and the UI looks silently empty - every list returns zero items, no error. See [../patterns/api-host-wiring.md](../patterns/api-host-wiring.md) -> *Dev-Mode Tenant Fallback* for the API-side middleware.

Ship a `DelegatingHandler` that injects a project-scoped tenant header on every Refit call:

```csharp
// Services/TenantHeaderHandler.cs
public sealed class TenantHeaderHandler(IConfiguration config) : DelegatingHandler
{
    private const string HeaderName = "X-{Project}-Tenant";

    protected override Task<HttpResponseMessage> SendAsync(
        HttpRequestMessage request, CancellationToken ct)
    {
        var tenantId = config["{Project}:DefaultTenantId"];
        if (!string.IsNullOrWhiteSpace(tenantId) && !request.Headers.Contains(HeaderName))
        {
            request.Headers.Add(HeaderName, tenantId);
        }
        return base.SendAsync(request, ct);
    }
}
```

Register and attach to every Refit client:

```csharp
builder.Services.AddTransient<TenantHeaderHandler>();

builder.Services
    .AddRefitClient<I{Project}ApiClient>(...)
    .ConfigureHttpClient(c => c.BaseAddress = new Uri(gatewayUrl))
    .AddHttpMessageHandler<TenantHeaderHandler>()
    // Auth handler (when wired) goes AFTER the tenant handler so claims-based
    // tenant resolution can override the dev header.
    .AddStandardResilienceHandler();
```

`appsettings.Development.json`:

```json
{
  "{Project}": { "DefaultTenantId": "<seeded-tenant-guid>" }
}
```

Use the same GUID the data-seed step inserts into the `Tenants` table. When real auth lands, delete `{Project}:DefaultTenantId` (or leave it for dev-only use); production tenant resolution then flows from the `userTenantId` claim.

**Non-negotiables:**
- Register the handler as **Transient** - `DelegatingHandler` instances are pooled per-message by `IHttpMessageHandlerFactory`; scoped/singleton causes lifetime errors.
- The header name must match the API's `DevRequestContextMiddleware` exactly. Centralize the literal in a shared constant if both projects can see it.
- Do **not** read the tenant id from a Blazor `IRequestContext` - Blazor Server runs server-side per circuit and there is no inbound tenant header to read from. The configuration value is the source of truth in dev.

## Editable Forms Against `init`-Only DTO Records

Scaffolded DTOs are `record` types with `init`-only setters (immutability is the contract between API and client). MudBlazor's `@bind-Value="Model.Title"` requires a settable property and fails to compile against `init` with `CS8852: Init-only property ... can only be assigned in an object initializer`.

Edit pages must declare **local mutable fields** for every editable property and project a `with`-expression on submit:

```razor
@page "/tasks/{Id:guid?}"
@code {
    [Parameter] public Guid? Id { get; set; }

    private TaskItemDto? _model;
    private string _title = "";
    private string? _description;
    private TaskItemStatus _status;

    protected override async Task OnParametersSetAsync()
    {
        _model = Id is null ? new TaskItemDto { Title = "" } : (await Api.GetTaskItemAsync(Id.Value)).Item!;
        _title = _model.Title;
        _description = _model.Description;
        _status = _model.Status;
    }

    private async Task SaveAsync()
    {
        var dto = _model! with
        {
            Title = _title,
            Description = _description,
            Status = _status,
        };
        await Api.UpdateTaskItemAsync(dto.Id, new DefaultRequest<TaskItemDto> { Item = dto });
    }
}

<MudTextField @bind-Value="_title" Label="Title" />
<MudTextField @bind-Value="_description" Label="Description" />
<MudSelect @bind-Value="_status" Label="Status">@* ... *@</MudSelect>
```

**Why not just drop `init` from DTOs?** Because the `Updater`-pattern projection in [data-persistence.md](data-persistence.md) and `with`-based testing rely on records being immutable, and `set` members would propagate noise into every service that serializes DTOs. Keep DTOs `init`; mutate locally.

**Non-negotiables:**
- One local field per bound property - do not try to project intermediate types or use computed properties on the DTO.
- Re-baseline against the local fields, not the DTO, in the unsaved-changes prompt (see *Unsaved-Changes Prompt on Navigation*).
- Convert to and from the DTO at the page's edges (`OnParametersSetAsync` and `SaveAsync`); the middle of the page should not see the DTO record at all.

## File Uploads (Multipart)

`AttachmentDto` is metadata-only; the realistic upload path posts the file body as `multipart/form-data`. A pure JSON `Create` endpoint cannot carry an `IFormFile`.

**Service contract** - add the streaming overload alongside any metadata-only method:

```csharp
public interface I{Project}AttachmentService
{
    Task<Result<DefaultResponse<AttachmentDto>>> UploadAsync(
        Stream content, string fileName, string contentType,
        string ownerType, Guid ownerId, CancellationToken ct = default);
}
```

**API endpoint** - `[Multipart]` consumer with antiforgery disabled (browser form posts without an antiforgery token from the Blazor host):

```csharp
group.MapPost("/upload", async (
    [FromForm] IFormFile file,
    [FromForm] string ownerType,
    [FromForm] Guid ownerId,
    I{Project}AttachmentService service,
    CancellationToken ct) =>
{
    await using var stream = file.OpenReadStream();
    var result = await service.UploadAsync(stream, file.FileName, file.ContentType, ownerType, ownerId, ct);
    return result.ToHttpResult();
})
.DisableAntiforgery()
.WithMetadata(new ConsumesAttribute("multipart/form-data"))
.RequireAuthorization(); // omit during auth-off scaffolding
```

**Refit method** - `[Multipart]` attribute, `StreamPart` for the file body, `[AliasAs]` for each form field:

```csharp
public interface I{Project}ApiClient
{
    [Multipart]
    [Post("/v1/attachments/upload")]
    Task<DefaultResponse<AttachmentDto>> UploadAttachmentAsync(
        [AliasAs("file")] StreamPart file,
        [AliasAs("ownerType")] string ownerType,
        [AliasAs("ownerId")] Guid ownerId,
        CancellationToken ct = default);
}
```

**Blazor `MudFileUpload` call site:**

```razor
<MudFileUpload T="IBrowserFile" FilesChanged="UploadFileAsync" Accept=".pdf,.png,.jpg" />

@code {
    private async Task UploadFileAsync(IBrowserFile file)
    {
        await using var stream = file.OpenReadStream(maxAllowedSize: 25 * 1024 * 1024);
        var part = new StreamPart(stream, file.Name, file.ContentType);
        await FloatService.ExecuteWithProgressAsync(
            () => Api.UploadAttachmentAsync(part, "TaskItem", _model!.Id),
            errorMessage: $"Upload failed for {file.Name}");
    }
}
```

**Non-negotiables:**
- `OpenReadStream(maxAllowedSize: ...)` - the default is 512 KB and silently truncates larger files in WASM.
- `.DisableAntiforgery()` on the endpoint - without it, browser-originated multipart posts are rejected. Re-enable per-route when antiforgery is wired post-scaffold.
- `[Multipart]` on the Refit method **and** `[AliasAs]` on every parameter - Refit's default name mangler emits PascalCase which the model binder fails to match.
- Stream the file (`OpenReadStream`) instead of buffering to a byte array - large uploads OOM the circuit otherwise.

## MudBlazor 9.x API Gotchas

These are changes from MudBlazor 7/8 -> 9.x that bite on scaffold and are cheap to avoid up-front:

| Construct | Old | **9.x (use this)** |
|---|---|---|
| Confirm dialog | `DialogService.ShowMessageBox(title, message, yesText:, cancelText:)` | `DialogService.ShowMessageBoxAsync(new MessageBoxOptions { Title, Message, YesText, CancelText })` |
| Expansion panel initial state | `IsInitiallyExpanded="true"` | `Expanded="true"` |
| `MudChip` | non-generic | `<MudChip T="string">` - type parameter is now required |

The MudBlazor analyzer emits `MUD0002 Illegal Attribute` warnings for several of these - treat them as errors during scaffolding.

**Version drift on `ShowMessageBoxAsync`.** Some MudBlazor 9.x point releases ship without the `ShowMessageBoxAsync` extension (or expose only the legacy synchronous `ShowMessageBox` that has been pulled in others). Before relying on it, grep the installed package: `dotnet list package | findstr MudBlazor` then check `IDialogService` for the method. If absent, **ship a `ConfirmDialog.razor` scaffold component** and route every confirm prompt through `DialogService.ShowAsync<ConfirmDialog>(...)`:

```razor
@* Components/Dialogs/ConfirmDialog.razor *@
@inherits MudComponentBase

<MudDialog>
    <DialogContent><MudText>@Message</MudText></DialogContent>
    <DialogActions>
        <MudButton OnClick="Cancel">@CancelText</MudButton>
        <MudButton Color="Color.Error" Variant="Variant.Filled" OnClick="Confirm">@ConfirmText</MudButton>
    </DialogActions>
</MudDialog>

@code {
    [CascadingParameter] private IMudDialogInstance MudDialog { get; set; } = default!;
    [Parameter] public string Message { get; set; } = "Are you sure?";
    [Parameter] public string ConfirmText { get; set; } = "Confirm";
    [Parameter] public string CancelText { get; set; } = "Cancel";

    private void Confirm() => MudDialog.Close(DialogResult.Ok(true));
    private void Cancel()  => MudDialog.Cancel();
}
```

Caller pattern:

```csharp
var parameters = new DialogParameters
{
    ["Message"] = "Discard unsaved changes?",
    ["ConfirmText"] = "Discard",
};
var dialog = await DialogService.ShowAsync<ConfirmDialog>("Confirm", parameters);
var result = await dialog.Result;
if (result is { Canceled: false, Data: true }) { /* proceed */ }
```

Decide once per scaffold (`ShowMessageBoxAsync` vs `ConfirmDialog`) and use the same pattern everywhere - mixing them produces inconsistent confirm UX and doubles the surface to maintain. Alternative: pin MudBlazor to a known-good 8.x range in `Directory.Packages.props` until v9 ships a documented confirm helper.

## Server-Side Table Paging

Use `<MudTable ServerData="LoadServerData">` for any list bigger than a couple dozen rows. The callback receives a `TableState` with `Page` and `PageSize` and must return a `TableData<T>`:

```csharp
private async Task<TableData<TaskItemDto>> LoadServerData(TableState state, CancellationToken ct)
{
    var req = new SearchRequest<TaskItemSearchFilter>
    {
        PageIndex = state.Page + 1,  // MudTable is 0-based; server API is 1-based
        PageSize = state.PageSize,
        Filter = new TaskItemSearchFilter { SearchTerm = _searchTerm }
    };
    var page = await FloatService.ExecuteWithProgressAsync(() => Api.SearchTaskItemsAsync(req, ct));
    return new TableData<TaskItemDto>
    {
        Items = page?.Data ?? Enumerable.Empty<TaskItemDto>(),
        TotalItems = page?.Total ?? 0
    };
}
```

`MudTable.Page` is 0-based, the API is 1-based. Do the `+1` at the boundary here so the rest of the code sees the server's 1-based convention.

## Auth

**Scaffold with auth off.** Gateway dev mode ships a no-op JWT bearer handler that accepts unauthenticated calls - lean on it for the first vertical slice, add auth once CRUD is wired.

### WebAssembly -> MSAL

```csharp
builder.Services.AddMsalAuthentication(options =>
{
    builder.Configuration.Bind("EntraExternal", options.ProviderOptions.Authentication);
    options.ProviderOptions.LoginMode = "redirect";
    var scopes = builder.Configuration.GetSection("Gateway:Scopes").Get<string[]>() ?? [];
    foreach (var s in scopes) options.ProviderOptions.DefaultAccessTokenScopes.Add(s);
});

builder.Services.AddScoped<ApiAuthHandler>();  // DelegatingHandler

builder.Services.AddRefitClient<I{Project}ApiClient>(...)
    .ConfigureHttpClient(c => c.BaseAddress = new Uri(gatewayUrl))
    .AddHttpMessageHandler<ApiAuthHandler>();
```

`ApiAuthHandler` reads the token from `IAccessTokenProvider` in `SendAsync` and sets `Authorization: Bearer <token>`.

### Server -> cookie + forward bearer

For Blazor Server, auth at the edge is a cookie (OIDC), and the server forwards a service-principal bearer token to the Gateway. Use Microsoft.Identity.Web server-side; the Gateway's `TokenService` pattern handles the rest.

See [identity-management.md](identity-management.md) for Entra External ID registration details - the UI app registration values slot into the `EntraExternal` section of `appsettings.json`.

## appsettings.json

```json
{
  "Gateway": {
    "BaseUrl": "https://localhost:7120",
    "Scopes": [ "api://{api-app-id}/DefaultAccess" ]
  },
  "EntraExternal": {
    "Authority": "https://{tenant}.ciamlogin.com/{tenant}.onmicrosoft.com",
    "ClientId": "__SETTINGS_ENTRA_CLIENTID__",
    "ValidateAuthority": false
  }
}
```

[WASM] - file lives under `wwwroot/appsettings.json`. Server - at project root (same as an API). Development override is `appsettings.Development.json` in the same folder.

Gateway CORS must include the Blazor origin:

```json
"CorsSettings": {
  "AllowedOrigins": [ "https://localhost:7201", "http://localhost:5201" ]
}
```

Add both the HTTPS and HTTP dev URLs declared in `launchSettings.json`.

## MainLayout Pattern

```razor
@inherits LayoutComponentBase
@inject FloatService FloatService
@implements IDisposable

<MudThemeProvider IsDarkMode="_dark" />
<MudPopoverProvider />
<MudDialogProvider />
<MudSnackbarProvider />

<MudLayout>
    <MudAppBar Elevation="1" Dense="true">
        <MudIconButton Icon="@Icons.Material.Filled.Menu" OnClick="@(() => _open = !_open)" />
        <MudText Typo="Typo.h6" Class="ml-3">{Project}</MudText>
        @if (!string.IsNullOrWhiteSpace(FloatService.ModuleName))
        {
            <MudText Typo="Typo.subtitle1" Class="ml-3">/ @FloatService.ModuleName</MudText>
        }
        @if (FloatService.RequestIsActive)
        {
            <MudProgressCircular Indeterminate="true" Size="Size.Small" Class="ml-3" />
        }
    </MudAppBar>
    <MudDrawer @bind-Open="_open" Variant="DrawerVariant.Responsive" ClipMode="DrawerClipMode.Always">
        <MudNavMenu>
            <MudNavLink Href="/" Match="NavLinkMatch.All">Dashboard</MudNavLink>
            <MudNavLink Href="/tasks">Tasks</MudNavLink>
            @* ... *@
        </MudNavMenu>
    </MudDrawer>
    <MudMainContent>
        <MudContainer MaxWidth="MaxWidth.False" Class="pa-4">@Body</MudContainer>
    </MudMainContent>
</MudLayout>

@code {
    private bool _open = true;
    private bool _dark;
    protected override void OnInitialized() => FloatService.StateHasChanged = StateHasChanged;
    public void Dispose()
    {
        if (FloatService.StateHasChanged == StateHasChanged)
            FloatService.StateHasChanged = null;
    }
}
```

**Non-negotiables:**
- Exactly one of each provider (`MudTheme`, `MudPopover`, `MudDialog`, `MudSnackbar`) - at the layout root
- Dispose clears `FloatService.StateHasChanged` - without this the layout's delegate survives navigation and fires into a disposed component

## Unsaved-Changes Prompt on Navigation

Detail pages with editable fields must prompt before the user leaves via any navigation - top menu (`MudNavLink`), back button, `Nav.NavigateTo`, or browser back. Use `NavigationManager.RegisterLocationChangingHandler`.

`MudNavLink` renders a standard `<a>` that triggers `NavigationManager.NavigateTo`, so `LocationChanging` fires reliably. **No custom click handler is required on Blazor** (this differs from Uno, which needs a code-behind handler because `PanelVisibilityNavigator` can silently no-op - see [ui-uno-mvux.md](ui-uno-mvux.md) -> *Menu Navigation: Always Land On Top Page*).

```razor
@page "/tasks/{Id:guid}"
@implements IDisposable
@inject NavigationManager Nav
@inject IDialogService DialogService

@code {
    private TaskItemDto? _model;
    private TaskItemDto? _baseline;
    private DateTime? _startDate, _dueDate;
    private DateTime? _baselineStart, _baselineDue;
    private IDisposable? _locationChangingRegistration;
    private bool _bypassDirtyCheck;

    protected override void OnInitialized()
    {
        _locationChangingRegistration = Nav.RegisterLocationChangingHandler(OnLocationChangingAsync);
    }

    protected override async Task OnParametersSetAsync()
    {
        // ... load model ...
        CaptureBaseline();   // snapshot initial state AFTER load
    }

    private void CaptureBaseline()
    {
        _baseline = _model is null ? null : _model with { };
        _baselineStart = _startDate;
        _baselineDue = _dueDate;
    }

    private bool IsDirty()
    {
        if (_model is null || _baseline is null) return false;
        return _model.Title != _baseline.Title
            || _model.Description != _baseline.Description
            || _model.Status != _baseline.Status
            || _model.Priority != _baseline.Priority
            || _model.CategoryId != _baseline.CategoryId
            || _startDate != _baselineStart
            || _dueDate != _baselineDue;
    }

    private async ValueTask OnLocationChangingAsync(LocationChangingContext ctx)
    {
        if (_bypassDirtyCheck || !IsDirty()) return;

        var confirm = await DialogService.ShowMessageBoxAsync(new MessageBoxOptions
        {
            Title = "Discard unsaved changes?",
            Message = "You have unsaved edits. Leave and discard them?",
            YesText = "Discard", CancelText = "Stay",
        });
        if (confirm != true) ctx.PreventNavigation();
    }

    private async Task SaveAsync()
    {
        // ... save ...
        CaptureBaseline();               // re-baseline after successful update
        _bypassDirtyCheck = true;         // suppress prompt on post-save redirect
        Nav.NavigateTo($"/tasks/{id}");
    }

    private async Task DeleteAsync()
    {
        // ... delete ...
        _bypassDirtyCheck = true;
        Nav.NavigateTo("/tasks");
    }

    public void Dispose() => _locationChangingRegistration?.Dispose();
}
```

Non-negotiables:

- **Register in `OnInitialized`, dispose in `Dispose`.** A leaked handler fires on every navigation for the rest of the circuit's life - including after the component is gone - producing ghost prompts.
- **Capture baseline AFTER `OnParametersSetAsync` loads the model**, not in `OnInitialized`. Initial load mutates `_model` and would fire as false-dirty if the baseline were taken earlier.
- **Re-baseline inside `SaveAsync` on success** so a user who saves and then keeps editing gets a fresh comparison point.
- **Set `_bypassDirtyCheck = true` before the post-save / post-delete `Nav.NavigateTo`**. Otherwise the prompt fires on your own programmatic redirect.
- **Diff by scalar fields only** for the base dirty check. Buffered children (new checklist item text, pending comment body) count too if your form has them - include them in `IsDirty()` explicitly.
- **Record `with { }` copy is enough** to snapshot a `record` DTO; the form only mutates top-level scalar properties.

## Editing Parent Aggregates with Child Collections

When a page edits an aggregate root whose children are synced by the server `Updater` (e.g., `TaskItem` with `ChecklistItems` + `Comments`), the UI holds children as local state on the parent DTO and persists in the **single** Create/Update call. Per-child Create/Update/Delete endpoints exist for direct-access flows - **do not** call them from the aggregate edit page: each click becomes a round trip, Cancel leaves partial persists behind, and the parent's validation / transactional boundary is bypassed.

### Pattern

```razor
@* Bind list-panels directly to _model.ChildItems and _model.Comments. *@
@foreach (var item in Checklist) { ... }

@code {
    private TaskItemDto? _model;
    private bool _childrenDirty;

    // Convenience accessors - `_model` is non-null by the time the UI renders these.
    private List<ChecklistItemDto> Checklist => _model!.ChecklistItems ??= new();
    private List<CommentDto> Comments => _model!.Comments ??= new();

    // IsNew branch seeds empty child lists so the Updater sees an empty
    // collection (not null) and knows there's nothing to insert.
    _model = new TaskItemDto
    {
        Title = string.Empty,
        ChecklistItems = new(),
        Comments = new()
    };

    // Add/Toggle/Delete are local-only - no API call.
    private void AddChecklist() { Checklist.Add(new ChecklistItemDto { ... }); _childrenDirty = true; }
    private void ToggleChecklist(ChecklistItemDto item, bool done)
    {
        var i = Checklist.IndexOf(item);
        if (i >= 0) { Checklist[i] = item with { IsCompleted = done }; _childrenDirty = true; }
    }
    private void DeleteChecklist(ChecklistItemDto item) { if (Checklist.Remove(item)) _childrenDirty = true; }
}
```

### Non-negotiables

- **Local mutation only** - Add/Toggle/Delete mutate the parent DTO's list; they do not call the API. `SaveAsync` sends the full tree via `Create{Entity}Async` / `Update{Entity}Async`.
- **Seed empty lists on IsNew** - initialize `ChecklistItems = new()` / `Comments = new()` so the Updater has a collection to iterate (null != empty for some sync utilities, and null-coalesce is defensive, not definitive).
- **GET must `.Include()` children.** The edit page must not need a separate child search. If children are missing on load, fix the query repo's includes (see [data-persistence.md](data-persistence.md)).
- **Include `_childrenDirty` in `IsDirty()`** so the unsaved-changes prompt fires on child-only edits. A dirty flag is simpler than deep-comparing record collections.
- **Re-sort / normalize children after save.** The response DTO reflects the new persisted state (fresh IDs, server-assigned sort orders) - re-apply client-side ordering (`OrderBy(c => c.SortOrder)`) before re-baselining.
- **Server-side counterpart**: `UpdateAsync` must call `repoTrxn.UpdateFromDto(entity, dto, RelatedDeleteBehavior.RelationshipAndEntity)`. The default `None` silently drops client-side removals. See [data-persistence.md](data-persistence.md) -> Updater Pattern.
- **Toggle via list index, not reference**, when replacing a `record` in-place (`Checklist[i] = item with { IsCompleted = done }`). Records are reference types but `with` returns a new instance - `FindIndex(c => c == item)` works via value equality, but `IndexOf(item)` against the current list entry is simpler and safer.

### Anti-patterns

- Calling `Api.CreateChecklistItemAsync` / `Api.DeleteCommentAsync` from the parent edit page.
- Keeping parallel `_checklist` / `_comments` fields alongside `_model.ChecklistItems` / `_model.Comments` - they drift, and one of them ends up being the payload while the other drives the UI.
- Leaving `TaskItemService.UpdateAsync` with `UpdateFromDto(entity, dto)` - child removals never persist.

## Generation Checklist

- [ ] `includeBlazorUI: true` set in domain inputs
- [ ] `Gateway:BaseUrl` present in `appsettings*.json`
- [ ] MudBlazor + Refit + Refit.HttpClientFactory versions in `Directory.Packages.props`
- [ ] `Program.cs` registers `FloatService` as scoped, MudBlazor services, Refit client with JSON options + resilience
- [ ] `App.razor` and `Routes.razor` apply `@rendermode="InteractiveServer"` (Server) or use `Router` under the WASM root (WASM)
- [ ] `MainLayout.razor` wires all four Mud providers, `FloatService.StateHasChanged` bound in `OnInitialized`, cleared in `Dispose`
- [ ] Refit interface uses `DefaultRequest<T>` for POST/PUT bodies, `DefaultResponse<T>` for single-item returns, `SearchRequest<T>`/`PagedResponse<T>` for search
- [ ] `SearchRequest.PageIndex` passed 1-based to the API
- [ ] MudBlazor 9.x: `ShowMessageBoxAsync` (not `ShowMessageBox`), `Expanded` (not `IsInitiallyExpanded`), `<MudChip T="...">`
- [ ] Gateway `CorsSettings.AllowedOrigins` includes the Blazor dev URLs
- [ ] Pages: Dashboard, {Entity}List (server paging + filters), {Entity}Page (new/edit), Settings, Error
- [ ] Blazor UI calls the Gateway only - never the API host directly
- [ ] Aggregate edit pages bind children to `_model.<Collection>` and persist via the single Create/Update call (no per-child API calls) - see *Editing Parent Aggregates with Child Collections*

## Coexistence With Uno

A second UI head is most often an **admin/operator portal** distinct from the primary end-user app - the canonical multi-head case. Blazor Server is the default suggestion for that internal/data-dense management head even when the end-user app is React/Vite or Uno WASM. Decide this in Phase 1 from the persona -> UI-surface mapping, not after Phase 4 fixes the layout: see [shared-understanding-interview.md section Multi-Head UI Decision](../ai/shared-understanding-interview.md#multi-head-ui-decision). Mechanically it means enabling a second host flag (`includeBlazorUI` alongside `includeReactUI`/`includeUnoUI`).

Both clients can ship side-by-side under `src/UI/`:

```
src/UI/
  {Project}.Uno/
  {Project}.Uno.Core/
  {Project}.Blazor/
```

Share the same contract types (`{Project}.Application.Models` project). Do **not** duplicate DTOs in either UI project - the shared project reference is the single source of truth. Keep the Refit interface in the Blazor project isomorphic to the Uno client builder: same resource groups, same parameters, same envelope, so a bug found on one side fixes both by the same rule.

## Related Skills

- Alternative UI: [ui-uno.md](ui-uno.md)
- Solution layout: [solution-structure.md](solution-structure.md)
- Gateway integration: [gateway.md](gateway.md)
- Auth setup: [identity-management.md](identity-management.md)
- App configuration: [configuration-secrets.md](configuration-secrets.md)
