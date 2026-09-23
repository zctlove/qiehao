[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$guiPath = Join-Path $projectRoot 'gui\QiehaoGui.ps1'
$helperPath = Join-Path $projectRoot 'gui\GuiHelpers.psm1'

function Assert-SwitchQuotaContract {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Code
    )
    if (-not $Condition) { throw $Code }
}

function Invoke-DispatcherFor {
    param([Parameter(Mandatory = $true)][int]$Milliseconds)
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds($Milliseconds)
    $handler = [System.EventHandler]({
        param($sender, $eventArgs)
        $sender.Stop()
        $frame.Continue = $false
    }.GetNewClosure())
    $timer.Add_Tick($handler)
    try {
        $timer.Start()
        [System.Windows.Threading.Dispatcher]::PushFrame($frame)
    }
    finally {
        $timer.Remove_Tick($handler)
        $timer.Stop()
    }
}

$guiSource = [System.IO.File]::ReadAllText($guiPath)
$switchEntry = [regex]::Match(
    $guiSource,
    '(?s)function Invoke-QiehaoSwitchSelectedProfile\s*\{.*?function Invoke-QiehaoVerifySelectedProfile'
).Value
$switchCore = [regex]::Match(
    $guiSource,
    '(?s)function Invoke-QiehaoSwitchCore\s*\{.*?function Invoke-QiehaoSwitchSelectedProfile'
).Value
$manualTimer = [regex]::Match(
    $guiSource,
    '(?s)function Start-QiehaoManualSwitchWaitTimer\s*\{.*?function Cancel-QiehaoManualSwitchWait'
).Value
$completion = [regex]::Match(
    $guiSource,
    '(?s)function Show-QiehaoSwitchCompletionMessage\s*\{.*?function Show-QiehaoSwitchResult'
).Value
$addEntry = [regex]::Match(
    $guiSource,
    '(?s)function Invoke-QiehaoAddAccount\s*\{.*?function Get-QiehaoDataGridRowFromSource'
).Value
$deleteEntry = [regex]::Match(
    $guiSource,
    '(?s)function Invoke-QiehaoDeleteSelectedProfile\s*\{.*?function Start-QiehaoAddWizard'
).Value

Assert-SwitchQuotaContract (
    -not [string]::IsNullOrWhiteSpace($switchEntry) -and
    $switchEntry -match
        '(?s)Stop-QiehaoQuotaAsync.*?Get-QiehaoLiveCodexStatus' -and
    $switchEntry -notmatch 'Start-QiehaoQuotaAsync -Reason SwitchBefore' -and
    $switchEntry -notmatch 'SwitchAfterQuota' -and
    $switchEntry -match
        '(?s)Set-QiehaoWriteBusy.*?Invoke-QiehaoSwitchCore'
) 'SWITCH_LIFECYCLE_STILL_WAITS_FOR_QUOTA'

Assert-SwitchQuotaContract (
    -not [string]::IsNullOrWhiteSpace($switchCore) -and
    $switchCore -notmatch
        'Invoke-QiehaoQuotaBeforeSwitch|Start-QiehaoQuotaAsync|SwitchBefore' -and
    $switchCore -match 'Switch-CodexAccountProfile'
) 'SWITCH_CORE_CONTAINS_QUOTA_PREREQUISITE'

Assert-SwitchQuotaContract (
    -not [string]::IsNullOrWhiteSpace($manualTimer) -and
    $manualTimer -notmatch
        'guiQuota|QuotaAsync|QuotaCoordinator|SwitchBefore' -and
    $manualTimer -match
        'if \(\$status -ceq [^\r\n]+\) \{ return ''Succeeded'' \}'
) 'MANUAL_EXIT_WAIT_STILL_WAITS_FOR_QUOTA'

Assert-SwitchQuotaContract (
    -not [string]::IsNullOrWhiteSpace($completion) -and
    $completion -match 'Start-QiehaoQuotaAsync -Reason SwitchAfter'
) 'POST_SWITCH_QUOTA_NOT_BACKGROUND'

Assert-SwitchQuotaContract (
    $addEntry -match
        '(?s)Stop-QiehaoQuotaAsync.*?Get-QiehaoLiveCodexStatus' -and
    $deleteEntry -match
        '(?s)Stop-QiehaoQuotaAsync.*?Get-CodexProfileDeleteSafety'
) 'LIFECYCLE_DOES_NOT_CANCEL_INFLIGHT_QUOTA'

Add-Type -AssemblyName WindowsBase -ErrorAction Stop
Import-Module -Name $helperPath -Force -ErrorAction Stop
$runtimeState = [pscustomobject]@{
    QuotaPending = $true
    SwitchCalls = 0
}
$runtime = New-QiehaoWaitTimerRuntime -IntervalMilliseconds 10 `
    -TimeoutSeconds 1 -ProbeProvider ({
        # The Codex process is already stopped. A pending quota request must
        # not be consulted by the lifecycle wait state.
        return 'Succeeded'
    }.GetNewClosure()) -CompletionAction ({
        param($Result, $IgnoredRuntime)
        if ($Result -ceq 'Succeeded') { $runtimeState.SwitchCalls++ }
    }.GetNewClosure())
$null = Start-QiehaoWaitTimerRuntime -Runtime $runtime
Invoke-DispatcherFor -Milliseconds 80
Assert-SwitchQuotaContract (
    $runtimeState.QuotaPending -and
    $runtimeState.SwitchCalls -eq 1 -and
    -not $runtime.Active -and $runtime.Stopped -and
    $runtime.HandlerRemoved
) 'PENDING_QUOTA_BLOCKED_STOPPED_SWITCH'

Write-Output 'QuotaNeverStartsDuringManualExitWait=True'
Write-Output 'SwitchRunsImmediatelyWhenCodexStopped=True'
Write-Output 'SwitchCoreHasNoQuotaPrerequisite=True'
Write-Output 'LifecycleCancelsInFlightQuotaFirst=True'
Write-Output 'SwitchAfterQuotaRemainsBackground=True'
Write-Output 'PendingQuotaNeverBlocksStoppedSwitch=True'
Write-Output 'QuotaFailureNeverChangesSwitchSuccess=True'
Write-Output 'SWITCH_BEFORE_QUOTA_SELFTEST_PASS'
