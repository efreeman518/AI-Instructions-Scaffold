# Structure Validator Template

| | |
|---|---|
| **File** | `Application.Services/Rules/{Entity}StructureValidator.cs` |
| **Depends on** | [data-mapping-template](data-mapping-template.md) |
| **Referenced by** | [service-template](service-template.md), [application-layer.md](../skills/application-layer.md) |

## Purpose

Validates DTO structure (required fields, string lengths, enum ranges, child collection constraints) **before** domain factory/update calls. Static class - no DI registration needed.

Returns `Result<{Entity}Dto>` so services can short-circuit on invalid input without touching the domain layer.

> **Multi-tenant toggle:** `StructureValidators.ValidateCreate<T>` and `ValidateUpdate<T>` constrain on `ITenantEntityDto` to enforce `TenantId != Guid.Empty`. For single-tenant scaffolds, use `ValidateUpdateId<T>` (constrains only on `IEntityBaseDto`) or define non-tenant generic overloads.

## Template

### Generic Base Validators (Application.Services/Rules/StructureValidators.cs)

Shared validation for all entities - validates presence, TenantId, and Id constraints via generic type constraints. Per-entity validators delegate to these first.

```csharp
using Application.Models.Shared;
using EF.Common.Contracts;

namespace Application.Services.Rules;

internal static class StructureValidators
{
    internal static Result ValidateCreate<T>(T? dto) where T : class, ITenantEntityDto
    {
        if (dto is null) return Result.Failure("Payload is required.");
        return Require(dto.TenantId != Guid.Empty, "TenantId is required.");
    }

    internal static Result ValidateUpdate<T>(T? dto) where T : class, IEntityBaseDto, ITenantEntityDto
    {
        if (dto is null) return Result.Failure("Payload is required.");
        if (dto.Id is null || dto.Id == Guid.Empty) return Result.Failure("Id is required for updates.");
        return Require(dto.TenantId != Guid.Empty, "TenantId is required.");
    }

    internal static Result ValidateUpdateId<T>(T? dto) where T : class, IEntityBaseDto
    {
        if (dto is null) return Result.Failure("Payload is required.");
        return Require(dto.Id is not null && dto.Id != Guid.Empty, "Id is required for updates.");
    }

    private static Result Require(bool condition, string errorMessage)
        => condition ? Result.Success() : Result.Failure(errorMessage);
}
```

### Per-Entity Validator (Application.Services/Rules/{Entity}StructureValidator.cs)

Delegates common checks to `StructureValidators`, then adds entity-specific field validation using `DomainConstants`.

```csharp
// File: Application.Services/Rules/{Entity}StructureValidator.cs
using Application.Models;
using Domain.Shared.Constants;

namespace Application.Services.Rules;

/// <summary>
/// Validates {Entity}Dto structure before domain operations.
/// </summary>
internal static class {Entity}StructureValidator
{
    public static Result<{Entity}Dto> ValidateCreate({Entity}Dto dto)
    {
        // Common checks (null, TenantId)
        var common = StructureValidators.ValidateCreate(dto);
        if (common.IsFailure) return Result<{Entity}Dto>.Failure(common.Errors);

        var errors = new List<string>();

        // Entity-specific field checks
        if (string.IsNullOrWhiteSpace(dto.Name))
            errors.Add("{Entity} name is required.");

        if (dto.Name?.Length > DomainConstants.RULE_DEFAULT_NAME_LENGTH_MAX)
            errors.Add($"{Entity} name cannot exceed {DomainConstants.RULE_DEFAULT_NAME_LENGTH_MAX} characters.");

        if (dto.Description?.Length > DomainConstants.RULE_DEFAULT_DESCRIPTION_LENGTH_MAX)
            errors.Add($"Description cannot exceed {DomainConstants.RULE_DEFAULT_DESCRIPTION_LENGTH_MAX} characters.");

        return errors.Count > 0
            ? Result<{Entity}Dto>.Failure(errors)
            : Result<{Entity}Dto>.Success(dto);
    }

    public static Result<{Entity}Dto> ValidateUpdate({Entity}Dto dto)
    {
        // Common checks (null, Id, TenantId)
        var common = StructureValidators.ValidateUpdate(dto);
        if (common.IsFailure) return Result<{Entity}Dto>.Failure(common.Errors);

        var errors = new List<string>();

        // Reuse shared field checks
        if (string.IsNullOrWhiteSpace(dto.Name))
            errors.Add("{Entity} name is required.");

        if (dto.Name?.Length > DomainConstants.RULE_DEFAULT_NAME_LENGTH_MAX)
            errors.Add($"{Entity} name cannot exceed {DomainConstants.RULE_DEFAULT_NAME_LENGTH_MAX} characters.");

        if (dto.Description?.Length > DomainConstants.RULE_DEFAULT_DESCRIPTION_LENGTH_MAX)
            errors.Add($"Description cannot exceed {DomainConstants.RULE_DEFAULT_DESCRIPTION_LENGTH_MAX} characters.");

        return errors.Count > 0
            ? Result<{Entity}Dto>.Failure(errors)
            : Result<{Entity}Dto>.Success(dto);
    }
}
```

## Rules

- **Static class** - no DI registration. Call directly: `{Entity}StructureValidator.ValidateCreate(dto)`.
- **Delegate common checks** - Per-entity validators call `StructureValidators.ValidateCreate/ValidateUpdate` first for null, TenantId, and Id checks. Only add entity-specific rules after.
- Keep validations purely structural (field presence, length, range). Domain invariants belong in [domain-rules-template](domain-rules-template.md). Entry-point validators can be bypassed; factories and domain methods are shared across API, CQRS, jobs, messages, and tests, so invariants need one domain-owned enforcement boundary.
- **Use `DomainConstants`** for string length limits - single source of truth shared with EF configuration and domain `Valid()`. Do not use magic numbers or contextual tokens like `{NameMaxLength}`.
- Provide separate `ValidateCreate` and `ValidateUpdate` methods - update requires `Id` (via generic `ValidateUpdate<T>`), create may have different required fields.
- Return all errors at once (don't short-circuit on first failure) so the caller gets a complete validation report.
- Add or remove validated properties to match the entity's DTO - `dto.Description` is shown as an example; adjust to your entity's actual fields.

## Verification Checklist

- [ ] `StructureValidators.cs` exists with generic `ValidateCreate<T>`, `ValidateUpdate<T>`, `ValidateUpdateId<T>`
- [ ] Per-entity validator delegates common checks to `StructureValidators` first
- [ ] `ValidateCreate` checks all required fields for new entity creation
- [ ] `ValidateUpdate` requires `Id` and validates mutable fields
- [ ] String length limits use `DomainConstants` - single source of truth with EF config and domain `Valid()`
- [ ] Returns `Result<{Entity}Dto>` consistent with service layer pattern
- [ ] Service template calls `ValidateCreate`/`ValidateUpdate` before domain operations
- [ ] No domain logic in validator - structural checks only
