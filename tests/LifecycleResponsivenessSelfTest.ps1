Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$SelfTest = $true
$projectRoot = Split-Path -Parent $PSScriptRoot
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
$coreModulePath = Join-Path $projectRoot 'lib\CodexAuth.psm1'
$refreshStatusText = New-Object Windows.Controls.TextBlock
$script:nameDialogCalls = 0
function Get-QiehaoGuiText { param([string]$Key) return $Key }
function Show-QiehaoNameDialog { param($Title,$Prompt) $script:nameDialogCalls++; return 'Fake Named' }
. (Join-Path $projectRoot 'gui\LifecycleWorker.ps1')
$pulse = @{Count=0}
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(25)
$tick = [EventHandler]({ $pulse.Count++ }.GetNewClosure())
$timer.Add_Tick($tick)
$timer.Start()
try {
    $r = Invoke-QiehaoResponsiveLifecycle -Action Switch -Name Fake -TestWorker {
        param($module,$action,$name,$registry)
        $registry.Stage='ACCOUNT_VERIFY_START'
        [Threading.Thread]::Sleep(350)
        [pscustomobject]@{Result='SWITCH_VERIFIED_SUCCESS'}
    }
    if ($r.Result -cne 'SWITCH_VERIFIED_SUCCESS' -or $pulse.Count -lt 2 -or $script:guiLifecycleWorkerRunning) { throw 'DISPATCHER_BLOCKED_BY_LIFECYCLE' }
    if ($refreshStatusText.Text -cne 'Account.VerifyingOfficial') { throw 'LIFECYCLE_STATUS_NOT_DISPATCHED' }
    $r=Invoke-QiehaoResponsiveLifecycle -Action Switch -Name Fake -IdentityRecoveryConsent ([pscustomobject]@{Stamp='FAKE-CONSENT'}) -TestWorker {
        param($module,$action,$name,$registry,$consent)
        if ($consent.Stamp -cne 'FAKE-CONSENT') {throw 'RECOVERY_CONSENT_NOT_FORWARDED'}
        [pscustomobject]@{Result='SWITCH_RECOVERY_LOCAL_COMMITTED_MANUAL_CHECK_REQUIRED'}
    }
    if (-not $script:guiManualRecoveryRequired -or $r.Result -cne 'SWITCH_RECOVERY_LOCAL_COMMITTED_MANUAL_CHECK_REQUIRED') {throw 'RECOVERY_MANUAL_CHECK_GATE_NOT_RETAINED'}
    $script:guiManualRecoveryRequired=$false
    $r = Invoke-QiehaoResponsiveLifecycle -Action Login -TestWorker {
        param($module,$action,$name,$registry)
        $registry.Stage='ACCOUNT_LOGIN_NAME_REQUIRED'
        $deadline=[DateTime]::UtcNow.AddSeconds(5)
        while (-not $registry.PickedProfileName) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'FAKE_NAME_TIMEOUT' }
            [Threading.Thread]::Sleep(20)
        }
        [pscustomobject]@{Result='ADD_VERIFIED_SUCCESS';Profile=$registry.PickedProfileName}
    }
    if ($r.Profile -cne 'Fake Named' -or $script:nameDialogCalls -ne 1) { throw 'POST_LOGIN_NAME_DIALOG_NOT_CALLED' }
    $failed = $false
    try { $null = Invoke-QiehaoResponsiveLifecycle -Action Delete -TestWorker {throw 'FAKE_DELETE_FAILURE'} }
    catch { $failed=$true }
    if (-not $failed -or $script:guiLifecycleWorkerRunning) { throw 'DELETE_WORKER_BUSY_NOT_CLEARED' }
    $window=New-Object Windows.Window
    $closedState=@{Closed=$false}
    $window.Add_Closed({$closedState.Closed=$true}.GetNewClosure())
    foreach ($reason in @('Esc','WindowClose','Timeout')) {
        $cancelTimer=New-Object Windows.Threading.DispatcherTimer
        $cancelTimer.Interval=[TimeSpan]::FromMilliseconds(50)
        $reasonToSend=$reason
        $cancelTick=[EventHandler]({Request-QiehaoLifecycleCancellation -Reason $reasonToSend}.GetNewClosure())
        $cancelTimer.Add_Tick($cancelTick);$cancelTimer.Start()
        try {
            $r=Invoke-QiehaoResponsiveLifecycle -Action Login -TestWorker {
                param($module,$action,$name,$registry)
                $deadline=[DateTime]::UtcNow.AddSeconds(2)
                while (-not $registry.CancelRequested) {if ([DateTime]::UtcNow -gt $deadline) {throw 'FAKE_CANCEL_NOT_DELIVERED'};[Threading.Thread]::Sleep(10)}
                [pscustomobject]@{Result='ACCOUNT_LOGIN_CANCELLED'}
            }
            if ($r.Result -cne 'ACCOUNT_LOGIN_CANCELLED' -or $script:guiLifecycleWorkerRunning -or $script:guiLifecycleRegistry.CancellationReason -cne $reason) {throw 'SHARED_GUI_CANCEL_PIPELINE_FAILED'}
            if ($reason -ceq 'WindowClose') {
                $drainFrame=New-Object Windows.Threading.DispatcherFrame
                $null=$window.Dispatcher.BeginInvoke([Action]({$drainFrame.Continue=$false}.GetNewClosure()),[Windows.Threading.DispatcherPriority]::ContextIdle)
                [Windows.Threading.Dispatcher]::PushFrame($drainFrame)
                if (-not $closedState.Closed) {throw 'WINDOW_NOT_CLOSED_AFTER_CANCEL_CLEANUP'}
            }
        } finally {$cancelTimer.Stop();$cancelTimer.Remove_Tick($cancelTick);$script:guiLifecycleClosingRequested=$false}
    }
    $nameDefinition=(Get-Command Show-QiehaoNameDialog).ScriptBlock
    try {
        function Show-QiehaoNameDialog {param($Title,$Prompt) throw 'FAKE_NAME_DIALOG_FAILURE'}
        $r=Invoke-QiehaoResponsiveLifecycle -Action Login -TestWorker {
            param($module,$action,$name,$registry)
            $registry.Stage='ACCOUNT_LOGIN_NAME_REQUIRED'
            $deadline=[DateTime]::UtcNow.AddSeconds(2)
            while (-not $registry.CancelRequested) {if ([DateTime]::UtcNow -gt $deadline) {throw 'FAKE_NAME_CANCEL_NOT_DELIVERED'};[Threading.Thread]::Sleep(10)}
            [pscustomobject]@{Result='ACCOUNT_LOGIN_CANCELLED'}
        }
        if ($script:guiLifecycleWorkerRunning -or $r.Result -cne 'ACCOUNT_LOGIN_CANCELLED') {throw 'DISPATCHER_HANDLER_FAILURE_STRANDS_WORKER'}
    } finally {Set-Item -LiteralPath Function:Show-QiehaoNameDialog -Value $nameDefinition}
    $gui = [IO.File]::ReadAllText((Join-Path $projectRoot 'gui\QiehaoGui.ps1'))
    # Exercise the actual name-dialog timeout hook with an offscreen owner.
    $parseTokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'gui\QiehaoGui.ps1'),[ref]$parseTokens,[ref]$parseErrors)
    $nameAst=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Show-QiehaoNameDialog'},$true)
    Invoke-Expression $nameAst.Extent.Text
    function Set-QiehaoDialogContent {param($Dialog,$Content) $Dialog.Content=$Content}
    $window=New-Object Windows.Window
    $window.Left=-10000;$window.Top=-10000;$window.Width=100;$window.Height=100;$window.ShowInTaskbar=$false;$window.ShowActivated=$false
    $window.Resources[[Windows.Controls.TextBox]]=New-Object Windows.Style([Windows.Controls.TextBox])
    foreach ($key in @('PrimaryButtonStyle','SecondaryButtonStyle')) {$window.Resources[$key]=New-Object Windows.Style([Windows.Controls.Button])}
    $window.Show();$window.Hide()
    try {
        foreach ($terminalFlag in @('CancelRequested','OperationFinished')) {
            $nameRegistry=[hashtable]::Synchronized(@{CancelRequested=$false;OperationFinished=$false})
            $nameTimer=New-Object Windows.Threading.DispatcherTimer
            $nameTimer.Interval=[TimeSpan]::FromMilliseconds(150)
            $nameTick=[EventHandler]({$nameRegistry[$terminalFlag]=$true}.GetNewClosure())
            $nameTimer.Add_Tick($nameTick);$nameTimer.Start()
            $watch=[Diagnostics.Stopwatch]::StartNew()
            try {$picked=Show-QiehaoNameDialog -Title Fake -Prompt Fake -LifecycleRegistry $nameRegistry}
            finally {$nameTimer.Stop();$nameTimer.Remove_Tick($nameTick)}
            if ($null -ne $picked -or $watch.ElapsedMilliseconds -gt 2000) {throw 'NAME_DIALOG_OUTLIVES_LOGIN_TERMINAL'}
        }
    } finally {$window.Close();Set-Item -LiteralPath Function:Show-QiehaoNameDialog -Value $nameDefinition}
    $delete = [regex]::Match($gui,'(?s)function Invoke-QiehaoDeleteSelectedProfile\s*\{.*?function Start-QiehaoAddWizard').Value
    if ($delete -notmatch 'finally \{ Set-QiehaoWriteBusy -Value \$false \}' -or
        $delete -notmatch 'if \(-not \(Stop-QiehaoQuotaForLifecycle\)\) \{ return \}' -or
        $delete -notmatch 'Invoke-QiehaoResponsiveLifecycle -Action Delete') { throw 'DELETE_GUI_FINALLY_CONTRACT_BROKEN' }
    $actions = @('SwitchSelectedProfile','VerifySelectedProfile','DeleteSelectedProfile','AddAccount')
    foreach ($action in $actions) {
        $section=[regex]::Match($gui,('(?s)function (?:Invoke|Start)-Qiehao'+$action+'\s*\{.*?(?=\s+function )')).Value
        if ($section -notmatch 'if \(-not \(Stop-QiehaoQuotaForLifecycle\)\) \{ return \}') { throw ('QUOTA_LIFECYCLE_PREEMPTION_MISSING_'+$action) }
    }
    [pscustomobject]@{
        DispatcherResponsiveDuringLongQuery='PASS';PostLoginNameDialogOnDispatcher='PASS'
        DeleteBusyStateAlwaysClears='PASS';QuotaNeverBlocksLifecycle='PASS'
        XEscTimeoutShareCancellation='PASS';NameDialogFailureCleansWorker='PASS'
        WindowClosesOnlyAfterWorkerCleanup='PASS'
        NameDialogClosesOnCancelOrFinishedOperation='PASS'
        RealAuthOrProfileRead=$false;RealNetworkRequests=$false;Status='PASS'
    }
} finally { $timer.Stop(); $timer.Remove_Tick($tick) }
