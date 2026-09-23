[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$xamlPath = Join-Path $projectRoot 'gui\MainWindow.xaml'
$helperPath = Join-Path $projectRoot 'gui\GuiHelpers.psm1'
$localizationPath = Join-Path $projectRoot 'gui\Localization.psm1'

Add-Type -AssemblyName PresentationCore -ErrorAction Stop
Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop
Import-Module -Name $helperPath -Force -ErrorAction Stop
Import-Module -Name $localizationPath -Force -ErrorAction Stop

function Assert-LayoutTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Code
    )
    if (-not $Condition) { throw $Code }
}

function Read-LayoutWindow {
    $text = [IO.File]::ReadAllText($xamlPath)
    $stringReader = New-Object IO.StringReader($text)
    $xmlReader = $null
    try {
        $xmlReader = [Xml.XmlReader]::Create($stringReader)
        return [Windows.Markup.XamlReader]::Load($xmlReader)
    }
    finally {
        if ($null -ne $xmlReader) { $xmlReader.Dispose() }
        $stringReader.Dispose()
    }
}

function Invoke-LayoutPump {
    param([ValidateRange(1, 1000)][int]$Milliseconds = 40)
    $frame = New-Object Windows.Threading.DispatcherFrame
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
    $handler = [EventHandler]({
        param($sender, $eventArgs)
        $timer.Stop()
        $frame.Continue = $false
    }.GetNewClosure())
    $timer.Add_Tick($handler)
    try {
        $timer.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame)
    }
    finally {
        $timer.Remove_Tick($handler)
        $timer.Stop()
    }
}

function Update-LayoutWindow {
    param([Parameter(Mandatory = $true)][object]$Window)
    [void]$Window.ApplyTemplate()
    [void]$Window.UpdateLayout()
    Invoke-LayoutPump
    [void]$Window.UpdateLayout()
}

function Get-VisualDescendants {
    param([AllowNull()][object]$Root)
    $result = New-Object Collections.ArrayList
    if ($null -eq $Root) { return @() }
    $queue = New-Object Collections.Queue
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        $count = 0
        try {
            $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount(
                $parent
            )
        }
        catch { $count = 0 }
        for ($index = 0; $index -lt $count; $index++) {
            $child = [System.Windows.Media.VisualTreeHelper]::GetChild(
                $parent,
                $index
            )
            [void]$result.Add($child)
            $queue.Enqueue($child)
        }
    }
    return @($result)
}

function Get-GridScrollViewer {
    param([Parameter(Mandatory = $true)][object]$Grid)
    [void]$Grid.ApplyTemplate()
    $named = $Grid.Template.FindName('DG_ScrollViewer', $Grid)
    if ($null -ne $named) { return $named }
    return @(Get-VisualDescendants -Root $Grid | Where-Object {
        $_ -is [Windows.Controls.ScrollViewer]
    } | Select-Object -First 1)[0]
}

