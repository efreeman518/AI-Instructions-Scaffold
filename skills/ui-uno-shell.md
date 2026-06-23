# Uno Platform UI - Shell, Project Setup, App Hosting

App-shell scaffolding and project-file rules for an Uno application. Loaded during Phase 5c when an Uno UI project is in scope.

Companion files:
- [ui-uno.md](ui-uno.md) - index + decision table
- [ui-uno-mvux.md](ui-uno-mvux.md) - MVUX models, routing, XAML, business services, auth
- [ui-uno-navigation.md](ui-uno-navigation.md) - menu "always-to-top" wiring, cross-page dirty guard
- [ui-uno-platforms.md](ui-uno-platforms.md) - WASM debugging, Android, CI requirements

---

## Packages (Minimum)

> **Important:** With Uno.Sdk, you do NOT list individual Uno packages. The SDK resolves them automatically from `<UnoFeatures>`. The list below is for reference only - to understand what `UnoFeatures` maps to. Do NOT add these `PackageReference` entries to the csproj.

```xml
<PackageReference Include="Uno.WinUI" />
<PackageReference Include="Uno.Sdk.Private" />
<PackageReference Include="Uno.Extensions.Hosting.WinUI" />
<PackageReference Include="Uno.Extensions.Navigation.WinUI" />
<PackageReference Include="Uno.Extensions.Navigation.Toolkit.WinUI" />
<PackageReference Include="Uno.Extensions.Reactive.WinUI" />
<PackageReference Include="Uno.Extensions.Authentication.WinUI" />
<PackageReference Include="Uno.Extensions.Http.WinUI" />
<PackageReference Include="Uno.Extensions.Http.Kiota" />
<PackageReference Include="Uno.Extensions.Localization.WinUI" />
<PackageReference Include="Uno.Extensions.Logging.WinUI" />
<PackageReference Include="Uno.Extensions.Serialization" />
<PackageReference Include="Uno.Toolkit.WinUI" />
<PackageReference Include="Uno.Toolkit.WinUI.Material" />
<PackageReference Include="Uno.Material.WinUI" />
<PackageReference Include="CommunityToolkit.Mvvm" />
<PackageReference Include="Microsoft.Kiota.Abstractions" />
<PackageReference Include="Microsoft.Kiota.Http.HttpClientLibrary" />
<PackageReference Include="Microsoft.Kiota.Serialization.Json" />
```

Use central package management in `Directory.Packages.props`.

### Testable Core Library Packages

The `{Project}.Uno.Core` project is a plain `Microsoft.NET.Sdk` library, not an `Uno.Sdk` head. It must reference the packages needed to compile MVUX presentation records and navigation contracts directly through central package management:

```xml
<PackageReference Include="Uno.WinUI" />
<PackageReference Include="Uno.Extensions.Reactive" />
<PackageReference Include="Uno.Extensions.Navigation" />
<PackageReference Include="CommunityToolkit.Mvvm" />
<PackageReference Include="Microsoft.Kiota.Abstractions" />
<PackageReference Include="Microsoft.Kiota.Http.HttpClientLibrary" />
<PackageReference Include="Microsoft.Kiota.Serialization.Json" />
```

Do not add `Uno.Sdk` to `{Project}.Uno.Core`. Keep `Uno.Sdk` only on `src/UI/{Project}.Uno`.

## Project File Rules (`.csproj`)

Uno Platform uses an **MSBuild SDK package** (`Uno.Sdk`), not a .NET workload. Never run `dotnet workload install uno-*`.

### Canonical csproj Structure

