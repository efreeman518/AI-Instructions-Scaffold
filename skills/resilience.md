# Resilience

> **When to read:** Phase 5b, when wiring any outbound HTTP client (external API, gateway-to-API, service-to-service) or reviewing retry/circuit/timeout behavior.
> **Skip if:** the app makes no outbound HTTP calls beyond Aspire service discovery defaults, or the current task is pure domain/data work.

Resilience policy for outbound calls: what the scaffold applies by default, when to customize, and what to leave alone. Package: `Microsoft.Extensions.Http.Resilience` (already part of the reference-app stack via ServiceDefaults).

## Standard Resilience Handler (default path)

Every `HttpClient` registered through `AddServiceDefaults()` gets `AddStandardResilienceHandler()` automatically - see [aspire.md](aspire.md) section ServiceDefaults Pattern. The standard pipeline bundles, in order: rate limiter, total-request timeout, retry (exponential + jitter), circuit breaker, and per-attempt timeout. Service-discovery internal calls (API -> API, Gateway -> API) therefore need **no additional wiring** - the default is the policy.

## Custom Per-Client Pipelines

Use a named `AddResilienceHandler` only for external third-party APIs whose failure profile differs from internal traffic (aggressive provider rate limits, slow cold starts, flaky sandboxes). The canonical Refit + settings-driven example lives in [external-api.md](external-api.md) section DI + Refit + Resilience - do not duplicate that code; bind the knobs through `{ServiceName}Settings`.

Default knobs (aligned with the `{ServiceName}Settings` shape):

| Knob | Default | Notes |
|---|---|---|
| `RetryCount` | 3 | Exponential backoff, `UseJitter = true` |
| `CircuitBreakerThreshold` (`MinimumThroughput`) | 5 | `FailureRatio` 0.5 over a 30s sampling window |
| Break duration | 15s | Probe half-open after this |
| Per-attempt timeout | 10s | Inside the pipeline |
| `TimeoutSeconds` (client total) | 30 | `HttpClient.Timeout` is the outer bound |

Keep the client total timeout larger than `retries x per-attempt timeout` budget or retries get cut off mid-flight.

## Internal-Call Guidance

- **Never stack pipelines.** A client that already has the standard handler (via ServiceDefaults) must not also get a custom `AddResilienceHandler` - double retry multiplies load during incidents.
- Retries are safe for idempotent calls (GET, PUT with full payload, DELETE). **Do not retry non-idempotent POSTs** unless the endpoint is idempotency-keyed; a retried create duplicates data.
- In-process calls (service -> repository, domain methods) get no resilience wrapper - failures there are bugs or store outages, surfaced through `Result<T>`/exceptions, not retried.

## What NOT to Wrap

| Dependency | Why no HTTP resilience pipeline |
|---|---|
| EF Core / SQL | `EnableRetryOnFailure` on the provider owns transient retry - see [data-persistence.md](data-persistence.md) |
| Service Bus / Azure SDK clients | The SDKs ship built-in retry policies; configure via client options, not a wrapper |
| FusionCache-backed reads | Fail-safe serves stale entries under dependency failure - see [caching.md](caching.md); adding HTTP retry underneath delays the fail-safe path |
| Scaffold no-op stubs | Stubs never fail; wrapping them hides nothing and adds noise |

## Verification

- [ ] Internal clients rely on ServiceDefaults only (no custom pipeline stacked on the standard handler)
- [ ] Each external client has exactly one named pipeline with settings-bound knobs
- [ ] No retry on non-idempotent POSTs without an idempotency key
- [ ] Client total timeout exceeds the retry budget
- [ ] Circuit-breaker open state surfaces as a `Result` failure / `ProblemDetails`, not an unhandled exception (see [api.md](api.md) section Error Handling Strategy)
