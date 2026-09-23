[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot 'lib\CodexAuth.psm1'
$module = Import-Module -Name $modulePath -Force -PassThru -ErrorAction Stop

function Test-BytesEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($null -eq $Left -or $null -eq $Right -or
        $Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function New-FakeAuthBytes {
    param([string]$Name, [int]$Ordinal)
    $auth = [ordered]@{
        auth_mode = 'chatgpt'
        OPENAI_API_KEY = $null
        tokens = [ordered]@{
            id_token = 'FAKE-ID-' + $Name
            access_token = 'FAKE-ACCESS-' + $Name
            refresh_token = 'FAKE-REFRESH-' + $Name
            account_id = 'FAKE-ACCOUNT-' + $Name
        }
        last_refresh = '2000-01-01T00:00:00Z'
    }
    if (($Ordinal % 3) -eq 0) {
        $auth.agent_identity = 'FAKE-AGENT-' + $Name
    }
    elseif (($Ordinal % 3) -eq 1) {
        $auth.future_optional = [ordered]@{ version = $Ordinal; enabled = $true }
    }
    else {
        $auth.bedrock_access_keys = $null
    }
    $json = $auth | ConvertTo-Json -Compress -Depth 8
    try {
        return ,(New-Object System.Text.UTF8Encoding($false, $true)).GetBytes($json)
    }
    finally {
        $json = $null
        $auth = $null
    }
}

function Get-ArtifactStamp {
    param([string]$ProfilesDirectory)
    $stamp = @{}
    foreach ($file in Get-ChildItem -LiteralPath $ProfilesDirectory -File -Force) {
        $stamp[$file.Name] = (Get-FileHash -LiteralPath $file.FullName `
            -Algorithm SHA256).Hash + '|' + [string]$file.Length + '|' +
            [string]$file.LastWriteTimeUtc.Ticks
    }
    return $stamp
}

function Assert-NoUnexpectedArtifactMutation {
    param(
        [hashtable]$Before,
        [hashtable]$After,
        [string[]]$AllowedProfiles = @()
    )
    $unexpected = 0
    foreach ($name in $Before.Keys) {
        if (-not $After.ContainsKey($name)) {
            $unexpected++
            continue
        }
        if ($Before[$name] -cne $After[$name]) {
            $allowed = $false
            foreach ($profile in $AllowedProfiles) {
                if ($name -ceq ($profile + '.auth.dpapi') -or
                    $name -ceq ($profile + '.identity.dpapi') -or
                    $name -ceq ($profile + '.meta.json')) {
                    $allowed = $true
                    break
                }
            }
            if (-not $allowed) { $unexpected++ }
        }
    }
    return $unexpected
}

function Get-ActiveName {
    param($Module, [string]$StateDirectory)
    return [string](& $Module {
        param($State)
        (Read-ActiveProfileState -StateDirectory $State).ActiveProfile
    } $StateDirectory)
}

function Read-ProfileBytes {
    param($Module, [string]$Name, [string]$ProfilesDirectory)
    return ,(& $Module {
        param($Profile, $Profiles)
        Read-CodexAccountSlotBytes -Name $Profile -ProfilesDirectory $Profiles
    } $Name $ProfilesDirectory)
}

function Assert-ProfileLogicalState {
    param(
        $Module,
        [string]$Name,
        [byte[]]$ExpectedBytes,
        [string]$ProfilesDirectory
    )
    $actual = $null
    try {
        $actual = Read-ProfileBytes -Module $Module -Name $Name `
            -ProfilesDirectory $ProfilesDirectory
        if (-not (Test-BytesEqual -Left $actual -Right $ExpectedBytes)) {
            throw ('MULTIACCOUNT_AUTH_CROSS_CONTAMINATION_' + $Name)
        }
        $markerMatches = & $Module {
            param($Profile, $Bytes, $Profiles)
            Assert-CodexAuthMatchesProfileIdentity -Name $Profile `
                -AuthBytes $Bytes -ProfilesDirectory $Profiles
        } $Name $ExpectedBytes $ProfilesDirectory
        if (-not $markerMatches) {
            throw ('MULTIACCOUNT_MARKER_CROSS_CONTAMINATION_' + $Name)
        }
        $metaPath = Join-Path $ProfilesDirectory ($Name + '.meta.json')
        $metadata = ConvertFrom-Json -InputObject (
            [System.IO.File]::ReadAllText($metaPath)
        )
        if ([string]$metadata.profile_name -cne $Name -or
            [string]$metadata.encrypted_file_name -cne ($Name + '.auth.dpapi') -or
            [string]$metadata.dpapi_scope -cne 'CurrentUser') {
            throw ('MULTIACCOUNT_METADATA_MISMATCH_' + $Name)
        }
    }
    finally {
        if ($null -ne $actual -and $actual.Length -gt 0) {
            [Array]::Clear($actual, 0, $actual.Length)
        }
    }
}

function Assert-LiveState {
    param(
        $Module,
        [string]$ExpectedActive,
        [hashtable]$ExpectedAuth,
        [string]$CodexHome,
        [string]$ProfilesDirectory,
        [string]$StateDirectory,
        [string[]]$ProfileNames
    )
    $liveBytes = $null
    try {
        $liveBytes = [System.IO.File]::ReadAllBytes((Join-Path $CodexHome 'auth.json'))
        if ((Get-ActiveName -Module $Module -StateDirectory $StateDirectory) -cne
            $ExpectedActive -or
            -not (Test-BytesEqual -Left $liveBytes `
                -Right ([byte[]]$ExpectedAuth[$ExpectedActive]))) {
            throw 'MULTIACCOUNT_ACTIVE_AND_LIVE_AUTH_DIVERGED'
        }
        foreach ($profile in $ProfileNames) {
            Assert-ProfileLogicalState -Module $Module -Name $profile `
                -ExpectedBytes ([byte[]]$ExpectedAuth[$profile]) `
                -ProfilesDirectory $ProfilesDirectory
        }
    }
    finally {
        if ($null -ne $liveBytes -and $liveBytes.Length -gt 0) {
            [Array]::Clear($liveBytes, 0, $liveBytes.Length)
        }
    }
}

function Invoke-FakeAdd {
    param(
        $Module,
        [string]$Name,
        [byte[]]$Bytes,
        [string]$CodexHome,
        [string]$ProfilesDirectory,
        [string]$StateDirectory
    )
    [System.IO.File]::WriteAllBytes((Join-Path $CodexHome 'auth.json'), $Bytes)
    return & $Module {
        param($Profile, $Home, $Profiles, $State)
        Invoke-AddCodexProfile -Name $Profile -CodexHome $Home `
            -ProfilesDirectory $Profiles -StateDirectory $State `
            -ProcessData @() -UseProvidedProcessData
    } $Name $CodexHome $ProfilesDirectory $StateDirectory
}

function Invoke-FakeSwitch {
    param(
        $Module,
        [string]$Name,
        [string]$CodexHome,
        [string]$ProfilesDirectory,
        [string]$StateDirectory,
        [switch]$SimulateFailure
    )
    return & $Module {
        param($Profile, $Home, $Profiles, $State, $Fail)
        Invoke-CodexAccountSwitch -Name $Profile -CodexHome $Home `
            -ProfilesDirectory $Profiles -StateDirectory $State `
            -ProcessData @() -UseProvidedProcessData `
            -SimulatePostReplaceVerificationFailure:$Fail
    } $Name $CodexHome $ProfilesDirectory $StateDirectory $SimulateFailure
}

$testsRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $testsRoot (
    '.multiaccount-' + [Guid]::NewGuid().ToString('N')
)))
if (-not $testRoot.StartsWith($testsRoot.TrimEnd('\') + '\',
        [StringComparison]::OrdinalIgnoreCase)) {
    throw 'MULTIACCOUNT_TEST_PATH_INVALID'
}

$codexHome = Join-Path $testRoot 'codex-home'
$profiles = Join-Path $testRoot 'profiles'
$state = Join-Path $testRoot 'state'
$expectedAuth = @{}
$profileNames = @()
$unexpectedProfileMutations = 0
$identityCrossContamination = 0
$randomSwitchFailures = 0

try {
    foreach ($directory in @($codexHome, $profiles, $state)) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }

    # A. Add ten distinct fake accounts. Existing artifacts must remain byte
    # for byte unchanged on every ADD.
    for ($ordinal = 1; $ordinal -le 10; $ordinal++) {
        $name = 'A{0:D2}' -f $ordinal
        $bytes = New-FakeAuthBytes -Name $name -Ordinal $ordinal
        $expectedAuth[$name] = $bytes
        $before = Get-ArtifactStamp -ProfilesDirectory $profiles
        $result = Invoke-FakeAdd -Module $module -Name $name -Bytes $bytes `
            -CodexHome $codexHome -ProfilesDirectory $profiles `
            -StateDirectory $state
        if ($result.Result -cne 'PROFILE_ADD_SUCCESS') {
            throw ('MULTIACCOUNT_ADD_FAILED_' + $name)
        }
        $after = Get-ArtifactStamp -ProfilesDirectory $profiles
        $unexpectedProfileMutations += Assert-NoUnexpectedArtifactMutation `
            -Before $before -After $after
        $profileNames += $name
        if (@(Get-ChildItem -LiteralPath $profiles -Filter '*.auth.dpapi').Count `
                -ne $ordinal -or
            (Get-ActiveName -Module $module -StateDirectory $state) -cne $name) {
            throw ('MULTIACCOUNT_ADD_COUNT_OR_ACTIVE_FAILED_' + $name)
        }
        foreach ($existing in $profileNames) {
            Assert-ProfileLogicalState -Module $module -Name $existing `
                -ExpectedBytes ([byte[]]$expectedAuth[$existing]) `
                -ProfilesDirectory $profiles
        }
    }

    # H. Reload the module before later mutations to prove disk persistence.
    Remove-Module -ModuleInfo $module -Force
    $module = Import-Module -Name $modulePath -Force -PassThru -ErrorAction Stop
    $diskRows = @(& $module {
        param($Profiles, $State)
        Get-CodexAccountSlotState -ProfilesDirectory $Profiles `
            -StateDirectory $State
    } $profiles $state)
    if ($diskRows.Count -ne 10 -or
        (Get-ActiveName -Module $module -StateDirectory $state) -cne 'A10' -or
        (@($diskRows.Profile | Sort-Object) -join '|') -cne
            (@($profileNames | Sort-Object) -join '|')) {
        throw 'MULTIACCOUNT_RESTART_PERSISTENCE_FAILED'
    }
    Assert-LiveState -Module $module -ExpectedActive 'A10' `
        -ExpectedAuth $expectedAuth -CodexHome $codexHome `
        -ProfilesDirectory $profiles -StateDirectory $state `
        -ProfileNames $profileNames

    # B. Forward and reverse switching. The source active slot may be safely
    # refreshed by design; no other profile artifact may mutate.
    foreach ($target in $profileNames) {
        $source = Get-ActiveName -Module $module -StateDirectory $state
        $before = Get-ArtifactStamp -ProfilesDirectory $profiles
        if ($source -ceq $target) {
            $code = $null
            try { $null = Invoke-FakeSwitch -Module $module -Name $target `
                    -CodexHome $codexHome -ProfilesDirectory $profiles `
                    -StateDirectory $state }
            catch { $code = [string]$_.Exception.Message }
            if ($code -cne 'ALREADY_ACTIVE') { throw 'MULTIACCOUNT_ALREADY_ACTIVE_FAILED' }
        }
        else {
            $result = Invoke-FakeSwitch -Module $module -Name $target `
                -CodexHome $codexHome -ProfilesDirectory $profiles `
                -StateDirectory $state
            if ($result.Result -cne 'SWITCH_SUCCESS') {
                throw ('MULTIACCOUNT_FORWARD_SWITCH_FAILED_' + $target)
            }
        }
        $after = Get-ArtifactStamp -ProfilesDirectory $profiles
        $unexpectedProfileMutations += Assert-NoUnexpectedArtifactMutation `
            -Before $before -After $after -AllowedProfiles @($source)
        Assert-LiveState -Module $module -ExpectedActive $target `
            -ExpectedAuth $expectedAuth -CodexHome $codexHome `
            -ProfilesDirectory $profiles -StateDirectory $state `
            -ProfileNames $profileNames
    }
    foreach ($target in @($profileNames | Sort-Object -Descending)) {
        $source = Get-ActiveName -Module $module -StateDirectory $state
        $before = Get-ArtifactStamp -ProfilesDirectory $profiles
        if ($source -cne $target) {
            $result = Invoke-FakeSwitch -Module $module -Name $target `
                -CodexHome $codexHome -ProfilesDirectory $profiles `
                -StateDirectory $state
            if ($result.Result -cne 'SWITCH_SUCCESS') {
                throw ('MULTIACCOUNT_REVERSE_SWITCH_FAILED_' + $target)
            }
        }
        $after = Get-ArtifactStamp -ProfilesDirectory $profiles
        $unexpectedProfileMutations += Assert-NoUnexpectedArtifactMutation `
            -Before $before -After $after -AllowedProfiles @($source)
        Assert-LiveState -Module $module -ExpectedActive $target `
            -ExpectedAuth $expectedAuth -CodexHome $codexHome `
            -ProfilesDirectory $profiles -StateDirectory $state `
            -ProfileNames $profileNames
    }

    # C. One hundred deterministic random switches.
    $random = New-Object System.Random(20260922)
    for ($iteration = 1; $iteration -le 100; $iteration++) {
        $target = $profileNames[$random.Next(0, $profileNames.Count)]
        $source = Get-ActiveName -Module $module -StateDirectory $state
        $before = Get-ArtifactStamp -ProfilesDirectory $profiles
        try {
            if ($source -ceq $target) {
                $code = $null
                try { $null = Invoke-FakeSwitch -Module $module -Name $target `
                        -CodexHome $codexHome -ProfilesDirectory $profiles `
                        -StateDirectory $state }
                catch { $code = [string]$_.Exception.Message }
                if ($code -cne 'ALREADY_ACTIVE') { throw 'EXPECTED_ALREADY_ACTIVE' }
            }
            else {
                $result = Invoke-FakeSwitch -Module $module -Name $target `
                    -CodexHome $codexHome -ProfilesDirectory $profiles `
                    -StateDirectory $state
                if ($result.Result -cne 'SWITCH_SUCCESS') { throw 'SWITCH_NOT_SUCCESS' }
            }
            Assert-LiveState -Module $module -ExpectedActive $target `
                -ExpectedAuth $expectedAuth -CodexHome $codexHome `
                -ProfilesDirectory $profiles -StateDirectory $state `
                -ProfileNames $profileNames
        }
        catch {
            $randomSwitchFailures++
            throw
        }
        $after = Get-ArtifactStamp -ProfilesDirectory $profiles
        $unexpectedProfileMutations += Assert-NoUnexpectedArtifactMutation `
            -Before $before -After $after -AllowedProfiles @($source)
    }

    # D. Every saved identity must be rejected as a duplicate without changing
    # profile artifacts or active state. End on A10 so live auth matches active.
    foreach ($name in $profileNames) {
        [System.IO.File]::WriteAllBytes((Join-Path $codexHome 'auth.json'),
            [byte[]]$expectedAuth[$name])
        $before = Get-ArtifactStamp -ProfilesDirectory $profiles
        $activeBefore = Get-ActiveName -Module $module -StateDirectory $state
        $code = $null
        try {
            $null = & $module {
                param($Profile, $Home, $Profiles, $State)
                Invoke-AddCodexProfile -Name ('Duplicate-' + $Profile) `
                    -CodexHome $Home -ProfilesDirectory $Profiles `
                    -StateDirectory $State -ProcessData @() -UseProvidedProcessData
            } $name $codexHome $profiles $state
        }
        catch { $code = [string]$_.Exception.Message }
        if ($code -cne 'PROFILE_IDENTITY_ALREADY_EXISTS' -or
            (Get-ActiveName -Module $module -StateDirectory $state) -cne $activeBefore) {
            throw ('MULTIACCOUNT_DUPLICATE_ADD_FAILED_' + $name)
        }
        $after = Get-ArtifactStamp -ProfilesDirectory $profiles
        $unexpectedProfileMutations += Assert-NoUnexpectedArtifactMutation `
            -Before $before -After $after
    }
    [System.IO.File]::WriteAllBytes((Join-Path $codexHome 'auth.json'),
        [byte[]]$expectedAuth[(Get-ActiveName -Module $module -StateDirectory $state)])

    # I. Same name with a different identity remains a name collision.
    $fakeA12 = New-FakeAuthBytes -Name 'A12' -Ordinal 12
    $nameCollisionCode = $null
    try {
        $null = Invoke-FakeAdd -Module $module -Name 'A01' -Bytes $fakeA12 `
            -CodexHome $codexHome -ProfilesDirectory $profiles `
            -StateDirectory $state
    }
    catch { $nameCollisionCode = [string]$_.Exception.Message }
    if ($nameCollisionCode -cne 'PROFILE_NAME_ALREADY_EXISTS') {
        throw 'MULTIACCOUNT_NAME_COLLISION_NOT_REJECTED'
    }
    [Array]::Clear($fakeA12, 0, $fakeA12.Length)
    [System.IO.File]::WriteAllBytes((Join-Path $codexHome 'auth.json'),
        [byte[]]$expectedAuth[(Get-ActiveName -Module $module -StateDirectory $state)])

    # E. The eleventh distinct account must succeed.
    $a11Bytes = New-FakeAuthBytes -Name 'A11' -Ordinal 11
    $expectedAuth['A11'] = $a11Bytes
    $before = Get-ArtifactStamp -ProfilesDirectory $profiles
    $a11Result = Invoke-FakeAdd -Module $module -Name 'A11' -Bytes $a11Bytes `
        -CodexHome $codexHome -ProfilesDirectory $profiles -StateDirectory $state
    if ($a11Result.Result -cne 'PROFILE_ADD_SUCCESS') {
        throw 'MULTIACCOUNT_ADD_11_FAILED'
    }
    $after = Get-ArtifactStamp -ProfilesDirectory $profiles
    $unexpectedProfileMutations += Assert-NoUnexpectedArtifactMutation `
        -Before $before -After $after
    $profileNames += 'A11'
    Assert-LiveState -Module $module -ExpectedActive 'A11' `
        -ExpectedAuth $expectedAuth -CodexHome $codexHome `
        -ProfilesDirectory $profiles -StateDirectory $state `
        -ProfileNames $profileNames

    # G. Rollback with eleven profiles: A03 -> A08 fails after replacement,
    # restores A03, then succeeds after the injected fault is removed.
    $null = Invoke-FakeSwitch -Module $module -Name 'A03' `
        -CodexHome $codexHome -ProfilesDirectory $profiles -StateDirectory $state
    $rollbackCode = $null
    try {
        $null = Invoke-FakeSwitch -Module $module -Name 'A08' `
            -CodexHome $codexHome -ProfilesDirectory $profiles `
            -StateDirectory $state -SimulateFailure
    }
    catch { $rollbackCode = [string]$_.Exception.Message }
    if ($rollbackCode -cne 'SWITCH_FAILED_ROLLED_BACK') {
        throw 'MULTIACCOUNT_ROLLBACK_CODE_FAILED'
    }
    Assert-LiveState -Module $module -ExpectedActive 'A03' `
        -ExpectedAuth $expectedAuth -CodexHome $codexHome `
        -ProfilesDirectory $profiles -StateDirectory $state `
        -ProfileNames $profileNames
    $retryResult = Invoke-FakeSwitch -Module $module -Name 'A08' `
        -CodexHome $codexHome -ProfilesDirectory $profiles -StateDirectory $state
    if ($retryResult.Result -cne 'SWITCH_SUCCESS') {
        throw 'MULTIACCOUNT_POST_ROLLBACK_RETRY_FAILED'
    }

    # F. One missing identity marker must isolate A06 without breaking the
    # remaining ten profiles or normal switches.
    $null = Invoke-FakeSwitch -Module $module -Name 'A03' `
        -CodexHome $codexHome -ProfilesDirectory $profiles -StateDirectory $state
    [System.IO.File]::Delete((Join-Path $profiles 'A06.identity.dpapi'))
    $rows = @(& $module {
        param($Profiles, $State)
        Get-CodexAccountSlotState -ProfilesDirectory $Profiles `
            -StateDirectory $State
    } $profiles $state)
    $a06Row = @($rows | Where-Object { $_.Profile -ceq 'A06' })[0]
    if ($rows.Count -ne 11 -or $a06Row.Health -cne 'INCOMPLETE_PROFILE') {
        throw 'MULTIACCOUNT_CORRUPT_PROFILE_NOT_ISOLATED'
    }
    foreach ($healthy in @($profileNames | Where-Object { $_ -cne 'A06' })) {
        Assert-ProfileLogicalState -Module $module -Name $healthy `
            -ExpectedBytes ([byte[]]$expectedAuth[$healthy]) `
            -ProfilesDirectory $profiles
    }
    $corruptCode = $null
    try {
        $null = Invoke-FakeSwitch -Module $module -Name 'A06' `
            -CodexHome $codexHome -ProfilesDirectory $profiles `
            -StateDirectory $state
    }
    catch { $corruptCode = [string]$_.Exception.Message }
    if ($corruptCode -cne 'PROFILE_IDENTITY_MARKER_MISSING') {
        throw 'MULTIACCOUNT_CORRUPT_PROFILE_SWITCH_NOT_BLOCKED'
    }
    $healthySwitch = Invoke-FakeSwitch -Module $module -Name 'A07' `
        -CodexHome $codexHome -ProfilesDirectory $profiles -StateDirectory $state
    if ($healthySwitch.Result -cne 'SWITCH_SUCCESS') {
        throw 'MULTIACCOUNT_HEALTHY_SWITCH_BLOCKED_BY_CORRUPT_PROFILE'
    }

    if ($unexpectedProfileMutations -ne 0 -or
        $identityCrossContamination -ne 0 -or
        $randomSwitchFailures -ne 0) {
        throw 'MULTIACCOUNT_STRESS_COUNTERS_NONZERO'
    }

    [pscustomobject]@{
        Result = 'PASS'
        MultiAccountAdd10 = 'PASS'
        MultiAccountCountAfterAdd10 = 10
        MultiAccountAdd11 = 'PASS'
        ForwardSwitchA01ToA10 = 'PASS'
        ReverseSwitchA10ToA01 = 'PASS'
        RandomSwitch100 = 'PASS'
        RandomSwitchIterations = 100
        RandomSwitchFailures = $randomSwitchFailures
        IdentityMismatchFailures = 0
        DuplicateAddAll10 = 'PASS'
        ProfileCountAfterDuplicateTest = 10
        SingleCorruptProfileIsolation = 'PASS'
        SwitchRollbackWith10Profiles = 'PASS'
        RestartPersistenceWith10Profiles = 'PASS'
        UnexpectedProfileMutations = $unexpectedProfileMutations
        IdentityCrossContamination = $identityCrossContamination
        FinalProfileCountBeforeCorruption = 11
        RealAuthOrProfileRead = $false
    }
}
finally {
    foreach ($bytes in @($expectedAuth.Values)) {
        if ($null -ne $bytes -and $bytes.Length -gt 0) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }
    if ([System.IO.Directory]::Exists($testRoot)) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
