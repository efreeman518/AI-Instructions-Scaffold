# Uno Platform UI - Navigation Chrome & Cross-Page Guards

Cross-page navigation rules: persistent menu "always-to-top" behavior and the cross-model dirty guard that prompts before leaving an edited page. Loaded during Phase 5c when wiring an Uno app's menu/navigation chrome or a detail page with unsaved-edit protection.

Companion files:
- [ui-uno.md](ui-uno.md) - index + decision table
- [ui-uno-shell.md](ui-uno-shell.md) - project setup, app hosting, shell control
- [ui-uno-mvux.md](ui-uno-mvux.md) - MVUX models, routing, XAML, business services, auth
- [ui-uno-platforms.md](ui-uno-platforms.md) - WASM debugging, Android, CI requirements

---

## Navigator layout mode and route ownership

Choose the navigator from the host control and desired ownership. These shapes are not interchangeable:

| Shape | Use | Ownership rule |
|---|---|---|
| Panel/Grid with `Region.Navigator="Visibility"` | Multiple top-level sibling routes kept alive and shown/hidden | Leave the panel region empty; the navigator materializes sibling `FrameView` children. Do not predeclare named attached `ContentControl` children inside it. |
| `ContentControl` content region | One route view replaces the current content | Attach the region to the content host and use its content navigator; do not add a competing `Visibility` panel around named child hosts. |
| `Frame` / `FrameView` | Detail navigation with a back stack | The frame owns push/pop history. Decide explicitly whether a detail belongs in this stack or is a sibling in the parent region. |

Mixing `Region.Navigator="Visibility"` with predeclared named attached `ContentControl` children can produce successful route responses with no visible content. Start from one proven layout shape and add a render test that navigates to every registered sibling.

`this.Navigator()` resolves the navigator containing `this`; it does not mean "the navigator for the sibling I want." A command executing inside a child frame can therefore replace that frame or its shell while the intended sibling region never changes. Resolve the owning region element (`RootGrid.Navigator()` in the pattern below), or use an explicit parent route qualifier only after proving the resulting route ownership. Tests must assert both the active view and the shell/chrome that must remain mounted.

## Menu Navigation: Always Land On Top Page

A persistent side-nav / bottom-tab menu must land on the **top** page regardless of any sub-page stacked in the content region. Three distinct traps must be handled together - solving only one leaves the nav broken in a different way.

**Architecture recap** (after `PanelVisibilityNavigator` wires up):

- `RootGrid` is the region host with `Region.Navigator="Visibility"`.
- Its children are `FrameView` instances - one per top-level sibling route (`Dashboard`, `TaskList`, ...). Auto-created on first visit to each sibling. Not declared in XAML.
- Each `FrameView` wraps a private `Frame` that owns its own back-stack.

| Trap | Symptom | Rule |
|---|---|---|
| 1 - absolute `/Main/X` routes no-op (they walk up to Shell's `FrameNavigator`, which already has `MainPage` loaded and returns `Success=true` without descending) | Click logs `FrameNavigator Request: /Main/TaskList`; nothing visually changes | Never use rooted paths for sibling switching |
| 2 - relative route on the parent navigator can report success without flipping sibling `Visibility` | Previously-active sibling (e.g. `TaskItem`) stays `Visible`; the detail paints on top of the new sibling | Always run a `ForceSiblingVisibility` pass after the nav call |
| 3 - detail pages stack *inside* the source sibling's `Frame` (the model's injected `Navigator` is the inner Frame navigator, not the parent Visibility navigator) | After flipping visibility the user still sees Edit Task even though `TaskList` is the active sibling | Pop every FrameView's inner Frame to root when switching siblings |

### Proven pattern

Combine three fixes in the menu click handler. Do not omit any one.

```xml
<!-- MainPage.xaml -->
<Button Click="NavigateTopClick" Tag="Dashboard" ...>
<Button Click="NavigateTopClick" Tag="TaskList" ...>
<Button Click="NavigateTopClick" Tag="Settings" ...>

<!-- Inner region that actually hosts the siblings -->
<Grid x:Name="RootGrid"
      uen:Region.Attached="True"
      uen:Region.Navigator="Visibility" />
```

