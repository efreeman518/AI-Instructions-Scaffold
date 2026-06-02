# Context Tooling - Per-Repo Graphify Layer Selection

How to decide which graphify LAYER to build per repository, and how to wire it in.
graphify is the single knowledge-graph tool: it reduces orientation token cost by
letting an agent query relationships instead of grepping/reading raw files. It sits
upstream of the compression tools (headroom, rtk) and does not overlap with them.

## Tool stack roles (no overlap)

- rtk - compresses CLI command output. Enforced via the `rtk` Bash prefix rule.
- headroom - compresses prompt inputs (tool outputs, history) before the API call.
- Output compression (caveman style) - enforced via instruction rules, not a tool.
- Knowledge graph (graphify) - reduces what gets loaded by enabling relationship
  queries. This file governs which graphify layer to build, per repo.

Pipeline: graph (what to load) -> headroom (compress inputs) -> rtk + output rules.

graphify is installed/updated globally by
`misc/update-python-and-context-tools.ps1`. That script installs the CLI only. It
does not enable any repo harness and does not create a graph database.
Per-harness enablement and per-repo graph creation are project-time actions.

## Two layers: structure-only vs. full

graphify can build at two depths. The per-repo decision is which LAYER, not which tool:

- **Structure-only** - AST parsing via tree-sitter. 100% local, zero model spend, no
  backend needed. Sees code symbols and call/reference edges; blind to markdown, YAML,
  infra, and `.razor` / `.xaml` markup. This is the cheap, code-navigation layer.
- **Full (AST + semantic)** - adds an LLM pass that extracts semantic relationships
  from markdown/YAML/infra and the `.instructions/` / `.scaffold/` doc layer. In a
  Claude Code or **Claude VS Code** session the host Claude session performs this
  extraction directly (subagent dispatch) - **no API key needed**. Headless/CI flows set
  `GEMINI_API_KEY` or `GOOGLE_API_KEY` to use Gemini, or pass
  `--backend gemini|kimi|openai|deepseek|claude-cli` to `graphify extract`. graphify
  reads only the Gemini/Google keys from the environment - never `ANTHROPIC_API_KEY` or
  `OPENAI_API_KEY`. Spends model tokens; sees the whole repo.

The choice is a deliberate cost/coverage call, not forced by key availability.

## Decision rule (LOC ratio)

Measure two sums, excluding generated/transient files (bin, obj, node_modules,
.tmp, TestResults, StrykerOutput, BenchmarkDotNet.Artifacts, logs,
package-lock.json, *.Designer.cs, ModelSnapshot.cs, rendered *.html docs):

- KNOWLEDGE = LOC of `.instructions/` + `.scaffold/` + `docs/*.md`
- CODE = LOC of application `src/` (*.cs, *.razor, *.ts, *.tsx, *.xaml)

| Condition                                                | Layer          | Why                                                                 |
|----------------------------------------------------------|----------------|---------------------------------------------------------------------|
| KNOWLEDGE >= CODE                                        | full           | Doc/spec layer is the majority; only the semantic pass reads it     |
| CODE > KNOWLEDGE but CODE < 3x KNOWLEDGE                 | full           | Spec<->code links still high value; semantic layer wins             |
| CODE >= 3x KNOWLEDGE                                     | structure-only | Mostly code navigation; local + free + AST is sufficient            |
| No `.instructions/` or `.scaffold/`                      | structure-only | Plain code repo; no semantic doc layer to miss                      |
| Brownfield adoption pass (src/ exists, no .scaffold/ yet)| structure-only | Thick code, no knowledge layer yet; re-evaluate after Phase-1 artifacts derived |

Rationale: the full layer sees the whole repo (code AST PLUS LLM semantic extraction
of markdown/YAML/infra), at the cost of model spend. The structure-only layer is
AST-only, 100% local, zero model spend, but blind to the `.instructions/` /
`.scaffold/` / docs layer and to `.razor` / `.xaml` markup. A freshly scaffolded app
is knowledge-heavy (KNOWLEDGE >= CODE) -> full. A mature app where code dwarfs the
static doc layer -> structure-only, with an occasional full pass for spec<->code
consistency checks.

## Measure command (PowerShell)

