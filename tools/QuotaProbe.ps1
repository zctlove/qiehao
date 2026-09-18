[CmdletBinding()]
param(
    [switch]$RunRealQuery,

    [switch]$ValidateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$parserPath = Join-Path -Path $PSScriptRoot -ChildPath 'QuotaParser.psm1'
$authModulePath = Join-Path -Path $projectRoot -ChildPath 'lib\CodexAuth.psm1'
Import-Module -Name $parserPath -Force -ErrorAction Stop
$authModule = Import-Module -Name $authModulePath -Force -PassThru -ErrorAction Stop

if ($ValidateOnly) {
    $lockValidation = & $authModule {
        Invoke-WithCodexWriteLock -Operation {
            'ACCOUNT_STABILITY_LOCK_VALIDATE_OK'
        }
    }
    if ($lockValidation -ne 'ACCOUNT_STABILITY_LOCK_VALIDATE_OK') {
        throw 'ACCOUNT_STABILITY_LOCK_VALIDATE_FAILED'
    }
    Write-Output 'QUOTA_PROBE_VALIDATE_OK'
    return
}

if (-not $RunRealQuery) {
    throw 'REAL_QUERY_REQUIRES_EXPLICIT_RUNREALQUERY'
}

function Write-QiehaoJsonLine {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.StreamWriter]$Writer,

        [Parameter(Mandatory = $true)]
        [object]$Message
    )

    $line = $Message | ConvertTo-Json -Depth 12 -Compress
    $Writer.WriteLine($line)
    $Writer.Flush()
}

function Read-QiehaoJsonLineBeforeDeadline {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.StreamReader]$Reader,

        [Parameter(Mandatory = $true)]
        [DateTime]$DeadlineUtc
    )

    $readTask = $Reader.ReadLineAsync()
    while (-not $readTask.IsCompleted) {
        if ([DateTime]::UtcNow -ge $DeadlineUtc) {
            throw 'APP_SERVER_RESPONSE_TIMEOUT'
        }
        [Threading.Thread]::Sleep(25)
    }

    if ($readTask.IsFaulted) {
        throw 'APP_SERVER_STDOUT_READ_FAILED'
    }
    return $readTask.Result
}

function Wait-QiehaoMatchingResponse {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.StreamReader]$Reader,

        [Parameter(Mandatory = $true)]
        [int]$RequestId,

        [Parameter(Mandatory = $true)]
        [DateTime]$DeadlineUtc
    )

    $linesReceived = 0
    $notificationsReceived = 0
    $responsesWithOtherId = 0
    $notificationMethods = New-Object 'System.Collections.Generic.List[string]'

    while ([DateTime]::UtcNow -lt $DeadlineUtc) {
        $line = Read-QiehaoJsonLineBeforeDeadline -Reader $Reader -DeadlineUtc $DeadlineUtc
        if ($null -eq $line) {
            throw 'APP_SERVER_STDOUT_CLOSED'
        }
        $linesReceived++

        try {
            $message = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw 'APP_SERVER_INVALID_JSONL'
        }

        $idProperty = $message.PSObject.Properties['id']
        if ($null -eq $idProperty) {
            $notificationsReceived++
            $methodProperty = $message.PSObject.Properties['method']
            if ($null -ne $methodProperty -and $null -ne $methodProperty.Value) {
                $null = $notificationMethods.Add([string]$methodProperty.Value)
            }
            continue
        }

        if ([string]$idProperty.Value -ne [string]$RequestId) {
            $responsesWithOtherId++
            continue
        }

        $errorProperty = $message.PSObject.Properties['error']
        return [pscustomobject]@{
            Response = $message
            LinesReceived = $linesReceived
            NotificationsReceived = $notificationsReceived
            ResponsesWithOtherId = $responsesWithOtherId
            NotificationMethods = $notificationMethods.ToArray()
            MatchingResponseReceived = $true
            MatchingErrorReceived = ($null -ne $errorProperty -and
                $null -ne $errorProperty.Value)
        }
    }

    throw 'APP_SERVER_RESPONSE_TIMEOUT'
}