function Get-Named {
    param(
        [Parameter(Mandatory = $true)][object]$Window,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $control = $Window.FindName($Name)
    if ($null -eq $control) { throw ('LAYOUT_CONTROL_MISSING_' + $Name) }
    return $control
}

function Apply-TestLanguage {
    param(
        [Parameter(Mandatory = $true)][object]$Window,
        [Parameter(Mandatory = $true)][string]$Language
    )
    $Window.Title = Get-QiehaoLocalizedString -Language $Language `
        -Key 'App.Title'
    $controlKeys = [ordered]@{
        HeaderTitleText = 'App.Title'
        ThemeLabelText = 'Theme.Label'
        LanguageLabelText = 'Language.Label'
        CodexClientLabelText = 'Section.CodexClient'
        CurrentAccountLabelText = 'Section.CurrentAccount'
        CurrentIdentityLabelText = 'Section.CurrentIdentity'
        WebChatGPTLabelText = 'Section.WebChatGPT'
        WebChatGPTText = 'WebChatGPT.Unchanged'
        WebChatGPTHintText = 'WebChatGPT.Hint'
        CodexSafetyHintText = 'Safety.Running'
        SavedAccountsHeadingText = 'Section.SavedAccounts'
        SearchAccountsLabelText = 'Search.Label'
        WorkspaceFirstAddHintText = 'Account.TeamFirstAddHint'
        SwitchButton = 'Button.Switch'
        VerifyButton = 'Button.Verify'
        RefreshButton = 'Button.Refresh'
        RefreshQuotaButton = 'Button.RefreshQuota'
        AddButton = 'Button.Add'
        RenameButton = 'Button.Rename'
        DeleteButton = 'Button.Delete'
        LaunchCodexButton = 'Button.LaunchCodex'
        LaunchSettingsButton = 'Button.LaunchSettings'
        RefreshStatusText = 'Status.Ready'
        BrowserSafetyFooterText = 'Footer.BrowserSafe'
    }
    foreach ($entry in $controlKeys.GetEnumerator()) {
        $control = Get-Named -Window $Window -Name ([string]$entry.Key)
        $value = Get-QiehaoLocalizedString -Language $Language `
            -Key ([string]$entry.Value)
        if ($null -ne $control.PSObject.Properties['Text']) {
            $control.Text = $value
        }
        else { $control.Content = $value }
    }
    (Get-Named -Window $Window -Name 'ProfileSearchTextBox').ToolTip =
        Get-QiehaoLocalizedString -Language $Language -Key 'Search.ToolTip'
    (Get-Named -Window $Window -Name 'LaunchTargetText').Text =
        Format-QiehaoLocalizedString -Language $Language `
            -Key 'Launch.Target' -Arguments @(
                Get-QiehaoLocalizedString -Language $Language `
                    -Key 'Launch.Status.AutoDetected'
            )
    $columnKeys = [ordered]@{
        ProfileColumn = 'Column.Profile'
        CurrentColumn = 'Column.Current'
        VerificationColumn = 'Column.Verification'
        HealthColumn = 'Column.Status'
        AuthColumn = 'Column.Auth'
        IdentityColumn = 'Column.Identity'
        MetadataColumn = 'Column.Metadata'
        UpdatedColumn = 'Column.Updated'
        QuotaColumn = 'Column.QuotaSnapshot'
    }
    foreach ($entry in $columnKeys.GetEnumerator()) {
        (Get-Named -Window $Window -Name ([string]$entry.Key)).Header =
            Get-QiehaoLocalizedString -Language $Language `
                -Key ([string]$entry.Value)
    }
}

function New-FakeLayoutRows {
    param(
        [ValidateRange(1, 10)][int]$Count,
        [Parameter(Mandatory = $true)][string]$Language
    )
    $activeName = if ($Count -ge 7) { 'Profile07' } else { 'Profile01' }
    $source = @(1..$Count | ForEach-Object {
        [pscustomobject]@{
            Profile = ('Profile{0:D2}' -f $_)
            Active = ($_ -eq 7 -or ($Count -lt 7 -and $_ -eq 1))
            Health = 'READY'
            AuthFile = 'PRESENT'
            IdentityMarker = 'PRESENT'
            Metadata = 'VALID'
            UpdatedAt = '2026-09-18T18:20:57.961374'
        }
    })
    $rows = @(ConvertTo-QiehaoGuiProfileRows -ProfileData $source `
        -ActiveProfile $activeName -ActiveProfileKnown)
    foreach ($row in $rows) {
        if ($Language -ceq 'en-US') {
            $activeKey = if ($row.ActiveCode -ceq 'Yes') {
                'Profile.Active.Yes'
            }
            else { 'Profile.Active.No' }
            $row.Active = Get-QiehaoLocalizedString -Language $Language `
                -Key $activeKey
            $row.Verification = Get-QiehaoLocalizedString `
                -Language $Language -Key 'Profile.Verification.Unverified'
            $row.Health = Get-QiehaoLocalizedString `
                -Language $Language -Key 'Profile.Health.Ready'
            $row.Auth = Get-QiehaoLocalizedString `
                -Language $Language -Key 'Profile.Artifact.Present'
            $row.Identity = $row.Auth
            $row.Metadata = Get-QiehaoLocalizedString `
                -Language $Language -Key 'Profile.Metadata.Valid'
        }
        $row | Add-Member -NotePropertyName QuotaSummary `
            -NotePropertyValue '5h 16% · Week 21%'
        $row | Add-Member -NotePropertyName QuotaToolTip `
            -NotePropertyValue ('Quota details for ' + [string]$row.Name)
    }
    return $rows
}

function Open-LayoutWindow {
    param(
        [Parameter(Mandatory = $true)][string]$Language,
        [ValidateRange(1, 10)][int]$ProfileCount = 2,
        [double]$Width = 1040,
        [double]$Height = 690,
        [switch]$IgnoreProductionMinHeight
    )
    $window = Read-LayoutWindow
    if ($IgnoreProductionMinHeight) { $window.MinHeight = 0 }
    Apply-TestLanguage -Window $window -Language $Language
    $grid = Get-Named -Window $window -Name 'ProfilesGrid'
    $grid.ItemsSource = @(New-FakeLayoutRows -Count $ProfileCount `
        -Language $Language)
    $window.WindowStartupLocation = 'Manual'
    $window.Left = -20000
    $window.Top = -20000
    $window.ShowInTaskbar = $false
    $window.Opacity = 0
    $window.Width = $Width
    $window.Height = $Height
    [void]$window.Show()
    Update-LayoutWindow -Window $window
    return $window
}

