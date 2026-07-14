# Test Templates - Service (Phase 5b)

| | |
|---|---|
| **Generates** | `tests/Test.Unit/Services/{Entity}ServiceTests.cs`, `tests/Test.Unit/Mappers/{Entity}MapperTests.cs` |
| **Requires** | [service-template](service-template.md), [data-mapping-template](data-mapping-template.md), interfaces from Phase 4 |
| **Phase** | 5b (App Core TDD) |
| **Protocol** | Write these tests BEFORE implementing services. See [../ai/tdd-protocol.md](../ai/tdd-protocol.md). |

## BDD Naming Convention

All test methods use `Given_When_Then`:
```csharp
[TestMethod]
public async Task Given_ValidDto_When_CreateAsync_Then_ReturnsSuccessResult() { }
```

---

## Test Class Shape

Unit test classes are **flat** - no shared unit-test base. Declare per-class `Mock<T>` fields inline, put cross-test setups (request-context tenant, tenant-boundary defaults) in `[TestInitialize]`, and use a single `CreateService` helper per class:

```csharp
private readonly Mock<I{Entity}RepositoryTrxn> _repoTrxnMock = new();
private readonly Mock<I{Entity}RepositoryQuery> _repoQueryMock = new();
private readonly Mock<IRequestContext<string, Guid?>> _requestContextMock = new();
private readonly Mock<ITenantBoundaryValidator> _tenantBoundaryMock = new();
private readonly Mock<IInternalMessageBus> _messageBusMock = new();
private readonly Mock<IEntityCacheProvider> _entityCacheMock = new();
private readonly Mock<IFusionCacheProvider> _fusionCacheProviderMock = new();
private readonly Mock<IFusionCache> _fusionCacheMock = new();

[TestInitialize]
public void Setup()
{
    _requestContextMock.Setup(x => x.TenantId).Returns(TestConstants.TenantId);
    _requestContextMock.Setup(x => x.Roles).Returns(new List<string>());
    _tenantBoundaryMock.Setup(t => t.EnsureTenantBoundary(
            It.IsAny<ILogger>(), It.IsAny<Guid?>(), It.IsAny<IReadOnlyCollection<string>>(),
            It.IsAny<Guid>(), It.IsAny<string>(), It.IsAny<string>(), It.IsAny<Guid?>()))
        .Returns(Result.Success());
    _tenantBoundaryMock.Setup(t => t.PreventTenantChange(
            It.IsAny<ILogger>(), It.IsAny<Guid?>(), It.IsAny<Guid?>(),
            It.IsAny<string>(), It.IsAny<Guid>()))
        .Returns(Result.Success());
    _fusionCacheProviderMock.Setup(x => x.GetCache(AppConstants.DEFAULT_CACHE))
        .Returns(_fusionCacheMock.Object);
}

private {Entity}Service CreateService(
    I{Entity}RepositoryTrxn? trxn = null,
    I{Entity}RepositoryQuery? query = null)
{
    return new {Entity}Service(
        new NullLogger<{Entity}Service>(),
        _requestContextMock.Object,
        trxn ?? _repoTrxnMock.Object,
        query ?? _repoQueryMock.Object,
        _messageBusMock.Object,
        _entityCacheMock.Object,
        _fusionCacheProviderMock.Object,
        _tenantBoundaryMock.Object);
}
```

---

## Service Tests

### File: `tests/Test.Unit/Services/{Entity}ServiceTests.cs`

