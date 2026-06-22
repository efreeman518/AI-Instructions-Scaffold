# Instruction-Set Maintenance - Periodic SSOT / Drift Audit (run manually)

**Primary trigger: run this by hand after any significant instruction refactor** - any change that moved,
merged, split, or reworded guidance across multiple files. Run it otherwise periodically too (before cutting a
release, whenever a "broken until X" deviation is added, or just every so often). There is no schedule.
Maintenance-only doc - lives in `maintenance/`, **not** copied by
`scripts/install-to-project.py`, so it never ships into scaffolded apps. (Same reason it is not linked from
`README.md`/`CLAUDE.md`: those are installed, and a link to this file would dangle in every target app.)

## Why this exists

Adding the Foundry "local path temporarily broken" guidance took four correction rounds. Root cause was
**duplication**: the same volatile facts (RunAsFoundryLocal broken, version pins, dotnet/aspire#12750, the
SDK-direct workaround, migration steps) were restated across ~7 files, so every reframe meant editing all of
them and each round missed spots. Two aggravators: volatile and stable content interleaved, and docs embedding
un-compiled copyable code that drifts from reality. This audit keeps the set single-source-of-truth (SSOT) so
the next change touches one owner, not seven.

The Foundry topic has already been consolidated (owner: [skills/ai-integration.md](../skills/ai-integration.md))
and is the worked example for the procedure below.

## The manual procedure

Run from the repo root. One topic per pass; do not batch unrelated topics.

### 1. Structural check (fast, always first)

```bash
py -3 scripts/validate-instructions.py
```
Must print "all checks passed" (links, section anchors, Phase 5 load-set, template coverage, golden-path
schemas). Fix any failure before going further.

### 2. SSOT canary check (regression tripwire)

Each canary is a distinctive string that must live in exactly **one** owner file. If a consolidated fact has
crept back into another file, a canary shows up twice. Paste and run:

```bash
py -3 - <<'PY'
import pathlib
# canary substring -> the single file allowed to contain it
CANARIES = {
    "13.4.5-preview": "skills/ai-integration.md",
    "StartWebServiceAsync": "skills/ai-integration.md",
    "Microsoft.Extensions.AI.OpenAI": "skills/ai-integration.md",
    "Microsoft.AI.Foundry.Local.Core": "skills/ai-integration.md",  # native transitive payload; RID-bound test lane needs its own direct ref
    'AiProviderInfo("local")': "skills/ai-integration.md",  # availability-driven provider signal; pointers say "AiProviderInfo" only
    'AiProviderInfo("stub")': "skills/ai-integration.md",  # opt-in dev-stub content tier; pointers say "AiProviderInfo" / provider "stub" only
}
roots = ["skills", "patterns", "ai", "support", "schemas", "profiles", "templates"]
files = [p for r in roots for p in pathlib.Path(r).rglob("*.md")]
bad = False
for canary, owner in CANARIES.items():
    hits = [str(p).replace("\\", "/") for p in files if canary in p.read_text(encoding="utf-8")]
    extra = [h for h in hits if h != owner]
    if extra:
        bad = True
        print(f"DRIFT: '{canary}' should live only in {owner}; also in: {', '.join(extra)}")
print("canary check: " + ("FAILED - consolidate to owner, leave a pointer" if bad else "ok"))
PY
```
**Maintain the canary list:** every time you consolidate a topic (step 5), add one distinctive string from
its owner here so future drift is caught. Pick strings that are intrinsic to the topic and unlikely to be
quoted in pointers (a version like `13.4.5-preview`, an API name like `StartWebServiceAsync`, a workaround-only
package). Do **not** use strings the pointers legitimately repeat (e.g. `dotnet/aspire#12750`).

### 3. Deep duplication scan (judgment)

Look for the same snippet/rule/explanation in 2+ files. Grep for distinctive method names and phrases, then
read the hits:

```bash
rtk grep -rl "AddFusionCache\|AddServiceDefaults\|AddSqlServer(\|ScaffoldAuthHandler\|NotImplementedException" \
  skills/ patterns/ support/ templates/ ai/
```
For each cluster, ask: is this a concept restated (consolidate) or a legitimate per-phase minimum (leave, add
a pointer)? Use the backlog below as the standing work queue.

### 4. Triage with the SSOT principles

1. **One canonical owner per concept.** Name it in the doc ("canonical owner: X").
2. **Volatile facts live once.** Version pins, known issues, migration steps go in the owner only; everyone
   else carries a one-line pointer, never a restatement.
