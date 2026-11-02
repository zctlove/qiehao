Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$localizationModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'Localization.psm1'
Import-Module -Name $localizationModulePath -ErrorAction Stop

$script:QuotaUiStrings = [ordered]@{
    RefreshButton = '刷新额度'
    ColumnHeader = '额度快照'
    RefreshCurrentOnly = '仅刷新当前账号额度。'
    Updating = '正在更新当前账号额度……'
    Updated = '当前账号额度已更新。'
    UpdateFailedRetry = '额度获取失败，可点击刷新额度重新获取。'
    UpdateFailedCached = '额度更新失败，保留原缓存。'
    UpdateFailedNoCache = '额度更新失败；当前账号尚无额度快照。'
    CacheUnavailable = '额度缓存不可用；不影响账号管理。'
    NoSnapshot = '尚无额度快照'
    NoWindows = '未返回额度窗口'
    WindowUnavailable = '不可用'
    JustQueried = '刚查询'
    CachedPrefix = '历史缓存'
    IdentityUnverified = '旧额度缓存归属未验证'
    UsageAvailable = '包含额度：可用'
    UsageUnavailable = '当前包含额度不可用'
    UsageUnknown = '包含额度状态未知'
    CurrentTooltip = '这是当前账号最近一次成功保存的额度快照。'
    CurrentNoSnapshotTooltip = '当前账号尚无额度快照；可点击“刷新额度”查询。'
    InactiveTooltip = '这是该账号上次作为当前账号时保存的额度快照。切换为当前账号后可刷新。'
    InactiveNoSnapshotTooltip = '该账号尚无额度快照。非当前账号不会联网；切换为当前账号后可刷新。'
    RenameCacheFailed = '账号已重命名；额度缓存迁移失败，不影响账号状态。'
    DeleteCacheFailed = '账号已删除；额度缓存清理失败，不影响账号状态。'
    SwitchOldFailed = '旧账号额度更新失败，已保留原缓存；继续切换。'
    SwitchNewFailed = '额度获取失败，可点击刷新额度重新获取。'
}

$script:QuotaLocalizationKeys = [ordered]@{
    RefreshButton = 'Button.RefreshQuota'; ColumnHeader = 'Column.QuotaSnapshot'
    RefreshCurrentOnly = 'Quota.RefreshCurrentOnly'; Updating = 'Quota.Updating'
    Updated = 'Quota.Updated'; UpdateFailedRetry = 'Quota.UpdateFailedRetry'
    UpdateFailedCached = 'Quota.UpdateFailedCached'; UpdateFailedNoCache = 'Quota.UpdateFailedNoCache'
    CacheUnavailable = 'Quota.CacheUnavailable'; NoSnapshot = 'Quota.NoSnapshot'
    NoWindows = 'Quota.NoWindows'; JustQueried = 'Quota.JustQueried'
    WindowUnavailable = 'Quota.WindowUnavailable'
    CachedPrefix = 'Quota.CachedPrefix'; UsageAvailable = 'Quota.UsageAvailable'
    IdentityUnverified = 'Quota.IdentityUnverified'
    UsageUnavailable = 'Quota.UsageUnavailable'; UsageUnknown = 'Quota.UsageUnknown'
    CurrentTooltip = 'Quota.CurrentTooltip'; CurrentNoSnapshotTooltip = 'Quota.CurrentNoSnapshotTooltip'
    InactiveTooltip = 'Quota.InactiveTooltip'; InactiveNoSnapshotTooltip = 'Quota.InactiveNoSnapshotTooltip'
    RenameCacheFailed = 'Quota.RenameCacheFailed'; DeleteCacheFailed = 'Quota.DeleteCacheFailed'
    SwitchOldFailed = 'Quota.SwitchOldFailed'; SwitchNewFailed = 'Quota.SwitchNewFailed'
}

function Get-QiehaoQuotaUiText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Language = 'zh-CN'
    )
    if (-not $script:QuotaUiStrings.Contains($Key)) {
        throw 'QUOTA_UI_STRING_NOT_FOUND'
    }
    return Get-QiehaoLocalizedString `
        -Key ([string]$script:QuotaLocalizationKeys[$Key]) `
        -Language $Language
}

function New-QiehaoEmptyQuotaCache {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        schema_version = 1
        profiles = [ordered]@{}
    }
}

function Get-QiehaoQuotaCachePath {
    param([Parameter(Mandatory = $true)][string]$StateDirectory)
    return Join-Path -Path $StateDirectory -ChildPath 'quota-cache.json'
}

function Get-QiehaoQuotaProfiles {
    param([Parameter(Mandatory = $true)][object]$Cache)
    $property = $Cache.PSObject.Properties['profiles']
    if ($null -eq $property -or $null -eq $property.Value) {
        throw 'QUOTA_CACHE_SCHEMA_INVALID'
    }
    return $property.Value
}

