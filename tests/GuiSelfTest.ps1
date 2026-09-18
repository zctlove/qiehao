[CmdletBinding()]
param(
    [switch]$XamlOnly,
    [switch]$ModalLifecycleOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$guiRoot = Join-Path -Path $projectRoot -ChildPath 'gui'
$xamlPath = Join-Path -Path $guiRoot -ChildPath 'MainWindow.xaml'
$guiScriptPath = Join-Path -Path $guiRoot -ChildPath 'QiehaoGui.ps1'
$helperModulePath = Join-Path -Path $guiRoot -ChildPath 'GuiHelpers.psm1'
$quotaGuiSelfTestPath = Join-Path -Path $PSScriptRoot `
    -ChildPath 'QuotaGuiSelfTest.ps1'
$quotaImportContractPath = Join-Path -Path $PSScriptRoot `
    -ChildPath 'QuotaImportContractSelfTest.ps1'
$quotaBackgroundWorkerTestPath = Join-Path -Path $PSScriptRoot `
    -ChildPath 'QuotaBackgroundWorkerSelfTest.ps1'
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

function Get-TestColorLuminance {
    param([Parameter(Mandatory = $true)][string]$Color)
    if ($Color -notmatch '^#[0-9A-Fa-f]{8}$') {
        throw 'GUI_TEST_COLOR_FORMAT_INVALID'
    }
    $channels = @(
        [Convert]::ToInt32($Color.Substring(3, 2), 16),
        [Convert]::ToInt32($Color.Substring(5, 2), 16),
        [Convert]::ToInt32($Color.Substring(7, 2), 16)
    )
    $linear = @()
    foreach ($channel in $channels) {
        $normalized = [double]$channel / 255.0
        $linear += if ($normalized -le 0.04045) {
            $normalized / 12.92
        }
        else {
            [Math]::Pow(($normalized + 0.055) / 1.055, 2.4)
        }
    }
    return 0.2126 * $linear[0] + 0.7152 * $linear[1] +
        0.0722 * $linear[2]
}

function Get-TestContrastRatio {
    param(
        [Parameter(Mandatory = $true)][string]$Foreground,
        [Parameter(Mandatory = $true)][string]$Background
    )
    $first = Get-TestColorLuminance -Color $Foreground
    $second = Get-TestColorLuminance -Color $Background
    return ([Math]::Max($first, $second) + 0.05) /
        ([Math]::Min($first, $second) + 0.05)
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

function Invoke-TestDispatcherFor {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 5000)]
        [int]$Milliseconds
    )

    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $stopTimer = New-Object System.Windows.Threading.DispatcherTimer
    $stopTimer.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
    $stopHandler = [System.EventHandler]({
        param($sender, $eventArgs)
        $stopTimer.Stop()
        $frame.Continue = $false
    }.GetNewClosure())
    $stopTimer.Add_Tick($stopHandler)
    try {
        $stopTimer.Start()
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    }
    finally {
        $stopTimer.Remove_Tick($stopHandler)
        $stopTimer.Stop()
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

if ($ModalLifecycleOnly) {
    Add-Type -AssemblyName PresentationCore -ErrorAction Stop
    Add-Type -AssemblyName PresentationFramework -ErrorAction Stop
    Add-Type -AssemblyName WindowsBase -ErrorAction Stop
    Import-Module -Name $helperModulePath -Force -ErrorAction Stop

    $modalState = [pscustomobject]@{
        Busy = $true
        UiState = 'WaitingForCodexExit'
        ActiveProfile = 'Plus'
        PlusCurrent = '是'
        PlusActive = $true
        TeamCurrent = '否'
        TeamActive = $false
        SwitchCalls = 0
        RefreshCalls = 0
        LaunchCalls = 0
        MainTimerCalls = 0
        NotificationPreconditions = $false
        HandlerRemoved = $false
        TickHandler = $null
        TickCount = 0
        CallbackError = ''
        Order = @()
        Presentation = $null
    }
    $dialog = New-Object System.Windows.Window
    $dialog.Width = 1
    $dialog.Height = 1
    $dialog.WindowStyle = 'None'
    $dialog.ShowInTaskbar = $false
    $dialog.Opacity = 0
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(15)
    $tickHandler = [System.EventHandler]({
        param($sender, $eventArgs)
        try {
            $modalState.TickCount++
            if ($modalState.TickCount -eq 1) {
                $modalState.Order += 'Running'
                return
            }
            $sender.Stop()
            $sender.Remove_Tick($modalState.TickHandler)
            $modalState.HandlerRemoved = $true
            $modalState.SwitchCalls++
            $modalState.Order += 'Switch'
            $backendResult = ConvertTo-QiehaoOperationResult `
                -ResultCode 'SWITCH_SUCCESS'
            $modalState.Presentation = Invoke-QiehaoSwitchUiCompletion `
                -Result $backendResult -TargetProfile 'Team' `
                -RefreshProvider ({
                    param($Target)
                    $modalState.RefreshCalls++
                    $modalState.ActiveProfile = $Target
                    $modalState.PlusCurrent = '否'
                    $modalState.PlusActive = $false
                    $modalState.TeamCurrent = '是'
                    $modalState.TeamActive = $true
                    $modalState.Order += 'Refresh'
                    return $true
                }.GetNewClosure()) `
                -BusyProvider ({
                    param($Value)
                    $modalState.Busy = [bool]$Value
                    $modalState.Order += 'BusyFalse'
                }.GetNewClosure()) `
                -StateProvider ({
                    param($State, $Target)
                    $modalState.UiState = $State
                    $modalState.Order += ('State:' + $State)
                }.GetNewClosure())
            $modalState.NotificationPreconditions = (
                $modalState.RefreshCalls -eq 1 -and
                $modalState.ActiveProfile -ceq 'Team' -and
                $modalState.TeamCurrent -ceq '是' -and $modalState.TeamActive -and
                $modalState.PlusCurrent -ceq '否' -and
                -not $modalState.PlusActive -and
                $modalState.UiState -ceq 'SwitchSucceeded' -and
                -not $modalState.Busy
            )
            $dialog.Close()
        }
        catch {
            $modalState.CallbackError =
                $_.Exception.GetType().FullName + ':' + $_.Exception.Message
            try { $sender.Stop() }
            catch { }
            try { $sender.Remove_Tick($modalState.TickHandler) }
            catch { }
            try { $dialog.Close() }
            catch { }
        }
    }.GetNewClosure())
    $modalState.TickHandler = $tickHandler
    $dialog.Tag = [pscustomobject]@{
        Timer = $timer
        TickHandler = $tickHandler
    }
    $loadedHandler = [System.Windows.RoutedEventHandler]{
        param($sender, $eventArgs)
        $sender.Tag.Timer.Add_Tick($sender.Tag.TickHandler)
        $sender.Tag.Timer.Start()
    }
    $dialog.Add_Loaded($loadedHandler)
    $fallbackTimer = New-Object System.Windows.Threading.DispatcherTimer
    $fallbackTimer.Interval = [TimeSpan]::FromSeconds(2)
    $fallbackHandler = [System.EventHandler]({
        param($sender, $eventArgs)
        $sender.Stop()
        if ([string]::IsNullOrWhiteSpace($modalState.CallbackError)) {
            $modalState.CallbackError = 'MODAL_TEST_TIMEOUT'
        }
        $dialog.Close()
    }.GetNewClosure())
    $fallbackTimer.Add_Tick($fallbackHandler)
    try {
        $fallbackTimer.Start()
        [void]$dialog.ShowDialog()
    }
    finally {
        $fallbackTimer.Stop()
        try { $fallbackTimer.Remove_Tick($fallbackHandler) }
        catch { }
        $timer.Stop()
        try { $timer.Remove_Tick($tickHandler) }
        catch { }
        try { $dialog.Remove_Loaded($loadedHandler) }
        catch { }
    }
    $modalState.Order += 'WindowClosed'
    if (-not [string]::IsNullOrWhiteSpace($modalState.CallbackError)) {
        throw ('GUI_MODAL_CALLBACK_FAILED:' + $modalState.CallbackError)
    }
    if ($modalState.NotificationPreconditions) {
        $modalState.Order += 'Success'
    }
    Assert-GuiTest -Condition (
        $modalState.SwitchCalls -eq 1 -and
        $modalState.RefreshCalls -eq 1 -and
        $modalState.LaunchCalls -eq 0 -and
        $modalState.MainTimerCalls -eq 0 -and
        $modalState.NotificationPreconditions -and
        $modalState.HandlerRemoved -and -not $timer.IsEnabled -and
        $modalState.Presentation.State -ceq 'SwitchSucceeded' -and
        (@($modalState.Order) -join '|') -ceq
            'Running|Switch|Refresh|BusyFalse|State:SwitchSucceeded|WindowClosed|Success'
    ) -Code 'GUI_MODAL_SWITCH_REFRESH_ORDER_FAILED'

    $failureState = [pscustomobject]@{
        Busy = $true; UiState = 'Switching'; SwitchCalls = 1
        RefreshCalls = 0; RollbackCalls = 0
    }
    $failureResult = ConvertTo-QiehaoOperationResult `
        -ResultCode 'SWITCH_SUCCESS'
    $failurePresentation = Invoke-QiehaoSwitchUiCompletion `
        -Result $failureResult -TargetProfile 'Team' `
        -RefreshProvider ({
            param($Target)
            $failureState.RefreshCalls++
            throw 'FAKE_UI_REFRESH_FAILURE'
        }.GetNewClosure()) `
        -BusyProvider ({
            param($Value)
            $failureState.Busy = [bool]$Value
        }.GetNewClosure()) `
        -StateProvider ({
            param($State, $Target)
            $failureState.UiState = $State
        }.GetNewClosure())
    Assert-GuiTest -Condition (
        $failureState.SwitchCalls -eq 1 -and
        $failureState.RefreshCalls -eq 1 -and
        $failureState.RollbackCalls -eq 0 -and
        -not $failureState.Busy -and
        $failureState.UiState -ceq 'SwitchSucceededUiRefreshFailed' -and
        $failurePresentation.BackendSucceeded -and
        -not $failurePresentation.UiRefreshSucceeded
    ) -Code 'GUI_BACKEND_SUCCESS_REFRESH_FAILURE_NOT_DISTINGUISHED'
    Write-Output 'MODAL_SWITCH_LIFECYCLE_PASS'
    return
}

Import-Module -Name $helperModulePath -Force -ErrorAction Stop
Import-Module -Name $coreModulePath -Force -ErrorAction Stop

$quotaGuiOutput = @(& $quotaGuiSelfTestPath)
Assert-GuiTest -Condition (
    $quotaGuiOutput -ccontains 'QUOTA_GUI_SELFTEST_PASS'
) -Code 'GUI_QUOTA_SELFTEST_FAILED'

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

        [string[]]$AdditionalArguments = @(),

        [string]$WorkingDirectory = ''
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
    $previousLocation = Get-Location
    try {
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            Set-Location -LiteralPath $WorkingDirectory
        }
        $output = @(& $HostPath @arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        Set-Location -LiteralPath $previousLocation.Path
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output | ForEach-Object { [string]$_ })
    }
}

$ps51Command = Get-Command -Name 'powershell.exe' -ErrorAction Stop
$ps7Command = Get-Command -Name 'pwsh.exe' -ErrorAction Stop

$productionImport51 = Invoke-PowerShellFileTest `
    -HostPath $ps51Command.Source -ScriptPath $quotaImportContractPath
