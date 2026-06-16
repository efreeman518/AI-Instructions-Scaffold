# React UI

Scaffold a React + TypeScript Vite SPA that calls the Gateway/API. Load during Phase 5c when `includeReactUI: true`.

Use this for web-only authenticated business apps where the backend owns data, auth, and workflows. Prefer Vite SPA for scaffolded internal tools. Use Next.js only when the product explicitly needs server rendering, SEO/indexable public pages, React server functions, or a full-stack React route layer.

## Project Shape

Place the app under `src/UI/{Project}.React/`.

```text
src/UI/{Project}.React/
  package.json
  vite.config.ts
  tsconfig.json
  src/
    main.tsx
    app/
      App.tsx
      routes.tsx
      queryClient.ts
      theme.ts
    api/
      {project}Api.ts
      types.ts
    features/
      {entity}/
        {Entity}ListPage.tsx
        {Entity}DetailPage.tsx
        {Entity}Form.tsx
        {entity}Queries.ts
    shared/
      components/
      layout/
      theme/
```

Baseline stack:

- React + TypeScript + Vite.
- React Router for client routes.
- TanStack Query for server state, mutations, cache invalidation, and request status.
- Established component system first. Use Material UI when the app has no existing design system.
- `lucide-react` for command/icon buttons.
- Typed fetch wrapper or generated OpenAPI client. Keep route contracts aligned with `/api/v1`.

Do not duplicate DTO semantics by hand when shared/generated contracts are available. If a hand-written TypeScript contract is needed, keep it thin and map the API envelope explicitly.

## API Contract

- UI calls the Gateway by default, never the API host directly when Gateway is enabled.
- Prefer relative `/api` routes in app code. Use `VITE_API_BASE_URL` only in Vite dev proxy/Aspire wiring.
- Normalize `DefaultResponse<T>` / paged search envelopes in one API client layer.
- Match the backend's page-index base exactly; verify it empirically (request page 0 vs page 1 against a seeded list) rather than assuming, and do not silently switch the UI to a different base than the API uses.
- For aggregate roots, create/update the aggregate with nested child collections in one save when backend mappers/updaters support it. Do not add child API calls on create just because the UI has child controls.
- Dev tenant/auth headers must follow the Gateway/API dev-auth rules. Never hard-code production tokens or tenant IDs in the React app.

## Aspire + Vite

When `useAspire: true`, register the Vite dev server in `Host/Aspire/AppHost/AppHost.cs` instead of treating React as a .NET project.

Required lessons:

- Add `Aspire.Hosting.JavaScript` to the AppHost.
- Register the app with `AddViteApp(...)` from `src/Host/Aspire/AppHost`, pointing at `../../../UI/{Project}.React`.
- Pass the Gateway HTTP endpoint into `VITE_API_BASE_URL` when Gateway is enabled; otherwise pass the API endpoint.
- Expect Aspire to assign a dynamic Vite port. Do not hard-code `5173`, `5178`, or any previous dashboard URL in tests or docs.
- The Vite resource is healthy when the root URL renders and one API-backed page returns data or a typed empty state.

Standalone dev still uses:

```powershell
npm ci
npm run lint
npm run build
npm run dev -- --host 127.0.0.1
```

Stop standalone Vite and AppHost processes after validation; do not leave dev servers running between sessions.

## UI Scope

Duplicate the existing app's real workflow surface, not just a landing page:

- Dashboard or work queue.
- Entity list/search with paging and filters.
- Create/edit/detail flow.
- Delete/confirm flow.
- Child collection editing when the aggregate has comments, checklist items, tags, attachments, or similar children.
- Lookup/maintenance screens for shared catalogs such as categories or tags when the existing app exposes them.
- Settings/theme page when the app has user preferences.

Theme persistence: if a theme toggle is scaffolded, default to dark mode unless the domain asks otherwise and persist under `{project}.react.theme` in `localStorage`.

## Playwright

React UI tests must run against a real hosted stack.

- Configure a dedicated Playwright project for React.
- Make `baseURL` environment-driven, for example `{APP}_REACT_BASE_URL`, because Aspire's Vite port is dynamic.
- Run CRUD tests with unique names and clean up created data.
- Include at least one create/read/update/delete flow through the UI and one shell test for navigation/theme persistence.
- Assert structural UI and the unique test data created by the test. Do not assert seed counts or shared database totals.
- Verify nested child collections in the CRUD flow when the UI supports them.
- Node Playwright is acceptable for React/Vite. If the scaffold uses C# Playwright MSTest, keep the same base-URL and hosted-stack rules.
- If a shell wrapper mangles `npx playwright`, invoke the local CLI directly: `node node_modules/@playwright/test/cli.js`.

Minimum React validation:

```powershell
npm run lint
npm run build
dotnet build src/Host/Aspire/AppHost
```

Then start AppHost, get the React resource URL from the Aspire dashboard/console, set `{APP}_REACT_BASE_URL` to that URL, and run the Playwright React project.

## Completion Checklist

- [ ] `includeReactUI: true` set in `.scaffold/resource-implementation.yaml`.
- [ ] Node.js LTS/npm recorded in `.scaffold/implementation-plan.md` tooling readiness.
- [ ] React app lives under `src/UI/{Project}.React`.
- [ ] App code calls relative `/api` or a single configured API base, not scattered host URLs.
- [ ] Vite proxy/AppHost wiring points to the Gateway endpoint, or the API endpoint when Gateway is disabled.
- [ ] AppHost builds with `Aspire.Hosting.JavaScript`.
- [ ] `npm run lint` and `npm run build` pass.
- [ ] Standalone Vite root renders.
- [ ] Aspire-registered Vite root renders from the dynamic resource URL.
- [ ] Playwright uses an env-driven React base URL and passes against the hosted stack.
