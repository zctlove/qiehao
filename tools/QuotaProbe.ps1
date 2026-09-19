[CmdletBinding()]
param(
    [switch]$RunRealQuery,
    [switch]$ValidateOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$clientPath = Join-Path -Path $PSScriptRoot -ChildPath 'QuotaClient.psm1'
Import-Module -Name $clientPath -Force -ErrorAction Stop

if ($ValidateOnly) {
    Write-Output 'QUOTA_PROBE_VALIDATE_OK'
    return
}
if (-not $RunRealQuery) {
    throw 'REAL_QUERY_REQUIRES_EXPLICIT_RUNREALQUERY'
}

$result = Get-QiehaoCurrentQuotaSnapshot -TimeoutSeconds 60
if (-not $result.Succeeded) {
    Write-Output 'END_TO_END_QUOTA_POC_FAIL'
    Write-Output ('FailureStage: ' + [string]$result.FailureCode)
    Write-Output ('ChildCleanup: ' + [string]$result.ChildCleanup)
    Write-Output ('AccountStabilityLockCleanup: ' +
        [string]$result.AccountStabilityLockCleanup)
    exit 1
}

Write-Output 'CODEX_USAGE_POC_OK'
Write-Output ('Plan: ' + [string]$result.Snapshot.Plan)
Write-Output ('OrdinaryUsageAllowed: ' +
    [string]$result.Snapshot.OrdinaryUsageAllowed)
Write-Output 'Windows:'
foreach ($window in $result.Snapshot.Windows) {
    Write-Output ('- Label: ' + [string]$window.Label)
    Write-Output ('  DurationMinutes: ' + [string]$window.DurationMinutes)
    Write-Output ('  RemainingPercent: ' + [string]$window.RemainingPercent)
    Write-Output ('  ResetLocal: ' + [string]$window.ResetLocal)
}
Write-Output ('LinesReceived: ' + [string]$result.Diagnostics.LinesReceived)
Write-Output ('NotificationsReceived: ' +
    [string]$result.Diagnostics.NotificationsReceived)
Write-Output ('ResponsesWithOtherId: ' +
    [string]$result.Diagnostics.ResponsesWithOtherId)
Write-Output ('MatchingResponseReceived: ' +
    [string]$result.Diagnostics.MatchingResponseReceived)
Write-Output ('MatchingErrorReceived: ' +
    [string]$result.Diagnostics.MatchingErrorReceived)
Write-Output ('ElapsedMilliseconds: ' + [string]$result.ElapsedMilliseconds)
Write-Output ('ChildCleanup: ' + [string]$result.ChildCleanup)
Write-Output ('AccountStabilityLockCleanup: ' +
    [string]$result.AccountStabilityLockCleanup)
Write-Output 'END_TO_END_QUOTA_POC_PASS'
