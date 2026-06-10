# Uno Platform UI - MVUX, Routing, XAML, Business Services, Auth

Presentation-layer rules: MVUX models, navigation, XAML patterns, business-service contracts, and auth wiring. Loaded during Phase 5c when an Uno UI project is in scope.

Companion files:
- [ui-uno.md](ui-uno.md) - index + decision table
- [ui-uno-shell.md](ui-uno-shell.md) - project setup, app hosting, shell control
- [ui-uno-navigation.md](ui-uno-navigation.md) - menu "always-to-top" wiring, cross-page dirty guard
- [ui-uno-platforms.md](ui-uno-platforms.md) - WASM debugging, Android, CI requirements

---

## MVUX Model Rules

Use partial records in `Presentation/`:
- Read: `IFeed<T>` / `IListFeed<T>`
- Mutable UI state: `IState<T>` / `IListState<T>`
- Commands: public `ValueTask` methods
- Navigation: `INavigator`
- Cross-model refresh: `IMessenger` + `.Observe(...)`

### Feed Refresh After Mutations (Version Counter Pattern)

MVUX feeds are pull-based - they do not re-evaluate automatically when the underlying data changes. After a create/update/delete operation, the UI stays stale unless the feed is explicitly invalidated.

**Pattern:** Add an `IState<int>` version counter. Increment it after every mutation. Make the feed depend on the counter so it re-evaluates.

```csharp
public partial record CategoryTreeModel(
    INavigator Navigator,
    ICategoryApiService CategoryService)
{
    // Version counter - increment after any mutation
    public IState<int> CategoriesVersion => State<int>.Value(this, () => 0);

    // Feed depends on version - re-evaluates when version changes
    public IListFeed<CategoryModel> Categories => ListFeed.Async(async ct =>
    {
        _ = await CategoriesVersion;  // creates dependency
        return (await CategoryService.SearchAsync(ct: ct)).ToImmutableList();
    });

    public async ValueTask SaveCategory(CancellationToken ct)
    {
        await CategoryService.CreateAsync(/* ... */, ct);
        await CategoriesVersion.Update(v => v + 1, ct);  // triggers feed refresh
    }
}
```

**Rules:**
- One version counter per independent feed (e.g., `CommentsVersion`, `ChecklistVersion`, `AttachmentsVersion` on a detail model).
- `_ = await CategoriesVersion;` inside the feed lambda creates the dependency. Without it, incrementing the counter does nothing.
- Increment the counter as the **last step** of every mutation method (`Create`, `Update`, `Delete`, `Toggle`).
- For cross-model refresh (e.g., creating a task in `TaskFormModel` should refresh `TaskListModel`), use `IMessenger` with `.Observe(...)` instead of version counters.

### Cross-Model Refresh via Messenger

When a mutation in model A (e.g. Task Save) must refresh model B (e.g. Task List) and B is already constructed on a visible page, `IListFeed` + version counter doesn't help - the receiving model needs a push. Pattern:

1. Define a marker record message: `public sealed record TaskItemsChangedMessage(bool ResetToFirstPage = false);`
2. Receiver registers in its constructor (explicit ctor required - positional-record ctor has no body):
   ```csharp
   Messenger.Register<TaskListModel, TaskItemsChangedMessage>(this, static (recipient, msg) =>
   {
       if (msg.ResetToFirstPage) _ = recipient.LoadPageAsync(1);
       else                      _ = recipient.RefreshAsync();
   });
   ```
3. Sender sends after save: `Messenger.Send(new TaskItemsChangedMessage(ResetToFirstPage: true));`

Non-negotiables:
- Registered with **StrongReferenceMessenger** (see host wiring above) - weak references let records get collected.
- Receive handler is `static` and takes `recipient` - closing over `this` defeats weak-reference safety and produces analyzer warnings.
- Parameter name in the lambda must not be `_` (conflicts with discard in some generator paths). Use `msg` / `message`.

### Buffered Child Items in Create Mode

