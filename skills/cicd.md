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
9. Superseded CI may cancel. An environment deployment uses `cancel-in-progress: false`; never interrupt an in-flight migration or rollout.
10. A deployment consumes one previously validated commit, builds each artifact once, records immutable image digests/artifact IDs, and rolls back from the previous release manifest without rebuilding.
11. Tracked files contain no package credentials. Repository `nuget.config` may contain `%NUGET_AUTH_TOKEN%` only; secrets must not be echoed or included in diagnostic artifacts.
12. **CI green must imply the deploy will compile.** Every compile surface the deploy pipeline builds - platform heads excluded from the fast lane for workload cost, container-only hosts, the migrator image - either gets a pre-merge compile gate (`dotnet build`, no tests, workloads installed) or the workflow states the required manual build explicitly. A fast lane that tests less than deploy compiles converts merge-time errors into deploy-time outages.

### Registry choice is a scaffold input

ACR vs GHCR is a scaffold decision, not a default. Each path has a different auth model, secret set, and deploy command:

| | ACR | GHCR |
|---|---|---|
| Image push auth | `az acr login` (OIDC) | `docker/login-action` with `GITHUB_TOKEN` |
| ACA pull auth | managed identity (no secret) | `az containerapp registry set` + `read:packages` PAT (private only) |
| Required vars | `ACR_NAME`, `ACR_LOGIN_SERVER` | `GHCR_USER` (+ `GHCR_PULL_TOKEN` secret if private) |

---

## Action References

At generation time, query each action repository for its latest stable release, resolve that release tag to its commit, and write `owner/action@<resolved-commit-sha> # <stable-release-tag>` into the generated workflow. The instruction examples use `owner/action@<latest-stable-sha>` placeholders so source guidance never freezes a release or SHA. Add GitHub Actions Dependabot updates to generated repositories; review and merge its immutable-ref updates through normal CI.

A temporary action rollback is allowed only for a specific documented issue. Record the issue or failing behavior, selected temporary release, removal condition, and validating test beside the generated ref. Remove the exception as soon as that test passes on the latest stable release.

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
- setup .NET from `global.json`
- `dotnet restore`
- `dotnet build --no-restore`
- targeted test runs by category (Endpoint path by default, broader Integration path optionally gated)
- publish TRX and coverage artifacts

Base-filtered triggers do not gate stacked PRs: a PR whose base is another feature branch never triggers CI, and its empty check list reads as "nothing ran", not "not covered". Either retarget to `main` before relying on CI or state local verification in the PR body. Never `gh pr merge --squash --delete-branch` while another PR is stacked on that branch - deleting the base auto-closes the stacked PR, and GitHub refuses both `gh pr reopen` (base branch gone) and retargeting a closed PR; the only recovery is a replacement PR that strands the original review thread. After a squash merge, replay a stacked branch with `git rebase --onto main <old-base-sha>` (a plain rebase replays the merged commits), and check merged-ness by content (`git diff origin/<branch> <squash-sha>`), never by `git rev-list --count`, which stays nonzero after a squash merge.

Minimal shape:

```yaml
name: CI

on:
  pull_request:
    branches: [main, develop]
    types: [opened, synchronize, reopened, ready_for_review]
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

concurrency:
  group: ci-${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  build-and-test:
    if: github.event_name != 'pull_request' || github.event.pull_request.draft == false
    runs-on: ubuntu-latest
    env:
      NUGET_AUTH_TOKEN: ${{ secrets.NUGET_PAT }}
    steps:
      - uses: actions/checkout@<latest-stable-sha>
      - uses: actions/setup-dotnet@<latest-stable-sha>
        with:
          global-json-file: global.json

      # Install extra workloads if solution includes WASM/Uno projects
      # - run: dotnet workload install wasm-tools

      - run: dotnet restore {SolutionName}.slnx

      # Vulnerability audit per support/execution-gates.md section Vulnerability Audit
      # High severity must be fixed or recorded in .scaffold/INSTRUCTION-GAPS.md
      - name: Vulnerability audit
        run: |
          dotnet list {SolutionName}.slnx package --vulnerable --include-transitive 2>&1 | tee vuln.log
          if grep -E '\bHigh\b' vuln.log; then
            echo "::warning::High-severity vulnerable packages detected. Verify each is documented in .scaffold/INSTRUCTION-GAPS.md."
          fi

      - run: dotnet build {SolutionName}.slnx --no-restore --configuration Release

      # Fast tiers: always run, no Docker, no gate.
      # Target specific test projects to avoid "No test matches" noise from unrelated projects
      - run: dotnet test tests/Test.Unit/Test.Unit.csproj --no-build --configuration Release
      - run: dotnet test tests/Test.Endpoints/Test.Endpoints.csproj --no-build --configuration Release
      - run: dotnet test tests/Test.Architecture/Test.Architecture.csproj --no-build --configuration Release

      # Docker-backed tiers: manual dispatch only.
      - if: ${{ github.event_name == 'workflow_dispatch' && inputs.includeIntegration == true }}
        run: dotnet test tests/Test.Integration/Test.Integration.csproj --no-build --configuration Release
      - if: ${{ github.event_name == 'workflow_dispatch' && inputs.includeAspireMesh == true }}
        run: dotnet test tests/Test.Aspire/Test.Aspire.csproj --no-build --configuration Release -m:1
      - if: ${{ github.event_name == 'workflow_dispatch' && inputs.includeE2E == true }}
        run: dotnet test tests/Test.E2E/Test.E2E.csproj --no-build --configuration Release

      # Perf / quality tiers: manual dispatch only. NOTE the runner per tier.
      - if: ${{ github.event_name == 'workflow_dispatch' && inputs.includeLoad == true }}
        run: dotnet test tests/Test.Load/Test.Load.csproj --no-build --configuration Release --filter "TestCategory=Load"
      # Test.Benchmarks uses BenchmarkDotNet [Benchmark], not [TestMethod] - `dotnet test`
      # discovers nothing (silent no-op). Run the console host instead.
      - if: ${{ github.event_name == 'workflow_dispatch' && inputs.includeBenchmarks == true }}
        run: dotnet run --project tests/Test.Benchmarks/Test.Benchmarks.csproj --configuration Release
      # Test.Mutation runs via the Stryker local tool, not `dotnet test`.
      - if: ${{ github.event_name == 'workflow_dispatch' && inputs.includeMutation == true }}
        run: dotnet stryker --project tests/Test.Mutation/Test.Mutation.csproj
      # Test.PlaywrightUI / Test.Mobile / Test.FoundryLocal each need runner setup the main
      # job should not carry - see the separate jobs below.
```

The committed `nuget.config` uses an environment placeholder such as `<add key="ClearTextPassword" value="%NUGET_AUTH_TOKEN%" />`; the value remains a placeholder in source. Never run a command that writes the resolved secret back into the tracked file. Mask credentials, keep them out of command lines, and exclude `nuget.config`, environment dumps, and credential-provider caches from uploaded diagnostics.

Upload failure diagnostics with `if: failure() || cancelled()` and `if-no-files-found: error`. Upload successful benchmark, mutation, coverage, or release evidence on success when that evidence is the output of the lane. The producer and uploader must share the exact artifact path; fail fast when an expected file is missing.

For every configured EF provider, CI runs the non-destructive `has-pending-model-changes` or provider-parity verifier. Baseline regeneration is not a normal CI repair action and must not be implemented through a workflow that edits/deletes itself or pushes a cleanup branch.

The self-modifying prohibition is general, not EF-specific: **routine maintenance is never a workflow that modifies workflows.** Action bumps, cleanups, and one-time repairs land as ordinary PR edits to the workflow files. Two consumer repos have independently burned double-digit commit counts on one-shot updater/cleanup workflows that never triggered reliably (eight trigger variations in one case) and then had to be removed by hand.

### Runner Disk for Container-Backed Test Tiers

