# AI Instructions - New .NET App/Service Scaffolding

Pragmatic instruction set for AI-assisted scaffolding of C#/.NET applications and services.

**Profile structure.** Phase 1 (domain discovery, ubiquitous language, design decisions) is a **universal core** - stack-agnostic and reusable. Phases 2-5 (resource definition, planning, contracts, implementation) run under the **C#/.NET/Azure profile** indexed at [profiles/csharp-dotnet-azure.md](profiles/csharp-dotnet-azure.md). That is the only profile shipped today; the boundary is documented so a second profile (e.g. TypeScript/Node, Python/FastAPI) could plug in later without restructuring the repo.

## AI Agents & Harnesses - Quick Start

Clone this repo then run the install script to copy the instruction files into any target app repository root folder. The installer copies runtime instructions into `<app>/.instructions/` and places thin harness entrypoints at the app root. Scaffold rules stay app-scoped; do not put phase routing, TaskFlow rules, or generated-code conventions in global Codex, Claude, or Copilot instruction files.

### Supported harnesses

Each harness has a project-memory file (auto-loaded on session start) and, where supported, a scoped command/agent picker. The three project-memory files (`AGENTS.md`, `CLAUDE.md`, `.github/copilot-instructions.md`) play the same role for their respective tools - the installer writes all three so any agent that opens the repo finds its native entrypoint.

| Harness | Project-memory file | Scoped command/agent picker | Full scaffold | Vertical slice | Brownfield adoption |
|---|---|---|---|---|---|
| Codex CLI (and other CLI agents that read `AGENTS.md`) | `AGENTS.md` | - (no stable convention yet) | Prompt: `Load .instructions/START-AI.md and run the scaffold router` | Prompt: `Load .instructions/support/vertical-slice-checklist.md` | Prompt: `Load .instructions/ai/adopt-codebase.md and run the adoption flow` |
| GitHub Copilot in VS Code | `.github/copilot-instructions.md` | `.github/agents/` | Select `dotnet-scaffold` agent | Select `vertical-slice` agent | Select `scaffold-adopt` agent |
| Claude Code / Claude VS Code | `CLAUDE.md` | `.claude/commands/` | `/scaffold <domain>` | `/vertical-slice <Entity>` | `/scaffold-adopt` |
| Generic AI assistant | - (point it at `.instructions/START-AI.md` manually) | - | Prompt: `Load .instructions/START-AI.md and run the scaffold router` | Prompt: `Load .instructions/support/vertical-slice-checklist.md` | Prompt: `Load .instructions/ai/adopt-codebase.md and run the adoption flow` |

All harnesses follow the same flow: scaffold sessions boot from `.instructions/START-AI.md`, resume from `HANDOFF.md` if present, run one phase, write `HANDOFF.md`, stop. Vertical-slice sessions load `.instructions/support/vertical-slice-checklist.md` and generate one full entity stack against the gate. **Brownfield adoption** replaces the Phase 1 interview with a code-inspection pass that derives `.scaffold/domain-specification.yaml`, `.scaffold/UBIQUITOUS-LANGUAGE.md`, and `.scaffold/DESIGN-DECISIONS.md` from the existing solution; the project then continues into Phase 2 identically to a greenfield scaffold. Detail: [ai/adopt-codebase.md](ai/adopt-codebase.md).

In installed app repositories, `.instructions/` is runtime payload and should be treated as read-only during scaffold work. Record instruction feedback in `.scaffold/INSTRUCTION-GAPS.md`; maintainers fold approved gaps back into this source repo later.

Canonical execution rules: [START-AI.md](START-AI.md) (session model, phase router) and [support/execution-gates.md](support/execution-gates.md) (gate commands).

### Install into a new app

Use `install-to-project.py` from a local clone of this repo. It copies only the runtime payload - instruction files, scoped agents, CLI entrypoint, and slash commands - into your app, and skips repo-maintenance files (tests, CI workflows, global assistant instruction files, git hooks, virtualenvs).

Do not install this payload into the TaskFlow reference app (`AI-Instructions-ReferenceApp`) during normal maintenance. TaskFlow is the proof/reference implementation that these instructions point to; it should not carry its own `.instructions/` copy unless you are deliberately smoke-testing installer behavior.

