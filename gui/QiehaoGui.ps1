[CmdletBinding()]
param(
    [switch]$SelfTest
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$guiRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent $guiRoot
$coreModulePath = Join-Path -Path $projectRoot -ChildPath 'lib\CodexAuth.psm1'
$helperModulePath = Join-Path -Path $guiRoot -ChildPath 'GuiHelpers.psm1'
$xamlPath = Join-Path -Path $guiRoot -ChildPath 'MainWindow.xaml'
$stateDirectory = $null
$backgroundDirectory = Join-Path -Path $guiRoot -ChildPath 'assets\backgrounds'
$guiMutexName = 'Qiehaoqu.CodexAccountSwitcher.Gui.v1'

Add-Type -AssemblyName PresentationCore -ErrorAction Stop
Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop

Import-Module -Name $coreModulePath -Force -ErrorAction Stop
Import-Module -Name $helperModulePath -Force -ErrorAction Stop
$stateDirectory = Resolve-QiehaoProjectStateDirectory -GuiScriptRoot $guiRoot

function Read-QiehaoMainWindow {
    $xamlText = [System.IO.File]::ReadAllText($xamlPath)
    $stringReader = $null
    $xmlReader = $null
    try {
        $stringReader = New-Object System.IO.StringReader($xamlText)
        $xmlReader = [System.Xml.XmlReader]::Create($stringReader)
        return [Windows.Markup.XamlReader]::Load($xmlReader)
    }
    finally {
        if ($null -ne $xmlReader) { $xmlReader.Dispose() }
        if ($null -ne $stringReader) { $stringReader.Dispose() }
        $xamlText = $null
    }
}

function Get-RequiredControl {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Window]$Window,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $control = $Window.FindName($Name)
    if ($null -eq $control) { throw ('GUI_CONTROL_NOT_FOUND_' + $Name) }
    return $control
}