function Invoke-QiehaoQuotaRpc {
    $codexCommand = Get-Command -Name 'codex' -CommandType Application `
        -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $codexCommand) {
        throw 'CODEX_COMMAND_NOT_FOUND'
    }

    $process = $null
    $stderrTask = $null
    $childCleanup = 'NotStarted'
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = $codexCommand.Source
        $startInfo.Arguments = 'app-server --stdio'
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        if (-not $process.Start()) {
            throw 'APP_SERVER_START_FAILED'
        }
        $stderrTask = $process.StandardError.ReadToEndAsync()

        $initializeId = 1
        Write-QiehaoJsonLine -Writer $process.StandardInput -Message ([ordered]@{
            id = $initializeId
            method = 'initialize'
            params = [ordered]@{
                clientInfo = [ordered]@{
                    name = 'qiehaoqu-quota-probe'
                    title = 'Qiehaoqu Quota Probe'
                    version = '1.0.0'
                }
                capabilities = [ordered]@{
                    experimentalApi = $true
                }
            }
        })

        $initializeDeadline = [DateTime]::UtcNow.AddSeconds(20)
        $initializeResponse = Wait-QiehaoMatchingResponse `
            -Reader $process.StandardOutput -RequestId $initializeId `
            -DeadlineUtc $initializeDeadline
        if ($initializeResponse.MatchingErrorReceived) {
            throw 'APP_SERVER_INITIALIZE_ERROR'
        }

        Write-QiehaoJsonLine -Writer $process.StandardInput -Message ([ordered]@{
            method = 'initialized'
            params = [ordered]@{}
        })

        $quotaRequestId = 2
        Write-QiehaoJsonLine -Writer $process.StandardInput -Message ([ordered]@{
            id = $quotaRequestId
            method = 'account/rateLimits/read'
            params = [ordered]@{
                excludeResetCreditDetails = $true
            }
        })

        $quotaDeadline = [DateTime]::UtcNow.AddSeconds(60)
        $quotaResponse = Wait-QiehaoMatchingResponse `
            -Reader $process.StandardOutput -RequestId $quotaRequestId `
            -DeadlineUtc $quotaDeadline
        $stopwatch.Stop()

        if ($quotaResponse.MatchingErrorReceived) {
            return [pscustomobject]@{
                Succeeded = $false
                FailureStage = 'RATE_LIMITS_RPC_ERROR'
                Diagnostics = $quotaResponse
                Snapshot = $null
                ElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
                ChildCleanup = $childCleanup
            }
        }

        $resultProperty = $quotaResponse.Response.PSObject.Properties['result']
        if ($null -eq $resultProperty -or $null -eq $resultProperty.Value) {
            throw 'APP_SERVER_MATCHING_RESULT_MISSING'
        }

        $snapshot = ConvertTo-QiehaoQuotaSnapshot -Result $resultProperty.Value
        if ($null -eq $snapshot.Windows -or -not ($snapshot.Windows -is [object[]])) {
            throw 'SANITIZED_WINDOWS_ARRAY_INVALID'
        }

        return [pscustomobject]@{
            Succeeded = $true
            FailureStage = $null
            Diagnostics = $quotaResponse
            Snapshot = $snapshot
            ElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
            ChildCleanup = $childCleanup
        }
    }
    finally {
        if ($stopwatch.IsRunning) {
            $stopwatch.Stop()
        }
        if ($null -ne $process) {
            try {
                $process.StandardInput.Close()
            }
            catch {
            }

            if (-not $process.WaitForExit(10000)) {
                try {
                    # Only the exact child Process instance created above is touched.
                    $process.Kill()
                    $null = $process.WaitForExit(5000)
                    $childCleanup = 'ExactChildTerminatedAfterTimeout'
                }
                catch {
                    $childCleanup = 'ExactChildCleanupFailed'
                }
            }
            else {
                $childCleanup = 'Normal'
            }

            if ($null -ne $stderrTask) {
                try {
                    $null = $stderrTask.GetAwaiter().GetResult()
                }
                catch {
                }
            }
            $process.Dispose()
        }
        $script:LastChildCleanup = $childCleanup
    }
}

$script:LastChildCleanup = 'NotStarted'
$operation = {
    Invoke-QiehaoQuotaRpc
}

try {
    $probeResult = & $authModule {
        param($LockedOperation)
        Invoke-WithCodexWriteLock -Operation $LockedOperation
    } $operation

    if (-not $probeResult.Succeeded) {
        throw $probeResult.FailureStage
    }

    # Cleanup is finalized in Invoke-QiehaoQuotaRpc's finally block, after its
    # return object is constructed.
    $probeResult.ChildCleanup = $script:LastChildCleanup
    Write-Output 'CODEX_USAGE_POC_OK'
    Write-Output ('Plan: ' + [string]$probeResult.Snapshot.Plan)
    Write-Output ('OrdinaryUsageAllowed: ' +
        [string]$probeResult.Snapshot.OrdinaryUsageAllowed)
    Write-Output 'Windows:'
    foreach ($window in $probeResult.Snapshot.Windows) {
        Write-Output ('- Label: ' + [string]$window.Label)
        Write-Output ('  DurationMinutes: ' + [string]$window.DurationMinutes)
        Write-Output ('  RemainingPercent: ' + [string]$window.RemainingPercent)
        Write-Output ('  ResetLocal: ' + [string]$window.ResetLocal)
    }
    Write-Output ('LinesReceived: ' + [string]$probeResult.Diagnostics.LinesReceived)
    Write-Output ('NotificationsReceived: ' +
        [string]$probeResult.Diagnostics.NotificationsReceived)
    Write-Output ('ResponsesWithOtherId: ' +
        [string]$probeResult.Diagnostics.ResponsesWithOtherId)
    Write-Output ('MatchingResponseReceived: ' +
        [string]$probeResult.Diagnostics.MatchingResponseReceived)
    Write-Output ('MatchingErrorReceived: ' +
        [string]$probeResult.Diagnostics.MatchingErrorReceived)
    Write-Output ('ElapsedMilliseconds: ' + [string]$probeResult.ElapsedMilliseconds)
    Write-Output ('ChildCleanup: ' + [string]$probeResult.ChildCleanup)
    Write-Output 'AccountStabilityLockCleanup: Released'
    Write-Output 'END_TO_END_QUOTA_POC_PASS'
}
catch {
    Write-Output 'END_TO_END_QUOTA_POC_FAIL'
    Write-Output ('FailureStage: ' + [string]$_.Exception.Message)
    Write-Output ('ChildCleanup: ' + [string]$script:LastChildCleanup)
    Write-Output 'AccountStabilityLockCleanup: Released'
    exit 1
}