When a form can add/check child items (checklist, attachments, comments) before the parent entity has been saved, give each buffered item a client-generated `Guid.NewGuid()` Id so the UI can match items by Id immediately. On Save:

1. Bundle the buffered children into the parent DTO (`dto.ChecklistItems`, `dto.Comments`, ...) with `Id = null` on each - the server `Updater` will assign real Ids.
2. Send **one** POST (create) or PUT (update) for the parent + children together. Do NOT loop separate `ChildService.CreateAsync(...)` calls after the parent create - state on the buffered child (e.g. a pre-checked `IsCompleted`) gets silently dropped when the child's domain `Create()` doesn't accept that field. See [updater-template.md](../templates/updater-template.md) -> *createFunc must apply ALL DTO fields*.
3. Client DTO mapper must include the children. Easy miss: `MapToDto` that only copies scalar fields produces a payload the server parses as "no children".
4. Mutations on buffered items (e.g. toggle checked) must only hit the server if the parent is already persisted. Gate with `if (Entity?.Id is not null)` - otherwise the server returns 404 on a non-existent parent and the UI rolls back.

```csharp
// OK Correct - single payload, children embedded
var model = (Entity ?? new TaskItemModel()) with
{
    Title = title,
    /* scalar fields ... */,
    ChecklistItems = isCreate
        ? pendingChecklist.Select(c => c with { Id = null, TaskItemId = Guid.Empty }).ToList()
        : pendingChecklist.ToList(),
    Comments = isCreate
        ? pendingComments.Select(c => c with { Id = null, TaskItemId = Guid.Empty }).ToList()
        : pendingComments.ToList()
};
var saved = isCreate
    ? await TaskItemService.CreateAsync(model, ct)
    : await TaskItemService.UpdateAsync(model, ct);

// FAIL Wrong - post-create loop silently drops child fields that Create() can't take
var saved = await TaskItemService.CreateAsync(model, ct);
foreach (var c in pendingChecklist)
    await ChecklistItemService.CreateAsync(c with { Id = null, TaskItemId = saved.Id!.Value }, ct);
```

```csharp
public async ValueTask ToggleChecklistItem(ChecklistItemModel item, CancellationToken ct)
{
    var updated = item with { IsCompleted = !item.IsCompleted };

    // Update UI state first - this is the source of truth while buffered.
    await ChecklistItems.UpdateAsync((IImmutableList<ChecklistItemModel>? list) =>
    {
        var src = list ?? ImmutableList<ChecklistItemModel>.Empty;
        var idx = FindById(src, item.Id);
        return idx < 0 ? src : src.SetItem(idx, updated);
    }, CancellationToken.None);

    // Only persist if the parent already exists server-side.
    if (Entity?.Id is not null)
    {
        try { await ChecklistItemService.UpdateAsync(updated, ct); }
        catch { /* state rollback not required - buffered flow survives */ }
    }
}
```

### Menu Navigation & Cross-Page Dirty Guard

Persistent menu "always land on the top page" wiring (the three `PanelVisibilityNavigator` traps + proven click handler) and the cross-model form dirty guard moved to a dedicated companion: [ui-uno-navigation.md](ui-uno-navigation.md). Load it when building menu/navigation chrome or a detail page with unsaved-edit protection.

### WASM Console Logging: Use `Console.WriteLine`, Not `Debug.WriteLine`

In Uno WASM, `System.Diagnostics.Debug.WriteLine` does NOT reach the browser DevTools console by default - only framework `ILogger` output (prefixed `info:` / `warn:`) is routed there. For ad-hoc diagnostics in code-behind or models, use `Console.WriteLine` - it shows as a plain line in the browser console.

```csharp
Console.WriteLine($"[MainPage] NavigateTopClick tag={tag}");  // OK appears in browser console
System.Diagnostics.Debug.WriteLine("...");                    // FAIL swallowed in WASM
```

### WASM Rebuild / Hot-Reload Trap

