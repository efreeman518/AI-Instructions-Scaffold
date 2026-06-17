# Multi-Agent Orchestration (optional)

Opt-in, harness-gated guidance for running parts of a phase across multiple agents. It changes **how** a single phase executes; it never changes the phase sequence or the human review gates.

> **Most harnesses cannot do this, and that is fine.** Spawning subagents, and isolating their writes in git worktrees, is a capability of some harnesses (e.g. Claude Code) and absent or limited in others (Copilot exposes a single `agent` tool; CLI agents that read `AGENTS.md` and generic assistants usually have none). If your harness cannot spawn subagents, ignore this file and run every phase sequentially - the workflow is designed to work that way first. Nothing here is ever a required step.

## What does not change

- **Phases stay strictly ordered and human-gated.** 1 -> 2 -> 3 -> 4 -> 5a..5e. Each phase ends in a developer review gate. Multi-agent work never crosses a phase boundary, because phase N consumes phase N-1's reviewed artifact.
- **State lives in files, not in an agent.** `HANDOFF.md` + `.scaffold/*` remain the single source of truth. There is no long-lived super-orchestrator holding state in context across phases. The "orchestrator" is just the current phase's main session, re-instantiated each phase from the files.
- **One agent owns all shared writes.** The orchestrator is the only writer of `HANDOFF.md`, `.scaffold/*`, and shared wiring (`RegisterServices`, the two `DbContext`s, `Directory.Packages.props`, the Aspire AppHost). Subagents return structured results; they do not edit the blackboard.

## The model: orchestrator + work-item workers + independent reviewer

The developer-facing agent is the orchestrator. It dispatches subagents, collects their results as tool output, performs the merge and the gate itself, then updates `HANDOFF.md` and closes. Subagents never talk to the developer.

Decompose work **by independent work-item (fan-out), not by role.**

- **Fan-out by work-item** = N workers, same job, different data (one per host, one per entity, one per slice). This is the parallelism that pays.
- **Role pipelines** (separate code agent / test agent / review agent) mostly do not fit here. The specialization is already the *phase + its load-set*, not a persona, and every role handoff pays a context re-brief tax. The one role split that helps is an **independent reviewer** (below).

| Role | Separate agent? | Why |
|---|---|---|
| Orchestrator | Yes - it is the existing phase session | Owns the developer relationship, gate authority, and every shared write |
| Worker (per host / entity / slice) | Yes, by work-item | Independent units; each does its *whole* slice |
| Reviewer / verifier | Yes | Independence is the point: a fresh agent that did not write the code is a better adversary for ground-rule and architecture-test compliance. Read-only, so no write conflict |
| Separate "test agent" vs "code agent" | No | The workflow is TDD ([../ai/tdd-protocol.md](../ai/tdd-protocol.md)). The same reasoning writes the failing test and makes it pass; splitting them breaks the red-green loop and the shared understanding of intent |

## The precondition: fan out only the leaves, after the shared core is frozen

You can only parallelize the **leaves** of the dependency graph at a given level. Any node the parallel workers share must be **complete and frozen first**, then treated as read-only. Before fanning out, the orchestrator's job is not "split into hosts" - it is "complete every shared dependency, freeze it, then dispatch the consumers that only read it."

The phase ordering already encodes the coarse barrier - the shared backend the UIs consume is built before the host layer:

- shared base types (`EntityBase`, `DbContextBase`, `DomainResult`, `IRepositoryBase`) - from packages/feed, fixed before Phase 4;
- contracts / DTOs / interfaces - Phase 4;
- domain model + repositories - Phase 5a;
- application services + the API endpoints UIs call - Phase 5b.

That is *why* Phase 5c (optional hosts) is the natural fan-out phase and 5a/5b are not.

There is also a **finer barrier inside the host layer**: anything shared *across* the target hosts must be built once before fan-out, or parallel workers will each invent and collide on it -

- a shared contracts assembly or generated/typed API client the UIs reference,
- a shared component / design-token / theme library (if admin and public share UI primitives),
- common client-side wiring (the HTTP/auth client setup pattern they reuse).

The orchestrator completes and freezes these, then dispatches the per-host workers read-only.

### Two consequences

- **Stub shared dependencies rather than block on them.** Identity/auth is Phase 5e - *after* 5c - so UIs are scaffolded against an auth stub and 5e wires the real provider. This is the external-dependency-mode pattern (GR-05/GR-06) applied to ordering: freeze a placeholder so consumers can fan out, fill it in later.
- **A fan-out unit is an independent deployable host, not a target or route of one.** Uno "browser and mobile" is multi-*targeting* within a single project (one head, many TFMs) - which is why Uno is already one dedicated session, not splittable. Admin-vs-public is a fan-out unit only if they are separate deployables; if they are role-gated routes in one app, they are not.

## Worked example: Phase 5c with three enabled hosts

1. Orchestrator (the phase session, talking to the developer) reads `HANDOFF.md` + `.scaffold/resource-implementation.yaml`, confirms the 5a/5b gates passed, and enumerates the enabled hosts.
2. It completes and freezes any artifact shared across those hosts (shared contracts/client, shared component lib, common client wiring).
3. It fans out **one worker per host**, each in its own git worktree, each scaffolding *and* validating its host standalone (TDD where applicable), returning a structured status. Workers read the frozen shared layer; they write only their own host's disjoint files.
4. Workers finish; the orchestrator merges, performs the single serialized Aspire AppHost registration pass itself, and runs the mesh gate (`dotnet run` + health) per [execution-gates.md](execution-gates.md).
5. Optionally, it fans out an independent **reviewer** over the merged result for ground-rule / architecture-test compliance - read-only.
6. Orchestrator updates `hostGates` in `HANDOFF.md`, records gate evidence per [execution-gates.md](execution-gates.md) section Verification Evidence Rule, and closes. The next phase is a fresh orchestrator.

## Pre-dispatch checklist

Before the orchestrator spawns any worker:

- [ ] The shared backend phases for this work (5a/5b) passed their gates.
- [ ] Every artifact shared *across* the target work-items is complete and frozen (shared contracts/client, shared component/theme library, common wiring).
- [ ] Each fan-out unit is an independent deployable host (or a genuinely independent entity/slice), not a target or route within one host.
- [ ] Workers are constrained to disjoint write paths; all shared writes are reserved for the orchestrator's serialized merge step.
- [ ] Worker writes are isolated (git worktree per worker) when the harness supports it.

## When it is not worth it

For a `lite` / `api-only` app, or a slice with 2-3 entities and one host, the orchestration and merge overhead exceeds the wall-clock saving - run sequentially. Fan-out pays off at scale: many entities, several independent optional hosts, or a batch of independent vertical slices. The scaffold is a one-time, high-leverage effort; never trade output confidence for parallelism. Read-only review/research fan-out is the safe default that adds value without write-conflict risk at any size.