Assert-GuiTest -Condition (
    $productionImport51.ExitCode -eq 0 -and
    $productionImport51.Output -ccontains 'CORE_COMMANDS_PRESENT=True' -and
    $productionImport51.Output -ccontains
        'CORE_COMMANDS_SURVIVE_ALL_QUOTA_IMPORTS=True' -and
    $productionImport51.Output -ccontains
        'QUOTA_PARSER_COMMANDS_PRESENT=True' -and
    $productionImport51.Output -ccontains
        'QUOTA_CLIENT_COMMANDS_PRESENT=True' -and
    $productionImport51.Output -ccontains
        'QUOTA_HELPER_COMMANDS_PRESENT=True' -and
    $productionImport51.Output -ccontains
        'QUOTA_AUTH_MODULE_REFERENCE_VALID=True' -and
    $productionImport51.Output -ccontains
        'QUOTA_MUTEX_HELPER_PRESENT=True' -and
    $productionImport51.Output -ccontains
        'QUOTA_MUTEX_ACQUIRE_SUCCEEDED=True' -and
    $productionImport51.Output -ccontains
        'QUOTA_PARSER_MODULE_PATH_ABSOLUTE=True' -and
    $productionImport51.Output -ccontains
        'QUOTA_AUTH_MODULE_PATH_ABSOLUTE=True' -and
    $productionImport51.Output -ccontains 'QUOTA_RUNTIME_AVAILABLE=True' -and
    $productionImport51.Output -ccontains 'PRODUCTION_IMPORT_ORDER_PASS'
) -Code 'GUI_PRODUCTION_IMPORT_ORDER_PS51_FAILED'

$productionImport7 = Invoke-PowerShellFileTest `
    -HostPath $ps7Command.Source -ScriptPath $quotaImportContractPath
Assert-GuiTest -Condition (
    $productionImport7.ExitCode -eq 0 -and
    $productionImport7.Output -ccontains 'CORE_COMMANDS_PRESENT=True' -and
    $productionImport7.Output -ccontains
        'CORE_COMMANDS_SURVIVE_ALL_QUOTA_IMPORTS=True' -and
    $productionImport7.Output -ccontains
        'QUOTA_PARSER_COMMANDS_PRESENT=True' -and
    $productionImport7.Output -ccontains
        'QUOTA_CLIENT_COMMANDS_PRESENT=True' -and
    $productionImport7.Output -ccontains
        'QUOTA_HELPER_COMMANDS_PRESENT=True' -and
    $productionImport7.Output -ccontains
        'QUOTA_AUTH_MODULE_REFERENCE_VALID=True' -and
    $productionImport7.Output -ccontains
        'QUOTA_MUTEX_HELPER_PRESENT=True' -and
    $productionImport7.Output -ccontains
        'QUOTA_MUTEX_ACQUIRE_SUCCEEDED=True' -and
    $productionImport7.Output -ccontains
        'QUOTA_PARSER_MODULE_PATH_ABSOLUTE=True' -and
    $productionImport7.Output -ccontains
        'QUOTA_AUTH_MODULE_PATH_ABSOLUTE=True' -and
    $productionImport7.Output -ccontains 'QUOTA_RUNTIME_AVAILABLE=True' -and
    $productionImport7.Output -ccontains 'PRODUCTION_IMPORT_ORDER_PASS'
) -Code 'GUI_PRODUCTION_IMPORT_ORDER_PS7_FAILED'

$requiredWorkerContractOutput = @(
    'BackgroundWorkerImportsQuotaClient=True',
    'BackgroundWorkerImportsQuotaParser=True',
    'BackgroundWorkerHasQuotaPublicCommand=True',
    'BackgroundWorkerReturnsStructuredResult=True',
    'BackgroundWorkerFailureCodeSurvivesEndInvoke=True',
    'BackgroundWorkerDoesNotRequireCallerScopeModules=True',
    'BackgroundWorkerOutputCount=1',
    'BackgroundWorkerRejectsPipelinePollution=True',
    'BackgroundWorkerStreamsDoNotOverrideSuccess=True',
    'BackgroundWorkerSnapshotSurvivesEndInvoke=True',
    'BackgroundWorkerDiagnosticsSurviveEndInvoke=True',
    'BackgroundWorkerBundledDiscoveryWithoutPath=True',
    'QUOTA_BACKGROUND_WORKER_SELFTEST_PASS'
)
$workerContract51 = Invoke-PowerShellFileTest `
    -HostPath $ps51Command.Source `
    -ScriptPath $quotaBackgroundWorkerTestPath
Assert-GuiTest -Condition (
    $workerContract51.ExitCode -eq 0 -and
    @($requiredWorkerContractOutput | Where-Object {
        $workerContract51.Output -cnotcontains $_
    }).Count -eq 0
) -Code 'GUI_BACKGROUND_WORKER_CONTRACT_PS51_FAILED'

$workerContract7 = Invoke-PowerShellFileTest `
    -HostPath $ps7Command.Source `
    -ScriptPath $quotaBackgroundWorkerTestPath
Assert-GuiTest -Condition (
    $workerContract7.ExitCode -eq 0 -and
    @($requiredWorkerContractOutput | Where-Object {
        $workerContract7.Output -cnotcontains $_
    }).Count -eq 0
) -Code 'GUI_BACKGROUND_WORKER_CONTRACT_PS7_FAILED'

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

$quotaLayoutWindow = Read-TestWindow
try {
    $quotaLayoutWindow.WindowStartupLocation = 'Manual'
    $quotaLayoutWindow.Left = -10000
    $quotaLayoutWindow.Top = -10000
    $quotaLayoutWindow.Opacity = 0
    $quotaLayoutWindow.ShowInTaskbar = $false
    $quotaLayoutGrid = $quotaLayoutWindow.FindName('ProfilesGrid')
    $quotaLayoutItems = @(
        [pscustomobject]@{
            Name = 'One'; QuotaSummary = '30d 72%'
            QuotaToolTip = 'One window'
        },
        [pscustomobject]@{
            Name = 'Two'; QuotaSummary = '5h 35% - Week 15%'
            QuotaToolTip = 'Two windows'
        },
        [pscustomobject]@{
            Name = 'Three'; QuotaSummary = '1h 90% - 2h 80% - 3h 70%'
            QuotaToolTip = 'Three windows'
        }
    )
    $quotaLayoutGrid.ItemsSource = $quotaLayoutItems
    $quotaLayoutWindow.Show()
    $quotaLayoutWindow.UpdateLayout()
    $quotaRows = @(0..2 | ForEach-Object {
        $quotaLayoutGrid.ItemContainerGenerator.ContainerFromIndex($_)
    })
    Assert-GuiTest -Condition (
        @($quotaRows | Where-Object { $null -eq $_ }).Count -eq 0 -and
        @($quotaRows | Where-Object {
            $_.ActualHeight -lt 28 -or $_.ActualHeight -gt 34
        }).Count -eq 0 -and
        @($quotaRows | Select-Object -ExpandProperty ActualHeight -Unique).
            Count -eq 1
    ) -Code 'GUI_QUOTA_WINDOW_COUNT_CHANGED_ROW_HEIGHT'

    $quotaLayoutGrid.ItemsSource = @(
        [pscustomobject]@{
            Name = 'NoSnapshot'; QuotaSummary = 'No snapshot'
            QuotaToolTip = 'No snapshot'
        },
        $quotaLayoutItems[2]
    )
    $quotaLayoutWindow.UpdateLayout()
    $noSnapshotRow =
        $quotaLayoutGrid.ItemContainerGenerator.ContainerFromIndex(0)
    $threeWindowRow =
        $quotaLayoutGrid.ItemContainerGenerator.ContainerFromIndex(1)
    $quotaScrollViewer = $quotaLayoutGrid.Template.FindName(
        'DG_ScrollViewer',
        $quotaLayoutGrid
    )
    Assert-GuiTest -Condition (
        $null -ne $noSnapshotRow -and $null -ne $threeWindowRow -and
        $noSnapshotRow.ActualHeight -ge 28 -and
        $noSnapshotRow.ActualHeight -le 34 -and
        $threeWindowRow.ActualHeight -eq $noSnapshotRow.ActualHeight -and
        $null -ne $quotaScrollViewer -and
        $quotaScrollViewer.ComputedVerticalScrollBarVisibility -eq
            [System.Windows.Visibility]::Collapsed
    ) -Code 'GUI_TWO_PROFILE_QUOTA_TEMPLATE_FORCED_VERTICAL_SCROLL'
}
finally {
    $quotaLayoutWindow.Close()
}

$ps51ModalLifecycle = Invoke-PowerShellFileTest `
    -HostPath $ps51Command.Source -ScriptPath $PSCommandPath `
    -AdditionalArguments @('-ModalLifecycleOnly')
Assert-GuiTest -Condition (
    $ps51ModalLifecycle.ExitCode -eq 0 -and
    $ps51ModalLifecycle.Output -ccontains 'MODAL_SWITCH_LIFECYCLE_PASS'
) -Code 'GUI_POWERSHELL_51_MODAL_SWITCH_LIFECYCLE_FAILED'

$ps7ModalLifecycle = Invoke-PowerShellFileTest `
    -HostPath $ps7Command.Source -ScriptPath $PSCommandPath `
    -AdditionalArguments @('-ModalLifecycleOnly')
Assert-GuiTest -Condition (
    $ps7ModalLifecycle.ExitCode -eq 0 -and
    $ps7ModalLifecycle.Output -ccontains 'MODAL_SWITCH_LIFECYCLE_PASS'
) -Code 'GUI_POWERSHELL_7_MODAL_SWITCH_LIFECYCLE_FAILED'

$guiStartup51 = Invoke-PowerShellFileTest -HostPath $ps51Command.Source `
    -ScriptPath $guiScriptPath -AdditionalArguments @('-SelfTest')
