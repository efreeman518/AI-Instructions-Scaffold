# Operator Setup & Phase 3 Pre-Flight

Run-once machine/repo setup and the Phase 3 pre-flight, done before the per-phase build/test gates apply. Validation gate commands and exit criteria stay in [execution-gates.md](execution-gates.md); session routing and load rules stay in [../START-AI.md](../START-AI.md).

---

## Operator Setup (Pre-Scaffold)

Run once per machine/repo before beginning any scaffolding phase.

### Scope Selection (Pick One)

- [ ] **API-only baseline**: Foundation + App Core + API verification
- [ ] **API + services**: API baseline + Gateway/Aspire/Scheduler as enabled
- [ ] **Full app**: API + services + Function App + Uno/Blazor/React UI + IaC as enabled

### Development Tools

- [ ] Git repo initialized with `.gitignore` for .NET, **patched** for this scaffold's `src/Packages/` source folder and `Test.E2E/` project (see [../skills/solution-structure.md](../skills/solution-structure.md) section Required Root Files (Cross-Platform Hygiene))
- [ ] Current machine- or user-global Python 3 installed for scaffold helper scripts. Verify from a fresh shell per [python-setup.md](python-setup.md); do not rely on a repo `.venv` as the machine launcher.
- [ ] Tracked-source validation runs after `git add .` - see [Tracked-Source Validation](#tracked-source-validation) below.
- [ ] `.NET SDK` installed (`dotnet --version`)
- [ ] A Docker-compatible container runtime running *(if Aspire/Testcontainers tiers use SQL/Redis/Service Bus/Azurite containers)* - any of Docker Desktop, WSL Docker Engine, Rancher Desktop, or a Podman-compatible Docker socket. Verify by **capability, not product**: `docker version`, `docker info`, and `docker run --rm hello-world` all succeed. For the Aspire mesh resource floor (CPU/RAM/swap) and WSL `.wslconfig` settings, see [troubleshooting.md](troubleshooting.md) -> Docker / Container Runtime.
- [ ] `nuget.config` includes `nuget.org` + all custom/private feeds (see Private Feed Auth below)
- [ ] EF tools available (`dotnet ef --version`; prefer repo-local tool manifest, user-global `dotnet-ef` is acceptable)
- [ ] Functions Core Tools installed (`func --version`) *(if using Functions)*
- [ ] Uno templates installed (`dotnet new install Uno.Templates`) *(if using Uno UI)*
- [ ] Uno.Check installed (`dotnet tool install -g uno.check`) *(if using Uno UI)*
- [ ] Uno browserwasm workload installed (`dotnet workload install wasm-tools`) *(if using Uno browserwasm)*
- [ ] Uno Android workload installed (`dotnet workload install android`) and Android SDK/emulator tools available *(if using Uno Android)*
- [ ] Node.js LTS/npm available (`node --version`, `npm --version`) - Appium's runtime; install before the Appium CLI *(if running Uno Android/iOS Appium UI tests)*
- [ ] Appium CLI + UiAutomator2 driver installed and `appium driver doctor uiautomator2` passes required checks *(if running Uno Android device/emulator UI tests)*
- [ ] Uno iOS workload installed (`dotnet workload install ios`) and macOS runner/Mac host identified for simulator/device tests *(if using Uno iOS beyond compile planning)*
- [ ] Kiota CLI installed (`dotnet tool install -g Microsoft.OpenApi.Kiota`) *(if using Uno UI)*
- [ ] Node.js LTS/npm available (`node --version`, `npm --version`) *(if using React UI)*

### Tracked-Source Validation

Post-generation check: every `.csproj` under `src/` must be tracked by git. Run after `git add .`:

```powershell
$expected = Get-ChildItem -Recurse -Filter *.csproj src/ | ForEach-Object { (Resolve-Path $_.FullName).Path }
$tracked  = git ls-files 'src/**/*.csproj' | ForEach-Object { (Resolve-Path $_).Path }
$missing  = Compare-Object $expected $tracked -PassThru | Where-Object SideIndicator -eq '<='
if ($missing) { throw ".csproj files excluded by .gitignore: $missing" }
```

Failure means a `.gitignore` rule is silently shadowing a source folder. Fix the `.gitignore` (do **not** force-add the excluded files - the next scaffold folder will hit the same hidden rule). This generalizes: any future folder whose name collides with stock VS ignore patterns surfaces here, not on a CI fresh clone.

### Shared Base-Type Readiness (Phase 3 Pre-Flight)

The required steps depend on `packageStrategy` (set in `.scaffold/resource-implementation.yaml`).

#### When `packageStrategy: feed` or `hybrid`

Feed-supplied layers require package read access before Phase 4 restore/build can pass.

**Step 1:** Ask the user to set or confirm:
- Feed URL (e.g., `https://nuget.pkg.github.com/{owner}/index.json`)
- Auth method: `NUGET_AUTH_TOKEN` environment variable (recommended) or credential provider
- `packagePrefix` matches the feed (e.g., `EF`, `Contoso`)

**Step 2:** Generate `nuget.config`. First probe the user-global config (`%APPDATA%\NuGet\nuget.config` on Windows; `~/.nuget/NuGet/NuGet.Config` on Linux/Mac) for a `<packageSource>` whose `value` is the **same feed URL**, then branch:

| Global config has this feed URL | Action |
|---|---|
| Found | Author a **secret-free** repo `nuget.config`: copy the global source key into `<packageSources>`, add the prefix entry to `<packageSourceMapping>`, emit **no** `<packageSourceCredentials>` block (a repo credential block would shadow working global creds). NuGet resolves the PAT from the global store locally; CI injects `NUGET_AUTH_TOKEN`. Skip Step 3. |
| Not found | Run Step 2b below to write the `%NUGET_AUTH_TOKEN%` credential block. |

> **Local restore is a bare `dotnet restore`.** Never pass `--configfile src/nuget.config` for local restore: `--configfile` makes NuGet use only that file and skips the hierarchical merge with the global `NuGet.Config`, so the PAT resolved from the global store is never found and restore 401s on a fresh machine. The repo `nuget.config` is source-mapping only; credentials come from the global store (local) or `NUGET_AUTH_TOKEN` (CI, injected before restore). `--configfile` is correct only on the CI `dotnet nuget update source` step that writes those credentials in first.

**Step 2b - write the credential-bearing config** (only when the probe found no global creds). Use the feed helper:

```powershell
python .instructions/scripts/configure-ef-packages-feed.py --root . --feed-url https://nuget.pkg.github.com/{owner}/index.json --username {username} --prefix {packagePrefix}
```

The helper writes `%NUGET_AUTH_TOKEN%` only; it must never write the PAT value.

Manual equivalent (substitute `{packagePrefix}` for your prefix, e.g., `EF`):

```xml
<?xml version="1.0" encoding="utf-8"?>
<configuration>
  <packageSources>
    <clear />
    <add key="nuget.org" value="https://api.nuget.org/v3/index.json" />
    <add key="privatefeed" value="https://nuget.pkg.github.com/{owner}/index.json" />
  </packageSources>

  <packageSourceMapping>
    <packageSource key="nuget.org">
      <package pattern="*" />
    </packageSource>
    <packageSource key="privatefeed">
      <package pattern="{packagePrefix}.*" />
    </packageSource>
  </packageSourceMapping>

  <packageSourceCredentials>
    <privatefeed>
      <add key="Username" value="{username}" />
      <add key="ClearTextPassword" value="%NUGET_AUTH_TOKEN%" />
    </privatefeed>
  </packageSourceCredentials>
</configuration>
```

**Step 3:** Set the auth token via environment variable (Step 2b path only - skip when Step 2a reused working global credentials):

```powershell
# PowerShell - session-scoped (recommended for local dev)
$env:NUGET_AUTH_TOKEN = "<package-read-token>"

# Or persist in user profile (PowerShell $PROFILE)
[Environment]::SetEnvironmentVariable("NUGET_AUTH_TOKEN", "<package-read-token>", "User")
```

> **Security:** Never commit PATs to source control or ask the user to paste one into chat. Use `%VARIABLE%` syntax in `nuget.config` (Windows) or `$VARIABLE` (Linux/Mac) for credential interpolation. Add `.env` and `nuget.config.local` to `.gitignore`.

**Step 4:** Verify:

```powershell
dotnet restore
```

Gate: `dotnet restore` exits 0. All feed-supplied `{packagePrefix}.*` packages resolve, the prefix pattern maps to the private feed, and `dotnet-ef` maps to `nuget.org` when package source mapping is enabled.

#### When `packageStrategy: local`

No private feed is required. `nuget.config` only needs `nuget.org` (auto-default if the file is absent). Confirm:

- `packagePrefix` is set in `.scaffold/resource-implementation.yaml`.
- `localPackageLayers` covers every layer in [`ef-packages-reference.md`](ef-packages-reference.md).
- Phase 4 will generate one packable project per layer under `src/Packages/<packagePrefix>.<Layer>` with `IsPackable=true` and `<PackageId>=<packagePrefix>.<Layer>`.

Gate: `dotnet restore` exits 0 against `nuget.org` only.

#### When `packageStrategy: hybrid`

Both blocks above apply. The feed supplies the layers it covers; layers in `localPackageLayers` are generated locally under the **same** `packagePrefix` so they can be published into the feed later without renaming.

### AI Assistant - MCP Servers

Configure these in your AI client (VS Code `settings.json` or Claude Desktop config) so the AI can look up current docs and interact with tools during scaffolding.

- [ ] MCP servers configured per [../README.md](../README.md) (Essential + phase-relevant)

### Tooling Verification (Phase 3 Gate)

Phase 3 must populate the **Tooling & Environment Readiness** section of `.scaffold/implementation-plan.md`. Before closing Phase 3:

- [ ] Artifact consistency check in `.scaffold/implementation-plan.md` is complete: language, domain spec, resource mapping, decisions, and Phase 4 tasks agree
- [ ] `HANDOFF.md` `enabledFeatures` flags equal the host toggles in `.scaffold/resource-implementation.yaml` (`includeApi`, `includeGateway`, `includeScheduler`, `includeFunctionApp`, `includeUnoUI`, `includeBlazorUI`, `includeReactUI`, `includeNotifications`, `includeIaC`, ...). Any mismatch means a flag flipped without a re-sync - run the Gate-time Amendment Protocol below before proceeding to Phase 4
- [ ] No `[OPEN QUESTION: ...]` marker blocks Phase 4 contract scaffolding (**GR-10**). Run a literal-string scan across `.scaffold/domain-specification.yaml`, `.scaffold/UBIQUITOUS-LANGUAGE.md`, `.scaffold/DESIGN-DECISIONS.md`, and `.scaffold/implementation-plan.md`; classify any remaining marker as **blocking Phase 4** (halt) or **non-blocking deferred** (record in `HANDOFF.md` section Open Questions and proceed).
- [ ] All CLIs required by resource YAML technology choices are identified with install commands
- [ ] MCP server discovery completed (npm search, MCP registry) for project-specific libraries
- [ ] CLI preference applied: CLIs chosen over MCP servers where both exist (lower token cost)
- [ ] Each CLI entry has a verified checkbox or an install command the operator can run before Phase 4
- [ ] `dotnet restore` exits 0 (with `NUGET_AUTH_TOKEN` set when `packageStrategy: feed` or `hybrid`)
- [ ] Developer reviews `.scaffold/UBIQUITOUS-LANGUAGE.md` and `.scaffold/DESIGN-DECISIONS.md` for completeness against `.scaffold/domain-specification.yaml`
- [ ] Developer reviews `.scaffold/implementation-plan.md` against `ai/implementation-plan.md` schema

### Gate-time Amendment Protocol

A host or topology flag can still flip at a pre-code gate after Phase 2 closes (e.g., enabling `includeBlazorUI: true` because the multi-head UI decision surfaced late - see [../ai/shared-understanding-interview.md](../ai/shared-understanding-interview.md) section Multi-Head UI Decision). When any host/topology flag changes at a pre-code gate, **re-sync all four canonical artifacts before continuing** - do not let Phase 4 start until they agree:

- [ ] `.scaffold/resource-implementation.yaml` - the changed feature flag(s) are set (this is the canonical source of truth for hosting topology)
- [ ] `.scaffold/DESIGN-DECISIONS.md` - add a new decision row for the change and update the decision dependency graph / affected-decisions list (see [../templates/design-decisions-template.md](../templates/design-decisions-template.md))
- [ ] `.scaffold/implementation-plan.md` - update the solution layout, Phase 4/5 steps, test plan, tooling readiness, and risks the new host introduces (see [../ai/implementation-plan.md](../ai/implementation-plan.md))
- [ ] `HANDOFF.md` - update `enabledFeatures`, `hostGates`, and `resumeCommand`; these mirror the resource YAML and must match it exactly (HANDOFF already requires `enabledFeatures` to stay in sync - see [HANDOFF.md](HANDOFF.md))

Then re-run the `HANDOFF.md enabledFeatures == resource YAML` consistency check above. A flag that flips without this re-sync is a Phase 4 defect, not a Phase 5 surprise.
