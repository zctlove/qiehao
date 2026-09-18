Set-StrictMode -Version 2.0

function Get-QiehaoObjectProperty {
    param(
        [AllowNull()]
        [object]$InputObject,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($null -eq $InputObject) {
        return $null
    }

    $property = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }
    return $property
}

function Get-QiehaoDurationLabel {
    param(
        [AllowNull()]
        [Nullable[long]]$DurationMinutes
    )

    if ($null -eq $DurationMinutes) {
        return 'Unknown-duration window'
    }

    $minutes = [long]$DurationMinutes
    if ($minutes -eq 300) {
        return '5-hour'
    }
    if ($minutes -eq 10080) {
        return 'Weekly'
    }
    if ($minutes -gt 0 -and ($minutes % 1440) -eq 0) {
        return ([string]($minutes / 1440) + '-day window')
    }
    if ($minutes -gt 0 -and ($minutes % 60) -eq 0) {
        return ([string]($minutes / 60) + '-hour window')
    }
    return ([string]$minutes + '-minute window')
}

function ConvertTo-QiehaoNullableInt64 {
    param(
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }

    try {
        return [Convert]::ToInt64($Value, [Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        return $null
    }
}

function ConvertTo-QiehaoRemainingPercent {
    param(
        [AllowNull()]
        [object]$UsedPercent
    )

    if ($null -eq $UsedPercent) {
        return $null
    }

    try {
        $used = [Convert]::ToDouble(
            $UsedPercent,
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    catch {
        return $null
    }

    if ([double]::IsNaN($used) -or [double]::IsInfinity($used)) {
        return $null
    }

    $remaining = 100.0 - $used
    if ($remaining -lt 0.0) {
        $remaining = 0.0
    }
    elseif ($remaining -gt 100.0) {
        $remaining = 100.0
    }
    return $remaining
}

function ConvertTo-QiehaoResetLocal {
    param(
        [AllowNull()]
        [object]$ResetsAt
    )

    $seconds = ConvertTo-QiehaoNullableInt64 -Value $ResetsAt
    if ($null -eq $seconds) {
        return $null
    }

    try {
        return [DateTimeOffset]::FromUnixTimeSeconds([long]$seconds).
            ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')
    }
    catch {
        return $null
    }
}

function ConvertTo-QiehaoUsageWindow {
    param(
        [AllowNull()]
        [object]$Window
    )

    if ($null -eq $Window) {
        return $null
    }

    $usedProperty = Get-QiehaoObjectProperty -InputObject $Window -Name 'usedPercent'
    if ($null -eq $usedProperty) {
        return $null
    }

    $durationProperty = Get-QiehaoObjectProperty `
        -InputObject $Window -Name 'windowDurationMins'
    $resetProperty = Get-QiehaoObjectProperty -InputObject $Window -Name 'resetsAt'

    $durationMinutes = $null
    if ($null -ne $durationProperty) {
        $durationMinutes = ConvertTo-QiehaoNullableInt64 -Value $durationProperty.Value
    }

    $resetValue = $null
    if ($null -ne $resetProperty) {
        $resetValue = $resetProperty.Value
    }

    return [pscustomobject]@{
        DurationMinutes = $durationMinutes
        Label = Get-QiehaoDurationLabel -DurationMinutes $durationMinutes
        RemainingPercent = ConvertTo-QiehaoRemainingPercent `
            -UsedPercent $usedProperty.Value
        ResetLocal = ConvertTo-QiehaoResetLocal -ResetsAt $resetValue
    }
}

function ConvertTo-QiehaoQuotaSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Result
    )

    $selectedBucket = $null
    $bucketsProperty = Get-QiehaoObjectProperty `
        -InputObject $Result -Name 'rateLimitsByLimitId'
    if ($null -ne $bucketsProperty -and $null -ne $bucketsProperty.Value) {
        $codexProperty = Get-QiehaoObjectProperty `
            -InputObject $bucketsProperty.Value -Name 'codex'
        if ($null -ne $codexProperty -and $null -ne $codexProperty.Value) {
            $selectedBucket = $codexProperty.Value
        }
    }

    if ($null -eq $selectedBucket) {
        $legacyProperty = Get-QiehaoObjectProperty -InputObject $Result -Name 'rateLimits'
        if ($null -ne $legacyProperty) {
            $selectedBucket = $legacyProperty.Value
        }
    }

    $plan = $null
    $windows = New-Object 'System.Collections.Generic.List[object]'
    if ($null -ne $selectedBucket) {
        $planProperty = Get-QiehaoObjectProperty `
            -InputObject $selectedBucket -Name 'planType'
        if ($null -ne $planProperty -and $null -ne $planProperty.Value) {
            $plan = [string]$planProperty.Value
        }

        foreach ($propertyName in @('primary', 'secondary')) {
            $windowProperty = Get-QiehaoObjectProperty `
                -InputObject $selectedBucket -Name $propertyName
            if ($null -eq $windowProperty -or $null -eq $windowProperty.Value) {
                continue
            }
            $parsedWindow = ConvertTo-QiehaoUsageWindow -Window $windowProperty.Value
            if ($null -ne $parsedWindow) {
                $null = $windows.Add($parsedWindow)
            }
        }
    }

    $ordinaryUsageAllowed = $null
    $ordinaryProperty = Get-QiehaoObjectProperty `
        -InputObject $Result -Name 'ordinaryUsageAllowed'
    if ($null -ne $ordinaryProperty -and $null -ne $ordinaryProperty.Value) {
        if ($ordinaryProperty.Value -is [bool]) {
            $ordinaryUsageAllowed = [bool]$ordinaryProperty.Value
        }
    }

    # Windows PowerShell 5.1 cannot reliably wrap Generic.List[object] with
    # @($windows) while constructing a PSCustomObject. ToArray() is deliberate.
    return [pscustomobject]@{
        Plan = $plan
        OrdinaryUsageAllowed = $ordinaryUsageAllowed
        Windows = $windows.ToArray()
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-QiehaoQuotaSnapshot'
)
