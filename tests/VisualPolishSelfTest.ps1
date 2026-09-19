[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$xamlPath = Join-Path $projectRoot 'gui\MainWindow.xaml'
$guiPath = Join-Path $projectRoot 'gui\QiehaoGui.ps1'
$helperPath = Join-Path $projectRoot 'gui\GuiHelpers.psm1'
$localizationPath = Join-Path $projectRoot 'gui\Localization.psm1'

Add-Type -AssemblyName PresentationCore -ErrorAction Stop
Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop
Import-Module -Name $helperPath -Force -ErrorAction Stop
Import-Module -Name $localizationPath -Force -ErrorAction Stop

function Assert-VisualPolish {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw $Code }
}

function Read-VisualWindow {
    $reader = $null
    $stringReader = New-Object IO.StringReader(
        [IO.File]::ReadAllText($xamlPath)
    )
    try {
        $reader = [Xml.XmlReader]::Create($stringReader)
        return [Windows.Markup.XamlReader]::Load($reader)
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        $stringReader.Dispose()
    }
}

function Invoke-VisualPump {
    $frame = New-Object Windows.Threading.DispatcherFrame
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(45)
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

function Update-VisualWindow {
    param([object]$Window)
    [void]$Window.ApplyTemplate()
    [void]$Window.UpdateLayout()
    Invoke-VisualPump
    [void]$Window.UpdateLayout()
}

function Get-VisualChildren {
    param([AllowNull()][object]$Root)
    if ($null -eq $Root) { return @() }
    $found = New-Object Collections.ArrayList
    $queue = New-Object Collections.Queue
    $queue.Enqueue($Root)
    while ($queue.Count -gt 0) {
        $parent = $queue.Dequeue()
        try { $count = [Windows.Media.VisualTreeHelper]::GetChildrenCount($parent) }
        catch { $count = 0 }
        for ($index = 0; $index -lt $count; $index++) {
            $child = [Windows.Media.VisualTreeHelper]::GetChild($parent, $index)
            [void]$found.Add($child)
            $queue.Enqueue($child)
        }
    }
    return @($found)
}

function Get-VisualNamed {
    param([object]$Window, [string]$Name)
    $control = $Window.FindName($Name)
    if ($null -eq $control) { throw ('VISUAL_CONTROL_MISSING_' + $Name) }
    return $control
}

function New-VisualBrush {
    param([string]$Color)
    $brush = New-Object Windows.Media.SolidColorBrush
    $brush.Color = [Windows.Media.ColorConverter]::ConvertFromString($Color)
    if ($brush.CanFreeze) { $brush.Freeze() }
    return $brush
}

function New-VisualGradientBrush {
    param(
        [Parameter(Mandatory = $true)][string]$Top,
        [Parameter(Mandatory = $true)][string]$Bottom
    )
    $brush = New-Object Windows.Media.LinearGradientBrush
    $brush.StartPoint = New-Object Windows.Point(0, 0)
    $brush.EndPoint = New-Object Windows.Point(0, 1)
    $brush.GradientStops.Add((New-Object Windows.Media.GradientStop(
        ([Windows.Media.ColorConverter]::ConvertFromString($Top)), 0
    )))
    $brush.GradientStops.Add((New-Object Windows.Media.GradientStop(
        ([Windows.Media.ColorConverter]::ConvertFromString($Bottom)), 1
    )))
    if ($brush.CanFreeze) { $brush.Freeze() }
    return $brush
}

function Set-VisualBackgroundImage {
    param([object]$Window, [object]$Theme)
    $path = Join-Path $projectRoot (
        'gui\assets\backgrounds\' + [string]$Theme.FileName
    )
    if (-not [IO.File]::Exists($path)) {
        throw ('VISUAL_BACKGROUND_MISSING_' + [string]$Theme.Id)
    }
    $bitmap = New-Object Windows.Media.Imaging.BitmapImage
    $bitmap.BeginInit()
    $bitmap.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $bitmap.UriSource = New-Object Uri($path, [UriKind]::Absolute)
    $bitmap.EndInit()
    if ($bitmap.CanFreeze) { $bitmap.Freeze() }
    (Get-VisualNamed $Window 'BackgroundImage').Source = $bitmap
}

function Set-VisualTheme {
    param([object]$Window, [object]$Theme)
    $map = [ordered]@{
        PanelBorderBrush = 'CardBorder'
        TextPrimaryBrush = 'TextPrimary'; TextSecondaryBrush = 'TextSecondary'
        TextMutedBrush = 'TextMuted'; ButtonDisabledBrush = 'DisabledBackground'
        BrandWatermarkBrush = 'BrandWatermark'
        ActiveRowBrush = 'GridActive'; ActiveSelectedRowBrush = 'GridActiveSelected'
        SelectedRowBrush = 'GridSelected'; GridHoverBrush = 'GridHover'
        ActiveBorderBrush = 'ActiveBorderTint'
        ColumnHeaderBackgroundBrush = 'GridHeader'
        ColumnHeaderForegroundBrush = 'ColumnHeaderForegroundTint'
        ColumnHeaderBorderBrush = 'ColumnHeaderBorderTint'
        CurrentYesBrush = 'CurrentYesTint'; CurrentNoBrush = 'CurrentNoTint'
        SuccessBrush = 'Positive'; InfoBrush = 'Info'; WarningBrush = 'Warning'
        DangerBrush = 'Danger'; ButtonOnAccentBrush = 'ButtonOnAccent'
        PrimaryButtonBrush = 'Primary'; PrimaryButtonHoverBrush = 'PrimaryHover'
        PrimaryButtonPressedBrush = 'PrimaryPressed'
        PositiveButtonBrush = 'Positive'; PositiveButtonHoverBrush = 'PositiveHover'
        PositiveButtonPressedBrush = 'PositivePressed'
        InfoButtonBrush = 'Info'; InfoButtonHoverBrush = 'InfoHover'
        InfoButtonPressedBrush = 'InfoPressed'; AccentButtonBrush = 'Accent'
        AccentButtonHoverBrush = 'AccentHover'; AccentButtonPressedBrush = 'AccentPressed'
        SecondaryButtonBrush = 'Secondary'; SecondaryButtonHoverBrush = 'SecondaryHover'
        SecondaryButtonPressedBrush = 'SecondaryPressed'
        DangerButtonSolidBrush = 'Danger'; DangerButtonHoverBrush = 'DangerHover'
        DangerButtonPressedBrush = 'DangerPressed'
        ControlBackgroundBrush = 'ControlBackground'; ControlBorderBrush = 'ControlBorder'
        FocusRingBrush = 'FocusRing'; ToolTipBackgroundBrush = 'ToolTipBackground'
        ToolTipBorderBrush = 'ToolTipBorder'; ToolTipForegroundBrush = 'ToolTipForeground'
    }
    foreach ($entry in $map.GetEnumerator()) {
        $brush = New-VisualBrush -Color ([string]$Theme.([string]$entry.Value))
        $Window.Resources[[string]$entry.Key] = $brush.PSObject.BaseObject
    }
    $panelBrush = New-VisualGradientBrush -Top $Theme.CardTop `
        -Bottom $Theme.CardBottom
    $Window.Resources['PanelBrush'] = $panelBrush.PSObject.BaseObject
    $brush = New-VisualBrush $Theme.Warning
    $Window.Resources['RunningWarningBrush'] = $brush.PSObject.BaseObject
    $Window.Resources['UnknownWarningBrush'] = $brush.PSObject.BaseObject
    $brush = New-VisualBrush $(
        if ($Theme.OverlayMode -ceq 'Dark') { '#3AFFFFFF' } else { '#68FFFFFF' }
    )
    $Window.Resources['GridBackgroundBrush'] = $brush.PSObject.BaseObject
    $brush = New-VisualBrush $(
        if ($Theme.OverlayMode -ceq 'Dark') { '#25FFFFFF' } else { '#50FFFFFF' }
    )
    $Window.Resources['GridRowBrush'] = $brush.PSObject.BaseObject
    $brush = New-VisualBrush $(
        if ($Theme.OverlayMode -ceq 'Dark') { '#16FFFFFF' } else { '#36FFFFFF' }
    )
    $Window.Resources['GridAltRowBrush'] = $brush.PSObject.BaseObject
    $Window.Background = $Window.Resources['PanelBrush']
    $Window.Foreground = $Window.Resources['TextPrimaryBrush']
    (Get-VisualNamed $Window 'BackgroundOverlay').Background =
        (New-VisualBrush $Theme.WindowOverlay).PSObject.BaseObject
}

function Set-VisualLanguage {
    param([object]$Window, [string]$Language)
    $keys = [ordered]@{
        HeaderTitleText='App.Title'; ThemeLabelText='Theme.Label'
        LanguageLabelText='Language.Label'; SavedAccountsHeadingText='Section.SavedAccounts'
        SearchAccountsLabelText='Search.Label'; SwitchButton='Button.Switch'
        VerifyButton='Button.Verify'; RefreshButton='Button.Refresh'
        RefreshQuotaButton='Button.RefreshQuota'; AddButton='Button.Add'
        RenameButton='Button.Rename'; DeleteButton='Button.Delete'
        LaunchCodexButton='Button.LaunchCodex'; LaunchSettingsButton='Button.LaunchSettings'
        RefreshStatusText='Status.Ready'; BrowserSafetyFooterText='Footer.BrowserSafe'
    }
    foreach ($entry in $keys.GetEnumerator()) {
        $control = Get-VisualNamed $Window ([string]$entry.Key)
        $text = Get-QiehaoLocalizedString -Language $Language -Key ([string]$entry.Value)
        if ($null -ne $control.PSObject.Properties['Text']) { $control.Text = $text }
        else { $control.Content = $text }
    }
    (Get-VisualNamed $Window 'ProfileSearchTextBox').ToolTip =
        Get-QiehaoLocalizedString -Language $Language -Key 'Search.ToolTip'
    $columnKeys = [ordered]@{
        ProfileColumn='Column.Profile'; CurrentColumn='Column.Current'
        VerificationColumn='Column.Verification'; HealthColumn='Column.Status'
        AuthColumn='Column.Auth'; IdentityColumn='Column.Identity'
        MetadataColumn='Column.Metadata'; UpdatedColumn='Column.Updated'
        QuotaColumn='Column.QuotaSnapshot'
    }
    foreach ($entry in $columnKeys.GetEnumerator()) {
        (Get-VisualNamed $Window ([string]$entry.Key)).Header =
            Get-QiehaoLocalizedString -Language $Language -Key ([string]$entry.Value)
    }
}

function New-VisualRows {
    return @(1..10 | ForEach-Object {
        [pscustomobject]@{
            Name=('Profile{0:D2}' -f $_); Active=if($_ -eq 1){'Yes'}else{'No'}
            ActiveCode=if($_ -eq 1){'Yes'}else{'No'}; Verification='Unverified'
            Health='Ready'; HealthCode='READY'; Auth='Present'; Identity='Present'
            Metadata='Valid'; UpdatedDisplay='2026-09-19 10:20:30'
            QuotaSummary='5h 16% - Week 21%'; QuotaToolTip='Fake quota snapshot'
        }
    })
}

function Get-ColorDistance {
    param([string]$Left, [string]$Right)
    $a = [Windows.Media.ColorConverter]::ConvertFromString($Left)
    $b = [Windows.Media.ColorConverter]::ConvertFromString($Right)
    return [Math]::Sqrt(
        [Math]::Pow([double]$a.R - $b.R, 2) +
        [Math]::Pow([double]$a.G - $b.G, 2) +
        [Math]::Pow([double]$a.B - $b.B, 2)
    )
}

function Get-VisualColor {
    param([Parameter(Mandatory = $true)][string]$Value)
    return [Windows.Media.ColorConverter]::ConvertFromString($Value)
}

function Get-VisualLuminance {
    param([Parameter(Mandatory = $true)][string]$Value)
    $color = Get-VisualColor $Value
    $linear = @($color.R, $color.G, $color.B | ForEach-Object {
        $channel = [double]$_ / 255.0
        if ($channel -le 0.04045) { $channel / 12.92 }
        else { [Math]::Pow(($channel + 0.055) / 1.055, 2.4) }
    })
    return 0.2126 * $linear[0] + 0.7152 * $linear[1] +
        0.0722 * $linear[2]
}

function Get-ThemeFingerprint {
    param(
        [Parameter(Mandatory = $true)][object]$Theme,
        [Parameter(Mandatory = $true)][string[]]$Fields
    )
    $data = ($Fields | ForEach-Object {
        $_ + '=' + [string]$Theme.$_
    }) -join ';'
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($data)) |
            ForEach-Object { $_.ToString('x2') }) -join ''
    }
    finally { $sha.Dispose() }
}

function Test-ControlInsideWindow {
    param([object]$Window, [object]$Control)
    if (-not $Control.IsVisible -or $Control.ActualWidth -le 0 -or
        $Control.ActualHeight -le 0) { return $false }
    $point = $Control.TransformToAncestor($Window).Transform(
        (New-Object Windows.Point(0, 0))
    )
    return ($point.X -ge -0.5 -and $point.Y -ge -0.5 -and
        $point.X + $Control.ActualWidth -le $Window.ActualWidth + 0.5 -and
        $point.Y + $Control.ActualHeight -le $Window.ActualHeight + 0.5)
}

$themes = @(Get-QiehaoBackgroundThemes)
$requiredThemeIds = @(
    '01-blue-glass','02-navy-gold','03-ice-glass','04-purple-tech',
    '05-light-flow','06-aurora-silver-blue','07-arctic-sea-glass'
)
$requiredSemantic = @(
    'WindowOverlay','CardBackground','CardBorder','CardShadow','Primary','Positive',
    'Info','Warning','Danger','TextPrimary','TextSecondary','TextMuted','GridHeader',
    'GridHover','GridSelected','GridActive','GridActiveSelected','ControlBackground',
    'ControlBorder','FocusRing','DisabledBackground','ToolTipBackground',
    'ToolTipBorder','ToolTipForeground','BrandWatermark'
)
$themeFingerprintFields = @(
    'Id','FileName','OverlayMode','OverlayColor','CardTop','CardBottom',
    'BorderTint','TextPrimary','TextSecondary','ButtonTop','ButtonBottom',
    'ButtonHover','ButtonPressed','ActiveRowTint','ActiveSelectedRowTint',
    'SelectedRowTint','ActiveBorderTint','RunningWarningTint',
    'UnknownWarningTint','ColumnHeaderBackgroundTint',
    'ColumnHeaderForegroundTint','ColumnHeaderBorderTint','CurrentYesTint',
    'CurrentNoTint','AccentTint','DangerTop','DangerBottom','WindowOverlay',
    'CardBackground','CardBorder','CardShadow','TextMuted','Primary',
    'PrimaryHover','PrimaryPressed','Positive','PositiveHover',
    'PositivePressed','Info','InfoHover','InfoPressed','Warning','Danger',
    'DangerHover','DangerPressed','Accent','AccentHover','AccentPressed',
    'Secondary','SecondaryHover','SecondaryPressed','ControlBackground',
    'ControlBorder','GridHeader','GridHover','GridSelected','GridActive',
    'GridActiveSelected','FocusRing','ToolTipBackground','ToolTipBorder',
    'ToolTipForeground','ButtonOnAccent','DisabledBackground'
)
$darkThemeBaselineHashes = [ordered]@{
    '01-blue-glass' = '9bc4d09c68de41760f5f86b508e4ff9607717c38311ac3e3b292565cb242f3a0'
    '02-navy-gold' = '7626373fc06f57324f02a71c60cfa84cf0bd785370446ad3937cadfca389f49c'
    '04-purple-tech' = '2cc07e0ddbb7b2a56e5d28844c86c8869b6f62cf5ea81ef8e9f8767c1417ffef'
}
Assert-VisualPolish ($themes.Count -eq 7) 'VISUAL_THEME_COUNT_FAILED'
Assert-VisualPolish ((@($themes.Id) -join '|') -ceq
    ($requiredThemeIds -join '|')) `
    'VISUAL_THEME_IDS_CHANGED'
Assert-VisualPolish (
    (Get-Command Get-QiehaoBackgroundThemes).ScriptBlock.ToString() -notmatch
        'Get-ChildItem|EnumerateFiles|GetFiles'
) 'VISUAL_THEME_REGISTRY_MUST_NOT_SCAN_DIRECTORY'
foreach ($theme in $themes) {
    foreach ($property in $requiredSemantic) {
        Assert-VisualPolish (
            $null -ne $theme.PSObject.Properties[$property] -and
            -not [string]::IsNullOrWhiteSpace([string]$theme.$property)
        ) ('VISUAL_THEME_TOKEN_MISSING_' + $theme.Id + '_' + $property)
    }
    foreach ($pair in @(
        @('GridHover','GridSelected'), @('GridSelected','GridActive'),
        @('GridActive','GridActiveSelected'), @('Primary','Positive'),
        @('Positive','Info'), @('TextPrimary','CardBackground'),
        @('TextMuted','DisabledBackground'), @('Danger','ButtonOnAccent')
    )) {
        Assert-VisualPolish ((Get-ColorDistance $theme.($pair[0]) $theme.($pair[1])) -gt 18) `
            ('VISUAL_COLOR_SANITY_FAILED_' + $theme.Id + '_' + $pair[0])
    }
    $brandColor = Get-VisualColor $theme.BrandWatermark
    if ($theme.OverlayMode -ceq 'Dark') {
        Assert-VisualPolish (
            $brandColor.A -ge 0x1F -and $brandColor.A -le 0x2E
        ) ('VISUAL_DARK_BRAND_OPACITY_INVALID_' + $theme.Id)
    }
    else {
        Assert-VisualPolish (
            $brandColor.A -ge 0x1A -and $brandColor.A -le 0x24
        ) ('VISUAL_LIGHT_BRAND_OPACITY_INVALID_' + $theme.Id)
    }
}
foreach ($entry in $darkThemeBaselineHashes.GetEnumerator()) {
    $theme = @($themes | Where-Object { $_.Id -ceq [string]$entry.Key })[0]
    Assert-VisualPolish (
        (Get-ThemeFingerprint -Theme $theme -Fields $themeFingerprintFields) `
            -ceq [string]$entry.Value
    ) ('VISUAL_DARK_THEME_BASELINE_CHANGED_' + [string]$entry.Key)
}

$lightThemes = @($themes | Where-Object { $_.OverlayMode -ceq 'Light' })
Assert-VisualPolish ($lightThemes.Count -eq 4) 'VISUAL_LIGHT_THEME_COUNT_CHANGED'
foreach ($theme in $lightThemes) {
    $overlay = Get-VisualColor $theme.WindowOverlay
    $cardTop = Get-VisualColor $theme.CardTop
    $cardBottom = Get-VisualColor $theme.CardBottom
    $border = Get-VisualColor $theme.CardBorder
    $control = Get-VisualColor $theme.ControlBackground
    $secondary = Get-VisualColor $theme.Secondary
    $header = Get-VisualColor $theme.GridHeader
    $shadow = Get-VisualColor $theme.CardShadow
    $tooltip = Get-VisualColor $theme.ToolTipBackground
    Assert-VisualPolish ($overlay.A -le 0x24) `
        ('VISUAL_LIGHT_OVERLAY_TOO_HEAVY_' + $theme.Id)
    Assert-VisualPolish ($cardTop.A -ge 0x70 -and $cardTop.A -le 0x86 -and
        $cardBottom.A -lt $cardTop.A) `
        ('VISUAL_LIGHT_CARD_NOT_TRANSLUCENT_' + $theme.Id)
    Assert-VisualPolish ($border.A -gt $cardTop.A -and
        $border.B -ge $border.R) `
        ('VISUAL_LIGHT_EDGE_HIGHLIGHT_MISSING_' + $theme.Id)
    Assert-VisualPolish ((Get-VisualLuminance $theme.CardTop) -ge 0.88 -and
        $cardTop.B -ge $cardTop.R -and $cardBottom.B -gt $cardBottom.R) `
        ('VISUAL_LIGHT_CARD_NOT_COLD_BRIGHT_' + $theme.Id)
    Assert-VisualPolish ((Get-ColorDistance $theme.CardTop $theme.CardBottom) -gt 20) `
        ('VISUAL_LIGHT_CARD_GRADIENT_TOO_FLAT_' + $theme.Id)
    Assert-VisualPolish ($control.A -le 0xA6 -and $secondary.A -le 0xA0 -and
        $header.A -le 0xA4) `
        ('VISUAL_LIGHT_CONTROLS_TOO_OPAQUE_' + $theme.Id)
    Assert-VisualPolish ($shadow.A -le 0x30 -and $tooltip.A -ge 0xE0) `
        ('VISUAL_LIGHT_DEPTH_OR_TOOLTIP_INVALID_' + $theme.Id)
}
$iceTheme = @($lightThemes | Where-Object { $_.Id -ceq '03-ice-glass' })[0]
$flowTheme = @($lightThemes | Where-Object { $_.Id -ceq '05-light-flow' })[0]
$auroraTheme = @($lightThemes | Where-Object {
    $_.Id -ceq '06-aurora-silver-blue'
})[0]
$arcticTheme = @($lightThemes | Where-Object {
    $_.Id -ceq '07-arctic-sea-glass'
})[0]
Assert-VisualPolish (
    (Get-VisualColor $flowTheme.WindowOverlay).A -lt
        (Get-VisualColor $iceTheme.WindowOverlay).A -and
    (Get-VisualColor $flowTheme.CardTop).A -lt
        (Get-VisualColor $iceTheme.CardTop).A
) 'VISUAL_LIGHT_FLOW_NOT_LIGHTER_THAN_ICE'
Assert-VisualPolish (
    $auroraTheme.FileName -ceq '06-aurora-silver-blue.png' -and
    $arcticTheme.FileName -ceq '07-arctic-sea-glass.png' -and
    $auroraTheme.Primary -cne $arcticTheme.Primary -and
    $auroraTheme.Accent -cne $arcticTheme.Accent -and
    $auroraTheme.GridHeader -cne $arcticTheme.GridHeader -and
    $auroraTheme.CardShadow -cne $arcticTheme.CardShadow
) 'VISUAL_NEW_THEME_PALETTES_NOT_INDEPENDENT'

$brandWatermarkExists = $false
$brandWatermarkTextZct = $false
$brandWatermarkHitTestDisabled = $false
$brandWatermarkRotationValid = $false
$probe = Read-VisualWindow
try {
    foreach ($style in @(
        'PrimaryButtonStyle','PositiveButtonStyle','InfoButtonStyle',
        'AccentButtonStyle','SecondaryButtonStyle','DangerButtonStyle',
        'PanelStyle','StatusChipStyle','FooterStatusBarStyle'
    )) {
        Assert-VisualPolish ($null -ne $probe.Resources[$style]) `
            ('VISUAL_STYLE_MISSING_' + $style)
    }
    foreach ($type in @(
        [Windows.Controls.TextBox], [Windows.Controls.ComboBox],
        [Windows.Controls.ToolTip]
    )) {
        Assert-VisualPolish ($null -ne $probe.Resources[$type]) `
            ('VISUAL_IMPLICIT_STYLE_MISSING_' + $type.Name)
    }
    Assert-VisualPolish ($probe.Width -eq 1040 -and $probe.MinWidth -eq 960 -and
        $probe.MinHeight -eq 690) 'VISUAL_WINDOW_SIZE_CHANGED'
    $profileColumn = Get-VisualNamed $probe 'ProfileColumn'
    $quotaColumn = Get-VisualNamed $probe 'QuotaColumn'
    $grid = Get-VisualNamed $probe 'ProfilesGrid'
    Assert-VisualPolish ($profileColumn.Width.IsStar -and
        [Math]::Abs($profileColumn.Width.Value - 1) -lt 0.01 -and
        $quotaColumn.Width.IsStar -and
        [Math]::Abs($quotaColumn.Width.Value - 1.4) -lt 0.01) `
        'VISUAL_ACCOUNT_GRID_STAR_LAYOUT_CHANGED'
    Assert-VisualPolish ($grid.RowHeight -eq 32 -and
        $grid.ColumnHeaderHeight -eq 34) 'VISUAL_GRID_HEIGHT_CHANGED'
    $brandLayer = Get-VisualNamed $probe 'BrandWatermarkLayer'
    $brandText = Get-VisualNamed $probe 'BrandWatermarkText'
    $brandRotation = $brandText.RenderTransform
    $brandWatermarkExists = (
        $brandLayer -is [Windows.Controls.Canvas] -and
        $brandText -is [Windows.Controls.TextBlock] -and
        $probe.Content.Children.IndexOf($brandLayer) -eq 2
    )
    $brandWatermarkTextZct = (
        $brandText.Text -ceq 'ZCT' -and $brandText.FontSize -ge 72 -and
        $brandText.FontSize -le 88
    )
    $brandWatermarkHitTestDisabled = (
        -not $brandLayer.IsHitTestVisible -and
        -not $brandText.IsHitTestVisible
    )
    $brandWatermarkRotationValid = (
        $brandRotation -is [Windows.Media.RotateTransform] -and
        $brandRotation.Angle -ge -32 -and $brandRotation.Angle -le -28
    )
}
finally { $probe.Close() }

$rendered = 0
$allCards = $true
$allButtons = $true
$allNoClip = $true
$allGridStyles = $true
$allInputStyles = $true
$allNoPageScroll = $true
$allDisabledReadable = $true
$allStateRendering = $true
$allCardSeparation = $true
$allLightRenderedLayers = $true
$allBrandRendering = $true
$allBrandLayoutNeutral = $true
$brandRenderedThemes = @{}
foreach ($theme in $themes) {
    foreach ($language in @('zh-CN','en-US')) {
        $window = Read-VisualWindow
        try {
            Set-VisualTheme -Window $window -Theme $theme
            Set-VisualBackgroundImage -Window $window -Theme $theme
            Set-VisualLanguage -Window $window -Language $language
            $grid = Get-VisualNamed $window 'ProfilesGrid'
            $grid.ItemsSource = @(New-VisualRows)
            $window.WindowStartupLocation = 'Manual'
            $window.Left = -20000; $window.Top = -20000
            $window.ShowInTaskbar = $false; $window.Opacity = 0
            $window.Width = 1040; $window.Height = 690
            [void]$window.Show()
            Update-VisualWindow $window

            $root = $window.Content
            $brandLayer = Get-VisualNamed $window 'BrandWatermarkLayer'
            $brandText = Get-VisualNamed $window 'BrandWatermarkText'
            $brandBounds = $brandText.TransformToAncestor($window).TransformBounds(
                (New-Object Windows.Rect(
                    0, 0, $brandText.ActualWidth, $brandText.ActualHeight
                ))
            )
            $layout = $root.Children[3]
            $allBrandRendering = $allBrandRendering -and
                $brandText.Text -ceq 'ZCT' -and
                $brandText.Visibility -eq [Windows.Visibility]::Visible -and
                $brandText.ActualWidth -gt 0 -and
                $brandText.ActualHeight -gt 0 -and
                $brandText.Foreground -is [Windows.Media.SolidColorBrush] -and
                $brandText.Foreground.Color -eq
                    (Get-VisualColor $theme.BrandWatermark) -and
                $brandBounds.Left -ge 0 -and $brandBounds.Top -ge 0 -and
                $brandBounds.Right -le $window.ActualWidth -and
                $brandBounds.Bottom -le $window.ActualHeight
            $allBrandLayoutNeutral = $allBrandLayoutNeutral -and
                $root.Children.Count -eq 4 -and
                $root.Children.IndexOf($brandLayer) -eq 2 -and
                $root.Children.IndexOf($layout) -eq 3 -and
                [Math]::Abs($brandLayer.DesiredSize.Width) -lt 0.01 -and
                [Math]::Abs($brandLayer.DesiredSize.Height) -lt 0.01 -and
                [Math]::Abs([Windows.Controls.Canvas]::GetLeft($brandText) - 36) -lt 0.01 -and
                [Math]::Abs([Windows.Controls.Canvas]::GetTop($brandText) - 52) -lt 0.01
            $brandRenderedThemes[[string]$theme.Id] = $true
            $cards = @($layout.Children | Where-Object {
                $_ -is [Windows.Controls.Border] -and
                $_.Style -eq $window.Resources['PanelStyle']
            })
            $allCards = $allCards -and $cards.Count -eq 3 -and
                $null -ne $cards[0].Effect -and $null -ne $cards[1].Effect -and
                $null -ne $cards[2].Effect
            if ($theme.OverlayMode -ceq 'Light') {
                $panelBrush = $window.Resources['PanelBrush']
                $overlayBrush = (Get-VisualNamed $window `
                    'BackgroundOverlay').Background
                $searchBrush = (Get-VisualNamed $window `
                    'ProfileSearchTextBox').Background
                $secondaryBrush = (Get-VisualNamed $window `
                    'LaunchSettingsButton').Background
                $allLightRenderedLayers = $allLightRenderedLayers -and
                    $panelBrush -is [Windows.Media.LinearGradientBrush] -and
                    $panelBrush.GradientStops.Count -eq 2 -and
                    $panelBrush.GradientStops[0].Color -eq
                        (Get-VisualColor $theme.CardTop) -and
                    $panelBrush.GradientStops[1].Color -eq
                        (Get-VisualColor $theme.CardBottom) -and
                    $cards[0].Background -eq $panelBrush -and
                    $overlayBrush.Color.A -eq
                        (Get-VisualColor $theme.WindowOverlay).A -and
                    $searchBrush.Color.A -eq
                        (Get-VisualColor $theme.ControlBackground).A -and
                    $secondaryBrush.Color.A -eq
                        (Get-VisualColor $theme.Secondary).A -and
                    $null -ne (Get-VisualNamed $window 'BackgroundImage').Source
            }
            $cardBounds = @($cards | ForEach-Object {
                $point = $_.TransformToAncestor($window).Transform(
                    (New-Object Windows.Point(0, 0))
                )
                [pscustomobject]@{ Top=$point.Y; Bottom=$point.Y + $_.ActualHeight }
            } | Sort-Object Top)
            $allCardSeparation = $allCardSeparation -and
                $cardBounds[0].Bottom -le $cardBounds[1].Top -and
                $cardBounds[1].Bottom -le $cardBounds[2].Top

            $buttons = @(
                'SwitchButton','VerifyButton','RefreshButton',
                'RefreshQuotaButton','AddButton','RenameButton','DeleteButton',
                'LaunchCodexButton','LaunchSettingsButton'
            ) | ForEach-Object { Get-VisualNamed $window $_ }
            $allButtons = $allButtons -and $buttons.Count -eq 9 -and
                @($buttons | Where-Object { $_.ActualHeight -lt 29 }).Count -eq 0
            $disabledButton = Get-VisualNamed $window 'SwitchButton'
            [void]$disabledButton.ApplyTemplate()
            $disabledShell = $disabledButton.Template.FindName(
                'ButtonShell', $disabledButton
            )
            $allDisabledReadable = $allDisabledReadable -and
                -not $disabledButton.IsEnabled -and $null -ne $disabledShell -and
                $disabledShell.Opacity -ge 0.70 -and
                $disabledButton.Foreground.Color.A -ge 160
            foreach ($name in @(
                'HeaderTitleText','ThemeComboBox','LanguageComboBox',
                'ProfileSearchTextBox','ProfilesGrid','SwitchButton',
                'LaunchSettingsButton','RefreshStatusText'
            )) {
                $allNoClip = $allNoClip -and (Test-ControlInsideWindow $window `
                    (Get-VisualNamed $window $name))
            }

            $headers = @(Get-VisualChildren $grid | Where-Object {
                $_ -is [Windows.Controls.Primitives.DataGridColumnHeader] -and
                $null -ne $_.Column
            })
            $rows = @(Get-VisualChildren $grid | Where-Object {
                $_ -is [Windows.Controls.DataGridRow]
            })
            $allGridStyles = $allGridStyles -and $headers.Count -eq 9 -and
                @($headers | Where-Object {
                    [Math]::Abs($_.ActualHeight - 34) -gt 0.6 -or
                    $null -eq $_.Background
                }).Count -eq 0 -and $rows.Count -ge 1 -and
                [Math]::Abs($rows[0].ActualHeight - 32) -lt 0.6
            $grid.SelectedIndex = 1
            Update-VisualWindow $window
            $activeRow = $grid.ItemContainerGenerator.ContainerFromIndex(0)
            $selectedRow = $grid.ItemContainerGenerator.ContainerFromIndex(1)
            $activeColor = [string]$activeRow.Background
            $selectedColor = [string]$selectedRow.Background
            $grid.SelectedIndex = 0
            Update-VisualWindow $window
            $activeSelectedColor = [string]$activeRow.Background
            $allStateRendering = $allStateRendering -and
                $activeColor -ceq [string]$window.Resources['ActiveRowBrush'] -and
                $selectedColor -ceq [string]$window.Resources['SelectedRowBrush'] -and
                $activeSelectedColor -ceq
                    [string]$window.Resources['ActiveSelectedRowBrush'] -and
                @($activeColor,$selectedColor,$activeSelectedColor | Sort-Object -Unique).Count -eq 3

            $search = Get-VisualNamed $window 'ProfileSearchTextBox'
            $combo = Get-VisualNamed $window 'ThemeComboBox'
            $allInputStyles = $allInputStyles -and
                $null -ne $search.Template -and $null -ne $combo.Template -and
                $search.BorderBrush -ne $null -and $combo.BorderBrush -ne $null

            $pageScrollers = @(Get-VisualChildren $window | Where-Object {
                $_ -is [Windows.Controls.ScrollViewer] -and
                $_.Name -ne 'DG_ScrollViewer' -and
                $_.TemplatedParent -isnot [Windows.Controls.TextBox] -and
                $_.TemplatedParent -isnot [Windows.Controls.ComboBox]
            })
            $allNoPageScroll = $allNoPageScroll -and $pageScrollers.Count -eq 0
            $rendered++
        }
        finally { $window.Close() }
    }
}

$guiSource = [IO.File]::ReadAllText($guiPath)
$switchSection = [regex]::Match($guiSource,
    '(?s)function Show-QiehaoManualSwitchWaitDialog\s*\{.*?function Show-QiehaoSwitchResult').Value
$dialogPresentation = (
    $guiSource -match 'function Copy-QiehaoDialogVisualResources' -and
    $guiSource -match 'function Set-QiehaoDialogContent' -and
    $switchSection -match 'Copy-QiehaoDialogVisualResources -Dialog \$dialog' -and
    $switchSection -match "SecondaryButtonStyle" -and
    $switchSection -match 'DialogCardBrush' -and
    $switchSection -match 'DropShadowEffect'
)
$snapshotVisualSection = [regex]::Match($guiSource,
    '(?s)function Set-QiehaoSnapshot\s*\{.*?function Invoke-QiehaoReadOnlyRefresh').Value
$semanticStateCodes = (
    $snapshotVisualSection -match 'switch \(\$script:guiCurrentIdentityState\)' -and
    $snapshotVisualSection -match "'Confirmed'.*SuccessBrush" -and
    $snapshotVisualSection -match "'Mismatch'.*DangerBrush" -and
    $snapshotVisualSection -match "'PendingExit'.*WarningBrush" -and
    $snapshotVisualSection -notmatch 'switch \(\[string\]\$Snapshot\.IdentityStatus\)'
)
$codexVisualSection = [regex]::Match($guiSource,
    '(?s)function Set-QiehaoCodexStatusVisual\s*\{.*?function Get-QiehaoLiveCodexStatus').Value
$semanticCodexStateCodes = (
    $codexVisualSection -match 'switch \(\$script:guiCurrentCodexState\)' -and
    $codexVisualSection -match "'Running'.*SuccessBrush" -and
    $codexVisualSection -match "'Stopped'.*TextMutedBrush" -and
    $codexVisualSection -match 'default.*WarningBrush'
)

Assert-VisualPolish ($rendered -eq 14) 'VISUAL_FOURTEEN_COMBINATIONS_NOT_RENDERED'
Assert-VisualPolish $brandWatermarkExists 'VISUAL_BRAND_WATERMARK_MISSING'
Assert-VisualPolish $brandWatermarkTextZct 'VISUAL_BRAND_WATERMARK_TEXT_INVALID'
Assert-VisualPolish $brandWatermarkHitTestDisabled 'VISUAL_BRAND_WATERMARK_HIT_TEST_ENABLED'
Assert-VisualPolish $brandWatermarkRotationValid 'VISUAL_BRAND_WATERMARK_ROTATION_INVALID'
Assert-VisualPolish $allBrandLayoutNeutral 'VISUAL_BRAND_WATERMARK_AFFECTS_LAYOUT'
Assert-VisualPolish (
    $allBrandRendering -and $brandRenderedThemes.Count -eq 7
) 'VISUAL_BRAND_WATERMARK_NOT_VISIBLE_IN_SEVEN_THEMES'
Assert-VisualPolish $allCards 'VISUAL_GLASS_CARDS_NOT_RENDERED'
Assert-VisualPolish $allLightRenderedLayers `
    'VISUAL_LIGHT_THEME_LAYERS_NOT_RENDERED'
Assert-VisualPolish $allCardSeparation 'VISUAL_GLASS_CARDS_OVERLAP'
Assert-VisualPolish $allButtons 'VISUAL_BUTTON_DIMENSIONS_FAILED'
Assert-VisualPolish $allDisabledReadable 'VISUAL_DISABLED_BUTTON_NOT_READABLE'
Assert-VisualPolish $allNoClip 'VISUAL_CONTROL_CLIPPING_DETECTED'
Assert-VisualPolish $allGridStyles 'VISUAL_GRID_STYLE_FAILED'
Assert-VisualPolish $allStateRendering 'VISUAL_GRID_STATES_NOT_RENDERED'
Assert-VisualPolish $allInputStyles 'VISUAL_INPUT_STYLE_FAILED'
Assert-VisualPolish $allNoPageScroll 'VISUAL_WHOLE_PAGE_SCROLL_DETECTED'
Assert-VisualPolish $dialogPresentation 'VISUAL_SWITCH_DIALOG_THEME_FAILED'
Assert-VisualPolish $semanticStateCodes 'VISUAL_STATE_USES_DISPLAY_TEXT'
Assert-VisualPolish $semanticCodexStateCodes 'VISUAL_CODEX_STATE_USES_DISPLAY_TEXT'

'AllThemesLoad=True'
'AllThemesExposeRequiredSemanticBrushes=True'
'SevenThemesRegistered=True'
'ExplicitThemeRegistryOnly=True'
'NewThemesHaveIndependentSemanticPalettes=True'
'DarkThemeBaselineUnchanged=True'
'IceGlassAirierPalette=True'
'LightFlowAirierPalette=True'
'LightThemeOverlayReduced=True'
'LightThemeGlassEdgeHighlight=True'
'LightThemeRenderedGlassLayers=True'
'ZhCnEnUsAllThemesRender=True'
'FourteenThemeLanguageCombinationsRendered=14'
'BrandWatermarkExists=True'
'BrandWatermarkTextZCT=True'
'BrandWatermarkIsHitTestVisibleFalse=True'
'BrandWatermarkRotationBetweenMinus28AndMinus32=True'
'BrandWatermarkDoesNotAffectLayout=True'
'BrandWatermarkVisibleInSevenThemes=True'
'PrimaryButtonStyleExists=True'
'PositiveButtonStyleExists=True'
'InfoButtonStyleExists=True'
'AccentButtonStyleExists=True'
'DangerButtonStyleExists=True'
'SecondaryButtonStyleExists=True'
'DisabledButtonReadable=True'
'AccountGridHeaderStyleApplied=True'
'AccountGridRowStyleApplied=True'
'ActiveSelectedStatesDistinct=True'
'SearchStyleApplied=True'
'ComboBoxStyleApplied=True'
'TooltipStyleApplied=True'
'SwitchDialogUsesThemeResources=True'
'VisualStateUsesSemanticCodes=True'
'GlassCardsRenderedOffscreen=True'
'NoCriticalControlClipping=True'
'WindowMinSizePreserved=True'
'AccountGridResponsiveLayoutPreserved=True'
'QuotaRowHeightPreserved=True'
'NoWholePageVerticalScroll=True'
'VISUAL_POLISH_SELFTEST_PASS'
