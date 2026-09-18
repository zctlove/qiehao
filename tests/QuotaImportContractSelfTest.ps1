[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$coreModulePath = Join-Path $projectRoot 'lib\CodexAuth.psm1'
$guiHelperModulePath = Join-Path $projectRoot 'gui\GuiHelpers.psm1'
$quotaParserModulePath = Join-Path $projectRoot 'tools\QuotaParser.psm1'
$quotaClientModulePath = Join-Path $projectRoot 'tools\QuotaClient.psm1'
$quotaHelperModulePath = Join-Path $projectRoot 'gui\QuotaHelpers.psm1'

function Assert-ImportContract {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Code
    )
    if (-not $Condition) { throw $Code }
}

function Test-ExportedCommands {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSModuleInfo]$Module,
        [Parameter(Mandatory = $true)]
        [string[]]$RequiredCommands
    )
    foreach ($requiredCommand in $RequiredCommands) {
        if (-not $Module.ExportedCommands.ContainsKey($requiredCommand)) {
            return $false
        }
    }
    return $true
}

$coreCommands = @(
    'Get-CodexAccountSlot',
    'Get-CodexActiveProfile',
    'Test-CodexProcessesStopped',
    'Test-CodexActiveIdentity'
)
$quotaHelperCommands = @(
    'Get-QiehaoQuotaUiText',
    'New-QiehaoEmptyQuotaCache',
    'Read-QiehaoQuotaCache',
    'Write-QiehaoQuotaCache',
    'Get-QiehaoQuotaCacheSnapshot',
    'Save-QiehaoQuotaSnapshot',
    'Rename-QiehaoQuotaCacheProfile',
    'Remove-QiehaoQuotaCacheProfile',
    'New-QiehaoQuotaCoordinatorState',
    'Invoke-QiehaoQuotaCacheRefresh',
    'Update-QiehaoQuotaProfileRows'
)

# This is the production QiehaoGui.ps1 import order.
$coreModule = @(Import-Module -Name $coreModulePath -Force -PassThru -ErrorAction Stop | Select-Object -Last 1)[0]
$guiHelperModule = @(Import-Module -Name $guiHelperModulePath -Force -PassThru -ErrorAction Stop | Select-Object -Last 1)[0]
$coreBeforeQuota = @($coreCommands | Where-Object {
    $null -eq (Get-Command -Name $_ -ErrorAction SilentlyContinue)
}).Count -eq 0

$parserModule = @(Import-Module -Name $quotaParserModulePath -PassThru -ErrorAction Stop | Select-Object -Last 1)[0]
$clientModule = @(Import-Module -Name $quotaClientModulePath -PassThru -ErrorAction Stop | Select-Object -Last 1)[0]
$helperModule = @(Import-Module -Name $quotaHelperModulePath -PassThru -ErrorAction Stop | Select-Object -Last 1)[0]

$coreAfterQuota = @($coreCommands | Where-Object {
    $null -eq (Get-Command -Name $_ -ErrorAction SilentlyContinue)
}).Count -eq 0
$parserCommandsPresent = Test-ExportedCommands -Module $parserModule -RequiredCommands @('ConvertTo-QiehaoQuotaSnapshot')
$clientCommandsPresent = Test-ExportedCommands -Module $clientModule -RequiredCommands @('Get-QiehaoCurrentQuotaSnapshot')
$helperCommandsPresent = Test-ExportedCommands -Module $helperModule -RequiredCommands $quotaHelperCommands

$clientInternals = & $clientModule {
    $authReferenceValid = (
        $null -ne $script:QuotaAuthModule -and
        $script:QuotaAuthModule -is
            [System.Management.Automation.PSModuleInfo]
    )
    $mutexHelperPresent = $false
    if ($authReferenceValid) {
        $mutexHelperPresent = & $script:QuotaAuthModule {
            $null -ne (Get-Command -Name Invoke-WithCodexWriteLock -CommandType Function -ErrorAction SilentlyContinue)
        }
    }
    [pscustomobject]@{
        AuthReferenceValid = $authReferenceValid
        MutexHelperPresent = [bool]$mutexHelperPresent
    }
}

$runtimeAvailable = (
    $coreBeforeQuota -and
    $coreAfterQuota -and
    $parserCommandsPresent -and
    $clientCommandsPresent -and
    $helperCommandsPresent -and
    [bool]$clientInternals.AuthReferenceValid -and
    [bool]$clientInternals.MutexHelperPresent
)

Assert-ImportContract $coreBeforeQuota 'CORE_COMMANDS_MISSING_BEFORE_QUOTA_IMPORTS'
Assert-ImportContract $coreAfterQuota 'CORE_COMMANDS_REMOVED_BY_QUOTA_IMPORTS'
Assert-ImportContract $parserCommandsPresent 'QUOTA_PARSER_EXPORT_CONTRACT_FAILED'
Assert-ImportContract $clientCommandsPresent 'QUOTA_CLIENT_EXPORT_CONTRACT_FAILED'
Assert-ImportContract $helperCommandsPresent 'QUOTA_HELPER_EXPORT_CONTRACT_FAILED'
Assert-ImportContract ([bool]$clientInternals.AuthReferenceValid) 'QUOTA_AUTH_MODULE_REFERENCE_INVALID'
Assert-ImportContract ([bool]$clientInternals.MutexHelperPresent) 'QUOTA_MUTEX_HELPER_NOT_AVAILABLE_IN_AUTH_MODULE'
Assert-ImportContract $runtimeAvailable 'QUOTA_RUNTIME_NOT_AVAILABLE'

Write-Output ('CORE_COMMANDS_PRESENT=' + [string]$coreBeforeQuota)
Write-Output ('CORE_COMMANDS_SURVIVE_ALL_QUOTA_IMPORTS=' + [string]$coreAfterQuota)
Write-Output ('QUOTA_PARSER_COMMANDS_PRESENT=' + [string]$parserCommandsPresent)
Write-Output ('QUOTA_CLIENT_COMMANDS_PRESENT=' + [string]$clientCommandsPresent)
Write-Output ('QUOTA_HELPER_COMMANDS_PRESENT=' + [string]$helperCommandsPresent)
Write-Output ('QUOTA_AUTH_MODULE_REFERENCE_VALID=' + [string]$clientInternals.AuthReferenceValid)
Write-Output ('QUOTA_MUTEX_HELPER_PRESENT=' + [string]$clientInternals.MutexHelperPresent)
Write-Output ('QUOTA_RUNTIME_AVAILABLE=' + [string]$runtimeAvailable)
Write-Output 'PRODUCTION_IMPORT_ORDER_PASS'