```xml
<Project Sdk="Uno.Sdk/{VERSION}">
  <PropertyGroup>
    <!-- Clear singular TargetFramework inherited from Directory.Build.props -->
    <TargetFramework />
    <UnoTargetFrameworks>$(LatestStableTfm)-browserwasm;$(LatestStableTfm)-android;$(LatestStableTfm)-ios</UnoTargetFrameworks>
    <TargetFrameworks Condition="'$(TargetFrameworkOverride)'!=''">$(TargetFrameworkOverride)</TargetFrameworks>
    <TargetFrameworks Condition="'$(TargetFrameworkOverride)'=='' and '$(BuildAllUnoTargets)'=='true'">$(UnoTargetFrameworks)</TargetFrameworks>
    <TargetFrameworks Condition="'$(TargetFrameworkOverride)'=='' and '$(BuildAllUnoTargets)'!='true'">$(LatestStableTfm)-browserwasm</TargetFrameworks>
    <OutputType>Exe</OutputType>
    <UnoSingleProject>true</UnoSingleProject>
    <IsAotCompatible>true</IsAotCompatible>
    <NoWarn>$(NoWarn);IL2026;IL3050;XA4214</NoWarn>
    <ApplicationTitle>{AppName}</ApplicationTitle>
    <ApplicationId>com.{company}.{app}</ApplicationId>
    <UseMocks Condition="'$(UseMocks)'==''">false</UseMocks>
    <DefineConstants Condition="'$(UseMocks)'=='true'">$(DefineConstants);USE_MOCKS</DefineConstants>

    <UnoFeatures>
      Material;
      Hosting;
      Skia;
      SkiaRenderer;
      Toolkit;
      Logging;
      MVUX;
      Configuration;
      HttpKiota;
      Serialization;
      Localization;
      Navigation;
      ThemeService;
      Authentication;
    </UnoFeatures>
  </PropertyGroup>

  <ItemGroup>
    <Using Include="System.Collections.Immutable" />
  </ItemGroup>

  <PropertyGroup Condition="'$(TargetFramework)' != '' AND $(TargetFramework.Contains('-android'))">
    <!-- Appium/ADB sideloads only the APK, so Debug builds cannot rely on fast-deployed assemblies. -->
    <EmbedAssembliesIntoApk>true</EmbedAssembliesIntoApk>
    <AndroidEnableAssemblyCompression>false</AndroidEnableAssemblyCompression>
    <AndroidStoreUncompressedFileExtensions>.so;$(AndroidStoreUncompressedFileExtensions)</AndroidStoreUncompressedFileExtensions>
  </PropertyGroup>
</Project>
```

### Non-Negotiable csproj Rules

1. **SDK version**: Use the latest stable `Uno.Sdk` line that supports the project's target .NET TFM. An older `Uno.Sdk` line can bundle a `Uno.Wasm.Bootstrap` that does not support the current TFM; check Uno release notes when bumping the TFM.
2. **TargetFramework clearing**: When `Directory.Build.props` sets a singular `<TargetFramework>` for non-Uno projects, the Uno csproj MUST add `<TargetFramework />` before `<TargetFrameworks>` to clear the inherited value. Otherwise MSBuild merges both, causing `NETSDK1005`. **Do not rely on guarding the root prop with `Condition="'$(UnoSingleProject)' != 'true'"`** - that guard is evaluated during the early `Directory.Build.props` import, *before* the Uno `.csproj` PropertyGroup sets `UnoSingleProject=true`, so the singular `<TargetFramework>` still wins over `<TargetFrameworks>` and the build fails with `NETSDK1005`. Clearing it in the Uno csproj (`<TargetFramework />`) is the reliable fix; alternatively scope the root `<TargetFramework>` so it never reaches Uno heads.
3. **Targeted builds**: Build one platform at a time with `-p:TargetFrameworkOverride=$(LatestStableTfm)-browserwasm`, `-android`, or `-ios`. Do not use `-f`; the conditional `TargetFrameworks` property owns the effective target. Default builds target browserwasm only. For browserwasm test rebuilds, clean target `bin` and target `obj`, restore with `-p:BuildAllUnoTargets=true -p:EnableUnoWasm=true`, then build with `-p:TargetFrameworkOverride=$(LatestStableTfm)-browserwasm -p:EnableUnoWasm=true --no-restore -m:1`. Before Android/iOS package builds, run `dotnet restore src/UI/{Project}.Uno/{Project}.Uno.csproj -p:BuildAllUnoTargets=true`, then build the selected target with `--no-restore`; this keeps mobile Skia runtime packages in the NuGet asset graph.
4. **Entry point**: Uno SDK may not auto-generate `Program.Main` on the latest TFMs. For browserwasm, use the Chefs-style host builder entry point:

```csharp
#if __WASM__
using Uno.UI.Hosting;

namespace {Project}.Uno;

public class Program
{
    static async Task Main(string[] args)
    {
        var host = UnoPlatformHostBuilder.Create()
            .App(() => new App())
            .UseWebAssembly()
            .Build();

        await host.RunAsync();
    }
}
#endif
```

5. **Global using for ImmutableList**: MVUX `IListFeed<T>` requires `IImmutableList<T>`. Add `<Using Include="System.Collections.Immutable" />` to the `{Project}.Uno.Core` csproj where the MVUX records live.
6. **Aspire AppHost reference**: Do not add a direct Aspire `AddProject` reference to the Uno SDK project. Host browserwasm through a small ASP.NET Core wrapper project under `src/Host/{Project}.Uno.WasmHost/`, then register that wrapper in AppHost.

