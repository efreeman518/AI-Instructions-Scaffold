# Test Templates - Index

Test scaffolding lives in split files by phase and harness. Load only the matching template(s) for the current task.

**Applies to every template below:** generated test code must be analyzer-clean at generation time. Any class with async test methods declares an instance `TestContext` property and flows `TestContext.CancellationToken` into every cancellable async call (HttpClient, service/repository, EF Core, and private helpers) - EF `FindAsync` takes the key array-wrapped then the token. The canonical rule (and the `MSTEST0049` severity + `dotnet format analyzers --verify-no-changes` gate that enforce it) is [../skills/testing.md](../skills/testing.md) section Cancellation-Token & TestContext Discipline.

| Phase | Template | Generates |
|---|---|---|
| 5a | [test-templates-domain.md](test-templates-domain.md) | `tests/Test.Unit/Domain/**` |
| 5a | [test-templates-repository.md](test-templates-repository.md) | `tests/Test.Unit/Repositories/**` |
| 5b | [test-templates-service.md](test-templates-service.md) | `tests/Test.Unit/Services/**` |
| 5b | [test-templates-endpoint.md](test-templates-endpoint.md) | `tests/Test.Endpoints/**` (incl. shared `WebApplicationFactoryBase` in `Test.Support`) |
| 5c | [test-templates-presentation.md](test-templates-presentation.md) | `tests/Test.UI/Presentation/**` for fast headless Uno MVUX/UI model tests in `{Project}.Uno.Presentation` |
| 5d | [test-templates-quality.md](test-templates-quality.md) | `tests/Test.Architecture/**`, `tests/Test.Load/**`, `tests/Test.Benchmarks/**`, `tests/Test.Mutation/**`, `tests/Test.PlaywrightUI/**` (hosted-stack; C# MSTest or Node Playwright for React/Vite), `tests/Test.E2E/**` |

Skill files (two only):

- Phase 5a/5b/5c TDD, harness model, integration host fixtures, template map: [../skills/testing.md](../skills/testing.md)
- Phase 5d quality gates, mutation testing, and hosted Playwright UI: [../skills/testing-quality.md](../skills/testing-quality.md)