function Set-ProfileCount {
    param(
        [Parameter(Mandatory = $true)][object]$Window,
        [Parameter(Mandatory = $true)][string]$Language,
        [ValidateRange(1, 10)][int]$Count
    )
    $grid = Get-Named -Window $Window -Name 'ProfilesGrid'
    $grid.ItemsSource = @(New-FakeLayoutRows -Count $Count `
        -Language $Language)
    Update-LayoutWindow -Window $Window
    return @($grid.ItemsSource)
}

function Test-UniformProfileRowHeight {
    param(
        [Parameter(Mandatory = $true)][object]$Window,
        [Parameter(Mandatory = $true)][object]$Grid,
        [Parameter(Mandatory = $true)][object[]]$Rows
    )
    $heights = @()
    foreach ($item in $Rows) {
        [void]$Grid.ScrollIntoView($item)
        Update-LayoutWindow -Window $Window
        $index = [Array]::IndexOf($Rows, $item)
        $row = $Grid.ItemContainerGenerator.ContainerFromIndex($index)
        if ($null -eq $row) { return $false }
        $heights += [double]$row.ActualHeight
    }
    return (
        $heights.Count -eq $Rows.Count -and
        @($heights | Where-Object {
            [Math]::Abs($_ - 32.0) -gt 0.6
        }).Count -eq 0
    )
}

function Get-ColumnWidths {
    param([Parameter(Mandatory = $true)][object]$Window)
    $result = [ordered]@{}
    foreach ($name in @(
        'ProfileColumn','CurrentColumn','VerificationColumn','HealthColumn',
        'AuthColumn','IdentityColumn','MetadataColumn','UpdatedColumn',
        'QuotaColumn'
    )) {
        $result[$name] = [double](Get-Named -Window $Window -Name $name).ActualWidth
    }
    return $result
}

function Get-RowCellTextBlock {
    param(
        [Parameter(Mandatory = $true)][object]$Grid,
        [ValidateRange(0, 100)][int]$RowIndex,
        [ValidateRange(0, 20)][int]$ColumnIndex
    )
    $row = $Grid.ItemContainerGenerator.ContainerFromIndex($RowIndex)
    if ($null -eq $row) { return $null }
    $presenter = @(Get-VisualDescendants -Root $row | Where-Object {
        $_ -is [Windows.Controls.Primitives.DataGridCellsPresenter]
    } | Select-Object -First 1)[0]
    if ($null -eq $presenter) { return $null }
    $cell = $presenter.ItemContainerGenerator.ContainerFromIndex($ColumnIndex)
    if ($null -eq $cell) { return $null }
    return @(Get-VisualDescendants -Root $cell | Where-Object {
        $_ -is [Windows.Controls.TextBlock]
    } | Select-Object -First 1)[0]
}

function Test-CoreControlsVisible {
    param([Parameter(Mandatory = $true)][object]$Window)
    foreach ($name in @(
        'HeaderTitleText','ThemeComboBox','LanguageComboBox',
        'SavedAccountsHeadingText','ProfileSearchTextBox',
        'WorkspaceFirstAddHintText','ProfilesGrid',
        'SwitchButton','LaunchSettingsButton','RefreshStatusText'
    )) {
        $control = Get-Named -Window $Window -Name $name
        if (-not $control.IsVisible -or $control.ActualHeight -le 0) {
            return $false
        }
        try {
            $point = $control.TransformToAncestor($Window).Transform(
                (New-Object Windows.Point(0, 0))
            )
            if ($point.Y -lt 0 -or
                $point.Y + $control.ActualHeight -gt
                    $Window.ActualHeight + 0.5) {
                return $false
            }
        }
        catch { return $false }
    }
    $grid = Get-Named -Window $Window -Name 'ProfilesGrid'
    return ($grid.ActualHeight -ge 100)
}

function Measure-RequiredLayoutHeight {
    param([Parameter(Mandatory = $true)][string]$Language)
    $window = Open-LayoutWindow -Language $Language -ProfileCount 2 `
        -Width 960 -Height 720 -IgnoreProductionMinHeight
    try {
        foreach ($height in 600..720) {
            if (($height % 2) -ne 0) { continue }
            $window.Height = $height
            Update-LayoutWindow -Window $window
            $grid = Get-Named -Window $window -Name 'ProfilesGrid'
            $scroll = Get-GridScrollViewer -Grid $grid
            $row0 = $grid.ItemContainerGenerator.ContainerFromIndex(0)
            $row1 = $grid.ItemContainerGenerator.ContainerFromIndex(1)
            if ((Test-CoreControlsVisible -Window $window) -and
                $null -ne $scroll -and
                $scroll.ComputedVerticalScrollBarVisibility -eq
                    [Windows.Visibility]::Collapsed -and
                $null -ne $row0 -and $null -ne $row1 -and
                $row0.ActualHeight -ge 31 -and $row1.ActualHeight -ge 31) {
                return [double]$height
            }
        }
        throw ('LAYOUT_REQUIRED_HEIGHT_NOT_FOUND_' + $Language)
    }
    finally { $window.Close() }
}

function Get-HeaderFitState {
    param([Parameter(Mandatory = $true)][object]$Window)
    foreach ($name in @(
        'ProfileColumn','CurrentColumn','VerificationColumn','HealthColumn',
        'AuthColumn','IdentityColumn','MetadataColumn','UpdatedColumn',
        'QuotaColumn'
    )) {
        $column = Get-Named -Window $Window -Name $name
        $probe = New-Object Windows.Controls.TextBlock
        $probe.Text = [string]$column.Header
        $probe.FontFamily = $Window.FontFamily
        $probe.FontSize = 13
        $probe.FontWeight = [Windows.FontWeights]::SemiBold
        $probe.Measure((New-Object Windows.Size(
            [double]::PositiveInfinity,
            [double]::PositiveInfinity
        )))
        [pscustomobject]@{
            Name = $name
            Header = [string]$column.Header
            RequiredWidth = [Math]::Round($probe.DesiredSize.Width + 10, 1)
            ActualWidth = [Math]::Round([double]$column.ActualWidth, 1)
            Fits = ($probe.DesiredSize.Width + 10 -le $column.ActualWidth + 0.5)
        }
    }
}

$xamlText = [IO.File]::ReadAllText($xamlPath)
$updatedProbe = @(ConvertTo-QiehaoGuiProfileRows -ProfileData @(
    [pscustomobject]@{
        Profile = 'TimestampProbe'; Active = $true; Health = 'READY'
        AuthFile = 'PRESENT'; IdentityMarker = 'PRESENT'; Metadata = 'VALID'
        UpdatedAt = '2026-09-18T18:20:57.961374'
    }
) -ActiveProfile 'TimestampProbe' -ActiveProfileKnown)[0]
$updatedDisplayCompact = (
    [string]$updatedProbe.UpdatedRaw -ceq
        '2026-09-18T18:20:57.961374' -and
    [string]$updatedProbe.UpdatedDisplay -ceq '2026-09-18 18:20:57' -and
    [string]$updatedProbe.Updated -ceq '2026-09-18 18:20:57'
)

$requiredHeightZh = Measure-RequiredLayoutHeight -Language 'zh-CN'
$requiredHeightEn = Measure-RequiredLayoutHeight -Language 'en-US'
$productionProbe = Read-LayoutWindow
$chosenMinHeight = [double]$productionProbe.MinHeight
$chosenMinWidth = [double]$productionProbe.MinWidth
$productionProbe.Close()
$heightMargin = $chosenMinHeight - [Math]::Max(
    $requiredHeightZh,
    $requiredHeightEn
)
Assert-LayoutTest ($heightMargin -ge 6) ((
    'WINDOW_MIN_HEIGHT_MARGIN_TOO_SMALL|RequiredZh={0}|RequiredEn={1}|' +
    'Chosen={2}|Margin={3}') -f $requiredHeightZh,$requiredHeightEn,
        $chosenMinHeight,$heightMargin)

$languageResults = [ordered]@{}
foreach ($language in @('zh-CN','en-US')) {
    $window = Open-LayoutWindow -Language $language -ProfileCount 2 `
        -Width 1040 -Height 690
    try {
        $grid = Get-Named -Window $window -Name 'ProfilesGrid'
        $scroll = Get-GridScrollViewer -Grid $grid
        $defaultWidths = Get-ColumnWidths -Window $window
        $horizontalDefault = (
            $scroll.ComputedHorizontalScrollBarVisibility -eq
                [Windows.Visibility]::Collapsed -and
            $scroll.ScrollableWidth -le 0.5
        )
        $horizontalDefaultState = ('{0}/{1}' -f
            $scroll.ComputedHorizontalScrollBarVisibility,
            [Math]::Round([double]$scroll.ScrollableWidth, 1))

        $window.Width = $chosenMinWidth
        $window.Height = $chosenMinHeight
        Update-LayoutWindow -Window $window
        $scroll = Get-GridScrollViewer -Grid $grid
        $minWidths = Get-ColumnWidths -Window $window
        $horizontalMin = (
            $scroll.ComputedHorizontalScrollBarVisibility -eq
                [Windows.Visibility]::Collapsed -and
            $scroll.ScrollableWidth -le 0.5
        )
        $horizontalMinState = ('{0}/{1}' -f
            $scroll.ComputedHorizontalScrollBarVisibility,
            [Math]::Round([double]$scroll.ScrollableWidth, 1))
        $headerFitState = @(Get-HeaderFitState -Window $window)
        $headerFits = @($headerFitState | Where-Object {
            -not $_.Fits
        }).Count -eq 0
        $coreVisible = Test-CoreControlsVisible -Window $window

        $window.Width = 1340
        Update-LayoutWindow -Window $window
        $largeWidths = Get-ColumnWidths -Window $window
        $fixedNames = @(
            'CurrentColumn','VerificationColumn','HealthColumn','AuthColumn',
            'IdentityColumn','MetadataColumn','UpdatedColumn'
        )
        $fixedStable = @($fixedNames | Where-Object {
            [Math]::Abs($largeWidths[$_] - $minWidths[$_]) -gt 1.0
        }).Count -eq 0
        $responsive = (
            $fixedStable -and
            $defaultWidths.ProfileColumn -gt $minWidths.ProfileColumn + 5 -and
            $defaultWidths.QuotaColumn -gt $minWidths.QuotaColumn + 5 -and
            $largeWidths.ProfileColumn -gt $defaultWidths.ProfileColumn + 40 -and
            $largeWidths.QuotaColumn -gt $defaultWidths.QuotaColumn + 50
        )

        $window.Width = $chosenMinWidth
        Update-LayoutWindow -Window $window
        $headers = @(Get-VisualDescendants -Root $grid | Where-Object {
            $_ -is [Windows.Controls.Primitives.DataGridColumnHeader] -and
            $null -ne $_.Column
        })
        $headersCentered = (
            $headers.Count -eq 9 -and
            @($headers | Where-Object {
                $_.HorizontalContentAlignment -ne
                    [Windows.HorizontalAlignment]::Center -or
                $_.VerticalContentAlignment -ne
                    [Windows.VerticalAlignment]::Center -or
                $_.ActualHeight -lt 33 -or $_.ActualHeight -gt 35
            }).Count -eq 0
        )
        $headerVisualState = @($headers | ForEach-Object {
            [pscustomobject]@{
                Header = [string]$_.Content
                Horizontal = [string]$_.HorizontalContentAlignment
                Vertical = [string]$_.VerticalContentAlignment
                Height = [Math]::Round([double]$_.ActualHeight, 1)
            }
        })
        $fixedTextBlocks = @(1..7 | ForEach-Object {
            Get-RowCellTextBlock -Grid $grid -RowIndex 0 -ColumnIndex $_
        })
        $nameText = Get-RowCellTextBlock -Grid $grid -RowIndex 0 `
            -ColumnIndex 0
        $quotaText = Get-RowCellTextBlock -Grid $grid -RowIndex 0 `
            -ColumnIndex 8
        $fixedCentered = (
            @($fixedTextBlocks | Where-Object {
                $null -eq $_ -or
                $_.TextAlignment -ne [Windows.TextAlignment]::Center -or
                $_.VerticalAlignment -ne [Windows.VerticalAlignment]::Center
            }).Count -eq 0
        )
        $leftAligned = (
            $null -ne $nameText -and $null -ne $quotaText -and
            $nameText.TextAlignment -eq [Windows.TextAlignment]::Left -and
            $quotaText.TextAlignment -eq [Windows.TextAlignment]::Left -and
            $nameText.VerticalAlignment -eq
                [Windows.VerticalAlignment]::Center -and
            $quotaText.VerticalAlignment -eq
                [Windows.VerticalAlignment]::Center
        )
        $fontContract = (
            [string]$grid.FontFamily -match 'Microsoft YaHei UI' -and
            [Math]::Abs([double]$grid.FontSize - 13) -lt 0.1 -and
            [System.Windows.Media.TextOptions]::GetTextFormattingMode($grid) -eq
                [System.Windows.Media.TextFormattingMode]::Display -and
            [System.Windows.Media.TextOptions]::GetTextRenderingMode($grid) -eq
                [System.Windows.Media.TextRenderingMode]::ClearType
        )

        $profileColumn = Get-Named -Window $window -Name 'ProfileColumn'
        $profileColumn.MinWidth = 600
        $profileColumn.Width = New-Object Windows.Controls.DataGridLength(
            600,
            [Windows.Controls.DataGridLengthUnitType]::Pixel
        )
        Update-LayoutWindow -Window $window
        $scroll = Get-GridScrollViewer -Grid $grid
        $manualWideShowsHorizontal = (
            $scroll.ComputedHorizontalScrollBarVisibility -eq
                [Windows.Visibility]::Visible -and
            $scroll.ScrollableWidth -gt 0
        )
        $manualWideState = ('Window={0};Grid={1};Profile={2};Quota={3};' +
            'Visibility={4};Scrollable={5}') -f
            [Math]::Round([double]$window.ActualWidth, 1),
            [Math]::Round([double]$grid.ActualWidth, 1),
            [Math]::Round([double]$profileColumn.ActualWidth, 1),
            [Math]::Round([double](Get-Named -Window $window `
                -Name 'QuotaColumn').ActualWidth, 1),
            $scroll.ComputedHorizontalScrollBarVisibility,
            [Math]::Round([double]$scroll.ScrollableWidth, 1)
        $profileColumn.MinWidth = 120
        $profileColumn.Width = New-Object Windows.Controls.DataGridLength(
            1,
            [Windows.Controls.DataGridLengthUnitType]::Star
        )
        Update-LayoutWindow -Window $window
        $scroll = Get-GridScrollViewer -Grid $grid
        $manualRestoreHidesHorizontal = (
            $scroll.ComputedHorizontalScrollBarVisibility -eq
                [Windows.Visibility]::Collapsed -and
            $scroll.ScrollableWidth -le 0.5
        )
        $manualRestoreState = ('{0}/{1}' -f
            $scroll.ComputedHorizontalScrollBarVisibility,
            [Math]::Round([double]$scroll.ScrollableWidth, 1))

        $rows2 = Set-ProfileCount -Window $window -Language $language -Count 2
        $rows2Uniform = Test-UniformProfileRowHeight -Window $window `
            -Grid $grid -Rows $rows2
        $scroll = Get-GridScrollViewer -Grid $grid
        $twoNoVertical = (
            $scroll.ComputedVerticalScrollBarVisibility -eq
                [Windows.Visibility]::Collapsed -and
            $scroll.ScrollableHeight -le 0.5
        )
        $rows4 = Set-ProfileCount -Window $window -Language $language -Count 4
        $rows4Uniform = Test-UniformProfileRowHeight -Window $window `
            -Grid $grid -Rows $rows4
        $scroll = Get-GridScrollViewer -Grid $grid
        $rows4OverflowSafe = (
            $scroll.ComputedVerticalScrollBarVisibility -eq
                [Windows.Visibility]::Visible -or
            $scroll.ScrollableHeight -le 0.5
        )
        [void]$grid.ScrollIntoView($rows4[3])
        Update-LayoutWindow -Window $window
        $fourAccessible = (
            $rows4OverflowSafe -and $null -ne
                $grid.ItemContainerGenerator.ContainerFromIndex(3)
        )
        $rows6 = Set-ProfileCount -Window $window -Language $language -Count 6
        $rows6Uniform = Test-UniformProfileRowHeight -Window $window `
            -Grid $grid -Rows $rows6
        $scroll = Get-GridScrollViewer -Grid $grid
        $rows6OverflowSafe = (
            $scroll.ComputedVerticalScrollBarVisibility -eq
                [Windows.Visibility]::Visible -or
            $scroll.ScrollableHeight -le 0.5
        )
        [void]$grid.ScrollIntoView($rows6[5])
        Update-LayoutWindow -Window $window
        $sixAccessible = (
            $rows6OverflowSafe -and $null -ne
                $grid.ItemContainerGenerator.ContainerFromIndex(5)
        )

        $rows10 = Set-ProfileCount -Window $window -Language $language -Count 10
        $rows10Uniform = Test-UniformProfileRowHeight -Window $window `
            -Grid $grid -Rows $rows10
        $scroll = Get-GridScrollViewer -Grid $grid
        $tenVertical = (
            $scroll.ComputedVerticalScrollBarVisibility -eq
                [Windows.Visibility]::Visible -and
            $scroll.ScrollableHeight -gt 0 -and
            $scroll.ViewportHeight -gt 0
        )
        $grid.SelectedItem = $rows10[9]
        [void]$grid.ScrollIntoView($rows10[9])
        Update-LayoutWindow -Window $window
        $scroll = Get-GridScrollViewer -Grid $grid
        $lastRow = $grid.ItemContainerGenerator.ContainerFromIndex(9)
        $scrollLast = $null -ne $lastRow -and $scroll.VerticalOffset -gt 0
        $grid.SelectedItem = $rows10[0]
        [void]$grid.ScrollIntoView($rows10[0])
        Update-LayoutWindow -Window $window
        $firstRow = $grid.ItemContainerGenerator.ContainerFromIndex(0)
        $scrollFirst = $null -ne $firstRow -and $scroll.VerticalOffset -le 0.5

        $grid.SelectedItem = $null
        [void]$grid.ScrollIntoView($rows10[6])
        Update-LayoutWindow -Window $window
        $activeRow = $grid.ItemContainerGenerator.ContainerFromIndex(6)
        $activeText = Get-RowCellTextBlock -Grid $grid -RowIndex 6 `
            -ColumnIndex 1
        $expectedActiveText = Get-QiehaoLocalizedString `
            -Language $language -Key 'Profile.Active.Yes'
        $activeSurvives = (
            $null -ne $activeRow -and $null -ne $activeText -and
            [string]$activeText.Text -ceq $expectedActiveText -and
            [string]$activeRow.Background -ceq
                [string]$window.Resources['ActiveRowBrush'] -and
            $activeRow.FontWeight -eq [Windows.FontWeights]::SemiBold
        )
        $fixedUiVisible = (
            (Get-Named -Window $window -Name 'ProfileSearchTextBox').IsVisible -and
            (Get-Named -Window $window -Name 'SwitchButton').IsVisible -and
            (Get-Named -Window $window -Name 'RefreshStatusText').IsVisible
        )

        $languageResults[$language] = [pscustomobject]@{
            HeadersCentered = $headersCentered
            FixedCentered = $fixedCentered
            LeftAligned = $leftAligned
            HeaderFits = $headerFits
            FontContract = $fontContract
            Responsive = $responsive
            HorizontalDefault = $horizontalDefault
            HorizontalMin = $horizontalMin
            CoreVisible = $coreVisible
            ManualWide = $manualWideShowsHorizontal
            ManualRestore = $manualRestoreHidesHorizontal
            TwoNoVertical = $twoNoVertical
            FourAccessible = $fourAccessible
            SixAccessible = $sixAccessible
            TenVertical = $tenVertical
            ScrollLast = $scrollLast
            ScrollFirst = $scrollFirst
            ActiveSurvives = $activeSurvives
            FixedUiVisible = $fixedUiVisible
            UniformRows = (
                $rows2Uniform -and $rows4Uniform -and
                $rows6Uniform -and $rows10Uniform
            )
            HorizontalDefaultState = $horizontalDefaultState
            HorizontalMinState = $horizontalMinState
            ManualRestoreState = $manualRestoreState
            ManualWideState = $manualWideState
            HeaderFitState = $headerFitState
            HeaderVisualState = $headerVisualState
            FixedCellState = @($fixedTextBlocks | ForEach-Object {
                if ($null -eq $_) { return '<null>' }
                return ('{0}/{1}/{2}' -f $_.Text,
                    $_.TextAlignment,$_.VerticalAlignment)
            })
            NameCellState = if ($null -eq $nameText) { '<null>' } else {
                '{0}/{1}/{2}' -f $nameText.Text,$nameText.TextAlignment,
                    $nameText.VerticalAlignment
            }
            QuotaCellState = if ($null -eq $quotaText) { '<null>' } else {
                '{0}/{1}/{2}' -f $quotaText.Text,$quotaText.TextAlignment,
                    $quotaText.VerticalAlignment
            }
            ActiveState = ('Text={0};RowBackground={1};ExpectedBackground={2}' -f
                $(if ($null -eq $activeText) { '<null>' } else { $activeText.Text }),
                $(if ($null -eq $activeRow) { '<null>' } else { $activeRow.Background }),
                $window.Resources['ActiveRowBrush'])
            MinNameWidth = [Math]::Round($minWidths.ProfileColumn, 1)
            DefaultNameWidth = [Math]::Round($defaultWidths.ProfileColumn, 1)
            LargeNameWidth = [Math]::Round($largeWidths.ProfileColumn, 1)
            MinQuotaWidth = [Math]::Round($minWidths.QuotaColumn, 1)
            DefaultQuotaWidth = [Math]::Round($defaultWidths.QuotaColumn, 1)
            LargeQuotaWidth = [Math]::Round($largeWidths.QuotaColumn, 1)
        }
    }
    finally { $window.Close() }
}

