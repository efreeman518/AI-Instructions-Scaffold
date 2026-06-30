# Domain Rules Template

## Output

| Field | Value |
|-------|-------|
| **File** | `src/Domain/{Project}.Domain.Model/Rules/{Entity}Rules.cs` |
| **Depends on** | `Domain.Model` (entity types), `Domain.Shared` (enums, constants) |
| **Referenced by** | `Application.Services` (called in service methods before state transitions) |

---

## Overview

Domain rules use the **Specification pattern** to encode complex business invariants as composable, testable rule objects. Rules return `DomainResult` so they integrate naturally with the railway-oriented error handling used throughout the domain layer.

---

## Rule Interface

```csharp
// File: src/Domain/{Project}.Domain.Model/Rules/IRule.cs
namespace Domain.Model.Rules;

/// <summary>
/// A domain rule that can be evaluated against a subject.
/// </summary>
public interface IRule<in T>
{
    string ErrorMessage { get; }
    bool IsSatisfiedBy(T subject);
}
```

---

## Base Rule Implementation

```csharp
// File: src/Domain/{Project}.Domain.Model/Rules/RuleBase.cs
using EF.Domain;

namespace Domain.Model.Rules;

public abstract class RuleBase<T> : IRule<T>
{
    public abstract string ErrorMessage { get; }
    public abstract bool IsSatisfiedBy(T subject);

    /// <summary>
    /// Evaluate the rule and return a DomainResult.
    /// </summary>
    public DomainResult Evaluate(T subject) =>
        IsSatisfiedBy(subject)
            ? DomainResult.Success()
            : DomainResult.Failure(ErrorMessage);
}
```

---

## Entity-Specific Rules

```csharp
// File: src/Domain/{Project}.Domain.Model/Rules/{Entity}Rules.cs
using Domain.Model;
using Domain.Shared;

namespace Domain.Model.Rules;

/// <summary>
/// {Entity} must have a non-empty name.
/// </summary>
public class {Entity}NameRequiredRule : RuleBase<{Entity}>
{
    public override string ErrorMessage => "{Entity} name is required.";

    public override bool IsSatisfiedBy({Entity} subject) =>
        !string.IsNullOrWhiteSpace(subject.Name);
}

/// <summary>
/// {Entity} cannot be deactivated while it has active children.
/// </summary>
public class {Entity}CannotDeactivateWithActiveChildrenRule : RuleBase<{Entity}>
{
    public override string ErrorMessage =>
        "Cannot deactivate {Entity} while it has active child entities.";

    public override bool IsSatisfiedBy({Entity} subject) =>
        !subject.Flags.HasFlag({Entity}Flags.IsInactive) ||
        !subject.{ChildEntity}s.Any(c => !c.Flags.HasFlag({ChildEntity}Flags.IsInactive));
}

/// <summary>
/// {Entity} status transition must follow allowed paths.
/// </summary>
public class {Entity}ValidStatusTransitionRule(
    {Entity}Flags currentFlags, {Entity}Flags targetFlags) : RuleBase<{Entity}>
{
    public override string ErrorMessage =>
        $"Transition from {currentFlags} to {targetFlags} is not allowed.";

    public override bool IsSatisfiedBy({Entity} subject)
    {
        // Example: cannot go directly from None to IsArchived
        if (currentFlags == {Entity}Flags.None && targetFlags.HasFlag({Entity}Flags.IsArchived))
            return false;

        return true;
    }
}
```

---

## Composite Rules

Combine multiple rules with AND/OR logic:

```csharp
// File: src/Domain/{Project}.Domain.Model/Rules/CompositeRule.cs
namespace Domain.Model.Rules;

/// <summary>
/// All rules must be satisfied (AND logic).
/// </summary>
public class AllRule<T>(params IRule<T>[] rules) : IRule<T>
{
    private readonly string _errorMessage =
        string.Join("; ", rules.Select(r => r.ErrorMessage));

    public string ErrorMessage => _errorMessage;

    public bool IsSatisfiedBy(T subject) =>
        rules.All(r => r.IsSatisfiedBy(subject));
}

/// <summary>
/// At least one rule must be satisfied (OR logic).
/// </summary>
public class AnyRule<T>(params IRule<T>[] rules) : IRule<T>
{
    public string ErrorMessage => "None of the rules were satisfied.";

    public bool IsSatisfiedBy(T subject) =>
        rules.Any(r => r.IsSatisfiedBy(subject));
}
```

