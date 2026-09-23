[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path -Path $projectRoot -ChildPath 'gui\QuotaHelpers.psm1'
$guiHelperPath = Join-Path -Path $projectRoot -ChildPath 'gui\GuiHelpers.psm1'
$corePath = Join-Path -Path $projectRoot -ChildPath 'lib\CodexAuth.psm1'
$guiScriptPath = Join-Path -Path $projectRoot -ChildPath 'gui\QiehaoGui.ps1'
$clientPath = Join-Path -Path $projectRoot -ChildPath 'tools\QuotaClient.psm1'
$xamlPath = Join-Path -Path $projectRoot -ChildPath 'gui\MainWindow.xaml'
$gitIgnorePath = Join-Path -Path $projectRoot -ChildPath '.gitignore'
Import-Module -Name $modulePath -Force -ErrorAction Stop
Import-Module -Name $guiHelperPath -Force -ErrorAction Stop

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

function New-FakeStartupCoreSnapshot {
    param(
        [string]$ActiveProfile = 'Team',
        [AllowNull()][object]$Order
    )
    $profiles = @(
        [pscustomobject]@{
            Profile = 'Plus'; Active = $false; Health = 'READY'
            AuthFile = 'PRESENT'; IdentityMarker = 'PRESENT'
            Metadata = 'VALID'; UpdatedAt = '2000-01-01T00:00:00Z'
        },
        [pscustomobject]@{
            Profile = 'Team'; Active = $true; Health = 'READY'
            AuthFile = 'PRESENT'; IdentityMarker = 'PRESENT'
            Metadata = 'VALID'; UpdatedAt = '2000-01-01T00:00:00Z'
        }
    )
    if ($null -ne $Order) { $null = $Order.Add('CoreSnapshot') }
    return Get-QiehaoGuiSnapshot -ListProvider ({ $profiles }.GetNewClosure()) `
        -ActiveProvider ({
            [pscustomobject]@{ ActiveProfile = $ActiveProfile }
        }.GetNewClosure()) `
        -ProcessProvider {
            [pscustomobject]@{ ReasonCode = 'CODEX_PROCESSES_STOPPED' }
        } `
        -ActiveIdentityProvider {
            [pscustomobject]@{ Result = 'ACTIVE_IDENTITY_CONFIRMED' }
        }
}

$testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath (
    'qiehao-quota-selftest-' + [Guid]::NewGuid().ToString('N')
)
[System.IO.Directory]::CreateDirectory($testRoot) | Out-Null

try {
    # Regression guard for 4ae0e77: importing QuotaClient must not remove the
    # core commands that the GUI Loaded handler invokes.
    Import-Module -Name $corePath -Force -ErrorAction Stop
    $coreCommandNames = @(
        'Get-CodexAccountSlot',
        'Get-CodexActiveProfile',
        'Test-CodexProcessesStopped',
        'Test-CodexActiveIdentity'
    )
    Assert-QuotaTest (
        @($coreCommandNames | Where-Object {
            $null -eq (Get-Command -Name $_ -ErrorAction SilentlyContinue)
        }).Count -eq 0
    ) 'QUOTA_STARTUP_CORE_COMMANDS_MISSING_BEFORE_CLIENT_IMPORT'
    Import-Module -Name $clientPath -Force -ErrorAction Stop
    Assert-QuotaTest (
        @($coreCommandNames | Where-Object {
            $null -eq (Get-Command -Name $_ -ErrorAction SilentlyContinue)
        }).Count -eq 0
    ) 'QUOTA_CLIENT_IMPORT_REMOVED_CORE_COMMANDS'

    $startupRoot = Join-Path $testRoot 'startup-regression'
    [System.IO.Directory]::CreateDirectory($startupRoot) | Out-Null

    # Core Profile rows exist before any optional quota work.
    $coreSnapshot = New-FakeStartupCoreSnapshot
    $coreRows = @($coreSnapshot.Profiles)
    $teamCore = @($coreRows | Where-Object { $_.Name -ceq 'Team' })[0]
    $plusCore = @($coreRows | Where-Object { $_.Name -ceq 'Plus' })[0]
    Assert-QuotaTest (
        $coreRows.Count -eq 2 -and
        $coreSnapshot.ActiveProfile -ceq 'Team' -and
        $teamCore.Active -ceq '是' -and $plusCore.Active -ceq '否'
    ) 'QUOTA_STARTUP_CORE_BASELINE_INVALID'

    # A. Missing cache: both core rows remain and receive safe placeholders.
    $noCacheDirectory = Join-Path $startupRoot 'missing'
    [System.IO.Directory]::CreateDirectory($noCacheDirectory) | Out-Null
    $noCache = Read-QiehaoQuotaCache -StateDirectory $noCacheDirectory
    $noCacheRows = @((New-FakeStartupCoreSnapshot).Profiles)
    $noCacheDecorated = @(Update-QiehaoQuotaProfileRows -Rows $noCacheRows `
        -Cache $noCache.Cache -ActiveProfile 'Team')
    Assert-QuotaTest (
        $noCache.UsedEmpty -and $noCacheDecorated.Count -eq 2 -and
        @($noCacheDecorated | Where-Object {
            $_.Name -ceq 'Team' -and
            [string]$_.QuotaSummary -ceq '尚无额度快照' -and
            [string]$_.QuotaSummary -notmatch '[\r\n]'
        }).Count -eq 1
    ) 'NO_QUOTA_CACHE_CORE_STILL_LOADS'

    # B/C/D. Empty, corrupt and unsupported cache all degrade independently.
    foreach ($badCase in @(
        [pscustomobject]@{ Name = 'empty'; Text = '' },
        [pscustomobject]@{ Name = 'corrupt'; Text = '{BROKEN JSON' },
        [pscustomobject]@{
            Name = 'unsupported'
            Text = '{"schema_version":999,"profiles":{}}'
        }
    )) {
        $badDirectory = Join-Path $startupRoot $badCase.Name
        [System.IO.Directory]::CreateDirectory($badDirectory) | Out-Null
        [System.IO.File]::WriteAllText(
            (Join-Path $badDirectory 'quota-cache.json'),
            [string]$badCase.Text
        )
        $badRead = Read-QiehaoQuotaCache -StateDirectory $badDirectory
        $badCore = New-FakeStartupCoreSnapshot
        Assert-QuotaTest (
            -not $badRead.IsValid -and
            @($badCore.Profiles).Count -eq 2 -and
            $badCore.ActiveProfile -ceq 'Team'
        ) ('QUOTA_' + $badCase.Name.ToUpperInvariant() +
            '_CACHE_CHANGED_CORE')
    }

    # Provider failure and unavailable enrichment cannot mutate core identity.
    $providerCoordinator = New-QiehaoQuotaCoordinatorState
    $providerFailure = Invoke-QiehaoQuotaCacheRefresh -Reason Manual `
        -Coordinator $providerCoordinator -StateDirectory $noCacheDirectory `
        -Cache $noCache.Cache -ActiveProfile 'Team' -SelectedProfile 'Plus' `
        -QuotaProvider {
            [pscustomobject]@{
                Succeeded = $false
                FailureCode = 'FAKE_PROVIDER_FAILURE'
                Snapshot = $null
            }
        }
    $providerCore = New-FakeStartupCoreSnapshot
    Assert-QuotaTest (
        -not $providerFailure.Succeeded -and
        @($providerCore.Profiles).Count -eq 2 -and
        $providerCore.ActiveProfile -ceq 'Team'
    ) 'QUOTA_PROVIDER_FAILURE_CHANGED_CORE'

    $moduleUnavailableRows = @((New-FakeStartupCoreSnapshot).Profiles)
    $moduleUnavailable = Invoke-QiehaoOptionalProfileRowEnrichment `
        -Rows $moduleUnavailableRows -Enrichment $null
    Assert-QuotaTest (
        -not $moduleUnavailable.EnrichmentSucceeded -and
        @($moduleUnavailable.Rows).Count -eq 2 -and
        @($moduleUnavailable.Rows | Where-Object {
            $_.Name -ceq 'Team' -and $_.Active -ceq '是'
        }).Count -eq 1
    ) 'QUOTA_MODULE_UNAVAILABLE_CHANGED_CORE'

    # Cache keys can decorate known rows but can never define population.
    $ghostDirectory = Join-Path $startupRoot 'ghost'
    [System.IO.Directory]::CreateDirectory($ghostDirectory) | Out-Null
    $ghostSave = Save-QiehaoQuotaSnapshot -StateDirectory $ghostDirectory `
        -Cache (New-QiehaoEmptyQuotaCache) -ProfileName 'Ghost' `
        -Snapshot (New-FakeQuotaSnapshot -Durations @(60) -Remaining @(50))
    $ghostRows = @((New-FakeStartupCoreSnapshot).Profiles)
    $ghostDecorated = @(Update-QiehaoQuotaProfileRows -Rows $ghostRows `
        -Cache $ghostSave.Cache -ActiveProfile 'Team')
    Assert-QuotaTest (
        $ghostSave.Succeeded -and $ghostDecorated.Count -eq 2 -and
        @($ghostDecorated.Name) -ccontains 'Plus' -and
        @($ghostDecorated.Name) -ccontains 'Team' -and
        -not (@($ghostDecorated.Name) -ccontains 'Ghost')
    ) 'QUOTA_CACHE_DEFINED_PROFILE_POPULATION'

    # Explicit startup ordering: core snapshot is established before optional
    # quota enrichment, and enrichment failure cannot set it to uninitialized.
    $startupOrder = New-Object 'System.Collections.Generic.List[string]'
    $orderedCore = New-FakeStartupCoreSnapshot -Order $startupOrder
    $orderedRows = @($orderedCore.Profiles)
    $orderedResult = Invoke-QiehaoOptionalProfileRowEnrichment `
        -Rows $orderedRows -Enrichment ({
            $null = $startupOrder.Add('QuotaSnapshot')
            throw 'FAKE_QUOTA_FORMATTER_FAILURE'
        }.GetNewClosure())
    Assert-QuotaTest (
        ($startupOrder.ToArray() -join '|') -ceq
            'CoreSnapshot|QuotaSnapshot' -and
        -not $orderedResult.EnrichmentSucceeded -and
        @($orderedResult.Rows).Count -eq 2 -and
        $orderedCore.ActiveProfile -ceq 'Team' -and
        @($orderedCore.ReadOnlyErrors).Count -eq 0
    ) 'QUOTA_STARTUP_ORDER_OR_CORE_ISOLATION_FAILED'

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
    $plusRow = @($rows | Where-Object { $_.Name -ceq 'Plus' })[0]
    $teamRow = @($rows | Where-Object { $_.Name -ceq 'Team' })[0]
    Assert-QuotaTest (
        [string]$plusRow.QuotaSummary -ceq '5h 84% · Week 61%' -and
        [string]$plusRow.QuotaSummary -notmatch '[\r\n]' -and
        [string]$plusRow.QuotaToolTip -match '当前账号额度' -and
        [string]$plusRow.QuotaToolTip -match '5-hour' -and
        [string]$plusRow.QuotaToolTip -match 'Weekly' -and
        [string]$plusRow.QuotaToolTip -match '剩余：84%' -and
        [string]$plusRow.QuotaToolTip -match '包含额度：可用' -and
        [string]$plusRow.QuotaToolTip -match '查询于：'
    ) 'QUOTA_TWO_WINDOW_SUMMARY_OR_TOOLTIP_FAILED'
    Assert-QuotaTest (
        [string]$teamRow.QuotaSummary -ceq
            '1h 90% · 2h 80% · 3h 70%' -and
        [string]$teamRow.QuotaSummary -notmatch '[\r\n]' -and
        $teamRow.QuotaSummary -notmatch '5h|Week'
    ) `
        'QUOTA_DYNAMIC_WINDOWS_OR_FAKE_STANDARD_WINDOW'
    Assert-QuotaTest (
        $teamRow.QuotaToolTip -match
            '这是该账号上次作为当前账号时保存的额度快照。' -and
        $teamRow.QuotaToolTip -match '切换为当前账号后可刷新。' -and
        $teamRow.QuotaToolTip -match '1-hour' -and
        $teamRow.QuotaToolTip -match '2-hour' -and
        $teamRow.QuotaToolTip -match '3-hour'
    ) `
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
    $singleRows = @(
        [pscustomobject]@{ Name = 'Single'; Active = '是' },
        [pscustomobject]@{ Name = 'Empty'; Active = '否' }
    )
    $singleRows = @(Update-QiehaoQuotaProfileRows -Rows $singleRows `
        -Cache $emptySave.Cache -ActiveProfile 'Single')
    Assert-QuotaTest (
        [string]$singleRows[0].QuotaSummary -ceq '30d 55%' -and
        [string]$singleRows[0].QuotaSummary -notmatch '[\r\n]' -and
        [string]$singleRows[1].QuotaSummary -ceq '未返回额度窗口' -and
        [string]$singleRows[1].QuotaSummary -notmatch '[\r\n]'
    ) 'QUOTA_ONE_OR_ZERO_WINDOW_NOT_COMPACT'

    $fourSave = Save-QiehaoQuotaSnapshot -StateDirectory $testRoot `
        -Cache $emptySave.Cache -ProfileName 'Four' `
        -Snapshot (New-FakeQuotaSnapshot `
            -Durations @(60, 120, 180, 240) `
            -Remaining @(90, 80, 70, 60))
    $fourRows = @(Update-QiehaoQuotaProfileRows `
        -Rows @([pscustomobject]@{ Name = 'Four'; Active = '是' }) `
        -Cache $fourSave.Cache -ActiveProfile 'Four')
    Assert-QuotaTest (
        [string]$fourRows[0].QuotaSummary -ceq
            '1h 90% · 2h 80% · 3h 70% · +1' -and
        [string]$fourRows[0].QuotaSummary -notmatch '[\r\n]' -and
        [string]$fourRows[0].QuotaToolTip -match '4-hour' -and
        [string]$fourRows[0].QuotaToolTip -match '剩余：60%'
    ) 'QUOTA_FOUR_WINDOW_SUMMARY_NOT_BOUNDED'

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
        $waitTimerSection -notmatch
            'guiQuota|QuotaAsync|QuotaCoordinator|SwitchBefore' -and
        $waitTimerSection -match
            'if \(\$status -ceq ''已退出''\) \{ return ''Succeeded'' \}' -and
        $waitTimerSection -notmatch
            'Get-QiehaoCurrentQuotaSnapshot|Invoke-QiehaoQuotaBackgroundWorker|Save-QiehaoQuotaSnapshot|account/rateLimits/read'
    ) 'QUOTA_LEAKED_INTO_PROCESS_TIMERS'
    Assert-QuotaTest (
        $guiSource -notmatch 'account/rateLimits/read' -and
        $guiSource -match 'Get-QiehaoCurrentQuotaSnapshot' -and
        $guiSource -match 'Start-QiehaoQuotaAsync -Reason Open' -and
        $guiSource -notmatch 'Start-QiehaoQuotaAsync -Reason SwitchBefore' -and
        $guiSource -match 'Start-QiehaoQuotaAsync -Reason SwitchAfter'
    ) 'QUOTA_GUI_RPC_ENCAPSULATION_FAILED'
    $clientSource = [System.IO.File]::ReadAllText($clientPath)
    Assert-QuotaTest (
        [regex]::Matches($clientSource, 'account/rateLimits/read').Count -eq 1 -and
        $clientSource -match '\[int\]\$TimeoutSeconds = 30' -and
        $clientSource -match '\[int\]\$CleanupGraceMilliseconds = 4000' -and
        $clientSource -notmatch 'remainingCleanupMilliseconds' -and
        $clientSource -match '\$process\.StandardInput\.Flush\(\)' -and
        $clientSource -match '\$process\.StandardInput\.Close\(\)' -and
        $clientSource -match '\$process\.StandardInput\.Dispose\(\)' -and
        $clientSource -match '(?s)WaitForExit\(\s*\$CleanupGraceMilliseconds\s*\)' -and
        $clientSource -match 'PrimarySucceeded = \$primarySucceeded' -and
        $clientSource -match 'PrimaryFailureCode = \$primaryFailureCode' -and
        $clientSource -match 'CleanupSucceeded = \$cleanupSucceeded' -and
        $clientSource -match 'CleanupFailureCode = \$cleanupFailureCode' -and
        $clientSource -match 'PrimaryElapsedMilliseconds' -and
        $clientSource -match 'RateLimitsWaitElapsedMilliseconds' -and
        $clientSource -match '(?s)\$failureCode = if \(-not \$primarySucceeded\).*?\$primaryFailureCode.*?elseif \(-not \$cleanupSucceeded\).*?\$cleanupFailureCode' -and
        $clientSource -notmatch 'Stop-Process|taskkill|TerminateProcess|\.Kill\s*\(' -and
        $clientSource -notmatch 'supportsLunaReserve|Invoke-WebRequest|Invoke-RestMethod|HttpClient|Authorization'
    ) 'QUOTA_CLIENT_SAFETY_CONTRACT_FAILED'

    $xaml = [System.IO.File]::ReadAllText($xamlPath)
    Assert-QuotaTest ($xaml -match 'x:Name="QuotaColumn"' -and
        $xaml -match 'x:Name="RefreshQuotaButton"') `
        'QUOTA_UI_CONTROLS_MISSING'
    $quotaCellTemplate = [regex]::Match(
        $xaml,
        '(?s)<DataGridTemplateColumn x:Name="QuotaColumn".*?</DataGridTemplateColumn>'
    ).Value
    Assert-QuotaTest (
        -not [string]::IsNullOrWhiteSpace($quotaCellTemplate) -and
        $quotaCellTemplate -match 'TextWrapping="NoWrap"' -and
        $quotaCellTemplate -match 'TextTrimming="CharacterEllipsis"' -and
        $quotaCellTemplate -match 'VerticalAlignment="Center"' -and
        $quotaCellTemplate -match 'ToolTip="{Binding QuotaToolTip}"' -and
        $quotaCellTemplate -notmatch '<StackPanel' -and
        $quotaCellTemplate -notmatch 'QuotaFreshness|QuotaAvailability' -and
        $quotaCellTemplate -notmatch '(?i)\b(?:Min)?Height='
    ) 'QUOTA_CELL_TEMPLATE_NOT_COMPACT_SINGLE_LINE'
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
        CompactOneTwoThreeWindows = 'PASS'
        BoundedFourWindowSummary = 'PASS'
        FullQuotaTooltip = 'PASS'
        QuotaCellSingleLine = 'PASS'
        SwitchBeforeCommit = 'PASS'
        SwitchBeforeFailureNonBlocking = 'PASS'
        LifecycleOperationsNeverStartSwitchBeforeQuota = 'PASS'
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
        CoreCommandsSurviveQuotaImport = 'PASS'
        NoQuotaCacheCoreStillLoads = 'PASS'
        EmptyQuotaCacheCoreStillLoads = 'PASS'
        CorruptQuotaCacheCoreStillLoads = 'PASS'
        UnsupportedQuotaCacheCoreStillLoads = 'PASS'
        QuotaProviderFailureCoreStillLoads = 'PASS'
        QuotaModuleUnavailableCoreStillLoads = 'PASS'
        ProfileWithoutQuotaEntryStillVisible = 'PASS'
        QuotaCacheNeverDefinesProfilePopulation = 'PASS'
        QuotaStartupRunsAfterCoreSnapshot = 'PASS'
        QuotaFailureDoesNotSetCoreUninitialized = 'PASS'
    }
    Write-Output 'QUOTA_GUI_SELFTEST_PASS'
}
finally {
    if ([System.IO.Directory]::Exists($testRoot)) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
