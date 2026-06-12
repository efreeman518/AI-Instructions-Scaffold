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

1. Use OIDC (`id-token: write`) for Azure auth; do not store cloud credentials as static secrets.
2. Promotion path is explicit (`dev -> staging -> prod`) with environment protections.
3. Deploy artifacts are immutable by commit SHA tag.
4. Scheduler schema/dependency steps run before scheduler rollout.
5. PR CI excludes heavy suites (E2E/load/benchmarks unless explicitly gated).
6. **Private NuGet feed auth:** If the solution references packages from authenticated feeds (e.g., GitHub Packages), the workflow must authenticate before `dotnet restore`. Store a PAT as a repo secret (e.g., `NUGET_PAT`) and add an auth step. Without this, restore fails with `NU1301 / 401 Unauthorized`. See the NuGet auth step below.
7. **ACA managed identity can pull ACR but NOT GHCR.** When images live in a **private** GHCR package, the ACA managed identity cannot authenticate to `ghcr.io`. Set an explicit registry credential on each app with a PAT that has `read:packages`: `az containerapp registry set --name <app> --server ghcr.io --username <gh-user> --password <PAT>`. `GITHUB_TOKEN` does NOT work as the ACA pull password - it is job-scoped and expires when the job ends. **Public** GHCR packages need no pull secret. State this tradeoff when offering GHCR as the registry.
8. **Production DB migrations run as an explicit pipeline step, never on startup in Production.** Startup migration is gated `IsDevelopment()` and is a no-op in ACA. Apply schema with an EF migration bundle BEFORE the image swap so schema leads code (see the migration bundle step below).

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
    inputs:
      includeIntegration:
        type: boolean
        default: false
        description: "Run Test.Integration component tests (standalone Testcontainers SQL/Azurite; requires Docker)"
      includeAspireMesh:
        type: boolean
        default: false
        description: "Run Test.Aspire distributed-app mesh tests (full AppHost graph; requires Docker)"

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

      # Target specific test projects to avoid "No test matches" noise from unrelated projects
      - run: dotnet test src/Test/Test.Unit/Test.Unit.csproj --no-build --configuration Release
      - run: dotnet test src/Test/Test.Endpoints/Test.Endpoints.csproj --no-build --configuration Release
      - run: dotnet test src/Test/Test.Architecture/Test.Architecture.csproj --no-build --configuration Release
      - if: ${{ github.event_name == 'workflow_dispatch' && inputs.includeIntegration == true }}
        run: dotnet test src/Test/Test.Integration/Test.Integration.csproj --no-build --configuration Release
      - if: ${{ github.event_name == 'workflow_dispatch' && inputs.includeAspireMesh == true }}
        run: dotnet test src/Test/Test.Aspire/Test.Aspire.csproj --no-build --configuration Release
      - if: ${{ github.event_name == 'workflow_dispatch' && inputs.includeE2E == true }}
        run: dotnet test src/Test/Test.E2E/Test.E2E.csproj --no-build --configuration Release
      # Test.PlaywrightUI requires a hosted stack - see "Hosted-stack orchestration" section below.
```

### Runner Disk for Container-Backed Test Tiers

The `Integration` and `Aspire` tiers pull the full emulator image set: SQL Server (**two** tags once the Service Bus emulator's bundled SQL sidecar is counted - see [aspire.md](aspire.md) -> *Emulator Image Pinning*), plus Azurite, the Service Bus emulator, and Redis. A GitHub-hosted `ubuntu-latest` runner has ~14 GB free and can overflow mid-pull. **The failure is misleading:** Docker reports `no space left on device` deep in the pull log, but the test surfaces it as an AppHost resource-wait `System.TimeoutException` (the SQL container never reaches healthy). Check the pull log for the disk error before chasing the timeout.

Reclaim space before the container-backed steps, gated to the same dispatch inputs so normal PR runs (unit/endpoint/arch only) skip it:

```yaml
- name: Free disk space
  if: ${{ github.event_name == 'workflow_dispatch' && (inputs.includeIntegration || inputs.includeAspireMesh) }}
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

    | Category | PR Default | Optional / Manual |
    |---|---|---|
    | `Unit` | required | - |
    | `Endpoint` | required (WebApplicationFactory contract coverage) | - |
    | `Architecture` | required | - |
    | `Integration` | - | service-level vs real external services (workflow dispatch; Testcontainers required) |
    | `E2E` | - | multi-endpoint workflow chains (workflow dispatch) |
    | `PlaywrightUI` | - | browser UI; requires hosted stack (release/nightly) |
    | `Load`, `Benchmark`, `Mutation` | - | release/on-demand only |

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

