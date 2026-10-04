Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$core = Import-Module (Join-Path $project 'lib\CodexAuth.psm1') -Force -PassThru
$client = Import-Module (Join-Path $project 'tools\AccountClient.psm1') -Force -PassThru
$root = Join-Path ([IO.Path]::GetTempPath()) ('Qiehao-SequentialLogin-' + [Guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $root 'codex'; $profiles = Join-Path $root 'profiles'; $state = Join-Path $root 'state'; $logs = Join-Path $root 'logs'
foreach ($dir in @($root,$fakeHome,$profiles,$state,$logs)) { $null = [IO.Directory]::CreateDirectory($dir) }
$shellPath = (Get-Process -Id $PID).Path
$server = Join-Path $PSScriptRoot 'FakeAccountAppServer.ps1'
$replacement = Join-Path $root 'fake-replacement.json'; $trace = Join-Path $root 'fake-trace.txt'
$results = [ordered]@{}; $ownedPids = New-Object 'Collections.Generic.List[int]'
$registry = [hashtable]::Synchronized(@{CancelRequested=$false;IsActive=$false})
$a=$null; $b=$null; $c=$null; $d=$null
function Assert-Sequential([bool]$Condition,[string]$Name) { if (-not $Condition) { throw ('SEQUENTIAL_LOGIN_'+$Name) }; $results[$Name]='PASS' }
function New-FakeAuth([string]$Id) {
    $utf8 = New-Object Text.UTF8Encoding($false)
    $claims = @{'https://api.openai.com/auth'=@{chatgpt_account_id=$Id;chatgpt_user_id='fake-user';chatgpt_plan_type='team'}}
    $payload = [Convert]::ToBase64String($utf8.GetBytes(($claims | ConvertTo-Json -Depth 5 -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
    return ,$utf8.GetBytes((@{auth_mode='chatgpt';OPENAI_API_KEY=$null;tokens=@{account_id=$Id;access_token='FAKE-ACCESS';refresh_token='FAKE-REFRESH';id_token=('e30.'+$payload+'.fake')};last_refresh='2000-01-01T00:00:00Z';future_optional=@{preserve=$true}} | ConvertTo-Json -Depth 6))
}
function Fake-Arguments([string]$Scenario) { return ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Scenario "{1}" -ReplacementPath "{2}" -TracePath "{3}" -Plan team' -f $server,$Scenario,$replacement,$trace) }
function Read-FakeActive { return & $core {param($s) (Read-ActiveProfileState -StateDirectory $s).ActiveProfile} $state }
function Get-FakeLog { return @([IO.File]::ReadAllLines((Join-Path $logs 'qiehao.log')) | ForEach-Object { $_ | ConvertFrom-Json }) }
function Run-FakeLogin([string]$Name,[string]$Scenario,[byte[]]$Bytes,[string]$BrowserMode='Normal') {
    [IO.File]::WriteAllBytes($replacement,$Bytes)
    $registry.CancelRequested=$false
    $browser = {param($url)
        if ($BrowserMode -ceq 'Cancel') { $registry.CancelRequested=$true }
        if ($BrowserMode -ceq 'Fail') { throw 'FAKE_BROWSER_OPEN_FAILURE' }
    }.GetNewClosure()
    $before = @(Get-FakeLog | Where-Object event -CEQ ACCOUNT_LOGIN_START).Count
    $traceBefore = if ([IO.File]::Exists($trace)) { [IO.File]::ReadAllLines($trace).Count } else { 0 }
    $result = $null; $caught = ''
    try {
        $result = & $core {param($n,$c,$p,$s,$r,$browser,$exe,$argsText)
            Invoke-QiehaoManagedAdd -Name $n -CodexHome $c -ProfilesDirectory $p -StateDirectory $s -OwnedProcessRegistry $r `
                -BrowserProvider $browser -ProcessData @() -UseProvidedProcessData -TestExecutablePath $exe -TestProcessArguments $argsText -LoginBudgetMilliseconds 700
        } $Name $fakeHome $profiles $state $registry $browser $shellPath (Fake-Arguments $Scenario)
    } catch { $caught = $_.Exception.Message }
    if ($registry.ProcessId) { $ownedPids.Add([int]$registry.ProcessId) }
    $entries = Get-FakeLog
    $starts = @($entries | Where-Object event -CEQ ACCOUNT_LOGIN_START)
    Assert-Sequential ($starts.Count -eq $before+1) ($Name+$Scenario+'OneStart')
    $id = $starts[-1].data.OperationId
    $ends = @($entries | Where-Object { $_.event -ceq 'ACCOUNT_LOGIN_FINISH' -and $_.data.OperationId -ceq $id })
    $terminal = @($entries | Where-Object { $_.event -in @('ACCOUNT_LOGIN_SUCCEEDED','ACCOUNT_LOGIN_FAILED','ACCOUNT_LOGIN_CANCELLED','ACCOUNT_LOGIN_TIMEOUT','ACCOUNT_LOGIN_MANUAL_RECOVERY_REQUIRED') -and $_.data.OperationId -ceq $id })
    Assert-Sequential ($ends.Count -eq 1 -and $terminal.Count -eq 1 -and $registry.OperationFinished -and -not $registry.IsActive) ($Name+$Scenario+'ExactlyOnceFinishedAndChildCleaned')
    $newTrace=@([IO.File]::ReadAllLines($trace) | Select-Object -Skip $traceBefore)
    Assert-Sequential (@($newTrace | Where-Object {$_ -like 'account/login/cancel:*'}).Count -le 1) ($Name+$Scenario+'CancelSentAtMostOnce')
    foreach ($key in @('AppServerSpawnMs','InitializeMs','LoginStartRpcMs','BrowserLaunchMs')) {
        Assert-Sequential ($null -ne $ends[0].data.PSObject.Properties[$key] -and $ends[0].data.$key -isnot [string] -and $ends[0].data.$key -ge 0) ($Name+$Scenario+$key+'Numeric')
    }
    return [pscustomobject]@{Result=$result;ErrorCode=$caught;FinalState=$ends[0].data.FinalState;OperationId=$id}
}
try {
    & $core {param($l) $script:LogsDirectory=$l} $logs
    # Seed the fake log so the initial count can use the same safe reader.
    [IO.File]::WriteAllText((Join-Path $logs 'qiehao.log'),'')
    $a=New-FakeAuth 'fake-sequential-A'; $b=New-FakeAuth 'fake-sequential-B'; $c=New-FakeAuth 'fake-sequential-C'
    $r=Run-FakeLogin A Success $a
    Assert-Sequential ($r.Result.Result -ceq 'ADD_VERIFIED_SUCCESS' -and (Read-FakeActive) -ceq 'A') 'FirstSuccess'
    $r=Run-FakeLogin B Success $b
    Assert-Sequential ($r.Result.Result -ceq 'ADD_VERIFIED_SUCCESS' -and (Read-FakeActive) -ceq 'B') 'SecondSuccessWithoutRestart'
    $r=Run-FakeLogin Candidate LoginFailed $c
    Assert-Sequential ($r.FinalState -ceq 'FAILED' -and (Read-FakeActive) -ceq 'B') 'FailureRestoresPreLoginActive'
    $r=Run-FakeLogin C Success $c
    Assert-Sequential ($r.Result.Result -ceq 'ADD_VERIFIED_SUCCESS' -and (Read-FakeActive) -ceq 'C') 'SuccessFailureSuccessWithoutRestart'
    Assert-Sequential ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fakeHome 'auth.json'))) -ceq [Convert]::ToBase64String($c)) 'SuccessfulAddNotRolledBack'
    foreach ($scenario in @('LoginFailed','LoginReadFailed','LoginReadTimeout','Unsupported','IdentityMalformed','ChildCrash','LoginCallbackMismatch','LoginTimeout')) {
        $r=Run-FakeLogin Candidate $scenario $a
        Assert-Sequential ((Read-FakeActive) -ceq 'C' -and -not [IO.File]::Exists((Join-Path $profiles 'Candidate.auth.dpapi')) -and
            [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fakeHome 'auth.json'))) -ceq [Convert]::ToBase64String($c)) ($scenario+'RestoresAuthAndActive')
    }
    foreach ($mode in @('Cancel','Fail')) {
        $r=Run-FakeLogin Candidate LoginTimeout $a $mode
        Assert-Sequential ((Read-FakeActive) -ceq 'C' -and $r.FinalState -ceq $(if ($mode -ceq 'Cancel') {'CANCELLED'} else {'FAILED'})) ($mode+'RestoresActive')
    }
    $r=Run-FakeLogin Duplicate Success $c
    Assert-Sequential ($r.ErrorCode -ceq 'PROFILE_IDENTITY_ALREADY_EXISTS' -and (Read-FakeActive) -ceq 'C' -and -not (Test-Path (Join-Path $profiles 'Duplicate.auth.dpapi'))) 'DuplicateNeverCreatesProfile'
    $d=New-FakeAuth 'fake-sequential-D'
    $r=Run-FakeLogin C Success $d
    Assert-Sequential ($r.ErrorCode -ne '' -and (Read-FakeActive) -ceq 'C' -and @(Get-ChildItem -LiteralPath $profiles -Filter '*.auth.dpapi').Count -eq 3) 'AddFailureRestoresActiveAndNoPartialProfile'
    $readBody=& $core { (Get-Command Read-CodexAccountSlotBytes).ScriptBlock }
    try {
        & $core {param($body) $script:fakeOriginalRead=$body; function script:Read-CodexAccountSlotBytes {param($Name,$ProfilesDirectory) if ($Name -ceq 'Candidate') {throw 'PROFILE_ADD_VERIFICATION_FAILED'}; return & $script:fakeOriginalRead -Name $Name -ProfilesDirectory $ProfilesDirectory}} $readBody
        $r=Run-FakeLogin Candidate Success $d
        Assert-Sequential ($r.ErrorCode -ceq 'PROFILE_ADD_VERIFICATION_FAILED' -and (Read-FakeActive) -ceq 'C' -and @(Get-ChildItem -LiteralPath $profiles -Filter 'Candidate.*').Count -eq 0) 'AddReadbackFailureRollsBackBeforeManagedRestore'
    } finally { & $core {param($body) Set-Item -LiteralPath Function:Read-CodexAccountSlotBytes -Value $body} $readBody }
    # Stage budgets are independent and test-scaled; no real login/network.
    foreach ($scenario in @('InitializeTimeout','LoginStartTimeout','LoginReadTimeout')) {
        $registry.CancelRequested=$false
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $r=Invoke-QiehaoManagedLoginTransport -CodexHome $fakeHome -OwnedProcessRegistry $registry -BrowserProvider {param($url)} `
            -TestExecutablePath $shellPath -TestProcessArguments (Fake-Arguments $scenario) -InitializeBudgetMilliseconds 1800 -LoginStartBudgetMilliseconds 250 -ReadBudgetMilliseconds 250 -LoginBudgetMilliseconds 5000
        Assert-Sequential ($r.VerificationState -ceq 'Timeout' -and $clock.ElapsedMilliseconds -lt 5000 -and -not $registry.IsActive) ($scenario+'ShortBudgetNotBrowserBudget')
        if ($registry.ProcessId) { $ownedPids.Add([int]$registry.ProcessId) }
    }
    # Fault injection AFTER actual owned-child cleanup tests fail-closed recovery,
    # without leaving any helper or touching a real Codex process.
    $closeBody = & $client { (Get-Command Close-AccountSession).ScriptBlock }
    [IO.File]::WriteAllBytes((Join-Path $fakeHome 'auth.json'),$c)
    try {
        & $client {param($body) $script:fakeOriginalClose=$body; function script:Close-AccountSession { param($session) $null=& $script:fakeOriginalClose $session; return $false }} $closeBody
        $r=Run-FakeLogin Candidate Success $d
        Assert-Sequential ($r.FinalState -ceq 'MANUAL_RECOVERY_REQUIRED' -and $r.ErrorCode -ceq 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED' -and (Read-FakeActive) -ceq 'C') 'CleanupFailureManualRecoveryTerminal'
    } finally { & $client {param($body) Set-Item -LiteralPath Function:Close-AccountSession -Value $body} $closeBody }
    $restoreBody=& $core { (Get-Command Restore-QiehaoSwitchAfterIdentityMismatch).ScriptBlock }
    try {
        & $core {function script:Restore-QiehaoSwitchAfterIdentityMismatch {param($Name,$CodexHome,$ProfilesDirectory,$StateDirectory,$ProcessData,[switch]$UseProvidedProcessData) throw 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED'}}
        $r=Run-FakeLogin Candidate LoginFailed $d
        Assert-Sequential ($r.FinalState -ceq 'MANUAL_RECOVERY_REQUIRED' -and $r.ErrorCode -ceq 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED' -and -not (Test-Path (Join-Path $profiles 'Candidate.auth.dpapi'))) 'RestoreCannotConfirmNeverClaimsSuccess'
    } finally {
        & $core {param($body,$c,$p,$s) Set-Item -LiteralPath Function:Restore-QiehaoSwitchAfterIdentityMismatch -Value $body; Restore-QiehaoSwitchAfterIdentityMismatch -Name C -CodexHome $c -ProfilesDirectory $p -StateDirectory $s -ProcessData @() -UseProvidedProcessData} $restoreBody $fakeHome $profiles $state
    }
    # Last proof: after all failure/cancel cases another valid login still works.
    $r=Run-FakeLogin D Success $d
    Assert-Sequential ($r.Result.Result -ceq 'ADD_VERIFIED_SUCCESS' -and (Read-FakeActive) -ceq 'D') 'FinalSuccessWithoutRestart'
    $entries=Get-FakeLog; $starts=@($entries | Where-Object event -CEQ ACCOUNT_LOGIN_START); $ends=@($entries | Where-Object event -CEQ ACCOUNT_LOGIN_FINISH)
    Assert-Sequential ($starts.Count -eq $ends.Count -and @($starts.data.OperationId | Sort-Object -Unique).Count -eq $starts.Count) 'StartedLoginOperationsEqualFinishedOperations'
    $sessions=@([IO.File]::ReadAllLines($trace) | Where-Object {$_ -like 'SESSION:*'})
    Assert-Sequential (@($sessions | Sort-Object -Unique).Count -eq $sessions.Count) 'IndependentChildAndLoginIdsEverySession'
    Assert-Sequential (@(Get-Process -Id @($ownedPids) -ErrorAction SilentlyContinue).Count -eq 0) 'NoOwnedAppServerLeak'
    $log=[IO.File]::ReadAllText((Join-Path $logs 'qiehao.log'))
    Assert-Sequential ($log -notmatch 'loginId|authUrl|fake-sequential|FAKE-ACCESS|FAKE-REFRESH|e30\.|state=fake') 'NoLoginIdOrAuthSecretsLogged'
    $results.StartedLoginOperationsEqualFinishedOperations=$true
    $results.SequentialLoginRequiresAppRestart=$false
    $results.PreLoginActiveRestoredOnFailure=$true
    $results.SuccessfulAddNotRolledBack=$true
    $results.NoOwnedAppServerLeak=$true
    $results.RealAuthOrProfileRead=$false; $results.RealOAuthBrowserOpened=$false; $results.RealNetworkRequests=$false; $results.Status='PASS'
    [pscustomobject]$results
} finally {
    foreach ($bytes in @($a,$b,$c,$d)) { if ($null -ne $bytes) { [Array]::Clear($bytes,0,$bytes.Length) } }
    $resolved=[IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { [IO.Directory]::Delete($resolved,$true) }
}
