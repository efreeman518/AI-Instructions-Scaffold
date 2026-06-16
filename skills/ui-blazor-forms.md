# Blazor UI - Forms, Uploads & Interaction Patterns

Situational page-interaction patterns for the Blazor UI: editing immutable DTO records, the unsaved-changes navigation prompt, parent-aggregate child editing, file uploads, server-side paging, and the MudBlazor confirm-dialog fallback. Loaded during Phase 5c on demand, when building a Blazor `{Entity}Page` (add/edit), an upload surface, or a paged list - the always-needed Blazor spine (structure, `Program.cs`, `FloatService`, Refit client, `MainLayout`) lives in the companion.

Companion file:
- [ui-blazor.md](ui-blazor.md) - Blazor spine: render mode, structure, `Program.cs`, `FloatService`, Refit client, dev tenant header, `MainLayout`, auth, generation checklist.

The `{Entity}Page` (unified new/edit) typically needs everything here; a read-only list page needs only the spine.

---

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

## MudBlazor `ShowMessageBoxAsync` Fallback

Some MudBlazor releases ship without the `ShowMessageBoxAsync` extension. Check `IDialogService` in the installed package before relying on it (`dotnet list package | findstr MudBlazor`); if absent, ship the `ConfirmDialog.razor` scaffold component below and route every confirm prompt through `DialogService.ShowAsync<ConfirmDialog>(...)`:

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

Decide once per scaffold (`ShowMessageBoxAsync` vs `ConfirmDialog`) and use the same pattern everywhere; pinning MudBlazor to a known-good range in `Directory.Packages.props` is the alternative.

## Unsaved-Changes Prompt on Navigation

Detail pages with editable fields must prompt before the user leaves via any navigation - top menu (`MudNavLink`), back button, `Nav.NavigateTo`, or browser back. Use `NavigationManager.RegisterLocationChangingHandler`.

`MudNavLink` renders a standard `<a>` that triggers `NavigationManager.NavigateTo`, so `LocationChanging` fires reliably. **No custom click handler is required on Blazor** (this differs from Uno, which needs a code-behind handler because `PanelVisibilityNavigator` can silently no-op - see [ui-uno-navigation.md](ui-uno-navigation.md) -> *Menu Navigation: Always Land On Top Page*).

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

## Server-Side Table Paging

Use `<MudTable ServerData="LoadServerData">` for any list bigger than a couple dozen rows. The callback receives a `TableState` with `Page` and `PageSize` and must return a `TableData<T>`:

```csharp
private async Task<TableData<TaskItemDto>> LoadServerData(TableState state, CancellationToken ct)
{
    var req = new SearchRequest<TaskItemSearchFilter>
    {
        PageIndex = state.Page + 1,  // MudTable.Page is 0-based; +1 only if the API is 1-based (verify - see below)
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

`MudTable.Page` is 0-based. The API's page-index base (0- vs 1-based) is a property of the running backend - verify it empirically (request page 0 vs page 1 against a seeded list and see which returns the first row). Convert MudTable's 0-based page to whatever base the API expects at this boundary (the `+1` shown is correct only when the API is 1-based) so the rest of the code deals in a single convention.
