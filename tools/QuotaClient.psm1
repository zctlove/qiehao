Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:QuotaProjectRoot = Split-Path -Parent $PSScriptRoot
$script:QuotaParserPath = Join-Path -Path $PSScriptRoot -ChildPath 'QuotaParser.psm1'
$script:QuotaAuthModulePath = Join-Path -Path $script:QuotaProjectRoot `
    -ChildPath 'lib\CodexAuth.psm1'

$script:QuotaParserModule = Import-Module -Name $script:QuotaParserPath `
    -PassThru -ErrorAction Stop
$script:QuotaAuthModule = Import-Module -Name $script:QuotaAuthModulePath `
    -PassThru -ErrorAction Stop
if ($null -eq $script:QuotaParserModule -or
    -not $script:QuotaParserModule.ExportedCommands.ContainsKey(
        'ConvertTo-QiehaoQuotaSnapshot'
    )) {
    throw 'QUOTA_PARSER_EXPORT_CONTRACT_INVALID'
}
if ($null -eq $script:QuotaAuthModule -or
    $script:QuotaAuthModule -isnot
        [System.Management.Automation.PSModuleInfo]) {
    throw 'QUOTA_AUTH_MODULE_REFERENCE_INVALID'
}

function Write-QiehaoQuotaJsonLine {
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

function Read-QiehaoQuotaJsonLine {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.StreamReader]$Reader,

        [Parameter(Mandatory = $true)]
        [DateTime]$DeadlineUtc
    )

    $readTask = $Reader.ReadLineAsync()
    while (-not $readTask.IsCompleted) {
        if ([DateTime]::UtcNow -ge $DeadlineUtc) {
            throw 'QUOTA_RESPONSE_TIMEOUT'
        }
        [Threading.Thread]::Sleep(25)
    }
    if ($readTask.IsFaulted) {
        throw 'QUOTA_STDOUT_READ_FAILED'
    }
    return $readTask.Result
}

function Wait-QiehaoQuotaMatchingResponse {
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
        $line = Read-QiehaoQuotaJsonLine -Reader $Reader -DeadlineUtc $DeadlineUtc
        if ($null -eq $line) {
            throw 'QUOTA_STDOUT_CLOSED'
        }
        $linesReceived++

        try {
            $message = $line | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            throw 'QUOTA_INVALID_JSONL'
        }

        $idProperty = $message.PSObject.Properties['id']
        if ($null -eq $idProperty) {
            $notificationsReceived++
            $methodProperty = $message.PSObject.Properties['method']
            if ($null -ne $methodProperty -and $null -ne $methodProperty.Value) {
                $method = [string]$methodProperty.Value
                if ($method -match '^[A-Za-z0-9_./-]{1,128}$') {
                    $null = $notificationMethods.Add($method)
                }
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
            MatchingErrorReceived = (
                $null -ne $errorProperty -and $null -ne $errorProperty.Value
            )
        }
    }
    throw 'QUOTA_RESPONSE_TIMEOUT'
}

function New-QiehaoQuotaDiagnostics {
    param(
        [AllowNull()]
        [object]$Response
    )

    if ($null -eq $Response) {
        return [pscustomobject]@{
            LinesReceived = 0
            NotificationsReceived = 0
            ResponsesWithOtherId = 0
            NotificationMethods = [object[]]@()
            MatchingResponseReceived = $false
            MatchingErrorReceived = $false
        }
    }
    return [pscustomobject]@{
        LinesReceived = [int]$Response.LinesReceived
        NotificationsReceived = [int]$Response.NotificationsReceived
        ResponsesWithOtherId = [int]$Response.ResponsesWithOtherId
        NotificationMethods = [object[]]@($Response.NotificationMethods)
        MatchingResponseReceived = [bool]$Response.MatchingResponseReceived
        MatchingErrorReceived = [bool]$Response.MatchingErrorReceived
    }
}

function ConvertTo-QiehaoQuotaFailureCode {
    param(
        [AllowNull()]
        [object]$ErrorRecord
    )

    $candidate = if ($null -eq $ErrorRecord) {
        ''
    }
    else {
        [string]$ErrorRecord.Exception.Message
    }
    $allowed = @(
        'QUOTA_RESPONSE_TIMEOUT',
        'QUOTA_STDOUT_READ_FAILED',
        'QUOTA_STDOUT_CLOSED',
        'QUOTA_INVALID_JSONL',
        'QUOTA_INITIALIZE_ERROR',
        'QUOTA_RPC_ERROR',
        'QUOTA_MATCHING_RESULT_MISSING',
        'QUOTA_SANITIZED_WINDOWS_INVALID',
        'QUOTA_APP_SERVER_START_FAILED',
        'QUOTA_CODEX_COMMAND_NOT_FOUND',
        'OPERATION_BUSY'
    )
    if ($allowed -ccontains $candidate) {
        return $candidate
    }
    return 'QUOTA_QUERY_FAILED'
}

function Invoke-QiehaoQuotaTransport {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 60)]
        [int]$TimeoutSeconds
    )

    $process = $null
    $stderrTask = $null
    $quotaResponse = $null
    $snapshot = $null
    $failureCode = $null
    $childCleanup = 'NotStarted'
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        $codexCommand = Get-Command -Name 'codex' -CommandType Application `
            -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $codexCommand) {
            throw 'QUOTA_CODEX_COMMAND_NOT_FOUND'
        }

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
            throw 'QUOTA_APP_SERVER_START_FAILED'
        }
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $deadlineUtc = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)

        $initializeId = 1
        Write-QiehaoQuotaJsonLine -Writer $process.StandardInput `
            -Message ([ordered]@{
                id = $initializeId
                method = 'initialize'
                params = [ordered]@{
                    clientInfo = [ordered]@{
                        name = 'qiehaoqu-quota-client'
                        title = 'Qiehaoqu Quota Client'
                        version = '1.0.0'
                    }
                    capabilities = [ordered]@{
                        experimentalApi = $true
                    }
                }
            })
        $initializeResponse = Wait-QiehaoQuotaMatchingResponse `
            -Reader $process.StandardOutput -RequestId $initializeId `
            -DeadlineUtc $deadlineUtc
        if ($initializeResponse.MatchingErrorReceived) {
            throw 'QUOTA_INITIALIZE_ERROR'
        }

        Write-QiehaoQuotaJsonLine -Writer $process.StandardInput `
            -Message ([ordered]@{
                method = 'initialized'
                params = [ordered]@{}
            })

        $quotaRequestId = 2
        Write-QiehaoQuotaJsonLine -Writer $process.StandardInput `
            -Message ([ordered]@{
                id = $quotaRequestId
                method = 'account/rateLimits/read'
                params = [ordered]@{
                    excludeResetCreditDetails = $true
                }
            })
        $quotaResponse = Wait-QiehaoQuotaMatchingResponse `
            -Reader $process.StandardOutput -RequestId $quotaRequestId `
            -DeadlineUtc $deadlineUtc
        if ($quotaResponse.MatchingErrorReceived) {
            throw 'QUOTA_RPC_ERROR'
        }

        $resultProperty = $quotaResponse.Response.PSObject.Properties['result']
        if ($null -eq $resultProperty -or $null -eq $resultProperty.Value) {
            throw 'QUOTA_MATCHING_RESULT_MISSING'
        }
        $snapshot = ConvertTo-QiehaoQuotaSnapshot -Result $resultProperty.Value
        if ($null -eq $snapshot.Windows -or
            -not ($snapshot.Windows -is [object[]])) {
            throw 'QUOTA_SANITIZED_WINDOWS_INVALID'
        }
    }
    catch {
        $failureCode = ConvertTo-QiehaoQuotaFailureCode -ErrorRecord $_
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
            $remainingCleanupMilliseconds = [Math]::Max(
                0,
                ([long]$TimeoutSeconds * 1000L) - $stopwatch.ElapsedMilliseconds
            )
            if (-not $process.WaitForExit([int]$remainingCleanupMilliseconds)) {
                try {
                    # Only this exact child instance is eligible for fallback cleanup.
                    $process.Kill()
                    $childCleanup = 'ExactChildTerminationRequestedAtDeadline'
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
        $initializeResponse = $null
        if ($null -ne $quotaResponse) {
            $quotaResponse.Response = $null
        }
    }

    if ($childCleanup -cne 'Normal') {
        $failureCode = 'QUOTA_CHILD_CLEANUP_FAILED'
        $snapshot = $null
    }
    $succeeded = [string]::IsNullOrWhiteSpace($failureCode)
    return [pscustomobject]@{
        Succeeded = $succeeded
        FailureCode = if ($succeeded) { $null } else { $failureCode }
        Snapshot = if ($succeeded) { $snapshot } else { $null }
        Diagnostics = New-QiehaoQuotaDiagnostics -Response $quotaResponse
        ElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
        ChildCleanup = $childCleanup
        AccountStabilityLockCleanup = 'Pending'
    }
}

function Get-QiehaoCurrentQuotaSnapshot {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 60)]
        [int]$TimeoutSeconds = 10
    )

    $operation = {
        param($DeadlineSeconds)
        Invoke-QiehaoQuotaTransport -TimeoutSeconds $DeadlineSeconds
    }
    try {
        $result = & $script:QuotaAuthModule {
            param($LockedOperation, $Arguments)
            Invoke-WithCodexWriteLock -Operation $LockedOperation `
                -ArgumentList $Arguments
        } $operation @($TimeoutSeconds)
        $result.AccountStabilityLockCleanup = 'Released'
        return $result
    }
    catch {
        return [pscustomobject]@{
            Succeeded = $false
            FailureCode = ConvertTo-QiehaoQuotaFailureCode -ErrorRecord $_
            Snapshot = $null
            Diagnostics = New-QiehaoQuotaDiagnostics -Response $null
            ElapsedMilliseconds = 0
            ChildCleanup = 'NotStarted'
            AccountStabilityLockCleanup = 'ReleasedOrNotAcquired'
        }
    }
}

Export-ModuleMember -Function @(
    'Get-QiehaoCurrentQuotaSnapshot'
)