If `Test.PlaywrightUI` is a Node Playwright suite for React/Vite, replace the browser install/run steps with `npm ci`, `npx playwright install --with-deps`, and `node node_modules/@playwright/test/cli.js test --project react`, while keeping the same hosted-stack startup/teardown contract.

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

1. Build and push images (ACR or GHCR variant).
2. **Apply EF migration bundle** (below) - BEFORE the image swap.
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
  needs: [build-and-push, migrate]   # migrate runs before image swap
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

## Production DB Migration (EF Bundle)

Run BEFORE the image swap so schema leads code. Build a self-contained bundle and apply it with Entra auth.

```yaml
migrate:
  needs: [build-and-push]
  runs-on: ubuntu-latest
  environment: ${{ inputs.environment }}
  steps:
    - uses: actions/checkout@v6
    - uses: actions/setup-dotnet@v4
      with:
        global-json-file: src/global.json
    - run: dotnet tool install --global dotnet-ef
    - name: Build migration bundle
      run: |
        dotnet ef migrations bundle --self-contained -r linux-x64 \
          --context {App}DbContextTrxn \
          --project src/Infrastructure/{Project}.Infrastructure.Data \
          --startup-project src/Infrastructure/{Project}.Infrastructure.Data \
          -o efbundle
    - uses: azure/login@v3
      with:
        client-id: ${{ secrets.AZURE_CLIENT_ID }}
        tenant-id: ${{ secrets.AZURE_TENANT_ID }}
        subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
    - name: Apply bundle (temporary firewall open for the runner)
      run: |
        IP=$(curl -s https://api.ipify.org)
        az sql server firewall-rule create -g "${{ vars.AZURE_RESOURCE_GROUP }}" \
          -s "${{ vars.AZURE_SQL_SERVER }}" -n "gha-runner" \
          --start-ip-address "$IP" --end-ip-address "$IP"
        trap 'az sql server firewall-rule delete -g "${{ vars.AZURE_RESOURCE_GROUP }}" \
          -s "${{ vars.AZURE_SQL_SERVER }}" -n "gha-runner" || true' EXIT
        ./efbundle --connection "Server=tcp:${{ vars.AZURE_SQL_SERVER }}.database.windows.net;Database={Project}db;Authentication=Active Directory Default;Encrypt=True;"
```

Migration gotchas (these cost real time):

- **`--startup-project` must reference `Microsoft.EntityFrameworkCore.Design`.** In this scaffold only the Data project references Design and ships a `DesignTimeDbContextFactory`; the API host does not. So use the **Data project as BOTH `--project` and `--startup-project`**. Pointing `--startup-project` at the API fails with "doesn't reference Microsoft.EntityFrameworkCore.Design". (See [data-layer-wiring.md](../patterns/data-layer-wiring.md).)
- **Dual contexts:** if Trxn (read/write) and Query (read-only) share one schema, only the write context has migrations. Bundle the write context only.
- **Entra auth:** `Authentication=Active Directory Default` in the connection string. The OIDC principal already has `db_owner` from provisioning (Aspire `AddAzureSqlServer` grants it), so no manual user creation is needed.
- **Firewall:** Azure SQL blocks GitHub runners. Open a temporary `az sql server firewall-rule` for the runner IP and remove it in a `trap`/`always()`. Alternative when SQL is private-endpoint-only: run the bundle as a manual-trigger ACA Job inside the VNet instead of from the runner.

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
| `AZURE_SQL_SERVER` (for migration bundle) | yes | yes |
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
7. Never run E2E/load/benchmark in default PR path.
8. Keep token placeholders aligned with [placeholder-tokens.md](../ai/placeholder-tokens.md).

---

## Verification

- [ ] `ci.yml` runs restore/build and required PR test categories
- [ ] `cd.yml` defaults to `workflow_dispatch` only (push-to-main is opt-in, added after infra exists)
- [ ] `cd.yml` logs in with OIDC and pushes SHA-tagged images (ACR or GHCR per scaffold choice)
- [ ] GHCR path: private package has `az containerapp registry set` pull cred per app
- [ ] EF migration bundle runs BEFORE image swap; uses Data project as `--project` and `--startup-project`
- [ ] deployment step updates correct environment resources by SHA tag
- [ ] scheduler deployment order includes prerequisite schema step
- [ ] `infra.yml`/`provision.yml` validates and deploys infra when enabled
- [ ] repo secrets/variables/environments match the registry path and are protected
