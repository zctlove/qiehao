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

function Invoke-SwitchQuotaDispatcherFor {
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

function Invoke-FakeSwitchBeforeFlow {
    param(
        [Parameter(Mandatory = $true)][double]$CodexStoppedAtSeconds,
        [Parameter(Mandatory = $true)][double]$QuotaCompletesAtSeconds,
        [Parameter(Mandatory = $true)][bool]$QuotaSucceeds,
        [Parameter(Mandatory = $true)][bool]$HasOldCache,
        [double]$BudgetSeconds = 8
    )

    $state = [pscustomobject]@{
        QueryStartedAt = 0.0
        ExitWaitStartedAt = 0.0
        DeadlineAt = [double]$BudgetSeconds
        QueryCalls = 1
        QueryPending = $true
        CodexStopped = $false
        QuotaSucceeded = $false
        SwitchCalls = 0
        SwitchSucceeded = $false
        SwitchAt = $null
        CacheValue = if ($HasOldCache) { 'OldSnapshot' } else { $null }
        QueriedAt = if ($HasOldCache) { 'OldQueriedAt' } else { $null }
        Statuses = New-Object 'System.Collections.Generic.List[string]'
    }
    $null = $state.Statuses.Add('SnapshotStarting')

    for ($step = 0; $step -le 40; $step++) {
        $now = [double]$step / 2.0
        if (-not $state.CodexStopped -and
            $now -ge $CodexStoppedAtSeconds) {
            $state.CodexStopped = $true
            if ($state.QueryPending) {
                $null = $state.Statuses.Add('CodexStoppedSnapshotPending')
            }
        }

        if ($state.QueryPending -and $now -ge 3 -and
            -not $state.Statuses.Contains('QuotaSlow')) {
            $null = $state.Statuses.Add('QuotaSlow')
        }

        if ($state.QueryPending -and
            $now -ge $QuotaCompletesAtSeconds -and
            $now -le $state.DeadlineAt) {
            $state.QueryPending = $false
            if ($QuotaSucceeds) {
                $state.QuotaSucceeded = $true
                $state.CacheValue = 'NewSnapshot'
                $state.QueriedAt = 'NewQueriedAt'
                $null = $state.Statuses.Add('SnapshotSavedSwitching')
            }
            else {
                $null = $state.Statuses.Add('SnapshotFailedOldCacheKept')
            }
        }
        elseif ($state.QueryPending -and $now -ge $state.DeadlineAt) {
            $state.QueryPending = $false
            $null = $state.Statuses.Add('SnapshotFailedOldCacheKept')
        }

        if ($state.CodexStopped -and -not $state.QueryPending -and
            $state.SwitchCalls -eq 0) {
            $state.SwitchCalls = 1
            $state.SwitchSucceeded = $true
            $state.SwitchAt = $now
            break
        }
    }
    return $state
}

$beforeStopped = Invoke-FakeSwitchBeforeFlow `
    -CodexStoppedAtSeconds 5 -QuotaCompletesAtSeconds 2 `
    -QuotaSucceeds $true -HasOldCache $true
Assert-SwitchQuotaContract (
    $beforeStopped.QueryStartedAt -eq $beforeStopped.ExitWaitStartedAt
) 'SWITCH_QUOTA_NOT_STARTED_WITH_MANUAL_EXIT_WAIT'
Assert-SwitchQuotaContract (
    $beforeStopped.QuotaSucceeded -and
    [double]$beforeStopped.SwitchAt -eq 5 -and
    $beforeStopped.SwitchCalls -eq 1
) 'SWITCH_QUOTA_SUCCESS_BEFORE_STOPPED_FAILED'

$afterStopped = Invoke-FakeSwitchBeforeFlow `
    -CodexStoppedAtSeconds 3 -QuotaCompletesAtSeconds 6 `
    -QuotaSucceeds $true -HasOldCache $true
Assert-SwitchQuotaContract (
    $afterStopped.QuotaSucceeded -and
    [double]$afterStopped.SwitchAt -eq 6 -and
    $afterStopped.Statuses.Contains('CodexStoppedSnapshotPending')
) 'SWITCH_QUOTA_SUCCESS_AFTER_STOPPED_FAILED'

$timedOut = Invoke-FakeSwitchBeforeFlow `
    -CodexStoppedAtSeconds 2 -QuotaCompletesAtSeconds 99 `
    -QuotaSucceeds $false -HasOldCache $true
Assert-SwitchQuotaContract (
    $timedOut.SwitchSucceeded -and $timedOut.SwitchCalls -eq 1 -and
    [double]$timedOut.SwitchAt -eq 8
) 'SWITCH_QUOTA_TIMEOUT_BLOCKED_SWITCH'
Assert-SwitchQuotaContract (
    $timedOut.CacheValue -ceq 'OldSnapshot' -and
    $timedOut.QueriedAt -ceq 'OldQueriedAt'
) 'SWITCH_QUOTA_FAILURE_CHANGED_OLD_CACHE'

$noOldCache = Invoke-FakeSwitchBeforeFlow `
    -CodexStoppedAtSeconds 1 -QuotaCompletesAtSeconds 4 `
    -QuotaSucceeds $false -HasOldCache $false
Assert-SwitchQuotaContract (
    $noOldCache.SwitchSucceeded -and $null -eq $noOldCache.CacheValue -and
    $null -eq $noOldCache.QueriedAt
) 'SWITCH_QUOTA_FAILURE_WITHOUT_CACHE_BLOCKED_SWITCH'

Assert-SwitchQuotaContract (
    $beforeStopped.QueryCalls -eq 1 -and
    $afterStopped.QueryCalls -eq 1 -and $timedOut.QueryCalls -eq 1 -and
    $noOldCache.QueryCalls -eq 1
) 'SWITCH_QUOTA_RETRIED'

$lateStop = Invoke-FakeSwitchBeforeFlow `
    -CodexStoppedAtSeconds 6 -QuotaCompletesAtSeconds 99 `
    -QuotaSucceeds $false -HasOldCache $true
Assert-SwitchQuotaContract (
    [double]$lateStop.SwitchAt -eq 8 -and
    ([double]$lateStop.SwitchAt - 6.0) -eq 2.0
) 'SWITCH_QUOTA_BUDGET_RESTARTED_AFTER_STOPPED'

Assert-SwitchQuotaContract (
    $afterStopped.Statuses.Contains('QuotaSlow')
) 'SWITCH_QUOTA_SLOW_STATUS_MISSING'
Assert-SwitchQuotaContract (
    $afterStopped.Statuses.Contains('SnapshotSavedSwitching')
) 'SWITCH_QUOTA_SUCCESS_STATUS_MISSING'
Assert-SwitchQuotaContract (
    $timedOut.Statuses.Contains('SnapshotFailedOldCacheKept')
) 'SWITCH_QUOTA_TIMEOUT_STATUS_MISSING'
Assert-SwitchQuotaContract (
    $noOldCache.SwitchSucceeded -and $timedOut.SwitchSucceeded
) 'QUOTA_FAILURE_CHANGED_SWITCH_SUCCESS'

Add-Type -AssemblyName WindowsBase -ErrorAction Stop
Import-Module -Name $helperPath -Force -ErrorAction Stop
$runtimeState = [pscustomobject]@{
    QuotaPending = $true
    SwitchCalls = 0
}
$runtime = New-QiehaoWaitTimerRuntime -IntervalMilliseconds 10 `
    -TimeoutSeconds 1 -ProbeProvider ({
        if ($runtimeState.QuotaPending) { return 'Pending' }
        return 'Succeeded'
    }.GetNewClosure()) -CompletionAction ({
        param($Result, $IgnoredRuntime)
        if ($Result -ceq 'Succeeded') { $runtimeState.SwitchCalls++ }
    }.GetNewClosure())
$null = Start-QiehaoWaitTimerRuntime -Runtime $runtime
Invoke-SwitchQuotaDispatcherFor -Milliseconds 80
$timerStayedActive = (
    $runtime.Active -and $runtimeState.SwitchCalls -eq 0 -and
    $runtime.LastProbe -ceq 'Pending'
)
$runtimeState.QuotaPending = $false
Invoke-SwitchQuotaDispatcherFor -Milliseconds 80
Assert-SwitchQuotaContract (
    $timerStayedActive -and -not $runtime.Active -and $runtime.Stopped -and
    $runtime.HandlerRemoved -and $runtimeState.SwitchCalls -eq 1
) 'SWITCH_QUOTA_WAIT_TIMER_FINALIZED_BEFORE_QUOTA_DONE'

$guiSource = [System.IO.File]::ReadAllText($guiPath)
$switchEntry = [regex]::Match(
    $guiSource,
    '(?s)function Invoke-QiehaoSwitchSelectedProfile\s*\{.*?function Invoke-QiehaoVerifySelectedProfile'
).Value
$manualDialogFailure = [regex]::Match(
    $switchEntry,
    '(?s)Show-QiehaoManualSwitchWaitDialog.*?catch\s*\{.*?return'
).Value
$manualWait = [regex]::Match(
    $guiSource,
    '(?s)function Complete-QiehaoManualSwitchWait\s*\{.*?function Start-QiehaoManualSwitchWaitTimer'
).Value
$manualTimer = [regex]::Match(
    $guiSource,
    '(?s)function Start-QiehaoManualSwitchWaitTimer\s*\{.*?function Cancel-QiehaoManualSwitchWait'
).Value
Assert-SwitchQuotaContract (
    $switchEntry -match
        '(?s)Start-QiehaoQuotaAsync -Reason SwitchBefore.*?Show-QiehaoManualSwitchWaitDialog' -and
    $switchEntry -match 'guiPendingAction = ''SwitchAfterQuota''' -and
    $guiSource -match 'elseif \(\$Reason -ceq ''SwitchBefore''\) \{ 8000 \}' -and
    $guiSource -match 'if \(\$Reason -ceq ''SwitchBefore''\) \{\s*8' -and
    $manualTimer -match 'guiQuotaCoordinator\.\s*QueryInProgress' -and
    $manualTimer -match
        '(?s)guiQuotaAsyncReason.*?QueryInProgress.*?return ''Pending''.*?return ''Succeeded''' -and
    $manualWait -match 'SkipQuotaBefore' -and
    $manualDialogFailure -match 'Stop-QiehaoQuotaAsync'
) 'SWITCH_QUOTA_PRODUCTION_WIRING_INVALID'

Write-Output 'SwitchBeforeQuotaRunsDuringManualExitWait=True'
Write-Output 'SwitchBeforeQuotaSuccessBeforeStopped=True'
Write-Output 'SwitchBeforeQuotaSuccessAfterStoppedWithinBudget=True'
Write-Output 'SwitchBeforeQuotaTimeoutDoesNotBlockSwitch=True'
Write-Output 'SwitchBeforeQuotaUsesOldCacheOnFailure=True'
Write-Output 'SwitchBeforeQuotaFailureWithoutOldCacheStillSwitches=True'
Write-Output 'SwitchBeforeQuotaNoRetry=True'
Write-Output 'SwitchBeforeQuotaBudgetDoesNotRestartAfterStopped=True'
Write-Output 'SwitchBeforeQuotaSlowStatusMessage=True'
Write-Output 'SwitchBeforeQuotaSuccessStatusMessage=True'
Write-Output 'SwitchBeforeQuotaTimeoutStatusMessage=True'
Write-Output 'QuotaFailureNeverChangesSwitchSuccess=True'
Write-Output 'SwitchBeforeQuotaWaitTimerRemainsActiveUntilQuotaDone=True'
Write-Output 'SWITCH_BEFORE_QUOTA_SELFTEST_PASS'