$zh = $languageResults['zh-CN']
$en = $languageResults['en-US']
$both = @($zh, $en)
function Test-Both {
    param([Parameter(Mandatory = $true)][string]$Property)
    foreach ($item in $both) {
        if (-not [bool]$item.PSObject.Properties[$Property].Value) {
            return $false
        }
    }
    return $true
}

function Test-AllProperties {
    param(
        [Parameter(Mandatory = $true)][object]$Item,
        [Parameter(Mandatory = $true)][string[]]$Properties
    )
    foreach ($property in $Properties) {
        if (-not [bool]$Item.PSObject.Properties[$property].Value) {
            return $false
        }
    }
    return $true
}

$results = [ordered]@{
    AccountGridHeadersCentered = Test-Both -Property 'HeadersCentered'
    FixedColumnsCentered = Test-Both -Property 'FixedCentered'
    NameColumnLeftAligned = Test-Both -Property 'LeftAligned'
    QuotaColumnLeftAligned = Test-Both -Property 'LeftAligned'
    UpdatedDisplayCompact = $updatedDisplayCompact
    ResponsiveColumnsAtDefaultWidth = Test-Both -Property 'Responsive'
    ResponsiveColumnsAtMinWidth = Test-Both -Property 'Responsive'
    NameColumnShrinksWithWindow = Test-Both -Property 'Responsive'
    QuotaColumnShrinksWithWindow = Test-Both -Property 'Responsive'
    HorizontalScrollCollapsedAtDefault = Test-Both `
        -Property 'HorizontalDefault'
    HorizontalScrollCollapsedAtMinWidth = Test-Both `
        -Property 'HorizontalMin'
    WindowMinHeightKeepsCoreVisible = Test-Both -Property 'CoreVisible'
    WindowCannotCollapseAccountArea = ($heightMargin -ge 6)
    TwoProfilesNoVerticalScroll = Test-Both -Property 'TwoNoVertical'
    FourProfilesAccessible = Test-Both -Property 'FourAccessible'
    SixProfilesAccessible = Test-Both -Property 'SixAccessible'
    TenProfilesAccessible = Test-Both -Property 'TenVertical'
    TenProfilesUsesInternalVerticalScroll = Test-Both -Property 'TenVertical'
    SearchBarRemainsVisible = Test-Both -Property 'FixedUiVisible'
    ActionButtonsRemainVisible = Test-Both -Property 'FixedUiVisible'
    ScrollToLastProfile = Test-Both -Property 'ScrollLast'
    ScrollBackToFirstProfile = Test-Both -Property 'ScrollFirst'
    ActiveProfileSurvivesVirtualization = Test-Both -Property 'ActiveSurvives'
    ProfileRowsUniformHeight = Test-Both -Property 'UniformRows'
    ManualWideColumnShowsHorizontal = Test-Both -Property 'ManualWide'
    ManualRestoreHidesHorizontal = Test-Both -Property 'ManualRestore'
    ZhCnLayoutPass = Test-AllProperties -Item $zh -Properties @(
        'HeadersCentered','FixedCentered','LeftAligned','HeaderFits',
        'FontContract','Responsive','HorizontalDefault','HorizontalMin',
        'CoreVisible','ManualWide','ManualRestore','TwoNoVertical',
        'FourAccessible','SixAccessible','TenVertical','ScrollLast',
        'ScrollFirst','ActiveSurvives','FixedUiVisible','UniformRows'
    )
    EnUsLayoutPass = Test-AllProperties -Item $en -Properties @(
        'HeadersCentered','FixedCentered','LeftAligned','HeaderFits',
        'FontContract','Responsive','HorizontalDefault','HorizontalMin',
        'CoreVisible','ManualWide','ManualRestore','TwoNoVertical',
        'FourAccessible','SixAccessible','TenVertical','ScrollLast',
        'ScrollFirst','ActiveSurvives','FixedUiVisible','UniformRows'
    )
}