### Testable Core Library

Extract `Presentation/` (MVUX records), `Business/` (Models, Services), and `Client/` into a separate `{Project}.Uno.Core` class library targeting plain single-TFM (the same TFM the rest of the solution targets). This allows unit testing without the Uno SDK.

```text
src/UI/{Project}.Uno.Core/          <- single-TFM class lib (testable)
  Presentation/                     <- MVUX models, all in one assembly
  Business/Models/
  Business/Services/
  Client/
src/UI/{Project}.Uno/               <- Uno.Sdk (browserwasm, android, ios)
  App.xaml, App.xaml.cs, App.xaml.host.cs
  Views/                     <- XAML pages
  references {Project}.Uno.Core
src/Host/{Project}.Uno.WasmHost/    <- ASP.NET Core wrapper for Aspire browserwasm hosting
```

After extracting, **delete** the original files from the Uno project - do not leave duplicates. All MVUX partial records for one app must live in `{Project}.Uno.Core`; splitting them across the core library and the app head can make the MVUX generators emit duplicate `BindableXxx` wrapper types.

## App.xaml Rules

The `App.xaml` base class is `Application`, NOT `utu:App` (which doesn't exist):

```xml
<Application x:Class="{Namespace}.App"
             xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
    <Application.Resources>
        <ResourceDictionary>
            <ResourceDictionary.MergedDictionaries>
                <XamlControlsResources xmlns="using:Microsoft.UI.Xaml.Controls" />
                <MaterialToolkitTheme xmlns="using:Uno.Toolkit.UI.Material"
                                      ColorOverrideSource="ms-appx:///Styles/ColorPaletteOverride.xaml" />
                <ResourceDictionary Source="ms-appx:///Converters/Converters.xaml" />
                <ResourceDictionary Source="ms-appx:///Styles/AppStyles.xaml" />
            </ResourceDictionary.MergedDictionaries>
        </ResourceDictionary>
    </Application.Resources>
</Application>
```

### App.xaml Non-Negotiables

- Base element: `<Application>` - never `<utu:App>` or `<toolkit:App>`
- `MaterialToolkitTheme` namespace: `using:Uno.Toolkit.UI.Material` - NOT `using:Uno.Material`
- Do NOT add `<ToolkitResources xmlns="using:Uno.Toolkit.UI" />` as a separate merged dictionary (included via `MaterialToolkitTheme`)

- Put palette changes in `Styles/ColorPaletteOverride.xaml`; do not hard-code page-level hex colors.
- Put global converters in `Converters/Converters.xaml` and reusable control styles in `Styles/AppStyles.xaml`; pages consume resources instead of redefining them.

### App.xaml.cs Pattern

Follow the Uno Chefs reference app pattern:

```csharp
using Microsoft.Extensions.Hosting;
using {Project}.Uno.Views;

namespace {Project}.Uno;

public partial class App : Application
{
    public static Window? MainWindow;
    public static IHost? Host { get; private set; }

    public App() => this.InitializeComponent();

    protected override async void OnLaunched(LaunchActivatedEventArgs args)
    {
        var builder = this.CreateBuilder(args);
        ConfigureAppBuilder(builder);
        MainWindow = builder.Window;
        Host = await builder.NavigateAsync<Shell>();
    }
}
```

### Shell Control

Create a `Shell.xaml` UserControl with `ExtendedSplashScreen` as the loading container. The `Content` property MUST hold a `<Frame />` - this is what Uno Extensions Navigation writes page content into. The `LoadingContentTemplate` shows the spinner while the host boots. Both are required.

```xml
<UserControl x:Class="{Namespace}.Views.Shell"
             xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
             xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
             xmlns:utu="using:Uno.Toolkit.UI">
    <utu:ExtendedSplashScreen x:Name="Splash"
                              HorizontalAlignment="Stretch"
                              VerticalAlignment="Stretch"
                              HorizontalContentAlignment="Stretch"
                              VerticalContentAlignment="Stretch">
        <utu:ExtendedSplashScreen.LoadingContentTemplate>
            <DataTemplate>
                <Grid>
                    <ProgressRing IsActive="True"
                                  VerticalAlignment="Center"
                                  HorizontalAlignment="Center"
                                  Height="60" Width="60" />
                </Grid>
            </DataTemplate>
        </utu:ExtendedSplashScreen.LoadingContentTemplate>

        <utu:ExtendedSplashScreen.Content>
            <Frame />
        </utu:ExtendedSplashScreen.Content>
    </utu:ExtendedSplashScreen>
</UserControl>
```

`Shell.xaml.cs` MUST implement `IContentControlProvider` - this is how `NavigateAsync<Shell>()` locates the `Frame` for page navigation. Without it, the app starts but never renders any page content.

```csharp
using Microsoft.UI.Xaml.Controls;
using Uno.Toolkit.UI;
using Uno.UI.Extensions;

namespace {Namespace}.Views;

public sealed partial class Shell : UserControl, IContentControlProvider
{
    public ExtendedSplashScreen SplashScreen => Splash;
    public ContentControl ContentControl => Splash;
    public Frame? RootFrame => Splash.FindFirstDescendant<Frame>();

    public Shell() => this.InitializeComponent();
}
```

`ShellModel` MUST navigate to the first route on startup. Without this the Frame sits empty after the splash screen clears.

```csharp
using Uno.Extensions.Navigation;

namespace {Project}.Uno.Core.Presentation;

public partial record ShellModel
{
    private readonly INavigator _navigator;

    public ShellModel(INavigator navigator)
    {
        _navigator = navigator;
        _ = Start();
    }

    public async Task Start() => await _navigator.NavigateRouteAsync(this, "Main");
}
```

Navigate to `"Main"` only - **not** the full leaf path `"Main/{FirstPage}"`. The `Main` route's
`IsDefault` nested child (see [ui-uno-mvux.md](ui-uno-mvux.md) section Route Registration Pattern)
auto-loads the first content page *inside* MainPage's content region.

**Frame-vs-Visibility trap.** With the canonical responsive-menu MainPage (content host is a
Visibility region: `uen:Region.Navigator="Visibility"`, see
[ui-uno-navigation.md](ui-uno-navigation.md)), navigating the full leaf path `"Main/{FirstPage}"`
**flattens to the leaf** and renders it directly in Shell's `Frame` *without instantiating
MainPage* - so the app loses all chrome (no header, side-nav, or theme toggle) and `MainPage`'s ctor
never runs. The navigation still reports `success=True`, which masks the bug. Navigating just
`"Main"` displays MainPage and lets its `IsDefault` route fill the content region. (If MainPage's
content host were a plain `<Frame />` region instead of a Visibility region, the leaf path would
work - but the scaffold's responsive menu uses a Visibility region, so always navigate `"Main"`.)
Verified on Uno.Sdk 6.5.36 / Uno.Extensions Navigation / net10.0-browserwasm.

### Shell Non-Negotiables

- `ExtendedSplashScreen.Content` contains `<Frame />` - **never omit this**. The app will appear to load (spinner disappears) but show a blank screen because there is no navigation target.
- Shell code-behind implements `IContentControlProvider` - required by `NavigateAsync<Shell>()` to bind the `Frame`.
- `ShellModel` calls `NavigateRouteAsync(this, "Main")` in the constructor (fire-and-forget via `_ = Start()`) - this triggers the first navigation immediately after the host finishes loading. Navigate `"Main"`, never `"Main/{FirstPage}"` (see the Frame-vs-Visibility trap above).

Configure everything through `IApplicationBuilder`:

```csharp
builder
    .UseToolkitNavigation()
    .Configure(host => host
        .UseAuthentication(auth => auth.AddCustom(..., name: "CustomAuth"))
        .UseHttp((context, services) =>
        {
            var gatewayUrl =
#if __ANDROID__
                context.Configuration["AndroidGatewayBaseUrl"] ??
#elif __IOS__
                context.Configuration["IosGatewayBaseUrl"] ??
#endif
                context.Configuration["GatewayBaseUrl"] ?? "https://localhost:7200";

            // If the client was generated by Kiota (takes IRequestAdapter), use AddKiotaClient:
            //   services.AddKiotaClient<{Project}ApiClient>(context, options: new EndpointOptions { Url = gatewayUrl });
            //
            // If the client is a hand-written stub (takes HttpClient directly), use AddHttpClient:
            services
                .AddHttpClient<{Project}ApiClient>(client => client.BaseAddress = new Uri(gatewayUrl))
#if USE_MOCKS
                .ConfigurePrimaryHttpMessageHandler<MockHttpMessageHandler>()
#endif
            ;
        })
        .UseConfiguration(cfg => cfg.EmbeddedSource<App>())
        .UseLocalization()
        .UseSerialization(configure: ConfigureSerialization)
        .ConfigureServices((context, services) =>
        {
            // Use StrongReferenceMessenger - MVUX partial-record recipients registered
            // via Messenger.Register<TRecipient, TMessage> are not held alive elsewhere
            // and get GC'd under WeakReferenceMessenger. Cross-model refresh then stops
            // firing with no error.
            services.AddSingleton<IMessenger, StrongReferenceMessenger>();
            services.AddSingleton<I{Entity}Service, {Entity}Service>();
        })
        .UseNavigation(ReactiveViewModelMappings.ViewModelMappings, RegisterRoutes));
```

Non-negotiables:
- Always call Gateway URL from config. Use `AndroidGatewayBaseUrl` for emulator/device Android, `IosGatewayBaseUrl` for iOS, and `GatewayBaseUrl` as the browserwasm/default fallback.
- Register auth + HTTP + navigation in one place.
- Keep service registration in host config, not in views/models.

## Theme (IThemeService)

`ThemeService` (enabled via the `ThemeService` `<UnoFeatures>` entry) needs a **navigation/view
scope that carries the Window** - its ctor is `ThemeService(Window, IDispatcher, ISettings,
ILogger)`.

- **Never resolve `IThemeService` from `App.Host.Services`** (the root provider). The root scope has
  no `Window`, so `App.Host.Services.GetService<IThemeService>()` from `OnLaunched` or page
  code-behind throws `NullReferenceException` in `ThemeService..ctor`. On WASM this crashes the
  dispatcher mid-launch and the app chrome never renders (the failure looks like a navigation/chrome
  bug, not a theme bug).
- **Constructor-inject `IThemeService` into a model** (e.g. `MainModel`) and apply the default/
  initial theme + the toggle command there - the model is resolved within the navigation scope, so
  the Window is present. This matches the Uno Chefs `ThemeService` recipe.
- **Do not apply the initial theme in `App.OnLaunched`** - the scope is not ready yet. Apply it from
  the first model that owns chrome.

(Contrast: `IFormGuard` in [ui-uno-navigation.md](ui-uno-navigation.md) *is* safe to resolve from
`App.Host.Services` because it is a plain singleton with no `Window` dependency. The root-scope rule
is specific to services like `ThemeService` that capture the Window.)

## Mock vs Live API

Support both at scaffold time (`Features:UseMocks`).

```json
{
  "GatewayBaseUrl": "https://localhost:7200",
  "AndroidGatewayBaseUrl": "http://10.0.2.2:{GatewayHttpPort}",
  "IosGatewayBaseUrl": "https://localhost:7200",
  "Features": { "UseMocks": false }
}
```

If mocks enabled, use a custom `HttpMessageHandler`; otherwise call live Gateway.

For Android emulator live calls, prefer the Gateway HTTP endpoint through `10.0.2.2` unless the emulator trusts the development HTTPS certificate.

## Aspire WASM Wrapper Host

Use a wrapper host for Aspire. The Uno SDK project remains under `src/UI/{Project}.Uno/`; a plain ASP.NET Core project under `src/Host/{Project}.Uno.WasmHost/` builds and serves the browserwasm output.

Wrapper rules:

- The wrapper `.csproj` invokes the Uno build with `dotnet build "$(UnoWasmProject)" -p:TargetFrameworkOverride=$(UnoWasmTargetFramework) -p:Configuration=$(Configuration) -m:1`.
- Skip the wrapper build target during solution builds unless explicitly requested; otherwise full-solution builds can recursively rebuild the UI at surprising times.
- Guard the `BuildUnoWasm` target with **both** `'$(SkipUnoWasmBuild)' != 'true'` **and** `'$(BuildingInsideVisualStudio)' != 'true'`. In Visual Studio the Uno SDK project and the wrapper are both solution projects, so VS already builds `{Project}.Uno` (browserwasm) while the wrapper's `BeforeBuild` target rebuilds the same project -> CS2012 file-lock on the output assembly. `SkipUnoWasmBuild` does not cover this case because it is not set on a plain VS build; the `BuildingInsideVisualStudio` guard is required alongside it.
- `Program.cs` loads the Uno static-web-assets manifest with `StaticWebAssetsLoader.UseStaticWebAssets`.
- Map `.dat`, `.dll`, `.wasm`, and `.pdb` as binary/static files and verify `/_framework` plus `/_content` return 200 with non-empty bodies.
- In Aspire, register the wrapper, not the Uno SDK project:

```csharp
builder.AddProject<Projects.{Project}_Uno_WasmHost>("{project}-uno")
    .WithReference(gateway)
    .WaitFor(gateway)
    .WithExternalHttpEndpoints();
```

When the wrapper serves stale or mixed files after rebuilds, refresh by navigating to the root URL in a new browser tab. Uno browserwasm package hashes change per rebuild, so a normal reload can keep requesting old package paths.