```powershell
$prune = '\\(node_modules|\.git|bin|obj|dist|\.tmp|TestResults|StrykerOutput|BenchmarkDotNet\.Artifacts|\.venv|packages)\\'
$skip  = '(package-lock\.json|.*\.Designer\.cs|.*ModelSnapshot\.cs|.*\.csproj\.user)$'
function Sum-Loc($paths) {
  ($paths | Where-Object { Test-Path $_ } | Get-ChildItem -Recurse -File -EA SilentlyContinue |
    Where-Object { $_.FullName -notmatch $prune -and $_.Name -notmatch $skip } |
    ForEach-Object { (Get-Content -LiteralPath $_.FullName | Measure-Object -Line).Lines } |
    Measure-Object -Sum).Sum
}
$knowledge = Sum-Loc @('.instructions','.scaffold','docs')
$code = (Get-ChildItem src -Recurse -File -Include *.cs,*.razor,*.ts,*.tsx,*.xaml -EA SilentlyContinue |
         Where-Object { $_.FullName -notmatch $prune -and $_.Name -notmatch $skip } |
         ForEach-Object { (Get-Content -LiteralPath $_.FullName | Measure-Object -Line).Lines } |
         Measure-Object -Sum).Sum
"KNOWLEDGE=$knowledge  CODE=$code  ratio(code/knowledge)={0:N2}" -f ($code / [math]::Max($knowledge,1))
```

## Setup - graphify

Global CLI install:

```powershell
winget install astral-sh.uv    # only if uv is missing
uv tool install graphifyy      # PyPI package name has double-y
uv tool upgrade graphifyy      # update an existing global install
graphify --version
```

The CLI command is `graphify`. Avoid plain `pip install graphifyy` on Windows and
Mac unless there is no alternative; Graphify's own guidance prefers `uv tool`
or `pipx` to avoid interpreter mismatch during skill execution.

Enable Graphify per repo and per harness only where wanted. Run from the target
repo root after the global CLI exists:

```powershell
graphify claude install --project
graphify codex install --project
graphify copilot install --project
```

Equivalent generic form:

```powershell
graphify install --project --platform codex
```

Codex also needs `multi_agent = true` under `[features]` in
`%USERPROFILE%\.codex\config.toml` before `$graphify` skill commands are
available. If skill commands are unavailable, use the CLI commands below.

Create the graph database from the repo root. Pick the layer per the decision rule
above:

```powershell
# Full layer (AST + semantic): the normal scaffolded-app build.
# In a Claude Code / Claude VS Code session semantic extraction runs through the
# host Claude session - no API key. Headless: set GEMINI_API_KEY/GOOGLE_API_KEY.
# Add --wiki to also emit the agent-crawlable wiki (graphify-out/wiki/index.md + one
# article per community + god nodes) that the global steering points agents to.
graphify . --wiki       # PowerShell CLI: no leading slash

# Structure-only layer (AST, no model spend): code-heavy / low-doc repos.
# There is no dedicated --code-only flag: graphify ALWAYS extracts code locally via
# tree-sitter (no API calls); the semantic LLM pass only runs on docs/papers/images.
# So restrict the corpus to code via .graphifyignore (exclude docs/.instructions/
# .scaffold) and the semantic pass has nothing to do. Add --no-cluster to also skip
# the clustering/community-naming step. A structure-only build has no communities, so
# the wiki adds little - skip --wiki here. Refresh with the no-LLM update:
graphify .  --no-cluster   # initial structure-only build
graphify update .          # re-extract changed code files only; no LLM, no model spend
```

Verify the build created:

- `graphify-out/graph.json`
- `graphify-out/GRAPH_REPORT.md`
- `graphify-out/graph.html`
- `graphify-out/wiki/index.md` (full layer with `--wiki` only)

Do not treat a global install or project harness registration as a built graph.
The repo is not graph-enabled until `graphify-out/graph.json` exists.

Query or refresh an existing graph:

```powershell
graphify query "what connects the API to persistence?"
graphify update .             # incremental AST refresh (no LLM); skill alias: graphify . --update
graphify export wiki          # regenerate graphify-out/wiki/ from graph.json (no LLM, no model spend)
graphify extract . --force    # full re-extraction after large refactors or stale/duplicate nodes
```

The commit-time auto-update hook (below) refreshes the code/AST layer in graph.json but does
NOT regenerate the wiki. Rerun `graphify export wiki` (cheap, no model) after large code
changes, and a full `graphify . --wiki` at phase boundaries to refresh the semantic/doc layer
and the wiki together.

Codex skill syntax is `$graphify .`; Claude-style `/graphify .` is not valid in
PowerShell. Prefer CLI/skill mode over the Graphify MCP server to avoid standing
tool-schema tokens.

`.graphifyignore` (repo root):
**/bin/
**/obj/
**/dist/
**/node_modules/
**/.tmp/
**/TestResults/
**/StrykerOutput/
**/BenchmarkDotNet.Artifacts/
**/.log
**/.trx
**/package-lock.json
/.csproj.user
docs/.html
docs/assets/
src/Infrastructure/**/Migrations/

Keep `.instructions/`, `.scaffold/`, `docs/*.md`, `HANDOFF.md`, all `src/*.cs|.razor`.

