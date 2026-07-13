# CI/CD - GitHub Actions

See dockerfile-template.md for container patterns.

## Prerequisites

- [solution-structure.md](solution-structure.md)
- [iac.md](iac.md)
- [testing.md](testing.md)

## Purpose

Use GitHub Actions for:

1. CI on pull requests (restore/build/test).
2. CD on protected branches (build image, push, deploy by environment).
3. Optional IaC deployment (`infra.yml`) when Bicep is enabled.

## Non-Negotiables

1. Use OIDC (`id-token: write`) for Azure auth; do not store cloud credentials as static secrets. **Why:** OIDC issues short-lived tokens bound to the trusted repository/environment subject; static secrets persist until rotation or revocation and widen the blast radius when leaked. Therefore CI obtains scoped tokens per run.
2. Promotion path is explicit (`dev -> staging -> prod`) with environment protections.
3. Deploy artifacts are immutable by commit SHA tag.
4. Scheduler schema/dependency steps run before scheduler rollout.
5. PR CI runs only the fast tiers (`Unit`/`UI`/`Presentation`/`Endpoint`/`Architecture`, no Docker). Every heavy or special-runtime tier (`Integration`/`Aspire`/`E2E`/`PlaywrightUI`/`MobileUI`/Foundry Local/`Load`/`Benchmark`/`Mutation`) is a default-off `workflow_dispatch` toggle, never run automatically.
6. **Private NuGet feed auth:** If the solution references packages from authenticated feeds (e.g., GitHub Packages), the workflow must authenticate before `dotnet restore`. Store a PAT as a repo secret (e.g., `NUGET_PAT`) and add an auth step. Without this, restore fails with `NU1301 / 401 Unauthorized`. See the NuGet auth step below.
7. **ACA managed identity can pull ACR but NOT GHCR.** When images live in a **private** GHCR package, the ACA managed identity cannot authenticate to `ghcr.io`. Set an explicit registry credential on each app with a PAT that has `read:packages`: `az containerapp registry set --name <app> --server ghcr.io --username <gh-user> --password <PAT>`. `GITHUB_TOKEN` does NOT work as the ACA pull password - it is job-scoped and expires when the job ends. **Public** GHCR packages need no pull secret. State this tradeoff when offering GHCR as the registry.
8. **DB migrations run as an explicit pipeline step, never in runtime hosts.** The `{App}.DatabaseMigrator` image runs as a one-shot Container Apps Job BEFORE the image swap so schema leads code; every runtime deploy job gates on its success (see the migrator job step below). Canonical migration rules: [data-persistence-advanced.md](../support/data-persistence-advanced.md) section Migration Ownership: Dedicated Migrator Host.

### Registry choice is a scaffold input

ACR vs GHCR is a scaffold decision, not a default. Each path has a different auth model, secret set, and deploy command:

| | ACR | GHCR |
|---|---|---|
| Image push auth | `az acr login` (OIDC) | `docker/login-action` with `GITHUB_TOKEN` |
| ACA pull auth | managed identity (no secret) | `az containerapp registry set` + `read:packages` PAT (private only) |
| Required vars | `ACR_NAME`, `ACR_LOGIN_SERVER` | `GHCR_USER` (+ `GHCR_PULL_TOKEN` secret if private) |

---

## Action Versions