The `Integration`, `Aspire`, and `E2E` tiers pull the emulator/container image set: SQL Server (**two** tags once the Service Bus emulator's bundled SQL sidecar is counted - see [aspire.md](aspire.md) -> *Emulator Image Pinning*; `Test.E2E` adds its own Testcontainers SQL), plus Azurite, the Service Bus emulator, and Redis. A GitHub-hosted `ubuntu-latest` runner has ~14 GB free and can overflow mid-pull. **The failure is misleading:** Docker reports `no space left on device` deep in the pull log, but the test surfaces it as an AppHost resource-wait `System.TimeoutException` (the SQL container never reaches healthy). Check the pull log for the disk error before chasing the timeout.

Reclaim space before the container-backed steps, gated to the same dispatch inputs so normal PR runs (unit/endpoint/arch only) skip it:

```yaml
- name: Free disk space
  if: ${{ github.event_name == 'workflow_dispatch' && (inputs.includeIntegration || inputs.includeAspireMesh || inputs.includeE2E) }}
  uses: jlumbroso/free-disk-space@<latest-stable-sha>
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

Treat Aspire, Playwright, and WasmUI projects as resource-heavy. Keep their workflow steps/jobs non-overlapping, and use `-m:1` for every solution-wide or heavy-project `dotnet test` command. The scheduled/manual acceptance lane must also run the unfiltered solution command `dotnet test {SolutionName}.slnx --no-build -m:1`; filtered fast tiers do not prove scaffold acceptance.

| Category | Trigger | Prerequisite / notes |
|---|---|---|
| `Unit` | Auto (PR) | none |
| `Endpoint` | Auto (PR) | none (WebApplicationFactory contract coverage) |
| `Architecture` | Auto (PR) | none |
| `Integration` | Manual (`includeIntegration`) | Docker (component vs one standalone Testcontainer) |
| `Aspire` | Manual (`includeAspireMesh`) | Docker (full AppHost mesh; disk reclaim) |
| `E2E` | Manual (`includeE2E`) | Docker (multi-endpoint chains, Testcontainers SQL) |
| `PlaywrightUI` | Manual (`includePlaywright`) | hosted stack + browser install (own job) |
| `MobileUI` | Manual (`includeMobile`) | `tests/Test.Mobile/run-mobile-tests.ps1`; Android SDK + emulator + Appium + UiAutomator2; fail-fast prerequisites (own job) |
| Foundry Local (`LiveAI`) | Manual (`includeFoundryLocal`) | native Foundry Local runtime, RID-bound (own job) |
| `Load` | Manual (`includeLoad`) | heavy; NBomber via `dotnet test --filter TestCategory=Load` |
| `Benchmark` | Manual (`includeBenchmarks`) | heavy; BenchmarkDotNet via `dotnet run` (NOT `dotnet test`) |
| `Mutation` | Manual (`includeMutation`) | heavy; Stryker via `dotnet stryker` (NOT `dotnet test`) |

### Hosted-Stack Orchestration (`Test.PlaywrightUI`)

Playwright tests cannot use `WebApplicationFactory` - they drive a real browser and need real Kestrel + UI host. The generated `Test.PlaywrightUI` fixture self-hosts Aspire through the shared `AspireTestHostContext`, waits named resources, resolves dynamic endpoints, and owns bounded cleanup. CI provisions Node/browser/WASM prerequisites, then runs the test project; do not start a second AppHost in the workflow.

```yaml
playwright:
  runs-on: ubuntu-latest
  needs: [build]
  if: github.event_name == 'workflow_dispatch' && inputs.includePlaywright == true
  steps:
    - uses: actions/checkout@<latest-stable-sha>
    - uses: actions/setup-dotnet@<latest-stable-sha>
    - run: dotnet build {SolutionName}.slnx --configuration Release -m:1
    - name: Install Playwright browsers
      run: pwsh tests/Test.PlaywrightUI/bin/Release/$(TargetFramework)/playwright.ps1 install --with-deps
    - name: Run Playwright tests
      run: dotnet test tests/Test.PlaywrightUI/Test.PlaywrightUI.csproj --no-build --configuration Release -m:1
```

For PR-time runs, gate `Test.PlaywrightUI` to nightly to keep PR loops fast.

If `Test.PlaywrightUI` wraps Node Playwright for React/Vite, run `npm ci`, install browsers, then let the C# test adapter invoke one `node node_modules/@playwright/test/cli.js test --project <name>` process per project. Capture stdout/stderr and pass the shared remaining startup-deadline token; `{APP}_PLAYWRIGHT_PROJECT_TIMEOUT_SECONDS` is only a shorter subordinate cap.

### Special-Runtime Jobs (`Test.Mobile`, `Test.FoundryLocal`)

These two tiers need a runtime the main job must not carry, so each is its own
`workflow_dispatch`-gated job, emitted only when the tier was generated.

**`Test.Mobile` (`MobileUI`, Appium).** Needs Android SDK + running emulator + Appium + UiAutomator2. Default `dotnet test` with no enable flag self-marks `Inconclusive` without touching mobile dependencies. Explicit CI mobile lane must call `tests/Test.Mobile/run-mobile-tests.ps1`; that runner sets `{APP}_MOBILE_TESTS_ENABLED=true`, produces TRX, and fails fast red when APK, emulator/device, Appium, or UiAutomator2 is missing/broken. Use generated runner logic, or `reactivecircus/android-emulator-runner` as the emulator provider and still call the runner inside it.
```yaml
mobile:
  runs-on: ubuntu-latest        # the emulator action provides KVM acceleration
  if: github.event_name == 'workflow_dispatch' && inputs.includeMobile == true
  steps:
    - uses: actions/checkout@<latest-stable-sha>
    - uses: actions/setup-dotnet@<latest-stable-sha>
      with: { global-json-file: global.json }
 - name: Run Mobile UI tests on emulator
   uses: reactivecircus/android-emulator-runner@<latest-stable-sha>
   with:
     api-level: 34
     script: pwsh -NoProfile -File tests/Test.Mobile/run-mobile-tests.ps1
```

**`Test.FoundryLocal` (live AI smoke).** RID-bound native tier - the runner must install and
bootstrap the Foundry Local runtime before the test loads the native
`Microsoft.AI.Foundry.Local` SDK. The lane decides the provider via `GET /api/v1/ai/status`, not a CLI probe.
Failure versus inconclusive classification belongs to [ai-integration.md](ai-integration.md) -> *Provider Test Tiers* / *Deciding the Live Lane Without Probing the CLI*.

```yaml
foundry-local:
  runs-on: ubuntu-latest
  if: github.event_name == 'workflow_dispatch' && inputs.includeFoundryLocal == true
  steps:
    - uses: actions/checkout@<latest-stable-sha>
    - uses: actions/setup-dotnet@<latest-stable-sha>
      with: { global-json-file: global.json }
    - name: Install + bootstrap Foundry Local runtime
      run: |
        # Install the Foundry Local runtime per its docs, then warm the model.
        # foundry model run <model>   # bootstrap before the RID-bound test loads the native SDK
    - name: Run live AI smoke (RID-bound)
      run: dotnet test tests/Test.FoundryLocal/Test.FoundryLocal.csproj --configuration Release --filter "TestCategory=LiveAI" -m:1
```

---

## `cd.yml` (Build, Push, Deploy)

### Trigger default: `workflow_dispatch` only

`cd.yml` (and `provision.yml`, below) default to callable/manual entrypoints only until infra exists and the `AZURE_*` / registry secrets+vars are set. `workflow_call` preserves orchestration from a trusted promotion workflow; `workflow_dispatch` supports explicit deploy or rollback. Auto-deploy on push to `main` is opt-in only after the environment is ready.

```yaml
on:
  workflow_call:
    inputs:
      environment: { type: string, required: true }
      commit_sha: { type: string, required: true }
  workflow_dispatch:
    inputs:
      environment:
        type: choice
        options: [dev, staging, prod]
      operation:
        type: choice
        options: [deploy, rollback]
        default: deploy
      commit_sha:
        type: string
        required: false
        description: "Exact green commit to deploy; required for operation=deploy"
  # Opt-in after infra + secrets exist - uncomment to deploy on merge:
  # push:
  #   branches: [main]

concurrency:
  group: deploy-${{ inputs.environment }}
  cancel-in-progress: false
```

The entry job rejects `operation=deploy` without a full commit SHA. Resolve that SHA, verify the repository's required checks are green for the exact commit, and checkout that commit rather than the workflow branch tip. A rollback ignores new build inputs and resolves the authoritative previous successful release manifest for the environment.

### Step order (schema leads code)

1. Validate the requested exact commit is green.
2. Build and push images plus Functions/Uno bundles once - the migrator image ships with the other deployables. Resolve image digests and immutable artifact IDs into a release manifest.
3. Provision infrastructure without activating new runtime revisions.
4. Back up data before any destructive reset/migration allowed by the recorded lifecycle, then run the migrator job below before the image swap.
5. Deploy only artifacts from the release manifest.
6. Verify internal database-aware readiness (`/health/db` or app equivalent), then public full health (`/health/full` or app equivalent), then an explicit functional CRUD smoke.
7. Atomically record the previous/current successful release manifests for later rollback.

Keep scheduler replicas pinned when no coordination layer exists.

Rollback selects the recorded previous manifest, redeploys its exact image digests and bundle artifact IDs, and reruns readiness/functional smoke. It never rebuilds a historical SHA. If no authoritative previous manifest exists, fail safely instead of guessing from mutable tags or revision ordering.

### Build + Push - ACR variant

- login via `azure/login@<latest-stable-sha>` + OIDC, then `az acr login`.
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
      - uses: actions/checkout@<latest-stable-sha>
      - uses: azure/login@<latest-stable-sha>
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
      - uses: actions/checkout@<latest-stable-sha>
      - uses: docker/setup-buildx-action@<latest-stable-sha>
      - uses: docker/login-action@<latest-stable-sha>
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - id: meta
        uses: docker/metadata-action@<latest-stable-sha>
        with:
          images: ghcr.io/${{ github.repository_owner }}/${{ matrix.project.name }}
          tags: |
            type=sha,format=long,prefix=
            type=raw,value=latest
      - uses: docker/build-push-action@<latest-stable-sha>
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
    - uses: azure/login@<latest-stable-sha>
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
    - uses: azure/login@<latest-stable-sha>
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

## Post-Deploy Smoke Contract

When a deployment pipeline gains a post-deploy smoke workflow (browser tests against the deployed app), it inherits evidence duties the CI tiers do not cover:

- **Upload condition.** `if: failure()` on the artifact-upload step discards the most interesting case: a first attempt that fails and passes on retry leaves the job green, so screenshots, traces, and accessibility snapshots from the flaky failure are gone - and a full deploy cycle gets burned re-triggering a failure that already happened. Use `if: ${{ !cancelled() }}` with `if-no-files-found: ignore`; a clean run still uploads nothing.
- **Retention is a ceiling, not a setting.** `retention-days:` above the repo/org ceiling is silently clamped (a `Using N instead` line in the very log being debugged), and it covers artifacts only - run **logs** follow the repo-level value, which is why a failure log can be unreadable by the time someone looks. Check both at `gh api repos/{owner}/{repo}/actions/permissions/artifact-and-log-retention`.
- **Dispatching without a checkout.** A job that only calls `gh` (e.g. triggering the smoke workflow after deploy) has no repo checkout, and `gh` fails with "not a git repository". Pass `--repo`/`GH_REPO` explicitly instead of adding an unneeded checkout step.
- **Diagnosis order for a deployed UI failure.** The browser trace shows what the client attempted; the server request log shows what the server actually did; the bugs live in the gap. Read the server's request timeline for the failure window before theorizing from the client trace - one query can settle what two trace-derived root causes got wrong (e.g. `POST /signin-oidc` 302 -> `GET /` 200 -> `POST /logout`: sign-in succeeded, the test signed itself out).

Selector durability for the smoke suite is owned by [testing-quality.md](testing-quality.md) (every smoke-asserted selector pinned by a fast-lane component test); interactive IdP login helper rules live there too.

---

## `infra.yml` (Optional Bicep)

Use manual dispatch per environment:

1. OIDC login
2. `az bicep build --file infra/main.bicep`
3. deploy with `azure/arm-deploy@<latest-stable-sha>`

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
3. Tag by SHA for traceability, deploy the resolved digest/revision from the immutable release manifest, and avoid mutable-only references.
4. Schema prerequisites (such as scheduler tables) are applied before rolling dependent services.
5. Keep environment promotions explicit and approval-gated.
6. Validate Bicep before deploy.
7. Default PR path runs fast tiers only; all heavy/special tiers are `workflow_dispatch` toggles, default off.
8. Keep token placeholders aligned with [placeholder-tokens.md](../ai/placeholder-tokens.md).
9. Validate the requested deployment SHA is green before building; build each artifact once and reuse it through rollout and promotion.
10. Verify database-aware internal readiness before public health, then run a post-deploy functional smoke. Every health gate polls with a bounded deadline (e.g. 30 x 2s) and dumps recent service logs on genuine failure - a one-shot probe fired straight after container start false-fails healthy deploys.11. Roll back from authoritative previous-release metadata without rebuilding. Deployment concurrency queues rather than canceling an active run.
12. Operational docs state what automation actually verifies. Do not claim rollback, backup, health, or smoke coverage that the workflow does not execute.
13. Local/manual emergency deployment may mirror the same gates when explicitly requested, but scaffold generation does not create a second default deployment path.
14. A single-file bind mount does not track a replaced file: an scp'd/copied replacement is a new inode, so `reload` serves the old config silently. Mount the directory, or restart (not reload) the container after replacing the file.
15. PowerShell deploy/ops scripts carry three recurring traps: PowerShell 7.3+ drops a literal `$null` argument to a native exe (`curl -o $null` fails before any request - pipe to `Out-Null`); a here-string in a CRLF-checked-out `.ps1` carries `\r` into any embedded script piped to remote bash, aborting `set -euo pipefail` - and the repo's own `*.ps1 text eol=crlf` gitattribute guarantees it, so strip CR before piping; `-match`/`-notmatch` against an array filters elements (always truthy), never a boolean - write `-not ($lines -match ...)`.

---

## Verification

- [ ] `ci.yml` runs the fast tiers (`Unit`/`Endpoint`/`Architecture`) on PR with no Docker and no `if:` gate
- [ ] `ci.yml` declares a `workflow_dispatch` boolean (default false) for every manual tier it references, and emits one only for tiers this scaffold generated; every `inputs.*` referenced in an `if:` is declared
- [ ] heavy tiers carry the `workflow_dispatch && inputs.<x>` gate, do not overlap, and use `-m:1`; Benchmarks use `dotnet run` and Mutation uses `dotnet stryker` (never `dotnet test`); disk reclaim covers Integration/Aspire/E2E
- [ ] scheduled/manual acceptance provisions generated prerequisites, then runs unfiltered `dotnet test {SolutionName}.slnx --no-build -m:1`; filtered fast tiers remain diagnostic lanes, not acceptance
- [ ] `ci.yml` cancels superseded runs, skips draft PR work, and includes `ready_for_review`; deployment queues with `cancel-in-progress: false`
- [ ] `cd.yml` defaults to `workflow_call` plus `workflow_dispatch` deploy/rollback inputs (push-to-main is opt-in, added after infra exists); deploy requires an exact `commit_sha`
- [ ] `cd.yml` logs in with OIDC and pushes SHA-tagged images (ACR or GHCR per scaffold choice)
- [ ] GHCR path: private package has `az containerapp registry set` pull cred per app
- [ ] Migrator Container Apps Job runs BEFORE image swap; pipeline polls the execution to terminal status; runtime deploys gate on it
- [ ] deployment step updates correct environment resources by SHA tag
- [ ] requested SHA is green; one release manifest records image digests and immutable bundle IDs; expected files fail fast when absent
- [ ] internal DB-aware readiness, public full health, and functional smoke pass in order
- [ ] previous/current successful manifests are authoritative and rollback reuses the previous manifest without rebuilding
- [ ] scheduler deployment order includes prerequisite schema step
- [ ] `infra.yml`/`provision.yml` validates and deploys infra when enabled
- [ ] repo secrets/variables/environments match the registry path and are protected
