# misc - Operator Tooling and Machine Setup

Everything in this folder is **optional** machine-side tooling and dev-environment setup. It
is a separate concern from the scaffold instruction set (the root [README.md](../README.md)
and the `.instructions/` payload that gets installed into apps): nothing here is required to
scaffold or run an application. These are the scripts and runbooks an operator uses to set up
a developer workstation and to give AI coding agents cheaper, longer sessions.

None of this is distributed into scaffolded apps. It is environment/machine setup, run once
per machine (or per repo where noted), not part of any app's payload.

Two clusters:

- **AI context tooling** (rtk, headroom, graphify) - cut token cost in AI coding sessions.
- **Machine setup and maintenance** - Python, WSL/Docker, Defender, scheduled maintenance.

---

## AI context tooling (rtk, headroom, graphify)

Three tools, no overlap. They stack: graphify reduces *what* gets loaded, then headroom and
rtk compress *what still does*.

- **[rtk](https://github.com/rtk-ai/rtk)** - compresses CLI command output (the shell layer).
  Enforced via the `rtk` Bash prefix rule in your global agent config.
- **[headroom](https://github.com/chopratejas/headroom)** - compresses prompt inputs (tool
  output, history) through a local proxy at `http://127.0.0.1:8787` before requests reach the
  model.
- **[graphify](https://github.com/safishamsi/graphify)** - builds a knowledge graph of a repo
  so an agent can query relationships (call flow, spec-to-code links, impact radius) instead
  of grepping and reading raw files.

### Operating model: three actions

Keep these three straight and there is almost nothing else to learn.

| Action | When | What it does |
|--------|------|--------------|
| Run [`update-python-and-context-tools.ps1`](update-python-and-context-tools.ps1) | periodically, per machine | Installs/updates rtk + headroom + the graphify CLI and wires ALL global config: rtk + headroom always-on in every harness, plus graphify's GLOBAL conditional steering (the `/graphify` skill, a "graphify graph usage" block in `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`, and a PreToolUse grep hook in `~/.claude/settings.json`). Idempotent; safe to re-run. Restart your harnesses afterward so they pick up the new `setx` env vars. |
| Paste [`apply-graphify-to-repo.txt`](apply-graphify-to-repo.txt) into a repo | once per repo that warrants a graph (opt-in) | Measures the repo, picks the graphify layer, and builds `graphify-out/graph.json`. The only per-repo step. |
| Run [`strip-graphify-repo-wiring.ps1`](strip-graphify-repo-wiring.ps1) in a repo | as needed | Removes graphify wiring that leaked into a repo's tracked files (so it never rides into template-scaffolded apps); leaves the global steering and the built graph intact. Refuses to run against a machine-global config root. |

### Always-on (rtk, headroom) vs opt-in (graphify)

**rtk and headroom are always-on and environment-global.** The installer wires both into
every harness, so they apply to every repo and session with no per-repo action. They are
universal and carry no per-repo cost or decision: rtk's command-output compression is
lossless, and headroom's prompt-input compression is lossy by default but bypassable when
exactness matters. Their rules are NOT distributed in any app's payload; they live in
your global agent config, written by `rtk init -g` and `headroom init -g`. Manual install,
per-agent wiring, telemetry, and troubleshooting are in
[`context-optimize.md`](context-optimize.md).

**graphify is opt-in per repo.** A graph carries per-repo cost (build time, model spend on
the doc layer for a full build, an artifact to keep current) and a per-repo choice of layer,
so auto-building everywhere would waste effort. The graph engages in a repo only where you
explicitly initialize it (the marker is `graphify-out/graph.json`).

### graphify: global steering vs per-repo graph

graphify splits cleanly:

**Global half (the installer, machine-wide, idempotent):**

1. Install the CLI: `uv tool install graphifyy` (`graphifyy` package, `graphify` command).
2. Install the `/graphify` skill into each harness' global config.
3. Wire CONDITIONAL steering into each harness' global config (a "graphify graph usage"
   block + a Claude grep hook). All of it is GUARDED on `graphify-out/graph.json` existing in
   the working directory, so it stays inert in every repo until that repo builds a graph.

**Per-repo half (opt-in; paste `apply-graphify-to-repo.txt`):**

4. Build the graph from the repo root: `graphify . --wiki` (full layer - also emits the
   agent-crawlable wiki at `graphify-out/wiki/index.md` that the global steering points agents
   to) or the structure-only path (`graphify . --no-cluster`, no wiki).
5. Optionally enable repo harnesses (`graphify <h> install --project`) - but NOT in a
   template/scaffold repo, where committed wiring would leak into generated apps. The global
   conditional steering already covers any repo once its graph exists, so this is rarely
   needed.
6. Recommended: `graphify hook install` adds post-commit/post-checkout git hooks so code
   changes auto-update the graph (AST-only, background, no API cost, no extra commit; untracked
   in `.git/hooks/`, so it does not leak into scaffolded apps). It refreshes the code/AST layer
   only and does NOT regenerate the wiki - run `graphify export wiki` for a cheap wiki refresh
   (renders from `graph.json`, no model cost), and a full `graphify . --wiki` at phase
   boundaries for the semantic/doc layer.

The per-repo **layer choice** (structure-only vs full) and **phase-boundary build timing**
are documented in [`../support/context-tooling.md`](../support/context-tooling.md), reached
per repo via a pointer in [`../START-AI.md`](../START-AI.md).

### Keeping graphify wiring global, not committed

graphify's per-harness installers (`graphify claude install`, `graphify vscode install`,
etc.) write the CURRENT repo's tracked files and emit an unconditional block - they are meant
for ordinary app repos, not for global setup and not for a template. The installer therefore
hand-writes the GLOBAL conditional steering itself and never touches a repo. If graphify
wiring does end up committed somewhere (`CLAUDE.md`, `AGENTS.md`,
`.github/copilot-instructions.md`, `.claude/settings.json`, `.codex/hooks.json`), run
[`strip-graphify-repo-wiring.ps1`](strip-graphify-repo-wiring.ps1) from the repo root. It
snapshots and restores your machine-global config, so a stray `graphify uninstall` cannot
damage the global steering, and it preserves the built `graphify-out/` graph.