`--target` is the **app repo root** (not the `.instructions/` folder). The script creates `<target>/.instructions/` if it does not exist, and writes harness entrypoints (`AGENTS.md`, `CLAUDE.md`, `.github/copilot-instructions.md`, `.claude/commands/`, `.github/agents/`) at the target root so CLI agents, Claude, and Copilot discover the scoped scaffold instructions. Root-level `AGENTS.md`/`CLAUDE.md`/`copilot-instructions.md` scaffold content is written inside sentinel markers (`<!-- ai-scaffold: start --> ... <!-- ai-scaffold: end -->`) so re-running the installer is idempotent; existing user content outside the markers is preserved.

```bash
# from a clone of this repo
python scripts/install-to-project.py --target /path/to/your-app-repo
# tip: run with --dry-run first to preview what gets copied
```

**Windows Python launcher fallback chain.** Install Python once per machine or user profile; do not rely on a repo-specific launcher for scaffold work across repos. Verify the install with [support/python-setup.md](support/python-setup.md). Try in order; the first one that prints a version is the one to use for every `scripts/*.py` invocation:

```powershell
python --version            # may resolve to Microsoft-Store stub; if it errors, try the next
py -3 --version             # works only when the Python launcher (py.exe) is installed
.venv\Scripts\python.exe --version   # source-repo fallback only; not the preferred cross-repo setup
```

Then call the script with the same machine/user-global launcher, e.g. `python scripts/install-to-project.py --target C:\path\to\your-app` or `py -3 scripts/install-to-project.py --target ...`. Use `.venv\Scripts\python.exe` only as a local authoring fallback. The same fallback applies to `configure-ef-packages-feed.py`, `validate-instructions.py`, and any other `scripts/*.py` invocation.

What it places:

| Source in this repo | Destination in your app | Mode |
|---|---|---|
| `README.md`, `CLAUDE.md`, `START-AI.md` | `<app>/.instructions/` | copy |
| `ai/`, `patterns/`, `profiles/`, `schemas/`, `skills/`, `support/`, `templates/`, `scripts/` | `<app>/.instructions/` | copy |
| `AGENTS.md` | `<app>/AGENTS.md` (Codex-style CLI agents) | merge |
| `CLAUDE.md` | `<app>/CLAUDE.md` (Claude Code project memory) | merge |
| `.github/copilot-instructions.md` | `<app>/.github/copilot-instructions.md` (Copilot global guidance) | merge |
| `.claude/commands/` | `<app>/.claude/commands/` (Claude slash commands) | dir |
| `.github/agents/` | `<app>/.github/agents/` (Copilot scoped agents) | dir |

**Merge mode** writes the scaffold block inside `<!-- ai-scaffold: start --> ... <!-- ai-scaffold: end -->` markers. Existing user content outside the markers is preserved, and an older unmarked scaffold-only copy is converted into a single marked block.

Flags:

| Flag | Purpose |
|---|---|
| `--dry-run` | Print planned copies without writing anything. |
| `--update` | Re-run against an existing install; preserves any target file with a newer mtime than the source. Leaves `HANDOFF.md` untouched. |
| `--instructions-only` | Copy only `<app>/.instructions/`; skip `AGENTS.md`, `.claude/commands/`, and `.github/agents/` placement (useful if you manage those separately). |
| `--verify` | After install, smoke-check that the expected entrypoints and payload files exist. Non-zero exit if anything is missing. Cheap insurance after a manual edit or selective copy. |
| `--verify-only` | Skip install entirely; just run the smoke check against an existing target. Useful in CI or to confirm an unfamiliar repo is correctly wired. |

After install:

- [ ] Decide the shared base-type strategy (`packageStrategy` in `.scaffold/resource-implementation.yaml`):
  - `feed` - consume `<packagePrefix>.*` from a private NuGet feed. Configure with `python .instructions/scripts/configure-ef-packages-feed.py --root . --feed-url https://nuget.pkg.github.com/{owner}/index.json --username {github-user} --prefix {packagePrefix}`.
  - `local` - no private feed. Phase 4 generates `src/Packages/<packagePrefix>.*` packable projects you can publish later.
  - `hybrid` - feed plus a `localPackageLayers` list for any gaps. Run the helper above for feed access; locally-generated projects use the same prefix.
- [ ] Confirm `dotnet restore` exits 0.
- [ ] Phase gates rely on `dotnet build` and `dotnet test`; the scaffold checklist at `support/final-scaffold-checklist.md` covers end-to-end acceptance.

### Manual copy (alternative)

