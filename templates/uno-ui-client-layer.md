# UI Client Layer Template (Models + Services)

| | |
|---|---|
| **Files** | `src/UI/{Project}.Uno.Core/Client/{Project}ApiClient.cs`, `Business/Models/{Entity}.cs`, `Business/Models/IEntityBase.cs`, `Business/Messages/EntityMessage.cs`, `Business/Services/{Feature}/I{Entity}Service.cs`, `Business/Services/{Feature}/{Entity}Service.cs` |
| **Depends on** | [data-mapping-template](data-mapping-template.md) (API DTO structure) |
| **Referenced by** | [uno-mvux-model-template](uno-mvux-model-template.md), [ui-uno.md](../skills/ui-uno.md) |

## Models

Client models, DTO wrappers, API clients, business services, and platform-agnostic UI messages live in `src/UI/{Project}.Uno.Core`. MVUX presentation models live in `src/UI/{Project}.Uno.Presentation`. The `src/UI/{Project}.Uno` app head references the presentation library and owns only app startup, routes, XAML views, styles, converters, strings, and platform assets.

### Client-Side Record Model

```csharp
using {Project}.Uno.Core.Client.Models;
using {Entity}Data = {Project}.Uno.Core.Client.Models.{Entity}Data;

namespace {Project}.Uno.Core.Business.Models;

/// <summary>
/// Client-side immutable record for {Entity}.
/// Wraps the Kiota-generated wire DTO ({Entity}Data).
/// </summary>
public partial record {Entity} : IEntityBase
{
    /// <summary>
    /// Create from Kiota wire DTO.
    /// </summary>
    internal {Entity}({Entity}Data data)
    {
        Id = data.Id ?? Guid.Empty;
        Name = data.Name;
        // Map all properties from data -> record
    }

    // Default constructor for create scenarios
    public {Entity}() { }

    public Guid Id { get; init; }
    public string? Name { get; init; }
    public bool IsFavorite { get; init; }
    // ... add all entity properties

    // Computed properties (display helpers)
    // public string DisplayText => $"{Name} - {SomeOtherProp}";

    /// <summary>
    /// Convert back to Kiota wire DTO for POST/PUT requests.
    /// </summary>
    internal {Entity}Data ToData() => new()
    {
        Id = Id,
        Name = Name,
        // Map all properties from record -> data
    };
}
```

### Model Rules

- Use `partial record` with `init` properties - immutable by default
- Provide an `internal` constructor that accepts the Kiota wire DTO (`{Entity}Data`)
- Provide a `ToData()` method to convert back to the wire DTO
- Keep computed/display properties as expression-bodied getters
- Implement `IEntityBase` so messaging key selectors work
- Default constructor (parameterless) is needed for create/form scenarios
- Use `using {Entity}Data = ...` alias to avoid naming collisions with the client record

## Services

### Service Interface

```csharp
namespace {Project}.Uno.Core.Business.Services.{Feature};

/// <summary>
/// Client-side service for {Entity} operations via the Gateway API.
/// </summary>
public interface I{Entity}Service
{
    /// <summary>Get all {entity}s.</summary>
    ValueTask<IImmutableList<{Entity}>> GetAll(CancellationToken ct);

    /// <summary>Get a single {entity} by ID.</summary>
    ValueTask<{Entity}> GetById(Guid id, CancellationToken ct);

    /// <summary>Create a new {entity}.</summary>
    ValueTask Create({Entity} entity, CancellationToken ct);

    /// <summary>Update an existing {entity}.</summary>
    ValueTask Update({Entity} entity, CancellationToken ct);

    /// <summary>Delete a {entity} by ID.</summary>
    ValueTask Delete(Guid id, CancellationToken ct);

    /// <summary>Toggle favorite status.</summary>
    ValueTask Favorite({Entity} entity, CancellationToken ct);

    // Add child collection methods as needed:
    // ValueTask<IImmutableList<{ChildEntity}>> Get{ChildEntity}s(Guid {entity}Id, CancellationToken ct);
}
```

### Service Implementation

```csharp
using {Project}.Uno.Core.Business.Models;
using {Project}.Uno.Core.Client;
using {Project}.Uno.Core.Business.Messages;

namespace {Project}.Uno.Core.Business.Services.{Feature};

/// <summary>
/// Calls the Gateway API via Kiota-generated client.
/// Maps wire DTOs to client-side records.
/// Sends EntityMessage on mutations for MVUX auto-refresh.
/// </summary>
public class {Entity}Service(
    {Project}ApiClient api,
    IMessenger messenger) : I{Entity}Service
{
    public async ValueTask<IImmutableList<{Entity}>> GetAll(CancellationToken ct)
    {
        var data = await api.Api.{Entity}.GetAsync(cancellationToken: ct);
        return data?.Select(d => new {Entity}(d)).ToImmutableList()
            ?? ImmutableList<{Entity}>.Empty;
    }

    public async ValueTask<{Entity}> GetById(Guid id, CancellationToken ct)
    {
        var data = await api.Api.{Entity}[id].GetAsync(cancellationToken: ct);
        return new {Entity}(data!);
    }

    public async ValueTask Create({Entity} entity, CancellationToken ct)
    {
        await api.Api.{Entity}.PostAsync(entity.ToData(), cancellationToken: ct);
        messenger.Send(new EntityMessage<{Entity}>(EntityChange.Created, entity));
    }

    public async ValueTask Update({Entity} entity, CancellationToken ct)
    {
        await api.Api.{Entity}[entity.Id].PutAsync(entity.ToData(), cancellationToken: ct);
        messenger.Send(new EntityMessage<{Entity}>(EntityChange.Updated, entity));
    }

    public async ValueTask Delete(Guid id, CancellationToken ct)
    {
        await api.Api.{Entity}[id].DeleteAsync(cancellationToken: ct);
        messenger.Send(new EntityMessage<{Entity}>(EntityChange.Deleted, new {Entity} { Id = id }));
    }

    public async ValueTask Favorite({Entity} entity, CancellationToken ct)
    {
        var updated = entity with { IsFavorite = !entity.IsFavorite };
        await api.Api.{Entity}.Favorited.PostAsync(q =>
        {
            q.QueryParameters.{Entity}Id = updated.Id;
        }, cancellationToken: ct);
        messenger.Send(new EntityMessage<{Entity}>(EntityChange.Updated, updated));
    }
}
```

