[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $projectRoot 'lib\CodexAuth.psm1'
$module = Import-Module -Name $modulePath -Force -PassThru -ErrorAction Stop

function Assert-Audit {
    param([bool]$Condition, [string]$Code)
    if (-not $Condition) { throw $Code }
}

function Test-BytesEqual {
    param([byte[]]$Left, [byte[]]$Right)
    if ($null -eq $Left -or $null -eq $Right -or
        $Left.Length -ne $Right.Length) { return $false }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) { return $false }
    }
    return $true
}

function New-AuditAuthBytes {
    param([string]$Identity, [switch]$LegacyFourFields)
    $auth = [ordered]@{
        auth_mode = 'chatgpt'
        OPENAI_API_KEY = $null
        tokens = [ordered]@{
            id_token = 'AUDIT-FAKE-ID-' + $Identity
            access_token = 'AUDIT-FAKE-ACCESS-' + $Identity
            refresh_token = 'AUDIT-FAKE-REFRESH-' + $Identity
            account_id = 'AUDIT-FAKE-ACCOUNT-' + $Identity
        }
        last_refresh = '2000-01-01T00:00:00Z'
    }
    if (-not $LegacyFourFields) {
        $auth.future_optional = [ordered]@{ version = 2; fake = $true }
    }
    $json = $auth | ConvertTo-Json -Compress -Depth 8
    try {
        return ,(New-Object System.Text.UTF8Encoding($false, $true)).GetBytes($json)
    }
    finally { $json = $null; $auth = $null }
}

