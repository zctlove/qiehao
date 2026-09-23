[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot 'lib\CodexAuth.psm1'
$module = Import-Module -Name $modulePath -Force -PassThru -ErrorAction Stop
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot (
    '.delete-transaction-' + [Guid]::NewGuid().ToString('N')
)))
$aBytes = $null
$bBytes = $null

function Assert-DeleteTest {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw $Code }
}

function New-FakeAuthBytes {
    param([string]$Identity)

    $auth = [ordered]@{
        auth_mode = 'chatgpt'
        OPENAI_API_KEY = $null
        tokens = [ordered]@{
            id_token = 'DELETE-FAKE-ID-' + $Identity
            access_token = 'DELETE-FAKE-ACCESS-' + $Identity
            refresh_token = 'DELETE-FAKE-REFRESH-' + $Identity
            account_id = 'DELETE-FAKE-ACCOUNT-' + $Identity
        }
        last_refresh = '2000-01-01T00:00:00Z'
    }
    $json = $auth | ConvertTo-Json -Compress -Depth 8
    try {
        return ,(New-Object System.Text.UTF8Encoding($false, $true)).GetBytes($json)
    }
    finally {
        $json = $null
        $auth = $null
    }
}

function New-DeleteFixture {
    param(
        [string]$Root,
        $Module,
        [byte[]]$ActiveBytes,
        [byte[]]$TargetBytes
    )

    $profiles = Join-Path $Root 'profiles'
    $state = Join-Path $Root 'state'
    [System.IO.Directory]::CreateDirectory($profiles) | Out-Null
    [System.IO.Directory]::CreateDirectory($state) | Out-Null
    & $Module {
        param($A, $B, $Profiles, $State)
        $null = Write-CodexAccountSlotBytes -Name 'A' -AuthBytes $A `
            -ProfilesDirectory $Profiles
        $null = Write-CodexAccountSlotBytes -Name 'B' -AuthBytes $B `
            -ProfilesDirectory $Profiles
        Write-ActiveProfileState -Name 'A' -StateDirectory $State
    } $ActiveBytes $TargetBytes $profiles $state
    return [pscustomobject]@{
        Profiles = $profiles
        State = $state
        Mutex = 'Local\Qiehaoqu.DeleteTransactionSelfTest.' +
            [Guid]::NewGuid().ToString('N')
    }
}

function Assert-CompleteProfile {
    param([string]$Name, [string]$ProfilesDirectory)
    foreach ($suffix in @('.auth.dpapi', '.identity.dpapi', '.meta.json')) {
        Assert-DeleteTest -Condition ([System.IO.File]::Exists(
                (Join-Path $ProfilesDirectory ($Name + $suffix))
            )) -Code ('DELETE_TEST_PROFILE_INCOMPLETE_' + $Name + $suffix)
    }
}

function Assert-NoFormalProfile {
    param([string]$Name, [string]$ProfilesDirectory)
    foreach ($suffix in @('.auth.dpapi', '.identity.dpapi', '.meta.json')) {
        Assert-DeleteTest -Condition (-not [System.IO.File]::Exists(
                (Join-Path $ProfilesDirectory ($Name + $suffix))
            )) -Code ('DELETE_TEST_FORMAL_ARTIFACT_REMAINED_' + $Name + $suffix)
    }
}

function Get-ProfileStamp {
    param([string]$Name, [string]$ProfilesDirectory)
    $parts = New-Object System.Collections.ArrayList
    foreach ($suffix in @('.auth.dpapi', '.identity.dpapi', '.meta.json')) {
        $path = Join-Path $ProfilesDirectory ($Name + $suffix)
        if (-not [System.IO.File]::Exists($path)) {
            [void]$parts.Add($suffix + ':MISSING')
            continue
        }
        [void]$parts.Add(
            $suffix + ':' +
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash +
            ':' + ([System.IO.FileInfo]$path).Length
        )
    }
    return @($parts) -join '|'
}

