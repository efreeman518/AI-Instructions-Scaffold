# AI Harness Entry (GitHub Copilot)

Project-memory entrypoint for this repository. Do not auto-activate the scaffold
workflow for ordinary repository work - normal coding, review, docs, and
maintenance use regular project context only.

## Scaffold workflows

- Add an entity/feature slice to an existing scaffolded app: select the `vertical-slice` agent.
- Full scaffold, brownfield adopt, or resuming an in-progress scaffold phase: load `.instructions/START-AI.md` (or select the `dotnet-scaffold` / `scaffold-adopt` agent). Scoped agents live in [.github/agents/](agents/).
- Treat installed `.instructions/` files as read-only during scaffold work. Record instruction feedback in `.scaffold/INSTRUCTION-GAPS.md`.
- Working in the instruction repository itself: see [README.md](../README.md) for maintenance context and author-side validation.

## Context graph (graphify)

These rules are conditional - they activate only when `graphify-out/graph.json`
exists in the repo, and are inert otherwise.

- For codebase questions (architecture, structure, where/what/how things relate), run `graphify query "<question>"` before grepping or reading raw files. Use `graphify path "<A>" "<B>"` for relationships and `graphify explain "<concept>"` for a focused concept.
- If `graphify-out/wiki/index.md` exists, use it for broad navigation instead of browsing source.
- After modifying code, run `graphify update .` to keep the graph current.
- No API key needed inside a coding-agent session - the harness model performs graphify's extraction.