Assert-GuiTest -Condition (
    $guiStartup51.ExitCode -eq 0 -and
    $guiStartup51.Output -ccontains 'QUOTA_RUNTIME_AVAILABLE=True' -and
    $guiStartup51.Output -ccontains
        'QUOTA_INITIALIZATION_FAILURE_CODE=NONE' -and
    $guiStartup51.Output -ccontains
        'QUOTA_REFRESH_BUTTON_ENABLED=True' -and
    $guiStartup51.Output -ccontains 'QUOTA_CACHE_EXISTS=False' -and
    $guiStartup51.Output -ccontains 'GUI_SELFTEST_READY'
) -Code 'GUI_STARTUP_SELFTEST_PS51_FAILED'
$guiStartup7 = Invoke-PowerShellFileTest -HostPath $ps7Command.Source `
    -ScriptPath $guiScriptPath -AdditionalArguments @('-SelfTest')
Assert-GuiTest -Condition (
    $guiStartup7.ExitCode -eq 0 -and
    $guiStartup7.Output -ccontains 'QUOTA_RUNTIME_AVAILABLE=True' -and
    $guiStartup7.Output -ccontains
        'QUOTA_INITIALIZATION_FAILURE_CODE=NONE' -and
    $guiStartup7.Output -ccontains
        'QUOTA_REFRESH_BUTTON_ENABLED=True' -and
    $guiStartup7.Output -ccontains 'QUOTA_CACHE_EXISTS=False' -and
    $guiStartup7.Output -ccontains 'GUI_SELFTEST_READY'
) -Code 'GUI_STARTUP_SELFTEST_PS7_FAILED'

$guiQuotaUnavailable51 = Invoke-PowerShellFileTest `
    -HostPath $ps51Command.Source -ScriptPath $guiScriptPath `
    -AdditionalArguments @('-SelfTest', '-SimulateQuotaModuleUnavailable')
Assert-GuiTest -Condition (
    $guiQuotaUnavailable51.ExitCode -eq 0 -and
    $guiQuotaUnavailable51.Output -ccontains
        'QUOTA_RUNTIME_AVAILABLE=False' -and
    $guiQuotaUnavailable51.Output -ccontains
        'QUOTA_INITIALIZATION_FAILURE_CODE=QUOTA_HELPERS_IMPORT_FAILED' -and
    $guiQuotaUnavailable51.Output -ccontains
        'QUOTA_REFRESH_BUTTON_ENABLED=False' -and
    $guiQuotaUnavailable51.Output -ccontains 'GUI_SELFTEST_READY'
) -Code 'GUI_QUOTA_MODULE_UNAVAILABLE_PS51_BLOCKED_CORE_STARTUP'

$guiQuotaUnavailable7 = Invoke-PowerShellFileTest `
    -HostPath $ps7Command.Source -ScriptPath $guiScriptPath `
    -AdditionalArguments @('-SelfTest', '-SimulateQuotaModuleUnavailable')
Assert-GuiTest -Condition (
    $guiQuotaUnavailable7.ExitCode -eq 0 -and
    $guiQuotaUnavailable7.Output -ccontains
        'QUOTA_RUNTIME_AVAILABLE=False' -and
    $guiQuotaUnavailable7.Output -ccontains
        'QUOTA_INITIALIZATION_FAILURE_CODE=QUOTA_HELPERS_IMPORT_FAILED' -and
    $guiQuotaUnavailable7.Output -ccontains
        'QUOTA_REFRESH_BUTTON_ENABLED=False' -and
    $guiQuotaUnavailable7.Output -ccontains 'GUI_SELFTEST_READY'
) -Code 'GUI_QUOTA_MODULE_UNAVAILABLE_PS7_BLOCKED_CORE_STARTUP'

$guiQueryFailure51 = Invoke-PowerShellFileTest `
    -HostPath $ps51Command.Source -ScriptPath $guiScriptPath `
    -AdditionalArguments @('-SelfTest', '-SimulateQuotaQueryFailure')
Assert-GuiTest -Condition (
    $guiQueryFailure51.ExitCode -eq 0 -and
    $guiQueryFailure51.Output -ccontains 'QUOTA_RUNTIME_AVAILABLE=True' -and
    $guiQueryFailure51.Output -ccontains
        'QUOTA_INITIALIZATION_FAILURE_CODE=NONE' -and
    $guiQueryFailure51.Output -ccontains
        'QUOTA_REFRESH_BUTTON_ENABLED=True' -and
    $guiQueryFailure51.Output -ccontains 'GUI_SELFTEST_READY'
) -Code 'GUI_QUERY_FAILURE_DISABLED_QUOTA_PS51'

$guiQueryFailure7 = Invoke-PowerShellFileTest `
    -HostPath $ps7Command.Source -ScriptPath $guiScriptPath `
    -AdditionalArguments @('-SelfTest', '-SimulateQuotaQueryFailure')
Assert-GuiTest -Condition (
    $guiQueryFailure7.ExitCode -eq 0 -and
    $guiQueryFailure7.Output -ccontains 'QUOTA_RUNTIME_AVAILABLE=True' -and
    $guiQueryFailure7.Output -ccontains
        'QUOTA_INITIALIZATION_FAILURE_CODE=NONE' -and
    $guiQueryFailure7.Output -ccontains
        'QUOTA_REFRESH_BUTTON_ENABLED=True' -and
    $guiQueryFailure7.Output -ccontains 'GUI_SELFTEST_READY'
) -Code 'GUI_QUERY_FAILURE_DISABLED_QUOTA_PS7'

$requiredQuotaAsyncOutputs = @(
    'StartupQuotaSuccessClearsBusy=True',
    'StartupQuotaFailureClearsBusy=True',
    'StartupQuotaTimeoutClearsBusy=True',
    'StartupQuotaCompletionTimerStops=True',
    'StartupQuotaCompletionHandlerRemoved=True',
    'StartupQuotaSuccessReEnablesRefresh=True',
    'StartupQuotaFailureReEnablesRefresh=True',
    'QueryFailureDoesNotDisableQuotaRuntime=True',
    'AsyncCompletionExceptionStillCleansUp=True',
    'GuiClosingDuringQuotaQueryCleansUp=True',
    'StartupSendsAtMostOneQuery=True',
    'StartupUsesActiveProfile=True',
    'BackgroundWorkerImportsQuotaClient=True',
    'BackgroundWorkerImportsQuotaParser=True',
    'BackgroundWorkerHasQuotaPublicCommand=True',
    'BackgroundWorkerReturnsStructuredResult=True',
    'BackgroundWorkerFailureCodeSurvivesEndInvoke=True',
    'BackgroundWorkerDoesNotRequireCallerScopeModules=True',
    'WorkerOutputCountOne=True',
    'WorkerSnapshotSurvivesEndInvoke=True',
    'WorkerExecutableDiscoverySucceeded=True',
    'WorkerLockDiagnosticSurvives=True',
    'QUOTA_ASYNC_LIFECYCLE_SELFTEST_PASS'
)
$quotaAsync51 = Invoke-PowerShellFileTest `
    -HostPath $ps51Command.Source -ScriptPath $guiScriptPath `
    -AdditionalArguments @('-SelfTest', '-QuotaAsyncLifecycleSelfTest')
Assert-GuiTest -Condition (
    $quotaAsync51.ExitCode -eq 0 -and
    @($requiredQuotaAsyncOutputs | Where-Object {
        $quotaAsync51.Output -cnotcontains $_
    }).Count -eq 0
) -Code 'GUI_QUOTA_ASYNC_LIFECYCLE_PS51_FAILED'

$quotaAsync7 = Invoke-PowerShellFileTest `
    -HostPath $ps7Command.Source -ScriptPath $guiScriptPath `
    -AdditionalArguments @('-SelfTest', '-QuotaAsyncLifecycleSelfTest')
Assert-GuiTest -Condition (
    $quotaAsync7.ExitCode -eq 0 -and
    @($requiredQuotaAsyncOutputs | Where-Object {
        $quotaAsync7.Output -cnotcontains $_
    }).Count -eq 0
) -Code 'GUI_QUOTA_ASYNC_LIFECYCLE_PS7_FAILED'

$tempBase = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::GetTempPath()
).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
$foreignWorkingDirectory = [System.IO.Path]::GetFullPath(
    (Join-Path $tempBase (
        'qiehao-quota-foreign-cwd-' + [Guid]::NewGuid().ToString('N')
    ))
)
if (-not $foreignWorkingDirectory.StartsWith(
    $tempBase + [System.IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'GUI_FOREIGN_CWD_OUTSIDE_TEMP'
}
[System.IO.Directory]::CreateDirectory($foreignWorkingDirectory) | Out-Null
try {
    $foreignCwd51 = Invoke-PowerShellFileTest `
        -HostPath $ps51Command.Source -ScriptPath $guiScriptPath `
        -AdditionalArguments @('-SelfTest') `
        -WorkingDirectory $foreignWorkingDirectory
    Assert-GuiTest -Condition (
        $foreignCwd51.ExitCode -eq 0 -and
        $foreignCwd51.Output -ccontains 'QUOTA_RUNTIME_AVAILABLE=True' -and
        $foreignCwd51.Output -ccontains
            'QUOTA_REFRESH_BUTTON_ENABLED=True' -and
        $foreignCwd51.Output -ccontains 'GUI_SELFTEST_READY'
    ) -Code 'GUI_FOREIGN_CWD_PS51_FAILED'

    $foreignCwd7 = Invoke-PowerShellFileTest `
        -HostPath $ps7Command.Source -ScriptPath $guiScriptPath `
        -AdditionalArguments @('-SelfTest') `
        -WorkingDirectory $foreignWorkingDirectory
    Assert-GuiTest -Condition (
        $foreignCwd7.ExitCode -eq 0 -and
        $foreignCwd7.Output -ccontains 'QUOTA_RUNTIME_AVAILABLE=True' -and
        $foreignCwd7.Output -ccontains
            'QUOTA_REFRESH_BUTTON_ENABLED=True' -and
        $foreignCwd7.Output -ccontains 'GUI_SELFTEST_READY'
    ) -Code 'GUI_FOREIGN_CWD_PS7_FAILED'
}
finally {
    if ([System.IO.Directory]::Exists($foreignWorkingDirectory)) {
        [System.IO.Directory]::Delete($foreignWorkingDirectory, $true)
    }
}

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
        'ActiveBorderTint','RunningWarningTint','UnknownWarningTint',
        'ColumnHeaderBackgroundTint','ColumnHeaderForegroundTint',
        'ColumnHeaderBorderTint','CurrentYesTint','CurrentNoTint',
        'DangerTop','DangerBottom'
    )) {
        Assert-GuiTest -Condition (
            $null -ne $theme.PSObject.Properties[$requiredThemeProperty] -and
            -not [string]::IsNullOrWhiteSpace([string]$theme.$requiredThemeProperty)
        ) -Code ('GUI_THEME_GLASS_PROPERTY_MISSING_' + $theme.Id + '_' +
            $requiredThemeProperty)
    }
    $runningRed = [Convert]::ToInt32(
        ([string]$theme.RunningWarningTint).Substring(3, 2), 16
    )
    $runningGreen = [Convert]::ToInt32(
        ([string]$theme.RunningWarningTint).Substring(5, 2), 16
    )
    $runningBlue = [Convert]::ToInt32(
        ([string]$theme.RunningWarningTint).Substring(7, 2), 16
    )
    Assert-GuiTest -Condition (
        ([string]$theme.ColumnHeaderBackgroundTint).StartsWith('#FF') -and
        (Get-TestContrastRatio `
            -Foreground ([string]$theme.ColumnHeaderForegroundTint) `
            -Background ([string]$theme.ColumnHeaderBackgroundTint)) -ge 4.5 -and
        $runningRed -gt $runningGreen -and $runningRed -gt $runningBlue -and
        (Get-TestContrastRatio `
            -Foreground ([string]$theme.RunningWarningTint) `
            -Background ([string]$theme.CardTop)) -ge 4.5 -and
        (Get-TestContrastRatio `
            -Foreground ([string]$theme.RunningWarningTint) `
            -Background ([string]$theme.CardBottom)) -ge 4.5
    ) -Code ('GUI_THEME_SEMANTIC_CONTRAST_FAILED_' + $theme.Id)
    $dialogPalette = Get-QiehaoSwitchDialogPalette -Theme $theme
    foreach ($dialogProperty in @(
        'Background', 'CardTop', 'CardBottom', 'Border', 'Foreground',
        'Secondary', 'Accent', 'Warning', 'Success', 'ButtonBackground',
        'ButtonForeground', 'ButtonBorder'
    )) {
        Assert-GuiTest -Condition (
            $null -ne $dialogPalette.PSObject.Properties[$dialogProperty] -and
            [string]$dialogPalette.$dialogProperty -match '^#[0-9A-Fa-f]{8}$'
        ) -Code ('GUI_DIALOG_THEME_RESOURCE_MISSING_' + $theme.Id + '_' +
            $dialogProperty)
    }
    Assert-GuiTest -Condition (
        ([string]$dialogPalette.Background).StartsWith('#FF') -and
        (Get-TestContrastRatio -Foreground $dialogPalette.Foreground `
            -Background $dialogPalette.Background) -ge 4.5 -and
        (Get-TestContrastRatio -Foreground $dialogPalette.Warning `
            -Background $dialogPalette.Background) -ge 4.5 -and
        (Get-TestContrastRatio -Foreground $dialogPalette.Success `
            -Background $dialogPalette.Background) -ge 4.5 -and
        (Get-TestContrastRatio -Foreground $dialogPalette.ButtonForeground `
            -Background $dialogPalette.ButtonBackground) -ge 4.5
    ) -Code ('GUI_DIALOG_THEME_CONTRAST_FAILED_' + $theme.Id)
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

    $null = Write-QiehaoUiPreferences -StateDirectory $fakeStateDirectory `
        -Background '02-navy-gold'
    $preferencePath = Join-Path $fakeStateDirectory 'ui-preferences.json'
    [System.IO.File]::SetLastWriteTimeUtc(
        $preferencePath, [DateTime]::UtcNow.AddMinutes(-1)
    )
    $initialWriteTime = ([System.IO.FileInfo]$preferencePath).LastWriteTimeUtc
    $themeWindow = Read-TestWindow
    $themeSelectionHandler = $null
    $themeLoadedHandler = $null
    try {
        $themeCombo = $themeWindow.FindName('ThemeComboBox')
        $wpfThemes = @(Get-QiehaoBackgroundThemes)
        $themeCombo.ItemsSource = $wpfThemes
        $existingPreference = Read-QiehaoUiPreferences `
            -StateDirectory $fakeStateDirectory
        $startupTheme = @($wpfThemes | Where-Object {
            [string]$_.Id -ceq [string]$existingPreference.Background
        } | Select-Object -First 1)[0]
        $themeCombo.SelectedItem = $startupTheme
        $themeLifecycle = [pscustomobject]@{
            Ready = $false; HandlerCalls = 0; PersistCalls = 0
        }
        $themeSelectionHandler = {
            param($sender, $eventArgs)
            $themeLifecycle.HandlerCalls++
            if ($themeLifecycle.Ready -and $null -ne $sender.SelectedItem) {
                $themeLifecycle.PersistCalls++
                $null = Write-QiehaoUiPreferences `
                    -StateDirectory $fakeStateDirectory `
                    -Background ([string]$sender.SelectedItem.Id)
            }
        }.GetNewClosure()
        $themeCombo.Add_SelectionChanged($themeSelectionHandler)
        $iceTheme = @($wpfThemes | Where-Object {
            [string]$_.Id -ceq '03-ice-glass'
        } | Select-Object -First 1)[0]
        $themeCombo.SelectedItem = $iceTheme
        $beforeLoadedPreference = Read-QiehaoUiPreferences `
            -StateDirectory $fakeStateDirectory
        $themeCombo.SelectedItem = $startupTheme
        $themeLoadedHandler = {
            param($sender, $eventArgs)
            $themeLifecycle.Ready = $true
        }.GetNewClosure()
        $themeWindow.Add_Loaded($themeLoadedHandler)
        $themeWindow.RaiseEvent((New-Object System.Windows.RoutedEventArgs(
            [System.Windows.FrameworkElement]::LoadedEvent
        )))
        $themeCombo.SelectedItem = $iceTheme
        $immediatePreference = Read-QiehaoUiPreferences `
            -StateDirectory $fakeStateDirectory
        $immediateWriteTime = ([System.IO.FileInfo]$preferencePath).LastWriteTimeUtc
    }
    finally {
        if ($null -ne $themeSelectionHandler) {
            $themeCombo.Remove_SelectionChanged($themeSelectionHandler)
        }
        if ($null -ne $themeLoadedHandler) {
            $themeWindow.Remove_Loaded($themeLoadedHandler)
        }
        $themeWindow.Close()
    }
    $secondThemeWindow = Read-TestWindow
    try {
        $secondThemeCombo = $secondThemeWindow.FindName('ThemeComboBox')
        $secondThemes = @(Get-QiehaoBackgroundThemes)
        $secondThemeCombo.ItemsSource = $secondThemes
        $restoredPreference = Read-QiehaoUiPreferences `
            -StateDirectory $fakeStateDirectory
        $secondThemeCombo.SelectedItem = @($secondThemes | Where-Object {
            [string]$_.Id -ceq [string]$restoredPreference.Background
        } | Select-Object -First 1)[0]
        $secondSelectedThemeId = [string]$secondThemeCombo.SelectedItem.Id
    }
    finally { $secondThemeWindow.Close() }
    $preferenceData = ConvertFrom-Json -InputObject (
        [System.IO.File]::ReadAllText($preferencePath)
    )
    Assert-GuiTest -Condition (
        @($themeCombo.ItemsSource).Count -eq 5 -and
        [string]$startupTheme.Id -ceq '02-navy-gold' -and
        $beforeLoadedPreference.Background -ceq '02-navy-gold' -and
        $themeLifecycle.Ready -and $themeLifecycle.HandlerCalls -ge 3 -and
        $themeLifecycle.PersistCalls -eq 1 -and
        $immediatePreference.Background -ceq '03-ice-glass' -and
        $immediateWriteTime -gt $initialWriteTime -and
        $restoredPreference.Background -ceq '03-ice-glass' -and
        $secondSelectedThemeId -ceq '03-ice-glass' -and
        (@($preferenceData.PSObject.Properties.Name) -join '|') -ceq
            'schema_version|background' -and
        [int]$preferenceData.schema_version -eq 1
    ) -Code 'GUI_WPF_THEME_PERSISTENCE_LIFECYCLE_FAILED'

    $fakeProjectRoot = Join-Path $themeTestRoot 'project-from-any-cwd'
    $fakeGuiRoot = Join-Path $fakeProjectRoot 'gui'
    $otherWorkingDirectory = Join-Path $themeTestRoot 'other-working-directory'
    [System.IO.Directory]::CreateDirectory($fakeGuiRoot) | Out-Null
    [System.IO.Directory]::CreateDirectory($otherWorkingDirectory) | Out-Null
    $resolvedStateBefore = Resolve-QiehaoProjectStateDirectory `
        -GuiScriptRoot $fakeGuiRoot
    $null = Write-QiehaoUiPreferences `
        -StateDirectory $resolvedStateBefore -Background '02-navy-gold'
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

$beforeSwitchRows = New-FakeSnapshot -Profiles @(
    (New-FakeProfileRow -Name 'Plus'),
    (New-FakeProfileRow -Name 'Team')
) -Active 'Plus'
$afterSwitchRows = New-FakeSnapshot -Profiles @(
    (New-FakeProfileRow -Name 'Plus'),
    (New-FakeProfileRow -Name 'Team')
) -Active 'Team'
Assert-GuiTest -Condition (
    [string](@($beforeSwitchRows.Profiles | Where-Object {
        $_.Name -ceq 'Plus'
    })[0].Active) -ceq '是' -and
    [string](@($beforeSwitchRows.Profiles | Where-Object {
        $_.Name -ceq 'Team'
    })[0].Active) -ceq '否' -and
    [string](@($afterSwitchRows.Profiles | Where-Object {
        $_.Name -ceq 'Plus'
    })[0].Active) -ceq '否' -and
    [string](@($afterSwitchRows.Profiles | Where-Object {
        $_.Name -ceq 'Team'
    })[0].Active) -ceq '是'
) -Code 'GUI_ACTIVE_ROW_DID_NOT_MIGRATE_AFTER_REFRESH'

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

$runningFlow = [pscustomobject]@{ Wait=0; Switch=0; Target=''; Order=@() }
$runningSwitch = Invoke-QiehaoSwitchRequest -SelectedProfile 'Team' `
    -ActiveProfile 'Plus' `
    -ProcessProvider { [pscustomobject]@{ ReasonCode='CODEX_PROCESS_RUNNING' } } `
    -ManualWaitProvider ({
        param($TargetProfile)
        $runningFlow.Wait++
        $runningFlow.Target = $TargetProfile
        $runningFlow.Order += 'ManualWait'
    }.GetNewClosure()) `
    -SwitchProvider ({
        param($Name)
        $runningFlow.Switch++
        $runningFlow.Order += 'Switch'
        [pscustomobject]@{ Result='SWITCH_SUCCESS' }
    }.GetNewClosure())
Assert-GuiTest -Condition (
    $runningSwitch.WaitStarted -and -not $runningSwitch.CoreCalled -and
    $runningSwitch.ResultCode -ceq 'CODEX_MANUAL_EXIT_WAIT_STARTED' -and
    $runningFlow.Wait -eq 1 -and
    $runningFlow.Switch -eq 0 -and $runningFlow.Target -ceq 'Team' -and
    (@($runningFlow.Order) -join '|') -ceq 'ManualWait'
) -Code 'GUI_ONE_CLICK_MANUAL_WAIT_NOT_STARTED'

$failedWaitFlow = [pscustomobject]@{ Switch=0 }
$failedWait = Invoke-QiehaoSwitchRequest -SelectedProfile 'Team' `
    -ActiveProfile 'Plus' `
    -ProcessProvider { [pscustomobject]@{ ReasonCode='CODEX_PROCESS_RUNNING' } } `
    -ManualWaitProvider { throw 'FAKE_WAIT_START_FAILURE' } `
    -SwitchProvider ({ $failedWaitFlow.Switch++ }.GetNewClosure())
Assert-GuiTest -Condition (
    -not $failedWait.CoreCalled -and -not $failedWait.WaitStarted -and
    $failedWait.ResultCode -ceq 'CODEX_PROCESS_STATE_UNKNOWN' -and
    $failedWaitFlow.Switch -eq 0
) -Code 'GUI_MANUAL_WAIT_START_FAILURE_NOT_BLOCKED'

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
$waitingActions = Get-QiehaoActionState -SelectedProfile 'Team' `
    -ActiveProfile 'Plus' -CodexStatus '运行中' -IsWriteOperationBusy
$unavailableLaunchActions = Get-QiehaoActionState -SelectedProfile 'Team' `
    -ActiveProfile 'Plus' -CodexStatus '已退出' -LaunchTargetAvailable:$false
Assert-GuiTest -Condition (
    -not $activeStoppedActions.Switch -and
    -not $activeStoppedActions.ContextSwitch -and
    -not $activeStoppedActions.Delete -and
    -not $activeStoppedActions.ContextDelete -and
    $activeStoppedActions.Rename -and
    $activeStoppedActions.LaunchCodex -and
    $otherRunningActions.Switch -and
    -not $otherRunningActions.Verify -and
    -not $otherRunningActions.LaunchCodex -and
    $busyActions.Refresh -and
    -not $busyActions.Switch -and -not $busyActions.Add -and
    -not $busyActions.Rename -and -not $busyActions.Delete -and
    -not $busyActions.LaunchCodex -and
    -not $busyActions.ContextSwitch -and -not $busyActions.ContextRename -and
    -not $waitingActions.Switch -and -not $waitingActions.Verify -and
    -not $waitingActions.Add -and -not $waitingActions.Rename -and
    -not $waitingActions.Delete -and -not $waitingActions.LaunchCodex -and
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

function New-FakeNativeQuitElement {
    param(
        [string]$Name,
        [string]$AutomationId,
        [int]$ProcessId = 9101,
        [string]$ControlType = 'MenuItem',
        [bool]$IsEnabled = $true,
        [bool]$SupportsInvoke = $true,
        [bool]$IsMenuDescendant = $true
    )
    return [pscustomobject]@{
        Name = $Name
        AutomationId = $AutomationId
        ProcessId = $ProcessId
        ControlType = $ControlType
        IsEnabled = $IsEnabled
        SupportsInvoke = $SupportsInvoke
        IsMenuDescendant = $IsMenuDescendant
    }
}

$stableIdCapture = [pscustomobject]@{ Invokes=0; Name='' }
$stableIdQuit = Request-CodexDesktopNativeQuit `
    -ProcessData $runningCodexSnapshot `
    -AutomationSnapshotProvider {
        param($WindowHandle, $ExpectedProcessId)
        [pscustomobject]@{
            Available = $true
            Elements = @(New-FakeNativeQuitElement `
                -Name 'Localized application command' `
                -AutomationId 'app.quit' -ProcessId $ExpectedProcessId)
            CleanupAction = $null
        }
    } `
    -AutomationInvokeProvider ({
        param($Element)
        $stableIdCapture.Invokes++
        $stableIdCapture.Name = [string]$Element.Name
        return $true
    }.GetNewClosure())
Assert-GuiTest -Condition (
    $stableIdQuit.Result -ceq 'CODEX_NATIVE_QUIT_REQUESTED' -and
    $stableIdQuit.NativeQuitTargetFound -and
    $stableIdQuit.NativeQuitMethod -ceq 'AutomationId' -and
    $stableIdQuit.NativeQuitInvokeResult -ceq 'requested' -and
    $stableIdCapture.Invokes -eq 1
) -Code 'GUI_NATIVE_QUIT_AUTOMATION_ID_FAILED'

$englishCapture = [pscustomobject]@{ Invokes=0 }
$englishQuit = Request-CodexDesktopNativeQuit `
    -ProcessData $runningCodexSnapshot `
    -AutomationSnapshotProvider {
        param($WindowHandle, $ExpectedProcessId)
        [pscustomobject]@{
            Available = $true
            Elements = @(New-FakeNativeQuitElement `
                -Name 'Exit' -AutomationId '' -ProcessId $ExpectedProcessId)
            CleanupAction = $null
        }
    } `
    -AutomationInvokeProvider ({
        param($Element)
        $englishCapture.Invokes++
        return $true
    }.GetNewClosure())
Assert-GuiTest -Condition (
    $englishQuit.Result -ceq 'CODEX_NATIVE_QUIT_REQUESTED' -and
    $englishQuit.NativeQuitMethod -ceq 'Name' -and
    $englishCapture.Invokes -eq 1
) -Code 'GUI_NATIVE_QUIT_ENGLISH_EXIT_FAILED'

$chineseCapture = [pscustomobject]@{ Invokes=0 }
$chineseQuit = Request-CodexDesktopNativeQuit `
    -ProcessData $runningCodexSnapshot `
    -AutomationSnapshotProvider {
        param($WindowHandle, $ExpectedProcessId)
        [pscustomobject]@{
            Available = $true
            Elements = @(New-FakeNativeQuitElement `
                -Name '退出 Codex' -AutomationId '' `
                -ProcessId $ExpectedProcessId)
            CleanupAction = $null
        }
    } `
    -AutomationInvokeProvider ({
        param($Element)
        $chineseCapture.Invokes++
        return $true
    }.GetNewClosure())