Uno WASM dev hot-reload **does not reliably pick up code-behind changes** (XAML may hot-swap, but `.xaml.cs` edits often serve from the old `package_<hash>/` bundle). Symptoms: console logs from your new code never appear; the UI behaves as before the edit.

Recovery:

1. Stop the running host (`Ctrl+C` on `dotnet run`, or terminate the Aspire resource).
2. `dotnet build src/UI/{Project}.Uno --no-incremental` (forces a clean package hash).
3. In the browser, unregister any service worker (DevTools -> Application -> Service Workers) and hard-refresh (`Ctrl+F5`) - or open the origin in a new tab; never reload an existing tab.

Do not debug perceived "code didn't work" symptoms without verifying the new bundle actually loaded (grep for one of your new `Console.WriteLine` tags in the console).

### URL Sync: Disable AddressBarUpdateEnabled (Chefs Pattern)

The default address-bar update pipeline can lag or lock on a prior route after nested navigation, leaving the browser URL stuck at e.g. `/Main/Categories` while the content has moved on. Match the Chefs reference app by disabling it:

```csharp
.UseNavigation(
    ReactiveViewModelMappings.ViewModelMappings,
    RegisterRoutes,
    configure: navConfig => navConfig with { AddressBarUpdateEnabled = false });
```

The app is still fully navigable via the in-app menu; only the browser URL stops reflecting internal route changes. This is the documented trade-off in Chefs.

### Navigation: Prefer NavigateBackAsync Over Hardcoded Routes

Save/Cancel actions should use `Navigator.NavigateBackAsync(this)` instead of `Navigator.NavigateRouteAsync(this, "Dashboard")`. Hardcoded route names break when the user arrives from a different page (e.g., navigating to TaskForm from TaskList vs Dashboard).

```csharp
// OK Correct - returns to wherever the user came from
await Navigator.NavigateBackAsync(this, cancellation: ct);

// FAIL Wrong - always goes to Dashboard even if user came from TaskList
await Navigator.NavigateRouteAsync(this, "Dashboard", cancellation: ct);
```

### ListView Item Click Navigation

To make ListView items navigable (e.g., clicking a task row opens its detail page), wrap the item template content in a `Button` with `uen:Navigation.Request` and `uen:Navigation.Data`:

```xml
<ListView ItemsSource="{Binding Data.RecentActivity}" SelectionMode="None">
    <ListView.ItemTemplate>
        <DataTemplate>
            <Button uen:Navigation.Request="{Entity}Item"
                    uen:Navigation.Data="{Binding}"
                    HorizontalAlignment="Stretch"
                    HorizontalContentAlignment="Stretch"
                    Background="Transparent"
                    BorderThickness="0"
                    Padding="0" Margin="0,3">
                <!-- Item visual content here -->
            </Button>
        </DataTemplate>
    </ListView.ItemTemplate>
</ListView>
```

**Do not** rely on `ListView.SelectionChanged` or `ItemClick` for navigation - these are less reliable with MVUX data binding than the declarative `uen:Navigation.Request` approach.

### MVUX Pitfalls

- **`Feed.Async` type inference**: `Feed.Async(service.GetAsync)` may fail with CS0411/CS0453 when the return type is a reference type or the delegate signature is ambiguous. Always use an explicit lambda: `Feed.Async(async ct => await service.GetAsync(ct))`.
- **`IListFeed` return type**: `ListFeed.Async(...)` callbacks must return `IImmutableList<T>`. Call `.ToImmutableList()` on results. Requires `using System.Collections.Immutable;` (add as global using in csproj, see Project File Rules).
- **Nullable state**: `IState<T?>` with `State.UpdateAsync` produces CS8714 warnings. Suppress with `#nullable disable` in the record or accept the warning - it's cosmetic.
- **No optional parameters on command methods**: The MVUX Bindable generator emits a compile error like `CS0103: The name 'False' does not exist` when a command method has an optional parameter (e.g. `public ValueTask Refresh(bool hard = false, CancellationToken ct = default)`). Split into two methods (`Refresh(ct)` + `RefreshHard(ct)`) or take the parameter as state instead. CancellationToken default is fine.
- **`IListState<T>.UpdateAsync` overload ambiguity**: There are two overloads - one updates a single item, one updates the whole list. When you pass a bare lambda the compiler picks the single-item one and you get `'IImmutableList<T>' does not contain 'FindIndex'` or `Operator '??' cannot be applied...`. Explicitly type the parameter to disambiguate:
  ```csharp
  await Items.UpdateAsync((IImmutableList<ChildModel>? list) =>
  {
      var src = list ?? ImmutableList<ChildModel>.Empty;
      var idx = /* find */;
      return idx < 0 ? src : src.SetItem(idx, updated);
  }, CancellationToken.None);
  ```
