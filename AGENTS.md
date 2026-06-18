## AI Harness Entry (CLI agents)

Harness-neutral entrypoint for CLI agents that read root `AGENTS.md` files
(Codex CLI, GitHub Copilot CLI, and other CLI agents using the same discovery
convention). GitHub Copilot in VS Code uses `.github/copilot-instructions.md`
and the scoped agents in `.github/agents/` instead.

Do not auto-activate the scaffold workflow for ordinary work - normal coding,
review, docs, and maintenance use regular project context.

### Scaffold workflows

- Add an entity/feature slice to an existing scaffolded app: load `.instructions/support/vertical-slice-checklist.md`.
- Full scaffold, brownfield adopt, or resuming an in-progress scaffold phase: load `.instructions/START-AI.md`, follow the phase router and one-phase-per-session rule. (Brownfield adoption loads `.instructions/ai/adopt-codebase.md` in place of Phase 1.)
- Treat installed `.instructions/` files as read-only during scaffold work; record gaps in `.scaffold/INSTRUCTION-GAPS.md` (create `.scaffold/` at project root if absent).

### Context graph (graphify)

Conditional - active only when `graphify-out/graph.json` exists, inert otherwise.

- For codebase questions (architecture, where/what/how things relate), run `graphify query "<question>"` before grepping or reading raw files; use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for a concept.
- If `graphify-out/wiki/index.md` exists, use it for broad navigation.
- After modifying code, run `graphify update .` to keep the graph current.
