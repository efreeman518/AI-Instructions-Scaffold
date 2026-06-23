# Test Templates - Index

Test scaffolding lives in split files by phase and harness. Load only the matching template(s) for the current task.

| Phase | Template | Generates |
|---|---|---|
| 5a | [test-templates-domain.md](test-templates-domain.md) | `Test/Test.Unit/Domain/**` |
| 5a | [test-templates-repository.md](test-templates-repository.md) | `Test/Test.Unit/Repositories/**` |
| 5b | [test-templates-service.md](test-templates-service.md) | `Test/Test.Unit/Services/**` |
| 5b | [test-templates-endpoint.md](test-templates-endpoint.md) | `Test/Test.Endpoints/**` (incl. shared `WebApplicationFactoryBase` in `Test.Support`) |
| 5c | [test-templates-presentation.md](test-templates-presentation.md) | `Test/Test.Unit/Presentation/**` for Uno MVUX models in `{Project}.Uno.Core` |
| 5d | [test-templates-quality.md](test-templates-quality.md) | `Test/Test.Architecture/**`, `Test/Test.Load/**`, `Test/Test.Benchmarks/**`, `Test/Test.Mutation/**`, `Test/Test.PlaywrightUI/**` (hosted-stack; C# MSTest or Node Playwright for React/Vite), `Test/Test.E2E/**` |

Skill files (two only):

- Phase 5a/5b/5c TDD, harness model, integration host fixtures, template map: [../skills/testing.md](../skills/testing.md)
- Phase 5d quality gates, mutation testing, and hosted Playwright UI: [../skills/testing-quality.md](../skills/testing-quality.md)
