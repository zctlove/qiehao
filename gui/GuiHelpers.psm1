Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

function Get-ObjectPropertyValue {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$DefaultValue
    )

    if ($null -eq $InputObject) {
        return $DefaultValue
    }
    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }
    return $property.Value
}

function Get-AllowlistedDisplayValue {
    param(
        [AllowNull()]
        [object]$Value,

        [Parameter(Mandatory = $true)]
        [string[]]$AllowedValues,

        [Parameter(Mandatory = $true)]
        [string]$Fallback
    )

    $candidate = [string]$Value
    if ($AllowedValues -ccontains $candidate) {
        return $candidate
    }
    return $Fallback
}

function ConvertTo-QiehaoGuiProfileRows {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$ProfileData,

        [AllowNull()]
        [string]$ActiveProfile,

        [switch]$ActiveProfileKnown
    )

    $rows = @()
    foreach ($item in @($ProfileData)) {
        if ($null -eq $item) {
            continue
        }

        $name = [string](Get-ObjectPropertyValue -InputObject $item `
            -Name 'Profile' -DefaultValue '<Unknown>')
        if ([string]::IsNullOrWhiteSpace($name)) {
            $name = '<Unknown>'
        }

        if ($ActiveProfileKnown) {
            $activeText = if ($name.Equals(
                $ActiveProfile,
                [StringComparison]::OrdinalIgnoreCase
            )) { 'Yes' } else { 'No' }
        }
        else {
            $activeValue = Get-ObjectPropertyValue -InputObject $item `
                -Name 'Active' -DefaultValue $null
            if ($activeValue -is [bool]) {
                $activeText = if ([bool]$activeValue) { 'Yes' } else { 'No' }
            }
            else {
                $activeText = 'Unknown'
            }
        }

        $updated = [string](Get-ObjectPropertyValue -InputObject $item `
            -Name 'UpdatedAt' -DefaultValue '<UNAVAILABLE>')
        if ([string]::IsNullOrWhiteSpace($updated)) {
            $updated = '<UNAVAILABLE>'
        }

        $rows += [pscustomobject]@{
            Name = $name
            Active = $activeText
            Health = Get-AllowlistedDisplayValue `
                -Value (Get-ObjectPropertyValue -InputObject $item `
                    -Name 'Health' -DefaultValue 'UNKNOWN') `
                -AllowedValues @(
                    'READY',
                    'INCOMPLETE_PROFILE',
                    'INVALID_METADATA',
                    'UNKNOWN'
                ) -Fallback 'UNKNOWN'
            Auth = Get-AllowlistedDisplayValue `
                -Value (Get-ObjectPropertyValue -InputObject $item `
                    -Name 'AuthFile' -DefaultValue 'UNKNOWN') `
                -AllowedValues @('PRESENT', 'MISSING', 'UNKNOWN') `
                -Fallback 'UNKNOWN'
            Identity = Get-AllowlistedDisplayValue `
                -Value (Get-ObjectPropertyValue -InputObject $item `
                    -Name 'IdentityMarker' -DefaultValue 'UNKNOWN') `
                -AllowedValues @('PRESENT', 'MISSING', 'UNKNOWN') `
                -Fallback 'UNKNOWN'
            Metadata = Get-AllowlistedDisplayValue `
                -Value (Get-ObjectPropertyValue -InputObject $item `
                    -Name 'Metadata' -DefaultValue 'UNKNOWN') `
                -AllowedValues @('VALID', 'MISSING', 'INVALID', 'UNKNOWN') `
                -Fallback 'UNKNOWN'
            Updated = $updated
        }
    }
    return @($rows)
}

function ConvertTo-QiehaoCodexStatus {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$ProcessState
    )

    $reasonCode = [string](Get-ObjectPropertyValue -InputObject $ProcessState `
        -Name 'ReasonCode' -DefaultValue 'CODEX_PROCESS_STATE_UNKNOWN')
    switch ($reasonCode) {
        'CODEX_PROCESSES_STOPPED' { return 'Stopped' }
        'CODEX_PROCESS_RUNNING' { return 'Running' }
        'CODEX_PROCESS_STATE_UNKNOWN' { return 'Unknown' }
        default { return 'Unknown' }
    }
}

function Get-QiehaoGuiSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ListProvider,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ActiveProvider,

        [Parameter(Mandatory = $true)]
        [scriptblock]$ProcessProvider
    )

    $errors = @()
    $rawProfiles = @()
    try {
        $rawProfiles = @(& $ListProvider)
    }
    catch {
        $errors += 'PROFILE_LIST_UNAVAILABLE'
        $rawProfiles = @()
    }

    $activeProfile = 'Not initialized'
    $activeProfileKnown = $false
    try {
        $activeState = & $ActiveProvider
        $candidate = [string](Get-ObjectPropertyValue -InputObject $activeState `
            -Name 'ActiveProfile' -DefaultValue '')
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $activeProfile = $candidate
            $activeProfileKnown = $true
        }
    }
    catch {
        $errors += 'ACTIVE_PROFILE_UNAVAILABLE'
    }

    $codexStatus = 'Unknown'
    try {
        $codexStatus = ConvertTo-QiehaoCodexStatus -ProcessState (& $ProcessProvider)
    }
    catch {
        $errors += 'CODEX_PROCESS_STATE_UNAVAILABLE'
    }

    $rows = ConvertTo-QiehaoGuiProfileRows -ProfileData $rawProfiles `
        -ActiveProfile $activeProfile -ActiveProfileKnown:$activeProfileKnown

    return [pscustomobject]@{
        CodexDesktop = $codexStatus
        ActiveProfile = $activeProfile
        IdentityStatus = 'Not checked'
        WebChatGPT = 'Unaffected'
        Profiles = @($rows)
        ReadOnlyErrors = @($errors)
    }
}

function Enter-QiehaoGuiSingleInstance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$MutexName
    )

    $createdNew = $false
    $mutex = $null
    try {
        $mutex = [System.Threading.Mutex]::new(
            $true,
            $MutexName,
            [ref]$createdNew
        )
        if (-not $createdNew) {
            $mutex.Dispose()
            $mutex = $null
        }
        return [pscustomobject]@{
            Acquired = $createdNew
            Mutex = $mutex
        }
    }
    catch {
        if ($null -ne $mutex) {
            $mutex.Dispose()
        }
        throw
    }
}

function Exit-QiehaoGuiSingleInstance {
    [CmdletBinding()]
    param(
        [AllowNull()]
        [object]$Lease
    )

    if ($null -eq $Lease -or -not [bool]$Lease.Acquired -or
        $null -eq $Lease.Mutex) {
        return
    }
    try {
        $Lease.Mutex.ReleaseMutex()
    }
    catch [System.ApplicationException] {
        # The lease was not owned by this thread. Disposal is still required.
    }
    finally {
        $Lease.Mutex.Dispose()
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-QiehaoGuiProfileRows',
    'ConvertTo-QiehaoCodexStatus',
    'Get-QiehaoGuiSnapshot',
    'Enter-QiehaoGuiSingleInstance',
    'Exit-QiehaoGuiSingleInstance'
)
