[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$clientModulePath = Join-Path $projectRoot 'tools\QuotaClient.psm1'
$originalProcessPath = [Environment]::GetEnvironmentVariable(
    'Path',
    [EnvironmentVariableTarget]::Process
)
$desktopPathParts = @(
    [Environment]::GetEnvironmentVariable(
        'Path',
        [EnvironmentVariableTarget]::Machine
    ),
    [Environment]::GetEnvironmentVariable(
        'Path',
        [EnvironmentVariableTarget]::User
    )
) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

function Assert-WorkerContract {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Code
    )
    if (-not $Condition) { throw $Code }
}

function Invoke-FakeBackgroundWorker {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Success', 'Failure', 'Polluted')]
        [string]$Scenario
    )

    $worker = [PowerShell]::Create()
    try {
        $scriptText = {
            param($ClientModulePath, $Scenario)
            $ErrorActionPreference = 'Stop'
            $module = @(Import-Module -Name $ClientModulePath -PassThru `
                -ErrorAction Stop | Select-Object -Last 1)[0]
            if ($null -eq $module -or
                -not $module.ExportedCommands.ContainsKey(
                    'Invoke-QiehaoQuotaBackgroundWorker'
                )) {
                throw 'WORKER_IMPORT_CONTRACT_FAILED'
            }
            $provider = {
                param($IgnoredTimeoutSeconds, $ProviderScenario)
                switch ([string]$ProviderScenario) {
                    'Success' {
                        Write-Warning 'SAFE_FAKE_WARNING'
                        Write-Error 'SAFE_FAKE_NONTERMINATING_ERROR' `
                            -ErrorAction Continue
                        [pscustomobject]@{
                            Succeeded = $true
                            FailureCode = $null
                            Snapshot = [pscustomobject]@{
                                Plan = 'team'
                                OrdinaryUsageAllowed = $true
                                Windows = @(
                                    [pscustomobject]@{
                                        DurationMinutes = 300
                                        Label = '5-hour'
                                        RemainingPercent = 42
                                        ResetsAt = 1893542400
                                        ResetLocal = '2030-01-01 00:00:00 +00:00'
                                    }
                                )
                            }
                            Diagnostics = [pscustomobject]@{
                                AccountStabilityLockAcquired = $true
                                AppServerStarted = $true
                                InitializeMatched = $true
                                RateLimitsResponseMatched = $true
                            }
                            ElapsedMilliseconds = 12
                            ChildCleanup = 'Normal'
                            AccountStabilityLockCleanup = 'Released'
                        }
                    }
                    'Failure' {
                        [pscustomobject]@{
                            Succeeded = $false
                            FailureCode = 'OPERATION_BUSY'
                            Snapshot = $null
                            Diagnostics = [pscustomobject]@{
                                AccountStabilityLockAcquired = $false
                                AppServerStarted = $false
                                InitializeMatched = $false
                                RateLimitsResponseMatched = $false
                            }
                            ElapsedMilliseconds = 0
                            ChildCleanup = 'NotStarted'
                            AccountStabilityLockCleanup =
                                'ReleasedOrNotAcquired'
                        }
                    }
                    'Polluted' {
                        'UNEXPECTED_SUCCESS_PIPELINE_OUTPUT'
                        [pscustomobject]@{
                            Succeeded = $true
                            FailureCode = $null
                            Snapshot = [pscustomobject]@{
                                Plan = 'team'
                                OrdinaryUsageAllowed = $true
                                Windows = @()
                            }
                        }
                    }
                }
            }
            Invoke-QiehaoQuotaBackgroundWorker -TimeoutSeconds 10 `
                -QuotaProvider $provider `
                -QuotaProviderArgument $Scenario
        }
        $null = $worker.AddScript($scriptText.ToString()).
            AddArgument($clientModulePath).
            AddArgument($Scenario)
        $async = $worker.BeginInvoke()
        if (-not $async.AsyncWaitHandle.WaitOne(5000)) {
            try { $worker.Stop() } catch { }
            throw 'BACKGROUND_WORKER_SELFTEST_TIMEOUT'
        }
        $output = @($worker.EndInvoke($async))
        return [pscustomobject]@{
            Output = $output
            OutputCount = $output.Count
            ErrorCount = $worker.Streams.Error.Count
            WarningCount = $worker.Streams.Warning.Count
        }
    }
    finally {
        $worker.Dispose()
    }
}