function Get-TreeStamp {
    param([string]$Root)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return (@(Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
        Sort-Object FullName | ForEach-Object {
            $_.FullName.Substring($rootFull.Length) + '|' +
                (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash +
                '|' + [string]$_.Length + '|' +
                [string]$_.LastWriteTimeUtc.Ticks
        }) -join "`n")
}

function New-AuditFixture {
    param(
        [string]$Root,
        $Module,
        [byte[]]$ABytes,
        [byte[]]$BBytes
    )
    $fixtureHome = Join-Path $Root 'codex-home'
    $profiles = Join-Path $Root 'profiles'
    $state = Join-Path $Root 'state'
    foreach ($directory in @($fixtureHome, $profiles, $state)) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $authPath = Join-Path $fixtureHome 'auth.json'
    [System.IO.File]::WriteAllBytes($authPath, $ABytes)
    & $Module {
        param($A, $B, $Profiles, $State)
        $null = Write-CodexAccountSlotBytes -Name 'A' -AuthBytes $A `
            -ProfilesDirectory $Profiles
        $null = Write-CodexAccountSlotBytes -Name 'B' -AuthBytes $B `
            -ProfilesDirectory $Profiles
        Write-ActiveProfileState -Name 'A' -StateDirectory $State
    } $ABytes $BBytes $profiles $state
    return [pscustomobject]@{
        Home = $fixtureHome
        Profiles = $profiles
        State = $state
        AuthPath = $authPath
    }
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

function Assert-CompleteProfile {
    param([string]$Name, [string]$ProfilesDirectory)
    foreach ($suffix in @('.auth.dpapi', '.identity.dpapi', '.meta.json')) {
        Assert-Audit -Condition ([System.IO.File]::Exists(
            (Join-Path $ProfilesDirectory ($Name + $suffix)))) `
            -Code ('AUDIT_PROFILE_ARTIFACT_MISSING_' + $Name + $suffix)
    }
}

function Assert-NoProfileFiles {
    param([string]$Name, [string]$ProfilesDirectory)
    foreach ($suffix in @('.auth.dpapi', '.identity.dpapi', '.meta.json')) {
        Assert-Audit -Condition (-not [System.IO.File]::Exists(
            (Join-Path $ProfilesDirectory ($Name + $suffix)))) `
            -Code ('AUDIT_ORPHAN_PROFILE_ARTIFACT_' + $Name + $suffix)
    }
}

function Invoke-AuditAdd {
    param(
        $Module,
        [string]$Name,
        [byte[]]$Bytes,
        [object]$Fixture
    )
    [System.IO.File]::WriteAllBytes($Fixture.AuthPath, $Bytes)
    return & $Module {
        param($Profile, $FixtureHome, $Profiles, $State)
        Invoke-AddCodexProfile -Name $Profile -CodexHome $FixtureHome `
            -ProfilesDirectory $Profiles -StateDirectory $State `
            -ProcessData @() -UseProvidedProcessData
    } $Name $Fixture.Home $Fixture.Profiles $Fixture.State
}

$testsRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$unicodeAuditSegment = -join @(
    [char]0x957F, [char]0x671F, [char]0x5B89, [char]0x5168,
    [char]0x5BA1, [char]0x8BA1
)
$auditRoot = [System.IO.Path]::GetFullPath((Join-Path $testsRoot (
    '.audit-' + $unicodeAuditSegment + '-' + [Guid]::NewGuid().ToString('N')
)))
Assert-Audit -Condition ($auditRoot.StartsWith(
        $testsRoot.TrimEnd('\') + '\',
        [StringComparison]::OrdinalIgnoreCase
    )) -Code 'AUDIT_TEMP_PATH_OUTSIDE_TESTS'

$aBytes = New-AuditAuthBytes -Identity 'A'
$bBytes = New-AuditAuthBytes -Identity 'B'
$cBytes = New-AuditAuthBytes -Identity 'C'
$xBytes = New-AuditAuthBytes -Identity 'EXTERNAL-X'
$legacyBytes = New-AuditAuthBytes -Identity 'LEGACY' -LegacyFourFields
$findings = New-Object System.Collections.ArrayList
$deleteFailureRollback = 'PASS'
$deleteFailureOrphanFiles = 0
$deleteFailureCases = New-Object System.Collections.ArrayList
$nonAdministratorExecution = 'NOT_PROVEN'

try {
    [System.IO.Directory]::CreateDirectory($auditRoot) | Out-Null

    # 1. External identity drift during Switch must fail before any profile or
    # state write and must leave the external X auth file untouched.
    $drift = New-AuditFixture -Root (Join-Path $auditRoot '01-external-drift') `
        -Module $module -ABytes $aBytes -BBytes $bBytes
    [System.IO.File]::WriteAllBytes($drift.AuthPath, $xBytes)
    $driftProfilesBefore = Get-TreeStamp -Root $drift.Profiles
    $driftStateBefore = Get-TreeStamp -Root $drift.State
    $driftCode = $null
    try {
        $null = & $module {
            param($Fixture)
            Invoke-CodexAccountSwitch -Name 'B' -CodexHome $Fixture.Home `
                -ProfilesDirectory $Fixture.Profiles `
                -StateDirectory $Fixture.State -ProcessData @() `
                -UseProvidedProcessData
        } $drift
    }
    catch { $driftCode = [string]$_.Exception.Message }
    $driftLive = [System.IO.File]::ReadAllBytes($drift.AuthPath)
    try {
        Assert-Audit -Condition (
            $driftCode -ceq 'ACTIVE_PROFILE_IDENTITY_MISMATCH' -and
            (Get-TreeStamp -Root $drift.Profiles) -ceq $driftProfilesBefore -and
            (Get-TreeStamp -Root $drift.State) -ceq $driftStateBefore -and
            (Test-BytesEqual -Left $driftLive -Right $xBytes) -and
            (Get-ActiveName -Module $module -StateDirectory $drift.State) -ceq 'A'
        ) -Code 'AUDIT_SWITCH_EXTERNAL_DRIFT_CONTAMINATED_STATE'
    }
    finally { [Array]::Clear($driftLive, 0, $driftLive.Length) }

    # 2a. Deleting a non-active profile must remove all three artifacts and
    # leave Active pointing to the existing A profile.
    $deleteNormal = New-AuditFixture `
        -Root (Join-Path $auditRoot '02a-delete-nonactive') `
        -Module $module -ABytes $aBytes -BBytes $bBytes
    $deleteResult = & $module {
        param($Fixture)
        Invoke-RemoveCodexProfile -Name 'B' `
            -ProfilesDirectory $Fixture.Profiles `
            -StateDirectory $Fixture.State -ConfirmDelete
    } $deleteNormal
    Assert-Audit -Condition (
        $deleteResult.Result -ceq 'PROFILE_REMOVE_SUCCESS' -and
        (Get-ActiveName -Module $module -StateDirectory $deleteNormal.State) -ceq 'A'
    ) -Code 'AUDIT_DELETE_NONACTIVE_RESULT_OR_ACTIVE_INVALID'
    Assert-NoProfileFiles -Name 'B' -ProfilesDirectory $deleteNormal.Profiles
    Assert-CompleteProfile -Name 'A' -ProfilesDirectory $deleteNormal.Profiles

    # 2b. Deleting the active profile must fail without touching any artifact.
    $deleteActive = New-AuditFixture `
        -Root (Join-Path $auditRoot '02b-delete-active') `
        -Module $module -ABytes $aBytes -BBytes $bBytes
    $deleteActiveBefore = Get-TreeStamp -Root $deleteActive.Profiles
    $deleteActiveCode = $null
    try {
        $null = & $module {
            param($Fixture)
            Invoke-RemoveCodexProfile -Name 'A' `
                -ProfilesDirectory $Fixture.Profiles `
                -StateDirectory $Fixture.State -ConfirmDelete
        } $deleteActive
    }
    catch { $deleteActiveCode = [string]$_.Exception.Message }
    Assert-Audit -Condition (
        $deleteActiveCode -ceq 'CANNOT_REMOVE_ACTIVE_PROFILE' -and
        (Get-TreeStamp -Root $deleteActive.Profiles) -ceq $deleteActiveBefore -and
        (Get-ActiveName -Module $module -StateDirectory $deleteActive.State) -ceq 'A'
    ) -Code 'AUDIT_DELETE_ACTIVE_DID_NOT_FAIL_CLOSED'

    # 2c. Every quarantine move failure must restore the complete formal
    # Profile and leave no half-deleted state.
    foreach ($failureType in @('AuthFile', 'IdentityMarker', 'Metadata')) {
        $deleteFailure = New-AuditFixture `
            -Root (Join-Path $auditRoot ('02c-delete-failure-' + $failureType)) `
            -Module $module -ABytes $aBytes -BBytes $bBytes
        $deleteFailureBefore = Get-TreeStamp -Root $deleteFailure.Profiles
        $deleteFailureResult = & $module {
            param($Fixture, $FailureType)
            Invoke-RemoveCodexProfile -Name 'B' `
                -ProfilesDirectory $Fixture.Profiles `
                -StateDirectory $Fixture.State -ConfirmDelete `
                -SimulateDeleteFailureType $FailureType
        } $deleteFailure $failureType
        $deleteFailureAfter = Get-TreeStamp -Root $deleteFailure.Profiles
        $remainingArtifacts = 0
        foreach ($suffix in @('.auth.dpapi', '.identity.dpapi', '.meta.json')) {
            if ([System.IO.File]::Exists(
                    (Join-Path $deleteFailure.Profiles ('B' + $suffix)))) {
                $remainingArtifacts++
            }
        }
        $deleteFailureOrphanFiles += $remainingArtifacts
        [void]$deleteFailureCases.Add(
            ($failureType + ':' + $remainingArtifacts))
        if ($deleteFailureResult.Result -cne 'PROFILE_REMOVE_FAILED_ROLLED_BACK' -or
            $deleteFailureAfter -cne $deleteFailureBefore -or
            $remainingArtifacts -ne 3) {
            $deleteFailureRollback = 'FAIL'
        }
        Assert-Audit -Condition (
            (Get-ActiveName -Module $module `
                -StateDirectory $deleteFailure.State) -ceq 'A' -and
            [System.IO.File]::Exists(
                (Join-Path $deleteFailure.Profiles 'A.auth.dpapi'))
        ) -Code ('AUDIT_DELETE_FAILURE_CORRUPTED_ACTIVE_PROFILE_' + $failureType)
    }
    if ($deleteFailureRollback -ceq 'FAIL') {
        [void]$findings.Add('P1_DELETE_PARTIAL_FAILURE_NO_ROLLBACK')
    }

    # 3a. ADD: auth container succeeds, identity marker write fails. The newly
    # written auth container must be removed and Active must remain A.
    $addIdentityFailure = New-AuditFixture `
        -Root (Join-Path $auditRoot '03a-identity-write-failure') `
        -Module $module -ABytes $aBytes -BBytes $bBytes
    [System.IO.Directory]::CreateDirectory((Join-Path `
        $addIdentityFailure.Profiles 'C.identity.dpapi')) | Out-Null
    $addIdentityCode = $null
    try {
        $null = Invoke-AuditAdd -Module $module -Name 'C' -Bytes $cBytes `
            -Fixture $addIdentityFailure
    }
    catch { $addIdentityCode = [string]$_.Exception.Message }
    Assert-Audit -Condition (
        $addIdentityCode -ceq 'ATOMIC_WRITE_FAILED' -and
        (Get-ActiveName -Module $module `
            -StateDirectory $addIdentityFailure.State) -ceq 'A'
    ) -Code 'AUDIT_ADD_IDENTITY_FAILURE_CODE_OR_ACTIVE_INVALID'
    Assert-NoProfileFiles -Name 'C' `
        -ProfilesDirectory $addIdentityFailure.Profiles

    # 3b. ADD: auth and identity succeed, metadata write fails. Both completed
    # artifacts must be removed.
    $addMetadataFailure = New-AuditFixture `
        -Root (Join-Path $auditRoot '03b-metadata-write-failure') `
        -Module $module -ABytes $aBytes -BBytes $bBytes
    [System.IO.Directory]::CreateDirectory((Join-Path `
        $addMetadataFailure.Profiles 'C.meta.json')) | Out-Null
    $addMetadataCode = $null
    try {
        $null = Invoke-AuditAdd -Module $module -Name 'C' -Bytes $cBytes `
            -Fixture $addMetadataFailure
    }
    catch { $addMetadataCode = [string]$_.Exception.Message }
    Assert-Audit -Condition (
        $addMetadataCode -ceq 'ATOMIC_WRITE_FAILED' -and
        (Get-ActiveName -Module $module `
            -StateDirectory $addMetadataFailure.State) -ceq 'A'
    ) -Code 'AUDIT_ADD_METADATA_FAILURE_CODE_OR_ACTIVE_INVALID'
    Assert-NoProfileFiles -Name 'C' `
        -ProfilesDirectory $addMetadataFailure.Profiles

    # 3c. ADD readback verification failure is injected by replacing only the
    # internal reader in this disposable module instance. Production files are
    # not modified; the module is immediately reloaded after the scenario.
    $addReadbackFailure = New-AuditFixture `
        -Root (Join-Path $auditRoot '03c-readback-failure') `
        -Module $module -ABytes $aBytes -BBytes $bBytes
    & $module {
        Set-Item -Path Function:script:Read-CodexAccountSlotBytes -Value {
            param([string]$Name, [string]$ProfilesDirectory)
            throw (New-SafeException -Code 'PROFILE_ADD_VERIFICATION_FAILED')
        }
    }
    $addReadbackCode = $null
    try {
        $null = Invoke-AuditAdd -Module $module -Name 'C' -Bytes $cBytes `
            -Fixture $addReadbackFailure
    }
    catch { $addReadbackCode = [string]$_.Exception.Message }
    Assert-Audit -Condition (
        $addReadbackCode -ceq 'PROFILE_ADD_VERIFICATION_FAILED' -and
        (Get-ActiveName -Module $module `
            -StateDirectory $addReadbackFailure.State) -ceq 'A'
    ) -Code 'AUDIT_ADD_READBACK_FAILURE_CODE_OR_ACTIVE_INVALID'
    Assert-NoProfileFiles -Name 'C' `
        -ProfilesDirectory $addReadbackFailure.Profiles
    Remove-Module -ModuleInfo $module -Force
    $module = Import-Module -Name $modulePath -Force -PassThru -ErrorAction Stop

    # 3d. SWITCH readback failure must restore both live auth and active state.
    $switchFailure = New-AuditFixture `
        -Root (Join-Path $auditRoot '03d-switch-readback-failure') `
        -Module $module -ABytes $aBytes -BBytes $bBytes
    $switchFailureCode = $null
    try {
        $null = & $module {
            param($Fixture)
            Invoke-CodexAccountSwitch -Name 'B' -CodexHome $Fixture.Home `
                -ProfilesDirectory $Fixture.Profiles `
                -StateDirectory $Fixture.State -ProcessData @() `
                -UseProvidedProcessData `
                -SimulatePostReplaceVerificationFailure
        } $switchFailure
    }
    catch { $switchFailureCode = [string]$_.Exception.Message }
    $switchLive = [System.IO.File]::ReadAllBytes($switchFailure.AuthPath)
    try {
        Assert-Audit -Condition (
            $switchFailureCode -ceq 'SWITCH_FAILED_ROLLED_BACK' -and
            (Get-ActiveName -Module $module `
                -StateDirectory $switchFailure.State) -ceq 'A' -and
            (Test-BytesEqual -Left $switchLive -Right $aBytes)
        ) -Code 'AUDIT_SWITCH_READBACK_ROLLBACK_FAILED'
    }
    finally { [Array]::Clear($switchLive, 0, $switchLive.Length) }

    # 4. Upgrade compatibility: the original four-field auth schema and the
    # metadata schema from the earliest repository baseline must remain valid.
    $legacy = New-AuditFixture -Root (Join-Path $auditRoot '04-legacy') `
        -Module $module -ABytes $aBytes -BBytes $bBytes
    $legacyResult = Invoke-AuditAdd -Module $module -Name 'Legacy' `
        -Bytes $legacyBytes -Fixture $legacy
    Assert-Audit -Condition ($legacyResult.Result -ceq 'PROFILE_ADD_SUCCESS') `
        -Code 'AUDIT_LEGACY_FOUR_FIELD_AUTH_REJECTED'
    $legacyMetaPath = Join-Path $legacy.Profiles 'Legacy.meta.json'
    $legacyContainerLength = ([System.IO.FileInfo](Join-Path `
        $legacy.Profiles 'Legacy.auth.dpapi')).Length
    $legacyMeta = [ordered]@{
        schema_version = 1
        profile_name = 'Legacy'
        created_at = '2000-01-01T00:00:00.0000000Z'
        updated_at = '2000-01-01T00:00:00.0000000Z'
        encrypted_file_name = 'Legacy.auth.dpapi'
        encrypted_file_size = $legacyContainerLength
        dpapi_scope = 'CurrentUser'
    }
    [System.IO.File]::WriteAllText(
        $legacyMetaPath,
        ($legacyMeta | ConvertTo-Json -Compress),
        (New-Object System.Text.UTF8Encoding($false))
    )
    $legacyRows = @(& $module {
        param($Profiles, $State)
        Get-CodexAccountSlotState -ProfilesDirectory $Profiles `
            -StateDirectory $State
    } $legacy.Profiles $legacy.State)
    $legacyRow = @($legacyRows | Where-Object {
        $_.Profile -ceq 'Legacy'
    })[0]
    $legacyRoundTrip = Read-ProfileBytes -Module $module -Name 'Legacy' `
        -ProfilesDirectory $legacy.Profiles
    try {
        Assert-Audit -Condition (
            $legacyRow.Health -ceq 'READY' -and
            (Test-BytesEqual -Left $legacyRoundTrip -Right $legacyBytes)
        ) -Code 'AUDIT_LEGACY_PROFILE_OR_METADATA_NOT_COMPATIBLE'
    }
    finally { [Array]::Clear($legacyRoundTrip, 0, $legacyRoundTrip.Length) }

    # 5. Chinese paths, current-user DPAPI, ordinary-user execution and module
    # reload must work without an administrator-only API or in-memory cache.
    $chinese = New-AuditFixture `
        -Root (Join-Path $auditRoot '05-unicode-standard-restart') `
        -Module $module -ABytes $aBytes -BBytes $bBytes
    $chineseBefore = Get-TreeStamp -Root $chinese.Profiles
    Remove-Module -ModuleInfo $module -Force
    $module = Import-Module -Name $modulePath -Force -PassThru -ErrorAction Stop
    $chineseRows = @(& $module {
        param($Profiles, $State)
        Get-CodexAccountSlotState -ProfilesDirectory $Profiles `
            -StateDirectory $State
    } $chinese.Profiles $chinese.State)
    $chineseA = Read-ProfileBytes -Module $module -Name 'A' `
        -ProfilesDirectory $chinese.Profiles
    try {
        Assert-Audit -Condition (
            $chineseRows.Count -eq 2 -and
            (Get-ActiveName -Module $module `
                -StateDirectory $chinese.State) -ceq 'A' -and
            (Test-BytesEqual -Left $chineseA -Right $aBytes) -and
            (Get-TreeStamp -Root $chinese.Profiles) -ceq $chineseBefore
        ) -Code 'AUDIT_CHINESE_PATH_OR_RESTART_RECOVERY_FAILED'
    }
    finally { [Array]::Clear($chineseA, 0, $chineseA.Length) }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    $isElevated = $principal.IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )
    $nonAdministratorExecution = if ($isElevated) {
        'NOT_PROVEN_ELEVATED_HOST'
    }
    else { 'PASS' }
    if ($isElevated) {
        [void]$findings.Add('COVERAGE_NON_ADMIN_NOT_PROVEN_ON_ELEVATED_HOST')
    }

    $auditResult = if ($findings.Count -eq 0) { 'PASS' } else { 'ISSUES_FOUND' }
    [pscustomobject]@{
        Result = $auditResult
        SwitchExternalIdentityDriftFailClosed = 'PASS'
        SwitchExternalIdentityDriftCode = $driftCode
        ExternalIdentityDidNotOverwriteActive = 'PASS'
        DeleteNonActiveNoOrphans = 'PASS'
        DeleteActiveRejected = 'PASS'
        DeleteFailureRollback = $deleteFailureRollback
        DeleteFailureCasesTested = $deleteFailureCases.Count
        DeleteFailureRemainingByCase = @($deleteFailureCases)
        DeleteFailureFormalArtifactsPreserved = $deleteFailureOrphanFiles
        DeleteFailureActiveStateSafe = 'PASS'
        AddAuthThenIdentityFailureRollback = 'PASS'
        AddIdentityThenMetadataFailureRollback = 'PASS'
        AddReadbackFailureRollback = 'PASS'
        SwitchReadbackFailureRollback = 'PASS'
        LegacyFourFieldAuthReadable = 'PASS'
        LegacyBaselineMetadataReadable = 'PASS'
        ChinesePath = 'PASS'
        DpapiCurrentUserRoundTrip = 'PASS'
        RestartRecovery = 'PASS'
        NonAdministratorExecution = $nonAdministratorExecution
        Findings = @($findings)
        RealAuthOrProfileRead = $false
    }
}
finally {
    foreach ($bytes in @($aBytes, $bBytes, $cBytes, $xBytes, $legacyBytes)) {
        if ($null -ne $bytes -and $bytes.Length -gt 0) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }
    if ([System.IO.Directory]::Exists($auditRoot)) {
        [System.IO.Directory]::Delete($auditRoot, $true)
    }
}