Write-Output ('MeasuredRequiredHeightZhCn={0}' -f $requiredHeightZh)
Write-Output ('MeasuredRequiredHeightEnUs={0}' -f $requiredHeightEn)
Write-Output ('ChosenMinHeight={0}' -f $chosenMinHeight)
Write-Output ('MinHeightSafetyMargin={0}' -f $heightMargin)
Write-Output ('ChosenMinWidth={0}' -f $chosenMinWidth)
Write-Output ('ZhCnColumnWidths=Name:{0}/{1}/{2};Quota:{3}/{4}/{5}' -f
    $zh.MinNameWidth,$zh.DefaultNameWidth,$zh.LargeNameWidth,
    $zh.MinQuotaWidth,$zh.DefaultQuotaWidth,$zh.LargeQuotaWidth)
Write-Output ('EnUsColumnWidths=Name:{0}/{1}/{2};Quota:{3}/{4}/{5}' -f
    $en.MinNameWidth,$en.DefaultNameWidth,$en.LargeNameWidth,
    $en.MinQuotaWidth,$en.DefaultQuotaWidth,$en.LargeQuotaWidth)
foreach ($entry in $results.GetEnumerator()) {
    if (-not [bool]$entry.Value) {
        Write-Output ('LayoutFailureDiagnostics=' +
            ($languageResults | ConvertTo-Json -Depth 5 -Compress))
        throw ('ACCOUNT_GRID_LAYOUT_FAILED_' + [string]$entry.Key)
    }
    Write-Output ([string]$entry.Key + '=True')
}
Write-Output 'ACCOUNT_GRID_LAYOUT_SELFTEST_PASS'
