# Dockerfile Template

| | |
|---|---|
| **File** | `src/Host/{Host}.Api/Dockerfile` (or per-host project root under `Host/`) |
| **Depends on** | [skills/cicd.md](../skills/cicd.md), [skills/iac.md](../skills/iac.md) |
| **Referenced by** | [skills/aspire.md](../skills/aspire.md) |

## Multi-Stage Chiseled Pattern

Use this pattern for all host projects (API, Gateway, Scheduler, Functions).

```dockerfile
# ===== Stage 1: Restore (cached layer) =====
FROM mcr.microsoft.com/dotnet/sdk:latest AS restore
WORKDIR /src

# Copy only project files + central package management for restore cache
COPY Directory.Build.props .
COPY Directory.Packages.props .
# Emit this line only when the scaffold generated repo-root nuget.config.
COPY nuget.config .
COPY global.json .
COPY {SolutionName}.slnx .

# Copy all .csproj files preserving folder structure
COPY src/Domain/{Project}.Domain.Model/{Project}.Domain.Model.csproj src/Domain/{Project}.Domain.Model/
COPY src/Application/{Project}.Application.Models/{Project}.Application.Models.csproj src/Application/{Project}.Application.Models/
COPY src/Application/{Project}.Application.Contracts/{Project}.Application.Contracts.csproj src/Application/{Project}.Application.Contracts/
COPY src/Application/{Project}.Application.Mappers/{Project}.Application.Mappers.csproj src/Application/{Project}.Application.Mappers/
COPY src/Application/{Project}.Application.Services/{Project}.Application.Services.csproj src/Application/{Project}.Application.Services/
COPY src/Infrastructure/{Project}.Infrastructure.Data/{Project}.Infrastructure.Data.csproj src/Infrastructure/{Project}.Infrastructure.Data/
COPY src/Infrastructure/{Project}.Infrastructure.Repositories/{Project}.Infrastructure.Repositories.csproj src/Infrastructure/{Project}.Infrastructure.Repositories/
COPY src/Host/{Host}.Bootstrapper/{Host}.Bootstrapper.csproj src/Host/{Host}.Bootstrapper/
COPY src/Host/{Host}.Api/{Host}.Api.csproj src/Host/{Host}.Api/

RUN dotnet restore src/Host/{Host}.Api/{Host}.Api.csproj

# ===== Stage 2: Build + Publish =====
FROM restore AS publish
COPY . .
RUN dotnet publish src/Host/{Host}.Api/{Host}.Api.csproj \
    -c Release \
    -o /app/publish \
    --no-restore

# ===== Stage 3: Runtime (chiseled, non-root) =====
# Default to the SMALLEST chiseled variant (see "Chiseled variant selection" below).
# `-chiseled` has no ICU/tzdata, so pair it with <InvariantGlobalization>true</InvariantGlobalization>
# in the host .csproj. Step up to `-noble-chiseled-extra` only when the app needs globalization
# (culture-aware formatting/sorting, non-UTC time zones) or libstdc++.
FROM mcr.microsoft.com/dotnet/aspnet:10.0-noble-chiseled AS runtime
WORKDIR /app
COPY --from=publish /app/publish .

# Health probes - configure at orchestrator level (Container Apps / Kubernetes),
# not via HEALTHCHECK directive (chiseled images have no shell/curl).
# See skills/aspire.md for Container Apps health probe configuration.

EXPOSE 8080
ENTRYPOINT ["dotnet", "{Host}.Api.dll"]
```

## Variant: Gateway

Same pattern but replace `{Host}.Api` with `{Gateway}.Gateway` and include YARP dependencies.

## Variant: Scheduler

Same pattern but replace `{Host}.Api` with `{Host}.Scheduler` and include TickerQ dependencies. Add `--replicas=1` in orchestration.

## Variant: Function App

```dockerfile
FROM mcr.microsoft.com/azure-functions/dotnet-isolated:4-dotnet-isolated10.0 AS runtime
WORKDIR /home/site/wwwroot
COPY --from=publish /app/publish .
# Isolated worker listens on port 80 (image sets no ASPNETCORE_URLS).
EXPOSE 80
```

