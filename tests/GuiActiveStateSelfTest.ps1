Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$SelfTest = $true
$projectRoot = Split-Path -Parent $PSScriptRoot
$coreModulePath = Join-Path $projectRoot 'lib\CodexAuth.psm1'
$module = Import-Module $coreModulePath -Force -PassThru
Import-Module (Join-Path $projectRoot 'gui\GuiHelpers.psm1') -Force
Import-Module (Join-Path $projectRoot 'gui\QuotaHelpers.psm1') -Force
Import-Module (Join-Path $projectRoot 'gui\Localization.psm1') -Force
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
$root = Join-Path ([IO.Path]::GetTempPath()) ('Qiehao-GuiActive-' + [Guid]::NewGuid().ToString('N'))
$fakeHome = Join-Path $root 'codex'
$fakeProfiles = Join-Path $root 'profiles'
$fakeState = Join-Path $root 'state'
foreach ($path in @($root,$fakeHome,$fakeProfiles,$fakeState,(Join-Path $root 'logs'))) { $null = [IO.Directory]::CreateDirectory($path) }
& $module { param($p,$s,$l) $script:ProfilesDirectory=$p; $script:StateDirectory=$s; $script:LogsDirectory=$l } $fakeProfiles $fakeState (Join-Path $root 'logs')
$script:activeReads = 0
function Get-CodexActiveProfile { $script:activeReads++; return & $module { Get-CodexActiveProfile } }
function Get-QiehaoGuiText { param($Key,$Fallback='') $text=Get-QiehaoLocalizedString -Key $Key -Language 'en-US'; if ($text -like '[[]Missing:*' -and $Fallback) {return $Fallback}; return $text }
function Format-QiehaoGuiText { param($Key,$Arguments=@(),$Fallback='') return [string]::Format((Get-QiehaoGuiText $Key $Fallback),[object[]]$Arguments) }
function Show-QiehaoNameDialog { param($Title,$Prompt) return 'Fake Added' }
function Get-QiehaoSelectedProfileName { if ($null -ne $profilesGrid.SelectedItem) { return $profilesGrid.SelectedItem.Name }; return '' }
function Update-QiehaoActionButtons { $script:buttonsEnabled = -not ($script:guiIsWriteOperationBusy -or $script:guiManualRecoveryRequired) }
function Show-QiehaoSafeMessage { param($Message,$Severity) $script:lastSafeMessage=$Message }
function Set-QiehaoSwitchUiState { param($State,$TargetProfile) $script:completionState=$State }
function Close-QiehaoManualSwitchWaitDialog { $script:dialogClosed=$true }
function Set-QiehaoQuotaUnavailableRows { param($Rows) }
function Disable-QiehaoQuotaFeature { $script:guiQuotaModulesAvailable=$false }
$refreshStatusText = New-Object Windows.Controls.TextBlock
$activeProfileText = New-Object Windows.Controls.TextBlock
$profileCountText = New-Object Windows.Controls.TextBlock
$profileSearchTextBox = New-Object Windows.Controls.TextBox
$profilesGrid = New-Object Windows.Controls.DataGrid
$profilesGrid.AutoGenerateColumns=$false
$col = New-Object Windows.Controls.DataGridTextColumn
$col.Binding = New-Object Windows.Data.Binding('Active')
$null = $profilesGrid.Columns.Add($col)
$script:guiAllProfileRows=@(); $script:guiVerificationStates=@{}; $script:guiVerificationStateCodes=@{}
$script:guiQuotaModulesAvailable=$true; $script:guiQuotaCache=New-QiehaoEmptyQuotaCache
$script:guiQuotaJustUpdatedProfile=''; $script:guiLanguage='en-US'
$script:guiIsWriteOperationBusy=$false; $script:guiCurrentActiveProfile=''; $script:guiActiveProfileKnown=$false
$script:guiCurrentStatusKey=''; $script:guiCurrentStatusArguments=@()
. (Join-Path $projectRoot 'gui\LifecycleWorker.ps1')
$script:guiLifecycleRegistry.TestHome=$fakeHome
$script:guiLifecycleRegistry.TestProfiles=$fakeProfiles
$script:guiLifecycleRegistry.TestState=$fakeState
$script:guiLifecycleRegistry.TestLogs=Join-Path $root 'logs'
$script:guiLifecycleRegistry.TestResult='SWITCH_VERIFIED_SUCCESS'
$script:guiLifecycleRegistry.TestRollback=$false
$tokens=$null; $parseErrors=$null
$guiAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'gui\QiehaoGui.ps1'),[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw 'GUI_SOURCE_PARSE_FAILED' }
$functions=@('Set-QiehaoLocalizedStatus','Set-QiehaoWriteBusy','Update-QiehaoLocalizedProfileRows','Update-QiehaoProfileFilter',
    'Update-QiehaoQuotaRows','Sync-QiehaoCommittedActiveState','Set-QiehaoSnapshot','Invoke-QiehaoReadOnlyRefresh',
    'Complete-QiehaoSwitchUiAfterBackend','Invoke-QiehaoDeferredSwitchCompletion','Show-QiehaoOperationResult','Update-QiehaoProcessOnlyStatus','Write-QiehaoRefreshResult')
