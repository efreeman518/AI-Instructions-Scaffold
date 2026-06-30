# Ubiquitous Language - {{ProjectName}}

This file records the shared language between developer and AI. Use these terms in code, tests, docs, prompts, API contracts, and comments. Prefer a recorded term over synonyms.

## Purpose

- Business domain:
- Primary users:
- Success criteria:

## Accepted Terms

| Term | Type | Meaning | Code/Naming Guidance |
|---|---|---|---|
| `{{Entity}}` | entity | _Business meaning._ | Use `{{Entity}}` in class, DTO, service, endpoint, and test names. |

Term types: entity, aggregate, value-object, role, command, state, event, policy, external-system, UI-label.

## Vocabulary Rules

- One accepted term maps to one business meaning.
- Prefer explicit terms over abbreviations.
- Rejected synonyms are binding. Do not use them in source names, route labels, tests, prompts, or docs unless a framework forces the name.
- If a term is still ambiguous, record it under Ambiguous Terms and do not use it for generated code until it is resolved or explicitly deferred.

## Rejected Synonyms

| Rejected Term | Use Instead | Reason |
|---|---|---|
| `Task` | `WorkItem` | Avoid `System.Threading.Tasks.Task` collision. |

## Ambiguous Terms

This table should be empty before Phase 2 unless the ambiguity is non-blocking and has a decision entry in `.scaffold/DESIGN-DECISIONS.md`.

| Term | Ambiguity | Blocking? | Decision |
|---|---|---|---|
| `{{Term}}` | _What is unclear._ | no | `D-###` |

For a vocabulary gap that is not yet ready to become a row above, drop an inline `[OPEN QUESTION: <single-sentence question>]` marker next to the closest term it touches (**GR-10**) and mirror it in `HANDOFF.md` section Open Questions. Markers must be resolved or converted to deferred decisions before the next phase gate.

## Entities And Aggregates

| Entity | Aggregate Role | Tenant Scope | Ownership Notes |
|---|---|---|---|
| `{{Entity}}` | root | tenant-scoped | _Owned children and references._ |

## Value Objects

| Value Object | Meaning | Fields | Used By | Equality Boundary | Validation/Behavior |
|---|---|---|---|---|---|
| `{{ValueObject}}` | _Business concept._ | `_Field list._` | `{{Entity}}.{{Property}}` | _Fields that define equality._ | _Rules or behavior justifying non-primitive model._ |

## Roles And Actors

| Role/Actor | Meaning | Permissions Language |
|---|---|---|
| `{{Role}}` | _Who this represents._ | _Allowed actions in business terms._ |

## Commands And Actions

| Command/Action | Actor | Target | Business Meaning | Expected Result |
|---|---|---|---|---|
| `Create{{Entity}}` | `{{Role}}` | `{{Entity}}` | _What the business says happened._ | _State/event/result._ |

## States

| Entity | State | Meaning | Terminal |
|---|---|---|---|
| `{{Entity}}` | `{{State}}` | _Business condition._ | no |

## Events

| Event | Raised By | Meaning | Consumers |
|---|---|---|---|
| `{{Entity}}Created` | `{{Entity}}` | _Business fact after it occurs._ | _Workflow/search/notification/etc._ |

## Policies And Rules

| Policy/Rule | Applies To | Meaning | Decision Source |
|---|---|---|---|
| `{{PolicyName}}` | `{{Entity}}` | _Business constraint._ | `D-###` |

## External Systems

| System | Domain Meaning | Interaction Vocabulary |
|---|---|---|
| `{{ExternalSystem}}` | _Business role of system._ | _Use verbs/nouns from this row._ |

## Naming Notes

- Use terms exactly as recorded unless C# framework collision requires a recorded alternative.
- Do not introduce abbreviations unless listed here.
- API route labels may be lowercase/kebab-case, but source names should use the accepted PascalCase term.
- Tests should use business phrases from this file in test method names where practical.