Assert-GuiTest -Condition (
    $chineseQuit.Result -ceq 'CODEX_NATIVE_QUIT_REQUESTED' -and
    $chineseQuit.NativeQuitMethod -ceq 'Name' -and
    $chineseCapture.Invokes -eq 1
) -Code 'GUI_NATIVE_QUIT_CHINESE_EXIT_FAILED'

$missingQuitCapture = [pscustomobject]@{ Invokes=0 }
$missingQuit = Request-CodexDesktopNativeQuit `
    -ProcessData $runningCodexSnapshot `
    -AutomationSnapshotProvider {
        param($WindowHandle, $ExpectedProcessId)
        [pscustomobject]@{
            Available = $true
            Elements = @(New-FakeNativeQuitElement `
                -Name 'New Window' -AutomationId 'newWindow' `
                -ProcessId $ExpectedProcessId)
            CleanupAction = $null
        }
    } `
    -AutomationInvokeProvider ({
        param($Element)
        $missingQuitCapture.Invokes++
        return $true
    }.GetNewClosure())
Assert-GuiTest -Condition (
    $missingQuit.Result -ceq 'CODEX_NATIVE_QUIT_UI_NOT_FOUND' -and
    $missingQuit.NativeQuitTargetFound -and
    $missingQuit.NativeQuitMethod -ceq 'None' -and
    $missingQuitCapture.Invokes -eq 0
) -Code 'GUI_NATIVE_QUIT_MISSING_MENU_UNSAFE_FALLBACK'

$invokeFailureCapture = [pscustomobject]@{ Invokes=0; ManagerAlive=$true }
$invokeFailure = Request-CodexDesktopNativeQuit `
    -ProcessData $runningCodexSnapshot `
    -AutomationSnapshotProvider {
        param($WindowHandle, $ExpectedProcessId)
        [pscustomobject]@{
            Available = $true
            Elements = @(New-FakeNativeQuitElement `
                -Name 'Quit Codex' -AutomationId '' `
                -ProcessId $ExpectedProcessId)
            CleanupAction = $null
        }
    } `
    -AutomationInvokeProvider ({
        param($Element)
        $invokeFailureCapture.Invokes++
        throw 'FAKE_UIA_SENSITIVE_DETAIL'
    }.GetNewClosure())