function Get-DeleteTransactionDirectories {
    param([string]$ProfilesDirectory)
    $trash = Join-Path $ProfilesDirectory '.trash'
    if (-not [System.IO.Directory]::Exists($trash)) { return @() }
    return @(
        Get-ChildItem -LiteralPath $trash -Directory -Force -ErrorAction Stop
    )
}

function Get-ActiveProfileName {
    param($Module, [string]$StateDirectory)
    return [string](& $Module {
        param($State)
        (Read-ActiveProfileState -StateDirectory $State).ActiveProfile
    } $StateDirectory)
}

try {
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $aBytes = New-FakeAuthBytes -Identity 'A'
    $bBytes = New-FakeAuthBytes -Identity 'B'

    # A first-run installation has no Active state and no delete transaction.
    # Startup recovery must remain a no-op instead of blocking the empty UI.
    $firstRunProfiles = Join-Path $testRoot 'first-run\profiles'
    $firstRunState = Join-Path $testRoot 'first-run\state'
    [System.IO.Directory]::CreateDirectory($firstRunProfiles) | Out-Null
    [System.IO.Directory]::CreateDirectory($firstRunState) | Out-Null
    $firstRunResult = & $module {
        param($Profiles, $State)
        Invoke-RecoverCodexProfileDeleteTransactions `
            -ProfilesDirectory $Profiles -StateDirectory $State `
            -MutexName ('Local\Qiehaoqu.DeleteFirstRun.' +
                [Guid]::NewGuid().ToString('N'))
    } $firstRunProfiles $firstRunState
    Assert-DeleteTest -Condition (
        $firstRunResult.RestoredTransactions -eq 0 -and
        $firstRunResult.CompletedTransactions -eq 0
    ) -Code 'DELETE_TEST_FIRST_RUN_RECOVERY_FAILED'

    # A. Normal deletion commits only after all three artifacts enter
    # quarantine, then removes the committed transaction directory.
    $normal = New-DeleteFixture -Root (Join-Path $testRoot 'A-normal') `
        -Module $module -ActiveBytes $aBytes -TargetBytes $bBytes
    $normalResult = & $module {
        param($Fixture)
        Invoke-RemoveCodexProfile -Name 'B' `
            -ProfilesDirectory $Fixture.Profiles `
            -StateDirectory $Fixture.State -ConfirmDelete `
            -MutexName $Fixture.Mutex
    } $normal
    Assert-DeleteTest -Condition (
        $normalResult.Result -ceq 'PROFILE_REMOVE_SUCCESS' -and
        [string]::IsNullOrWhiteSpace([string]$normalResult.WarningCode) -and
        -not $normalResult.QuarantineCleanupPending -and
        @(Get-DeleteTransactionDirectories $normal.Profiles).Count -eq 0
    ) -Code 'DELETE_TEST_NORMAL_RESULT_FAILED'
    Assert-NoFormalProfile -Name 'B' -ProfilesDirectory $normal.Profiles
    Assert-CompleteProfile -Name 'A' -ProfilesDirectory $normal.Profiles

    # B-D. Every move failure restores the exact complete Profile.
    $moveFailureResults = New-Object System.Collections.ArrayList
    foreach ($failureType in @('AuthFile', 'IdentityMarker', 'Metadata')) {
        $fixture = New-DeleteFixture `
            -Root (Join-Path $testRoot ('move-' + $failureType)) `
            -Module $module -ActiveBytes $aBytes -TargetBytes $bBytes
        $beforeStamp = Get-ProfileStamp -Name 'B' `
            -ProfilesDirectory $fixture.Profiles
        $result = & $module {
            param($Fixture, $Failure)
            Invoke-RemoveCodexProfile -Name 'B' `
                -ProfilesDirectory $Fixture.Profiles `
                -StateDirectory $Fixture.State -ConfirmDelete `
                -SimulateMoveFailureType $Failure `
                -MutexName $Fixture.Mutex
        } $fixture $failureType
        $afterStamp = Get-ProfileStamp -Name 'B' `
            -ProfilesDirectory $fixture.Profiles
        Assert-DeleteTest -Condition (
            $result.Result -ceq 'PROFILE_REMOVE_FAILED_ROLLED_BACK' -and
            $result.FailedFileTypes -ccontains $failureType -and
            $beforeStamp -ceq $afterStamp -and
            @(Get-DeleteTransactionDirectories $fixture.Profiles).Count -eq 0 -and
            (Get-ActiveProfileName -Module $module `
                -StateDirectory $fixture.State) -ceq 'A'
        ) -Code ('DELETE_TEST_MOVE_ROLLBACK_FAILED_' + $failureType)
        Assert-CompleteProfile -Name 'B' -ProfilesDirectory $fixture.Profiles
        [void]$moveFailureResults.Add($failureType + '=PASS')
    }

    # E. Cleanup failure happens after commit: the formal Profile remains
    # deleted, a clear warning is returned, and startup recovery can finish it.
    $cleanupFailure = New-DeleteFixture `
        -Root (Join-Path $testRoot 'E-cleanup-warning') `
        -Module $module -ActiveBytes $aBytes -TargetBytes $bBytes
    $cleanupResult = & $module {
        param($Fixture)
        Invoke-RemoveCodexProfile -Name 'B' `
            -ProfilesDirectory $Fixture.Profiles `
            -StateDirectory $Fixture.State -ConfirmDelete `
            -SimulateCleanupFailureType 'IdentityMarker' `
            -MutexName $Fixture.Mutex
    } $cleanupFailure
    $pendingTransactions = @(
        Get-DeleteTransactionDirectories $cleanupFailure.Profiles
    )
    $pendingCommitMarker = Join-Path (
        Join-Path $cleanupFailure.Profiles '.trash'
    ) ($pendingTransactions[0].Name + '.committed')
    Assert-DeleteTest -Condition (
        $cleanupResult.Result -ceq 'PROFILE_REMOVE_SUCCESS' -and
        $cleanupResult.WarningCode -ceq `
            'PROFILE_REMOVE_QUARANTINE_CLEANUP_FAILED' -and
        $cleanupResult.QuarantineCleanupPending -and
        $pendingTransactions.Count -eq 1 -and
        [System.IO.File]::Exists($pendingCommitMarker)
    ) -Code 'DELETE_TEST_CLEANUP_WARNING_NOT_PRESERVED'
    Assert-NoFormalProfile -Name 'B' -ProfilesDirectory $cleanupFailure.Profiles
    $cleanupRecovery = & $module {
        param($Fixture)
        Invoke-RecoverCodexProfileDeleteTransactions `
            -ProfilesDirectory $Fixture.Profiles `
            -StateDirectory $Fixture.State -MutexName $Fixture.Mutex
    } $cleanupFailure
    Assert-DeleteTest -Condition (
        $cleanupRecovery.CompletedTransactions -eq 1 -and
        $cleanupRecovery.CleanupPending -eq 0 -and
        @(Get-DeleteTransactionDirectories $cleanupFailure.Profiles).Count -eq 0
    ) -Code 'DELETE_TEST_COMMITTED_RECOVERY_FAILED'
    Assert-NoFormalProfile -Name 'B' -ProfilesDirectory $cleanupFailure.Profiles

    # If cleanup removed the transaction directory and the process stopped
    # before removing the sibling commit marker, startup finishes the delete
    # rather than mistaking the empty window for an uncommitted transaction.
    $markerWindow = New-DeleteFixture `
        -Root (Join-Path $testRoot 'E2-marker-window') `
        -Module $module -ActiveBytes $aBytes -TargetBytes $bBytes
    $markerWindowResult = & $module {
        param($Fixture)
        Invoke-RemoveCodexProfile -Name 'B' `
            -ProfilesDirectory $Fixture.Profiles `
            -StateDirectory $Fixture.State -ConfirmDelete `
            -SimulateCleanupFailureType 'IdentityMarker' `
            -MutexName $Fixture.Mutex
    } $markerWindow
    $markerWindowTransactions = @(
        Get-DeleteTransactionDirectories $markerWindow.Profiles
    )
    $markerWindowPath = Join-Path (
        Join-Path $markerWindow.Profiles '.trash'
    ) ($markerWindowTransactions[0].Name + '.committed')
    [System.IO.Directory]::Delete(
        $markerWindowTransactions[0].FullName,
        $true
    )
    Assert-DeleteTest -Condition (
        $markerWindowResult.QuarantineCleanupPending -and
        [System.IO.File]::Exists($markerWindowPath) -and
        @(Get-DeleteTransactionDirectories $markerWindow.Profiles).Count -eq 0
    ) -Code 'DELETE_TEST_ORPHAN_COMMIT_MARKER_SETUP_FAILED'
    $markerWindowRecovery = & $module {
        param($Fixture)
        Invoke-RecoverCodexProfileDeleteTransactions `
            -ProfilesDirectory $Fixture.Profiles `
            -StateDirectory $Fixture.State -MutexName $Fixture.Mutex
    } $markerWindow
    Assert-DeleteTest -Condition (
        $markerWindowRecovery.CompletedTransactions -eq 1 -and
        -not [System.IO.File]::Exists($markerWindowPath)
    ) -Code 'DELETE_TEST_ORPHAN_COMMIT_MARKER_RECOVERY_FAILED'
    Assert-NoFormalProfile -Name 'B' -ProfilesDirectory $markerWindow.Profiles

    # F. Simulate process termination before commit. Reload the module, point
    # its normal startup state reader at the fixture, and verify auto-restore.
    $interrupted = New-DeleteFixture `
        -Root (Join-Path $testRoot 'F-interrupted') `
        -Module $module -ActiveBytes $aBytes -TargetBytes $bBytes
    $interruptionCode = $null
    try {
        $null = & $module {
            param($Fixture)
            Invoke-RemoveCodexProfile -Name 'B' `
                -ProfilesDirectory $Fixture.Profiles `
                -StateDirectory $Fixture.State -ConfirmDelete `
                -SimulateInterruptionAfterMoveCount 2 `
                -MutexName $Fixture.Mutex
        } $interrupted
    }
    catch { $interruptionCode = [string]$_.Exception.Message }
    Assert-DeleteTest -Condition (
        $interruptionCode -ceq 'SIMULATED_PROFILE_DELETE_INTERRUPTION' -and
        @(Get-DeleteTransactionDirectories $interrupted.Profiles).Count -eq 1
    ) -Code 'DELETE_TEST_INTERRUPTION_NOT_CREATED'

    Remove-Module -ModuleInfo $module -Force -ErrorAction Stop
    $module = Import-Module -Name $modulePath -Force -PassThru -ErrorAction Stop
    $startupProfiles = & $module {
        param($Profiles, $State)
        $script:ProfilesDirectory = $Profiles
        $script:StateDirectory = $State
        @(Get-CodexAccountSlot)
    } $interrupted.Profiles $interrupted.State
    $startupTransactionCount = @(
        Get-DeleteTransactionDirectories $interrupted.Profiles
    ).Count
    $startupBCount = @($startupProfiles | Where-Object {
            @($_.PSObject.Properties.Name) -ccontains 'Profile' -and
            [string]$_.Profile -ceq 'B'
        }).Count
    $startupActiveName = Get-ActiveProfileName -Module $module `
        -StateDirectory $interrupted.State
    Assert-DeleteTest -Condition (
        $startupTransactionCount -eq 0 -and
        $startupBCount -eq 1 -and
        $startupActiveName -ceq 'A'
    ) -Code (
        'DELETE_TEST_STARTUP_RECOVERY_FAILED_' +
        'TRANSACTIONS_' + $startupTransactionCount +
        '_B_' + $startupBCount +
        '_ACTIVE_' + $startupActiveName
    )
    Assert-CompleteProfile -Name 'B' -ProfilesDirectory $interrupted.Profiles

    # G. The current Active Profile is still never eligible for deletion.
    $activeDelete = New-DeleteFixture `
        -Root (Join-Path $testRoot 'G-active') `
        -Module $module -ActiveBytes $aBytes -TargetBytes $bBytes
    $activeCode = $null
    try {
        $null = & $module {
            param($Fixture)
            Invoke-RemoveCodexProfile -Name 'A' `
                -ProfilesDirectory $Fixture.Profiles `
                -StateDirectory $Fixture.State -ConfirmDelete `
                -MutexName $Fixture.Mutex
        } $activeDelete
    }
    catch { $activeCode = [string]$_.Exception.Message }
    Assert-DeleteTest -Condition (
        $activeCode -ceq 'CANNOT_REMOVE_ACTIVE_PROFILE' -and
        @(Get-DeleteTransactionDirectories $activeDelete.Profiles).Count -eq 0
    ) -Code 'DELETE_TEST_ACTIVE_PROFILE_NOT_REJECTED'
    Assert-CompleteProfile -Name 'A' -ProfilesDirectory $activeDelete.Profiles
    Assert-CompleteProfile -Name 'B' -ProfilesDirectory $activeDelete.Profiles

    # A rollback failure is explicit and remains recoverable on the next
    # startup rather than being silently reported as a successful rollback.
    $rollbackFailure = New-DeleteFixture `
        -Root (Join-Path $testRoot 'rollback-failure') `
        -Module $module -ActiveBytes $aBytes -TargetBytes $bBytes
    $rollbackFailureResult = & $module {
        param($Fixture)
        Invoke-RemoveCodexProfile -Name 'B' `
            -ProfilesDirectory $Fixture.Profiles `
            -StateDirectory $Fixture.State -ConfirmDelete `
            -SimulateMoveFailureType 'IdentityMarker' `
            -SimulateRollbackFailureType 'AuthFile' `
            -MutexName $Fixture.Mutex
    } $rollbackFailure
    Assert-DeleteTest -Condition (
        $rollbackFailureResult.Result -ceq 'PROFILE_REMOVE_ROLLBACK_FAILED' -and
        $rollbackFailureResult.RollbackFailedFileTypes -ccontains 'AuthFile' -and
        @(Get-DeleteTransactionDirectories $rollbackFailure.Profiles).Count -eq 1
    ) -Code 'DELETE_TEST_ROLLBACK_FAILURE_NOT_EXPLICIT'
    $rollbackRecovery = & $module {
        param($Fixture)
        Invoke-RecoverCodexProfileDeleteTransactions `
            -ProfilesDirectory $Fixture.Profiles `
            -StateDirectory $Fixture.State -MutexName $Fixture.Mutex
    } $rollbackFailure
    Assert-DeleteTest -Condition (
        $rollbackRecovery.RestoredTransactions -eq 1 -and
        @(Get-DeleteTransactionDirectories $rollbackFailure.Profiles).Count -eq 0
    ) -Code 'DELETE_TEST_ROLLBACK_FAILURE_NOT_RECOVERABLE'
    Assert-CompleteProfile -Name 'B' -ProfilesDirectory $rollbackFailure.Profiles

    [pscustomobject]@{
        Result = 'PASS'
        NormalDelete = 'PASS'
        AuthMoveFailureRollback = 'PASS'
        IdentityMoveFailureRollback = 'PASS'
        MetadataMoveFailureRollback = 'PASS'
        CleanupFailureWarning = 'PASS'
        CleanupFailureLeavesFormalProfileDeleted = 'PASS'
        CommittedCleanupRecovered = 'PASS'
        CommitMarkerCrashWindowRecovered = 'PASS'
        InterruptedTransactionStartupRecovery = 'PASS'
        ActiveProfileDeleteRejected = 'PASS'
        RollbackFailureExplicit = 'PASS'
        RollbackFailureStartupRecovery = 'PASS'
        FirstRunWithoutActiveState = 'PASS'
        NamedMutexPathUsed = 'PASS'
        RealAuthOrProfileRead = $false
    }
}
finally {
    if ($null -ne $module) {
        Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
    }
    if ([System.IO.Directory]::Exists($testRoot)) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
    foreach ($buffer in @($aBytes, $bBytes)) {
        if ($null -ne $buffer -and $buffer.Length -gt 0) {
            [Array]::Clear($buffer, 0, $buffer.Length)
        }
    }
}
