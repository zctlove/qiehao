param([string]$Scenario = 'Success',[string]$ReplacementPath = '',[string]$TracePath = '',[string]$Plan = 'plus')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$fakeLoginId = [Guid]::NewGuid().ToString('N')
if ($TracePath) { [IO.File]::AppendAllText($TracePath,('SESSION:'+$PID+':'+$fakeLoginId+[Environment]::NewLine)) }
function Emit($Value) { [Console]::Out.WriteLine(($Value | ConvertTo-Json -Depth 8 -Compress)); [Console]::Out.Flush() }
while ($null -ne ($line = [Console]::In.ReadLine())) {
    $m = $line | ConvertFrom-Json
    $method = [string]$m.method
    if ($TracePath) {
        $refresh = $false
        if ($null -ne $m.PSObject.Properties['params'] -and $null -ne $m.params.PSObject.Properties['refreshToken']) { $refresh = [bool]$m.params.refreshToken }
        [IO.File]::AppendAllText($TracePath, ($method + ':' + $refresh + [Environment]::NewLine))
    }
    if ($method -eq 'initialized') { continue }
    if ($method -eq 'initialize') {
        if ($Scenario -ceq 'InitializeTimeout') { continue }
        if ($m.params.capabilities.experimentalApi) { throw 'FAKE_EXPERIMENTAL_FORBIDDEN' }
        Emit @{ id = $m.id; result = @{ userAgent = 'fake' } }; continue
    }
    if ($method -eq 'account/login/cancel') { Emit @{id=$m.id;result=@{status='cancelled'}}; continue }
    if ($Scenario -eq 'Unsupported') { Emit @{id=$m.id;error=@{code=-32601;message='Method not found'}}; continue }
    if ($Scenario -eq 'Timeout' -and $method -eq 'account/read') { continue }
    if ($method -eq 'account/login/start') {
        if ($Scenario -ceq 'LoginStartTimeout') { continue }
        Emit @{ method='account/updated';params=@{authMode='chatgpt'} }
        # A previous ceremony must never satisfy this new one.
        Emit @{method='account/login/completed';params=@{loginId='stale-previous-login';success=$true;error=$null}}
        # Exercise notification before the matching login/start response.
        if ($Scenario -notin @('LoginTimeout','LoginCancel','LoginCallbackMismatch')) {
            if ($ReplacementPath) { [IO.File]::WriteAllBytes((Join-Path $env:CODEX_HOME 'auth.json'),[IO.File]::ReadAllBytes($ReplacementPath)) }
            if ($Scenario -ceq 'IdentityMalformed') { [IO.File]::WriteAllText((Join-Path $env:CODEX_HOME 'auth.json'),'{') }
            if ($Scenario -ceq 'ChildCrash') { break }
            Emit @{method='account/login/completed';params=@{loginId=$fakeLoginId;success=($Scenario -ne 'LoginFailed');error=$null}}
        }
        Emit @{id=$m.id;result=@{type='chatgpt';loginId=$fakeLoginId;authUrl='https://auth.openai.com/authorize?state=fake'}}
        continue
    }
    if ($method -eq 'account/read') {
        if ($Scenario -ceq 'LoginReadTimeout') { continue }
        $refresh = $null -ne $m.params.PSObject.Properties['refreshToken'] -and $m.params.refreshToken
        if (($Scenario -eq 'Permanent' -and $refresh) -or $Scenario -eq 'PermanentRead') {
            Emit @{id=$m.id;error=@{code=-32000;message='refresh_token_expired';data=@{code='refresh_token_expired'}}}; continue
        }
        if ($Scenario -eq 'TransientRpc') { Emit @{id=$m.id;error=@{code=-32000;message='temporarily unavailable'}}; continue }
        if ($Scenario -eq 'LoginReadFailed') { Emit @{id=$m.id;error=@{code=-32000;message='read failed'}}; continue }
        if ($Scenario -eq 'OldFields') { Emit @{id=$m.id;result=@{account=@{type='chatgpt'}}}; continue }
        if ($refresh -and $ReplacementPath) { [IO.File]::WriteAllBytes((Join-Path $env:CODEX_HOME 'auth.json'),[IO.File]::ReadAllBytes($ReplacementPath)) }
        if ($refresh -and $Scenario -ceq 'RefreshMalformed') { [IO.File]::WriteAllText((Join-Path $env:CODEX_HOME 'auth.json'),'{') }
        Emit @{id=$m.id;result=@{requiresOpenaiAuth=$true;account=@{type='chatgpt';planType=$Plan}}}
        continue
    }
    Emit @{id=$m.id;error=@{code=-32601;message='Method not found'}}
}
if ($Scenario -ceq 'NeverExit') { while ($true) { [Threading.Thread]::Sleep(500) } }
