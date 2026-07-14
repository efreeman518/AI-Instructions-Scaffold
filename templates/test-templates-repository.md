# Test Templates - Repository (Phase 5a)

| | |
|---|---|
| **Generates** | `tests/Test.Unit/Repositories/{Entity}RepositoryTrxnTests.cs`, `tests/Test.Unit/Repositories/{Entity}RepositoryQueryTests.cs` |
| **Requires** | [repository-template](repository-template.md), entity (implemented in 5a), InMemoryDbBuilder (from Phase 4) |
| **Phase** | 5a (Foundation TDD) |
| **Protocol** | Write these tests AFTER entity is implemented (green). See [../ai/tdd-protocol.md](../ai/tdd-protocol.md). |

## BDD Naming Convention

All test methods use `Given_When_Then`:
```csharp
[TestMethod]
public async Task Given_ValidEntity_When_Created_Then_CanBeRetrieved() { }
```

---

## Repository Trxn Tests

### File: `tests/Test.Unit/Repositories/{Entity}RepositoryTrxnTests.cs`

```csharp
[TestClass]
[TestCategory("Unit")]
public class {Entity}RepositoryTrxnTests
{
    [TestMethod]
    public async Task Given_ValidEntity_When_CrudCycleCompleted_Then_AllOperationsSucceed()
    {
        // Arrange
        var db = new InMemoryDbBuilder().BuildInMemory<{App}DbContextTrxn>();
        var repo = new {Entity}RepositoryTrxn(db);
        var tenantId = Guid.NewGuid();
        var entity = {Entity}.Create(tenantId, "TestEntity").Value!;

        // Act - Create
        repo.Create(ref entity);
        await repo.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins);

        // Act - Read
        var retrieved = await repo.Get{Entity}Async(entity.Id);

        // Assert - Read
        Assert.IsNotNull(retrieved);
        Assert.AreEqual("TestEntity", retrieved.Name);

        // Act - Update via domain method
        retrieved.Update(name: "Updated");
        await repo.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins);

        // Assert - Updated
        var updated = await repo.Get{Entity}Async(entity.Id);
        Assert.AreEqual("Updated", updated!.Name);

        // Act - Delete
        repo.Delete(updated);
        await repo.SaveChangesAsync(OptimisticConcurrencyWinner.ClientWins);

        // Assert - Deleted
        var deleted = await repo.Get{Entity}Async(entity.Id);
        Assert.IsNull(deleted);
    }
}
```

---

## Repository Query Tests

### File: `tests/Test.Unit/Repositories/{Entity}RepositoryQueryTests.cs`

```csharp
[TestClass]
[TestCategory("Unit")]
public class {Entity}RepositoryQueryTests
{
    [TestMethod]
    public async Task Given_SeededEntities_When_SearchWithFilter_Then_ReturnsMatchingEntities()
    {
        // Arrange
        var tenantId = Guid.NewGuid();
        var db = new InMemoryDbBuilder()
            .UseEntityData(ctx =>
            {
                ctx.Set<{Entity}>().Add({Entity}.Create(tenantId, "Alpha").Value!);
                ctx.Set<{Entity}>().Add({Entity}.Create(tenantId, "Beta").Value!);
                ctx.Set<{Entity}>().Add({Entity}.Create(tenantId, "AlphaTwo").Value!);
                ctx.SaveChanges();
            })
            .BuildInMemory<{App}DbContextQuery>();
        var repo = new {Entity}RepositoryQuery(db);

        // Act
        var page = await repo.Search{Entity}Async(
            new SearchRequest<{Entity}SearchFilter>
            {
                PageIndex = 1,
                PageSize = 10,
                Filter = new {Entity}SearchFilter { SearchTerm = "Alpha" }
            });

        // Assert
        Assert.AreEqual(2, page.Total);
        Assert.IsTrue(page.Data.All(i => i.Name.Contains("Alpha")));
    }

    [TestMethod]
    public async Task Given_EmptyFilter_When_SearchExecuted_Then_ReturnsAllEntities()
    {
        // Arrange
        var tenantId = Guid.NewGuid();
        var db = new InMemoryDbBuilder()
            .UseEntityData(ctx =>
            {
                ctx.Set<{Entity}>().Add({Entity}.Create(tenantId, "One").Value!);
                ctx.Set<{Entity}>().Add({Entity}.Create(tenantId, "Two").Value!);
                ctx.SaveChanges();
            })
            .BuildInMemory<{App}DbContextQuery>();
        var repo = new {Entity}RepositoryQuery(db);

        // Act
        var page = await repo.Search{Entity}Async(
            new SearchRequest<{Entity}SearchFilter>
            {
                PageIndex = 1,
                PageSize = 10,
                Filter = new {Entity}SearchFilter()
            });

        // Assert
        Assert.AreEqual(2, page.Total);
    }

    [TestMethod]
    public async Task Given_PaginatedRequest_When_SearchExecuted_Then_ReturnsCorrectPage()
    {
        // Arrange
        var tenantId = Guid.NewGuid();
        var db = new InMemoryDbBuilder()
            .UseEntityData(ctx =>
            {
                for (int i = 0; i < 15; i++)
                    ctx.Set<{Entity}>().Add({Entity}.Create(tenantId, $"Item{i}").Value!);
                ctx.SaveChanges();
            })
            .BuildInMemory<{App}DbContextQuery>();
        var repo = new {Entity}RepositoryQuery(db);

        // Act
        var page = await repo.Search{Entity}Async(
            new SearchRequest<{Entity}SearchFilter>
            {
                PageIndex = 2,
                PageSize = 10,
                Filter = new {Entity}SearchFilter()
            });

        // Assert
        Assert.AreEqual(15, page.Total);
        Assert.AreEqual(5, page.Data.Count);
    }
}
```

---

## InMemoryDbBuilder Usage Notes

- `BuildInMemory<T>()` - uses EF in-memory provider; fast but does not enforce relational constraints
- `BuildSQLite<T>()` - uses SQLite in-memory; enforces FK/unique constraints; use for relationship tests
- `SeedDefaultEntityData()` - seeds standard test data (implement in Test.Support)
- `UseEntityData(Action<DbContext>)` - custom seed per test