foreach ($name in $functions) {
    $ast=$guiAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name}.GetNewClosure(),$true)
    if ($null -eq $ast) { throw ('GUI_FUNCTION_MISSING_'+$name) }
    Invoke-Expression $ast.Extent.Text
}
$results=[ordered]@{}
function Assert-GuiActive([bool]$Condition,[string]$Name) { if (-not $Condition) { throw ('GUI_ACTIVE_'+$Name) }; $results[$Name]='PASS' }
function New-FakeAuth([string]$Id) {
    return ,([Text.UTF8Encoding]::new($false)).GetBytes((@{auth_mode='chatgpt';OPENAI_API_KEY=$null;tokens=@{account_id=$Id;access_token='FAKE-ACCESS';refresh_token='FAKE-REFRESH';id_token='FAKE-ID'};last_refresh='2000-01-01T00:00:00Z'} | ConvertTo-Json -Depth 4 -Compress))
}
$a=New-FakeAuth 'FAKE-A'; $b=New-FakeAuth 'FAKE-B'; $c=$null
function Invoke-LocalFakeSwitch([string]$Name) {
    return & $module {param($n,$c,$p,$s) Invoke-CodexAccountSwitch -Name $n -CodexHome $c -ProfilesDirectory $p -StateDirectory $s -ProcessData @() -UseProvidedProcessData} $Name $fakeHome $fakeProfiles $fakeState
}
function Assert-Current([string]$Expected) {
    $rows=@($profilesGrid.ItemsSource)
    $current=@($rows | Where-Object ActiveCode -CEQ 'Yes')
    if (-not $Expected) { return ($current.Count -eq 0 -and -not $script:guiActiveProfileKnown) }
    return ($current.Count -eq 1 -and $current[0].Name -ceq $Expected -and $script:guiCurrentActiveProfile -ceq $Expected -and $activeProfileText.Text -ceq $Expected)
}
$fakeSwitchWorker={
    param($ModulePath,$Action,$Name,$Registry)
    $core=Import-Module $ModulePath -Force -PassThru
    & $core {param($l) $script:LogsDirectory=$l} $Registry.TestLogs
    try {
        $null=& $core {param($n,$c,$p,$s,$r) Invoke-CodexAccountSwitch -Name $n -CodexHome $c -ProfilesDirectory $p -StateDirectory $s -ProcessData @() -UseProvidedProcessData -SimulatePostReplaceVerificationFailure:$r} $Name $Registry.TestHome $Registry.TestProfiles $Registry.TestState $Registry.TestRollback
    } catch { if (-not $Registry.TestRollback) { throw } }
    [pscustomobject]@{Result=$Registry.TestResult}
}
function Run-GuiFakeSwitch([string]$Name,[string]$Result='SWITCH_VERIFIED_SUCCESS',[bool]$Rollback=$false) {
    $script:guiLifecycleRegistry.TestResult=$Result; $script:guiLifecycleRegistry.TestRollback=$Rollback
    Set-QiehaoWriteBusy -Value $true -StatusText 'WORKING'
    $before=$script:activeReads
    try { $raw=Invoke-QiehaoResponsiveLifecycle -Action Switch -Name $Name -TestWorker $fakeSwitchWorker }
    finally { Set-QiehaoWriteBusy -Value $false }
    Assert-GuiActive ($script:activeReads-$before -eq 1) 'ExactlyOneExplicitActiveReadPerCompletion'
    Assert-GuiActive (-not $script:guiLifecycleWorkerRunning -and -not $script:guiIsWriteOperationBusy) 'SwitchBusyStateAlwaysClears'
    return $raw
}
try {
    foreach ($entry in @(@('A',$a),@('B',$b))) {
        [IO.File]::WriteAllBytes((Join-Path $fakeHome 'auth.json'),[byte[]]$entry[1])
        $null=& $module {param($n,$c,$p,$s) Invoke-AddCodexProfile -Name $n -CodexHome $c -ProfilesDirectory $p -StateDirectory $s -ProcessData @() -UseProvidedProcessData} $entry[0] $fakeHome $fakeProfiles $fakeState
    }
    $null=Invoke-LocalFakeSwitch A
    $null=Sync-QiehaoCommittedActiveState
    Assert-GuiActive (Assert-Current A) 'InitialA'
    $raw=Run-GuiFakeSwitch B
    Assert-GuiActive (Assert-Current B) 'VerifiedSwitchBWithoutDesktop'
    $presentation=Complete-QiehaoSwitchUiAfterBackend -Result (ConvertTo-QiehaoOperationResult -ResultCode $raw.Result) -TargetProfile B
    Assert-GuiActive ($presentation.UiRefreshSucceeded -and $presentation.State -ceq 'SwitchSucceeded') 'CompletionUsesCommittedCurrentWithoutProcessScan'
    $script:guiVerificationStateCodes['B']='Verified'
    Update-QiehaoLocalizedProfileRows
    Assert-GuiActive ((@($profilesGrid.ItemsSource | Where-Object Name -CEQ 'B')[0].VerificationCode -ceq 'Verified') -and (Assert-Current B)) 'VerificationDisplayUpdatedWithoutFullRefresh'
    $script:guiVerificationStateCodes.Clear()
    $null=Run-GuiFakeSwitch A
    Assert-GuiActive (Assert-Current A) 'SwitchBackAWithoutDesktop'
    $null=Run-GuiFakeSwitch B SWITCH_AUTH_UNVERIFIED_TRANSIENT
    Assert-GuiActive ((Assert-Current B) -and $script:guiCurrentStatusKey -ceq 'Operation.SWITCH_AUTH_UNVERIFIED_TRANSIENT') 'TransientCurrentBAndFinalStatus'
    $results.LocalCommittedTransientShowsTargetCurrent = (Assert-Current B)
    $null=Run-GuiFakeSwitch A
    $null=Run-GuiFakeSwitch B SWITCH_REAUTH_REQUIRED
    Assert-GuiActive ((Assert-Current B) -and $script:guiCurrentStatusKey -ceq 'Operation.SWITCH_REAUTH_REQUIRED') 'ReauthCurrentBAndFinalStatus'
    $null=Run-GuiFakeSwitch A
    $null=Run-GuiFakeSwitch B SWITCH_POST_VERIFY_IDENTITY_MISMATCH $true
    Assert-GuiActive (Assert-Current A) 'RollbackRestoresCurrentA'
    $oldSnapshot=Get-QiehaoCommittedProfileSnapshot -ListProvider {Get-CodexAccountSlot} -ActiveProvider {Get-CodexActiveProfile}
    $oldGeneration=$script:guiRefreshEpoch.Generation; $oldSequence=$script:guiRefreshEpoch.Sequence
    $null=Run-GuiFakeSwitch B
    Set-QiehaoSnapshot -Snapshot $oldSnapshot -Generation $oldGeneration -Sequence $oldSequence
    Assert-GuiActive (Assert-Current B) 'OlderSnapshotCannotOverwriteB'
    $beforeCodes=(@($script:guiAllProfileRows | ForEach-Object {$_.Name+':'+$_.ActiveCode}) -join '|')
    $script:guiQuotaJustUpdatedProfile='A'
    Update-QiehaoQuotaRows
    Assert-GuiActive ((Assert-Current B) -and $beforeCodes -ceq (@($script:guiAllProfileRows | ForEach-Object {$_.Name+':'+$_.ActiveCode}) -join '|')) 'OldQuotaAResultCannotSetCurrent'
    # Exercise actual process classification with only synthetic descriptors.
    $servicePath='C:\Program Files\WindowsApps\OpenAI.Codex_26.928.2636.0_x64__2p2nqsd0c76g0\app\resources\codex-windows-sandbox-service.exe'
    $sandbox=@([pscustomobject]@{ProcessName='codex-windows-sandbox-service.exe';Id=41001;ExecutablePath=$servicePath;PathReadStatus='Readable';ProcessStartTimeUtc=[DateTime]'2000-01-01T00:00:00Z';StartTimeReadStatus='Readable';ParentProcessId=600;ParentReadStatus='Readable';SessionId=0})
    $service=[pscustomobject]@{Name='CodexSandboxService.OpenAI.Codex';ProcessId=41001;PathName=$servicePath;StartName='LocalSystem';State='Running'}
    $serviceProvider={return @($service)}.GetNewClosure()
    $proved=& $module {param($p,$sp) Add-CodexSandboxServiceEvidence -Snapshot $p -ServiceProvider $sp} $sandbox $serviceProvider
    $gate=Test-CodexProcessesStopped -ProcessData @($proved)
    Assert-GuiActive ($gate.SafeToSave -and (Assert-Current B)) 'SandboxStillRunningCurrentBWithoutDesktop'
    function Get-QiehaoLiveCodexStatus { return [string][char]0x5DF2+[char]0x9000+[char]0x51FA }
    function Set-QiehaoCodexStatusVisual {param($Status) $script:fakeProcessStatus=$Status}
    $script:guiIsClosing=$false
    $null=Update-QiehaoProcessOnlyStatus
    Assert-GuiActive (Assert-Current B) 'ProcessMonitorCannotSetCurrent'
    # The actual read-only refresh can reenter while a dispatcher operation commits.
    $null=Invoke-LocalFakeSwitch A
    $null=Sync-QiehaoCommittedActiveState
    function Get-QiehaoOwnedQuotaProcessDescriptors {return @()}
    function Get-QiehaoGuiProcessState {return Test-CodexProcessesStopped}
    function Test-CodexProcessesStopped {
        param($OwnedProcessDescriptors)
        $null=Invoke-LocalFakeSwitch B
        $null=Sync-QiehaoCommittedActiveState
        return [pscustomobject]@{SafeToSave=$true;ReasonCode='CODEX_PROCESSES_STOPPED'}
    }
    function Test-CodexActiveIdentity {return [pscustomobject]@{Result='ACTIVE_IDENTITY_CONFIRMED'}}
    $late=Invoke-QiehaoReadOnlyRefresh -PassThru
    Assert-GuiActive (-not $late -and (Assert-Current B)) 'ReentrantOldRefreshRejectedAfterNewCommit'
    # Reproduce dynamic-module script writes; the new delegate calls a GUI function instead.
    $script:guiManualSwitchResult=$null
    $legacy=[Action]({$script:guiManualSwitchResult='legacy-result'}.GetNewClosure())
    $legacy.Invoke()
    Assert-GuiActive ($null -eq $script:guiManualSwitchResult) 'LegacyClosureScopeLossReproduced'
    function Invoke-QiehaoSwitchCore {param($TargetProfile,[switch]$DeferPresentation) return ConvertTo-QiehaoOperationResult -ResultCode 'SWITCH_VERIFIED_SUCCESS'}
    $capturedTarget='B'
    $fixed=[Action]({Invoke-QiehaoDeferredSwitchCompletion -TargetProfile $capturedTarget}.GetNewClosure())
    $fixed.Invoke()
    Assert-GuiActive ($script:guiManualSwitchResult.ResultCode -ceq 'SWITCH_VERIFIED_SUCCESS' -and $script:guiManualSwitchWaitOutcome -ceq 'SwitchSucceeded' -and $script:dialogClosed) 'DeferredCompletionWritesOriginalGuiScope'
    $uiMismatch=0; $contamination=0
    for ($index=0;$index -lt 100;$index++) {
        $name=if ($index%2 -eq 0) {'A'} else {'B'}
        $null=Run-GuiFakeSwitch $name
        $disk=Get-CodexActiveProfile
        if (-not (Assert-Current $disk.ActiveProfile)) { $uiMismatch++ }
        $expected=if ($name -ceq 'A') {$a} else {$b}
        $actual=[IO.File]::ReadAllBytes((Join-Path $fakeHome 'auth.json'))
        if ([Convert]::ToBase64String($actual) -cne [Convert]::ToBase64String($expected)) { $contamination++ }
        [Array]::Clear($actual,0,$actual.Length)
    }
    Assert-GuiActive ($uiMismatch -eq 0 -and $contamination -eq 0) 'HundredCoreTransactionsAndGuiCompletions'
    foreach ($name in @('A','B')) {
        $saved=& $module {param($n,$p) Read-CodexAccountSlotBytes -Name $n -ProfilesDirectory $p} $name $fakeProfiles
        $expected=if ($name -ceq 'A') {$a} else {$b}
        Assert-GuiActive ([Convert]::ToBase64String($saved) -ceq [Convert]::ToBase64String($expected)) ('SavedProfileUncontaminated'+$name)
        [Array]::Clear($saved,0,$saved.Length)
    }
    # Same-generation late refresh is rejected by request sequence too.
    $sameGen=$script:guiRefreshEpoch.Generation; $oldSeq=$script:guiRefreshEpoch.Sequence
    $null=Sync-QiehaoCommittedActiveState
    Set-QiehaoSnapshot -Snapshot $oldSnapshot -Generation $sameGen -Sequence $oldSeq
    Assert-GuiActive (Assert-Current B) 'OlderSequenceWithinGenerationRejected'
    # Manual recovery is not silently cleared by a readable Active state.
    $null=Run-GuiFakeSwitch A DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED
    Assert-GuiActive ((Assert-Current '') -and -not $script:buttonsEnabled) 'ManualRecoveryUnknownAndSafetyDisabled'
    $script:guiManualRecoveryRequired=$false
    $null=Sync-QiehaoCommittedActiveState
    Set-QiehaoWriteBusy -Value $true -StatusText 'WORKING'
    Set-QiehaoWriteBusy -Value $false
    Assert-GuiActive (-not $script:guiIsWriteOperationBusy -and $script:guiCurrentStatusKey -ceq 'Status.Ready') 'CancelledBeforeWorkerDoesNotLeaveWorkingStatus'
    # Non-switch actions, including exceptional workers, use the same barrier.
    foreach ($action in @('Switch','Login','ManualAdd','Delete','Verify')) {
        Set-QiehaoWriteBusy -Value $true -StatusText 'WORKING'
        try { $null=Invoke-QiehaoResponsiveLifecycle -Action $action -Name Fake -TestWorker {throw 'FAKE_WORKER_FAILURE'} } catch { }
        finally { Set-QiehaoWriteBusy -Value $false }
        Assert-GuiActive (-not $script:guiIsWriteOperationBusy -and -not $script:guiLifecycleWorkerRunning -and $script:guiCurrentStatusKey -ceq 'Operation.ACCOUNT_OPERATION_FAILED') ($action+'BusyStateAlwaysClears')
    }
    # List changes are rebuilt from actual fake profile artifacts.
    $c=New-FakeAuth 'FAKE-C'
    [IO.File]::WriteAllBytes((Join-Path $fakeHome 'auth.json'),$c)
    $null=& $module {param($c,$p,$s) Invoke-AddCodexProfile -Name C -CodexHome $c -ProfilesDirectory $p -StateDirectory $s -ProcessData @() -UseProvidedProcessData} $fakeHome $fakeProfiles $fakeState
    $null=Sync-QiehaoCommittedActiveState
    Assert-GuiActive ((Assert-Current C) -and @($profilesGrid.ItemsSource).Count -eq 3) 'AddRebuildsCommittedList'
    $null=& $module {param($p,$s) Invoke-RenameCodexProfile -OldName C -NewName Renamed -ProfilesDirectory $p -StateDirectory $s} $fakeProfiles $fakeState
    $null=Sync-QiehaoCommittedActiveState
    Assert-GuiActive (Assert-Current Renamed) 'RenamedCurrentFollowsCommittedName'
    $null=& $module {param($p,$s) Invoke-RemoveCodexProfile -Name B -ProfilesDirectory $p -StateDirectory $s -ConfirmDelete} $fakeProfiles $fakeState
    $null=Sync-QiehaoCommittedActiveState
    Assert-GuiActive ((Assert-Current Renamed) -and @($profilesGrid.ItemsSource | Where-Object Name -CEQ 'B').Count -eq 0) 'DeleteNonCurrentKeepsCurrent'
    & $module {param($s) [IO.File]::Delete((Join-Path $s 'active-profile.json'))} $fakeState
    $null=Sync-QiehaoCommittedActiveState
    Assert-GuiActive (Assert-Current '') 'NoActiveZeroCurrent'
    $bad=Get-QiehaoCommittedProfileSnapshot -ListProvider {throw 'FAKE_LIST_ERROR'} -ActiveProvider {[pscustomobject]@{ActiveProfile='A'}}
    Assert-GuiActive (-not $bad.ActiveProfileKnown -and @($bad.Profiles | Where-Object ActiveCode -CEQ 'Yes').Count -eq 0) 'ReadFailureNeverGuessesTarget'
    $results.SingleCurrentMarkerInvariant=$true; $results.GuiMatchesPersistedActiveProfile=$true
    # AccountLogin test4: the real dispatcher completion barrier must keep
    # existing profiles visible for every non-success result and block refresh.
    & $module {param($s) Write-ActiveProfileState -Name A -StateDirectory $s} $fakeState
    $null=Sync-QiehaoCommittedActiveState
    $refreshChecks=@{Count=0;Blocked=$true;Visible=$true}
    $refreshTimer=New-Object Windows.Threading.DispatcherTimer
    $refreshTimer.Interval=[TimeSpan]::FromMilliseconds(20)
    $refreshTick=[EventHandler]({
        $refreshChecks.Count++
        if (Invoke-QiehaoReadOnlyRefresh -PassThru) {$refreshChecks.Blocked=$false}
        if (@($profilesGrid.ItemsSource | Where-Object Name -CEQ 'A').Count -ne 1) {$refreshChecks.Visible=$false}
    }.GetNewClosure())
    $refreshTimer.Add_Tick($refreshTick)
    try {
        foreach ($code in @('ACCOUNT_LOGIN_FAILED','ACCOUNT_LOGIN_CANCELLED','ACCOUNT_LOGIN_TIMEOUT',
            'ACCOUNT_LOGIN_MANUAL_FALLBACK_REQUIRED','AUTH_JSON_INVALID','ACCOUNT_LOGIN_IDENTITY_MISMATCH',
            'PROFILE_IDENTITY_ALREADY_EXISTS','ACCOUNT_OPERATION_FAILED')) {
            $script:guiLifecycleRegistry.TestResult=$code
            Set-QiehaoWriteBusy -Value $true
            $refreshTimer.Start()
            try {
                $null=Invoke-QiehaoResponsiveLifecycle -Action Login -TestWorker {
                    param($m,$action,$name,$registry)
                    [Threading.Thread]::Sleep(120)
                    [pscustomobject]@{Result=$registry.TestResult}
                }
            } finally {$refreshTimer.Stop()}
            Assert-GuiActive (-not $script:guiIsWriteOperationBusy -and -not $script:guiLifecycleWorkerRunning -and (Assert-Current A) -and
                @($profilesGrid.ItemsSource | Where-Object Name -CEQ 'A').Count -eq 1) ($code+'ClearsBusyAndKeepsPersistedA')
        }
        Assert-GuiActive ($refreshChecks.Count -gt 0 -and $refreshChecks.Blocked -and $refreshChecks.Visible) 'RefreshCannotOverwriteActiveLoginState'
        $stoppedText=[string][char]0x5DF2+[char]0x9000+[char]0x51FA
        $actionState=Get-QiehaoActionState -SelectedProfile A -ActiveProfile A -CodexStatus $stoppedText -IsWriteOperationBusy
        Assert-GuiActive (-not $actionState.Refresh -and -not $actionState.Add) 'BusyRefreshAndAddDisabled'
        $actionState=Get-QiehaoActionState -SelectedProfile A -ActiveProfile A -CodexStatus $stoppedText
        Assert-GuiActive ($actionState.Refresh -and $actionState.Add) 'IdleRefreshAndAddRestored'
        Set-QiehaoWriteBusy -Value $true
        $null=Invoke-QiehaoResponsiveLifecycle -Action Login -TestWorker {param($m,$action,$name,$registry) [pscustomobject]@{Result='DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED'}}
        Assert-GuiActive (-not $script:guiIsWriteOperationBusy -and (Assert-Current '') -and
            @($profilesGrid.ItemsSource | Where-Object Name -CEQ 'A').Count -eq 1 -and -not $script:buttonsEnabled) 'LoginManualRecoveryKeepsProfilesAndUnknownCurrent'
        $script:guiManualRecoveryRequired=$false
        $null=Sync-QiehaoCommittedActiveState
    } finally {$refreshTimer.Stop();$refreshTimer.Remove_Tick($refreshTick)}
    $results.AccountLoginBusyAlwaysClears=$true
    $results.PersistedProfileVisibilityPreserved=$true
    $results.RefreshCannotOverwriteActiveLoginState=$true
    $results.AddBusyStateAlwaysClears=$true
    $results.SwitchesWithoutDesktop=100; $results.UiActiveProfileMismatch=$uiMismatch; $results.IdentityCrossContamination=$contamination
    $results.RealAuthOrProfileRead=$false; $results.RealNetworkRequests=$false; $results.CodexDesktopStarted=$false; $results.Status='PASS'
    [pscustomobject]$results
} finally {
    foreach ($buffer in @($a,$b,$c)) {if ($null -ne $buffer) {[Array]::Clear($buffer,0,$buffer.Length)}}
    $profilesGrid.ItemsSource=$null
    if ([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) {[IO.Directory]::Delete($root,$true)}
}
