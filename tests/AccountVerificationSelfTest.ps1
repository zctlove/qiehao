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
function Transport-Fake([string]$Scenario,[bool]$NeedsRefresh = $false) {
    $registry = [hashtable]::Synchronized(@{CancelRequested=$false;IsActive=$false})
    return & $client {param($c,$r,$refresh,$exe,$a)
        Invoke-QiehaoAccountTransport -CodexHome $c -OwnedProcessRegistry $r -NeedsRefresh $refresh `
            -TestExecutablePath $exe -TestProcessArguments $a -PrimaryBudgetMilliseconds 8000
    } $fakeCodexHome $registry $NeedsRefresh $shellPath (Fake-Arguments $Scenario)
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
    [IO.File]::WriteAllText($trace,'')
    $r = Transport-Fake 'SlowFirstRead'
    $reads = @([IO.File]::ReadAllLines($trace) | Where-Object { $_ -like 'account/read:*' })
    Assert-Account ($r.VerificationState -ceq 'Verified' -and $r.CleanupSucceeded -and
        $r.ElapsedMilliseconds -ge 3000 -and $reads.Count -eq 1) 'ThreeSecondReadVerifiedWith8000Budget'
    [IO.File]::WriteAllText($trace,'')
    $r = Transport-Fake 'FirstReadOverBudget'
    $reads = @([IO.File]::ReadAllLines($trace) | Where-Object { $_ -like 'account/read:*' })
    Assert-Account ($r.VerificationState -ceq 'TransientFailure' -and $r.FailureCode -ceq 'ACCOUNT_TIMEOUT' -and
        $r.CleanupSucceeded -and $r.ElapsedMilliseconds -lt 8000 -and $reads.Count -eq 1) 'FirstReadStillTimesOutWithoutRetry'
    [IO.File]::WriteAllText($trace,'')
    $r = Transport-Fake 'RefreshOverBudget' $true
    $reads = @([IO.File]::ReadAllLines($trace) | Where-Object { $_ -like 'account/read:*' })
    Assert-Account ($r.VerificationState -ceq 'TransientFailure' -and $r.FailureCode -ceq 'ACCOUNT_TIMEOUT' -and
        $r.RefreshAttempted -and $r.CleanupSucceeded -and $r.ElapsedMilliseconds -lt 12000 -and
        $reads.Count -eq 2 -and $reads[0] -ceq 'account/read:False' -and
        $reads[1] -ceq 'account/read:True') 'RefreshUsesRemainingOverallBudgetWithoutRetry'
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
    # P0: real functions against disposable identities only.
    $team = New-FakeAuth 'fake-recovery-team' $false 'team'
    $null = Add-Fake 'Team8' $team
    Set-FakeAuth $a
    function Recovery-Consent {
        & $module {param($c,$p,$s) Get-QiehaoRecoveryConsent -Name Team8 -CodexHome $c -ProfilesDirectory $p -StateDirectory $s} $fakeCodexHome $profiles $state
    }
    function Recovery-Switch($Consent,[string]$Scenario='Success') {
        & $module {param($c,$p,$s,$consent,$exe,$argsText,$budget)
            Invoke-QiehaoVerifiedSwitch -Name Team8 -CodexHome $c -ProfilesDirectory $p -StateDirectory $s -IdentityRecoveryConsent $consent `
                -ProcessData @() -UseProvidedProcessData -TestExecutablePath $exe -TestProcessArguments $argsText -PrimaryBudgetMilliseconds $budget
        } $fakeCodexHome $profiles $state $Consent $shellPath (Fake-Arguments $Scenario team) $(if($Scenario -ceq 'Timeout'){700}else{4800})
    }
    function Fake-ProfileStamp {
        (@(Get-ChildItem -LiteralPath $profiles -File | Sort-Object Name | ForEach-Object{(Get-FileHash -LiteralPath $_.FullName).Hash}) -join '|')
    }
    $profileStamp = Fake-ProfileStamp
    $consent = Recovery-Consent
    $caught='';try {$null=Recovery-Switch $null} catch {$caught=$_.Exception.Message}
    Assert-Account ($caught -ceq 'ACTIVE_PROFILE_OUT_OF_SYNC' -and (Fake-ProfileStamp) -ceq $profileStamp) 'DivergentSameNameRequiresConfirmation'
    $guiAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'gui\QiehaoGui.ps1'),[ref]$null,[ref]$null)
    $showFn=$guiAst.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq 'Show-QiehaoSwitchResult'},$true)
    . ([scriptblock]::Create($showFn.Extent.Text))
    function Get-CodexIdentityRecoveryConsent {param($Name) Recovery-Consent}
    function Get-QiehaoGuiText {param($Key) $Key}
    function Format-QiehaoGuiText {param($Key,$Arguments) $Key}
    function Show-QiehaoChoiceDialog {param($Title,$Message,$ConfirmText,$ConfirmStyle) $false}
    function Invoke-QiehaoResponsiveLifecycle {throw 'CANCEL_MUST_NOT_CALL_SWITCH'}
    $authStamp=(Get-FileHash (Join-Path $fakeCodexHome 'auth.json')).Hash
    $stateStamp=(Get-FileHash (Join-Path $state 'active-profile.json')).Hash
    Show-QiehaoSwitchResult -Result ([pscustomobject]@{ResultCode='ACTIVE_PROFILE_OUT_OF_SYNC'}) -TargetProfile Team8
    Assert-Account ((Get-FileHash (Join-Path $fakeCodexHome 'auth.json')).Hash -ceq $authStamp -and (Get-FileHash (Join-Path $state 'active-profile.json')).Hash -ceq $stateStamp -and (Fake-ProfileStamp) -ceq $profileStamp) 'GuiCancelChangesNoCredentialsOrState'
    Set-FakeAuth (New-FakeAuth 'fake-A' $false plus changed)
    $caught='';try {$null=Recovery-Switch $consent} catch {$caught=$_.Exception.Message}
    Assert-Account ($caught -ceq 'IDENTITY_RECOVERY_STATE_CHANGED') 'ChangedAuthorizationRequiresFreshConsent'
    Set-FakeAuth $a
    $consent=Recovery-Consent
    $consentBody=& $module {(Get-Command Get-QiehaoRecoveryConsent).ScriptBlock}
    try {
        & $module {param($body,$changed)
            $script:fakeConsentBody=$body;$script:fakeChangedAuth=$changed;$script:fakeConsentReads=0
            function script:Get-QiehaoRecoveryConsent {param($Name,$CodexHome,$ProfilesDirectory,$StateDirectory)
                $script:fakeConsentReads++
                if ($script:fakeConsentReads -eq 2) {[IO.File]::WriteAllBytes((Join-Path $CodexHome 'auth.json'),$script:fakeChangedAuth)}
                & $script:fakeConsentBody @PSBoundParameters
            }
        } $consentBody (New-FakeAuth 'fake-A' $false plus race)
        $caught='';try {$null=Recovery-Switch $consent} catch {$caught=$_.Exception.Message}
        Assert-Account ($caught -ceq 'IDENTITY_RECOVERY_STATE_CHANGED' -and (Fake-ProfileStamp) -ceq $profileStamp) 'AuthorizationRaceImmediatelyBeforeReplaceIsRefused'
    } finally {& $module {param($body)Set-Item Function:Get-QiehaoRecoveryConsent $body} $consentBody}
    Set-FakeAuth $a
    $teamMarkerPath=Join-Path $profiles 'Team8.identity.dpapi'
    $teamMarker=[IO.File]::ReadAllBytes($teamMarkerPath)
    try {
        [IO.File]::WriteAllBytes($teamMarkerPath,[byte[]]@(1,2,3))
        $caught='';try {$null=Recovery-Switch $consent} catch {$caught=$_.Exception.Message}
        Assert-Account ($caught -ceq 'PROFILE_IDENTITY_MARKER_INVALID' -and (Get-FileHash (Join-Path $fakeCodexHome 'auth.json')).Hash -ceq $authStamp) 'CorruptTeamCannotEnterRecovery'
    } finally {[IO.File]::WriteAllBytes($teamMarkerPath,$teamMarker);[Array]::Clear($teamMarker,0,$teamMarker.Length)}
    Set-FakeAuth $a
    $consent=Recovery-Consent
    [IO.File]::WriteAllBytes($replacement,$team)
    $r=Recovery-Switch $consent
    Assert-Account ($r.Result -ceq 'SWITCH_VERIFIED_SUCCESS' -and (Fake-ProfileStamp) -ceq $profileStamp -and [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fakeCodexHome 'auth.json'))) -ceq [Convert]::ToBase64String($team)) 'ConfirmedRecoveryUsesTeamWithoutChangingAnySavedProfile'
    Set-FakeAuth $a
    $r=Recovery-Switch (Recovery-Consent) Timeout
    Assert-Account ($r.Result -ceq 'SWITCH_RECOVERY_LOCAL_COMMITTED_UNVERIFIED' -and $r.LocalCommitted -and (Fake-ProfileStamp) -ceq $profileStamp) 'RecoveryOfficialTimeoutReportsLocalCommitWithoutRollback'
    Set-FakeAuth $a
    $verifyBody=& $module {(Get-Command Invoke-QiehaoAccountVerification).ScriptBlock}
    try {
        & $module {function script:Invoke-QiehaoAccountVerification {throw 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED'}}
        $r=Recovery-Switch (Recovery-Consent)
        Assert-Account ($r.Result -ceq 'SWITCH_RECOVERY_LOCAL_COMMITTED_MANUAL_CHECK_REQUIRED' -and $r.LocalCommitted -and (Fake-ProfileStamp) -ceq $profileStamp) 'RecoveryVerificationExceptionPreservesLocalCommitEvidence'
    } finally {& $module {param($body)Set-Item Function:Invoke-QiehaoAccountVerification $body} $verifyBody}
    Set-FakeAuth $a
    $consent=Recovery-Consent
    $caught='';try {
        $null=& $module {param($c,$p,$s,$approval) Invoke-CodexAccountSwitch -Name Team8 -CodexHome $c -ProfilesDirectory $p -StateDirectory $s -IdentityRecoveryConsent $approval -ProcessData @() -UseProvidedProcessData -SimulatePostReplaceVerificationFailure} $fakeCodexHome $profiles $state $consent
    } catch {$caught=$_.Exception.Message}
    Assert-Account ($caught -ceq 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED' -and (Fake-ProfileStamp) -ceq $profileStamp -and [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $fakeCodexHome 'auth.json'))) -ceq [Convert]::ToBase64String($team)) 'RecoveryReadbackFailureNeverRestoresDivergentPlus'
    $qm=Import-Module (Join-Path $project 'tools\QuotaClient.psm1') -PassThru
    Import-Module (Join-Path $project 'gui\QuotaHelpers.psm1') -Force
    & $qm {param($c,$p,$s)
        & $script:QuotaAuthModule {param($c,$p,$s)
            $script:fakeQuotaHome=$c;$script:ProfilesDirectory=$p;$script:StateDirectory=$s
            function script:Get-CodexHome {return $script:fakeQuotaHome}
        } $c $p $s
        $script:FakeQuotaCalls=0;$script:FakeQuotaMutation=$null
        $script:FakeQuotaPlan='team';$script:FakeQuotaRemaining=61;$script:FakeQuotaFail=$false
        function script:Invoke-QiehaoQuotaTransport {
            param($TimeoutSeconds,$OwnedProcessRegistry)
            $script:FakeQuotaCalls++
            if($script:FakeQuotaFail){throw 'QUOTA_RATE_LIMITS_TIMEOUT'}
            if ($null -ne $script:FakeQuotaMutation) { & $script:FakeQuotaMutation }
            [pscustomobject]@{Succeeded=$true;Snapshot=[pscustomobject]@{Plan=$script:FakeQuotaPlan;OrdinaryUsageAllowed=$true;Windows=@([pscustomobject]@{DurationMinutes=300;RemainingPercent=$script:FakeQuotaRemaining;ResetsAt=$null},[pscustomobject]@{DurationMinutes=10080;RemainingPercent=42;ResetsAt=$null})};Diagnostics=[pscustomobject]@{AccountStabilityLockAcquired=$false};AccountStabilityLockCleanup=''}
        }
    } $fakeCodexHome $profiles $state
    Set-FakeAuth $a
    $r=Get-QiehaoCurrentQuotaSnapshot -ExpectedProfileName Team8
    Assert-Account (-not $r.Succeeded -and $r.FailureCode -ceq 'QUOTA_ACCOUNT_IDENTITY_MISMATCH' -and (& $qm {$script:FakeQuotaCalls}) -eq 0) 'PlusUnderTeamBlockedBeforeQuotaTransport'
    Set-FakeAuth $team
    $r=Get-QiehaoCurrentQuotaSnapshot -ExpectedProfileName Team8
    Assert-Account $r.Succeeded 'MatchingTeamQuotaHasIdentityProof'
    $saved=Save-QiehaoQuotaSnapshot -StateDirectory $state -Cache (New-QiehaoEmptyQuotaCache) -ProfileName Team8 -Snapshot $r.Snapshot -IdentityProof $r.IdentityProof
    Assert-Account $saved.Succeeded 'MatchingTeamQuotaCommitRevalidatesIdentity'
    $refreshedTeam=New-FakeAuth 'fake-recovery-team' $false team refreshed
    $sameIdentityRefresh={[IO.File]::WriteAllBytes((Join-Path $fakeCodexHome 'auth.json'),$refreshedTeam)}.GetNewClosure()
    & $qm {param($m)$script:FakeQuotaMutation=$m} $sameIdentityRefresh
    $r=Get-QiehaoCurrentQuotaSnapshot -ExpectedProfileName Team8
    Assert-Account $r.Succeeded 'SameIdentityOfficialRefreshCanStillReturnQuota'
    & $qm {$script:FakeQuotaMutation=$null}
    $cacheStamp=(Get-FileHash (Join-Path $state 'quota-cache.json')).Hash
    $oldTime=$saved.Cache.profiles.Team8.queried_at
    Set-FakeAuth $a
    $blocked=Save-QiehaoQuotaSnapshot -StateDirectory $state -Cache $saved.Cache -ProfileName Team8 -Snapshot $r.Snapshot -IdentityProof $r.IdentityProof
    Assert-Account (-not $blocked.Succeeded -and $blocked.FailureCode -ceq 'QUOTA_ACCOUNT_IDENTITY_MISMATCH' -and (Get-FileHash (Join-Path $state 'quota-cache.json')).Hash -ceq $cacheStamp -and $blocked.Cache.profiles.Team8.queried_at -ceq $oldTime) 'IdentityChangedBeforeCommitKeepsCacheAndTime'
    Set-FakeAuth $team
    $mutate={[IO.File]::WriteAllBytes((Join-Path $fakeCodexHome 'auth.json'),$a)}.GetNewClosure()
    & $qm {param($m)$script:FakeQuotaMutation=$m} $mutate
    $r=Get-QiehaoCurrentQuotaSnapshot -ExpectedProfileName Team8
    Assert-Account (-not $r.Succeeded -and $r.FailureCode -ceq 'QUOTA_ACCOUNT_IDENTITY_MISMATCH' -and $null -eq $r.Snapshot) 'IdentityChangedDuringQueryDiscardsResult'
    $legacy=New-QiehaoEmptyQuotaCache
    $legacy.profiles.Team8=[pscustomobject]@{plan_type='plus';ordinary_usage_allowed=$true;queried_at=$oldTime;windows=@([pscustomobject]@{duration_minutes=300;label='5-hour';remaining_percent=99;resets_at=$null})}
    $row=@(Update-QiehaoQuotaProfileRows -Rows @([pscustomobject]@{Name='Team8'}) -Cache $legacy -ActiveProfile Team8 -JustUpdatedProfile Team8 -ProfilesDirectory $profiles)[0]
    Assert-Account ($row.QuotaSummary -ceq (Get-QiehaoQuotaUiText -Key IdentityUnverified) -and $row.QuotaFreshness.StartsWith((Get-QiehaoQuotaUiText -Key CachedPrefix)) -and $row.QuotaToolTip -notmatch '99%') 'LegacyPersonalQuotaNeverDisplayedAsTrustedTeam'
    # A normal switch re-encrypts the departing profile without changing identity.
    Set-FakeAuth $team
    $markerBeforeSwitch=(Get-FileHash (Join-Path $profiles 'Team8.identity.dpapi')).Hash
    $null=& $module {param($c,$p,$s) Invoke-CodexAccountSwitch -Name A -CodexHome $c -ProfilesDirectory $p -StateDirectory $s -ProcessData @() -UseProvidedProcessData} $fakeCodexHome $profiles $state
    Assert-Account ($markerBeforeSwitch -cne (Get-FileHash (Join-Path $profiles 'Team8.identity.dpapi')).Hash) 'NormalSwitchReencryptsDepartingMarker'
    $row=@(Update-QiehaoQuotaProfileRows -Rows @([pscustomobject]@{Name='Team8'}) -Cache $saved.Cache -ActiveProfile A -ProfilesDirectory $profiles)[0]
    Assert-Account ($row.QuotaSummary.StartsWith('5h 61%') -and $row.QuotaSummary.Contains('Week 42%')) 'DepartingTrustedSnapshotRemainsVisibleAfterNormalSwitch'
    # Three accounts, including two Team workspaces for the same fake user.
    function Switch-LocalFake([string]$Name) {
        $null=& $module {param($n,$c,$p,$s) Invoke-CodexAccountSwitch -Name $n -CodexHome $c -ProfilesDirectory $p -StateDirectory $s -ProcessData @() -UseProvidedProcessData} $Name $fakeCodexHome $profiles $state
    }
    $teamB=New-FakeAuth 'fake-team-B' $false team
    $null=Add-Fake TeamB $teamB
    $threeCache=$saved.Cache
    & $qm {$script:FakeQuotaMutation=$null}
    foreach($item in @(@('A','plus',84),@('Team8','team',61),@('TeamB','team',37))) {
        Switch-LocalFake $item[0]
        & $qm {param($plan,$percent)$script:FakeQuotaPlan=$plan;$script:FakeQuotaRemaining=$percent} $item[1] $item[2]
        $r=Get-QiehaoCurrentQuotaSnapshot -ExpectedProfileName $item[0]
        $next=Save-QiehaoQuotaSnapshot -StateDirectory $state -Cache $threeCache -ProfileName $item[0] -Snapshot $r.Snapshot -IdentityProof $r.IdentityProof
        Assert-Account ($r.Succeeded -and $next.Succeeded) ('TrustedQuotaSaved'+$item[0])
        $threeCache=$next.Cache
    }
    $bindings=@($threeCache.profiles.Values | ForEach-Object {$_.identity_binding} | Select-Object -Unique)
    Assert-Account ($bindings.Count -eq 3 -and $threeCache.profiles.Count -eq 3) 'ThreeDifferentIdentitiesHaveSeparatePersistentBindings'
    $threeJson=$threeCache | ConvertTo-Json -Depth 12 -Compress
    $cacheStamp=(Get-FileHash (Join-Path $state 'quota-cache.json')).Hash
    $callsBefore=& $qm {$script:FakeQuotaCalls}
    # Make accidental current-auth reads fail. Local switch receives an explicit fake path.
    & $qm {& $script:QuotaAuthModule {function script:Get-CodexHome {throw 'OFFLINE_MUST_NOT_READ_CURRENT_AUTH'}}}
    foreach($target in @('A','Team8','TeamB','A')) {
        Switch-LocalFake $target
        $beforeDisplay=Fake-ProfileStamp
        $rows=@(Update-QiehaoQuotaProfileRows -Rows @([pscustomobject]@{Name='A'},[pscustomobject]@{Name='Team8'},[pscustomobject]@{Name='TeamB'}) -Cache $threeCache -ActiveProfile $target -ProfilesDirectory $profiles)
        Assert-Account ($rows[0].QuotaSummary.StartsWith('5h 84%') -and $rows[1].QuotaSummary.StartsWith('5h 61%') -and $rows[2].QuotaSummary.StartsWith('5h 37%') -and @($rows | Where-Object {-not $_.QuotaSummary.Contains('Week 42%')}).Count -eq 0) ('AllSnapshotsOfflineAfterSwitch'+$target)
        Assert-Account ((Fake-ProfileStamp) -ceq $beforeDisplay -and (Get-FileHash (Join-Path $state 'quota-cache.json')).Hash -ceq $cacheStamp) ('OfflineDisplayDoesNotWrite'+$target)
    }
    Assert-Account ((& $qm {$script:FakeQuotaCalls}) -eq $callsBefore) 'OfflineDisplayStartsNoQuotaTransport'
    # Clear module memory and read the persisted file as on a fresh GUI start.
    Remove-Module QuotaHelpers
    Import-Module (Join-Path $project 'gui\QuotaHelpers.psm1')
    $reopened=Read-QiehaoQuotaCache -StateDirectory $state
    $rows=@(Update-QiehaoQuotaProfileRows -Rows @([pscustomobject]@{Name='A'},[pscustomobject]@{Name='Team8'},[pscustomobject]@{Name='TeamB'}) -Cache $reopened.Cache -ActiveProfile A -ProfilesDirectory $profiles)
    Assert-Account ($reopened.IsValid -and ($reopened.Cache | ConvertTo-Json -Depth 12 -Compress) -ceq $threeJson -and @($rows | Where-Object {$_.QuotaSummary -notmatch '%'}).Count -eq 0) 'ReopenPreservesAllTrustedValuesTimesAndBindings'
    & $qm {& $script:QuotaAuthModule {function script:Get-CodexHome {return $script:fakeQuotaHome}}}
    $r=Get-QiehaoCurrentQuotaSnapshot -ExpectedProfileName Team8
    Assert-Account (-not $r.Succeeded -and $r.FailureCode -ceq 'QUOTA_ACCOUNT_IDENTITY_MISMATCH' -and (& $qm {$script:FakeQuotaCalls}) -eq $callsBefore) 'InactiveProfileQueryRejectedBeforeTransport'
    & $qm {$script:FakeQuotaFail=$true}
    $r=Invoke-QiehaoQuotaCacheRefresh -Reason Manual -ActiveProfile A -SelectedProfile A -StateDirectory $state -Cache $threeCache -Coordinator (New-QiehaoQuotaCoordinatorState) -QuotaProvider {param($p) Get-QiehaoCurrentQuotaSnapshot -ExpectedProfileName $p}
    Assert-Account (-not $r.Succeeded -and (Get-FileHash (Join-Path $state 'quota-cache.json')).Hash -ceq $cacheStamp -and ($r.Cache | ConvertTo-Json -Depth 12 -Compress) -ceq $threeJson) 'OneAccountQueryFailureKeepsAllSnapshotsAndTimes'
    $freshA=New-FakeAuth 'fake-A' $false plus 'q05-refreshed'
    Set-FakeAuth $freshA
    & $module {param($p,$b) Save-QiehaoRefreshedProfileBytes -Name A -AuthBytes $b -ProfilesDirectory $p} $profiles $freshA
    $stable=Get-QiehaoQuotaSavedIdentityBinding -ProfileName A -ProfilesDirectory $profiles
    Assert-Account ($stable -ceq $threeCache.profiles.A.identity_binding) 'TokenRefreshPreservesStableBinding'
    $rename=& $module {param($p,$s) Invoke-RenameCodexProfile -OldName A -NewName RenamedPlus -ProfilesDirectory $p -StateDirectory $s} $profiles $state
    $renamed=Rename-QiehaoQuotaCacheProfile -StateDirectory $state -Cache $threeCache -OldName A -NewName RenamedPlus
    $row=@(Update-QiehaoQuotaProfileRows -Rows @([pscustomobject]@{Name='RenamedPlus'}) -Cache $renamed.Cache -ActiveProfile RenamedPlus -ProfilesDirectory $profiles)[0]
    Assert-Account ($renamed.Succeeded -and $row.QuotaSummary.StartsWith('5h 84%') -and (Get-QiehaoQuotaSavedIdentityBinding -ProfileName RenamedPlus -ProfilesDirectory $profiles) -ceq $stable) 'ProfileRenamePreservesStableBindingAndTime'
    # A copied binding from another workspace must not expose that workspace's values.
    $tampered=$threeJson | ConvertFrom-Json
    $tampered.profiles.Team8.identity_binding=$threeCache.profiles.TeamB.identity_binding
    $row=@(Update-QiehaoQuotaProfileRows -Rows @([pscustomobject]@{Name='Team8'}) -Cache $tampered -ActiveProfile RenamedPlus -ProfilesDirectory $profiles)[0]
    Assert-Account ($row.QuotaSummary -ceq (Get-QiehaoQuotaUiText -Key IdentityUnverified) -and $row.QuotaToolTip -notmatch '%') 'OtherTeamBindingCannotAuthorizeThisTeamsCache'
    $legacy.profiles.Team8 | Add-Member -NotePropertyName identity_binding -NotePropertyValue (Get-FileHash (Join-Path $profiles 'Team8.identity.dpapi')).Hash
    $row=@(Update-QiehaoQuotaProfileRows -Rows @([pscustomobject]@{Name='Team8'}) -Cache $legacy -ActiveProfile RenamedPlus -ProfilesDirectory $profiles)[0]
    Assert-Account ($row.QuotaSummary -ceq (Get-QiehaoQuotaUiText -Key IdentityUnverified)) 'LegacyCiphertextHashNotSilentlyPromotedToStableIdentity'
    Set-FakeAuth $team
    $callsBefore=& $qm {$script:FakeQuotaCalls}
    $r=Get-QiehaoCurrentQuotaSnapshot -ExpectedProfileName RenamedPlus
    $rows=@(Update-QiehaoQuotaProfileRows -Rows @([pscustomobject]@{Name='RenamedPlus'},[pscustomobject]@{Name='Team8'},[pscustomobject]@{Name='TeamB'}) -Cache $renamed.Cache -ActiveProfile RenamedPlus -ProfilesDirectory $profiles)
    Assert-Account (-not $r.Succeeded -and $r.FailureCode -ceq 'QUOTA_ACCOUNT_IDENTITY_MISMATCH' -and (& $qm {$script:FakeQuotaCalls}) -eq $callsBefore -and @($rows | Where-Object {$_.QuotaSummary -notmatch '%'}).Count -eq 0) 'DivergentCurrentLoginDoesNotHideOtherTrustedProfiles'
    $originalMarker=[IO.File]::ReadAllBytes((Join-Path $profiles 'TeamB.identity.dpapi'))
    try {
        [IO.File]::WriteAllBytes((Join-Path $profiles 'TeamB.identity.dpapi'),[byte[]](1,2,3))
        $row=@(Update-QiehaoQuotaProfileRows -Rows @([pscustomobject]@{Name='TeamB'}) -Cache $renamed.Cache -ActiveProfile RenamedPlus -ProfilesDirectory $profiles)[0]
        Assert-Account ($row.QuotaSummary -ceq (Get-QiehaoQuotaUiText -Key IdentityUnverified) -and $row.QuotaToolTip -notmatch '%') 'DamagedSavedIdentityCannotAuthorizeHistoricalQuota'
    } finally { [IO.File]::WriteAllBytes((Join-Path $profiles 'TeamB.identity.dpapi'),$originalMarker);[Array]::Clear($originalMarker,0,$originalMarker.Length) }
    $log = [IO.File]::ReadAllText((Join-Path $fakeLogs 'qiehao.log'))
    foreach($code in @('QUOTA_CACHE_BINDING_VALID','QUOTA_CACHE_LEGACY_UNVERIFIED','QUOTA_CACHE_BINDING_UNVERIFIED','QUOTA_CACHE_SAVE_SUCCESS','QUOTA_CACHE_SAVE_REJECTED')) {
        Assert-Account ($log.Contains($code)) ('FixedCacheDiagnostic'+$code)
    }
    Assert-Account (-not $log.Contains('identity-v2:') -and $threeJson -notmatch 'fake-user|fake-recovery-team|fake-team-B|fake-refresh') 'StableBindingsAndDiagnosticsContainNoIdentityPlaintext'
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
