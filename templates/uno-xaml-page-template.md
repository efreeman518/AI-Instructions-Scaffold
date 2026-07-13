# XAML Page Template

| | |
|---|---|
| **Files** | `Views/{Entity}ListPage.xaml`, `{Entity}Page.xaml` + code-behind |
| **Depends on** | [uno-mvux-model-template](uno-mvux-model-template.md) |
| **Referenced by** | [ui-uno.md](../skills/ui-uno.md) |

## Design Standard: Single Entity Page

Each main entity gets **two** XAML pages:
- **`{Entity}ListPage`** - list/search, navigates to entity page
- **`{Entity}Page`** - unified add/edit with form fields + children (comments, checklist, etc.)

This replaces the old 3-page pattern (List + Detail + Create/Edit). The entity page:
- Shows form fields (title, description, etc.) always
- Shows children sections (checklist, comments, attachments) only in edit mode
- Has Save button (text changes: "Save" vs "Update") and Delete button (edit mode only)
- Uses `FormTextBoxStyle` for visible borders on all input fields

## List Page

When the whole row navigates, make the item root a transparent `Button` with `uen:Navigation.Request` and `uen:Navigation.Data`. The button supplies reliable pointer/keyboard activation and accessibility semantics; attached navigation on a non-interactive `Border` is not an equivalent click target. Do not nest row-action buttons inside it - rows with independent actions use a non-navigating container plus explicit action buttons.

```xml
<Page x:Class="{Project}.Uno.Views.{Entity}ListPage"
      x:Name="{Entity}ListRoot"
      xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      xmlns:uen="using:Uno.Extensions.Navigation.UI"
      xmlns:utu="using:Uno.Toolkit.UI"
      xmlns:uer="using:Uno.Extensions.Reactive.UI"
      Background="{ThemeResource BackgroundBrush}">

    <Grid Padding="{utu:Responsive Normal='16,16,16,16', Wide='24,24,24,24'}" RowSpacing="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto" />
            <RowDefinition Height="Auto" />
            <RowDefinition Height="*" />
        </Grid.RowDefinitions>

        <!-- Header -->
        <Grid Grid.Row="0" ColumnSpacing="12">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*" />
                <ColumnDefinition Width="Auto" />
            </Grid.ColumnDefinitions>
            <utu:AutoLayout Spacing="2">
                <TextBlock Text="{Entity}s" Style="{StaticResource TitleLarge}" />
                <TextBlock Text="Manage your {entity}s"
                           Style="{StaticResource BodyMedium}"
                           Foreground="{ThemeResource OnSurfaceVariantBrush}" />
            </utu:AutoLayout>
            <Button Grid.Column="1"
                    uen:Navigation.Request="{Entity}Item"
                    Style="{StaticResource FabButtonStyle}">
                <StackPanel Orientation="Horizontal" Spacing="8">
                    <FontIcon Glyph="&#xE710;" FontSize="14" />
                    <TextBlock Text="New {Entity}" VerticalAlignment="Center" />
                </StackPanel>
            </Button>
        </Grid>

        <!-- Search -->
        <TextBox Grid.Row="1" PlaceholderText="Search..."
                 Text="{Binding SearchTerm, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}" />

        <!-- Feed-bound list -->
        <uer:FeedView Grid.Row="2" Source="{Binding Items}">
            <uer:FeedView.ValueTemplate>
                <DataTemplate>
                    <ListView ItemsSource="{Binding Data}" SelectionMode="None">
                        <ListView.ItemTemplate>
                            <DataTemplate>
                                <Button uen:Navigation.Request="{Entity}Item"
                                        uen:Navigation.Data="{Binding}"
                                        HorizontalAlignment="Stretch"
                                        HorizontalContentAlignment="Stretch"
                                        Background="Transparent"
                                        BorderThickness="0"
                                        Padding="0"
                                        AutomationProperties.Name="{Binding Title}">
                                    <Border Style="{StaticResource ListItemCardStyle}">
                                        <Grid ColumnSpacing="12">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="Auto" />
                                                <ColumnDefinition Width="*" />
                                                <ColumnDefinition Width="Auto" />
                                            </Grid.ColumnDefinitions>
                                            <FontIcon Grid.Column="0" Glyph="&#xE9D5;" FontSize="16"
                                                      Foreground="{ThemeResource PrimaryBrush}"
                                                      VerticalAlignment="Center" />
                                            <TextBlock Grid.Column="1" Text="{Binding Title}"
                                                       Style="{StaticResource BodyStrongTextBlockStyle}"
                                                       TextTrimming="CharacterEllipsis" />
                                            <Border Grid.Column="2" Style="{StaticResource BadgeStyle}">
                                                <TextBlock Text="{Binding Status}" Style="{StaticResource BadgeTextStyle}" />
                                            </Border>
                                        </Grid>
                                    </Border>
                                </Button>
                            </DataTemplate>
                        </ListView.ItemTemplate>
                    </ListView>
                </DataTemplate>
            </uer:FeedView.ValueTemplate>
            <uer:FeedView.NoneTemplate>
                <DataTemplate>
                    <TextBlock Text="No items found" Style="{StaticResource EmptyStateTextStyle}" />
                </DataTemplate>
            </uer:FeedView.NoneTemplate>
        </uer:FeedView>
    </Grid>
</Page>
```

