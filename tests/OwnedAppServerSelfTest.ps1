Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$ownershipPath=Join-Path $project 'tools\AppServerOwnership.psm1'
Import-Module $ownershipPath -Force
$core=Import-Module (Join-Path $project 'lib\CodexAuth.psm1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('Qiehao-OwnedServer-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
$shell=(Get-Process -Id $PID).Path
$fake=Join-Path $PSScriptRoot 'FakeOwnedAppServer.ps1'
$results=[ordered]@{};$children=New-Object 'Collections.Generic.List[object]'
function Assert-Owner([bool]$Condition,[string]$Name) {if (-not $Condition) {throw ('OWNERSHIP_TEST_'+$Name)};$results[$Name]='PASS'}
function New-FakeChild {
    $p=New-Object Diagnostics.Process
    $p.StartInfo=New-Object Diagnostics.ProcessStartInfo
    $p.StartInfo.FileName=$shell
    $p.StartInfo.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$fake+'"'
    $p.StartInfo.UseShellExecute=$false;$p.StartInfo.CreateNoWindow=$true
    $p.StartInfo.RedirectStandardInput=$true
    $children.Add($p)
    return $p
}
function Synthetic-Descriptor($Registry,[int]$Id=0,[int]$StartOffset=0) {
    if ($Id -eq 0) {$Id=$Registry.ProcessId}
    return [pscustomobject]@{ProcessName='codex.exe';Id=$Id;ExecutablePath=$Registry.ExecutablePath;PathReadStatus='Readable';ProcessStartTimeUtc=$Registry.ProcessStartTimeUtc.AddSeconds($StartOffset);StartTimeReadStatus='Readable';ParentProcessId=$Registry.ParentProcessId;ParentReadStatus='Readable'}
}
function Synthetic-Owner($Registry) {
    $d=Get-QiehaoOwnedAppServerDescriptor -Registry $Registry
    # The child is a fake PowerShell process; test the real strict matcher with
    # synthetic Codex metadata, never enumerate or start real Codex.
    $d.Arguments='app-server --stdio'
    return $d
}
try {
    foreach ($purpose in @('Quota','AccountVerify','AccountLogin')) {
        $registry=[hashtable]::Synchronized(@{IsActive=$false;DiagnosticLogDirectory=$root})
        $child=New-FakeChild
        Assert-Owner (Start-QiehaoOwnedAppServer -Process $child -Registry $registry -Purpose $purpose) ($purpose+'Started')
        $owned=Synthetic-Owner $registry;$data=Synthetic-Descriptor $registry
        $registry.OwnershipReady=$false
        $metadataCode='';$metadataProbe=@{Called=$false}
        try {$null=Invoke-QiehaoOwnedProcessInspection -Registries @($registry) -InspectionProvider {$metadataProbe.Called=$true}} catch {$metadataCode=$_.Exception.Message}
        Assert-Owner ($metadataCode -ceq 'OWNED_APP_SERVER_SNAPSHOT_BUSY' -and -not $metadataProbe.Called -and $registry.IsActive) ($purpose+'IncompleteMetadataDefersWithoutExternalClassification')
        $registry.OwnershipReady=$true
        $gate=Test-CodexProcessesStopped -ProcessData @($data) -OwnedProcessDescriptors @($owned)
        Assert-Owner ($gate.SafeToSave -and $gate.OwnedQuotaProcesses[0].Classification -ceq 'QIEHAO_OWNED_APP_SERVER' -and $gate.OwnedQuotaProcesses[0].Purpose -ceq $purpose) ($purpose+'NeverExternal')
        $external=Synthetic-Descriptor $registry ($registry.ProcessId+100000)
        $gate=Test-CodexProcessesStopped -ProcessData @($data,$external) -OwnedProcessDescriptors @($owned)
        Assert-Owner (-not $gate.SafeToSave -and $gate.BlockingProcesses.Count -eq 1) ($purpose+'SamePathExternalStillBlocks')
        $reused=Synthetic-Descriptor $registry 0 10
        $gate=Test-CodexProcessesStopped -ProcessData @($reused) -OwnedProcessDescriptors @($owned)
        Assert-Owner (-not $gate.SafeToSave) ($purpose+'ReusedPidDoesNotMatch')
        $child.StandardInput.Close()
        $exit=$child.WaitForExit(20)
        Assert-Owner (-not $exit) ($purpose+'DelayedCleanupFixture')
        Complete-QiehaoOwnedAppServer -Registry $registry -ExitObserved $exit -CleanupResult GraceExpired
        Assert-Owner $registry.IsActive ($purpose+'OwnershipRetainedDuringCleanup')
        Assert-Owner (Test-CodexProcessesStopped -ProcessData @($data) -OwnedProcessDescriptors @(Synthetic-Owner $registry)).SafeToSave ($purpose+'DelayedCleanupStillOwned')
        Assert-Owner ($child.WaitForExit(5000)) ($purpose+'EventuallyExited')
        Complete-QiehaoOwnedAppServer -Registry $registry -ExitObserved $true -CleanupResult Normal
        Assert-Owner (-not $registry.IsActive -and @(Get-QiehaoOwnedAppServerDescriptor -Registry $registry).Count -eq 0) ($purpose+'InactiveOnlyAfterExit')
        $child.Dispose()
    }
    # A foreign runspace holds the actual registry lock while a created child
    # exists. GUI inspection must defer before calling any process provider.
    $registry=[hashtable]::Synchronized(@{IsActive=$false;DiagnosticLogDirectory=$root})
    $child=New-FakeChild
    $ready=New-Object Threading.ManualResetEventSlim($false)
    $release=New-Object Threading.ManualResetEventSlim($false)
    $worker=[PowerShell]::Create()
    $null=$worker.AddScript({param($path,$r,$p,$readySignal,$releaseSignal)
        Import-Module $path
        [Threading.Monitor]::Enter($r.SyncRoot)
        try {
            $null=Start-QiehaoOwnedAppServer -Process $p -Registry $r -Purpose Quota
            $readySignal.Set()
            if (-not $releaseSignal.Wait(5000)) {throw 'FAKE_LOCK_WAIT_TIMEOUT'}
        } finally {[Threading.Monitor]::Exit($r.SyncRoot)}
    }).AddArgument($ownershipPath).AddArgument($registry).AddArgument($child).AddArgument($ready).AddArgument($release)
    $async=$worker.BeginInvoke()
    try {
        Assert-Owner ($ready.Wait(5000)) 'StartupRaceFixtureReady'
        $probe=@{Called=$false};$code=''
        $watch=[Diagnostics.Stopwatch]::StartNew()
        try {$null=Invoke-QiehaoOwnedProcessInspection -Registries @($registry) -InspectionProvider {$probe.Called=$true}} catch {$code=$_.Exception.Message}
        Assert-Owner ($code -ceq 'OWNED_APP_SERVER_SNAPSHOT_BUSY' -and -not $probe.Called -and $watch.ElapsedMilliseconds -lt 1000) 'StartupRaceDefersWithoutFalseExternalOrDispatcherWait'
    } finally {$release.Set();$null=$worker.EndInvoke($async);$worker.Dispose();$ready.Dispose();$release.Dispose()}
    $check=Invoke-QiehaoOwnedProcessInspection -Registries @($registry) -InspectionProvider {
        param($owners)
        Assert-Owner ([Threading.Monitor]::IsEntered($registry.SyncRoot)) 'InspectionLockSpansProcessEnumeration'
        Assert-Owner ($owners.Count -eq 1 -and $owners[0].ProcessId -eq $child.Id -and $null -ne $owners[0].ProcessStartTimeUtc) 'PublishedDescriptorComplete'
        return $true
    }
    Assert-Owner $check 'InspectionAfterPublishSucceeds'
    Assert-Owner (Confirm-QiehaoOwnedAppServerExit -Registry $registry -WaitMilliseconds 500) 'CancelledExactOwnedChildConfirmedBeforeLifecycle'
    Assert-Owner (-not $registry.IsActive) 'CancelledChildInactiveAfterExit'
    $log=[IO.File]::ReadAllText((Join-Path $root 'qiehao.log'))
    $entries=@($log -split '[\r\n]+' | Where-Object {$_} | ForEach-Object {$_ | ConvertFrom-Json})
    Assert-Owner (@($entries | Where-Object event -CEQ OWNED_APP_SERVER_START).Count -eq 4) 'StartEventsCorrelateFourChildren'
    Assert-Owner (@($entries | Where-Object {$_.event -ceq 'OWNED_APP_SERVER_FINISH' -and -not $_.data.ExitObserved}).Count -eq 3) 'FinishLogsUnconfirmedExitSafely'
    Assert-Owner ($log -notmatch 'Arguments|auth\.json|access_token|refresh_token|id_token|@|Authorization|Cookie') 'OwnershipLogsContainOnlySafeMetadata'
    $results.OwnedQuotaChildNeverReportedAsExternalCodex=$true
    $results.OwnershipPersistsUntilChildExit=$true
    $results.ExternalCodexStillBlocks=$true
    $results.RealAuthOrProfileRead=$false;$results.RealNetworkRequests=$false;$results.Status='PASS'
    [pscustomobject]$results
} finally {
    foreach ($child in $children) {try {if (-not $child.HasExited) {$child.Kill();$null=$child.WaitForExit(1000)};$child.Dispose()} catch {}}
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) {[IO.Directory]::Delete($root,$true)}
}