```csharp
// MainPage.xaml.cs
private async void NavigateTopClick(object sender, RoutedEventArgs e)
{
    if (sender is not FrameworkElement element ||
        element.Tag is not string sibling ||
        string.IsNullOrWhiteSpace(sibling)) return;

    // (Optional dirty-guard check - see "Cross-Model Form Dirty Guard")
    // var guard = App.Host?.Services.GetService<IFormGuard>();
    // if (guard?.IsDirtyAsync is { } d && await d(default) && !await ConfirmDiscardAsync()) return;
    // guard?.Clear();

    // 1) Target the INNER visibility-region navigator with a RELATIVE route.
    //    Never "/Main/X" - that hops to Shell's FrameNavigator and no-ops.
    var inner = RootGrid?.Navigator();
    var resp = inner is not null
        ? await inner.NavigateRouteAsync(this, sibling)
        : null;
    if (resp?.Success != true) return;

    // 2) Force sibling visibility - PanelVisibilityNavigator can report
    //    success without collapsing the prior active sibling. Match the
    //    child FrameView by Region.Name attached property.
    if (RootGrid is null) return;
    foreach (var child in RootGrid.Children.OfType<FrameworkElement>())
    {
        var name = global::Uno.Extensions.Navigation.UI.Region.GetName(child);
        child.Visibility = string.Equals(name, sibling, StringComparison.Ordinal)
            ? Visibility.Visible : Visibility.Collapsed;

        // 3) Pop every FrameView's inner Frame to root so any stacked
        //    detail (TaskItem pushed onto TaskList's Frame) is cleared.
        var frame = FindChildFrame(child);
        var pops = 0;
        while (frame?.CanGoBack == true && pops++ < 32) frame.GoBack();
    }
}

private static Frame? FindChildFrame(DependencyObject root)
{
    if (root is Frame f) return f;
    var count = Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(root);
    for (var i = 0; i < count; i++)
    {
        var hit = FindChildFrame(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(root, i));
        if (hit is not null) return hit;
    }
    if (root is ContentControl cc && cc.Content is DependencyObject content)
        return FindChildFrame(content);
    return null;
}
```

**Route qualifiers** (for reference only - do NOT use them for menu navigation):
`/` = root (dispatches to Shell `FrameNavigator`, no-ops on already-loaded Main),
`../` = parent, `-/` = back-then-forward, `!` = dialog, `./` = current scope.

**Alternative that avoids trap 3 entirely:** change detail openers to use the parent qualifier so `TaskItem` becomes a true sibling rather than a stacked page:

```csharp
// TaskListModel / DashboardModel
public ValueTask OpenDetail(TaskItemModel item, CancellationToken ct) =>
    Navigator.NavigateRouteAsync(this, "../TaskItem", data: item, cancellation: ct);
```

This creates a `TaskItem` `FrameView` as a proper sibling of `TaskList`/`Dashboard`. The menu-click handler then only needs steps 1 and 2 - no Frame popping. Trade-off: `NavigateBackAsync` from the detail is no longer a push-pop back to the list; it navigates to whichever sibling the `Visibility` region treats as "previous". Test both flows.

## Cross-Model Form Dirty Guard

Detail pages with unsaved edits must prompt before the user navigates to a different top-level route. The dirty check crosses models (chrome in MainPage consults dirty state owned by `TaskItemPageModel`), so route it through a small DI singleton, not through MVUX state.

```csharp
// Presentation/IFormGuard.cs
public interface IFormGuard
{
    Func<CancellationToken, ValueTask<bool>>? IsDirtyAsync { get; set; }
    void Clear();
}

internal sealed class FormGuard : IFormGuard
{
    public Func<CancellationToken, ValueTask<bool>>? IsDirtyAsync { get; set; }
    public void Clear() => IsDirtyAsync = null;
}
```

```csharp
// App.xaml.host.cs - register as singleton
services.AddSingleton<IFormGuard, FormGuard>();
```

