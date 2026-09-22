[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        'status',
        'list',
        'save',
        'active',
        'init-marker',
        'init-active',
        'switch',
        'add-profile',
        'remove-profile',
        'rename-profile',
        'verify-profile'
    )]
    [string]$Command = 'status',

    [Parameter(Position = 1)]
    [string]$ProfileName,

    [Parameter(Position = 2)]
    [string]$NewProfileName,

    [switch]$Force,

    [switch]$ConfirmDelete
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$modulePath = Join-Path -Path $PSScriptRoot -ChildPath 'lib\CodexAuth.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

$safeErrorCodes = @(
    'ATOMIC_WRITE_FAILED',
    'AUTH_BYTES_EMPTY',
    'AUTH_FILE_EMPTY',
    'AUTH_FILE_NOT_FOUND',
    'AUTH_FILE_READ_FAILED',
    'AUTH_FILE_TOO_LARGE',
    'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED',
    'AUTH_JSON_INVALID',
    'AUTH_SCHEMA_UNEXPECTED',
    'ACTIVE_PROFILE_IDENTITY_MISMATCH',
    'ACTIVE_PROFILE_OUT_OF_SYNC',
    'ACTIVE_PROFILE_MISMATCH',
    'ACTIVE_PROFILE_NOT_INITIALIZED',
    'ACTIVE_PROFILE_STATE_INVALID',
    'ALREADY_ACTIVE',
    'CODEX_HOME_INVALID',
    'CODEX_HOME_NOT_FOUND',
    'CODEX_PROCESS_RUNNING',
    'CODEX_PROCESS_STATE_UNKNOWN',
    'CANNOT_REMOVE_ACTIVE_PROFILE',
    'DPAPI_PROTECT_FAILED',
    'DPAPI_UNPROTECT_FAILED',
    'ENCRYPTED_BYTES_EMPTY',
    'IDENTITY_MARKER_PROTECT_FAILED',
    'OPERATION_BUSY',
    'OPERATION_LOCK_INVALID',
    'PROFILE_ADD_FAILED',
    'PROFILE_ADD_ROLLBACK_FAILED',
    'PROFILE_ADD_VERIFICATION_FAILED',
    'PROFILE_EXISTS',
    'PROFILE_IDENTITY_ALREADY_EXISTS',
    'PROFILE_IDENTITY_MARKER_INVALID',
    'PROFILE_IDENTITY_MARKER_MISSING',
    'PROFILE_IDENTITY_MISMATCH',
    'PROFILE_IDENTITY_SCAN_INCOMPLETE',
    'PROFILE_IDENTITY_SCHEMA_UNRECOGNIZED',
    'PROFILE_INCOMPLETE',
    'PROFILE_METADATA_INVALID',
    'PROFILE_NAME_ALREADY_EXISTS',
    'PROFILE_NAME_INVALID',
    'PROFILE_NAME_RESERVED',
    'PROFILE_NAME_TOO_LONG',
    'PROFILE_NOT_FOUND',
    'PROFILE_PATH_UNSAFE',
    'PROFILE_REMOVE_CONFIRMATION_REQUIRED',
    'PROFILE_RENAME_FAILED',
    'PROFILE_RENAME_FAILED_ROLLED_BACK',
    'PROFILE_RENAME_ROLLBACK_FAILED',
    'PROFILES_DIRECTORY_NOT_FOUND',
    'SAVE_FAILED',
    'STATE_DIRECTORY_NOT_FOUND',
    'SWITCH_FAILED',
    'SWITCH_FAILED_ROLLED_BACK',
    'SWITCH_POST_REPLACE_VERIFICATION_FAILED',
    'SWITCH_ROLLBACK_FAILED',
    'TARGET_DIRECTORY_NOT_FOUND',
    'USERPROFILE_NOT_AVAILABLE'
)