> **Functions port is 80, not 8080.** The dotnet-isolated base image listens on **80**; do not add `EXPOSE 8080` or set `ASPNETCORE_URLS=...:8080` for Functions. On Container Apps the Functions app's `--target-port`/ingress must be 80. This differs from the ASP.NET hosts above, which use 8080. See [skills/function-app.md](../skills/function-app.md) -> *Container Port on ACA*.

## Build Context

This template's `COPY` paths reference both repo-root files (`Directory.Build.props`, `Directory.Packages.props`, `{SolutionName}.slnx`) and `src/...` paths, so it is built with the **repo root** as context:

```bash
docker build -f src/Host/{Host}.Api/Dockerfile .
```

The build context must match the Dockerfile's `COPY` roots. If you rewrite `COPY` lines to be `src/`-relative, build from `src/` instead. Keep the CI build context ([skills/cicd.md](../skills/cicd.md)) aligned with whichever rooting this Dockerfile uses - do not assume `src/`.

## Chiseled variant selection

Always ship the **smallest chiseled variant the app actually needs** - smaller image, smaller attack surface, faster pulls. Start at the most-chiseled rung and step up only when a runtime need forces it:

1. **`-chiseled`** (default target) - no ICU, no tzdata, no `libstdc++`. Requires `InvariantGlobalization=true` (culture-invariant formatting/sorting, UTC-only). Use for APIs/services that don't do culture-aware formatting or time-zone conversion.
2. **`-chiseled-extra`** - adds ICU (globalization), tzdata (`TimeZoneInfo` beyond UTC), and `libstdc++`. Use only when the app needs culture-aware formatting/sorting, non-UTC time zones, or native components that link `libstdc++`.
3. **`-chiseled-aot`** - for Native AOT / trimmed self-contained publishes; no ICU/tzdata/`libstdc++`.

Prefer `-chiseled` and set `<InvariantGlobalization>true</InvariantGlobalization>`; escalate to `-chiseled-extra` only after confirming a globalization/tzdata/`libstdc++` dependency. Never fall back to the full (non-chiseled) `aspnet` image for production.

## Rules

- **Always use chiseled base images** for production - smaller attack surface, no shell. Default to the most-chiseled variant (`-noble-chiseled`) and escalate to `-noble-chiseled-extra` only when needed - see *Chiseled variant selection* above.
- **Base image versions track the latest .NET** - build on `sdk:latest`; pin the chiseled runtime to the current .NET major (`10.0` today, `-noble-chiseled` has no floating tag). These advance with each .NET release. Keep the runtime major aligned with the project's `TargetFramework` - `sdk:latest` can roll ahead of the pinned runtime major, so bump the runtime tag in the same change that raises the TFM.
- **Restore layer caching:** Copy `.csproj` files first, then `dotnet restore`, then copy source. This ensures source changes don't invalidate the restore cache.
- **Port:** Default to `8080` for ASP.NET hosts (API/Gateway/Scheduler) on Container Apps. **Exception: Azure Functions isolated worker listens on 80** - see the Function App variant above.
- **Non-root:** Chiseled images run as non-root by default.
- **Health probes:** Configure orchestrator liveness against `/healthz` and readiness against `/readyz`; do not swap their roles or use an all-check endpoint for liveness.
- **No secrets in image:** Use Aspire/Container Apps environment injection for connection strings.
- Adjust COPY lines to match your actual solution project structure - add or remove projects as needed.

## Verification Checklist

- [ ] Restore stage copies all `.csproj` files needed by the target host
- [ ] `{SolutionName}.slnx`, `Directory.Build.props`, `Directory.Packages.props`, and `global.json` are copied before restore; `nuget.config` is copied only when generated
- [ ] Publish uses `--no-restore` (relies on cached restore layer)
- [ ] Runtime uses the smallest chiseled non-root variant the app needs (`-chiseled` unless globalization/tzdata/`libstdc++` forces `-chiseled-extra`)
- [ ] `EXPOSE` port matches Container Apps / Aspire configuration
- [ ] `ENTRYPOINT` matches the published assembly name
- [ ] No `HEALTHCHECK` in image - health probes configured at orchestrator level (Container Apps / K8s)
