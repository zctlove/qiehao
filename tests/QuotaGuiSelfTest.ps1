[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path -Path $projectRoot -ChildPath 'gui\QuotaHelpers.psm1'
$guiScriptPath = Join-Path -Path $projectRoot -ChildPath 'gui\QiehaoGui.ps1'
$clientPath = Join-Path -Path $projectRoot -ChildPath 'tools\QuotaClient.psm1'
$xamlPath = Join-Path -Path $projectRoot -ChildPath 'gui\MainWindow.xaml'
$gitIgnorePath = Join-Path -Path $projectRoot -ChildPath '.gitignore'
Import-Module -Name $modulePath -Force -ErrorAction Stop

function Assert-QuotaTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Code
    )
    if (-not $Condition) { throw $Code }
}

function New-FakeQuotaSnapshot {
    param(
        [long[]]$Durations = @(),
        [double[]]$Remaining = @(),
        [AllowNull()][object]$OrdinaryUsageAllowed = $true,
        [string]$Plan = 'plus'
    )
    if ($Durations.Count -ne $Remaining.Count) {
        throw 'FAKE_QUOTA_LENGTH_MISMATCH'
    }
    $windows = New-Object 'System.Collections.Generic.List[object]'
    for ($index = 0; $index -lt $Durations.Count; $index++) {
        $null = $windows.Add([pscustomobject]@{
            DurationMinutes = $Durations[$index]
            Label = 'IGNORED-FAKE-LABEL'
            RemainingPercent = $Remaining[$index]
            ResetsAt = 1893542400 + ($index * 3600)
            ResetLocal = 'IGNORED'
        })
    }
    return [pscustomobject]@{
        Plan = $Plan
        OrdinaryUsageAllowed = $OrdinaryUsageAllowed
        Windows = $windows.ToArray()
        accountId = 'FAKE-ACCOUNT-ID-MUST-NOT-PERSIST'
        email = 'fake@example.invalid'
        token = 'FAKE-TOKEN-MUST-NOT-PERSIST'
    }
}

$testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath (
    'qiehao-quota-selftest-' + [Guid]::NewGuid().ToString('N')
)
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null

