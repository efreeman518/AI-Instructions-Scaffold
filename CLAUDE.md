## AI Harness Entry (Claude Code)

Do not auto-activate the scaffold workflow for ordinary work - normal coding,
review, docs, and maintenance use regular project context.

### Scaffold workflows

- Add an entity/feature slice to an existing scaffolded app: `/vertical-slice`.
- Full scaffold, brownfield adopt, or resuming an in-progress scaffold phase: load `.instructions/START-AI.md` (or run `/scaffold` / `/scaffold-adopt`). Scoped commands live in `.claude/commands/`.
- Treat installed `.instructions/` files as read-only during scaffold work; record gaps in `.scaffold/INSTRUCTION-GAPS.md`.

### Context graph (graphify)

Conditional - active only when `graphify-out/graph.json` exists, inert otherwise.

- For codebase questions (architecture, where/what/how things relate), run `graphify query "<question>"` before grepping or reading raw files; use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for a concept.
- If `graphify-out/wiki/index.md` exists, use it for broad navigation.
- After modifying code, run `graphify update .` to keep the graph current.