```csharp
[TestClass]
[TestCategory("Unit")]
public class {Entity}ServiceTests
{
    [TestMethod]
    public async Task Given_ValidDto_When_CreateAsync_Then_ReturnsSuccessResult()
    {
        // Arrange
        var forgedTenantId = Guid.NewGuid();
        var dto = new {Entity}Dto
        {
            Name = "Test {Entity}",
            TenantId = forgedTenantId
        };
        var request = new DefaultRequest<{Entity}Dto> { Item = dto };

        _repoTrxnMock.Setup(r => r.Create(ref It.Ref<{Entity}>.IsAny));
        _repoTrxnMock.Setup(r => r.UpdateFromDto(It.IsAny<{Entity}>(), It.IsAny<{Entity}Dto>(), It.IsAny<RelatedDeleteBehavior>()))
            .Returns(({Entity} entity, {Entity}Dto _, RelatedDeleteBehavior _) =>
                DomainResult<{Entity}>.Success(entity));
        _repoTrxnMock.Setup(r => r.SaveChangesAsync(It.IsAny<OptimisticConcurrencyWinner>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(0);
        var service = CreateService();

        // Act
        var result = await service.CreateAsync(request);

        // Assert
        Assert.IsTrue(result.IsSuccess);
        Assert.IsNotNull(result.Value?.Item);
        Assert.AreEqual(dto.Name, result.Value.Item.Name);
        Assert.AreEqual(TestConstants.TenantId, dto.TenantId);
        Assert.AreEqual(TestConstants.TenantId, result.Value.Item.TenantId);
        Assert.AreNotEqual(forgedTenantId, result.Value.Item.TenantId);
    }

    [TestMethod]
    public async Task Given_EmptyPayloadTenant_When_CreateAsync_Then_StampsBeforeValidation()
    {
        // Arrange
        var dto = new {Entity}Dto { Name = "Test {Entity}", TenantId = Guid.Empty };
        _repoTrxnMock.Setup(r => r.Create(ref It.Ref<{Entity}>.IsAny));
        _repoTrxnMock.Setup(r => r.UpdateFromDto(It.IsAny<{Entity}>(), dto, It.IsAny<RelatedDeleteBehavior>()))
            .Returns(({Entity} entity, {Entity}Dto _, RelatedDeleteBehavior _) =>
                DomainResult<{Entity}>.Success(entity));
        _repoTrxnMock.Setup(r => r.SaveChangesAsync(It.IsAny<OptimisticConcurrencyWinner>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(0);

        // Act
        var result = await CreateService().CreateAsync(new() { Item = dto });

        // Assert
        Assert.IsTrue(result.IsSuccess);
        Assert.AreEqual(TestConstants.TenantId, dto.TenantId);
    }

    [TestMethod]
    public async Task Given_EmptyPayloadTenantAndMissingEntity_When_UpdateAsync_Then_StampsBeforeLookup()
    {
        // Arrange
        var dto = new {Entity}Dto { Id = Guid.NewGuid(), Name = "Test", TenantId = Guid.Empty };
        _repoTrxnMock.Setup(r => r.Get{Entity}Async(dto.Id, true, It.IsAny<CancellationToken>()))
            .ReturnsAsync(({Entity}?)null);
        var service = CreateService();

        // Act
        var result = await service.UpdateAsync(new() { Item = dto });

        // Assert
        Assert.IsTrue(result.IsFailure);
        Assert.AreEqual(TestConstants.TenantId, dto.TenantId);
        _repoTrxnMock.Verify(r => r.Get{Entity}Async(dto.Id, true, It.IsAny<CancellationToken>()), Times.Once);
    }

    [DataTestMethod]
    [DataRow(false)]
    [DataRow(true)]
    public async Task Given_UntrustedTenant_When_UpdateAsync_Then_PreservesContextTenant(bool useEmptyTenant)
    {
        // Arrange
        var entityId = Guid.NewGuid();
        var payloadTenantId = useEmptyTenant ? Guid.Empty : Guid.NewGuid();
        var entity = {Entity}.Create(TestConstants.TenantId, "Before").Value!;
        var dto = new {Entity}Dto
        {
            Id = entityId,
            Name = "After",
            TenantId = payloadTenantId
        };

        _repoTrxnMock.Setup(r => r.Get{Entity}Async(entityId, true, It.IsAny<CancellationToken>()))
            .ReturnsAsync(entity);
        _repoTrxnMock.Setup(r => r.UpdateFromDto(entity, dto, RelatedDeleteBehavior.RelationshipAndEntity))
            .Returns(DomainResult<{Entity}>.Success(entity));
        _repoTrxnMock.Setup(r => r.SaveChangesAsync(It.IsAny<OptimisticConcurrencyWinner>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(0);
        // Act
        var result = await CreateService().UpdateAsync(new() { Item = dto });

        // Assert
        Assert.IsTrue(result.IsSuccess);
        Assert.AreEqual(TestConstants.TenantId, dto.TenantId);
        Assert.AreEqual(TestConstants.TenantId, result.Value!.Item.TenantId);
        Assert.AreNotEqual(payloadTenantId, result.Value.Item.TenantId);
    }

    [TestMethod]
    public async Task Given_MissingContextTenant_When_CreateAsync_Then_RejectsPayloadFallback()
    {
        // Arrange
        _requestContextMock.Setup(x => x.TenantId).Returns((Guid?)null);
        var dto = new {Entity}Dto { Name = "Forged", TenantId = Guid.NewGuid() };

        // Act
        var result = await CreateService().CreateAsync(new() { Item = dto });

        // Assert
        Assert.IsTrue(result.IsFailure);
        Assert.AreEqual(Guid.Empty, dto.TenantId);
        _repoTrxnMock.Verify(r => r.Create(ref It.Ref<{Entity}>.IsAny), Times.Never);
        _repoTrxnMock.Verify(r => r.UpdateFromDto(
            It.IsAny<{Entity}>(), It.IsAny<{Entity}Dto>(), It.IsAny<RelatedDeleteBehavior>()), Times.Never);
        _repoTrxnMock.Verify(r => r.SaveChangesAsync(
            It.IsAny<OptimisticConcurrencyWinner>(), It.IsAny<CancellationToken>()), Times.Never);
    }

    [TestMethod]
    public async Task Given_ExistingEntity_When_DeleteAsync_Then_ReturnsSuccessAndCallsDelete()
    {
        // Arrange
        var entityId = Guid.NewGuid();
        var entity = {Entity}.Create(TestConstants.TenantId, "ToDelete").Value!;
        _repoTrxnMock.Setup(r => r.Get{Entity}Async(entityId, false, It.IsAny<CancellationToken>()))
            .ReturnsAsync(entity);
        _repoTrxnMock.Setup(r => r.SaveChangesAsync(It.IsAny<OptimisticConcurrencyWinner>(), It.IsAny<CancellationToken>()))
            .ReturnsAsync(0);
        var service = CreateService();

        // Act
        var result = await service.DeleteAsync(entityId);

        // Assert
        Assert.IsTrue(result.IsSuccess);
        _repoTrxnMock.Verify(r => r.Delete(entity), Times.Once);
    }

    [TestMethod]
    public async Task Given_ExistingEntity_When_GetAsync_Then_ReturnsMappedDto()
    {
        // Arrange
        var entityId = Guid.NewGuid();
        var entity = {Entity}.Create(TestConstants.TenantId, "GetTest").Value!;
        _repoTrxnMock.Setup(r => r.Get{Entity}Async(entityId, true, It.IsAny<CancellationToken>()))
            .ReturnsAsync(entity);
        var service = CreateService();

        // Act
        var result = await service.GetAsync(entityId);

        // Assert
        Assert.IsTrue(result.IsSuccess);
        Assert.IsNotNull(result.Value?.Item);
        Assert.AreEqual("GetTest", result.Value.Item.Name);
    }
}
```

