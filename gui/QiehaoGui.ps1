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
$stateDirectory = Join-Path -Path $projectRoot -ChildPath 'state'
$backgroundDirectory = Join-Path -Path $guiRoot `
    -ChildPath 'assets\backgrounds'
$guiMutexName = 'Qiehaoqu.CodexAccountSwitcher.Gui.v1'

Add-Type -AssemblyName PresentationCore -ErrorAction Stop
Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
Add-Type -AssemblyName WindowsBase -ErrorAction Stop

Import-Module -Name $coreModulePath -Force -ErrorAction Stop
Import-Module -Name $helperModulePath -Force -ErrorAction Stop

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
        if ($null -ne $xmlReader) {
            $xmlReader.Dispose()
        }
        if ($null -ne $stringReader) {
            $stringReader.Dispose()
        }
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
    if ($null -eq $control) {
        throw ('GUI_CONTROL_NOT_FOUND_' + $Name)
    }
    return $control
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
    $profileCountText = Get-RequiredControl -Window $window -Name 'ProfileCountText'
    $codexStatusText = Get-RequiredControl -Window $window -Name 'CodexStatusText'
    $activeProfileText = Get-RequiredControl -Window $window -Name 'ActiveProfileText'
    $identityStatusText = Get-RequiredControl -Window $window -Name 'IdentityStatusText'
    $webChatGPTText = Get-RequiredControl -Window $window -Name 'WebChatGPTText'
    $refreshStatusText = Get-RequiredControl -Window $window -Name 'RefreshStatusText'
    $refreshButton = Get-RequiredControl -Window $window -Name 'RefreshButton'
    $themeComboBox = Get-RequiredControl -Window $window -Name 'ThemeComboBox'
    $backgroundImage = Get-RequiredControl -Window $window -Name 'BackgroundImage'
    $backgroundOverlay = Get-RequiredControl -Window $window -Name 'BackgroundOverlay'

    function Set-QiehaoTheme {
        param(
            [Parameter(Mandatory = $true)]
            [object]$Theme,

            [switch]$Persist
        )

        $imageResult = Get-QiehaoBackgroundImage -Theme $Theme `
            -BackgroundDirectory $backgroundDirectory
        if ($imageResult.Loaded) {
            $backgroundImage.Source = $imageResult.ImageSource
        }
        else {
            $backgroundImage.Source = $null
            $window.Background = '#FFF4F6F8'
        }

        $overlayColor = if ([string]$Theme.OverlayMode -ceq 'Dark') {
            '#A6212B3A'
        }
        else {
            '#BFFFFFFF'
        }
        $backgroundOverlay.Background = $overlayColor

        if ($Persist) {
            try {
                $null = Write-QiehaoUiPreferences `
                    -StateDirectory $stateDirectory -Background $Theme.Id
                $refreshStatusText.Text = if ($imageResult.Loaded) {
                    '皮肤已切换并保存'
                }
                else {
                    '背景图片不可用，已使用默认纯色并保存选择'
                }
            }
            catch {
                $refreshStatusText.Text = if ($imageResult.Loaded) {
                    '皮肤已切换，但偏好保存失败'
                }
                else {
                    '背景图片不可用，已使用默认纯色'
                }
            }
        }
        return $imageResult
    }

    function Set-QiehaoSnapshot {
        param(
            [Parameter(Mandatory = $true)]
            [object]$Snapshot
        )

        $rows = @($Snapshot.Profiles)
        $profilesGrid.ItemsSource = $rows
        $profileCountText.Text = if ($rows.Count -eq 1) {
            '1 个账号'
        }
        else {
            [string]$rows.Count + ' 个账号'
        }
        $codexStatusText.Text = [string]$Snapshot.CodexDesktop
        $activeProfileText.Text = [string]$Snapshot.ActiveProfile
        $identityStatusText.Text = [string]$Snapshot.IdentityStatus
        $webChatGPTText.Text = [string]$Snapshot.WebChatGPT

        switch ([string]$Snapshot.CodexDesktop) {
            '运行中' { $codexStatusText.Foreground = '#FFB42318' }
            '已退出' { $codexStatusText.Foreground = '#FF167A45' }
            default { $codexStatusText.Foreground = '#FF5B6472' }
        }

        $refreshStatusText.Text = if (@($Snapshot.ReadOnlyErrors).Count -eq 0) {
            '只读状态已刷新'
        }
        else {
            '部分只读状态暂不可用'
        }
    }

    function Invoke-QiehaoReadOnlyRefresh {
        $refreshButton.IsEnabled = $false
        try {
            $snapshot = Get-QiehaoGuiSnapshot `
                -ListProvider { @(Get-CodexAccountSlot) } `
                -ActiveProvider { Get-CodexActiveProfile } `
                -ProcessProvider { Test-CodexProcessesStopped }
            Set-QiehaoSnapshot -Snapshot $snapshot
        }
        catch {
            $refreshStatusText.Text = '只读刷新失败'
            $codexStatusText.Text = '未知'
            $identityStatusText.Text = '未知'
        }
        finally {
            $refreshButton.IsEnabled = $true
        }
    }

    $themes = @(Get-QiehaoBackgroundThemes)
    $themeComboBox.ItemsSource = $themes
    $preference = if ($SelfTest) {
        [pscustomobject]@{
            Background = '01-blue-glass'
            IsValid = $true
            UsedDefault = $true
        }
    }
    else {
        Read-QiehaoUiPreferences -StateDirectory $stateDirectory
    }
    $startupTheme = Get-QiehaoBackgroundTheme -Id $preference.Background
    if ($null -eq $startupTheme) {
        $startupTheme = Get-QiehaoBackgroundTheme -Id '01-blue-glass'
    }
    $themeComboBox.SelectedValue = $startupTheme.Id
    $startupImageResult = Set-QiehaoTheme -Theme $startupTheme
    $themeComboBox.Add_SelectionChanged({
        $selectedTheme = $themeComboBox.SelectedItem
        if ($null -ne $selectedTheme) {
            $null = Set-QiehaoTheme -Theme $selectedTheme -Persist
        }
    })

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
            -ProcessProvider {
                [pscustomobject]@{ ReasonCode = 'CODEX_PROCESSES_STOPPED' }
            }
        Set-QiehaoSnapshot -Snapshot $snapshot
        if (@($profilesGrid.ItemsSource).Count -ne 2) {
            throw 'GUI_SELFTEST_PROFILE_BINDING_FAILED'
        }
        if ($codexStatusText.Text -cne '已退出') {
            throw 'GUI_SELFTEST_CODEX_STATUS_FAILED'
        }
        if ($activeProfileText.Text -cne 'Plus') {
            throw 'GUI_SELFTEST_ACTIVE_PROFILE_FAILED'
        }
        if ($themes.Count -ne 5) {
            throw 'GUI_SELFTEST_THEME_COUNT_FAILED'
        }
        if (-not $startupImageResult.Loaded) {
            throw ('GUI_SELFTEST_THEME_LOAD_FAILED_' + `
                [string]$startupImageResult.FailureStage + '_' + `
                [string]$startupImageResult.FailureType)
        }
        $alternateTheme = Get-QiehaoBackgroundTheme -Id '03-ice-glass'
        $alternateImageResult = Set-QiehaoTheme -Theme $alternateTheme
        if (-not $alternateImageResult.Loaded -or
            $alternateImageResult.ThemeId -cne '03-ice-glass') {
            throw 'GUI_SELFTEST_THEME_SWITCH_FAILED'
        }
        Write-Output 'GUI_SELFTEST_READY'
        return
    }

    $refreshButton.Add_Click({ Invoke-QiehaoReadOnlyRefresh })
    $window.Add_Loaded({ Invoke-QiehaoReadOnlyRefresh })
    [void]$window.ShowDialog()
}
finally {
    if ($null -ne $window -and $SelfTest) {
        $window.Close()
    }
    if ($null -ne $lease) {
        Exit-QiehaoGuiSingleInstance -Lease $lease
    }
}