- **Don't cancel state writes with the command's CT**: MVUX commands flip `IsEnabled` bindings during execution, which can cascade back and cancel the command's own `CancellationToken` mid-state-update, leaving state half-written. For `UpdateAsync` calls that must complete, pass `CancellationToken.None`. Only use the command CT on the outbound HTTP / service call.
- **Command-CT cancels mid-HTTP**: Same mechanism cancels the HTTP call to the server. If a state update during the request flips an IsEnabled binding, the command CT is cancelled and the fetch aborts. For navigation-triggering commands (Save/Update), pass `CancellationToken.None` to the service call too.
- **Prefer individual `IState<T>` fields over a wrapped result object**: Binding a XAML pager/grid to `Data.PageNumber`, `Data.HasNextPage`, etc. via a single `IState<PageResult>` breaks: the generated bindable surfaces `Data` as a snapshot and child paths don't re-evaluate on partial updates. Declare one `IState<int> PageNumber`, `IState<bool> HasNextPage`, `IListState<T> Items`, etc. and update each explicitly in the load method.

Example pattern:

```csharp
public partial record TodoItemListModel(
    INavigator Navigator,
    ITodoItemService Service,
    IMessenger Messenger)
{
    public IListFeed<TodoItemModel> Items => ListFeed.Async(Service.GetAll);

    public IState<string> SearchTerm => State<string>.Value(this, () => string.Empty);

    public IListState<TodoItemModel> FilteredItems => ListState
        .FromFeed(this, Feed.Combine(SearchTerm, Items.AsFeed())
            .SelectAsync(Filter)
            .AsListFeed())
        .Observe(Messenger, x => x.Id);

    public ValueTask OpenDetail(TodoItemModel item, CancellationToken ct) =>
        Navigator.NavigateRouteAsync(this, "TodoItemDetail", data: item, cancellation: ct);
}
```

## Routing + Mapping

- Define `ViewMap`/`DataViewMap` in one route registration method.
- Keep route names stable (`Home`, `{Entity}List`, `{Entity}Item`, `Settings`).
- **One route per entity** for add/edit: `{Entity}Item` receives optional entity data (null = create, non-null = edit).
- Pass selected entity as route data for the entity page.

### Route Architecture (Shell vs MainPage)

Shell and MainPage serve **distinct roles** in the navigation hierarchy. Mixing them breaks the navigation bootstrap.

| Layer | View | Contains | Route binding |
|-------|------|----------|---------------|
| Root | `Shell` | `ExtendedSplashScreen` + `Frame` only | Viewless `ShellModel` at root `""` |
| Chrome | `MainPage` | Header bar, sidebar/bottom `TabBar`, content `Frame` or region | `ViewMap<MainPage, MainModel>` nested under root, `IsDefault: true` |
| Content | Page views | Page-specific UI | Nested under `Main` route |

**Critical**: Shell must NOT contain app chrome (headers, tabs, navigation bars). The `ExtendedSplashScreen` manages the navigation bootstrap chain - placing chrome in Shell means it either gets covered by the splash screen or, when the splash is removed, the navigation Frame stops receiving page content.

