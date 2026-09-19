[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Normal', 'NeverExit', 'PrimaryTimeoutNeverExit')]
    [string]$Scenario,

    [ValidateRange(0, 10000)]
    [int]$ResponseDelayMilliseconds = 0,

    [ValidateRange(0, 10000)]
    [int]$ExitDelayMilliseconds = 0,

    [AllowNull()][string]$PidFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

if (-not [string]::IsNullOrWhiteSpace($PidFile)) {
    [System.IO.File]::WriteAllText(
        $PidFile,
        [string]$PID,
        (New-Object System.Text.UTF8Encoding($false))
    )
}

function Write-FakeJsonLine {
    param([Parameter(Mandatory = $true)][object]$Value)
    $line = $Value | ConvertTo-Json -Depth 12 -Compress
    [Console]::Out.WriteLine($line)
    [Console]::Out.Flush()
}

while ($true) {
    $line = [Console]::In.ReadLine()
    if ($null -eq $line) { break }

    try {
        $message = $line | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        exit 2
    }
    $methodProperty = $message.PSObject.Properties['method']
    if ($null -eq $methodProperty) { continue }
    $method = [string]$methodProperty.Value

    if ($method -ceq 'initialize') {
        $idProperty = $message.PSObject.Properties['id']
        if ($null -eq $idProperty) { exit 3 }
        Write-FakeJsonLine -Value ([ordered]@{
            id = $idProperty.Value
            result = [ordered]@{}
        })
        continue
    }

    if ($method -ceq 'initialized') { continue }

    if ($method -ceq 'account/rateLimits/read') {
        if ($Scenario -ceq 'PrimaryTimeoutNeverExit') {
            continue
        }
        if ($ResponseDelayMilliseconds -gt 0) {
            Start-Sleep -Milliseconds $ResponseDelayMilliseconds
        }
        $idProperty = $message.PSObject.Properties['id']
        if ($null -eq $idProperty) { exit 4 }
        Write-FakeJsonLine -Value ([ordered]@{
            id = $idProperty.Value
            result = [ordered]@{
                rateLimits = [ordered]@{
                    planType = 'team'
                    primary = [ordered]@{
                        usedPercent = 58
                        windowDurationMins = 300
                        resetsAt = 1893542400
                    }
                    secondary = [ordered]@{
                        usedPercent = 72
                        windowDurationMins = 10080
                        resetsAt = 1893628800
                    }
                }
                ordinaryUsageAllowed = $true
            }
        })
    }
}

if ($Scenario -in @('NeverExit', 'PrimaryTimeoutNeverExit')) {
    while ($true) {
        Start-Sleep -Seconds 60
    }
}

if ($ExitDelayMilliseconds -gt 0) {
    Start-Sleep -Milliseconds $ExitDelayMilliseconds
}
exit 0
