## AI Harness Entry (GitHub Copilot)

Agent instructions live in [AGENTS.md](../AGENTS.md) - current Copilot agent
surfaces read root `AGENTS.md` natively; treat it as the single source of
truth. This file remains only as repository-wide custom instructions for older
Copilot clients and non-agent surfaces (Chat, code review).

- Scoped scaffold agents live in [.github/agents/](agents/): `dotnet-scaffold`, `vertical-slice`, `scaffold-adopt`.
- Do not auto-activate the scaffold workflow for ordinary work - normal coding, review, docs, and maintenance use regular project context.
