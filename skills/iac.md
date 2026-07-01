# Infrastructure as Code - Azure Bicep

Use this skill to generate `infra/` Bicep templates that mirror the runtime topology.

## Prerequisites

- API/core hosts scaffolded
- Aspire AppHost available (if used)
- Azure CLI + Bicep CLI installed

---

## Aspire <-> Azure Mapping

| Aspire resource | Azure resource | Bicep type |
|---|---|---|
| `AddSqlServer().AddDatabase()` | Azure SQL server + DB | `Microsoft.Sql/servers`, `Microsoft.Sql/servers/databases` |
| `AddRedis()` | Azure Cache for Redis | `Microsoft.Cache/redis` |
| `AddProject<Api/Gateway/Scheduler/...>()` | Container App or App Service | `Microsoft.App/containerApps` / `Microsoft.Web/sites` |
| ServiceDefaults telemetry | App Insights + Log Analytics | `Microsoft.Insights/components`, `Microsoft.OperationalInsights/workspaces` |

Rule: every `WithReference(resource, connectionName: "X")` in Aspire requires `ConnectionStrings__X` in app env settings.

---

## File Layout

```text
infra/
  main.bicep
  environments/
    dev.bicepparam
    staging.bicepparam
    prod.bicepparam
  modules/
    identity.bicep
    app-insights.bicep
    sql-server.bicep
    redis.bicep
    key-vault.bicep
    container-registry.bicep
    container-apps-env.bicep
    container-app.bicep
  scripts/
    deploy.ps1
```

---

## Core Patterns

### `main.bicep` orchestration

```bicep
targetScope = 'subscription'

param envName string
param location string = 'eastus2'
param projectName string

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${projectName}-${envName}'
  location: location
}

module identity 'modules/identity.bicep' = {
  scope: rg
  name: 'identity'
  params: { projectName: projectName, envName: envName, location: location }
}

module sql 'modules/sql-server.bicep' = {
  scope: rg
  name: 'sql'
  params: {
    projectName: projectName
    envName: envName
    location: location
    adminIdentityId: identity.outputs.principalId
  }
}
```

### Reusable container app module

```bicep
param appName string
param envName string
param location string
param containerAppsEnvId string
param registryServer string
param identityId string
param imageName string
param isExternalIngress bool = false
param minReplicas int = 1
param maxReplicas int = 3
param env array = []

resource app 'Microsoft.App/containerApps@2024-03-01' = {
  name: '${appName}-${envName}'
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${identityId}': {} }
  }
  properties: {
    managedEnvironmentId: containerAppsEnvId
    configuration: {
      ingress: {
        external: isExternalIngress
        targetPort: 8080
      }
      registries: [
        { server: registryServer, identity: identityId }
      ]
    }
    template: {
      containers: [
        {
          name: appName
          image: '${registryServer}/${imageName}:latest'
          env: env
        }
      ]
      scale: {
        minReplicas: minReplicas
        maxReplicas: maxReplicas
      }
    }
  }
}
```

### SQL module baseline

```bicep
param projectName string
param envName string
param location string
param adminIdentityId string

resource sqlServer 'Microsoft.Sql/servers@2023-08-01-preview' = {
  name: 'sql-${projectName}-${envName}'
  location: location
  properties: {
    administrators: {
      azureADOnlyAuthentication: true
      principalType: 'Application'
      login: '${projectName}-identity'
      sid: adminIdentityId
    }
    minimalTlsVersion: '1.2'
  }
}

resource db 'Microsoft.Sql/servers/databases@2023-08-01-preview' = {
  parent: sqlServer
  name: '${projectName}db-${envName}'
  location: location
}
```

---

## Required Consistency Rules

1. One AppHost project => one deployable host module.
2. Connection names match exactly (`WithReference` <-> `ConnectionStrings__*`).
3. Gateway is the only external ingress by default.
4. Scheduler stays single replica (`minReplicas = maxReplicas = 1`) when using TickerQ.
5. ServiceDefaults telemetry maps to App Insights + Log Analytics.
6. Keep Aspire resource names, IaC names, and appsettings keys aligned.

### TickerQ schema deployment

The `[Scheduler]` schema is a migrator target like any other: the one-shot `{App}.DatabaseMigrator` Container Apps Job applies it before scheduler rollout (see [../skills/cicd.md](../skills/cicd.md) section Production DB Migration (Migrator Job)). IaC ships a container-app-job module for the migrator (manual trigger, migrator image, job name exposed as an output).

---

## Security Rules

- Use managed identity for ACR pull, SQL, Key Vault, App Config.
- Keep SQL Entra-only (`azureADOnlyAuthentication: true`).
- Put secrets in Key Vault / secret refs, not plain Bicep values.
- Prefer private endpoints in production.
- Map compliance requirements (classification, retention, audit) to deployable controls (diagnostic settings, retention policies, encryption settings, access restrictions).

