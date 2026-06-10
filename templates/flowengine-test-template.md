# FlowEngine Test Template

Project: `Test.Integration.{Project}.FlowEngine`. Generated when `includeFlowEngine: true`. Loaded in Phase 5d as part of the quality gate. See [../skills/flowengine.md](../skills/flowengine.md).

## Purpose

Workflow JSONs are the production wiring of FlowEngine. They are loaded from disk at runtime, parsed, validated, and registered. Each of those stages can fail silently:

| Stage | Silent failure mode |
|---|---|
| File present in build output | csproj `<Content>` glob excludes the file -> seeding has nothing to seed -> `StartAsync(workflowId)` returns "not found" at runtime. |
| JSON deserializes to `WorkflowDefinition` | Missing `JsonStringEnumConverter` -> `NodeKind` deserializes as default -> workflow runs but nodes are wrong. `WorkflowDefinitionJsonOptions.Default` supplies the required converters. |
| Definition passes FE validation | Invalid edges or missing required fields -> registry rejects on first start, not at deploy. |
| Definition round-trips through `IWorkflowRegistry` | Registry write/read mismatch -> workflow appears in dev tests but the registry returns stale data in prod. |
| `WorkflowDefinitionBuilder.FromJson(json).Build()` hydrates | A builder that fails to hydrate -> silent zero-node workflow. The assertion guards against it. |

The five-tier test below covers every stage. Generate one class per workflow JSON declared in `Workflows/`.

## Template

```csharp
using System.Text.Json;
using EF.FlowEngine;
using EF.FlowEngine.Models;
using EF.FlowEngine.Persistence;
using EF.FlowEngine.Validation;
using Microsoft.Extensions.DependencyInjection;

namespace Test.Integration.{Project}.FlowEngine;

[TestClass]
public class {WorkflowPascalName}WorkflowTests
{
    private const string WorkflowFileName = "{workflow-kebab-name}.json";
    private static string WorkflowsDirectory => Path.Combine(AppContext.BaseDirectory, "Workflows");
    private static string WorkflowPath => Path.Combine(WorkflowsDirectory, WorkflowFileName);

    // Tier 1 - file presence (G-005 guard).
    // Catches: csproj <Content> glob regression, accidental .gitignore, build-server filesystem-case issues.
    [TestMethod]
    public void Workflow_File_Is_Copied_To_Output()
    {
        Assert.IsTrue(
            File.Exists(WorkflowPath),
            $"Expected workflow JSON at '{WorkflowPath}'. Verify the API csproj has " +
            $"<Content Include=\"Workflows\\*.json\"> with CopyToOutputDirectory=PreserveNewest.");
    }

    // Tier 2 - JSON deserializes to WorkflowDefinition with the canonical options.
    // Catches: enum-as-string regressions, missing JsonStringEnumConverter, schema drift.
    [TestMethod]
    public void Workflow_Deserializes_With_Canonical_Options()
    {
        var json = File.ReadAllText(WorkflowPath);
        var def = JsonSerializer.Deserialize<WorkflowDefinition>(
            json, WorkflowDefinitionJsonOptions.Default);

        Assert.IsNotNull(def, "Deserialization returned null.");
        Assert.IsFalse(string.IsNullOrWhiteSpace(def.WorkflowId), "WorkflowId is empty.");
        Assert.IsTrue(def.Nodes.Count > 0, "Definition has zero nodes.");
    }

    // Tier 3 - Definition passes FE validation.
    [TestMethod]
    public void Workflow_Passes_FlowEngine_Validation()
    {
        var json = File.ReadAllText(WorkflowPath);
        var def = JsonSerializer.Deserialize<WorkflowDefinition>(
            json, WorkflowDefinitionJsonOptions.Default)!;

        var result = WorkflowDefinitionValidator.Validate(def);

        Assert.IsTrue(
            result.IsValid,
            $"Validation failed:\n{string.Join("\n", result.Errors)}");
    }

    // Tier 4 - round-trip through an in-memory registry.
    [TestMethod]
    public async Task Workflow_RoundTrips_Through_Registry()
    {
        var json = File.ReadAllText(WorkflowPath);
        var def = JsonSerializer.Deserialize<WorkflowDefinition>(
            json, WorkflowDefinitionJsonOptions.Default)!;

        var registry = new InMemoryWorkflowRegistry();
        await registry.UpsertAsync(def, CancellationToken.None);

        var hydrated = await registry.GetActiveAsync(def.WorkflowId, CancellationToken.None);

        Assert.IsNotNull(hydrated);
        Assert.AreEqual(def.WorkflowId, hydrated.WorkflowId);
        Assert.AreEqual(def.Nodes.Count, hydrated.Nodes.Count);
    }

    // Tier 5 - Builder.FromJson hydration (guards against a silent empty-builder result).
    [TestMethod]
    public void Workflow_Builder_FromJson_Hydrates_Nodes()
    {
        var json = File.ReadAllText(WorkflowPath);
        var built = WorkflowDefinitionBuilder.FromJson(json).Build();

        Assert.IsTrue(
            built.Nodes.Count > 0,
            "WorkflowDefinitionBuilder.FromJson(json).Build() produced zero nodes.");
    }
}
```

## Cross-Workflow File-Presence Guard

When the API declares **multiple** workflow JSONs, add a single guard test that asserts every expected file is present. This catches an accidental rename or removal that the per-workflow class wouldn't see (the per-workflow test only runs if the class compiles; a missing file may also delete the test).

```csharp
[TestClass]
public class AllWorkflowsArePresentTests
{
    private static readonly string[] ExpectedWorkflowFiles =
    [
        "approval-loop.json",
        "notify-on-completion.json",
        "nightly-reconciliation.json",
    ];

    [TestMethod]
    public void All_Expected_Workflows_Are_Copied_To_Output()
    {
        var dir = Path.Combine(AppContext.BaseDirectory, "Workflows");
        var missing = ExpectedWorkflowFiles
            .Where(f => !File.Exists(Path.Combine(dir, f)))
            .ToArray();

        Assert.AreEqual(
            0, missing.Length,
            $"Missing workflow JSONs in output: {string.Join(", ", missing)}. " +
            $"Verify <Content Include=\"Workflows\\*.json\"> in the API csproj.");
    }
}
```

## csproj - Test Project Output Wiring

The test project must `<Content>`-include the workflow JSONs (relative to the API project) and copy them to its own output, otherwise `AppContext.BaseDirectory` won't see them at test time:

```xml
<ItemGroup>
  <Content Include="..\..\src\Host\{Project}.Api\Workflows\*.json"
           Link="Workflows\%(Filename)%(Extension)">
    <CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
  </Content>
</ItemGroup>
```

The exact `Include` path depends on the solution layout; adjust the `..\..` segment to point from the test csproj to the API project.

## Tier Coverage Summary

| Tier | Catches | Cost |
|---|---|---|
| 1 - File presence | csproj/glob drift, gitignore, filesystem case | One `File.Exists` per workflow |
| 2 - Deserialize | JSON schema drift, enum converter regressions | One JSON parse |
| 3 - Validate | Bad edges, missing required fields | One validator pass |
| 4 - Registry round-trip | Registry serialization mismatch | One in-memory write/read |
| 5 - Builder hydration | Silent empty-builder hydration | One builder run |

All five run in the unit-test tier - no SQL, no Aspire, no real registry. Add to `Test.Integration.{Project}.FlowEngine` for the project naming convention; the tier semantics are pure unit-test.