Action majors drift. **Verify current majors at scaffold time** (check each action's repo) rather than copying pins. As of May 2026 the verified majors are:

- `actions/checkout@v6` (was `@v4` in older templates)
- `azure/login@v3` (was `@v2`)
- `actions/setup-dotnet@v4` (a `v5` exists - verify before bumping), `actions/upload-artifact@v4`
- GHCR/Docker path: `docker/setup-buildx-action@v4`, `docker/login-action@v4`, `docker/metadata-action@v6`, `docker/build-push-action@v7`
- azd path: `Azure/setup-azd@v2`

---

## Recommended Workflow Layout

```
.github/
|-- workflows/
|   |-- ci.yml
|   |-- cd.yml
|   `-- infra.yml        # optional
`-- actions/
    `-- dotnet-build/    # optional composite action
```

---

## `ci.yml` (PR Validation)

**Trigger policy: fast tiers auto, everything heavy is a manual toggle.** The fast tiers
(`Unit`, `UI`, `Presentation`, `Endpoint`, `Architecture`) take no Docker and run automatically on every PR. Every
heavy or special-runtime tier - `Integration`, `Aspire`, `E2E` (Docker), `PlaywrightUI`
(hosted stack), `MobileUI` (emulator + Appium), Foundry Local live AI (native runtime),
`Load`, `Benchmark`, `Mutation` - is a default-off `workflow_dispatch` boolean a maintainer
opts into. Declare a toggle (and emit its step/job) **only for tiers this scaffold actually
generated** - the capability-gated table in [testing.md](testing.md) decides which projects
exist; do not emit dead toggles for absent projects.

Run on PRs to `main`/`develop`:

- checkout
- setup .NET from `src/global.json`
- `dotnet restore`
- `dotnet build --no-restore`
- targeted test runs by category (Endpoint path by default, broader Integration path optionally gated)
- publish TRX and coverage artifacts

Minimal shape:

```yaml
name: CI

on:
  pull_request:
    branches: [main, develop]
    paths-ignore: ['**.md', 'infra/**']
  workflow_dispatch:
    # Declare a toggle ONLY for a tier this scaffold generated (see testing.md capability table).
    inputs:
      includeIntegration:
        type: boolean
        default: false
        description: "Run Test.Integration component tests (standalone Testcontainers SQL/Azurite; requires Docker)"
      includeAspireMesh:
        type: boolean
        default: false
        description: "Run Test.Aspire distributed-app mesh tests (full AppHost graph; requires Docker)"
      includeE2E:
        type: boolean
        default: false
        description: "Run Test.E2E workflow tests (WebApplicationFactory + Testcontainers SQL; requires Docker)"
      includePlaywright:
        type: boolean
        default: false
        description: "Run Test.PlaywrightUI browser tests against a hosted stack (separate job; requires Docker + browser install)"
      includeMobile:
        type: boolean
        default: false
        description: "Run Test.Mobile (MobileUI) through run-mobile-tests.ps1 (separate job; requires Android SDK + emulator + Appium + UiAutomator2)"
      includeFoundryLocal:
        type: boolean
        default: false
        description: "Run Test.FoundryLocal live AI smoke (separate job; RID-bound, requires the native Foundry Local runtime)"
      includeLoad:
        type: boolean
        default: false
        description: "Run Test.Load (NBomber) throughput/latency baselines"
      includeBenchmarks:
        type: boolean
        default: false
        description: "Run Test.Benchmarks (BenchmarkDotNet via dotnet run, not dotnet test)"
      includeMutation:
        type: boolean
        default: false
        description: "Run Test.Mutation (Stryker via dotnet stryker, not dotnet test)"

jobs:
  build-and-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-dotnet@v4
        with:
          global-json-file: src/global.json

      # Install extra workloads if solution includes WASM/Uno projects
      # - run: dotnet workload install wasm-tools

      # Private NuGet feed auth (if nuget.config references authenticated feeds)
      - name: Authenticate private NuGet feed
        env:
          NUGET_PAT: ${{ secrets.NUGET_PAT }}
        if: env.NUGET_PAT != ''
        run: >
          dotnet nuget update source "{FeedName}"
          --username "ci" --password "$NUGET_PAT"
          --store-password-in-clear-text
          --configfile src/nuget.config

      - run: dotnet restore src/{SolutionName}.slnx

      # Vulnerability audit per support/execution-gates.md section Vulnerability Audit
      # High severity must be fixed or recorded in .scaffold/INSTRUCTION-GAPS.md
      - name: Vulnerability audit
        run: |
          dotnet list src/{SolutionName}.slnx package --vulnerable --include-transitive 2>&1 | tee vuln.log
          if grep -E '\bHigh\b' vuln.log; then
            echo "::warning::High-severity vulnerable packages detected. Verify each is documented in .scaffold/INSTRUCTION-GAPS.md."
          fi

      - run: dotnet build src/{SolutionName}.slnx --no-restore --configuration Release

      # Fast tiers: always run, no Docker, no gate.
      # Target specific test projects to avoid "No test matches" noise from unrelated projects
      - run: dotnet test src/Test/Test.Unit/Test.Unit.csproj --no-build --configuration Release
      - run: dotnet test src/Test/Test.Endpoints/Test.Endpoints.csproj --no-build --configuration Release
      - run: dotnet test src/Test/Test.Architecture/Test.Architecture.csproj --no-build --configuration Release

      # Docker-backed tiers: manual dispatch only.
      - if: ${{ github.event_name == 'workflow_dispatch' && inputs.includeIntegration == true }}
        run: dotnet test src/Test/Test.Integration/Test.Integration.csproj --no-build --configuration Release
      - if: ${{ github.event_name == 'workflow_dispatch' && inputs.includeAspireMesh == true }}
        run: dotnet test src/Test/Test.Aspire/Test.Aspire.csproj --no-build --configuration Release
      - if: ${{ github.event_name == 'workflow_dispatch' && inputs.includeE2E == true }}
        run: dotnet test src/Test/Test.E2E/Test.E2E.csproj --no-build --configuration Release

      # Perf / quality tiers: manual dispatch only. NOTE the runner per tier.
      - if: ${{ github.event_name == 'workflow_dispatch' && inputs.includeLoad == true }}
        run: dotnet test src/Test/Test.Load/Test.Load.csproj --no-build --configuration Release --filter "TestCategory=Load"
      # Test.Benchmarks uses BenchmarkDotNet [Benchmark], not [TestMethod] - `dotnet test`
      # discovers nothing (silent no-op). Run the console host instead.
      - if: ${{ github.event_name == 'workflow_dispatch' && inputs.includeBenchmarks == true }}
        run: dotnet run --project src/Test/Test.Benchmarks/Test.Benchmarks.csproj --configuration Release
      # Test.Mutation runs via the Stryker local tool, not `dotnet test`.
      - if: ${{ github.event_name == 'workflow_dispatch' && inputs.includeMutation == true }}
        run: dotnet stryker --project src/Test/Test.Mutation/Test.Mutation.csproj
      # Test.PlaywrightUI / Test.Mobile / Test.FoundryLocal each need runner setup the main
      # job should not carry - see the separate jobs below.
```

### Runner Disk for Container-Backed Test Tiers

The `Integration`, `Aspire`, and `E2E` tiers pull the emulator/container image set: SQL Server (**two** tags once the Service Bus emulator's bundled SQL sidecar is counted - see [aspire.md](aspire.md) -> *Emulator Image Pinning*; `Test.E2E` adds its own Testcontainers SQL), plus Azurite, the Service Bus emulator, and Redis. A GitHub-hosted `ubuntu-latest` runner has ~14 GB free and can overflow mid-pull. **The failure is misleading:** Docker reports `no space left on device` deep in the pull log, but the test surfaces it as an AppHost resource-wait `System.TimeoutException` (the SQL container never reaches healthy). Check the pull log for the disk error before chasing the timeout.

Reclaim space before the container-backed steps, gated to the same dispatch inputs so normal PR runs (unit/endpoint/arch only) skip it:

```yaml
- name: Free disk space
  if: ${{ github.event_name == 'workflow_dispatch' && (inputs.includeIntegration || inputs.includeAspireMesh || inputs.includeE2E) }}
  uses: jlumbroso/free-disk-space@main
  with:
    tool-cache: false   # keep the hosted .NET; build depends on it
    dotnet: false
    android: true       # ~9 GB
    haskell: true       # ~5 GB
    large-packages: true
    swap-storage: false
```

Aligning the Service Bus SQL sidecar tag with the `sql` resource (aspire.md, same section) also shrinks the pull - the two SQL containers then share layers instead of pulling two majors.

### Test Category Policy

Fast tiers run automatically on PRs; everything else is a default-off `workflow_dispatch`
toggle (only emitted for tiers this scaffold generated). The trigger column maps each
category to its `inputs.*` switch.

| Category | Trigger | Prerequisite / notes |
|---|---|---|
| `Unit` | Auto (PR) | none |
| `Endpoint` | Auto (PR) | none (WebApplicationFactory contract coverage) |
| `Architecture` | Auto (PR) | none |
| `Integration` | Manual (`includeIntegration`) | Docker (component vs one standalone Testcontainer) |
| `Aspire` | Manual (`includeAspireMesh`) | Docker (full AppHost mesh; disk reclaim) |
| `E2E` | Manual (`includeE2E`) | Docker (multi-endpoint chains, Testcontainers SQL) |
| `PlaywrightUI` | Manual (`includePlaywright`) | hosted stack + browser install (own job) |
| `MobileUI` | Manual (`includeMobile`) | `src/Test/Test.Mobile/run-mobile-tests.ps1`; Android SDK + emulator + Appium + UiAutomator2; fail-fast prerequisites (own job) |
| Foundry Local (`LiveAI`) | Manual (`includeFoundryLocal`) | native Foundry Local runtime, RID-bound (own job) |
| `Load` | Manual (`includeLoad`) | heavy; NBomber via `dotnet test --filter TestCategory=Load` |
| `Benchmark` | Manual (`includeBenchmarks`) | heavy; BenchmarkDotNet via `dotnet run` (NOT `dotnet test`) |
| `Mutation` | Manual (`includeMutation`) | heavy; Stryker via `dotnet stryker` (NOT `dotnet test`) |

### Hosted-Stack Orchestration (`Test.PlaywrightUI`)

Playwright tests cannot use `WebApplicationFactory` - they drive a real browser and need real Kestrel + UI host. The CI job must launch the stack, wait for health, run the tests, then tear down. For React/Vite, pass the actual UI resource URL from the hosted stack into the test project (for example `{APP}_REACT_BASE_URL`); do not assume the local Vite default port.

```yaml
playwright:
  runs-on: ubuntu-latest
  needs: [build]
  if: github.event_name == 'workflow_dispatch' && inputs.includePlaywright == true
  steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-dotnet@v4
    - run: dotnet build src/{SolutionName}.slnx --configuration Release
    - name: Start Aspire AppHost
      run: |
        dotnet run --project src/Host/Aspire/AppHost --configuration Release &
        echo "APPHOST_PID=$!" >> $GITHUB_ENV
    - name: Wait for stack health
      run: |
        for i in {1..30}; do
          if curl -sf http://localhost:5100/health; then exit 0; fi
          sleep 2
        done
        exit 1
    - name: Install Playwright browsers
      run: pwsh src/Test/Test.PlaywrightUI/bin/Release/$(TargetFramework)/playwright.ps1 install --with-deps
    - name: Run Playwright tests
      env:
        PLAYWRIGHT_BASE_URL: http://localhost:5100
      run: dotnet test src/Test/Test.PlaywrightUI/Test.PlaywrightUI.csproj --no-build --configuration Release
    - name: Stop AppHost
      if: always()
      run: kill $APPHOST_PID || true
```

For PR-time runs, gate `Test.PlaywrightUI` to nightly to keep PR loops fast.

If `Test.PlaywrightUI` is a Node Playwright suite for React/Vite, replace the browser install/run steps with `npm ci`, `npx playwright install --with-deps`, and one `node node_modules/@playwright/test/cli.js test --project <name>` process per project. Keep the same hosted-stack startup/teardown contract, capture stdout/stderr, and bound each project with `{APP}_PLAYWRIGHT_PROJECT_TIMEOUT_SECONDS`.

### Special-Runtime Jobs (`Test.Mobile`, `Test.FoundryLocal`)

These two tiers need a runtime the main job must not carry, so each is its own
`workflow_dispatch`-gated job, emitted only when the tier was generated.

**`Test.Mobile` (`MobileUI`, Appium).** Needs Android SDK + running emulator + Appium + UiAutomator2. Default `dotnet test` with no enable flag self-marks `Inconclusive` without touching mobile dependencies. Explicit CI mobile lane must call `src/Test/Test.Mobile/run-mobile-tests.ps1`; that runner sets `{APP}_MOBILE_TESTS_ENABLED=true`, produces TRX, and fails fast red when APK, emulator/device, Appium, or UiAutomator2 is missing/broken. Use generated runner logic, or `reactivecircus/android-emulator-runner` as the emulator provider and still call the runner inside it.
```yaml
mobile:
  runs-on: ubuntu-latest        # the emulator action provides KVM acceleration
  if: github.event_name == 'workflow_dispatch' && inputs.includeMobile == true
  steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-dotnet@v4
      with: { global-json-file: src/global.json }
 - name: Run Mobile UI tests on emulator
   uses: reactivecircus/android-emulator-runner@v2
   with:
     api-level: 34
     script: pwsh -NoProfile -File src/Test/Test.Mobile/run-mobile-tests.ps1
```

**`Test.FoundryLocal` (live AI smoke).** RID-bound native tier - the runner must install and
bootstrap the Foundry Local runtime before the test loads the native
`Microsoft.AI.Foundry.Local` SDK. The live lane is `Inconclusive` (never green) when no real
provider is active because the runtime is missing/undiscoverable; installed/discovered runtime with no-op fallback, timeout, or wrong `/api/v1/ai/status` is failure. The lane decides the provider via `GET /api/v1/ai/status`, not a CLI probe.
Owner doctrine: [ai-integration.md](ai-integration.md) -> *Provider Test Tiers* / *Deciding the
Live Lane Without Probing the CLI*. Do not restate it here.

```yaml
foundry-local:
  runs-on: ubuntu-latest
  if: github.event_name == 'workflow_dispatch' && inputs.includeFoundryLocal == true
  steps:
    - uses: actions/checkout@v4
    - uses: actions/setup-dotnet@v4
      with: { global-json-file: src/global.json }
    - name: Install + bootstrap Foundry Local runtime
      run: |
        # Install the Foundry Local runtime per its docs, then warm the model.
        # foundry model run <model>   # bootstrap before the RID-bound test loads the native SDK
    - name: Run live AI smoke (RID-bound)
      run: dotnet test src/Test/Test.FoundryLocal/Test.FoundryLocal.csproj --configuration Release --filter "TestCategory=LiveAI"
```

---

## `cd.yml` (Build, Push, Deploy)

### Trigger default: `workflow_dispatch` only

`cd.yml` (and `provision.yml`, below) default to **`workflow_dispatch` only** until infra exists and the `AZURE_*` / registry secrets+vars are set. Auto-deploy on push to `main` fails every merge before infra exists, so it is opt-in: add the `push` block once the environment is ready.

```yaml
on:
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options: [dev, staging, prod]
  # Opt-in after infra + secrets exist - uncomment to deploy on merge:
  # push:
  #   branches: [main]
```

### Step order (schema leads code)

1. Build and push images (ACR or GHCR variant) - the migrator image ships with the other deployables.
2. **Run the migrator job** (below) - BEFORE the image swap.
3. Deploy: update each ACA app to the new SHA tag.

Keep scheduler replicas pinned when no coordination layer exists.

### Build + Push - ACR variant

- login via `azure/login@v3` + OIDC, then `az acr login`.
- build each deployable image, push `:${{ github.sha }}` (+ optional `:latest`).
- ACA pull needs no secret (managed identity pulls ACR).

```yaml
permissions:
  id-token: write
  contents: read

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        project:
          - { name: api, dockerfile: src/Host/{Host}.Api/Dockerfile }
          - { name: gateway, dockerfile: src/Host/{Gateway}.Gateway/Dockerfile }
          - { name: scheduler, dockerfile: src/Host/{Host}.Scheduler/Dockerfile }
    steps:
      - uses: actions/checkout@v6
      - uses: azure/login@v3
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - run: az acr login --name ${{ vars.ACR_NAME }}
      - run: docker build -t ${{ vars.ACR_LOGIN_SERVER }}/${{ matrix.project.name }}:${{ github.sha }} -f ${{ matrix.project.dockerfile }} .
      - run: docker push ${{ vars.ACR_LOGIN_SERVER }}/${{ matrix.project.name }}:${{ github.sha }}
```

> **Build context.** The examples use `.` (repo root). Confirm per app: DemoApp1 Dockerfiles build from the repo ROOT, not `src/`. Older templates used `src/` as context - that is wrong for repo-root Dockerfiles. Match the context to where the Dockerfile's `COPY` paths are rooted (see [dockerfile-template.md](../templates/dockerfile-template.md)).

### Build + Push - GHCR variant

- `permissions: { contents: read, packages: write, id-token: write }`.
- `docker/login-action` to `ghcr.io` with `GITHUB_TOKEN`.
- `docker/metadata-action` `images: ghcr.io/${{ github.repository_owner }}/<svc>` (it lowercases the image name automatically); tags `type=sha,format=long,prefix=` + `latest`.
- `docker/build-push-action` with `context: .`, `cache-from/to: type=gha,scope=<svc>`, `provenance: false` (single-platform manifest ACA pulls cleanly).

```yaml
permissions:
  contents: read
  packages: write
  id-token: write

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        project:
          - { name: api, dockerfile: src/Host/{Host}.Api/Dockerfile }
          - { name: gateway, dockerfile: src/Host/{Gateway}.Gateway/Dockerfile }
          - { name: scheduler, dockerfile: src/Host/{Host}.Scheduler/Dockerfile }
    steps:
      - uses: actions/checkout@v6
      - uses: docker/setup-buildx-action@v4
      - uses: docker/login-action@v4
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - id: meta
        uses: docker/metadata-action@v6
        with:
          images: ghcr.io/${{ github.repository_owner }}/${{ matrix.project.name }}
          tags: |
            type=sha,format=long,prefix=
            type=raw,value=latest
      - uses: docker/build-push-action@v7
        with:
          context: .
          file: ${{ matrix.project.dockerfile }}
          push: true
          tags: ${{ steps.meta.outputs.tags }}
          cache-from: type=gha,scope=${{ matrix.project.name }}
          cache-to: type=gha,scope=${{ matrix.project.name }},mode=max
          provenance: false
```

### Deploy to Azure Container Apps

Lowercase the owner in bash - do not rely on the raw `github.repository_owner` casing.

```yaml
deploy:
  needs: [build-and-push, run-migrations]   # migrator job succeeds before image swap
  runs-on: ubuntu-latest
  environment: ${{ inputs.environment }}
  steps:
    - uses: azure/login@v3
      with:
        client-id: ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id: ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
    - name: Update container apps
      run: |
        OWNER=$(echo "${{ github.repository_owner }}" | tr '[:upper:]' '[:lower:]')
        for svc in api gateway scheduler; do
          az containerapp update \
            --name "$svc" \
            --resource-group "${{ vars.AZURE_RESOURCE_GROUP }}" \
            --image "ghcr.io/$OWNER/$svc:${{ github.sha }}"
        done
```

For ACR, swap the image to `${{ vars.ACR_LOGIN_SERVER }}/$svc:${{ github.sha }}` and drop the owner-lowercasing step.

---

## Production DB Migration (Migrator Job)

Run BEFORE the image swap so schema leads code. The `{App}.DatabaseMigrator` image (built and pushed alongside the other deployables) runs as a one-shot Container Apps Job inside the environment; the pipeline starts it and polls the execution to terminal status. Canonical migration rules (target ordering, history tables, timeouts, identity split): [data-persistence-advanced.md](../support/data-persistence-advanced.md) section Migration Ownership: Dedicated Migrator Host.

```yaml
run-migrations:
  needs: [build-and-push, deploy-infra]
  runs-on: ubuntu-latest
  environment: ${{ inputs.environment }}
  timeout-minutes: 60   # sized for data movement, not just DDL
  steps:
    - uses: azure/login@v3
      with:
        client-id: ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id: ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
    - name: Start migrator job and poll to terminal status
      run: |
        JOB="${{ needs.deploy-infra.outputs.migration-job-name }}"
        RG="${{ vars.AZURE_RESOURCE_GROUP }}"
        EXECUTION=$(az containerapp job start --name "$JOB" -g "$RG" --query name -o tsv)
        echo "Started migration execution: $EXECUTION"
        while :; do
          STATUS=$(az containerapp job execution show --name "$JOB" -g "$RG" \
            --job-execution-name "$EXECUTION" --query properties.status -o tsv)
          case "$STATUS" in
            Succeeded) exit 0 ;;
            Failed|Stopped) echo "Migration $STATUS"; exit 1 ;;
            *) sleep 15 ;;
          esac
        done
