# No WPF layout changes. A background runspace owns the write mutex and child.
$script:guiLifecycleRegistry = [hashtable]::Synchronized(@{
    IsActive = $false; CancelRequested = $false; Stage = ''; Purpose = ''
    RequestProfileName = $false; PickedProfileName = ''
})
$script:guiLifecycleWorkerRunning = $false
$script:guiLifecycleClosingRequested = $false
$script:guiManualRecoveryRequired = $false
$script:guiRefreshEpoch = @{Generation=0L;Sequence=0L}
$script:guiLifecycleFinalCode = ''

function Request-QiehaoLifecycleCancellation {
    param([ValidateSet('Esc','WindowClose','NameDialog','Timeout','Failure')][string]$Reason)
    $script:guiLifecycleRegistry.CancelRequested = $true
    $script:guiLifecycleRegistry.CancellationReason = $Reason
    if ($Reason -ceq 'WindowClose') { $script:guiLifecycleClosingRequested = $true }
}

function Invoke-QiehaoResponsiveLifecycle {
    param([ValidateSet('Switch','Verify','Login','ManualAdd','DeleteSafety','Delete')][string]$Action,[string]$Name,
        [scriptblock]$TestWorker)
    if ($null -ne $TestWorker -and -not $SelfTest) { throw 'LIFECYCLE_FAKE_REQUIRES_SELFTEST' }
    if ($script:guiLifecycleWorkerRunning -or $script:guiLifecycleRegistry.IsActive) { throw 'OPERATION_BUSY' }
    $script:guiRefreshEpoch.Generation++
    $script:guiRefreshEpoch.Sequence++
    $script:guiLifecycleFinalCode = ''
    $script:guiLifecycleRegistry.CancelRequested = $false
    $script:guiLifecycleRegistry.Stage = ''
    $script:guiLifecycleRegistry.PickedProfileName = ''
    $script:guiLifecycleRegistry.RequestProfileName = $Action -ceq 'Login'
    $script:guiLifecycleWorkerRunning = $true
    $script:guiLifecycleFinalCode = 'ACCOUNT_OPERATION_FAILED'
    $ps = $null; $timer = $null; $handler = $null
    try {
    if ($Action -ceq 'Switch') { $refreshStatusText.Text = Get-QiehaoGuiText -Key 'Account.LocalSwitchWorking' }
    $ps = [PowerShell]::Create()
    $frame = New-Object Windows.Threading.DispatcherFrame
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(40)
    $state = @{ NamePrompted = $false; LastStage = ''; Async = $null }
    $registry = $script:guiLifecycleRegistry
    $statusControl = $refreshStatusText
    $textProvider = { param($Key) Get-QiehaoGuiText -Key $Key }
    $nameProvider = { Show-QiehaoNameDialog -Title (Get-QiehaoGuiText -Key 'Dialog.Add.Title') -Prompt (Get-QiehaoGuiText -Key 'Dialog.Name.Local') -LifecycleRegistry $registry }.GetNewClosure()
    $worker = {
        param($ModulePath,$Action,$Name,$Registry)
        try {
            Import-Module $ModulePath -Force -ErrorAction Stop
            switch ($Action) {
                'Switch' { Switch-CodexAccountProfile -Name $Name -OwnedProcessRegistry $Registry }
                'Verify' { Test-CodexProfile -Name $Name -OwnedProcessRegistry $Registry }
                'Login' { Add-CodexManagedProfile -Name '__pending__' -OwnedProcessRegistry $Registry }
                'ManualAdd' { Add-CodexVerifiedLocalProfile -Name $Name -OwnedProcessRegistry $Registry }
                'DeleteSafety' { Get-CodexProfileDeleteSafety -Name $Name }
                'Delete' { Remove-CodexProfile -Name $Name -ConfirmDelete }
            }
        } catch {
            $code = [string]$_.Exception.Message
            if ($code -notmatch '^[A-Z][A-Z0-9_]+$') { $code = 'ACCOUNT_OPERATION_FAILED' }
            [pscustomobject]@{Result=$code}
        }
    }
    if ($null -ne $TestWorker) { $worker = $TestWorker }
    $null = $ps.AddScript($worker.ToString()).AddArgument($coreModulePath).AddArgument($Action).AddArgument($Name).AddArgument($registry)
    $handler = [EventHandler]({
        param($sender,$eventArgs)
        if ($state.Async.IsCompleted) { $frame.Continue = $false; return }
        try {
        $stage = [string]$registry.Stage
        if ($stage -ceq 'ACCOUNT_LOGIN_NAME_REQUIRED' -and -not $state.NamePrompted) {
            $state.NamePrompted = $true
            $picked = & $nameProvider
            if ([string]::IsNullOrWhiteSpace($picked)) { Request-QiehaoLifecycleCancellation -Reason NameDialog }
            else { $registry.PickedProfileName = $picked }
        }
        if ($stage -cne $state.LastStage) {
            $state.LastStage = $stage
            $key = switch ($stage) {
                'ACCOUNT_VERIFY_START' { 'Account.VerifyingOfficial' }
                'ACCOUNT_REFRESH_START' { 'Account.VerifyingOfficial' }
                'ACCOUNT_LOGIN_URL_READY' { 'Account.LoginBrowserOpened' }
                'ACCOUNT_LOGIN_COMPLETED' { 'Account.VerifyingOfficial' }
                'ACCOUNT_LOGIN_SAVING' { 'Account.LoginSaving' }
                default { '' }
            }
            if ($key) { $statusControl.Text = & $textProvider $key }
        }
        } catch { Request-QiehaoLifecycleCancellation -Reason Failure }
    }.GetNewClosure())
    $timer.Add_Tick($handler)
    $script:guiLifecycleFinalCode = 'ACCOUNT_OPERATION_FAILED'
    try {
        $state.Async = $ps.BeginInvoke()
        $timer.Start()
        [Windows.Threading.Dispatcher]::PushFrame($frame)
        $output = @($ps.EndInvoke($state.Async))
        if ($output.Count -ne 1) { throw 'ACCOUNT_OPERATION_FAILED' }
        $script:guiLifecycleFinalCode = [string]$output[0].Result
        if ($script:guiLifecycleFinalCode -ceq 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED') {
            $script:guiManualRecoveryRequired = $true
        }
        return $output[0]
    } finally {
        $timer.Stop(); $timer.Remove_Tick($handler)
    }
    } finally {
        # UI finalization must survive setup/disposal/presentation exceptions.
        try { if ($null -ne $ps) { $ps.Dispose() } }
        finally {
        $script:guiLifecycleWorkerRunning = $false
        $script:guiRefreshEpoch.Generation++
        $script:guiRefreshEpoch.Sequence++
        try {
        if (Get-Command Sync-QiehaoCommittedActiveState -ErrorAction SilentlyContinue) {
            $null = Sync-QiehaoCommittedActiveState
        }
        } finally {
            if (Get-Command Set-QiehaoWriteBusy -ErrorAction SilentlyContinue) {
                Set-QiehaoWriteBusy -Value $false
            }
        }
        $script:guiLifecycleRegistry.Stage = ''
        $script:guiLifecycleRegistry.PickedProfileName = ''
        $script:guiLifecycleRegistry.RequestProfileName = $false
        if ($script:guiLifecycleClosingRequested -and -not $script:guiLifecycleRegistry.IsActive -and
            $null -ne (Get-Variable window -ErrorAction SilentlyContinue)) {
            $null = $window.Dispatcher.BeginInvoke([Action]{ $window.Close() },[Windows.Threading.DispatcherPriority]::Background)
        }
        }
    }
}
