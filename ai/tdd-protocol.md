# TDD Protocol

## Purpose

Defines the red/green loop for Phase 5a and Phase 5b, plus the tests-after protocol for Phase 5c, Phase 5d, and Phase 5e.

Phase 4 already generated interfaces, DTOs, entity shells, test infrastructure, and no-op DI stubs. Use those contracts to write tests first, then implement to green.

---

## Vertical Tracer Bullet Rule

For each entity, prove one narrow behavior through the public surface before broad layer fill-in. A good tracer starts from a business action, hits the generated contract, and ends in an observable result.

Examples:

- Domain: `Create{Entity}` rejects an invalid state transition.
- Service: `CreateAsync` validates input and persists one valid entity through the repository contract.
- Endpoint: `POST /{entity-route}` returns the expected envelope and status code.

Do not build all entities across one layer before proving one entity end-to-end. That creates horizontal scaffolding drift and delays real feedback.

Tests must verify behavior through public interfaces or endpoints. Avoid assertions that pin private method names, internal collection types, mapper implementation details, or DI registration order unless that is the behavior under test.

---

## TDD Enforcement Rules (Non-Negotiable)

> RED confirmation is mandatory. Do not skip it.

1. **Write tests FIRST.** Do not write any production code until the test file(s) for the current slice exist and compile.
2. **Confirm RED before implementing.** Run `dotnet test` and verify the new tests **fail with assertion errors**. If they pass against no-op stubs, tighten assertions until they fail. Record the failing test count.
3. **Implement ONLY enough to pass.** Write the minimum production code needed to make the failing tests pass. Do not add untested behavior.
4. **Confirm GREEN immediately.** Run `dotnet test` after implementation. All tests must pass. If any fail, fix before moving to the next slice.
5. **Never batch multiple slices.** Complete the full RED -> GREEN cycle for one entity slice before starting the next.
6. **No simultaneous test + implementation files.** In a single file-generation pass, produce either test files OR implementation files - not both. The only exception is activating `{Entity}Builder.Build()` alongside entity implementation (Step 5 of Phase 5a).
7. **Do not accept compile-fail as RED.** Fix compile issues first, then confirm assertion-fail RED.
8. **No horizontal red/green.** Write and green one vertical tracer before expanding the same pattern to the next entity or layer.
9. **Cover every terminal branch and in-handler transform.** A handler/service method with more than one terminal outcome leaves **one test per branch** - e.g. a completion handler whose pass path sets `Completed` and whose fail path sets `CompletedPartial` needs both tested, not just the passing path. Any in-handler clamp / normalize / transform leaves **one test for that transform** - e.g. a dimension-score clamp to `[0, max]`. A binary terminal branch or a clamp with only the happy path tested is incomplete behavior (rule 3 inverted: non-trivial logic leaves a runnable check).

### What RED Looks Like

Valid RED - assertion failure (always counts):

```text
Failed Given_ValidInput_When_Create_Then_ReturnsSuccess [12 ms]
  Assert.AreEqual failed. Expected:<Active>. Actual:<(null)>.
```

Valid RED in 5a only - Phase 4 shell throw (proves the test reaches unimplemented code):

```text
Failed Given_EmptyName_When_Create_Then_ReturnsFailure [8 ms]
  System.NotImplementedException: ... at {Project}.Domain.Model.{Entity}.Create(...)
```

NOT RED: a compile error (rule 7), or a test that passes against a no-op stub returning defaults - tighten assertions until it fails (rule 2). In 5b, stubs return safe defaults rather than throwing, so only assertion failures count as RED.

---

## BDD Naming Convention

All test methods use `Given_When_Then`.

Rules:
- `Given` describes the precondition or initial state
- `When` describes the action under test
- `Then` describes the expected outcome
- Use PascalCase segments separated by underscores
- Keep names descriptive but concise

---

## Phase 5a - Foundation TDD (Per Entity Slice)

Process each entity in the dependency order established in Phase 4 (parents first, then children).

1. **Write domain entity tests** in `tests/Test.Unit/Domain/{Entity}Tests.cs` from `test-templates-domain.md`.
2. **Write domain rule tests** in `tests/Test.Unit/Domain/{Entity}RulesTests.cs`.
3. **Run RED**:

```powershell
dotnet test --filter "TestCategory=Unit"
```

   Expected: tests fail with assertions or `NotImplementedException`, not compile errors.
4. **Implement entity + rules**:

- Replace `NotImplementedException` bodies in `Create()`, `Update()`, and rule methods.
- Activate `{Entity}Builder.Build()` only after `Create()` works.

5. **Run GREEN**:

```powershell
dotnet test --filter "TestCategory=Unit"
```