```

Job configuration lives in the Bicep container-app-job module - infra deploys it with the migrator image tag and exposes the job name as an output. Job knobs (trigger, parallelism, completion count, retry, timeout) are canonical in [data-persistence-advanced.md](../support/data-persistence-advanced.md) section Migration Ownership: Dedicated Migrator Host.

Migration gotchas (these cost real time):

- **Gate on the concrete execution.** `az containerapp job start` returns immediately; poll `job execution show` until `Succeeded` and fail the pipeline on `Failed`/`Stopped`. Every runtime deploy job takes `needs: [run-migrations]`.
- **Dual contexts:** if Trxn (read/write) and Query (read-only) share one schema, only the write context is a migration target.
- **Identity:** the job runs inside the Container Apps environment with the migrator identity (schema DDL + migration history); runtime identities keep least-privilege DML, no DDL. No runner firewall rules needed - the migrator is not the GitHub runner, so this also works with private-endpoint-only SQL.
- **Entra auth does not create SQL users.** Entra-auth connection strings never create contained database users or grants. Aspire `AddAzureSqlServer` provisioning grants the managed identity and deploying principal; anything beyond that needs an explicit SQL data-plane step or a clear comment in infra that identities are not wired.

---

## `infra.yml` (Optional Bicep)

Use manual dispatch per environment:

1. OIDC login
2. `az bicep build --file infra/main.bicep`
3. deploy with `azure/arm-deploy@v2`

Run infra separately from app rollout unless the team explicitly couples both.

---

## Dockerfile Contract

Each deployable host has a Dockerfile in its project folder. **Build context must match where the Dockerfile's `COPY` paths are rooted** - confirm per app. Repo-root Dockerfiles (e.g. DemoApp1) build from `.`; only use `src/` when the `COPY` lines are relative to `src/`. Do not assume `src/`.

Required pattern:

1. Multi-stage (`restore -> publish -> runtime`).
2. Copy solution/package files before source for restore-layer caching.
3. Runtime image is minimal and only contains published outputs.

---

## Repository Configuration

The required secrets/vars differ by registry path. Pick the column that matches the scaffold's registry choice.

### Required Secrets

| Secret | ACR path | GHCR + azd path |
|---|---|---|
| `AZURE_CLIENT_ID` | yes | yes |
| `AZURE_TENANT_ID` | yes | yes |
| `AZURE_SUBSCRIPTION_ID` | yes | yes |
| `GHCR_PULL_TOKEN` (`read:packages` PAT) | - | yes, if GHCR package is private |
| `CI_SQL_PASSWORD` | if SQL service container used in CI | if SQL service container used in CI |

### Required Variables

| Variable | ACR path | GHCR + azd path |
|---|---|---|
| `ACR_LOGIN_SERVER`, `ACR_NAME` | yes | drop |
| `GHCR_USER` | - | yes |
| `AZURE_RESOURCE_GROUP` | yes | yes |
| `AZURE_SQL_SERVER` | yes | yes |
| `AZURE_ENV_NAME`, `AZURE_LOCATION` (azd) | - | yes |
| `PROJECT_NAME`, `INCLUDE_SCHEDULER` | yes | yes |

### Environments

Create `dev`, `staging`, `prod` with protection rules on `staging` and `prod`. The job's `environment:` name must match the OIDC federated-credential subject (`repo:<owner>/<repo>:environment:<env>`) - see [iac.md](iac.md) -> *azd from Aspire (infra-only path)* -> *One-time, account-bound steps*.

---

## Lite Mode

For `scaffoldMode: lite`:

- CI: unit tests only.
- CD: API image only.
- Infra workflow optional/manual.
- simplified Dockerfile/project matrix.

---

## Deployment Guardrails

1. OIDC only for Azure auth in workflows (image push to ACR/GHCR + Azure control-plane). Private GHCR pull still needs a `read:packages` PAT on each app - OIDC does not cover ACA-to-GHCR pulls.
2. Build context matches the Dockerfile's `COPY` roots (repo root or `src/`) - verify per app, do not assume `src/`.
3. Deploy by SHA tag; avoid mutable-only deploy references.
4. Schema prerequisites (such as scheduler tables) are applied before rolling dependent services.
5. Keep environment promotions explicit and approval-gated.
6. Validate Bicep before deploy.
7. Default PR path runs fast tiers only; all heavy/special tiers are `workflow_dispatch` toggles, default off.
8. Keep token placeholders aligned with [placeholder-tokens.md](../ai/placeholder-tokens.md).

---

## Verification

- [ ] `ci.yml` runs the fast tiers (`Unit`/`Endpoint`/`Architecture`) on PR with no Docker and no `if:` gate
- [ ] `ci.yml` declares a `workflow_dispatch` boolean (default false) for every manual tier it references, and emits one only for tiers this scaffold generated; every `inputs.*` referenced in an `if:` is declared
- [ ] heavy tiers carry the `workflow_dispatch && inputs.<x>` gate; Benchmarks use `dotnet run` and Mutation uses `dotnet stryker` (never `dotnet test`); disk reclaim covers Integration/Aspire/E2E
- [ ] `cd.yml` defaults to `workflow_dispatch` only (push-to-main is opt-in, added after infra exists)
- [ ] `cd.yml` logs in with OIDC and pushes SHA-tagged images (ACR or GHCR per scaffold choice)
- [ ] GHCR path: private package has `az containerapp registry set` pull cred per app
- [ ] Migrator Container Apps Job runs BEFORE image swap; pipeline polls the execution to terminal status; runtime deploys gate on it
- [ ] deployment step updates correct environment resources by SHA tag
- [ ] scheduler deployment order includes prerequisite schema step
- [ ] `infra.yml`/`provision.yml` validates and deploys infra when enabled
- [ ] repo secrets/variables/environments match the registry path and are protected
