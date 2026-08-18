# Reference Application - TaskFlow

A companion reference app that provides executable proof for selected high-value patterns without claiming universal coverage.

**Repository:** <https://github.com/efreeman518/AI-Instructions-ReferenceApp>

TaskFlow is a scaffolded task-management application built by following this instruction set end-to-end. It covers dual DbContext pooling, YARP gateway with claims transformation, Aspire orchestration, FusionCache with Redis backplane, TickerQ scheduling, Azure Functions, multi-tenancy, scaffold-mode auth, Uno WASM UI, Blazor UI, and React/Vite UI.

## Coverage contract

TaskFlow's `.scaffold/REFERENCE-STATUS.md` is the canonical current matrix. Read each capability through one of four statuses:

| Status | Meaning |
|---|---|
| `proven` | Implemented and covered by executable build, test, or smoke evidence |
| `deployment-only` | Generated or wired, but live acceptance requires deployed external resources or identity |
| `documented-only` | Example or opt-in documentation exists without active runtime wiring |
| `not enabled` | Intentionally absent from TaskFlow configuration |

Do not promote `deployment-only` or `documented-only` examples as compiled proof. Use the [proof map](taskflow-proof-map.md) only for capabilities marked `proven` in current status.

## When to consult it

- **Pattern lookups** - when an instruction or template describes a pattern (e.g., middleware ordering, repository split, cache key format), TaskFlow contains the working implementation.
- **Wiring verification** - cross-project DI registration, startup sequences, and Aspire resource definitions are all present and buildable.
- **Test structure** - unit, integration, architecture, endpoint, and full-stack test projects are scaffolded. `tests/Test.Support/Hosting/DockerRuntimePreflight.cs` owns the bounded dual-stream capability check; `tests/Test.Support/Aspire/AspireTestHostContext.cs` owns the cumulative startup deadline, named resource waits, diagnostics, and bounded cleanup. Mesh and Playwright/WASM adapters consume the context; component container tiers reuse the generic preflight.

For a phase-by-phase pointer map into the reference app, use [taskflow-proof-map.md](taskflow-proof-map.md).

## How the AI accesses it

- **Local clone preferred:** if `../AI-Instructions-ReferenceApp/` exists relative to the target project's parent, the AI reads TaskFlow files via the Read tool.
- **Fallback:** GitHub MCP. Use only when the local clone is absent.

## Rules

- Do not install the scaffold `.instructions/` payload into TaskFlow during normal maintenance. TaskFlow is the proof/reference implementation; install into it only when deliberately testing installer behavior.
- Do not copy TaskFlow files wholesale - use as a verified example and generate code matching the target project's domain.
- When stuck on how a pattern should look in practice, consult TaskFlow before inventing a new approach.
- Treat TaskFlow as a live codebase reference whenever local clone or GitHub MCP access is available. If neither access path is available, note the gap in `HANDOFF.md` and continue with the current instruction set.

## CQRS Reference App

The TaskFlow reference app demonstrates `applicationStyle: switch`: side-by-side service and CQRS endpoint registration with one mapped at runtime. Default configuration is `Application:Style=Service`; set `TASKFLOW_APPLICATION_STYLE=Cqrs` or `Application:Style=Cqrs` to map CQRS endpoints and register handlers. CQRS handlers use the existing repository contracts directly. CQRS endpoints avoid central request dispatchers, request buses, and generic `Send()` entrypoints so each route shows the exact request and handler it invokes.

TaskFlow keeps DTOs in `Application.Models` and static mappers in `Application.Mappers` so service and CQRS endpoints share one demo contract. A stricter CQRS implementation can consolidate feature-specific models, mappers, projections, validators, and handlers under `Application.Cqrs/Features/{Entity}` when those shapes are not shared.

TaskFlow also demonstrates the route-versioning boundary: public domain API routes are versioned under `/api/v1/*`, while operational and host-management routes stay unversioned (`/health/*`, `/alive`, `/healthz`, `/api/flowengine/*`, and Functions host health `/api/health`). Azure Functions business HTTP triggers mirror the public versioned contract under the Functions default `/api` prefix.
