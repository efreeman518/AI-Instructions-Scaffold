# CQRS Validation Template

Custom validation only. Do not add FluentValidation or another third-party validation package.

Put CQRS validators in `Application.Cqrs/Features/{Entity}/{Entity}CommandValidators.cs`. Put shared validation-result mapping in `Application.Cqrs/Features/Shared/CqrsHandlerSupport.cs` so feature validators stay small.

```csharp
namespace {Project}.Application.Cqrs.Features.{EntityPlural};

internal sealed class Create{Entity}CommandValidator(IRequestContext<string, Guid?> requestContext)
    : IRequestValidator<Create{Entity}Command>
{
    public Task<RequestValidationResult> ValidateAsync(Create{Entity}Command request, CancellationToken ct = default)
    {
        var dto = request.Request.Item;
        var authoritativeTenantId = requestContext.TenantId ?? Guid.Empty;
        dto.TenantId = authoritativeTenantId; // overwrite untrusted payload before validation
        var validation = {Entity}StructureValidator.ValidateCreate(dto);
        return Task.FromResult(CqrsHandlerSupport.ToValidationResult(validation));
    }
}
```

Put cheap shape validation in validators when it removes repeated handler code. Keep aggregate/domain invariants in domain methods. Multi-tenant validators and handlers both stamp from `IRequestContext` so every execution path is server-authoritative; neither may use DTO tenant as fallback.

Registration stays in `Registration/CqrsApplicationRegistration.cs`:

```csharp
services.AddScoped<IRequestValidator<Create{Entity}Command>, Create{Entity}CommandValidator>();
```
