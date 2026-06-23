# Blazor UI

## Purpose

Scaffold a Blazor UI (Server or WebAssembly) that calls the **Gateway** (YARP), not backend APIs directly. This is an alternative to [ui-uno.md](ui-uno.md) and [ui-react.md](ui-react.md) - pick one or offer explicit siblings under `src/UI/`.

- **UI**: MudBlazor shell + components
- **State**: `FloatService` (scoped singleton) shared across layout and pages - **not** cascading parameters
- **Client**: Refit (`Refit.HttpClientFactory`) against the Gateway base URL
- **Auth**: MSAL WebAssembly for WASM builds; JWT bearer cookie/claims for Server. Scaffold auth-off and add after first vertical slice works

Reference app: [TaskFlow.Blazor](https://github.com/efreeman518/AI-Instructions-ReferenceApp/tree/main/src/UI/TaskFlow.Blazor) and the Caller Portal ([Portal.UI1](https://github.com/efreeman518/Portal/tree/main/src/Portal/Portal.UI1)) - canonical source of the FloatService + Refit + MudBlazor layering.

Companion file:
- [ui-blazor-forms.md](ui-blazor-forms.md) - on-demand: editable `init`-only forms, unsaved-changes prompt, parent-aggregate child editing, file uploads, server-side paging, `ShowMessageBoxAsync` fallback. Load when building an `{Entity}Page` (add/edit), upload, or paged list. This file is the always-needed spine.

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

**Non-negotiable:** `@rendermode="InteractiveServer"` on both `HeadOutlet` and `Routes`. Registering an interactive render mode in `Program.cs` (`AddInteractiveServerComponents` + `AddInteractiveServerRenderMode`) does nothing on its own - no component opts in, so Blazor serves everything as **static SSR** and every interaction (theme toggle, dialogs, grid actions, buttons) silently no-ops with no error. The component must opt in via `@rendermode`.

Naming trap: the bare shorthand `InteractiveServer` (used above) requires `@using static Microsoft.AspNetCore.Components.Web.RenderMode` (present in `_Imports.razor` below). The qualified form `@rendermode="RenderMode.InteractiveServer"` works with the default imports and no `using static`. Pick one; do not mix a bare shorthand with missing imports (compile error) or a missing `@rendermode` (dead interactivity).

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
- **Reuse the shared `SearchRequest<T>` / `PagedResponse<T>` from `EF.Common.Contracts`** (via the `{Project}.Application.Models` reference) - do not redefine envelopes in the Blazor project. The page-index base (0- vs 1-based) is a property of the running API, not a constant: verify it empirically (request page 0 vs page 1 against a seeded list and inspect which returns the first row) before wiring the pager. Do not hard-code an assumed base - sending the wrong one silently returns the same page on every request.

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
- This config-value rule is for the **read** path (tenant header on outbound calls) only. Create DTOs must **not** carry a client-populated `TenantId` or owner - the API stamps both server-side from the request context. See [../patterns/api-host-wiring.md](../patterns/api-host-wiring.md) section Dev-Mode Write Identity. The UI sends the domain fields; identity is the server's job.

## Forms & Interaction Patterns

The `{Entity}Page` (unified add/edit) and any upload or paged-list surface use the situational patterns in the on-demand companion [ui-blazor-forms.md](ui-blazor-forms.md). Load it when building those pages:

- **Editable forms against `init`-only DTO records** - local mutable fields + `with`-projection on submit.
- **Unsaved-changes prompt on navigation** - `RegisterLocationChangingHandler` + baseline / `_bypassDirtyCheck`.
- **Editing parent aggregates with child collections** - local child state, single Create/Update call (no per-child API calls).
- **File uploads (multipart)** - service overload, `[Multipart]` endpoint/Refit, `MudFileUpload` call site.
- **Server-side table paging** - `MudTable ServerData` with the page-base conversion at the boundary (MudTable is 0-based; convert to the base the API expects - verify empirically).
- **MudBlazor `ShowMessageBoxAsync` fallback** - `ConfirmDialog.razor` when the extension is absent.

## MudBlazor API Gotchas

These MudBlazor API points bite on scaffold and are cheap to avoid up-front:

| Construct | Avoid | **Use this** |
|---|---|---|
| Confirm dialog | `DialogService.ShowMessageBox(title, message, yesText:, cancelText:)` | `DialogService.ShowMessageBoxAsync(new MessageBoxOptions { Title, Message, YesText, CancelText })` |
| Expansion panel initial state | `IsInitiallyExpanded="true"` | `Expanded="true"` |
| `MudChip` | non-generic | `<MudChip T="string">` - type parameter is now required |

The MudBlazor analyzer emits `MUD0002 Illegal Attribute` warnings for several of these - treat them as errors during scaffolding.

**API drift on `ShowMessageBoxAsync`.** Some MudBlazor releases ship without the `ShowMessageBoxAsync` extension; the `ConfirmDialog.razor` fallback and caller pattern live in [ui-blazor-forms.md](ui-blazor-forms.md) section MudBlazor `ShowMessageBoxAsync` Fallback. Decide once per scaffold (`ShowMessageBoxAsync` vs `ConfirmDialog`) and use it everywhere; pinning MudBlazor to a known-good range in `Directory.Packages.props` is the alternative.

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

## Test Selectors

Emit a stable `data-testid` on every element an E2E test drives, so Playwright selectors do not fall
back to MudBlazor-generated CSS classes (which churn across MudBlazor versions and break tests silently).
MudBlazor components forward unknown attributes to the rendered root, so `data-testid` passes through.

Required `data-testid` coverage:
- Nav links: `data-testid="nav-{entity}"` on each `MudNavLink`.
- Page actions: `new-{entity}`, `save`, `delete`, `cancel` on the `MudButton`s.
- Dialog inputs: one per field, e.g. `field-{property}` on each `MudTextField`/`MudSelect`.
- Grids: `grid-{entity}` on the table and `row-{id}` on each row.

```razor
<MudNavLink Href="/{entities}" data-testid="nav-{entity}">{Entity}</MudNavLink>
<MudButton OnClick="OpenCreate" data-testid="new-{entity}">New</MudButton>
<MudTextField @bind-Value="_title" Label="Title" data-testid="field-title" />
```

The consumption-side preference ("prefer stable selectors") lives in
[testing-quality.md](testing-quality.md); this is the generation-side rule that makes those selectors exist.

## Generation Checklist

- [ ] `includeBlazorUI: true` set in domain inputs
- [ ] `Gateway:BaseUrl` present in `appsettings*.json`
- [ ] MudBlazor + Refit + Refit.HttpClientFactory versions in `Directory.Packages.props`
- [ ] `Program.cs` registers `FloatService` as scoped, MudBlazor services, Refit client with JSON options + resilience
- [ ] `App.razor` and `Routes.razor` apply `@rendermode="InteractiveServer"` (Server) or use `Router` under the WASM root (WASM)
- [ ] `MainLayout.razor` wires all four Mud providers, `FloatService.StateHasChanged` bound in `OnInitialized`, cleared in `Dispose`
- [ ] Refit interface uses `DefaultRequest<T>` for POST/PUT bodies, `DefaultResponse<T>` for single-item returns, `SearchRequest<T>`/`PagedResponse<T>` for search
- [ ] `SearchRequest.PageIndex` uses the base the API actually expects (verified empirically; reuse `EF.Common.Contracts` `SearchRequest`/`PagedResponse`, do not redefine)
- [ ] MudBlazor: `ShowMessageBoxAsync` (not `ShowMessageBox`), `Expanded` (not `IsInitiallyExpanded`), `<MudChip T="...">`
- [ ] Gateway `CorsSettings.AllowedOrigins` includes the Blazor dev URLs
- [ ] Pages: Dashboard, {Entity}List (server paging + filters), {Entity}Page (new/edit), Settings, Error
- [ ] Blazor UI calls the Gateway only - never the API host directly
- [ ] Aggregate edit pages bind children to `_model.<Collection>` and persist via the single Create/Update call (no per-child API calls) - see [ui-blazor-forms.md](ui-blazor-forms.md) section Editing Parent Aggregates with Child Collections
- [ ] Each create form binds a field for every required `{Entity}.Create(...)` arg (or is marked a stub) - see [ui-blazor-forms.md](ui-blazor-forms.md) section Editable Forms Against `init`-Only DTO Records
- [ ] `data-testid` on nav links, New/Save/Delete buttons, dialog inputs, and grids/rows - see section Test Selectors

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
