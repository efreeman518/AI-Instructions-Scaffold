# Solution Structure

## Purpose

Define the canonical clean-architecture layout and dependency direction used by all hosts (API, Scheduler, Functions, Gateway, UI) through a shared Bootstrapper.

## Non-Negotiables

1. Use `.slnx` as the solution format (not legacy `.sln`).
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
|   |-- {Host}.Uno/                     # optional
|   |-- {Host}.Uno.Core/                # optional
|   |-- {Host}.Blazor/                  # optional
|   `-- {Host}.React/                   # optional
|-- Test/
|   |-- Test.Unit/                    # mocked unit tests
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

Failure mode is **invisible locally** (files on disk, build green) and surfaces only on a fresh clone or CI runner. The execution-gates post-generation step runs a `git ls-files` check to catch the same class of bug for any future scaffold folder whose name collides with a stock ignore pattern - see [../support/execution-gates.md](../support/execution-gates.md) section Tracked-Source Validation.

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

---

## Minimal Reference Matrix

| Project | Direct References (minimum) |
|---|---|
| `Domain.Shared` | none |
| `Domain.Model` | `Domain.Shared` |
| `Application.Models` | shared/common abstractions as needed |
| `Application.Mappers` | `Application.Models`, `Domain.Model`, `Domain.Shared` |
| `Application.Contracts` | `Application.Models`, `Domain.Model`, `Domain.Shared` |
| `Application.Services` | `Application.Contracts`, `Application.Mappers`, `Application.Models`, domain projects |
| `Application.Cqrs` | `Application.Contracts`, `Application.Mappers`, `Application.Models`, domain projects, `<Prefix>.CQRS` |
| `Infrastructure.Data` | domain projects |
| `Infrastructure.Repositories` | `Application.Contracts`, `Infrastructure.Data` |
| `{Host}.Bootstrapper` | app/infrastructure implementations |

Default scaffold and TaskFlow keep `Application.Cqrs` referencing shared `Application.Models` and `Application.Mappers` so service and CQRS styles share one contract. A CQRS-only vertical slice may move feature-specific models, mappers, projections, and adapters under `Application.Cqrs/Features/{Entity}` and then trim unused shared project references.
| `{Host}.Api` / `{Host}.Scheduler` / `{Host}.Functions` | `{Host}.Bootstrapper` (+ host-specific packages) |

Adjust optional dependencies per enabled features without inverting layer direction.

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

- [ ] `.slnx` exists and is the active solution format
- [ ] `dotnet build` succeeds from `src/`
- [ ] `Directory.Packages.props` is present and controls package versions
- [ ] `global.json` uses `latestFeature` roll-forward
- [ ] `nuget.config` includes required public/private feeds
- [ ] Domain projects do not reference Application/Infrastructure
- [ ] Host projects depend on Bootstrapper instead of duplicating shared DI wiring
- [ ] Optional hosts can be removed without breaking core layer compilation
- [ ] token placeholders follow [placeholder-tokens.md](../ai/placeholder-tokens.md)
