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
                'Codex Account Switcher is already running.',
                'Codex Account Switcher',
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

    function Set-QiehaoSnapshot {
        param(
            [Parameter(Mandatory = $true)]
            [object]$Snapshot
        )

        $rows = @($Snapshot.Profiles)
        $profilesGrid.ItemsSource = $rows
        $profileCountText.Text = if ($rows.Count -eq 1) {
            '1 profile'
        }
        else {
            [string]$rows.Count + ' profiles'
        }
        $codexStatusText.Text = [string]$Snapshot.CodexDesktop
        $activeProfileText.Text = [string]$Snapshot.ActiveProfile
        $identityStatusText.Text = [string]$Snapshot.IdentityStatus
        $webChatGPTText.Text = [string]$Snapshot.WebChatGPT

        switch ([string]$Snapshot.CodexDesktop) {
            'Running' { $codexStatusText.Foreground = '#FFB42318' }
            'Stopped' { $codexStatusText.Foreground = '#FF167A45' }
            default { $codexStatusText.Foreground = '#FF5B6472' }
        }

        $refreshStatusText.Text = if (@($Snapshot.ReadOnlyErrors).Count -eq 0) {
            'Read-only status refreshed'
        }
        else {
            'Some read-only status is unavailable'
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
            $refreshStatusText.Text = 'Read-only refresh failed'
            $codexStatusText.Text = 'Unknown'
            $identityStatusText.Text = 'Unknown'
        }
        finally {
            $refreshButton.IsEnabled = $true
        }
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
            -ProcessProvider {
                [pscustomobject]@{ ReasonCode = 'CODEX_PROCESSES_STOPPED' }
            }
        Set-QiehaoSnapshot -Snapshot $snapshot
        if (@($profilesGrid.ItemsSource).Count -ne 2 -or
            $codexStatusText.Text -cne 'Stopped' -or
            $activeProfileText.Text -cne 'Plus') {
            throw 'GUI_SELFTEST_BINDING_FAILED'
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
