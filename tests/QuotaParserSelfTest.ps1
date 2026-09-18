[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path -Path $projectRoot -ChildPath 'tools\QuotaParser.psm1'
Import-Module -Name $modulePath -Force -ErrorAction Stop

function Assert-True {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Condition,

        [Parameter(Mandatory = $true)]
        [string]$Code
    )

    if (-not $Condition) {
        throw $Code
    }
}

function Assert-Equal {
    param(
        [AllowNull()]
        [object]$Actual,

        [AllowNull()]
        [object]$Expected,

        [Parameter(Mandatory = $true)]
        [string]$Code
    )

    if ($null -eq $Actual -and $null -eq $Expected) {
        return
    }
    if ($null -eq $Actual -or $null -eq $Expected -or $Actual -ne $Expected) {
        throw ($Code + ': expected=[' + [string]$Expected +
            '] actual=[' + [string]$Actual + ']')
    }
}

function New-FakeWindow {
    param(
        [Parameter(Mandatory = $true)]
        [int]$UsedPercent,

        [AllowNull()]
        [Nullable[long]]$DurationMinutes,

        [AllowNull()]
        [Nullable[long]]$ResetsAt
    )

    return [pscustomobject]@{
        usedPercent = $UsedPercent
        windowDurationMins = $DurationMinutes
        resetsAt = $ResetsAt
    }
}

function New-FakeResult {
    param(
        [AllowNull()]
        [object]$Primary,

        [AllowNull()]
        [object]$Secondary,

        [AllowNull()]
        [object]$OrdinaryUsageAllowed = $null,

        [string]$PlanType = 'team'
    )

    return [pscustomobject]@{
        accountId = 'FAKE-ACCOUNT-ID-MUST-NOT-LEAK'
        email = 'fake-secret@example.invalid'
        token = 'FAKE-TOKEN-MUST-NOT-LEAK'
        ordinaryUsageAllowed = $OrdinaryUsageAllowed
        rateLimits = [pscustomobject]@{
            planType = $PlanType
            primary = $Primary
            secondary = $Secondary
        }
        rateLimitsByLimitId = $null
    }
}

$resetSeconds = [DateTimeOffset]::Parse(
    '2030-01-02T03:04:05Z',
    [Globalization.CultureInfo]::InvariantCulture
).ToUnixTimeSeconds()
$expectedReset = [DateTimeOffset]::FromUnixTimeSeconds($resetSeconds).
    ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz')

$fiveHour = New-FakeWindow -UsedPercent 86 -DurationMinutes 300 -ResetsAt $resetSeconds
$weekly = New-FakeWindow -UsedPercent 63 -DurationMinutes 10080 -ResetsAt ($resetSeconds + 3600)
$multiple = ConvertTo-QiehaoQuotaSnapshot -Result (
    New-FakeResult -Primary $fiveHour -Secondary $weekly -OrdinaryUsageAllowed $true
)
Assert-Equal $multiple.Windows.Count 2 'MULTIPLE_WINDOWS_COUNT'
Assert-Equal $multiple.Windows[0].Label '5-hour' 'FIVE_HOUR_LABEL'
Assert-Equal $multiple.Windows[0].DurationMinutes 300 'FIVE_HOUR_DURATION'
Assert-Equal $multiple.Windows[0].RemainingPercent 14 'USED_TO_REMAINING'
Assert-Equal $multiple.Windows[0].ResetLocal $expectedReset 'RESET_TO_LOCAL'
Assert-Equal $multiple.Windows[1].Label 'Weekly' 'WEEKLY_LABEL'
Assert-Equal $multiple.Windows[1].DurationMinutes 10080 'WEEKLY_DURATION'
Assert-Equal $multiple.Windows[1].RemainingPercent 37 'WEEKLY_REMAINING'
Assert-Equal $multiple.OrdinaryUsageAllowed $true 'ORDINARY_TRUE'

$single = ConvertTo-QiehaoQuotaSnapshot -Result (
    New-FakeResult -Primary $fiveHour -Secondary $null -OrdinaryUsageAllowed $false
)
Assert-Equal $single.Windows.Count 1 'SINGLE_WINDOW_COUNT'
Assert-Equal $single.OrdinaryUsageAllowed $false 'ORDINARY_FALSE'