## Entity Page (Unified Add/Edit + Children)

```xml
<Page x:Class="{Project}.Uno.Views.{Entity}Page"
      x:Name="{Entity}Root"
      xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
      xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
      xmlns:uen="using:Uno.Extensions.Navigation.UI"
      xmlns:utu="using:Uno.Toolkit.UI"
      xmlns:uer="using:Uno.Extensions.Reactive.UI"
      Background="{ThemeResource BackgroundBrush}">

    <ScrollViewer>
        <utu:AutoLayout Spacing="20"
                        Padding="{utu:Responsive Normal='16,12,16,24', Wide='32,20,32,32'}"
                        MaxWidth="{StaticResource ContentMaxWidth}">

            <!-- Back link -->
            <Button uen:Navigation.Request="{Entity}List"
                    Style="{StaticResource TextButtonStyle}" Padding="0,4">
                <StackPanel Orientation="Horizontal" Spacing="6">
                    <FontIcon Glyph="&#xE72B;" FontSize="12" />
                    <TextBlock Text="Back to {Entity}s" Style="{StaticResource LabelMedium}" />
                </StackPanel>
            </Button>

            <!-- Header + action buttons -->
            <Grid ColumnSpacing="12">
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="*" />
                    <ColumnDefinition Width="Auto" />
                </Grid.ColumnDefinitions>
                <utu:AutoLayout Spacing="4">
                    <TextBlock Text="{Binding FormHeader}" Style="{StaticResource TitleLarge}" />
                </utu:AutoLayout>
                <StackPanel Grid.Column="1"
                            Orientation="{utu:Responsive Normal=Vertical, Wide=Horizontal}"
                            Spacing="8" VerticalAlignment="Top">
                    <Button Content="{Binding SaveButtonText}" Command="{Binding Save}"
                            Style="{StaticResource FormActionButtonStyle}" />
                    <Button Content="Delete" Command="{Binding Delete}"
                            Style="{StaticResource DangerButtonStyle}"
                            Visibility="{Binding IsEditMode}" />
                </StackPanel>
            </Grid>

            <!-- =========== Form Fields =========== -->
            <Border Style="{StaticResource InlineFormCardStyle}">
                <utu:AutoLayout Spacing="16">
                    <TextBox Header="Title"
                             Text="{Binding Title, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                             PlaceholderText="Enter title..."
                             Style="{StaticResource FormTextBoxStyle}" />
                    <TextBox Header="Description"
                             Text="{Binding Description, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                             AcceptsReturn="True" TextWrapping="Wrap" MinHeight="100"
                             PlaceholderText="Add details..."
                             Style="{StaticResource FormTextBoxStyle}" />
                    <!-- Add more form fields per entity properties -->
                </utu:AutoLayout>
            </Border>

            <!-- =========== Children Section (edit mode only) =========== -->
            <!-- Repeat this pattern for each child collection (comments, checklist items, etc.) -->
            <utu:CardContentControl Style="{StaticResource FilledCardContentControlStyle}"
                                    Visibility="{Binding IsEditMode}">
                <utu:AutoLayout Spacing="8">
                    <!-- Section header -->
                    <Grid ColumnSpacing="8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto" />
                            <ColumnDefinition Width="*" />
                        </Grid.ColumnDefinitions>
                        <FontIcon Glyph="&#xE8F2;" FontSize="18"
                                  Foreground="{StaticResource AccentInfoBrush}" VerticalAlignment="Center" />
                        <TextBlock Grid.Column="1" Text="{ChildEntity}s" Style="{StaticResource TitleSmall}" />
                    </Grid>

                    <!-- Child list -->
                    <uer:FeedView Source="{Binding {ChildEntity}s}">
                        <uer:FeedView.ValueTemplate>
                            <DataTemplate>
                                <ListView ItemsSource="{Binding Data}" SelectionMode="None">
                                    <ListView.ItemTemplate>
                                        <DataTemplate>
                                            <Border Style="{StaticResource ListItemCardStyle}">
                                                <Grid ColumnSpacing="8">
                                                    <Grid.ColumnDefinitions>
                                                        <ColumnDefinition Width="*" />
                                                        <ColumnDefinition Width="Auto" />
                                                    </Grid.ColumnDefinitions>
                                                    <TextBlock Text="{Binding Body}" TextWrapping="Wrap" />
                                                    <Button Grid.Column="1" Content="&#xE74D;"
                                                            FontFamily="{ThemeResource SymbolThemeFontFamily}" FontSize="14"
                                                            Command="{utu:AncestorBinding AncestorType=uer:FeedView, Path=DataContext.Delete{ChildEntity}}"
                                                            CommandParameter="{Binding}"
                                                            Background="Transparent" Padding="6" Opacity="0.5" />
                                                </Grid>
                                            </Border>
                                        </DataTemplate>
                                    </ListView.ItemTemplate>
                                </ListView>
                            </DataTemplate>
                        </uer:FeedView.ValueTemplate>
                        <uer:FeedView.NoneTemplate>
                            <DataTemplate>
                                <TextBlock Text="No items yet" Opacity="0.4" FontStyle="Italic" />
                            </DataTemplate>
                        </uer:FeedView.NoneTemplate>
                    </uer:FeedView>

                    <!-- Inline add form -->
                    <Grid ColumnSpacing="8">
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="*" />
                            <ColumnDefinition Width="Auto" />
                        </Grid.ColumnDefinitions>
                        <TextBox PlaceholderText="Add {childEntity}..."
                                 Text="{Binding New{ChildEntity}Body, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                                 Style="{StaticResource FormTextBoxStyle}" />
                        <Button Grid.Column="1" Content="Add" Command="{Binding Add{ChildEntity}}"
                                Style="{StaticResource FilledButtonStyle}" Padding="16,6" />
                    </Grid>
                </utu:AutoLayout>
            </utu:CardContentControl>

        </utu:AutoLayout>
    </ScrollViewer>
</Page>
```

