[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$module = Import-Module (Join-Path $projectRoot 'lib\CodexAuth.psm1') -Force -PassThru
Import-Module (Join-Path $projectRoot 'gui\GuiHelpers.psm1') -Force

function Assert-SandboxTest {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw $Code }
}

$servicePath = 'C:\Program Files\WindowsApps\OpenAI.Codex_26.928.2636.0_x64__2p2nqsd0c76g0\app\resources\codex-windows-sandbox-service.exe'
function New-FakeService {
    return [pscustomobject]@{
        Name = 'CodexSandboxService.OpenAI.Codex'
        ProcessId = 41001
        PathName = $servicePath
        StartName = 'LocalSystem'
        State = 'Running'
    }
}
function New-FakeSandboxProcess {
    param([string]$Name = 'codex-windows-sandbox-service.exe')
    return [pscustomobject]@{
        ProcessName = $Name
        Id = 41001
        ExecutablePath = $servicePath
        PathReadStatus = 'Readable'
        ProcessStartTimeUtc = [DateTime]'2000-01-01T00:00:00Z'
        StartTimeReadStatus = 'Readable'
        ParentProcessId = 600
        ParentReadStatus = 'Readable'
        SessionId = 0
    }
}
function Add-FakeServiceEvidence {
    param([object[]]$Snapshot, [object[]]$Services)
    $provider = { return $Services }.GetNewClosure()
    return @(& $module {
        param($Processes, $Provider)
        Add-CodexSandboxServiceEvidence -Snapshot $Processes -ServiceProvider $Provider
    } $Snapshot $provider)
}
function Assert-FakeBlocked {
    param([object[]]$Snapshot, [string]$Code)
    $result = Test-CodexProcessesStopped -ProcessData $Snapshot
    Assert-SandboxTest (
        -not $result.SafeToSave -and
        $result.ReasonCode -ceq 'CODEX_PROCESS_RUNNING'
    ) $Code
    return $result
}
function New-FakeAuth {
    param([string]$Name)
    $utf8 = [Text.UTF8Encoding]::new($false)
    $payload = [ordered]@{
        'https://api.openai.com/auth' = [ordered]@{
            chatgpt_account_id = 'FAKE-SANDBOX-' + $Name
            chatgpt_user_id = 'FAKE-SANDBOX-USER'
            chatgpt_plan_type = if ($Name -ceq 'A') { 'team' } else { 'plus' }
        }
    } | ConvertTo-Json -Depth 5 -Compress
    $headerPart = [Convert]::ToBase64String($utf8.GetBytes('{"alg":"none","typ":"JWT"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $payloadPart = [Convert]::ToBase64String($utf8.GetBytes($payload)).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $fakeIdToken = $headerPart + '.' + $payloadPart + '.fake'
    $json = [ordered]@{
        auth_mode = 'chatgpt'
        tokens = [ordered]@{
            account_id = 'FAKE-SANDBOX-' + $Name
            id_token = $fakeIdToken
            access_token = 'FAKE-ACCESS'
            refresh_token = 'FAKE-REFRESH'
        }
    } | ConvertTo-Json -Depth 6 -Compress
    return ,([Text.UTF8Encoding]::new($false)).GetBytes($json)
}
function Get-FakeProfileStamps {
    param([string]$Directory)
    $result = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Directory -File) {
        $result[$file.Name] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $result
}
function Test-FakeBytesEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($Left.Length -ne $Right.Length) { return $false }
    for ($i = 0; $i -lt $Left.Length; $i++) {
        if ($Left[$i] -ne $Right[$i]) { return $false }
    }
    return $true
}

$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot (
    '.selftest-sandbox-service-' + [Guid]::NewGuid().ToString('N')
)))
$testParent = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\') + '\'
Assert-SandboxTest ($root.StartsWith($testParent, [StringComparison]::OrdinalIgnoreCase)) 'SANDBOX_TEST_ROOT_INVALID'
$fakeCodexHome = Join-Path $root 'fake-codex-home'
$profiles = Join-Path $root 'profiles'
$state = Join-Path $root 'state'
$logs = Join-Path $root 'logs'
$bytesByName = @{}
try {
    foreach ($dir in @($fakeCodexHome, $profiles, $state, $logs)) {
        [IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    & $module { param($Logs) $script:LogsDirectory = $Logs } $logs

    $sandbox = @(Add-FakeServiceEvidence -Snapshot @(New-FakeSandboxProcess) -Services @(New-FakeService))
    $stopped = Test-CodexProcessesStopped -ProcessData $sandbox
    & $module {param($p) Assert-CodexNotRunning -ProcessData $p -UseProvidedProcessData -DelayProvider { throw 'SANDBOX_MUST_NOT_WAIT' }} $sandbox
    Assert-SandboxTest (
        $stopped.SafeToSave -and $stopped.ReasonCode -ceq 'CODEX_PROCESSES_STOPPED' -and
        @($stopped.PersistentSandboxServices).Count -eq 1 -and
        $stopped.PersistentSandboxServices[0].Classification -ceq 'CODEX_PERSISTENT_SANDBOX_SERVICE' -and
        @($stopped.BlockingProcesses).Count -eq 0
    ) 'VERIFIED_SANDBOX_SERVICE_BLOCKED'

    foreach ($name in @('codex', 'codex.exe', 'codex-code-mode-host.exe',
        'codex-command-runner.exe', 'codex-windows-sandbox-setup.exe', 'codex-app-server.exe')) {
        $realExecutor = [pscustomobject]@{
            ProcessName = $name; Id = 42002
            ExecutablePath = 'C:\Program Files\WindowsApps\OpenAI.Codex_26.928_x64__fake\app\resources\codex.exe'
            PathReadStatus = 'Readable'
        }
        $null = Assert-FakeBlocked -Snapshot @($sandbox + @($realExecutor)) -Code ('REAL_EXECUTOR_NOT_BLOCKED_' + $name)
    }
    $desktop = [pscustomobject]@{
        ProcessName = 'ChatGPT.exe'; Id = 42003; PathReadStatus = 'Readable'
        ExecutablePath = 'C:\Program Files\WindowsApps\OpenAI.Codex_26.928_x64__fake\app\ChatGPT.exe'
    }
    $null = Assert-FakeBlocked @($sandbox + @($desktop)) 'DESKTOP_WITH_SANDBOX_NOT_BLOCKED'
    $extension = [pscustomobject]@{
        ProcessName = 'extension-host.exe'; Id = 42004
        ExecutablePath = 'C:\Users\Fake\.codex\plugins\host\extension-host.exe'
        PathReadStatus = 'Readable'; ParentReadStatus = 'Readable'; ParentProcessId = 42003
    }
    $extensionResult = Assert-FakeBlocked @($sandbox + @($desktop, $extension)) 'CODEX_EXTENSION_NOT_BLOCKED'
    Assert-SandboxTest (
        @($extensionResult.BlockingProcesses | Where-Object {
            $_.PID -eq 42004 -and $_.Classification -ceq 'CODEX_EXTENSION_HOST'
        }).Count -eq 1
    ) 'CODEX_EXTENSION_CLASSIFICATION_NOT_PRESERVED'

    # Every independently invalid piece of service evidence remains blocking.
    foreach ($case in @('WrongName', 'WrongPID', 'WrongProcessPath', 'WrongServicePath',
        'WrongState', 'WrongAccount', 'WrongSession', 'InvalidPID',
        'DuplicateService', 'MissingService')) {
        $process = New-FakeSandboxProcess
        $service = New-FakeService
        switch ($case) {
            'WrongName' { $service.Name = 'SomeOtherService' }
            'WrongPID' { $service.ProcessId++ }
            'InvalidPID' { $service.ProcessId = 'NOT-A-PID' }
            'WrongProcessPath' { $process.ExecutablePath = 'C:\Temp\codex-windows-sandbox-service.exe' }
            'WrongServicePath' { $service.PathName = 'C:\Temp\codex-windows-sandbox-service.exe' }
            'WrongState' { $service.State = 'Stopped' }
            'WrongAccount' { $service.StartName = 'FakeUser' }
            'WrongSession' { $process.SessionId = 1 }
        }
        $services = @($service)
        if ($case -ceq 'DuplicateService') { $services += New-FakeService }
        if ($case -ceq 'MissingService') { $services = @() }
        $badSnapshot = @(Add-FakeServiceEvidence @($process) $services)
        $badResult = Assert-FakeBlocked $badSnapshot ('UNVERIFIED_SERVICE_IGNORED_' + $case)
        Assert-SandboxTest (
            $badResult.BlockingProcesses[0].Classification -ceq 'UNVERIFIED_CODEX_SANDBOX_SERVICE'
        ) ('UNVERIFIED_CLASSIFICATION_MISSING_' + $case)
    }
    $unavailable = @(& $module {
        param($Process)
        Add-CodexSandboxServiceEvidence -Snapshot @($Process) -ServiceProvider { throw 'FAKE_CIM_DENIED' }
    } (New-FakeSandboxProcess))
    $null = Assert-FakeBlocked $unavailable 'SERVICE_QUERY_FAILURE_IGNORED'
    $null = Assert-FakeBlocked @(New-FakeSandboxProcess) 'MISSING_EVIDENCE_IGNORED'

    # Ordinary users may not read a LocalSystem executable path. SCM path plus
    # exact live PID/name still verifies it; contradictory readable paths fail.
    $unreadable = New-FakeSandboxProcess -Name 'codex-windows-sandbox-service'
    $unreadable.ExecutablePath = ''
    $unreadable.PathReadStatus = 'Unavailable'
    $quotedService = New-FakeService
    $quotedService.PathName = '"' + $servicePath + '" --service'
    $unreadableSnapshot = @(Add-FakeServiceEvidence @($unreadable) @($quotedService))
    Assert-SandboxTest (
        (Test-CodexProcessesStopped -ProcessData $unreadableSnapshot).SafeToSave
    ) 'VERIFIED_SCM_PATH_UNREADABLE_PROCESS_REJECTED'
    $providerCalls = [pscustomobject]@{ Count = 0 }
    $null = & $module {
        param($Calls)
        Add-CodexSandboxServiceEvidence -Snapshot @(
            [pscustomobject]@{ ProcessName = 'notepad'; Id = 4 }
        ) -ServiceProvider { $Calls.Count++; throw 'SHOULD_NOT_QUERY' }
    } $providerCalls
    Assert-SandboxTest ($providerCalls.Count -eq 0) 'UNNECESSARY_SERVICE_QUERY'

    $quota = [pscustomobject]@{
        ProcessName = 'codex.exe'; Id = 43005
        ExecutablePath = 'C:\Fake\codex.exe'; PathReadStatus = 'Readable'
        ProcessStartTimeUtc = [DateTime]'2000-01-01T00:00:00Z'; StartTimeReadStatus = 'Readable'
        ParentProcessId = 77; ParentReadStatus = 'Readable'
    }
    $owner = [pscustomobject]@{
        IsActive = $true; ProcessId = 43005; ExecutablePath = 'C:\Fake\codex.exe'
        ProcessStartTimeUtc = [DateTime]'2000-01-01T00:00:00Z'
        Arguments = 'app-server --stdio'; ParentProcessId = 77
    }
    $quotaSnapshot = @($sandbox + @($quota))
    $quotaResult = Test-CodexProcessesStopped -ProcessData $quotaSnapshot -OwnedProcessDescriptors @($owner)
    Assert-SandboxTest (
        $quotaResult.SafeToSave -and @($quotaResult.OwnedQuotaProcesses).Count -eq 1 -and
        @($quotaResult.PersistentSandboxServices).Count -eq 1
    ) 'QUOTA_AND_SANDBOX_BLOCKED'
    $null = Assert-FakeBlocked $quotaSnapshot 'UNREGISTERED_APP_SERVER_IGNORED'
    foreach ($purpose in @('AccountVerify','AccountLogin')) {
        $accountOwner = [pscustomobject]@{
            IsActive=$true; ProcessId=$owner.ProcessId; ExecutablePath=$owner.ExecutablePath
            ProcessStartTimeUtc=$owner.ProcessStartTimeUtc; Arguments='app-server --stdio'
            ParentProcessId=$owner.ParentProcessId; Purpose=$purpose
        }
        $accountGate = Test-CodexProcessesStopped -ProcessData $quotaSnapshot -OwnedProcessDescriptors @($accountOwner)
        Assert-SandboxTest ($accountGate.SafeToSave -and $accountGate.OwnedQuotaProcesses[0].Classification -ceq 'QIEHAO_OWNED_APP_SERVER') ($purpose+'_SANDBOX_OWNERSHIP_FAILED')
        $desktopSnapshot = $quotaSnapshot + @([pscustomobject]@{ProcessName='codex.exe';Id=55501;ExecutablePath='C:\Fake\desktop\codex.exe';PathReadStatus='Readable'})
        $desktopGate = Test-CodexProcessesStopped -ProcessData $desktopSnapshot -OwnedProcessDescriptors @($accountOwner)
        Assert-SandboxTest (-not $desktopGate.SafeToSave) ($purpose+'_REAL_DESKTOP_BYPASSED')
    }

    $status = ConvertTo-QiehaoCodexStatus -ProcessState $stopped
    $actions = Get-QiehaoActionState -SelectedProfile 'A' -ActiveProfile 'B' -CodexStatus $status
    Assert-SandboxTest (
        $status -ceq ([string][char]0x5df2 + [char]0x9000 + [char]0x51fa) -and
        $actions.LaunchCodex -and $actions.Switch -and
        $actions.Delete -and $actions.Verify -and $actions.Add
    ) 'SANDBOX_GUI_ACTIONS_DISABLED'

    $records = @(& $module {
        param($Snapshot, $State)
        Get-QiehaoProcessDiagnosticRecords -Snapshot $Snapshot -ProcessState $State
    } $sandbox $stopped)
    Assert-SandboxTest (
        $records.Count -eq 1 -and -not $records[0].IsBlockingProcess -and
        $records[0].Classification -ceq 'CODEX_PERSISTENT_SANDBOX_SERVICE' -and
        $records[0].SessionId -eq 0 -and $records[0].ServiceStartName -ceq 'LocalSystem'
    ) 'SANDBOX_DIAGNOSTIC_CLASSIFICATION_FAILED'
    & $module {
        param($Records)
        Write-QiehaoDiagnosticEvent -Event 'PROCESS_CHECK_RESULT' -Result 'CODEX_PROCESSES_STOPPED' -Data @{ Processes = $Records }
    } $records

    foreach ($name in @('A', 'B')) {
        $bytesByName[$name] = New-FakeAuth $name
        [IO.File]::WriteAllBytes((Join-Path $fakeCodexHome 'auth.json'), $bytesByName[$name])
        $added = & $module {
            param($Name, $FakeHome, $Profiles, $State, $Processes)
            Invoke-AddCodexProfile -Name $Name -CodexHome $FakeHome -ProfilesDirectory $Profiles -StateDirectory $State -ProcessData $Processes -UseProvidedProcessData
        } $name $fakeCodexHome $profiles $state $sandbox
        Assert-SandboxTest ($added.Result -ceq 'PROFILE_ADD_SUCCESS') 'SANDBOX_ADD_FAILED'
    }
    $failures = 0
    $contamination = 0
    $mutations = 0
    $source = 'B'
    for ($iteration = 0; $iteration -lt 100; $iteration++) {
        $target = if ($source -ceq 'A') { 'B' } else { 'A' }
        $before = Get-FakeProfileStamps $profiles
        try {
            $switched = & $module {
                param($Target, $FakeHome, $Profiles, $State, $Processes)
                Invoke-CodexAccountSwitch -Name $Target -CodexHome $FakeHome -ProfilesDirectory $Profiles -StateDirectory $State -ProcessData $Processes -UseProvidedProcessData
            } $target $fakeCodexHome $profiles $state $sandbox
            if ($switched.Result -cne 'SWITCH_SUCCESS') { $failures++ }
        } catch { $failures++; throw }
        $after = Get-FakeProfileStamps $profiles
        if ($after.Count -ne $before.Count) { $mutations++ }
        foreach ($file in $before.Keys) {
            if ($file -notin @(($source + '.auth.dpapi'), ($source + '.identity.dpapi'), ($source + '.meta.json')) -and
                (-not $after.ContainsKey($file) -or $before[$file] -cne $after[$file])) { $mutations++ }
        }
        $live = [IO.File]::ReadAllBytes((Join-Path $fakeCodexHome 'auth.json'))
        $active = & $module { param($State) (Read-ActiveProfileState -StateDirectory $State).ActiveProfile } $state
        if ($active -cne $target -or -not (Test-FakeBytesEqual $live $bytesByName[$target])) { $contamination++ }
        [Array]::Clear($live, 0, $live.Length)
        foreach ($name in @('A', 'B')) {
            $saved = & $module {
                param($Name, $Profiles)
                Read-CodexAccountSlotBytes -Name $Name -ProfilesDirectory $Profiles
            } $name $profiles
            if (-not (Test-FakeBytesEqual $saved $bytesByName[$name])) { $contamination++ }
            [Array]::Clear($saved, 0, $saved.Length)
        }
        $source = $target
    }
    Assert-SandboxTest ($failures -eq 0 -and $contamination -eq 0 -and $mutations -eq 0) 'SANDBOX_STRESS_FAILED'
    $verified = & $module {
        param($Name, $FakeHome, $Profiles, $Processes)
        Invoke-VerifyCodexProfile -Name $Name -CodexHome $FakeHome -ProfilesDirectory $Profiles -ProcessData $Processes -UseProvidedProcessData
    } $source $fakeCodexHome $profiles $sandbox
    Assert-SandboxTest ($verified.Result -ceq 'PROFILE_VERIFY_SUCCESS') 'SANDBOX_VERIFY_FAILED'
    $other = if ($source -ceq 'A') { 'B' } else { 'A' }
    $deleted = & $module {
        param($Other, $FakeHome, $Profiles, $State, $Processes)
        $safety = Invoke-GetCodexProfileDeleteSafety -Name $Other -CodexHome $FakeHome -ProfilesDirectory $Profiles -StateDirectory $State -ProcessData $Processes -UseProvidedProcessData
        if ($safety.Result -cne 'PROFILE_DELETE_SAFE') { throw 'SANDBOX_DELETE_SAFETY_FAILED' }
        Invoke-RemoveCodexProfile -Name $Other -ProfilesDirectory $Profiles -StateDirectory $State -ConfirmDelete
    } $other $fakeCodexHome $profiles $state $sandbox
    Assert-SandboxTest ($deleted.Result -ceq 'PROFILE_REMOVE_SUCCESS') 'SANDBOX_DELETE_FAILED'
    $log = [IO.File]::ReadAllText((Join-Path $logs 'qiehao.log'))
    Assert-SandboxTest (
        $log -match 'CODEX_PERSISTENT_SANDBOX_SERVICE' -and
        $log -notmatch 'FAKE-SANDBOX-|FAKE-ACCESS|FAKE-REFRESH|FAKE-ID'
    ) 'SANDBOX_DIAGNOSTIC_SECRET_OR_MISSING_CLASSIFICATION'

    [pscustomobject]@{
        Result = 'PASS'
        SandboxServiceDetected = $true
        SandboxServiceBlocks = $false
        SandboxServiceOnlyFastPathDoesNotWait = $true
        RealCodexStillBlocks = 'PASS'
        DesktopStillBlocks = 'PASS'
        ExecutorHelpersStillBlock = 'PASS'
        CodexExtensionStillBlocks = 'PASS'
        UnverifiedServiceFailClosed = 'PASS'
        ServicePidMismatchBlocks = 'PASS'
        ServicePathMismatchBlocks = 'PASS'
        ServiceQueryFailureBlocks = 'PASS'
        UnreadableProcessUsesVerifiedScmPath = 'PASS'
        NoUnnecessaryServiceQuery = 'PASS'
        OwnedQuotaWithSandboxAllowed = 'PASS'
        UnregisteredQuotaStillBlocks = 'PASS'
        SandboxGuiStoppedAndLaunchEnabled = 'PASS'
        SandboxDiagnosticClassification = 'PASS'
        AddWithSandbox = 'PASS'
        VerifyWithSandbox = 'PASS'
        DeleteWithSandbox = 'PASS'
        SwitchIterations = 100
        RandomSwitchFailures = $failures
        IdentityCrossContamination = $contamination
        UnexpectedProfileMutations = $mutations
        RealAuthOrProfileRead = $false
        RealCodexAuthRead = $false
        RealQuotaRpc = $false
        ServiceControlCalls = 0
    }
}
finally {
    foreach ($bytes in $bytesByName.Values) {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
    if ([IO.Directory]::Exists($root)) { [IO.Directory]::Delete($root, $true) }
}
