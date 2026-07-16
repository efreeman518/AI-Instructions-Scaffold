# Instruction-Set Maintenance - Periodic SSOT / Drift Audit (run manually)

**Primary trigger: run this by hand after any significant instruction refactor** - any change that moved,
merged, split, or reworded guidance across multiple files. Run it otherwise periodically too (before cutting a
release, whenever a "broken until X" deviation is added, or just every so often). There is no schedule.
Maintenance-only doc - lives in `maintenance/`, **not** copied by
`scripts/install-to-project.py`, so it never ships into scaffolded apps. (Same reason it is not linked from
`README.md`/`AGENTS.md`: those are installed, and a link to this file would dangle in every target app.)

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
    "machine capacity, not a contract failure": "skills/ai-integration.md",  # capacity-timeout is Inconclusive, not Fail; keeps the old "timeout -> Fail" wording from drifting back
    "before Aspire graph creation": "skills/ai-integration.md",  # Azure optional-provider eligibility is checked before boot; missing config is Inconclusive
    "public static IHostApplicationBuilder AddServiceDefaults(": "patterns/infrastructure-wiring.md",  # ServiceDefaults method body; hosts call AddServiceDefaults() but only the owner defines it
    "builder.Services.AddOpenTelemetry().UseAzureMonitor()": "patterns/infrastructure-wiring.md",  # Azure Monitor export gate (ConfigureOpenTelemetry body); observability/iac/function-app point here, never restate the call-site
    "No direct App Insights integration in the worker": "skills/function-app.md",  # Aspire+Functions telemetry hazard (startup error + duplicate-request suppression); infrastructure-wiring points here
    "binds to the wrong overload and is a **compile break**": "skills/testing.md",  # EF FindAsync array-wrap+token rule inside the test cancellation-token discipline; templates point here
    "--severity info --verify-no-changes": "support/execution-gates.md",  # analyzer-cleanliness gate command; solution-structure/testing point here, never restate the command
    "AddFusionCache(settings.Name)": "skills/caching.md",  # FusionCache registration loop; infrastructure-wiring points here
    "Add{App}MigrationDbContexts": "support/data-persistence-advanced.md",  # migrator-local context registration; migration ownership owner - other files point, never restate the runner wiring
    "replica completion count": "support/data-persistence-advanced.md",  # Container Apps Job knobs live once with the migration owner; cicd.md carries the pipeline step and points here
    "public record DefaultRequest<T>": "ai/contract-scaffolding.md",  # wrapper shape + Item member name live at the Phase-4 generation point; ef-packages-reference App-Level table points here
    "Nullable object must have a value": "skills/multi-tenant.md",  # lifted-nullable hand-written tenant filter rule; repository/template files show the guard-flag pattern instead
    "Descriptor removal no-ops when a registration is absent": "templates/test-templates-endpoint.md",  # EfWebApplicationFactoryBase behavior narrative lives with the adapter shape; other files point
    "primary no-crash oracle": "skills/testing-quality.md",  # Uno/Skia mobile oracle + assertion doctrine; templates point to the section, never restate it
    "waitForIdleTimeout": "skills/testing-quality.md",  # UiAutomator2 canvas-app settings live with the mobile doctrine
    "emulator booting visibly": "templates/local-test-stack-template.md",  # run-mobile-tests.ps1 runner mechanics (probe, SDK discovery, visible cold-boot, scoped retry)
    "StartMobileSession": "templates/test-templates-quality.md",  # MobileTestHelpers contract; the doctrine file points here for the helper shape
    "Two separate passing runs": "support/execution-gates.md",  # canonical mobile completion gate (visible mobile pass, then non-load exit 0); other files point
    "If another file disagrees on validation gates or commands, this file wins": "support/execution-gates.md",  # the gates-file SSOT authority declaration; no other file may claim gate authority
    "If you did not run it, it is not green": "support/execution-gates.md",  # verification-evidence rule (anti-false-green); others point, never restate
    "Fix warnings at the source - never hide them": "support/execution-gates.md",  # compiler-warning policy canonical wording
    "Primary-actor vertical slice runs end-to-end with seeded data": "support/final-scaffold-checklist.md",  # final acceptance owner for the GR-11 primary-flow proof
    "public static class {Entity}Endpoints": "templates/endpoint-template.md",  # generated service-style endpoint shape; api.md owns host policy
    "internal class {Entity}Service(": "templates/service-template.md",  # generated application-service shape; application-layer.md owns orchestration policy
    "public class {Entity}RepositoryTrxn({Project}DbContextTrxn dbContext)": "templates/repository-template.md",  # generated repository shape; data-persistence.md owns persistence policy
    "internal sealed class {Agent}AgentService : I{Agent}Agent": "templates/agent-template.md",  # code-hosted agent shape; ai-integration.md owns provider and selection policy
    "internal sealed class {Project}SearchService : I{Project}SearchService": "templates/ai-search-template.md",  # AI Search generated shape; ai-integration.md owns capability policy
    "Start every Phase 5 sub-phase with:": "support/prompt-catalog.md",  # generic prompts live once; MVS carries profile overlays only
    "dotnet build src/UI/{Project}.Uno/{Project}.Uno.csproj -p:TargetFrameworkOverride=$(LatestStableTfm)-ios --no-restore -m:1": "support/execution-gates.md",  # enabled-target Uno validation commands; skills retain project policy and hazards
    "public record DefaultResponse<T>": "ai/contract-scaffolding.md",  # Phase-4 response wrapper shape; sibling of DefaultRequest<T>, templates re-emit it
    "HeaderPropagationValues.Headers not initialized": "patterns/infrastructure-wiring.md",  # runtime error anchoring the "no AddHeaderPropagation in ServiceDefaults" rule; drifts when the body is re-copied
    "intentionally blocked to force use of the concurrency-safe path": "skills/data-persistence.md",  # SaveChangesAsync 1-param NotImplementedException rule; NotImplementedException is a scan hotspot
    "Body was inferred but the method does not allow inferred body parameters": "skills/api.md",  # runtime failure behind the [FromServices] endpoint-param non-negotiable
    "NU1011": "skills/package-dependencies.md",  # CPM + floating-version restore-failure rule tied to the central-package-version mandate
    "10.9.1": "support/tech-design-diagrams.md",  # @mermaid-js/mermaid-cli pin for deterministic SVG render; volatile
    "1.12.1": "skills/ui-uno-platforms.md",  # Resizetizer WASM manifest-path workaround pin (drop when upstream fixes); volatile
    "Never rename a migration after it has been shared": "support/data-persistence-advanced.md",  # migration-immutability rule owned with the migration content
    "SKIP_ALWAYS_ENCRYPTED_SETUP": "support/data-persistence-advanced.md",  # Always Encrypted local-green gating + full mechanics live once here; interview/domain-spec point in by topic name only
    "4 GB swap": "support/troubleshooting.md",  # Aspire mesh container resource floor; operator-setup/testing point here without the number
    'AddSqlServer("sql", sqlPassword, port: isTesting ? null : 38433)': "patterns/infrastructure-wiring.md",  # Aspire Resource Wiring graph; quick-reference keeps a minimal correct stub and points here
    "This holds even for entities the scaffold contracts but does not activate": "templates/no-op-stub-template.md",  # no-op-stub never-throw rule; skills carry a "never-throw rule" pointer, never restate
    "ApplicationStyleResolver.Resolve(config[ApplicationStyleResolver.ConfigKey]": "templates/cqrs-endpoint-template.md",  # applicationStyle:switch route-mapping code shape; api.md points here
    "public class ScaffoldAuthHandler": "skills/identity-management.md",  # scaffold auth-toggle handler; api-host-wiring/data-layer/service+endpoint templates only reference it by name
    "ManagedIdentityCredential": "skills/ai-integration.md",  # production credential-preference rule; DefaultAzureCredential itself is a cross-cutting primitive, not canaried
    "Verified generated shapes": "ai/SKILL.md",  # GR-18 first-party DTO-read / constructor-read discipline; ai-integration.md carries only the AI-surface cite
    "Your mono runtime and class libraries are out of sync": "support/troubleshooting.md",  # WASM mono/class-lib mismatch symptom; ui-uno-platforms.md points here for the fix
    "so mesh coverage never duplicates infrastructure graphs": "skills/testing.md",  # one-AppHost-graph-per-mesh-run rule; test-templates-aspire.md + testing-quality.md point here, never restate
    "leftover manual snapshots": "support/context-tooling.md",  # graphify-out dated-snapshot cleanup rule; AGENTS.md (outside scan roots) carries only the concise end-of-session step + pointer
    "Pipeline order alone does not reject anonymous callers": "skills/gateway.md",  # forwarded-claims trust boundary lives with Gateway; API wiring points here
}
roots = ["skills", "patterns", "ai", "support", "schemas", "profiles", "templates"]
files = [p for r in roots for p in pathlib.Path(r).rglob("*.md")]
bad = False
for canary, owner in CANARIES.items():
    hits = [str(p).replace("\\", "/") for p in files if canary in p.read_text(encoding="utf-8")]
    if owner not in hits:
        bad = True
        print(f"DRIFT: '{canary}' is missing from owner {owner}")
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
4. **Templates own generated shape; the reference app proves it.** Keep one copyable implementation in the
   matching template and point to compiled `TaskFlow` paths ([support/reference-app.md](../support/reference-app.md))
   as evidence. Skills retain policy, hazards, and selection rules.