**Why chrome cannot live inside `Splash.Content`**: Uno's navigation bootstrap replaces the entire `ExtendedSplashScreen.Content` subtree with a `FrameView` at runtime once the host finishes loading. Any Grid/Border/StackPanel you author inside `Splash.Content` is thrown away - observable symptom is a header or nav bar that renders before the splash clears and then vanishes. All persistent chrome belongs in **MainPage**, never in Shell.

### Route Registration Pattern (Chefs-Aligned)

```csharp
private static void RegisterRoutes(IViewRegistry views, IRouteRegistry routes)
{
    views.Register(
        // Viewless root - Shell resolves via NavigateAsync<Shell>()
        new ViewMap(ViewModel: typeof(ShellModel)),
        // MainPage is the app chrome shell (header, tabs, content frame)
        new ViewMap<MainPage, MainModel>(),
        new ViewMap<DashboardPage, DashboardModel>(),
        new ViewMap<{Entity}ListPage, {Entity}ListModel>(),
        // Single entity page - Entity? data: null=create, non-null=edit
        new ViewMap<{Entity}Page, {Entity}PageModel>(Data: new DataMap<{Entity}Model>()),
        new ViewMap<SettingsPage, SettingsModel>()
    );

    routes.Register(
        new RouteMap("", View: views.FindByViewModel<ShellModel>(),
            Nested:
            [
                new RouteMap("Main", View: views.FindByViewModel<MainModel>(), IsDefault: true,
                    Nested:
                    [
                        new RouteMap("Dashboard", View: views.FindByViewModel<DashboardModel>(), IsDefault: true),
                        new RouteMap("{Entity}List", View: views.FindByViewModel<{Entity}ListModel>()),
                        new RouteMap("{Entity}Item", View: views.FindByViewModel<{Entity}PageModel>()),
                    ]
                ),
                // Routes outside Main (no tab bar chrome)
                new RouteMap("Settings", View: views.FindByViewModel<SettingsModel>()),
            ]
        )
    );
}
```

> **Naming collision avoidance**: If the entity model is `{Entity}Model` (e.g., `TaskItemModel`) and the presentation model would also be `{Entity}Model`, append `PageModel` to the presentation class (e.g., `TaskItemPageModel`). Use the full namespace qualifier in `ViewMap`/`RouteMap` if needed.

### Route Non-Negotiables

1. **Root ViewMap is viewless**: `new ViewMap(ViewModel: typeof(ShellModel))` - no `<TView>` type parameter. Shell is resolved by `NavigateAsync<Shell>()`, not by the route map.
2. **MainPage is a nested route with `IsDefault: true`**: The navigation system navigates Shell -> Main -> Dashboard. Without the `Main` intermediate route, page content renders directly in Shell's Frame with no chrome.
3. **Tab routes nest under Main**: Dashboard, entity lists, and other tab-navigable pages must be children of the `Main` route so they render inside MainPage's content region (which has `uen:Region.Attached="True"`).
4. **Chrome-free routes nest under root**: Settings, login, profile - routes that should NOT show the tab bar - go as siblings of `Main`, not children of it.

## XAML Rules

- Code-behind stays minimal (initialize + thin UI-only behaviors).
- Put visual tokens and style overrides in `Styles/` dictionaries.
- Use converters from `Converters/` for presentation-only formatting.
- Keep reusable UI in `Views/Controls` and shared templates in `Views/Templates`.

### XAML Pitfalls

- **`TreeViewItemTemplateSelector`** does not exist. Use `<DataTemplate>` directly inside `<TreeView.ItemTemplate>`.
- **`uen:NavigationBar`** (`Uno.Extensions.Navigation.UI.NavigationBar`) does not exist. For top bars use `utu:NavigationBar` from `Uno.Toolkit.UI`, or omit and rely on `NavigationView` header.
- **`uen:ContentControl`** doesn't exist. For navigation content regions, use `<Frame />` inside a `<Grid uen:Region.Attached="true">`.
- **`NavigationView` content area**: Place a `<Grid uen:Region.Attached="true"><Frame /></Grid>` as the `NavigationView` content for region-based navigation.
- **`utu:AutoLayout.PrimaryAlignment`** valid values are `Stretch`, `Center`, `End` - there is no `Start`. Using `Start` produces a XAML parse error with no useful message. Default to `Stretch` for full-width content.

