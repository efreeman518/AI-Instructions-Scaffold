# Uno Platform UI

## Purpose

Scaffold a single Uno codebase (browserwasm + Android + iOS) that calls the **Gateway** (YARP), not backend APIs directly.

- UI auth: `EntraExternal` (or configured UI auth provider)
- API auth: token relay through Gateway
- Pattern: Views (`XAML`) <-> Presentation (`MVUX`) <-> Business services <-> Kiota client <-> Gateway

References:
- [../ai/domain-specification-schema.md](../ai/domain-specification-schema.md)
- [../ai/resource-implementation-schema.md](../ai/resource-implementation-schema.md)
- See [../patterns/expected-output-index.md](../patterns/expected-output-index.md).
- [../ai/SKILL.md](../ai/SKILL.md)
- Reference app: [Uno Chefs](https://github.com/unoplatform/uno.chefs) - canonical Uno example for MVUX, navigation, Kiota HTTP, and page structure

---

## Skill File Map

This skill is split for context-budget-friendly loading. Use the table to decide what to load for the current task - load only what you need.

| File | Load when |
|---|---|
| **[ui-uno-shell.md](ui-uno-shell.md)** | Setting up the Uno project: `.csproj` with `Uno.Sdk`, packages, `App.xaml`, Shell control, host wiring (`App.xaml.host.cs`), Aspire WASM wrapper host, mock-vs-live HTTP switch. |
| **[ui-uno-mvux.md](ui-uno-mvux.md)** | Writing presentation code: MVUX models, feed-refresh patterns, cross-model messaging, XAML pitfalls, business services, client-API contract (`DefaultRequest`/`DefaultResponse`/pagination), auth patterns. |
| **[ui-uno-navigation.md](ui-uno-navigation.md)** | Wiring navigation chrome: persistent menu "always land on the top page" (`PanelVisibilityNavigator` traps + click handler), cross-model form dirty guard before leaving an edited page. |
| **[ui-uno-platforms.md](ui-uno-platforms.md)** | Platform-specific work: WASM debugging, port exclusion, Android SDK + emulator, Resizetizer issues, CI requirements (`wasm-tools` workload). |

For frontier-model loading (>=200K context), all three may be loaded together. For constrained context, load by task.

---

## Profiles

| Profile | Scope |
|---|---|
| `starter` | Host wiring, auth/http, route maps, list/detail/settings pages, MVUX models, service layer, mock/live switch |
| `full` | `starter` + richer shell, dialog/flyout routes, expanded page set and UX flows |

Prefer `starter` until core vertical slices stabilize.

## Required Structure

```text
src/UI/{Project}.Uno/
  App.xaml
  App.xaml.cs
  App.xaml.host.cs
  appsettings.json
  Presentation/           # MVUX models
  Views/
  Styles/
  Strings/
  Converters/
  Platforms/
    Android/
    iOS/
    WebAssembly/
src/UI/{Project}.Uno.Core/
  Business/
    Models/
    Services/
  Client/                 # Kiota-generated client
src/Host/{Project}.Uno.WasmHost/
  Program.cs              # Aspire/browserwasm wrapper host
```

Detailed structure rules live in [ui-uno-shell.md](ui-uno-shell.md) section Project File Rules.

## Generation Checklist

- [ ] `includeUnoUI: true` set in domain inputs
- [ ] `GatewayBaseUrl` present in `appsettings*.json`
- [ ] Auth + HTTP + navigation configured in `App.xaml.host.cs` (see [ui-uno-shell.md](ui-uno-shell.md))
- [ ] `Business/Models`, `Business/Services`, `Presentation`, `Views` scaffolded
- [ ] Business services and generated clients live in `src/UI/{Project}.Uno.Core`; XAML/MVUX/platform heads live in `src/UI/{Project}.Uno`
- [ ] `Features:UseMocks` implemented (mock + live path)
- [ ] Core pages scaffolded: Home, {Entity}List, {Entity}Page (unified add/edit + children), Settings (+ Login when auth enabled)
- [ ] Each entity uses single page pattern: `{Entity}Page` with form fields + children sections
- [ ] Children sections visible only in edit mode (`Visibility="{Binding IsEditMode}"`)
- [ ] `FormTextBoxStyle` applied to all TextBox inputs for visible borders
- [ ] Route mappings and page-model bindings compile (see [ui-uno-mvux.md](ui-uno-mvux.md) section Routing + Mapping)
- [ ] `Shell.xaml` has `ExtendedSplashScreen.Content` containing `<Frame />`
- [ ] `Shell.xaml.cs` implements `IContentControlProvider`
- [ ] `ShellModel` navigates to first route in constructor
- [ ] `Platforms/WebAssembly/WasmScripts/AppManifest.js` present (see [ui-uno-platforms.md](ui-uno-platforms.md))
- [ ] Android/iOS platform folders are present when mobile targets are enabled
- [ ] Aspire registers `src/Host/{Project}.Uno.WasmHost`, not the Uno SDK project directly
- [ ] `launchSettings.json` applicationUrl set to `https://localhost:7069;http://localhost:5189`
- [ ] Gateway `CorsSettings.AllowedOrigins` includes `https://localhost:7069` and `http://localhost:5189`
- [ ] UI uses Gateway endpoints only

## Related Skills

- Solution layout: [solution-structure.md](solution-structure.md)
- Gateway integration: [gateway.md](gateway.md)
- Auth setup: [identity-management.md](identity-management.md)
- Testing strategy: [testing.md](testing.md)
- App configuration: [configuration-secrets.md](configuration-secrets.md)