$unknownDuration = New-FakeWindow -UsedPercent 40 -DurationMinutes 4320 -ResetsAt $null
$unknown = ConvertTo-QiehaoQuotaSnapshot -Result (
    New-FakeResult -Primary $unknownDuration -Secondary $null
)
Assert-Equal $unknown.Windows[0].Label '3-day window' 'UNKNOWN_DURATION_LABEL'
Assert-Equal $unknown.Windows[0].ResetLocal $null 'RESET_MISSING'
Assert-Equal $unknown.OrdinaryUsageAllowed $null 'ORDINARY_NULL'

$missingDuration = ConvertTo-QiehaoQuotaSnapshot -Result (
    New-FakeResult `
        -Primary (New-FakeWindow -UsedPercent 10 -DurationMinutes $null -ResetsAt $null) `
        -Secondary $null
)
Assert-Equal $missingDuration.Windows.Count 1 'NULL_DURATION_WINDOW_COUNT'
Assert-Equal $missingDuration.Windows[0].DurationMinutes $null 'NULL_DURATION_VALUE'
Assert-Equal $missingDuration.Windows[0].Label 'Unknown-duration window' `
    'NULL_DURATION_LABEL'

$clamped = ConvertTo-QiehaoQuotaSnapshot -Result (
    New-FakeResult `
        -Primary (New-FakeWindow -UsedPercent 125 -DurationMinutes 60 -ResetsAt $null) `
        -Secondary (New-FakeWindow -UsedPercent -20 -DurationMinutes 90 -ResetsAt $null)
)
Assert-Equal $clamped.Windows[0].RemainingPercent 0 'CLAMP_LOW'
Assert-Equal $clamped.Windows[1].RemainingPercent 100 'CLAMP_HIGH'

$empty = ConvertTo-QiehaoQuotaSnapshot -Result (
    New-FakeResult -Primary $null -Secondary $null
)
Assert-True ($empty.Windows -is [object[]]) 'EMPTY_WINDOWS_ARRAY_TYPE'
Assert-Equal $empty.Windows.Count 0 'EMPTY_WINDOWS_COUNT'

$preferred = New-FakeResult -Primary $fiveHour -Secondary $weekly `
    -OrdinaryUsageAllowed $true -PlanType 'plus'
$preferred.rateLimitsByLimitId = [pscustomobject]@{
    other = [pscustomobject]@{
        planType = 'free'
        primary = New-FakeWindow -UsedPercent 99 -DurationMinutes 15 -ResetsAt $null
        secondary = $null
    }
    codex = [pscustomobject]@{
        planType = 'team'
        primary = New-FakeWindow -UsedPercent 25 -DurationMinutes 120 -ResetsAt $null
        secondary = $null
    }
}
$preferredSnapshot = ConvertTo-QiehaoQuotaSnapshot -Result $preferred
Assert-Equal $preferredSnapshot.Plan 'team' 'CODEX_BUCKET_PLAN'
Assert-Equal $preferredSnapshot.Windows.Count 1 'CODEX_BUCKET_NO_DUPLICATE'
Assert-Equal $preferredSnapshot.Windows[0].DurationMinutes 120 'CODEX_BUCKET_PRIORITY'

$fallbackSnapshot = ConvertTo-QiehaoQuotaSnapshot -Result (
    New-FakeResult -Primary $fiveHour -Secondary $null -PlanType 'plus'
)
Assert-Equal $fallbackSnapshot.Plan 'plus' 'LEGACY_BUCKET_FALLBACK'

$sanitizedJson = $preferredSnapshot | ConvertTo-Json -Depth 8 -Compress
foreach ($forbidden in @(
    'FAKE-ACCOUNT-ID-MUST-NOT-LEAK',
    'fake-secret@example.invalid',
    'FAKE-TOKEN-MUST-NOT-LEAK',
    'accountId',
    'email',
    'token'
)) {
    Assert-True (-not $sanitizedJson.Contains($forbidden)) `
        ('SANITIZED_OUTPUT_' + $forbidden)
}

Write-Output 'FAKE_PARSE_OK'