Assert-GuiTest -Condition (
    $invokeFailure.Result -ceq 'CODEX_NATIVE_QUIT_INVOKE_FAILED' -and
    $invokeFailure.NativeQuitInvokeResult -ceq 'failed' -and
    $invokeFailure.NativeQuitMethod -ceq 'Name' -and
    $invokeFailureCapture.Invokes -eq 1 -and
    $invokeFailureCapture.ManagerAlive -and
    (ConvertTo-QiehaoExitMessage -ResultCode $invokeFailure.Result) `
        -notmatch 'FAKE_UIA_SENSITIVE_DETAIL'
) -Code 'GUI_NATIVE_QUIT_INVOKE_EXCEPTION_ESCAPED'

$unsafeNativeCapture = [pscustomobject]@{ Snapshots=0; Invokes=0 }
$unsafeNativeQuit = Request-CodexDesktopNativeQuit -CallerProcessId 9401 `
    -ProcessData @(
        [pscustomobject]@{
            ProcessName='ChatGPT.exe'; Id=9401
            ExecutablePath=$nativeCodexPath; PathReadStatus='Readable'
            ParentProcessId=0; ParentReadStatus='Readable'
            MainWindowHandle=44001; MainWindowOwnerProcessId=9401
        },
        [pscustomobject]@{
            ProcessName='ChatGPT.exe'; Id=9402
            ExecutablePath='C:\Fake\Unrelated\ChatGPT.exe'
            PathReadStatus='Readable'; ParentProcessId=0
            ParentReadStatus='Readable'; MainWindowHandle=44002
            MainWindowOwnerProcessId=9402
        }
    ) `
    -AutomationSnapshotProvider ({
        $unsafeNativeCapture.Snapshots++
        throw 'UNSAFE_TARGET_REACHED_UIA'
    }.GetNewClosure()) `
    -AutomationInvokeProvider ({
        $unsafeNativeCapture.Invokes++
        return $true
    }.GetNewClosure())
Assert-GuiTest -Condition (
    $unsafeNativeQuit.Result -ceq 'CODEX_NATIVE_QUIT_UI_NOT_FOUND' -and
    -not $unsafeNativeQuit.NativeQuitTargetFound -and
    $unsafeNativeCapture.Snapshots -eq 0 -and
    $unsafeNativeCapture.Invokes -eq 0
) -Code 'GUI_NATIVE_QUIT_SELF_OR_UNOFFICIAL_TARGETED'

$browserNativeCapture = [pscustomobject]@{ Snapshots=0; Invokes=0 }
$browserNativeQuit = Request-CodexDesktopNativeQuit -ProcessData @(
    [pscustomobject]@{
        ProcessName='extension-host.exe'; Id=9451
        ExecutablePath=$extensionHostPath; PathReadStatus='Readable'
        ParentProcessId=9452; ParentReadStatus='Readable'
        MainWindowHandle=44501; MainWindowOwnerProcessId=9451
    },
    [pscustomobject]@{
        ProcessName='chrome.exe'; Id=9452
        ExecutablePath='C:\Program Files\Google\Chrome\Application\chrome.exe'
        PathReadStatus='Readable'; ParentProcessId=0
        ParentReadStatus='Readable'; MainWindowHandle=44502
        MainWindowOwnerProcessId=9452
    }
) -AutomationSnapshotProvider ({
    $browserNativeCapture.Snapshots++
    throw 'BROWSER_REACHED_UIA'
}.GetNewClosure()) -AutomationInvokeProvider ({
    $browserNativeCapture.Invokes++
    return $true
}.GetNewClosure())
Assert-GuiTest -Condition (
    $browserNativeQuit.Result -ceq 'CODEX_ALREADY_STOPPED' -and
    $browserNativeCapture.Snapshots -eq 0 -and
    $browserNativeCapture.Invokes -eq 0
) -Code 'GUI_NATIVE_QUIT_BROWSER_EXTENSION_TARGETED'

$closeCapture = [pscustomobject]@{ Count=0; LastPid=0; Order=@() }
$closeRequested = Request-CodexDesktopClose `
    -ProcessData $runningCodexSnapshot -CloseMainWindowAction ({
        param($ProcessItem)
        $closeCapture.Order += 'CloseMainWindow'
        $closeCapture.Count++
        $closeCapture.LastPid = [int]$ProcessItem.Id
        return $true
    }.GetNewClosure())
if ($closeRequested.Result -ceq 'CODEX_CLOSE_REQUESTED') {
    $closeCapture.Order += 'WaitTimer'
}
Assert-GuiTest -Condition (
    $closeRequested.Result -ceq 'CODEX_CLOSE_REQUESTED' -and
    $closeRequested.CloseRequested -and
    $closeRequested.AttemptedCount -eq 1 -and
    $closeRequested.RequestedCount -eq 1 -and
    $closeRequested.FailedCount -eq 0 -and
    $closeCapture.Count -eq 1 -and
    $closeCapture.LastPid -eq 9101 -and
    (@($closeCapture.Order) -join '|') -ceq 'CloseMainWindow|WaitTimer'
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
$falseCloseCalls = [pscustomobject]@{ Count=0 }
$falseCloseResult = Request-CodexDesktopClose `
    -ProcessData $runningCodexSnapshot -CloseMainWindowAction ({
        param($ProcessItem)
        $falseCloseCalls.Count++
        return $false
    }.GetNewClosure())
Assert-GuiTest -Condition (
    $falseCloseResult.Result -ceq 'CODEX_CLOSE_REQUEST_FAILED' -and
    -not $falseCloseResult.CloseRequested -and
    $falseCloseResult.AttemptedCount -eq 1 -and
    $falseCloseResult.RequestedCount -eq 0 -and
    $falseCloseResult.FailedCount -eq 1 -and
    $falseCloseCalls.Count -eq 1
) -Code 'GUI_CLOSE_MAIN_WINDOW_FALSE_NOT_REPORTED'

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
    $failedNormalExit.Result -ceq 'CODEX_CLOSE_REQUEST_FAILED' -and
    -not $failedNormalExit.CloseRequested -and
    $failedNormalExit.AttemptedCount -eq 1 -and
    $failedNormalExit.FailedCount -eq 1 -and
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

function New-TestWaitRuntime {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ProbeProvider,

        [double]$TimeoutSeconds = 1,

        [double]$MilestoneSeconds = 0,

        [scriptblock]$MilestoneAction,

        [scriptblock]$ClockProvider = { [DateTime]::UtcNow }
    )

    $guiState = [pscustomobject]@{
        Busy = $true
        Recoverable = $false
        CompletionResult = ''
    }
    $completion = {
        param($Result, $Runtime)
        $guiState.Busy = $false
        $guiState.Recoverable = $true
        $guiState.CompletionResult = $Result
    }.GetNewClosure()
    $runtime = New-QiehaoWaitTimerRuntime `
        -IntervalMilliseconds 10 -TimeoutSeconds $TimeoutSeconds `
        -MilestoneSeconds $MilestoneSeconds `
        -MilestoneAction $MilestoneAction -ClockProvider $ClockProvider `
        -ProbeProvider $ProbeProvider -CompletionAction $completion
    $null = Start-QiehaoWaitTimerRuntime -Runtime $runtime
    return [pscustomobject]@{ Runtime = $runtime; Gui = $guiState }
}

