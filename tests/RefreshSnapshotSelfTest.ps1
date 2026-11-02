Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
$project=Split-Path -Parent $PSScriptRoot
$core=Import-Module (Join-Path $project 'lib\CodexAuth.psm1') -Force -PassThru
Import-Module (Join-Path $project 'gui\GuiHelpers.psm1') -Force
Import-Module (Join-Path $project 'gui\Localization.psm1') -Force
Add-Type -AssemblyName PresentationFramework
$root=Join-Path ([IO.Path]::GetTempPath()) ('Qiehao-RefreshSnapshot-'+[Guid]::NewGuid().ToString('N'))
$null=[IO.Directory]::CreateDirectory($root)
& $core {param($l) $script:LogsDirectory=$l} $root
$results=[ordered]@{}
function Assert-Refresh([bool]$Condition,[string]$Name) {if (-not $Condition) {throw ('REFRESH_TEST_'+$Name)}; $results[$Name]='PASS'}
$script:guiRefreshEpoch=@{Generation=0L;Sequence=0L}
$script:guiManualRecoveryRequired=$false;$script:guiIsWriteOperationBusy=$false;$script:guiLifecycleWorkerRunning=$false
$script:guiActiveProfileKnown=$true;$script:guiCurrentActiveProfile='A';$script:guiCurrentCodexStatus='fake';$script:guiCurrentCodexState='Stopped';$script:guiCurrentIdentityState='Confirmed'
$script:guiAllProfileRows=@(ConvertTo-QiehaoGuiProfileRows -ProfileData @([pscustomobject]@{Profile='A'},[pscustomobject]@{Profile='B'}) -ActiveProfile A -ActiveProfileKnown)
$script:guiVerificationStates=@{};$script:guiVerificationStateCodes=@{};$script:guiQuotaModulesAvailable=$false
$script:guiQuotaJustUpdatedProfile='';$script:guiLanguage='en-US'
$script:guiQuotaLastQueryFailed=$false
$profilesGrid=New-Object Windows.Controls.DataGrid
$profilesGrid.ItemsSource=$script:guiAllProfileRows
$activeProfileText=New-Object Windows.Controls.TextBlock;$activeProfileText.Text='A'
$identityStatusText=New-Object Windows.Controls.TextBlock
$webChatGPTText=New-Object Windows.Controls.TextBlock
$codexStatusText=New-Object Windows.Controls.TextBlock
$window=New-Object Windows.Window
foreach ($name in @('SuccessBrush','DangerBrush','WarningBrush','TextMutedBrush')) {$window.Resources[$name]=[Windows.Media.Brushes]::Black}
$script:listMode='Normal';$script:activeMode='Normal';$script:late=$false
function Get-CodexAccountSlot {
    switch ($script:listMode) {'Busy' {throw 'OPERATION_BUSY'} 'Failure' {throw 'FAKE_READ_FAILED'} 'Empty' {return @()} 'Partial' {return [pscustomobject]@{Health='UNKNOWN'}}}
    return @([pscustomobject]@{Profile='A'},[pscustomobject]@{Profile='B'})
}
function Get-CodexActiveProfile {
    if ($script:activeMode -ceq 'Failure') {throw 'FAKE_ACTIVE_READ_FAILED'}
    if ($script:activeMode -ceq 'Empty') {throw 'ACTIVE_PROFILE_NOT_INITIALIZED'}
    return [pscustomobject]@{ActiveProfile='A'}
}
function Get-QiehaoGuiProcessState {
    if ($script:late) {$script:guiRefreshEpoch.Sequence++}
    return [pscustomobject]@{SafeToSave=$true;ReasonCode='CODEX_PROCESSES_STOPPED'}
}
function Test-CodexActiveIdentity {return [pscustomobject]@{Result='ACTIVE_IDENTITY_CONFIRMED'}}
function Set-QiehaoLocalizedStatus {param($Key,$Fallback) $script:statusKey=$Key}
function Get-QiehaoGuiText {param($Key,$Fallback) if ($Fallback) {return $Fallback}; return $Key}
function Update-QiehaoActionButtons {}
function Set-QiehaoCodexStatusVisual {param($Status)}
function Set-QiehaoQuotaUnavailableRows {param($Rows)}
function Disable-QiehaoQuotaFeature {$script:guiQuotaModulesAvailable=$false}
function Update-QiehaoLocalizedProfileRows {}
function Update-QiehaoProfileFilter {$profilesGrid.ItemsSource=$script:guiAllProfileRows}
function Update-QiehaoQuotaRows {}
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $project 'gui\QiehaoGui.ps1'),[ref]$tokens,[ref]$errors)
if ($errors.Count) {throw 'GUI_PARSE_FAILED'}
foreach ($name in @('Set-QiehaoSnapshot','Sync-QiehaoCommittedActiveState','Write-QiehaoRefreshResult','Invoke-QiehaoReadOnlyRefresh','Stop-QiehaoQuotaForLifecycle','Invoke-QiehaoDeleteSelectedProfile')) {
    $fn=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -ceq $name}.GetNewClosure(),$true)
    Invoke-Expression $fn.Extent.Text
}
try {
    $original=$profilesGrid.ItemsSource
    foreach ($mode in @('Busy','Failure','Partial')) {
        $script:listMode=$mode
        $ok=Invoke-QiehaoReadOnlyRefresh -PassThru
        Assert-Refresh (-not $ok -and [object]::ReferenceEquals($original,$profilesGrid.ItemsSource) -and $activeProfileText.Text -ceq 'A') ('List'+$mode+'PreservesRowsAndCurrent')
    }
    $script:listMode='Normal';$script:activeMode='Failure'
    $ok=Invoke-QiehaoReadOnlyRefresh -PassThru
    Assert-Refresh (-not $ok -and [object]::ReferenceEquals($original,$profilesGrid.ItemsSource)) 'ActiveReadFailurePreservesRows'
    $ok=Sync-QiehaoCommittedActiveState
    Assert-Refresh (-not $ok -and [object]::ReferenceEquals($original,$profilesGrid.ItemsSource)) 'CommittedStateReadFailurePreservesRows'
    $script:activeMode='Normal';$script:guiIsWriteOperationBusy=$true
    $ok=Invoke-QiehaoReadOnlyRefresh -PassThru
    Assert-Refresh (-not $ok -and [object]::ReferenceEquals($original,$profilesGrid.ItemsSource)) 'LifecycleBusyPreservesRows'
    $script:guiIsWriteOperationBusy=$false;$script:late=$true
    $ok=Invoke-QiehaoReadOnlyRefresh -PassThru
    Assert-Refresh (-not $ok -and [object]::ReferenceEquals($original,$profilesGrid.ItemsSource)) 'LateSnapshotDropped'
    $script:late=$false;$script:listMode='Empty';$script:activeMode='Empty'
    $script:guiQuotaLastQueryFailed=$true;$script:statusKey='Quota.NoDisplayableWindows'
    $ok=Invoke-QiehaoReadOnlyRefresh -PassThru
    Assert-Refresh ($ok -and $script:statusKey -ceq 'Quota.NoDisplayableWindows') 'ListRefreshPreservesQuotaFailureAndDoesNotClaimQuotaUpdate'
    $script:guiQuotaLastQueryFailed=$false
    $ok=Invoke-QiehaoReadOnlyRefresh -PassThru
    Assert-Refresh ($ok -and @($profilesGrid.ItemsSource).Count -eq 0) 'SuccessfulConfirmedEmptyClearsRows'
    $log=@(Get-Content -LiteralPath (Join-Path $root 'qiehao.log') | ForEach-Object {$_ | ConvertFrom-Json})
    foreach ($code in @('REFRESH_BUSY','REFRESH_READ_FAILED','REFRESH_STALE_DROPPED','REFRESH_EMPTY_CONFIRMED')) {
        Assert-Refresh (@($log | Where-Object result -CEQ $code).Count -gt 0) ('Log'+$code)
    }
    $mapped=ConvertTo-QiehaoOperationResult -ResultCode SWITCH_AUTH_UNVERIFIED_TRANSIENT
    $presentation=Invoke-QiehaoSwitchUiCompletion -Result $mapped -TargetProfile B -RefreshProvider {$true} -StateProvider {param($s,$p) $script:completion=$s} -BusyProvider {}
    Assert-Refresh ($mapped.Severity -ceq 'Information' -and $mapped.LocalCommitted -and -not $mapped.IsSuccess -and $presentation.State -ceq 'SwitchUnverified') 'TransientDoesNotClaimVerifiedOrSwitchFailed'
    foreach ($language in @('zh-CN','en-US')) {
        $text=Get-QiehaoLocalizedString -Language $language -Key Operation.SWITCH_AUTH_UNVERIFIED_TRANSIENT
        Assert-Refresh ($text -notmatch '\[Missing:' -and $text -notmatch 'try switching|switch failed') ('TransientFriendlyMessage'+$language)
    }
    function Stop-QiehaoQuotaAsync {throw 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED'}
    function Set-QiehaoWriteBusy {param($Value,$StatusText) $script:guiIsWriteOperationBusy=$Value}
    function Show-QiehaoOperationResult {param($Result) $script:safetyResult=$Result.ResultCode}
    function Get-QiehaoSelectedProfileName {return 'B'}
    function Invoke-QiehaoResponsiveLifecycle {throw 'LIFECYCLE_MUST_NOT_RUN_ON_UNCONFIRMED_CHILD_EXIT'}
    Invoke-QiehaoDeleteSelectedProfile
    Assert-Refresh ($script:safetyResult -ceq 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED' -and -not $script:guiIsWriteOperationBusy) 'CleanupUnconfirmedShowsSafetyResultWithoutCallingDeleteOrEscapingGui'
    $results.RefreshFailurePreservesExistingRows=$true
    $results.RefreshEmptyRequiresSuccessfulSnapshot=$true
    $results.TransientVerifyDoesNotPresentAsSwitchFailure=$true
    $results.RealAuthOrProfileRead=$false;$results.RealNetworkRequests=$false;$results.Status='PASS'
    [pscustomobject]$results
} finally {
    $window.Close()
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) {[IO.Directory]::Delete($root,$true)}
}
