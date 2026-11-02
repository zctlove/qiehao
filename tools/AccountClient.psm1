Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AppServerOwnership.psm1') -ErrorAction Stop

# Stable protocol; sensitive responses never leave this module.
function Get-AccountField {
    param($Value, [string]$Name, $Default = $null)
    if ($null -eq $Value) { return $Default }
    $p = $Value.PSObject.Properties[$Name]
    if ($null -eq $p) { return $Default }
    return $p.Value
}
function Test-QiehaoOfficialLoginUrl {
    param([string]$Value)
    $uri = $null
    return ([Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -and
        $uri.Scheme -ceq 'https' -and $uri.IsDefaultPort -and
        [string]::IsNullOrEmpty($uri.UserInfo) -and
        $uri.Host.ToLowerInvariant() -in @('auth.openai.com', 'chatgpt.com'))
}
function Send-AccountMessage {
    param($Session, $Message)
    $Session.Process.StandardInput.WriteLine(($Message | ConvertTo-Json -Depth 8 -Compress))
    $Session.Process.StandardInput.Flush()
}
function Read-AccountMessage {
    param($Session, [DateTime]$Deadline, [switch]$IgnoreCancellation)
    if (-not $IgnoreCancellation -and $Session.Registry.CancelRequested) { throw 'ACCOUNT_CANCELLED' }
    if ($null -eq $Session.PendingRead) {
        $Session.PendingRead = $Session.Process.StandardOutput.ReadLineAsync()
    }
    while (-not $Session.PendingRead.IsCompleted) {
        if (-not $IgnoreCancellation -and $Session.Registry.CancelRequested) { throw 'ACCOUNT_CANCELLED' }
        if ([DateTime]::UtcNow -ge $Deadline) { throw 'ACCOUNT_TIMEOUT' }
        [Threading.Thread]::Sleep(20)
    }
    $line = $Session.PendingRead.GetAwaiter().GetResult()
    $Session.PendingRead = $null
    if ($null -eq $line) { throw 'ACCOUNT_PROTOCOL_CLOSED' }
    if ($line.Length -gt 1048576) { throw 'ACCOUNT_PROTOCOL_UNSUPPORTED' }
    try { return ($line | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw 'ACCOUNT_PROTOCOL_UNSUPPORTED' }
    finally { $line = $null }
}
function Get-AccountRpcFailure {
    param($Value)
    if ((Get-AccountField $Value 'code') -in @(-32601, -32602)) { return 'ACCOUNT_PROTOCOL_UNSUPPORTED' }
    $marker = Get-AccountField (Get-AccountField $Value 'data') 'code' ''
    $message = [string](Get-AccountField $Value 'message' '')
    # Generic unauthorized/network/server errors are not permanent evidence.
    if ($marker -in @('refresh_token_expired','refresh_token_reused','refresh_token_invalid','invalid_grant') -or
        $message -match '(?i)\b(refresh_token_expired|refresh_token_reused|refresh_token_invalid)\b') {
        return 'ACCOUNT_REAUTH_REQUIRED'
    }
    return 'ACCOUNT_TRANSIENT_FAILURE'
}
function Invoke-AccountRpc {
    param($Session, [string]$Method, $Parameters, [DateTime]$Deadline)
    $Session.NextId++
    $requestId = $Session.NextId
    Send-AccountMessage $Session @{ id = $requestId; method = $Method; params = $Parameters }
    while ([DateTime]::UtcNow -lt $Deadline) {
        $message = Read-AccountMessage $Session $Deadline
        $id = Get-AccountField $message 'id'
        if ($null -eq $id) {
            if ($Session.Notifications.Count -ge 64) { throw 'ACCOUNT_PROTOCOL_UNSUPPORTED' }
            $Session.Notifications.Add($message)
            continue
        }
        if ([string]$id -cne [string]$requestId) { continue }
        $errorValue = Get-AccountField $message 'error'
        if ($null -ne $errorValue) { throw (Get-AccountRpcFailure $errorValue) }
        $result = Get-AccountField $message 'result'
        if ($null -eq $result) { throw 'ACCOUNT_PROTOCOL_UNSUPPORTED' }
        return $result
    }
    throw 'ACCOUNT_TIMEOUT'
}
function Get-AccountResultState {
    param($Result)
    $requires = Get-AccountField $Result 'requiresOpenaiAuth'
    $p = $Result.PSObject.Properties['account']
    if ($requires -isnot [bool] -or $null -eq $p) { return 'Unsupported' }
    if (-not $requires) { return 'CredentialStoreMismatch' }
    if ($null -eq $p.Value) { return 'NeedsRefresh' }
    if ([string](Get-AccountField $p.Value 'type') -cne 'chatgpt') { return 'CredentialStoreMismatch' }
    return 'Loaded'
}
function New-AccountSession {
    param([string]$CodexHome, [string]$Purpose, [hashtable]$Registry,
        [string]$TestExecutablePath, [string]$TestProcessArguments)
    $executable = $TestExecutablePath
    $arguments = $TestProcessArguments
    if ([string]::IsNullOrWhiteSpace($executable)) {
        $module = Import-Module (Join-Path $PSScriptRoot 'QuotaClient.psm1') -PassThru
        $resolved = & $module { Resolve-QiehaoCodexExecutable }
        if (-not $resolved.Succeeded) { throw 'ACCOUNT_CODEX_NOT_FOUND' }
        $executable = [string]$resolved.Path
        $arguments = 'app-server --stdio'
    }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $executable
    $start.Arguments = $arguments
    $start.WorkingDirectory = [IO.Path]::GetFullPath($CodexHome)
    $start.EnvironmentVariables['CODEX_HOME'] = [IO.Path]::GetFullPath($CodexHome)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $utf8 = New-Object Text.UTF8Encoding($false)
    $start.StandardOutputEncoding = $utf8
    $start.StandardErrorEncoding = $utf8
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    $spawned = $false
    try {
        if (-not (Start-QiehaoOwnedAppServer -Process $process -Registry $Registry -Purpose $Purpose)) { throw 'ACCOUNT_START_FAILED' }
        $spawned = $true
        return @{
            Process = $process; Registry = $Registry; PendingRead = $null; NextId = 0
            Notifications = New-Object 'Collections.Generic.List[object]'
            Stderr = $process.StandardError.ReadToEndAsync()
        }
    } catch {
        # A start/metadata failure can occur after creation: never abandon it.
        $safe = $true
        try {
            if ($spawned -or ($Registry.IsActive -and [object]::ReferenceEquals($process,$Registry.ProcessHandle))) {
                $process.StandardInput.Close()
                $safe = $process.WaitForExit(1200)
            }
        } catch { $safe = $false }
        if ($Registry.ContainsKey('OwnershipGeneration') -and [object]::ReferenceEquals($process,$Registry.ProcessHandle)) { Complete-QiehaoOwnedAppServer -Registry $Registry -ExitObserved $safe -CleanupResult $(if ($safe) {'StartFailureExited'} else {'ExitUnconfirmed'}) }
        if ($safe) { $process.Dispose(); throw 'ACCOUNT_START_FAILED' }
        throw 'ACCOUNT_CLEANUP_FAILED'
    }
}
function Close-AccountSession {
    param($Session)
    if ($null -eq $Session) { return $true }
    $process = $Session.Process
    $clean = $false
    try {
        try { $process.StandardInput.Close() } catch { }
        $clean = $process.WaitForExit(700)
        if (-not $clean -and -not $process.HasExited) {
            # Exact owned Process handle only; no name-based or descendant kill.
            $r = $Session.Registry
            if ($r.IsActive -and $process.Id -eq $r.ProcessId -and
                $process.StartTime.ToUniversalTime() -eq $r.ProcessStartTimeUtc -and
                $process.StartInfo.FileName.Equals($r.ExecutablePath,[StringComparison]::OrdinalIgnoreCase)) {
                $process.Kill()
                $clean = $process.WaitForExit(500)
            }
        }
    } catch { $clean = $false }
    finally {
        Complete-QiehaoOwnedAppServer -Registry $Session.Registry -ExitObserved $clean -CleanupResult $(if ($clean) {'Normal'} else {'ExitUnconfirmed'})
        $Session.Notifications.Clear()
        if ($clean) { $Session.PendingRead = $null; $Session.Stderr = $null; $process.Dispose() }
    }
    return $clean
}
function Initialize-AccountSession {
    param($Session, [DateTime]$Deadline)
    $null = Invoke-AccountRpc $Session 'initialize' @{
        clientInfo = @{ name = 'qiehao-account-client'; version = '1.1.1' }
        capabilities = @{ experimentalApi = $false }
    } $Deadline
    Send-AccountMessage $Session @{ method = 'initialized'; params = @{} }
}
function Get-AccountSafePlan {
    param($Result)
    $plan = Get-AccountField (Get-AccountField $Result 'account') 'planType' ''
    if ($plan -in @('free','plus','pro','team','business','enterprise','edu')) { return [string]$plan }
    return 'Unknown'
}
function Invoke-QiehaoAccountTransport {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CodexHome,
        [bool]$NeedsRefresh = $true, [hashtable]$OwnedProcessRegistry,
        [string]$TestExecutablePath, [string]$TestProcessArguments,
        [ValidateRange(100, 8000)][int]$PrimaryBudgetMilliseconds = 8000,
        [switch]$NoRefresh)
    $registry = $OwnedProcessRegistry
    if ($null -eq $registry) { $registry = @{ CancelRequested = $false } }
    if (-not $registry.ContainsKey('CancelRequested')) { $registry.CancelRequested = $false }
    $session = $null; $state = 'TransientFailure'; $failure = ''; $plan = 'Unknown'
    $refreshed = $false; $clean = $true
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($NoRefresh -and $NeedsRefresh) { throw 'ACCOUNT_READ_ONLY_UNVERIFIED' }
        $deadline = [DateTime]::UtcNow.AddMilliseconds($PrimaryBudgetMilliseconds)
        $session = New-AccountSession $CodexHome 'AccountVerify' $registry $TestExecutablePath $TestProcessArguments
        Initialize-AccountSession $session $deadline
        $readDeadline = [DateTime]::UtcNow.AddMilliseconds(4000)
        if ($readDeadline -gt $deadline) { $readDeadline = $deadline }
        $readParameters = if ($NoRefresh) { @{ refreshToken = $false } } else { @{} }
        $result = Invoke-AccountRpc $session 'account/read' $readParameters $readDeadline
        $loaded = Get-AccountResultState $result
        if ($NoRefresh -and $loaded -eq 'NeedsRefresh') {
            $state = 'TransientFailure'; $failure = 'ACCOUNT_READ_ONLY_UNVERIFIED'
        }
        elseif ($loaded -in @('Unsupported','CredentialStoreMismatch')) { $state = $loaded }
        else {
            if ($loaded -eq 'NeedsRefresh') { $NeedsRefresh = $true }
            if ($NeedsRefresh) {
                $registry.Stage = 'ACCOUNT_REFRESH_START'
                $refreshed = $true
                $result = Invoke-AccountRpc $session 'account/read' @{ refreshToken = $true } $deadline
                $loaded = Get-AccountResultState $result
            }
            $state = switch ($loaded) {
                'Loaded' { 'Verified' }
                'NeedsRefresh' { 'ReauthRequired' }
                default { $loaded }
            }
        }
        if ($state -eq 'Verified') { $plan = Get-AccountSafePlan $result }
    } catch {
        $failure = [string]$_.Exception.Message
        $state = switch ($failure) {
            'ACCOUNT_PROTOCOL_UNSUPPORTED' { 'Unsupported' }
            'ACCOUNT_REAUTH_REQUIRED' { 'ReauthRequired' }
            default { 'TransientFailure' }
        }
        if ($failure -notmatch '^ACCOUNT_[A-Z_]+$') { $failure = 'ACCOUNT_TRANSIENT_FAILURE' }
    } finally {
        $clean = Close-AccountSession $session
        $result = $null
        if ($failure -ceq 'ACCOUNT_CLEANUP_FAILED') { $clean = $false }
        if (-not $clean) { $state = 'TransientFailure'; $failure = 'ACCOUNT_CLEANUP_FAILED' }
        $clock.Stop()
    }
    return [pscustomobject]@{
        VerificationState = $state; FailureCode = $failure; PlanType = $plan
        RefreshAttempted = $refreshed; CleanupSucceeded = $clean
        ElapsedMilliseconds = $clock.ElapsedMilliseconds
    }
}
function Invoke-QiehaoManagedLoginTransport {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$CodexHome,
        [hashtable]$OwnedProcessRegistry, [scriptblock]$BrowserProvider,
        [string]$TestExecutablePath, [string]$TestProcessArguments,
        [ValidateRange(100, 300000)][int]$LoginBudgetMilliseconds = 180000,
        [ValidateRange(100, 20000)][int]$InitializeBudgetMilliseconds = 5000,
        [ValidateRange(100, 20000)][int]$LoginStartBudgetMilliseconds = 15000,
        [ValidateRange(100, 5000)][int]$ReadBudgetMilliseconds = 3000,
        [scriptblock]$EventProvider)
    $registry = $OwnedProcessRegistry
    if ($null -eq $registry) { $registry = @{ CancelRequested = $false } }
    if (-not $registry.ContainsKey('CancelRequested')) { $registry.CancelRequested = $false }
    $session = $null; $loginId = $null; $complete = $false
    $loginPhase = 'Spawn'; $staleCompletions = 0; $accountUpdates = 0; $otherNotifications = 0; $completionRejected = $false
    $state = 'Failed'; $failure = ''; $plan = 'Unknown'; $cancelSent = $false; $clean = $true
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $timings = @{ AppServerSpawnMs = 0L; InitializeMs = 0L; LoginStartRpcMs = 0L; BrowserLaunchMs = 0L }
    $phase = [Diagnostics.Stopwatch]::StartNew()
    try {
        $registry.Stage = 'ACCOUNT_LOGIN_STARTING'
        $session = New-AccountSession $CodexHome 'AccountLogin' $registry $TestExecutablePath $TestProcessArguments
        $timings.AppServerSpawnMs = $phase.ElapsedMilliseconds
        $phase.Restart()
        $loginPhase = 'Initialize'
        try { Initialize-AccountSession $session ([DateTime]::UtcNow.AddMilliseconds($InitializeBudgetMilliseconds)) }
        finally { $timings.InitializeMs = $phase.ElapsedMilliseconds }
        $phase.Restart()
        $loginPhase = 'LoginStart'
        try { $started = Invoke-AccountRpc $session 'account/login/start' @{ type = 'chatgpt' } ([DateTime]::UtcNow.AddMilliseconds($LoginStartBudgetMilliseconds)) }
        finally { $timings.LoginStartRpcMs = $phase.ElapsedMilliseconds }
        if ([string](Get-AccountField $started 'type') -cne 'chatgpt') { throw 'ACCOUNT_PROTOCOL_UNSUPPORTED' }
        $loginId = Get-AccountField $started 'loginId'
        $url = [string](Get-AccountField $started 'authUrl')
        if ($loginId -isnot [string] -or [string]::IsNullOrWhiteSpace($loginId) -or
            -not (Test-QiehaoOfficialLoginUrl $url)) { throw 'ACCOUNT_LOGIN_RESPONSE_INVALID' }
        $registry.Stage = 'ACCOUNT_LOGIN_URL_READY'
        if ($null -ne $EventProvider) { $null = & $EventProvider 'ACCOUNT_LOGIN_URL_READY' $timings }
        $phase.Restart()
        $loginPhase = 'BrowserLaunch'
        try {
          if ($null -ne $BrowserProvider) { $null = & $BrowserProvider $url }
          else {
            $browserStart = New-Object Diagnostics.ProcessStartInfo
            $browserStart.FileName = $url
            $browserStart.UseShellExecute = $true
            # This is the user-requested interactive login, not a helper window.
            $browserStart.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
            $browserProcess = [Diagnostics.Process]::Start($browserStart)
            if ($null -ne $browserProcess) { $browserProcess.Dispose() }
          }
        } finally { $timings.BrowserLaunchMs = $phase.ElapsedMilliseconds }
        $url = $null; $started = $null
        # Only the browser ceremony receives the long interaction budget.
        $deadline = [DateTime]::UtcNow.AddMilliseconds($LoginBudgetMilliseconds)
        $loginPhase = 'WaitCompletion'
        while (-not $complete) {
            if ($registry.CancelRequested) { throw 'ACCOUNT_CANCELLED' }
            if ([DateTime]::UtcNow -ge $deadline) { throw 'ACCOUNT_TIMEOUT' }
            $message = $null
            if ($session.Notifications.Count -gt 0) {
                $message = $session.Notifications[0]; $session.Notifications.RemoveAt(0)
            } else { $message = Read-AccountMessage $session $deadline }
            if ([string](Get-AccountField $message 'method') -cne 'account/login/completed') {
                if ([string](Get-AccountField $message 'method') -ceq 'account/updated') { $accountUpdates++ }
                else { $otherNotifications++ }
                continue
            }
            $parameters = Get-AccountField $message 'params'
            if ([string](Get-AccountField $parameters 'loginId') -cne $loginId) { $staleCompletions++; continue }
            $success = Get-AccountField $parameters 'success'
            if ($success -isnot [bool]) { throw 'ACCOUNT_LOGIN_COMPLETION_INVALID' }
            if (-not $success) { $completionRejected = $true; throw 'ACCOUNT_LOGIN_REJECTED' }
            $complete = $true
        }
        $registry.Stage = 'ACCOUNT_LOGIN_COMPLETED'
        if ($null -ne $EventProvider) { $null = & $EventProvider 'ACCOUNT_LOGIN_COMPLETED' $timings }
        $readDeadline = [DateTime]::UtcNow.AddMilliseconds($ReadBudgetMilliseconds)
        $loginPhase = 'ReadAccount'
        $account = Invoke-AccountRpc $session 'account/read' @{ refreshToken = $false } $readDeadline
        if ((Get-AccountResultState $account) -cne 'Loaded') { throw 'ACCOUNT_LOGIN_VERIFY_FAILED' }
        $plan = Get-AccountSafePlan $account
        $state = 'Verified'
    } catch {
        $failure = [string]$_.Exception.Message
        $state = switch ($failure) {
            'ACCOUNT_PROTOCOL_UNSUPPORTED' { 'Unsupported' }
            'ACCOUNT_CANCELLED' { 'Cancelled' }
            'ACCOUNT_TIMEOUT' { 'Timeout' }
            default { 'Failed' }
        }
        if ($failure -notmatch '^ACCOUNT_[A-Z_]+$') { $failure = 'ACCOUNT_LOGIN_FAILED' }
        if ($failure -ceq 'ACCOUNT_PROTOCOL_CLOSED') {
            $exited = $false
            try { $exited = $session.Process.HasExited } catch { }
            $failure = if ($exited) { 'ACCOUNT_LOGIN_PROCESS_EXITED' } else { 'ACCOUNT_LOGIN_CONNECTION_CLOSED' }
        }
        elseif ($failure -ceq 'ACCOUNT_TIMEOUT') {
            $failure = switch ($loginPhase) {
                'Initialize' { 'ACCOUNT_LOGIN_INITIALIZE_TIMEOUT' }
                'LoginStart' { 'ACCOUNT_LOGIN_START_TIMEOUT' }
                'ReadAccount' { 'ACCOUNT_LOGIN_READ_TIMEOUT' }
                default { if ($staleCompletions -gt 0) { 'ACCOUNT_LOGIN_COMPLETION_ID_MISMATCH' } else { 'ACCOUNT_LOGIN_TIMEOUT' } }
            }
        }
    } finally {
        if ($null -ne $session -and $null -ne $loginId -and $state -ne 'Verified') {
            try {
                Send-AccountMessage $session @{ id = 999; method = 'account/login/cancel'; params = @{ loginId = $loginId } }
                $cancelSent = $true
                $cancelDeadline = [DateTime]::UtcNow.AddMilliseconds(350)
                while ([DateTime]::UtcNow -lt $cancelDeadline) {
                    $cancelReply = Read-AccountMessage $session $cancelDeadline -IgnoreCancellation
                    if ([string](Get-AccountField $cancelReply 'id') -ceq '999') { break }
                }
            } catch { }
        }
        $clean = Close-AccountSession $session
        if ($failure -ceq 'ACCOUNT_CLEANUP_FAILED') { $clean = $false }
        if (-not $clean) { $state = 'Failed'; $failure = 'ACCOUNT_CLEANUP_FAILED' }
        $loginId = $null; $url = $null; $started = $null; $message = $null; $account = $null
        $clock.Stop()
        $registry.LoginTimings = $timings
        $registry.LoginDiagnostics = @{
            LoginPhase = $loginPhase; FailureCode = $failure
            MismatchedCompletionCount = $staleCompletions; AccountUpdateCount = $accountUpdates
            OtherNotificationCount = $otherNotifications; CompletionRejected = $completionRejected
        }
    }
    return [pscustomobject]@{
        VerificationState = $state; FailureCode = $failure; PlanType = $plan
        CancelSent = $cancelSent; CleanupSucceeded = $clean; ElapsedMilliseconds = $clock.ElapsedMilliseconds
        AppServerSpawnMs = $timings.AppServerSpawnMs; InitializeMs = $timings.InitializeMs
        LoginStartRpcMs = $timings.LoginStartRpcMs; BrowserLaunchMs = $timings.BrowserLaunchMs
    }
}
Export-ModuleMember -Function @('Invoke-QiehaoAccountTransport','Invoke-QiehaoManagedLoginTransport')