3. **Phase-scoped files keep only their phase's minimum** inline; depth lives in the owner.
4. **Reference app is the canonical code.** Prefer pointing to compiled `TaskFlow` paths
   ([support/reference-app.md](../support/reference-app.md)) over embedding large copyable snippets that cannot be
   compile-checked.
5. **Data/schema docs: values + pointer**, not a re-explanation of the narrative.

### 5. Fix one topic

Pick the owner consistent with the authority hierarchy (GR-12: `START-AI.md` -> `support/execution-gates.md`
-> `ai/SKILL.md` -> skills -> templates). Move the volatile/duplicated content into the owner; replace the
other copies with a one-line pointer that respects phase boundaries (see constraints). Add a canary (step 2).

### 6. Verify

```bash
py -3 scripts/validate-instructions.py
py -3 scripts/install-to-project.py --target <a-scaffolded-app> --verify
py -3 <a-scaffolded-app>/.instructions/scripts/validate-instructions.py
```
Then re-run step 2's canary check. Grep the topic: the volatile fact should appear in one owner; all others
are pointers.

## Hard constraints (do not violate)

- **Per-phase, fresh-session loading.** `ai/START-AI.md` + `ai/SKILL.md` load only the current phase's files.
  A cross-file pointer is safe only when both files load in the **same phase**; across phases keep each phase's
  minimum inline and point to the owner for depth. (Pilot: `aspire.md` -> `infrastructure-wiring.md` is safe,
  both Phase 5b; `infrastructure-wiring.md` (5b) keeps its wiring but points to `ai-integration.md` (5e) only
  for diagnosis/migration that 5b does not need at wiring time.)
- **Validator must pass**: link targets exist; **one link per target per line**; `[label](file.md) section
  <Name>` needs a real heading; Phase 5 tokens in `ai/SKILL.md` resolve; every `templates/*.md` stays
  reachable from the Phase 5 table; golden-path YAML stays schema-valid; no whole-file code fences.
- **No mid-scaffold edits to installed `.instructions/`** (GR-07): patch source here, then reinstall.

## Backlog - known hotspots (work queue, ranked by frequency x volatility)

Done: **Foundry** (owner `skills/ai-integration.md`).

1. **Aspire AppHost resource wiring** (HIGH) - SQL/Redis/project refs duplicated across
   [patterns/infrastructure-wiring.md](../patterns/infrastructure-wiring.md) and [skills/aspire.md](../skills/aspire.md)
   (also `support/quick-reference.md`, `support/troubleshooting.md`). Proposed owner:
   `patterns/infrastructure-wiring.md`; `aspire.md` keeps its mode/decision tables and points (same 5b).
2. **AddServiceDefaults / OpenTelemetry / health checks** (HIGH freq) - `infrastructure-wiring.md`,
   [patterns/api-host-wiring.md](../patterns/api-host-wiring.md), `skills/api.md`, `skills/background-services.md`.
   Owner: `patterns/infrastructure-wiring.md`.
3. **FusionCache multi-cache config loop** (~60 lines) - `infrastructure-wiring.md` and
   [skills/caching.md](../skills/caching.md). Owner: decide concept (`caching.md`) vs wiring
   (`infrastructure-wiring.md`) - see Open decisions.
4. **No-op stub / conditional-DI rule** (15+ files) - owner [templates/no-op-stub-template.md](../templates/no-op-stub-template.md);
   replace restatements with a `GR`-style one-liner + pointer.
5. **CQRS handler/validation/endpoint boilerplate** - owner: the `templates/cqrs-*-template.md` set; skills and
   `ai/contract-scaffolding.md` point.
6. **Identity auth toggle (scaffold vs live)** - owner [skills/identity-management.md](../skills/identity-management.md)
   (verify `skills/gateway.md`, `patterns/api-host-wiring.md` refs first).
7. **DefaultAzureCredential / ManagedIdentityCredential** one-liner - owner `skills/identity-management.md`
   (verify first).
8. **DTO-read / constructor-read non-negotiables** - promote to a `GR-NN` rule in
   [GROUND-RULES.md](../GROUND-RULES.md), cite by id elsewhere.

Work top-down, one per pass. Reassess after 1-3: if drift recurrences drop, the lighter items may not be worth
the churn.

## Open decisions (resolve before the relevant pass)

- **Wiring authority vs concept owner** for items 1-3: do `patterns/*` own shared wiring snippets, or do the
  concept `skills/*`? Pick one convention and apply consistently.
- **How far to push reference-app-as-code:** thin embedded snippets to fragments + TaskFlow pointers, or keep
  full snippets?