function Get-QiehaoDictionaryKeys {
    param([Parameter(Mandatory = $true)][object]$Dictionary)
    if ($Dictionary -is [System.Collections.IDictionary]) {
        return @($Dictionary.Keys)
    }
    return @($Dictionary.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-QiehaoDictionaryValue {
    param(
        [Parameter(Mandatory = $true)][object]$Dictionary,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($Dictionary -is [System.Collections.IDictionary]) {
        if ($Dictionary.Contains($Name)) { return $Dictionary[$Name] }
        return $null
    }
    $property = $Dictionary.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-QiehaoDictionaryActualKey {
    param(
        [Parameter(Mandatory = $true)][object]$Dictionary,
        [Parameter(Mandatory = $true)][string]$Name
    )
    foreach ($key in @(Get-QiehaoDictionaryKeys -Dictionary $Dictionary)) {
        if (([string]$key).Equals($Name, [StringComparison]::OrdinalIgnoreCase)) {
            return [string]$key
        }
    }
    return $null
}

function ConvertTo-QiehaoQuotaPlanDisplay {
    param([AllowNull()][object]$Plan)
    $candidate = ([string]$Plan).Trim()
    if ([string]::IsNullOrWhiteSpace($candidate) -or
        $candidate -notmatch '^[A-Za-z0-9_]{1,64}$') {
        return 'Unknown'
    }
    $parts = @($candidate.ToLowerInvariant().Split('_') | ForEach-Object {
        if (-not [string]::IsNullOrWhiteSpace($_)) {
            if ($_.Length -eq 1) { $_.ToUpperInvariant() }
            else { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }
        }
    })
    return ($parts -join ' ')
}

function Get-QiehaoQuotaDurationLabel {
    param([AllowNull()][Nullable[long]]$DurationMinutes)
    if ($null -eq $DurationMinutes) { return 'Unknown-duration window' }
    $minutes = [long]$DurationMinutes
    if ($minutes -eq 300) { return '5-hour' }
    if ($minutes -eq 10080) { return 'Weekly' }
    if ($minutes -gt 0 -and ($minutes % 1440) -eq 0) {
        return ([string]($minutes / 1440) + '-day')
    }
    if ($minutes -gt 0 -and ($minutes % 60) -eq 0) {
        return ([string]($minutes / 60) + '-hour')
    }
    return ([string]$minutes + '-minute')
}

function ConvertTo-QiehaoNullableInt64Value {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    try {
        return [Convert]::ToInt64(
            $Value,
            [Globalization.CultureInfo]::InvariantCulture
        )
    }
    catch { throw 'QUOTA_CACHE_SCHEMA_INVALID' }
}

function ConvertTo-QiehaoDisplayablePercent {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value -or $Value -isnot [ValueType] -or
        $Value -is [bool] -or $Value -is [char]) { return $null }
    try { $number = [Convert]::ToDouble($Value, [Globalization.CultureInfo]::InvariantCulture) }
    catch { return $null }
    if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or
        $number -lt 0 -or $number -gt 100) { return $null }
    return $number
}

function Write-QiehaoQuotaCacheDiagnostic {
    param([ValidateSet('QUOTA_CACHE_BINDING_VALID','QUOTA_CACHE_LEGACY_UNVERIFIED',
        'QUOTA_CACHE_BINDING_UNVERIFIED','QUOTA_CACHE_NO_SNAPSHOT',
        'QUOTA_CACHE_SAVE_SUCCESS','QUOTA_CACHE_SAVE_REJECTED')][string]$Code)
    try {
        if (Get-Command Write-QiehaoDiagnosticEvent -ErrorAction SilentlyContinue) {
            Write-QiehaoDiagnosticEvent -Event REFRESH_RESULT -Result $Code -Data @{Purpose='Quota';Role='Cache'}
        }
    } catch { } # Diagnostics must not change cache or query results.
}

function Get-QiehaoQuotaCacheBindingState {
    param([AllowNull()][object]$Entry,[string]$ProfileName,[string]$ProfilesDirectory)
    if ($null -eq $Entry -or @($Entry.windows | Where-Object {$null -ne $_.remaining_percent}).Count -eq 0) { return 'QUOTA_CACHE_NO_SNAPSHOT' }
    $binding=$Entry.PSObject.Properties['identity_binding']
    # Old ciphertext hashes cannot establish a stable identity after re-encryption.
    # Keep the old snapshot and time, but never invent or silently upgrade a binding.
    if ($null -eq $binding -or [string]$binding.Value -cnotmatch '^identity-v2:[A-F0-9]{64}$') { return 'QUOTA_CACHE_LEGACY_UNVERIFIED' }
    try {
        if (-not (Get-Command Get-QiehaoQuotaSavedIdentityBinding -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $PSScriptRoot '..\tools\QuotaClient.psm1') -ErrorAction Stop
        }
        $saved=Get-QiehaoQuotaSavedIdentityBinding -ProfileName $ProfileName -ProfilesDirectory $ProfilesDirectory
        if ($saved -ceq [string]$binding.Value) { return 'QUOTA_CACHE_BINDING_VALID' }
    } catch { }
    return 'QUOTA_CACHE_BINDING_UNVERIFIED'
}

function ConvertTo-QiehaoQuotaCacheEntry {
    param(
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [Parameter(Mandatory = $true)][DateTimeOffset]$QueriedAt
    )
    $windowsProperty = $Snapshot.PSObject.Properties['Windows']
    if ($null -eq $windowsProperty -or $null -eq $windowsProperty.Value) {
        throw 'QUOTA_SNAPSHOT_INVALID'
    }
    $windows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($window in @($windowsProperty.Value)) {
        if ($null -eq $window) { continue }
        $remainingProperty = $window.PSObject.Properties['RemainingPercent']
        $remaining = ConvertTo-QiehaoDisplayablePercent -Value $(
            if ($null -eq $remainingProperty) { $null } else { $remainingProperty.Value })
        $durationProperty = $window.PSObject.Properties['DurationMinutes']
        $duration = if ($null -eq $durationProperty) { $null } else {
            ConvertTo-QiehaoNullableInt64Value -Value $durationProperty.Value
        }
        $resetProperty = $window.PSObject.Properties['ResetsAt']
        $resetsAt = if ($null -eq $resetProperty) { $null } else {
            ConvertTo-QiehaoNullableInt64Value -Value $resetProperty.Value
        }
        $null = $windows.Add([pscustomobject][ordered]@{
            duration_minutes = $duration
            label = Get-QiehaoQuotaDurationLabel -DurationMinutes $duration
            remaining_percent = $remaining
            resets_at = $resetsAt
        })
    }
    $ordinary = $null
    $ordinaryProperty = $Snapshot.PSObject.Properties['OrdinaryUsageAllowed']
    if ($null -ne $ordinaryProperty -and $null -ne $ordinaryProperty.Value) {
        if (-not ($ordinaryProperty.Value -is [bool])) {
            throw 'QUOTA_SNAPSHOT_INVALID'
        }
        $ordinary = [bool]$ordinaryProperty.Value
    }
    $planProperty = $Snapshot.PSObject.Properties['Plan']
    $plan = if ($null -eq $planProperty) { $null } else { $planProperty.Value }
    return [pscustomobject][ordered]@{
        plan_type = ConvertTo-QiehaoQuotaPlanDisplay -Plan $plan
        ordinary_usage_allowed = $ordinary
        queried_at = $QueriedAt.ToUniversalTime().ToString('o')
        windows = $windows.ToArray()
    }
}

function ConvertTo-QiehaoValidatedCacheEntry {
    param([Parameter(Mandatory = $true)][object]$Entry)
    $required = @(
        'plan_type', 'ordinary_usage_allowed', 'queried_at', 'windows'
    )
    $keys = @($Entry.PSObject.Properties | ForEach-Object { $_.Name })
    $binding = $Entry.PSObject.Properties['identity_binding']
    if ($null -ne $binding) {
        if ([string]$binding.Value -cnotmatch '^(identity-v2:)?[A-F0-9]{64}$') { throw 'QUOTA_CACHE_SCHEMA_INVALID' }
        $required += 'identity_binding'
    }
    if ($keys.Count -ne $required.Count) {
        throw 'QUOTA_CACHE_SCHEMA_INVALID'
    }
    foreach ($key in $required) {
        if (-not ($keys -ccontains $key)) {
            throw 'QUOTA_CACHE_SCHEMA_INVALID'
        }
    }
    $plan = [string]$Entry.plan_type
    if ([string]::IsNullOrWhiteSpace($plan) -or
        $plan.Length -gt 64 -or $plan -notmatch '^[A-Za-z0-9 ]+$') {
        throw 'QUOTA_CACHE_SCHEMA_INVALID'
    }
    try {
        # PowerShell 7 may deserialize ISO timestamps as DateTime. Casting them
        # to string loses the offset and fractions; preserve their roundtrip form.
        $timestamp = if ($Entry.queried_at -is [DateTime] -or $Entry.queried_at -is [DateTimeOffset]) {
            $Entry.queried_at.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        } else { [string]$Entry.queried_at }
        $queriedAt = [DateTimeOffset]::Parse(
            $timestamp,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind
        )
    }
    catch { throw 'QUOTA_CACHE_SCHEMA_INVALID' }
    $ordinary = $null
    if ($null -ne $Entry.ordinary_usage_allowed) {
        if (-not ($Entry.ordinary_usage_allowed -is [bool])) {
            throw 'QUOTA_CACHE_SCHEMA_INVALID'
        }
        $ordinary = [bool]$Entry.ordinary_usage_allowed
    }
    $inputWindows = @($Entry.windows)
    if ($inputWindows.Count -gt 16) {
        throw 'QUOTA_CACHE_SCHEMA_INVALID'
    }
    $windows = New-Object 'System.Collections.Generic.List[object]'
    foreach ($window in $inputWindows) {
        if ($null -eq $window) { throw 'QUOTA_CACHE_SCHEMA_INVALID' }
        $windowRequired = @(
            'duration_minutes', 'label', 'remaining_percent', 'resets_at'
        )
        $windowKeys = @($window.PSObject.Properties | ForEach-Object { $_.Name })
        if ($windowKeys.Count -ne $windowRequired.Count) {
            throw 'QUOTA_CACHE_SCHEMA_INVALID'
        }
        foreach ($key in $windowRequired) {
            if (-not ($windowKeys -ccontains $key)) {
                throw 'QUOTA_CACHE_SCHEMA_INVALID'
            }
        }
        $duration = ConvertTo-QiehaoNullableInt64Value `
            -Value $window.duration_minutes
        $remaining = ConvertTo-QiehaoDisplayablePercent -Value $window.remaining_percent
        $resetsAt = ConvertTo-QiehaoNullableInt64Value -Value $window.resets_at
        $expectedLabel = Get-QiehaoQuotaDurationLabel -DurationMinutes $duration
        if ([string]$window.label -cne $expectedLabel) {
            throw 'QUOTA_CACHE_SCHEMA_INVALID'
        }
        $null = $windows.Add([pscustomobject][ordered]@{
            duration_minutes = $duration
            label = $expectedLabel
            remaining_percent = $remaining
            resets_at = $resetsAt
        })
    }
    $validated = [pscustomobject][ordered]@{
        plan_type = $plan
        ordinary_usage_allowed = $ordinary
        queried_at = $queriedAt.ToUniversalTime().ToString('o')
        windows = $windows.ToArray()
    }
    if ($null -ne $binding) { $validated | Add-Member -NotePropertyName identity_binding -NotePropertyValue ([string]$binding.Value) }
    return $validated
}

function ConvertTo-QiehaoValidatedQuotaCache {
    param([Parameter(Mandatory = $true)][object]$Cache)
    $topKeys = @($Cache.PSObject.Properties | ForEach-Object { $_.Name })
    if ($topKeys.Count -ne 2 -or
        -not ($topKeys -ccontains 'schema_version') -or
        -not ($topKeys -ccontains 'profiles') -or
        [int]$Cache.schema_version -ne 1) {
        throw 'QUOTA_CACHE_SCHEMA_INVALID'
    }
    $profiles = Get-QiehaoQuotaProfiles -Cache $Cache
    $validatedProfiles = [ordered]@{}
    foreach ($key in @(Get-QiehaoDictionaryKeys -Dictionary $profiles)) {
        $name = [string]$key
        if ([string]::IsNullOrWhiteSpace($name) -or
            $name.Length -gt 80 -or $name -match '[\x00-\x1F]') {
            throw 'QUOTA_CACHE_SCHEMA_INVALID'
        }
        $entry = Get-QiehaoDictionaryValue -Dictionary $profiles -Name $name
        if ($null -eq $entry) { throw 'QUOTA_CACHE_SCHEMA_INVALID' }
        $validatedProfiles[$name] =
            ConvertTo-QiehaoValidatedCacheEntry -Entry $entry
    }
    return [pscustomobject]@{
        schema_version = 1
        profiles = $validatedProfiles
    }
}

function Read-QiehaoQuotaCache {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$StateDirectory)
    $path = Get-QiehaoQuotaCachePath -StateDirectory $StateDirectory
    if (-not [System.IO.File]::Exists($path)) {
        return [pscustomobject]@{
            Cache = New-QiehaoEmptyQuotaCache
            IsValid = $true
            UsedEmpty = $true
            ErrorCode = $null
            Path = $path
        }
    }
    $text = $null
    try {
        $length = ([System.IO.FileInfo]$path).Length
        if ($length -le 0 -or $length -gt 1MB) {
            throw 'QUOTA_CACHE_SCHEMA_INVALID'
        }
        $text = [System.IO.File]::ReadAllText($path)
        $parsed = ConvertFrom-Json -InputObject $text -ErrorAction Stop
        $validated = ConvertTo-QiehaoValidatedQuotaCache -Cache $parsed
        return [pscustomobject]@{
            Cache = $validated
            IsValid = $true
            UsedEmpty = $false
            ErrorCode = $null
            Path = $path
        }
    }
    catch {
        return [pscustomobject]@{
            Cache = New-QiehaoEmptyQuotaCache
            IsValid = $false
            UsedEmpty = $true
            ErrorCode = 'QUOTA_CACHE_INVALID'
            Path = $path
        }
    }
    finally {
        $text = $null
        $parsed = $null
    }
}

function Write-QiehaoQuotaCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateDirectory,
        [Parameter(Mandatory = $true)][object]$Cache
    )
    $validated = ConvertTo-QiehaoValidatedQuotaCache -Cache $Cache
    [System.IO.Directory]::CreateDirectory($StateDirectory) | Out-Null
    $path = Get-QiehaoQuotaCachePath -StateDirectory $StateDirectory
    $temporaryPath = Join-Path -Path $StateDirectory -ChildPath (
        '.quota-cache.' + [Guid]::NewGuid().ToString('N') + '.tmp'
    )
    $stream = $null
    $writer = $null
    $json = $null
    try {
        $json = $validated | ConvertTo-Json -Depth 12
        $encoding = New-Object System.Text.UTF8Encoding($false)
        $stream = New-Object System.IO.FileStream(
            $temporaryPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None
        )
        $writer = New-Object System.IO.StreamWriter($stream, $encoding)
        $writer.Write($json)
        $writer.Flush()
        $stream.Flush($true)
        $writer.Dispose()
        $writer = $null
        $stream.Dispose()
        $stream = $null
        if ([System.IO.File]::Exists($path)) {
            [System.IO.File]::Replace(
                $temporaryPath,
                $path,
                [System.Management.Automation.Language.NullString]::Value
            )
        }
        else {
            [System.IO.File]::Move($temporaryPath, $path)
        }
        return $validated
    }
    finally {
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $stream) { $stream.Dispose() }
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
        $json = $null
    }
}

function Copy-QiehaoQuotaCache {
    param([Parameter(Mandatory = $true)][object]$Cache)
    $json = $Cache | ConvertTo-Json -Depth 12 -Compress
    try {
        $parsed = ConvertFrom-Json -InputObject $json -ErrorAction Stop
        return ConvertTo-QiehaoValidatedQuotaCache -Cache $parsed
    }
    finally {
        $json = $null
        $parsed = $null
    }
}

function Get-QiehaoQuotaCacheSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Cache,
        [Parameter(Mandatory = $true)][string]$ProfileName
    )
    $profiles = Get-QiehaoQuotaProfiles -Cache $Cache
    $actualKey = Get-QiehaoDictionaryActualKey `
        -Dictionary $profiles -Name $ProfileName
    if ([string]::IsNullOrWhiteSpace($actualKey)) { return $null }
    return Get-QiehaoDictionaryValue -Dictionary $profiles -Name $actualKey
}

function Save-QiehaoQuotaSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateDirectory,
        [Parameter(Mandatory = $true)][object]$Cache,
        [Parameter(Mandatory = $true)][string]$ProfileName,
        [Parameter(Mandatory = $true)][object]$Snapshot,
        [AllowNull()][object]$IdentityProof,
        [DateTimeOffset]$QueriedAt = [DateTimeOffset]::Now
    )
    try {
        $next = Copy-QiehaoQuotaCache -Cache $Cache
        $entry = ConvertTo-QiehaoQuotaCacheEntry `
            -Snapshot $Snapshot -QueriedAt $QueriedAt
        if (@($entry.windows | Where-Object { $null -ne $_.remaining_percent }).Count -eq 0) {
            throw 'QUOTA_NO_DISPLAYABLE_WINDOWS'
        }
        if ($null -eq $IdentityProof -or $IdentityProof.ProfileName -cne $ProfileName -or
            [string]$IdentityProof.Binding -cnotmatch '^identity-v2:[A-F0-9]{64}$') { throw 'QUOTA_ACCOUNT_IDENTITY_MISMATCH' }
        $entry | Add-Member -NotePropertyName identity_binding -NotePropertyValue ([string]$IdentityProof.Binding)
        $profiles = Get-QiehaoQuotaProfiles -Cache $next
        $actualKey = Get-QiehaoDictionaryActualKey `
            -Dictionary $profiles -Name $ProfileName
        if (-not [string]::IsNullOrWhiteSpace($actualKey)) {
            $profiles.Remove($actualKey)
        }
        $profiles[$ProfileName] = $entry
        if (-not (Get-Command Invoke-QiehaoQuotaIdentityBoundOperation -ErrorAction SilentlyContinue)) {
            Import-Module (Join-Path $PSScriptRoot '..\tools\QuotaClient.psm1') -ErrorAction Stop
        }
        $persisted = Invoke-QiehaoQuotaIdentityBoundOperation -ProfileName $ProfileName -IdentityProof $IdentityProof -Operation {
            param($directory,$nextCache)
            Write-QiehaoQuotaCache -StateDirectory $directory -Cache $nextCache
        } -ArgumentList @($StateDirectory,$next)
        Write-QiehaoQuotaCacheDiagnostic -Code QUOTA_CACHE_SAVE_SUCCESS
        return [pscustomobject]@{
            Succeeded = $true
            Cache = $persisted
            FailureCode = $null
        }
    }
    catch {
        Write-QiehaoQuotaCacheDiagnostic -Code QUOTA_CACHE_SAVE_REJECTED
        return [pscustomobject]@{
            Succeeded = $false
            Cache = $Cache
            FailureCode = $(if ($_.Exception.Message -in @('QUOTA_NO_DISPLAYABLE_WINDOWS','QUOTA_ACCOUNT_IDENTITY_MISMATCH')) {
                $_.Exception.Message
            } else { 'QUOTA_CACHE_WRITE_FAILED' })
        }
    }
}

function Rename-QiehaoQuotaCacheProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateDirectory,
        [Parameter(Mandatory = $true)][object]$Cache,
        [Parameter(Mandatory = $true)][string]$OldName,
        [Parameter(Mandatory = $true)][string]$NewName
    )
    try {
        $next = Copy-QiehaoQuotaCache -Cache $Cache
        $profiles = Get-QiehaoQuotaProfiles -Cache $next
        $oldKey = Get-QiehaoDictionaryActualKey -Dictionary $profiles -Name $OldName
        if ([string]::IsNullOrWhiteSpace($oldKey)) {
            return [pscustomobject]@{
                Succeeded = $true; Cache = $next; Changed = $false
            }
        }
        $newKey = Get-QiehaoDictionaryActualKey -Dictionary $profiles -Name $NewName
        if (-not [string]::IsNullOrWhiteSpace($newKey)) {
            throw 'QUOTA_CACHE_RENAME_TARGET_EXISTS'
        }
        $entry = $profiles[$oldKey]
        $profiles.Remove($oldKey)
        $profiles[$NewName] = $entry
        $persisted = Write-QiehaoQuotaCache `
            -StateDirectory $StateDirectory -Cache $next
        return [pscustomobject]@{
            Succeeded = $true; Cache = $persisted; Changed = $true
        }
    }
    catch {
        return [pscustomobject]@{
            Succeeded = $false; Cache = $Cache; Changed = $false
        }
    }
}

function Remove-QiehaoQuotaCacheProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$StateDirectory,
        [Parameter(Mandatory = $true)][object]$Cache,
        [Parameter(Mandatory = $true)][string]$ProfileName
    )
    try {
        $next = Copy-QiehaoQuotaCache -Cache $Cache
        $profiles = Get-QiehaoQuotaProfiles -Cache $next
        $actualKey = Get-QiehaoDictionaryActualKey `
            -Dictionary $profiles -Name $ProfileName
        if ([string]::IsNullOrWhiteSpace($actualKey)) {
            return [pscustomobject]@{
                Succeeded = $true; Cache = $next; Changed = $false
            }
        }
        $profiles.Remove($actualKey)
        $persisted = Write-QiehaoQuotaCache `
            -StateDirectory $StateDirectory -Cache $next
        return [pscustomobject]@{
            Succeeded = $true; Cache = $persisted; Changed = $true
        }
    }
    catch {
        return [pscustomobject]@{
            Succeeded = $false; Cache = $Cache; Changed = $false
        }
    }
}

function New-QiehaoQuotaCoordinatorState {
    [CmdletBinding()]
    param()
    return [pscustomobject]@{
        StartupAttempted = $false
        QueryInProgress = $false
    }
}

function Invoke-QiehaoQuotaCacheRefresh {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Open', 'Manual', 'SwitchBefore', 'SwitchAfter')]
        [string]$Reason,
        [Parameter(Mandatory = $true)][object]$Coordinator,
        [Parameter(Mandatory = $true)][string]$StateDirectory,
        [Parameter(Mandatory = $true)][object]$Cache,
        [AllowNull()][string]$ActiveProfile,
        [AllowNull()][string]$SelectedProfile,
        [Parameter(Mandatory = $true)][scriptblock]$QuotaProvider,
        [DateTimeOffset]$QueriedAt = [DateTimeOffset]::Now
    )
    if ($Reason -ceq 'Open') {
        if ([bool]$Coordinator.StartupAttempted) {
            return [pscustomobject]@{
                Succeeded = $false; ProviderCalled = $false
                RequestedProfile = $null; Cache = $Cache
                FailureCode = 'QUOTA_STARTUP_ALREADY_ATTEMPTED'
            }
        }
        $Coordinator.StartupAttempted = $true
    }
    if ([bool]$Coordinator.QueryInProgress) {
        return [pscustomobject]@{
            Succeeded = $false; ProviderCalled = $false
            RequestedProfile = $null; Cache = $Cache
            FailureCode = 'QUOTA_QUERY_IN_PROGRESS'
        }
    }
    if ([string]::IsNullOrWhiteSpace($ActiveProfile) -or
        $ActiveProfile -ceq '未初始化') {
        return [pscustomobject]@{
            Succeeded = $false; ProviderCalled = $false
            RequestedProfile = $null; Cache = $Cache
            FailureCode = 'QUOTA_ACTIVE_PROFILE_UNAVAILABLE'
        }
    }
    $Coordinator.QueryInProgress = $true
    try {
        # SelectedProfile is intentionally ignored. Only ActiveProfile is legal.
        $providerResult = & $QuotaProvider $ActiveProfile
        if ($null -eq $providerResult -or -not [bool]$providerResult.Succeeded) {
            return [pscustomobject]@{
                Succeeded = $false; ProviderCalled = $true
                RequestedProfile = $ActiveProfile; Cache = $Cache
                FailureCode = if ($null -eq $providerResult) {
                    'QUOTA_PROVIDER_FAILED'
                } else { [string]$providerResult.FailureCode }
            }
        }
        $saved = Save-QiehaoQuotaSnapshot -StateDirectory $StateDirectory `
            -Cache $Cache -ProfileName $ActiveProfile `
            -Snapshot $providerResult.Snapshot -QueriedAt $QueriedAt -IdentityProof $providerResult.IdentityProof
        return [pscustomobject]@{
            Succeeded = [bool]$saved.Succeeded
            ProviderCalled = $true
            RequestedProfile = $ActiveProfile
            Cache = $saved.Cache
            FailureCode = $saved.FailureCode
        }
    }
    catch {
        return [pscustomobject]@{
            Succeeded = $false; ProviderCalled = $true
            RequestedProfile = $ActiveProfile; Cache = $Cache
            FailureCode = 'QUOTA_PROVIDER_FAILED'
        }
    }
    finally {
        $Coordinator.QueryInProgress = $false
    }
}

function Format-QiehaoQuotaReset {
    param(
        [AllowNull()][object]$ResetsAt,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Now
    )
    if ($null -eq $ResetsAt) { return '' }
    try {
        $local = [DateTimeOffset]::FromUnixTimeSeconds([long]$ResetsAt).
            ToLocalTime()
        if ($local.Date -eq $Now.ToLocalTime().Date) {
            return $local.ToString('HH:mm')
        }
        return $local.ToString('MM/dd HH:mm')
    }
    catch { return '' }
}

function Get-QiehaoQuotaCompactLabel {
    param([AllowNull()][object]$Duration, [string]$Label)
    if ($null -ne $Duration -and [long]$Duration -eq 300) { return '5h' }
    if ($null -ne $Duration -and [long]$Duration -eq 10080) { return 'Week' }
    if ($null -ne $Duration -and [long]$Duration -gt 0) {
        $minutes = [long]$Duration
        if (($minutes % 1440) -eq 0) {
            return ([string]($minutes / 1440) + 'd')
        }
        if (($minutes % 60) -eq 0) {
            return ([string]($minutes / 60) + 'h')
        }
        return ([string]$minutes + 'm')
    }
    if (-not [string]::IsNullOrWhiteSpace($Label)) { return $Label }
    return 'Window'
}

function Format-QiehaoQuotaPercent {
    param([Parameter(Mandatory = $true)][object]$Value)
    return ([Convert]::ToDouble(
        $Value,
        [Globalization.CultureInfo]::InvariantCulture
    )).ToString('0.#', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-QiehaoQuotaSnapshotTooltip {
    param(
        [Parameter(Mandatory = $true)][object]$Entry,
        [Parameter(Mandatory = $true)][bool]$IsActive,
        [Parameter(Mandatory = $true)][DateTimeOffset]$Now,
        [Parameter(Mandatory = $true)][string]$Availability,
        [string]$Language = 'zh-CN'
    )

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $null = $lines.Add((Get-QiehaoLocalizedString -Language $Language `
        -Key $(if ($IsActive) { 'Quota.CurrentTitle' } `
            else { 'Quota.SnapshotTitle' })))
    $null = $lines.Add('')
    foreach ($window in @($Entry.windows)) {
        $label = [string]$window.label
        if ([string]::IsNullOrWhiteSpace($label)) {
            $label = Get-QiehaoQuotaDurationLabel `
                -DurationMinutes $window.duration_minutes
        }
        $null = $lines.Add($label)
        if ($null -eq $window.remaining_percent) {
            $null = $lines.Add((Get-QiehaoQuotaUiText -Key 'WindowUnavailable' -Language $Language))
        } else {
            $null = $lines.Add((Format-QiehaoLocalizedString `
                -Key 'Quota.Remaining' -Language $Language -Arguments @(
                    (Format-QiehaoQuotaPercent -Value $window.remaining_percent)
                )))
        }
        $reset = Format-QiehaoQuotaReset `
            -ResetsAt $window.resets_at -Now $Now
        if (-not [string]::IsNullOrWhiteSpace($reset)) {
            $null = $lines.Add((Format-QiehaoLocalizedString `
                -Key 'Quota.Resets' -Language $Language -Arguments @($reset)))
        }
        $null = $lines.Add('')
    }
    $null = $lines.Add($Availability)
    $null = $lines.Add('')
    $null = $lines.Add((Get-QiehaoLocalizedString `
        -Key 'Quota.QueriedAt' -Language $Language))
    $queried = [DateTimeOffset]::Parse(
        [string]$Entry.queried_at,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::RoundtripKind
    ).ToLocalTime()
    $null = $lines.Add($queried.ToString('yyyy-MM-dd HH:mm:ss'))
    if (-not $IsActive) {
        $null = $lines.Add('')
        $null = $lines.Add((Get-QiehaoLocalizedString `
            -Key 'Quota.InactiveTooltip' -Language $Language))
    }
    return $lines.ToArray() -join [Environment]::NewLine
}

function Update-QiehaoQuotaProfileRows {
    [CmdletBinding()]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][object]$Cache,
        [AllowNull()][string]$ActiveProfile,
        [AllowNull()][string]$JustUpdatedProfile,
        [DateTimeOffset]$Now = [DateTimeOffset]::Now,
        [string]$Language = 'zh-CN',
        [string]$ProfilesDirectory = (Join-Path (Split-Path -Parent $PSScriptRoot) 'profiles')
    )
    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }
        $name = [string]$row.Name
        $isActive = (
            -not [string]::IsNullOrWhiteSpace($ActiveProfile) -and
            $name.Equals($ActiveProfile, [StringComparison]::OrdinalIgnoreCase)
        )
        $entry = Get-QiehaoQuotaCacheSnapshot -Cache $Cache -ProfileName $name
        if ($null -ne $entry -and @($entry.windows | Where-Object { $null -ne $_.remaining_percent }).Count -eq 0) { $entry = $null }
        $summary = Get-QiehaoQuotaUiText -Key 'NoSnapshot' -Language $Language
        $freshness = ''
        $availability = ''
        if ($null -ne $entry) {
            $summaryParts = New-Object 'System.Collections.Generic.List[string]'
            $windowCount = @($entry.windows).Count
            $windowIndex = 0
            foreach ($window in @($entry.windows)) {
                if ($windowIndex -ge 3) { break }
                $compact = Get-QiehaoQuotaCompactLabel `
                    -Duration $window.duration_minutes -Label ([string]$window.label)
                $part = $compact + ' ' + $(if ($null -eq $window.remaining_percent) {
                    Get-QiehaoQuotaUiText -Key 'WindowUnavailable' -Language $Language
                } else { (Format-QiehaoQuotaPercent -Value $window.remaining_percent) + '%' })
                $null = $summaryParts.Add($part)
                $windowIndex++
            }
            if ($windowCount -gt 3) {
                $null = $summaryParts.Add('+' + [string]($windowCount - 3))
            }
            $summary = if ($summaryParts.Count -eq 0) {
                Get-QiehaoQuotaUiText -Key 'NoWindows' -Language $Language
            } else { $summaryParts.ToArray() -join ' · ' }
            if ($null -ne $entry.ordinary_usage_allowed) {
                $availability = if ([bool]$entry.ordinary_usage_allowed) {
                    Get-QiehaoQuotaUiText -Key 'UsageAvailable' -Language $Language
                } else {
                    Get-QiehaoQuotaUiText -Key 'UsageUnavailable' -Language $Language
                }
            }
            else {
                $availability = Get-QiehaoQuotaUiText -Key 'UsageUnknown' `
                    -Language $Language
            }
            if ($isActive -and -not [string]::IsNullOrWhiteSpace($JustUpdatedProfile) -and
                $name.Equals(
                    $JustUpdatedProfile,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                $freshness = Get-QiehaoQuotaUiText -Key 'JustQueried' `
                    -Language $Language
            }
            else {
                $queried = [DateTimeOffset]::Parse(
                    [string]$entry.queried_at,
                    [Globalization.CultureInfo]::InvariantCulture,
                    [Globalization.DateTimeStyles]::RoundtripKind
                ).ToLocalTime()
                $stamp = $queried.ToString('yyyy-MM-dd HH:mm:ss')
                $freshness = (Get-QiehaoQuotaUiText -Key 'CachedPrefix' `
                    -Language $Language) +
                    ' · ' + $stamp
            }
        }
        $tooltip = if ($null -ne $entry) {
            Get-QiehaoQuotaSnapshotTooltip -Entry $entry `
                -IsActive $isActive -Now $Now -Availability $availability `
                -Language $Language
        }
        elseif ($isActive) {
            Get-QiehaoQuotaUiText -Key 'CurrentNoSnapshotTooltip' `
                -Language $Language
        }
        else {
            Get-QiehaoQuotaUiText -Key 'InactiveNoSnapshotTooltip' `
                -Language $Language
        }
        $bindingState=Get-QiehaoQuotaCacheBindingState -Entry $entry -ProfileName $name -ProfilesDirectory $ProfilesDirectory
        # Emit only fixed state transitions, without names, identity hashes or values.
        if (-not (Get-Variable -Name QuotaBindingStates -Scope Script -ErrorAction SilentlyContinue)) { $script:QuotaBindingStates=@{} }
        $diagnosticKey=$ProfilesDirectory + '|' + $name
        if ($script:QuotaBindingStates[$diagnosticKey] -cne $bindingState) {
            Write-QiehaoQuotaCacheDiagnostic -Code $bindingState
            $script:QuotaBindingStates[$diagnosticKey]=$bindingState
        }
        if ($null -ne $entry) {
            if ($bindingState -cne 'QUOTA_CACHE_BINDING_VALID') {
                $summary = Get-QiehaoQuotaUiText -Key IdentityUnverified -Language $Language
                $freshness = (Get-QiehaoQuotaUiText -Key CachedPrefix -Language $Language) + ' · ' + ([DateTimeOffset]::Parse($entry.queried_at)).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss')
                $availability = ''
                $tooltip = $summary + ' · ' + $freshness
            }
        }
        $row | Add-Member -NotePropertyName QuotaSummary `
            -NotePropertyValue $summary -Force
        $row | Add-Member -NotePropertyName QuotaFreshness `
            -NotePropertyValue $freshness -Force
        $row | Add-Member -NotePropertyName QuotaAvailability `
            -NotePropertyValue $availability -Force
        $row | Add-Member -NotePropertyName QuotaToolTip `
            -NotePropertyValue $tooltip -Force
        $row | Add-Member -NotePropertyName QuotaIsActive `
            -NotePropertyValue $isActive -Force
    }
    return @($Rows)
}

Export-ModuleMember -Function @(
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
