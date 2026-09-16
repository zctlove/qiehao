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
            $testWindow.Title -ceq 'Codex Account Switcher'
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

        [string]$ReasonCode = 'CODEX_PROCESSES_STOPPED'
    )

    $listData = @($Profiles)
    $activeName = $Active
    $processReason = $ReasonCode
    return Get-QiehaoGuiSnapshot `
        -ListProvider ({ $listData }.GetNewClosure()) `
        -ActiveProvider ({
            [pscustomobject]@{ ActiveProfile = $activeName }
        }.GetNewClosure()) `
        -ProcessProvider ({
            [pscustomobject]@{ ReasonCode = $processReason }
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

$guiStartup = Invoke-PowerShellFileTest -HostPath $ps51Command.Source `
    -ScriptPath $guiScriptPath -AdditionalArguments @('-SelfTest')
Assert-GuiTest -Condition (
    $guiStartup.ExitCode -eq 0 -and
    $guiStartup.Output -ccontains 'GUI_SELFTEST_READY'
) -Code 'GUI_STARTUP_SELFTEST_FAILED'

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
    ((@('READY','INCOMPLETE_PROFILE','INVALID_METADATA','UNKNOWN') |
        Sort-Object) -join '|')
) -Code 'GUI_HEALTH_DISPLAY_FAILED'

$activeRows = @($tenSnapshot.Profiles | Where-Object { $_.Active -ceq 'Yes' })
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
    $runningSnapshot.CodexDesktop -ceq 'Running'
) -Code 'GUI_CODEX_RUNNING_MAP_FAILED'
Assert-GuiTest -Condition (
    $stoppedSnapshot.CodexDesktop -ceq 'Stopped'
) -Code 'GUI_CODEX_STOPPED_MAP_FAILED'
Assert-GuiTest -Condition (
    $unknownSnapshot.CodexDesktop -ceq 'Unknown'
) -Code 'GUI_CODEX_UNKNOWN_MAP_FAILED'

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

$providerCalls = [pscustomobject]@{ List=0; Active=0; Process=0 }
$null = Get-QiehaoGuiSnapshot `
    -ListProvider ({ $providerCalls.List++; @() }.GetNewClosure()) `
    -ActiveProvider ({
        $providerCalls.Active++
        [pscustomobject]@{ ActiveProfile='A' }
    }.GetNewClosure()) `
    -ProcessProvider ({
        $providerCalls.Process++
        [pscustomobject]@{ ReasonCode='CODEX_PROCESSES_STOPPED' }
    }.GetNewClosure())
Assert-GuiTest -Condition (
    $providerCalls.List -eq 1 -and
    $providerCalls.Active -eq 1 -and
    $providerCalls.Process -eq 1
) -Code 'GUI_REFRESH_PROVIDER_COUNT_FAILED'

$guiSource = [System.IO.File]::ReadAllText($guiScriptPath)
foreach ($dangerousCommand in @(
    'Save-CodexAccountSlot',
    'Switch-CodexAccountProfile',
    'Add-CodexProfile',
    'Remove-CodexProfile',
    'Rename-CodexProfile',
    'Test-CodexProfile',
    'Initialize-CodexProfileIdentityMarker',
    'Initialize-CodexActiveProfile'
)) {
    Assert-GuiTest -Condition (
        $guiSource -notmatch ('(?i)\b' + [regex]::Escape($dangerousCommand) + '\b')
    ) -Code ('GUI_DANGEROUS_COMMAND_PRESENT_' + $dangerousCommand)
}

[xml]$xamlDocument = [System.IO.File]::ReadAllText($xamlPath)
$namespaceManager = New-Object System.Xml.XmlNamespaceManager($xamlDocument.NameTable)
$namespaceManager.AddNamespace('x', 'http://schemas.microsoft.com/winfx/2006/xaml')
foreach ($buttonName in @(
    'SwitchButton',
    'VerifyButton',
    'AddButton',
    'RenameButton',
    'DeleteButton',
    'ExitCodexButton'
)) {
    $buttonNode = $xamlDocument.SelectSingleNode(
        "//*[@x:Name='$buttonName']",
        $namespaceManager
    )
    Assert-GuiTest -Condition (
        $null -ne $buttonNode -and
        $buttonNode.GetAttribute('IsEnabled') -ceq 'False'
    ) -Code ('GUI_DANGEROUS_BUTTON_ENABLED_' + $buttonName)
}
$refreshNode = $xamlDocument.SelectSingleNode(
    "//*[@x:Name='RefreshButton']",
    $namespaceManager
)
Assert-GuiTest -Condition (
    $null -ne $refreshNode -and
    $refreshNode.GetAttribute('IsEnabled') -cne 'False'
) -Code 'GUI_REFRESH_BUTTON_DISABLED'

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
    GuiStartup = 'PASS'
    PowerShell51XamlParse = 'PASS'
    PowerShell7XamlParse = 'PASS'
    DynamicPlusTeam = 'PASS'
    FakeThreeProfiles = 'PASS'
    FakeTenProfiles = 'PASS'
    HealthStates = 'PASS'
    ActiveProfile = 'PASS'
    CodexRunning = 'PASS'
    CodexStopped = 'PASS'
    CodexUnknown = 'PASS'
    BrowserExtensionIsolation = 'PASS'
    RefreshReadOnly = 'PASS'
    DangerousButtonsDisabled = 'PASS'
    SecondInstanceBlocked = 'PASS'
    RealAuthOrProfileRead = $false
}