$runningThenStopped = [pscustomobject]@{ Calls = 0 }
$successWait = New-TestWaitRuntime -ProbeProvider ({
    $runningThenStopped.Calls++
    if ($runningThenStopped.Calls -ge 2) { return 'Succeeded' }
    return 'Pending'
}.GetNewClosure())
Invoke-TestDispatcherFor -Milliseconds 100
$successTicksAfterStop = $successWait.Runtime.TickCount
Invoke-TestDispatcherFor -Milliseconds 30
Assert-GuiTest -Condition (
    $successWait.Runtime.StartedAt -is [DateTime] -and
    $successWait.Runtime.Result -ceq 'Succeeded' -and
    $successWait.Runtime.TickCount -ge 2 -and
    $successWait.Runtime.TickCount -eq $successTicksAfterStop -and
    $successWait.Runtime.Stopped -and
    $successWait.Runtime.HandlerRemoved -and
    -not $successWait.Runtime.Active -and
    -not $successWait.Gui.Busy -and $successWait.Gui.Recoverable
) -Code 'GUI_REAL_TIMER_RUNNING_TO_STOPPED_FAILED'

$phaseClock = [pscustomobject]@{ Now=[DateTime]::UtcNow }
$phaseCapture = [pscustomobject]@{ Milestones=0; LastElapsed=0 }
$phaseWait = New-TestWaitRuntime -TimeoutSeconds 8 -MilestoneSeconds 5 `
    -ClockProvider ({ $phaseClock.Now }.GetNewClosure()) `
    -MilestoneAction ({
        param($Runtime)
        $phaseCapture.Milestones++
        $phaseCapture.LastElapsed = [int]$Runtime.ElapsedMilliseconds
    }.GetNewClosure()) -ProbeProvider { 'Pending' }
$phaseClock.Now = $phaseClock.Now.AddSeconds(5.1)
Invoke-TestDispatcherFor -Milliseconds 30
Assert-GuiTest -Condition (
    $phaseWait.Runtime.Active -and $phaseWait.Runtime.MilestoneReached -and
    $phaseCapture.Milestones -eq 1 -and
    $phaseWait.Runtime.ElapsedMilliseconds -ge 5000 -and
    $phaseWait.Gui.Busy
) -Code 'GUI_EXIT_WAIT_FIVE_SECOND_MILESTONE_FAILED'
$phaseClock.Now = $phaseClock.Now.AddSeconds(3)
Invoke-TestDispatcherFor -Milliseconds 30
Assert-GuiTest -Condition (
    $phaseWait.Runtime.Result -ceq 'TimedOut' -and
    $phaseWait.Runtime.ElapsedMilliseconds -ge 8000 -and
    $phaseCapture.Milestones -eq 1 -and
    $phaseWait.Runtime.Stopped -and
    $phaseWait.Runtime.HandlerRemoved -and
    -not $phaseWait.Runtime.Active -and
    -not $phaseWait.Gui.Busy -and $phaseWait.Gui.Recoverable
) -Code 'GUI_EXIT_WAIT_EIGHT_SECOND_HARD_TIMEOUT_FAILED'

$timeoutWait = New-TestWaitRuntime -TimeoutSeconds 0.03 `
    -ProbeProvider { 'Pending' }
Invoke-TestDispatcherFor -Milliseconds 100
Assert-GuiTest -Condition (
    $timeoutWait.Runtime.Result -ceq 'TimedOut' -and
    $timeoutWait.Runtime.TickCount -ge 1 -and
    $timeoutWait.Runtime.Stopped -and
    $timeoutWait.Runtime.HandlerRemoved -and
    -not $timeoutWait.Runtime.Active -and
    -not $timeoutWait.Gui.Busy -and $timeoutWait.Gui.Recoverable
) -Code 'GUI_REAL_TIMER_TIMEOUT_CLEANUP_FAILED'

$errorWait = New-TestWaitRuntime -ProbeProvider {
    throw 'FAKE_PROCESS_PROVIDER_FAILURE'
}
Invoke-TestDispatcherFor -Milliseconds 50
Assert-GuiTest -Condition (
    $errorWait.Runtime.Result -ceq 'Error' -and
    $errorWait.Runtime.CallbackFailed -and
    $errorWait.Runtime.Stopped -and
    $errorWait.Runtime.HandlerRemoved -and
    -not $errorWait.Runtime.Active -and
    -not $errorWait.Gui.Busy -and $errorWait.Gui.Recoverable
) -Code 'GUI_REAL_TIMER_CALLBACK_EXCEPTION_ESCAPED'

$closingWait = New-TestWaitRuntime -TimeoutSeconds 1 `
    -ProbeProvider { 'Pending' }
Invoke-TestDispatcherFor -Milliseconds 30
$closingTicksBeforeStop = $closingWait.Runtime.TickCount
$closingCleanup = Stop-QiehaoWaitTimerRuntime `
    -Runtime $closingWait.Runtime -Result 'WindowClosing'
$closingWait.Gui.Busy = $false
$closingWait.Gui.Recoverable = $true
Invoke-TestDispatcherFor -Milliseconds 30
Assert-GuiTest -Condition (
    $closingTicksBeforeStop -ge 1 -and
    $closingWait.Runtime.Result -ceq 'WindowClosing' -and
    $closingCleanup.Stopped -and $closingCleanup.HandlerRemoved -and
    $closingWait.Runtime.TickCount -eq $closingTicksBeforeStop -and
    -not $closingWait.Runtime.Active -and
    -not $closingWait.Gui.Busy -and $closingWait.Gui.Recoverable
) -Code 'GUI_REAL_TIMER_WINDOW_CLOSE_CLEANUP_FAILED'

function New-TestManualSwitchRuntime {
    param(
        [ValidateSet('Running', 'Stopped', 'Unknown')]
        [string]$InitialStatus = 'Running',
        [double]$TimeoutSeconds = 1
    )
    $manualState = [pscustomobject]@{
        Status = $InitialStatus
        Busy = $true
        PendingAction = 'Switch'
        PendingTarget = 'Team'
        SwitchCalls = 0
        Result = 'Pending'
        CleanupBeforeSwitch = $false
        WaitWindowOpen = $true
        SwitchSawWaitWindowOpen = $false
        RefreshCalls = 0
        ActiveProfile = 'Plus'
        PlusCurrent = '是'
        PlusActive = $true
        TeamCurrent = '否'
        TeamActive = $false
        UiState = 'WaitingForCodexExit'
        NotificationPreconditions = $false
        SuccessMessage = ''
        Order = @()
        Runtime = $null
    }
    $probe = {
        switch ($manualState.Status) {
            'Stopped' { return 'Succeeded' }
            'Unknown' { return 'Unknown' }
            default { return 'Pending' }
        }
    }.GetNewClosure()
    $completion = {
        param($Result, $Runtime)
        $manualState.Result = $Result
        $manualState.PendingAction = $null
        $manualState.PendingTarget = $null
        if ($Result -ceq 'Succeeded') {
            $manualState.CleanupBeforeSwitch =
                [bool]$Runtime.Stopped -and [bool]$Runtime.HandlerRemoved -and
                $null -eq $manualState.PendingAction -and
                $null -eq $manualState.PendingTarget
            $manualState.SwitchSawWaitWindowOpen = $manualState.WaitWindowOpen
            $manualState.SwitchCalls++
            $manualState.Order += 'Switch'
            $manualState.RefreshCalls++
            $manualState.ActiveProfile = 'Team'
            $manualState.PlusCurrent = '否'
            $manualState.PlusActive = $false
            $manualState.TeamCurrent = '是'
            $manualState.TeamActive = $true
            $manualState.Order += 'Refresh'
            $manualState.Busy = $false
            $manualState.Order += 'BusyFalse'
            $manualState.UiState = 'SwitchSucceeded'
            $manualState.Order += 'State:SwitchSucceeded'
            $manualState.NotificationPreconditions = (
                $manualState.ActiveProfile -ceq 'Team' -and
                $manualState.TeamCurrent -ceq '是' -and
                $manualState.TeamActive -and
                $manualState.PlusCurrent -ceq '否' -and
                -not $manualState.PlusActive -and
                $manualState.UiState -ceq 'SwitchSucceeded' -and
                -not $manualState.Busy
            )
            $manualState.WaitWindowOpen = $false
            $manualState.Order += 'WindowClosed'
            $manualState.SuccessMessage =
                '切换成功。' + [Environment]::NewLine + '当前账号：Team'
            $manualState.Order += 'Success'
        }
        else {
            $manualState.Busy = $false
            $manualState.WaitWindowOpen = $false
        }
    }.GetNewClosure()
    $manualState.Runtime = New-QiehaoWaitTimerRuntime `
        -IntervalMilliseconds 10 -TimeoutSeconds $TimeoutSeconds `
        -ProbeProvider $probe -CompletionAction $completion
    $null = Start-QiehaoWaitTimerRuntime -Runtime $manualState.Runtime
    return $manualState
}

function Stop-TestManualSwitchRuntime {
    param(
        [Parameter(Mandatory = $true)][object]$State,
        [Parameter(Mandatory = $true)][string]$Result
    )
    $cleanup = Stop-QiehaoWaitTimerRuntime -Runtime $State.Runtime -Result $Result
    $State.Result = $Result
    $State.PendingAction = $null
    $State.PendingTarget = $null
    $State.Busy = $false
    $State.WaitWindowOpen = $false
    return $cleanup
}

$manualStoppedWait = New-TestManualSwitchRuntime
Invoke-TestDispatcherFor -Milliseconds 35
Assert-GuiTest -Condition (
    $manualStoppedWait.Runtime.Active -and
    $manualStoppedWait.SwitchCalls -eq 0 -and
    $manualStoppedWait.PendingAction -ceq 'Switch' -and
    $manualStoppedWait.PendingTarget -ceq 'Team' -and
    $manualStoppedWait.Busy
) -Code 'GUI_MANUAL_WAIT_SWITCHED_WHILE_RUNNING'
$manualStoppedWait.Status = 'Stopped'
Invoke-TestDispatcherFor -Milliseconds 35
Assert-GuiTest -Condition (
    $manualStoppedWait.Result -ceq 'Succeeded' -and
    $manualStoppedWait.SwitchCalls -eq 1 -and
    $manualStoppedWait.CleanupBeforeSwitch -and
    $manualStoppedWait.SwitchSawWaitWindowOpen -and
    -not $manualStoppedWait.WaitWindowOpen -and
    $manualStoppedWait.RefreshCalls -eq 1 -and
    $manualStoppedWait.ActiveProfile -ceq 'Team' -and
    $manualStoppedWait.PlusCurrent -ceq '否' -and
    -not $manualStoppedWait.PlusActive -and
    $manualStoppedWait.TeamCurrent -ceq '是' -and
    $manualStoppedWait.TeamActive -and
    $manualStoppedWait.UiState -ceq 'SwitchSucceeded' -and
    $manualStoppedWait.NotificationPreconditions -and
    $manualStoppedWait.SuccessMessage -match '当前账号：Team' -and
    (@($manualStoppedWait.Order) -join '|') -ceq
        'Switch|Refresh|BusyFalse|State:SwitchSucceeded|WindowClosed|Success' -and
    $manualStoppedWait.Runtime.Stopped -and
    $manualStoppedWait.Runtime.HandlerRemoved -and
    -not $manualStoppedWait.Runtime.Active -and
    $null -eq $manualStoppedWait.PendingAction -and
    $null -eq $manualStoppedWait.PendingTarget -and
    -not $manualStoppedWait.Busy
) -Code 'GUI_MANUAL_WAIT_STOPPED_DID_NOT_SWITCH_ONCE'

$manualUnknownWait = New-TestManualSwitchRuntime
Invoke-TestDispatcherFor -Milliseconds 20
$manualUnknownWait.Status = 'Unknown'
Invoke-TestDispatcherFor -Milliseconds 30
Assert-GuiTest -Condition (
    $manualUnknownWait.Result -ceq 'Unknown' -and
    $manualUnknownWait.SwitchCalls -eq 0 -and
    $manualUnknownWait.Runtime.Stopped -and
    $manualUnknownWait.Runtime.HandlerRemoved -and
    $null -eq $manualUnknownWait.PendingAction -and
    $null -eq $manualUnknownWait.PendingTarget -and
    -not $manualUnknownWait.WaitWindowOpen -and
    -not $manualUnknownWait.Busy
) -Code 'GUI_MANUAL_WAIT_UNKNOWN_DID_NOT_FAIL_CLOSED'

$manualTimeoutWait = New-TestManualSwitchRuntime -TimeoutSeconds 0.03
Invoke-TestDispatcherFor -Milliseconds 100
Assert-GuiTest -Condition (
    $manualTimeoutWait.Result -ceq 'TimedOut' -and
    $manualTimeoutWait.SwitchCalls -eq 0 -and
    $manualTimeoutWait.Runtime.Stopped -and
    $manualTimeoutWait.Runtime.HandlerRemoved -and
    $null -eq $manualTimeoutWait.PendingAction -and
    $null -eq $manualTimeoutWait.PendingTarget -and
    -not $manualTimeoutWait.WaitWindowOpen -and
    -not $manualTimeoutWait.Busy
) -Code 'GUI_MANUAL_WAIT_TIMEOUT_DID_NOT_CLEANUP'

$manualCancelledWait = New-TestManualSwitchRuntime
Invoke-TestDispatcherFor -Milliseconds 20
$manualCancelCleanup = Stop-TestManualSwitchRuntime `
    -State $manualCancelledWait -Result 'Cancelled'