6. **Write repository tests** from `test-templates-repository.md`.
7. **Implement EF configuration + repositories**:

- Create `{Entity}Configuration.cs`.
- Implement `{Entity}RepositoryTrxn` and `{Entity}RepositoryQuery`.
- Wire `DbSet<{Entity}>` and swap the no-op DI registrations.

8. **Run GREEN again**:

```powershell
dotnet test --filter "TestCategory=Unit"
```

9. **Gate the slice**:

```powershell
dotnet ef migrations add InitialCreate ...
dotnet build
dotnet test --filter "TestCategory=Unit"
```

Git checkpoint after gate passes.

---

## Phase 5b - App Core TDD (Per Entity Slice)

1. **Write service tests** in `tests/Test.Unit/Services/{Entity}ServiceTests.cs` from `test-templates-service.md`.
2. **Run RED**:

```powershell
dotnet test --filter "TestCategory=Unit"
```

   Expected: new tests fail because no-op stubs return empty/default values.
3. **Implement service + mapper + validator** and replace the no-op service registration.
4. **Run GREEN (Unit)**:

```powershell
dotnet test --filter "TestCategory=Unit"
```

5. **Write endpoint tests** in `tests/Test.Endpoints/Endpoints/{Entity}EndpointsTests.cs` from `test-templates-endpoint.md`.
6. **Implement endpoints** and wire endpoint registration.
7. **Run GREEN (Endpoint)**:

```powershell
dotnet test --filter "TestCategory=Unit|TestCategory=Endpoint"
```

8. **Runtime / edge concerns (tests-after, after all entity slices are green):**

   Once every entity has reached green Unit + Endpoint, layer in enabled runtime concerns (gateway, multi-tenant middleware, caching, Aspire orchestration, configuration/secrets, observability, security) and **then** write infrastructure tests covering them: health checks, config-loading, cache wiring, gateway routing.

   - Place mock-based infrastructure tests in `Test.Unit` with `[TestCategory("Unit")]`.
   - Place WAF-based infrastructure tests in `Test.Endpoints` with `[TestCategory("Endpoint")]`.
   - Service-level integration tests against real external services (Testcontainers SQL, real cache) belong in `Test.Integration` and run as part of Phase 5d's quality regression - not 5b's gate.

   Re-run the same filter after writing them:

   ```powershell
   dotnet test --filter "TestCategory=Unit|TestCategory=Endpoint"
   ```

   When Aspire is enabled, also verify the AppHost gate per [`../support/execution-gates.md`](../support/execution-gates.md) section 5b before closing the session.

Git checkpoint after gate passes.

---

## Phase 5c/5d/5e - Tests-After Protocol

Infrastructure and optional host phases do not follow TDD. Instead, implement first, then write tests at the end of the session to verify behavior.

5c tests: optional host smoke tests, scheduler/function trigger tests, and Uno/Blazor/React client tests when applicable.

5d tests: architecture, load, benchmark, mutation, E2E, vulnerability, and delivery checks according to `testingProfile`.

5e tests: auth endpoint behavior plus AI service registration/no-op behavior; live provider checks only when provisioned.

```powershell
dotnet test -m:1
```

---

## Red State Troubleshooting

If tests fail to compile (not just fail assertions):

1. **Missing type**: Check Phase 4 output. The type should exist as a contract/shell.
2. **Missing project reference**: Add `<ProjectReference>` to the test project's `.csproj`.
3. **Missing package**: Add to `Directory.Packages.props` and restore.
4. **Wrong namespace**: Verify against `placeholder-tokens.md` substitutions.

If tests pass unexpectedly (should be red but are green):

1. **No-op stub satisfies the assertion**: Tighten assertions. Assert on specific values, not just success or non-null.
2. **Wrong test target**: Verify the test is calling the code you think it's calling.

---

## Replacing No-Op Stubs

When implementing a real class that replaces a no-op stub:

1. Create the real implementation class
2. Update `RegisterServices.cs` to swap the no-op registration for the real class
3. Leave the no-op class in place or delete it
4. Verify `dotnet build` still succeeds after the swap

---

## Slice Completion Checklist

A vertical slice is TDD-complete when:

- [ ] Entity tests exist and pass (5a)
- [ ] Domain rule tests exist and pass (5a)
- [ ] Repository tests exist and pass (5a)
- [ ] Service tests exist and pass (5b)
- [ ] Endpoint tests exist and pass (5b)
- [ ] At least one vertical tracer behavior was proven through the public contract or endpoint before broad layer expansion
- [ ] All no-op stubs for this entity are replaced with real implementations
- [ ] `{Entity}Builder.Build()` is activated and returns a valid entity
- [ ] `{Entity}DtoBuilder.Build()` returns a valid DTO (should already work from 4)
