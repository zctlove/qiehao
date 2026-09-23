[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$clientPath = Join-Path $projectRoot 'tools\QuotaClient.psm1'
$fakeServerPath = Join-Path $PSScriptRoot 'FakeQuotaAppServer.ps1'
$hostExecutable = if ($PSVersionTable.PSVersion.Major -ge 6) {
    Join-Path $PSHOME 'pwsh.exe'
}
else {
    Join-Path $PSHOME 'powershell.exe'
}

function Assert-CleanupContract {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Code
    )
    if (-not $Condition) { throw $Code }
}

function Quote-TestArgument {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value.Contains('"')) { throw 'FAKE_SERVER_ARGUMENT_INVALID' }
    return '"' + $Value + '"'
}

function Stop-FakeTestChild {
    param([Parameter(Mandatory = $true)][string]$PidFile)
    if (-not [System.IO.File]::Exists($PidFile)) { return }
    $pidText = [System.IO.File]::ReadAllText($PidFile).Trim()
    $childId = 0
    if (-not [int]::TryParse($pidText, [ref]$childId) -or
        $childId -le 0) {
        return
    }
    $child = Get-Process -Id $childId -ErrorAction SilentlyContinue
    if ($null -ne $child) {
        # Test isolation only. Production QuotaClient is statically asserted
        # below to contain no force-termination API.
        Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue
        try { $child.WaitForExit(3000) | Out-Null }
        catch { }
    }
}

function Invoke-FakeCleanupTransport {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Normal', 'NeverExit', 'PrimaryTimeoutNeverExit')]
        [string]$Scenario,
        [Parameter(Mandatory = $true)][int]$TimeoutSeconds,
        [Parameter(Mandatory = $true)][int]$CleanupGraceMilliseconds,
        [int]$ResponseDelayMilliseconds = 0,
        [int]$ExitDelayMilliseconds = 0,
        [int]$TestDeadlineMilliseconds = 0,
        [Parameter(Mandatory = $true)][string]$PidFile,
        [AllowNull()][hashtable]$OwnedProcessRegistry
    )

    $arguments = @(
        '-NoLogo',
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        (Quote-TestArgument -Value $fakeServerPath),
        '-Scenario',
        (Quote-TestArgument -Value $Scenario),
        '-ResponseDelayMilliseconds',
        [string]$ResponseDelayMilliseconds,
        '-ExitDelayMilliseconds',
        [string]$ExitDelayMilliseconds,
        '-PidFile',
        (Quote-TestArgument -Value $PidFile)
    ) -join ' '

    $module = Import-Module -Name $clientPath -Force -PassThru `
        -ErrorAction Stop
    return & $module {
        param(
            $TimeoutSeconds,
            $CleanupGraceMilliseconds,
            $TestExecutablePath,
            $TestProcessArguments,
            $TestDeadlineMilliseconds,
            $OwnedProcessRegistry
        )
        Invoke-QiehaoQuotaTransport `
            -TimeoutSeconds $TimeoutSeconds `
            -CleanupGraceMilliseconds $CleanupGraceMilliseconds `
            -TestExecutablePath $TestExecutablePath `
            -TestProcessArguments $TestProcessArguments `
            -TestDeadlineMilliseconds $TestDeadlineMilliseconds `
            -OwnedProcessRegistry $OwnedProcessRegistry
    } $TimeoutSeconds $CleanupGraceMilliseconds $hostExecutable $arguments `
        $TestDeadlineMilliseconds $OwnedProcessRegistry
}

$tempBase = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::GetTempPath()
).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
$testDirectory = [System.IO.Path]::GetFullPath(
    (Join-Path $tempBase (
        'qiehao-child-cleanup-' + [Guid]::NewGuid().ToString('N')
    ))
)
if (-not $testDirectory.StartsWith(
    $tempBase + [System.IO.Path]::DirectorySeparatorChar,
    [StringComparison]::OrdinalIgnoreCase
)) {
    throw 'CHILD_CLEANUP_TEST_PATH_INVALID'
}
[System.IO.Directory]::CreateDirectory($testDirectory) | Out-Null

