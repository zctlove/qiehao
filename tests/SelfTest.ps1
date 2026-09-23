[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path -Path $projectRoot -ChildPath 'lib\CodexAuth.psm1'
$module = Import-Module -Name $modulePath -Force -PassThru -ErrorAction Stop

function Test-ByteArrayEqual {
    param(
        [byte[]]$Left,
        [byte[]]$Right
    )

    if ($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length) {
        return $false
    }
    for ($index = 0; $index -lt $Left.Length; $index++) {
        if ($Left[$index] -ne $Right[$index]) {
            return $false
        }
    }
    return $true
}

function Assert-FakeAuthRejected {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSModuleInfo]$Module,

        [Parameter(Mandatory = $true)]
        [string]$Json,

        [Parameter(Mandatory = $true)]
        [string[]]$ExpectedCodes,

        [Parameter(Mandatory = $true)]
        [string]$FailureCode
    )

    $bytes = (New-Object System.Text.UTF8Encoding($false, $true)).GetBytes($Json)
    $actualCode = $null
    try {
        & $Module {
            param($AuthBytes)
            $null = Test-CodexAuthBytes -Bytes $AuthBytes
        } $bytes
    }
    catch {
        $actualCode = [string]$_.Exception.Message
    }
    finally {
        if ($bytes.Length -gt 0) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }

    if ($ExpectedCodes -cnotcontains $actualCode) {
        throw $FailureCode
    }
}

