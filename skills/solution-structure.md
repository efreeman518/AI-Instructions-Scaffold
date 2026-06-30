# Solution Structure

## Purpose

Define the canonical clean-architecture layout and dependency direction used by all hosts (API, Scheduler, Functions, Gateway, UI) through a shared Bootstrapper.

## Non-Negotiables

1. Use `.slnx` as the solution format (not legacy `.sln`). Place it at **`src/{SolutionName}.slnx`** - inside `src/`, not at the repo root. The repo root holds only cross-cutting files (`.gitignore`, `.editorconfig`, `CLAUDE.md`, `AGENTS.md`, `HANDOFF.md`, `infra/`, `docs/`).
2. Maintain dependency flow: Domain -> Application -> Infrastructure -> Bootstrapper -> Hosts.
3. Domain projects never reference Application or Infrastructure.
4. Use central package management via `Directory.Packages.props`.
5. Host projects add host-specific wiring only; shared registrations stay in Bootstrapper.
6. **One public type per file.** Each `.cs` file declares exactly one public/internal top-level type and the file name matches that type. This rule is **universal** - it applies to generated app code (`src/Domain`, `src/Application`, `src/Infrastructure`, `src/Host`, `src/UI`, `src/Test`) **and** to local-package source under `src/Packages/<Prefix>.*` (the vendored `<packagePrefix>.*` shared surface). Lumped files (e.g. `ServiceBus.cs` declaring multiple message types, `Models.cs` declaring multiple DTOs, `Constants.cs` containing nested helper classes) must be split at generation time. The only permitted exceptions are: (a) nested types whose visibility is `private` to the outer type, (b) records / classes that exist solely to parameterize a generic type and are tightly coupled to the declaring file (rare - prefer splitting), and (c) compiler-generated partials. When scaffolding touches an existing lumped vendored file under `src/Packages/`, split it during that same sub-phase rather than leaving it as a tracked debt item.

---

## Canonical Folder Layout

```
src/
|-- Packages/                                       # only when packageStrategy: local or hybrid
|   |-- {Prefix}.Domain/                            # generated only for layers in localPackageLayers
|   |-- {Prefix}.Domain.Contracts/
|   |-- {Prefix}.Data/
|   |-- {Prefix}.Data.Contracts/
|   |-- {Prefix}.CQRS/                              # when applicationStyle: cqrs or switch
|   |-- {Prefix}.Common/
|   `-- {Prefix}.Common.Contracts/
|-- Domain/
|   |-- {Project}.Domain.Model/
|   `-- {Project}.Domain.Shared/
|-- Application/
|   |-- {Project}.Application.Contracts/
|   |-- {Project}.Application.Mappers/
|   |-- {Project}.Application.Models/
|   |-- {Project}.Application.Services/
|   |-- {Project}.Application.Cqrs/                 # when applicationStyle: cqrs or switch
|   `-- {Project}.Application.MessageHandlers/
|-- Infrastructure/
|   |-- {Project}.Infrastructure.Data/
|   |-- {Project}.Infrastructure.Repositories/
|   `-- {Project}.Infrastructure.{ServiceName}/
|-- Host/
|   |-- {Host}.Bootstrapper/
|   |-- {Host}.Api/
|   |-- {Host}.Scheduler/               # optional
|   |-- {Host}.BackgroundServices/      # optional
|   |-- {Gateway}.Gateway/              # optional
|   |-- {Host}.Functions/               # optional
|   `-- Aspire/
|       |-- AppHost/
|       `-- ServiceDefaults/
|-- UI/
|   |-- {Host}.Uno/                     # optional Uno.Sdk app head: XAML, styles, platform assets
|   |-- {Host}.Uno.Core/                # optional Microsoft.NET.Sdk library: business models, services, client
|   |-- {Host}.Uno.Presentation/        # optional Microsoft.NET.Sdk library: MVUX models, UI state/feed logic
|   |-- {Host}.Blazor/                  # optional
|   `-- {Host}.React/                   # optional
|-- Test/
|   |-- Test.Unit/                    # pure domain/application unit tests
|   |-- Test.UI/                      # fast headless UI model/presentation tests; no app head reference
|   |-- Test.Integration/             # component: one class vs one real store (standalone Testcontainers SQL/Azurite/Redis)
|   |-- Test.Aspire/                  # mesh: full AppHost graph over HTTP (lazy-started; Docker-gated)
|   |-- Test.Endpoints/               # WebApplicationFactory in-memory; per-endpoint contract tests
|   |-- Test.E2E/                     # WebApplicationFactory + Testcontainers SQL; multi-endpoint workflow chains
|   |-- Test.Architecture/            # NetArchTest layering rules
|   |-- Test.PlaywrightUI/            # browser-driven UI tests against hosted stack (Aspire/docker-compose)
|   |-- Test.Load/                    # NBomber (comprehensive profile)
|   |-- Test.Benchmarks/              # BenchmarkDotNet (comprehensive profile)
|   |-- Test.Mutation/                # Stryker.NET mutation tests (comprehensive profile)
|   `-- Test.Support/                 # shared bases, builders, fixtures
|-- Directory.Packages.props
|-- global.json
|-- nuget.config
|-- .gitattributes
|-- .gitignore
|-- .editorconfig
`-- {SolutionName}.slnx
```

Reference patterns: [../patterns/expected-output-index.md](../patterns/expected-output-index.md).

### Project-Name Prefix (`projectNamePrefix`)

The `{Project}.` / `{Host}.` prefix shown above is the **default** (`projectNamePrefix: solution-name`, set in Phase 1) and matches the TaskFlow reference app. When Phase 1 records `projectNamePrefix: none`, the prefix tokens collapse to empty and the layout uses bare project names, folders, and root namespaces:

```
src/
|-- Domain/
|   |-- Domain.Model/              # was {Project}.Domain.Model
|   `-- Domain.Shared/
|-- Application/
|   |-- Application.Contracts/
|   `-- Application.Services/
|-- Infrastructure/
|   |-- Infrastructure.Data/
|   `-- Infrastructure.Repositories/
|-- Host/
|   |-- Bootstrapper/              # was {Host}.Bootstrapper
|   `-- Api/                       # was {Host}.Api
...
`-- {SolutionName}.slnx            # solution file name is NOT collapsed
```

