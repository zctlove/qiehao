Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $project 'lib\CodexAuth.psm1') -Force -PassThru
$client = Import-Module (Join-Path $project 'tools\AccountClient.psm1') -PassThru
$root = Join-Path ([IO.Path]::GetTempPath()) ('Qiehao-Upgrade-' + [Guid]::NewGuid().ToString('N'))
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
    $a=New-FakeAuth 'fake-upgrade-A' $false 'team'
    $b=New-FakeAuth 'fake-upgrade-B'
    $null=Add-Fake A $a
    $null=Add-Fake B $b
    Import-Module (Join-Path $project 'gui\QuotaHelpers.psm1')
    $snapshot=[pscustomobject]@{Plan='plus';OrdinaryUsageAllowed=$true;Windows=@([pscustomobject]@{DurationMinutes=10080;Label='Weekly';RemainingPercent=75;ResetsAt=1893542400;ResetLocal='2030-01-01'})}
    $saved=Save-QiehaoQuotaSnapshot -StateDirectory $state -Cache (New-QiehaoEmptyQuotaCache) -ProfileName B -Snapshot $snapshot
    Assert-Account $saved.Succeeded 'V103QuotaFixtureCreated'
    $before=@{}
    foreach($f in @(Get-ChildItem $profiles,$state -File -Recurse)){$before[$f.FullName]=(Get-FileHash $f.FullName).Hash}
    $rows=@(& $module {param($p,$s) Get-CodexAccountSlotState -ProfilesDirectory $p -StateDirectory $s} $profiles $state)
    $active=& $module {param($s) Read-ActiveProfileState -StateDirectory $s} $state
    Assert-Account ($rows.Count -eq 2 -and $active.ActiveProfile -ceq 'B') 'V103ProfilesAndActivePreserved'
    $quota=Read-QiehaoQuotaCache -StateDirectory $state
    Assert-Account ($quota.IsValid -and -not $quota.UsedEmpty) 'V103QuotaCacheStillReadable'
    foreach($name in @('A','B')){
        $bytes=& $module {param($n,$p) Read-CodexAccountSlotBytes -Name $n -ProfilesDirectory $p} $name $profiles
        $expected=if($name -ceq 'A'){$a}else{$b}
        Assert-Account ([Convert]::ToBase64String($bytes) -ceq [Convert]::ToBase64String($expected)) ('V103'+$name+'DpapiRawBytesPreserved')
        $match=& $module {param($n,$p,$b) Compare-CodexAuthToProfileIdentity -Name $n -ProfilesDirectory $p -AuthBytes $b} $name $profiles $bytes
        Assert-Account ($match.Matches -and $match.WorkspaceContextStatus -ceq 'Confirmed') ('V103'+$name+'IdentityUnchanged')
        [Array]::Clear($bytes,0,$bytes.Length)
    }
    $mutations=0
    foreach($f in @(Get-ChildItem $profiles,$state -File -Recurse)){if($before[$f.FullName] -cne (Get-FileHash $f.FullName).Hash){$mutations++}}
    Assert-Account ($mutations -eq 0) 'V103LoadDoesNotMutateSavedArtifacts'
    $results.OAuthRequiredForUpgrade=$false
    $results.AddAccountsAgainRequired=$false
    $results.UnexpectedProfileMutations=$mutations
    $results.RealAuthOrProfileRead=$false
    $results.Status='PASS'
    [pscustomobject]$results
}finally{[IO.Directory]::Delete($root,$true)}