```csharp
// TaskItemPageModel.cs - register on Reset, clear on Save/Delete
public TaskItemPageModel(..., IFormGuard formGuard)
{
    FormGuard = formGuard;
    _baseline = entity ?? new TaskItemModel();
    FormGuard.IsDirtyAsync = ComputeIsDirtyAsync;   // register
    // ...
}

public async ValueTask Reset(CancellationToken ct = default)
{
    // ... reset state fields ...
    _baseline = Entity ?? new TaskItemModel();
    FormGuard.IsDirtyAsync = ComputeIsDirtyAsync;   // re-register if model is reused
}

public async ValueTask Save(CancellationToken ct)
{
    // ... save ...
    _baseline = saved ?? model;
    FormGuard.Clear();                              // clear on success
    // ... navigate ...
}

private async ValueTask<bool> ComputeIsDirtyAsync(CancellationToken ct)
{
    var title = (await Title) ?? string.Empty;
    // ... load each current field + compare against _baseline ...
    return /* any field differs */;
}
```

```csharp
// MainPage.xaml.cs - consult guard BEFORE any menu navigation
var guard = App.Host?.Services.GetService<IFormGuard>();
if (guard?.IsDirtyAsync is { } isDirty)
{
    bool dirty; try { dirty = await isDirty(default); } catch { dirty = false; }
    if (dirty && !await ConfirmDiscardAsync()) return;
    guard.Clear();
}

private async Task<bool> ConfirmDiscardAsync()
{
    var dialog = new ContentDialog
    {
        Title = "Discard unsaved changes?",
        Content = "You have unsaved edits. Leave the page and discard them?",
        PrimaryButtonText = "Discard",
        CloseButtonText = "Stay",
        DefaultButton = ContentDialogButton.Close,
        XamlRoot = this.XamlRoot,
    };
    return (await dialog.ShowAsync()) == ContentDialogResult.Primary;
}
```

Non-negotiables:

- `IFormGuard` is a **singleton**. The delegate registration is overwritten each time a detail model is constructed - latest wins.
- Compare against a **mutable `_baseline` field**, not `Entity` (the record's `Entity` is `init`-only; post-save refresh replaces `_baseline`, not `Entity`).
- **Re-register in `Reset()`** - `PanelVisibilityNavigator` reuses model instances on re-visit, so `Reset()` is called but the constructor is not.
- **Clear on Save / Delete** success - stale `IsDirtyAsync` delegates from previously-closed detail forms otherwise block the next menu click with a false-positive prompt.
- The baseline comparison must include buffered-child inputs (`NewChecklistTitle`, `NewCommentBody`) as well as the scalar form fields.

### Blazor equivalent

Blazor has a built-in `NavigationManager.RegisterLocationChangingHandler` - no cross-model service needed. Register in `OnInitialized`, capture a baseline snapshot after load/save, check dirty in the handler, and use a `_bypassDirtyCheck` flag to suppress the prompt on programmatic post-save redirects. Full code: [ui-blazor-forms.md](ui-blazor-forms.md) section Unsaved-Changes Prompt on Navigation.

```csharp
// TaskItemPage.razor
protected override void OnInitialized()
{
    _locationChangingRegistration = Nav.RegisterLocationChangingHandler(OnLocationChangingAsync);
}

private async ValueTask OnLocationChangingAsync(LocationChangingContext context)
{
    if (_bypassDirtyCheck || !IsDirty()) return;
    var confirm = await DialogService.ShowMessageBoxAsync(new MessageBoxOptions
    {
        Title = "Discard unsaved changes?",
        Message = "You have unsaved edits. Leave and discard them?",
        YesText = "Discard", CancelText = "Stay"
    });
    if (confirm != true) context.PreventNavigation();
}

private async Task SaveAsync()
{
    // ... save ...
    _bypassDirtyCheck = true;           // suppress prompt during post-save redirect
    Nav.NavigateTo($"/tasks/{newId}");
}

public void Dispose() => _locationChangingRegistration?.Dispose();
```

MudBlazor's `MudNavLink` renders a standard anchor that triggers `NavigationManager.NavigateTo`, so `LocationChanging` fires reliably - no special menu-click handler is required on the Blazor side.