function Get-FakeTreeStamp {
    param([Parameter(Mandatory = $true)][string]$Root)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd('\') + '\'
    return (@(Get-ChildItem -LiteralPath $Root -File -Recurse | Sort-Object FullName | ForEach-Object {
        $relative = $_.FullName.Substring($rootFull.Length)
        $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        $relative + '|' + [string]$_.Length + '|' +
            [string]$_.LastWriteTimeUtc.Ticks + '|' + $hash
    }) -join "`n")
}

function ConvertTo-FakeBase64Url {
    param([Parameter(Mandatory = $true)][byte[]]$Bytes)
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function New-FakeIdToken {
    param(
        [Parameter(Mandatory = $true)][string]$UserIdentity,
        [Parameter(Mandatory = $true)][string]$PlanType,
        [Parameter(Mandatory = $true)][string]$WorkspaceAccountId
    )
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $headerBytes = $null
    $payloadBytes = $null
    try {
        $headerBytes = $utf8.GetBytes('{"alg":"none","typ":"JWT"}')
        $payloadJson = [ordered]@{
            'https://api.openai.com/auth' = [ordered]@{
                chatgpt_account_id = $WorkspaceAccountId
                chatgpt_user_id = $UserIdentity
                chatgpt_plan_type = $PlanType
            }
        } | ConvertTo-Json -Compress
        $payloadBytes = $utf8.GetBytes($payloadJson)
        return (ConvertTo-FakeBase64Url -Bytes $headerBytes) + '.' +
            (ConvertTo-FakeBase64Url -Bytes $payloadBytes) + '.fake'
    }
    finally {
        foreach ($buffer in @($headerBytes, $payloadBytes)) {
            if ($null -ne $buffer -and $buffer.Length -gt 0) {
                [Array]::Clear($buffer, 0, $buffer.Length)
            }
        }
        $payloadJson = $null
    }
}

function New-FakeAuthBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Identity,

        [Parameter(Mandatory = $true)]
        [string]$CredentialRevision,

        [string]$UserIdentity,

        [string]$PlanType,

        [string]$WorkspaceClaimIdentity
    )

    $fakeIdToken = if (
        -not [string]::IsNullOrWhiteSpace($UserIdentity) -and
        -not [string]::IsNullOrWhiteSpace($PlanType)
    ) {
        New-FakeIdToken -UserIdentity $UserIdentity -PlanType $PlanType `
            -WorkspaceAccountId $(if ([string]::IsNullOrWhiteSpace(
                    $WorkspaceClaimIdentity
                )) { $Identity } else { $WorkspaceClaimIdentity })
    }
    else { 'SELFTEST-ID-' + $CredentialRevision }

    $authObject = [ordered]@{
        auth_mode = 'chatgpt'
        OPENAI_API_KEY = $null
        tokens = [ordered]@{
            id_token = $fakeIdToken
            access_token = 'SELFTEST-ACCESS-' + $CredentialRevision
            refresh_token = 'SELFTEST-REFRESH-' + $CredentialRevision
            account_id = $Identity
        }
        last_refresh = '2000-01-01T00:00:00Z'
    }
    $json = $authObject | ConvertTo-Json -Compress
    try {
        return ,(New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    }
    finally {
        $authObject = $null
        $json = $null
        $fakeIdToken = $null
    }
}

function New-SwitchFixture {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Root,

        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSModuleInfo]$Module,

        [Parameter(Mandatory = $true)]
        [byte[]]$ActiveBytes,

        [Parameter(Mandatory = $true)]
        [byte[]]$TargetBytes,

        [switch]$SkipActiveState,

        [switch]$CorruptTargetDpapi,

        [switch]$AllowInvalidTargetSchema
    )

    $codexHome = Join-Path -Path $Root -ChildPath 'codex-home'
    $profiles = Join-Path -Path $Root -ChildPath 'profiles'
    $state = Join-Path -Path $Root -ChildPath 'state'
    [System.IO.Directory]::CreateDirectory($codexHome) | Out-Null
    [System.IO.Directory]::CreateDirectory($profiles) | Out-Null
    [System.IO.Directory]::CreateDirectory($state) | Out-Null
    $authPath = Join-Path -Path $codexHome -ChildPath 'auth.json'
    [System.IO.File]::WriteAllBytes($authPath, $ActiveBytes)

    & $Module {
        param($Bytes, $Profiles)
        $null = Write-CodexAccountSlotBytes -Name 'A' -AuthBytes $Bytes `
            -ProfilesDirectory $Profiles
    } $ActiveBytes $profiles

    $targetPath = Join-Path -Path $profiles -ChildPath 'B.auth.dpapi'
    if ($CorruptTargetDpapi) {
        [System.IO.File]::WriteAllBytes($targetPath, [byte[]](1, 2, 3, 4, 5))
    }
    elseif ($AllowInvalidTargetSchema) {
        $invalidEncrypted = Protect-CodexAuthBytes -Data $TargetBytes
        try {
            [System.IO.File]::WriteAllBytes($targetPath, $invalidEncrypted)
        }
        finally {
            if ($null -ne $invalidEncrypted -and $invalidEncrypted.Length -gt 0) {
                [Array]::Clear($invalidEncrypted, 0, $invalidEncrypted.Length)
            }
        }
    }
    else {
        & $Module {
            param($Bytes, $Profiles)
            $null = Write-CodexAccountSlotBytes -Name 'B' -AuthBytes $Bytes `
                -ProfilesDirectory $Profiles
        } $TargetBytes $profiles
    }

    if (-not $SkipActiveState) {
        & $Module {
            param($CodexHome, $Profiles, $State)
            $null = Invoke-InitializeCodexActiveProfile -Name 'A' `
                -CodexHome $CodexHome -ProfilesDirectory $Profiles `
                -StateDirectory $State -ProcessData @() -UseProvidedProcessData
        } $codexHome $profiles $state
    }

    return [pscustomobject]@{
        CodexHome = $codexHome
        Profiles = $profiles
        State = $state
        AuthPath = $authPath
    }
}

function Invoke-FakeSwitch {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.PSModuleInfo]$Module,

        [Parameter(Mandatory = $true)]
        [object]$Fixture,

        [Parameter(Mandatory = $true)]
        [string]$Target,

        [object[]]$ProcessData = @(),

        [switch]$SimulatePostReplaceVerificationFailure
    )

    return & $Module {
        param($Target, $Fixture, $ProcessData, $SimulateFailure)
        Invoke-CodexAccountSwitch -Name $Target `
            -CodexHome $Fixture.CodexHome `
            -ProfilesDirectory $Fixture.Profiles `
            -StateDirectory $Fixture.State `
            -ProcessData $ProcessData -UseProvidedProcessData `
            -SimulatePostReplaceVerificationFailure:$SimulateFailure
    } $Target $Fixture $ProcessData $SimulatePostReplaceVerificationFailure
}

$fakeJson = @'
{
  "auth_mode": "chatgpt",
  "OPENAI_API_KEY": null,
  "tokens": {
    "id_token": "SELFTEST-ID-LEGACY",
    "access_token": "SELFTEST-ACCESS-LEGACY",
    "refresh_token": "SELFTEST-REFRESH-LEGACY",
    "account_id": "SELFTEST-ACCOUNT-LEGACY"
  },
  "last_refresh": "2000-01-01T00:00:00Z"
}
'@

$testsRoot = [System.IO.Path]::GetFullPath($PSScriptRoot)
$workDirectory = Join-Path -Path $testsRoot -ChildPath (
    '.selftest-' + [Guid]::NewGuid().ToString('N')
)
$workDirectoryFull = [System.IO.Path]::GetFullPath($workDirectory)
$requiredPrefix = $testsRoot.TrimEnd('\') + '\'
if (-not $workDirectoryFull.StartsWith($requiredPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'SELFTEST_PATH_SAFETY_FAILED'
}

$fakeAuthPath = Join-Path -Path $workDirectoryFull -ChildPath 'auth.json'
$agentIdentityAuthPath = Join-Path -Path $workDirectoryFull -ChildPath 'agent-identity-auth.json'
$unknownOptionalAuthPath = Join-Path -Path $workDirectoryFull -ChildPath 'unknown-optional-auth.json'
$temporaryWritePath = Join-Path -Path $workDirectoryFull -ChildPath 'SelfTest.auth.dpapi'
$plainBytes = $null
$agentIdentityBytes = $null
$unknownOptionalBytes = $null
$forwardRoundTripBytes = $null
$forwardIdentityBytes = $null
$protectedBytes = $null
$unprotectedBytes = $null
$roundTripBytes = $null
$fakeAInitial = $null
$fakeARefreshed = $null
$fakeB = $null
$fakeC = $null
$fakeX = $null
$fakeWorkspaceTeam = $null
$fakeWorkspacePersonal = $null
$fakeWorkspaceClaimMismatch = $null
$fakeInvalidB = $null
$fakeIdentitySchemaUnknown = $null

try {
    [System.IO.Directory]::CreateDirectory($workDirectoryFull) | Out-Null
    $diagnosticLogDirectory = Join-Path $workDirectoryFull 'diagnostic-logs'
    [System.IO.Directory]::CreateDirectory($diagnosticLogDirectory) | Out-Null
    & $module {
        param($Directory)
        $script:LogsDirectory = $Directory
    } $diagnosticLogDirectory
    $plainBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($fakeJson)
    [System.IO.File]::WriteAllBytes($fakeAuthPath, $plainBytes)

    $validation = Test-CodexAuthFile -Path $fakeAuthPath
    if (-not $validation.SchemaExpected) {
        throw 'SELFTEST_SCHEMA_VALIDATION_FAILED'
    }

    $agentIdentityJson = $fakeJson.TrimEnd() -replace '\}\s*$', `
        ',"agent_identity":"SELFTEST-AGENT-IDENTITY"}'
    $agentIdentityBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(
        $agentIdentityJson
    )
    [System.IO.File]::WriteAllBytes($agentIdentityAuthPath, $agentIdentityBytes)
    $agentIdentityValidation = Test-CodexAuthFile -Path $agentIdentityAuthPath
    if (-not $agentIdentityValidation.SchemaExpected) {
        throw 'SELFTEST_AGENT_IDENTITY_FIELD_NOT_ACCEPTED'
    }

    $unknownOptionalJson = $fakeJson.TrimEnd() -replace '\}\s*$', `
        ',"future_optional":{"enabled":true,"version":2}}'
    $unknownOptionalBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(
        $unknownOptionalJson
    )
    [System.IO.File]::WriteAllBytes($unknownOptionalAuthPath, $unknownOptionalBytes)
    $unknownOptionalValidation = Test-CodexAuthFile -Path $unknownOptionalAuthPath
    if (-not $unknownOptionalValidation.SchemaExpected) {
        throw 'SELFTEST_UNKNOWN_OPTIONAL_FIELD_NOT_ACCEPTED'
    }

    $forwardProfiles = Join-Path $workDirectoryFull 'forward-compatible-profiles'
    [System.IO.Directory]::CreateDirectory($forwardProfiles) | Out-Null
    & $module {
        param($Bytes, $Profiles)
        $null = Write-CodexAccountSlotBytes -Name 'ForwardCompatible' `
            -AuthBytes $Bytes -ProfilesDirectory $Profiles
    } $unknownOptionalBytes $forwardProfiles
    $forwardRoundTripBytes = & $module {
        param($Profiles)
        Read-CodexAccountSlotBytes -Name 'ForwardCompatible' `
            -ProfilesDirectory $Profiles
    } $forwardProfiles
    $forwardIdentityBytes = & $module {
        param($Bytes)
        Get-CodexAuthIdentityBytes -Bytes $Bytes
    } $unknownOptionalBytes
    if (-not (Test-ByteArrayEqual -Left $unknownOptionalBytes `
            -Right $forwardRoundTripBytes) -or
        $forwardIdentityBytes.Length -le 0) {
        throw 'SELFTEST_FORWARD_COMPATIBLE_BYTES_NOT_PRESERVED'
    }

    Assert-FakeAuthRejected -Module $module -Json '{BROKEN JSON' `
        -ExpectedCodes @('AUTH_JSON_INVALID') `
        -FailureCode 'SELFTEST_DAMAGED_JSON_NOT_REJECTED'
    Assert-FakeAuthRejected -Module $module -Json '[]' `
        -ExpectedCodes @('AUTH_SCHEMA_UNEXPECTED') `
        -FailureCode 'SELFTEST_NON_OBJECT_ROOT_NOT_REJECTED'
    Assert-FakeAuthRejected -Module $module `
        -Json '{"tokens":{"account_id":"SELFTEST"}}' `
        -ExpectedCodes @('AUTH_SCHEMA_UNEXPECTED') `
        -FailureCode 'SELFTEST_MISSING_AUTH_MODE_NOT_REJECTED'
    Assert-FakeAuthRejected -Module $module `
        -Json '{"auth_mode":"api_key","tokens":{"account_id":"SELFTEST"}}' `
        -ExpectedCodes @('AUTH_IDENTITY_SCHEMA_UNRECOGNIZED') `
        -FailureCode 'SELFTEST_ILLEGAL_AUTH_MODE_NOT_REJECTED'
    Assert-FakeAuthRejected -Module $module `
        -Json '{"auth_mode":"chatgpt"}' `
        -ExpectedCodes @('AUTH_SCHEMA_UNEXPECTED') `
        -FailureCode 'SELFTEST_MISSING_TOKENS_NOT_REJECTED'
    Assert-FakeAuthRejected -Module $module `
        -Json '{"auth_mode":"chatgpt","tokens":"invalid"}' `
        -ExpectedCodes @('AUTH_IDENTITY_SCHEMA_UNRECOGNIZED') `
        -FailureCode 'SELFTEST_NON_OBJECT_TOKENS_NOT_REJECTED'
    Assert-FakeAuthRejected -Module $module `
        -Json '{"auth_mode":"chatgpt","tokens":{}}' `
        -ExpectedCodes @('AUTH_IDENTITY_SCHEMA_UNRECOGNIZED') `
        -FailureCode 'SELFTEST_MISSING_ACCOUNT_ID_NOT_REJECTED'
    Assert-FakeAuthRejected -Module $module `
        -Json '{"auth_mode":"chatgpt","tokens":{"account_id":123}}' `
        -ExpectedCodes @('AUTH_IDENTITY_SCHEMA_UNRECOGNIZED') `
        -FailureCode 'SELFTEST_NON_STRING_ACCOUNT_ID_NOT_REJECTED'
    Assert-FakeAuthRejected -Module $module `
        -Json '{"auth_mode":"chatgpt","tokens":{"account_id":"   "}}' `
        -ExpectedCodes @('AUTH_IDENTITY_SCHEMA_UNRECOGNIZED') `
        -FailureCode 'SELFTEST_EMPTY_ACCOUNT_ID_NOT_REJECTED'
    Assert-FakeAuthRejected -Module $module `
        -Json '{"auth_mode":"chatgpt","auth_mode":"chatgpt","tokens":{"account_id":"SELFTEST"}}' `
        -ExpectedCodes @('AUTH_SCHEMA_UNEXPECTED') `
        -FailureCode 'SELFTEST_DUPLICATE_AUTH_MODE_NOT_REJECTED'
    Assert-FakeAuthRejected -Module $module `
        -Json '{"auth_mode":"chatgpt","tokens":{"account_id":"SELFTEST-A","account_id":"SELFTEST-B"}}' `
        -ExpectedCodes @('AUTH_IDENTITY_SCHEMA_UNRECOGNIZED') `
        -FailureCode 'SELFTEST_DUPLICATE_ACCOUNT_ID_NOT_REJECTED'

    $protectedBytes = Protect-CodexAuthBytes -Data $plainBytes
    $unprotectedBytes = Unprotect-CodexAuthBytes -Data $protectedBytes
    if (-not (Test-ByteArrayEqual -Left $plainBytes -Right $unprotectedBytes)) {
        throw 'SELFTEST_DPAPI_ROUNDTRIP_FAILED'
    }

    # Exercise the module's real temporary-file -> flush -> atomic-move writer
    # without invoking Save-CodexAccountSlot or reading the real Codex home.
    & $module {
        param($Path, $Bytes)
        Write-AtomicByteFile -Path $Path -Bytes $Bytes
    } $temporaryWritePath $protectedBytes

    $overwriteRejected = $false
    try {
        & $module {
            param($Path, $Bytes)
            Write-AtomicByteFile -Path $Path -Bytes $Bytes
        } $temporaryWritePath $protectedBytes
    }
    catch {
        $overwriteRejected = $_.Exception.Message -ceq 'PROFILE_EXISTS'
    }
    if (-not $overwriteRejected) {
        throw 'SELFTEST_DEFAULT_OVERWRITE_NOT_REJECTED'
    }

    $storedBytes = [System.IO.File]::ReadAllBytes($temporaryWritePath)
    try {
        $roundTripBytes = Unprotect-CodexAuthBytes -Data $storedBytes
    }
    finally {
        if ($null -ne $storedBytes -and $storedBytes.Length -gt 0) {
            [Array]::Clear($storedBytes, 0, $storedBytes.Length)
        }
    }

    if (-not (Test-ByteArrayEqual -Left $plainBytes -Right $roundTripBytes)) {
        throw 'SELFTEST_ATOMIC_PROFILE_ROUNDTRIP_FAILED'
    }

    $processTest1 = Test-CodexProcessesStopped -ProcessData @(
        [pscustomobject]@{
            ProcessName = 'codex.exe'
            Id = 1001
            ExecutablePath = $null
            PathReadStatus = 'Unavailable'
        }
    )
    if ($processTest1.SafeToSave -or
        $processTest1.ReasonCode -cne 'CODEX_PROCESS_RUNNING') {
        throw 'SELFTEST_CODEX_PROCESS_NOT_BLOCKED'
    }

    $processTest2 = Test-CodexProcessesStopped -ProcessData @(
        [pscustomobject]@{
            ProcessName = 'node.exe'
            Id = 1002
            ExecutablePath = 'C:\Program Files\UnrelatedApp\node.exe'
            PathReadStatus = 'Readable'
        }
    )
    if (-not $processTest2.SafeToSave -or
        $processTest2.ReasonCode -cne 'CODEX_PROCESSES_STOPPED') {
        throw 'SELFTEST_UNRELATED_NODE_BLOCKED'
    }

    $processTest3 = Test-CodexProcessesStopped -ProcessData @(
        [pscustomobject]@{
            ProcessName = 'pwsh.exe'
            Id = 1003
            ExecutablePath = 'C:\Program Files\PowerShell\7\pwsh.exe'
            PathReadStatus = 'Readable'
        }
    )
    if (-not $processTest3.SafeToSave -or
        $processTest3.ReasonCode -cne 'CODEX_PROCESSES_STOPPED') {
        throw 'SELFTEST_UNRELATED_PWSH_BLOCKED'
    }

    $processTest4 = Test-CodexProcessesStopped -ProcessData @(
        [pscustomobject]@{
            ProcessName = 'ChatGPT.exe'
            Id = 1004
            ExecutablePath = 'C:\Program Files\WindowsApps\OpenAI.Codex_1.0.0.0_x64__test\app\ChatGPT.exe'
            PathReadStatus = 'Readable'
        }
    )
    if ($processTest4.SafeToSave -or
        $processTest4.ReasonCode -cne 'CODEX_PROCESS_RUNNING') {
        throw 'SELFTEST_CODEX_CHATGPT_NOT_BLOCKED'
    }

    $processTest5 = Test-CodexProcessesStopped -ProcessData @()
    if (-not $processTest5.SafeToSave -or
        $processTest5.ReasonCode -cne 'CODEX_PROCESSES_STOPPED') {
        throw 'SELFTEST_EMPTY_PROCESS_SET_NOT_ALLOWED'
    }

    $processTest6 = Test-CodexProcessesStopped -ProcessData @(
        [pscustomobject]@{
            ProcessName = 'ChatGPT.exe'
            Id = 1006
            ExecutablePath = $null
            PathReadStatus = 'Unavailable'
        }
    )
    if ($processTest6.SafeToSave -or
        $processTest6.ReasonCode -cne 'CODEX_PROCESS_STATE_UNKNOWN') {
        throw 'SELFTEST_UNKNOWN_CHATGPT_STATE_GUESSED'
    }

    # Only the exact quota child descriptor created by Qiehao may be excluded.
    # PID, path, start time, arguments, and parent must all match.
    $ownedQuotaStart = [DateTime]'2026-09-23T00:00:00Z'
    $quotaProcess = [pscustomobject]@{
        ProcessName = 'codex.exe'; Id = 1701; ParentProcessId = 1700
        ParentReadStatus = 'Readable'
        ExecutablePath = 'C:\Fake\Codex\codex.exe'; PathReadStatus = 'Readable'
        ProcessStartTimeUtc = $ownedQuotaStart; StartTimeReadStatus = 'Readable'
    }
    $quotaDescriptor = [pscustomobject]@{
        ProcessId = 1701; ParentProcessId = 1700
        ExecutablePath = 'C:\Fake\Codex\codex.exe'
        ProcessStartTimeUtc = $ownedQuotaStart
        Arguments = 'app-server --stdio'; IsActive = $true
    }
    $ownedQuotaOnly = Test-CodexProcessesStopped `
        -ProcessData @($quotaProcess) `
        -OwnedProcessDescriptors @($quotaDescriptor)
    if (-not $ownedQuotaOnly.SafeToSave -or
        @($ownedQuotaOnly.OwnedQuotaProcesses).Count -ne 1 -or
        $ownedQuotaOnly.ReasonCode -cne 'CODEX_PROCESSES_STOPPED') {
        throw 'SELFTEST_OWNED_QUOTA_CHILD_BLOCKED'
    }
    $desktopAndQuota = Test-CodexProcessesStopped `
        -ProcessData @($quotaProcess, [pscustomobject]@{
            ProcessName = 'codex.exe'; Id = 1702
            ExecutablePath = 'C:\Program Files\WindowsApps\OpenAI.Codex\codex.exe'
            PathReadStatus = 'Readable'; ParentProcessId = 500
            ParentReadStatus = 'Readable'; ProcessStartTimeUtc = $ownedQuotaStart
            StartTimeReadStatus = 'Readable'
        }) -OwnedProcessDescriptors @($quotaDescriptor)
    if ($desktopAndQuota.SafeToSave -or
        @($desktopAndQuota.OwnedQuotaProcesses).Count -ne 1 -or
        @($desktopAndQuota.BlockingProcesses).Count -ne 1) {
        throw 'SELFTEST_DESKTOP_NOT_BLOCKED_WITH_QUOTA_CHILD'
    }
    $wrongParentDescriptor = [pscustomobject]@{
        ProcessId = 1701; ParentProcessId = 9999
        ExecutablePath = 'C:\Fake\Codex\codex.exe'
        ProcessStartTimeUtc = $ownedQuotaStart
        Arguments = 'app-server --stdio'; IsActive = $true
    }
    $untrustedQuota = Test-CodexProcessesStopped `
        -ProcessData @($quotaProcess) `
        -OwnedProcessDescriptors @($wrongParentDescriptor)
    if ($untrustedQuota.SafeToSave -or
        $untrustedQuota.ReasonCode -cne 'CODEX_PROCESS_RUNNING') {
        throw 'SELFTEST_UNVERIFIED_QUOTA_CHILD_WAS_IGNORED'
    }

    $credentialSourceFile = Get-CodexCredentialSourceInfo `
        -CodexHome $workDirectoryFull `
        -ConfigText 'cli_auth_credentials_store = "file"' `
        -UseProvidedConfigText
    $credentialSourceKeyring = Get-CodexCredentialSourceInfo `
        -CodexHome $workDirectoryFull `
        -ConfigText 'cli_auth_credentials_store = "keyring"' `
        -UseProvidedConfigText
    $credentialSourceAuto = Get-CodexCredentialSourceInfo `
        -CodexHome $workDirectoryFull `
        -ConfigText 'cli_auth_credentials_store = "auto"' `
        -UseProvidedConfigText
    $credentialSourceEphemeral = Get-CodexCredentialSourceInfo `
        -CodexHome $workDirectoryFull `
        -ConfigText 'cli_auth_credentials_store = "ephemeral"' `
        -UseProvidedConfigText
    if (-not $credentialSourceFile.FileCredentialUsable -or
        $credentialSourceFile.Source -cne 'File' -or
        $credentialSourceKeyring.ResultCode -cne
            'AUTH_CREDENTIAL_SOURCE_UNSUPPORTED' -or
        $credentialSourceAuto.ResultCode -cne
            'AUTH_CREDENTIAL_SOURCE_AMBIGUOUS' -or
        $credentialSourceEphemeral.ResultCode -cne
            'AUTH_CREDENTIAL_SOURCE_UNSUPPORTED') {
        throw 'SELFTEST_CREDENTIAL_SOURCE_DETECTION_FAILED'
    }

    $extensionHostPath = 'C:\Users\FakeUser\.codex\plugins\cache\extension-host.exe'
    $browserExtensionTest1 = Test-CodexProcessesStopped -ProcessData @(
        [pscustomobject]@{ ProcessName = 'extension-host.exe'; Id = 2001; ParentProcessId = 2002; ParentReadStatus = 'Readable'; ExecutablePath = $extensionHostPath; PathReadStatus = 'Readable' },
        [pscustomobject]@{ ProcessName = 'cmd.exe'; Id = 2002; ParentProcessId = 2003; ParentReadStatus = 'Readable'; ExecutablePath = 'C:\Windows\System32\cmd.exe'; PathReadStatus = 'Readable' },
        [pscustomobject]@{ ProcessName = 'chrome.exe'; Id = 2003; ParentProcessId = 0; ParentReadStatus = 'Readable'; ExecutablePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'; PathReadStatus = 'Readable' }
    )
    if (-not $browserExtensionTest1.SafeToSave -or
        $browserExtensionTest1.ReasonCode -cne 'CODEX_PROCESSES_STOPPED' -or
        @($browserExtensionTest1.BrowserExtensionHosts).Count -ne 1) {
        throw 'SELFTEST_CHROME_EXTENSION_HOST_BLOCKED'
    }

    $browserExtensionTest2 = Test-CodexProcessesStopped -ProcessData @(
        [pscustomobject]@{ ProcessName = 'extension-host.exe'; Id = 2101; ParentProcessId = 2102; ParentReadStatus = 'Readable'; ExecutablePath = $extensionHostPath; PathReadStatus = 'Readable' },
        [pscustomobject]@{ ProcessName = 'cmd.exe'; Id = 2102; ParentProcessId = 2103; ParentReadStatus = 'Readable'; ExecutablePath = 'C:\Windows\System32\cmd.exe'; PathReadStatus = 'Readable' },
        [pscustomobject]@{ ProcessName = 'msedge.exe'; Id = 2103; ParentProcessId = 2104; ParentReadStatus = 'Readable'; ExecutablePath = 'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe'; PathReadStatus = 'Readable' },
        [pscustomobject]@{ ProcessName = 'explorer.exe'; Id = 2104; ParentProcessId = 0; ParentReadStatus = 'Readable'; ExecutablePath = 'C:\Windows\explorer.exe'; PathReadStatus = 'Readable' }
    )
    if (-not $browserExtensionTest2.SafeToSave -or
        $browserExtensionTest2.ReasonCode -cne 'CODEX_PROCESSES_STOPPED' -or
        @($browserExtensionTest2.BrowserExtensionHosts).Count -ne 1) {
        throw 'SELFTEST_EDGE_EXTENSION_HOST_BLOCKED'
    }

    $codexExtensionTest = Test-CodexProcessesStopped -ProcessData @(
        [pscustomobject]@{ ProcessName = 'extension-host.exe'; Id = 2201; ParentProcessId = 2202; ParentReadStatus = 'Readable'; ExecutablePath = $extensionHostPath; PathReadStatus = 'Readable' },
        [pscustomobject]@{ ProcessName = 'cmd.exe'; Id = 2202; ParentProcessId = 2203; ParentReadStatus = 'Readable'; ExecutablePath = 'C:\Windows\System32\cmd.exe'; PathReadStatus = 'Readable' },
        [pscustomobject]@{ ProcessName = 'codex.exe'; Id = 2203; ParentProcessId = 0; ParentReadStatus = 'Readable'; ExecutablePath = 'C:\Users\FakeUser\AppData\Local\OpenAI\Codex\bin\codex.exe'; PathReadStatus = 'Readable' }
    )
    $codexExtensionBlocked = @($codexExtensionTest.BlockingProcesses | Where-Object {
        $_.PID -eq 2201 -and $_.Classification -ceq 'CODEX_EXTENSION_HOST'
    }).Count -eq 1
    if ($codexExtensionTest.SafeToSave -or
        $codexExtensionTest.ReasonCode -cne 'CODEX_PROCESS_RUNNING' -or
        -not $codexExtensionBlocked) {
        throw 'SELFTEST_CODEX_EXTENSION_HOST_NOT_BLOCKED'
    }

    $unknownExtensionTest = Test-CodexProcessesStopped -ProcessData @(
        [pscustomobject]@{ ProcessName = 'extension-host.exe'; Id = 2301; ParentProcessId = $null; ParentReadStatus = 'Unavailable'; ExecutablePath = $extensionHostPath; PathReadStatus = 'Readable' }
    )
    if ($unknownExtensionTest.SafeToSave -or
        $unknownExtensionTest.ReasonCode -cne 'CODEX_PROCESS_STATE_UNKNOWN') {
        throw 'SELFTEST_EXTENSION_HOST_UNKNOWN_GUESSED'
    }

    $fakeAInitial = New-FakeAuthBytes -Identity 'SELFTEST-ACCOUNT-A' `
        -CredentialRevision 'A-INITIAL'
    $fakeARefreshed = New-FakeAuthBytes -Identity 'SELFTEST-ACCOUNT-A' `
        -CredentialRevision 'A-REFRESHED'
    $fakeB = New-FakeAuthBytes -Identity 'SELFTEST-ACCOUNT-B' `
        -CredentialRevision 'B'
    $fakeC = New-FakeAuthBytes -Identity 'SELFTEST-ACCOUNT-C' `
        -CredentialRevision 'C'
    $fakeX = New-FakeAuthBytes -Identity 'SELFTEST-ACCOUNT-X' `
        -CredentialRevision 'X-UNKNOWN'
    $fakeWorkspaceTeam = New-FakeAuthBytes `
        -Identity 'SELFTEST-TEAM-WORKSPACE' `
        -CredentialRevision 'WORKSPACE-TEAM' `
        -UserIdentity 'SELFTEST-SHARED-USER' -PlanType 'team'
    $fakeWorkspacePersonal = New-FakeAuthBytes `
        -Identity 'SELFTEST-PERSONAL-WORKSPACE' `
        -CredentialRevision 'WORKSPACE-PERSONAL' `
        -UserIdentity 'SELFTEST-SHARED-USER' -PlanType 'plus'
    $fakeWorkspaceClaimMismatch = New-FakeAuthBytes `
        -Identity 'SELFTEST-TEAM-WORKSPACE' `
        -CredentialRevision 'WORKSPACE-CLAIM-MISMATCH' `
        -UserIdentity 'SELFTEST-SHARED-USER' -PlanType 'team' `
        -WorkspaceClaimIdentity 'SELFTEST-DIFFERENT-WORKSPACE-CLAIM'
    $invalidJson = '{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"last_refresh":"2000-01-01T00:00:00Z"}'
    $fakeInvalidB = (New-Object System.Text.UTF8Encoding($false)).GetBytes($invalidJson)
    $invalidJson = $null

    $identityUnknownJson = '{"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"SELFTEST","access_token":"SELFTEST","refresh_token":"SELFTEST"},"last_refresh":"2000-01-01T00:00:00Z"}'
    $fakeIdentitySchemaUnknown = (New-Object System.Text.UTF8Encoding($false)).GetBytes(
        $identityUnknownJson
    )
    $identityUnknownJson = $null

    # 1 + 2: complete A -> B transaction and preservation of refreshed A.
    $fixture1 = New-SwitchFixture -Root (Join-Path $workDirectoryFull 'switch-normal') `
        -Module $module -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    $metadataBeforeSwitch = ConvertFrom-Json -InputObject (
        [System.IO.File]::ReadAllText((Join-Path $fixture1.Profiles 'A.meta.json'))
    )
    [System.IO.File]::WriteAllBytes($fixture1.AuthPath, $fakeARefreshed)
    $switchResult = Invoke-FakeSwitch -Module $module -Fixture $fixture1 -Target 'B'
    $switchedBytes = [System.IO.File]::ReadAllBytes($fixture1.AuthPath)
    try {
        if ($switchResult.Result -cne 'SWITCH_SUCCESS' -or
            $switchResult.From -cne 'A' -or
            $switchResult.To -cne 'B' -or
            -not (Test-ByteArrayEqual -Left $switchedBytes -Right $fakeB)) {
            throw 'SELFTEST_NORMAL_SWITCH_FAILED'
        }
    }
    finally {
        [Array]::Clear($switchedBytes, 0, $switchedBytes.Length)
    }
    $savedRefreshedA = & $module {
        param($Profiles)
        Read-CodexAccountSlotBytes -Name 'A' -ProfilesDirectory $Profiles
    } $fixture1.Profiles
    try {
        if (-not (Test-ByteArrayEqual -Left $savedRefreshedA -Right $fakeARefreshed)) {
            throw 'SELFTEST_REFRESHED_ACTIVE_NOT_SAVED'
        }
    }
    finally {
        [Array]::Clear($savedRefreshedA, 0, $savedRefreshedA.Length)
    }
    $activeAfterSwitch = & $module {
        param($State)
        Read-ActiveProfileState -StateDirectory $State
    } $fixture1.State
    if ($activeAfterSwitch.ActiveProfile -cne 'B') {
        throw 'SELFTEST_ACTIVE_STATE_NOT_COMMITTED_LAST'
    }
    $metadataAfterSwitch = ConvertFrom-Json -InputObject (
        [System.IO.File]::ReadAllText((Join-Path $fixture1.Profiles 'A.meta.json'))
    )
    if ([string]$metadataAfterSwitch.updated_at -ceq [string]$metadataBeforeSwitch.updated_at) {
        throw 'SELFTEST_ACTIVE_METADATA_NOT_UPDATED'
    }
    $metadataBeforeSwitch = $null
    $metadataAfterSwitch = $null

    # init-active must refuse a label whose decrypted bytes do not match auth.
    $fixtureInitMismatch = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'init-mismatch') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB -SkipActiveState
    $initMismatchCode = $null
    try {
        & $module {
            param($Fixture)
            $null = Invoke-InitializeCodexActiveProfile -Name 'B' `
                -CodexHome $Fixture.CodexHome -ProfilesDirectory $Fixture.Profiles `
                -StateDirectory $Fixture.State -ProcessData @() -UseProvidedProcessData
        } $fixtureInitMismatch
    }
    catch {
        $initMismatchCode = $_.Exception.Message
    }
    if ($initMismatchCode -cne 'ACTIVE_PROFILE_MISMATCH' -or
        [System.IO.File]::Exists((Join-Path $fixtureInitMismatch.State 'active-profile.json'))) {
        throw 'SELFTEST_INIT_ACTIVE_MISMATCH_NOT_REJECTED'
    }

    # 3: corrupt target DPAPI must not change auth.json.
    $fixture3 = New-SwitchFixture -Root (Join-Path $workDirectoryFull 'target-dpapi-failure') `
        -Module $module -ActiveBytes $fakeAInitial -TargetBytes $fakeB -CorruptTargetDpapi
    $before3 = [System.IO.File]::ReadAllBytes($fixture3.AuthPath)
    $code3 = $null
    try { $null = Invoke-FakeSwitch -Module $module -Fixture $fixture3 -Target 'B' }
    catch { $code3 = $_.Exception.Message }
    $after3 = [System.IO.File]::ReadAllBytes($fixture3.AuthPath)
    try {
        if ($code3 -cne 'DPAPI_UNPROTECT_FAILED' -or
            -not (Test-ByteArrayEqual -Left $before3 -Right $after3)) {
            throw 'SELFTEST_TARGET_DPAPI_FAILURE_MODIFIED_AUTH'
        }
    }
    finally {
        [Array]::Clear($before3, 0, $before3.Length)
        [Array]::Clear($after3, 0, $after3.Length)
    }

    # 4: decryptable target with invalid schema must not change auth.json.
    $fixture4 = New-SwitchFixture -Root (Join-Path $workDirectoryFull 'target-schema-failure') `
        -Module $module -ActiveBytes $fakeAInitial -TargetBytes $fakeInvalidB `
        -AllowInvalidTargetSchema
    $before4 = [System.IO.File]::ReadAllBytes($fixture4.AuthPath)
    $code4 = $null
    try { $null = Invoke-FakeSwitch -Module $module -Fixture $fixture4 -Target 'B' }
    catch { $code4 = $_.Exception.Message }
    $after4 = [System.IO.File]::ReadAllBytes($fixture4.AuthPath)
    try {
        if ($code4 -cne 'AUTH_SCHEMA_UNEXPECTED' -or
            -not (Test-ByteArrayEqual -Left $before4 -Right $after4)) {
            throw 'SELFTEST_TARGET_SCHEMA_FAILURE_MODIFIED_AUTH'
        }
    }
    finally {
        [Array]::Clear($before4, 0, $before4.Length)
        [Array]::Clear($after4, 0, $after4.Length)
    }

    # 5: simulated post-replace verification failure must restore A.
    $fixture5 = New-SwitchFixture -Root (Join-Path $workDirectoryFull 'rollback') `
        -Module $module -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    [System.IO.File]::WriteAllBytes($fixture5.AuthPath, $fakeARefreshed)
    $code5 = $null
    try {
        $null = Invoke-FakeSwitch -Module $module -Fixture $fixture5 -Target 'B' `
            -SimulatePostReplaceVerificationFailure
    }
    catch { $code5 = $_.Exception.Message }
    $afterRollback = [System.IO.File]::ReadAllBytes($fixture5.AuthPath)
    try {
        $stateAfterRollback = & $module {
            param($State)
            Read-ActiveProfileState -StateDirectory $State
        } $fixture5.State
        if ($code5 -cne 'SWITCH_FAILED_ROLLED_BACK' -or
            -not (Test-ByteArrayEqual -Left $afterRollback -Right $fakeARefreshed) -or
            $stateAfterRollback.ActiveProfile -cne 'A') {
            throw 'SELFTEST_ROLLBACK_FAILED'
        }
    }
    finally {
        [Array]::Clear($afterRollback, 0, $afterRollback.Length)
    }

    # 6: missing active state rejects before auth is read or changed.
    $fixture6 = New-SwitchFixture -Root (Join-Path $workDirectoryFull 'missing-active') `
        -Module $module -ActiveBytes $fakeAInitial -TargetBytes $fakeB -SkipActiveState
    $code6 = $null
    try { $null = Invoke-FakeSwitch -Module $module -Fixture $fixture6 -Target 'B' }
    catch { $code6 = $_.Exception.Message }
    if ($code6 -cne 'ACTIVE_PROFILE_NOT_INITIALIZED') {
        throw 'SELFTEST_MISSING_ACTIVE_NOT_REJECTED'
    }

    # 7: switching to the active profile is a no-op error.
    $fixture7 = New-SwitchFixture -Root (Join-Path $workDirectoryFull 'already-active') `
        -Module $module -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    $code7 = $null
    try { $null = Invoke-FakeSwitch -Module $module -Fixture $fixture7 -Target 'A' }
    catch { $code7 = $_.Exception.Message }
    if ($code7 -cne 'ALREADY_ACTIVE') {
        throw 'SELFTEST_ALREADY_ACTIVE_NOT_REJECTED'
    }

    # 7b: the Active label cannot short-circuit identity verification. If the
    # recorded Active profile is A while Codex is signed in as saved profile B,
    # switching to A reports an explicit out-of-sync state without any write.
    $fixture7b = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'active-out-of-sync') `
        -Module $module -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    [System.IO.File]::WriteAllBytes($fixture7b.AuthPath, $fakeB)
    $fixture7bProfilesBefore = Get-FakeTreeStamp -Root $fixture7b.Profiles
    $fixture7bStateBefore = Get-FakeTreeStamp -Root $fixture7b.State
    $fixture7bAuthBefore = [System.IO.File]::ReadAllBytes($fixture7b.AuthPath)
    $code7b = $null
    try {
        $null = Invoke-FakeSwitch -Module $module -Fixture $fixture7b `
            -Target 'A'
    }
    catch { $code7b = [string]$_.Exception.Message }
    $fixture7bAuthAfter = [System.IO.File]::ReadAllBytes($fixture7b.AuthPath)
    try {
        if ($code7b -cne 'ACTIVE_PROFILE_OUT_OF_SYNC' -or
            (Get-FakeTreeStamp -Root $fixture7b.Profiles) -cne
                $fixture7bProfilesBefore -or
            (Get-FakeTreeStamp -Root $fixture7b.State) -cne
                $fixture7bStateBefore -or
            -not (Test-ByteArrayEqual -Left $fixture7bAuthBefore `
                -Right $fixture7bAuthAfter)) {
            throw 'SELFTEST_ACTIVE_OUT_OF_SYNC_NOT_SAFE'
        }
    }
    finally {
        [Array]::Clear($fixture7bAuthBefore, 0, $fixture7bAuthBefore.Length)
        [Array]::Clear($fixture7bAuthAfter, 0, $fixture7bAuthAfter.Length)
    }

    # 7c: explicit recovery may update only active-profile.json after the
    # current identity is proven to match a complete saved profile.
    $syncProfilesBefore = Get-FakeTreeStamp -Root $fixture7b.Profiles
    $syncAuthBefore = [System.IO.File]::ReadAllBytes($fixture7b.AuthPath)
    $syncResult = & $module {
        param($Fixture)
        Invoke-SyncCodexActiveProfile -CodexHome $Fixture.CodexHome `
            -ProfilesDirectory $Fixture.Profiles `
            -StateDirectory $Fixture.State `
            -ProcessData @() -UseProvidedProcessData
    } $fixture7b
    $syncState = & $module {
        param($State)
        Read-ActiveProfileState -StateDirectory $State
    } $fixture7b.State
    $syncAuthAfter = [System.IO.File]::ReadAllBytes($fixture7b.AuthPath)
    try {
        if ($syncResult.Result -cne 'ACTIVE_PROFILE_SYNCED' -or
            $syncResult.ActiveProfile -cne 'B' -or
            $syncState.ActiveProfile -cne 'B' -or
            (Get-FakeTreeStamp -Root $fixture7b.Profiles) -cne
                $syncProfilesBefore -or
            -not (Test-ByteArrayEqual -Left $syncAuthBefore `
                -Right $syncAuthAfter)) {
            throw 'SELFTEST_ACTIVE_SYNC_MODIFIED_CREDENTIALS'
        }
    }
    finally {
        [Array]::Clear($syncAuthBefore, 0, $syncAuthBefore.Length)
        [Array]::Clear($syncAuthAfter, 0, $syncAuthAfter.Length)
    }

    # 7d: an unknown external identity remains fail-closed for both ordinary
    # switching and the explicit state-only recovery operation.
    $fixture7d = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'active-unknown-identity') `
        -Module $module -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    [System.IO.File]::WriteAllBytes($fixture7d.AuthPath, $fakeX)
    $fixture7dProfilesBefore = Get-FakeTreeStamp -Root $fixture7d.Profiles
    $fixture7dStateBefore = Get-FakeTreeStamp -Root $fixture7d.State
    $unknownSwitchCode = $null
    $unknownSyncCode = $null
    try {
        $null = Invoke-FakeSwitch -Module $module -Fixture $fixture7d `
            -Target 'B'
    }
    catch { $unknownSwitchCode = [string]$_.Exception.Message }
    try {
        & $module {
            param($Fixture)
            $null = Invoke-SyncCodexActiveProfile `
                -CodexHome $Fixture.CodexHome `
                -ProfilesDirectory $Fixture.Profiles `
                -StateDirectory $Fixture.State `
                -ProcessData @() -UseProvidedProcessData
        } $fixture7d
    }
    catch { $unknownSyncCode = [string]$_.Exception.Message }
    if ($unknownSwitchCode -cne 'ACTIVE_PROFILE_IDENTITY_MISMATCH' -or
        $unknownSyncCode -cne 'ACTIVE_PROFILE_IDENTITY_MISMATCH' -or
        (Get-FakeTreeStamp -Root $fixture7d.Profiles) -cne
            $fixture7dProfilesBefore -or
        (Get-FakeTreeStamp -Root $fixture7d.State) -cne
            $fixture7dStateBefore) {
        throw 'SELFTEST_UNKNOWN_IDENTITY_NOT_FAIL_CLOSED'
    }

    # 8: browser-owned extension host must not block an otherwise valid switch.
    $fixture8 = New-SwitchFixture -Root (Join-Path $workDirectoryFull 'browser-host') `
        -Module $module -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    $browserSentinelPath = Join-Path -Path (Split-Path $fixture8.CodexHome -Parent) `
        -ChildPath 'browser-session-do-not-touch.bin'
    $browserSentinelBytes = [byte[]](11, 22, 33, 44, 55)
    [System.IO.File]::WriteAllBytes($browserSentinelPath, $browserSentinelBytes)
    $browserProcessData = @(
        [pscustomobject]@{ ProcessName = 'extension-host.exe'; Id = 8001; ParentProcessId = 8002; ParentReadStatus = 'Readable'; ExecutablePath = $extensionHostPath; PathReadStatus = 'Readable' },
        [pscustomobject]@{ ProcessName = 'cmd.exe'; Id = 8002; ParentProcessId = 8003; ParentReadStatus = 'Readable'; ExecutablePath = 'C:\Windows\System32\cmd.exe'; PathReadStatus = 'Readable' },
        [pscustomobject]@{ ProcessName = 'chrome.exe'; Id = 8003; ParentProcessId = 0; ParentReadStatus = 'Readable'; ExecutablePath = 'C:\Program Files\Google\Chrome\Application\chrome.exe'; PathReadStatus = 'Readable' }
    )
    $browserSwitchResult = Invoke-FakeSwitch -Module $module -Fixture $fixture8 `
        -Target 'B' -ProcessData $browserProcessData
    if ($browserSwitchResult.Result -cne 'SWITCH_SUCCESS') {
        throw 'SELFTEST_BROWSER_EXTENSION_BLOCKED_SWITCH'
    }
    $browserSentinelAfter = [System.IO.File]::ReadAllBytes($browserSentinelPath)
    try {
        if (-not (Test-ByteArrayEqual -Left $browserSentinelBytes `
            -Right $browserSentinelAfter)) {
            throw 'SELFTEST_BROWSER_SESSION_WAS_MODIFIED'
        }
    }
    finally {
        [Array]::Clear($browserSentinelAfter, 0, $browserSentinelAfter.Length)
        [Array]::Clear($browserSentinelBytes, 0, $browserSentinelBytes.Length)
    }

    # 9: an explicit Codex Desktop process rejects before auth changes.
    $fixture9 = New-SwitchFixture -Root (Join-Path $workDirectoryFull 'codex-running') `
        -Module $module -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    $before9 = [System.IO.File]::ReadAllBytes($fixture9.AuthPath)
    $code9 = $null
    try {
        $null = Invoke-FakeSwitch -Module $module -Fixture $fixture9 -Target 'B' `
            -ProcessData @([pscustomobject]@{
                ProcessName = 'codex.exe'; Id = 9001; ExecutablePath = $null;
                PathReadStatus = 'Unavailable'
            })
    }
    catch { $code9 = $_.Exception.Message }
    $after9 = [System.IO.File]::ReadAllBytes($fixture9.AuthPath)
    try {
        if ($code9 -cne 'CODEX_PROCESS_RUNNING' -or
            -not (Test-ByteArrayEqual -Left $before9 -Right $after9)) {
            throw 'SELFTEST_CODEX_RUNNING_DID_NOT_BLOCK_SWITCH'
        }
    }
    finally {
        [Array]::Clear($before9, 0, $before9.Length)
        [Array]::Clear($after9, 0, $after9.Length)
    }

    # A real Codex Desktop process may outlive its last window briefly. The
    # bounded gate must recheck and allow the caller to continue when the fake
    # process disappears, without weakening the static fail-closed tests above.
    $delayedExitRechecks = [pscustomobject]@{ Count = 0 }
    $delayedExitDelayCalls = [pscustomobject]@{ Count = 0 }
    $delayedExitContinued = & $module {
        param($Rechecks, $DelayCalls)
        $runningProcess = [pscustomobject]@{
            ProcessName = 'codex.exe'
            Id = 9101
            ExecutablePath =
                'C:\Users\Fake\AppData\Local\OpenAI\Codex\bin\codex.exe'
            PathReadStatus = 'Readable'
        }
        $snapshotProvider = {
            $Rechecks.Count++
            return @()
        }.GetNewClosure()
        $delayProvider = {
            param($Milliseconds)
            $DelayCalls.Count++
        }.GetNewClosure()
        Assert-CodexNotRunning -ProcessData @($runningProcess) `
            -UseProvidedProcessData -DiagnosticOperation 'SWITCH' `
            -ProcessExitWaitMilliseconds 100 `
            -ProcessRecheckIntervalMilliseconds 1 `
            -ProcessSnapshotProvider $snapshotProvider `
            -DelayProvider $delayProvider
        return $true
    } $delayedExitRechecks $delayedExitDelayCalls
    if (-not $delayedExitContinued -or
        $delayedExitRechecks.Count -ne 1 -or
        $delayedExitDelayCalls.Count -ne 1) {
        throw 'SELFTEST_CODEX_DELAYED_EXIT_DID_NOT_CONTINUE'
    }

    $processWaitEvents = @(
        Get-Content -LiteralPath (
            Join-Path $diagnosticLogDirectory 'qiehao.log'
        ) | ForEach-Object { $_ | ConvertFrom-Json } |
        Where-Object {
            $_.event -in @(
                'PROCESS_WAIT_START',
                'PROCESS_RECHECK',
                'PROCESS_EXITED_DURING_WAIT'
            )
        }
    )
    foreach ($requiredWaitEvent in @(
        'PROCESS_WAIT_START',
        'PROCESS_RECHECK',
        'PROCESS_EXITED_DURING_WAIT'
    )) {
        if (@($processWaitEvents | Where-Object {
                $_.event -ceq $requiredWaitEvent
            }).Count -lt 1) {
            throw ('SELFTEST_PROCESS_WAIT_EVENT_MISSING_' +
                $requiredWaitEvent)
        }
    }

    $persistentRunningCode = & $module {
        $runningProcess = [pscustomobject]@{
            ProcessName = 'codex.exe'
            Id = 9102
            ExecutablePath =
                'C:\Users\Fake\AppData\Local\OpenAI\Codex\bin\codex.exe'
            PathReadStatus = 'Readable'
        }
        $snapshotProvider = {
            return @($runningProcess)
        }.GetNewClosure()
        try {
            Assert-CodexNotRunning -ProcessData @($runningProcess) `
                -UseProvidedProcessData -DiagnosticOperation 'DELETE' `
                -ProcessExitWaitMilliseconds 5 `
                -ProcessRecheckIntervalMilliseconds 1 `
                -ProcessSnapshotProvider $snapshotProvider
            return 'UNEXPECTED_SUCCESS'
        }
        catch { return [string]$_.Exception.Message }
    }
    $persistentWaitEvents = @(
        Get-Content -LiteralPath (
            Join-Path $diagnosticLogDirectory 'qiehao.log'
        ) | ForEach-Object { $_ | ConvertFrom-Json } |
        Where-Object { $_.event -ceq 'PROCESS_STILL_RUNNING' }
    )
    if ($persistentRunningCode -cne 'CODEX_PROCESS_RUNNING' -or
        $persistentWaitEvents.Count -lt 1) {
        throw 'SELFTEST_CODEX_PROCESS_WAIT_TIMEOUT_NOT_FAIL_CLOSED'
    }

    # Workspace 1: the same user may have distinct Personal and Team
    # contexts. ADD must preserve both complete raw-byte profiles rather than
    # collapsing them solely by the legacy account marker.
    $workspaceAddRoot = Join-Path $workDirectoryFull 'workspace-add'
    $workspaceAddHome = Join-Path $workspaceAddRoot 'codex-home'
    $workspaceAddProfiles = Join-Path $workspaceAddRoot 'profiles'
    $workspaceAddState = Join-Path $workspaceAddRoot 'state'
    foreach ($directory in @(
        $workspaceAddHome,
        $workspaceAddProfiles,
        $workspaceAddState
    )) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    [System.IO.File]::WriteAllBytes(
        (Join-Path $workspaceAddHome 'auth.json'),
        $fakeWorkspaceTeam
    )
    $workspaceTeamAdd = & $module {
        param($Home, $Profiles, $State)
        Invoke-AddCodexProfile -Name 'WorkspaceTeam' -CodexHome $Home `
            -ProfilesDirectory $Profiles -StateDirectory $State `
            -ProcessData @() -UseProvidedProcessData
    } $workspaceAddHome $workspaceAddProfiles $workspaceAddState
    [System.IO.File]::WriteAllBytes(
        (Join-Path $workspaceAddHome 'auth.json'),
        $fakeWorkspacePersonal
    )
    $workspacePersonalAdd = & $module {
        param($Home, $Profiles, $State)
        Invoke-AddCodexProfile -Name 'WorkspacePersonal' -CodexHome $Home `
            -ProfilesDirectory $Profiles -StateDirectory $State `
            -ProcessData @() -UseProvidedProcessData
    } $workspaceAddHome $workspaceAddProfiles $workspaceAddState
    if ($workspaceTeamAdd.Result -cne 'PROFILE_ADD_SUCCESS' -or
        $workspacePersonalAdd.Result -cne 'PROFILE_ADD_SUCCESS' -or
        @(Get-ChildItem -LiteralPath $workspaceAddProfiles `
            -Filter '*.auth.dpapi').Count -ne 2) {
        throw 'SELFTEST_SAME_ACCOUNT_DIFFERENT_WORKSPACE_COLLAPSED'
    }

    # Workspace 2: Active=Team while current Codex=Personal must be explicit
    # out-of-sync. Verify must distinguish local integrity from current login.
    $workspaceFixture = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'workspace-drift') `
        -Module $module -ActiveBytes $fakeWorkspaceTeam `
        -TargetBytes $fakeWorkspacePersonal
    [System.IO.File]::WriteAllBytes(
        $workspaceFixture.AuthPath,
        $fakeWorkspacePersonal
    )
    $workspaceProfilesBefore = Get-FakeTreeStamp `
        -Root $workspaceFixture.Profiles
    $workspaceOutOfSyncCode = $null
    try {
        $null = Invoke-FakeSwitch -Module $module `
            -Fixture $workspaceFixture -Target 'A'
    }
    catch { $workspaceOutOfSyncCode = [string]$_.Exception.Message }
    $workspaceVerifyTeam = & $module {
        param($Fixture)
        Invoke-VerifyCodexProfile -Name 'A' `
            -CodexHome $Fixture.CodexHome `
            -ProfilesDirectory $Fixture.Profiles `
            -ProcessData @() -UseProvidedProcessData
    } $workspaceFixture
    $workspaceMismatchEvents = @(
        Get-Content -LiteralPath (
            Join-Path $diagnosticLogDirectory 'qiehao.log'
        ) | ForEach-Object { $_ | ConvertFrom-Json } |
        Where-Object { $_.event -ceq 'WORKSPACE_TYPE_MISMATCH' }
    )
    $workspaceMismatchEvent = @($workspaceMismatchEvents | Select-Object -Last 1)
    $workspaceDeleteTeam = & $module {
        param($Fixture)
        Invoke-GetCodexProfileDeleteSafety -Name 'A' `
            -CodexHome $Fixture.CodexHome `
            -ProfilesDirectory $Fixture.Profiles `
            -StateDirectory $Fixture.State `
            -ProcessData @() -UseProvidedProcessData
    } $workspaceFixture
    if ($workspaceOutOfSyncCode -cne 'ACTIVE_PROFILE_OUT_OF_SYNC' -or
        $workspaceVerifyTeam.Result -cne
            'PROFILE_VERIFY_IDENTITY_MISMATCH' -or
        $workspaceVerifyTeam.SavedWorkspaceClass -cne 'Team' -or
        $workspaceVerifyTeam.CurrentWorkspaceClass -cne 'Personal' -or
        $workspaceMismatchEvent.Count -ne 1 -or
        [string]$workspaceMismatchEvent[0].data.saved_workspace_type -cne
            'Team' -or
        [string]$workspaceMismatchEvent[0].data.current_workspace_type -cne
            'Personal' -or
        $workspaceDeleteTeam.Result -cne
            'PROFILE_DELETE_ACTIVE_OUT_OF_SYNC' -or
        $workspaceDeleteTeam.CurrentProfile -cne 'B' -or
        (Get-FakeTreeStamp -Root $workspaceFixture.Profiles) -cne
            $workspaceProfilesBefore) {
        throw 'SELFTEST_TEAM_PERSONAL_DRIFT_NOT_DETECTED'
    }

    # Workspace 3: recovery commits only active-profile.json. Afterwards the
    # stale Team profile is deletable, while the actually signed-in Personal
    # profile remains protected.
    $workspaceSync = & $module {
        param($Fixture)
        Invoke-SyncCodexActiveProfile -CodexHome $Fixture.CodexHome `
            -ProfilesDirectory $Fixture.Profiles `
            -StateDirectory $Fixture.State `
            -ProcessData @() -UseProvidedProcessData
    } $workspaceFixture
    $workspaceDeleteOld = & $module {
        param($Fixture)
        Invoke-GetCodexProfileDeleteSafety -Name 'A' `
            -CodexHome $Fixture.CodexHome `
            -ProfilesDirectory $Fixture.Profiles `
            -StateDirectory $Fixture.State `
            -ProcessData @() -UseProvidedProcessData
    } $workspaceFixture
    $workspaceDeleteCurrent = & $module {
        param($Fixture)
        Invoke-GetCodexProfileDeleteSafety -Name 'B' `
            -CodexHome $Fixture.CodexHome `
            -ProfilesDirectory $Fixture.Profiles `
            -StateDirectory $Fixture.State `
            -ProcessData @() -UseProvidedProcessData
    } $workspaceFixture
    if ($workspaceSync.Result -cne 'ACTIVE_PROFILE_SYNCED' -or
        $workspaceSync.ActiveProfile -cne 'B' -or
        $workspaceDeleteOld.Result -cne 'PROFILE_DELETE_SAFE' -or
        $workspaceDeleteCurrent.Result -cne
            'CANNOT_REMOVE_CURRENT_CODEX_PROFILE' -or
        (Get-FakeTreeStamp -Root $workspaceFixture.Profiles) -cne
            $workspaceProfilesBefore) {
        throw 'SELFTEST_WORKSPACE_RECOVERY_CHANGED_CREDENTIALS'
    }

    # Workspace 4: the inverse drift (Active=Personal, Codex=Team) is also
    # rejected and cannot be misreported as already active.
    [System.IO.File]::WriteAllBytes(
        $workspaceFixture.AuthPath,
        $fakeWorkspaceTeam
    )
    $personalOutOfSyncCode = $null
    try {
        $null = Invoke-FakeSwitch -Module $module `
            -Fixture $workspaceFixture -Target 'B'
    }
    catch { $personalOutOfSyncCode = [string]$_.Exception.Message }
    if ($personalOutOfSyncCode -cne 'ACTIVE_PROFILE_OUT_OF_SYNC' -or
        (Get-FakeTreeStamp -Root $workspaceFixture.Profiles) -cne
            $workspaceProfilesBefore) {
        throw 'SELFTEST_PERSONAL_TEAM_DRIFT_NOT_DETECTED'
    }

    # Workspace 5: a token whose nested official workspace claim disagrees
    # with tokens.account_id must never be accepted as the active profile.
    [System.IO.File]::WriteAllBytes(
        $workspaceFixture.AuthPath,
        $fakeWorkspaceClaimMismatch
    )
    $workspaceClaimMismatchCode = $null
    try {
        $null = Invoke-FakeSwitch -Module $module `
            -Fixture $workspaceFixture -Target 'A'
    }
    catch { $workspaceClaimMismatchCode = [string]$_.Exception.Message }
    if ($workspaceClaimMismatchCode -cne
            'ACTIVE_PROFILE_IDENTITY_MISMATCH' -or
        (Get-FakeTreeStamp -Root $workspaceFixture.Profiles) -cne
            $workspaceProfilesBefore) {
        throw 'SELFTEST_WORKSPACE_CLAIM_MISMATCH_NOT_REJECTED'
    }

    # Identity 1: refreshed token bytes retain the same account identity. The
    # successful transaction above already exercised this; assert the marker
    # directly as a separate invariant.
    $refreshedIdentityMatches = & $module {
        param($Bytes, $Profiles)
        Assert-CodexAuthMatchesProfileIdentity -Name 'A' -AuthBytes $Bytes `
            -ProfilesDirectory $Profiles
    } $fakeARefreshed $fixture1.Profiles
    if (-not $refreshedIdentityMatches) {
        throw 'SELFTEST_REFRESHED_IDENTITY_NOT_RECOGNIZED'
    }

    # Identity 2: active state says A while auth is really B. Refuse before the
    # latest auth can contaminate the A encrypted slot.
    $fixtureIdentityDrift = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'identity-drift') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    $savedABeforeDrift = & $module {
        param($Profiles)
        Read-CodexAccountSlotBytes -Name 'A' -ProfilesDirectory $Profiles
    } $fixtureIdentityDrift.Profiles
    [System.IO.File]::WriteAllBytes($fixtureIdentityDrift.AuthPath, $fakeB)
    $driftCode = $null
    try {
        $null = Invoke-FakeSwitch -Module $module -Fixture $fixtureIdentityDrift `
            -Target 'B'
    }
    catch { $driftCode = $_.Exception.Message }
    $authAfterDriftRefusal = [System.IO.File]::ReadAllBytes($fixtureIdentityDrift.AuthPath)
    $savedAAfterDrift = & $module {
        param($Profiles)
        Read-CodexAccountSlotBytes -Name 'A' -ProfilesDirectory $Profiles
    } $fixtureIdentityDrift.Profiles
    try {
        if ($driftCode -cne 'ACTIVE_PROFILE_IDENTITY_MISMATCH' -or
            -not (Test-ByteArrayEqual -Left $authAfterDriftRefusal -Right $fakeB) -or
            -not (Test-ByteArrayEqual -Left $savedAAfterDrift -Right $savedABeforeDrift)) {
            throw 'SELFTEST_IDENTITY_DRIFT_NOT_BLOCKED'
        }
    }
    finally {
        [Array]::Clear($authAfterDriftRefusal, 0, $authAfterDriftRefusal.Length)
        [Array]::Clear($savedABeforeDrift, 0, $savedABeforeDrift.Length)
        [Array]::Clear($savedAAfterDrift, 0, $savedAAfterDrift.Length)
    }

    # Identity 3: a legacy or damaged active profile without a marker must fail
    # closed and must not change auth or the encrypted active slot.
    $fixtureMarkerMissing = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'identity-marker-missing') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    [System.IO.File]::Delete((Join-Path $fixtureMarkerMissing.Profiles 'A.identity.dpapi'))
    $authBeforeMarkerMissing = [System.IO.File]::ReadAllBytes($fixtureMarkerMissing.AuthPath)
    $markerMissingCode = $null
    try {
        $null = Invoke-FakeSwitch -Module $module -Fixture $fixtureMarkerMissing `
            -Target 'B'
    }
    catch { $markerMissingCode = $_.Exception.Message }
    $authAfterMarkerMissing = [System.IO.File]::ReadAllBytes($fixtureMarkerMissing.AuthPath)
    try {
        if ($markerMissingCode -cne 'PROFILE_IDENTITY_MARKER_MISSING' -or
            -not (Test-ByteArrayEqual -Left $authBeforeMarkerMissing `
                -Right $authAfterMarkerMissing)) {
            throw 'SELFTEST_MISSING_IDENTITY_MARKER_NOT_CLOSED'
        }
    }
    finally {
        [Array]::Clear($authBeforeMarkerMissing, 0, $authBeforeMarkerMissing.Length)
        [Array]::Clear($authAfterMarkerMissing, 0, $authAfterMarkerMissing.Length)
    }
    $markerInitResult = & $module {
        param($Profiles)
        Invoke-InitializeCodexProfileIdentityMarker -Name 'A' `
            -ProfilesDirectory $Profiles -ProcessData @() -UseProvidedProcessData
    } $fixtureMarkerMissing.Profiles
    $markerAfterInitMatches = & $module {
        param($Bytes, $Profiles)
        Assert-CodexAuthMatchesProfileIdentity -Name 'A' -AuthBytes $Bytes `
            -ProfilesDirectory $Profiles
    } $fakeAInitial $fixtureMarkerMissing.Profiles
    if ($markerInitResult.Result -cne 'IDENTITY_MARKER_INITIALIZED' -or
        -not $markerAfterInitMatches) {
        throw 'SELFTEST_LEGACY_MARKER_INITIALIZATION_FAILED'
    }

    # Identity 4: top-level auth schema can remain recognizable while the
    # identity-specific schema changes. Missing account_id is never guessed.
    $fixtureIdentitySchema = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'identity-schema-unknown') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    [System.IO.File]::WriteAllBytes(
        $fixtureIdentitySchema.AuthPath,
        $fakeIdentitySchemaUnknown
    )
    $identitySchemaCode = $null
    try {
        $null = Invoke-FakeSwitch -Module $module -Fixture $fixtureIdentitySchema `
            -Target 'B'
    }
    catch { $identitySchemaCode = $_.Exception.Message }
    $identitySchemaAuthAfter = [System.IO.File]::ReadAllBytes(
        $fixtureIdentitySchema.AuthPath
    )
    try {
        if ($identitySchemaCode -cne 'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED' -or
            -not (Test-ByteArrayEqual -Left $identitySchemaAuthAfter `
                -Right $fakeIdentitySchemaUnknown)) {
            throw 'SELFTEST_UNKNOWN_IDENTITY_SCHEMA_NOT_CLOSED'
        }
    }
    finally {
        [Array]::Clear($identitySchemaAuthAfter, 0, $identitySchemaAuthAfter.Length)
    }

    # Active-identity confirmation is a read-only operation. Process gating
    # happens before any fake auth read, and all branches return allowlisted
    # status codes instead of identity data.
    $fixtureActiveIdentity = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'active-identity-confirm') `
        -Module $module -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    $treeBeforeIdentityCheck = Get-FakeTreeStamp -Root (
        Split-Path -Parent $fixtureActiveIdentity.CodexHome
    )
    $activeIdentityConfirmed = & $module {
        param($Fixture)
        Invoke-TestCodexActiveIdentity -CodexHome $Fixture.CodexHome `
            -ProfilesDirectory $Fixture.Profiles -StateDirectory $Fixture.State `
            -ProcessData @() -UseProvidedProcessData
    } $fixtureActiveIdentity
    $treeAfterIdentityCheck = Get-FakeTreeStamp -Root (
        Split-Path -Parent $fixtureActiveIdentity.CodexHome
    )
    if ($activeIdentityConfirmed.Result -cne 'ACTIVE_IDENTITY_CONFIRMED' -or
        $treeBeforeIdentityCheck -cne $treeAfterIdentityCheck -or
        @($activeIdentityConfirmed.PSObject.Properties).Count -ne 1) {
        throw 'SELFTEST_ACTIVE_IDENTITY_CONFIRM_READONLY_FAILED'
    }

    [System.IO.File]::WriteAllBytes($fixtureActiveIdentity.AuthPath, $fakeB)
    $activeIdentityMismatch = & $module {
        param($Fixture)
        Invoke-TestCodexActiveIdentity -CodexHome $Fixture.CodexHome `
            -ProfilesDirectory $Fixture.Profiles -StateDirectory $Fixture.State `
            -ProcessData @() -UseProvidedProcessData
    } $fixtureActiveIdentity
    if ($activeIdentityMismatch.Result -cne 'ACTIVE_PROFILE_IDENTITY_MISMATCH') {
        throw 'SELFTEST_ACTIVE_IDENTITY_MISMATCH_NOT_REPORTED'
    }

    $identityGateRoot = Join-Path $workDirectoryFull 'active-identity-process-gate'
    $identityGateHome = Join-Path $identityGateRoot 'codex-home-without-auth'
    $identityGateProfiles = Join-Path $identityGateRoot 'profiles'
    $identityGateState = Join-Path $identityGateRoot 'state'
    foreach ($directory in @($identityGateHome, $identityGateProfiles, $identityGateState)) {
        [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    }
    $runningIdentityResult = & $module {
        param($Home, $Profiles, $State)
        Invoke-TestCodexActiveIdentity -CodexHome $Home `
            -ProfilesDirectory $Profiles -StateDirectory $State `
            -ProcessData @([pscustomobject]@{
                ProcessName = 'ChatGPT.exe'; Id = 9101
                ExecutablePath = 'C:\Program Files\WindowsApps\OpenAI.Codex_1.0.0.0_x64__test\app\ChatGPT.exe'
                PathReadStatus = 'Readable'
            }) -UseProvidedProcessData
    } $identityGateHome $identityGateProfiles $identityGateState
    $unknownIdentityResult = & $module {
        param($Home, $Profiles, $State)
        Invoke-TestCodexActiveIdentity -CodexHome $Home `
            -ProfilesDirectory $Profiles -StateDirectory $State `
            -ProcessData @([pscustomobject]@{
                ProcessName = 'ChatGPT.exe'; Id = 9102
                ExecutablePath = $null; PathReadStatus = 'Unavailable'
            }) -UseProvidedProcessData
    } $identityGateHome $identityGateProfiles $identityGateState
    if ($runningIdentityResult.Result -cne 'CODEX_PROCESS_RUNNING' -or
        $unknownIdentityResult.Result -cne 'CODEX_PROCESS_STATE_UNKNOWN' -or
        [System.IO.File]::Exists((Join-Path $identityGateHome 'auth.json'))) {
        throw 'SELFTEST_ACTIVE_IDENTITY_PROCESS_GATE_FAILED'
    }

    # Add-wizard safety: refresh the existing active slot only after the live
    # auth identity matches its protected marker. All paths are fake fixtures.
    $fixtureSaveActive = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'save-active-refresh') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    [System.IO.File]::WriteAllBytes($fixtureSaveActive.AuthPath, $fakeARefreshed)
    $saveActiveResult = & $module {
        param($Fixture)
        Invoke-SaveCodexActiveProfile -CodexHome $Fixture.CodexHome `
            -ProfilesDirectory $Fixture.Profiles -StateDirectory $Fixture.State `
            -ProcessData @() -UseProvidedProcessData
    } $fixtureSaveActive
    $savedActiveBytes = & $module {
        param($Profiles)
        Read-CodexAccountSlotBytes -Name 'A' -ProfilesDirectory $Profiles
    } $fixtureSaveActive.Profiles
    try {
        if ($saveActiveResult.Result -cne 'ACTIVE_PROFILE_SAVE_SUCCESS' -or
            -not (Test-ByteArrayEqual -Left $savedActiveBytes -Right $fakeARefreshed)) {
            throw 'SELFTEST_SAVE_ACTIVE_REFRESH_FAILED'
        }
    }
    finally {
        [Array]::Clear($savedActiveBytes, 0, $savedActiveBytes.Length)
    }

    $fixtureSaveActiveDrift = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'save-active-drift') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    [System.IO.File]::WriteAllBytes($fixtureSaveActiveDrift.AuthPath, $fakeC)
    $saveActiveDriftCode = $null
    try {
        & $module {
            param($Fixture)
            $null = Invoke-SaveCodexActiveProfile -CodexHome $Fixture.CodexHome `
                -ProfilesDirectory $Fixture.Profiles -StateDirectory $Fixture.State `
                -ProcessData @() -UseProvidedProcessData
        } $fixtureSaveActiveDrift
    }
    catch { $saveActiveDriftCode = $_.Exception.Message }
    $unchangedActiveBytes = & $module {
        param($Profiles)
        Read-CodexAccountSlotBytes -Name 'A' -ProfilesDirectory $Profiles
    } $fixtureSaveActiveDrift.Profiles
    try {
        if ($saveActiveDriftCode -cne 'ACTIVE_PROFILE_IDENTITY_MISMATCH' -or
            -not (Test-ByteArrayEqual -Left $unchangedActiveBytes -Right $fakeAInitial)) {
            throw 'SELFTEST_SAVE_ACTIVE_DRIFT_NOT_BLOCKED'
        }
    }
    finally {
        [Array]::Clear($unchangedActiveBytes, 0, $unchangedActiveBytes.Length)
    }

    # Identity 5: marker payloads are deliberately profile-name independent.
    # A future transactional rename can move the three artifacts and update
    # active state without decrypting or rewriting authentication content.
    $fixtureRename = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'identity-marker-rename') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    foreach ($suffix in @('.auth.dpapi', '.meta.json', '.identity.dpapi')) {
        [System.IO.File]::Move(
            (Join-Path $fixtureRename.Profiles ('A' + $suffix)),
            (Join-Path $fixtureRename.Profiles ('RenamedA' + $suffix))
        )
    }
    & $module {
        param($State)
        Write-ActiveProfileState -Name 'RenamedA' -StateDirectory $State
    } $fixtureRename.State
    $renamedMarkerMatches = & $module {
        param($Bytes, $Profiles)
        Assert-CodexAuthMatchesProfileIdentity -Name 'RenamedA' -AuthBytes $Bytes `
            -ProfilesDirectory $Profiles
    } $fakeAInitial $fixtureRename.Profiles
    if (-not $renamedMarkerMatches) {
        throw 'SELFTEST_RENAMED_MARKER_NOT_ASSOCIATED'
    }

    # A missing file-backed credential may mean Codex is using the OS keyring.
    # Qiehao must stop safely without creating any profile artifacts or state.
    $missingAuthRoot = Join-Path $workDirectoryFull 'missing-auth-file'
    $missingAuthHome = Join-Path $missingAuthRoot 'codex-home'
    $missingAuthProfiles = Join-Path $missingAuthRoot 'profiles'
    $missingAuthState = Join-Path $missingAuthRoot 'state'
    [System.IO.Directory]::CreateDirectory($missingAuthHome) | Out-Null
    [System.IO.Directory]::CreateDirectory($missingAuthProfiles) | Out-Null
    [System.IO.Directory]::CreateDirectory($missingAuthState) | Out-Null
    $missingAuthCode = $null
    try {
        & $module {
            param($Home, $Profiles, $State)
            $null = Invoke-AddCodexProfile -Name 'MissingAuth' -CodexHome $Home `
                -ProfilesDirectory $Profiles -StateDirectory $State `
                -ProcessData @() -UseProvidedProcessData
        } $missingAuthHome $missingAuthProfiles $missingAuthState
    }
    catch { $missingAuthCode = [string]$_.Exception.Message }
    if ($missingAuthCode -cne 'AUTH_FILE_NOT_FOUND' -or
        @(Get-ChildItem -LiteralPath $missingAuthProfiles -Force).Count -ne 0 -or
        @(Get-ChildItem -LiteralPath $missingAuthState -Force).Count -ne 0) {
        throw 'SELFTEST_MISSING_AUTH_FILE_NOT_FAIL_CLOSED'
    }

    # CRUD 1 + 4: add an arbitrary third identity C. This is not a special
    # Plus/Team code path and commits active state only after read-back checks.
    $fixtureAddC = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'crud-add-c') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    $existingProfilesBeforeAddC = Get-FakeTreeStamp -Root $fixtureAddC.Profiles
    [System.IO.File]::WriteAllBytes($fixtureAddC.AuthPath, $fakeC)
    $addCResult = & $module {
        param($Fixture)
        Invoke-AddCodexProfile -Name 'C' -CodexHome $Fixture.CodexHome `
            -ProfilesDirectory $Fixture.Profiles -StateDirectory $Fixture.State `
            -ProcessData @() -UseProvidedProcessData
    } $fixtureAddC
    $addedCBytes = & $module {
        param($Profiles)
        Read-CodexAccountSlotBytes -Name 'C' -ProfilesDirectory $Profiles
    } $fixtureAddC.Profiles
    try {
        $activeAfterAddC = & $module {
            param($State)
            Read-ActiveProfileState -StateDirectory $State
        } $fixtureAddC.State
        if ($addCResult.Result -cne 'PROFILE_ADD_SUCCESS' -or
            $activeAfterAddC.ActiveProfile -cne 'C' -or
            -not (Test-ByteArrayEqual -Left $addedCBytes -Right $fakeC) -or
            -not [System.IO.File]::Exists((Join-Path $fixtureAddC.Profiles 'C.identity.dpapi')) -or
            -not [System.IO.File]::Exists((Join-Path $fixtureAddC.Profiles 'C.meta.json'))) {
            throw 'SELFTEST_ADD_THIRD_PROFILE_FAILED'
        }
        $existingProfilesAfterAddC = @(
            Get-ChildItem -LiteralPath $fixtureAddC.Profiles -File | Where-Object {
                $_.BaseName -notlike 'C.*' -and
                $_.Name -notlike 'C.auth.dpapi' -and
                $_.Name -notlike 'C.identity.dpapi' -and
                $_.Name -notlike 'C.meta.json'
            }
        )
        $existingProfilesCopy = Join-Path $workDirectoryFull 'crud-add-c-existing-copy'
        [System.IO.Directory]::CreateDirectory($existingProfilesCopy) | Out-Null
        foreach ($existingFile in $existingProfilesAfterAddC) {
            [System.IO.File]::Copy(
                $existingFile.FullName,
                (Join-Path $existingProfilesCopy $existingFile.Name)
            )
            [System.IO.File]::SetLastWriteTimeUtc(
                (Join-Path $existingProfilesCopy $existingFile.Name),
                $existingFile.LastWriteTimeUtc
            )
        }
        if ((Get-FakeTreeStamp -Root $existingProfilesCopy) -cne
            $existingProfilesBeforeAddC) {
            throw 'SELFTEST_ADD_NEW_IDENTITY_MODIFIED_EXISTING_PROFILES'
        }
    }
    finally {
        [Array]::Clear($addedCBytes, 0, $addedCBytes.Length)
    }

    # CRUD 2: name collision rejects before creating or overwriting artifacts.
    $fixtureAddSameName = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'crud-add-same-name') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    [System.IO.File]::WriteAllBytes($fixtureAddSameName.AuthPath, $fakeC)
    $sameNameCode = $null
    try {
        & $module {
            param($Fixture)
            $null = Invoke-AddCodexProfile -Name 'A' -CodexHome $Fixture.CodexHome `
                -ProfilesDirectory $Fixture.Profiles -StateDirectory $Fixture.State `
                -ProcessData @() -UseProvidedProcessData
        } $fixtureAddSameName
    }
    catch { $sameNameCode = $_.Exception.Message }
    if ($sameNameCode -cne 'PROFILE_NAME_ALREADY_EXISTS') {
        throw 'SELFTEST_DUPLICATE_PROFILE_NAME_NOT_REJECTED'
    }

    # CRUD 3: when active state remains A but Codex is currently signed in as
    # the already-saved B identity, ADD rejects the duplicate without changing
    # A, B, or active state.
    $fixtureAddDuplicateIdentity = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'crud-add-duplicate-identity') `
        -Module $module -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    [System.IO.File]::WriteAllBytes(
        $fixtureAddDuplicateIdentity.AuthPath,
        $fakeB
    )
    $duplicateIdentityTreeBefore = Get-FakeTreeStamp `
        -Root $fixtureAddDuplicateIdentity.Profiles
    $duplicateIdentityStateBefore = Get-FakeTreeStamp `
        -Root $fixtureAddDuplicateIdentity.State
    $duplicateIdentityCode = $null
    $duplicateIdentityProfile = $null
    try {
        & $module {
            param($Fixture)
            $null = Invoke-AddCodexProfile -Name 'AnotherB' `
                -CodexHome $Fixture.CodexHome `
                -ProfilesDirectory $Fixture.Profiles -StateDirectory $Fixture.State `
                -ProcessData @() -UseProvidedProcessData
        } $fixtureAddDuplicateIdentity
    }
    catch {
        $duplicateIdentityCode = $_.Exception.Message
        $duplicateIdentityProfile = [string]$_.Exception.Data['ExistingProfile']
    }
    if ($duplicateIdentityCode -cne 'PROFILE_IDENTITY_ALREADY_EXISTS' -or
        $duplicateIdentityProfile -cne 'B' -or
        [System.IO.File]::Exists((Join-Path $fixtureAddDuplicateIdentity.Profiles 'AnotherB.auth.dpapi')) -or
        (Get-FakeTreeStamp -Root $fixtureAddDuplicateIdentity.Profiles) -cne
            $duplicateIdentityTreeBefore -or
        (Get-FakeTreeStamp -Root $fixtureAddDuplicateIdentity.State) -cne
            $duplicateIdentityStateBefore) {
        throw 'SELFTEST_DUPLICATE_IDENTITY_NOT_REJECTED'
    }

    # CRUD 5: removing a non-active complete profile deletes only its three
    # known artifact types and leaves active state unchanged.
    $fixtureRemove = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'crud-remove') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    $removeResult = & $module {
        param($Fixture)
        Invoke-RemoveCodexProfile -Name 'B' -ProfilesDirectory $Fixture.Profiles `
            -StateDirectory $Fixture.State -ConfirmDelete
    } $fixtureRemove
    $activeAfterRemove = & $module {
        param($State)
        Read-ActiveProfileState -StateDirectory $State
    } $fixtureRemove.State
    if ($removeResult.Result -cne 'PROFILE_REMOVE_SUCCESS' -or
        $activeAfterRemove.ActiveProfile -cne 'A' -or
        [System.IO.File]::Exists((Join-Path $fixtureRemove.Profiles 'B.auth.dpapi')) -or
        [System.IO.File]::Exists((Join-Path $fixtureRemove.Profiles 'B.identity.dpapi')) -or
        [System.IO.File]::Exists((Join-Path $fixtureRemove.Profiles 'B.meta.json'))) {
        throw 'SELFTEST_REMOVE_NON_ACTIVE_FAILED'
    }

    # Removal without explicit confirmation is always rejected.
    $fixtureRemoveNoConfirm = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'crud-remove-no-confirm') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    $removeNoConfirmCode = $null
    try {
        & $module {
            param($Fixture)
            $null = Invoke-RemoveCodexProfile -Name 'B' `
                -ProfilesDirectory $Fixture.Profiles -StateDirectory $Fixture.State
        } $fixtureRemoveNoConfirm
    }
    catch { $removeNoConfirmCode = $_.Exception.Message }
    if ($removeNoConfirmCode -cne 'PROFILE_REMOVE_CONFIRMATION_REQUIRED') {
        throw 'SELFTEST_REMOVE_WITHOUT_CONFIRMATION_NOT_REJECTED'
    }

    # CRUD 6: active profile deletion is prohibited even with confirmation.
    $fixtureRemoveActive = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'crud-remove-active') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    $removeActiveCode = $null
    try {
        & $module {
            param($Fixture)
            $null = Invoke-RemoveCodexProfile -Name 'A' `
                -ProfilesDirectory $Fixture.Profiles -StateDirectory $Fixture.State `
                -ConfirmDelete
        } $fixtureRemoveActive
    }
    catch { $removeActiveCode = $_.Exception.Message }
    if ($removeActiveCode -cne 'CANNOT_REMOVE_ACTIVE_PROFILE' -or
        -not [System.IO.File]::Exists((Join-Path $fixtureRemoveActive.Profiles 'A.auth.dpapi'))) {
        throw 'SELFTEST_ACTIVE_PROFILE_REMOVE_NOT_REJECTED'
    }

    # CRUD 7: a non-existent profile is not treated as an empty deletion.
    $removeMissingCode = $null
    try {
        & $module {
            param($Fixture)
            $null = Invoke-RemoveCodexProfile -Name 'Missing' `
                -ProfilesDirectory $Fixture.Profiles -StateDirectory $Fixture.State `
                -ConfirmDelete
        } $fixtureRemoveActive
    }
    catch { $removeMissingCode = $_.Exception.Message }
    if ($removeMissingCode -cne 'PROFILE_NOT_FOUND') {
        throw 'SELFTEST_MISSING_PROFILE_REMOVE_NOT_REJECTED'
    }

    # A quarantine move failure restores every formal Profile artifact and
    # reports a rolled-back delete rather than leaving a half-deleted slot.
    $fixtureRemovePartial = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'crud-remove-partial') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    $removePartialResult = & $module {
        param($Fixture)
        Invoke-RemoveCodexProfile -Name 'B' -ProfilesDirectory $Fixture.Profiles `
            -StateDirectory $Fixture.State -ConfirmDelete `
            -SimulateDeleteFailureType 'IdentityMarker'
    } $fixtureRemovePartial
    if ($removePartialResult.Result -cne 'PROFILE_REMOVE_FAILED_ROLLED_BACK' -or
        -not ($removePartialResult.FailedFileTypes -ccontains 'IdentityMarker') -or
        -not [System.IO.File]::Exists((Join-Path $fixtureRemovePartial.Profiles 'B.auth.dpapi')) -or
        -not [System.IO.File]::Exists((Join-Path $fixtureRemovePartial.Profiles 'B.identity.dpapi')) -or
        -not [System.IO.File]::Exists((Join-Path $fixtureRemovePartial.Profiles 'B.meta.json'))) {
        throw 'SELFTEST_PARTIAL_REMOVE_NOT_REPORTED'
    }

    # CRUD 8: rename a non-active profile without changing encrypted contents.
    $fixtureRenameNormal = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'crud-rename-normal') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    $oldAuthContainerBytes = [System.IO.File]::ReadAllBytes(
        (Join-Path $fixtureRenameNormal.Profiles 'B.auth.dpapi')
    )
    $oldMarkerContainerBytes = [System.IO.File]::ReadAllBytes(
        (Join-Path $fixtureRenameNormal.Profiles 'B.identity.dpapi')
    )
    $renameNormalResult = & $module {
        param($Fixture)
        Invoke-RenameCodexProfile -OldName 'B' -NewName 'Work' `
            -ProfilesDirectory $Fixture.Profiles -StateDirectory $Fixture.State
    } $fixtureRenameNormal
    $renamedAuthContainerBytes = [System.IO.File]::ReadAllBytes(
        (Join-Path $fixtureRenameNormal.Profiles 'Work.auth.dpapi')
    )
    $renamedMarkerContainerBytes = [System.IO.File]::ReadAllBytes(
        (Join-Path $fixtureRenameNormal.Profiles 'Work.identity.dpapi')
    )
    try {
        $renamedMetadata = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText(
            (Join-Path $fixtureRenameNormal.Profiles 'Work.meta.json')
        ))
        if ($renameNormalResult.Result -cne 'PROFILE_RENAME_SUCCESS' -or
            $renamedMetadata.profile_name -cne 'Work' -or
            -not (Test-ByteArrayEqual -Left $oldAuthContainerBytes `
                -Right $renamedAuthContainerBytes) -or
            -not (Test-ByteArrayEqual -Left $oldMarkerContainerBytes `
                -Right $renamedMarkerContainerBytes) -or
            [System.IO.File]::Exists((Join-Path $fixtureRenameNormal.Profiles 'B.auth.dpapi'))) {
            throw 'SELFTEST_NORMAL_PROFILE_RENAME_FAILED'
        }
    }
    finally {
        foreach ($buffer in @(
            $oldAuthContainerBytes,
            $oldMarkerContainerBytes,
            $renamedAuthContainerBytes,
            $renamedMarkerContainerBytes
        )) {
            [Array]::Clear($buffer, 0, $buffer.Length)
        }
        $renamedMetadata = $null
    }

    # CRUD 9: active rename commits active state last.
    $fixtureRenameActive = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'crud-rename-active') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    $renameActiveResult = & $module {
        param($Fixture)
        Invoke-RenameCodexProfile -OldName 'A' -NewName 'Primary' `
            -ProfilesDirectory $Fixture.Profiles -StateDirectory $Fixture.State
    } $fixtureRenameActive
    $stateAfterActiveRename = & $module {
        param($State)
        Read-ActiveProfileState -StateDirectory $State
    } $fixtureRenameActive.State
    if ($renameActiveResult.Result -cne 'PROFILE_RENAME_SUCCESS' -or
        -not $renameActiveResult.ActiveProfileRenamed -or
        $stateAfterActiveRename.ActiveProfile -cne 'Primary') {
        throw 'SELFTEST_ACTIVE_PROFILE_RENAME_STATE_FAILED'
    }

    # CRUD 10: injected mid-move failure rolls every completed move back.
    $fixtureRenameRollback = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'crud-rename-rollback') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    $renameRollbackCode = $null
    try {
        & $module {
            param($Fixture)
            $null = Invoke-RenameCodexProfile -OldName 'B' -NewName 'Work' `
                -ProfilesDirectory $Fixture.Profiles -StateDirectory $Fixture.State `
                -SimulateFailureAfterMoveCount 2
        } $fixtureRenameRollback
    }
    catch { $renameRollbackCode = $_.Exception.Message }
    if ($renameRollbackCode -cne 'PROFILE_RENAME_FAILED_ROLLED_BACK' -or
        -not [System.IO.File]::Exists((Join-Path $fixtureRenameRollback.Profiles 'B.auth.dpapi')) -or
        -not [System.IO.File]::Exists((Join-Path $fixtureRenameRollback.Profiles 'B.identity.dpapi')) -or
        -not [System.IO.File]::Exists((Join-Path $fixtureRenameRollback.Profiles 'B.meta.json')) -or
        [System.IO.File]::Exists((Join-Path $fixtureRenameRollback.Profiles 'Work.auth.dpapi'))) {
        throw 'SELFTEST_PROFILE_RENAME_ROLLBACK_FAILED'
    }

    # CRUD 11: missing one of the three artifacts is visibly incomplete.
    $fixtureHealth = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'crud-health') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    [System.IO.File]::Delete((Join-Path $fixtureHealth.Profiles 'B.identity.dpapi'))
    $healthRows = @(& $module {
        param($Fixture)
        Get-CodexAccountSlotState -ProfilesDirectory $Fixture.Profiles `
            -StateDirectory $Fixture.State
    } $fixtureHealth)
    $healthB = @($healthRows | Where-Object { $_.Profile -ceq 'B' })
    if ($healthB.Count -ne 1 -or
        $healthB[0].Health -cne 'INCOMPLETE_PROFILE' -or
        $healthB[0].IdentityMarker -cne 'MISSING') {
        throw 'SELFTEST_INCOMPLETE_PROFILE_HEALTH_FAILED'
    }

    # CRUD 12: deep verification confirms local integrity and compares the
    # current fake Codex file identity. Legacy opaque tokens are not promoted
    # to a full workspace verification success.
    $fixtureVerify = New-SwitchFixture `
        -Root (Join-Path $workDirectoryFull 'crud-verify') -Module $module `
        -ActiveBytes $fakeAInitial -TargetBytes $fakeB
    [System.IO.File]::WriteAllBytes($fixtureVerify.AuthPath, $fakeB)
    $verifyResult = & $module {
        param($Fixture)
        Invoke-VerifyCodexProfile -Name 'B' -ProfilesDirectory $Fixture.Profiles `
            -CodexHome $Fixture.CodexHome `
            -ProcessData @() -UseProvidedProcessData
    } $fixtureVerify
    if ($verifyResult.Result -cne 'PROFILE_VERIFY_WORKSPACE_CONTEXT_UNKNOWN' -or
        $verifyResult.ProfileIntegrity -cne 'Complete' -or
        $verifyResult.WorkspaceContextStatus -cne 'LegacyUnknown') {
        throw 'SELFTEST_PROFILE_VERIFY_FAILED'
    }

    # CRUD 13: swap in A's protected marker for B; verify must detect mismatch.
    $aMarkerBytes = [System.IO.File]::ReadAllBytes(
        (Join-Path $fixtureVerify.Profiles 'A.identity.dpapi')
    )
    try {
        [System.IO.File]::WriteAllBytes(
            (Join-Path $fixtureVerify.Profiles 'B.identity.dpapi'),
            $aMarkerBytes
        )
    }
    finally {
        [Array]::Clear($aMarkerBytes, 0, $aMarkerBytes.Length)
    }
    $verifyMismatchCode = $null
    try {
        & $module {
            param($Fixture)
            $null = Invoke-VerifyCodexProfile -Name 'B' `
                -ProfilesDirectory $Fixture.Profiles `
                -CodexHome $Fixture.CodexHome `
                -ProcessData @() -UseProvidedProcessData
        } $fixtureVerify
    }
    catch { $verifyMismatchCode = $_.Exception.Message }
    if ($verifyMismatchCode -cne 'PROFILE_IDENTITY_MISMATCH') {
        throw 'SELFTEST_PROFILE_VERIFY_IDENTITY_MISMATCH_NOT_REJECTED'
    }

    # CRUD 14: a separate process holds the same named mutex. A second write
    # operation must be rejected immediately rather than race or deadlock.
    $defaultLockResult = & $module {
        Invoke-WithCodexWriteLock -Operation { 'DEFAULT_LOCK_PASS' }
    }
    if ($defaultLockResult -cne 'DEFAULT_LOCK_PASS') {
        throw 'SELFTEST_DEFAULT_USER_MUTEX_FAILED'
    }
    $testMutexName = 'Local\Qiehaoqu.SelfTest.' + [Guid]::NewGuid().ToString('N')
    $mutexReadyPath = Join-Path $workDirectoryFull 'mutex-ready.signal'
    $mutexReleasePath = Join-Path $workDirectoryFull 'mutex-release.signal'
    $lockJob = Start-Job -ArgumentList @(
        $modulePath,
        $testMutexName,
        $mutexReadyPath,
        $mutexReleasePath
    ) -ScriptBlock {
        param($ModulePath, $MutexName, $ReadyPath, $ReleasePath)
        $jobModule = Import-Module -Name $ModulePath -Force -PassThru
        & $jobModule {
            param($Name, $Ready, $Release)
            Invoke-WithCodexWriteLock -MutexName $Name -Operation {
                param($ReadyFile, $ReleaseFile)
                [System.IO.File]::WriteAllText($ReadyFile, 'READY')
                $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
                while (-not [System.IO.File]::Exists($ReleaseFile) -and
                    $stopwatch.Elapsed.TotalSeconds -lt 15) {
                    Start-Sleep -Milliseconds 25
                }
                return 'FIRST_OPERATION_COMPLETE'
            } -ArgumentList @($Ready, $Release)
        } $MutexName $ReadyPath $ReleasePath
    }
    try {
        $readyWatch = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not [System.IO.File]::Exists($mutexReadyPath) -and
            $readyWatch.Elapsed.TotalSeconds -lt 10) {
            Start-Sleep -Milliseconds 25
        }
        if (-not [System.IO.File]::Exists($mutexReadyPath)) {
            throw 'SELFTEST_FIRST_WRITE_LOCK_NOT_ACQUIRED'
        }
        $concurrentCode = $null
        try {
            & $module {
                param($Name)
                $null = Invoke-WithCodexWriteLock -MutexName $Name `
                    -Operation { 'SECOND_OPERATION_SHOULD_NOT_RUN' }
            } $testMutexName
        }
        catch { $concurrentCode = $_.Exception.Message }
        if ($concurrentCode -cne 'OPERATION_BUSY') {
            throw 'SELFTEST_CONCURRENT_WRITE_NOT_REJECTED'
        }
    }
    finally {
        [System.IO.File]::WriteAllText($mutexReleasePath, 'RELEASE')
        $null = Wait-Job -Job $lockJob -Timeout 20
        $null = Receive-Job -Job $lockJob -ErrorAction SilentlyContinue
        Remove-Job -Job $lockJob -Force -ErrorAction SilentlyContinue
    }

    & $module {
        Write-QiehaoDiagnosticEvent -Event 'APP_START' -Result 'STARTED' `
            -Data @{
                Version = 'SELFTEST'
                PowerShellVersion = [string]$PSVersionTable.PSVersion
                WindowsVersion = 'SELFTEST_WINDOWS'
                CodexHomeExists = $true
                CredentialSource = 'File'
                ProfileCount = 2
            }
        Write-QiehaoDiagnosticEvent -Event 'DELETE_FAILED' -Level 'ERROR' `
            -Result 'SELFTEST_DELETE_FAILED' -Data @{
                Profile = 'token=test123 user@example.com'
                ResultCode = 'SELFTEST_DELETE_FAILED'
                auth = '{"access_token":"DO_NOT_LOG_AUTH"}'
                account_id = 'DO_NOT_LOG_ACCOUNT_ID'
            }
    }
    $diagnosticLogPath = Join-Path $diagnosticLogDirectory 'qiehao.log'
    if (-not [System.IO.File]::Exists($diagnosticLogPath)) {
        throw 'SELFTEST_DIAGNOSTIC_LOG_NOT_WRITTEN'
    }
    $diagnosticLogText = [System.IO.File]::ReadAllText($diagnosticLogPath)
    foreach ($forbiddenText in @(
        'test123', 'user@example.com', 'DO_NOT_LOG_AUTH',
        'DO_NOT_LOG_ACCOUNT_ID', 'SELFTEST-ACCESS-', 'SELFTEST-REFRESH-',
        'SELFTEST-ID-', 'SELFTEST-ACCOUNT-'
    )) {
        if ($diagnosticLogText.Contains($forbiddenText)) {
            throw 'SELFTEST_DIAGNOSTIC_LOG_CONTAINS_SENSITIVE_VALUE'
        }
    }
    $diagnosticEntries = @(
        [System.IO.File]::ReadAllLines($diagnosticLogPath) | ForEach-Object {
            ConvertFrom-Json -InputObject $_ -ErrorAction Stop
        }
    )
    $diagnosticEvents = @($diagnosticEntries | ForEach-Object {
        [string]$_.event
    })
    foreach ($requiredEvent in @(
        'APP_START', 'ADD_START', 'ADD_AUTH_FOUND', 'ADD_IDENTITY_PARSE',
        'SWITCH_START', 'PROCESS_CHECK_RESULT', 'PROCESS_WAIT_START',
        'PROCESS_RECHECK', 'PROCESS_EXITED_DURING_WAIT',
        'PROCESS_STILL_RUNNING', 'WORKSPACE_DETECT',
        'WORKSPACE_TYPE_MISMATCH',
        'AUTH_REPLACE', 'READBACK_VERIFY', 'SWITCH_SUCCESS',
        'SWITCH_FAILED', 'VERIFY_START', 'PROFILE_INTEGRITY_RESULT',
        'CURRENT_IDENTITY_RESULT', 'VERIFY_FAILED',
        'DELETE_FAILED'
    )) {
        if ($diagnosticEvents -cnotcontains $requiredEvent) {
            throw ('SELFTEST_DIAGNOSTIC_EVENT_MISSING_' + $requiredEvent)
        }
    }
    if ($diagnosticLogText -notmatch '\[token_removed\]' -or
        $diagnosticLogText -notmatch '\[email_removed\]') {
        throw 'SELFTEST_DIAGNOSTIC_REDACTION_NOT_APPLIED'
    }

    [pscustomobject]@{
        Result = 'PASS'
        AuthSchemaValidation = 'PASS'
        AgentIdentityTopLevelFieldAccepted = 'PASS'
        UnknownOptionalTopLevelFieldAccepted = 'PASS'
        ForwardCompatibleBytesPreserved = 'PASS'
        InvalidJsonRejected = 'PASS'
        NonObjectRootRejected = 'PASS'
        MissingOrInvalidAuthModeRejected = 'PASS'
        MissingOrInvalidTokensRejected = 'PASS'
        MissingInvalidOrEmptyAccountIdRejected = 'PASS'
        DuplicateCriticalFieldsRejected = 'PASS'
        DpapiRoundTrip = 'PASS'
        AtomicProfileRoundTrip = 'PASS'
        DefaultOverwriteRejected = 'PASS'
        ExplicitCodexProcessBlocked = 'PASS'
        UnrelatedNodeAllowed = 'PASS'
        UnrelatedPwshAllowed = 'PASS'
        CodexChatGPTPathBlocked = 'PASS'
        EmptyProcessSetAllowed = 'PASS'
        UnreadableChatGPTIsUnknown = 'PASS'
        OwnedQuotaChildExcluded = 'PASS'
        DesktopStillBlocksWithQuotaChild = 'PASS'
        UnverifiedQuotaChildBlocked = 'PASS'
        CredentialSourceModesDetected = 'PASS'
        ChromeExtensionHostAllowed = 'PASS'
        EdgeExtensionHostAllowed = 'PASS'
        CodexExtensionHostBlocked = 'PASS'
        UnknownExtensionHostIsUnknown = 'PASS'
        SwitchAToB = 'PASS'
        RefreshedActiveSavedBeforeSwitch = 'PASS'
        TargetDpapiFailureLeavesAuth = 'PASS'
        TargetSchemaFailureLeavesAuth = 'PASS'
        PostReplaceFailureRollsBack = 'PASS'
        MissingActiveRejected = 'PASS'
        AlreadyActiveRejected = 'PASS'
        ActiveProfileOutOfSyncDetected = 'PASS'
        SavedIdentityActiveStateSynchronized = 'PASS'
        ActiveStateSyncPreservesCredentialArtifacts = 'PASS'
        UnknownIdentitySyncRejected = 'PASS'
        BrowserExtensionAllowsSwitch = 'PASS'
        CodexProcessBlocksSwitch = 'PASS'
        CodexDelayedExitContinues = 'PASS'
        CodexWaitTimeoutFailsClosed = 'PASS'
        SameUserDifferentWorkspacePreserved = 'PASS'
        TeamPersonalDriftDetected = 'PASS'
        PersonalTeamDriftDetected = 'PASS'
        WorkspaceClaimMismatchRejected = 'PASS'
        VerifyCurrentWorkspaceMismatch = 'PASS'
        WorkspaceMismatchDiagnostic = 'PASS'
        DeleteDriftRecoverySafe = 'PASS'
        InitActiveMismatchRejected = 'PASS'
        RefreshedTokenIdentityMatch = 'PASS'
        ActiveIdentityDriftRejected = 'PASS'
        MissingIdentityMarkerRejected = 'PASS'
        LegacyMarkerInitialization = 'PASS'
        UnknownIdentitySchemaRejected = 'PASS'
        ActiveIdentityConfirmedReadOnly = 'PASS'
        ActiveIdentityMismatchReported = 'PASS'
        ActiveIdentityProcessGate = 'PASS'
        SaveActiveRefresh = 'PASS'
        SaveActiveIdentityDriftRejected = 'PASS'
        RenamedProfileMarkerAssociated = 'PASS'
        WebSessionIsolation = 'PASS'
        MissingAuthFileFailsClosed = 'PASS'
        AddThirdProfile = 'PASS'
        AddDifferentIdentityPreservesExistingProfiles = 'PASS'
        DuplicateProfileNameRejected = 'PASS'
        DuplicateIdentityRejected = 'PASS'
        DuplicateSavedIdentityPreservesProfilesAndState = 'PASS'
        AddNewIdentity = 'PASS'
        RemoveNonActiveProfile = 'PASS'
        RemoveActiveProfileRejected = 'PASS'
        RemoveMissingProfileRejected = 'PASS'
        RemoveRequiresConfirmation = 'PASS'
        RemovePartialFailureReported = 'PASS'
        RenameProfile = 'PASS'
        RenameActiveStateSynchronized = 'PASS'
        RenameFailureRolledBack = 'PASS'
        IncompleteProfileHealth = 'PASS'
        VerifyProfile = 'PASS'
        VerifyIdentityMismatchRejected = 'PASS'
        ConcurrentWriteRejected = 'PASS'
        DefaultUserScopedLock = 'PASS'
        StructuredDiagnosticLog = 'PASS'
        DiagnosticSensitiveValuesRemoved = 'PASS'
        DiagnosticLifecycleEvents = 'PASS'
        RealCodexAuthRead = $false
    }
}
finally {
    if ([System.IO.Directory]::Exists($workDirectoryFull)) {
        [System.IO.Directory]::Delete($workDirectoryFull, $true)
    }

    foreach ($buffer in @(
        $plainBytes,
        $agentIdentityBytes,
        $unknownOptionalBytes,
        $forwardRoundTripBytes,
        $forwardIdentityBytes,
        $protectedBytes,
        $unprotectedBytes,
        $roundTripBytes,
        $fakeAInitial,
        $fakeARefreshed,
        $fakeB,
        $fakeC,
        $fakeX,
        $fakeWorkspaceTeam,
        $fakeWorkspacePersonal,
        $fakeWorkspaceClaimMismatch,
        $fakeInvalidB,
        $fakeIdentitySchemaUnknown
    )) {
        if ($null -ne $buffer -and $buffer.Length -gt 0) {
            [Array]::Clear($buffer, 0, $buffer.Length)
        }
    }
    $fakeJson = $null
    $agentIdentityJson = $null
    $unknownOptionalJson = $null
}