Invoke-TestDispatcherFor -Milliseconds 30
Assert-GuiTest -Condition (
    $manualCancelledWait.Result -ceq 'Cancelled' -and
    $manualCancelledWait.SwitchCalls -eq 0 -and
    $manualCancelCleanup.Stopped -and $manualCancelCleanup.HandlerRemoved -and
    $null -eq $manualCancelledWait.PendingAction -and
    $null -eq $manualCancelledWait.PendingTarget -and
    -not $manualCancelledWait.WaitWindowOpen -and
    -not $manualCancelledWait.Busy
) -Code 'GUI_MANUAL_WAIT_CANCEL_DID_NOT_CLEANUP'

$manualClosingWait = New-TestManualSwitchRuntime
Invoke-TestDispatcherFor -Milliseconds 20
$manualCloseCleanup = Stop-TestManualSwitchRuntime `
    -State $manualClosingWait -Result 'WindowClosing'
$manualCloseTicks = $manualClosingWait.Runtime.TickCount
Invoke-TestDispatcherFor -Milliseconds 30
Assert-GuiTest -Condition (
    $manualClosingWait.Result -ceq 'WindowClosing' -and
    $manualClosingWait.SwitchCalls -eq 0 -and
    $manualCloseCleanup.Stopped -and $manualCloseCleanup.HandlerRemoved -and
    $manualClosingWait.Runtime.TickCount -eq $manualCloseTicks -and
    $null -eq $manualClosingWait.PendingAction -and
    $null -eq $manualClosingWait.PendingTarget -and
    -not $manualClosingWait.WaitWindowOpen -and
    -not $manualClosingWait.Busy
) -Code 'GUI_MANUAL_WAIT_WINDOW_CLOSE_DID_NOT_CLEANUP'

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
    '正在检测 Codex 进程状态……'
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

foreach ($phaseTwoButtonName in @('VerifyButton', 'LaunchCodexButton')) {
    $phaseTwoNode = $xamlDocument.SelectSingleNode(
        "//*[@x:Name='$phaseTwoButtonName']",
        $namespaceManager
    )
    Assert-GuiTest -Condition (
        $null -ne $phaseTwoNode -and
        $phaseTwoNode.GetAttribute('IsEnabled') -ceq 'False'
    ) -Code ('GUI_PHASE_TWO_BUTTON_INITIAL_STATE_INVALID_' + $phaseTwoButtonName)
}
Assert-GuiTest -Condition (
    $null -eq $xamlDocument.SelectSingleNode(
        "//*[@x:Name='ExitCodexButton']", $namespaceManager
    ) -and
    $null -ne $xamlDocument.SelectSingleNode(
        "//*[@x:Name='CodexSafetyHintText']", $namespaceManager
    ) -and
    $null -eq $xamlDocument.SelectSingleNode(
        "//*[@x:Name='CancelSwitchWaitButton']", $namespaceManager
    )
) -Code 'GUI_MANUAL_QUIT_CONTROLS_INVALID'

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
    $xamlTextForEncoding -match 'DynamicResource SelectedRowBrush' -and
    $xamlTextForEncoding -match 'DynamicResource ActiveBorderBrush' -and
    $xamlTextForEncoding -match 'MultiDataTrigger' -and
    $xamlTextForEncoding -match 'BorderThickness" Value="4,0,1,0"' -and
    $xamlTextForEncoding -match 'TargetType="DataGridColumnHeader"' -and
    $xamlTextForEncoding -match 'DynamicResource ColumnHeaderBackgroundBrush' -and
    $xamlTextForEncoding -match 'DynamicResource ColumnHeaderForegroundBrush' -and
    $xamlTextForEncoding -match 'DynamicResource ColumnHeaderBorderBrush' -and
    $xamlTextForEncoding -match 'Property="VerticalContentAlignment" Value="Center"' -and
    $xamlTextForEncoding -match 'DynamicResource CurrentYesBrush' -and
    $xamlTextForEncoding -match 'DynamicResource CurrentNoBrush'
) -Code 'GUI_GLASS_OR_ACTIVE_ROW_STYLE_MISSING'

$coreAndGuiSource = $guiSource + [System.IO.File]::ReadAllText($coreModulePath)
Assert-GuiTest -Condition (
    $coreAndGuiSource -notmatch '(?i)Stop-Process\b|taskkill\b|TerminateProcess\b|\.Kill\s*\('
) -Code 'GUI_FORCE_TERMINATION_API_PRESENT'
Assert-GuiTest -Condition (
    $guiSource -match 'Test-CodexProfile' -and
    $guiSource -match 'Start-QiehaoManualSwitchWaitTimer' -and
    $guiSource -match 'Show-QiehaoManualSwitchWaitDialog' -and
    $guiSource -match 'Cancel-QiehaoManualSwitchWait' -and
    $guiSource -match 'DispatcherTimer' -and
    $guiSource -match 'Invoke-QiehaoReadOnlyRefresh' -and
    $guiSource -match 'guiIsWriteOperationBusy'
) -Code 'GUI_OPERATION_WIRING_MISSING'

$quotaAsyncSourceSection = [regex]::Match(
    $guiSource,
    '(?s)function Stop-QiehaoQuotaCompletionTimer.*?function Invoke-QiehaoQuotaBeforeSwitch'
).Value
Assert-GuiTest -Condition (
    -not [string]::IsNullOrWhiteSpace($quotaAsyncSourceSection) -and
    $quotaAsyncSourceSection -match 'Remove_Tick' -and
    $quotaAsyncSourceSection -match 'EndInvoke' -and
    $quotaAsyncSourceSection -match 'finally' -and
    $quotaAsyncSourceSection -match
        'guiQuotaCoordinator\.QueryInProgress = \$false' -and
    $quotaAsyncSourceSection -match 'AddMilliseconds\(' -and
    $quotaAsyncSourceSection -match 'else \{ 15000 \}' -and
    $quotaAsyncSourceSection -match
        'Invoke-QiehaoQuotaBackgroundWorker -TimeoutSeconds 10' -and
    $quotaAsyncSourceSection -match
        '\$script:guiQuotaWorkerOutputCount = \$output\.Count' -and
    $quotaAsyncSourceSection -match '\$output\.Count -eq 1' -and
    $quotaAsyncSourceSection -match
        'Format-QiehaoQuotaFailureStatus' -and
    $quotaAsyncSourceSection -match
        'Get-QiehaoQuotaUiTextSafe -Key ''UpdateFailedRetry''' -and
    $quotaAsyncSourceSection -notmatch
        'Get-QiehaoCurrentQuotaSnapshot -TimeoutSeconds 10' -and
    $quotaAsyncSourceSection -notmatch 'GetNewClosure'
) -Code 'GUI_QUOTA_ASYNC_SOURCE_LIFECYCLE_INVALID'
Assert-GuiTest -Condition (
    $guiSource -match 'Codex 已安全退出，可以切换账号。' -and
    $guiSource -match '文件 → 退出' -and
    $guiSource -match '无法确认 Codex 是否完全退出，请先检查 Codex 状态'
) -Code 'GUI_DYNAMIC_SAFE_EXIT_HINTS_MISSING'

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
        'IntervalMilliseconds 500')).Count -eq 2 -and
    ([regex]::Matches($timerWaitAndCloseSection,
        'TimeoutSeconds 10')).Count -eq 1 -and
    ([regex]::Matches($timerWaitAndCloseSection,
        'TimeoutSeconds = 90')).Count -eq 2 -and
    $timerWaitAndCloseSection -match 'guiPendingAction = ''Switch''' -and
    $timerWaitAndCloseSection -match 'guiPendingTargetProfile = \$TargetProfile' -and
    $timerWaitAndCloseSection -match 'Stop-QiehaoProcessMonitor' -and
    $timerWaitAndCloseSection -match 'Start-QiehaoProcessMonitor' -and
    $timerWaitAndCloseSection -match 'Add_Closing\(\{ Stop-QiehaoAllTimers \}\)' -and
    $timerWaitAndCloseSection -match 'Add_Closed\(' -and
    $timerWaitAndCloseSection -notmatch '\$startedAt' -and
    $helperSource -match 'Remove_Tick' -and
    $helperSource -match '\$state\.StartedAt' -and
    $helperSource -match 'GetNewClosure' -and
    $helperSource -match "finalize 'Error'" -and
    $guiSource -match 'guiIsClosing'
) -Code 'GUI_TIMER_WAIT_OR_WINDOW_CLOSE_CLEANUP_MISSING'

Assert-GuiTest -Condition (
    $guiSource -match 'Resolve-QiehaoProjectStateDirectory -GuiScriptRoot \$guiRoot' -and
    $guiSource -match '\$themeComboBox\.SelectedItem = \$startupTheme' -and
    $guiSource -match 'guiThemePersistenceReady' -and
    $guiSource -match 'Set-QiehaoTheme -Theme \$selectedTheme -Persist' -and
    $helperSource -match 'File\]::Replace' -and
    $helperSource -match 'NullString\]::Value'
) -Code 'GUI_PREF_OR_MANUAL_WAIT_WIRING_MISSING'

$manualWaitSection = [regex]::Match(
    $guiSource,
    '(?s)function Complete-QiehaoManualSwitchWait\s*\{.*?function Invoke-QiehaoSwitchCore'
).Value
Assert-GuiTest -Condition (
    -not [string]::IsNullOrWhiteSpace($manualWaitSection) -and
    $manualWaitSection -match 'IntervalMilliseconds 500' -and
    $manualWaitSection -match 'TimeoutSeconds \$TimeoutSeconds' -and
    $manualWaitSection -match 'Test-CodexProcessesStopped' -and
    $manualWaitSection -match 'Invoke-QiehaoSwitchCore' -and
    $manualWaitSection -match 'TargetProfile \$capturedTarget -DeferPresentation' -and
    $manualWaitSection -match 'Stop-QiehaoManualSwitchWaitTimer' -and
    $manualWaitSection -notmatch 'Request-CodexDesktopNativeQuit|Request-CodexDesktopClose|CloseMainWindow' -and
    $manualWaitSection -notmatch '(?i)Get-CodexActiveProfile|Get-CodexAccountSlot|Test-CodexActiveIdentity|Save-CodexActiveProfile|Set-Content|Out-File|WriteAll|Invoke-WebRequest|Invoke-RestMethod'
) -Code 'GUI_MANUAL_WAIT_IMPLEMENTATION_INVALID'
$waitDialogSection = [regex]::Match(
    $guiSource,
    '(?s)function Show-QiehaoManualSwitchWaitDialog\s*\{.*?function Show-QiehaoSwitchResult'
).Value
Assert-GuiTest -Condition (
    -not [string]::IsNullOrWhiteSpace($waitDialogSection) -and
    ([regex]::Matches($waitDialogSection,
        'New-Object System\.Windows\.Controls\.Button')).Count -eq 1 -and
    $waitDialogSection -match '\$cancelButton\.Content = ''取消''' -and
    $waitDialogSection -match 'Add_Loaded' -and
    $waitDialogSection -match 'Start-QiehaoManualSwitchWaitTimer' -and
    $waitDialogSection -match 'Add_Closing' -and
    $waitDialogSection -match "DialogBackgroundBrush" -and
    $waitDialogSection -match "DialogCardBrush" -and
    $waitDialogSection -match "DialogBorderBrush" -and
    $waitDialogSection -match "DialogForegroundBrush" -and
    $waitDialogSection -match "DialogAccentBrush" -and
    $waitDialogSection -match "DialogWarningBrush" -and
    $waitDialogSection -match "DialogSuccessBrush" -and
    $waitDialogSection -match "PrimaryButtonStyle" -and
    $waitDialogSection -match 'New-Object System\.Windows\.Controls\.Border' -and
    $waitDialogSection -notmatch 'SystemColors|ControlBrush|#FFD4D0C8' -and
    $waitDialogSection -notmatch "Button\.Content\s*=\s*'(开始等待|开始检测|继续切换)" -and
    $waitDialogSection -notmatch 'ConfirmText'
) -Code 'GUI_WAIT_DIALOG_SECOND_STAGE_ACTION_PRESENT'
$oneClickSwitchSection = [regex]::Match(
    $guiSource,
    '(?s)function Invoke-QiehaoSwitchSelectedProfile\s*\{.*?function Invoke-QiehaoVerifySelectedProfile'
).Value
Assert-GuiTest -Condition (
    -not [string]::IsNullOrWhiteSpace($oneClickSwitchSection) -and
    $oneClickSwitchSection -match 'Show-QiehaoManualSwitchWaitDialog -TargetProfile \$targetProfile' -and
    $oneClickSwitchSection -match "ResultCode 'CODEX_EXIT_STATE_UNKNOWN'" -and
    $oneClickSwitchSection -notmatch 'Show-QiehaoChoiceDialog|ConfirmText'
) -Code 'GUI_SWITCH_STILL_REQUIRES_SECOND_CLICK'
Assert-GuiTest -Condition (
    $guiSource -match '切换成功。`n`n当前账号：\$TargetProfile' -and
    $guiSource -match 'Complete-QiehaoSwitchUiAfterBackend' -and
    $guiSource -match 'ExpectedActiveProfile \$ExpectedProfile -PassThru' -and
    $guiSource -match "'SwitchSucceededUiRefreshFailed'" -and
    $guiSource -match '账号切换已经成功，但界面状态刷新失败' -and
    $helperSource -match 'function Invoke-QiehaoSwitchUiCompletion' -and
    $helperSource -match "'SwitchSucceeded'" -and
    $helperSource -match "'SwitchSucceededUiRefreshFailed'"
) -Code 'GUI_SWITCH_SUCCESS_PRESENTATION_INCOMPLETE'
Assert-GuiTest -Condition (
    $guiSource -notmatch 'Request-CodexDesktopNativeQuit|Request-CodexDesktopClose|CloseMainWindow|ExitCodexButton|Request-QiehaoNormalExit' -and
    $xamlTextForEncoding -notmatch '正常退出 Codex'
) -Code 'GUI_AUTO_EXIT_PATH_STILL_REACHABLE'
Assert-GuiTest -Condition (
    $coreAndGuiSource -match 'AutomationId' -and
    $coreAndGuiSource -match 'InvokePattern' -and
    $coreAndGuiSource -match 'ExpandCollapsePattern' -and
    $coreAndGuiSource -match 'ControlType\]::MenuItem' -and
    $coreAndGuiSource -notmatch '(?i)SendKeys|Alt\+F4|mouse_event'
) -Code 'GUI_NATIVE_QUIT_UIA_IMPLEMENTATION_UNSAFE'

$launchSection = [regex]::Match(
    $guiSource,
    '(?s)function Invoke-QiehaoLaunchCodex\s*\{.*?function Complete-QiehaoManualSwitchWait'
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
    ProductionImportOrderPowerShell51 = 'PASS'
    ProductionImportOrderPowerShell7 = 'PASS'
    BackgroundWorkerContractPowerShell51 = 'PASS'
    BackgroundWorkerContractPowerShell7 = 'PASS'
    QuotaCommandsExportedPowerShell51 = 'PASS'
    QuotaCommandsExportedPowerShell7 = 'PASS'
    CoreCommandsSurviveAllQuotaImports = 'PASS'
    GuiStartupPowerShell51 = 'PASS'
    GuiStartupPowerShell7 = 'PASS'
    QuotaAvailableWithNoCache = 'PASS'
    NoCacheDoesNotDisableRefreshButton = 'PASS'
    QueryFailureDoesNotDisableQuotaFeature = 'PASS'
    StartupQuotaSuccessClearsBusy = 'PASS'
    StartupQuotaFailureClearsBusy = 'PASS'
    StartupQuotaTimeoutClearsBusy = 'PASS'
    StartupQuotaCompletionTimerStops = 'PASS'
    StartupQuotaCompletionHandlerRemoved = 'PASS'
    StartupQuotaSuccessReEnablesRefresh = 'PASS'
    StartupQuotaFailureReEnablesRefresh = 'PASS'
    AsyncCompletionExceptionStillCleansUp = 'PASS'
    GuiClosingDuringQuotaQueryCleansUp = 'PASS'
    StartupSendsAtMostOneQuery = 'PASS'
    BackgroundWorkerImportsQuotaClient = 'PASS'
    BackgroundWorkerImportsQuotaParser = 'PASS'
    BackgroundWorkerHasQuotaPublicCommand = 'PASS'
    BackgroundWorkerReturnsStructuredResult = 'PASS'
    BackgroundWorkerFailureCodeSurvivesEndInvoke = 'PASS'
    BackgroundWorkerDoesNotRequireCallerScopeModules = 'PASS'
    WorkerOutputCountOne = 'PASS'
    WorkerSnapshotSurvivesEndInvoke = 'PASS'
    WorkerExecutableDiscoverySucceeded = 'PASS'
    WorkerLockDiagnosticSurvives = 'PASS'
    QuotaTimerNoDynamicClosure = 'PASS'
    QuotaGuiHardFailSafe15Seconds = 'PASS'
    QuotaAvailableFromForeignWorkingDirectory = 'PASS'
    QuotaModuleUnavailablePowerShell51 = 'PASS'
    QuotaModuleUnavailablePowerShell7 = 'PASS'
    QuotaSnapshotGuiCache = 'PASS'
    PowerShell51XamlParse = 'PASS'
    PowerShell7XamlParse = 'PASS'
    QuotaRowsCompact28To34 = 'PASS'
    QuotaWindowCountDoesNotChangeRowHeight = 'PASS'
    NoSnapshotSingleLineHeight = 'PASS'
    TwoProfilesNoQuotaVerticalScroll = 'PASS'
    ModalSwitchLifecyclePowerShell51 = 'PASS'
    ModalSwitchLifecyclePowerShell7 = 'PASS'
    FiveThemesLoad = 'PASS'
    FiveThemesGlassProperties = 'PASS'
    FiveThemesDialogResources = 'PASS'
    FiveThemesDialogContrast = 'PASS'
    MissingThemeFallback = 'PASS'
    CorruptThemeFallback = 'PASS'
    BackgroundUniformToFill = 'PASS'
    ImmediateThemeSwitch = 'PASS'
    ThemePreferenceRestore = 'PASS'
    ThemePersistenceWpfLifecycle = 'PASS'
    ThemeExistingFileAtomicReplace = 'PASS'
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
    LegacyExitAlreadyStopped = 'PASS'
    LegacyNativeQuitHelpers = 'PASS'
    LegacyCloseMainWindowHelpers = 'PASS'
    LaunchAutoDetection = 'PASS'
    LaunchCustomSettings = 'PASS'
    LaunchProviderContract = 'PASS'
    LaunchAndWaitButtonStates = 'PASS'
    ProcessMonitorReadOnly = 'PASS'
    ProcessMonitorFiveSeconds = 'PASS'
    GenericWaitRealDispatcherClosure = 'PASS'
    GenericWaitMilestone = 'PASS'
    GenericWaitHardTimeout = 'PASS'
    GenericWaitTimeoutCleanup = 'PASS'
    GenericWaitCallbackIsolation = 'PASS'
    GenericWaitWindowCloseCleanup = 'PASS'
    ManualWaitRunningNoSwitch = 'PASS'
    ManualWaitStoppedSwitchOnce = 'PASS'
    SwitchRefreshBeforeNotification = 'PASS'
    SwitchActiveMigrationWithoutLaunch = 'PASS'
    SwitchActiveMigrationWithoutMainTimer = 'PASS'
    SwitchSuccessRefreshFailureDistinct = 'PASS'
    ManualWaitUnknownFailClosed = 'PASS'
    ManualWaitInjectedTimeout = 'PASS'
    ManualWaitCancelCleanup = 'PASS'
    ManualWaitWindowCloseCleanup = 'PASS'
    ManualWaitDefaultNinetySeconds = 'PASS'
    AutoExitGuiPathAbsent = 'PASS'
    WindowCloseStopsAllTimers = 'PASS'
    GlassCardsAndButtons = 'PASS'
    ActiveRowDistinct = 'PASS'
    RefreshReadOnly = 'PASS'
    ClickOnlySelects = 'PASS'
    DoubleClickStoppedSwitch = 'PASS'
    DoubleClickActiveNoWrite = 'PASS'
    NonRowDoubleClickIgnored = 'PASS'
    RunningStartsManualWait = 'PASS'
    ManualWaitDoesNotPreSwitch = 'PASS'
    ManualWaitStartFailureBlocksSwitch = 'PASS'
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