$neverPidFile = Join-Path $testDirectory 'never.pid'
$doublePidFile = Join-Path $testDirectory 'double.pid'
$boundaryPidFiles = @()
try {
    $ownedProcessRegistry = [hashtable]::Synchronized(@{
        IsActive = $false; ProcessId = 0; ProcessStartTimeUtc = $null
        ExecutablePath = ''; Arguments = ''; ParentProcessId = 0
    })
    $normal = Invoke-FakeCleanupTransport -Scenario Normal `
        -TimeoutSeconds 3 -CleanupGraceMilliseconds 1500 `
        -PidFile (Join-Path $testDirectory 'normal.pid') `
        -OwnedProcessRegistry $ownedProcessRegistry
    Assert-CleanupContract (
        [bool]$normal.Succeeded -and
        [bool]$normal.PrimarySucceeded -and
        [bool]$normal.CleanupSucceeded -and
        $null -eq $normal.PrimaryFailureCode -and
        $null -eq $normal.CleanupFailureCode -and
        [bool]$normal.Diagnostics.MatchingResponseReceived -and
        [bool]$normal.Diagnostics.SnapshotParsed -and
        [bool]$normal.Diagnostics.StdinCloseAttempted -and
        [bool]$normal.Diagnostics.StdinCloseSucceeded -and
        [bool]$normal.Diagnostics.ChildExitedNaturally -and
        [bool]$normal.Diagnostics.ChildHasExited -and
        -not [bool]$ownedProcessRegistry.IsActive -and
        [int]$ownedProcessRegistry.ProcessId -gt 0 -and
        $ownedProcessRegistry.ProcessStartTimeUtc -is [DateTime] -and
        [System.IO.Path]::GetFullPath(
            [string]$ownedProcessRegistry.ExecutablePath
        ).Equals(
            [System.IO.Path]::GetFullPath($hostExecutable),
            [StringComparison]::OrdinalIgnoreCase
        ) -and
        [string]$ownedProcessRegistry.Arguments -match
            'FakeQuotaAppServer\.ps1' -and
        [int]$ownedProcessRegistry.ParentProcessId -eq [int]$PID
    ) 'FAKE_NORMAL_CHILD_CLEANUP_FAILED'

    $slow = Invoke-FakeCleanupTransport -Scenario Normal `
        -TimeoutSeconds 3 -CleanupGraceMilliseconds 1500 `
        -ExitDelayMilliseconds 500 `
        -PidFile (Join-Path $testDirectory 'slow.pid')
    Assert-CleanupContract (
        [bool]$slow.Succeeded -and
        [bool]$slow.PrimarySucceeded -and
        [bool]$slow.CleanupSucceeded -and
        [bool]$slow.Diagnostics.ChildExitedNaturally -and
        [long]$slow.CleanupElapsedMilliseconds -ge 350
    ) 'FAKE_SLOW_CHILD_CLEANUP_FAILED'

    # The RPC response arrives near its own deadline, then the child needs a
    # separate normal-exit grace. The old shared budget fails this shape.
    $nearDeadline = Invoke-FakeCleanupTransport -Scenario Normal `
        -TimeoutSeconds 5 -CleanupGraceMilliseconds 2500 `
        -ResponseDelayMilliseconds 3400 -ExitDelayMilliseconds 1800 `
        -PidFile (Join-Path $testDirectory 'near-deadline.pid')
    Assert-CleanupContract (
        [bool]$nearDeadline.Succeeded -and
        [bool]$nearDeadline.PrimarySucceeded -and
        [bool]$nearDeadline.CleanupSucceeded -and
        [long]$nearDeadline.ElapsedMilliseconds -ge 3200 -and
        [long]$nearDeadline.CleanupElapsedMilliseconds -ge 1500
    ) 'RPC_AND_CLEANUP_BUDGETS_NOT_SEPARATE'

    # Boundary semantics are scaled 5:1 to keep the offline matrix fast:
    # 200 ms of fake wait represents one production second. The production
    # public default remains 30 seconds; only the private fake transport seam
    # receives the 6000 ms deadline used below.
    $boundaryResults = @{}
    foreach ($boundary in @(
        [pscustomobject]@{ Name = 'At2'; Delay = 400 },
        [pscustomobject]@{ Name = 'At9'; Delay = 1800 },
        [pscustomobject]@{ Name = 'At12'; Delay = 2400 },
        [pscustomobject]@{ Name = 'At25'; Delay = 5000 }
    )) {
        $pidFile = Join-Path $testDirectory (
            'boundary-' + $boundary.Name + '.pid'
        )
        $boundaryPidFiles += $pidFile
        $boundaryResults[$boundary.Name] = Invoke-FakeCleanupTransport `
            -Scenario Normal -TimeoutSeconds 30 `
            -CleanupGraceMilliseconds 2000 `
            -ResponseDelayMilliseconds $boundary.Delay `
            -TestDeadlineMilliseconds 6000 -PidFile $pidFile
    }
    Assert-CleanupContract (
        [bool]$boundaryResults.At2.Succeeded -and
        [bool]$boundaryResults.At9.Succeeded -and
        [bool]$boundaryResults.At12.Succeeded -and
        [bool]$boundaryResults.At25.Succeeded -and
        [long]$boundaryResults.At12.Diagnostics.
            RateLimitsWaitElapsedMilliseconds -ge 2100 -and
        [long]$boundaryResults.At25.Diagnostics.
            RateLimitsWaitElapsedMilliseconds -ge 4600
    ) 'QUOTA_30_SECOND_BOUNDARY_PASS_CASE_FAILED'

    $beyondPidFile = Join-Path $testDirectory 'boundary-beyond-30.pid'
    $boundaryPidFiles += $beyondPidFile
    $beyond = Invoke-FakeCleanupTransport -Scenario Normal `
        -TimeoutSeconds 30 -CleanupGraceMilliseconds 2000 `
        -ResponseDelayMilliseconds 6500 `
        -TestDeadlineMilliseconds 6000 -PidFile $beyondPidFile
    Assert-CleanupContract (
        -not [bool]$beyond.Succeeded -and
        -not [bool]$beyond.PrimarySucceeded -and
        [string]$beyond.PrimaryFailureCode -ceq
            'QUOTA_RATE_LIMITS_TIMEOUT' -and
        [string]$beyond.FailureCode -ceq 'QUOTA_RATE_LIMITS_TIMEOUT' -and
        [long]$beyond.Diagnostics.RateLimitsWaitElapsedMilliseconds -ge 5000
    ) 'QUOTA_BEYOND_30_SECOND_BOUNDARY_DID_NOT_TIMEOUT'

    $neverStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $never = Invoke-FakeCleanupTransport -Scenario NeverExit `
        -TimeoutSeconds 3 -CleanupGraceMilliseconds 250 `
        -PidFile $neverPidFile
    $neverStopwatch.Stop()
    Assert-CleanupContract (
        -not [bool]$never.Succeeded -and
        [bool]$never.PrimarySucceeded -and
        $null -eq $never.PrimaryFailureCode -and
        -not [bool]$never.CleanupSucceeded -and
        [string]$never.CleanupFailureCode -ceq
            'QUOTA_CHILD_CLEANUP_FAILED' -and
        [string]$never.FailureCode -ceq
            'QUOTA_CHILD_CLEANUP_FAILED' -and
        [bool]$never.Diagnostics.SnapshotParsed -and
        [bool]$never.Diagnostics.StdinCloseSucceeded -and
        -not [bool]$never.Diagnostics.ChildHasExited -and
        $neverStopwatch.ElapsedMilliseconds -lt 2500
    ) 'FAKE_NEVER_EXIT_CHILD_NOT_BOUNDED'

    $double = Invoke-FakeCleanupTransport `
        -Scenario PrimaryTimeoutNeverExit `
        -TimeoutSeconds 1 -CleanupGraceMilliseconds 250 `
        -PidFile $doublePidFile
    Assert-CleanupContract (
        -not [bool]$double.Succeeded -and
        -not [bool]$double.PrimarySucceeded -and
        [string]$double.PrimaryFailureCode -ceq
            'QUOTA_RATE_LIMITS_TIMEOUT' -and
        -not [bool]$double.CleanupSucceeded -and
        [string]$double.CleanupFailureCode -ceq
            'QUOTA_CHILD_CLEANUP_FAILED' -and
        [string]$double.FailureCode -ceq
            'QUOTA_RATE_LIMITS_TIMEOUT' -and
        [string]$double.Diagnostics.PrimaryFailureCode -ceq
            'QUOTA_RATE_LIMITS_TIMEOUT' -and
        [string]$double.Diagnostics.CleanupFailureCode -ceq
            'QUOTA_CHILD_CLEANUP_FAILED'
    ) 'PRIMARY_AND_CLEANUP_FAILURES_NOT_PRESERVED'

    $clientSource = [System.IO.File]::ReadAllText($clientPath)
    Assert-CleanupContract (
        $clientSource -notmatch
            '(?i)Stop-Process\b|taskkill\b|TerminateProcess\b|\.Kill\s*\('
    ) 'PRODUCTION_CHILD_FORCE_TERMINATION_PRESENT'

    Write-Output 'FakeNormalMatchingResponse=True'
    Write-Output 'FakeNormalSnapshotParsed=True'
    Write-Output 'FakeNormalStdinCloseSucceeded=True'
    Write-Output 'FakeNormalChildExitedNaturally=True'
    Write-Output 'QuotaChildOwnershipMetadataCaptured=True'
    Write-Output 'QuotaChildOwnershipInactiveAfterCleanup=True'
    Write-Output 'FakeSlowExitUsesSeparateCleanupBudget=True'
    Write-Output 'FakeNearDeadlineUsesSeparateCleanupBudget=True'
    Write-Output 'ResponseAt2SecondsPasses=True'
    Write-Output 'ResponseAt9SecondsPasses=True'
    Write-Output 'ResponseAt12SecondsPasses=True'
    Write-Output 'ResponseAt25SecondsPasses=True'
    Write-Output 'ResponseBeyond30SecondsFailsWithQuotaRateLimitsTimeout=True'
    Write-Output 'RateLimitsWaitElapsedMillisecondsPreserved=True'
    Write-Output 'FakeNeverExitCleanupBounded=True'
    Write-Output 'FakeNeverExitCleanupFailurePreserved=True'
    Write-Output 'PrimaryAndCleanupFailuresSeparated=True'
    Write-Output 'PrimaryFailureNotOverwritten=True'
    Write-Output 'ProductionChildForceTerminationPresent=False'
    Write-Output 'QUOTA_CHILD_CLEANUP_SELFTEST_PASS'
}
finally {
    Stop-FakeTestChild -PidFile $neverPidFile
    Stop-FakeTestChild -PidFile $doublePidFile
    foreach ($pidFile in $boundaryPidFiles) {
        Stop-FakeTestChild -PidFile $pidFile
    }
    if ([System.IO.Directory]::Exists($testDirectory)) {
        [System.IO.Directory]::Delete($testDirectory, $true)
    }
}
