Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $project 'lib\CodexAuth.psm1') -Force -PassThru
$client = Import-Module (Join-Path $project 'tools\AccountClient.psm1') -PassThru
$root = Join-Path ([IO.Path]::GetTempPath()) ('Qiehao-AccountVerify-' + [Guid]::NewGuid().ToString('N'))
$fakeCodexHome = Join-Path $root 'codex'
$profiles = Join-Path $root 'profiles'
$state = Join-Path $root 'state'
$fakeLogs = Join-Path $root 'logs'
foreach ($path in @($root,$fakeCodexHome,$profiles,$state,$fakeLogs)) { $null = [IO.Directory]::CreateDirectory($path) }
$shellPath = (Get-Process -Id $PID).Path
$server = Join-Path $PSScriptRoot 'FakeAccountAppServer.ps1'
$trace = Join-Path $root 'trace.txt'
$replacement = Join-Path $root 'replacement.json'
$results = [ordered]@{}
$a = $null; $b = $null; $expired = $null; $latest = $null; $roundtrip = $null; $marker = $null
function Assert-Account($Condition,[string]$Name) {
    if (-not $Condition) {
        if ($null -ne (Get-Variable -Name r -ErrorAction SilentlyContinue)) { $r | Select-Object VerificationState, FailureCode, Result | Out-String | Write-Output }
        throw ('ACCOUNT_SELFTEST_' + $Name)
    }
    $results[$Name] = 'PASS'
}
function New-FakeAuth([string]$Id,[bool]$Expired = $false,[string]$Plan = 'plus',[string]$Nonce = 'old') {
    $encoding = New-Object Text.UTF8Encoding($false)
    $expiry = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 7200
    if ($Expired) { $expiry -= 8000 }
    $accessPayload = [Convert]::ToBase64String($encoding.GetBytes((@{exp=$expiry} | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
    $claims = @{ 'https://api.openai.com/auth' = @{chatgpt_account_id=$Id;chatgpt_user_id='fake-user';chatgpt_plan_type=$Plan} }
    $idPayload = [Convert]::ToBase64String($encoding.GetBytes(($claims | ConvertTo-Json -Depth 5 -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
    # Deliberately formatted, with unknown optional data. Saved bytes must match.
    return ,$encoding.GetBytes((@{auth_mode='chatgpt';OPENAI_API_KEY=$null;tokens=@{account_id=$Id;access_token=('e30.'+$accessPayload+'.fake');refresh_token=('fake-refresh-'+$Nonce);id_token=('e30.'+$idPayload+'.fake')};last_refresh='2026-01-01T00:00:00Z';future_optional=@{nonce=$Nonce}} | ConvertTo-Json -Depth 6))
}
function Fake-Arguments([string]$Scenario,[string]$Plan = 'plus') {
    return ('-NoProfile -ExecutionPolicy Bypass -File "{0}" -Scenario "{1}" -ReplacementPath "{2}" -TracePath "{3}" -Plan "{4}"' -f $server,$Scenario,$replacement,$trace,$Plan)
}
function Set-FakeAuth([byte[]]$Bytes) { [IO.File]::WriteAllBytes((Join-Path $fakeCodexHome 'auth.json'),$Bytes) }
function Add-Fake([string]$Name,[byte[]]$Bytes) {
    Set-FakeAuth $Bytes
    return & $module {param($n,$c,$p,$s) Invoke-AddCodexProfile -Name $n -CodexHome $c -ProfilesDirectory $p -StateDirectory $s -ProcessData @() -UseProvidedProcessData} $Name $fakeCodexHome $profiles $state
}
function Verify-Fake([string]$Name,[string]$Scenario,[string]$Plan = 'plus',[int]$Budget = 4800) {
    $registry = [hashtable]::Synchronized(@{CancelRequested=$false;IsActive=$false})
    return & $module {param($n,$c,$p,$r,$exe,$a,$b)
        Invoke-QiehaoAccountVerification -Name $n -CodexHome $c -ProfilesDirectory $p -OwnedProcessRegistry $r `
            -ProcessData @() -UseProvidedProcessData -TestExecutablePath $exe -TestProcessArguments $a -PrimaryBudgetMilliseconds $b
    } $Name $fakeCodexHome $profiles $registry $shellPath (Fake-Arguments $Scenario $Plan) $Budget
}
function Switch-Fake([string]$Name,[string]$Scenario,[int]$Budget = 4800) {
    return & $module {param($n,$c,$p,$s,$exe,$a,$b)
        Invoke-QiehaoVerifiedSwitch -Name $n -CodexHome $c -ProfilesDirectory $p -StateDirectory $s `
            -ProcessData @() -UseProvidedProcessData -TestExecutablePath $exe -TestProcessArguments $a -PrimaryBudgetMilliseconds $b
    } $Name $fakeCodexHome $profiles $state $shellPath (Fake-Arguments $Scenario) $Budget
}
try {
    & $module {param($l) $script:LogsDirectory=$l} $fakeLogs
    $a = New-FakeAuth 'fake-A'
    $b = New-FakeAuth 'fake-B'
    $null = Add-Fake 'A' $a
    $null = Add-Fake 'B' $b
    [IO.File]::WriteAllBytes($replacement,$b)
    $r = Verify-Fake 'B' 'Success'
    Assert-Account ($r.VerificationState -ceq 'Verified') 'FastReadVerified'
    Assert-Account (([IO.File]::ReadAllText($trace)) -notmatch 'account/read:True') 'UnexpiredTokenDoesNotRefresh'
    $expired = New-FakeAuth 'fake-B' $true
    $latest = New-FakeAuth 'fake-B' $false 'plus' 'new'
    Set-FakeAuth $expired
    [IO.File]::WriteAllBytes($replacement,$latest)
    $marker = [IO.File]::ReadAllBytes((Join-Path $profiles 'B.identity.dpapi'))
    $r = Verify-Fake 'B' 'Success'
    $roundtrip = & $module {param($p) Read-CodexAccountSlotBytes -Name B -ProfilesDirectory $p} $profiles
    Assert-Account ($r.VerificationState -ceq 'Verified' -and [Convert]::ToBase64String($latest) -ceq [Convert]::ToBase64String($roundtrip)) 'TokenRefreshPersistsLatestAuth'
    Assert-Account ([Convert]::ToBase64String($marker) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $profiles 'B.identity.dpapi')))) 'RefreshPreservesIdentityMarker'
    Set-FakeAuth $expired
    $r = Verify-Fake 'B' 'Permanent'
    Assert-Account ($r.VerificationState -ceq 'ReauthRequired') 'PermanentAuthFailureDoesNotReportSuccess'
    Set-FakeAuth $latest
    & $module {param($p,$b) Save-QiehaoRefreshedProfileBytes -Name A -AuthBytes $b -ProfilesDirectory $p} $profiles (New-FakeAuth 'fake-A' $true)
    $r = Switch-Fake A Permanent
    Assert-Account ($r.Result -ceq 'SWITCH_REAUTH_REQUIRED') 'PermanentSwitchNeverReportsSuccess'
    Set-FakeAuth $latest
    & $module {param($s) Write-ActiveProfileState -Name B -StateDirectory $s} $state
    Set-FakeAuth $latest
    $r = Verify-Fake 'B' 'OldFields'
    Assert-Account ($r.VerificationState -ceq 'Unsupported') 'OldProtocolUnverified'
    $r = Verify-Fake 'B' 'Success' 'team'
    Assert-Account ($r.VerificationState -ceq 'IdentityMismatch') 'OfficialPlanFileWorkspaceMismatchFailClosed'
    $r = Verify-Fake 'B' 'TransientRpc'
    Assert-Account ($r.VerificationState -ceq 'TransientFailure') 'NetworkErrorsNeverBecomeReauthRequired'
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $r = Switch-Fake 'A' 'Timeout' 700
    $active = & $module {param($s) Read-ActiveProfileState -StateDirectory $s} $state
    Assert-Account ($r.Result -ceq 'SWITCH_AUTH_UNVERIFIED_TRANSIENT' -and $active.ActiveProfile -ceq 'A') 'TransientVerifyDoesNotRollbackLocalSwitch'
    Assert-Account $r.LocalCommitted 'TransientResultExplicitlyLocallyCommitted'
    $again = ''
    try { $null = & $module {param($c,$p,$s) Invoke-CodexAccountSwitch -Name A -CodexHome $c -ProfilesDirectory $p -StateDirectory $s -ProcessData @() -UseProvidedProcessData} $fakeCodexHome $profiles $state } catch { $again = $_.Exception.Message }
    Assert-Account ($again -ceq 'ALREADY_ACTIVE') 'SecondTargetSwitchAlreadyActiveAfterTransient'
    $transientLog = @(Get-Content -LiteralPath (Join-Path $fakeLogs 'qiehao.log') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.result -ceq 'SWITCH_AUTH_UNVERIFIED_TRANSIENT' })
    Assert-Account ($transientLog.Count -eq 1 -and $transientLog[0].event -ceq 'SWITCH_UNVERIFIED' -and $transientLog[0].data.LocalCommitted) 'TransientNeverLoggedAsSwitchFailure'
    Assert-Account ($watch.ElapsedMilliseconds -lt 10000) 'AccountVerifyHasBoundedDeadline'
    [IO.File]::WriteAllBytes($replacement,(New-FakeAuth 'fake-X'))
    Set-FakeAuth (New-FakeAuth 'fake-A' $true)
    $stamp = (Get-FileHash (Join-Path $profiles 'A.auth.dpapi')).Hash
    $r = Verify-Fake 'A' 'Success'
    Assert-Account ($r.VerificationState -ceq 'IdentityMismatch' -and $stamp -ceq (Get-FileHash (Join-Path $profiles 'A.auth.dpapi')).Hash) 'RefreshDifferentIdentityNeverUpdatesProfile'
    Set-FakeAuth $a
    # Force target refresh, then fake refresh changes it to X: rollback to A.
    & $module {param($p,$b) Save-QiehaoRefreshedProfileBytes -Name B -AuthBytes $b -ProfilesDirectory $p} $profiles $expired
    $r = Switch-Fake 'B' 'Success'
    $active = & $module {param($s) Read-ActiveProfileState -StateDirectory $s} $state
    Assert-Account ($r.Result -ceq 'SWITCH_POST_VERIFY_IDENTITY_MISMATCH' -and $active.ActiveProfile -ceq 'A' -and [Convert]::ToBase64String($a) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fakeCodexHome 'auth.json')))) 'PostVerifyMismatchRollsBackWithoutContamination'
    Set-FakeAuth $a
    $r = Switch-Fake B RefreshMalformed
    $active = & $module {param($s) Read-ActiveProfileState -StateDirectory $s} $state
    Assert-Account ($r.Result -ceq 'SWITCH_POST_VERIFY_IDENTITY_MISMATCH' -and $active.ActiveProfile -ceq 'A' -and
        [Convert]::ToBase64String($a) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fakeCodexHome 'auth.json')))) 'MalformedRefreshRollsBackAndNeverBecomesNetworkFailure'
    foreach ($mode in @('keyring','ephemeral','auto')) {
        $info = Get-CodexCredentialSourceInfo -CodexHome $fakeCodexHome -UseProvidedConfigText -ConfigText ('cli_auth_credentials_store = "'+$mode+'"')
        Assert-Account (-not $info.FileCredentialUsable) ($mode+'FailClosed')
    }
    $info = Get-CodexCredentialSourceInfo -CodexHome $fakeCodexHome -UseProvidedConfigText -ConfigText 'cli_auth_credentials_store = "file"'
    Assert-Account $info.FileCredentialUsable 'ExplicitFileUsable'
    $gate = Test-CodexProcessesStopped -ProcessData @()
    Assert-Account $gate.SafeToSave 'StoppedProcessFastPathDoesNotWait'
    $inactive = & $module {param($c,$p,$s) Invoke-QiehaoLayeredVerify -Name B -CodexHome $c -ProfilesDirectory $p -StateDirectory $s -ProcessData @() -UseProvidedProcessData} $fakeCodexHome $profiles $state
    Assert-Account ($inactive.Result -ceq 'PROFILE_INTEGRITY_ONLY_SUCCESS') 'InactiveVerifyNeverWritesAuthOrStartsChild'
    & $module { Assert-CodexNotRunning -ProcessData @() -UseProvidedProcessData -DelayProvider { throw 'STOPPED_MUST_NOT_WAIT' } }
    Assert-Account $true 'StoppedFastPathHasNoDelayCall'
    foreach ($scenario in @('Success','Unsupported','PermanentRead')) {
        $candidate = New-FakeAuth ('fake-manual-'+$scenario)
        Set-FakeAuth $candidate
        $name = 'Manual'+$scenario
        $r = & $module {param($n,$c,$p,$s,$exe,$argsText)
            Invoke-QiehaoVerifiedLocalAdd -Name $n -CodexHome $c -ProfilesDirectory $p -StateDirectory $s `
                -ProcessData @() -UseProvidedProcessData -TestExecutablePath $exe -TestProcessArguments $argsText
        } $name $fakeCodexHome $profiles $state $shellPath (Fake-Arguments $scenario)
        $expected = switch ($scenario) { Success {'ADD_VERIFIED_SUCCESS'} Unsupported {'ADD_SUCCESS_UNVERIFIED'} PermanentRead {'ADD_REAUTH_REQUIRED'} }
        Assert-Account ($r.Result -ceq $expected) ('ManualFallback'+$scenario)
        Assert-Account ((Test-Path (Join-Path $profiles ($name+'.auth.dpapi'))) -eq ($scenario -cne 'PermanentRead')) ('ManualSavePolicy'+$scenario)
        [Array]::Clear($candidate,0,$candidate.Length)
    }
    $log = [IO.File]::ReadAllText((Join-Path $fakeLogs 'qiehao.log'))
    Assert-Account ($log -notmatch 'fake-refresh|e30\.|authUrl|fake-login|fake-A|fake-B|fake-X') 'DiagnosticsContainNoSensitiveFixtures'
    $results.RealAuthOrProfileRead = $false
    $results.RealNetworkRequests = $false
    $results.IdentityCrossContamination = 0
    $results.ProfileFormatChanged = $false
    $results.Status = 'PASS'
    [pscustomobject]$results
} finally {
    foreach ($buffer in @($a,$b,$expired,$latest,$roundtrip,$marker)) { if ($null -ne $buffer) { [Array]::Clear($buffer,0,$buffer.Length) } }
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { [IO.Directory]::Delete($root,$true) }
}
