Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# The same registry lock covers creation/publication and each GUI process scan.
# A monitor must never observe a started child with a half-built descriptor.
function Write-QiehaoOwnershipEvent {
    param([hashtable]$Registry,[string]$Event,[hashtable]$Data)
    if ($null -eq $Registry -or -not $Registry.ContainsKey('DiagnosticLogDirectory')) { return }
    try {
        $core = Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'lib\CodexAuth.psm1') -PassThru -ErrorAction Stop
        & $core { param($e,$d,$l) Write-QiehaoDiagnosticEvent -Event $e -Data $d -LogDirectory $l } $Event $Data $Registry.DiagnosticLogDirectory
    } catch { }
}

function Start-QiehaoOwnedAppServer {
    param([Diagnostics.Process]$Process,[hashtable]$Registry,
        [ValidateSet('Quota','AccountVerify','AccountLogin')][string]$Purpose)
    if ($null -eq $Registry) { return [bool]$Process.Start() }
    [Threading.Monitor]::Enter($Registry.SyncRoot)
    try {
        if ($Registry.ContainsKey('IsActive') -and $Registry.IsActive) { throw 'OWNED_APP_SERVER_CLEANUP_REQUIRED' }
        $Registry.IsActive = $false
        $Registry.OwnershipReady = $false
        $generation = if ($Registry.ContainsKey('OwnershipGeneration')) { [long]$Registry.OwnershipGeneration + 1 } else { 1L }
        $Registry.OwnershipGeneration = $generation
        $Registry.ProcessId = 0; $Registry.ProcessStartTimeUtc = $null
        $Registry.ExecutablePath = [IO.Path]::GetFullPath($Process.StartInfo.FileName)
        $Registry.Arguments = $Process.StartInfo.Arguments
        $Registry.ParentProcessId = $PID; $Registry.Purpose = $Purpose
        $Registry.ProcessHandle = $Process
        $Registry.OwnershipStartedUtc = [DateTime]::UtcNow
        if (-not $Process.Start()) { return $false }
        # Publish active before reading metadata: an exceptional start must also
        # retain its handle for bounded cleanup, never silently lose ownership.
        $Registry.IsActive = $true
        $Registry.ProcessId = $Process.Id
        $Registry.ProcessStartTimeUtc = $Process.StartTime.ToUniversalTime()
        $Registry.OwnershipReady = $true
        $data = @{Purpose=$Purpose;PID=$Registry.ProcessId;ProcessStartTime=$Registry.ProcessStartTimeUtc.ToString('o');OwnershipGeneration=$generation}
    } finally { [Threading.Monitor]::Exit($Registry.SyncRoot) }
    Write-QiehaoOwnershipEvent -Registry $Registry -Event OWNED_APP_SERVER_START -Data $data
    return $true
}

function Complete-QiehaoOwnedAppServer {
    param([hashtable]$Registry,[bool]$ExitObserved,[string]$CleanupResult)
    if ($null -eq $Registry) { return }
    [Threading.Monitor]::Enter($Registry.SyncRoot)
    try {
        $Registry.IsActive = -not $ExitObserved
        $elapsed = if ($Registry.ContainsKey('OwnershipStartedUtc')) { [long]([DateTime]::UtcNow-$Registry.OwnershipStartedUtc).TotalMilliseconds } else { 0L }
        $data = @{Purpose=$Registry.Purpose;PID=$Registry.ProcessId;ExitObserved=$ExitObserved;ElapsedMilliseconds=$elapsed;CleanupResult=$CleanupResult;OwnershipGeneration=$Registry.OwnershipGeneration}
        if ($ExitObserved) { $Registry.ProcessHandle = $null }
    } finally { [Threading.Monitor]::Exit($Registry.SyncRoot) }
    Write-QiehaoOwnershipEvent -Registry $Registry -Event OWNED_APP_SERVER_FINISH -Data $data
}

function Get-QiehaoOwnedAppServerDescriptor {
    param([hashtable]$Registry)
    if ($null -eq $Registry) { return }
    [Threading.Monitor]::Enter($Registry.SyncRoot)
    try {
        if (-not $Registry.IsActive) { return }
        if ($Registry.ContainsKey('OwnershipReady') -and -not $Registry.OwnershipReady) { throw 'OWNED_APP_SERVER_SNAPSHOT_BUSY' }
        return [pscustomobject]@{
            IsActive=$true;ProcessId=$Registry.ProcessId;ProcessStartTimeUtc=$Registry.ProcessStartTimeUtc
            ExecutablePath=$Registry.ExecutablePath;Arguments=$Registry.Arguments
            ParentProcessId=$Registry.ParentProcessId;Purpose=$Registry.Purpose
            OwnershipGeneration=$Registry.OwnershipGeneration
        }
    } finally { [Threading.Monitor]::Exit($Registry.SyncRoot) }
}

function Invoke-QiehaoOwnedProcessInspection {
    param([AllowEmptyCollection()][hashtable[]]$Registries,[scriptblock]$InspectionProvider)
    $held = New-Object 'Collections.Generic.List[object]'
    try {
        foreach ($registry in $Registries) {
            if ($null -eq $registry) { continue }
            if (-not [Threading.Monitor]::TryEnter($registry.SyncRoot)) { throw 'OWNED_APP_SERVER_SNAPSHOT_BUSY' }
            $held.Add($registry.SyncRoot)
        }
        $descriptors = @(foreach ($registry in $Registries) { Get-QiehaoOwnedAppServerDescriptor -Registry $registry })
        # Lock spans both descriptor capture AND actual process enumeration.
        return & $InspectionProvider $descriptors
    } finally {
        for ($index=$held.Count-1;$index -ge 0;$index--) { [Threading.Monitor]::Exit($held[$index]) }
    }
}

function Confirm-QiehaoOwnedAppServerExit {
    param([hashtable]$Registry,[ValidateRange(1,1200)][int]$WaitMilliseconds=500)
    if ($null -eq $Registry -or -not $Registry.IsActive) { return $true }
    $process = $null; $exited = $false
    [Threading.Monitor]::Enter($Registry.SyncRoot)
    try {
        $process = $Registry.ProcessHandle
        if ($null -eq $process) { return $false }
        if ($process.HasExited) { $exited=$true }
        elseif ($process.Id -eq $Registry.ProcessId -and
            $process.StartTime.ToUniversalTime() -eq $Registry.ProcessStartTimeUtc -and
            $process.StartInfo.FileName.Equals($Registry.ExecutablePath,[StringComparison]::OrdinalIgnoreCase) -and
            $Registry.ParentProcessId -eq $PID) {
            # Only the exact handle created by Qiehao; never names or descendants.
            $process.Kill()
            $exited = $process.WaitForExit($WaitMilliseconds)
        }
    } catch { $exited=$false }
    finally { [Threading.Monitor]::Exit($Registry.SyncRoot) }
    Complete-QiehaoOwnedAppServer -Registry $Registry -ExitObserved $exited -CleanupResult $(if ($exited) {'CancelledChildExited'} else {'ExitUnconfirmed'})
    if ($exited -and $null -ne $process) { $process.Dispose() }
    return $exited
}

Export-ModuleMember -Function Start-QiehaoOwnedAppServer,Complete-QiehaoOwnedAppServer,Get-QiehaoOwnedAppServerDescriptor,Invoke-QiehaoOwnedProcessInspection,Confirm-QiehaoOwnedAppServerExit
