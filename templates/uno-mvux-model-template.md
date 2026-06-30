# MVUX Presentation Model Template

| | |
|---|---|
| **Files** | `src/UI/{Project}.Uno.Presentation/Presentation/{Entity}ListModel.cs`, `src/UI/{Project}.Uno.Presentation/Presentation/{Entity}PageModel.cs` |
| **Depends on** | [uno-ui-client-layer](uno-ui-client-layer.md) |
| **Referenced by** | [uno-xaml-page-template](uno-xaml-page-template.md), [ui-uno.md](../skills/ui-uno.md) |

This file belongs in the `{Project}.Uno.Presentation` library (`Microsoft.NET.Sdk`), not in the `{Project}.Uno` `Uno.Sdk` app head.

## Design Standard: Single Entity Page

Each main entity gets **two** presentation models:
- **`{Entity}ListModel`** - list/search/filter, navigates to the entity page
- **`{Entity}PageModel`** - unified add/edit page with all CRUD + child collections

This replaces the old 3-model pattern (List + Detail + Create). Benefits:
- One route per entity (not two)
- Edit form + children (comments, checklist items, etc.) on a single page
- `Entity?` parameter: `null` = create mode, non-null = edit mode
- Save/Delete buttons visible based on mode
- Children sections (feeds + inline add forms) visible only in edit mode

## List Model

```csharp
using {Project}.Uno.Core.Business.Models;
using {Project}.Uno.Core.Business.Services.{Feature};

namespace {Project}.Uno.Presentation.Presentation;

public partial record {Entity}ListModel(
    INavigator Navigator,
    I{Entity}ApiService {Entity}Service,
    IMessenger Messenger)
{
    public IState<int> ItemsVersion => State<int>.Value(this, () => 0);

    public IListFeed<{Entity}Model> Items => ListFeed.Async(async ct =>
    {
        _ = await ItemsVersion;
        return (IImmutableList<{Entity}Model>)(await {Entity}Service.SearchAsync(ct: ct)).ToImmutableList();
    });

    public IState<string> SearchTerm => State<string>.Value(this, () => string.Empty);

    public async ValueTask OpenItem({Entity}Model item, CancellationToken ct) =>
        await Navigator.NavigateRouteAsync(this, "{Entity}Item", data: item, cancellation: ct);

    public async ValueTask CreateNew(CancellationToken ct) =>
        await Navigator.NavigateRouteAsync(this, "{Entity}Item", cancellation: ct);
}
```

## Entity Page Model (Unified Add/Edit + Children)

```csharp
using CommunityToolkit.Mvvm.Messaging;
using {Project}.Uno.Core.Business.Models;
using {Project}.Uno.Core.Business.Services;

namespace {Project}.Uno.Presentation.Presentation;

public partial record {Entity}PageModel(
    {Entity}Model? Entity,
    INavigator Navigator,
    I{Entity}ApiService {Entity}Service,
    // inject child services as needed:
    // ICommentApiService CommentService,
    // IChecklistItemApiService ChecklistItemService,
    IMessenger Messenger)
{
    // -- Mode -------------------------------------------------
    public IState<bool> IsEditMode => State<bool>.Value(this, () => Entity?.Id is not null);

    // -- Form fields (IState per editable property) -----------
    public IState<string> Title => State<string>.Value(this, () => Entity?.Title ?? string.Empty);
    public IState<string> Description => State<string>.Value(this, () => Entity?.Description ?? string.Empty);
    // ... add IState<T> per editable property

    // -- Dynamic header text ----------------------------------
    public IState<string> FormHeader => State<string>.Value(this, () => Entity?.Id is not null ? "Edit {Entity}" : "New {Entity}");
    public IState<string> SaveButtonText => State<string>.Value(this, () => Entity?.Id is not null ? "Update" : "Save");

    // -- Children version counters (one per child feed) -------
    // public IState<int> CommentsVersion => State<int>.Value(this, () => 0);
    // public IState<int> ChecklistVersion => State<int>.Value(this, () => 0);

    // -- Children feeds ---------------------------------------
    // public IListFeed<CommentModel> Comments => ListFeed.Async(async ct =>
    // {
    //     _ = await CommentsVersion;
    //     if (Entity?.Id is null) return ImmutableList<CommentModel>.Empty;
    //     return (IImmutableList<CommentModel>)(await CommentService.SearchAsync(Entity.Id, ct)).ToImmutableList();
    // });

    // -- Inline add form states -------------------------------
    // public IState<string> NewCommentBody => State<string>.Value(this, () => string.Empty);

    // -- Save (create or update) ------------------------------
    public async ValueTask Save(CancellationToken ct)
    {
        var title = await Title;
        if (string.IsNullOrWhiteSpace(title)) return;

        var model = (Entity ?? new {Entity}Model()) with
        {
            Title = title,
            Description = await Description,
            // ... map all form fields
        };

        if (model.Id.HasValue)
            await {Entity}Service.UpdateAsync(model, ct);
        else
            await {Entity}Service.CreateAsync(model, ct);

        await Navigator.NavigateBackAsync(this, cancellation: ct);
    }

    // -- Delete -----------------------------------------------
    public async ValueTask Delete(CancellationToken ct)
    {
        if (Entity?.Id is null) return;
        await {Entity}Service.DeleteAsync(Entity.Id.Value, ct);
        await Navigator.NavigateRouteAsync(this, "{Entity}List", cancellation: ct);
    }

    // -- Child add commands -----------------------------------
    // public async ValueTask AddComment(CancellationToken ct)
    // {
    //     var body = await NewCommentBody;
    //     if (Entity?.Id is null || string.IsNullOrWhiteSpace(body)) return;
    //     await CommentService.CreateAsync(new CommentModel { Body = body, {Entity}Id = Entity.Id.Value }, ct);
    //     await NewCommentBody.UpdateAsync(_ => string.Empty, ct);
    //     await CommentsVersion.UpdateAsync(v => v + 1, ct);  // triggers feed refresh
    // }

    // -- Child delete commands --------------------------------
    // public async ValueTask DeleteComment(CommentModel comment, CancellationToken ct)
    // {
    //     if (comment.Id is null) return;
    //     await CommentService.DeleteAsync(comment.Id.Value, ct);
    //     await CommentsVersion.UpdateAsync(v => v + 1, ct);
    // }
}
```

## Rules

- Always use `partial record` - the MVUX source generator needs it
- Keep every MVUX presentation record for one app in `{Project}.Uno.Presentation`; do not split records across the app head, core library, and presentation library
- Constructor-injected parameters: services via DI, `Entity?` via navigation data (`null` = create, non-null = edit)
- Inject navigation, theme, shell, and app-behavior dependencies; never call static `App.*` members from presentation models
- Use `IFeed`/`IListFeed` for read-only data, `IState`/`IListState` for mutable data
- Public `ValueTask` methods become bindable commands automatically
- Accept `CancellationToken ct` as the last parameter on all async methods
- **Two models per entity** - List + Page (not three)
- **Children on the entity page** - not a separate detail page
- **Version counter per child feed** - increment after mutations to trigger refresh
- Save navigates back (`NavigateBackAsync`), Delete navigates to list route
- `IsEditMode` drives visibility of Delete button and children sections in XAML