### Service Rules

- Use **primary constructor** injection (C# 12+)
- All methods return `ValueTask` or `ValueTask<T>`
- Always accept `CancellationToken ct` as the last parameter
- Return `IImmutableList<T>` (never `List<T>` or `IEnumerable<T>`)
- Map Kiota wire DTOs -> client records via constructor: `new {Entity}(data)`
- Map client records -> wire DTOs via `entity.ToData()` for POST/PUT
- Send `EntityMessage<T>` via `IMessenger` after every mutation (create, update, delete)
- Register as singleton in `App.xaml.host.cs` -> `ConfigureServices`

### Client Contract Rules

- Prefer shared contract types where available: `DefaultRequest<T>`, `DefaultResponse<T>`, `SearchRequest<TFilter>`, and `PagedResponse<T>`.
- Do not hand-roll client-side envelope DTOs when the shared application/common contract package is already referenced.
- POST/PUT bodies use `DefaultRequest<T>` with an `Item` property.
- Single-item GET/create/update responses unwrap `DefaultResponse<T>.Item`.
- Search responses use `PagedResponse<T>` and its `Data` collection; search requests are not wrapped in `DefaultRequest<T>`.
- Browser-WASM clients use a source-generated `JsonSerializerContext`; reflection-based JSON is not a valid published-Release dependency.

```csharp
using System.Text.Json;
using System.Text.Json.Serialization;

namespace {Project}.Uno.Core.Client;

[JsonSourceGenerationOptions(JsonSerializerDefaults.Web)]
[JsonSerializable(typeof(DefaultRequest<{Entity}Dto>))]
[JsonSerializable(typeof(DefaultResponse<{Entity}Dto>))]
[JsonSerializable(typeof(PagedResponse<{Entity}Dto>))]
[JsonSerializable(typeof(SearchRequest<{Entity}SearchFilter>))]
[JsonSerializable(typeof(List<{Entity}Dto>))]
internal partial class {Project}ApiJsonContext : JsonSerializerContext;
```

Use the generated `JsonTypeInfo<T>` overload at every `HttpClientJsonExtensions` call, for example:

```csharp
await http.PostAsJsonAsync(uri, request, {Project}ApiJsonContext.Default.DefaultRequest{Entity}Dto, ct);
var response = await content.ReadFromJsonAsync(
    {Project}ApiJsonContext.Default.DefaultResponse{Entity}Dto,
    ct);
```

The generated property names depend on the closed generic type names. Compile once, then use the emitted property exactly. Inventory internal envelopes read inside client methods as well as public parameters and returns.

## Shared Interfaces

### IEntityBase

```csharp
namespace {Project}.Uno.Core.Business.Models;

/// <summary>
/// Marker interface for entities with a Guid Id.
/// Used by EntityMessage<T> and messenger-based refresh.
/// </summary>
public interface IEntityBase
{
    Guid Id { get; }
}
```

### EntityMessage and EntityChange

```csharp
namespace {Project}.Uno.Core.Business.Messages;

public enum EntityChange { Created, Updated, Deleted }

/// <summary>
/// Broadcast via IMessenger when an entity is mutated.
/// MVUX models using .Observe() auto-refresh on receipt.
/// </summary>
public record EntityMessage<T>(EntityChange Change, T Entity);
```

## Client-Side Flow

The complete flow for a mutation (e.g., Create) through the client layer:

1. **Model** -- The caller builds an `{Entity}` record (immutable, `init` properties)
2. **Service** -- `{Entity}Service.Create()` converts the record to a wire DTO via `entity.ToData()`
3. **API call** -- The Kiota-generated client sends the DTO to the Gateway API
4. **Messaging** -- On success, the service sends `EntityMessage<{Entity}>(EntityChange.Created, entity)` via `IMessenger`
5. **Refresh** -- MVUX models subscribed via `.Observe()` receive the message and auto-refresh their state

For reads, the flow is reversed at the mapping step:

1. **API call** -- Kiota client returns `{Entity}Data` (wire DTO)
2. **Model** -- Service wraps data via `new {Entity}(data)` constructor
3. **Return** -- `IImmutableList<{Entity}>` returned to the presentation layer