try {
    # Explorer-launched GUI processes receive persistent machine/user PATH,
    # not the temporary versioned Codex bin injected into this task process.
    [Environment]::SetEnvironmentVariable(
        'Path',
        ($desktopPathParts -join ';'),
        [EnvironmentVariableTarget]::Process
    )

$success = Invoke-FakeBackgroundWorker -Scenario Success
Assert-WorkerContract ($success.OutputCount -eq 1) `
    'BACKGROUND_WORKER_SUCCESS_OUTPUT_COUNT_INVALID'
$successResult = $success.Output[0]
Assert-WorkerContract ([bool]$successResult.Succeeded) `
    'BACKGROUND_WORKER_SUCCESS_RESULT_INVALID'
Assert-WorkerContract (
    $success.ErrorCount -gt 0 -and $success.WarningCount -gt 0
) 'BACKGROUND_WORKER_STREAM_TEST_NOT_EXERCISED'
Assert-WorkerContract (
    [bool]$successResult.Diagnostics.ModulesLoaded -and
    [bool]$successResult.Diagnostics.QuotaClientCommandAvailable -and
    [bool]$successResult.Diagnostics.QuotaParserCommandAvailable -and
    [bool]$successResult.Diagnostics.CodexAuthReferenceValid
) 'BACKGROUND_WORKER_MODULE_CONTRACT_INVALID'
Assert-WorkerContract (
    [bool]$successResult.Diagnostics.ExecutableDiscoverySucceeded -and
    [string]$successResult.Diagnostics.ExecutableSource -ceq
        'BundledCodex'
) 'BACKGROUND_WORKER_EXECUTABLE_DISCOVERY_INVALID'
Assert-WorkerContract (
    [bool]$successResult.Diagnostics.AccountStabilityLockAcquired -and
    [bool]$successResult.Diagnostics.AppServerStarted -and
    [bool]$successResult.Diagnostics.InitializeMatched -and
    [bool]$successResult.Diagnostics.RateLimitsResponseMatched
) 'BACKGROUND_WORKER_DIAGNOSTICS_MARSHAL_INVALID'
Assert-WorkerContract (
    $successResult.Snapshot -is [pscustomobject] -and
    @($successResult.Snapshot.Windows).Count -eq 1 -and
    $successResult.Snapshot.Windows[0] -is [pscustomobject]
) 'BACKGROUND_WORKER_SNAPSHOT_MARSHAL_INVALID'

$failure = Invoke-FakeBackgroundWorker -Scenario Failure
Assert-WorkerContract (
    $failure.OutputCount -eq 1 -and
    -not [bool]$failure.Output[0].Succeeded -and
    [string]$failure.Output[0].FailureCode -ceq 'OPERATION_BUSY' -and
    -not [bool]$failure.Output[0].Diagnostics.AccountStabilityLockAcquired
) 'BACKGROUND_WORKER_FAILURE_CODE_MARSHAL_INVALID'

$polluted = Invoke-FakeBackgroundWorker -Scenario Polluted
Assert-WorkerContract (
    $polluted.OutputCount -eq 1 -and
    -not [bool]$polluted.Output[0].Succeeded -and
    [string]$polluted.Output[0].FailureCode -ceq 'QUOTA_RESULT_MISSING' -and
    [int]$polluted.Output[0].Diagnostics.ProviderOutputCount -eq 2
) 'BACKGROUND_WORKER_PIPELINE_POLLUTION_NOT_REJECTED'

Write-Output 'BackgroundWorkerImportsQuotaClient=True'
Write-Output 'BackgroundWorkerImportsQuotaParser=True'
Write-Output 'BackgroundWorkerHasQuotaPublicCommand=True'
Write-Output 'BackgroundWorkerReturnsStructuredResult=True'
Write-Output 'BackgroundWorkerFailureCodeSurvivesEndInvoke=True'
Write-Output 'BackgroundWorkerDoesNotRequireCallerScopeModules=True'
Write-Output 'BackgroundWorkerOutputCount=1'
Write-Output 'BackgroundWorkerRejectsPipelinePollution=True'
Write-Output 'BackgroundWorkerStreamsDoNotOverrideSuccess=True'
Write-Output 'BackgroundWorkerSnapshotSurvivesEndInvoke=True'
Write-Output 'BackgroundWorkerDiagnosticsSurviveEndInvoke=True'
Write-Output 'BackgroundWorkerBundledDiscoveryWithoutPath=True'
Write-Output 'QUOTA_BACKGROUND_WORKER_SELFTEST_PASS'
}
finally {
    [Environment]::SetEnvironmentVariable(
        'Path',
        $originalProcessPath,
        [EnvironmentVariableTarget]::Process
    )
}