### Responsive Menu Pattern (Side-Nav Wide / Bottom-Tabs Narrow)

Use `utu:Responsive` with `Normal` (mobile/narrow) and `Wide` (desktop) breakpoints to toggle visibility of two parallel menu trees inside MainPage. Keep a single content region between them.

```xml
<!-- Desktop side nav -->
<Border Grid.Column="0"
        Visibility="{utu:Responsive Normal=Collapsed, Wide=Visible}"
        Width="160">
    <StackPanel Orientation="Vertical" ...>
        <Button Click="NavigateTopClick" Tag="Dashboard" .../>
        <!-- ... -->
    </StackPanel>
</Border>

<!-- Mobile bottom tab bar -->
<Grid Grid.Row="1" Grid.Column="1"
      Visibility="{utu:Responsive Normal=Visible, Wide=Collapsed}">
    <!-- 4 Column buttons, all with Click="NavigateTopClick" -->
</Grid>
```

Both menus call the same `NavigateTopClick` code-behind handler (see [ui-uno-navigation.md](ui-uno-navigation.md) section Menu Navigation: Always Land On Top Page). Do not try to use a single `utu:TabBar` for both layouts - its `OnClickBehaviors` default to stack-aware navigation, which conflicts with the "always-to-top" requirement.

### Grid Paging - Fixed Header & Pager, Scrollable Body

When a list spans more rows than the viewport, the header and pager must stay visible while only the rows scroll. Use a three-row `Grid` with `Auto / * / Auto` and put the `ScrollViewer` around only the items region. Do NOT put the outer page content inside a `ScrollViewer` - the inner list will never get a scrollbar because the outer one absorbs all the height.

```xml
<Grid RowDefinitions="Auto,*,Auto">
    <!-- Row 0: toolbar / filters -->
    <Border Grid.Row="0" .../>

    <!-- Row 1: scrollable list body -->
    <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
        <ItemsControl ItemsSource="{Binding Items}" .../>
    </ScrollViewer>

    <!-- Row 2: pager (First / Prev / pages / Next / Last) -->
    <Border Grid.Row="2" .../>
</Grid>
```

### ItemsControl vs FeedView for Child Collections

For **independently-editable in-page child lists** (checklist items, attachments, buffered-before-save child rows), bind `ItemsControl.ItemsSource` directly to an `IListState<T>` and skip `uer:FeedView`. `FeedView` adds a ValueTemplate/ProgressTemplate wrapper that sizes to content-undefined during initial empty state, giving you a tall empty region, and the progress/value template swap can suppress the `ItemsSource` change notification that toggles a `CheckBox` visually.

Use `FeedView` for top-level page data that has distinct None/Error/Progress UX. Use bare `ItemsControl` for inline children whose UI just needs to track a list state.

## Business Service Rules

In `Business/Services`:
- Define `I{Feature}Service` interfaces.
- Implement via Kiota client wrapper.
- Convert transport DTOs to UI models at service boundary.
- Surface `Result`/failure states usable by MVUX models.

### Client-API Contract Rules

The API wraps all CRUD payloads in `DefaultRequest<T>` (inbound) and `DefaultResponse<T>` (outbound). The Kiota client stub (or hand-written `TaskFlowApiClient`) must match this envelope.

**Request wrapping** - POST (create) and PUT (update) endpoints expect `{"item": {dto}}`, not the bare DTO:

```csharp
// OK CORRECT - wraps DTO in DefaultRequest envelope
var response = await _http.PostAsJsonAsync("/api/categories",
    new DefaultRequest<CategoryDto> { Item = dto }, ct);

// FAIL WRONG - sends bare DTO, API deserializes Item as null -> NRE
var response = await _http.PostAsJsonAsync("/api/categories", dto, ct);
```