---

## Rule Evaluation Helpers

```csharp
// File: src/Domain/{Project}.Domain.Model/Rules/RuleExtensions.cs
using EF.Domain;

namespace Domain.Model.Rules;

public static class RuleExtensions
{
    /// <summary>
    /// Evaluate a single rule and return DomainResult.
    /// </summary>
    public static DomainResult Evaluate<T>(this IRule<T> rule, T subject) =>
        rule.IsSatisfiedBy(subject)
            ? DomainResult.Success()
            : DomainResult.Failure(rule.ErrorMessage);

    /// <summary>
    /// Evaluate multiple rules (AND). Collect all errors.
    /// </summary>
    public static DomainResult EvaluateAll<T>(this IEnumerable<IRule<T>> rules, T subject)
    {
        var errors = rules
            .Where(r => !r.IsSatisfiedBy(subject))
            .Select(r => DomainError.Create(r.ErrorMessage))
            .ToList();

        return errors.Count > 0
            ? DomainResult.Failure(errors)
            : DomainResult.Success();
    }

    /// <summary>
    /// Evaluate a rule chain - stop at first failure.
    /// </summary>
    public static DomainResult EvaluateChain<T>(this IEnumerable<IRule<T>> rules, T subject)
    {
        foreach (var rule in rules)
        {
            if (!rule.IsSatisfiedBy(subject))
                return DomainResult.Failure(rule.ErrorMessage);
        }
        return DomainResult.Success();
    }
}
```

---

## Usage in Entity

Rules can be invoked from within entity methods or from the application service layer:

```csharp
// In {Entity}.cs - using rules in domain methods
public DomainResult<{Entity}> Deactivate()
{
    var rule = new {Entity}CannotDeactivateWithActiveChildrenRule();
    var result = rule.Evaluate(this);
    if (result.IsFailure) return DomainResult<{Entity}>.Failure(result.ErrorMessage);

    Flags |= {Entity}Flags.IsInactive;
    return DomainResult<{Entity}>.Success(this);
}
```

```csharp
// In {Entity}Service.cs - using rules from service layer
public async Task<Result> DeactivateAsync(Guid id, CancellationToken ct = default)
{
    var entity = await repoTrxn.Get{Entity}Async(id, includeChildren: true, ct);
    if (entity == null) return Result.None();

    var rules = new IRule<{Entity}>[]
    {
        new {Entity}CannotDeactivateWithActiveChildrenRule(),
        new {Entity}NameRequiredRule()
    };

    var validation = rules.EvaluateAll(entity);
    if (validation.IsFailure)
        return Result.Failure(validation.ErrorMessage!);

    var result = entity.Deactivate();
    if (result.IsFailure) return Result.Failure(result.ErrorMessage);

    await repoTrxn.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins, ct);
    return Result.Success();
}
```

---

## Notes

- Rules should be **pure functions** - no I/O, no database access, no service calls.
- Rules return `DomainResult` or boolean rule outcomes for expected business failures. Do not throw custom domain exceptions or use catch-and-convert flow for normal validation.
- Keep rules co-located in `Domain.Model/Rules/` - they depend only on `Domain.Model` and `Domain.Shared`.
- Rules that require external data (e.g., uniqueness checks) belong in the **Application.Services** layer, not in domain rules.
- Keep generated rule files in `src/Domain/{Project}.Domain.Model/Rules/` for consistency with solution structure.
- For simple validations (e.g., required fields, string length), use the inline `Valid()` method in the entity. Reserve the specification pattern for compound or cross-entity business rules.
- For actor/state-dependent decisions, model policy matrices as explicit rule families (one rule per matrix row/group) instead of embedding large conditional blocks in services.