If you prefer to copy by hand: harness discovery files (`AGENTS.md`, `CLAUDE.md`, `.github/copilot-instructions.md`, `.github/agents/`, `.claude/commands/`) live at the **app repo root**, not inside `.instructions/`. Everything else goes under `.instructions/`. Do not copy scaffold routing into a developer's global assistant instruction files - the per-app placement is what keeps scope correct. The install script above does this automatically and handles the merge into existing root-level files.

---

## Purpose

This instruction set turns an AI coding assistant into a guided scaffolding engine for production-grade C#/.NET solutions. Instead of generating throwaway boilerplate, it drives a structured five-phase process - from domain discovery through implementation - producing consistent, buildable, testable code that follows clean architecture and the conventions of a mature engineering team.

The goal is not to replace engineering judgment but to compress the multi day/week "green-field to first vertical slice" timeline down to hours, with guardrails that prevent common shortcuts (missing tests, leaky abstractions, inconsistent naming).

Phase 1 also creates durable collaboration artifacts before code planning starts:

- `.scaffold/UBIQUITOUS-LANGUAGE.md` records accepted domain terms, rejected synonyms, states, commands/actions, roles, events, policies, and naming guidance so later AI sessions use consistent expressions.
- `.scaffold/DESIGN-DECISIONS.md` records design choices and dependencies between decisions, so downstream resource and code choices do not silently contradict earlier domain answers.

### Phase-1 Artifact Lifecycle

> **Rule of thumb:** *Fix the artifact first, then the code. When drift exists, the artifact loses to code reality.*

`.scaffold/domain-specification.yaml`, `.scaffold/UBIQUITOUS-LANGUAGE.md`, and `.scaffold/DESIGN-DECISIONS.md` are **living source of truth**, not snapshots. Every phase consumes them, so they must stay current as the project evolves - otherwise later AI sessions reason from a stale model and naming/decision drift creeps in.

This rule is enforced at every session boundary: [START-AI.md](START-AI.md) section Phase-1 Artifact Lifecycle Rule, [ai/SKILL.md](ai/SKILL.md) section Non-Negotiables and section Scaffold Definition of Done, and the per-session check in [support/HANDOFF.md](support/HANDOFF.md) section Phase-1 Artifact Currency.

**When to update each:**

- **New entity, term, role, event, or domain action** -> append the term to `.scaffold/UBIQUITOUS-LANGUAGE.md` and update the relevant section of `.scaffold/domain-specification.yaml` (entity, customAction, event, etc.) before generating code. The `/vertical-slice` checklist enforces this as a pre-flight step.
- **New design choice or revision of an earlier one** -> append to `.scaffold/DESIGN-DECISIONS.md`. Do not silently rewrite earlier entries; mark the prior decision as superseded and link forward, so the dependency graph remains traceable.
- **Schema or relationship change** -> update `.scaffold/domain-specification.yaml` first, then propagate to EF configuration, repositories, DTOs, mappers, and tests in that order.

**Drift signal.** If `.scaffold/UBIQUITOUS-LANGUAGE.md` and code identifiers diverge, the doc is wrong, not the code (per [support/final-scaffold-checklist.md](support/final-scaffold-checklist.md) language-failure rule). Update the doc to match accepted reality before changing code names. The same applies to `.scaffold/DESIGN-DECISIONS.md` - if the implemented architecture has moved past a recorded decision, supersede the entry rather than leaving the doc to contradict the code.

**Mid-scaffold corrections.** When a domain misunderstanding surfaces mid-Phase-5 (entity purpose wrong, term mismatched, decision violated), [support/OPERATIONS.md](support/OPERATIONS.md) is the canonical recovery path: clarify with the user, update the Phase-1 artifacts, then re-scaffold the affected slice.

**Do not delete.** These artifacts are the onboarding surface for every future AI session, code reviewer, and new team member. Keep them in the repo root for the life of the project - even when they grow long, the cost of reading them is far lower than the cost of an AI session reasoning from absent context.

## Phases

Each phase runs in its own AI session and produces artifacts the next phase consumes.

