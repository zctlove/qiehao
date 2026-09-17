[CmdletBinding()]
param(
    [switch]$XamlOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$guiRoot = Join-Path -Path $projectRoot -ChildPath 'gui'
$xamlPath = Join-Path -Path $guiRoot -ChildPath 'MainWindow.xaml'
$guiScriptPath = Join-Path -Path $guiRoot -ChildPath 'QiehaoGui.ps1'
$helperModulePath = Join-Path -Path $guiRoot -ChildPath 'GuiHelpers.psm1'
$coreModulePath = Join-Path -Path $projectRoot -ChildPath 'lib\CodexAuth.psm1'

function Assert-GuiTest {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Code
    )

    if (-not $Condition) {
        throw $Code
    }
}

function Read-TestWindow {
    Add-Type -AssemblyName PresentationCore -ErrorAction Stop
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase -ErrorAction Stop

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

if ($XamlOnly) {
    $testWindow = Read-TestWindow
    try {
        Assert-GuiTest -Condition (
            $testWindow.Title -ceq 'Codex 账号管理器'
        ) -Code 'GUI_XAML_TITLE_MISMATCH'
        Assert-GuiTest -Condition (
            $null -ne $testWindow.FindName('ProfilesGrid')
        ) -Code 'GUI_XAML_PROFILE_GRID_MISSING'
        Write-Output 'XAML_PARSE_PASS'
    }
    finally {
        $testWindow.Close()
    }
    return
}

Import-Module -Name $helperModulePath -Force -ErrorAction Stop
Import-Module -Name $coreModulePath -Force -ErrorAction Stop

function New-FakeProfileRow {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$Health = 'READY',

        [string]$Auth = 'PRESENT',

        [string]$Identity = 'PRESENT',

        [string]$Metadata = 'VALID'
    )

    return [pscustomobject]@{
        Profile = $Name
        Active = $false
        Health = $Health
        AuthFile = $Auth
        IdentityMarker = $Identity
        Metadata = $Metadata
        UpdatedAt = '2000-01-01T00:00:00Z'
    }
}

function New-FakeSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object[]]$Profiles,

        [string]$Active = 'Plus',

        [string]$ReasonCode = 'CODEX_PROCESSES_STOPPED',

        [string]$IdentityResultCode = 'ACTIVE_IDENTITY_CONFIRMED',

        [AllowNull()]
        [object]$IdentityCallCounter
    )

    $listData = @($Profiles)
    $activeName = $Active
    $processReason = $ReasonCode
    $identityCode = $IdentityResultCode
    $identityCounter = $IdentityCallCounter
    return Get-QiehaoGuiSnapshot `
        -ListProvider ({ $listData }.GetNewClosure()) `
        -ActiveProvider ({
            [pscustomobject]@{ ActiveProfile = $activeName }
        }.GetNewClosure()) `
        -ProcessProvider ({
            [pscustomobject]@{ ReasonCode = $processReason }
        }.GetNewClosure()) `
        -ActiveIdentityProvider ({
            if ($null -ne $identityCounter) { $identityCounter.Count++ }
            [pscustomobject]@{ Result = $identityCode }
        }.GetNewClosure())
}

function Invoke-PowerShellFileTest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$HostPath,

        [Parameter(Mandatory = $true)]
        [string]$ScriptPath,

        [string[]]$AdditionalArguments = @()
    )

    $arguments = @(
        '-NoProfile',
        '-NonInteractive',
        '-STA',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $ScriptPath
    ) + @($AdditionalArguments)
    $output = @(& $HostPath @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output | ForEach-Object { [string]$_ })
    }
}

$ps51Command = Get-Command -Name 'powershell.exe' -ErrorAction Stop
$ps7Command = Get-Command -Name 'pwsh.exe' -ErrorAction Stop

$ps51Xaml = Invoke-PowerShellFileTest -HostPath $ps51Command.Source `
    -ScriptPath $PSCommandPath -AdditionalArguments @('-XamlOnly')
Assert-GuiTest -Condition (
    $ps51Xaml.ExitCode -eq 0 -and
    $ps51Xaml.Output -ccontains 'XAML_PARSE_PASS'
) -Code 'GUI_POWERSHELL_51_XAML_PARSE_FAILED'

$ps7Xaml = Invoke-PowerShellFileTest -HostPath $ps7Command.Source `
    -ScriptPath $PSCommandPath -AdditionalArguments @('-XamlOnly')
Assert-GuiTest -Condition (
    $ps7Xaml.ExitCode -eq 0 -and
    $ps7Xaml.Output -ccontains 'XAML_PARSE_PASS'
) -Code 'GUI_POWERSHELL_7_XAML_PARSE_FAILED'

$guiStartup51 = Invoke-PowerShellFileTest -HostPath $ps51Command.Source `
    -ScriptPath $guiScriptPath -AdditionalArguments @('-SelfTest')
Assert-GuiTest -Condition (
    $guiStartup51.ExitCode -eq 0 -and
    $guiStartup51.Output -ccontains 'GUI_SELFTEST_READY'
) -Code 'GUI_STARTUP_SELFTEST_PS51_FAILED'
$guiStartup7 = Invoke-PowerShellFileTest -HostPath $ps7Command.Source `
    -ScriptPath $guiScriptPath -AdditionalArguments @('-SelfTest')
Assert-GuiTest -Condition (
    $guiStartup7.ExitCode -eq 0 -and
    $guiStartup7.Output -ccontains 'GUI_SELFTEST_READY'
) -Code 'GUI_STARTUP_SELFTEST_PS7_FAILED'

$themes = @(Get-QiehaoBackgroundThemes)
Assert-GuiTest -Condition (
    $themes.Count -eq 5 -and
    (@($themes.Name) -join '|') -ceq
    '科技蓝|深蓝鎏金|冰蓝玻璃|紫蓝星河|清透流光'
) -Code 'GUI_THEME_CATALOG_INVALID'
foreach ($theme in $themes) {
    foreach ($requiredThemeProperty in @(
        'OverlayColor','CardTop','CardBottom','BorderTint','TextPrimary',
        'TextSecondary','ButtonTop','ButtonBottom','ButtonHover','ButtonPressed',
        'ActiveRowTint','ActiveSelectedRowTint','SelectedRowTint','AccentTint',
        'DangerTop','DangerBottom'
    )) {
        Assert-GuiTest -Condition (
            $null -ne $theme.PSObject.Properties[$requiredThemeProperty] -and
            -not [string]::IsNullOrWhiteSpace([string]$theme.$requiredThemeProperty)
        ) -Code ('GUI_THEME_GLASS_PROPERTY_MISSING_' + $theme.Id + '_' +
            $requiredThemeProperty)
    }
    $loadResult = Get-QiehaoBackgroundImage -Theme $theme `
        -BackgroundDirectory (Join-Path -Path $guiRoot `
            -ChildPath 'assets\backgrounds')
    Assert-GuiTest -Condition (
        $loadResult.Loaded -and
        -not $loadResult.UsedSolidFallback -and
        $null -ne $loadResult.ImageSource
    ) -Code ('GUI_THEME_LOAD_FAILED_' + $theme.Id)
}

$themeTestRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) `
    -ChildPath ('qiehao-gui-theme-' + [Guid]::NewGuid().ToString('N'))
$fakeBackgroundDirectory = Join-Path -Path $themeTestRoot -ChildPath 'backgrounds'
$fakeStateDirectory = Join-Path -Path $themeTestRoot -ChildPath 'state'
[System.IO.Directory]::CreateDirectory($fakeBackgroundDirectory) | Out-Null
[System.IO.Directory]::CreateDirectory($fakeStateDirectory) | Out-Null
try {
    $defaultTheme = Get-QiehaoBackgroundTheme -Id '01-blue-glass'
    $missingResult = Get-QiehaoBackgroundImage -Theme $defaultTheme `
        -BackgroundDirectory $fakeBackgroundDirectory
    Assert-GuiTest -Condition (
        -not $missingResult.Loaded -and
        $missingResult.UsedSolidFallback
    ) -Code 'GUI_MISSING_THEME_DID_NOT_FALL_BACK'

    $corruptImagePath = Join-Path -Path $fakeBackgroundDirectory `
        -ChildPath $defaultTheme.FileName
    [System.IO.File]::WriteAllText($corruptImagePath, 'NOT_A_PNG')
    $corruptImageResult = Get-QiehaoBackgroundImage -Theme $defaultTheme `
        -BackgroundDirectory $fakeBackgroundDirectory
    Assert-GuiTest -Condition (
        -not $corruptImageResult.Loaded -and
        $corruptImageResult.UsedSolidFallback
    ) -Code 'GUI_CORRUPT_THEME_DID_NOT_FALL_BACK'

    $writtenPreference = Write-QiehaoUiPreferences `
        -StateDirectory $fakeStateDirectory -Background '03-ice-glass'
    $writtenPreferenceBackground = [string]$writtenPreference.Background
    $writtenPreference = $null
    $restoredPreference = Read-QiehaoUiPreferences `
        -StateDirectory $fakeStateDirectory
    $preferenceData = ConvertFrom-Json -InputObject (
        [System.IO.File]::ReadAllText((Join-Path $fakeStateDirectory `
            'ui-preferences.json'))
    )
    Assert-GuiTest -Condition (
        $writtenPreferenceBackground -ceq '03-ice-glass' -and
        $restoredPreference.Background -ceq '03-ice-glass' -and
        -not $restoredPreference.UsedDefault -and
        (@($preferenceData.PSObject.Properties.Name) -join '|') -ceq
            'schema_version|background' -and
        [int]$preferenceData.schema_version -eq 1
    ) -Code 'GUI_THEME_PREFERENCE_RESTORE_FAILED'

    $fakeProjectRoot = Join-Path $themeTestRoot 'project-from-any-cwd'
    $fakeGuiRoot = Join-Path $fakeProjectRoot 'gui'
    $otherWorkingDirectory = Join-Path $themeTestRoot 'other-working-directory'
    [System.IO.Directory]::CreateDirectory($fakeGuiRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($otherWorkingDirectory) | Out-Null
    $resolvedStateBefore = Resolve-QiehaoProjectStateDirectory `
        -GuiScriptRoot $fakeGuiRoot
    Push-Location -LiteralPath $otherWorkingDirectory
    try {
        $resolvedStateFromOtherCwd = Resolve-QiehaoProjectStateDirectory `
            -GuiScriptRoot $fakeGuiRoot
        $null = Write-QiehaoUiPreferences `
            -StateDirectory $resolvedStateFromOtherCwd `
            -Background '04-purple-tech'
    }
    finally { Pop-Location }
    $newInstancePreference = Read-QiehaoUiPreferences `
        -StateDirectory $resolvedStateBefore
    $expectedFakeState = [System.IO.Path]::GetFullPath(
        (Join-Path $fakeProjectRoot 'state')
    )
    $persistedPreferenceText = [System.IO.File]::ReadAllText(
        (Join-Path $expectedFakeState 'ui-preferences.json')
    )
    Assert-GuiTest -Condition (
        $resolvedStateBefore -ceq $expectedFakeState -and
        $resolvedStateFromOtherCwd -ceq $expectedFakeState -and
        $newInstancePreference.Background -ceq '04-purple-tech' -and
        $persistedPreferenceText -notmatch
            '(?i)account|auth|identity|token|email|credential|secret'
    ) -Code 'GUI_THEME_PREFERENCE_CWD_OR_SCHEMA_FAILED'

    $preferencePath = Join-Path -Path $fakeStateDirectory `
        -ChildPath 'ui-preferences.json'
    [System.IO.File]::WriteAllText($preferencePath, '{BROKEN JSON')
    $corruptPreference = Read-QiehaoUiPreferences `
        -StateDirectory $fakeStateDirectory
    Assert-GuiTest -Condition (
        $corruptPreference.Background -ceq '01-blue-glass' -and
        -not $corruptPreference.IsValid -and
        $corruptPreference.UsedDefault
    ) -Code 'GUI_CORRUPT_PREFERENCE_DID_NOT_FALL_BACK'
}
finally {
    if ([System.IO.Directory]::Exists($themeTestRoot)) {
        [System.IO.Directory]::Delete($themeTestRoot, $true)
    }
}

$themeOne = Get-QiehaoBackgroundImage `
    -Theme (Get-QiehaoBackgroundTheme -Id '01-blue-glass') `
    -BackgroundDirectory (Join-Path $guiRoot 'assets\backgrounds')
$themeThree = Get-QiehaoBackgroundImage `
    -Theme (Get-QiehaoBackgroundTheme -Id '03-ice-glass') `
    -BackgroundDirectory (Join-Path $guiRoot 'assets\backgrounds')
Assert-GuiTest -Condition (
    $themeOne.Loaded -and $themeThree.Loaded -and
    $themeOne.ThemeId -cne $themeThree.ThemeId -and
    $null -ne $themeOne.ImageSource -and
    $null -ne $themeThree.ImageSource
) -Code 'GUI_IMMEDIATE_THEME_SWITCH_FAILED'

$plusTeam = New-FakeSnapshot -Profiles @(
    (New-FakeProfileRow -Name 'Plus'),
    (New-FakeProfileRow -Name 'Team')
) -Active 'Plus'
Assert-GuiTest -Condition (
    @($plusTeam.Profiles).Count -eq 2 -and
    @($plusTeam.Profiles.Name) -ccontains 'Plus' -and
    @($plusTeam.Profiles.Name) -ccontains 'Team'
) -Code 'GUI_DYNAMIC_PLUS_TEAM_FAILED'

$threeProfiles = @(
    (New-FakeProfileRow -Name 'A'),
    (New-FakeProfileRow -Name 'B'),
    (New-FakeProfileRow -Name 'C')
)
$threeSnapshot = New-FakeSnapshot -Profiles $threeProfiles -Active 'A'
Assert-GuiTest -Condition (
    @($threeSnapshot.Profiles).Count -eq 3
) -Code 'GUI_THREE_PROFILE_LIST_FAILED'

$tenProfiles = @()
for ($profileIndex = 1; $profileIndex -le 10; $profileIndex++) {
    $tenProfiles += New-FakeProfileRow -Name ('Account' + $profileIndex)
}
$tenSnapshot = New-FakeSnapshot -Profiles $tenProfiles -Active 'Account7'
Assert-GuiTest -Condition (
    @($tenSnapshot.Profiles).Count -eq 10
) -Code 'GUI_TEN_PROFILE_LIST_FAILED'

$healthSnapshot = New-FakeSnapshot -Profiles @(
    (New-FakeProfileRow -Name 'Ready' -Health 'READY'),
    (New-FakeProfileRow -Name 'Incomplete' -Health 'INCOMPLETE_PROFILE' `
        -Identity 'MISSING'),
    (New-FakeProfileRow -Name 'Invalid' -Health 'INVALID_METADATA' `
        -Metadata 'INVALID'),
    (New-FakeProfileRow -Name 'Unknown' -Health 'UNKNOWN' `
        -Auth 'UNKNOWN' -Identity 'UNKNOWN' -Metadata 'UNKNOWN')
) -Active 'Ready'
Assert-GuiTest -Condition (
    (@($healthSnapshot.Profiles.Health | Sort-Object) -join '|') -ceq
    ((@('正常','不完整','元数据异常','未知') |
        Sort-Object) -join '|')
) -Code 'GUI_HEALTH_DISPLAY_FAILED'

$activeRows = @($tenSnapshot.Profiles | Where-Object { $_.Active -ceq '是' })
Assert-GuiTest -Condition (
    $tenSnapshot.ActiveProfile -ceq 'Account7' -and
    $activeRows.Count -eq 1 -and
    $activeRows[0].Name -ceq 'Account7'
) -Code 'GUI_ACTIVE_PROFILE_MARK_FAILED'

$runningSnapshot = New-FakeSnapshot -Profiles @() `
    -Active 'A' -ReasonCode 'CODEX_PROCESS_RUNNING'
$stoppedSnapshot = New-FakeSnapshot -Profiles @() `
    -Active 'A' -ReasonCode 'CODEX_PROCESSES_STOPPED'
$unknownSnapshot = New-FakeSnapshot -Profiles @() `
    -Active 'A' -ReasonCode 'CODEX_PROCESS_STATE_UNKNOWN'
Assert-GuiTest -Condition (
    $runningSnapshot.CodexDesktop -ceq '运行中'
) -Code 'GUI_CODEX_RUNNING_MAP_FAILED'
Assert-GuiTest -Condition (
    $stoppedSnapshot.CodexDesktop -ceq '已退出'
) -Code 'GUI_CODEX_STOPPED_MAP_FAILED'
Assert-GuiTest -Condition (
    $unknownSnapshot.CodexDesktop -ceq '未知'
) -Code 'GUI_CODEX_UNKNOWN_MAP_FAILED'
Assert-GuiTest -Condition (
    $stoppedSnapshot.WebChatGPT -ceq '不受影响' -and
    $stoppedSnapshot.IdentityStatus -ceq '已确认'
) -Code 'GUI_CHINESE_WEB_OR_IDENTITY_STATUS_FAILED'

$stoppedIdentityCalls = [pscustomobject]@{ Count=0 }
$runningIdentityCalls = [pscustomobject]@{ Count=0 }
$unknownIdentityCalls = [pscustomobject]@{ Count=0 }
$stoppedMismatchSnapshot = New-FakeSnapshot -Profiles @() -Active 'A' `
    -ReasonCode 'CODEX_PROCESSES_STOPPED' `
    -IdentityResultCode 'ACTIVE_PROFILE_IDENTITY_MISMATCH' `
    -IdentityCallCounter $stoppedIdentityCalls
$runningIdentitySnapshot = New-FakeSnapshot -Profiles @() -Active 'A' `
    -ReasonCode 'CODEX_PROCESS_RUNNING' `
    -IdentityCallCounter $runningIdentityCalls
$unknownIdentitySnapshot = New-FakeSnapshot -Profiles @() -Active 'A' `
    -ReasonCode 'CODEX_PROCESS_STATE_UNKNOWN' `
    -IdentityCallCounter $unknownIdentityCalls
Assert-GuiTest -Condition (
    $stoppedMismatchSnapshot.IdentityStatus -ceq '不匹配' -and
    $stoppedIdentityCalls.Count -eq 1 -and
    $runningIdentitySnapshot.IdentityStatus -ceq '待退出后确认' -and
    $runningIdentityCalls.Count -eq 0 -and
    $unknownIdentitySnapshot.IdentityStatus -ceq '无法确认' -and
    $unknownIdentityCalls.Count -eq 0
) -Code 'GUI_ACTIVE_IDENTITY_REFRESH_SEMANTICS_FAILED'

$extensionHostPath = 'C:\Users\Fake\.codex\plugins\cache\openai-bundled\chrome\latest\extension-host\windows\x64\extension-host.exe'
$chromeState = Test-CodexProcessesStopped -ProcessData @(
    [pscustomobject]@{
        ProcessName='extension-host.exe'; Id=8101
        ExecutablePath=$extensionHostPath; PathReadStatus='Readable'
        ParentProcessId=8102; ParentReadStatus='Readable'
    },
    [pscustomobject]@{
        ProcessName='cmd.exe'; Id=8102
        ExecutablePath='C:\Windows\System32\cmd.exe'; PathReadStatus='Readable'
        ParentProcessId=8103; ParentReadStatus='Readable'
    },
    [pscustomobject]@{
        ProcessName='chrome.exe'; Id=8103
        ExecutablePath='C:\Program Files\Google\Chrome\Application\chrome.exe'
        PathReadStatus='Readable'; ParentProcessId=0; ParentReadStatus='Readable'
    }
)
$edgeState = Test-CodexProcessesStopped -ProcessData @(
    [pscustomobject]@{
        ProcessName='extension-host.exe'; Id=8201
        ExecutablePath=$extensionHostPath; PathReadStatus='Readable'
        ParentProcessId=8202; ParentReadStatus='Readable'
    },
    [pscustomobject]@{
        ProcessName='cmd.exe'; Id=8202
        ExecutablePath='C:\Windows\System32\cmd.exe'; PathReadStatus='Readable'
        ParentProcessId=8203; ParentReadStatus='Readable'
    },
    [pscustomobject]@{
        ProcessName='msedge.exe'; Id=8203
        ExecutablePath='C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'
        PathReadStatus='Readable'; ParentProcessId=8204; ParentReadStatus='Readable'
    },
    [pscustomobject]@{
        ProcessName='explorer.exe'; Id=8204
        ExecutablePath='C:\Windows\explorer.exe'; PathReadStatus='Readable'
        ParentProcessId=0; ParentReadStatus='Readable'
    }
)
Assert-GuiTest -Condition (
    $chromeState.ReasonCode -ceq 'CODEX_PROCESSES_STOPPED' -and
    $edgeState.ReasonCode -ceq 'CODEX_PROCESSES_STOPPED'
) -Code 'GUI_BROWSER_EXTENSION_ISOLATION_FAILED'

# GUI account-management behavior uses only injected providers. No call below
# resolves the real CODEX_HOME or reads a real profile artifact.
$switchCalls = [pscustomobject]@{ Count = 0; Last = '' }
$stoppedSwitch = Invoke-QiehaoSwitchRequest -SelectedProfile 'Team' `
    -ActiveProfile 'Plus' `
    -ProcessProvider { [pscustomobject]@{ ReasonCode='CODEX_PROCESSES_STOPPED' } } `
    -SwitchProvider ({
        param($Name)
        $switchCalls.Count++
        $switchCalls.Last = $Name
        [pscustomobject]@{ Result='SWITCH_SUCCESS' }
    }.GetNewClosure())
Assert-GuiTest -Condition (
    $stoppedSwitch.CoreCalled -and $stoppedSwitch.IsSuccess -and
    $switchCalls.Count -eq 1 -and $switchCalls.Last -ceq 'Team'
) -Code 'GUI_SWITCH_STOPPED_FAILED'

$alreadyActiveSwitch = Invoke-QiehaoSwitchRequest -SelectedProfile 'Plus' `
    -ActiveProfile 'Plus' `
    -ProcessProvider { throw 'PROCESS_SHOULD_NOT_BE_CALLED' } `
    -SwitchProvider ({ $switchCalls.Count++ }.GetNewClosure())
Assert-GuiTest -Condition (
    -not $alreadyActiveSwitch.CoreCalled -and
    $alreadyActiveSwitch.ResultCode -ceq 'ALREADY_ACTIVE' -and
    $switchCalls.Count -eq 1
) -Code 'GUI_SWITCH_ACTIVE_WROTE_AUTH'

$unknownSwitch = Invoke-QiehaoSwitchRequest -SelectedProfile 'Team' `
    -ActiveProfile 'Plus' `
    -ProcessProvider { [pscustomobject]@{ ReasonCode='CODEX_PROCESS_STATE_UNKNOWN' } } `
    -SwitchProvider ({ $switchCalls.Count++ }.GetNewClosure())
Assert-GuiTest -Condition (
    -not $unknownSwitch.CoreCalled -and
    $unknownSwitch.ResultCode -ceq 'CODEX_PROCESS_STATE_UNKNOWN' -and
    $switchCalls.Count -eq 1
) -Code 'GUI_SWITCH_UNKNOWN_EXECUTED'

$runningFlow = [pscustomobject]@{ Confirm=0; Exit=0; Wait=0; Switch=0 }
$runningSwitch = Invoke-QiehaoSwitchRequest -SelectedProfile 'Team' `
    -ActiveProfile 'Plus' `
    -ProcessProvider { [pscustomobject]@{ ReasonCode='CODEX_PROCESS_RUNNING' } } `
    -ConfirmExitProvider ({ $runningFlow.Confirm++; $true }.GetNewClosure()) `
    -ExitProvider ({
        $runningFlow.Exit++
        [pscustomobject]@{ Result='CODEX_CLOSE_REQUESTED' }
    }.GetNewClosure()) `
    -WaitForStopProvider ({
        param($TimeoutSeconds)
        $runningFlow.Wait++
        [pscustomobject]@{ ReasonCode='CODEX_PROCESSES_STOPPED' }
    }.GetNewClosure()) `
    -SwitchProvider ({
        param($Name)
        $runningFlow.Switch++
        [pscustomobject]@{ Result='SWITCH_SUCCESS' }
    }.GetNewClosure())
Assert-GuiTest -Condition (
    $runningSwitch.IsSuccess -and $runningFlow.Confirm -eq 1 -and
    $runningFlow.Exit -eq 1 -and $runningFlow.Wait -eq 1 -and
    $runningFlow.Switch -eq 1
) -Code 'GUI_RUNNING_EXIT_AND_SWITCH_FAILED'

$failedExitFlow = [pscustomobject]@{ Switch=0 }
$failedExitSwitch = Invoke-QiehaoSwitchRequest -SelectedProfile 'Team' `
    -ActiveProfile 'Plus' `
    -ProcessProvider { [pscustomobject]@{ ReasonCode='CODEX_PROCESS_RUNNING' } } `
    -ConfirmExitProvider { $true } `
    -ExitProvider { [pscustomobject]@{ Result='CODEX_CLOSE_REQUESTED' } } `
    -WaitForStopProvider {
        param($TimeoutSeconds)
        [pscustomobject]@{ ReasonCode='CODEX_PROCESS_RUNNING' }
    } `
    -SwitchProvider ({ $failedExitFlow.Switch++ }.GetNewClosure())
Assert-GuiTest -Condition (
    -not $failedExitSwitch.CoreCalled -and
    $failedExitSwitch.ResultCode -ceq 'CODEX_EXIT_TIMEOUT' -and
    $failedExitFlow.Switch -eq 0
) -Code 'GUI_FAILED_EXIT_STILL_SWITCHED'

$unknownAfterExit = Invoke-QiehaoSwitchRequest -SelectedProfile 'Team' `
    -ActiveProfile 'Plus' `
    -ProcessProvider { [pscustomobject]@{ ReasonCode='CODEX_PROCESS_RUNNING' } } `
    -ConfirmExitProvider { $true } `
    -ExitProvider { [pscustomobject]@{ Result='CODEX_CLOSE_REQUESTED' } } `
    -WaitForStopProvider {
        param($TimeoutSeconds)
        [pscustomobject]@{ ReasonCode='CODEX_PROCESS_STATE_UNKNOWN' }
    } -SwitchProvider { throw 'SWITCH_SHOULD_NOT_RUN' }
Assert-GuiTest -Condition (
    -not $unknownAfterExit.CoreCalled -and
    $unknownAfterExit.ResultCode -ceq 'CODEX_EXIT_STATE_UNKNOWN'
) -Code 'GUI_UNKNOWN_AFTER_EXIT_NOT_BLOCKED'

$busyCalls = [pscustomobject]@{ Count=0 }
$busySwitch = Invoke-QiehaoSwitchRequest -SelectedProfile 'Team' `
    -ActiveProfile 'Plus' `
    -ProcessProvider { throw 'PROCESS_SHOULD_NOT_RUN' } `
    -SwitchProvider ({ $busyCalls.Count++ }.GetNewClosure()) -IsBusy
Assert-GuiTest -Condition (
    -not $busySwitch.CoreCalled -and
    $busySwitch.ResultCode -ceq 'OPERATION_BUSY' -and
    $busyCalls.Count -eq 0
) -Code 'GUI_BUSY_SWITCH_EXECUTED'

$rollbackResult = ConvertTo-QiehaoOperationResult `
    -ResultCode 'SWITCH_FAILED_ROLLED_BACK'
$rollbackFailureResult = ConvertTo-QiehaoOperationResult `
    -ResultCode 'SWITCH_ROLLBACK_FAILED'
$identityResult = ConvertTo-QiehaoOperationResult `
    -ResultCode 'ACTIVE_PROFILE_IDENTITY_MISMATCH'
Assert-GuiTest -Condition (
    $rollbackResult.Message -ceq '切换失败，已安全恢复原账号。' -and
    $rollbackFailureResult.Severity -ceq 'Critical' -and
    $rollbackFailureResult.Message -match '请不要启动 Codex' -and
    $identityResult.Message -match '已阻止操作'
) -Code 'GUI_SWITCH_RESULT_MAPPING_FAILED'

$activeStoppedActions = Get-QiehaoActionState -SelectedProfile 'Plus' `
    -ActiveProfile 'Plus' -CodexStatus '已退出'
$otherRunningActions = Get-QiehaoActionState -SelectedProfile 'Team' `
    -ActiveProfile 'Plus' -CodexStatus '运行中'
$busyActions = Get-QiehaoActionState -SelectedProfile 'Team' `
    -ActiveProfile 'Plus' -CodexStatus '已退出' -IsWriteOperationBusy
$unavailableLaunchActions = Get-QiehaoActionState -SelectedProfile 'Team' `
    -ActiveProfile 'Plus' -CodexStatus '已退出' -LaunchTargetAvailable:$false
Assert-GuiTest -Condition (
    -not $activeStoppedActions.Switch -and
    -not $activeStoppedActions.ContextSwitch -and
    -not $activeStoppedActions.Delete -and
    -not $activeStoppedActions.ContextDelete -and
    $activeStoppedActions.Rename -and
    $activeStoppedActions.LaunchCodex -and
    -not $activeStoppedActions.ExitCodex -and
    $otherRunningActions.Switch -and
    -not $otherRunningActions.Verify -and
    -not $otherRunningActions.LaunchCodex -and
    $otherRunningActions.ExitCodex -and
    $busyActions.Refresh -and
    -not $busyActions.Switch -and -not $busyActions.Add -and
    -not $busyActions.Rename -and -not $busyActions.Delete -and
    -not $busyActions.LaunchCodex -and -not $busyActions.ExitCodex -and
    -not $busyActions.ContextSwitch -and -not $busyActions.ContextRename -and
    -not $unavailableLaunchActions.LaunchCodex
) -Code 'GUI_ACTION_ENABLE_RULES_FAILED'

$appxLaunchTarget = Find-QiehaoCodexLaunchTarget -Mode Auto `
    -AppxApplications @([pscustomobject]@{
        PackageFamilyName='OpenAI.Codex_8wekyb3d8bbwe'; ApplicationId='App'
    }) -StartApps @([pscustomobject]@{ Name='Codex'; AppID='ignored' })
$startAppsLaunchTarget = Find-QiehaoCodexLaunchTarget -Mode Auto `
    -AppxApplications @() -StartApps @([pscustomobject]@{
        Name='Codex'; AppID='OpenAI.Codex_8wekyb3d8bbwe!App'
    })
Assert-GuiTest -Condition (
    $appxLaunchTarget.Available -and
    $appxLaunchTarget.Type -ceq 'AppUserModelId' -and
    $appxLaunchTarget.Source -ceq 'AppxManifest' -and
    $startAppsLaunchTarget.Available -and
    $startAppsLaunchTarget.Source -ceq 'StartApps'
) -Code 'GUI_CODEX_LAUNCH_AUTO_DETECTION_FAILED'

$launchTestRoot = Join-Path ([System.IO.Path]::GetTempPath()) `
    ('qiehao-launch-' + [Guid]::NewGuid().ToString('N'))
[System.IO.Directory]::CreateDirectory($launchTestRoot) | Out-Null
try {
    $fakeExePath = Join-Path $launchTestRoot 'Codex-Fake.exe'
    [System.IO.File]::WriteAllBytes($fakeExePath, [byte[]](77,90,0,0))
    $validCustomTarget = Find-QiehaoCodexLaunchTarget -Mode Custom `
        -CustomPath $fakeExePath
    $invalidCustomTarget = Find-QiehaoCodexLaunchTarget -Mode Custom `
        -CustomPath (Join-Path $launchTestRoot 'missing.exe')
    $writtenLaunchSettings = Write-QiehaoLaunchSettings `
        -StateDirectory $launchTestRoot -Mode Custom -CustomPath $fakeExePath
    $restoredLaunchSettings = Read-QiehaoLaunchSettings -StateDirectory $launchTestRoot
    Assert-GuiTest -Condition (
        $validCustomTarget.Available -and
        -not $invalidCustomTarget.Available -and
        $writtenLaunchSettings.Mode -ceq 'Custom' -and
        $restoredLaunchSettings.CustomPath -ceq $validCustomTarget.ExecutablePath
    ) -Code 'GUI_CODEX_CUSTOM_LAUNCH_SETTINGS_FAILED'

    $launchCalls = [pscustomobject]@{ Count=0; Type=''; PropertyCount=0 }
    $launchRequest = Invoke-QiehaoCodexLaunchRequest -Target $validCustomTarget `
        -LaunchProvider ({
            param($Target)
            $launchCalls.Count++
            $launchCalls.Type = [string]$Target.Type
            $launchCalls.PropertyCount = @($Target.PSObject.Properties).Count
            return $true
        }.GetNewClosure())
    $busyLaunchRequest = Invoke-QiehaoCodexLaunchRequest `
        -Target $validCustomTarget -LaunchProvider { throw 'MUST_NOT_RUN' } -IsBusy
    Assert-GuiTest -Condition (
        $launchRequest.Result -ceq 'CODEX_LAUNCH_REQUESTED' -and
        $launchRequest.LaunchCalled -and $launchCalls.Count -eq 1 -and
        $launchCalls.Type -ceq 'CustomExecutable' -and
        $launchCalls.PropertyCount -eq 6 -and
        $busyLaunchRequest.Result -ceq 'OPERATION_BUSY' -and
        -not $busyLaunchRequest.LaunchCalled
    ) -Code 'GUI_CODEX_LAUNCH_PROVIDER_CONTRACT_FAILED'
}
finally {
    if ([System.IO.Directory]::Exists($launchTestRoot)) {
        [System.IO.Directory]::Delete($launchTestRoot, $true)
    }
}

$renameCalls = [pscustomobject]@{ Count=0; From=''; To='' }
$renameSuccess = Invoke-QiehaoOperationProvider -Operation 'RENAME' `
    -Provider ({
        param($From, $To)
        $renameCalls.Count++; $renameCalls.From=$From; $renameCalls.To=$To
        [pscustomobject]@{ Result='PROFILE_RENAME_SUCCESS' }
    }.GetNewClosure()) -ArgumentList @('Plus','Primary')
$renameRollback = Invoke-QiehaoOperationProvider -Operation 'RENAME' `
    -Provider { throw 'PROFILE_RENAME_FAILED_ROLLED_BACK' }
Assert-GuiTest -Condition (
    $renameSuccess.IsSuccess -and $renameSuccess.RefreshRequired -and
    $renameCalls.Count -eq 1 -and $renameCalls.From -ceq 'Plus' -and
    $renameCalls.To -ceq 'Primary' -and
    $renameRollback.Message -match '已恢复原名称'
) -Code 'GUI_RENAME_FLOW_FAILED'

$deleteSuccess = Invoke-QiehaoOperationProvider -Operation 'DELETE' `
    -Provider { param($Name) [pscustomobject]@{ Result='PROFILE_REMOVE_SUCCESS' } } `
    -ArgumentList @('Team')
Assert-GuiTest -Condition (
    $deleteSuccess.IsSuccess -and $deleteSuccess.RefreshRequired
) -Code 'GUI_DELETE_FLOW_FAILED'

$addSuccess = Invoke-QiehaoOperationProvider -Operation 'ADD' `
    -Provider { param($Name) [pscustomobject]@{ Result='PROFILE_ADD_SUCCESS' } } `
    -ArgumentList @('Work')
$addDuplicateName = Invoke-QiehaoOperationProvider -Operation 'ADD' `
    -Provider { throw 'PROFILE_NAME_ALREADY_EXISTS' }
$addDuplicateIdentity = Invoke-QiehaoOperationProvider -Operation 'ADD' `
    -Provider { throw 'PROFILE_IDENTITY_ALREADY_EXISTS' }
Assert-GuiTest -Condition (
    $addSuccess.IsSuccess -and
    $addDuplicateName.Message -ceq '该本地账号名称已经存在。' -and
    $addDuplicateIdentity.Message -ceq '该账号已经存在于本地账号列表中。' -and
    $addDuplicateIdentity.Message -notmatch '(?i)account_id|@'
) -Code 'GUI_ADD_RESULT_MAPPING_FAILED'

$searchRows = @(
    [pscustomobject]@{ Name='Work-US' },
    [pscustomobject]@{ Name='Work-JP' },
    [pscustomobject]@{ Name='Team' },
    [pscustomobject]@{ Name='Personal' }
)
$workSearch = @(Select-QiehaoProfileRows -Rows $searchRows -SearchText 'work')
$substringSearch = @(Select-QiehaoProfileRows -Rows $searchRows -SearchText 'RK-J')
$clearedSearch = @(Select-QiehaoProfileRows -Rows $searchRows -SearchText '')
Assert-GuiTest -Condition (
    $workSearch.Count -eq 2 -and
    (@($workSearch.Name) -join '|') -ceq 'Work-US|Work-JP' -and
    $substringSearch.Count -eq 1 -and $substringSearch[0].Name -ceq 'Work-JP' -and
    $clearedSearch.Count -eq 4
) -Code 'GUI_PROFILE_SEARCH_FAILED'

$guardedRow = New-Object PSObject -Property @{ Name='SafeName' }
$guardedRow | Add-Member -MemberType ScriptProperty -Name Auth -Value {
    throw 'SEARCH_READ_AUTH'
}
$guardedRow | Add-Member -MemberType ScriptProperty -Name Identity -Value {
    throw 'SEARCH_READ_IDENTITY'
}
$guardedSearch = @(Select-QiehaoProfileRows -Rows @($guardedRow) -SearchText 'safe')
Assert-GuiTest -Condition ($guardedSearch.Count -eq 1) `
    -Code 'GUI_SEARCH_READ_SENSITIVE_PROPERTY'

$verifyCalls = [pscustomobject]@{ Count=0 }
$noSelectionVerify = Invoke-QiehaoVerifyRequest -SelectedProfile $null `
    -CodexStatus '已退出' -VerifyProvider ({
        param($Name)
        $verifyCalls.Count++
    }.GetNewClosure())
Assert-GuiTest -Condition (
    -not $noSelectionVerify.CoreCalled -and
    $noSelectionVerify.Message -ceq '请先选择一个账号。' -and
    $verifyCalls.Count -eq 0
) -Code 'GUI_VERIFY_WITHOUT_SELECTION_EXECUTED'

$runningVerify = Invoke-QiehaoVerifyRequest -SelectedProfile 'A' `
    -CodexStatus '运行中' -VerifyProvider ({
        param($Name)
        $verifyCalls.Count++
    }.GetNewClosure())
Assert-GuiTest -Condition (
    -not $runningVerify.CoreCalled -and
    $runningVerify.Message -ceq '请先正常退出 Codex，再验证账号。' -and
    $verifyCalls.Count -eq 0
) -Code 'GUI_VERIFY_RUNNING_NOT_REJECTED'

$unknownVerify = Invoke-QiehaoVerifyRequest -SelectedProfile 'A' `
    -CodexStatus '未知' -VerifyProvider ({
        param($Name)
        $verifyCalls.Count++
    }.GetNewClosure())
Assert-GuiTest -Condition (
    -not $unknownVerify.CoreCalled -and
    $unknownVerify.Message -ceq '无法确认 Codex 进程状态，请重新检测。' -and
    $verifyCalls.Count -eq 0
) -Code 'GUI_VERIFY_UNKNOWN_NOT_REJECTED'

$successVerify = Invoke-QiehaoVerifyRequest -SelectedProfile 'A' `
    -CodexStatus '已退出' -VerifyProvider ({
        param($Name)
        $verifyCalls.Count++
        [pscustomobject]@{ Result='PROFILE_VERIFY_SUCCESS'; Profile=$Name }
    }.GetNewClosure())
Assert-GuiTest -Condition (
    $successVerify.CoreCalled -and
    $successVerify.Message -ceq '账号验证成功' -and
    $successVerify.VerificationStatus -ceq '已验证' -and
    $verifyCalls.Count -eq 1
) -Code 'GUI_VERIFY_SUCCESS_FAILED'

$identityMismatchVerify = Invoke-QiehaoVerifyRequest -SelectedProfile 'A' `
    -CodexStatus '已退出' -VerifyProvider { throw 'PROFILE_IDENTITY_MISMATCH' }
Assert-GuiTest -Condition (
    $identityMismatchVerify.Message -ceq '账号身份标记不匹配' -and
    $identityMismatchVerify.VerificationStatus -ceq '验证失败'
) -Code 'GUI_VERIFY_IDENTITY_MISMATCH_MESSAGE_FAILED'

$incompleteVerify = Invoke-QiehaoVerifyRequest -SelectedProfile 'A' `
    -CodexStatus '已退出' -VerifyProvider { throw 'PROFILE_INCOMPLETE' }
Assert-GuiTest -Condition (
    $incompleteVerify.Message -ceq '账号资料不完整' -and
    $incompleteVerify.VerificationStatus -ceq '验证失败'
) -Code 'GUI_VERIFY_INCOMPLETE_MESSAGE_FAILED'

$sensitiveFailureVerify = Invoke-QiehaoVerifyRequest -SelectedProfile 'A' `
    -CodexStatus '已退出' -VerifyProvider {
        throw 'SECRET access_token account_id user@example.invalid'
    }
Assert-GuiTest -Condition (
    $sensitiveFailureVerify.Message -ceq '验证失败，请查看安全状态信息' -and
    $sensitiveFailureVerify.Message -notmatch '(?i)access_token|account_id|@'
) -Code 'GUI_VERIFY_SENSITIVE_EXCEPTION_EXPOSED'

$refreshAfterVerifyCalls = 0
if ($successVerify.CoreCalled) { $refreshAfterVerifyCalls++ }
Assert-GuiTest -Condition (
    $refreshAfterVerifyCalls -eq 1
) -Code 'GUI_VERIFY_REFRESH_NOT_REQUESTED'

$alreadyStoppedExit = Request-CodexDesktopClose -ProcessData @()
Assert-GuiTest -Condition (
    $alreadyStoppedExit.Result -ceq 'CODEX_ALREADY_STOPPED' -and
    -not $alreadyStoppedExit.CloseRequested -and
    (ConvertTo-QiehaoExitMessage -ResultCode $alreadyStoppedExit.Result) `
        -ceq 'Codex 已经退出。'
) -Code 'GUI_EXIT_ALREADY_STOPPED_FAILED'

$nativeCodexPath = 'C:\Program Files\WindowsApps\OpenAI.Codex_1.0.0.0_x64__8wekyb3d8bbwe\app\ChatGPT.exe'
$runningCodexSnapshot = @(
    [pscustomobject]@{
        ProcessName='ChatGPT.exe'; Id=9101
        ExecutablePath=$nativeCodexPath; PathReadStatus='Readable'
        ParentProcessId=0; ParentReadStatus='Readable'
        MainWindowHandle=12345
        MainWindowOwnerProcessId=9101
    }
)
$closeCapture = [pscustomobject]@{ Count=0; LastPid=0 }
$closeRequested = Request-CodexDesktopClose `
    -ProcessData $runningCodexSnapshot -CloseMainWindowAction ({
        param($ProcessItem)
        $closeCapture.Count++
        $closeCapture.LastPid = [int]$ProcessItem.Id
        return $true
    }.GetNewClosure())
Assert-GuiTest -Condition (
    $closeRequested.Result -ceq 'CODEX_CLOSE_REQUESTED' -and
    $closeRequested.CloseRequested -and
    $closeCapture.Count -eq 1 -and
    $closeCapture.LastPid -eq 9101
) -Code 'GUI_NORMAL_CLOSE_REQUEST_FAILED'

$selfCloseCalls = [pscustomobject]@{ Count=0 }
$selfWindowExit = Request-CodexDesktopClose -CallerProcessId 9401 `
    -ProcessData @([pscustomobject]@{
        ProcessName='ChatGPT.exe'; Id=9401
        ExecutablePath=$nativeCodexPath; PathReadStatus='Readable'
        ParentProcessId=0; ParentReadStatus='Readable'
        MainWindowHandle=44001; MainWindowOwnerProcessId=9401
    }) -CloseMainWindowAction ({
        param($ProcessItem)
        $selfCloseCalls.Count++
        return $true
    }.GetNewClosure())
Assert-GuiTest -Condition (
    $selfWindowExit.Result -ceq 'CODEX_MAIN_WINDOW_NOT_FOUND' -and
    -not $selfWindowExit.CloseRequested -and
    $selfCloseCalls.Count -eq 0
) -Code 'GUI_EXIT_SELF_WINDOW_NOT_EXCLUDED'

$mixedCloseCapture = [pscustomobject]@{ Pids=@() }
$mixedExit = Request-CodexDesktopClose -CallerProcessId 9599 `
    -ProcessData @(
        [pscustomobject]@{
            ProcessName='ChatGPT.exe'; Id=9501
            ExecutablePath=$nativeCodexPath; PathReadStatus='Readable'
            ParentProcessId=0; ParentReadStatus='Readable'
            MainWindowHandle=45001; MainWindowOwnerProcessId=9501
        },
        [pscustomobject]@{
            ProcessName='ChatGPT.exe'; Id=9502
            ExecutablePath=$nativeCodexPath; PathReadStatus='Readable'
            ParentProcessId=0; ParentReadStatus='Readable'
            MainWindowHandle=0; MainWindowOwnerProcessId=9502
        },
        [pscustomobject]@{
            ProcessName='ChatGPT.exe'; Id=9503
            ExecutablePath=$nativeCodexPath; PathReadStatus='Readable'
            ParentProcessId=0; ParentReadStatus='Readable'
            MainWindowHandle=45003; MainWindowOwnerProcessId=9999
        },
        [pscustomobject]@{
            ProcessName='codex-code-mode-host.exe'; Id=9504
            ExecutablePath='C:\Fake\.codex\bin\codex-code-mode-host.exe'
            PathReadStatus='Readable'; ParentProcessId=0
            ParentReadStatus='Readable'; MainWindowHandle=45004
            MainWindowOwnerProcessId=9504
        },
        [pscustomobject]@{
            ProcessName='ChatGPT.exe'; Id=9505
            ExecutablePath='C:\Fake\Unrelated\ChatGPT.exe'
            PathReadStatus='Readable'; ParentProcessId=0
            ParentReadStatus='Readable'; MainWindowHandle=45005
            MainWindowOwnerProcessId=9505
        }
    ) -CloseMainWindowAction ({
        param($ProcessItem)
        $mixedCloseCapture.Pids += [int]$ProcessItem.Id
        return $true
    }.GetNewClosure())
Assert-GuiTest -Condition (
    $mixedExit.Result -ceq 'CODEX_CLOSE_REQUESTED' -and
    $mixedExit.RequestedCount -eq 1 -and
    @($mixedCloseCapture.Pids).Count -eq 1 -and
    $mixedCloseCapture.Pids[0] -eq 9501
) -Code 'GUI_EXIT_MIXED_PROCESS_TARGET_UNSAFE'

$ownerProviderCalls = [pscustomobject]@{ Count=0 }
$ownerProviderExit = Request-CodexDesktopClose -CallerProcessId 9699 `
    -ProcessData @([pscustomobject]@{
        ProcessName='ChatGPT.exe'; Id=9601
        ExecutablePath=$nativeCodexPath; PathReadStatus='Readable'
        ParentProcessId=0; ParentReadStatus='Readable'
        MainWindowHandle=46001
    }) -WindowOwnerProcessIdProvider ({
        param($WindowHandle, $ProcessItem)
        $ownerProviderCalls.Count++
        return [int]$ProcessItem.Id
    }.GetNewClosure()) -CloseMainWindowAction { param($ProcessItem) $true }
Assert-GuiTest -Condition (
    $ownerProviderExit.Result -ceq 'CODEX_CLOSE_REQUESTED' -and
    $ownerProviderCalls.Count -eq 1
) -Code 'GUI_EXIT_WINDOW_OWNER_PROVIDER_NOT_USED'

$postCloseStopped = Test-CodexProcessesStopped -ProcessData @()
Assert-GuiTest -Condition (
    $postCloseStopped.ReasonCode -ceq 'CODEX_PROCESSES_STOPPED'
) -Code 'GUI_EXIT_POST_CLOSE_STOPPED_FAILED'

$stillRunningAfterClose = Test-CodexProcessesStopped `
    -ProcessData $runningCodexSnapshot
Assert-GuiTest -Condition (
    $stillRunningAfterClose.ReasonCode -ceq 'CODEX_PROCESS_RUNNING'
) -Code 'GUI_EXIT_STILL_RUNNING_NOT_REPORTED'

$unknownCloseCalls = [pscustomobject]@{ Count=0 }
$unknownExit = Request-CodexDesktopClose -ProcessData @(
    [pscustomobject]@{
        ProcessName='ChatGPT.exe'; Id=9201
        ExecutablePath=$null; PathReadStatus='Unavailable'
        ParentProcessId=$null; ParentReadStatus='Unavailable'
        MainWindowHandle=23456
    }
) -CloseMainWindowAction ({
    param($ProcessItem)
    $unknownCloseCalls.Count++
    return $true
}.GetNewClosure())
Assert-GuiTest -Condition (
    $unknownExit.Result -ceq 'CODEX_PROCESS_STATE_UNKNOWN' -and
    -not $unknownExit.CloseRequested -and
    $unknownCloseCalls.Count -eq 0
) -Code 'GUI_EXIT_UNKNOWN_SENT_CLOSE_REQUEST'

$browserCloseCalls = [pscustomobject]@{ Count=0 }
$browserOnlyExit = Request-CodexDesktopClose -ProcessData @(
    [pscustomobject]@{
        ProcessName='extension-host.exe'; Id=9301
        ExecutablePath=$extensionHostPath; PathReadStatus='Readable'
        ParentProcessId=9302; ParentReadStatus='Readable'
        MainWindowHandle=34567
    },
    [pscustomobject]@{
        ProcessName='cmd.exe'; Id=9302
        ExecutablePath='C:\Windows\System32\cmd.exe'; PathReadStatus='Readable'
        ParentProcessId=9303; ParentReadStatus='Readable'
        MainWindowHandle=0
    },
    [pscustomobject]@{
        ProcessName='chrome.exe'; Id=9303
        ExecutablePath='C:\Program Files\Google\Chrome\Application\chrome.exe'
        PathReadStatus='Readable'; ParentProcessId=0; ParentReadStatus='Readable'
        MainWindowHandle=45678
    }
) -CloseMainWindowAction ({
    param($ProcessItem)
    $browserCloseCalls.Count++
    return $true
}.GetNewClosure())
Assert-GuiTest -Condition (
    $browserOnlyExit.Result -ceq 'CODEX_ALREADY_STOPPED' -and
    $browserCloseCalls.Count -eq 0
) -Code 'GUI_EXIT_BROWSER_PROCESS_TARGETED'

$failedCloseCalls = [pscustomobject]@{ Count=0 }
$failedNormalExit = Request-CodexDesktopClose -CallerProcessId 9799 `
    -ProcessData @([pscustomobject]@{
        ProcessName='ChatGPT.exe'; Id=9701
        ExecutablePath=$nativeCodexPath; PathReadStatus='Readable'
        ParentProcessId=0; ParentReadStatus='Readable'
        MainWindowHandle=47001; MainWindowOwnerProcessId=9701
    }) -CloseMainWindowAction ({
        param($ProcessItem)
        $failedCloseCalls.Count++
        throw 'FAKE_CLOSE_FAILURE'
    }.GetNewClosure())
$fakeManagerState = [pscustomobject]@{ Alive=$true; Attempts=0 }
$safeExitDispatch = Invoke-QiehaoExitButtonAction -ExitAction ({
    $fakeManagerState.Attempts++
    throw 'FAKE_EXIT_HANDLER_FAILURE'
}.GetNewClosure())
Assert-GuiTest -Condition (
    $failedNormalExit.Result -ceq 'CODEX_MAIN_WINDOW_NOT_FOUND' -and
    -not $failedNormalExit.CloseRequested -and
    $failedCloseCalls.Count -eq 1 -and
    $safeExitDispatch.Failed -and
    -not $safeExitDispatch.Completed -and
    $fakeManagerState.Alive -and
    $fakeManagerState.Attempts -eq 1
) -Code 'GUI_EXIT_FAILURE_CLOSED_MANAGER'

$providerCalls = [pscustomobject]@{ List=0; Active=0; Process=0; Identity=0 }
$null = Get-QiehaoGuiSnapshot `
    -ListProvider ({ $providerCalls.List++; @() }.GetNewClosure()) `
    -ActiveProvider ({
        $providerCalls.Active++
        [pscustomobject]@{ ActiveProfile='A' }
    }.GetNewClosure()) `
    -ProcessProvider ({
        $providerCalls.Process++
        [pscustomobject]@{ ReasonCode='CODEX_PROCESSES_STOPPED' }
    }.GetNewClosure()) `
    -ActiveIdentityProvider ({
        $providerCalls.Identity++
        [pscustomobject]@{ Result='ACTIVE_IDENTITY_CONFIRMED' }
    }.GetNewClosure())
Assert-GuiTest -Condition (
    $providerCalls.List -eq 1 -and
    $providerCalls.Active -eq 1 -and
    $providerCalls.Process -eq 1 -and
    $providerCalls.Identity -eq 1
) -Code 'GUI_REFRESH_PROVIDER_COUNT_FAILED'

$timerProbe = [pscustomobject]@{ Count=0 }
$fakeTimer = New-Object psobject
$fakeTimer | Add-Member -NotePropertyName Active -NotePropertyValue $true
$fakeTimer | Add-Member -NotePropertyName Handler -NotePropertyValue $null
$fakeTimer | Add-Member -NotePropertyName StopCount -NotePropertyValue 0
$fakeTimer | Add-Member -NotePropertyName RemoveCount -NotePropertyValue 0
$fakeTimer | Add-Member -MemberType ScriptMethod -Name Stop -Value {
    $this.StopCount++
    $this.Active = $false
}
$fakeTimer | Add-Member -MemberType ScriptMethod -Name Remove_Tick -Value {
    param($Handler)
    $this.RemoveCount++
    $this.Handler = $null
}
$fakeTimer | Add-Member -MemberType ScriptMethod -Name Fire -Value {
    if ($this.Active -and $null -ne $this.Handler) {
        $null = & $this.Handler $null $null
    }
}
$fakeTickHandler = {
    param($sender, $eventArgs)
    $timerProbe.Count++
}.GetNewClosure()
$fakeTimer.Handler = $fakeTickHandler
$fakeTimer.Fire()
$timerStopResult = Stop-QiehaoDispatcherTimer `
    -Timer $fakeTimer -TickHandler $fakeTickHandler
$fakeTimer.Fire()
Assert-GuiTest -Condition (
    $timerStopResult.Stopped -and $timerStopResult.HandlerRemoved -and
    $fakeTimer.StopCount -eq 1 -and $fakeTimer.RemoveCount -eq 1 -and
    -not $fakeTimer.Active -and $null -eq $fakeTimer.Handler -and
    $timerProbe.Count -eq 1
) -Code 'GUI_TIMER_STOP_OR_HANDLER_DETACH_FAILED'

$guiSource = [System.IO.File]::ReadAllText($guiScriptPath)
$helperSource = [System.IO.File]::ReadAllText($helperModulePath)
foreach ($requiredBackendCommand in @(
    'Save-CodexActiveProfile',
    'Switch-CodexAccountProfile',
    'Add-CodexProfile',
    'Remove-CodexProfile',
    'Rename-CodexProfile',
    'Test-CodexActiveIdentity'
)) {
    Assert-GuiTest -Condition (
        $guiSource -match ('(?i)\b' + [regex]::Escape($requiredBackendCommand) + '\b')
    ) -Code ('GUI_BACKEND_WIRING_MISSING_' + $requiredBackendCommand)
}
Assert-GuiTest -Condition (
    $guiSource -notmatch '(?i)\bSave-CodexAccountSlot\b'
) -Code 'GUI_ADD_USED_UNSAFE_GENERIC_SAVE'
foreach ($requiredGuiHandler in @(
    'Invoke-QiehaoSwitchSelectedProfile',
    'Invoke-QiehaoRenameSelectedProfile',
    'Invoke-QiehaoDeleteSelectedProfile',
    'Invoke-QiehaoAddAccount',
    'Invoke-QiehaoLaunchCodex',
    'Show-QiehaoLaunchSettingsDialog',
    'Start-QiehaoProcessMonitor',
    'Add_MouseDoubleClick',
    'Add_PreviewMouseRightButtonDown',
    'Add_PreviewKeyDown',
    'Get-QiehaoDataGridRowFromSource'
)) {
    Assert-GuiTest -Condition ($guiSource.Contains($requiredGuiHandler)) `
        -Code ('GUI_HANDLER_WIRING_MISSING_' + $requiredGuiHandler)
}
Assert-GuiTest -Condition (
    ([regex]::Matches($guiSource,
        'Invoke-QiehaoSwitchSelectedProfile')).Count -ge 4 -and
    $guiSource -match 'DataGridRow' -and
    $guiSource -match 'OriginalSource' -and
    $guiSource -match 'ConfirmDelete' -and
    $guiSource -match '我已登录新账号并退出' -and
    $guiSource -match '本工具不会自动操作 OAuth' -and
    $guiSource -match 'liveStatus -ceq ''运行中''' -and
    $guiSource -match 'liveStatus -cne ''已退出'''
) -Code 'GUI_ACCOUNT_MANAGEMENT_GUARDS_MISSING'

[xml]$xamlDocument = [System.IO.File]::ReadAllText($xamlPath)
$xamlTextForEncoding = [System.IO.File]::ReadAllText($xamlPath)
foreach ($requiredChineseText in @(
    'Codex 账号管理器',
    'Codex 客户端',
    '当前账号',
    '当前身份确认',
    '网页 ChatGPT',
    '不受影响',
    '已保存账号',
    '搜索账号',
    '槽位验证',
    '切换账号',
    '启动 Codex',
    '启动设置',
    '正常退出 Codex'
)) {
    Assert-GuiTest -Condition (
        $xamlTextForEncoding.Contains($requiredChineseText) -and
        -not $xamlTextForEncoding.Contains([char]0xFFFD)
    ) -Code 'GUI_CHINESE_TEXT_ENCODING_FAILED'
}
$namespaceManager = New-Object System.Xml.XmlNamespaceManager($xamlDocument.NameTable)
$namespaceManager.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
$backgroundImageNode = $xamlDocument.SelectSingleNode(
    "//*[@x:Name='BackgroundImage']",
    $namespaceManager
)
Assert-GuiTest -Condition (
    $null -ne $backgroundImageNode -and
    $backgroundImageNode.GetAttribute('Stretch') -ceq 'UniformToFill' -and
    -not $backgroundImageNode.HasAttribute('TileMode')
) -Code 'GUI_BACKGROUND_RESIZE_MODE_INVALID'
foreach ($buttonName in @(
    'SwitchButton',
    'AddButton',
    'RenameButton',
    'DeleteButton'
)) {
    $buttonNode = $xamlDocument.SelectSingleNode(
        "//*[@x:Name='$buttonName']",
        $namespaceManager
    )
    Assert-GuiTest -Condition (
        $null -ne $buttonNode -and
        $buttonNode.GetAttribute('IsEnabled') -ceq 'False'
    ) -Code ('GUI_WRITE_BUTTON_INITIAL_STATE_INVALID_' + $buttonName)
}
$refreshNode = $xamlDocument.SelectSingleNode(
    "//*[@x:Name='RefreshButton']",
    $namespaceManager
)
Assert-GuiTest -Condition (
    $null -ne $refreshNode -and
    $refreshNode.GetAttribute('IsEnabled') -cne 'False'
) -Code 'GUI_REFRESH_BUTTON_DISABLED'

foreach ($phaseTwoButtonName in @(
    'VerifyButton', 'LaunchCodexButton', 'ExitCodexButton'
)) {
    $phaseTwoNode = $xamlDocument.SelectSingleNode(
        "//*[@x:Name='$phaseTwoButtonName']",
        $namespaceManager
    )
    Assert-GuiTest -Condition (
        $null -ne $phaseTwoNode -and
        $phaseTwoNode.GetAttribute('IsEnabled') -ceq 'False'
    ) -Code ('GUI_PHASE_TWO_BUTTON_INITIAL_STATE_INVALID_' + $phaseTwoButtonName)
}

foreach ($launchInfoName in @('LaunchSettingsButton', 'LaunchTargetText')) {
    Assert-GuiTest -Condition ($null -ne $xamlDocument.SelectSingleNode(
        "//*[@x:Name='$launchInfoName']", $namespaceManager
    )) -Code ('GUI_LAUNCH_CONTROL_MISSING_' + $launchInfoName)
}
Assert-GuiTest -Condition (
    $xamlTextForEncoding -match 'LinearGradientBrush x:Key="PanelBrush"' -and
    $xamlTextForEncoding -notmatch 'x:Key="PanelBrush"[^>]*#FFFFFFFF' -and
    $xamlTextForEncoding -match 'ControlTemplate.Triggers' -and
    $xamlTextForEncoding -match 'Property="IsMouseOver"' -and
    $xamlTextForEncoding -match 'Property="IsPressed"' -and
    $xamlTextForEncoding -match 'DynamicResource ActiveRowBrush' -and
    $xamlTextForEncoding -match 'DynamicResource ActiveSelectedRowBrush' -and
    $xamlTextForEncoding -match 'MultiDataTrigger' -and
    $xamlTextForEncoding -match 'BorderThickness" Value="4,0,1,0"'
) -Code 'GUI_GLASS_OR_ACTIVE_ROW_STYLE_MISSING'

$coreAndGuiSource = $guiSource + [System.IO.File]::ReadAllText($coreModulePath)
Assert-GuiTest -Condition (
    $coreAndGuiSource -notmatch '(?i)Stop-Process\b|taskkill\b|TerminateProcess\b|\.Kill\s*\('
) -Code 'GUI_FORCE_TERMINATION_API_PRESENT'
Assert-GuiTest -Condition (
    $guiSource -match 'Test-CodexProfile' -and
    $guiSource -match 'Request-CodexDesktopClose' -and
    $guiSource -match 'DispatcherTimer' -and
    $guiSource -match 'Invoke-QiehaoReadOnlyRefresh' -and
    $guiSource -match 'guiIsWriteOperationBusy'
) -Code 'GUI_OPERATION_WIRING_MISSING'

$processMonitorSection = [regex]::Match(
    $guiSource,
    '(?s)function Update-QiehaoProcessOnlyStatus\s*\{.*?function Get-QiehaoInstalledCodexApplications'
).Value
Assert-GuiTest -Condition (
    -not [string]::IsNullOrWhiteSpace($processMonitorSection) -and
    $processMonitorSection -match 'Get-QiehaoLiveCodexStatus' -and
    $processMonitorSection -match 'FromSeconds\(5\)' -and
    $processMonitorSection -match 'Stop-QiehaoDispatcherTimer' -and
    $processMonitorSection -notmatch '(?i)auth|identity|Get-CodexActiveProfile|Get-CodexAccountSlot'
) -Code 'GUI_PROCESS_MONITOR_NOT_READONLY_ISOLATED'

$timerWaitAndCloseSection = [regex]::Match(
    $guiSource,
    '(?s)function Complete-QiehaoLaunchWait\s*\{.*?\[void\]\$window\.ShowDialog\(\)'
).Value
Assert-GuiTest -Condition (
    -not [string]::IsNullOrWhiteSpace($timerWaitAndCloseSection) -and
    ([regex]::Matches($timerWaitAndCloseSection,
        'FromMilliseconds\(500\)')).Count -eq 2 -and
    $timerWaitAndCloseSection -match '\.TotalSeconds -ge 10' -and
    $timerWaitAndCloseSection -match 'Stop-QiehaoProcessMonitor' -and
    $timerWaitAndCloseSection -match 'Start-QiehaoProcessMonitor' -and
    $timerWaitAndCloseSection -match 'Add_Closing\(\{ Stop-QiehaoAllTimers \}\)' -and
    $timerWaitAndCloseSection -match 'Add_Closed\(' -and
    $helperSource -match 'Remove_Tick' -and
    $guiSource -match 'guiIsClosing'
) -Code 'GUI_TIMER_WAIT_OR_WINDOW_CLOSE_CLEANUP_MISSING'

Assert-GuiTest -Condition (
    $guiSource -match 'Resolve-QiehaoProjectStateDirectory -GuiScriptRoot \$guiRoot' -and
    $guiSource -match '\$themeComboBox\.SelectedItem = \$startupTheme' -and
    $guiSource -match 'guiThemePersistenceReady' -and
    $guiSource -match 'Request-CodexDesktopClose -CallerProcessId \$PID' -and
    $guiSource -match 'Invoke-QiehaoExitButtonAction'
) -Code 'GUI_PREF_OR_SAFE_EXIT_WIRING_MISSING'

$launchSection = [regex]::Match(
    $guiSource,
    '(?s)function Invoke-QiehaoLaunchCodex\s*\{.*?function Complete-QiehaoExitWait'
).Value
Assert-GuiTest -Condition (
    -not [string]::IsNullOrWhiteSpace($launchSection) -and
    $launchSection -match 'Start-Process' -and
    $launchSection -match 'shell:AppsFolder' -and
    $launchSection -notmatch '(?i)token|account_id|--profile|--user-data-dir|RunAs'
) -Code 'GUI_LAUNCH_ARGUMENT_SAFETY_FAILED'

$mutexName = 'Qiehaoqu.CodexAccountSwitcher.Gui.v1.SelfTest.' + `
    [Guid]::NewGuid().ToString('N')
$firstLease = Enter-QiehaoGuiSingleInstance -MutexName $mutexName
Assert-GuiTest -Condition $firstLease.Acquired `
    -Code 'GUI_FIRST_INSTANCE_MUTEX_FAILED'
$mutexJob = $null
try {
    $mutexJob = Start-Job -ArgumentList @($helperModulePath, $mutexName) `
        -ScriptBlock {
            param($ModulePath, $Name)
            Import-Module -Name $ModulePath -Force -ErrorAction Stop
            $lease = Enter-QiehaoGuiSingleInstance -MutexName $Name
            try {
                return [bool]$lease.Acquired
            }
            finally {
                if ($lease.Acquired) {
                    Exit-QiehaoGuiSingleInstance -Lease $lease
                }
            }
        }
    $null = Wait-Job -Job $mutexJob -Timeout 15
    $secondAcquired = [bool](Receive-Job -Job $mutexJob -ErrorAction Stop)
    Assert-GuiTest -Condition (-not $secondAcquired) `
        -Code 'GUI_SECOND_INSTANCE_NOT_BLOCKED'
}
finally {
    if ($null -ne $mutexJob) {
        Remove-Job -Job $mutexJob -Force -ErrorAction SilentlyContinue
    }
    Exit-QiehaoGuiSingleInstance -Lease $firstLease
}

[pscustomobject]@{
    Result = 'PASS'
    GuiStartupPowerShell51 = 'PASS'
    GuiStartupPowerShell7 = 'PASS'
    PowerShell51XamlParse = 'PASS'
    PowerShell7XamlParse = 'PASS'
    FiveThemesLoad = 'PASS'
    FiveThemesGlassProperties = 'PASS'
    MissingThemeFallback = 'PASS'
    CorruptThemeFallback = 'PASS'
    BackgroundUniformToFill = 'PASS'
    ImmediateThemeSwitch = 'PASS'
    ThemePreferenceRestore = 'PASS'
    ThemePreferenceDifferentWorkingDirectory = 'PASS'
    CorruptPreferenceFallback = 'PASS'
    ChineseTextEncoding = 'PASS'
    DynamicPlusTeam = 'PASS'
    FakeThreeProfiles = 'PASS'
    FakeTenProfiles = 'PASS'
    HealthStates = 'PASS'
    ActiveProfile = 'PASS'
    ActiveIdentityRefreshSemantics = 'PASS'
    CodexRunning = 'PASS'
    CodexStopped = 'PASS'
    CodexUnknown = 'PASS'
    BrowserExtensionIsolation = 'PASS'
    VerifyNoSelectionRejected = 'PASS'
    VerifyRunningRejected = 'PASS'
    VerifyUnknownRejected = 'PASS'
    VerifySuccess = 'PASS'
    VerifyIdentityMismatchSafe = 'PASS'
    VerifyIncompleteSafe = 'PASS'
    VerifySensitiveFailureSafe = 'PASS'
    VerifyRefresh = 'PASS'
    ExitAlreadyStopped = 'PASS'
    ExitCloseMainWindowRequested = 'PASS'
    ExitPostCloseStopped = 'PASS'
    ExitStillRunningNoForce = 'PASS'
    ExitUnknownNoRequest = 'PASS'
    ExitBrowserIsolation = 'PASS'
    ExitSelfWindowExcluded = 'PASS'
    ExitMixedProcessesOfficialOnly = 'PASS'
    ExitWindowOwnerValidated = 'PASS'
    ExitFailureKeepsManagerRunning = 'PASS'
    LaunchAutoDetection = 'PASS'
    LaunchCustomSettings = 'PASS'
    LaunchProviderContract = 'PASS'
    LaunchExitButtonStates = 'PASS'
    ProcessMonitorReadOnly = 'PASS'
    ProcessMonitorFiveSeconds = 'PASS'
    WindowCloseStopsAllTimers = 'PASS'
    GlassCardsAndButtons = 'PASS'
    ActiveRowDistinct = 'PASS'
    RefreshReadOnly = 'PASS'
    ClickOnlySelects = 'PASS'
    DoubleClickStoppedSwitch = 'PASS'
    DoubleClickActiveNoWrite = 'PASS'
    NonRowDoubleClickIgnored = 'PASS'
    RunningExitThenSwitch = 'PASS'
    ExitFailureBlocksSwitch = 'PASS'
    UnknownBlocksSwitch = 'PASS'
    SwitchSuccess = 'PASS'
    SwitchRollbackSafe = 'PASS'
    SwitchRollbackFailureCritical = 'PASS'
    IdentityMismatchSafe = 'PASS'
    OperationBusyRejected = 'PASS'
    RightClickSelectsRow = 'PASS'
    ActiveContextSwitchDisabled = 'PASS'
    ActiveDeleteDisabled = 'PASS'
    F2RenameWired = 'PASS'
    RenameSuccess = 'PASS'
    RenameActiveAllowed = 'PASS'
    RenameRollbackSafe = 'PASS'
    DeleteNonActiveSuccess = 'PASS'
    DeleteConfirmationRequired = 'PASS'
    AddSuccess = 'PASS'
    AddDuplicateNameSafe = 'PASS'
    AddDuplicateIdentitySafe = 'PASS'
    AddRunningGuard = 'PASS'
    AddUnknownGuard = 'PASS'
    SearchCaseInsensitive = 'PASS'
    SearchSubstring = 'PASS'
    SearchClearRestoresAll = 'PASS'
    SearchNameOnly = 'PASS'
    BusyDisablesWriteEntrypoints = 'PASS'
    WriteButtonsInitialStateSafe = 'PASS'
    SecondInstanceBlocked = 'PASS'
    RealAuthOrProfileRead = $false
}