function Get-RequiredContextMenuItem {
    param(
        [Parameter(Mandatory = $true)]
        [System.Windows.Controls.ContextMenu]$ContextMenu,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    foreach ($item in @($ContextMenu.Items)) {
        if ($item -is [System.Windows.Controls.MenuItem] -and
            [string]$item.Name -ceq $Name) { return $item }
    }
    throw ('GUI_CONTEXT_MENU_ITEM_NOT_FOUND_' + $Name)
}

$lease = $null
$window = $null
try {
    if (-not $SelfTest) {
        $lease = Enter-QiehaoGuiSingleInstance -MutexName $guiMutexName
        if (-not $lease.Acquired) {
            [void][System.Windows.MessageBox]::Show(
                'Codex 账号管理器已在运行。',
                'Codex 账号管理器',
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Information
            )
            return
        }
    }

    $window = Read-QiehaoMainWindow
    $profilesGrid = Get-RequiredControl -Window $window -Name 'ProfilesGrid'
    $profileSearchTextBox = Get-RequiredControl -Window $window -Name 'ProfileSearchTextBox'
    $profileCountText = Get-RequiredControl -Window $window -Name 'ProfileCountText'
    $codexStatusText = Get-RequiredControl -Window $window -Name 'CodexStatusText'
    $activeProfileText = Get-RequiredControl -Window $window -Name 'ActiveProfileText'
    $identityStatusText = Get-RequiredControl -Window $window -Name 'IdentityStatusText'
    $webChatGPTText = Get-RequiredControl -Window $window -Name 'WebChatGPTText'
    $refreshStatusText = Get-RequiredControl -Window $window -Name 'RefreshStatusText'
    $switchButton = Get-RequiredControl -Window $window -Name 'SwitchButton'
    $verifyButton = Get-RequiredControl -Window $window -Name 'VerifyButton'
    $refreshButton = Get-RequiredControl -Window $window -Name 'RefreshButton'
    $addButton = Get-RequiredControl -Window $window -Name 'AddButton'
    $renameButton = Get-RequiredControl -Window $window -Name 'RenameButton'
    $deleteButton = Get-RequiredControl -Window $window -Name 'DeleteButton'
    $launchCodexButton = Get-RequiredControl -Window $window -Name 'LaunchCodexButton'
    $codexSafetyHintText = Get-RequiredControl -Window $window -Name 'CodexSafetyHintText'
    $cancelSwitchWaitButton = Get-RequiredControl -Window $window -Name 'CancelSwitchWaitButton'
    $launchSettingsButton = Get-RequiredControl -Window $window -Name 'LaunchSettingsButton'
    $launchTargetText = Get-RequiredControl -Window $window -Name 'LaunchTargetText'
    $themeComboBox = Get-RequiredControl -Window $window -Name 'ThemeComboBox'
    $backgroundImage = Get-RequiredControl -Window $window -Name 'BackgroundImage'
    $backgroundOverlay = Get-RequiredControl -Window $window -Name 'BackgroundOverlay'
    $profileContextMenu = $profilesGrid.ContextMenu
    if ($null -eq $profileContextMenu) { throw 'GUI_CONTEXT_MENU_NOT_FOUND' }
    $contextSwitchMenuItem = Get-RequiredContextMenuItem -ContextMenu $profileContextMenu -Name 'ContextSwitchMenuItem'
    $contextVerifyMenuItem = Get-RequiredContextMenuItem -ContextMenu $profileContextMenu -Name 'ContextVerifyMenuItem'
    $contextRenameMenuItem = Get-RequiredContextMenuItem -ContextMenu $profileContextMenu -Name 'ContextRenameMenuItem'
    $contextDeleteMenuItem = Get-RequiredContextMenuItem -ContextMenu $profileContextMenu -Name 'ContextDeleteMenuItem'

    $script:guiCurrentCodexStatus = '未知'
    $script:guiCurrentActiveProfile = '未初始化'
    $script:guiIsWriteOperationBusy = $false
    $script:guiManualSwitchWaitInProgress = $false
    $script:guiManualSwitchWaitTimer = $null
    $script:guiManualSwitchWaitTimerTickHandler = $null
    $script:guiManualSwitchWaitRuntime = $null
    $script:guiLaunchTimer = $null
    $script:guiLaunchTimerTickHandler = $null
    $script:guiLaunchWaitRuntime = $null
    $script:guiProcessTimer = $null
    $script:guiProcessTimerTickHandler = $null
    $script:guiPendingAction = $null
    $script:guiPendingTargetProfile = $null
    $script:guiLaunchTarget = $null
    $script:guiLaunchSettings = $null
    $script:guiAllProfileRows = @()
    $script:guiVerificationStates = @{}
    $script:guiIsClosing = $false
    $script:guiThemePersistenceReady = $false

    function Get-QiehaoSelectedProfileName {
        if ($null -eq $profilesGrid.SelectedItem) { return $null }
        return [string]$profilesGrid.SelectedItem.Name
    }

    function Update-QiehaoActionButtons {
        $state = Get-QiehaoActionState `
            -SelectedProfile (Get-QiehaoSelectedProfileName) `
            -ActiveProfile $script:guiCurrentActiveProfile `
            -CodexStatus $script:guiCurrentCodexStatus `
            -IsWriteOperationBusy:$script:guiIsWriteOperationBusy `
            -ManualSwitchWaitInProgress:$script:guiManualSwitchWaitInProgress `
            -LaunchTargetAvailable:($null -ne $script:guiLaunchTarget -and
                [bool]$script:guiLaunchTarget.Available)
        $refreshButton.IsEnabled = [bool]$state.Refresh
        $switchButton.IsEnabled = [bool]$state.Switch
        $verifyButton.IsEnabled = [bool]$state.Verify
        $addButton.IsEnabled = [bool]$state.Add
        $renameButton.IsEnabled = [bool]$state.Rename
        $deleteButton.IsEnabled = [bool]$state.Delete
        $launchCodexButton.IsEnabled = [bool]$state.LaunchCodex
        $cancelSwitchWaitButton.IsEnabled = [bool]$state.CancelSwitchWait
        $contextSwitchMenuItem.IsEnabled = [bool]$state.ContextSwitch
        $contextVerifyMenuItem.IsEnabled = [bool]$state.ContextVerify
        $contextRenameMenuItem.IsEnabled = [bool]$state.ContextRename
        $contextDeleteMenuItem.IsEnabled = [bool]$state.ContextDelete
        Update-QiehaoCodexSafetyHint
    }

    function Set-QiehaoWriteBusy {
        param(
            [Parameter(Mandatory = $true)]
            [bool]$Value,
            [string]$StatusText = ''
        )
        $script:guiIsWriteOperationBusy = $Value
        if (-not [string]::IsNullOrWhiteSpace($StatusText)) {
            $refreshStatusText.Text = $StatusText
        }
        Update-QiehaoActionButtons
    }

    function Show-QiehaoSafeMessage {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Message,
            [ValidateSet('Information', 'Warning', 'Critical')]
            [string]$Severity = 'Information'
        )
        $icon = [System.Windows.MessageBoxImage]::Information
        $title = 'Codex 账号管理器'
        if ($Severity -ceq 'Warning') {
            $icon = [System.Windows.MessageBoxImage]::Warning
        }
        elseif ($Severity -ceq 'Critical') {
            $icon = [System.Windows.MessageBoxImage]::Error
            $title = '严重安全错误 - Codex 账号管理器'
        }
        [void][System.Windows.MessageBox]::Show(
            $window, $Message, $title,
            [System.Windows.MessageBoxButton]::OK, $icon
        )
    }

    function Show-QiehaoOperationResult {
        param([Parameter(Mandatory = $true)][object]$Result)
        if (-not [string]::IsNullOrWhiteSpace([string]$Result.Message)) {
            Show-QiehaoSafeMessage -Message ([string]$Result.Message) `
                -Severity ([string]$Result.Severity)
        }
    }

    function Show-QiehaoChoiceDialog {
        param(
            [Parameter(Mandatory = $true)][string]$Title,
            [Parameter(Mandatory = $true)][string]$Message,
            [Parameter(Mandatory = $true)][string]$ConfirmText,
            [string]$CancelText = '取消'
        )
        $dialog = New-Object System.Windows.Window
        $dialog.Title = $Title
        $dialog.Width = 500
        $dialog.Height = 230
        $dialog.MinWidth = 420
        $dialog.MinHeight = 200
        $dialog.WindowStartupLocation = 'CenterOwner'
        $dialog.ResizeMode = 'NoResize'
        $dialog.ShowInTaskbar = $false
        $dialog.Owner = $window
        $dialog.FontFamily = $window.FontFamily
        $dialog.FontSize = $window.FontSize
        $root = New-Object System.Windows.Controls.Grid
        $root.Margin = 18
        $root.RowDefinitions.Add((New-Object System.Windows.Controls.RowDefinition))
        $buttonRow = New-Object System.Windows.Controls.RowDefinition
        $buttonRow.Height = 'Auto'
        $root.RowDefinitions.Add($buttonRow)
        $messageText = New-Object System.Windows.Controls.TextBlock
        $messageText.Text = $Message
        $messageText.TextWrapping = 'Wrap'
        $messageText.VerticalAlignment = 'Center'
        [System.Windows.Controls.Grid]::SetRow($messageText, 0)
        $root.Children.Add($messageText) | Out-Null
        $buttons = New-Object System.Windows.Controls.StackPanel
        $buttons.Orientation = 'Horizontal'
        $buttons.HorizontalAlignment = 'Right'
        $buttons.Margin = '0,18,0,0'
        [System.Windows.Controls.Grid]::SetRow($buttons, 1)
        $confirmButton = New-Object System.Windows.Controls.Button
        $confirmButton.Content = $ConfirmText
        $confirmButton.MinWidth = 130
        $confirmButton.MinHeight = 34
        $confirmButton.Margin = '0,0,8,0'
        $confirmButton.IsDefault = $true
        $cancelButton = New-Object System.Windows.Controls.Button
        $cancelButton.Content = $CancelText
        $cancelButton.MinWidth = 90
        $cancelButton.MinHeight = 34
        $cancelButton.IsCancel = $true
        $confirmButton.Add_Click({ $dialog.Tag = $true; $dialog.DialogResult = $true })
        $cancelButton.Add_Click({ $dialog.Tag = $false; $dialog.DialogResult = $false })
        $buttons.Children.Add($confirmButton) | Out-Null
        $buttons.Children.Add($cancelButton) | Out-Null
        $root.Children.Add($buttons) | Out-Null
        $dialog.Tag = $false
        $dialog.Content = $root
        $null = $dialog.ShowDialog()
        return [bool]$dialog.Tag
    }

    function Show-QiehaoNameDialog {
        param(
            [Parameter(Mandatory = $true)][string]$Title,
            [Parameter(Mandatory = $true)][string]$Prompt,
            [string]$CurrentName = ''
        )
        $dialog = New-Object System.Windows.Window
        $dialog.Title = $Title
        $dialog.Width = 440
        $dialog.Height = 240
        $dialog.WindowStartupLocation = 'CenterOwner'
        $dialog.ResizeMode = 'NoResize'
        $dialog.ShowInTaskbar = $false
        $dialog.Owner = $window
        $dialog.FontFamily = $window.FontFamily
        $dialog.FontSize = $window.FontSize
        $root = New-Object System.Windows.Controls.Grid
        $root.Margin = 18
        foreach ($height in @('Auto', 'Auto', 'Auto', '*', 'Auto')) {
            $row = New-Object System.Windows.Controls.RowDefinition
            $row.Height = $height
            $root.RowDefinitions.Add($row)
        }
        if (-not [string]::IsNullOrWhiteSpace($CurrentName)) {
            $currentText = New-Object System.Windows.Controls.TextBlock
            $currentText.Text = '当前名称：' + $CurrentName
            $currentText.Margin = '0,0,0,12'
            [System.Windows.Controls.Grid]::SetRow($currentText, 0)
            $root.Children.Add($currentText) | Out-Null
        }
        $promptText = New-Object System.Windows.Controls.TextBlock
        $promptText.Text = $Prompt
        [System.Windows.Controls.Grid]::SetRow($promptText, 1)
        $root.Children.Add($promptText) | Out-Null
        $nameBox = New-Object System.Windows.Controls.TextBox
        $nameBox.MaxLength = 64
        $nameBox.MinHeight = 32
        $nameBox.Margin = '0,6,0,0'
        $nameBox.Padding = '7,4'
        [System.Windows.Controls.Grid]::SetRow($nameBox, 2)
        $root.Children.Add($nameBox) | Out-Null
        $buttons = New-Object System.Windows.Controls.StackPanel
        $buttons.Orientation = 'Horizontal'
        $buttons.HorizontalAlignment = 'Right'
        $buttons.Margin = '0,18,0,0'
        [System.Windows.Controls.Grid]::SetRow($buttons, 4)
        $okButton = New-Object System.Windows.Controls.Button
        $okButton.Content = '确定'
        $okButton.MinWidth = 90
        $okButton.MinHeight = 34
        $okButton.Margin = '0,0,8,0'
        $okButton.IsDefault = $true
        $cancelButton = New-Object System.Windows.Controls.Button
        $cancelButton.Content = '取消'
        $cancelButton.MinWidth = 90
        $cancelButton.MinHeight = 34
        $cancelButton.IsCancel = $true
        $okButton.Add_Click({
            $candidate = ([string]$nameBox.Text).Trim()
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                [void][System.Windows.MessageBox]::Show(
                    $dialog, '名称不能为空。', 'Codex 账号管理器',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning
                )
                return
            }
            $dialog.Tag = $candidate
            $dialog.DialogResult = $true
        })
        $cancelButton.Add_Click({ $dialog.DialogResult = $false })
        $buttons.Children.Add($okButton) | Out-Null
        $buttons.Children.Add($cancelButton) | Out-Null
        $root.Children.Add($buttons) | Out-Null
        $dialog.Content = $root
        $result = $dialog.ShowDialog()
        if ($result -eq $true) { return [string]$dialog.Tag }
        return $null
    }

    function New-QiehaoSolidBrush {
        param([Parameter(Mandatory = $true)][string]$Color)
        $brush = New-Object System.Windows.Media.SolidColorBrush
        $brush.Color = [System.Windows.Media.ColorConverter]::ConvertFromString($Color)
        if ($brush.CanFreeze) { $brush.Freeze() }
        return $brush
    }

    function New-QiehaoGradientBrush {
        param(
            [Parameter(Mandatory = $true)][string]$Top,
            [Parameter(Mandatory = $true)][string]$Bottom
        )
        $brush = New-Object System.Windows.Media.LinearGradientBrush
        $brush.StartPoint = New-Object System.Windows.Point(0, 0)
        $brush.EndPoint = New-Object System.Windows.Point(0, 1)
        $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop(
            ([System.Windows.Media.ColorConverter]::ConvertFromString($Top)), 0
        )))
        $brush.GradientStops.Add((New-Object System.Windows.Media.GradientStop(
            ([System.Windows.Media.ColorConverter]::ConvertFromString($Bottom)), 1
        )))
        if ($brush.CanFreeze) { $brush.Freeze() }
        return $brush
    }

    function Set-QiehaoThemeResources {
        param([Parameter(Mandatory = $true)][object]$Theme)
        $values = [ordered]@{
            PanelBrush = New-QiehaoGradientBrush -Top ([string]$Theme.CardTop) `
                -Bottom ([string]$Theme.CardBottom)
            PanelBorderBrush = New-QiehaoSolidBrush -Color ([string]$Theme.BorderTint)
            TextPrimaryBrush = New-QiehaoSolidBrush -Color ([string]$Theme.TextPrimary)
            TextSecondaryBrush = New-QiehaoSolidBrush -Color ([string]$Theme.TextSecondary)
            ButtonFaceBrush = New-QiehaoGradientBrush -Top ([string]$Theme.ButtonTop) `
                -Bottom ([string]$Theme.ButtonBottom)
            ButtonHoverBrush = New-QiehaoSolidBrush -Color ([string]$Theme.ButtonHover)
            ButtonPressedBrush = New-QiehaoSolidBrush -Color ([string]$Theme.ButtonPressed)
            DangerButtonBrush = New-QiehaoGradientBrush -Top ([string]$Theme.DangerTop) `
                -Bottom ([string]$Theme.DangerBottom)
            ActiveRowBrush = New-QiehaoSolidBrush -Color ([string]$Theme.ActiveRowTint)
            ActiveSelectedRowBrush = New-QiehaoSolidBrush `
                -Color ([string]$Theme.ActiveSelectedRowTint)
            SelectedRowBrush = New-QiehaoSolidBrush -Color ([string]$Theme.SelectedRowTint)
            AccentBrush = New-QiehaoSolidBrush -Color ([string]$Theme.AccentTint)
            ButtonDisabledBrush = New-QiehaoSolidBrush -Color $(
                if ([string]$Theme.OverlayMode -ceq 'Dark') { '#705B6472' }
                else { '#70AAB5BE' }
            )
            GridBackgroundBrush = New-QiehaoSolidBrush -Color $(
                if ([string]$Theme.OverlayMode -ceq 'Dark') { '#3AFFFFFF' }
                else { '#68FFFFFF' }
            )
            GridRowBrush = New-QiehaoSolidBrush -Color $(
                if ([string]$Theme.OverlayMode -ceq 'Dark') { '#25FFFFFF' }
                else { '#50FFFFFF' }
            )
            GridAltRowBrush = New-QiehaoSolidBrush -Color $(
                if ([string]$Theme.OverlayMode -ceq 'Dark') { '#16FFFFFF' }
                else { '#36FFFFFF' }
            )
        }
        foreach ($entry in $values.GetEnumerator()) {
            $window.Resources[[string]$entry.Key] = $entry.Value.PSObject.BaseObject
        }
        $window.Background = $values.PanelBrush.PSObject.BaseObject
        $window.Foreground = $values.TextPrimaryBrush.PSObject.BaseObject
    }

    function Set-QiehaoTheme {
        param(
            [Parameter(Mandatory = $true)][object]$Theme,
            [switch]$Persist
        )
        $imageResult = Get-QiehaoBackgroundImage -Theme $Theme `
            -BackgroundDirectory $backgroundDirectory
        Set-QiehaoThemeResources -Theme $Theme
        if ($imageResult.Loaded) { $backgroundImage.Source = $imageResult.ImageSource }
        else { $backgroundImage.Source = $null }
        $overlayBrush = New-QiehaoSolidBrush -Color ([string]$Theme.OverlayColor)
        $backgroundOverlay.Background = $overlayBrush.PSObject.BaseObject
        if ($Persist) {
            try {
                $null = Write-QiehaoUiPreferences -StateDirectory $stateDirectory `
                    -Background $Theme.Id
                $refreshStatusText.Text = if ($imageResult.Loaded) {
                    '皮肤已切换并保存'
                } else { '背景图片不可用，已使用默认纯色并保存选择' }
            }
            catch { $refreshStatusText.Text = '皮肤已切换，但偏好保存失败' }
        }
        return $imageResult
    }

    function Update-QiehaoProfileFilter {
        $selectedName = Get-QiehaoSelectedProfileName
        $filteredRows = @(Select-QiehaoProfileRows -Rows $script:guiAllProfileRows `
            -SearchText $profileSearchTextBox.Text)
        $profilesGrid.ItemsSource = $filteredRows
        $profilesGrid.SelectedItem = $null
        if (-not [string]::IsNullOrWhiteSpace($selectedName)) {
            $matching = @($filteredRows | Where-Object {
                ([string]$_.Name).Equals($selectedName, [StringComparison]::OrdinalIgnoreCase)
            } | Select-Object -First 1)
            if ($matching.Count -eq 1) { $profilesGrid.SelectedItem = $matching[0] }
        }
        if ($filteredRows.Count -eq $script:guiAllProfileRows.Count) {
            $profileCountText.Text = [string]$filteredRows.Count + ' 个账号'
        }
        else {
            $profileCountText.Text = [string]$filteredRows.Count + ' / ' +
                [string]$script:guiAllProfileRows.Count + ' 个账号'
        }
        Update-QiehaoActionButtons
    }

    function Set-QiehaoSnapshot {
        param([Parameter(Mandatory = $true)][object]$Snapshot)
        $rows = @($Snapshot.Profiles)
        foreach ($row in $rows) {
            if ($script:guiVerificationStates.ContainsKey([string]$row.Name)) {
                $row.Verification = [string]$script:guiVerificationStates[[string]$row.Name]
            }
        }
        $script:guiAllProfileRows = @($rows)
        $codexStatusText.Text = [string]$Snapshot.CodexDesktop
        $script:guiCurrentCodexStatus = [string]$Snapshot.CodexDesktop
        $activeProfileText.Text = [string]$Snapshot.ActiveProfile
        $script:guiCurrentActiveProfile = [string]$Snapshot.ActiveProfile
        $identityStatusText.Text = [string]$Snapshot.IdentityStatus
        $webChatGPTText.Text = [string]$Snapshot.WebChatGPT
        Set-QiehaoCodexStatusVisual -Status $script:guiCurrentCodexStatus
        switch ([string]$Snapshot.IdentityStatus) {
            '已确认' { $identityStatusText.Foreground = '#FF59D48B' }
            '不匹配' { $identityStatusText.Foreground = '#FFFF7B72' }
            '待退出后确认' { $identityStatusText.Foreground = '#FFFFC857' }
            default { $identityStatusText.Foreground = $window.Resources['TextSecondaryBrush'] }
        }
        $refreshStatusText.Text = if (@($Snapshot.ReadOnlyErrors).Count -eq 0) {
            '状态已刷新'
        } else { '部分只读状态暂不可用' }
        Update-QiehaoProfileFilter
    }

    function Invoke-QiehaoReadOnlyRefresh {
        try {
            $snapshot = Get-QiehaoGuiSnapshot `
                -ListProvider { @(Get-CodexAccountSlot) } `
                -ActiveProvider { Get-CodexActiveProfile } `
                -ProcessProvider { Test-CodexProcessesStopped } `
                -ActiveIdentityProvider { Test-CodexActiveIdentity }
            Set-QiehaoSnapshot -Snapshot $snapshot
        }
        catch {
            $refreshStatusText.Text = '只读刷新失败'
            $codexStatusText.Text = '未知'
            $script:guiCurrentCodexStatus = '未知'
            $identityStatusText.Text = '无法确认'
            Update-QiehaoActionButtons
        }
    }

    function Update-QiehaoCodexSafetyHint {
        if ($script:guiManualSwitchWaitInProgress) {
            $codexSafetyHintText.Text =
                '等待用户正常退出 Codex；检测到完全退出后将自动继续切换。'
            $codexSafetyHintText.Foreground = '#FFFFC857'
            $cancelSwitchWaitButton.Visibility =
                [System.Windows.Visibility]::Visible
            return
        }
        $cancelSwitchWaitButton.Visibility =
            [System.Windows.Visibility]::Collapsed
        switch ($script:guiCurrentCodexStatus) {
            '运行中' {
                $codexSafetyHintText.Text =
                    'Codex 正在运行。切换账号前，请在 Codex 中选择“文件 → 退出”，或从系统托盘选择“Quit Codex”。关闭主窗口不等于完全退出。'
                $codexSafetyHintText.Foreground = '#FFFFC857'
            }
            '已退出' {
                $codexSafetyHintText.Text = 'Codex 已安全退出，可以切换账号。'
                $codexSafetyHintText.Foreground = '#FF59D48B'
            }
            default {
                $codexSafetyHintText.Text =
                    '无法确认 Codex 是否完全退出，请先检查 Codex 状态；为保护账号状态，切换与写操作将安全停止。'
                $codexSafetyHintText.Foreground = '#FFFF7B72'
            }
        }
    }

    function Set-QiehaoCodexStatusVisual {
        param(
            [Parameter(Mandatory = $true)]
            [ValidateSet('运行中', '已退出', '未知')]
            [string]$Status
        )
        $script:guiCurrentCodexStatus = $Status
        $codexStatusText.Text = $Status
        switch ($Status) {
            '运行中' { $codexStatusText.Foreground = '#FFFF7B72' }
            '已退出' { $codexStatusText.Foreground = '#FF59D48B' }
            default { $codexStatusText.Foreground = $window.Resources['TextSecondaryBrush'] }
        }
        Update-QiehaoCodexSafetyHint
    }

    function Get-QiehaoLiveCodexStatus {
        try {
            return ConvertTo-QiehaoCodexStatus -ProcessState (Test-CodexProcessesStopped)
        }
        catch { return '未知' }
    }

    function Update-QiehaoProcessOnlyStatus {
        if ($script:guiIsClosing) { return '未知' }
        $status = Get-QiehaoLiveCodexStatus
        Set-QiehaoCodexStatusVisual -Status $status
        Update-QiehaoActionButtons
        return $status
    }

    function Stop-QiehaoProcessMonitor {
        $null = Stop-QiehaoDispatcherTimer `
            -Timer $script:guiProcessTimer `
            -TickHandler $script:guiProcessTimerTickHandler
        $script:guiProcessTimer = $null
        $script:guiProcessTimerTickHandler = $null
    }

    function Start-QiehaoProcessMonitor {
        if ($script:guiIsClosing -or $null -ne $script:guiProcessTimer) { return }
        $script:guiProcessTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:guiProcessTimer.Interval = [TimeSpan]::FromSeconds(5)
        $script:guiProcessTimerTickHandler = [System.EventHandler]{
            param($sender, $eventArgs)
            if (-not $script:guiIsClosing) {
                $null = Update-QiehaoProcessOnlyStatus
            }
        }
        $script:guiProcessTimer.Add_Tick($script:guiProcessTimerTickHandler)
        $script:guiProcessTimer.Start()
    }

    function Stop-QiehaoLaunchWaitTimer {
        if ($null -ne $script:guiLaunchWaitRuntime) {
            $null = Stop-QiehaoWaitTimerRuntime `
                -Runtime $script:guiLaunchWaitRuntime -Result 'Cancelled'
        }
        else {
            $null = Stop-QiehaoDispatcherTimer `
                -Timer $script:guiLaunchTimer `
                -TickHandler $script:guiLaunchTimerTickHandler
        }
        $script:guiLaunchWaitRuntime = $null
        $script:guiLaunchTimer = $null
        $script:guiLaunchTimerTickHandler = $null
    }

    function Stop-QiehaoManualSwitchWaitTimer {
        param([string]$Result = 'Cancelled')
        if ($null -ne $script:guiManualSwitchWaitRuntime) {
            $null = Stop-QiehaoWaitTimerRuntime `
                -Runtime $script:guiManualSwitchWaitRuntime -Result $Result
        }
        else {
            $null = Stop-QiehaoDispatcherTimer `
                -Timer $script:guiManualSwitchWaitTimer `
                -TickHandler $script:guiManualSwitchWaitTimerTickHandler
        }
        $script:guiManualSwitchWaitRuntime = $null
        $script:guiManualSwitchWaitTimer = $null
        $script:guiManualSwitchWaitTimerTickHandler = $null
    }

    function Stop-QiehaoAllTimers {
        $hadActiveWait = (
            $null -ne $script:guiManualSwitchWaitRuntime -and
            [bool]$script:guiManualSwitchWaitRuntime.Active
        )
        $script:guiIsClosing = $true
        Stop-QiehaoProcessMonitor
        Stop-QiehaoLaunchWaitTimer
        Stop-QiehaoManualSwitchWaitTimer -Result 'WindowClosing'
        $script:guiPendingAction = $null
        $script:guiPendingTargetProfile = $null
        $script:guiManualSwitchWaitInProgress = $false
        $script:guiIsWriteOperationBusy = $false
        if ($hadActiveWait) {
            try { $refreshStatusText.Text = '切换等待已停止' }
            catch { }
        }
        try { Update-QiehaoActionButtons }
        catch { }
    }

    function Get-QiehaoInstalledCodexApplications {
        $results = @()
        if ($null -eq (Get-Command -Name Get-AppxPackage -ErrorAction SilentlyContinue) -or
            $null -eq (Get-Command -Name Get-AppxPackageManifest -ErrorAction SilentlyContinue)) {
            return @()
        }
        try {
            foreach ($package in @(Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction Stop)) {
                $family = [string]$package.PackageFamilyName
                if ([string]::IsNullOrWhiteSpace($family)) { continue }
                $manifest = Get-AppxPackageManifest -Package $package -ErrorAction Stop
                foreach ($application in @($manifest.Package.Applications.Application)) {
                    $applicationId = [string]$application.Id
                    if (-not [string]::IsNullOrWhiteSpace($applicationId)) {
                        $results += [pscustomobject]@{
                            PackageFamilyName = $family
                            ApplicationId = $applicationId
                        }
                    }
                }
            }
        }
        catch { return @() }
        return @($results)
    }

    function Get-QiehaoStartApplications {
        if ($null -eq (Get-Command -Name Get-StartApps -ErrorAction SilentlyContinue)) {
            return @()
        }
        try { return @(Get-StartApps -ErrorAction Stop) }
        catch { return @() }
    }

    function Resolve-QiehaoLaunchTarget {
        if ($null -eq $script:guiLaunchSettings) {
            $script:guiLaunchSettings = Read-QiehaoLaunchSettings `
                -StateDirectory $stateDirectory
        }
        try {
            if ([string]$script:guiLaunchSettings.Mode -ceq 'Custom') {
                $script:guiLaunchTarget = Find-QiehaoCodexLaunchTarget `
                    -Mode Custom -CustomPath ([string]$script:guiLaunchSettings.CustomPath)
            }
            else {
                $script:guiLaunchTarget = Find-QiehaoCodexLaunchTarget -Mode Auto `
                    -AppxApplications @(Get-QiehaoInstalledCodexApplications) `
                    -StartApps @(Get-QiehaoStartApplications)
            }
        }
        catch {
            $script:guiLaunchTarget = [pscustomobject]@{
                Available = $false; Type = 'Unavailable'
                AppUserModelId = $null; ExecutablePath = $null
                DisplayStatus = '检测失败'; Source = 'None'
            }
        }
        $launchTargetText.Text = 'Codex 启动目标：' +
            [string]$script:guiLaunchTarget.DisplayStatus
        Update-QiehaoActionButtons
        return $script:guiLaunchTarget
    }

    function Show-QiehaoLaunchSettingsDialog {
        $dialog = New-Object System.Windows.Window
        $dialog.Title = 'Codex 启动设置'
        $dialog.Width = 600
        $dialog.Height = 310
        $dialog.MinWidth = 520
        $dialog.MinHeight = 280
        $dialog.WindowStartupLocation = 'CenterOwner'
        $dialog.ResizeMode = 'NoResize'
        $dialog.ShowInTaskbar = $false
        $dialog.Owner = $window
        $dialog.FontFamily = $window.FontFamily
        $dialog.FontSize = $window.FontSize

        $root = New-Object System.Windows.Controls.Grid
        $root.Margin = 18
        foreach ($height in @('Auto', 'Auto', 'Auto', '*', 'Auto')) {
            $row = New-Object System.Windows.Controls.RowDefinition
            $row.Height = $height
            $root.RowDefinitions.Add($row)
        }
        $intro = New-Object System.Windows.Controls.TextBlock
        $intro.Text = '推荐使用自动检测。仅在便携版或特殊安装位置时选择自定义 EXE。'
        $intro.TextWrapping = 'Wrap'
        [System.Windows.Controls.Grid]::SetRow($intro, 0)
        $root.Children.Add($intro) | Out-Null

        $modePanel = New-Object System.Windows.Controls.StackPanel
        $modePanel.Orientation = 'Horizontal'
        $modePanel.Margin = '0,14,0,10'
        [System.Windows.Controls.Grid]::SetRow($modePanel, 1)
        $autoRadio = New-Object System.Windows.Controls.RadioButton
        $autoRadio.Content = '自动检测（推荐）'
        $autoRadio.GroupName = 'LaunchMode'
        $autoRadio.Margin = '0,0,18,0'
        $customRadio = New-Object System.Windows.Controls.RadioButton
        $customRadio.Content = '自定义 EXE'
        $customRadio.GroupName = 'LaunchMode'
        $modePanel.Children.Add($autoRadio) | Out-Null
        $modePanel.Children.Add($customRadio) | Out-Null
        $root.Children.Add($modePanel) | Out-Null

        $pathGrid = New-Object System.Windows.Controls.Grid
        $pathGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
        $browseColumn = New-Object System.Windows.Controls.ColumnDefinition
        $browseColumn.Width = 'Auto'
        $pathGrid.ColumnDefinitions.Add($browseColumn)
        [System.Windows.Controls.Grid]::SetRow($pathGrid, 2)
        $pathBox = New-Object System.Windows.Controls.TextBox
        $pathBox.MinHeight = 32
        $pathBox.Padding = '7,4'
        $pathBox.Text = [string]$script:guiLaunchSettings.CustomPath
        $browseButton = New-Object System.Windows.Controls.Button
        $browseButton.Content = '浏览…'
        $browseButton.MinWidth = 82
        $browseButton.Margin = '8,0,0,0'
        [System.Windows.Controls.Grid]::SetColumn($browseButton, 1)
        $pathGrid.Children.Add($pathBox) | Out-Null
        $pathGrid.Children.Add($browseButton) | Out-Null
        $root.Children.Add($pathGrid) | Out-Null

        $hint = New-Object System.Windows.Controls.TextBlock
        $hint.Margin = '0,12,0,0'
        $hint.TextWrapping = 'Wrap'
        $hint.Text = '不会附加命令行参数，不会更改环境变量、权限、Codex 配置或登录状态。'
        [System.Windows.Controls.Grid]::SetRow($hint, 3)
        $root.Children.Add($hint) | Out-Null

        $buttons = New-Object System.Windows.Controls.StackPanel
        $buttons.Orientation = 'Horizontal'
        $buttons.HorizontalAlignment = 'Right'
        [System.Windows.Controls.Grid]::SetRow($buttons, 4)
        $detectButton = New-Object System.Windows.Controls.Button
        $detectButton.Content = '重新检测'
        $saveButton = New-Object System.Windows.Controls.Button
        $saveButton.Content = '保存'
        $saveButton.IsDefault = $true
        $cancelButton = New-Object System.Windows.Controls.Button
        $cancelButton.Content = '取消'
        $cancelButton.IsCancel = $true
        $cancelButton.Margin = '0'
        $buttons.Children.Add($detectButton) | Out-Null
        $buttons.Children.Add($saveButton) | Out-Null
        $buttons.Children.Add($cancelButton) | Out-Null
        $root.Children.Add($buttons) | Out-Null

        $setPathAvailability = {
            $pathBox.IsEnabled = [bool]$customRadio.IsChecked
            $browseButton.IsEnabled = [bool]$customRadio.IsChecked
        }
        $autoRadio.IsChecked = ([string]$script:guiLaunchSettings.Mode -ceq 'Auto')
        $customRadio.IsChecked = -not [bool]$autoRadio.IsChecked
        $autoRadio.Add_Checked($setPathAvailability)
        $customRadio.Add_Checked($setPathAvailability)
        & $setPathAvailability
        $browseButton.Add_Click({
            $picker = New-Object Microsoft.Win32.OpenFileDialog
            $picker.Title = '选择 Codex 可执行文件'
            $picker.Filter = '可执行文件 (*.exe)|*.exe'
            $picker.CheckFileExists = $true
            $picker.Multiselect = $false
            if ($picker.ShowDialog($dialog) -eq $true) { $pathBox.Text = $picker.FileName }
        })
        $detectButton.Add_Click({
            $autoRadio.IsChecked = $true
            $target = Find-QiehaoCodexLaunchTarget -Mode Auto `
                -AppxApplications @(Get-QiehaoInstalledCodexApplications) `
                -StartApps @(Get-QiehaoStartApplications)
            $hint.Text = '检测结果：' + [string]$target.DisplayStatus
        })
        $saveButton.Add_Click({
            $mode = if ([bool]$customRadio.IsChecked) { 'Custom' } else { 'Auto' }
            try {
                $script:guiLaunchSettings = Write-QiehaoLaunchSettings `
                    -StateDirectory $stateDirectory -Mode $mode `
                    -CustomPath ([string]$pathBox.Text)
                $null = Resolve-QiehaoLaunchTarget
                $dialog.DialogResult = $true
            }
            catch {
                [void][System.Windows.MessageBox]::Show(
                    $dialog,
                    '自定义路径必须是现有的本地 .exe 文件，且不能是重解析链接。',
                    'Codex 启动设置',
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning
                )
            }
        })
        $dialog.Content = $root
        $null = $dialog.ShowDialog()
    }

    function Complete-QiehaoLaunchWait {
        param(
            [Parameter(Mandatory = $true)]
            [ValidateSet('Running', 'Stopped', 'Unknown')]
            [string]$FinalState
        )
        Stop-QiehaoLaunchWaitTimer
        $script:guiIsWriteOperationBusy = $false
        Set-QiehaoWriteBusy -Value $false
        try {
            if (-not $script:guiIsClosing) { Start-QiehaoProcessMonitor }
            if ($FinalState -ceq 'Running') {
                $refreshStatusText.Text = 'Codex 已启动'
                Invoke-QiehaoReadOnlyRefresh
                return
            }
            if ($FinalState -ceq 'Unknown') {
                Show-QiehaoSafeMessage `
                    -Message '已请求启动，但无法确认 Codex 进程状态。' `
                    -Severity Warning
            }
            else {
                Show-QiehaoSafeMessage `
                    -Message '已请求启动，但 10 秒内未检测到 Codex 运行。' `
                    -Severity Warning
            }
            $null = Update-QiehaoProcessOnlyStatus
        }
        catch {
            $script:guiIsWriteOperationBusy = $false
            try {
                $refreshStatusText.Text = '启动状态检测失败，已停止等待'
                Update-QiehaoActionButtons
            }
            catch { }
        }
    }

    function Start-QiehaoLaunchWait {
        Stop-QiehaoProcessMonitor
        Stop-QiehaoLaunchWaitTimer
        $script:guiLaunchWaitRuntime = New-QiehaoWaitTimerRuntime `
            -IntervalMilliseconds 500 -TimeoutSeconds 10 `
            -ClosingProvider { [bool]$script:guiIsClosing } `
            -ProbeProvider {
                $status = Get-QiehaoLiveCodexStatus
                if ($status -ceq '运行中') { return 'Succeeded' }
                if ($status -ceq '未知') { return 'Unknown' }
                return 'Pending'
            } `
            -CompletionAction {
                param($Result, $Runtime)
                switch ($Result) {
                    'Succeeded' { Complete-QiehaoLaunchWait -FinalState 'Running' }
                    'TimedOut' { Complete-QiehaoLaunchWait -FinalState 'Stopped' }
                    'Closing' { Stop-QiehaoLaunchWaitTimer }
                    default { Complete-QiehaoLaunchWait -FinalState 'Unknown' }
                }
            }
        $script:guiLaunchTimer = $script:guiLaunchWaitRuntime.Timer
        $script:guiLaunchTimerTickHandler = `
            $script:guiLaunchWaitRuntime.TickHandler
        try {
            $null = Start-QiehaoWaitTimerRuntime `
                -Runtime $script:guiLaunchWaitRuntime
        }
        catch { Complete-QiehaoLaunchWait -FinalState 'Unknown' }
    }

    function Invoke-QiehaoLaunchCodex {
        if ($script:guiIsWriteOperationBusy) { return }
        $liveStatus = Get-QiehaoLiveCodexStatus
        Set-QiehaoCodexStatusVisual -Status $liveStatus
        if ($liveStatus -ceq '运行中') {
            Update-QiehaoActionButtons
            Show-QiehaoSafeMessage -Message 'Codex 已在运行。'
            return
        }
        if ($liveStatus -cne '已退出') {
            Update-QiehaoActionButtons
            Show-QiehaoSafeMessage -Message '无法安全确认 Codex 是否已退出，本次未启动。' `
                -Severity Warning
            return
        }
        if ($null -eq $script:guiLaunchTarget -or
            -not [bool]$script:guiLaunchTarget.Available) {
            $null = Resolve-QiehaoLaunchTarget
        }
        Set-QiehaoWriteBusy -Value $true -StatusText '正在请求启动 Codex…'
        $result = Invoke-QiehaoCodexLaunchRequest -Target $script:guiLaunchTarget `
            -LaunchProvider {
                param($Target)
                if ([string]$Target.Type -ceq 'AppUserModelId') {
                    $aumid = [string]$Target.AppUserModelId
                    if ($aumid -notmatch '^[A-Za-z0-9._-]+![A-Za-z0-9._-]+$') {
                        throw 'CODEX_LAUNCH_TARGET_INVALID'
                    }
                    Start-Process -FilePath 'explorer.exe' `
                        -ArgumentList ('shell:AppsFolder\' + $aumid) `
                        -WindowStyle Hidden -ErrorAction Stop
                    return $true
                }
                $validation = Test-QiehaoCustomLaunchPath `
                    -Path ([string]$Target.ExecutablePath)
                if (-not $validation.IsValid) { throw 'CODEX_CUSTOM_PATH_INVALID' }
                Start-Process -FilePath ([string]$validation.FullPath) -ErrorAction Stop
                return $true
            }
        if ([string]$result.Result -ceq 'CODEX_LAUNCH_REQUESTED') {
            Start-QiehaoLaunchWait
            return
        }
        Set-QiehaoWriteBusy -Value $false
        Show-QiehaoSafeMessage `
            -Message '无法启动 Codex。请打开“启动设置”重新检测或选择正确的 EXE。' `
            -Severity Warning
    }

    function Complete-QiehaoManualSwitchWait {
        param(
            [Parameter(Mandatory = $true)]
            [ValidateSet('Stopped', 'Running', 'Unknown', 'Cancelled', 'Closing')]
            [string]$FinalState
        )
        $targetProfile = $script:guiPendingTargetProfile
        Stop-QiehaoManualSwitchWaitTimer -Result $FinalState
        $script:guiPendingAction = $null
        $script:guiPendingTargetProfile = $null
        $script:guiManualSwitchWaitInProgress = $false
        $script:guiIsWriteOperationBusy = $false
        if ($script:guiIsClosing -or $FinalState -ceq 'Closing') { return }
        try {
            Start-QiehaoProcessMonitor
            if ($FinalState -ceq 'Stopped') {
                Set-QiehaoCodexStatusVisual -Status '已退出'
                if ([string]::IsNullOrWhiteSpace($targetProfile)) {
                    Show-QiehaoSafeMessage `
                        -Message '等待目标已丢失，本次未切换账号。' `
                        -Severity Warning
                    Update-QiehaoActionButtons
                    return
                }
                Set-QiehaoWriteBusy -Value $true `
                    -StatusText "已检测到 Codex 完全退出，正在切换到 '$targetProfile'……"
                Invoke-QiehaoSwitchCore -TargetProfile $targetProfile
                return
            }
            if ($FinalState -ceq 'Running') {
                Set-QiehaoCodexStatusVisual -Status '运行中'
                Show-QiehaoSafeMessage `
                    -Message '等待超时，90 秒内尚未检测到 Codex 完全退出。未执行账号切换；您可以再次点击“切换账号”重新等待。' `
                    -Severity Warning
            }
            elseif ($FinalState -ceq 'Cancelled') {
                $refreshStatusText.Text = '已取消等待，本次未切换账号'
            }
            else {
                Set-QiehaoCodexStatusVisual -Status '未知'
                Show-QiehaoSafeMessage `
                    -Message '无法确认 Codex 是否完全退出，本次未切换账号。' `
                    -Severity Warning
            }
            Update-QiehaoActionButtons
        }
        catch {
            $script:guiIsWriteOperationBusy = $false
            try {
                $refreshStatusText.Text = '退出状态检测失败，本次未切换账号'
                Update-QiehaoActionButtons
            }
            catch { }
        }
    }

    function Start-QiehaoManualSwitchWait {
        param(
            [Parameter(Mandatory = $true)][string]$TargetProfile,
            [ValidateRange(0.001, 3600)][double]$TimeoutSeconds = 90
        )
        $liveStatus = Get-QiehaoLiveCodexStatus
        Set-QiehaoCodexStatusVisual -Status $liveStatus
        if ($liveStatus -ceq '已退出') {
            Set-QiehaoWriteBusy -Value $true -StatusText '正在安全切换账号……'
            Invoke-QiehaoSwitchCore -TargetProfile $TargetProfile
            return
        }
        if ($liveStatus -cne '运行中') {
            Show-QiehaoSafeMessage `
                -Message '无法确认 Codex 是否完全退出，本次未开始等待或切换。' `
                -Severity Warning
            Update-QiehaoActionButtons
            return
        }
        Stop-QiehaoManualSwitchWaitTimer -Result 'Restarted'
        $script:guiPendingAction = 'Switch'
        $script:guiPendingTargetProfile = $TargetProfile
        $script:guiManualSwitchWaitInProgress = $true
        Set-QiehaoWriteBusy -Value $true `
            -StatusText "等待 Codex 完全退出，随后自动切换到 '$TargetProfile'……"
        Stop-QiehaoProcessMonitor
        try {
            $script:guiManualSwitchWaitRuntime = New-QiehaoWaitTimerRuntime `
                -IntervalMilliseconds 500 -TimeoutSeconds $TimeoutSeconds `
                -ClosingProvider { [bool]$script:guiIsClosing } `
                -ProbeProvider {
                    $status = ConvertTo-QiehaoCodexStatus `
                        -ProcessState (Test-CodexProcessesStopped)
                    Set-QiehaoCodexStatusVisual -Status $status
                    if ($status -ceq '已退出') { return 'Succeeded' }
                    if ($status -ceq '未知') { return 'Unknown' }
                    return 'Pending'
                } `
                -CompletionAction {
                    param($Result, $Runtime)
                    switch ($Result) {
                        'Succeeded' {
                            Complete-QiehaoManualSwitchWait -FinalState 'Stopped'
                        }
                        'TimedOut' {
                            Complete-QiehaoManualSwitchWait -FinalState 'Running'
                        }
                        'Closing' {
                            Complete-QiehaoManualSwitchWait -FinalState 'Closing'
                        }
                        default {
                            Complete-QiehaoManualSwitchWait -FinalState 'Unknown'
                        }
                    }
                }
            $script:guiManualSwitchWaitTimer =
                $script:guiManualSwitchWaitRuntime.Timer
            $script:guiManualSwitchWaitTimerTickHandler =
                $script:guiManualSwitchWaitRuntime.TickHandler
            $null = Start-QiehaoWaitTimerRuntime `
                -Runtime $script:guiManualSwitchWaitRuntime
        }
        catch { Complete-QiehaoManualSwitchWait -FinalState 'Unknown' }
    }

    function Cancel-QiehaoManualSwitchWait {
        if (-not $script:guiManualSwitchWaitInProgress) { return }
        Complete-QiehaoManualSwitchWait -FinalState 'Cancelled'
    }

    function Invoke-QiehaoSwitchCore {
        param([Parameter(Mandatory = $true)][string]$TargetProfile)
        try {
            $result = Invoke-QiehaoOperationProvider -Operation 'SWITCH' `
                -Provider { param($Name) Switch-CodexAccountProfile -Name $Name } `
                -ArgumentList @($TargetProfile)
            Show-QiehaoOperationResult -Result $result
            if ($result.RefreshRequired) { Invoke-QiehaoReadOnlyRefresh }
        }
        finally { Set-QiehaoWriteBusy -Value $false }
    }

    function Invoke-QiehaoSwitchSelectedProfile {
        $targetProfile = Get-QiehaoSelectedProfileName
        if ($script:guiIsWriteOperationBusy) {
            Show-QiehaoOperationResult -Result (
                ConvertTo-QiehaoOperationResult -ResultCode 'OPERATION_BUSY'
            )
            return
        }
        if ([string]::IsNullOrWhiteSpace($targetProfile)) {
            Show-QiehaoOperationResult -Result (
                ConvertTo-QiehaoOperationResult -ResultCode 'PROFILE_SELECTION_REQUIRED'
            )
            return
        }
        if ($targetProfile.Equals($script:guiCurrentActiveProfile,
            [StringComparison]::OrdinalIgnoreCase)) {
            Show-QiehaoOperationResult -Result (
                ConvertTo-QiehaoOperationResult -ResultCode 'ALREADY_ACTIVE'
            )
            return
        }
        $liveStatus = Get-QiehaoLiveCodexStatus
        if ($liveStatus -ceq '未知') {
            Show-QiehaoOperationResult -Result (
                ConvertTo-QiehaoOperationResult -ResultCode 'CODEX_PROCESS_STATE_UNKNOWN'
            )
            return
        }
        if ($liveStatus -ceq '运行中') {
            $confirmed = Show-QiehaoChoiceDialog -Title '切换账号' `
                -Message ("目标账号：$targetProfile`n`n" +
                    '请从 Codex 菜单“文件 → 退出”或系统托盘选择“退出”。' +
                    "`n检测到 Codex 完全退出后将自动继续切换。") `
                -ConfirmText '开始等待并继续切换'
            if (-not $confirmed) { return }
            Start-QiehaoManualSwitchWait -TargetProfile $targetProfile
            return
        }
        Set-QiehaoWriteBusy -Value $true -StatusText '正在安全切换账号…'
        Invoke-QiehaoSwitchCore -TargetProfile $targetProfile
    }

    function Invoke-QiehaoVerifySelectedProfile {
        if ($script:guiIsWriteOperationBusy) {
            Show-QiehaoOperationResult -Result (
                ConvertTo-QiehaoOperationResult -ResultCode 'OPERATION_BUSY'
            )
            return
        }
        $selectedProfile = Get-QiehaoSelectedProfileName
        Set-QiehaoWriteBusy -Value $true -StatusText '正在验证账号…'
        try {
            $verifyResult = Invoke-QiehaoVerifyRequest `
                -SelectedProfile $selectedProfile `
                -CodexStatus (Get-QiehaoLiveCodexStatus) `
                -VerifyProvider { param($ProfileName) Test-CodexProfile -Name $ProfileName }
            if ($verifyResult.CoreCalled -and
                -not [string]::IsNullOrWhiteSpace($selectedProfile)) {
                $script:guiVerificationStates[$selectedProfile] = `
                    [string]$verifyResult.VerificationStatus
            }
            $message = [string]$verifyResult.Message
            if ($verifyResult.ResultCode -ceq 'PROFILE_VERIFY_SUCCESS') {
                $message = "账号：$selectedProfile`n状态：已验证"
            }
            Show-QiehaoSafeMessage -Message $message
            if ($verifyResult.CoreCalled) { Invoke-QiehaoReadOnlyRefresh }
        }
        finally { Set-QiehaoWriteBusy -Value $false }
    }

    function Invoke-QiehaoRenameSelectedProfile {
        if ($script:guiIsWriteOperationBusy) { return }
        $oldName = Get-QiehaoSelectedProfileName
        if ([string]::IsNullOrWhiteSpace($oldName)) { return }
        $newName = Show-QiehaoNameDialog -Title '重命名账号' `
            -Prompt '新名称：' -CurrentName $oldName
        if ([string]::IsNullOrWhiteSpace($newName)) { return }
        Set-QiehaoWriteBusy -Value $true -StatusText '正在重命名账号…'
        try {
            $result = Invoke-QiehaoOperationProvider -Operation 'RENAME' `
                -Provider {
                    param($From, $To)
                    Rename-CodexProfile -OldName $From -NewName $To
                } -ArgumentList @($oldName, $newName)
            if ($result.IsSuccess -and
                $script:guiVerificationStates.ContainsKey($oldName)) {
                $script:guiVerificationStates[$newName] = $script:guiVerificationStates[$oldName]
                $script:guiVerificationStates.Remove($oldName)
            }
            Show-QiehaoOperationResult -Result $result
            if ($result.RefreshRequired) { Invoke-QiehaoReadOnlyRefresh }
        }
        finally { Set-QiehaoWriteBusy -Value $false }
    }

    function Invoke-QiehaoDeleteSelectedProfile {
        if ($script:guiIsWriteOperationBusy) { return }
        $profileName = Get-QiehaoSelectedProfileName
        if ([string]::IsNullOrWhiteSpace($profileName) -or
            $profileName.Equals($script:guiCurrentActiveProfile,
                [StringComparison]::OrdinalIgnoreCase)) { return }
        $message = "确定删除本地账号 '$profileName' 吗？`n`n" +
            "这只会删除本工具保存的本地账号槽位，`n" +
            '不会删除 OpenAI 账号、订阅或网页登录状态。'
        if (-not (Show-QiehaoChoiceDialog -Title '删除本地账号' `
            -Message $message -ConfirmText '删除')) { return }
        Set-QiehaoWriteBusy -Value $true -StatusText '正在删除本地账号…'
        try {
            $result = Invoke-QiehaoOperationProvider -Operation 'DELETE' `
                -Provider { param($Name) Remove-CodexProfile -Name $Name -ConfirmDelete } `
                -ArgumentList @($profileName)
            if ($result.IsSuccess) { $script:guiVerificationStates.Remove($profileName) }
            Show-QiehaoOperationResult -Result $result
            if ($result.RefreshRequired) { Invoke-QiehaoReadOnlyRefresh }
        }
        finally { Set-QiehaoWriteBusy -Value $false }
    }

    function Start-QiehaoAddWizard {
        try {
            $activeName = $null
            try {
                $activeState = Get-CodexActiveProfile
                $activeName = [string]$activeState.ActiveProfile
            }
            catch {
                if ([string]$_.Exception.Message -ceq 'ACTIVE_PROFILE_NOT_INITIALIZED') {
                    $activeName = $null
                }
                else {
                    Show-QiehaoSafeMessage `
                        -Message '无法安全读取当前账号状态，已停止添加流程。' `
                        -Severity Warning
                    return
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($activeName)) {
                $saveResult = Invoke-QiehaoOperationProvider `
                    -Operation 'SAVE_ACTIVE' -Provider { Save-CodexActiveProfile }
                if (-not $saveResult.IsSuccess) {
                    Show-QiehaoOperationResult -Result $saveResult
                    return
                }
            }
            $instructions = "请打开 Codex Desktop，使用官方登录流程登录要添加的新账号。`n`n" +
                "登录完成后，请正常退出 Codex，然后返回本窗口继续。`n`n" +
                '本工具不会自动操作 OAuth、网页、Cookie 或账号选择。'
            $ready = Show-QiehaoChoiceDialog -Title '添加账号' `
                -Message $instructions -ConfirmText '我已登录新账号并退出'
            if (-not $ready) { return }
            $liveStatus = Get-QiehaoLiveCodexStatus
            if ($liveStatus -ceq '运行中') {
                Show-QiehaoSafeMessage -Message '请先正常退出 Codex，再采集新账号。' `
                    -Severity Warning
                return
            }
            if ($liveStatus -cne '已退出') {
                Show-QiehaoSafeMessage `
                    -Message '无法确认 Codex 是否完全退出，本次未添加账号。' `
                    -Severity Warning
                return
            }
            $profileName = Show-QiehaoNameDialog -Title '添加账号' -Prompt '本地名称：'
            if ([string]::IsNullOrWhiteSpace($profileName)) { return }
            $result = Invoke-QiehaoOperationProvider -Operation 'ADD' `
                -Provider { param($Name) Add-CodexProfile -Name $Name } `
                -ArgumentList @($profileName)
            Show-QiehaoOperationResult -Result $result
            if ($result.RefreshRequired) { Invoke-QiehaoReadOnlyRefresh }
        }
        finally { Set-QiehaoWriteBusy -Value $false }
    }

    function Invoke-QiehaoAddAccount {
        if ($script:guiIsWriteOperationBusy) { return }
        $liveStatus = Get-QiehaoLiveCodexStatus
        if ($liveStatus -ceq '未知') {
            Show-QiehaoSafeMessage -Message '无法确认 Codex 进程状态，请重新检测。' `
                -Severity Warning
            return
        }
        Set-QiehaoWriteBusy -Value $true -StatusText '准备添加账号…'
        if ($liveStatus -ceq '运行中') {
            Set-QiehaoWriteBusy -Value $false
            Show-QiehaoSafeMessage `
                -Message '请先从 Codex 菜单“文件 → 退出”或系统托盘选择“退出”，确认状态变为“已退出”后再添加账号。' `
                -Severity Warning
            return
        }
        Start-QiehaoAddWizard
    }

    function Get-QiehaoDataGridRowFromSource {
        param([AllowNull()][object]$Source)
        $current = $Source -as [System.Windows.DependencyObject]
        while ($null -ne $current) {
            if ($current -is [System.Windows.Controls.DataGridRow]) { return $current }
            if ($current -eq $profilesGrid) { return $null }
            try { $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current) }
            catch { return $null }
        }
        return $null
    }

    $themes = @(Get-QiehaoBackgroundThemes)
    $themeComboBox.ItemsSource = $themes
    $preference = if ($SelfTest) {
        [pscustomobject]@{ Background = '01-blue-glass'; IsValid = $true; UsedDefault = $true }
    } else { Read-QiehaoUiPreferences -StateDirectory $stateDirectory }
    $startupTheme = @($themes | Where-Object {
        [string]$_.Id -ceq [string]$preference.Background
    } | Select-Object -First 1)
    if ($startupTheme.Count -ne 1) {
        $startupTheme = @($themes | Where-Object {
            [string]$_.Id -ceq '01-blue-glass'
        } | Select-Object -First 1)
    }
    if ($startupTheme.Count -ne 1) { throw 'GUI_DEFAULT_THEME_NOT_FOUND' }
    $startupTheme = $startupTheme[0]
    $themeComboBox.SelectedItem = $startupTheme
    $startupImageResult = Set-QiehaoTheme -Theme $startupTheme
    $themeComboBox.Add_SelectionChanged({
        if ($script:guiThemePersistenceReady -and
            $null -ne $themeComboBox.SelectedItem) {
            $selectedTheme = $themeComboBox.SelectedItem
            $null = Set-QiehaoTheme -Theme $selectedTheme -Persist
        }
    })

    if ($SelfTest) {
        $script:guiLaunchSettings = [pscustomobject]@{
            Mode = 'Auto'; CustomPath = ''; IsValid = $true; UsedDefault = $true
        }
        $script:guiLaunchTarget = Find-QiehaoCodexLaunchTarget -Mode Auto `
            -AppxApplications @([pscustomobject]@{
                PackageFamilyName = 'OpenAI.Codex_8wekyb3d8bbwe'
                ApplicationId = 'App'
            })
        $launchTargetText.Text = 'Codex 启动目标：' +
            [string]$script:guiLaunchTarget.DisplayStatus
    }
    else {
        $script:guiLaunchSettings = Read-QiehaoLaunchSettings `
            -StateDirectory $stateDirectory
        $null = Resolve-QiehaoLaunchTarget
    }

    if ($SelfTest) {
        $fakeProfiles = @(
            [pscustomobject]@{
                Profile = 'Plus'; Active = $true; Health = 'READY'
                AuthFile = 'PRESENT'; IdentityMarker = 'PRESENT'
                Metadata = 'VALID'; UpdatedAt = '2000-01-01T00:00:00Z'
            },
            [pscustomobject]@{
                Profile = 'Team'; Active = $false; Health = 'READY'
                AuthFile = 'PRESENT'; IdentityMarker = 'PRESENT'
                Metadata = 'VALID'; UpdatedAt = '2000-01-02T00:00:00Z'
            }
        )
        $snapshot = Get-QiehaoGuiSnapshot `
            -ListProvider { $fakeProfiles }.GetNewClosure() `
            -ActiveProvider { [pscustomobject]@{ ActiveProfile = 'Plus' } } `
            -ProcessProvider { [pscustomobject]@{ ReasonCode = 'CODEX_PROCESSES_STOPPED' } } `
            -ActiveIdentityProvider { [pscustomobject]@{ Result = 'ACTIVE_IDENTITY_CONFIRMED' } }
        Set-QiehaoSnapshot -Snapshot $snapshot
        if (@($profilesGrid.ItemsSource).Count -ne 2 -or
            $codexStatusText.Text -cne '已退出' -or
            $activeProfileText.Text -cne 'Plus' -or
            $identityStatusText.Text -cne '已确认' -or
            -not [bool]$script:guiLaunchTarget.Available -or
            $themes.Count -ne 5 -or -not $startupImageResult.Loaded) {
            throw 'GUI_SELFTEST_BINDING_FAILED'
        }
        $profileSearchTextBox.Text = 'team'
        Update-QiehaoProfileFilter
        if (@($profilesGrid.ItemsSource).Count -ne 1 -or
            [string]$profilesGrid.ItemsSource[0].Name -cne 'Team') {
            throw 'GUI_SELFTEST_SEARCH_FAILED'
        }
        $alternateImageResult = Set-QiehaoTheme `
            -Theme (Get-QiehaoBackgroundTheme -Id '03-ice-glass')
        if (-not $alternateImageResult.Loaded) { throw 'GUI_SELFTEST_THEME_SWITCH_FAILED' }
        Write-Output 'GUI_SELFTEST_READY'
        return
    }

    $profilesGrid.Add_SelectionChanged({ Update-QiehaoActionButtons })
    $profileSearchTextBox.Add_TextChanged({ Update-QiehaoProfileFilter })
    $refreshButton.Add_Click({ Invoke-QiehaoReadOnlyRefresh })
    $switchButton.Add_Click({ Invoke-QiehaoSwitchSelectedProfile })
    $verifyButton.Add_Click({ Invoke-QiehaoVerifySelectedProfile })
    $addButton.Add_Click({ Invoke-QiehaoAddAccount })
    $renameButton.Add_Click({ Invoke-QiehaoRenameSelectedProfile })
    $deleteButton.Add_Click({ Invoke-QiehaoDeleteSelectedProfile })
    $launchCodexButton.Add_Click({ Invoke-QiehaoLaunchCodex })
    $launchSettingsButton.Add_Click({ Show-QiehaoLaunchSettingsDialog })
    $cancelSwitchWaitButton.Add_Click({ Cancel-QiehaoManualSwitchWait })
    $contextSwitchMenuItem.Add_Click({ Invoke-QiehaoSwitchSelectedProfile })
    $contextVerifyMenuItem.Add_Click({ Invoke-QiehaoVerifySelectedProfile })
    $contextRenameMenuItem.Add_Click({ Invoke-QiehaoRenameSelectedProfile })
    $contextDeleteMenuItem.Add_Click({ Invoke-QiehaoDeleteSelectedProfile })
    $profilesGrid.Add_PreviewMouseRightButtonDown({
        param($sender, $eventArgs)
        $row = Get-QiehaoDataGridRowFromSource -Source $eventArgs.OriginalSource
        if ($null -eq $row) { $eventArgs.Handled = $true; return }
        $profilesGrid.SelectedItem = $row.Item
        Update-QiehaoActionButtons
    })
    $profilesGrid.Add_MouseDoubleClick({
        param($sender, $eventArgs)
        $row = Get-QiehaoDataGridRowFromSource -Source $eventArgs.OriginalSource
        if ($null -eq $row) { return }
        $profilesGrid.SelectedItem = $row.Item
        Invoke-QiehaoSwitchSelectedProfile
        $eventArgs.Handled = $true
    })
    $profilesGrid.Add_PreviewKeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.Key -eq [System.Windows.Input.Key]::F2 -and
            $null -ne $profilesGrid.SelectedItem -and
            -not $script:guiIsWriteOperationBusy) {
            $eventArgs.Handled = $true
            Invoke-QiehaoRenameSelectedProfile
        }
    })
    $profileContextMenu.Add_Opened({ Update-QiehaoActionButtons })
    $window.Add_Loaded({
        Invoke-QiehaoReadOnlyRefresh
        Start-QiehaoProcessMonitor
        $script:guiThemePersistenceReady = $true
    })
    $window.Add_Closing({ Stop-QiehaoAllTimers })
    $window.Add_Closed({
        Stop-QiehaoAllTimers
    })
    [void]$window.ShowDialog()
}
finally {
    try {
        if ($null -ne (Get-Command -Name Stop-QiehaoAllTimers `
            -CommandType Function -ErrorAction SilentlyContinue)) {
            Stop-QiehaoAllTimers
        }
    }
    catch { }
    if ($null -ne $window -and $SelfTest) { $window.Close() }
    if ($null -ne $lease) { Exit-QiehaoGuiSingleInstance -Lease $lease }
}