Required multi-tenant ownership cases:

- Create with a forged DTO `TenantId` uses `IRequestContext.TenantId` in the DTO passed to validation, mapper, and repository.
- Update with a forged DTO `TenantId` overwrites it before validation and preserves the loaded entity's server-authoritative tenant.
- With a valid request-context tenant, create and update DTOs carrying `Guid.Empty` pass structural tenant validation after stamping; this proves stamping runs first.
- Missing `IRequestContext.TenantId` plus a non-empty DTO `TenantId` fails and never calls `Create`, `UpdateFromDto`, or `SaveChangesAsync`; payload fallback is forbidden.

---

## Mapper Tests

### File: `tests/Test.Unit/Mappers/{Entity}MapperTests.cs`

```csharp
[TestClass]
[TestCategory("Unit")]
public class {Entity}MapperTests
{
    [TestMethod]
    public void Given_ValidEntity_When_MappedToDto_Then_AllPropertiesMapped()
    {
        // Arrange
        var tenantId = Guid.NewGuid();
        var entity = {Entity}.Create(tenantId, "Test Name").Value!;

        // Act
        var dto = entity.ToDto();

        // Assert
        Assert.AreEqual(entity.Id, dto.Id);
        Assert.AreEqual(entity.Name, dto.Name);
        Assert.AreEqual(entity.TenantId, dto.TenantId);
        // Assert each additional mapped property
        // Note: Audit fields (CreatedDate, etc.) are NOT mapped - managed by AuditInterceptor
    }

    [TestMethod]
    [TestCategory("Unit")]
    public void {Entity}_CompiledProjection_AgreesWith_ToDto()
    {
        // Arrange
        var entity = new {Entity}Builder().Build();

        // Act
        var fromCompiled = {Entity}Mapper.Projection.Compile()(entity);
        var fromToDto = entity.ToDto();

        // Assert
        Assert.AreEqual(fromToDto.Id, fromCompiled.Id);
        Assert.AreEqual(fromToDto.Name, fromCompiled.Name);
        Assert.AreEqual(fromToDto.TenantId, fromCompiled.TenantId);
        // Assert every scalar, owned-type flattened property, and collection count
    }

    [TestMethod]
    [TestCategory("Unit")]
    public void {Entity}_InlinedChildren_AgreeWith_ChildMappers()
    {
        // Arrange
        var entity = new {Entity}Builder().Build();
        var child = new {ChildEntity}Builder()
            .With{Entity}Id(entity.Id)
            .Build();
        entity.{ChildEntity}s.Add(child);

        // Act
        var fullDto = entity.ToDto();
        var expectedChild = entity.{ChildEntity}s.Single().ToDto();

        // Assert
        Assert.AreEqual(1, fullDto.{ChildEntity}s.Count);
        Assert.AreEqual(expectedChild.Id, fullDto.{ChildEntity}s[0].Id);
        Assert.AreEqual(expectedChild.{Entity}Id, fullDto.{ChildEntity}s[0].{Entity}Id);
        // Assert every child property mirrored by the parent inline projection
    }

    [TestMethod]
    public void Given_ValidDto_When_MappedToEntity_Then_ReturnsValidDomainResult()
    {
        // Arrange
        var payloadTenantId = Guid.NewGuid();
        var authoritativeTenantId = Guid.NewGuid();
        var dto = new {Entity}Dto { Name = "From DTO", TenantId = payloadTenantId };

        // Act
        var result = dto.ToEntity(authoritativeTenantId);

        // Assert
        Assert.IsTrue(result.IsSuccess);
        Assert.AreEqual(dto.Name, result.Value!.Name);
        Assert.AreEqual(authoritativeTenantId, result.Value!.TenantId);
        Assert.AreNotEqual(payloadTenantId, result.Value!.TenantId);
    }
}
```

