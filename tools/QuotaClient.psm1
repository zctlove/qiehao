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

function Get-QiehaoQuotaPropertyValue {
    param(
        [AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowNull()][object]$DefaultValue = $null
    )

    if ($null -eq $InputObject) { return $DefaultValue }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) { return $DefaultValue }
    return $property.Value
}

function Resolve-QiehaoCodexExecutable {
    param(
        [AllowNull()][string]$ExplicitKnownPath
    )

    function New-ResolutionResult {
        param(
            [Parameter(Mandatory = $true)][bool]$Succeeded,
            [Parameter(Mandatory = $true)][string]$Source,
            [AllowNull()][string]$Path
        )
        $fileName = ''
        $version = ''
        if ($Succeeded -and -not [string]::IsNullOrWhiteSpace($Path)) {
            try {
                $item = Get-Item -LiteralPath $Path -ErrorAction Stop
                $fileName = [string]$item.Name
                $version = [string]$item.VersionInfo.FileVersion
            }
            catch {
                return [pscustomobject]@{
                    Succeeded = $false
                    Source = 'NotFound'
                    Path = $null
                    FileName = ''
                    Version = ''
                }
            }
        }
        return [pscustomobject]@{
            Succeeded = $Succeeded
            Source = $Source
            Path = $Path
            FileName = $fileName
            Version = $version
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ExplicitKnownPath)) {
        try {
            $explicitFullPath = [System.IO.Path]::GetFullPath(
                $ExplicitKnownPath
            )
            if ([System.IO.Path]::GetFileName($explicitFullPath) -ieq
                    'codex.exe' -and
                [System.IO.File]::Exists($explicitFullPath)) {
                return New-ResolutionResult -Succeeded $true `
                    -Source 'ExplicitKnownPath' -Path $explicitFullPath
            }
        }
        catch { }
    }

    # Codex Desktop keeps its official CLI in one versioned directory below
    # this fixed per-user root. Enumerate only direct children, reject reparse
    # points, and never search the rest of the user profile.
    $localAppData = [Environment]::GetEnvironmentVariable(
        'LOCALAPPDATA',
        [EnvironmentVariableTarget]::Process
    )
    if (-not [string]::IsNullOrWhiteSpace($localAppData)) {
        try {
            $bundledRoot = [System.IO.Path]::GetFullPath(
                (Join-Path $localAppData 'OpenAI\Codex\bin')
            ).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
            if ([System.IO.Directory]::Exists($bundledRoot)) {
                $candidates = @(
                    Get-ChildItem -LiteralPath $bundledRoot -Directory `
                        -ErrorAction Stop | Where-Object {
                            -not ($_.Attributes -band
                                [System.IO.FileAttributes]::ReparsePoint)
                        } | ForEach-Object {
                            $candidate = [System.IO.Path]::GetFullPath(
                                (Join-Path $_.FullName 'codex.exe')
                            )
                            $expectedPrefix = $bundledRoot +
                                [System.IO.Path]::DirectorySeparatorChar
                            if ($candidate.StartsWith(
                                    $expectedPrefix,
                                    [StringComparison]::OrdinalIgnoreCase
                                ) -and
                                [System.IO.Path]::GetFileName($candidate) -ieq
                                    'codex.exe' -and
                                [System.IO.File]::Exists($candidate)) {
                                $item = Get-Item -LiteralPath $candidate `
                                    -ErrorAction Stop
                                if (-not ($item.Attributes -band
                                    [System.IO.FileAttributes]::ReparsePoint)) {
                                    $item
                                }
                            }
                        } | Sort-Object LastWriteTimeUtc, FullName `
                            -Descending
                )
                if ($candidates.Count -gt 0) {
                    return New-ResolutionResult -Succeeded $true `
                        -Source 'BundledCodex' `
                        -Path ([string]$candidates[0].FullName)
                }
            }
        }
        catch { }
    }

    try {
        $codexCommand = Get-Command -Name 'codex' -CommandType Application `
            -ErrorAction Stop | Select-Object -First 1
        if ($null -ne $codexCommand -and
            -not [string]::IsNullOrWhiteSpace([string]$codexCommand.Source)) {
            $pathFull = [System.IO.Path]::GetFullPath(
                [string]$codexCommand.Source
            )
            if ([System.IO.Path]::GetFileName($pathFull) -ieq 'codex.exe' -and
                [System.IO.File]::Exists($pathFull)) {
                return New-ResolutionResult -Succeeded $true `
                    -Source 'PathCommand' -Path $pathFull
            }
        }
    }
    catch { }

    return New-ResolutionResult -Succeeded $false -Source 'NotFound' `
        -Path $null
}

function New-QiehaoQuotaDiagnostics {
    param(
        [AllowNull()][object]$Response,
        [bool]$ExecutableDiscoverySucceeded = $false,
        [ValidateSet(
            'BundledCodex', 'PathCommand', 'ExplicitKnownPath', 'NotFound'
        )]
        [string]$ExecutableSource = 'NotFound',
        [string]$ExecutableFileName = '',
        [string]$ExecutableVersion = '',
        [bool]$AccountStabilityLockAcquired = $false,
        [bool]$AppServerStarted = $false,
        [bool]$InitializeMatched = $false,
        [bool]$RateLimitsResponseMatched = $false,
        [bool]$SnapshotParsed = $false,
        [bool]$StdinCloseAttempted = $false,
        [bool]$StdinCloseSucceeded = $false,
        [bool]$ChildExitedNaturally = $false,
        [bool]$ChildHasExited = $false,
        [long]$CleanupElapsedMilliseconds = 0,
        [bool]$PrimarySucceeded = $false,
        [AllowNull()][string]$PrimaryFailureCode,
        [bool]$CleanupSucceeded = $true,
        [AllowNull()][string]$CleanupFailureCode
    )

    $linesReceived = 0
    $notificationsReceived = 0
    $responsesWithOtherId = 0
    $notificationMethods = [object[]]@()
    $matchingResponseReceived = $false
    $matchingErrorReceived = $false
    if ($null -ne $Response) {
        $linesReceived = [int]$Response.LinesReceived
        $notificationsReceived = [int]$Response.NotificationsReceived
        $responsesWithOtherId = [int]$Response.ResponsesWithOtherId
        $notificationMethods = [object[]]@($Response.NotificationMethods)
        $matchingResponseReceived = [bool]$Response.MatchingResponseReceived
        $matchingErrorReceived = [bool]$Response.MatchingErrorReceived
    }
    return [pscustomobject]@{
        LinesReceived = $linesReceived
        NotificationsReceived = $notificationsReceived
        ResponsesWithOtherId = $responsesWithOtherId
        NotificationMethods = $notificationMethods
        MatchingResponseReceived = $matchingResponseReceived
        MatchingErrorReceived = $matchingErrorReceived
        ExecutableDiscoverySucceeded = $ExecutableDiscoverySucceeded
        ExecutableSource = $ExecutableSource
        ExecutableFileName = $ExecutableFileName
        ExecutableVersion = $ExecutableVersion
        AccountStabilityLockAcquired = $AccountStabilityLockAcquired
        AppServerStarted = $AppServerStarted
        ProcessStarted = $AppServerStarted
        InitializeMatched = $InitializeMatched
        RateLimitsResponseMatched = $RateLimitsResponseMatched
        SnapshotParsed = $SnapshotParsed
        StdinCloseAttempted = $StdinCloseAttempted
        StdinCloseSucceeded = $StdinCloseSucceeded
        ChildExitedNaturally = $ChildExitedNaturally
        ChildHasExited = $ChildHasExited
        CleanupElapsedMilliseconds = $CleanupElapsedMilliseconds
        PrimarySucceeded = $PrimarySucceeded
        PrimaryFailureCode = $PrimaryFailureCode
        CleanupSucceeded = $CleanupSucceeded
        CleanupFailureCode = $CleanupFailureCode
    }
}

function Get-QiehaoQuotaSafeFailureCode {
    param(
        [AllowNull()][object]$Value,
        [string]$Fallback = 'QUOTA_QUERY_FAILED'
    )

    $candidate = if ($null -eq $Value) { '' } else { [string]$Value }
    $allowed = @(
        'QUOTA_CODEX_NOT_FOUND',
        'QUOTA_APP_SERVER_START_FAILED',
        'QUOTA_INITIALIZE_TIMEOUT',
        'QUOTA_INITIALIZE_ERROR',
        'QUOTA_RATE_LIMITS_TIMEOUT',
        'QUOTA_RATE_LIMITS_RPC_ERROR',
        'QUOTA_RESPONSE_INVALID',
        'QUOTA_PARSE_FAILED',
        'QUOTA_CHILD_CLEANUP_FAILED',
        'QUOTA_BACKGROUND_WORKER_FAILED',
        'QUOTA_RESULT_MISSING',
        'QUOTA_QUERY_FAILED',
        'OPERATION_BUSY'
    )
    if ($allowed -ccontains $candidate) { return $candidate }
    return $Fallback
}

function ConvertTo-QiehaoQuotaFailureCode {
    param([AllowNull()][object]$ErrorRecord)

    $candidate = if ($null -eq $ErrorRecord) {
        ''
    }
    else {
        [string]$ErrorRecord.Exception.Message
    }
    return Get-QiehaoQuotaSafeFailureCode -Value $candidate
}

function Invoke-QiehaoQuotaTransport {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateRange(1, 60)]
        [int]$TimeoutSeconds,

        [ValidateRange(100, 10000)]
        [int]$CleanupGraceMilliseconds = 4000,

        [AllowNull()][string]$TestExecutablePath,

        [AllowNull()][string]$TestProcessArguments
    )

    $process = $null
    $processStarted = $false
    $stderrTask = $null
    $initializeResponse = $null
    $quotaResponse = $null
    $snapshot = $null
    $primarySucceeded = $false
    $primaryFailureCode = $null
    $cleanupSucceeded = $true
    $cleanupFailureCode = $null
    $childCleanup = 'NotStarted'
    $snapshotParsed = $false
    $stdinCloseAttempted = $false
    $stdinCloseSucceeded = $false
    $childExitedNaturally = $false
    $childHasExited = $false
    $cleanupElapsedMilliseconds = 0L
    $executable = [pscustomobject]@{
        Succeeded = $false
        Source = 'NotFound'
        Path = $null
        FileName = ''
        Version = ''
    }
    $processArguments = 'app-server --stdio'
    $appServerStarted = $false
    $initializeMatched = $false
    $rateLimitsResponseMatched = $false
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        if (-not [string]::IsNullOrWhiteSpace($TestExecutablePath)) {
            $testFullPath = [System.IO.Path]::GetFullPath(
                $TestExecutablePath
            )
            if (-not [System.IO.Path]::IsPathRooted($testFullPath) -or
                -not [System.IO.File]::Exists($testFullPath)) {
                throw 'QUOTA_APP_SERVER_START_FAILED'
            }
            $testItem = Get-Item -LiteralPath $testFullPath -ErrorAction Stop
            $executable = [pscustomobject]@{
                Succeeded = $true
                Source = 'ExplicitKnownPath'
                Path = $testFullPath
                FileName = [string]$testItem.Name
                Version = [string]$testItem.VersionInfo.FileVersion
            }
            $processArguments = [string]$TestProcessArguments
        }
        else {
            $executable = Resolve-QiehaoCodexExecutable
        }
        if (-not [bool]$executable.Succeeded) {
            throw 'QUOTA_CODEX_NOT_FOUND'
        }

        $startInfo = New-Object Diagnostics.ProcessStartInfo
        $startInfo.FileName = [string]$executable.Path
        $startInfo.Arguments = $processArguments
        $startInfo.WorkingDirectory = Split-Path -Parent (
            [string]$executable.Path
        )
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        foreach ($encodingProperty in @(
            'StandardInputEncoding',
            'StandardOutputEncoding',
            'StandardErrorEncoding'
        )) {
            if ($null -ne $startInfo.PSObject.Properties[$encodingProperty]) {
                $startInfo.$encodingProperty = $utf8NoBom
            }
        }

        $process = New-Object Diagnostics.Process
        $process.StartInfo = $startInfo
        try {
            $processStarted = [bool]$process.Start()
        }
        catch {
            throw 'QUOTA_APP_SERVER_START_FAILED'
        }
        if (-not $processStarted) { throw 'QUOTA_APP_SERVER_START_FAILED' }
        $appServerStarted = $true
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
        try {
            $initializeResponse = Wait-QiehaoQuotaMatchingResponse `
                -Reader $process.StandardOutput -RequestId $initializeId `
                -DeadlineUtc $deadlineUtc
        }
        catch {
            if ($_.Exception.Message -ceq 'QUOTA_RESPONSE_TIMEOUT') {
                throw 'QUOTA_INITIALIZE_TIMEOUT'
            }
            throw 'QUOTA_RESPONSE_INVALID'
        }
        if ($initializeResponse.MatchingErrorReceived) {
            throw 'QUOTA_INITIALIZE_ERROR'
        }
        $initializeMatched = $true

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
        try {
            $quotaResponse = Wait-QiehaoQuotaMatchingResponse `
                -Reader $process.StandardOutput -RequestId $quotaRequestId `
                -DeadlineUtc $deadlineUtc
        }
        catch {
            if ($_.Exception.Message -ceq 'QUOTA_RESPONSE_TIMEOUT') {
                throw 'QUOTA_RATE_LIMITS_TIMEOUT'
            }
            throw 'QUOTA_RESPONSE_INVALID'
        }
        if ($quotaResponse.MatchingErrorReceived) {
            throw 'QUOTA_RATE_LIMITS_RPC_ERROR'
        }
        $rateLimitsResponseMatched = $true

        $resultProperty = $quotaResponse.Response.PSObject.Properties['result']
        if ($null -eq $resultProperty -or $null -eq $resultProperty.Value) {
            throw 'QUOTA_RESULT_MISSING'
        }
        try {
            $snapshot = ConvertTo-QiehaoQuotaSnapshot `
                -Result $resultProperty.Value
        }
        catch {
            throw 'QUOTA_PARSE_FAILED'
        }
        if ($null -eq $snapshot.Windows -or
            -not ($snapshot.Windows -is [object[]])) {
            throw 'QUOTA_PARSE_FAILED'
        }
        $snapshotParsed = $true
        $primarySucceeded = $true
    }
    catch {
        $primaryFailureCode =
            ConvertTo-QiehaoQuotaFailureCode -ErrorRecord $_
    }
    finally {
        if ($stopwatch.IsRunning) {
            $stopwatch.Stop()
        }
        if ($null -ne $process -and $processStarted) {
            $cleanupSucceeded = $false
            $cleanupStopwatch = [Diagnostics.Stopwatch]::StartNew()
            $stdinCloseAttempted = $true
            $stdinOperationSucceeded = $true
            try {
                $process.StandardInput.Flush()
            }
            catch {
                $stdinOperationSucceeded = $false
            }
            try {
                $process.StandardInput.Close()
            }
            catch {
                $stdinOperationSucceeded = $false
            }
            try {
                $process.StandardInput.Dispose()
            }
            catch {
                $stdinOperationSucceeded = $false
            }
            $stdinCloseSucceeded = $stdinOperationSucceeded

            try {
                $childHasExited = [bool]$process.WaitForExit(
                    $CleanupGraceMilliseconds
                )
            }
            catch {
                $childHasExited = $false
            }
            if (-not $childHasExited) {
                try {
                    $childHasExited = [bool]$process.HasExited
                }
                catch {
                    $childHasExited = $false
                }
            }
            if ($childHasExited) {
                # The parameterless overload completes asynchronous stream
                # bookkeeping after the bounded wait has observed process exit.
                try { $process.WaitForExit() }
                catch { }
                $childExitedNaturally = $true
            }

            if ($null -ne $stderrTask -and
                ($childHasExited -or $stderrTask.IsCompleted)) {
                try { $null = $stderrTask.GetAwaiter().GetResult() }
                catch { }
            }
            try { $process.StandardOutput.Dispose() }
            catch { }
            try { $process.StandardError.Dispose() }
            catch { }
            if ($null -ne $stderrTask -and $stderrTask.IsCompleted) {
                try { $null = $stderrTask.GetAwaiter().GetResult() }
                catch { }
            }

            $cleanupSucceeded = (
                $stdinCloseSucceeded -and $childHasExited
            )
            if ($cleanupSucceeded) {
                $childCleanup = 'Normal'
            }
            else {
                $cleanupFailureCode = 'QUOTA_CHILD_CLEANUP_FAILED'
                $childCleanup = 'GraceExpired'
            }
            $process.Dispose()
            if ($cleanupStopwatch.IsRunning) {
                $cleanupStopwatch.Stop()
            }
            $cleanupElapsedMilliseconds =
                $cleanupStopwatch.ElapsedMilliseconds
        }
        elseif ($null -ne $process) {
            $process.Dispose()
        }
        $initializeResponse = $null
        if ($null -ne $quotaResponse) {
            $quotaResponse.Response = $null
        }
    }

    $succeeded = $primarySucceeded -and $cleanupSucceeded
    $failureCode = if (-not $primarySucceeded) {
        $primaryFailureCode
    }
    elseif (-not $cleanupSucceeded) {
        $cleanupFailureCode
    }
    else { $null }
    return [pscustomobject]@{
        Succeeded = $succeeded
        FailureCode = if ($succeeded) { $null } else { $failureCode }
        Snapshot = if ($succeeded) { $snapshot } else { $null }
        PrimarySucceeded = $primarySucceeded
        PrimaryFailureCode = $primaryFailureCode
        CleanupSucceeded = $cleanupSucceeded
        CleanupFailureCode = $cleanupFailureCode
        Diagnostics = New-QiehaoQuotaDiagnostics `
            -Response $quotaResponse `
            -ExecutableDiscoverySucceeded ([bool]$executable.Succeeded) `
            -ExecutableSource ([string]$executable.Source) `
            -ExecutableFileName ([string]$executable.FileName) `
            -ExecutableVersion ([string]$executable.Version) `
            -AppServerStarted $appServerStarted `
            -InitializeMatched $initializeMatched `
            -RateLimitsResponseMatched $rateLimitsResponseMatched `
            -SnapshotParsed $snapshotParsed `
            -StdinCloseAttempted $stdinCloseAttempted `
            -StdinCloseSucceeded $stdinCloseSucceeded `
            -ChildExitedNaturally $childExitedNaturally `
            -ChildHasExited $childHasExited `
            -CleanupElapsedMilliseconds $cleanupElapsedMilliseconds `
            -PrimarySucceeded $primarySucceeded `
            -PrimaryFailureCode $primaryFailureCode `
            -CleanupSucceeded $cleanupSucceeded `
            -CleanupFailureCode $cleanupFailureCode
        ElapsedMilliseconds = $stopwatch.ElapsedMilliseconds
        CleanupElapsedMilliseconds = $cleanupElapsedMilliseconds
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
        if ($null -eq $result) { throw 'QUOTA_RESULT_MISSING' }
        $result.Diagnostics.AccountStabilityLockAcquired = $true
        $result.AccountStabilityLockCleanup = 'Released'
        return $result
    }
    catch {
        $lockFailureCode =
            ConvertTo-QiehaoQuotaFailureCode -ErrorRecord $_
        return [pscustomobject]@{
            Succeeded = $false
            FailureCode = $lockFailureCode
            Snapshot = $null
            PrimarySucceeded = $false
            PrimaryFailureCode = $lockFailureCode
            CleanupSucceeded = $true
            CleanupFailureCode = $null
            Diagnostics = New-QiehaoQuotaDiagnostics -Response $null `
                -PrimarySucceeded $false `
                -PrimaryFailureCode $lockFailureCode `
                -CleanupSucceeded $true
            ElapsedMilliseconds = 0
            CleanupElapsedMilliseconds = 0
            ChildCleanup = 'NotStarted'
            AccountStabilityLockCleanup = 'ReleasedOrNotAcquired'
        }
    }
}

function ConvertTo-QiehaoQuotaPlainSnapshot {
    param([AllowNull()][object]$Snapshot)

    if ($null -eq $Snapshot) { return $null }
    $plainWindows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($window in @(
        Get-QiehaoQuotaPropertyValue -InputObject $Snapshot -Name 'Windows' `
            -DefaultValue ([object[]]@())
    )) {
        if ($null -eq $window) { continue }
        $null = $plainWindows.Add([pscustomobject]@{
            DurationMinutes = Get-QiehaoQuotaPropertyValue `
                -InputObject $window -Name 'DurationMinutes'
            Label = [string](Get-QiehaoQuotaPropertyValue `
                -InputObject $window -Name 'Label' -DefaultValue '')
            RemainingPercent = Get-QiehaoQuotaPropertyValue `
                -InputObject $window -Name 'RemainingPercent'
            ResetsAt = Get-QiehaoQuotaPropertyValue `
                -InputObject $window -Name 'ResetsAt'
            ResetLocal = [string](Get-QiehaoQuotaPropertyValue `
                -InputObject $window -Name 'ResetLocal' -DefaultValue '')
        })
    }
    return [pscustomobject]@{
        Plan = Get-QiehaoQuotaPropertyValue `
            -InputObject $Snapshot -Name 'Plan'
        OrdinaryUsageAllowed = Get-QiehaoQuotaPropertyValue `
            -InputObject $Snapshot -Name 'OrdinaryUsageAllowed'
        Windows = $plainWindows.ToArray()
    }
}

function ConvertTo-QiehaoQuotaPlainDiagnostics {
    param(
        [AllowNull()][object]$Diagnostics,
        [Parameter(Mandatory = $true)][object]$Executable,
        [Parameter(Mandatory = $true)][bool]$ModulesLoaded,
        [Parameter(Mandatory = $true)][bool]$ClientCommandAvailable,
        [Parameter(Mandatory = $true)][bool]$ParserCommandAvailable,
        [Parameter(Mandatory = $true)][bool]$AuthReferenceValid,
        [Parameter(Mandatory = $true)][int]$ProviderOutputCount
    )

    $source = [string](Get-QiehaoQuotaPropertyValue `
        -InputObject $Diagnostics -Name 'ExecutableSource' `
        -DefaultValue ([string]$Executable.Source))
    if (@(
        'BundledCodex', 'PathCommand', 'ExplicitKnownPath', 'NotFound'
    ) -cnotcontains $source) {
        $source = 'NotFound'
    }
    return [pscustomobject]@{
        WorkerStarted = $true
        ModulesLoaded = $ModulesLoaded
        QuotaClientCommandAvailable = $ClientCommandAvailable
        QuotaParserCommandAvailable = $ParserCommandAvailable
        CodexAuthReferenceValid = $AuthReferenceValid
        ProviderOutputCount = $ProviderOutputCount
        LinesReceived = [int](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'LinesReceived' -DefaultValue 0)
        NotificationsReceived = [int](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'NotificationsReceived' `
            -DefaultValue 0)
        ResponsesWithOtherId = [int](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'ResponsesWithOtherId' `
            -DefaultValue 0)
        NotificationMethods = [object[]]@(
            Get-QiehaoQuotaPropertyValue -InputObject $Diagnostics `
                -Name 'NotificationMethods' -DefaultValue ([object[]]@())
        )
        MatchingResponseReceived = [bool](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'MatchingResponseReceived' `
            -DefaultValue $false)
        MatchingErrorReceived = [bool](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'MatchingErrorReceived' `
            -DefaultValue $false)
        ExecutableDiscoverySucceeded = [bool](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'ExecutableDiscoverySucceeded' `
            -DefaultValue ([bool]$Executable.Succeeded))
        ExecutableSource = $source
        ExecutableFileName = [string](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'ExecutableFileName' `
            -DefaultValue ([string]$Executable.FileName))
        ExecutableVersion = [string](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'ExecutableVersion' `
            -DefaultValue ([string]$Executable.Version))
        AccountStabilityLockAcquired = [bool](
            Get-QiehaoQuotaPropertyValue -InputObject $Diagnostics `
                -Name 'AccountStabilityLockAcquired' -DefaultValue $false
        )
        AppServerStarted = [bool](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'AppServerStarted' `
            -DefaultValue $false)
        ProcessStarted = [bool](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'ProcessStarted' `
            -DefaultValue ([bool](Get-QiehaoQuotaPropertyValue `
                -InputObject $Diagnostics -Name 'AppServerStarted' `
                -DefaultValue $false)))
        InitializeMatched = [bool](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'InitializeMatched' `
            -DefaultValue $false)
        RateLimitsResponseMatched = [bool](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'RateLimitsResponseMatched' `
            -DefaultValue $false)
        SnapshotParsed = [bool](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'SnapshotParsed' `
            -DefaultValue $false)
        StdinCloseAttempted = [bool](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'StdinCloseAttempted' `
            -DefaultValue $false)
        StdinCloseSucceeded = [bool](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'StdinCloseSucceeded' `
            -DefaultValue $false)
        ChildExitedNaturally = [bool](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'ChildExitedNaturally' `
            -DefaultValue $false)
        ChildHasExited = [bool](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'ChildHasExited' `
            -DefaultValue $false)
        CleanupElapsedMilliseconds = [long](
            Get-QiehaoQuotaPropertyValue -InputObject $Diagnostics `
                -Name 'CleanupElapsedMilliseconds' -DefaultValue 0
        )
        PrimarySucceeded = [bool](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'PrimarySucceeded' `
            -DefaultValue $false)
        PrimaryFailureCode = Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'PrimaryFailureCode'
        CleanupSucceeded = [bool](Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'CleanupSucceeded' `
            -DefaultValue $true)
        CleanupFailureCode = Get-QiehaoQuotaPropertyValue `
            -InputObject $Diagnostics -Name 'CleanupFailureCode'
    }
}

function Invoke-QiehaoQuotaBackgroundWorker {
    [CmdletBinding()]
    param(
        [ValidateRange(1, 60)][int]$TimeoutSeconds = 10,
        [AllowNull()][scriptblock]$QuotaProvider,
        [AllowNull()][object]$QuotaProviderArgument
    )

    $clientCommandAvailable = $null -ne (Get-Command `
        -Name Get-QiehaoCurrentQuotaSnapshot -CommandType Function `
        -ErrorAction SilentlyContinue)
    $parserCommandAvailable = (
        $null -ne $script:QuotaParserModule -and
        $script:QuotaParserModule.ExportedCommands.ContainsKey(
            'ConvertTo-QiehaoQuotaSnapshot'
        )
    )
    $authReferenceValid = (
        $null -ne $script:QuotaAuthModule -and
        $script:QuotaAuthModule -is
            [System.Management.Automation.PSModuleInfo]
    )
    $modulesLoaded = (
        $clientCommandAvailable -and
        $parserCommandAvailable -and
        $authReferenceValid
    )
    $executable = Resolve-QiehaoCodexExecutable
    $providerOutput = @()
    try {
        if (-not $modulesLoaded) {
            throw 'QUOTA_BACKGROUND_WORKER_FAILED'
        }
        if ($null -eq $QuotaProvider) {
            $providerOutput = @(Get-QiehaoCurrentQuotaSnapshot `
                -TimeoutSeconds $TimeoutSeconds)
        }
        else {
            $providerOutput = @(
                & $QuotaProvider $TimeoutSeconds $QuotaProviderArgument
            )
        }
        if ($providerOutput.Count -ne 1) {
            throw 'QUOTA_RESULT_MISSING'
        }
        $providerResult = $providerOutput[0]
        if ($null -eq $providerResult -or
            $null -eq $providerResult.PSObject.Properties['Succeeded']) {
            throw 'QUOTA_RESULT_MISSING'
        }

        $succeeded = [bool]$providerResult.Succeeded
        $failureCode = $null
        $primarySucceeded = [bool](Get-QiehaoQuotaPropertyValue `
            -InputObject $providerResult -Name 'PrimarySucceeded' `
            -DefaultValue $succeeded)
        $primaryFailureValue = Get-QiehaoQuotaPropertyValue `
            -InputObject $providerResult -Name 'PrimaryFailureCode'
        $cleanupSucceeded = [bool](Get-QiehaoQuotaPropertyValue `
            -InputObject $providerResult -Name 'CleanupSucceeded' `
            -DefaultValue $true)
        $cleanupFailureValue = Get-QiehaoQuotaPropertyValue `
            -InputObject $providerResult -Name 'CleanupFailureCode'
        $primaryFailureCode = if ($null -eq $primaryFailureValue) {
            $null
        }
        else {
            Get-QiehaoQuotaSafeFailureCode -Value $primaryFailureValue
        }
        $cleanupFailureCode = if ($null -eq $cleanupFailureValue) {
            $null
        }
        else {
            Get-QiehaoQuotaSafeFailureCode -Value $cleanupFailureValue
        }
        $snapshot = $null
        if ($succeeded) {
            $snapshot = ConvertTo-QiehaoQuotaPlainSnapshot -Snapshot (
                Get-QiehaoQuotaPropertyValue -InputObject $providerResult `
                    -Name 'Snapshot'
            )
            if ($null -eq $snapshot) {
                $succeeded = $false
                $failureCode = 'QUOTA_RESULT_MISSING'
                $primarySucceeded = $false
                $primaryFailureCode = 'QUOTA_RESULT_MISSING'
            }
        }
        else {
            $failureCode = Get-QiehaoQuotaSafeFailureCode -Value (
                Get-QiehaoQuotaPropertyValue -InputObject $providerResult `
                    -Name 'FailureCode'
            ) -Fallback 'QUOTA_QUERY_FAILED'
            if (-not $primarySucceeded -and
                [string]::IsNullOrWhiteSpace($primaryFailureCode)) {
                $primaryFailureCode = $failureCode
            }
            elseif (-not $cleanupSucceeded -and
                [string]::IsNullOrWhiteSpace($cleanupFailureCode)) {
                $cleanupFailureCode = $failureCode
            }
        }

        $plainDiagnostics = ConvertTo-QiehaoQuotaPlainDiagnostics `
            -Diagnostics (Get-QiehaoQuotaPropertyValue `
                -InputObject $providerResult -Name 'Diagnostics') `
            -Executable $executable -ModulesLoaded $modulesLoaded `
            -ClientCommandAvailable $clientCommandAvailable `
            -ParserCommandAvailable $parserCommandAvailable `
            -AuthReferenceValid $authReferenceValid `
            -ProviderOutputCount $providerOutput.Count
        $plainDiagnostics.PrimarySucceeded = $primarySucceeded
        $plainDiagnostics.PrimaryFailureCode = $primaryFailureCode
        $plainDiagnostics.CleanupSucceeded = $cleanupSucceeded
        $plainDiagnostics.CleanupFailureCode = $cleanupFailureCode
        if ($primarySucceeded -and $null -ne $snapshot) {
            $plainDiagnostics.SnapshotParsed = $true
        }

        return [pscustomobject]@{
            Succeeded = $succeeded
            FailureCode = if ($succeeded) { $null } else { $failureCode }
            Snapshot = if ($succeeded) { $snapshot } else { $null }
            PrimarySucceeded = $primarySucceeded
            PrimaryFailureCode = $primaryFailureCode
            CleanupSucceeded = $cleanupSucceeded
            CleanupFailureCode = $cleanupFailureCode
            Diagnostics = $plainDiagnostics
            ElapsedMilliseconds = [long](Get-QiehaoQuotaPropertyValue `
                -InputObject $providerResult -Name 'ElapsedMilliseconds' `
                -DefaultValue 0)
            CleanupElapsedMilliseconds = [long](
                Get-QiehaoQuotaPropertyValue -InputObject $providerResult `
                    -Name 'CleanupElapsedMilliseconds' -DefaultValue 0
            )
            ChildCleanup = [string](Get-QiehaoQuotaPropertyValue `
                -InputObject $providerResult -Name 'ChildCleanup' `
                -DefaultValue 'NotStarted')
            AccountStabilityLockCleanup = [string](
                Get-QiehaoQuotaPropertyValue -InputObject $providerResult `
                    -Name 'AccountStabilityLockCleanup' `
                    -DefaultValue 'ReleasedOrNotAcquired'
            )
        }
    }
    catch {
        $failureCode = ConvertTo-QiehaoQuotaFailureCode -ErrorRecord $_
        if ($failureCode -ceq 'QUOTA_QUERY_FAILED') {
            $failureCode = 'QUOTA_BACKGROUND_WORKER_FAILED'
        }
        return [pscustomobject]@{
            Succeeded = $false
            FailureCode = $failureCode
            Snapshot = $null
            PrimarySucceeded = $false
            PrimaryFailureCode = $failureCode
            CleanupSucceeded = $true
            CleanupFailureCode = $null
            Diagnostics = ConvertTo-QiehaoQuotaPlainDiagnostics `
                -Diagnostics $null -Executable $executable `
                -ModulesLoaded $modulesLoaded `
                -ClientCommandAvailable $clientCommandAvailable `
                -ParserCommandAvailable $parserCommandAvailable `
                -AuthReferenceValid $authReferenceValid `
                -ProviderOutputCount $providerOutput.Count
            ElapsedMilliseconds = 0
            CleanupElapsedMilliseconds = 0
            ChildCleanup = 'NotStarted'
            AccountStabilityLockCleanup = 'ReleasedOrNotAcquired'
        }
    }
}

Export-ModuleMember -Function @(
    'Get-QiehaoCurrentQuotaSnapshot',
    'Invoke-QiehaoQuotaBackgroundWorker'
)
