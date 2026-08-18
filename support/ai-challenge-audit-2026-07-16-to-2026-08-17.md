# ai-challenge hardening audit: 2026-07-16 through 2026-08-17

## Scope and method

- Source: `efreeman518/ai-challenge`, default branch `main`.
- Inclusive UTC window: `2026-07-16T00:00:00Z` through `2026-08-17T23:59:59Z`.
- Inventory: 433 commits reachable from `main`, 99 first-parent integration events, 63 pull requests merged to `main`, 36 direct first-parent commits after merge-commit subtraction, and 354 net-changed files.
- Pull requests, bodies, changed files, and inline review comments were queried with GitHub CLI. Local `git` history supplied reachability, first-parent ordering, and diffs.
- Pull request commits are represented once by their `main` integration event. Direct commits remain separate. Event 99 has a local timestamp on July 15 and a UTC timestamp inside the July 16 boundary.

Promotion required either a repeated failure pattern or one severe correctness, security, deployment, or blank-application failure.

Disposition codes:

- `P`: promoted into canonical instructions, templates, validation, or TaskFlow proof.
- `E`: important but already covered; audit used to verify or sharpen existing coverage.
- `A`: application-specific implementation; only its general lesson was considered.
- `N`: no reusable instruction impact.

## Integration-event ledger

