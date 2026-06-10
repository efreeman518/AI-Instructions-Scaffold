# No-Op Stub Template

> **When to read:** Phase 4 (generating no-op DI stubs for every contract) and Phase 5b/5e (replacing or adding stubs for external dependencies).
> **Skip if:** the current task does not generate or replace a stub.

Canonical shape for compilable no-op implementations required by **GR-05** (every external dependency declares a scaffold-time mode) and **GR-06** (stub external dependencies so the solution compiles and runs locally). See [../ai/SKILL.md](../ai/SKILL.md) section Key Principles for the mode definitions (`emulator`, `lazy-optional`, `no-op stub`, `deployment-only`). A `deployment-only` dependency still gets a stub from this template.

## Never-Throw Rule

No-op method bodies return safe defaults - never `throw new NotImplementedException()`. This holds even for entities the scaffold contracts but does not activate (`TryAddSingleton`/`TryAddScoped` fallback wiring). Throwing converts a silently inactive registration into a runtime crash if anything ever resolves it.

Throwing is permitted **only** when no safe default exists for the return shape (e.g., a non-nullable abstract type with no parameterless ctor) - that file then becomes part of the scaffold-skipped surface allowed by [../support/final-scaffold-checklist.md](../support/final-scaffold-checklist.md).

## Safe-Default Table

| Return shape | Safe default |
|---|---|
| `Result<T>` / `DomainResult<T>` | `Result<T>.Success(default!)` or a constructed empty payload (`new DefaultResponse<T>()`) |
| `Task` | `Task.CompletedTask` |
| `Task<T>` | `Task.FromResult(default(T)!)` or `Task.FromResult` of an empty payload |
| `IEnumerable<T>` / `IList<T>` | `Array.Empty<T>()` / `new List<T>()` |
| `PagedResponse<T>` | empty page (`Total = 0`, empty items) |
| `bool` | `false` |
| `string?` / nullable | `null` |

## Read Stub (returns empty/default)

```csharp
// Infrastructure/{Project}.Infrastructure.Stubs/NoOp{ServiceName}Service.cs
// TODO: [CONFIGURE] {ServiceName} - replace this stub with the real implementation
public class NoOp{ServiceName}Service : I{ServiceName}Service
{
    public Task<Result<DefaultResponse<{Entity}Dto>>> GetAsync(Guid id, CancellationToken ct = default)
        => Task.FromResult(Result<DefaultResponse<{Entity}Dto>>.Success(new DefaultResponse<{Entity}Dto>()));

    public Task<Result<PagedResponse<{Entity}Dto>>> SearchAsync(SearchRequest request, CancellationToken ct = default)
        => Task.FromResult(Result<PagedResponse<{Entity}Dto>>.Success(new PagedResponse<{Entity}Dto>()));
}
```

## Write Stub (accepts and discards)

```csharp
// Infrastructure/{Project}.Infrastructure.Stubs/NoOp{ExternalSystem}Publisher.cs
// TODO: [CONFIGURE] {ExternalSystem} - replace this stub with the live integration
public class NoOp{ExternalSystem}Publisher : I{ExternalSystem}Publisher
{
    public Task PublishAsync({Event} message, CancellationToken ct = default)
        => Task.CompletedTask; // accepted and discarded - no cloud call

    public Task<Result> SendAsync({Request} request, CancellationToken ct = default)
        => Task.FromResult(Result.Success());
}
```

## `// TODO: [CONFIGURE]` Placement (all three required per GR-06)

1. **Stub class header** - one comment naming the dependency and what replaces the stub.
2. **DI registration line** - so the wiring site is findable without opening the stub.
3. **appsettings section** - the empty/placeholder config section the live implementation will bind to.

## DI Registration

```csharp
// Bootstrapper/RegisterServices.cs
// TODO: [CONFIGURE] {ExternalSystem} - swap NoOp registration when the live integration is configured
services.AddScoped<I{ExternalSystem}Publisher, NoOp{ExternalSystem}Publisher>();
```

For `lazy-optional` mode, register conditionally on config presence: bind the section, register the live implementation when the section is non-empty, otherwise register the no-op.

## appsettings Stub Section

```jsonc
// appsettings.json
"{ExternalSystem}": {
  // TODO: [CONFIGURE] populate to activate the live {ExternalSystem} integration (lazy-optional)
  "Endpoint": "",
  "ApiKey": ""
}
```

## Related

- Phase 4 stub generation context (service vs cqrs handler stub surface, bespoke vs generic repositories): the No-Op DI Stubs step in [../ai/contract-scaffolding.md](../ai/contract-scaffolding.md).
- External API stub walkthrough: [../skills/external-api.md](../skills/external-api.md) section Stubbing Unresolved External APIs.
- Deferral recording rules: [../ai/SKILL.md](../ai/SKILL.md) section Scaffold Definition of Done, item 6.
