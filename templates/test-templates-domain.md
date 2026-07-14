# Test Templates - Domain (Phase 5a)

| | |
|---|---|
| **Generates** | `tests/Test.Unit/Domain/{Entity}Tests.cs`, `tests/Test.Unit/Domain/{Entity}RulesTests.cs` |
| **Requires** | Entity shell from Phase 4, [domain-rules-template](domain-rules-template.md) |
| **Phase** | 5a (Foundation TDD) |
| **Protocol** | Write these tests BEFORE implementing entity logic. See [../ai/tdd-protocol.md](../ai/tdd-protocol.md). |

## BDD Naming Convention

All test methods use `Given_When_Then`:
```csharp
[TestMethod]
public void Given_ValidInput_When_EntityCreated_Then_ReturnsSuccess() { }
```

---

## Domain Entity Tests

### File: `tests/Test.Unit/Domain/{Entity}Tests.cs`

```csharp
[TestClass]
[TestCategory("Unit")]
public class {Entity}Tests
{
    [TestMethod]
    public void Given_ValidInput_When_EntityCreated_Then_ReturnsSuccess()
    {
        // Arrange & Act
        var result = {Entity}.Create(Guid.NewGuid(), "Valid Name");

        // Assert
        Assert.IsTrue(result.IsSuccess);
        Assert.IsNotNull(result.Value);
        Assert.AreEqual("Valid Name", result.Value.Name);
    }

    [TestMethod]
    [DataRow(null)]
    [DataRow("")]
    public void Given_EmptyName_When_EntityCreated_Then_ReturnsDomainFailure(string? name)
    {
        // Arrange & Act
        var result = {Entity}.Create(Guid.NewGuid(), name!);

        // Assert
        Assert.IsTrue(result.IsFailure);
        Assert.Contains("name", result.ErrorMessage!, StringComparison.OrdinalIgnoreCase);
    }

    [TestMethod]
    public void Given_ExistingEntity_When_Updated_Then_ReturnsUpdatedValues()
    {
        // Arrange
        var entity = {Entity}.Create(Guid.NewGuid(), "Original").Value!;

        // Act
        var result = entity.Update(name: "Updated");

        // Assert
        Assert.IsTrue(result.IsSuccess);
        Assert.AreEqual("Updated", result.Value!.Name);
    }

    [TestMethod]
    public void Given_NullUpdate_When_Updated_Then_OriginalValuesPreserved()
    {
        // Arrange
        var entity = {Entity}.Create(Guid.NewGuid(), "Original").Value!;

        // Act
        var result = entity.Update(name: null);

        // Assert
        Assert.IsTrue(result.IsSuccess);
        Assert.AreEqual("Original", result.Value!.Name);
    }

    [TestMethod]
    public void Given_ParentEntity_When_ChildAdded_Then_CollectionContainsChild()
    {
        // Arrange
        var entity = {Entity}.Create(Guid.NewGuid(), "Parent").Value!;
        var child = {ChildEntity}.Create(Guid.NewGuid(), "Child").Value!;

        // Act
        var result = entity.Add{ChildEntity}(child);

        // Assert
        Assert.IsTrue(result.IsSuccess);
        Assert.AreEqual(1, entity.{ChildEntity}s.Count);
    }

    [TestMethod]
    public void Given_DuplicateChild_When_ChildAdded_Then_IdempotentReturnsExisting()
    {
        // Arrange
        var entity = {Entity}.Create(Guid.NewGuid(), "Parent").Value!;
        var child = {ChildEntity}.Create(Guid.NewGuid(), "Child").Value!;
        entity.Add{ChildEntity}(child);

        // Act - add same child again
        var result = entity.Add{ChildEntity}(child);

        // Assert - idempotent
        Assert.IsTrue(result.IsSuccess);
        Assert.AreEqual(1, entity.{ChildEntity}s.Count);
    }
}
```

> **Child entity tests:** Include the `Add{ChildEntity}` and duplicate-child tests only when the entity has child collections defined in `.scaffold/resource-implementation.yaml`. Omit for leaf entities.

---

## Domain Rule Tests

### File: `tests/Test.Unit/Domain/{Entity}RulesTests.cs`

```csharp
[TestClass]
[TestCategory("Unit")]
public class {Entity}RulesTests
{
    [TestMethod]
    public void Given_EmptyName_When_NameRequiredRuleEvaluated_Then_IsNotSatisfied()
    {
        // Arrange
        var rule = new {Entity}NameRequiredRule();
        var entity = {Entity}.Create(Guid.NewGuid(), "").Value!;

        // Act
        var satisfied = rule.IsSatisfiedBy(entity);

        // Assert
        Assert.IsFalse(satisfied);
        Assert.IsFalse(string.IsNullOrEmpty(rule.ErrorMessage));
    }

    [TestMethod]
    public void Given_AllRulesComposite_When_OneFails_Then_ReturnsFalse()
    {
        // Arrange
        var rules = new IRule<{Entity}>[]
        {
            new {Entity}NameRequiredRule(),
            new {Entity}CannotDeactivateWithActiveChildrenRule()
        };
        var entity = {Entity}.Create(Guid.NewGuid(), "").Value!; // empty name

        // Act
        var result = rules.EvaluateAll(entity);

        // Assert
        Assert.IsTrue(result.IsFailure);
        Assert.Contains("name", result.ErrorMessage!, StringComparison.OrdinalIgnoreCase);
    }
}
```

---

## Builder Activation (Phase 5a)

After entity `Create()` is implemented, activate the builder in `tests/Test.Support/Builders/{Entity}Builder.cs`:

```csharp
// Replace the Phase 4 shell:
public {Entity} Build() => null!;

// With the activated version:
public {Entity} Build()
{
    var result = {Entity}.Create(_tenantId, _name);
    return result.Value!;
}
```

This must happen in Phase 5a **after** entity logic is implemented, not before.