5. **Data/schema docs: values + pointer**, not a re-explanation of the narrative.
6. **Rationale stays selective.** Apply [Selective rationale](README.md#selective-rationale); do not replace
   duplication with boilerplate why text.

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

## Consolidated owner map

- Foundry lifecycle/provider guidance: [skills/ai-integration.md](../skills/ai-integration.md).
- AppHost graph, ServiceDefaults body, OpenTelemetry, and health wiring:
  [patterns/infrastructure-wiring.md](../patterns/infrastructure-wiring.md). Host files keep call sites only.
- FusionCache registration loop: [skills/caching.md](../skills/caching.md). Wiring files point to it.
- No-op implementation shape and never-throw hazard:
  [templates/no-op-stub-template.md](../templates/no-op-stub-template.md). Phase files keep mode policy.
- CQRS generated shapes: the `templates/cqrs-*-template.md` set. Skills keep route/validation policy.
- Scaffold/live auth toggle and `ScaffoldAuthHandler`:
  [skills/identity-management.md](../skills/identity-management.md).
- First-party DTO/property and constructor-shape verification: **GR-18** in
  [GROUND-RULES.md](../GROUND-RULES.md).
- Service-style endpoint, application service, repository, code-hosted agent, and AI Search generated shapes:
  their matching files under `templates/`. Skills keep policy and hazards.
- Composite final acceptance: [support/final-scaffold-checklist.md](../support/final-scaffold-checklist.md).
  `support/execution-gates.md` owns per-sub-phase commands; `support/HANDOFF.md` records evidence.
- Generic phase prompts: [support/prompt-catalog.md](../support/prompt-catalog.md). MVS keeps only API-only,
  single-entity overlays.
- Uno enabled-target validation commands: [support/execution-gates.md](../support/execution-gates.md) section 5c.
  Uno skills keep project policy, asset-graph hazards, and diagnostics.

Credential construction remains trust-boundary-specific across AI, Gateway, secrets, and migration consumers;
forcing every `DefaultAzureCredential` or `ManagedIdentityCredential` mention into identity management would hide
different production constraints rather than remove competing authority.

## Current work queue

No ranked hotspot remains from the 2026-07-13 audit. Keep step 3 mandatory and add a queue item only when a scan
finds competing full owners or volatile facts copied across files. Phase-local call sites and cross-phase minimum
guidance are intentional when fresh-session usability requires them.
