# AI Scaffold Entry

This is a harness-neutral entrypoint for CLI agents that read root `AGENTS.md`
files (Codex CLI, GitHub Copilot CLI, and other CLI agents using the same
discovery convention).

GitHub Copilot in VS Code uses `.github/copilot-instructions.md` and the
scoped agents in `.github/agents/` instead - see [README.md](README.md) for
the harness routing table.

Do not activate the scaffold workflow automatically for ordinary repository
work.

## Scaffold Trigger

Run scaffold instructions only when the user explicitly asks to:

- scaffold a new .NET app or service;
- continue an existing scaffold phase;
- add a scaffolded vertical slice/entity;
- adopt the scaffold onto an existing C#/.NET solution (load `.instructions/ai/adopt-codebase.md` instead of running Phase 1).

Phase 1 is the universal core (stack-agnostic). Phases 2-5 run under the C#/.NET/Azure profile - see `profiles/csharp-dotnet-azure.md` (this repo) or `.instructions/profiles/csharp-dotnet-azure.md` (installed apps). Vertical-slice and brownfield-adoption flows are profile-bound.

## Scaffold Boot

1. If this file is installed in a target app repository, load `.instructions/START-AI.md`.
2. If working in the instruction repository itself, load `START-AI.md`.
3. Follow the phase router and one-phase-per-session rule.
4. Treat installed `.instructions/` files in code repositories as read-only. Do not modify them during scaffold work.
5. Record scaffold gaps in `.scaffold/INSTRUCTION-GAPS.md` (create the `.scaffold/` directory at project root if absent).

For normal coding, review, docs, or maintenance tasks, ignore scaffold phase
rules and use regular project context only.