The `{SolutionName}.slnx` file keeps its full name either way, and `{App}`-derived types render without the prefix (`DbContextTrxn` / `DbContextQuery`). `OrganizationName` is not applied under `none`. Test, `src/Packages/`, and `Aspire/` project names already omit the prefix and are unchanged by this setting. Token mechanics: [../ai/placeholder-tokens.md - Derivation Rules](../ai/placeholder-tokens.md#derivation-rules).

> **The prefix is not just verbosity - it prevents framework assembly/namespace collisions.** Bare project names and root namespaces collide with platform identities, and the failures are confusing:
> - A bare **`Uno`** / **`Uno.Core`** project name clashes with the Uno Platform's own `Uno.*` assemblies.
> - A bare **`Application`** layer creates a root `Application` namespace that **shadows `Microsoft.UI.Xaml.Application`** (and WPF's `System.Windows.Application`) inside any referencing UI project - the XAML code-behind base class fails to resolve (CS0118), and a `global using Application = ...` alias added to "fix" it then collides with the namespace (CS0576).
> - Bare `Domain.Model` / `Application.Services` also collide when consumed alongside other solutions.
>
> Because of this, `projectNamePrefix: none` is an accepted Phase-1 trade-off only for **backend-only** solutions, recorded in `.scaffold/DESIGN-DECISIONS.md`. When de-prefixing is requested **and a Uno/Blazor/WPF UI head is in scope**, do one of: (a) keep the prefix on UI heads and the `Application` layer (de-prefix the rest); (b) keep a short qualifier so no project is bare `Uno`/`Uno.Core`/`Application`; or (c) emit fully-qualified base types in generated XAML code-behind (`: global::Microsoft.UI.Xaml.Application`). Default to (a). Never ship a bare `Application` namespace into a XAML project.

### Required Root Files (Cross-Platform Hygiene)

The scaffold drops `.gitattributes`, `.gitignore`, and `.editorconfig` at repo root on first generation.

**`.gitattributes`** - pins working-tree line endings so Windows clients with `core.autocrlf=true` (installer default) don't spam `LF will be replaced by CRLF` warnings on every `git status` and don't block commits under `safecrlf=true`. Minimum content:

```gitattributes
* text=auto eol=lf
*.bat text eol=crlf
*.cmd text eol=crlf
*.ps1 text eol=crlf
*.png binary
*.jpg binary
*.ico binary
```

Add at scaffold time - retroactive `.gitattributes` requires `git add --renormalize .` to take effect.

**`.gitignore`** - `dotnet new gitignore` baseline plus Aspire local volumes, Function App secrets, and coverage outputs. **The stock Visual Studio `.gitignore` has two rules that collide with this scaffold's folder names and silently exclude source from `git add` - patch both:**

```gitignore
# `src/Packages/` is a SOURCE folder in this repo (local `<packagePrefix>.*`
# projects), not a NuGet restore folder. The stock `**/[Pp]ackages/*` rule
# matches it case-insensitively on Windows (core.ignoreCase=true is the
# default), so every `<packagePrefix>.*.csproj` under it gets skipped by
# `git add` - local build passes, fresh CI clone fails with MSB3202.
!src/Packages/
!src/Packages/**
src/Packages/**/bin/
src/Packages/**/obj/
```

Also **remove the line `*.e2e`** from the stock template. It targets a legacy Visual Studio trace format this scaffold never produces, but it matches the `Test.E2E/` project directory case-insensitively on Windows and silently excludes the entire E2E test project from git.

**Add ignore patterns for generated test output:** Stryker.NET reports are local quality artifacts and should not be committed. Append:

```gitignore
# Generated test output
**/StrykerOutput/
```

**Add ignore patterns for scaffold-session leakage:** Aspire's local launcher and other tooling occasionally drop transient log files at project root (e.g. `c..tmpaspire-run.log`). These are not scaffold artifacts and should never be committed. Append:

```gitignore
# Scaffold-session leakage (transient logs from local tooling)
/c..tmpaspire-run.log
/*.tmpaspire-run.log
**/aspire-run.log
*.tmp.log
```

Note: `.scaffold/` is a **tracked** directory - it holds the Phase 1/2/3 artifacts (`domain-specification.yaml`, `resource-implementation.yaml`, `UBIQUITOUS-LANGUAGE.md`, `DESIGN-DECISIONS.md`, `implementation-plan.md`) plus `INSTRUCTION-GAPS.md`. Do not add `.scaffold/` to `.gitignore`.

Failure mode is **invisible locally** (files on disk, build green) and surfaces only on a fresh clone or CI runner. The operator-setup post-generation step runs a `git ls-files` check to catch the same class of bug for any future scaffold folder whose name collides with a stock ignore pattern - see [../support/operator-setup.md](../support/operator-setup.md) section Tracked-Source Validation.

**`.editorconfig`** - pinned tab/space + `end_of_line = lf` (belt-and-suspenders with `.gitattributes`).

**Shell redirects:** scaffolded shell-agnostic scripts use `> /dev/null`, never `> NUL`. From git-bash, `> NUL` creates a real on-disk file named `NUL` that Win32 then can't open, breaking `git add -A`. Reserve `> nul` (lowercase) for files that only run under `cmd.exe`.

Note: Domain rules and specifications live in `Domain.Model/Rules/` (or `Domain.Model/Specifications/`). A separate `Domain.Rules` project is not required.

Note: `src/Packages/` exists only when `packageStrategy` is `local` or `hybrid` (set in `.scaffold/resource-implementation.yaml`). Generate one packable project per entry in `localPackageLayers`, matching the layer set in [`../support/ef-packages-reference.md`](../support/ef-packages-reference.md). Each project sets `IsPackable=true` and `<PackageId>=<Prefix>.<Layer>` so it can later be published to a feed and consumed via `<PackageReference>` without restructuring. When `applicationStyle` is `cqrs` or `switch`, include `<Prefix>.CQRS` in this local/feed layer set. When `packageStrategy: feed`, omit the `Packages/` folder entirely - the contracts come from `customNugetFeeds`.

---

## Dependency Direction (Contract)

Required flow:

```
{Prefix}.Common.Contracts / {Prefix}.Domain.Contracts / {Prefix}.Data.Contracts   # local/hybrid only; otherwise NuGet packages
        ^                            ^                          ^
        |                            |                          |
Domain.Shared <- Domain.Model
            \-> Application.Models <- Application.Contracts <- Application.Services
                                  \-> Application.Mappers   /
                                  \-> Application.Cqrs
                                                \-> Application.MessageHandlers
Domain.Model -> Infrastructure.Data -> Infrastructure.Repositories
Application.Contracts -> Infrastructure.Repositories
Application + Infrastructure -> {Host}.Bootstrapper
{Host}.Bootstrapper -> host projects (API/Scheduler/FunctionApp)
```

`src/Packages/<Prefix>.*` projects sit at the **bottom** of the dependency graph in `local`/`hybrid` mode - every other layer may depend on them, but they may not depend on any project-specific layer. In `feed` mode, this constraint is enforced by NuGet (packages can't reference local projects).

### Host Rules

- API/Scheduler/FunctionApp reference Bootstrapper and add host-only config.
- Gateway and UI follow their own skills but must not violate core dependency direction.
- Optional hosts should be removable without breaking core layer compilation.
- Uno MVUX presentation records live in `{Host}.Uno.Presentation`, not in the `{Host}.Uno` `Uno.Sdk` app head. `{Host}.Uno.Presentation` and `{Host}.Uno.Core` are plain `Microsoft.NET.Sdk` libraries so `Test.UI` can exercise UI/presentation logic without building platform targets. `{Host}.Uno` references `{Host}.Uno.Presentation`; `Test.UI` references `{Host}.Uno.Core` and `{Host}.Uno.Presentation`.

---

## `.slnx` Requirement

Use XML-based `.slnx` as the final solution artifact.

- Preferred: author `.slnx` directly from the reference pattern.
- If CLI scaffolding creates `.sln`, migrate and remove the `.sln` before continuing.

Do not keep both formats in active use.

---

## SDK and Package Management

### `global.json`

- Pin to latest stable installed SDK.
- Keep `rollForward` as `latestFeature`.

```json
{
  "sdk": {
    "version": "<latest-installed-stable-sdk>",
    "rollForward": "latestFeature"
  }
}
```

Resolve `<latest-installed-stable-sdk>` from `dotnet --list-sdks` at scaffold time (do not hard-code).

### `Directory.Packages.props`

- `ManagePackageVersionsCentrally=true`.
- No package versions in project-level `<PackageReference>` entries.
- Update package versions centrally only.

### `.csproj` Conventions

- Target the latest stable TFM supported by the pinned SDK.
- Enable `ImplicitUsings` and `Nullable`.
- API/Gateway use `Microsoft.NET.Sdk.Web`; library projects use `Microsoft.NET.Sdk`.

---

## Infrastructure Naming Rules

- One infrastructure project per external integration.
- Use service-descriptive suffixes (for example: `Infrastructure.Notification`, `Infrastructure.EntraExt`).
- Expose contracts in Application layer; keep implementations in Infrastructure.
- Register each infrastructure module through Bootstrapper extension methods.

### Wrap vs. Direct Reference

Not every external dependency earns an Infrastructure project. Two paths:

- **Wrap (default).** The application layer owns the interface in `Application.Contracts`; the Infrastructure project references `Application.Contracts` and implements it. Services/handlers inject the contract, never the provider type. This is the path for bespoke repositories, Refit API wrappers, and Service Bus / Event Grid adapters. The Infrastructure-references-`Application.Contracts` dependency direction (see the Minimal Reference Matrix) exists precisely so the implementation can satisfy the app-owned interface.
- **Direct reference (exception).** When a library already ships a stable, app-shaped interface, the application layer references that package and injects the interface directly - no `Application.Contracts` interface, no Infrastructure project. FusionCache (`IFusionCache` / `IFusionCacheProvider`) is the canonical case: the cache abstraction is already what you would have written, so wrapping it only re-exports the same shape.

Criterion: wrap when the provider's surface is provider-shaped, transport-coupled, or needs DTO/error mapping (the wrapper rules in [external-api.md](external-api.md)); reference directly when the provider's interface is already the abstraction you would have authored. A direct reference means the `Application` project takes the package reference itself - call that out, it is the deliberate exception to the otherwise internal-only application reference surface (see the Minimal Reference Matrix note).

---

## Minimal Reference Matrix

| Project | Direct References (minimum) |
|---|---|
| `Domain.Shared` | none |
| `Domain.Model` | `Domain.Shared` |
| `Application.Models` | shared/common abstractions as needed |
| `Application.Mappers` | `Application.Models`, `Domain.Model`, `Domain.Shared` |
| `Application.Contracts` | `Application.Models`, `Domain.Model`, `Domain.Shared` |
| `Application.Services` | `Application.Contracts`, `Application.Mappers`, `Application.Models`, domain projects, + external packages whose interface is the contract (e.g. FusionCache) |
| `Application.Cqrs` | `Application.Contracts`, `Application.Mappers`, `Application.Models`, domain projects, `<Prefix>.CQRS`, + external packages whose interface is the contract (e.g. FusionCache) |
| `Infrastructure.Data` | domain projects |
| `Infrastructure.Repositories` | `Application.Contracts`, `Infrastructure.Data` |
| `{Host}.Bootstrapper` | app/infrastructure implementations |

Default scaffold and TaskFlow keep `Application.Cqrs` referencing shared `Application.Models` and `Application.Mappers` so service and CQRS styles share one contract. A CQRS-only vertical slice may move feature-specific models, mappers, projections, and adapters under `Application.Cqrs/Features/{Entity}` and then trim unused shared project references.
| `{Host}.Api` / `{Host}.Scheduler` / `{Host}.Functions` | `{Host}.Bootstrapper` (+ host-specific packages) |

Adjust optional dependencies per enabled features without inverting layer direction. The `+ external packages whose interface is the contract` clause on the application rows is the deliberate direct-reference exception (see Infrastructure Naming Rules -> Wrap vs. Direct Reference): a library like FusionCache whose own interface is already the abstraction is referenced straight from the application layer, so the application project takes that package reference and no Infrastructure wrapper exists. Wrapped integrations (repositories, Refit APIs, messaging adapters) keep their package references in the Infrastructure implementation project, not in the application layer.

---

## EF.Packages Source Reference

The private EF.* NuGet packages (`EF.Domain`, `EF.Application`, `EF.Infrastructure`, `EF.Data`, `EF.Utility`, `EF.InternalMessageBus`) have full source available at:

**[https://github.com/efreeman518/EF.Packages](https://github.com/efreeman518/EF.Packages)**

Use this repo as the **authoritative source of truth** for all EF.* types, APIs, and patterns when scaffolding. Key types to understand:

| Type | Package | Purpose |
|---|---|---|
| `EntityBase` | EF.Domain | Base entity with `Id` (init, V7 GUID) and `RowVersion` (nullable byte[]) |
| `AuditableBase<T>` | EF.Domain | EntityBase + audit properties (rarely used when AuditInterceptor is active) |
| `DomainResult<T>` | EF.Domain.Contracts | Railway-oriented domain operation result |
| `Result` / `Result<T>` | EF.Domain.Contracts | Application-layer operation results |
| `RepositoryBase<TCtx,TAudit,TTenant>` | EF.Data | Base repository with CRUD + concurrency |
| `DbContextBase` | EF.Data | Base context - `SaveChangesAsync(ct)` throws `NotImplementedException` by design |
| `IRequestContext` | EF.Utility | Tenant, Roles, CorrelationId, AuditId (NO `.UserId`) |
| `IInternalMessageBus` | EF.InternalMessageBus | Synchronous `Publish()` (NOT async) |

---

## Verification

- [ ] `src/{SolutionName}.slnx` exists at `src/` root (not the repo root) and is the active solution format
- [ ] `dotnet build` succeeds from `src/`
- [ ] `Directory.Packages.props` is present and controls package versions
- [ ] `global.json` uses `latestFeature` roll-forward
- [ ] `nuget.config` includes required public/private feeds
- [ ] Domain projects do not reference Application/Infrastructure
- [ ] Host projects depend on Bootstrapper instead of duplicating shared DI wiring
- [ ] Optional hosts can be removed without breaking core layer compilation
- [ ] token placeholders follow [placeholder-tokens.md](../ai/placeholder-tokens.md)