| Phase | Purpose | Output |
|---|---|---|
| **1 - Domain Discovery** *(universal)* | Structured interview to reach shared understanding, define ubiquitous language, resolve decision dependencies, and capture entities, relationships, events, workflows, and business rules in pure business language - no implementation details. | `.scaffold/domain-specification.yaml`, `.scaffold/UBIQUITOUS-LANGUAGE.md`, `.scaffold/DESIGN-DECISIONS.md` |
| **2 - Resource Definition** *(C#/.NET/Azure profile)* | Map each resource requirement to concrete technology choices - data stores, messaging, AI capabilities, hosting models. | `.scaffold/resource-implementation.yaml` |
| **3 - Implementation Planning** *(C#/.NET/Azure profile)* | Resolve open questions, verify tooling (NuGet feeds, CLIs), discover project-specific CLIs and MCP servers, and produce a sequenced build plan. | `.scaffold/implementation-plan.md` |
| **4 - Contract Scaffolding** *(C#/.NET/Azure profile)* | Generate solution structure, interfaces, DTOs, entity shells, test infrastructure, and no-op DI stubs. Gate: `dotnet build` succeeds on the full solution. | Compilable skeleton |
| **5 - Implementation (TDD)** *(C#/.NET/Azure profile)* | Build vertical slices entity-by-entity across sub-phases 5a-5e (Foundation, App Core + Runtime, Optional Hosts, Quality + Delivery, Integration). Phase 5a uses test-driven development (write tests first -> red -> implement -> green); 5b is mixed (TDD for app/API, tests-after for runtime); 5c-5e are tests-after. | Production code + passing tests |

Phase 1 is stack-agnostic; Phase 2+ is the C#/.NET/Azure profile. See [profiles/csharp-dotnet-azure.md](profiles/csharp-dotnet-azure.md) for the file index, and [START-AI.md](START-AI.md) section Profiles and section Phase Router for routing detail.

## Ground Rules

A 1-page index of the binding rules every scaffold session honors lives at [GROUND-RULES.md](GROUND-RULES.md). The rules carry stable identifiers (`GR-01`...`GR-16`) so phase gates, skills, and templates can cite the rule they enforce without restating it. Detail enforcement remains in [ai/SKILL.md](ai/SKILL.md) section Non-Negotiables and section Scaffold Definition of Done, [START-AI.md](START-AI.md) section Phase-1 Artifact Lifecycle Rule, and [support/execution-gates.md](support/execution-gates.md) - the index does not replace them.

## Approach

The instruction set is designed around three core ideas:

**1. Phased workflow with TDD.**
Five phases prevent hallucinated architecture by ensuring verified context before code is written. Phase 4 produces a compilable skeleton so that Phase 5a/5b can follow a strict red/green TDD cycle - tests are written against contracts before any implementation exists. See [ai/tdd-protocol.md](ai/tdd-protocol.md).

**2. Skills and templates as composable units.**
Implementation knowledge is split into focused skill files (how things work) and template files plus a `templates/index.md` index (what to generate). The Phase Router in `START-AI.md` and the Phase 5 file table in `ai/SKILL.md` tell the agent which files to load for the current phase or sub-phase.

**3. Composition patterns, not documentation alone.**
Pattern files in `patterns/` document how generated components wire together across projects - database context pooling, API startup sequences, request context resolution, cache configuration, and Aspire resource wiring. The pattern index lives in `ai/SKILL.md` section Non-Negotiables (one bullet per pattern, with the phase to load it). This grounds the generated output in proven, real-world patterns rather than abstract descriptions.

## Reference Application

A companion reference app - **TaskFlow** - demonstrates every pattern and convention these instructions produce: dual DbContext pooling, YARP gateway, Aspire orchestration, FusionCache + Redis backplane, TickerQ scheduling, Azure Functions, multi-tenancy, scaffold-mode auth, Uno WASM UI, Blazor UI, and React/Vite UI.

TaskFlow is a reference/proof target, not a normal install target for `.instructions/`. Keep scaffold runtime instructions in this repository and consult TaskFlow through [support/reference-app.md](support/reference-app.md) and [support/taskflow-proof-map.md](support/taskflow-proof-map.md).

**Repository:** <https://github.com/efreeman518/AI-Instructions-ReferenceApp>

For consultation rules, AI access (local clone vs GitHub MCP), and the phase -> area pointer map, see [support/reference-app.md](support/reference-app.md) and [support/taskflow-proof-map.md](support/taskflow-proof-map.md).

## Quick Start

If you want the shortest path from zero context to first scaffold:

1. Create a new app repo.
2. Run `python scripts/install-to-project.py --target /path/to/your-app-repo --verify` from this repo.
3. Start through the harness table above: `AGENTS.md`, Copilot agent, Claude command, or a prompt that loads `.instructions/START-AI.md`.

**First time?** Use the [Minimum Viable Scaffold (MVS)](support/minimum-viable-scaffold.md) - paste-ready prompts (one per phase, with Phase 5 split into 5a + 5b sessions) that produce an API-only app with one entity, no Gateway/UI/AI/messaging. You can promote to a richer profile once the loop feels familiar.

Read the rest of this guide when you need setup details, MCP recommendations, or troubleshooting rules.

## Prerequisites

- `git`
- A current machine- or user-global Python 3 to run `install-to-project.py`, `configure-ef-packages-feed.py`, and `validate-instructions.py`; see [support/python-setup.md](support/python-setup.md). **On Windows, no single launcher is universal:** `py -3` works on machines with the Python launcher installed, and the bare `python` command works when a real Python is on PATH (it may resolve to the Microsoft-Store stub if not). Run `where python` and `where py` to see what's available, then pick the one that prints a real path. `.venv\Scripts\python.exe` is acceptable for source-repo authoring, but it is not the preferred cross-repo setup. The scripts have no Python-version-specific syntax - any current 3.x works.
- Latest stable `.NET SDK`
- Docker engine running (Docker Desktop not required) - Aspire relies on it for hosting local container services
- VS Code + AI assistant
- Local SQL Server/Azure SQL access for dev scenarios
- For `packageStrategy: feed` or `hybrid` only - read access to the configured private NuGet feed (e.g., GitHub Packages for the canonical `EF.*` example); expose via `NUGET_AUTH_TOKEN` or an approved credential provider before Phase 3/4 restore. `packageStrategy: local` skips this entirely.
- If using Uno UI:
  - `dotnet new install Uno.Templates`
  - `dotnet tool install -g uno.check` then `uno-check`
  - `dotnet workload install wasm-tools android`
  - `dotnet workload install ios` only when an iOS compile gate or macOS/iOS CI job is in scope
  - `dotnet tool install -g Microsoft.OpenApi.Kiota`
  - For Android local testing: Android Studio or command-line SDK tools with Platform-Tools, Android Emulator, one recent platform, and one AVD.
- If using React UI: current Node.js LTS plus npm.

Version policy: prefer latest stable packages and SDKs.

### Shared Base-Type Packaging

Phase 2 resolves how shared base-type contracts (entity bases, repository bases, request context, results, paged response, specifications, messaging interfaces) are sourced. Three modes live in `.scaffold/resource-implementation.yaml` under `packageStrategy`:

- **`feed`** - pre-built NuGet packages consumed from `customNugetFeeds` (e.g., the canonical `EF.*` example on GitHub Packages). Requires feed read access.
- **`local`** - no private feed. Phase 4 generates one packable project per layer in `localPackageLayers` under `src/Packages/<packagePrefix>.<Layer>`. The solution consumes them via `<ProjectReference>`. Publish later with `dotnet pack` and migrate to `feed` when ready.
- **`hybrid`** - feed plus locally-generated gaps. Layers the feed lacks live in `localPackageLayers` under the same prefix so they can be pushed into the feed later without renaming.

`packagePrefix` is required in every mode; `EF` is the canonical example used throughout these instructions.

#### `feed` or `hybrid` - Private Feed Setup

Local restore requires package read access through `NUGET_AUTH_TOKEN` or an approved credential provider.

Set the token in your shell rather than committing secrets or pasting PATs into chat:

```powershell
$env:NUGET_AUTH_TOKEN = "<package-read-token>"
```

Then ensure `nuget.config` maps `<packagePrefix>.*` to the private feed and uses `%NUGET_AUTH_TOKEN%` for the feed password. Configure once, then verify with `dotnet restore`:

```powershell
python .instructions/scripts/configure-ef-packages-feed.py --root . --feed-url https://nuget.pkg.github.com/{owner}/index.json --username {github-user} --prefix {packagePrefix}
dotnet restore
```

Never commit a PAT. CI should inject the same token through secret variables.

#### `local` - No Feed Setup Needed

`nuget.config` only needs `nuget.org` (the file may be absent and NuGet's default applies). Phase 4 generates the packable projects from `localPackageLayers`. Verify with `dotnet restore` after Phase 4 - no auth token required.

## Repository Setup

1. Create a new empty app repo.
2. Install this instruction set with `python scripts/install-to-project.py --target /path/to/your-app-repo`.
3. Open the app repo in VS Code or your CLI harness.

Expected shape (note `AGENTS.md`, `.github/agents/`, and `.claude/commands/` live at the app repo root, not inside `.instructions/`):

```text
<YourApp>/
  AGENTS.md                       # CLI agents discover here; loads .instructions/START-AI.md only on explicit scaffold request
  .github/
    agents/                        # Copilot discovers scoped agents here
      dotnet-scaffold.agent.md
      vertical-slice.agent.md
  .claude/
    commands/                      # Claude discovers scoped commands here
      scaffold.md
      vertical-slice.md
  .instructions/
    README.md
    CLAUDE.md
    START-AI.md
    ai/
      SKILL.md
      domain-specification-schema.md
      resource-implementation-schema.md
      implementation-plan.md
      placeholder-tokens.md
    profiles/
      csharp-dotnet-azure.md       # active stack profile (file index)
    support/
      HANDOFF.md
      operator-setup.md
      execution-gates.md
      troubleshooting.md
    skills/
    scripts/
    templates/
    schemas/
  README.md
```

Notes:
- `.instructions/support/HANDOFF.md` is the template.
- A working `HANDOFF.md` is created in the target project root at the end of every phase and updated after each Phase 5 sub-phase.

## Recommended MCP Servers

> **Prefer CLI over MCP when both exist.** CLI tools have lower token cost and faster execution. Use MCP servers for interactive exploration or when no CLI equivalent is available.

### Core (always on)

| Server | Why | CLI alternative |
|---|---|---|
| Microsoft Docs MCP | Official .NET/Azure docs, samples, full-page retrieval | - |
| Context7 MCP | Third-party library/API docs | - |

### Enable by phase

| Server | Enable when | CLI alternative |
|---|---|---|
| GitHub MCP | Repo workflows, issues/PRs, CI visibility | `gh` CLI (preferred) |
| Azure MCP | IaC/deployment/resource validation | `az` CLI (preferred) |
| Playwright MCP | UI E2E validation/debugging | - |
| Fetch MCP | Pull external specs/docs into markdown | `curl` / `Invoke-RestMethod` |
Optional additions: Git, Docker (`docker` CLI preferred), Memory, web-search MCPs, Azure DevOps MCP (`az devops` CLI preferred).

### Tooling discovery

Phase 3 analyzes `.scaffold/resource-implementation.yaml` technology choices and actively researches available CLIs and MCP servers for the project's specific libraries and services. Results are recorded in the implementation plan's **Tooling & Environment Readiness** section and verified at the start of each subsequent phase.

**CLI -> MCP -> online resources:** Prefer CLI tools first (lowest token cost), then MCP servers for interactive exploration, then documentation URLs and GitHub repos the AI can fetch during implementation.

## Model Tier by Phase

> **Quality first - the scaffold is built once and read for the project's life.** The default tier is **high-capability for every phase**. A cheaper tier is an opt-in cost lever only where the work is mechanical and fully build/test-verified; it is never a recommendation, and never appropriate on reasoning-heavy phases. When uncertain, stay higher. Model tier is operator- and harness-controlled (the operator selects it at session start, since the workflow is one phase per session); if your harness cannot select a model, ignore this section and continue. Per **GR-08** this guidance names capability tiers by characteristic only - never a model id or version, which would go stale on every release.

### Tiers

| Tier | Use for | Characteristics |
|---|---|---|
| Reasoning | Domain modeling, ambiguity resolution, design, integration nuance | Deepest multi-step reasoning; highest cost; slowest |
| Balanced | Well-specified implementation against a fixed design | Solid coding capability; moderate cost |
| Fast | Deterministic, mechanical, fully build/test-verifiable work | Lowest cost; fastest; weakest reasoning |

### Recommended tier by phase

| Phase | Recommended tier | Cost-lever note |
|---|---|---|
| 1 - Domain discovery (interview) | Reasoning | Never downgrade - ambiguity and dependency-ordered decisions set everything downstream |
| 2 - Resource definition | Reasoning | Technology and dependency-mode choices |
| 3 - Implementation planning | Reasoning | Sequencing and open-question resolution |
| 4 - Contract scaffolding | Reasoning | Errors here cascade into all of Phase 5; fast tier only to re-generate boilerplate after the design is fixed, gated on a green build |
| 5a/5b - Foundation + app core (TDD) | Reasoning / Balanced | Keep high for domain logic and test design |
| 5c - Optional hosts | Balanced | |
| 5d - Quality + delivery | Balanced | Fast tier for mechanical config/doc generation only under green tests |
| 5e - Integration (auth + AI) | Reasoning | Auth and AI wiring carry the most subtle failure modes |
| Cross-cutting: rollback structural decisions, mixed-store consistency design ([support/OPERATIONS.md](support/OPERATIONS.md)) | Reasoning | Structural calls are expensive to get wrong |

When in doubt, stay on the higher tier - the token saving is one-time, the output is permanent.

## Where Things Live

A short map of the repo so you know which directory owns what kind of content. Useful when deciding where to put a new instruction or fix.

| Folder | Owns | Loaded when |
|---|---|---|
| Root project-memory files: `AGENTS.md` (Codex / CLI agents), `CLAUDE.md` (Claude), `.github/copilot-instructions.md` (Copilot) - three vendor-specific entrypoints, same role | Harness discovery and explicit scaffold trigger detection | Auto-loaded by the harness; must stay thin |
| Root scoped pickers: `.claude/commands/` (Claude slash commands), `.github/agents/` (Copilot agent picker) | Harness-specific scaffold launchers | Selected only for scaffold, vertical-slice, or brownfield-adoption work |
| `START-AI.md` in this repo / `.instructions/START-AI.md` in installed apps | Canonical bootstrap: session router, phase router, load rules, reference-app pointer | Loaded only after explicit scaffold request |
| `ai/` | Phase orchestration: schemas, interview, contract scaffolding, TDD protocol, placeholder tokens, Phase 5 file table (`SKILL.md`) | Per-phase routing |
| `profiles/` | Per-stack profile indexes. Lists which Phase 2-5 files belong to each profile. Today: `csharp-dotnet-azure.md` (the only profile shipped) | Reference; consulted to confirm the active stack mapping |
| `skills/` | Reusable how-to per concern (domain, data, API, gateway, caching, identity, testing, UI, etc.) | Per-sub-phase, by `SKILL.md` file table |
| `templates/` | Code-shape templates for generated artifacts (entity, EF config, repository, service, endpoint, tests) | Per-sub-phase, paired with the matching skill |
| `patterns/` | Cross-project wiring (data layer, API host, infrastructure, expected output) | On-demand; index in `ai/SKILL.md` section Non-Negotiables |
| `support/` | Operator-facing detail: execution gates, operations protocols, troubleshooting, HANDOFF template, MVS, golden path, prompt catalog, reference-app proof map | On failure, on session boundary, or on need |
| `schemas/` | JSON Schemas for `.scaffold/domain-specification.yaml` and `.scaffold/resource-implementation.yaml` | Phase 1/2 validation |
| `scripts/` | Author + operator tooling: install-to-project, configure-ef-packages-feed, validate-instructions | One-off |

Rule of thumb when adding new content: it goes in `skills/` if it's "how to do X", in `templates/` if it's "the shape of the file you generate", in `patterns/` if it's "how multiple projects wire together", in `support/` if it's operator-facing, and in `ai/` only if it's phase orchestration the AI needs at session start.

## Mode Selection

| Need | Mode |
|---|---|
| Fast internal tool, minimal infra | `scaffoldMode: lite` |
| Production-ready with optional hosts | `scaffoldMode: full` |
| Smallest viable scaffold (single API, defaults to all optional hosts off) | `scaffoldMode: api-only` |

`scaffoldMode` drives load-set sizing per Phase 5 sub-phase; the optional-host toggles (`includeGateway`, `includeUnoUI`, `includeReactUI`, `includeScheduler`, etc.) are independent flags in `.scaffold/resource-implementation.yaml` and can be enabled in any mode. `api-only` simply biases the defaults toward "off".

Defaults: [ai/resource-implementation-schema.md](ai/resource-implementation-schema.md) **Canonical Defaults**. Load-set sizing: [ai/SKILL.md](ai/SKILL.md) section Load-Set Sizing.

## Happy Path

1. Prerequisites and repo setup (see [Quick Start](#quick-start) and [Prerequisites](#prerequisites))
2. Phase 1: Domain YAML + language + decisions -> [ai/shared-understanding-interview.md](ai/shared-understanding-interview.md)
3. Phase 2: Resource YAML -> [ai/resource-implementation-schema.md](ai/resource-implementation-schema.md)
4. Phase 3: Implementation plan -> [ai/implementation-plan.md](ai/implementation-plan.md)
5. Phase 4: Contract scaffolding -> [ai/contract-scaffolding.md](ai/contract-scaffolding.md)
6. Phase 5: Implementation (TDD) -> [ai/SKILL.md](ai/SKILL.md) + [ai/tdd-protocol.md](ai/tdd-protocol.md)
7. Validate gates -> [support/execution-gates.md](support/execution-gates.md)
8. Final scaffold check -> [support/final-scaffold-checklist.md](support/final-scaffold-checklist.md)
9. Troubleshoot -> [support/troubleshooting.md](support/troubleshooting.md)

## Prompt Catalog

For copy-paste phase prompts, see [support/prompt-catalog.md](support/prompt-catalog.md). The catalog is a convenience layer for engineers; [START-AI.md](START-AI.md) remains the canonical operational bootstrap for AI execution.

## Context Tooling

This scaffold can use optional context-optimization tools ([rtk](https://github.com/rtk-ai/rtk),
[headroom](https://github.com/chopratejas/headroom),
[graphify](https://github.com/safishamsi/graphify)) to cut token cost in AI sessions. They are a separate concern from the scaffold itself - machine and
operator setup, not part of any app's payload, and not required to scaffold or run an app.

Setup, installation, and per-tool details are operator/machine concerns managed separately
and are out of scope for this instruction set. Within the scaffold, the only context-tooling
guidance that matters is the per-repo graphify layer choice and phase-boundary build timing,
in [support/context-tooling.md](support/context-tooling.md) (reached per repo via a pointer in
[START-AI.md](START-AI.md)).

## Operational References

These references are for **maintaining and developing the instruction set itself** - not for using it to scaffold a new application. For app scaffolding, see [Quick Start](#quick-start) and [Happy Path](#happy-path).

- [START-AI.md](START-AI.md) - canonical AI bootstrap, version checks, phase routing, and load rules
- [support/prompt-catalog.md](support/prompt-catalog.md) - copy-paste prompts for starting or resuming a session
- [support/phase-1-worked-example.md](support/phase-1-worked-example.md) - condensed transcript of the TaskFlow Phase 1 interview (pacing, branch recaps, mid-interview corrections)
- [support/execution-gates.md](support/execution-gates.md) - canonical per-phase validation gates and commands
- [support/operator-setup.md](support/operator-setup.md) - run-once machine/repo setup + Phase 3 pre-flight (tools, tracked-source, package-feed readiness)
- [support/python-setup.md](support/python-setup.md) - Python install and launcher verification for scaffold scripts
- [support/golden-path-sample.md](support/golden-path-sample.md) - canonical small sample for regression-checking scaffold instructions
- [support/final-scaffold-checklist.md](support/final-scaffold-checklist.md) - final generated-app scaffold acceptance checklist
- [support/troubleshooting.md](support/troubleshooting.md) - failure triage and recurring issue guidance
- [support/taskflow-proof-map.md](support/taskflow-proof-map.md) - fast reference-app proof map from instruction concern to TaskFlow area
- [support/UPDATE-INSTRUCTIONS.md](support/UPDATE-INSTRUCTIONS.md) - capture improvements discovered during scaffolding

Useful script entrypoints:

- `scripts/install-to-project.py` - copy the runtime payload into a consumer app's `.instructions/` directory and place harness entrypoints at the app root. `--verify` smoke-checks the install; `--verify-only` runs the smoke check without copying.
- `scripts/configure-ef-packages-feed.py` - create/update target-app `nuget.config` for any private NuGet feed without writing PATs. Pass `--prefix <packagePrefix>` to map the appropriate `<packagePrefix>.*` pattern; the canonical EF.* example is the default. Only run for `packageStrategy: feed` or `hybrid`.
- `scripts/validate-instructions.py` - author-side sanity check: relative-link integrity, phase-label canonical set, harness command-file shape, payload shape vs installer declaration, and golden-path YAML vs `schemas/*.schema.json` (full jsonschema validation when `pyyaml` + `jsonschema` are installed; stdlib structural checks otherwise). Run before committing edits to instruction files; CI runs it on every push via `.github/workflows/validate.yml`.
- `tests/golden-path/run-golden-path.py` - author-side end-to-end regression: drives headless agent sessions (Claude Code subscription login or Codex CLI - no API key) through Phases 3-5b against the WorkBoard golden-path fixture in a throwaway workspace, gating each phase with `dotnet build`/`dotnet test`. Start with `--dry-run`. Not part of the installed payload; reports land under `.tmp/golden-path-runs/`.