try {
    switch ($Command) {
        'status' {
            $codexHome = Get-CodexHome
            $authPath = Join-Path -Path $codexHome -ChildPath 'auth.json'
            [pscustomobject]@{
                CodexHome = $codexHome
                CodexHomeExists = [System.IO.Directory]::Exists($codexHome)
                AuthFilePath = $authPath
                AuthFileExists = [System.IO.File]::Exists($authPath)
            }
        }
        'list' {
            Get-CodexAccountSlot
        }
        'save' {
            if ([string]::IsNullOrWhiteSpace($ProfileName)) {
                throw (New-Object System.InvalidOperationException('PROFILE_NAME_REQUIRED'))
            }
            Save-CodexAccountSlot -Name $ProfileName -Force:$Force
        }
        'active' {
            $activeState = Get-CodexActiveProfile
            Write-Output ('ActiveProfile: ' + $activeState.ActiveProfile)
            Write-Output ('UpdatedAt: ' + $activeState.UpdatedAt)
        }
        'init-marker' {
            if ([string]::IsNullOrWhiteSpace($ProfileName)) {
                throw (New-Object System.InvalidOperationException('PROFILE_NAME_REQUIRED'))
            }
            $result = Initialize-CodexProfileIdentityMarker -Name $ProfileName
            Write-Output $result.Result
            Write-Output ('Profile: ' + $result.Profile)
        }
        'init-active' {
            if ([string]::IsNullOrWhiteSpace($ProfileName)) {
                throw (New-Object System.InvalidOperationException('PROFILE_NAME_REQUIRED'))
            }
            $result = Initialize-CodexActiveProfile -Name $ProfileName
            Write-Output $result.Result
            Write-Output ('ActiveProfile: ' + $result.ActiveProfile)
        }
        'switch' {
            if ([string]::IsNullOrWhiteSpace($ProfileName)) {
                throw (New-Object System.InvalidOperationException('PROFILE_NAME_REQUIRED'))
            }
            $result = Switch-CodexAccountProfile -Name $ProfileName
            Write-Output $result.Result
            Write-Output ('From: ' + $result.From)
            Write-Output ('To: ' + $result.To)
        }
        'add-profile' {
            if ([string]::IsNullOrWhiteSpace($ProfileName)) {
                throw (New-Object System.InvalidOperationException('PROFILE_NAME_REQUIRED'))
            }
            $result = Add-CodexProfile -Name $ProfileName
            Write-Output $result.Result
            Write-Output ('Profile: ' + $result.Profile)
        }
        'remove-profile' {
            if ([string]::IsNullOrWhiteSpace($ProfileName)) {
                throw (New-Object System.InvalidOperationException('PROFILE_NAME_REQUIRED'))
            }
            $result = Remove-CodexProfile -Name $ProfileName `
                -ConfirmDelete:$ConfirmDelete
            if ($result.Result -ceq 'PROFILE_REMOVE_PARTIAL_FAILURE') {
                Write-Error -Message $result.Result -ErrorAction Continue
                Write-Output ('RemovedFileTypes: ' + ($result.RemovedFileTypes -join ', '))
                Write-Output ('FailedFileTypes: ' + ($result.FailedFileTypes -join ', '))
                exit 1
            }
            Write-Output $result.Result
            Write-Output ('Profile: ' + $result.Profile)
            Write-Output ('RemovedFileTypes: ' + ($result.RemovedFileTypes -join ', '))
        }
        'rename-profile' {
            if ([string]::IsNullOrWhiteSpace($ProfileName)) {
                throw (New-Object System.InvalidOperationException('PROFILE_NAME_REQUIRED'))
            }
            if ([string]::IsNullOrWhiteSpace($NewProfileName)) {
                throw (New-Object System.InvalidOperationException('NEW_PROFILE_NAME_REQUIRED'))
            }
            $result = Rename-CodexProfile -OldName $ProfileName `
                -NewName $NewProfileName
            Write-Output $result.Result
            Write-Output ('From: ' + $result.From)
            Write-Output ('To: ' + $result.To)
        }
        'verify-profile' {
            if ([string]::IsNullOrWhiteSpace($ProfileName)) {
                throw (New-Object System.InvalidOperationException('PROFILE_NAME_REQUIRED'))
            }
            $result = Test-CodexProfile -Name $ProfileName
            Write-Output $result.Result
            Write-Output ('Profile: ' + $result.Profile)
        }
    }
}
catch {
    $message = $_.Exception.Message
    if ($message -ceq 'SWITCH_ROLLBACK_FAILED') {
        Write-Error -Message 'SWITCH_ROLLBACK_FAILED' -ErrorAction Continue
        Write-Error -Message 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED' -ErrorAction Continue
        exit 1
    }
    if ($message -ceq 'PROFILE_IDENTITY_ALREADY_EXISTS') {
        Write-Error -Message $message -ErrorAction Continue
        $existingProfile = [string]$_.Exception.Data['ExistingProfile']
        if (-not [string]::IsNullOrWhiteSpace($existingProfile)) {
            Write-Output ('Identity already exists as profile: ' + $existingProfile)
        }
        exit 1
    }
    if ($safeErrorCodes -ccontains $message -or
        $message -ceq 'PROFILE_NAME_REQUIRED' -or
        $message -ceq 'NEW_PROFILE_NAME_REQUIRED') {
        Write-Error -Message $message -ErrorAction Continue
    }
    else {
        Write-Error -Message 'OPERATION_FAILED' -ErrorAction Continue
    }
    exit 1
}
