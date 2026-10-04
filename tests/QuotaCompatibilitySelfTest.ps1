Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$client=Import-Module (Join-Path $project 'tools\QuotaClient.psm1') -PassThru
$parser=Import-Module (Join-Path $project 'tools\QuotaParser.psm1') -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('Qiehao-QuotaCompat-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$exe=(Get-Process -Id $PID).Path
$server=Join-Path $PSScriptRoot 'FakeQuotaAppServer.ps1'
try {
    foreach ($scenario in @('RejectNewParams','RejectAlways','ServerFailure')) {
        $trace=Join-Path $root ($scenario+'.txt')
        $arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$server+'" -Scenario '+$scenario+' -TraceFile "'+$trace+'"'
        $r=& $client {param($exe,$arguments) Invoke-QiehaoQuotaTransport -TimeoutSeconds 3 -TestExecutablePath $exe -TestProcessArguments $arguments} $exe $arguments
        $count=([IO.File]::ReadAllLines($trace)).Count
        $expected=if($scenario -ceq 'ServerFailure'){1}else{2}
        if($count -ne $expected -or $r.Succeeded -ne ($scenario -ceq 'RejectNewParams')){throw ('QUOTA_COMPATIBILITY_FAILED_'+$scenario)}
    }
    $snapshot=ConvertTo-QiehaoQuotaSnapshot -Result ([pscustomobject]@{
        accountId='fake-optional-id';rateLimitResetCredits=@{unrecognized='optional'}
        rateLimitsByLimitId=[pscustomobject]@{
            other=[pscustomobject]@{limitId='other';primary=[pscustomobject]@{usedPercent=99;windowDurationMins=300}}
            codex=[pscustomobject]@{limitId='codex';normalModelSlug='optional';individualLimit=$null;primary=$null;secondary=[pscustomobject]@{usedPercent=20;windowDurationMins=10080;resetsAt=1893542400}}
        }
    })
    if($snapshot.Windows.Count -ne 1 -or $snapshot.Windows[0].Label -cne 'Weekly' -or $snapshot.Windows[0].RemainingPercent -ne 80){throw 'QUOTA_WEEKLY_ONLY_OR_CODEX_BUCKET_FAILED'}
    if(($snapshot | ConvertTo-Json -Depth 6) -match 'fake-optional-id|rateLimitResetCredits'){throw 'QUOTA_OPTIONAL_ID_LEAKED'}
    [pscustomobject]@{OldParamsFallbackOnce='PASS';UnsupportedParamsNeverLoop='PASS';ServerFailureNeverRetries='PASS';WeeklyOnlyNeverInventsWindow='PASS';CodexBucketPreferred='PASS';UnknownOptionalFieldsIgnored='PASS';RealQuotaRpc=$false;Status='PASS'}
}finally{[IO.Directory]::Delete($root,$true)}