---

## Deployment

### Azure CLI

```powershell
az deployment sub create `
  --location eastus2 `
  --template-file infra/main.bicep `
  --parameters infra/environments/dev.bicepparam
```

### GitHub Actions

```yaml
- uses: azure/arm-deploy@v2
  with:
    scope: subscription
    template: infra/main.bicep
    parameters: infra/environments/${{ inputs.environment }}.bicepparam
```

### azd (bicep provider)

```yaml
name: {project-name}
infra:
  provider: bicep
  path: infra
services:
  api:
    project: src/Host/{Host}.Api
    host: containerapp
```

---

## azd from Aspire (infra-only path)

An alternative to hand-written Bicep: let `azd` derive infra from the Aspire model. Use this when `deployTarget: ContainerApps` and the AppHost already declares the deployable graph (see [aspire.md](aspire.md) -> *Publish-Mode Branch*). Two forms exist - hand-written Bicep under `includeIaC` (above), or azd-from-Aspire (here). Pick one; do not run both.

### `azure.yaml` entry point

A single `azure.yaml` at the repo root points at the AppHost project; `azd` reads the Aspire model from it. Generated by `azd init` or hand-written:

```yaml
name: {project-name}
services:
  app:
    project: ./src/Host/Aspire/AppHost/AppHost.csproj
    host: containerapp
    language: dotnet
```

### Ownership split (images go to GHCR)

When images are built/pushed by GitHub Actions to GHCR, **azd owns INFRA only**:

- Run `azd provision` (creates the ACA environment, Azure SQL, identities, etc. from the Aspire model).
- **Never** run `azd deploy` or `azd up` - those build and push images to ACR, which collides with the GHCR image path. Image build/push and the ACA image swap belong to `cd.yml` (see [cicd.md](cicd.md)).

### `provision.yml` (manual infra workflow)

A separate workflow, `workflow_dispatch` only (same default as `cd.yml` - see [cicd.md](cicd.md) -> *Trigger default*):

```yaml
on: { workflow_dispatch: {} }
permissions: { id-token: write, contents: read }

jobs:
  provision:
    runs-on: ubuntu-latest
    environment: ${{ inputs.environment }}
    env:
      AZURE_ENV_NAME: ${{ vars.AZURE_ENV_NAME }}
      AZURE_LOCATION: ${{ vars.AZURE_LOCATION }}
      AZURE_SUBSCRIPTION_ID: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      AZURE_RESOURCE_GROUP: ${{ vars.AZURE_RESOURCE_GROUP }}
    steps:
      - uses: actions/checkout@v6
      - uses: Azure/setup-azd@v2
      - run: azd auth login --federated-credential-provider github
      - run: azd provision --no-prompt
      # After provision, set the GHCR pull cred on each app (private packages only):
      - name: Set GHCR pull credentials
        run: |
          for app in api gateway scheduler; do
            az containerapp registry set --name "$app" \
              --resource-group "${{ vars.AZURE_RESOURCE_GROUP }}" \
              --server ghcr.io \
              --username "${{ vars.GHCR_USER }}" \
              --password "${{ secrets.GHCR_PULL_TOKEN }}"
          done
```

### One-time, account-bound steps (document, do not script)

These bind to a user/tenant and cannot run unattended in the pipeline - put them in `HANDOFF.md` as manual steps:

- `azd init` - generates `azure.yaml` (skip if hand-written).
- `azd infra synth` (optional) - materializes reviewable Bicep into `infra/`. After synth, SKUs and tuning belong in `ConfigureInfrastructure(...)` callbacks in the AppHost, **not** in the generated Bicep - re-synth overwrites hand edits.
- **azd + OIDC trust:** `azd pipeline config --provider github`, or manual `az ad app federated-credential create` with subject `repo:<owner>/<repo>:environment:<env>` matching the job's `environment:` value. Without a matching subject, `azd auth login --federated-credential-provider github` fails.

---

## Dockerfile Requirement

Container deployments require per-host Dockerfiles. The build context must match the Dockerfile's `COPY` roots (repo root or `src/`) - confirm per app, do not assume `src/`.

```bash
# Repo-root Dockerfile (e.g. DemoApp1):
docker build -f src/Host/{Host}.Api/Dockerfile .
```

---

## Lite Mode

For `scaffoldMode: lite`:
- Usually one API host
- Single DbContext connection key
- No Redis module unless explicitly enabled
- Simplified `main.bicep`

## Verification

- [ ] `az bicep build --file infra/main.bicep` succeeds
- [ ] Env vars match runtime config keys
- [ ] Aspire resources and IaC modules align
- [ ] Scheduler replica and scheduler DB settings are correct
- [ ] Deploy parameters exist per target environment