**Response unwrapping** - GET and mutating endpoints return `{"item": {dto}}`:

```csharp
// OK CORRECT - unwraps from DefaultResponse envelope
var wrapper = await _http.GetFromJsonAsync<DefaultResponse<CategoryDto>>(url, ct);
return wrapper?.Item;

// FAIL WRONG - reads bare DTO, all properties are null/default
return await _http.GetFromJsonAsync<CategoryDto>(url, ct);
```

**Search is different** - search endpoints accept `SearchRequest<TFilter>` directly (no wrapping) and return `PagedResponse<T>` with a `data` array (not `DefaultResponse`).

#### Pagination contract

1-based `pageIndex`. The server API expects `pageIndex` (not `pageNumber`) and treats it as **1-based**. Never send `0`. The hand-written client stub must match that wire name and base exactly - using `pageNumber` or 0-based indexing silently returns page 1 for every request.

```csharp
public class SearchRequest<TFilter> where TFilter : class, new()
{
    [JsonPropertyName("filter")] public TFilter Filter { get; set; } = new();

    // Internal 1-based value; never exposed on the wire under this name.
    [JsonIgnore] public int PageNumber { get; set; } = 1;

    // What the server actually reads - same 1-based value, wire name "pageIndex".
    [JsonPropertyName("pageIndex")]
    public int PageIndex { get => PageNumber; set => PageNumber = value; }

    [JsonPropertyName("pageSize")] public int PageSize { get; set; } = 50;
}
```

When debugging paging that "always returns page 1": inspect the serialized request body in devtools. If you see `"pageNumber"` in the payload, or `"pageIndex": 0`, the contract is wrong - the server is silently coercing both to page 1.

**Response side must also stay 1-based - no offset conversion in `PagedResponse`.** The server echoes the same 1-based `pageIndex` in responses. A client-side `PagedResponse.PageIndex` setter that treats the incoming value as 0-based (`PageNumber = value + 1`) silently desyncs the UI page counter by one - first page shows as "Page 2", "Next" jumps past the actual next page, etc. The response parser must pass `pageIndex` through unchanged:

```csharp
public class PagedResponse<T>
{
    [JsonPropertyName("pageNumber")] public int PageNumber { get; set; }

    // Server emits 1-based pageIndex - keep client PageNumber 1-based too.
    [JsonPropertyName("pageIndex")]
    public int PageIndex { get => PageNumber; set => PageNumber = value; }
    // ...
}
```

Symptom to watch for: pager displays the correct total pages but the "current page" number is one higher than the data actually shown, or "Next" returns the same rows as the page just shown. Inspect the raw response JSON - if server returns `"pageIndex": 1` but client state shows `PageNumber = 2`, the setter is adding an offset.

Client-side wrapper classes:

```csharp
public class DefaultRequest<T>
{
    [JsonPropertyName("item")]
    public T Item { get; set; } = default!;
}

public class DefaultResponse<T>
{
    [JsonPropertyName("item")]
    public T? Item { get; set; }
}
```

## Auth Rules

- UI authenticates to Gateway identity provider.
- No direct API tokens in XAML or page code-behind.
- Keep auth/session handling in host/services.

### Dev-Mode Auth to Production MSAL Upgrade

Scaffold with `.AddCustom()` (no external identity provider required). When ready for production:

1. Register app in **Entra External ID** (CIAM) - get `ClientId` + `Authority`
2. Update `appsettings.json` `EntraExternal` section with real tenant values
3. Replace `.AddCustom(...)` with `.AddMsal()` in `App.xaml.host.cs`
4. Change `<UnoFeatures>` in `.csproj`: `AuthenticationCustom` to `AuthenticationMsal`
5. `AuthTokenHandler` (reads `ITokenCache`) works identically with both providers
6. Configure Gateway with `TaskFlowGateway_EntraID` config section (see [identity-management.md](identity-management.md))
