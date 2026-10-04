Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $project 'lib\CodexAuth.psm1') -Force -PassThru
$client = Import-Module (Join-Path $project 'tools\AccountClient.psm1') -PassThru
$root = Join-Path ([IO.Path]::GetTempPath()) ('Qiehao-ManagedLogin-' + [Guid]::NewGuid().ToString('N'))
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

function Login-Fake([string]$Scenario,[string]$Plan = 'plus',[int]$Budget = 4000) {
    $registry = [hashtable]::Synchronized(@{CancelRequested=$false;IsActive=$false;Opened=0})
    $browser = {param($url) $registry.Opened++; if ($Scenario -eq 'LoginCancel') { $registry.CancelRequested=$true } }.GetNewClosure()
    $r = Invoke-QiehaoManagedLoginTransport -CodexHome $fakeCodexHome -OwnedProcessRegistry $registry -BrowserProvider $browser `
        -TestExecutablePath $shellPath -TestProcessArguments (Fake-Arguments $Scenario $Plan) -LoginBudgetMilliseconds $Budget
    return [pscustomobject]@{Transport=$r;Registry=$registry}
}
function Managed-Add-Fake([string]$Name,[string]$Scenario,[string]$Plan='plus') {
    $registry = [hashtable]::Synchronized(@{CancelRequested=$false;IsActive=$false})
    return & $module {param($n,$c,$p,$s,$r,$exe,$a)
        Invoke-QiehaoManagedAdd -Name $n -CodexHome $c -ProfilesDirectory $p -StateDirectory $s `
            -OwnedProcessRegistry $r -BrowserProvider {param($url)} -ProcessData @() -UseProvidedProcessData `
            -TestExecutablePath $exe -TestProcessArguments $a -LoginBudgetMilliseconds 4000
    } $Name $fakeCodexHome $profiles $state $registry $shellPath (Fake-Arguments $Scenario $Plan)
}
try {
    & $module {param($l) $script:LogsDirectory=$l} $fakeLogs
    $a = New-FakeAuth 'fake-login-A'
    $b = New-FakeAuth 'fake-login-B'
    $freshHome = Join-Path $root 'first-login-codex'
    $freshProfiles = Join-Path $root 'first-login-profiles'
    $freshState = Join-Path $root 'first-login-state'
    foreach ($dir in @($freshHome,$freshProfiles,$freshState)) { $null = [IO.Directory]::CreateDirectory($dir) }
    [IO.File]::WriteAllBytes($replacement,$a)
    $r = & $module {param($c,$p,$s,$exe,$argsText)
        Invoke-QiehaoManagedAdd -Name First -CodexHome $c -ProfilesDirectory $p -StateDirectory $s `
            -BrowserProvider {param($url)} -ProcessData @() -UseProvidedProcessData `
            -TestExecutablePath $exe -TestProcessArguments $argsText -LoginBudgetMilliseconds 4000
    } $freshHome $freshProfiles $freshState $shellPath (Fake-Arguments Success)
    Assert-Account ($r.Result -ceq 'ADD_VERIFIED_SUCCESS' -and (Test-Path (Join-Path $freshProfiles 'First.auth.dpapi'))) 'FirstLoginWithoutExistingAuthOrActiveProfile'
    $null = Add-Fake A $a
    $freshA = New-FakeAuth 'fake-login-A' $false 'plus' 'latest-A'
    Set-FakeAuth $freshA
    [IO.File]::WriteAllBytes($replacement,$b)
    $r = Managed-Add-Fake B Success
    Assert-Account ($r.Result -ceq 'ADD_VERIFIED_SUCCESS') 'ManagedLoginAddsWithoutDesktop'
    $savedA = & $module {param($p) Read-CodexAccountSlotBytes -Name A -ProfilesDirectory $p} $profiles
    Assert-Account ([Convert]::ToBase64String($savedA) -ceq [Convert]::ToBase64String($freshA)) 'ActiveSavedBeforeNewOAuth'
    $r = Login-Fake LoginCancel
    Assert-Account ($r.Transport.VerificationState -ceq 'Cancelled' -and $r.Transport.CancelSent -and $r.Registry.Opened -eq 1 -and -not $r.Registry.IsActive) 'CancelCallsOfficialCancelAndCleansChild'
    $r = Login-Fake LoginTimeout 'plus' 850
    Assert-Account ($r.Transport.VerificationState -ceq 'Timeout' -and $r.Transport.CancelSent -and -not $r.Registry.IsActive) 'TimeoutCancelsAndCleansChild'
    $r = Login-Fake Success
    Assert-Account ($r.Transport.VerificationState -ceq 'Verified' -and $r.Registry.Opened -eq 1 -and -not $r.Registry.IsActive) 'BrowserActionAndEarlyNotificationHandled'
    $r = Login-Fake NeverExit
    Assert-Account ($r.Transport.VerificationState -ceq 'Verified' -and $r.Transport.CleanupSucceeded -and -not $r.Registry.IsActive) 'NonExitingOwnedChildCleanupHasNoResidue'
    $stale = @{CancelRequested=$false;IsActive=$false;ProcessId=123;ProcessStartTimeUtc=[DateTime]::UtcNow}
    $r = Invoke-QiehaoManagedLoginTransport -CodexHome $fakeCodexHome -OwnedProcessRegistry $stale `
        -BrowserProvider {param($url) throw 'BROWSER_MUST_NOT_OPEN'} `
        -TestExecutablePath (Join-Path $root 'does-not-exist.exe') -TestProcessArguments '' -LoginBudgetMilliseconds 1000
    Assert-Account ($r.VerificationState -ceq 'Failed' -and $r.CleanupSucceeded -and -not $stale.IsActive) 'StartFailureDoesNotReuseStaleOwnership'
    foreach ($scenario in @('LoginFailed','LoginReadFailed','Unsupported')) {
        Set-FakeAuth $b
        $beforeCount = @(Get-ChildItem -LiteralPath $profiles -File).Count
        $r = Managed-Add-Fake C $scenario
        $expected = if ($scenario -ceq 'Unsupported') { 'ACCOUNT_LOGIN_MANUAL_FALLBACK_REQUIRED' } else { 'ACCOUNT_LOGIN_FAILED' }
        Assert-Account ($r.Result -ceq $expected -and @(Get-ChildItem -LiteralPath $profiles -File).Count -eq $beforeCount) ($scenario+'NeverCreatesProfile')
        Assert-Account ([Convert]::ToBase64String($b) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fakeCodexHome 'auth.json')))) ($scenario+'RestoresPreviousAccount')
    }
    Set-FakeAuth $b
    [IO.File]::WriteAllBytes($replacement,(New-FakeAuth 'fake-login-C' $false 'team'))
    $caught = ''
    try { $r = Managed-Add-Fake C Success 'plus' } catch { $caught=$_.Exception.Message }
    Assert-Account ($caught -ceq 'ACCOUNT_LOGIN_IDENTITY_MISMATCH' -and -not (Test-Path (Join-Path $profiles 'C.auth.dpapi'))) 'LoginWorkspaceMismatchNeverSaves'
    Set-FakeAuth $b
    $r = Managed-Add-Fake C Success 'team'
    $workspace = & $module {param($p) $bytes=Read-CodexAccountSlotBytes -Name C -ProfilesDirectory $p; try { $c=Get-CodexAuthIdentityContext -Bytes $bytes; $c.WorkspaceClass } finally { Clear-CodexAuthIdentityContext $c; [Array]::Clear($bytes,0,$bytes.Length) }} $profiles
    Assert-Account ($r.Result -ceq 'ADD_VERIFIED_SUCCESS' -and $workspace -ceq 'Team') 'SyntheticTeamWorkspacePreserved'
    $stamp = [IO.File]::ReadAllText((Join-Path $fakeLogs 'qiehao.log'))
    Assert-Account ($stamp -notmatch 'authUrl|fake-login-[ABC]|fake-refresh|e30\.|authorization_code|state=fake') 'OAuthSecretsNeverLogged'
    $badUrls = @('http://auth.openai.com/','https://auth.openai.com.evil.invalid/','https://user@auth.openai.com/','file:///C:/example')
    foreach ($u in $badUrls) { Assert-Account (-not (& $client {param($u) Test-QiehaoOfficialLoginUrl $u} $u)) ('UnsafeUrlRejected'+$badUrls.IndexOf($u)) }
    $results.RealOAuthBrowserOpened=$false
    $results.RealAuthOrProfileRead=$false
    $results.RealNetworkRequests=$false
    $results.Status='PASS'
    [pscustomobject]$results
} finally {
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { [IO.Directory]::Delete($root,$true) }
}