> **Note:** Mapper tests require the entity `Create()` and test builders to be implemented (Phase 5a). Write mapper tests in Phase 5b after entity logic is available.
> Add `{Entity}_InlinedChildren_AgreeWith_ChildMappers` only for parents whose `Projection` inlines child DTO collections.

---

## Consolidated Mapper Parity Class

Per-entity `{Entity}MapperTests` classes cover `ToDto`, `ToEntity`, and child-inline parity per entity. **In addition**, scaffold a single consolidated `MapperProjectionParityTests` class that pins the compile-projection / `ToDto` agreement for every mapper in one place. This is a small file but it's the cheapest catch for drift across the whole mapper layer.

### File: `tests/Test.Unit/Mappers/MapperProjectionParityTests.cs`

```csharp
using {Project}.Application.Mappers;
using {Project}.Domain.Model;
using Test.Support;
using Test.Support.Builders;

namespace Test.Unit.Mappers;

/// <summary>
/// Parity guards for the compile-projection pattern. Each mapper exposes a single canonical
/// Projection expression; ToDto reuses the compiled delegate so EF (server-side) and in-memory
/// code paths cannot drift.
///
/// For simple mappers the parity check is trivially true (ToDto IS the compiled projection),
/// but the tests still verify the expression compiles and surfaces all expected fields - i.e.
/// the projection is a real full shape, not a forgotten subset.
///
/// For aggregate roots with inlined child projections the test additionally guards against
/// drift between the parent's inline projection (EF cannot translate child .ToDto() calls)
/// and each child mapper's own ToDto path.
///
/// Owned-type flattening (DateRange / Money / RecurrencePattern -> scalar columns) is also
/// exercised: it must remain EF-translatable AND evaluate correctly in-memory.
/// </summary>
[TestClass]
public class MapperProjectionParityTests
{
    [TestMethod]
    [TestCategory("Unit")]
    public void {Entity}_CompiledProjection_AgreesWith_ToDto()
    {
        var entity = new {Entity}Builder().Build();
        var fromCompiled = {Entity}Mapper.Projection.Compile()(entity);
        var fromToDto = entity.ToDto();

        Assert.AreEqual(fromToDto.Id, fromCompiled.Id);
        Assert.AreEqual(fromToDto.Name, fromCompiled.Name);
        // Assert every scalar, owned-type flattened property, and collection count.
    }

    [TestMethod]
    [TestCategory("Unit")]
    public void {Entity}_InlinedChildren_AgreeWith_ChildMappers()
    {
        // Only generate this method for aggregate roots whose Projection inlines child DTOs.
        var entity = new {Entity}Builder().Build();
        entity.{ChildEntity}s.Add(new {ChildEntity}Builder().With{Entity}Id(entity.Id).Build());

        var fullDto = entity.ToDto();
        var expectedChild = entity.{ChildEntity}s.Single().ToDto();

        Assert.AreEqual(1, fullDto.{ChildEntity}s.Count);
        Assert.AreEqual(expectedChild.Id, fullDto.{ChildEntity}s[0].Id);
        // Assert every child property the parent inline projection emits.
    }

    // One test method per entity. Group by aggregate when entities share a builder.
}
```

### Why both layouts coexist

- Per-entity `{Entity}MapperTests` is the home for `ToDto`/`ToEntity`/owned-type-specific tests - they assert mapper behavior, not just parity.
- Consolidated `MapperProjectionParityTests` is the **one-stop guard** that "EF expression and compiled in-memory delegate emit the same shape" - easy to scan when mapper changes are reviewed, and harder to drift than scattered per-entity duplicates of the same assertion.

Generate the parity class once at scaffold time; add a method per entity as each mapper is built in Phase 5b. Do not duplicate the `*_CompiledProjection_AgreesWith_ToDto` test in the per-entity file when the same assertion already lives in the consolidated class.