try {
    $cache = New-QiehaoEmptyQuotaCache
    $coordinator = New-QiehaoQuotaCoordinatorState
    $calls = New-Object 'System.Collections.Generic.List[string]'
    $openSnapshot = New-FakeQuotaSnapshot -Durations @(300, 10080) `
        -Remaining @(84, 61)
    $openResult = Invoke-QiehaoQuotaCacheRefresh -Reason Open `
        -Coordinator $coordinator -StateDirectory $testRoot -Cache $cache `
        -ActiveProfile 'Plus' -SelectedProfile 'Team' `
        -QuotaProvider ({
            param($Profile)
            $null = $calls.Add($Profile)
            [pscustomobject]@{
                Succeeded = $true
                FailureCode = $null
                Snapshot = $openSnapshot
            }
        }.GetNewClosure()) `
        -QueriedAt ([DateTimeOffset]::Parse('2030-01-01T00:00:00Z'))
    Assert-QuotaTest ($openResult.Succeeded -and $calls.Count -eq 1 -and
        $calls[0] -ceq 'Plus') ('QUOTA_OPEN_ACTIVE_ONLY_FAILED:' +
            [string]$openResult.FailureCode + ':' + [string]$calls.Count)
    $cache = $openResult.Cache

    $secondOpen = Invoke-QiehaoQuotaCacheRefresh -Reason Open `
        -Coordinator $coordinator -StateDirectory $testRoot -Cache $cache `
        -ActiveProfile 'Plus' -SelectedProfile 'Team' `
        -QuotaProvider { throw 'PROVIDER_MUST_NOT_RUN' }
    Assert-QuotaTest (-not $secondOpen.ProviderCalled -and
        $secondOpen.FailureCode -ceq 'QUOTA_STARTUP_ALREADY_ATTEMPTED') `
        'QUOTA_OPEN_ONCE_FAILED'

    $persisted = Read-QiehaoQuotaCache -StateDirectory $testRoot
    $persistedPlus = Get-QiehaoQuotaCacheSnapshot `
        -Cache $persisted.Cache -ProfileName 'Plus'
    Assert-QuotaTest ($persisted.IsValid -and
        @($persistedPlus.windows).Count -eq 2) 'QUOTA_RESTART_PERSIST_FAILED'
    Assert-QuotaTest (
        @(Get-ChildItem -LiteralPath $testRoot -Filter '*.tmp').Count -eq 0
    ) 'QUOTA_ATOMIC_TEMP_LEFTOVER'

    $beforeFailure = [System.IO.File]::ReadAllText($persisted.Path)
    $failedUpdate = Invoke-QiehaoQuotaCacheRefresh -Reason Manual `
        -Coordinator $coordinator -StateDirectory $testRoot `
        -Cache $persisted.Cache -ActiveProfile 'Plus' -SelectedProfile 'Team' `
        -QuotaProvider {
            [pscustomobject]@{
                Succeeded = $false
                FailureCode = 'FAKE_TIMEOUT'
                Snapshot = $null
            }
        }
    $afterFailure = [System.IO.File]::ReadAllText($persisted.Path)
    Assert-QuotaTest (-not $failedUpdate.Succeeded -and
        $beforeFailure -ceq $afterFailure) 'QUOTA_FAILURE_OVERWROTE_CACHE'

    $manualCalls = New-Object 'System.Collections.Generic.List[string]'
    $manualResult = Invoke-QiehaoQuotaCacheRefresh -Reason Manual `
        -Coordinator $coordinator -StateDirectory $testRoot `
        -Cache $persisted.Cache -ActiveProfile 'Plus' -SelectedProfile 'Team' `
        -QuotaProvider ({
            param($Profile)
            $null = $manualCalls.Add($Profile)
            [pscustomobject]@{
                Succeeded = $true
                FailureCode = $null
                Snapshot = $openSnapshot
            }
        }.GetNewClosure())
    Assert-QuotaTest ($manualResult.Succeeded -and
        $manualCalls.Count -eq 1 -and $manualCalls[0] -ceq 'Plus') `
        'QUOTA_MANUAL_SELECTED_INACTIVE_QUERIED'

    $coordinator.QueryInProgress = $true
    $blockedCalls = 0
    $blocked = Invoke-QiehaoQuotaCacheRefresh -Reason Manual `
        -Coordinator $coordinator -StateDirectory $testRoot `
        -Cache $manualResult.Cache -ActiveProfile 'Plus' -SelectedProfile 'Plus' `
        -QuotaProvider ({ $script:blockedCalls++ }.GetNewClosure())
    $coordinator.QueryInProgress = $false
    Assert-QuotaTest (-not $blocked.ProviderCalled -and
        $blocked.FailureCode -ceq 'QUOTA_QUERY_IN_PROGRESS') `
        'QUOTA_DOUBLE_REFRESH_NOT_BLOCKED'

    $dynamicSnapshot = New-FakeQuotaSnapshot `
        -Durations @(60, 120, 180) -Remaining @(90, 80, 70)
    $dynamicSave = Save-QiehaoQuotaSnapshot -StateDirectory $testRoot `
        -Cache $manualResult.Cache -ProfileName 'Team' `
        -Snapshot $dynamicSnapshot `
        -QueriedAt ([DateTimeOffset]::Parse('2030-01-02T00:00:00Z'))
    Assert-QuotaTest $dynamicSave.Succeeded 'QUOTA_DYNAMIC_SAVE_FAILED'
    $rows = @(
        [pscustomobject]@{ Name = 'Plus'; Active = '是' },
        [pscustomobject]@{ Name = 'Team'; Active = '否' }
    )
    $rows = @(Update-QiehaoQuotaProfileRows -Rows $rows `
        -Cache $dynamicSave.Cache -ActiveProfile 'Plus' `
        -Now ([DateTimeOffset]::Parse('2030-01-02T01:00:00Z')))
    $teamRow = @($rows | Where-Object { $_.Name -ceq 'Team' })[0]
    $dynamicLines = @(([string]$teamRow.QuotaSummary) -split [Environment]::NewLine)
    Assert-QuotaTest ($dynamicLines.Count -eq 3 -and
        $teamRow.QuotaSummary -notmatch '5h|Week') `
        'QUOTA_DYNAMIC_WINDOWS_OR_FAKE_STANDARD_WINDOW'
    Assert-QuotaTest ($teamRow.QuotaToolTip -match '上次') `
        'QUOTA_INACTIVE_TOOLTIP_MISSING'

    $singleSave = Save-QiehaoQuotaSnapshot -StateDirectory $testRoot `
        -Cache $dynamicSave.Cache -ProfileName 'Single' `
        -Snapshot (New-FakeQuotaSnapshot -Durations @(43200) -Remaining @(55))
    $emptySave = Save-QiehaoQuotaSnapshot -StateDirectory $testRoot `
        -Cache $singleSave.Cache -ProfileName 'Empty' `
        -Snapshot (New-FakeQuotaSnapshot -Durations @() -Remaining @())
    Assert-QuotaTest (
        @((Get-QiehaoQuotaCacheSnapshot -Cache $emptySave.Cache `
            -ProfileName 'Single').windows).Count -eq 1 -and
        @((Get-QiehaoQuotaCacheSnapshot -Cache $emptySave.Cache `
            -ProfileName 'Empty').windows).Count -eq 0
    ) 'QUOTA_SINGLE_OR_EMPTY_WINDOWS_FAILED'

    $order = New-Object 'System.Collections.Generic.List[string]'
    $switchBefore = Invoke-QiehaoQuotaCacheRefresh -Reason SwitchBefore `
        -Coordinator $coordinator -StateDirectory $testRoot `
        -Cache $emptySave.Cache -ActiveProfile 'Plus' -SelectedProfile 'Team' `
        -QuotaProvider ({
            param($Profile)
            $null = $order.Add('Quota:' + $Profile)
            [pscustomobject]@{
                Succeeded = $true
                FailureCode = $null
                Snapshot = $openSnapshot
            }
        }.GetNewClosure())
    $null = $order.Add('Switch')
    Assert-QuotaTest ($switchBefore.Succeeded -and
        (@($order) -join '|') -ceq 'Quota:Plus|Switch' -and
        $null -ne (Get-QiehaoQuotaCacheSnapshot `
            -Cache $switchBefore.Cache -ProfileName 'Plus')) `
        'QUOTA_SWITCH_BEFORE_COMMIT_ORDER_FAILED'

    $switchCalls = 0
    $switchBeforeFailure = Invoke-QiehaoQuotaCacheRefresh `
        -Reason SwitchBefore -Coordinator $coordinator `
        -StateDirectory $testRoot -Cache $switchBefore.Cache `
        -ActiveProfile 'Plus' -SelectedProfile 'Team' `
        -QuotaProvider {
            [pscustomobject]@{
                Succeeded = $false
                FailureCode = 'FAKE_TIMEOUT'
                Snapshot = $null
            }
        }
    $switchCalls++
    Assert-QuotaTest (-not $switchBeforeFailure.Succeeded -and
        $switchCalls -eq 1) 'QUOTA_SWITCH_BLOCKED_BY_FAILURE'

    $postCalls = New-Object 'System.Collections.Generic.List[string]'
    $postSuccess = Invoke-QiehaoQuotaCacheRefresh -Reason SwitchAfter `
        -Coordinator $coordinator -StateDirectory $testRoot `
        -Cache $switchBefore.Cache -ActiveProfile 'Team' -SelectedProfile 'Plus' `
        -QuotaProvider ({
            param($Profile)
            $null = $postCalls.Add($Profile)
            [pscustomobject]@{
                Succeeded = $true
                FailureCode = $null
                Snapshot = $dynamicSnapshot
            }
        }.GetNewClosure())
    Assert-QuotaTest ($postSuccess.Succeeded -and
        $postCalls.Count -eq 1 -and $postCalls[0] -ceq 'Team') `
        'QUOTA_SWITCH_AFTER_NEW_ACTIVE_FAILED'
    $switchSucceeded = $true
    $postFailure = Invoke-QiehaoQuotaCacheRefresh -Reason SwitchAfter `
        -Coordinator $coordinator -StateDirectory $testRoot `
        -Cache $postSuccess.Cache -ActiveProfile 'Team' -SelectedProfile 'Team' `
        -QuotaProvider {
            [pscustomobject]@{
                Succeeded = $false
                FailureCode = 'FAKE_FAILURE'
                Snapshot = $null
            }
        }
    Assert-QuotaTest ($switchSucceeded -and -not $postFailure.Succeeded) `
        'QUOTA_POST_SWITCH_FAILURE_CHANGED_SWITCH'

    $renameResult = Rename-QiehaoQuotaCacheProfile `
        -StateDirectory $testRoot -Cache $postSuccess.Cache `
        -OldName 'Plus' -NewName 'Personal'
    Assert-QuotaTest ($renameResult.Succeeded -and
        $null -eq (Get-QiehaoQuotaCacheSnapshot `
            -Cache $renameResult.Cache -ProfileName 'Plus') -and
        $null -ne (Get-QiehaoQuotaCacheSnapshot `
            -Cache $renameResult.Cache -ProfileName 'Personal')) `
        'QUOTA_RENAME_MIGRATION_FAILED'

    $teamBeforeDelete = Get-QiehaoQuotaCacheSnapshot `
        -Cache $renameResult.Cache -ProfileName 'Team'
    $deleteResult = Remove-QiehaoQuotaCacheProfile `
        -StateDirectory $testRoot -Cache $renameResult.Cache `
        -ProfileName 'Personal'
    Assert-QuotaTest ($deleteResult.Succeeded -and
        $null -eq (Get-QiehaoQuotaCacheSnapshot `
            -Cache $deleteResult.Cache -ProfileName 'Personal') -and
        $null -ne $teamBeforeDelete -and
        $null -ne (Get-QiehaoQuotaCacheSnapshot `
            -Cache $deleteResult.Cache -ProfileName 'Team')) `
        'QUOTA_DELETE_SCOPE_FAILED'

    $cacheJson = $deleteResult.Cache | ConvertTo-Json -Depth 12 -Compress
    foreach ($forbidden in @(
        'FAKE-ACCOUNT-ID-MUST-NOT-PERSIST',
        'fake@example.invalid',
        'FAKE-TOKEN-MUST-NOT-PERSIST',
        'accountId',
        'email',
        'token',
        'auth',
        'cookie'
    )) {
        Assert-QuotaTest (-not $cacheJson.ToLowerInvariant().Contains(
            $forbidden.ToLowerInvariant()
        )) ('QUOTA_CACHE_SENSITIVE_FIELD_' + $forbidden)
    }

    [System.IO.File]::WriteAllText(
        (Join-Path $testRoot 'quota-cache.json'),
        '{"schema_version":999,"profiles":{"Bad":{"token":"SECRET"}}}'
    )
    $corrupt = Read-QiehaoQuotaCache -StateDirectory $testRoot
    Assert-QuotaTest (-not $corrupt.IsValid -and $corrupt.UsedEmpty -and
        @($corrupt.Cache.profiles.Keys).Count -eq 0
    ) 'QUOTA_CORRUPT_CACHE_NOT_SAFE'

    $guiSource = [System.IO.File]::ReadAllText($guiScriptPath)
    $processTimerSection = [regex]::Match(
        $guiSource,
        '(?s)function Start-QiehaoProcessMonitor.*?function Stop-QiehaoLaunchWaitTimer'
    ).Value
    $waitTimerSection = [regex]::Match(
        $guiSource,
        '(?s)function Start-QiehaoManualSwitchWaitTimer.*?function Cancel-QiehaoManualSwitchWait'
    ).Value
    Assert-QuotaTest (
        $processTimerSection -notmatch 'Quota' -and
        $waitTimerSection -notmatch 'Quota'
    ) 'QUOTA_LEAKED_INTO_PROCESS_TIMERS'
    Assert-QuotaTest (
        $guiSource -notmatch 'account/rateLimits/read' -and
        $guiSource -match 'Get-QiehaoCurrentQuotaSnapshot' -and
        $guiSource -match 'Start-QiehaoQuotaAsync -Reason Open' -and
        $guiSource -match 'Start-QiehaoQuotaAsync -Reason SwitchAfter'
    ) 'QUOTA_GUI_RPC_ENCAPSULATION_FAILED'
    $clientSource = [System.IO.File]::ReadAllText($clientPath)
    Assert-QuotaTest (
        [regex]::Matches($clientSource, 'account/rateLimits/read').Count -eq 1 -and
        $clientSource -match '\[int\]\$TimeoutSeconds = 10' -and
        $clientSource -notmatch 'WaitForExit\(10000\)|WaitForExit\(5000\)' -and
        $clientSource -match 'remainingCleanupMilliseconds' -and
        $clientSource -notmatch 'supportsLunaReserve|Invoke-WebRequest|Invoke-RestMethod|HttpClient|Authorization'
    ) 'QUOTA_CLIENT_SAFETY_CONTRACT_FAILED'

    $xaml = [System.IO.File]::ReadAllText($xamlPath)
    Assert-QuotaTest ($xaml -match 'x:Name="QuotaColumn"' -and
        $xaml -match 'x:Name="RefreshQuotaButton"') `
        'QUOTA_UI_CONTROLS_MISSING'
    $gitIgnore = [System.IO.File]::ReadAllText($gitIgnorePath)
    Assert-QuotaTest ($gitIgnore -match '(?m)^state/\*$') `
        'QUOTA_CACHE_NOT_GIT_IGNORED'

    [pscustomobject]@{
        Result = 'PASS'
        GuiOpenActiveOnly = 'PASS'
        GuiOpenOnce = 'PASS'
        InactiveNeverQueried = 'PASS'
        SuccessAtomicUpdate = 'PASS'
        FailurePreservesOld = 'PASS'
        DynamicOneTwoThreeUnknown = 'PASS'
        NoSyntheticFiveHourOrWeekly = 'PASS'
        SwitchBeforeCommit = 'PASS'
        SwitchBeforeFailureNonBlocking = 'PASS'
        SwitchAfterNewActive = 'PASS'
        PostSwitchFailureNonBlocking = 'PASS'
        ManualCurrentOnly = 'PASS'
        DoubleRefreshBlocked = 'PASS'
        RestartPersistence = 'PASS'
        RenameMigration = 'PASS'
        DeleteScoped = 'PASS'
        CorruptCacheFallback = 'PASS'
        SensitiveFieldsExcluded = 'PASS'
        ProcessTimersIsolated = 'PASS'
    }
    Write-Output 'QUOTA_GUI_SELFTEST_PASS'
}
finally {
    if ([System.IO.Directory]::Exists($testRoot)) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
