# AI Harness Entry (CLI agents)

Harness-neutral entrypoint for CLI agents that read root `AGENTS.md` files
(Codex CLI, GitHub Copilot CLI, and other CLI agents using the same discovery
convention). GitHub Copilot in VS Code uses `.github/copilot-instructions.md`
and the scoped agents in `.github/agents/` instead - see [README.md](README.md)
for the harness routing table.

Do not auto-activate the scaffold workflow for ordinary repository work. For
normal coding, review, docs, or maintenance, ignore scaffold phase rules and use
regular project context only.

## Scaffold workflows

- Add an entity/feature slice to an existing scaffolded app: load `.instructions/support/vertical-slice-checklist.md`.
- Full scaffold, brownfield adopt, or resuming an in-progress scaffold phase: load `.instructions/START-AI.md`, follow the phase router and one-phase-per-session rule. (Brownfield adoption loads `.instructions/ai/adopt-codebase.md` in place of Phase 1.)
- Treat installed `.instructions/` files as read-only during scaffold work. Record gaps in `.scaffold/INSTRUCTION-GAPS.md` (create `.scaffold/` at project root if absent).
- Working in the instruction repository itself: load `START-AI.md`; see [README.md](README.md) for maintenance context.

## Context graph (graphify)

These rules are conditional - they activate only when `graphify-out/graph.json`
exists in the repo, and are inert otherwise.

- For codebase questions (architecture, structure, where/what/how things relate), run `graphify query "<question>"` before grepping or reading raw files. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for a focused concept.
- If `graphify-out/wiki/index.md` exists, use it for broad navigation instead of browsing source.
- After modifying code, run `graphify update .` to keep the graph current.
- No API key needed inside a coding-agent session - the harness model performs graphify's extraction.