**Known gap - VS Code Copilot Chat.** It has no global instruction file, so its global
graphify steering lives in VS Code user `settings.json`
(`github.copilot.chat.codeGeneration.instructions`). The installer adds it only with the
`-ConfigureVsCodeGlobal` switch (the write JSON-normalizes that file); without the switch it
prints the exact entry to paste. The VS Code Copilot **extension** also cannot be routed
through headroom (it uses GitHub's proprietary endpoints); rtk command-rewrite for that
extension is per-repo via [`enable-rtk-copilot-project.ps1`](enable-rtk-copilot-project.ps1).

### Version policy

Reference the tools by command name; do not pin versions. The installer keeps rtk, headroom,
and graphify current. It does NOT install or update the harness binaries themselves (Claude
Code / Codex / Copilot CLIs, VS Code extensions, desktop apps) - they self-update, and a
machine may deliberately run only some of them. The installer configures whichever harnesses
are present and skips the rest.

---

## Machine setup and maintenance

Workstation setup and upkeep for .NET development. These are independent of the AI tooling
above; use what applies to your machine. Several require an elevated (Administrator) shell.

- [`clean-python.md`](clean-python.md) - get to one current Python usable from any repo,
  removing stale installs and broken launchers. The scaffold's short prereq check is
  [`../support/python-setup.md`](../support/python-setup.md).
- [`install-wsl-docker-podman.md`](install-wsl-docker-podman.md) - WSL2 + Docker Engine (and
  optionally Podman Desktop) for running .NET Aspire locally on Windows.
- [`Set-DevDefenderExclusions.ps1`](Set-DevDefenderExclusions.ps1) - Windows Defender path and
  process exclusions for .NET dev to cut build/restore/Docker CPU. Admin; safe to re-run.
- [`win-maint/`](win-maint/) - scheduled Windows maintenance:
  [`PC-Maintenance.ps1`](win-maint/PC-Maintenance.ps1) (Quick weekly / Deep monthly) and
  [`Setup-MaintenanceSchedule.ps1`](win-maint/Setup-MaintenanceSchedule.ps1) (installs the two
  scheduled tasks). Admin.

---

## File index

| File | Type | Cluster | Purpose |
|------|------|---------|---------|
| [`update-python-and-context-tools.ps1`](update-python-and-context-tools.ps1) | script | AI tooling | Global installer/updater for rtk + headroom + graphify CLI, and all global harness wiring. Run periodically. |
| [`apply-graphify-to-repo.txt`](apply-graphify-to-repo.txt) | prompt | AI tooling | Per-repo graphify enablement: measure the layer, build `graphify-out/graph.json`. |
| [`strip-graphify-repo-wiring.ps1`](strip-graphify-repo-wiring.ps1) | script | AI tooling | Strip graphify wiring that leaked into a repo's tracked files. |
| [`enable-rtk-copilot-project.ps1`](enable-rtk-copilot-project.ps1) | script | AI tooling | Per-repo rtk command-rewrite for the VS Code Copilot extension (no global Copilot location exists). |
| [`context-optimize.md`](context-optimize.md) | runbook | AI tooling | rtk + headroom deep reference: manual install, per-agent wiring, telemetry, troubleshooting. |
| [`clean-python.md`](clean-python.md) | runbook | Machine setup | Windows Python cleanup to one current, repo-independent runtime. |
| [`install-wsl-docker-podman.md`](install-wsl-docker-podman.md) | runbook | Machine setup | WSL2 + Docker Engine (+ Podman) for .NET Aspire on Windows. |
| [`Set-DevDefenderExclusions.ps1`](Set-DevDefenderExclusions.ps1) | script (admin) | Machine setup | Defender path/process exclusions for .NET dev. |
| [`win-maint/PC-Maintenance.ps1`](win-maint/PC-Maintenance.ps1) | script (admin) | Machine setup | Quick (weekly) / Deep (monthly) Windows maintenance. |
| [`win-maint/Setup-MaintenanceSchedule.ps1`](win-maint/Setup-MaintenanceSchedule.ps1) | script (admin) | Machine setup | Install the PC-Maintenance scheduled tasks. |