| # | Integration event | Disposition | Reusable lesson or exclusion |
|---:|---|:---:|---|
| 1 | PR 69 `63cb7b2` popup blocked by `noopener` | P | Preserve a popup handle when callback coordination requires it. |
| 2 | PR 68 `054b4a5` local beta deploy script | P | Emergency local deploys are optional and must mirror normal gates. |
| 3 | PR 67 `4146c18` beta row-not-found timeouts | P | Stable paging, exact row identity, smoke cleanup, and truthful timeout diagnostics. |
| 4 | PR 66 `5db3dd4` real-browser popup blocking | P | Pre-open synchronously and retain real-browser acceptance for browser policy. |
| 5 | PR 65 `eed795f` missing deployed brand asset | P | Verify case-correct host-owned assets in publish output. |
| 6 | PR 64 `66e0b8a` documentation styling | A | Branding and spacing choices do not belong in the generic scaffold. |
| 7 | `2fef738` styling | A | Product styling only. |
| 8 | `d14940a` update | N | No independently reusable behavior. |
| 9 | PR 63 `1b5bb14` action runtime updates | E | Keep action pins supported; avoid generated-graph churn in maintenance-only PRs. |
| 10 | PR 62 `c827f70` Uno asset paths on Linux | P | Use forward-slash, case-correct publish paths and test on Linux. |
| 11 | `0a4bdaa` grid updates | A | Product layout only. |
| 12 | PR 61 `e9c9f20` redundant cleanup workflow | P | Do not scaffold repository-local self-cleaning workflows. |
| 13 | PR 59 `b7f3e65` Actions usage and image reuse | P | Reuse immutable per-SHA artifacts; retain required success artifacts. |
| 14 | PR 60 `831499e` manual VPS runbook | P | Operational docs must distinguish automated gates from manual acceptance. |
| 15 | PR 58 `45634db` Playwright UI repairs | P | Detect renderer, validate real staged assets, and capture correct diagnostics. |
| 16 | `a63fd12` updates | N | No independently reusable behavior. |
| 17 | PR 57 `4855168` documentation styling | A | Product documentation theme only. |
| 18 | PR 56 `d4d59c5` landing logo | P | Decorative images require platform-appropriate accessibility treatment. |
| 19 | PR 55 `372a31c` product logo | A | Brand identity is excluded. |
| 20 | PR 54 `2578711` public docs route | P | Browser storage can fail and must produce an explicit recoverable state. |
| 21 | `51c251f` PR 51 review fixes | P | Close endpoint validation, audit stamping, and safe-error review findings. |
| 22 | PR 51 `b923481` institution administration | A | Institution product behavior is excluded; boundary validation is promoted separately. |
| 23 | PR 50 `ed98bfe` OIDC callback hardening | P | Require state plus exact origin/path correlation and correctly scoped retry handling. |
| 24 | `8c38243` portal workflow coverage | P | Default-on security paths need deterministic contract tests. |
| 25 | `c090f3e` secure local sync cleanup | P | Cleanup must be scoped, explicit, and unable to expose credentials. |
| 26 | PR 49 `f06a524` access-context review gaps | P | Centralize effective access and sanitize provider failures. |
| 27 | PR 48 `94be52d` remove Entra mutation from smoke | P | General smoke tests must not mutate optional external providers. |
| 28 | PR 47 `ff523b7` visible role-sync action | P | Scope selectors to the visible, open interaction surface. |
| 29 | PR 46 `f714339` beta smoke UI checks | P | Wait for visible acknowledged state and preserve useful failure artifacts. |
| 30 | PR 45 `d478986` API access context | P | Mutable application membership is server-side authorization truth; do not cache transient faults. |
| 31 | PR 41 `6432969` institution-scoped security | P | Enforce resource scope at the API boundary and never track package credentials. |
| 32 | PR 44 `3a968e6` diagnostics and DOM coverage | P | Capture browser, server, screenshot, and DOM evidence before timeout. |
| 33 | `6fb4f26` remove smoke cleanup workflow | P | Evidence against scaffolding one-shot self-deleting workflows. |
| 34 | `98ec9e2` add smoke cleanup workflow | P | Evidence against scaffolding one-shot self-deleting workflows. |
| 35 | `1892720` integrate smoke and OIDC fixes | P | Keep smoke and identity fixes behind repeatable validation gates. |
| 36 | `bd56595` remove admin cleanup workflow | P | Evidence against scaffolding one-shot self-deleting workflows. |
| 37 | `7065c8c` remove merged admin branch | N | Repository housekeeping only. |
| 38 | `c8df164` simplify Entra provisioning | A | Provider-specific institution lifecycle is excluded; partial-failure rules are promoted. |
| 39 | `071eb19` remove mandatory RTK | P | Scaffold output must not require optional operator tooling. |
| 40 | `478816c` remove branch cleanup workflow | P | Evidence against scaffolding one-shot self-deleting workflows. |
| 41 | `5b683af` finalize obsolete branch cleanup | N | Repository housekeeping only. |
| 42 | `8a8a06d` verified obsolete branch cleanup | N | Repository housekeeping only. |
| 43 | `6b25a91` one-time obsolete branch cleanup | P | Routine repair must not use self-modifying workflow files. |
| 44 | `8d9876f` Graph registration diagnostics | P | Attach diagnostics to the provider's actual logger/context. |
| 45 | `95f25b3` Graph role-sync failures | P | Log structured provider detail server-side while returning stable safe errors. |
| 46 | PR 30 `52898d4` native-renderer DOM smoke | P | Select interaction strategy only after renderer detection. |
| 47 | PR 29 `9322a32` MudSelect server synchronization | P | Wait for server-acknowledged state before the next action. |
| 48 | PR 28 `dd126a1` Uno content and JSON | P | Use correct navigation regions and source-generated JSON metadata for trimmed WASM. |
| 49 | PR 27 `b40ae88` disable failing auto-smoke | P | Default-on lanes need proven prerequisites and actionable diagnostics. |
| 50 | PR 26 `4e46f73` cancel superseded CI | P | Cancel superseded CI, never an in-progress environment deployment. |
| 51 | PR 25 `55cb457` Uno menu and visible errors | P | Distinguish navigation ownership and bind error templates to the exception itself. |
| 52 | PR 24 `13381eb` native renderer | A | Renderer choice remains application-specific; measurement and selector consequences are promoted. |
| 53 | PR 23 `343a3be` download progress and linker roots | P | Measure published cold load and avoid obsolete linker workarounds. |
| 54 | PR 22 `da0bf93` invalid userinfo token | P | Do not call userinfo with a token for another audience. |
| 55 | PR 21 `7153d99` OIDC logger wiring | P | Wire diagnostics into the identity stack's real logger factory. |
| 56 | PR 20 `cfae8e2` exact roster selection | P | Use stable identifiers or exact normalized cells, never substring row selection. |
| 57 | PR 19 `ca15b2f` bootstrap cache policy | P | Bootstrap/config/index files must revalidate or use no-store. |
| 58 | PR 18 `1867501` visible sign-in failure | P | Release UI must surface safe actionable identity errors. |
| 59 | PR 17 `ba3dd67` order paged searches | P | Every `Skip/Take` query needs a deterministic total order. |
| 60 | PR 16 `0bca1bf` checkbox selector | P | Prefer semantic selectors tied to reachable controls. |
| 61 | `044f4a8` manual-only artifact cleanup | E | Artifact lifecycle must not delete evidence needed by active runs. |
| 62 | `ecedded` artifact storage cleanup | E | Scope cleanup safely and preserve required artifacts. |
| 63 | PR 15 `fc4884a` lost Blazor dialog click | P | Wait for an explicit interactive marker before actions. |
| 64 | PR 14 `53af3af` Release OIDC diagnostics | P | Production identity diagnostics must use the provider's effective logging path. |
| 65 | PR 13 `0ea12e4` institution memberships | A | Product administration is excluded; mutable-membership authorization is promoted. |
| 66 | PR 12 `ea1ef2c` Entra provisioning | P | External identity side effects need ordered behavior, safe errors, and default-path tests. |
| 67 | PR 11 `e8027c8` CIAM username field | A | Vendor page markup is not a scaffold contract. |
| 68 | PR 10 `484c8b5` CIAM endpoint hosts | P | Endpoint allowlists require exact origin boundaries and trailing-slash-safe matching. |
| 69 | PR 9 `688241a` smoke login diagnostics | P | Upload artifacts from the path where tests actually write them. |
| 70 | PR 8 `e3c3c6c` publish once in CI | P | Publish once, reuse the artifact, and fail when expected files are absent. |
| 71 | PR 7 `e24e493` sign-in and slow splash | P | Deploy Release publish output, parse encoding quality, and preserve compressed MIME types. |
| 72 | PR 6 `f79ae09` absolute installer path | P | Setup helpers cannot depend on an incidental working directory. |
| 73 | PR 5 `a5467de` context-tool install errors | P | Optional setup must not swallow its primary failure. |
| 74 | PR 4 `8c96197` automatic context-tool install | P | Automatic optional-tool installation is rejected as scaffold policy. |
| 75 | PR 3 `7243a16` web environment steps | A | Host-specific setup documentation is not generated by default. |
| 76 | PR 2 `10752d5` context tooling and graph refresh | P | Optional tools cannot gate delivery; refresh graphs only for material code changes. |
| 77 | PR 1 `c98d443` browser OIDC migration | P | Browser identity uses authorization code with PKCE and exact registered callbacks. |
| 78 | `088eb4a` restore Blazor bootstrap asset | P | Verify host-owned bootstrap assets survive publish. |
| 79 | `b638190` publish Blazor bootstrap script | P | Publish staging must include host-owned static assets. |
| 80 | `184196c` fingerprinted framework script | P | Immutable caching is limited to content-hashed assets. |
| 81 | `209fc1f` admin interactivity | P | Smoke actions must begin only after the app is interactive. |
| 82 | `6327832` mobile navigation and scaffold auth | P | Navigation acceptance must cover responsive shells without requiring live identity. |
| 83 | `227ec23` Entra roles and mobile navigation | P | Client role hints are not server authorization. |
| 84 | `4b544c7` mobile navigation | A | Product layout details are excluded. |
| 85 | `e234ace` mobile drawer and smoke | P | Responsive navigation needs semantic smoke coverage. |
| 86 | `0b3d6cc` post-deploy functional smoke | P | Deployment needs a functional lane after readiness. |
| 87 | `6d90dd2` deploy health and rollback | P | Use database-aware readiness, authoritative previous release, and no-rebuild rollback. |
| 88 | `4da02f1` live beta UI defects | P | Keep real-browser and deployed-head acceptance for behavior headless tests cannot reproduce. |
| 89 | `def126a` shared relational fixture | E | Reuse the existing real-provider fixture for deterministic integration proof. |
| 90 | `1ebe83e` Teacher data scope | P | Resource authorization belongs at the application/API boundary. |
| 91 | `3a15290` deploy correctness review | P | Deploy the requested green SHA and verify internal then public health. |
| 92 | `3f01481` readable Uno assets | P | Published runtime files need permissions readable by the serving process. |
| 93 | `f31587b` preserve deploy script after backup | P | Backups and recovery helpers must not destroy the only deploy path. |
| 94 | `37852fa` executable PostgreSQL backup | P | Verify recovery tooling permissions before destructive operations. |
| 95 | `a5f9c2c` install Python for WASM build | E | CI must provision declared publish prerequisites explicitly. |
| 96 | `edbb8cd` container restore inputs | E | Docker restore context must contain every referenced project/input. |
| 97 | `6996ecd` free runner disk | E | Existing runner disk-pressure guidance remains required. |
| 98 | `05df335` VPS deployment | E | Existing SHA images, migration job, health gates, and backup guidance cover the reusable parts. |
| 99 | `26f365a` updates | N | No independently reusable behavior; retained because its UTC commit time is in scope. |

## Exclusions

The audit does not promote VPS names, tenant or client identifiers, branding, institution-administration product features, provider-specific page selectors, UUIDv7 newest-first ordering, or repository-local self-cleaning workflows. Live identity guidance is conditional on a project enabling it; TaskFlow remains the automatic-auth proof.
