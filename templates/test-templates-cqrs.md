# CQRS Test Templates

## Handler Unit Test

Use the feature namespace for command/query types and validators: `{Project}.Application.Cqrs.Features.{EntityPlural}`.

```csharp
[TestMethod]
public async Task Given_InvalidCommand_When_HandlerRuns_Then_ReturnsFailure()
{
    var command = new Create{Entity}Command(new DefaultRequest<{Entity}Dto>
    {
        Item = new {Entity}Dto()
    });

    var result = await _handler.HandleAsync(command);

    Assert.IsTrue(result.IsFailure);
}
```

## Tenant Ownership Tests (Multi-Tenant)

Add handler and validator tests that prove:

- Given a create/update command whose DTO carries another tenant, both validator and handler overwrite it with `IRequestContext.TenantId` before validation/mapping, and the created/updated entity retains the context tenant.
- Given a valid request-context tenant and a DTO whose `TenantId` is `Guid.Empty`, validator and direct-handler tests succeed after stamping; this fails if validation runs first.
- Given no request-context tenant and a DTO with a non-empty tenant, validation fails and the handler never calls repository create/update/save; DTO fallback is forbidden.
- Given a same-tenant loaded entity and a forged update DTO tenant, the handler preserves the entity tenant; given a different request-context tenant, boundary validation rejects the write.
- Use fresh command and DTO instances for validator and direct-handler tests; shared mutation can make the second assertion pass without exercising its own stamp.

## Validation Decorator Test

Test that invalid commands return a failed `Result` and do not call the inner handler.

## Architecture Test

- CQRS project has no Host dependency.
- CQRS project has no Infrastructure implementation dependency.
- No central request dispatcher, request bus, or generic `Send()` entrypoint.
- Reason: endpoint -> request -> handler wiring stays explicit and testable.
- No CQRS type implements `I{Entity}Service`.
- One command/query has one handler registration through a feature-owned `{Entity}CqrsRegistrations` fragment.
- Root `CqrsHandlerRegistrationCatalog` only aggregates feature fragments.