## Code-Behind (same for all pages)

```csharp
namespace {Project}.Uno.Views;

public sealed partial class {Entity}ListPage : Page
{
    public {Entity}ListPage() => this.InitializeComponent();
}
```

```csharp
namespace {Project}.Uno.Views;

public sealed partial class {Entity}Page : Page
{
    public {Entity}Page() => this.InitializeComponent();
}
```

## Rules

- Code-behind: constructor + `InitializeComponent()` only
- All data binding targets the MVUX model (auto-set as `DataContext`)
- Use `uer:FeedView` to bind to `IFeed` / `IListFeed` / `IState`
- Use `uen:Navigation.Request` for declarative navigation on list items
- Use `uen:Navigation.Data` to pass the selected item as navigation data
- Use `utu:AutoLayout` for layout, `utu:Responsive` for adaptive breakpoints
- **`FormTextBoxStyle`** on all TextBox inputs for visible borders
- **Children use `utu:AncestorBinding`** to reach parent DataContext commands from within FeedView templates
- **`Visibility="{Binding IsEditMode}"`** on children sections and Delete button
- **Inline add forms** at bottom of each child section (TextBox + Add button)
- Reference Material theme resources: `{ThemeResource OnSurfaceBrush}`, `{ThemeResource SurfaceBrush}`, etc.
- Use `{StaticResource TitleSmall}`, `{StaticResource BodyMedium}`, etc. for typography
- Register all custom `DataTemplate`s in `Page.Resources` or in `Views/Templates/`