Do NOT gitignore all of `graphify-out/`. Commit the durable graph artifacts and ignore
only the transient/machine-specific ones. Keep these rules in the **repo-root
`.gitignore`** (path-prefixed) - not a `graphify-out/.gitignore` subfolder file. graphify
never creates a subfolder ignore file, and the canonical guidance keeps every ignore rule
at the root.

- **Commit**: `graphify-out/graph.json`, `graphify-out/GRAPH_REPORT.md`,
  `graphify-out/graph.html` (the queryable graph + report).
- **Ignore** (add to repo-root `.gitignore`):

  graphify-out/manifest.json
  graphify-out/cost.json
  graphify-out/cache/
  graphify-out/wiki/
  graphify-out/obsidian/
  graphify-out/.graphify_*

  The wiki is gitignored BY DEFAULT - it is regenerable from `graph.json` via
  `graphify export wiki` (no model cost), so it does not need to live in git. Commit
  `graphify-out/wiki/` only on explicit request (e.g. to give every clone the agent entry
  point without a rebuild).

  `manifest.json` / `cost.json` are mtime-based and break on clone; `.graphify_*` is local
  scratch/scan-root state (the `.graphify_semantic_marker` / `.graphify_analysis.json`
  markers are covered by the glob).

## Keeping the graph fresh (auto-update on commit)

graphify ships a harness-agnostic git hook that rebuilds the graph after each commit.
This is the answer to "update the graph after code changes for any harness" - it fires
for any tool or human that commits, so there is no per-harness wiring. Install it per
repo, alongside enabling graphify:

```powershell
graphify hook install     # installs ONLY the post-commit + post-checkout hooks
graphify hook status
graphify hook uninstall
```

Behavior (read before enabling):

- **Post-commit**: re-extracts only the changed code files in the BACKGROUND (`git
  commit` returns immediately), **AST-only, no LLM, no API cost**. Skips during
  rebase/merge/cherry-pick. Escape hatch `GRAPHIFY_SKIP_HOOK=1`; timeout via
  `GRAPHIFY_REBUILD_TIMEOUT` (default 600s).
- **Post-checkout**: full code rebuild on branch switch (only if `graphify-out/` exists).
- **It does NOT create or amend a commit.** The refreshed `graphify-out/` lands as an
  uncommitted working-tree change, and the hook explicitly skips when only
  `graphify-out/` changed (no rebuild loop). The committed artifacts (`graph.json`,
  `GRAPH_REPORT.md`, `graph.html`) therefore trail by one commit - you pick them up in
  your next commit. The ignored transients (per the `.gitignore` split above) are just
  refreshed locally. Do not gitignore the whole `graphify-out/` folder.
- The hooks live in `.git/hooks/` (or `core.hooksPath` / Husky's `.husky/`), which git
  never tracks - so they do NOT leak into apps scaffolded from a template repo.

### Optional: union-merge driver for a committed graph.json

`graphify hook install` does NOT wire the merge driver (despite what `graphify --help`
implies - that text is out of sync). It is a SEPARATE, manual, per-repo step, and only
matters once you actually commit `graph.json` and branches diverge on it. Without it, a
merge that touches `graph.json` on both sides produces ordinary conflict markers. To wire
graphify's union-merge driver (run once per repo):

```powershell
# 1. Tell git which driver handles graph.json (committed; travels with the repo)
Add-Content graphify-out/.gitattributes 'graph.json merge=graphify'
# 2. Define the driver in THIS repo's .git/config (local, not committed)
git config merge.graphify.name "graphify union-merge for graph.json"
git config merge.graphify.driver "graphify merge-driver %O %A %B"
```

The `.gitattributes` entry is shared, but every clone must run step 2 once (git never
auto-runs a third-party merge driver - this is a deliberate git safety boundary). Until
both are set, the union-merge does not run. If you keep `graph.json` untracked, skip this
entirely.

**Scope gap**: the hook is CODE/AST only. It does NOT refresh the semantic/doc layer
(`.instructions/`, `.scaffold/`, `docs/*.md`). Keep refreshing that with a full
`graphify .` at the phase boundaries below. For a structure-only repo the hook alone
keeps the graph current.

## Phase timing for scaffolded apps

Build/refresh the graph at phase boundaries, not continuously, to avoid churn during
the volatile Phase 4-5 window where code lands and artifacts get superseded:

- After Phase 1 artifacts exist, run `graphify .` (full layer) if graphify was enabled.
- After Phase 4 (`dotnet build` green, `contractsScaffolded: true`), run `graphify update .`.
- After a Phase 5 sub-phase gate passes, run `graphify update .`.

Drift rule (per START-AI.md, Phase-1 Artifact Lifecycle Rule, and
support/OPERATIONS.md Mid-Session Rollback Protocol): when artifact and code
disagree, code wins - fix the artifact, then re-extract the affected slice.
