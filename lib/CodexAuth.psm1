Set-StrictMode -Version 2.0

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:ProfilesDirectory = Join-Path -Path $script:ProjectRoot -ChildPath 'profiles'
$script:LogsDirectory = Join-Path -Path $script:ProjectRoot -ChildPath 'logs'
$script:StateDirectory = Join-Path -Path $script:ProjectRoot -ChildPath 'state'
$script:BackupDirectory = Join-Path -Path $script:ProjectRoot -ChildPath 'backup'
$script:EntropyText = 'CodexAccountSwitcher-v1'
$script:IdentityEntropyText = 'CodexAccountSwitcher-Identity-v1'
$script:MaximumAuthFileBytes = 16MB
$script:RequiredAuthKeys = @('auth_mode', 'tokens')
$script:IdentityMarkerHeader = [byte[]](0x51, 0x48, 0x49, 0x44, 0x01, 0x01)
$script:MaximumIdentityBytes = 2048
$script:MaximumMetadataFileBytes = 64KB
$script:CodexProcessExitWaitMilliseconds = 8000
$script:CodexProcessRecheckIntervalMilliseconds = 500
$script:WriteMutexName = 'Local\Qiehaoqu.CodexAccountSwitcher.WriteOperation.v1'
$script:ProfileDeleteTrashDirectoryName = '.trash'
$script:ProfileDeleteCommitMarkerSuffix = '.committed'
$script:ProfileDeleteCommitMarkerContent = 'QIEHAO_PROFILE_DELETE_COMMITTED_V1'
$windowsIdentity = $null
try {
    $windowsIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($null -ne $windowsIdentity.User) {
        $script:WriteMutexName = 'Global\Qiehaoqu.CodexAccountSwitcher.' +
            $windowsIdentity.User.Value + '.WriteOperation.v1'
    }
}
catch {
    # The Local fallback still protects multiple instances in the interactive
    # desktop session when a user SID cannot be obtained.
}
finally {
    if ($null -ne $windowsIdentity) {
        $windowsIdentity.Dispose()
    }
    $windowsIdentity = $null
}

function New-SafeException {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Code
    )

    return New-Object System.InvalidOperationException($Code)
}

function Initialize-QiehaoRuntimeDirectories {
    [CmdletBinding()]
    param()

    try {
        $rootPath = [System.IO.Path]::GetFullPath($script:ProjectRoot).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
        if (-not [System.IO.Directory]::Exists($rootPath)) {
            throw (New-SafeException -Code 'RUNTIME_DATA_ROOT_INVALID')
        }
        $rootInfo = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
        if (($rootInfo.Attributes -band
                [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw (New-SafeException -Code 'RUNTIME_DATA_ROOT_UNSAFE')
        }

        foreach ($runtimeDirectory in @(
            $script:ProfilesDirectory,
            $script:StateDirectory,
            $script:LogsDirectory,
            $script:BackupDirectory
        )) {
            $fullPath = [System.IO.Path]::GetFullPath($runtimeDirectory)
            $parentPath = [System.IO.Path]::GetDirectoryName($fullPath).TrimEnd(
                [System.IO.Path]::DirectorySeparatorChar,
                [System.IO.Path]::AltDirectorySeparatorChar
            )
            if (-not $parentPath.Equals(
                    $rootPath,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw (New-SafeException -Code 'RUNTIME_DIRECTORY_UNSAFE')
            }
            if ([System.IO.File]::Exists($fullPath)) {
                throw (New-SafeException -Code 'RUNTIME_DIRECTORY_UNSAFE')
            }
            [System.IO.Directory]::CreateDirectory($fullPath) | Out-Null
            $directoryInfo = Get-Item -LiteralPath $fullPath -Force `
                -ErrorAction Stop
            if (($directoryInfo.Attributes -band
                    [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw (New-SafeException -Code 'RUNTIME_DIRECTORY_UNSAFE')
            }
        }

        return [pscustomobject]@{
            Result = 'RUNTIME_BOOTSTRAP_SUCCESS'
            DataRoot = $rootPath
        }
    }
    catch [System.InvalidOperationException] {
        if ($_.Exception.Message -match '^RUNTIME_[A-Z0-9_]+$') {
            throw
        }
        throw (New-SafeException -Code 'RUNTIME_DIRECTORY_INITIALIZATION_FAILED')
    }
    catch {
        throw (New-SafeException -Code 'RUNTIME_DIRECTORY_INITIALIZATION_FAILED')
    }
}

# Git and ZIP archives do not preserve empty runtime directories. Bootstrap
# them before any exported account operation can run.
$null = Initialize-QiehaoRuntimeDirectories

function Invoke-WithCodexWriteLock {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Operation,

        [object[]]$ArgumentList = @(),

        [string]$MutexName = $script:WriteMutexName
    )

    if ([string]::IsNullOrWhiteSpace($MutexName)) {
        throw (New-SafeException -Code 'OPERATION_LOCK_INVALID')
    }

    $mutex = $null
    $lockAcquired = $false
    try {
        $createdNew = $false
        $mutex = New-Object System.Threading.Mutex($false, $MutexName, [ref]$createdNew)
        try {
            $lockAcquired = $mutex.WaitOne(0, $false)
        }
        catch [System.Threading.AbandonedMutexException] {
            # An abandoned mutex grants ownership to this thread. Continue and
            # release it in finally; profile-level validation still fails closed
            # if the previous process stopped during a write.
            $lockAcquired = $true
        }

        if (-not $lockAcquired) {
            throw (New-SafeException -Code 'OPERATION_BUSY')
        }
        return & $Operation @ArgumentList
    }
    finally {
        if ($null -ne $mutex) {
            if ($lockAcquired) {
                try {
                    $mutex.ReleaseMutex()
                }
                catch {
                    # Never replace the operation result with a lock cleanup
                    # detail. Disposing the handle still prevents handle leaks.
                }
            }
            $mutex.Dispose()
        }
    }
}

function Get-CodexHome {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $explicitHome = [Environment]::GetEnvironmentVariable(
        'CODEX_HOME',
        [EnvironmentVariableTarget]::Process
    )

    if (-not [string]::IsNullOrWhiteSpace($explicitHome)) {
        $candidate = $explicitHome.Trim()
        if (-not [System.IO.Path]::IsPathRooted($candidate)) {
            throw (New-SafeException -Code 'CODEX_HOME_INVALID')
        }
    }
    else {
        $userProfile = [Environment]::GetEnvironmentVariable(
            'USERPROFILE',
            [EnvironmentVariableTarget]::Process
        )
        if ([string]::IsNullOrWhiteSpace($userProfile)) {
            throw (New-SafeException -Code 'USERPROFILE_NOT_AVAILABLE')
        }

        $candidate = Join-Path -Path $userProfile -ChildPath '.codex'
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($candidate)
    }
    catch {
        throw (New-SafeException -Code 'CODEX_HOME_INVALID')
    }

    if (-not [System.IO.Directory]::Exists($fullPath)) {
        throw (New-SafeException -Code 'CODEX_HOME_NOT_FOUND')
    }

    return $fullPath
}

# Credential source detection is intentionally metadata-only. It never opens
# an operating-system keyring or emits credential contents.
function Get-CodexCredentialSourceInfo {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexHome,

        [AllowNull()][string]$ConfigText,

        [switch]$UseProvidedConfigText
    )

    $homePath = [System.IO.Path]::GetFullPath($CodexHome)
    $authPath = Join-Path -Path $homePath -ChildPath 'auth.json'
    $configPath = Join-Path -Path $homePath -ChildPath 'config.toml'
    $configAvailable = $UseProvidedConfigText
    if (-not $UseProvidedConfigText -and [System.IO.File]::Exists($configPath)) {
        try {
            $configInfo = Get-Item -LiteralPath $configPath -Force -ErrorAction Stop
            if (($configInfo.Attributes -band
                    [System.IO.FileAttributes]::ReparsePoint) -ne 0 -or
                $configInfo.Length -gt $script:MaximumMetadataFileBytes) {
                throw (New-SafeException -Code 'AUTH_CREDENTIAL_SOURCE_UNKNOWN')
            }
            $ConfigText = [System.IO.File]::ReadAllText($configPath)
            $configAvailable = $true
        }
        catch [System.InvalidOperationException] { throw }
        catch {
            throw (New-SafeException -Code 'AUTH_CREDENTIAL_SOURCE_UNKNOWN')
        }
    }

    $configuredModes = @()
    $mentionsSetting = $false
    if ($configAvailable -and $null -ne $ConfigText) {
        foreach ($line in ($ConfigText -split "`r?`n")) {
            if ($line -match '(?i)^\s*cli_auth_credentials_store\s*=') {
                $mentionsSetting = $true
                $match = [regex]::Match(
                    $line,
                    '(?i)^\s*cli_auth_credentials_store\s*=\s*["''](?<mode>file|keyring|auto|ephemeral)["'']\s*(?:#.*)?$'
                )
                if (-not $match.Success) {
                    throw (New-SafeException -Code 'AUTH_CREDENTIAL_SOURCE_UNKNOWN')
                }
                $configuredModes += $match.Groups['mode'].Value.ToLowerInvariant()
            }
        }
    }
    if ($mentionsSetting -and $configuredModes.Count -ne 1) {
        throw (New-SafeException -Code 'AUTH_CREDENTIAL_SOURCE_UNKNOWN')
    }

    $mode = if ($configuredModes.Count -eq 1) {
        [string]$configuredModes[0]
    }
    else { 'unspecified' }
    $source = switch ($mode) {
        'file' { 'File' }
        'keyring' { 'CredentialStore' }
        'auto' { 'Unknown' }
        'ephemeral' { 'Ephemeral' }
        # Legacy Codex installations do not declare this setting. Preserve
        # the file-backed contract so the later sensitive-file read returns
        # the precise AUTH_FILE_NOT_FOUND guidance when auth.json is absent.
        default { 'File' }
    }
    $resultCode = switch ($mode) {
        'keyring' { 'AUTH_CREDENTIAL_SOURCE_UNSUPPORTED' }
        'auto' { 'AUTH_CREDENTIAL_SOURCE_AMBIGUOUS' }
        'ephemeral' { 'AUTH_CREDENTIAL_SOURCE_UNSUPPORTED' }
        default {
            if ($source -ceq 'File') { 'AUTH_CREDENTIAL_SOURCE_FILE' }
            else { 'AUTH_CREDENTIAL_SOURCE_UNKNOWN' }
        }
    }
    return [pscustomobject]@{
        Source = $source
        ConfiguredMode = $mode
        Confidence = if ($mode -ceq 'unspecified') { 'Inferred' } else { 'Explicit' }
        ResultCode = $resultCode
        FileCredentialUsable = $resultCode -ceq 'AUTH_CREDENTIAL_SOURCE_FILE'
        CodexHome = $homePath
        ConfigPath = $configPath
    }
}

function Assert-CodexFileCredentialSource {
    param([Parameter(Mandatory = $true)][string]$CodexHome)

    $source = Get-CodexCredentialSourceInfo -CodexHome $CodexHome
    if (-not $source.FileCredentialUsable) {
        throw (New-SafeException -Code ([string]$source.ResultCode))
    }
    return $source
}

function ConvertTo-SafeProfileName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $trimmed = $Name.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        throw (New-SafeException -Code 'PROFILE_NAME_INVALID')
    }
    if ($trimmed.Length -gt 64) {
        throw (New-SafeException -Code 'PROFILE_NAME_TOO_LONG')
    }

    # Keep Unicode letters/numbers, dot, underscore, and hyphen. Everything
    # else is deterministically reduced to an underscore so it cannot become
    # a path separator, alternate-data-stream marker, wildcard, or control.
    $safeName = [regex]::Replace($trimmed, '[^\p{L}\p{Nd}._-]', '_')
    $safeName = [regex]::Replace($safeName, '_+', '_')
    $safeName = $safeName.Trim([char[]]@('.', ' '))

    if ([string]::IsNullOrWhiteSpace($safeName) -or
        $safeName -eq '.' -or
        $safeName -eq '..' -or
        $safeName.Length -gt 64) {
        throw (New-SafeException -Code 'PROFILE_NAME_INVALID')
    }

    if ($safeName -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
        throw (New-SafeException -Code 'PROFILE_NAME_RESERVED')
    }

    return $safeName
}

function Test-SafeProfileFileStem {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Name.Length -lt 1 -or $Name.Length -gt 64) {
        return $false
    }
    if ($Name -notmatch '^[\p{L}\p{Nd}_-][\p{L}\p{Nd}._-]{0,63}$') {
        return $false
    }
    if ($Name -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
        return $false
    }
    return $true
}

function Read-SensitiveFileBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not [System.IO.File]::Exists($Path)) {
        throw (New-SafeException -Code 'AUTH_FILE_NOT_FOUND')
    }

    $stream = $null
    $buffer = $null
    try {
        $stream = New-Object System.IO.FileStream(
            $Path,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::Read
        )

        if ($stream.Length -le 0) {
            throw (New-SafeException -Code 'AUTH_FILE_EMPTY')
        }
        if ($stream.Length -gt $script:MaximumAuthFileBytes) {
            throw (New-SafeException -Code 'AUTH_FILE_TOO_LARGE')
        }

        $buffer = New-Object byte[] ([int]$stream.Length)
        $offset = 0
        while ($offset -lt $buffer.Length) {
            $read = $stream.Read($buffer, $offset, $buffer.Length - $offset)
            if ($read -le 0) {
                throw (New-SafeException -Code 'AUTH_FILE_READ_FAILED')
            }
            $offset += $read
        }

        return ,$buffer
    }
    catch [System.InvalidOperationException] {
        throw
    }
    catch {
        if ($null -ne $buffer -and $buffer.Length -gt 0) {
            [Array]::Clear($buffer, 0, $buffer.Length)
        }
        throw (New-SafeException -Code 'AUTH_FILE_READ_FAILED')
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
    }
}

function Get-AuthTopLevelPropertyNames {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $jsonDocumentType = [Type]::GetType(
        'System.Text.Json.JsonDocument, System.Text.Json',
        $false
    )

    if ($null -ne $jsonDocumentType) {
        $memoryStream = $null
        $document = $null
        try {
            $memoryStream = New-Object System.IO.MemoryStream(, $Bytes)
            $document = [System.Text.Json.JsonDocument]::Parse($memoryStream)
            if ($document.RootElement.ValueKind.ToString() -ne 'Object') {
                throw (New-SafeException -Code 'AUTH_SCHEMA_UNEXPECTED')
            }

            $names = @()
            foreach ($property in $document.RootElement.EnumerateObject()) {
                # Deliberately access only the property name. Never enumerate or
                # format the value, including the nested tokens object.
                $names += $property.Name
            }
            return $names
        }
        catch [System.InvalidOperationException] {
            throw
        }
        catch {
            throw (New-SafeException -Code 'AUTH_JSON_INVALID')
        }
        finally {
            if ($null -ne $document) {
                $document.Dispose()
            }
            if ($null -ne $memoryStream) {
                $memoryStream.Dispose()
            }
        }
    }

    # Windows PowerShell 5.1 does not ship System.Text.Json. The framework JSON
    # reader preserves duplicate properties, unlike ConvertFrom-Json, so the
    # same fail-closed duplicate-key checks apply on both supported runtimes.
    $reader = $null
    $document = $null
    try {
        $null = Add-Type -AssemblyName System.Runtime.Serialization `
            -ErrorAction SilentlyContinue
        $reader = [System.Runtime.Serialization.Json.JsonReaderWriterFactory]::CreateJsonReader(
            $Bytes,
            [System.Xml.XmlDictionaryReaderQuotas]::Max
        )
        $document = New-Object System.Xml.XmlDocument
        $document.Load($reader)
        $root = $document.DocumentElement
        if ($null -eq $root -or $root.GetAttribute('type') -cne 'object') {
            throw (New-SafeException -Code 'AUTH_SCHEMA_UNEXPECTED')
        }

        $names = @($root.ChildNodes | Where-Object {
            $_.NodeType -eq [System.Xml.XmlNodeType]::Element
        } | ForEach-Object { $_.LocalName })
        return $names
    }
    catch [System.InvalidOperationException] {
        throw
    }
    catch {
        throw (New-SafeException -Code 'AUTH_JSON_INVALID')
    }
    finally {
        if ($null -ne $reader) {
            $reader.Close()
        }
        $document = $null
    }
}

function Test-CodexAuthBytes {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [switch]$TopLevelOnly
    )

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        throw (New-SafeException -Code 'AUTH_FILE_EMPTY')
    }

    $actualKeys = @(Get-AuthTopLevelPropertyNames -Bytes $Bytes)
    $schemaMatches = $true

    foreach ($requiredKey in $script:RequiredAuthKeys) {
        if (@($actualKeys | Where-Object { $_ -ceq $requiredKey }).Count -ne 1) {
            $schemaMatches = $false
            break
        }
    }

    if ($schemaMatches) {
        for ($i = 0; $i -lt $actualKeys.Count; $i++) {
            for ($j = $i + 1; $j -lt $actualKeys.Count; $j++) {
                if ($actualKeys[$i] -ceq $actualKeys[$j]) {
                    $schemaMatches = $false
                    break
                }
            }
        }
    }

    if (-not $schemaMatches) {
        throw (New-SafeException -Code 'AUTH_SCHEMA_UNEXPECTED')
    }

    if (-not $TopLevelOnly) {
        $identityBytes = $null
        try {
            $identityBytes = Get-CodexAuthIdentityBytes -Bytes $Bytes `
                -SkipTopLevelValidation
        }
        finally {
            if ($null -ne $identityBytes -and $identityBytes.Length -gt 0) {
                [Array]::Clear($identityBytes, 0, $identityBytes.Length)
            }
        }
    }

    return [pscustomobject]@{
        IsValidJson = $true
        RootIsObject = $true
        SchemaExpected = $true
    }
}

function Get-CodexAuthIdentityBytes {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [switch]$SkipTopLevelValidation
    )

    # Identity schema v1 deliberately uses the explicit TokenData account_id
    # field. It does not decode or depend on any JWT claim. Codex refreshes the
    # token strings independently while account_id identifies the selected
    # ChatGPT account/workspace. Any missing, duplicate, non-string, empty, or
    # unexpectedly shaped field fails closed.
    if (-not $SkipTopLevelValidation) {
        $null = Test-CodexAuthBytes -Bytes $Bytes -TopLevelOnly
    }
    $identityText = $null
    $identityBytes = $null
    $jsonDocumentType = [Type]::GetType(
        'System.Text.Json.JsonDocument, System.Text.Json',
        $false
    )

    try {
        if ($null -ne $jsonDocumentType) {
            $memoryStream = $null
            $document = $null
            try {
                $memoryStream = New-Object System.IO.MemoryStream(, $Bytes)
                $document = [System.Text.Json.JsonDocument]::Parse($memoryStream)
                $authModeCount = 0
                $tokensCount = 0
                $accountIdCount = 0
                $authModeValid = $false

                foreach ($property in $document.RootElement.EnumerateObject()) {
                    if ($property.Name -ceq 'auth_mode') {
                        $authModeCount++
                        if ($property.Value.ValueKind.ToString() -eq 'String') {
                            $authModeText = $property.Value.GetString()
                            try {
                                $authModeValid = $authModeText -ceq 'chatgpt'
                            }
                            finally {
                                $authModeText = $null
                            }
                        }
                    }
                    elseif ($property.Name -ceq 'tokens') {
                        $tokensCount++
                        if ($property.Value.ValueKind.ToString() -ne 'Object') {
                            throw (New-SafeException -Code 'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED')
                        }
                        foreach ($tokenProperty in $property.Value.EnumerateObject()) {
                            if ($tokenProperty.Name -ceq 'account_id') {
                                $accountIdCount++
                                if ($tokenProperty.Value.ValueKind.ToString() -ne 'String') {
                                    throw (New-SafeException -Code 'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED')
                                }
                                $identityText = $tokenProperty.Value.GetString()
                            }
                        }
                    }
                }

                if ($authModeCount -ne 1 -or -not $authModeValid -or
                    $tokensCount -ne 1 -or $accountIdCount -ne 1) {
                    throw (New-SafeException -Code 'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED')
                }
            }
            finally {
                if ($null -ne $document) {
                    $document.Dispose()
                }
                if ($null -ne $memoryStream) {
                    $memoryStream.Dispose()
                }
            }
        }
        else {
            # The framework JSON reader preserves duplicate keys on Windows
            # PowerShell 5.1. Values are never emitted, logged, persisted, or
            # included in exceptions; references are discarded in finally.
            $reader = $null
            $document = $null
            try {
                $null = Add-Type -AssemblyName System.Runtime.Serialization `
                    -ErrorAction SilentlyContinue
                $reader = [System.Runtime.Serialization.Json.JsonReaderWriterFactory]::CreateJsonReader(
                    $Bytes,
                    [System.Xml.XmlDictionaryReaderQuotas]::Max
                )
                $document = New-Object System.Xml.XmlDocument
                $document.Load($reader)
                $root = $document.DocumentElement
                if ($null -eq $root -or $root.GetAttribute('type') -cne 'object') {
                    throw (New-SafeException -Code 'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED')
                }

                $authModeProperties = @($root.ChildNodes | Where-Object {
                    $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and
                    $_.LocalName -ceq 'auth_mode'
                })
                $tokensProperties = @($root.ChildNodes | Where-Object {
                    $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and
                    $_.LocalName -ceq 'tokens'
                })
                if ($authModeProperties.Count -ne 1 -or
                    $authModeProperties[0].GetAttribute('type') -cne 'string' -or
                    $authModeProperties[0].InnerText -cne 'chatgpt' -or
                    $tokensProperties.Count -ne 1 -or
                    $tokensProperties[0].GetAttribute('type') -cne 'object') {
                    throw (New-SafeException -Code 'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED')
                }

                $accountIdProperties = @($tokensProperties[0].ChildNodes | Where-Object {
                    $_.NodeType -eq [System.Xml.XmlNodeType]::Element -and
                    $_.LocalName -ceq 'account_id'
                })
                if ($accountIdProperties.Count -ne 1 -or
                    $accountIdProperties[0].GetAttribute('type') -cne 'string') {
                    throw (New-SafeException -Code 'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED')
                }
                $identityText = $accountIdProperties[0].InnerText
            }
            finally {
                if ($null -ne $reader) {
                    $reader.Close()
                }
                $document = $null
            }
        }

        if ([string]::IsNullOrWhiteSpace($identityText) -or
            $identityText.Length -gt $script:MaximumIdentityBytes) {
            throw (New-SafeException -Code 'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED')
        }

        $identityBytes = (New-Object System.Text.UTF8Encoding($false, $true)).GetBytes(
            $identityText
        )
        if ($identityBytes.Length -le 0 -or
            $identityBytes.Length -gt $script:MaximumIdentityBytes) {
            throw (New-SafeException -Code 'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED')
        }
        return ,$identityBytes
    }
    catch [System.InvalidOperationException] {
        if ($null -ne $identityBytes -and $identityBytes.Length -gt 0) {
            [Array]::Clear($identityBytes, 0, $identityBytes.Length)
        }
        throw
    }
    catch {
        if ($null -ne $identityBytes -and $identityBytes.Length -gt 0) {
            [Array]::Clear($identityBytes, 0, $identityBytes.Length)
        }
        throw (New-SafeException -Code 'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED')
    }
    finally {
        $identityText = $null
    }
}

function ConvertFrom-CodexBase64Url {
    param([Parameter(Mandatory = $true)][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 131072) {
        throw (New-SafeException -Code 'AUTH_WORKSPACE_CONTEXT_UNAVAILABLE')
    }
    $base64 = $Value.Replace('-', '+').Replace('_', '/')
    switch ($base64.Length % 4) {
        0 { }
        2 { $base64 += '==' }
        3 { $base64 += '=' }
        default {
            throw (New-SafeException -Code 'AUTH_WORKSPACE_CONTEXT_UNAVAILABLE')
        }
    }
    try {
        return ,[Convert]::FromBase64String($base64)
    }
    catch {
        throw (New-SafeException -Code 'AUTH_WORKSPACE_CONTEXT_UNAVAILABLE')
    }
}

function Get-CodexWorkspaceClass {
    param([AllowNull()][string]$PlanType)

    if ([string]::IsNullOrWhiteSpace($PlanType)) { return 'Unknown' }
    switch -Regex ($PlanType.Trim().ToLowerInvariant()) {
        '^(team|business|enterprise|edu|education)$' { return 'Team' }
        '^(free|plus|pro|go|personal)$' { return 'Personal' }
        default { return 'Unknown' }
    }
}

function Get-CodexAuthIdentityContext {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    $accountIdBytes = $null
    $userIdBytes = $null
    $workspaceAccountIdBytes = $null
    $authText = $null
    $payloadBytes = $null
    $payloadText = $null
    $planType = $null
    try {
        $accountIdBytes = Get-CodexAuthIdentityBytes -Bytes $Bytes
        try {
            $utf8 = New-Object System.Text.UTF8Encoding($false, $true)
            $authText = $utf8.GetString($Bytes)
            $auth = ConvertFrom-Json -InputObject $authText -ErrorAction Stop
            $idToken = [string]$auth.tokens.id_token
            $parts = @($idToken -split '\.')
            if ($parts.Count -ge 2) {
                $payloadBytes = ConvertFrom-CodexBase64Url -Value $parts[1]
                if ($payloadBytes.Length -gt 65536) {
                    throw (New-SafeException -Code 'AUTH_WORKSPACE_CONTEXT_UNAVAILABLE')
                }
                $payloadText = $utf8.GetString($payloadBytes)
                $payload = ConvertFrom-Json -InputObject $payloadText -ErrorAction Stop
                $authClaimProperty = $payload.PSObject.Properties[
                    'https://api.openai.com/auth'
                ]
                $authClaim = if ($null -ne $authClaimProperty -and
                    $authClaimProperty.Value -is [pscustomobject]) {
                    $authClaimProperty.Value
                }
                else { $null }
                $planProperty = if ($null -eq $authClaim) {
                    $null
                }
                else {
                    $authClaim.PSObject.Properties['chatgpt_plan_type']
                }
                if ($null -ne $planProperty -and $planProperty.Value -is [string]) {
                    $planType = [string]$planProperty.Value
                }
                $userProperty = if ($null -eq $authClaim) {
                    $null
                }
                else {
                    $authClaim.PSObject.Properties['chatgpt_user_id']
                }
                if ($null -eq $userProperty) {
                    if ($null -ne $authClaim) {
                        $userProperty = $authClaim.PSObject.Properties['user_id']
                    }
                }
                if ($null -ne $userProperty -and
                    $userProperty.Value -is [string] -and
                    -not [string]::IsNullOrWhiteSpace([string]$userProperty.Value)) {
                    $userIdBytes = $utf8.GetBytes([string]$userProperty.Value)
                }
                $workspaceProperty = if ($null -eq $authClaim) {
                    $null
                }
                else {
                    $authClaim.PSObject.Properties['chatgpt_account_id']
                }
                if ($null -ne $workspaceProperty -and
                    $workspaceProperty.Value -is [string] -and
                    -not [string]::IsNullOrWhiteSpace(
                        [string]$workspaceProperty.Value
                    )) {
                    $workspaceAccountIdBytes = $utf8.GetBytes(
                        [string]$workspaceProperty.Value
                    )
                }
                $authClaim = $null
                $payload = $null
            }
            $auth = $null
        }
        catch {
            # Older profiles may contain an opaque or legacy id_token. The
            # account/workspace id remains authoritative, while verification
            # reports that supplemental workspace context is unavailable.
            $planType = $null
            if ($null -ne $userIdBytes -and $userIdBytes.Length -gt 0) {
                [Array]::Clear($userIdBytes, 0, $userIdBytes.Length)
            }
            $userIdBytes = $null
            if ($null -ne $workspaceAccountIdBytes -and
                $workspaceAccountIdBytes.Length -gt 0) {
                [Array]::Clear(
                    $workspaceAccountIdBytes,
                    0,
                    $workspaceAccountIdBytes.Length
                )
            }
            $workspaceAccountIdBytes = $null
        }

        $workspaceClass = Get-CodexWorkspaceClass -PlanType $planType
        $workspaceClaimStatus = if ($null -eq $workspaceAccountIdBytes) {
            'Unavailable'
        }
        elseif (Test-IdentityByteArraysEqual -Left $accountIdBytes `
            -Right $workspaceAccountIdBytes) {
            'Confirmed'
        }
        else { 'Mismatch' }
        return [pscustomobject]@{
            AccountIdBytes = $accountIdBytes
            UserIdBytes = $userIdBytes
            WorkspaceAccountIdBytes = $workspaceAccountIdBytes
            WorkspaceClass = $workspaceClass
            WorkspaceClaimStatus = $workspaceClaimStatus
            SupplementalContextKnown = (
                $workspaceClaimStatus -ceq 'Confirmed' -and
                $workspaceClass -cne 'Unknown' -and
                $null -ne $userIdBytes -and $userIdBytes.Length -gt 0
            )
        }
    }
    catch {
        foreach ($buffer in @(
            $accountIdBytes,
            $userIdBytes,
            $workspaceAccountIdBytes
        )) {
            if ($null -ne $buffer -and $buffer.Length -gt 0) {
                [Array]::Clear($buffer, 0, $buffer.Length)
            }
        }
        throw
    }
    finally {
        if ($null -ne $payloadBytes -and $payloadBytes.Length -gt 0) {
            [Array]::Clear($payloadBytes, 0, $payloadBytes.Length)
        }
        $authText = $null
        $payloadText = $null
        $planType = $null
    }
}

function Clear-CodexAuthIdentityContext {
    param([AllowNull()][object]$Context)

    if ($null -eq $Context) { return }
    foreach ($propertyName in @(
        'AccountIdBytes',
        'UserIdBytes',
        'WorkspaceAccountIdBytes'
    )) {
        $property = $Context.PSObject.Properties[$propertyName]
        if ($null -ne $property -and $property.Value -is [byte[]] -and
            $property.Value.Length -gt 0) {
            [Array]::Clear($property.Value, 0, $property.Value.Length)
        }
    }
}

function Protect-CodexIdentityMarkerPayload {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Data
    )

    $entropy = $null
    try {
        $null = Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
        $entropy = [System.Text.Encoding]::UTF8.GetBytes($script:IdentityEntropyText)
        $protected = [System.Security.Cryptography.ProtectedData]::Protect(
            $Data,
            $entropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return ,$protected
    }
    catch {
        throw (New-SafeException -Code 'IDENTITY_MARKER_PROTECT_FAILED')
    }
    finally {
        if ($null -ne $entropy -and $entropy.Length -gt 0) {
            [Array]::Clear($entropy, 0, $entropy.Length)
        }
    }
}

function Unprotect-CodexIdentityMarkerPayload {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Data
    )

    $entropy = $null
    try {
        $null = Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
        $entropy = [System.Text.Encoding]::UTF8.GetBytes($script:IdentityEntropyText)
        $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
            $Data,
            $entropy,
            [System.Security.Cryptography.DataProtectionScope]::CurrentUser
        )
        return ,$plain
    }
    catch {
        throw (New-SafeException -Code 'PROFILE_IDENTITY_MARKER_INVALID')
    }
    finally {
        if ($null -ne $entropy -and $entropy.Length -gt 0) {
            [Array]::Clear($entropy, 0, $entropy.Length)
        }
    }
}

function New-CodexIdentityMarkerPayload {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$IdentityBytes
    )

    if ($null -eq $IdentityBytes -or $IdentityBytes.Length -le 0 -or
        $IdentityBytes.Length -gt $script:MaximumIdentityBytes) {
        throw (New-SafeException -Code 'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED')
    }

    $headerLength = $script:IdentityMarkerHeader.Length
    $payload = New-Object byte[] ($headerLength + 4 + $IdentityBytes.Length)
    [Array]::Copy($script:IdentityMarkerHeader, 0, $payload, 0, $headerLength)
    $lengthOffset = $headerLength
    $identityLength = $IdentityBytes.Length
    $payload[$lengthOffset] = [byte]($identityLength -band 0xff)
    $payload[$lengthOffset + 1] = [byte](($identityLength -shr 8) -band 0xff)
    $payload[$lengthOffset + 2] = [byte](($identityLength -shr 16) -band 0xff)
    $payload[$lengthOffset + 3] = [byte](($identityLength -shr 24) -band 0xff)
    [Array]::Copy($IdentityBytes, 0, $payload, $headerLength + 4, $IdentityBytes.Length)
    return ,$payload
}

function Get-CodexIdentityFromMarkerPayload {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Payload
    )

    $headerLength = $script:IdentityMarkerHeader.Length
    if ($null -eq $Payload -or $Payload.Length -lt ($headerLength + 5)) {
        throw (New-SafeException -Code 'PROFILE_IDENTITY_SCHEMA_UNRECOGNIZED')
    }
    for ($index = 0; $index -lt $headerLength; $index++) {
        if ($Payload[$index] -ne $script:IdentityMarkerHeader[$index]) {
            throw (New-SafeException -Code 'PROFILE_IDENTITY_SCHEMA_UNRECOGNIZED')
        }
    }

    $lengthOffset = $headerLength
    $identityLength = [int]$Payload[$lengthOffset] -bor
        ([int]$Payload[$lengthOffset + 1] -shl 8) -bor
        ([int]$Payload[$lengthOffset + 2] -shl 16) -bor
        ([int]$Payload[$lengthOffset + 3] -shl 24)
    if ($identityLength -le 0 -or
        $identityLength -gt $script:MaximumIdentityBytes -or
        $Payload.Length -ne ($headerLength + 4 + $identityLength)) {
        throw (New-SafeException -Code 'PROFILE_IDENTITY_SCHEMA_UNRECOGNIZED')
    }

    $identityBytes = New-Object byte[] $identityLength
    [Array]::Copy($Payload, $headerLength + 4, $identityBytes, 0, $identityLength)
    return ,$identityBytes
}

function Test-IdentityByteArraysEqual {
    param(
        [byte[]]$Left,
        [byte[]]$Right
    )

    if ($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length) {
        return $false
    }
    $difference = 0
    for ($index = 0; $index -lt $Left.Length; $index++) {
        $difference = $difference -bor ($Left[$index] -bxor $Right[$index])
    }
    return $difference -eq 0
}

function Test-CodexAuthFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $bytes = $null
    try {
        $bytes = Read-SensitiveFileBytes -Path $fullPath
        $validation = Test-CodexAuthBytes -Bytes $bytes
        return [pscustomobject]@{
            Exists = $true
            SizeBytes = $bytes.Length
            IsValidJson = $validation.IsValidJson
            RootIsObject = $validation.RootIsObject
            SchemaExpected = $validation.SchemaExpected
        }
    }
    finally {
        if ($null -ne $bytes -and $bytes.Length -gt 0) {
            [Array]::Clear($bytes, 0, $bytes.Length)
        }
    }
}

function Get-DpapiEntropyBytes {
    return ,[System.Text.Encoding]::UTF8.GetBytes($script:EntropyText)
}

function Protect-CodexAuthBytes {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Data
    )

    if ($null -eq $Data -or $Data.Length -eq 0) {
        throw (New-SafeException -Code 'AUTH_BYTES_EMPTY')
    }

    try {
        Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
        $entropy = Get-DpapiEntropyBytes
        try {
            $protected = [System.Security.Cryptography.ProtectedData]::Protect(
                $Data,
                $entropy,
                [System.Security.Cryptography.DataProtectionScope]::CurrentUser
            )
            return ,$protected
        }
        finally {
            if ($null -ne $entropy -and $entropy.Length -gt 0) {
                [Array]::Clear($entropy, 0, $entropy.Length)
            }
        }
    }
    catch {
        throw (New-SafeException -Code 'DPAPI_PROTECT_FAILED')
    }
}

function Unprotect-CodexAuthBytes {
    [CmdletBinding()]
    [OutputType([byte[]])]
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Data
    )

    if ($null -eq $Data -or $Data.Length -eq 0) {
        throw (New-SafeException -Code 'ENCRYPTED_BYTES_EMPTY')
    }

    try {
        Add-Type -AssemblyName System.Security -ErrorAction SilentlyContinue
        $entropy = Get-DpapiEntropyBytes
        try {
            $plain = [System.Security.Cryptography.ProtectedData]::Unprotect(
                $Data,
                $entropy,
                [System.Security.Cryptography.DataProtectionScope]::CurrentUser
            )
            return ,$plain
        }
        finally {
            if ($null -ne $entropy -and $entropy.Length -gt 0) {
                [Array]::Clear($entropy, 0, $entropy.Length)
            }
        }
    }
    catch {
        throw (New-SafeException -Code 'DPAPI_UNPROTECT_FAILED')
    }
}

function Test-CodexOwnedExecutablePath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $normalizedPath = $Path.Replace('/', '\')
    $codexPathPatterns = @(
        '(?i)[\\]OpenAI[\\]Codex(?:[\\]|$)',
        '(?i)[\\]WindowsApps[\\]OpenAI\.Codex_[^\\]+[\\]',
        '(?i)[\\]\.codex[\\]',
        '(?i)[\\]\.cache[\\]codex-runtimes[\\]'
    )

    foreach ($pattern in $codexPathPatterns) {
        if ($normalizedPath -match $pattern) {
            return $true
        }
    }
    return $false
}

function Get-NormalizedProcessName {
    param(
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return ''
    }
    if ($Name.EndsWith('.exe', [StringComparison]::OrdinalIgnoreCase)) {
        return $Name.Substring(0, $Name.Length - 4)
    }
    return $Name
}

function Test-CodexPluginExtensionHostPath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    return $Path.Replace('/', '\') -match '(?i)[\\]\.codex[\\]plugins[\\]'
}

function Test-NativeCodexChatGptPath {
    param(
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    return ($Path.Replace('/', '\') -match '(?i)[\\]WindowsApps[\\]OpenAI\.Codex_[^\\]+[\\].*[\\]ChatGPT\.exe$')
}

function Get-ProcessInspectionSnapshot {
    try {
        $cimProcesses = @(Get-CimInstance -ClassName Win32_Process -Property @(
            'Name',
            'ProcessId',
            'ParentProcessId',
            'ExecutablePath',
            'CreationDate'
        ) -ErrorAction Stop)

        foreach ($process in $cimProcesses) {
            $processPath = [string]$process.ExecutablePath
            $startTimeUtc = $null
            $startTimeStatus = 'Unavailable'
            try {
                if ($null -ne $process.CreationDate) {
                    $startTimeUtc = ([DateTime]$process.CreationDate).ToUniversalTime()
                    $startTimeStatus = 'Readable'
                }
            }
            catch { }
            [pscustomobject]@{
                ProcessName = [string]$process.Name
                Id = [int]$process.ProcessId
                ParentProcessId = [int]$process.ParentProcessId
                ParentReadStatus = 'Readable'
                ExecutablePath = $processPath
                ProcessStartTimeUtc = $startTimeUtc
                StartTimeReadStatus = $startTimeStatus
                PathReadStatus = if ([string]::IsNullOrWhiteSpace($processPath)) {
                    'Unavailable'
                }
                else {
                    'Readable'
                }
            }
        }
        return
    }
    catch {
        # Sandboxed callers may be denied CIM access. Fall back to Get-Process
        # without inventing parent IDs; plugin-host ancestry will become UNKNOWN.
    }

    $processes = @(Get-Process -ErrorAction Stop)
    foreach ($process in $processes) {
        $processPath = $null
        $pathReadStatus = 'Unavailable'
        $startTimeUtc = $null
        $startTimeStatus = 'Unavailable'
        try {
            $processPath = $process.Path
            if (-not [string]::IsNullOrWhiteSpace($processPath)) {
                $pathReadStatus = 'Readable'
            }
        }
        catch {
            # Do not expose the exception or attempt to read the command line.
        }
        try {
            $startTimeUtc = $process.StartTime.ToUniversalTime()
            $startTimeStatus = 'Readable'
        }
        catch { }

        [pscustomobject]@{
            ProcessName = $process.ProcessName
            Id = $process.Id
            ParentProcessId = $null
            ParentReadStatus = 'Unavailable'
            ExecutablePath = $processPath
            PathReadStatus = $pathReadStatus
            ProcessStartTimeUtc = $startTimeUtc
            StartTimeReadStatus = $startTimeStatus
        }
    }
}

function Test-QiehaoOwnedQuotaProcess {
    param(
        [Parameter(Mandatory = $true)][object]$Process,
        [AllowEmptyCollection()][object[]]$OwnedProcessDescriptors
    )

    $nameProperty = $Process.PSObject.Properties['ProcessName']
    $idProperty = $Process.PSObject.Properties['Id']
    $pathProperty = $Process.PSObject.Properties['ExecutablePath']
    $startProperty = $Process.PSObject.Properties['ProcessStartTimeUtc']
    $startStatusProperty = $Process.PSObject.Properties['StartTimeReadStatus']
    $parentProperty = $Process.PSObject.Properties['ParentProcessId']
    $parentStatusProperty = $Process.PSObject.Properties['ParentReadStatus']
    if ($null -eq $nameProperty -or $null -eq $idProperty -or
        $null -eq $pathProperty -or $null -eq $startProperty -or
        $null -eq $startStatusProperty -or
        [string]$startStatusProperty.Value -cne 'Readable') {
        return $false
    }
    $normalizedName = Get-NormalizedProcessName -Name ([string]$nameProperty.Value)
    if ($normalizedName -notmatch '^(?i:codex(?:[-_].*)?)$') {
        return $false
    }

    foreach ($descriptor in @($OwnedProcessDescriptors)) {
        if ($null -eq $descriptor) { continue }
        $active = $descriptor.PSObject.Properties['IsActive']
        $pidProperty = $descriptor.PSObject.Properties['ProcessId']
        $ownedStart = $descriptor.PSObject.Properties['ProcessStartTimeUtc']
        $ownedPath = $descriptor.PSObject.Properties['ExecutablePath']
        $arguments = $descriptor.PSObject.Properties['Arguments']
        $ownedParent = $descriptor.PSObject.Properties['ParentProcessId']
        if ($null -eq $active -or -not [bool]$active.Value -or
            $null -eq $pidProperty -or
            [int]$pidProperty.Value -ne [int]$idProperty.Value -or
            $null -eq $ownedStart -or $null -eq $ownedPath -or
            $null -eq $arguments -or
            [string]$arguments.Value -cne 'app-server --stdio') {
            continue
        }
        if (-not ([string]$ownedPath.Value).Equals(
                [string]$pathProperty.Value,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            continue
        }
        try {
            $actualStart = ([DateTime]$startProperty.Value).ToUniversalTime()
            $expectedStart = ([DateTime]$ownedStart.Value).ToUniversalTime()
            if ([Math]::Abs(($actualStart - $expectedStart).TotalSeconds) -gt 2) {
                continue
            }
        }
        catch { continue }
        if ($null -ne $ownedParent) {
            if ($null -eq $parentProperty -or
                $null -eq $parentStatusProperty -or
                [string]$parentStatusProperty.Value -cne 'Readable' -or
                [int]$ownedParent.Value -ne [int]$parentProperty.Value) {
                continue
            }
        }
        return $true
    }
    return $false
}

function Get-ExtensionHostClassification {
    param(
        [Parameter(Mandatory = $true)]
        [object]$ExtensionHost,

        [Parameter(Mandatory = $true)]
        [hashtable]$ProcessById
    )

    $parentProperty = $ExtensionHost.PSObject.Properties['ParentProcessId']
    $parentStatusProperty = $ExtensionHost.PSObject.Properties['ParentReadStatus']
    if ($null -eq $parentProperty -or
        $null -eq $parentStatusProperty -or
        [string]$parentStatusProperty.Value -cne 'Readable') {
        return 'PROCESS_STATE_UNKNOWN'
    }

    $ancestorId = [int]$parentProperty.Value
    $visited = @{}
    for ($depth = 1; $depth -le 6; $depth++) {
        if ($ancestorId -le 0 -or $visited.ContainsKey([string]$ancestorId)) {
            return 'PROCESS_STATE_UNKNOWN'
        }
        $visited[[string]$ancestorId] = $true

        if (-not $ProcessById.ContainsKey([string]$ancestorId)) {
            return 'PROCESS_STATE_UNKNOWN'
        }

        $ancestor = $ProcessById[[string]$ancestorId]
        $nameProperty = $ancestor.PSObject.Properties['ProcessName']
        if ($null -eq $nameProperty) {
            return 'PROCESS_STATE_UNKNOWN'
        }
        $ancestorName = Get-NormalizedProcessName -Name ([string]$nameProperty.Value)

        if ($ancestorName -ieq 'chrome' -or $ancestorName -ieq 'msedge') {
            return 'BROWSER_EXTENSION_HOST'
        }
        if ($ancestorName -ieq 'codex' -or
            $ancestorName -ieq 'codex-code-mode-host') {
            return 'CODEX_EXTENSION_HOST'
        }
        if ($ancestorName -ieq 'ChatGPT') {
            $pathProperty = $ancestor.PSObject.Properties['ExecutablePath']
            $pathStatusProperty = $ancestor.PSObject.Properties['PathReadStatus']
            if ($null -eq $pathProperty -or
                $null -eq $pathStatusProperty -or
                [string]$pathStatusProperty.Value -cne 'Readable') {
                return 'PROCESS_STATE_UNKNOWN'
            }
            if (Test-NativeCodexChatGptPath -Path ([string]$pathProperty.Value)) {
                return 'CODEX_EXTENSION_HOST'
            }
        }

        $nextParentProperty = $ancestor.PSObject.Properties['ParentProcessId']
        $nextParentStatusProperty = $ancestor.PSObject.Properties['ParentReadStatus']
        if ($null -eq $nextParentProperty -or
            $null -eq $nextParentStatusProperty -or
            [string]$nextParentStatusProperty.Value -cne 'Readable') {
            return 'PROCESS_STATE_UNKNOWN'
        }
        $ancestorId = [int]$nextParentProperty.Value
    }

    return 'PROCESS_STATE_UNKNOWN'
}

function Test-CodexProcessesStopped {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$ProcessData,

        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$OwnedProcessDescriptors = @()
    )

    if ($PSBoundParameters.ContainsKey('ProcessData')) {
        $snapshot = @($ProcessData)
    }
    else {
        try {
            $snapshot = @(Get-ProcessInspectionSnapshot)
        }
        catch {
            return [pscustomobject]@{
                SafeToSave = $false
                BlockingProcesses = @()
                UncertainProcesses = @()
                ReasonCode = 'CODEX_PROCESS_STATE_UNKNOWN'
            }
        }
    }

    $blocking = @()
    $uncertain = @()
    $browserExtensionHosts = @()
    $ownedQuotaProcesses = @()
    $processById = @{}
    foreach ($snapshotItem in $snapshot) {
        if ($null -eq $snapshotItem) {
            continue
        }
        $snapshotIdProperty = $snapshotItem.PSObject.Properties['Id']
        if ($null -ne $snapshotIdProperty) {
            $processById[[string][int]$snapshotIdProperty.Value] = $snapshotItem
        }
    }

    foreach ($item in $snapshot) {
        if ($null -eq $item) {
            continue
        }

        $nameProperty = $item.PSObject.Properties['ProcessName']
        $idProperty = $item.PSObject.Properties['Id']
        $pathProperty = $item.PSObject.Properties['ExecutablePath']
        $statusProperty = $item.PSObject.Properties['PathReadStatus']
        if ($null -eq $nameProperty -or [string]::IsNullOrWhiteSpace([string]$nameProperty.Value)) {
            continue
        }

        $processName = [string]$nameProperty.Value
        $normalizedProcessName = Get-NormalizedProcessName -Name $processName
        $processId = if ($null -eq $idProperty) { 0 } else { [int]$idProperty.Value }
        $processPath = if ($null -eq $pathProperty) { $null } else { [string]$pathProperty.Value }
        $pathReadStatus = if ($null -eq $statusProperty) {
            if ([string]::IsNullOrWhiteSpace($processPath)) { 'Unavailable' } else { 'Readable' }
        }
        else {
            [string]$statusProperty.Value
        }

        $safeDescriptor = [pscustomobject]@{
            ProcessName = $processName
            PID = $processId
            Classification = 'CODEX_PROCESS'
        }

        if (Test-QiehaoOwnedQuotaProcess -Process $item -OwnedProcessDescriptors $OwnedProcessDescriptors) {
            $ownedQuotaProcesses += [pscustomobject]@{
                ProcessName = $processName
                PID = $processId
                Classification = 'QIEHAO_QUOTA_APP_SERVER'
            }
            continue
        }

        # These names are specific enough to block even when their path cannot
        # be read. Generic helper names are never blocked by name alone.
        if ($normalizedProcessName -match '^(?i:codex(?:[-_].*)?)$') {
            $blocking += $safeDescriptor
            continue
        }

        if ($normalizedProcessName -ieq 'extension-host' -and
            $pathReadStatus -ceq 'Readable' -and
            (Test-CodexPluginExtensionHostPath -Path $processPath)) {
            $extensionClassification = Get-ExtensionHostClassification -ExtensionHost $item -ProcessById $processById

            if ($extensionClassification -ceq 'BROWSER_EXTENSION_HOST') {
                $browserExtensionHosts += [pscustomobject]@{
                    ProcessName = $processName
                    PID = $processId
                    Classification = 'BROWSER_EXTENSION_HOST'
                }
            }
            elseif ($extensionClassification -ceq 'CODEX_EXTENSION_HOST') {
                $blocking += [pscustomobject]@{
                    ProcessName = $processName
                    PID = $processId
                    Classification = 'CODEX_EXTENSION_HOST'
                }
            }
            else {
                $uncertain += [pscustomobject]@{
                    ProcessName = $processName
                    PID = $processId
                    Classification = 'PROCESS_STATE_UNKNOWN'
                }
            }
            continue
        }

        if ($pathReadStatus -ceq 'Readable' -and
            (Test-CodexOwnedExecutablePath -Path $processPath)) {
            $safeDescriptor.Classification = 'CODEX_OWNED_PATH'
            $blocking += $safeDescriptor
            continue
        }

        # ChatGPT.exe is an ambiguous host name. A readable non-Codex path is
        # ignored; an unreadable path is explicitly UNKNOWN rather than being
        # guessed as either safe or running. Unreadable generic node/pwsh paths
        # do not create UNKNOWN because those names are not Codex-specific.
        if ($normalizedProcessName -ieq 'ChatGPT' -and $pathReadStatus -cne 'Readable') {
            $safeDescriptor.Classification = 'PROCESS_STATE_UNKNOWN'
            $uncertain += $safeDescriptor
        }
    }

    if ($blocking.Count -gt 0) {
        return [pscustomobject]@{
            SafeToSave = $false
            BlockingProcesses = @($blocking)
            UncertainProcesses = @($uncertain)
            BrowserExtensionHosts = @($browserExtensionHosts)
            OwnedQuotaProcesses = @($ownedQuotaProcesses)
            ReasonCode = 'CODEX_PROCESS_RUNNING'
        }
    }
    if ($uncertain.Count -gt 0) {
        return [pscustomobject]@{
            SafeToSave = $false
            BlockingProcesses = @()
            UncertainProcesses = @($uncertain)
            BrowserExtensionHosts = @($browserExtensionHosts)
            OwnedQuotaProcesses = @($ownedQuotaProcesses)
            ReasonCode = 'CODEX_PROCESS_STATE_UNKNOWN'
        }
    }

    return [pscustomobject]@{
        SafeToSave = $true
        BlockingProcesses = @()
        UncertainProcesses = @()
        BrowserExtensionHosts = @($browserExtensionHosts)
        OwnedQuotaProcesses = @($ownedQuotaProcesses)
        ReasonCode = 'CODEX_PROCESSES_STOPPED'
    }
}

function Request-CodexDesktopClose {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$ProcessData,

        [Parameter()]
        [scriptblock]$CloseMainWindowAction,

        [Parameter()]
        [int]$CallerProcessId = $PID,

        [Parameter()]
        [scriptblock]$WindowOwnerProcessIdProvider
    )

    $useProvidedProcessData = $PSBoundParameters.ContainsKey('ProcessData')
    if ($useProvidedProcessData) {
        $snapshot = @($ProcessData)
    }
    else {
        try {
            $snapshot = @(Get-ProcessInspectionSnapshot)
        }
        catch {
            return [pscustomobject]@{
                Result = 'CODEX_PROCESS_STATE_UNKNOWN'
                CloseRequested = $false
                RequestedCount = 0
                AttemptedCount = 0
                FailedCount = 0
            }
        }
    }

    $processState = Test-CodexProcessesStopped -ProcessData $snapshot
    if ($processState.ReasonCode -ceq 'CODEX_PROCESSES_STOPPED') {
        return [pscustomobject]@{
            Result = 'CODEX_ALREADY_STOPPED'
            CloseRequested = $false
            RequestedCount = 0
            AttemptedCount = 0
            FailedCount = 0
        }
    }
    if ($processState.ReasonCode -cne 'CODEX_PROCESS_RUNNING') {
        return [pscustomobject]@{
            Result = 'CODEX_PROCESS_STATE_UNKNOWN'
            CloseRequested = $false
            RequestedCount = 0
            AttemptedCount = 0
            FailedCount = 0
        }
    }

    $blockingIds = @{}
    foreach ($blockingProcess in @($processState.BlockingProcesses)) {
        $pidProperty = $blockingProcess.PSObject.Properties['PID']
        if ($null -ne $pidProperty) {
            $blockingIds[[string][int]$pidProperty.Value] = $true
        }
    }

    $requestedCount = 0
    $attemptedCount = 0
    $failedCount = 0
    foreach ($item in $snapshot) {
        if ($null -eq $item) {
            continue
        }
        $nameProperty = $item.PSObject.Properties['ProcessName']
        $idProperty = $item.PSObject.Properties['Id']
        $pathProperty = $item.PSObject.Properties['ExecutablePath']
        $pathStatusProperty = $item.PSObject.Properties['PathReadStatus']
        if ($null -eq $nameProperty -or $null -eq $idProperty -or
            $null -eq $pathProperty -or $null -eq $pathStatusProperty) {
            continue
        }

        $processId = [int]$idProperty.Value
        if ($processId -le 0 -or $processId -eq $CallerProcessId -or
            -not $blockingIds.ContainsKey([string]$processId) -or
            (Get-NormalizedProcessName -Name ([string]$nameProperty.Value)) `
                -ine 'ChatGPT' -or
            [string]$pathStatusProperty.Value -cne 'Readable' -or
            -not (Test-NativeCodexChatGptPath `
                -Path ([string]$pathProperty.Value))) {
            continue
        }

        if ($useProvidedProcessData) {
            $handleProperty = $item.PSObject.Properties['MainWindowHandle']
            if ($null -eq $handleProperty -or
                [int64]$handleProperty.Value -eq 0 -or
                $null -eq $CloseMainWindowAction) {
                continue
            }
            $windowHandle = [int64]$handleProperty.Value
            $ownerProcessId = 0
            try {
                if ($null -ne $WindowOwnerProcessIdProvider) {
                    $ownerProcessId = [int](& $WindowOwnerProcessIdProvider `
                        $windowHandle $item)
                }
                else {
                    $ownerProperty = $item.PSObject.Properties[
                        'MainWindowOwnerProcessId'
                    ]
                    if ($null -ne $ownerProperty) {
                        $ownerProcessId = [int]$ownerProperty.Value
                    }
                }
            }
            catch {
                $ownerProcessId = 0
            }
            if ($ownerProcessId -ne $processId -or
                $ownerProcessId -eq $CallerProcessId) {
                continue
            }
            $attemptedCount++
            try {
                if ([bool](& $CloseMainWindowAction $item)) {
                    $requestedCount++
                }
                else {
                    $failedCount++
                }
            }
            catch {
                $failedCount++
                # A failed normal-close request is not escalated to termination.
            }
            continue
        }

        $liveProcess = $null
        try {
            $liveProcess = Get-Process -Id $processId -ErrorAction Stop
            $livePath = [string]$liveProcess.Path
            $liveName = Get-NormalizedProcessName -Name ([string]$liveProcess.ProcessName)
            $liveWindowHandle = [int64]$liveProcess.MainWindowHandle
            if ([int]$liveProcess.Id -eq $CallerProcessId -or
                $liveName -ine 'ChatGPT' -or
                -not (Test-NativeCodexChatGptPath -Path $livePath) -or
                $liveWindowHandle -eq 0) {
                continue
            }
            $ownerProcessId = 0
            try {
                if ($null -ne $WindowOwnerProcessIdProvider) {
                    $ownerProcessId = [int](& $WindowOwnerProcessIdProvider `
                        $liveWindowHandle $liveProcess)
                }
                else {
                    if ($null -eq ('QiehaoquNativeWindow' -as [type])) {
                        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class QiehaoquNativeWindow {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(
        IntPtr hWnd,
        out uint processId
    );
}
'@ -ErrorAction Stop
                    }
                    [uint32]$nativeOwnerProcessId = 0
                    $null = [QiehaoquNativeWindow]::GetWindowThreadProcessId(
                        [IntPtr]$liveWindowHandle,
                        [ref]$nativeOwnerProcessId
                    )
                    $ownerProcessId = [int]$nativeOwnerProcessId
                }
            }
            catch {
                $ownerProcessId = 0
            }
            if ($ownerProcessId -ne $processId -or
                $ownerProcessId -eq $CallerProcessId) {
                continue
            }
            $attemptedCount++
            if ([bool]$liveProcess.CloseMainWindow()) {
                $requestedCount++
            }
            else {
                $failedCount++
            }
        }
        catch {
            if ($attemptedCount -gt ($requestedCount + $failedCount)) {
                $failedCount++
            }
            # Do not expose process details and never fall back to force-kill.
        }
        finally {
            if ($null -ne $liveProcess) {
                $liveProcess.Dispose()
            }
        }
    }

    if ($requestedCount -gt 0) {
        return [pscustomobject]@{
            Result = 'CODEX_CLOSE_REQUESTED'
            CloseRequested = $true
            RequestedCount = $requestedCount
            AttemptedCount = $attemptedCount
            FailedCount = $failedCount
        }
    }
    if ($attemptedCount -gt 0) {
        return [pscustomobject]@{
            Result = 'CODEX_CLOSE_REQUEST_FAILED'
            CloseRequested = $false
            RequestedCount = 0
            AttemptedCount = $attemptedCount
            FailedCount = $failedCount
        }
    }
    return [pscustomobject]@{
        Result = 'CODEX_MAIN_WINDOW_NOT_FOUND'
        CloseRequested = $false
        RequestedCount = 0
        AttemptedCount = 0
        FailedCount = 0
    }
}

function New-CodexNativeQuitResult {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Result,
        [bool]$TargetFound = $false,
        [ValidateSet('AutomationId', 'Name', 'None')]
        [string]$Method = 'None',
        [ValidateSet('requested', 'failed', 'not-requested')]
        [string]$InvokeResult = 'not-requested',
        [int]$BlockingProcessCount = 0
    )

    return [pscustomobject]@{
        Result = $Result
        NativeQuitTargetFound = $TargetFound
        NativeQuitMethod = $Method
        NativeQuitInvokeResult = $InvokeResult
        BlockingProcessCount = [Math]::Max(0, $BlockingProcessCount)
    }
}

function Test-CodexNativeQuitAutomationName {
    param([AllowNull()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $normalized = ($Name -replace '&', '').Trim()
    $normalized = ($normalized -replace '(?:\.{3})$', '').Trim()
    $ellipsis = [string][char]0x2026
    if ($normalized.EndsWith($ellipsis, [StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(
            0,
            $normalized.Length - $ellipsis.Length
        ).Trim()
    }
    $exitChinese = ([string][char]0x9000) + ([string][char]0x51FA)
    $finishChinese = ([string][char]0x7ED3) + ([string][char]0x675F)
    $closeApplicationChinese = ([string][char]0x5173) +
        ([string][char]0x95ED) + ([string][char]0x5E94) +
        ([string][char]0x7528)
    return @(
        'Exit', 'Quit', 'Exit Codex', 'Quit Codex',
        'Exit ChatGPT', 'Quit ChatGPT', $exitChinese,
        ($exitChinese + ' Codex'), ($exitChinese + ' ChatGPT'),
        ($finishChinese + ' Codex'), ($finishChinese + ' ChatGPT'),
        $closeApplicationChinese
    ) -icontains $normalized
}

function Test-CodexNativeQuitAutomationId {
    param([AllowNull()][string]$AutomationId)

    if ([string]::IsNullOrWhiteSpace($AutomationId)) { return $false }
    return @(
        'quit', 'exit', 'app.quit', 'appQuit', 'menu.quit',
        'menuQuit', 'file.exit', 'fileExit', 'file.quit',
        'fileQuit', 'systemQuitMenuItem'
    ) -icontains $AutomationId.Trim()
}

function Select-CodexNativeQuitAutomationElement {
    param(
        [AllowEmptyCollection()]
        [object[]]$Elements,
        [Parameter(Mandatory = $true)]
        [int]$ExpectedProcessId
    )

    $eligible = @($Elements | Where-Object {
        $null -ne $_ -and
        [string]$_.ControlType -ceq 'MenuItem' -and
        [int]$_.ProcessId -eq $ExpectedProcessId -and
        [bool]$_.IsEnabled -and
        [bool]$_.SupportsInvoke -and
        [bool]$_.IsMenuDescendant
    })
    $byAutomationId = @($eligible | Where-Object {
        Test-CodexNativeQuitAutomationId -AutomationId ([string]$_.AutomationId)
    })
    if ($byAutomationId.Count -eq 1) {
        return [pscustomobject]@{
            Element = $byAutomationId[0]
            Method = 'AutomationId'
        }
    }
    if ($byAutomationId.Count -gt 1) { return $null }

    $byName = @($eligible | Where-Object {
        Test-CodexNativeQuitAutomationName -Name ([string]$_.Name)
    })
    if ($byName.Count -eq 1) {
        return [pscustomobject]@{
            Element = $byName[0]
            Method = 'Name'
        }
    }
    return $null
}

function Get-CodexNativeQuitAutomationSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [int64]$WindowHandle,
        [Parameter(Mandatory = $true)]
        [int]$ExpectedProcessId
    )

    try {
        Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
        Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{
            Available = $false
            Elements = @()
            CleanupAction = $null
        }
    }

    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle(
            [IntPtr]$WindowHandle
        )
        if ($null -eq $root -or
            [int]$root.Current.ProcessId -ne $ExpectedProcessId) {
            return [pscustomobject]@{
                Available = $true
                Elements = @()
                CleanupAction = $null
            }
        }

        $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
        $expandedPatterns = @()
        $all = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition
        )
        for ($index = 0; $index -lt $all.Count; $index++) {
            $element = $all.Item($index)
            try {
                if ($element.Current.ControlType -ne
                    [System.Windows.Automation.ControlType]::MenuItem) {
                    continue
                }
                $menuName = ([string]$element.Current.Name -replace '&', '').Trim()
                $fileChinese = ([string][char]0x6587) +
                    ([string][char]0x4EF6)
                if (@('File', $fileChinese) -inotcontains $menuName) { continue }
                $expandPattern = $null
                if ($element.TryGetCurrentPattern(
                    [System.Windows.Automation.ExpandCollapsePattern]::Pattern,
                    [ref]$expandPattern
                )) {
                    $expandPattern.Expand()
                    $expandedPatterns += $expandPattern
                }
            }
            catch {
                # Never use input simulation when the native menu cannot expand.
            }
        }

        if ($expandedPatterns.Count -gt 0) {
            $all = $root.FindAll(
                [System.Windows.Automation.TreeScope]::Descendants,
                [System.Windows.Automation.Condition]::TrueCondition
            )
        }

        $normalized = @()
        for ($index = 0; $index -lt $all.Count; $index++) {
            $element = $all.Item($index)
            try {
                if ($element.Current.ControlType -ne
                    [System.Windows.Automation.ControlType]::MenuItem) {
                    continue
                }
                $hasMenuAncestor = $false
                $ancestor = $walker.GetParent($element)
                for ($depth = 0; $depth -lt 12 -and $null -ne $ancestor; $depth++) {
                    $ancestorType = $ancestor.Current.ControlType
                    if ($ancestorType -eq [System.Windows.Automation.ControlType]::Menu -or
                        $ancestorType -eq [System.Windows.Automation.ControlType]::MenuBar) {
                        $hasMenuAncestor = $true
                        break
                    }
                    if ($ancestor -eq $root) { break }
                    $ancestor = $walker.GetParent($ancestor)
                }
                $invokePattern = $null
                $supportsInvoke = $element.TryGetCurrentPattern(
                    [System.Windows.Automation.InvokePattern]::Pattern,
                    [ref]$invokePattern
                )
                $normalized += [pscustomobject]@{
                    Name = [string]$element.Current.Name
                    AutomationId = [string]$element.Current.AutomationId
                    ControlType = 'MenuItem'
                    ProcessId = [int]$element.Current.ProcessId
                    IsEnabled = [bool]$element.Current.IsEnabled
                    SupportsInvoke = [bool]$supportsInvoke
                    IsMenuDescendant = $hasMenuAncestor
                    NativeElement = $element
                }
            }
            catch {
                # Stale or inaccessible elements are omitted without details.
            }
        }

        $cleanup = {
            foreach ($pattern in @($expandedPatterns)) {
                try { $pattern.Collapse() }
                catch { }
            }
        }.GetNewClosure()
        return [pscustomobject]@{
            Available = $true
            Elements = @($normalized)
            CleanupAction = $cleanup
        }
    }
    catch {
        return [pscustomobject]@{
            Available = $true
            Elements = @()
            CleanupAction = $null
        }
    }
}

function Invoke-CodexNativeQuitAutomation {
    param(
        [Parameter(Mandatory = $true)]
        [int64]$WindowHandle,
        [Parameter(Mandatory = $true)]
        [int]$ExpectedProcessId,
        [scriptblock]$AutomationSnapshotProvider,
        [scriptblock]$AutomationInvokeProvider
    )

    try {
        $snapshot = if ($null -ne $AutomationSnapshotProvider) {
            & $AutomationSnapshotProvider $WindowHandle $ExpectedProcessId
        }
        else {
            Get-CodexNativeQuitAutomationSnapshot -WindowHandle $WindowHandle -ExpectedProcessId $ExpectedProcessId
        }
    }
    catch {
        return New-CodexNativeQuitResult -Result 'CODEX_NATIVE_QUIT_NOT_AVAILABLE' -TargetFound $true
    }

    if ($null -eq $snapshot -or -not [bool]$snapshot.Available) {
        return New-CodexNativeQuitResult -Result 'CODEX_NATIVE_QUIT_NOT_AVAILABLE' -TargetFound $true
    }
    $cleanupProperty = $snapshot.PSObject.Properties['CleanupAction']
    $cleanup = if ($null -eq $cleanupProperty) {
        $null
    }
    else {
        $cleanupProperty.Value
    }
    $selection = Select-CodexNativeQuitAutomationElement -Elements @($snapshot.Elements) -ExpectedProcessId $ExpectedProcessId
    if ($null -eq $selection) {
        if ($null -ne $cleanup) {
            try { & $cleanup }
            catch { }
        }
        return New-CodexNativeQuitResult -Result 'CODEX_NATIVE_QUIT_UI_NOT_FOUND' -TargetFound $true
    }

    try {
        $invoked = if ($null -ne $AutomationInvokeProvider) {
            [bool](& $AutomationInvokeProvider $selection.Element)
        }
        else {
            $pattern = $null
            $nativeElement = $selection.Element.NativeElement
            if ($null -eq $nativeElement -or
                -not $nativeElement.TryGetCurrentPattern(
                    [System.Windows.Automation.InvokePattern]::Pattern,
                    [ref]$pattern
                )) {
                $false
            }
            else {
                $pattern.Invoke()
                $true
            }
        }
        if (-not $invoked) { throw 'CODEX_NATIVE_QUIT_INVOKE_FAILED' }
        return New-CodexNativeQuitResult -Result 'CODEX_NATIVE_QUIT_REQUESTED' -TargetFound $true -Method ([string]$selection.Method) -InvokeResult 'requested'
    }
    catch {
        if ($null -ne $cleanup) {
            try { & $cleanup }
            catch { }
        }
        return New-CodexNativeQuitResult -Result 'CODEX_NATIVE_QUIT_INVOKE_FAILED' -TargetFound $true -Method ([string]$selection.Method) -InvokeResult 'failed'
    }
}

function Request-CodexDesktopNativeQuit {
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowEmptyCollection()]
        [object[]]$ProcessData,
        [Parameter()]
        [int]$CallerProcessId = $PID,
        [Parameter()]
        [scriptblock]$WindowOwnerProcessIdProvider,
        [Parameter()]
        [scriptblock]$AutomationSnapshotProvider,
        [Parameter()]
        [scriptblock]$AutomationInvokeProvider
    )

    $useProvidedProcessData = $PSBoundParameters.ContainsKey('ProcessData')
    if ($useProvidedProcessData) {
        $snapshot = @($ProcessData)
    }
    else {
        try { $snapshot = @(Get-ProcessInspectionSnapshot) }
        catch {
            return New-CodexNativeQuitResult -Result 'CODEX_PROCESS_STATE_UNKNOWN'
        }
    }

    $processState = Test-CodexProcessesStopped -ProcessData $snapshot
    $blockingCount = @($processState.BlockingProcesses).Count
    if ($processState.ReasonCode -ceq 'CODEX_PROCESSES_STOPPED') {
        return New-CodexNativeQuitResult -Result 'CODEX_ALREADY_STOPPED'
    }
    if ($processState.ReasonCode -cne 'CODEX_PROCESS_RUNNING') {
        return New-CodexNativeQuitResult -Result 'CODEX_PROCESS_STATE_UNKNOWN' -BlockingProcessCount $blockingCount
    }

    $blockingIds = @{}
    foreach ($blockingProcess in @($processState.BlockingProcesses)) {
        $pidProperty = $blockingProcess.PSObject.Properties['PID']
        if ($null -ne $pidProperty) {
            $blockingIds[[string][int]$pidProperty.Value] = $true
        }
    }

    foreach ($item in $snapshot) {
        if ($null -eq $item) { continue }
        $nameProperty = $item.PSObject.Properties['ProcessName']
        $idProperty = $item.PSObject.Properties['Id']
        $pathProperty = $item.PSObject.Properties['ExecutablePath']
        $pathStatusProperty = $item.PSObject.Properties['PathReadStatus']
        if ($null -eq $nameProperty -or $null -eq $idProperty -or
            $null -eq $pathProperty -or $null -eq $pathStatusProperty) {
            continue
        }

        $processId = [int]$idProperty.Value
        if ($processId -le 0 -or $processId -eq $CallerProcessId -or
            -not $blockingIds.ContainsKey([string]$processId) -or
            (Get-NormalizedProcessName -Name ([string]$nameProperty.Value)) -ine 'ChatGPT' -or
            [string]$pathStatusProperty.Value -cne 'Readable' -or
            -not (Test-NativeCodexChatGptPath -Path ([string]$pathProperty.Value))) {
            continue
        }

        $windowHandle = [int64]0
        $ownerProcessId = 0
        $liveProcess = $null
        try {
            if ($useProvidedProcessData) {
                $handleProperty = $item.PSObject.Properties['MainWindowHandle']
                if ($null -eq $handleProperty) { continue }
                $windowHandle = [int64]$handleProperty.Value
                if ($null -ne $WindowOwnerProcessIdProvider) {
                    $ownerProcessId = [int](& $WindowOwnerProcessIdProvider $windowHandle $item)
                }
                else {
                    $ownerProperty = $item.PSObject.Properties['MainWindowOwnerProcessId']
                    if ($null -ne $ownerProperty) {
                        $ownerProcessId = [int]$ownerProperty.Value
                    }
                }
            }
            else {
                $liveProcess = Get-Process -Id $processId -ErrorAction Stop
                $livePath = [string]$liveProcess.Path
                $liveName = Get-NormalizedProcessName -Name ([string]$liveProcess.ProcessName)
                $windowHandle = [int64]$liveProcess.MainWindowHandle
                if ([int]$liveProcess.Id -eq $CallerProcessId -or
                    $liveName -ine 'ChatGPT' -or
                    -not (Test-NativeCodexChatGptPath -Path $livePath)) {
                    continue
                }
                if ($null -ne $WindowOwnerProcessIdProvider) {
                    $ownerProcessId = [int](& $WindowOwnerProcessIdProvider $windowHandle $liveProcess)
                }
                else {
                    if ($null -eq ('QiehaoquNativeWindow' -as [type])) {
                        Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class QiehaoquNativeWindow { [DllImport("user32.dll", SetLastError = true)] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId); }' -ErrorAction Stop
                    }
                    [uint32]$nativeOwnerProcessId = 0
                    $null = [QiehaoquNativeWindow]::GetWindowThreadProcessId(
                        [IntPtr]$windowHandle,
                        [ref]$nativeOwnerProcessId
                    )
                    $ownerProcessId = [int]$nativeOwnerProcessId
                }
            }
        }
        catch {
            $windowHandle = 0
            $ownerProcessId = 0
        }
        finally {
            if ($null -ne $liveProcess) { $liveProcess.Dispose() }
        }

        if ($windowHandle -eq 0 -or $ownerProcessId -ne $processId -or
            $ownerProcessId -eq $CallerProcessId) {
            continue
        }

        $automationResult = Invoke-CodexNativeQuitAutomation -WindowHandle $windowHandle -ExpectedProcessId $processId -AutomationSnapshotProvider $AutomationSnapshotProvider -AutomationInvokeProvider $AutomationInvokeProvider
        $automationResult.BlockingProcessCount = $blockingCount
        return $automationResult
    }

    return New-CodexNativeQuitResult -Result 'CODEX_NATIVE_QUIT_UI_NOT_FOUND' -BlockingProcessCount $blockingCount
}

function Assert-CodexNotRunning {
    param(
        [object[]]$ProcessData,

        [switch]$UseProvidedProcessData,

        [string]$DiagnosticOperation = '',

        [AllowEmptyCollection()][object[]]$OwnedProcessDescriptors = @(),

        [ValidateRange(0, 30000)]
        [int]$ProcessExitWaitMilliseconds =
            $script:CodexProcessExitWaitMilliseconds,

        [ValidateRange(1, 5000)]
        [int]$ProcessRecheckIntervalMilliseconds =
            $script:CodexProcessRecheckIntervalMilliseconds,

        [AllowNull()][scriptblock]$ProcessSnapshotProvider,

        [AllowNull()][scriptblock]$DelayProvider
    )

    if (-not [string]::IsNullOrWhiteSpace($DiagnosticOperation)) {
        Write-QiehaoDiagnosticEvent -Event 'PROCESS_CHECK_START' `
            -Result 'STARTED' -Data @{ Role = $DiagnosticOperation }
    }
    if ($UseProvidedProcessData) {
        $snapshot = @($ProcessData)
    }
    else {
        try { $snapshot = @(Get-ProcessInspectionSnapshot) }
        catch {
            if (-not [string]::IsNullOrWhiteSpace($DiagnosticOperation)) {
                Write-QiehaoDiagnosticEvent -Event 'PROCESS_CHECK_RESULT' `
                    -Level 'ERROR' -Result 'CODEX_PROCESS_STATE_UNKNOWN' `
                    -Data @{
                        Role = $DiagnosticOperation
                        ProcessCount = 0
                        Processes = @()
                        SafeToSave = $false
                        ReasonCode = 'CODEX_PROCESS_STATE_UNKNOWN'
                        BlockingCount = 0
                        UncertainCount = 0
                    }
            }
            throw (New-SafeException -Code 'CODEX_PROCESS_STATE_UNKNOWN')
        }
    }
    $processState = Test-CodexProcessesStopped -ProcessData $snapshot `
        -OwnedProcessDescriptors $OwnedProcessDescriptors
    if (-not [string]::IsNullOrWhiteSpace($DiagnosticOperation)) {
        $diagnosticProcesses = @()
        foreach ($process in @($snapshot)) {
            if ($null -eq $process) { continue }
            $nameProperty = $process.PSObject.Properties['ProcessName']
            $idProperty = $process.PSObject.Properties['Id']
            $pathProperty = $process.PSObject.Properties['ExecutablePath']
            $startProperty = $process.PSObject.Properties['ProcessStartTimeUtc']
            if ($null -eq $nameProperty -or $null -eq $idProperty) { continue }
            $processName = [string]$nameProperty.Value
            $processPath = if ($null -eq $pathProperty) { '' }
                else { [string]$pathProperty.Value }
            $normalizedName = Get-NormalizedProcessName -Name $processName
            $isCodexCandidate = (
                $normalizedName -match '^(?i:codex(?:[-_].*)?)$' -or
                $normalizedName -ieq 'ChatGPT' -or
                $normalizedName -ieq 'extension-host' -or
                (Test-CodexOwnedExecutablePath -Path $processPath)
            )
            if (-not $isCodexCandidate) { continue }
            $startTime = if ($null -eq $startProperty -or
                $null -eq $startProperty.Value) { '' }
                else {
                    try { ([DateTime]$startProperty.Value).ToUniversalTime().ToString('o') }
                    catch { '' }
                }
            $diagnosticProcesses += [pscustomobject]@{
                PID = [int]$idProperty.Value
                ProcessName = $processName
                ProcessPath = $processPath
                ProcessStartTime = $startTime
                IsQiehaoQuotaChild = [bool](Test-QiehaoOwnedQuotaProcess `
                    -Process $process `
                    -OwnedProcessDescriptors $OwnedProcessDescriptors)
            }
        }
        Write-QiehaoDiagnosticEvent -Event 'PROCESS_CHECK_RESULT' `
            -Level $(if ($processState.SafeToSave) { 'INFO' } else { 'WARNING' }) `
            -Result ([string]$processState.ReasonCode) -Data @{
                Role = $DiagnosticOperation
                ProcessCount = @($diagnosticProcesses).Count
                Processes = @($diagnosticProcesses)
                SafeToSave = [bool]$processState.SafeToSave
                ReasonCode = [string]$processState.ReasonCode
                BlockingCount = @($processState.BlockingProcesses).Count
                UncertainCount = @($processState.UncertainProcesses).Count
            }
    }

    # Codex Desktop may need a few seconds to finish shutting down after its
    # last window disappears. Recheck only a positively identified running
    # state, before any credential or profile write begins. Unknown process
    # state still fails closed immediately.
    $canRecheck = $ProcessExitWaitMilliseconds -gt 0 -and (
        -not $UseProvidedProcessData -or $null -ne $ProcessSnapshotProvider
    )
    if (-not $processState.SafeToSave -and
        [string]$processState.ReasonCode -ceq 'CODEX_PROCESS_RUNNING' -and
        $canRecheck) {
        $waitStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $recheckCount = 0
        if (-not [string]::IsNullOrWhiteSpace($DiagnosticOperation)) {
            Write-QiehaoDiagnosticEvent -Event 'PROCESS_WAIT_START' `
                -Result 'CODEX_PROCESS_RUNNING' -Data @{
                    Role = $DiagnosticOperation
                    WaitMilliseconds = $ProcessExitWaitMilliseconds
                    RecheckIntervalMilliseconds =
                        $ProcessRecheckIntervalMilliseconds
                    BlockingCount = @($processState.BlockingProcesses).Count
                }
        }
        try {
            while ($waitStopwatch.ElapsedMilliseconds -lt
                $ProcessExitWaitMilliseconds) {
                $remainingMilliseconds = $ProcessExitWaitMilliseconds -
                    [int]$waitStopwatch.ElapsedMilliseconds
                $delayMilliseconds = [Math]::Min(
                    $ProcessRecheckIntervalMilliseconds,
                    $remainingMilliseconds
                )
                if ($delayMilliseconds -gt 0) {
                    if ($null -ne $DelayProvider) {
                        & $DelayProvider $delayMilliseconds
                    }
                    else {
                        Start-Sleep -Milliseconds $delayMilliseconds
                    }
                }

                try {
                    $snapshot = if ($null -ne $ProcessSnapshotProvider) {
                        @(& $ProcessSnapshotProvider)
                    }
                    else { @(Get-ProcessInspectionSnapshot) }
                    $processState = Test-CodexProcessesStopped `
                        -ProcessData $snapshot `
                        -OwnedProcessDescriptors $OwnedProcessDescriptors
                }
                catch {
                    $processState = [pscustomobject]@{
                        SafeToSave = $false
                        BlockingProcesses = @()
                        UncertainProcesses = @()
                        ReasonCode = 'CODEX_PROCESS_STATE_UNKNOWN'
                    }
                }
                $recheckCount++
                if (-not [string]::IsNullOrWhiteSpace(
                    $DiagnosticOperation
                )) {
                    Write-QiehaoDiagnosticEvent -Event 'PROCESS_RECHECK' `
                        -Level $(if ($processState.SafeToSave) {
                            'INFO'
                        } else { 'WARNING' }) `
                        -Result ([string]$processState.ReasonCode) -Data @{
                            Role = $DiagnosticOperation
                            RecheckCount = $recheckCount
                            ElapsedMilliseconds =
                                [int]$waitStopwatch.ElapsedMilliseconds
                            SafeToSave = [bool]$processState.SafeToSave
                            ReasonCode = [string]$processState.ReasonCode
                            BlockingCount =
                                @($processState.BlockingProcesses).Count
                            UncertainCount =
                                @($processState.UncertainProcesses).Count
                        }
                }
                if ($processState.SafeToSave) {
                    if (-not [string]::IsNullOrWhiteSpace(
                        $DiagnosticOperation
                    )) {
                        Write-QiehaoDiagnosticEvent `
                            -Event 'PROCESS_EXITED_DURING_WAIT' `
                            -Result 'CODEX_PROCESSES_STOPPED' -Data @{
                                Role = $DiagnosticOperation
                                RecheckCount = $recheckCount
                                ElapsedMilliseconds =
                                    [int]$waitStopwatch.ElapsedMilliseconds
                                SafeToSave = $true
                            }
                    }
                    return
                }
                if ([string]$processState.ReasonCode -cne
                    'CODEX_PROCESS_RUNNING') {
                    break
                }
            }
        }
        finally {
            $waitStopwatch.Stop()
        }
        if ([string]$processState.ReasonCode -ceq
            'CODEX_PROCESS_RUNNING' -and
            -not [string]::IsNullOrWhiteSpace($DiagnosticOperation)) {
            Write-QiehaoDiagnosticEvent -Event 'PROCESS_STILL_RUNNING' `
                -Level 'WARNING' -Result 'CODEX_PROCESS_RUNNING' -Data @{
                    Role = $DiagnosticOperation
                    RecheckCount = $recheckCount
                    ElapsedMilliseconds =
                        [int]$waitStopwatch.ElapsedMilliseconds
                    BlockingCount = @($processState.BlockingProcesses).Count
                }
        }
    }
    if (-not $processState.SafeToSave) {
        throw (New-SafeException -Code $processState.ReasonCode)
    }
}

function Invoke-AtomicReplaceWithoutBackup {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SourcePath,

        [Parameter(Mandatory = $true)]
        [string]$DestinationPath
    )

    if ($null -eq ('CodexAccountSwitcher.NativeFileOperations' -as [type])) {
        $null = Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexAccountSwitcher
{
    public static class NativeFileOperations
    {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool MoveFileEx(
            string existingFileName,
            string newFileName,
            uint flags
        );
    }
}
'@ -ErrorAction Stop
    }

    # MOVEFILE_REPLACE_EXISTING (0x1) | MOVEFILE_WRITE_THROUGH (0x8).
    # Source and destination are created in the same directory by the caller.
    $moved = [CodexAccountSwitcher.NativeFileOperations]::MoveFileEx(
        $SourcePath,
        $DestinationPath,
        [uint32]0x9
    )
    if (-not $moved) {
        throw (New-SafeException -Code 'ATOMIC_WRITE_FAILED')
    }
}

function Write-AtomicByteFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes,

        [switch]$Force,

        [switch]$NoBackup
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = [System.IO.Path]::GetDirectoryName($fullPath)
    if (-not [System.IO.Directory]::Exists($directory)) {
        throw (New-SafeException -Code 'TARGET_DIRECTORY_NOT_FOUND')
    }

    if ([System.IO.File]::Exists($fullPath) -and -not $Force) {
        throw (New-SafeException -Code 'PROFILE_EXISTS')
    }

    $leafName = [System.IO.Path]::GetFileName($fullPath)
    $temporaryPath = Join-Path -Path $directory -ChildPath (
        '.{0}.{1}.tmp' -f $leafName, [Guid]::NewGuid().ToString('N')
    )
    $backupPath = Join-Path -Path $directory -ChildPath (
        '.{0}.{1}.bak' -f $leafName, [Guid]::NewGuid().ToString('N')
    )
    $stream = $null

    try {
        $stream = New-Object System.IO.FileStream(
            $temporaryPath,
            [System.IO.FileMode]::CreateNew,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::None,
            4096,
            [System.IO.FileOptions]::WriteThrough
        )
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = $null

        if ([System.IO.File]::Exists($fullPath)) {
            if (-not $Force) {
                throw (New-SafeException -Code 'PROFILE_EXISTS')
            }
            if ($NoBackup) {
                Invoke-AtomicReplaceWithoutBackup -SourcePath $temporaryPath `
                    -DestinationPath $fullPath
            }
            else {
                [System.IO.File]::Replace($temporaryPath, $fullPath, $backupPath, $true)
            }
        }
        else {
            [System.IO.File]::Move($temporaryPath, $fullPath)
        }
    }
    catch [System.InvalidOperationException] {
        throw
    }
    catch {
        throw (New-SafeException -Code 'ATOMIC_WRITE_FAILED')
    }
    finally {
        if ($null -ne $stream) {
            $stream.Dispose()
        }
        if ([System.IO.File]::Exists($temporaryPath)) {
            [System.IO.File]::Delete($temporaryPath)
        }
        if ([System.IO.File]::Exists($backupPath)) {
            [System.IO.File]::Delete($backupPath)
        }
    }
}

function Test-ByteArraysEqual {
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

function Get-ProfileFilePaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory
    )

    $safeName = ConvertTo-SafeProfileName -Name $Name
    return [pscustomobject]@{
        Name = $safeName
        EncryptedPath = Join-Path -Path $ProfilesDirectory -ChildPath ($safeName + '.auth.dpapi')
        MetadataPath = Join-Path -Path $ProfilesDirectory -ChildPath ($safeName + '.meta.json')
        IdentityMarkerPath = Join-Path -Path $ProfilesDirectory -ChildPath ($safeName + '.identity.dpapi')
    }
}

function Get-StrictProfileArtifactPaths {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory
    )

    if (-not [System.IO.Directory]::Exists($ProfilesDirectory)) {
        throw (New-SafeException -Code 'PROFILES_DIRECTORY_NOT_FOUND')
    }

    $rootPath = [System.IO.Path]::GetFullPath($ProfilesDirectory).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $rootInfo = Get-Item -LiteralPath $rootPath -Force -ErrorAction Stop
    if (($rootInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw (New-SafeException -Code 'PROFILE_PATH_UNSAFE')
    }

    $paths = Get-ProfileFilePaths -Name $Name -ProfilesDirectory $rootPath
    foreach ($path in @(
        $paths.EncryptedPath,
        $paths.IdentityMarkerPath,
        $paths.MetadataPath
    )) {
        $fullPath = [System.IO.Path]::GetFullPath($path)
        $parentPath = [System.IO.Path]::GetDirectoryName($fullPath).TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
        if (-not $parentPath.Equals($rootPath, [StringComparison]::OrdinalIgnoreCase)) {
            throw (New-SafeException -Code 'PROFILE_PATH_UNSAFE')
        }
        if ([System.IO.File]::Exists($fullPath)) {
            $fileInfo = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
            if (($fileInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw (New-SafeException -Code 'PROFILE_PATH_UNSAFE')
            }
        }
    }
    return $paths
}

function Get-ProfileNamesFromArtifacts {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory
    )

    if (-not [System.IO.Directory]::Exists($ProfilesDirectory)) {
        return @()
    }

    $profileNames = @{}
    foreach ($file in Get-ChildItem -LiteralPath $ProfilesDirectory -File -Force `
        -ErrorAction Stop) {
        $stem = $null
        foreach ($suffix in @('.auth.dpapi', '.identity.dpapi', '.meta.json')) {
            if ($file.Name.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
                $stem = $file.Name.Substring(0, $file.Name.Length - $suffix.Length)
                break
            }
        }
        if ($null -ne $stem -and (Test-SafeProfileFileStem -Name $stem)) {
            if (-not $profileNames.ContainsKey($stem)) {
                $profileNames[$stem] = $stem
            }
        }
    }
    return @($profileNames.Values | Sort-Object)
}

function Test-AnyProfileArtifactExists {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Paths
    )

    return [System.IO.File]::Exists($Paths.EncryptedPath) -or
        [System.IO.File]::Exists($Paths.IdentityMarkerPath) -or
        [System.IO.File]::Exists($Paths.MetadataPath)
}

function Get-ProfileMetadataState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory
    )

    $paths = Get-StrictProfileArtifactPaths -Name $Name `
        -ProfilesDirectory $ProfilesDirectory
    if (-not [System.IO.File]::Exists($paths.MetadataPath)) {
        return [pscustomobject]@{
            Exists = $false
            IsValid = $false
            CreatedAt = '<UNAVAILABLE>'
            UpdatedAt = '<UNAVAILABLE>'
            DPAPIScope = '<UNAVAILABLE>'
            RawObject = $null
        }
    }

    $metadataText = $null
    $metadata = $null
    try {
        $metadataLength = ([System.IO.FileInfo]$paths.MetadataPath).Length
        if ($metadataLength -le 0 -or
            $metadataLength -gt $script:MaximumMetadataFileBytes) {
            throw (New-SafeException -Code 'PROFILE_METADATA_INVALID')
        }
        $metadataText = [System.IO.File]::ReadAllText($paths.MetadataPath)
        $metadata = ConvertFrom-Json -InputObject $metadataText -ErrorAction Stop
        if ($null -eq $metadata -or -not ($metadata -is [pscustomobject])) {
            throw (New-SafeException -Code 'PROFILE_METADATA_INVALID')
        }

        $expectedKeys = @(
            'schema_version',
            'profile_name',
            'created_at',
            'updated_at',
            'encrypted_file_name',
            'encrypted_file_size',
            'dpapi_scope'
        )
        $actualKeys = @($metadata.PSObject.Properties | ForEach-Object { $_.Name })
        if ($actualKeys.Count -ne $expectedKeys.Count) {
            throw (New-SafeException -Code 'PROFILE_METADATA_INVALID')
        }
        foreach ($key in $expectedKeys) {
            if (-not ($actualKeys -ccontains $key)) {
                throw (New-SafeException -Code 'PROFILE_METADATA_INVALID')
            }
        }

        $createdAt = [DateTime]::MinValue
        $updatedAt = [DateTime]::MinValue
        $encryptedSize = [long]0
        $expectedEncryptedName = $paths.Name + '.auth.dpapi'
        $valid = [int]$metadata.schema_version -eq 1 -and
            [string]$metadata.profile_name -ceq $paths.Name -and
            [DateTime]::TryParse([string]$metadata.created_at, [ref]$createdAt) -and
            [DateTime]::TryParse([string]$metadata.updated_at, [ref]$updatedAt) -and
            [string]$metadata.encrypted_file_name -ceq $expectedEncryptedName -and
            [long]::TryParse([string]$metadata.encrypted_file_size, [ref]$encryptedSize) -and
            $encryptedSize -gt 0 -and
            [string]$metadata.dpapi_scope -ceq 'CurrentUser'

        if ($valid -and [System.IO.File]::Exists($paths.EncryptedPath)) {
            $valid = ([System.IO.FileInfo]$paths.EncryptedPath).Length -eq $encryptedSize
        }
        if (-not $valid) {
            throw (New-SafeException -Code 'PROFILE_METADATA_INVALID')
        }

        return [pscustomobject]@{
            Exists = $true
            IsValid = $true
            CreatedAt = $createdAt.ToUniversalTime().ToString('o')
            UpdatedAt = $updatedAt.ToUniversalTime().ToString('o')
            DPAPIScope = 'CurrentUser'
            RawObject = $metadata
        }
    }
    catch {
        return [pscustomobject]@{
            Exists = $true
            IsValid = $false
            CreatedAt = '<INVALID_METADATA>'
            UpdatedAt = '<INVALID_METADATA>'
            DPAPIScope = '<INVALID_METADATA>'
            RawObject = $null
        }
    }
    finally {
        $metadataText = $null
    }
}

function Write-CodexProfileIdentityMarker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [byte[]]$AuthBytes,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [switch]$Force
    )

    $identityBytes = $null
    $payloadBytes = $null
    $protectedBytes = $null
    try {
        $paths = Get-ProfileFilePaths -Name $Name -ProfilesDirectory $ProfilesDirectory
        $identityBytes = Get-CodexAuthIdentityBytes -Bytes $AuthBytes
        $payloadBytes = New-CodexIdentityMarkerPayload -IdentityBytes $identityBytes
        $protectedBytes = Protect-CodexIdentityMarkerPayload -Data $payloadBytes
        Write-AtomicByteFile -Path $paths.IdentityMarkerPath -Bytes $protectedBytes `
            -Force:$Force
    }
    finally {
        foreach ($buffer in @($identityBytes, $payloadBytes, $protectedBytes)) {
            if ($null -ne $buffer -and $buffer.Length -gt 0) {
                [Array]::Clear($buffer, 0, $buffer.Length)
            }
        }
    }
}

function Read-CodexProfileIdentityMarker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory
    )

    $encryptedBytes = $null
    $payloadBytes = $null
    $identityBytes = $null
    try {
        $paths = Get-ProfileFilePaths -Name $Name -ProfilesDirectory $ProfilesDirectory
        if (-not [System.IO.File]::Exists($paths.IdentityMarkerPath)) {
            throw (New-SafeException -Code 'PROFILE_IDENTITY_MARKER_MISSING')
        }
        $encryptedBytes = Read-SensitiveFileBytes -Path $paths.IdentityMarkerPath
        $payloadBytes = Unprotect-CodexIdentityMarkerPayload -Data $encryptedBytes
        $identityBytes = Get-CodexIdentityFromMarkerPayload -Payload $payloadBytes
        return ,$identityBytes
    }
    catch {
        if ($null -ne $identityBytes -and $identityBytes.Length -gt 0) {
            [Array]::Clear($identityBytes, 0, $identityBytes.Length)
        }
        throw
    }
    finally {
        foreach ($buffer in @($encryptedBytes, $payloadBytes)) {
            if ($null -ne $buffer -and $buffer.Length -gt 0) {
                [Array]::Clear($buffer, 0, $buffer.Length)
            }
        }
    }
}

function Compare-CodexAuthToProfileIdentity {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][byte[]]$AuthBytes,
        [Parameter(Mandatory = $true)][string]$ProfilesDirectory
    )

    $markerIdentityBytes = $null
    $savedAuthBytes = $null
    $currentContext = $null
    $savedContext = $null
    try {
        $markerIdentityBytes = Read-CodexProfileIdentityMarker -Name $Name -ProfilesDirectory $ProfilesDirectory
        $currentContext = Get-CodexAuthIdentityContext -Bytes $AuthBytes
        $savedAuthBytes = Read-CodexAccountSlotBytes -Name $Name -ProfilesDirectory $ProfilesDirectory
        $savedContext = Get-CodexAuthIdentityContext -Bytes $savedAuthBytes

        $markerMatchesSaved = Test-IdentityByteArraysEqual -Left $markerIdentityBytes -Right $savedContext.AccountIdBytes
        $accountMatches = Test-IdentityByteArraysEqual -Left $savedContext.AccountIdBytes -Right $currentContext.AccountIdBytes
        $userMatches = $true
        if ($savedContext.SupplementalContextKnown -and
            $currentContext.SupplementalContextKnown) {
            $userMatches = Test-IdentityByteArraysEqual -Left $savedContext.UserIdBytes -Right $currentContext.UserIdBytes
        }
        $workspaceClaimsValid = (
            [string]$savedContext.WorkspaceClaimStatus -cne 'Mismatch' -and
            [string]$currentContext.WorkspaceClaimStatus -cne 'Mismatch'
        )
        $contextStatus = if (-not $workspaceClaimsValid) {
            'Mismatch'
        }
        elseif (
            $savedContext.SupplementalContextKnown -and
            $currentContext.SupplementalContextKnown
        ) { 'Confirmed' } else { 'LegacyUnknown' }

        return [pscustomobject]@{
            Matches = $markerMatchesSaved -and $accountMatches -and
                $userMatches -and $workspaceClaimsValid
            WorkspaceContextStatus = $contextStatus
            SavedWorkspaceClass = [string]$savedContext.WorkspaceClass
            CurrentWorkspaceClass = [string]$currentContext.WorkspaceClass
        }
    }
    finally {
        foreach ($buffer in @($markerIdentityBytes, $savedAuthBytes)) {
            if ($null -ne $buffer -and $buffer.Length -gt 0) {
                [Array]::Clear($buffer, 0, $buffer.Length)
            }
        }
        Clear-CodexAuthIdentityContext -Context $currentContext
        Clear-CodexAuthIdentityContext -Context $savedContext
    }
}

function Assert-CodexAuthMatchesProfileIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [byte[]]$AuthBytes,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [ValidateSet('ACTIVE_PROFILE_IDENTITY_MISMATCH', 'PROFILE_IDENTITY_MISMATCH')]
        [string]$MismatchCode = 'ACTIVE_PROFILE_IDENTITY_MISMATCH'
    )

    $comparison = Compare-CodexAuthToProfileIdentity -Name $Name `
        -AuthBytes $AuthBytes -ProfilesDirectory $ProfilesDirectory
    if (-not $comparison.Matches) {
        throw (New-SafeException -Code $MismatchCode)
    }
    return $comparison
}

function Test-ProfileIdentityExists {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$IdentityBytes,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [AllowNull()][byte[]]$AuthBytes,

        [string]$ExcludeProfileName
    )

    $safeExcludedName = $null
    if (-not [string]::IsNullOrWhiteSpace($ExcludeProfileName)) {
        $safeExcludedName = ConvertTo-SafeProfileName -Name $ExcludeProfileName
    }

    foreach ($artifactFile in Get-ChildItem -LiteralPath $ProfilesDirectory -File `
        -Force -ErrorAction Stop) {
        foreach ($suffix in @('.auth.dpapi', '.identity.dpapi', '.meta.json')) {
            if ($artifactFile.Name.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
                $artifactStem = $artifactFile.Name.Substring(
                    0,
                    $artifactFile.Name.Length - $suffix.Length
                )
                if (-not (Test-SafeProfileFileStem -Name $artifactStem)) {
                    throw (New-SafeException -Code 'PROFILE_IDENTITY_SCAN_INCOMPLETE')
                }
                break
            }
        }
    }

    foreach ($profileName in @(Get-ProfileNamesFromArtifacts `
        -ProfilesDirectory $ProfilesDirectory)) {
        if ($null -ne $safeExcludedName -and
            $profileName.Equals($safeExcludedName, [StringComparison]::OrdinalIgnoreCase)) {
            continue
        }

        $paths = Get-StrictProfileArtifactPaths -Name $profileName `
            -ProfilesDirectory $ProfilesDirectory
        if (-not [System.IO.File]::Exists($paths.IdentityMarkerPath)) {
            throw (New-SafeException -Code 'PROFILE_IDENTITY_SCAN_INCOMPLETE')
        }

        $existingIdentityBytes = $null
        $existingAuthBytes = $null
        $existingContext = $null
        $candidateContext = $null
        try {
            $existingIdentityBytes = Read-CodexProfileIdentityMarker `
                -Name $profileName -ProfilesDirectory $ProfilesDirectory
            if (Test-IdentityByteArraysEqual -Left $IdentityBytes `
                -Right $existingIdentityBytes) {
                if ($null -ne $AuthBytes) {
                    $candidateContext = Get-CodexAuthIdentityContext `
                        -Bytes $AuthBytes
                    $existingAuthBytes = Read-CodexAccountSlotBytes `
                        -Name $profileName `
                        -ProfilesDirectory $ProfilesDirectory
                    $existingContext = Get-CodexAuthIdentityContext `
                        -Bytes $existingAuthBytes
                    if ($candidateContext.SupplementalContextKnown -and
                        $existingContext.SupplementalContextKnown) {
                        $sameUser = Test-IdentityByteArraysEqual `
                            -Left $candidateContext.UserIdBytes `
                            -Right $existingContext.UserIdBytes
                        if (-not $sameUser) {
                            throw (New-SafeException `
                                -Code 'PROFILE_IDENTITY_SCAN_INCOMPLETE')
                        }
                    }
                }
                return [pscustomobject]@{
                    Exists = $true
                    Profile = $profileName
                }
            }
        }
        catch [System.InvalidOperationException] {
            if ($_.Exception.Message -eq 'PROFILE_IDENTITY_MARKER_MISSING') {
                throw (New-SafeException -Code 'PROFILE_IDENTITY_SCAN_INCOMPLETE')
            }
            if ($_.Exception.Message -match '^PROFILE_IDENTITY_') {
                throw (New-SafeException -Code 'PROFILE_IDENTITY_SCAN_INCOMPLETE')
            }
            throw
        }
        finally {
            foreach ($buffer in @($existingIdentityBytes, $existingAuthBytes)) {
                if ($null -ne $buffer -and $buffer.Length -gt 0) {
                    [Array]::Clear($buffer, 0, $buffer.Length)
                }
            }
            Clear-CodexAuthIdentityContext -Context $existingContext
            Clear-CodexAuthIdentityContext -Context $candidateContext
        }
    }

    return [pscustomobject]@{
        Exists = $false
        Profile = $null
    }
}

function Write-CodexAccountSlotBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [byte[]]$AuthBytes,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [switch]$Force
    )

    $encryptedBytes = $null
    $metadataBytes = $null
    try {
        $null = Test-CodexAuthBytes -Bytes $AuthBytes
        if (-not [System.IO.Directory]::Exists($ProfilesDirectory)) {
            throw (New-SafeException -Code 'PROFILES_DIRECTORY_NOT_FOUND')
        }

        $paths = Get-ProfileFilePaths -Name $Name -ProfilesDirectory $ProfilesDirectory
        if (([System.IO.File]::Exists($paths.EncryptedPath) -or
             [System.IO.File]::Exists($paths.MetadataPath) -or
             [System.IO.File]::Exists($paths.IdentityMarkerPath)) -and -not $Force) {
            throw (New-SafeException -Code 'PROFILE_EXISTS')
        }

        $now = [DateTime]::UtcNow
        if ([System.IO.File]::Exists($paths.EncryptedPath)) {
            $createdAt = [System.IO.File]::GetCreationTimeUtc($paths.EncryptedPath)
        }
        else {
            $createdAt = $now
        }

        $encryptedBytes = Protect-CodexAuthBytes -Data $AuthBytes
        $metadata = [ordered]@{
            schema_version = 1
            profile_name = $paths.Name
            created_at = $createdAt.ToString('o')
            updated_at = $now.ToString('o')
            encrypted_file_name = [System.IO.Path]::GetFileName($paths.EncryptedPath)
            encrypted_file_size = $encryptedBytes.Length
            dpapi_scope = 'CurrentUser'
        }
        $metadataJson = $metadata | ConvertTo-Json -Compress
        $metadataBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($metadataJson)
        $metadataJson = $null
        $metadata = $null

        Write-AtomicByteFile -Path $paths.EncryptedPath -Bytes $encryptedBytes -Force:$Force
        # The marker is written only after the encrypted credential container.
        # A partial failure leaves a missing/stale marker, which future switches
        # reject rather than trusting the profile label.
        Write-CodexProfileIdentityMarker -Name $paths.Name -AuthBytes $AuthBytes `
            -ProfilesDirectory $ProfilesDirectory -Force:$Force
        Write-AtomicByteFile -Path $paths.MetadataPath -Bytes $metadataBytes -Force:$Force

        return [pscustomobject]@{
            Profile = $paths.Name
            DPAPIScope = 'CurrentUser'
            EncryptedFile = [System.IO.Path]::GetFileName($paths.EncryptedPath)
        }
    }
    finally {
        if ($null -ne $encryptedBytes -and $encryptedBytes.Length -gt 0) {
            [Array]::Clear($encryptedBytes, 0, $encryptedBytes.Length)
        }
        if ($null -ne $metadataBytes -and $metadataBytes.Length -gt 0) {
            [Array]::Clear($metadataBytes, 0, $metadataBytes.Length)
        }
    }
}

function Read-CodexAccountSlotBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory
    )

    $encryptedBytes = $null
    $plainBytes = $null
    try {
        $paths = Get-ProfileFilePaths -Name $Name -ProfilesDirectory $ProfilesDirectory
        if (-not [System.IO.File]::Exists($paths.EncryptedPath)) {
            throw (New-SafeException -Code 'PROFILE_NOT_FOUND')
        }
        $encryptedBytes = Read-SensitiveFileBytes -Path $paths.EncryptedPath
        $plainBytes = Unprotect-CodexAuthBytes -Data $encryptedBytes
        $null = Test-CodexAuthBytes -Bytes $plainBytes
        return ,$plainBytes
    }
    catch {
        if ($null -ne $plainBytes -and $plainBytes.Length -gt 0) {
            [Array]::Clear($plainBytes, 0, $plainBytes.Length)
        }
        throw
    }
    finally {
        if ($null -ne $encryptedBytes -and $encryptedBytes.Length -gt 0) {
            [Array]::Clear($encryptedBytes, 0, $encryptedBytes.Length)
        }
    }
}

function Read-ActiveProfileState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$StateDirectory
    )

    $statePath = Join-Path -Path $StateDirectory -ChildPath 'active-profile.json'
    if (-not [System.IO.File]::Exists($statePath)) {
        throw (New-SafeException -Code 'ACTIVE_PROFILE_NOT_INITIALIZED')
    }

    $stateText = $null
    $stateObject = $null
    try {
        $stateText = [System.IO.File]::ReadAllText($statePath)
        $stateObject = ConvertFrom-Json -InputObject $stateText -ErrorAction Stop
        if ($null -eq $stateObject -or -not ($stateObject -is [pscustomobject])) {
            throw (New-SafeException -Code 'ACTIVE_PROFILE_STATE_INVALID')
        }

        $actualKeys = @($stateObject.PSObject.Properties | ForEach-Object { $_.Name })
        $expectedKeys = @('schema_version', 'active_profile', 'updated_at')
        if ($actualKeys.Count -ne $expectedKeys.Count) {
            throw (New-SafeException -Code 'ACTIVE_PROFILE_STATE_INVALID')
        }
        foreach ($key in $expectedKeys) {
            if (-not ($actualKeys -ccontains $key)) {
                throw (New-SafeException -Code 'ACTIVE_PROFILE_STATE_INVALID')
            }
        }
        if ([int]$stateObject.schema_version -ne 1) {
            throw (New-SafeException -Code 'ACTIVE_PROFILE_STATE_INVALID')
        }

        $activeName = ConvertTo-SafeProfileName -Name ([string]$stateObject.active_profile)
        if ($activeName -cne [string]$stateObject.active_profile) {
            throw (New-SafeException -Code 'ACTIVE_PROFILE_STATE_INVALID')
        }
        $parsedUpdatedAt = [DateTime]::MinValue
        if (-not [DateTime]::TryParse([string]$stateObject.updated_at, [ref]$parsedUpdatedAt)) {
            throw (New-SafeException -Code 'ACTIVE_PROFILE_STATE_INVALID')
        }

        return [pscustomobject]@{
            SchemaVersion = 1
            ActiveProfile = $activeName
            UpdatedAt = $parsedUpdatedAt.ToUniversalTime().ToString('o')
        }
    }
    catch [System.InvalidOperationException] {
        throw
    }
    catch {
        throw (New-SafeException -Code 'ACTIVE_PROFILE_STATE_INVALID')
    }
    finally {
        $stateObject = $null
        $stateText = $null
    }
}

function Write-ActiveProfileState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory
    )

    if (-not [System.IO.Directory]::Exists($StateDirectory)) {
        throw (New-SafeException -Code 'STATE_DIRECTORY_NOT_FOUND')
    }
    $safeName = ConvertTo-SafeProfileName -Name $Name
    $state = [ordered]@{
        schema_version = 1
        active_profile = $safeName
        updated_at = [DateTime]::UtcNow.ToString('o')
    }
    $stateJson = $state | ConvertTo-Json -Compress
    $stateBytes = $null
    try {
        $stateBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($stateJson)
        $statePath = Join-Path -Path $StateDirectory -ChildPath 'active-profile.json'
        Write-AtomicByteFile -Path $statePath -Bytes $stateBytes -Force -NoBackup
    }
    finally {
        if ($null -ne $stateBytes -and $stateBytes.Length -gt 0) {
            [Array]::Clear($stateBytes, 0, $stateBytes.Length)
        }
        $stateJson = $null
        $state = $null
    }
}

function Write-CodexAuthFileBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$AuthPath,

        [Parameter(Mandatory = $true)]
        [byte[]]$AuthBytes
    )

    $null = Test-CodexAuthBytes -Bytes $AuthBytes
    Write-AtomicByteFile -Path $AuthPath -Bytes $AuthBytes -Force -NoBackup
}

function ConvertTo-QiehaoDiagnosticSafeValue {
    param(
        [AllowNull()][object]$Value,
        [string]$FieldName = '',
        [ValidateRange(0, 6)][int]$Depth = 0
    )

    $allowedFields = @(
        'ActiveProfile', 'TargetProfile', 'Profile', 'Role',
        'CredentialSource', 'WorkspaceType', 'IdentityHash', 'ParseResult',
        'ProcessCount', 'Processes', 'PID', 'ProcessName', 'ProcessPath',
        'ProcessStartTime', 'IsQiehaoQuotaChild', 'SafeToSave',
        'ReasonCode', 'BlockingCount', 'UncertainCount', 'ResultCode',
        'ProfileIntegrity', 'CurrentWorkspaceType', 'SavedWorkspaceType',
        'Decision', 'Version', 'PowerShellVersion', 'WindowsVersion',
        'CodexHomeExists', 'ProfileCount', 'WaitMilliseconds',
        'RecheckIntervalMilliseconds', 'RecheckCount',
        'ElapsedMilliseconds', 'saved_workspace_type',
        'current_workspace_type'
    )
    if (-not [string]::IsNullOrWhiteSpace($FieldName) -and
        $allowedFields -cnotcontains $FieldName) {
        return $null
    }
    if ($null -eq $Value) { return $null }
    if ($Depth -ge 6) { return '[depth_limited]' }

    if ($Value -is [System.Collections.IDictionary]) {
        $safeMap = [ordered]@{}
        foreach ($key in @($Value.Keys)) {
            $safeKey = [string]$key
            if ($allowedFields -ccontains $safeKey) {
                $safeMap[$safeKey] = ConvertTo-QiehaoDiagnosticSafeValue `
                    -Value $Value[$key] -FieldName $safeKey `
                    -Depth ($Depth + 1)
            }
        }
        return $safeMap
    }
    if ($Value -is [System.Collections.IEnumerable] -and
        -not ($Value -is [string])) {
        $safeItems = @()
        foreach ($item in @($Value)) {
            $safeItems += ,(ConvertTo-QiehaoDiagnosticSafeValue `
                -Value $item -Depth ($Depth + 1))
        }
        return $safeItems
    }
    if ($Value -is [pscustomobject]) {
        $safeObject = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties)) {
            if ($allowedFields -ccontains [string]$property.Name) {
                $safeObject[[string]$property.Name] =
                    ConvertTo-QiehaoDiagnosticSafeValue `
                        -Value $property.Value `
                        -FieldName ([string]$property.Name) `
                        -Depth ($Depth + 1)
            }
        }
        return $safeObject
    }
    if ($Value -is [bool] -or $Value -is [byte] -or
        $Value -is [int16] -or $Value -is [int32] -or
        $Value -is [int64] -or $Value -is [uint16] -or
        $Value -is [uint32] -or $Value -is [uint64] -or
        $Value -is [double] -or $Value -is [decimal]) {
        return $Value
    }

    $text = [string]$Value
    $text = [regex]::Replace(
        $text,
        '(?i)\b(?:access_token|refresh_token|id_token|token)\s*[:=]\s*[^\s,;]+',
        '[token_removed]'
    )
    $text = [regex]::Replace(
        $text,
        '(?i)\b(?:authorization|cookie)\s*[:=]\s*[^\r\n]+',
        '[header_removed]'
    )
    $text = [regex]::Replace(
        $text,
        '(?i)\bBearer\s+[A-Za-z0-9._~+/=-]+',
        '[authorization_removed]'
    )
    $text = [regex]::Replace(
        $text,
        '(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*',
        '[jwt_removed]'
    )
    $text = [regex]::Replace(
        $text,
        '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b',
        '[email_removed]'
    )
    if ($text.Length -gt 1024) {
        $text = $text.Substring(0, 1024) + '[truncated]'
    }
    return $text
}

function Get-QiehaoDiagnosticIdentityHash {
    param([Parameter(Mandatory = $true)][byte[]]$IdentityBytes)

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $domainBytes = $null
    $combinedBytes = $null
    $hashBytes = $null
    try {
        $domainBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(
            'QIEHAO_DIAGNOSTIC_IDENTITY_V1'
        )
        $combinedBytes = New-Object byte[] ($domainBytes.Length + 1 +
            $IdentityBytes.Length)
        [Array]::Copy($domainBytes, 0, $combinedBytes, 0, $domainBytes.Length)
        [Array]::Copy(
            $IdentityBytes,
            0,
            $combinedBytes,
            $domainBytes.Length + 1,
            $IdentityBytes.Length
        )
        $hashBytes = $sha256.ComputeHash($combinedBytes)
        return ([BitConverter]::ToString($hashBytes, 0, 16)).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
        foreach ($buffer in @($domainBytes, $combinedBytes, $hashBytes)) {
            if ($null -ne $buffer -and $buffer.Length -gt 0) {
                [Array]::Clear($buffer, 0, $buffer.Length)
            }
        }
    }
}

function Write-QiehaoDiagnosticEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'APP_START',
            'ADD_START', 'ADD_AUTH_FOUND', 'ADD_IDENTITY_PARSE',
            'ADD_SUCCESS', 'ADD_FAILED',
            'SWITCH_START', 'PROCESS_CHECK_START', 'PROCESS_CHECK_RESULT',
            'PROCESS_WAIT_START', 'PROCESS_RECHECK',
            'PROCESS_EXITED_DURING_WAIT', 'PROCESS_STILL_RUNNING',
            'AUTH_REPLACE', 'READBACK_VERIFY', 'WORKSPACE_DETECT',
            'WORKSPACE_TYPE_MISMATCH',
            'SWITCH_SUCCESS', 'SWITCH_FAILED',
            'VERIFY_START', 'PROFILE_INTEGRITY_RESULT',
            'CURRENT_IDENTITY_RESULT', 'WORKSPACE_RESULT',
            'VERIFY_SUCCESS', 'VERIFY_MISMATCH', 'VERIFY_FAILED',
            'DELETE_START', 'DELETE_DECISION', 'DELETE_SUCCESS',
            'DELETE_FAILED', 'SAVE_STARTED', 'SAVE_SUCCEEDED', 'SAVE_FAILED',
            'PROFILE_REMOVE_QUARANTINE_CLEANUP_FAILED'
        )]
        [string]$Event,

        [ValidateSet('INFO', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO',

        [string]$Result = '',

        [AllowNull()][System.Collections.IDictionary]$Data,

        [string]$LogDirectory = $script:LogsDirectory
    )

    if (-not [System.IO.Directory]::Exists($LogDirectory)) { return }
    $safeData = ConvertTo-QiehaoDiagnosticSafeValue -Value $Data
    $entry = [ordered]@{
        time = [DateTime]::UtcNow.ToString('o')
        level = $Level
        event = $Event
        result = ConvertTo-QiehaoDiagnosticSafeValue -Value $Result
        data = $safeData
    }
    $json = $null
    try {
        $json = $entry | ConvertTo-Json -Compress -Depth 8
        $logPath = Join-Path -Path $LogDirectory -ChildPath 'qiehao.log'
        [System.IO.File]::AppendAllText(
            $logPath,
            $json + [Environment]::NewLine,
            (New-Object System.Text.UTF8Encoding($false))
        )
    }
    catch {
        # Diagnostics are best effort and must never alter a secure operation.
    }
    finally {
        $json = $null
        $entry = $null
        $safeData = $null
    }
}

function Write-SafeLog {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet(
            'SAVE_STARTED',
            'SAVE_SUCCEEDED',
            'SAVE_FAILED',
            'PROFILE_REMOVE_QUARANTINE_CLEANUP_FAILED'
        )]
        [string]$Event,

        [string]$ProfileName
    )

    if (-not [System.IO.Directory]::Exists($script:LogsDirectory)) {
        return
    }

    $level = if ($Event -ceq 'SAVE_FAILED') { 'ERROR' }
        elseif ($Event -ceq 'PROFILE_REMOVE_QUARANTINE_CLEANUP_FAILED') {
            'WARNING'
        }
        else { 'INFO' }
    $data = if ([string]::IsNullOrWhiteSpace($ProfileName)) { @{} }
        else { @{ Profile = $ProfileName } }
    Write-QiehaoDiagnosticEvent -Event $Event -Level $level `
        -Result $Event -Data $data
}

function Write-QiehaoAppStartDiagnostic {
    [CmdletBinding()]
    param([string]$Version = '1.0.0-rc')

    $codexHomeExists = $false
    $credentialSource = 'Unknown'
    $profileCount = 0
    try {
        $codexHome = Get-CodexHome
        $codexHomeExists = [System.IO.Directory]::Exists($codexHome)
        try {
            $sourceInfo = Get-CodexCredentialSourceInfo `
                -CodexHome $codexHome
            $credentialSource = [string]$sourceInfo.Source
        }
        catch { $credentialSource = 'Unknown' }
    }
    catch { }
    try {
        $profileCount = @(Get-CodexAccountSlotState `
            -ProfilesDirectory $script:ProfilesDirectory `
            -StateDirectory $script:StateDirectory).Count
    }
    catch { $profileCount = 0 }

    Write-QiehaoDiagnosticEvent -Event 'APP_START' -Result 'STARTED' `
        -Data @{
            Version = $Version
            PowerShellVersion = [string]$PSVersionTable.PSVersion
            WindowsVersion = [Environment]::OSVersion.VersionString
            CodexHomeExists = $codexHomeExists
            CredentialSource = $credentialSource
            ProfileCount = $profileCount
        }
}

function Invoke-SaveCodexAccountSlotUnlocked {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name,

        [switch]$Force
    )

    $safeName = ConvertTo-SafeProfileName -Name $Name
    $authBytes = $null

    try {
        # Fail closed before resolving or reading the real auth file. Saving is
        # intentionally permitted only from a separate PowerShell after all
        # Codex/ChatGPT processes have exited normally.
        Assert-CodexNotRunning

        Write-SafeLog -Event 'SAVE_STARTED' -ProfileName $safeName

        $codexHome = Get-CodexHome
        $authPath = Join-Path -Path $codexHome -ChildPath 'auth.json'
        $authBytes = Read-SensitiveFileBytes -Path $authPath
        $savedSlot = Write-CodexAccountSlotBytes -Name $safeName -AuthBytes $authBytes `
            -ProfilesDirectory $script:ProfilesDirectory -Force:$Force

        Write-SafeLog -Event 'SAVE_SUCCEEDED' -ProfileName $safeName
        return [pscustomobject]@{
            Profile = $safeName
            Saved = $true
            DPAPIScope = 'CurrentUser'
            EncryptedFile = $savedSlot.EncryptedFile
        }
    }
    catch {
        Write-SafeLog -Event 'SAVE_FAILED'
        if ($_.Exception.Message -match '^[A-Z][A-Z0-9_]+$') {
            throw
        }
        throw (New-SafeException -Code 'SAVE_FAILED')
    }
    finally {
        if ($null -ne $authBytes -and $authBytes.Length -gt 0) {
            [Array]::Clear($authBytes, 0, $authBytes.Length)
        }
    }
}

function Save-CodexAccountSlot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name,

        [switch]$Force
    )

    return Invoke-WithCodexWriteLock -Operation {
        param($LockedName, $LockedForce)
        Invoke-SaveCodexAccountSlotUnlocked -Name $LockedName -Force:$LockedForce
    } -ArgumentList @($Name, [bool]$Force)
}

function Invoke-SaveCodexActiveProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexHome,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [object[]]$ProcessData,

        [switch]$UseProvidedProcessData
    )

    $authBytes = $null
    $readBackBytes = $null
    try {
        Assert-CodexNotRunning -ProcessData $ProcessData `
            -UseProvidedProcessData:$UseProvidedProcessData
        $null = Assert-CodexFileCredentialSource -CodexHome $CodexHome

        $activeState = Read-ActiveProfileState -StateDirectory $StateDirectory
        $activeName = [string]$activeState.ActiveProfile
        $authPath = Join-Path -Path $CodexHome -ChildPath 'auth.json'
        $authBytes = Read-SensitiveFileBytes -Path $authPath
        $null = Test-CodexAuthBytes -Bytes $authBytes

        # The Add Account wizard must preserve refreshed credentials before the
        # user signs out. Never trust the active label alone: a manual identity
        # change must fail closed instead of contaminating the existing slot.
        $null = Assert-CodexAuthMatchesProfileIdentity -Name $activeName `
            -AuthBytes $authBytes -ProfilesDirectory $ProfilesDirectory `
            -MismatchCode 'ACTIVE_PROFILE_IDENTITY_MISMATCH'
        $null = Write-CodexAccountSlotBytes -Name $activeName `
            -AuthBytes $authBytes -ProfilesDirectory $ProfilesDirectory -Force

        $readBackBytes = Read-CodexAccountSlotBytes -Name $activeName `
            -ProfilesDirectory $ProfilesDirectory
        if (-not (Test-ByteArraysEqual -Left $authBytes -Right $readBackBytes)) {
            throw (New-SafeException -Code 'ACTIVE_PROFILE_SAVE_VERIFICATION_FAILED')
        }
        $null = Assert-CodexAuthMatchesProfileIdentity -Name $activeName `
            -AuthBytes $readBackBytes -ProfilesDirectory $ProfilesDirectory `
            -MismatchCode 'ACTIVE_PROFILE_IDENTITY_MISMATCH'

        return [pscustomobject]@{
            Result = 'ACTIVE_PROFILE_SAVE_SUCCESS'
            Profile = $activeName
        }
    }
    catch {
        if ($_.Exception.Message -match '^[A-Z][A-Z0-9_]+$') {
            throw
        }
        throw (New-SafeException -Code 'ACTIVE_PROFILE_SAVE_FAILED')
    }
    finally {
        foreach ($buffer in @($authBytes, $readBackBytes)) {
            if ($null -ne $buffer -and $buffer.Length -gt 0) {
                [Array]::Clear($buffer, 0, $buffer.Length)
            }
        }
    }
}

function Save-CodexActiveProfile {
    [CmdletBinding()]
    param()

    return Invoke-WithCodexWriteLock -Operation {
        $codexHome = Get-CodexHome
        Invoke-SaveCodexActiveProfile -CodexHome $codexHome `
            -ProfilesDirectory $script:ProfilesDirectory `
            -StateDirectory $script:StateDirectory
    }
}

function Invoke-InitializeCodexProfileIdentityMarker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [object[]]$ProcessData,

        [switch]$UseProvidedProcessData
    )

    $profileBytes = $null
    try {
        Assert-CodexNotRunning -ProcessData $ProcessData `
            -UseProvidedProcessData:$UseProvidedProcessData
        $safeName = ConvertTo-SafeProfileName -Name $Name
        $profileBytes = Read-CodexAccountSlotBytes -Name $safeName `
            -ProfilesDirectory $ProfilesDirectory
        Write-CodexProfileIdentityMarker -Name $safeName -AuthBytes $profileBytes `
            -ProfilesDirectory $ProfilesDirectory -Force
        $null = Assert-CodexAuthMatchesProfileIdentity -Name $safeName `
            -AuthBytes $profileBytes -ProfilesDirectory $ProfilesDirectory
        return [pscustomobject]@{
            Result = 'IDENTITY_MARKER_INITIALIZED'
            Profile = $safeName
        }
    }
    finally {
        if ($null -ne $profileBytes -and $profileBytes.Length -gt 0) {
            [Array]::Clear($profileBytes, 0, $profileBytes.Length)
        }
    }
}

function Initialize-CodexProfileIdentityMarker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name
    )

    return Invoke-WithCodexWriteLock -Operation {
        param($LockedName)
        Invoke-InitializeCodexProfileIdentityMarker -Name $LockedName `
            -ProfilesDirectory $script:ProfilesDirectory
    } -ArgumentList @($Name)
}

function Invoke-InitializeCodexActiveProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$CodexHome,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [object[]]$ProcessData,

        [switch]$UseProvidedProcessData
    )

    $profileBytes = $null
    $authBytes = $null
    try {
        Assert-CodexNotRunning -ProcessData $ProcessData `
            -UseProvidedProcessData:$UseProvidedProcessData
        $null = Assert-CodexFileCredentialSource -CodexHome $CodexHome

        $safeName = ConvertTo-SafeProfileName -Name $Name
        $profileBytes = Read-CodexAccountSlotBytes -Name $safeName `
            -ProfilesDirectory $ProfilesDirectory
        $authPath = Join-Path -Path $CodexHome -ChildPath 'auth.json'
        $authBytes = Read-SensitiveFileBytes -Path $authPath
        $null = Test-CodexAuthBytes -Bytes $authBytes

        if (-not (Test-ByteArraysEqual -Left $profileBytes -Right $authBytes)) {
            throw (New-SafeException -Code 'ACTIVE_PROFILE_MISMATCH')
        }

        # Exact init comparison is the safe migration point for legacy slots:
        # only a profile proven identical to the current auth receives a marker.
        Write-CodexProfileIdentityMarker -Name $safeName -AuthBytes $profileBytes `
            -ProfilesDirectory $ProfilesDirectory -Force
        Write-ActiveProfileState -Name $safeName -StateDirectory $StateDirectory
        return [pscustomobject]@{
            Result = 'INIT_ACTIVE_SUCCESS'
            ActiveProfile = $safeName
        }
    }
    finally {
        foreach ($buffer in @($profileBytes, $authBytes)) {
            if ($null -ne $buffer -and $buffer.Length -gt 0) {
                [Array]::Clear($buffer, 0, $buffer.Length)
            }
        }
    }
}

function Initialize-CodexActiveProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name
    )

    return Invoke-WithCodexWriteLock -Operation {
        param($LockedName)
        $codexHome = Get-CodexHome
        Invoke-InitializeCodexActiveProfile -Name $LockedName -CodexHome $codexHome `
            -ProfilesDirectory $script:ProfilesDirectory -StateDirectory $script:StateDirectory
    } -ArgumentList @($Name)
}

function Get-CodexActiveProfile {
    [CmdletBinding()]
    param()

    return Read-ActiveProfileState -StateDirectory $script:StateDirectory
}

function Invoke-TestCodexActiveIdentity {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexHome,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [object[]]$ProcessData,

        [switch]$UseProvidedProcessData
    )

    $authBytes = $null
    try {
        Assert-CodexNotRunning -ProcessData $ProcessData `
            -UseProvidedProcessData:$UseProvidedProcessData
        $null = Assert-CodexFileCredentialSource -CodexHome $CodexHome
        $activeState = Read-ActiveProfileState -StateDirectory $StateDirectory
        $authPath = Join-Path -Path $CodexHome -ChildPath 'auth.json'
        $authBytes = Read-SensitiveFileBytes -Path $authPath
        $null = Test-CodexAuthBytes -Bytes $authBytes
        $null = Assert-CodexAuthMatchesProfileIdentity `
            -Name ([string]$activeState.ActiveProfile) `
            -AuthBytes $authBytes -ProfilesDirectory $ProfilesDirectory `
            -MismatchCode 'ACTIVE_PROFILE_IDENTITY_MISMATCH'
        return [pscustomobject]@{
            Result = 'ACTIVE_IDENTITY_CONFIRMED'
        }
    }
    catch {
        $safeCodes = @(
            'ACTIVE_PROFILE_IDENTITY_MISMATCH',
            'ACTIVE_PROFILE_NOT_INITIALIZED',
            'PROFILE_IDENTITY_MARKER_MISSING',
            'PROFILE_IDENTITY_MARKER_INVALID',
            'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED',
            'PROFILE_IDENTITY_SCHEMA_UNRECOGNIZED',
            'AUTH_CREDENTIAL_SOURCE_UNSUPPORTED',
            'AUTH_CREDENTIAL_SOURCE_AMBIGUOUS',
            'AUTH_CREDENTIAL_SOURCE_UNKNOWN',
            'CODEX_PROCESS_RUNNING',
            'CODEX_PROCESS_STATE_UNKNOWN'
        )
        $code = [string]$_.Exception.Message
        if (-not ($safeCodes -ccontains $code)) {
            $code = 'ACTIVE_IDENTITY_CHECK_FAILED'
        }
        return [pscustomobject]@{
            Result = $code
        }
    }
    finally {
        if ($null -ne $authBytes -and $authBytes.Length -gt 0) {
            [Array]::Clear($authBytes, 0, $authBytes.Length)
        }
    }
}

function Test-CodexActiveIdentity {
    [CmdletBinding()]
    param()

    return Invoke-WithCodexWriteLock -Operation {
        $codexHome = Get-CodexHome
        Invoke-TestCodexActiveIdentity -CodexHome $codexHome `
            -ProfilesDirectory $script:ProfilesDirectory `
            -StateDirectory $script:StateDirectory
    }
}

function Invoke-CodexAccountSwitch {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$CodexHome,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [object[]]$ProcessData,

        [switch]$UseProvidedProcessData,

        [switch]$SimulatePostReplaceVerificationFailure
    )

    $currentAuthBytes = $null
    $targetAuthBytes = $null
    $writtenAuthBytes = $null
    $rollbackAuthBytes = $null
    $rollbackWrittenBytes = $null
    $authWasReplaced = $false
    $stateWasCommitted = $false
    $activeName = $null
    $targetName = ConvertTo-SafeProfileName -Name $Name
    $currentContext = $null
    $targetContext = $null
    $diagnosticActiveName = 'Unknown'
    try {
        $diagnosticActiveName = [string](
            Read-ActiveProfileState -StateDirectory $StateDirectory
        ).ActiveProfile
    }
    catch { }
    Write-QiehaoDiagnosticEvent -Event 'SWITCH_START' -Result 'STARTED' `
        -Data @{
            ActiveProfile = $diagnosticActiveName
            TargetProfile = $targetName
        }

    try {
        Assert-CodexNotRunning -ProcessData $ProcessData `
            -UseProvidedProcessData:$UseProvidedProcessData `
            -DiagnosticOperation 'SWITCH'
        $null = Assert-CodexFileCredentialSource -CodexHome $CodexHome

        $activeState = Read-ActiveProfileState -StateDirectory $StateDirectory
        $activeName = $activeState.ActiveProfile
        $authPath = Join-Path -Path $CodexHome -ChildPath 'auth.json'
        if ($activeName -ceq $targetName) {
            $currentAuthBytes = Read-SensitiveFileBytes -Path $authPath
            $null = Test-CodexAuthBytes -Bytes $currentAuthBytes
            try {
                $null = Assert-CodexAuthMatchesProfileIdentity `
                    -Name $activeName -AuthBytes $currentAuthBytes `
                    -ProfilesDirectory $ProfilesDirectory
            }
            catch [System.InvalidOperationException] {
                if ($_.Exception.Message -ceq
                        'ACTIVE_PROFILE_IDENTITY_MISMATCH') {
                    throw (New-SafeException `
                        -Code 'ACTIVE_PROFILE_OUT_OF_SYNC')
                }
                throw
            }
            throw (New-SafeException -Code 'ALREADY_ACTIVE')
        }

        # Preserve the freshest current credentials before attempting to use
        # the target slot; Codex may have refreshed OAuth data while running.
        $currentAuthBytes = Read-SensitiveFileBytes -Path $authPath
        $null = Test-CodexAuthBytes -Bytes $currentAuthBytes
        $currentContext = Get-CodexAuthIdentityContext `
            -Bytes $currentAuthBytes
        $currentIdentityHash = Get-QiehaoDiagnosticIdentityHash `
            -IdentityBytes $currentContext.AccountIdBytes
        Write-QiehaoDiagnosticEvent -Event 'WORKSPACE_DETECT' `
            -Result ([string]$currentContext.WorkspaceClaimStatus) -Data @{
                Role = 'SWITCH_CURRENT_AUTH'
                WorkspaceType = [string]$currentContext.WorkspaceClass
                IdentityHash = $currentIdentityHash
                ParseResult = [string]$currentContext.WorkspaceClaimStatus
            }
        # Never trust the active profile label by itself. This identity check is
        # intentionally before the first write to the active slot, preventing a
        # manual Codex sign-out/sign-in from contaminating another profile.
        $null = Assert-CodexAuthMatchesProfileIdentity -Name $activeName `
            -AuthBytes $currentAuthBytes -ProfilesDirectory $ProfilesDirectory
        $null = Write-CodexAccountSlotBytes -Name $activeName `
            -AuthBytes $currentAuthBytes -ProfilesDirectory $ProfilesDirectory -Force

        # Fully decrypt and validate the target before changing auth.json.
        $targetAuthBytes = Read-CodexAccountSlotBytes -Name $targetName `
            -ProfilesDirectory $ProfilesDirectory
        $null = Assert-CodexAuthMatchesProfileIdentity -Name $targetName `
            -AuthBytes $targetAuthBytes -ProfilesDirectory $ProfilesDirectory `
            -MismatchCode 'PROFILE_IDENTITY_MISMATCH'
        $targetContext = Get-CodexAuthIdentityContext -Bytes $targetAuthBytes
        $targetIdentityHash = Get-QiehaoDiagnosticIdentityHash `
            -IdentityBytes $targetContext.AccountIdBytes
        Write-QiehaoDiagnosticEvent -Event 'WORKSPACE_DETECT' `
            -Result ([string]$targetContext.WorkspaceClaimStatus) -Data @{
                Role = 'SWITCH_TARGET_PROFILE'
                WorkspaceType = [string]$targetContext.WorkspaceClass
                IdentityHash = $targetIdentityHash
                ParseResult = [string]$targetContext.WorkspaceClaimStatus
            }

        Write-CodexAuthFileBytes -AuthPath $authPath -AuthBytes $targetAuthBytes
        $authWasReplaced = $true
        Write-QiehaoDiagnosticEvent -Event 'AUTH_REPLACE' `
            -Result 'SUCCESS' -Data @{
                ActiveProfile = $activeName
                TargetProfile = $targetName
                IdentityHash = $targetIdentityHash
            }

        if ($SimulatePostReplaceVerificationFailure) {
            throw (New-SafeException -Code 'SWITCH_POST_REPLACE_VERIFICATION_FAILED')
        }

        $writtenAuthBytes = Read-SensitiveFileBytes -Path $authPath
        $null = Test-CodexAuthBytes -Bytes $writtenAuthBytes
        if (-not (Test-ByteArraysEqual -Left $targetAuthBytes -Right $writtenAuthBytes)) {
            throw (New-SafeException -Code 'SWITCH_POST_REPLACE_VERIFICATION_FAILED')
        }

        Write-QiehaoDiagnosticEvent -Event 'READBACK_VERIFY' `
            -Result 'SUCCESS' -Data @{
                TargetProfile = $targetName
                IdentityHash = $targetIdentityHash
            }

        # This is deliberately the final durable state change.
        Write-ActiveProfileState -Name $targetName -StateDirectory $StateDirectory
        $stateWasCommitted = $true
        Write-QiehaoDiagnosticEvent -Event 'SWITCH_SUCCESS' `
            -Result 'SWITCH_SUCCESS' -Data @{
                ActiveProfile = $activeName
                TargetProfile = $targetName
                WorkspaceType = [string]$targetContext.WorkspaceClass
                IdentityHash = $targetIdentityHash
            }

        return [pscustomobject]@{
            Result = 'SWITCH_SUCCESS'
            From = $activeName
            To = $targetName
        }
    }
    catch {
        if ($authWasReplaced -and -not $stateWasCommitted) {
            $rollbackSucceeded = $false
            try {
                # Roll back from the just-updated active slot, not from a stale
                # in-memory assumption about the previous auth file.
                $rollbackAuthBytes = Read-CodexAccountSlotBytes -Name $activeName `
                    -ProfilesDirectory $ProfilesDirectory
                $authPath = Join-Path -Path $CodexHome -ChildPath 'auth.json'
                Write-CodexAuthFileBytes -AuthPath $authPath -AuthBytes $rollbackAuthBytes
                $rollbackWrittenBytes = Read-SensitiveFileBytes -Path $authPath
                $null = Test-CodexAuthBytes -Bytes $rollbackWrittenBytes
                $rollbackSucceeded = Test-ByteArraysEqual `
                    -Left $rollbackAuthBytes -Right $rollbackWrittenBytes
            }
            catch {
                $rollbackSucceeded = $false
            }

            if ($rollbackSucceeded) {
                Write-QiehaoDiagnosticEvent -Event 'SWITCH_FAILED' `
                    -Level 'ERROR' -Result 'SWITCH_FAILED_ROLLED_BACK' `
                    -Data @{
                        ActiveProfile = $diagnosticActiveName
                        TargetProfile = $targetName
                        ResultCode = 'SWITCH_FAILED_ROLLED_BACK'
                    }
                throw (New-SafeException -Code 'SWITCH_FAILED_ROLLED_BACK')
            }
            Write-QiehaoDiagnosticEvent -Event 'SWITCH_FAILED' `
                -Level 'ERROR' -Result 'SWITCH_ROLLBACK_FAILED' `
                -Data @{
                    ActiveProfile = $diagnosticActiveName
                    TargetProfile = $targetName
                    ResultCode = 'SWITCH_ROLLBACK_FAILED'
                }
            throw (New-SafeException -Code 'SWITCH_ROLLBACK_FAILED')
        }

        $switchFailureCode = if ($_.Exception.Message -match `
            '^[A-Z][A-Z0-9_]+$') { $_.Exception.Message }
            else { 'SWITCH_FAILED' }
        Write-QiehaoDiagnosticEvent -Event 'SWITCH_FAILED' `
            -Level 'ERROR' -Result $switchFailureCode -Data @{
                ActiveProfile = $diagnosticActiveName
                TargetProfile = $targetName
                ResultCode = $switchFailureCode
            }
        if ($_.Exception.Message -match '^[A-Z][A-Z0-9_]+$') {
            throw
        }
        throw (New-SafeException -Code 'SWITCH_FAILED')
    }
    finally {
        foreach ($buffer in @(
            $currentAuthBytes,
            $targetAuthBytes,
            $writtenAuthBytes,
            $rollbackAuthBytes,
            $rollbackWrittenBytes
        )) {
            if ($null -ne $buffer -and $buffer.Length -gt 0) {
                [Array]::Clear($buffer, 0, $buffer.Length)
            }
        }
        Clear-CodexAuthIdentityContext -Context $currentContext
        Clear-CodexAuthIdentityContext -Context $targetContext
    }
}

function Invoke-SyncCodexActiveProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$CodexHome,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [object[]]$ProcessData,

        [switch]$UseProvidedProcessData
    )

    $currentAuthBytes = $null
    $currentIdentityBytes = $null
    $profileAuthBytes = $null
    $metadataState = $null
    try {
        Assert-CodexNotRunning -ProcessData $ProcessData `
            -UseProvidedProcessData:$UseProvidedProcessData
        $null = Assert-CodexFileCredentialSource -CodexHome $CodexHome
        $activeState = Read-ActiveProfileState -StateDirectory $StateDirectory
        $authPath = Join-Path -Path $CodexHome -ChildPath 'auth.json'
        $currentAuthBytes = Read-SensitiveFileBytes -Path $authPath
        $null = Test-CodexAuthBytes -Bytes $currentAuthBytes
        $currentIdentityBytes = Get-CodexAuthIdentityBytes `
            -Bytes $currentAuthBytes
        $identityMatch = Test-ProfileIdentityExists `
            -IdentityBytes $currentIdentityBytes -AuthBytes $currentAuthBytes `
            -ProfilesDirectory $ProfilesDirectory
        if (-not $identityMatch.Exists) {
            throw (New-SafeException `
                -Code 'ACTIVE_PROFILE_IDENTITY_MISMATCH')
        }

        $matchedProfile = ConvertTo-SafeProfileName `
            -Name ([string]$identityMatch.Profile)
        $paths = Get-StrictProfileArtifactPaths -Name $matchedProfile `
            -ProfilesDirectory $ProfilesDirectory
        if (-not [System.IO.File]::Exists($paths.EncryptedPath) -or
            -not [System.IO.File]::Exists($paths.IdentityMarkerPath) -or
            -not [System.IO.File]::Exists($paths.MetadataPath)) {
            throw (New-SafeException -Code 'PROFILE_INCOMPLETE')
        }
        $metadataState = Get-ProfileMetadataState -Name $matchedProfile `
            -ProfilesDirectory $ProfilesDirectory
        if (-not $metadataState.IsValid) {
            throw (New-SafeException -Code 'PROFILE_METADATA_INVALID')
        }
        $profileAuthBytes = Read-CodexAccountSlotBytes -Name $matchedProfile `
            -ProfilesDirectory $ProfilesDirectory
        $null = Assert-CodexAuthMatchesProfileIdentity -Name $matchedProfile `
            -AuthBytes $profileAuthBytes `
            -ProfilesDirectory $ProfilesDirectory `
            -MismatchCode 'PROFILE_IDENTITY_MISMATCH'
        $null = Assert-CodexAuthMatchesProfileIdentity -Name $matchedProfile `
            -AuthBytes $currentAuthBytes `
            -ProfilesDirectory $ProfilesDirectory `
            -MismatchCode 'ACTIVE_PROFILE_IDENTITY_MISMATCH'

        if ($activeState.ActiveProfile.Equals(
                $matchedProfile,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            return [pscustomobject]@{
                Result = 'ALREADY_ACTIVE'
                ActiveProfile = $matchedProfile
            }
        }

        # Recovery commits only the non-secret Active state. It never rewrites
        # auth.json or any saved Profile artifact.
        Write-ActiveProfileState -Name $matchedProfile `
            -StateDirectory $StateDirectory
        $readBackState = Read-ActiveProfileState `
            -StateDirectory $StateDirectory
        if (-not $readBackState.ActiveProfile.Equals(
                $matchedProfile,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw (New-SafeException -Code 'ACTIVE_PROFILE_SYNC_FAILED')
        }
        return [pscustomobject]@{
            Result = 'ACTIVE_PROFILE_SYNCED'
            From = [string]$activeState.ActiveProfile
            ActiveProfile = $matchedProfile
        }
    }
    catch [System.InvalidOperationException] {
        throw
    }
    catch {
        throw (New-SafeException -Code 'ACTIVE_PROFILE_SYNC_FAILED')
    }
    finally {
        foreach ($buffer in @(
            $currentAuthBytes,
            $currentIdentityBytes,
            $profileAuthBytes
        )) {
            if ($null -ne $buffer -and $buffer.Length -gt 0) {
                [Array]::Clear($buffer, 0, $buffer.Length)
            }
        }
        $metadataState = $null
    }
}

function Sync-CodexActiveProfile {
    [CmdletBinding()]
    param()

    return Invoke-WithCodexWriteLock -Operation {
        $codexHome = Get-CodexHome
        Invoke-SyncCodexActiveProfile -CodexHome $codexHome `
            -ProfilesDirectory $script:ProfilesDirectory `
            -StateDirectory $script:StateDirectory
    }
}

function Switch-CodexAccountProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name
    )

    return Invoke-WithCodexWriteLock -Operation {
        param($LockedName)
        $codexHome = Get-CodexHome
        Invoke-CodexAccountSwitch -Name $LockedName -CodexHome $codexHome `
            -ProfilesDirectory $script:ProfilesDirectory -StateDirectory $script:StateDirectory
    } -ArgumentList @($Name)
}

function Remove-NewProfileArtifactsBestEffort {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Paths
    )

    $failedTypes = @()
    foreach ($artifact in @(
        [pscustomobject]@{ Type = 'Metadata'; Path = $Paths.MetadataPath },
        [pscustomobject]@{ Type = 'IdentityMarker'; Path = $Paths.IdentityMarkerPath },
        [pscustomobject]@{ Type = 'AuthFile'; Path = $Paths.EncryptedPath }
    )) {
        try {
            if ([System.IO.File]::Exists($artifact.Path)) {
                [System.IO.File]::Delete($artifact.Path)
            }
        }
        catch {
            $failedTypes += $artifact.Type
        }
    }
    return @($failedTypes)
}

function Invoke-AddCodexProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$CodexHome,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [object[]]$ProcessData,

        [switch]$UseProvidedProcessData
    )

    $authBytes = $null
    $identityBytes = $null
    $readBackBytes = $null
    $writeAttempted = $false
    $stateCommitted = $false
    $paths = $null
    $identityContext = $null
    Write-QiehaoDiagnosticEvent -Event 'ADD_START' -Result 'STARTED' `
        -Data @{ Profile = $Name }
    try {
        Assert-CodexNotRunning -ProcessData $ProcessData `
            -UseProvidedProcessData:$UseProvidedProcessData `
            -DiagnosticOperation 'ADD'
        $credentialSource = Assert-CodexFileCredentialSource `
            -CodexHome $CodexHome
        $safeName = ConvertTo-SafeProfileName -Name $Name
        $paths = Get-StrictProfileArtifactPaths -Name $safeName `
            -ProfilesDirectory $ProfilesDirectory
        if (Test-AnyProfileArtifactExists -Paths $paths) {
            throw (New-SafeException -Code 'PROFILE_NAME_ALREADY_EXISTS')
        }

        $authPath = Join-Path -Path $CodexHome -ChildPath 'auth.json'
        $authBytes = Read-SensitiveFileBytes -Path $authPath
        Write-QiehaoDiagnosticEvent -Event 'ADD_AUTH_FOUND' `
            -Result 'AUTH_FILE_READ' -Data @{
                Profile = $safeName
                CredentialSource = [string]$credentialSource.Source
            }
        $null = Test-CodexAuthBytes -Bytes $authBytes
        $identityBytes = Get-CodexAuthIdentityBytes -Bytes $authBytes
        $identityContext = Get-CodexAuthIdentityContext -Bytes $authBytes
        $identityHash = Get-QiehaoDiagnosticIdentityHash `
            -IdentityBytes $identityBytes
        Write-QiehaoDiagnosticEvent -Event 'ADD_IDENTITY_PARSE' `
            -Result 'SUCCESS' -Data @{
                Profile = $safeName
                ParseResult = 'SUCCESS'
                WorkspaceType = [string]$identityContext.WorkspaceClass
                IdentityHash = $identityHash
            }
        Write-QiehaoDiagnosticEvent -Event 'WORKSPACE_DETECT' `
            -Result ([string]$identityContext.WorkspaceClaimStatus) -Data @{
                Role = 'ADD_CURRENT_AUTH'
                WorkspaceType = [string]$identityContext.WorkspaceClass
                IdentityHash = $identityHash
                ParseResult = [string]$identityContext.WorkspaceClaimStatus
            }
        $identityMatch = Test-ProfileIdentityExists -IdentityBytes $identityBytes `
            -AuthBytes $authBytes `
            -ProfilesDirectory $ProfilesDirectory
        if ($identityMatch.Exists) {
            $duplicateException = New-SafeException `
                -Code 'PROFILE_IDENTITY_ALREADY_EXISTS'
            $duplicateException.Data['ExistingProfile'] = $identityMatch.Profile
            throw $duplicateException
        }

        $writeAttempted = $true
        $null = Write-CodexAccountSlotBytes -Name $safeName -AuthBytes $authBytes `
            -ProfilesDirectory $ProfilesDirectory
        $readBackBytes = Read-CodexAccountSlotBytes -Name $safeName `
            -ProfilesDirectory $ProfilesDirectory
        if (-not (Test-ByteArraysEqual -Left $authBytes -Right $readBackBytes)) {
            throw (New-SafeException -Code 'PROFILE_ADD_VERIFICATION_FAILED')
        }
        $null = Assert-CodexAuthMatchesProfileIdentity -Name $safeName `
            -AuthBytes $readBackBytes -ProfilesDirectory $ProfilesDirectory `
            -MismatchCode 'PROFILE_IDENTITY_MISMATCH'

        # The user has explicitly logged this identity into Codex. Commit the
        # non-secret active state only after all three new artifacts verify.
        Write-ActiveProfileState -Name $safeName -StateDirectory $StateDirectory
        $stateCommitted = $true
        Write-QiehaoDiagnosticEvent -Event 'ADD_SUCCESS' `
            -Result 'PROFILE_ADD_SUCCESS' -Data @{
                Profile = $safeName
                WorkspaceType = [string]$identityContext.WorkspaceClass
                IdentityHash = $identityHash
            }
        return [pscustomobject]@{
            Result = 'PROFILE_ADD_SUCCESS'
            Profile = $safeName
        }
    }
    catch {
        $originalException = $_.Exception
        if ($writeAttempted -and -not $stateCommitted -and $null -ne $paths) {
            $cleanupFailures = @(Remove-NewProfileArtifactsBestEffort -Paths $paths)
            if ($cleanupFailures.Count -gt 0) {
                Write-QiehaoDiagnosticEvent -Event 'ADD_FAILED' `
                    -Level 'ERROR' -Result 'PROFILE_ADD_ROLLBACK_FAILED' `
                    -Data @{ Profile = $Name; ResultCode = 'PROFILE_ADD_ROLLBACK_FAILED' }
                throw (New-SafeException -Code 'PROFILE_ADD_ROLLBACK_FAILED')
            }
        }
        $failureCode = if ($originalException.Message -match `
            '^[A-Z][A-Z0-9_]+$') { $originalException.Message }
            else { 'PROFILE_ADD_FAILED' }
        Write-QiehaoDiagnosticEvent -Event 'ADD_FAILED' -Level 'ERROR' `
            -Result $failureCode -Data @{
                Profile = $Name
                ResultCode = $failureCode
            }
        if ($originalException.Message -match '^[A-Z][A-Z0-9_]+$') {
            throw $originalException
        }
        throw (New-SafeException -Code 'PROFILE_ADD_FAILED')
    }
    finally {
        foreach ($buffer in @($authBytes, $identityBytes, $readBackBytes)) {
            if ($null -ne $buffer -and $buffer.Length -gt 0) {
                [Array]::Clear($buffer, 0, $buffer.Length)
            }
        }
        Clear-CodexAuthIdentityContext -Context $identityContext
    }
}

function Add-CodexProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name
    )

    return Invoke-WithCodexWriteLock -Operation {
        param($LockedName)
        $codexHome = Get-CodexHome
        Invoke-AddCodexProfile -Name $LockedName -CodexHome $codexHome `
            -ProfilesDirectory $script:ProfilesDirectory `
            -StateDirectory $script:StateDirectory
    } -ArgumentList @($Name)
}

function Get-ProfileDeleteTrashRoot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [switch]$Create
    )

    if (-not [System.IO.Directory]::Exists($ProfilesDirectory)) {
        throw (New-SafeException -Code 'PROFILES_DIRECTORY_NOT_FOUND')
    }
    $profilesRoot = [System.IO.Path]::GetFullPath($ProfilesDirectory).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $trashRoot = [System.IO.Path]::GetFullPath(
        (Join-Path -Path $profilesRoot -ChildPath $script:ProfileDeleteTrashDirectoryName)
    )
    if (-not [System.IO.Path]::GetDirectoryName($trashRoot).Equals(
            $profilesRoot,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw (New-SafeException -Code 'PROFILE_DELETE_QUARANTINE_UNSAFE')
    }
    if ([System.IO.File]::Exists($trashRoot)) {
        throw (New-SafeException -Code 'PROFILE_DELETE_QUARANTINE_UNSAFE')
    }
    if (-not [System.IO.Directory]::Exists($trashRoot)) {
        if (-not $Create) {
            return $trashRoot
        }
        [System.IO.Directory]::CreateDirectory($trashRoot) | Out-Null
    }
    $trashInfo = Get-Item -LiteralPath $trashRoot -Force -ErrorAction Stop
    if (($trashInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw (New-SafeException -Code 'PROFILE_DELETE_QUARANTINE_UNSAFE')
    }
    return $trashRoot
}

function New-ProfileDeleteTransactionContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [string]$TransactionId
    )

    $safeName = ConvertTo-SafeProfileName -Name $Name
    if ([string]::IsNullOrWhiteSpace($TransactionId)) {
        $TransactionId = [Guid]::NewGuid().ToString('N')
    }
    if ($TransactionId -notmatch '^[0-9a-fA-F]{32}$') {
        throw (New-SafeException -Code 'PROFILE_DELETE_TRANSACTION_INVALID')
    }
    $trashRoot = Get-ProfileDeleteTrashRoot -ProfilesDirectory $ProfilesDirectory -Create
    $transactionName = $safeName + '-delete-' + $TransactionId.ToLowerInvariant()
    $transactionPath = [System.IO.Path]::GetFullPath(
        (Join-Path -Path $trashRoot -ChildPath $transactionName)
    )
    if (-not [System.IO.Path]::GetDirectoryName($transactionPath).Equals(
            $trashRoot,
            [StringComparison]::OrdinalIgnoreCase
        )) {
        throw (New-SafeException -Code 'PROFILE_DELETE_QUARANTINE_UNSAFE')
    }
    if ([System.IO.File]::Exists($transactionPath) -or
        [System.IO.Directory]::Exists($transactionPath)) {
        throw (New-SafeException -Code 'PROFILE_DELETE_TRANSACTION_EXISTS')
    }
    [System.IO.Directory]::CreateDirectory($transactionPath) | Out-Null
    $transactionInfo = Get-Item -LiteralPath $transactionPath -Force -ErrorAction Stop
    if (($transactionInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw (New-SafeException -Code 'PROFILE_DELETE_QUARANTINE_UNSAFE')
    }

    return Get-ProfileDeleteTransactionContext -Name $safeName `
        -ProfilesDirectory $ProfilesDirectory -TransactionPath $transactionPath
}

function Get-ProfileDeleteTransactionContext {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [Parameter(Mandatory = $true)]
        [string]$TransactionPath
    )

    $safeName = ConvertTo-SafeProfileName -Name $Name
    $paths = Get-StrictProfileArtifactPaths -Name $safeName `
        -ProfilesDirectory $ProfilesDirectory
    $transactionFullPath = [System.IO.Path]::GetFullPath($TransactionPath)
    $transactionInfo = Get-Item -LiteralPath $transactionFullPath -Force -ErrorAction Stop
    if (-not $transactionInfo.PSIsContainer -or
        ($transactionInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw (New-SafeException -Code 'PROFILE_DELETE_QUARANTINE_UNSAFE')
    }

    $artifacts = @(
        [pscustomobject]@{
            Type = 'AuthFile'
            SourcePath = $paths.EncryptedPath
            QuarantinePath = Join-Path $transactionFullPath 'auth.dpapi'
        },
        [pscustomobject]@{
            Type = 'IdentityMarker'
            SourcePath = $paths.IdentityMarkerPath
            QuarantinePath = Join-Path $transactionFullPath 'identity.dpapi'
        },
        [pscustomobject]@{
            Type = 'Metadata'
            SourcePath = $paths.MetadataPath
            QuarantinePath = Join-Path $transactionFullPath 'meta.json'
        }
    )
    foreach ($artifact in $artifacts) {
        if ([System.IO.File]::Exists($artifact.QuarantinePath)) {
            $quarantineInfo = Get-Item -LiteralPath $artifact.QuarantinePath `
                -Force -ErrorAction Stop
            if (($quarantineInfo.Attributes -band `
                    [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw (New-SafeException -Code 'PROFILE_DELETE_QUARANTINE_UNSAFE')
            }
        }
    }
    $trashRoot = [System.IO.Path]::GetDirectoryName($transactionFullPath)
    $transactionName = [System.IO.Path]::GetFileName($transactionFullPath)
    $commitMarkerPath = Join-Path $trashRoot (
        $transactionName + $script:ProfileDeleteCommitMarkerSuffix
    )
    if ([System.IO.File]::Exists($commitMarkerPath)) {
        $commitMarkerInfo = Get-Item -LiteralPath $commitMarkerPath `
            -Force -ErrorAction Stop
        if (($commitMarkerInfo.Attributes -band `
                [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw (New-SafeException -Code 'PROFILE_DELETE_QUARANTINE_UNSAFE')
        }
    }
    return [pscustomobject]@{
        Profile = $safeName
        TransactionPath = $transactionFullPath
        CommitMarkerPath = $commitMarkerPath
        Artifacts = $artifacts
    }
}

function Get-ExistingProfileDeleteTransactionContext {
    param(
        [Parameter(Mandatory = $true)]
        [System.IO.DirectoryInfo]$Directory,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory
    )

    if (($Directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw (New-SafeException -Code 'PROFILE_DELETE_QUARANTINE_UNSAFE')
    }
    $match = [regex]::Match(
        $Directory.Name,
        '^(?<profile>.+)-delete-(?<transaction>[0-9a-fA-F]{32})$'
    )
    if (-not $match.Success -or
        -not (Test-SafeProfileFileStem -Name $match.Groups['profile'].Value)) {
        throw (New-SafeException -Code 'PROFILE_DELETE_TRANSACTION_INVALID')
    }
    return Get-ProfileDeleteTransactionContext `
        -Name $match.Groups['profile'].Value `
        -ProfilesDirectory $ProfilesDirectory `
        -TransactionPath $Directory.FullName
}

function Test-ProfileDeleteCommitMarker {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not [System.IO.File]::Exists($Path)) {
        return $false
    }
    try {
        return [System.IO.File]::ReadAllText($Path) -ceq `
            $script:ProfileDeleteCommitMarkerContent
    }
    catch {
        return $false
    }
}

function Invoke-ProfileDeleteRollback {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context,

        [ValidateSet('', 'AuthFile', 'IdentityMarker', 'Metadata')]
        [string]$SimulateRollbackFailureType = ''
    )

    $failedTypes = New-Object System.Collections.ArrayList
    $artifacts = @($Context.Artifacts)
    [array]::Reverse($artifacts)
    foreach ($artifact in $artifacts) {
        $sourceExists = [System.IO.File]::Exists($artifact.SourcePath)
        $quarantineExists = [System.IO.File]::Exists($artifact.QuarantinePath)
        if ($sourceExists -and $quarantineExists) {
            [void]$failedTypes.Add($artifact.Type)
            continue
        }
        if (-not $sourceExists -and -not $quarantineExists) {
            [void]$failedTypes.Add($artifact.Type)
            continue
        }
        if ($sourceExists) {
            continue
        }
        try {
            if ($artifact.Type -ceq $SimulateRollbackFailureType) {
                throw (New-Object System.IO.IOException('SIMULATED_ROLLBACK_FAILURE'))
            }
            [System.IO.File]::Move($artifact.QuarantinePath, $artifact.SourcePath)
            if (-not [System.IO.File]::Exists($artifact.SourcePath) -or
                [System.IO.File]::Exists($artifact.QuarantinePath)) {
                throw (New-Object System.IO.IOException('ROLLBACK_DID_NOT_COMPLETE'))
            }
        }
        catch {
            [void]$failedTypes.Add($artifact.Type)
        }
    }

    if ($failedTypes.Count -eq 0) {
        try {
            $expectedNames = @($Context.Artifacts | ForEach-Object {
                    [System.IO.Path]::GetFileName($_.QuarantinePath)
                })
            $unexpectedEntries = @(
                Get-ChildItem -LiteralPath $Context.TransactionPath -Force `
                    -ErrorAction Stop |
                    Where-Object { $expectedNames -cnotcontains $_.Name }
            )
            if ($unexpectedEntries.Count -gt 0) {
                throw (New-Object System.IO.IOException(
                    'UNEXPECTED_QUARANTINE_ENTRY'
                ))
            }
            if ([System.IO.File]::Exists($Context.CommitMarkerPath)) {
                [System.IO.File]::Delete($Context.CommitMarkerPath)
            }
            if (@([System.IO.Directory]::GetFileSystemEntries(
                        $Context.TransactionPath
                    )).Count -eq 0) {
                [System.IO.Directory]::Delete($Context.TransactionPath, $false)
            }
        }
        catch {
            [void]$failedTypes.Add('TransactionCleanup')
        }
    }

    return [pscustomobject]@{
        Succeeded = $failedTypes.Count -eq 0
        FailedFileTypes = @($failedTypes)
    }
}

function Invoke-ProfileDeleteQuarantineCleanup {
    param(
        [Parameter(Mandatory = $true)]
        [object]$Context,

        [ValidateSet('', 'AuthFile', 'IdentityMarker', 'Metadata')]
        [string]$SimulateCleanupFailureType = ''
    )

    $failedTypes = New-Object System.Collections.ArrayList
    foreach ($artifact in @($Context.Artifacts)) {
        if (-not [System.IO.File]::Exists($artifact.QuarantinePath)) {
            continue
        }
        try {
            if ($artifact.Type -ceq $SimulateCleanupFailureType) {
                throw (New-Object System.IO.IOException('SIMULATED_CLEANUP_FAILURE'))
            }
            [System.IO.File]::Delete($artifact.QuarantinePath)
            if ([System.IO.File]::Exists($artifact.QuarantinePath)) {
                throw (New-Object System.IO.IOException('CLEANUP_DID_NOT_COMPLETE'))
            }
        }
        catch {
            [void]$failedTypes.Add($artifact.Type)
        }
    }

    if ($failedTypes.Count -eq 0) {
        try {
            $unexpectedEntries = @(
                Get-ChildItem -LiteralPath $Context.TransactionPath -Force `
                    -ErrorAction Stop
            )
            if ($unexpectedEntries.Count -gt 0) {
                throw (New-Object System.IO.IOException('UNEXPECTED_QUARANTINE_ENTRY'))
            }
            [System.IO.Directory]::Delete($Context.TransactionPath, $false)
            if ([System.IO.File]::Exists($Context.CommitMarkerPath)) {
                [System.IO.File]::Delete($Context.CommitMarkerPath)
                if ([System.IO.File]::Exists($Context.CommitMarkerPath)) {
                    throw (New-Object System.IO.IOException(
                        'COMMIT_MARKER_CLEANUP_DID_NOT_COMPLETE'
                    ))
                }
            }
        }
        catch {
            [void]$failedTypes.Add('TransactionCleanup')
        }
    }

    return [pscustomobject]@{
        Succeeded = $failedTypes.Count -eq 0
        FailedFileTypes = @($failedTypes)
    }
}

function Invoke-RecoverCodexProfileDeleteTransactionsUnlocked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory
    )

    $trashRoot = Get-ProfileDeleteTrashRoot -ProfilesDirectory $ProfilesDirectory
    if (-not [System.IO.Directory]::Exists($trashRoot)) {
        return [pscustomobject]@{
            RestoredTransactions = 0
            CompletedTransactions = 0
            CleanupPending = 0
            WarningCodes = @()
        }
    }

    $commitMarkerFiles = @(
        Get-ChildItem -LiteralPath $trashRoot -File -Force -ErrorAction Stop
    )
    foreach ($markerFile in $commitMarkerFiles) {
        if (($markerFile.Attributes -band `
                [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw (New-SafeException -Code 'PROFILE_DELETE_QUARANTINE_UNSAFE')
        }
        $markerMatch = [regex]::Match(
            $markerFile.Name,
            '^(?<profile>.+)-delete-(?<transaction>[0-9a-fA-F]{32})\.committed$'
        )
        if (-not $markerMatch.Success -or
            -not (Test-SafeProfileFileStem `
                -Name $markerMatch.Groups['profile'].Value)) {
            throw (New-SafeException -Code 'PROFILE_DELETE_RECOVERY_UNSAFE')
        }
    }

    $transactionDirectories = @(
        Get-ChildItem -LiteralPath $trashRoot -Directory -Force -ErrorAction Stop
    )
    $initialTransactionNames = @(
        $transactionDirectories | ForEach-Object { $_.Name }
    )
    if ($transactionDirectories.Count -eq 0 -and
        $commitMarkerFiles.Count -eq 0) {
        return [pscustomobject]@{
            RestoredTransactions = 0
            CompletedTransactions = 0
            CleanupPending = 0
            WarningCodes = @()
        }
    }

    # An absent Active state is valid before the first account is initialized.
    # Any malformed existing state still fails closed before recovery.
    $activeState = $null
    try {
        $activeState = Read-ActiveProfileState -StateDirectory $StateDirectory
    }
    catch [System.InvalidOperationException] {
        if ($_.Exception.Message -cne 'ACTIVE_PROFILE_NOT_INITIALIZED') {
            throw
        }
    }

    $restored = 0
    $completed = 0
    $pending = 0
    $warnings = New-Object System.Collections.ArrayList
    foreach ($directory in $transactionDirectories) {
        $context = Get-ExistingProfileDeleteTransactionContext `
            -Directory $directory -ProfilesDirectory $ProfilesDirectory
        if (Test-ProfileDeleteCommitMarker -Path $context.CommitMarkerPath) {
            if ($null -ne $activeState -and
                $activeState.ActiveProfile.Equals(
                    $context.Profile,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                throw (New-SafeException `
                    -Code 'PROFILE_DELETE_RECOVERY_ACTIVE_CONFLICT')
            }
            $cleanup = Invoke-ProfileDeleteQuarantineCleanup -Context $context
            if ($cleanup.Succeeded) {
                $completed++
            }
            else {
                $pending++
                [void]$warnings.Add('PROFILE_REMOVE_QUARANTINE_CLEANUP_FAILED')
            }
            continue
        }

        $rollback = Invoke-ProfileDeleteRollback -Context $context
        if (-not $rollback.Succeeded) {
            throw (New-SafeException -Code 'PROFILE_DELETE_RECOVERY_ROLLBACK_FAILED')
        }
        $restored++
    }

    # A committed marker can outlive its transaction directory only if all
    # quarantined files and the directory were already cleaned. Removing this
    # final sibling marker completes the transaction without any ambiguity.
    foreach ($markerFile in $commitMarkerFiles) {
        if (-not [System.IO.File]::Exists($markerFile.FullName)) {
            continue
        }
        $transactionName = $markerFile.Name.Substring(
            0,
            $markerFile.Name.Length - $script:ProfileDeleteCommitMarkerSuffix.Length
        )
        $transactionPath = Join-Path $trashRoot $transactionName
        if ($initialTransactionNames -ccontains $transactionName -or
            [System.IO.Directory]::Exists($transactionPath)) {
            continue
        }
        if (-not (Test-ProfileDeleteCommitMarker -Path $markerFile.FullName)) {
            throw (New-SafeException -Code 'PROFILE_DELETE_RECOVERY_UNSAFE')
        }
        $profileName = [regex]::Match(
            $transactionName,
            '^(?<profile>.+)-delete-[0-9a-fA-F]{32}$'
        ).Groups['profile'].Value
        if ($null -ne $activeState -and
            $activeState.ActiveProfile.Equals(
                $profileName,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            throw (New-SafeException `
                -Code 'PROFILE_DELETE_RECOVERY_ACTIVE_CONFLICT')
        }
        try {
            [System.IO.File]::Delete($markerFile.FullName)
            if ([System.IO.File]::Exists($markerFile.FullName)) {
                throw (New-Object System.IO.IOException(
                    'COMMIT_MARKER_CLEANUP_DID_NOT_COMPLETE'
                ))
            }
            $completed++
        }
        catch {
            $pending++
            [void]$warnings.Add('PROFILE_REMOVE_QUARANTINE_CLEANUP_FAILED')
        }
    }

    return [pscustomobject]@{
        RestoredTransactions = $restored
        CompletedTransactions = $completed
        CleanupPending = $pending
        WarningCodes = @($warnings)
    }
}

function Invoke-RecoverCodexProfileDeleteTransactions {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [string]$MutexName = $script:WriteMutexName
    )

    return Invoke-WithCodexWriteLock -MutexName $MutexName -Operation {
        param($LockedProfiles, $LockedState)
        Invoke-RecoverCodexProfileDeleteTransactionsUnlocked `
            -ProfilesDirectory $LockedProfiles -StateDirectory $LockedState
    } -ArgumentList @($ProfilesDirectory, $StateDirectory)
}

function Invoke-GetCodexProfileDeleteSafety {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$CodexHome,
        [Parameter(Mandatory = $true)][string]$ProfilesDirectory,
        [Parameter(Mandatory = $true)][string]$StateDirectory,
        [object[]]$ProcessData,
        [switch]$UseProvidedProcessData
    )

    $currentAuthBytes = $null
    $currentIdentityBytes = $null
    try {
        Assert-CodexNotRunning -ProcessData $ProcessData `
            -UseProvidedProcessData:$UseProvidedProcessData `
            -DiagnosticOperation 'DELETE'
        $credentialSource = Assert-CodexFileCredentialSource `
            -CodexHome $CodexHome
        $safeName = ConvertTo-SafeProfileName -Name $Name
        $paths = Get-StrictProfileArtifactPaths -Name $safeName `
            -ProfilesDirectory $ProfilesDirectory
        if (-not (Test-AnyProfileArtifactExists -Paths $paths)) {
            throw (New-SafeException -Code 'PROFILE_NOT_FOUND')
        }
        if (-not [System.IO.File]::Exists($paths.EncryptedPath) -or
            -not [System.IO.File]::Exists($paths.IdentityMarkerPath) -or
            -not [System.IO.File]::Exists($paths.MetadataPath)) {
            throw (New-SafeException -Code 'PROFILE_INCOMPLETE')
        }
        $activeState = Read-ActiveProfileState -StateDirectory $StateDirectory
        $authPath = Join-Path -Path $CodexHome -ChildPath 'auth.json'
        $currentAuthBytes = Read-SensitiveFileBytes -Path $authPath
        $null = Test-CodexAuthBytes -Bytes $currentAuthBytes

        $targetComparison = Compare-CodexAuthToProfileIdentity `
            -Name $safeName -AuthBytes $currentAuthBytes `
            -ProfilesDirectory $ProfilesDirectory
        if ($targetComparison.Matches) {
            return [pscustomobject]@{
                Result = 'CANNOT_REMOVE_CURRENT_CODEX_PROFILE'
                Profile = $safeName
                ActiveProfile = [string]$activeState.ActiveProfile
                CurrentProfile = $safeName
                CredentialSource = [string]$credentialSource.Source
            }
        }

        $currentIdentityBytes = Get-CodexAuthIdentityBytes `
            -Bytes $currentAuthBytes
        $identityMatch = Test-ProfileIdentityExists `
            -IdentityBytes $currentIdentityBytes `
            -AuthBytes $currentAuthBytes `
            -ProfilesDirectory $ProfilesDirectory
        $currentProfile = if ($identityMatch.Exists) {
            [string]$identityMatch.Profile
        }
        else { $null }
        if ($activeState.ActiveProfile.Equals(
                $safeName,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            if ([string]::IsNullOrWhiteSpace($currentProfile)) {
                return [pscustomobject]@{
                    Result = 'PROFILE_DELETE_IDENTITY_UNKNOWN'
                    Profile = $safeName
                    ActiveProfile = [string]$activeState.ActiveProfile
                    CurrentProfile = $null
                    CredentialSource = [string]$credentialSource.Source
                }
            }
            return [pscustomobject]@{
                Result = 'PROFILE_DELETE_ACTIVE_OUT_OF_SYNC'
                Profile = $safeName
                ActiveProfile = [string]$activeState.ActiveProfile
                CurrentProfile = $currentProfile
                CredentialSource = [string]$credentialSource.Source
            }
        }
        return [pscustomobject]@{
            Result = 'PROFILE_DELETE_SAFE'
            Profile = $safeName
            ActiveProfile = [string]$activeState.ActiveProfile
            CurrentProfile = $currentProfile
            CredentialSource = [string]$credentialSource.Source
        }
    }
    finally {
        foreach ($buffer in @($currentAuthBytes, $currentIdentityBytes)) {
            if ($null -ne $buffer -and $buffer.Length -gt 0) {
                [Array]::Clear($buffer, 0, $buffer.Length)
            }
        }
    }
}

function Get-CodexProfileDeleteSafety {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name
    )

    return Invoke-WithCodexWriteLock -Operation {
        param($LockedName)
        $codexHome = Get-CodexHome
        Invoke-GetCodexProfileDeleteSafety -Name $LockedName `
            -CodexHome $codexHome `
            -ProfilesDirectory $script:ProfilesDirectory `
            -StateDirectory $script:StateDirectory
    } -ArgumentList @($Name)
}

function Invoke-RemoveCodexProfileUnlocked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [switch]$ConfirmDelete,

        [Alias('SimulateDeleteFailureType')]
        [ValidateSet('', 'AuthFile', 'IdentityMarker', 'Metadata')]
        [string]$SimulateMoveFailureType = '',

        [ValidateSet('', 'AuthFile', 'IdentityMarker', 'Metadata')]
        [string]$SimulateRollbackFailureType = '',

        [ValidateSet('', 'AuthFile', 'IdentityMarker', 'Metadata')]
        [string]$SimulateCleanupFailureType = '',

        [ValidateRange(0, 3)]
        [int]$SimulateInterruptionAfterMoveCount = 0
    )

    if (-not $ConfirmDelete) {
        throw (New-SafeException -Code 'PROFILE_REMOVE_CONFIRMATION_REQUIRED')
    }
    $safeName = ConvertTo-SafeProfileName -Name $Name
    $paths = Get-StrictProfileArtifactPaths -Name $safeName `
        -ProfilesDirectory $ProfilesDirectory
    if (-not (Test-AnyProfileArtifactExists -Paths $paths)) {
        throw (New-SafeException -Code 'PROFILE_NOT_FOUND')
    }

    $activeState = Read-ActiveProfileState -StateDirectory $StateDirectory
    if ($activeState.ActiveProfile.Equals($safeName, [StringComparison]::OrdinalIgnoreCase)) {
        throw (New-SafeException -Code 'CANNOT_REMOVE_ACTIVE_PROFILE')
    }

    if (-not [System.IO.File]::Exists($paths.EncryptedPath) -or
        -not [System.IO.File]::Exists($paths.IdentityMarkerPath) -or
        -not [System.IO.File]::Exists($paths.MetadataPath)) {
        throw (New-SafeException -Code 'PROFILE_INCOMPLETE')
    }

    $context = New-ProfileDeleteTransactionContext -Name $safeName `
        -ProfilesDirectory $ProfilesDirectory
    $movedTypes = New-Object System.Collections.ArrayList
    $moveFailureType = $null
    foreach ($artifact in @($context.Artifacts)) {
        try {
            if ($artifact.Type -ceq $SimulateMoveFailureType) {
                throw (New-Object System.IO.IOException('SIMULATED_MOVE_FAILURE'))
            }
            [System.IO.File]::Move($artifact.SourcePath, $artifact.QuarantinePath)
            if ([System.IO.File]::Exists($artifact.SourcePath) -or
                -not [System.IO.File]::Exists($artifact.QuarantinePath)) {
                throw (New-Object System.IO.IOException('MOVE_DID_NOT_COMPLETE'))
            }
            [void]$movedTypes.Add($artifact.Type)
            if ($SimulateInterruptionAfterMoveCount -gt 0 -and
                $movedTypes.Count -eq $SimulateInterruptionAfterMoveCount) {
                throw (New-SafeException -Code 'SIMULATED_PROFILE_DELETE_INTERRUPTION')
            }
        }
        catch [System.InvalidOperationException] {
            if ($_.Exception.Message -ceq 'SIMULATED_PROFILE_DELETE_INTERRUPTION') {
                throw
            }
            $moveFailureType = $artifact.Type
            break
        }
        catch {
            $moveFailureType = $artifact.Type
            break
        }
    }

    if ($null -ne $moveFailureType) {
        $rollback = Invoke-ProfileDeleteRollback -Context $context `
            -SimulateRollbackFailureType $SimulateRollbackFailureType
        if (-not $rollback.Succeeded) {
            return [pscustomobject]@{
                Result = 'PROFILE_REMOVE_ROLLBACK_FAILED'
                Profile = $safeName
                FailedFileTypes = @($moveFailureType)
                RollbackFailedFileTypes = @($rollback.FailedFileTypes)
                QuarantineCleanupPending = $true
            }
        }
        return [pscustomobject]@{
            Result = 'PROFILE_REMOVE_FAILED_ROLLED_BACK'
            Profile = $safeName
            FailedFileTypes = @($moveFailureType)
            RollbackFailedFileTypes = @()
            QuarantineCleanupPending = $false
        }
    }

    try {
        [System.IO.File]::WriteAllText(
            $context.CommitMarkerPath,
            $script:ProfileDeleteCommitMarkerContent,
            (New-Object System.Text.UTF8Encoding($false))
        )
        if (-not (Test-ProfileDeleteCommitMarker -Path $context.CommitMarkerPath)) {
            throw (New-Object System.IO.IOException('COMMIT_MARKER_VERIFICATION_FAILED'))
        }
    }
    catch {
        $rollback = Invoke-ProfileDeleteRollback -Context $context `
            -SimulateRollbackFailureType $SimulateRollbackFailureType
        if (-not $rollback.Succeeded) {
            return [pscustomobject]@{
                Result = 'PROFILE_REMOVE_ROLLBACK_FAILED'
                Profile = $safeName
                FailedFileTypes = @('CommitMarker')
                RollbackFailedFileTypes = @($rollback.FailedFileTypes)
                QuarantineCleanupPending = $true
            }
        }
        return [pscustomobject]@{
            Result = 'PROFILE_REMOVE_FAILED_ROLLED_BACK'
            Profile = $safeName
            FailedFileTypes = @('CommitMarker')
            RollbackFailedFileTypes = @()
            QuarantineCleanupPending = $false
        }
    }

    $cleanup = Invoke-ProfileDeleteQuarantineCleanup -Context $context `
        -SimulateCleanupFailureType $SimulateCleanupFailureType
    $warningCode = $null
    if (-not $cleanup.Succeeded) {
        $warningCode = 'PROFILE_REMOVE_QUARANTINE_CLEANUP_FAILED'
    }
    return [pscustomobject]@{
        Result = 'PROFILE_REMOVE_SUCCESS'
        Profile = $safeName
        RemovedFileTypes = @($movedTypes)
        FailedFileTypes = @()
        WarningCode = $warningCode
        QuarantineCleanupPending = -not $cleanup.Succeeded
    }
}

function Invoke-RemoveCodexProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [switch]$ConfirmDelete,

        [Alias('SimulateDeleteFailureType')]
        [ValidateSet('', 'AuthFile', 'IdentityMarker', 'Metadata')]
        [string]$SimulateMoveFailureType = '',

        [ValidateSet('', 'AuthFile', 'IdentityMarker', 'Metadata')]
        [string]$SimulateRollbackFailureType = '',

        [ValidateSet('', 'AuthFile', 'IdentityMarker', 'Metadata')]
        [string]$SimulateCleanupFailureType = '',

        [ValidateRange(0, 3)]
        [int]$SimulateInterruptionAfterMoveCount = 0,

        [string]$MutexName = $script:WriteMutexName
    )

    return Invoke-WithCodexWriteLock -MutexName $MutexName -Operation {
        param(
            $LockedName,
            $LockedProfiles,
            $LockedState,
            $LockedConfirmation,
            $LockedMoveFailure,
            $LockedRollbackFailure,
            $LockedCleanupFailure,
            $LockedInterruptionCount
        )
        $null = Invoke-RecoverCodexProfileDeleteTransactionsUnlocked `
            -ProfilesDirectory $LockedProfiles -StateDirectory $LockedState
        Invoke-RemoveCodexProfileUnlocked -Name $LockedName `
            -ProfilesDirectory $LockedProfiles -StateDirectory $LockedState `
            -ConfirmDelete:$LockedConfirmation `
            -SimulateMoveFailureType $LockedMoveFailure `
            -SimulateRollbackFailureType $LockedRollbackFailure `
            -SimulateCleanupFailureType $LockedCleanupFailure `
            -SimulateInterruptionAfterMoveCount $LockedInterruptionCount
    } -ArgumentList @(
        $Name,
        $ProfilesDirectory,
        $StateDirectory,
        [bool]$ConfirmDelete,
        $SimulateMoveFailureType,
        $SimulateRollbackFailureType,
        $SimulateCleanupFailureType,
        $SimulateInterruptionAfterMoveCount
    )
}

function Remove-CodexProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name,

        [switch]$ConfirmDelete
    )

    Write-QiehaoDiagnosticEvent -Event 'DELETE_START' -Result 'STARTED' `
        -Data @{ Profile = $Name }
    try {
        if (-not $ConfirmDelete) {
            throw (New-SafeException `
                -Code 'PROFILE_REMOVE_CONFIRMATION_REQUIRED')
        }
        return Invoke-WithCodexWriteLock -Operation {
            param($LockedName, $LockedConfirmation)
            $null = Invoke-RecoverCodexProfileDeleteTransactionsUnlocked `
                -ProfilesDirectory $script:ProfilesDirectory `
                -StateDirectory $script:StateDirectory
            $codexHome = Get-CodexHome
            $safety = Invoke-GetCodexProfileDeleteSafety `
                -Name $LockedName -CodexHome $codexHome `
                -ProfilesDirectory $script:ProfilesDirectory `
                -StateDirectory $script:StateDirectory
            $decision = if ([string]$safety.Result -ceq `
                'PROFILE_DELETE_SAFE') { 'ALLOW' }
                elseif ([string]$safety.Result -ceq `
                    'PROFILE_DELETE_ACTIVE_OUT_OF_SYNC') { 'SYNC_REQUIRED' }
                else { 'DENY' }
            Write-QiehaoDiagnosticEvent -Event 'DELETE_DECISION' `
                -Result $decision -Data @{
                    Profile = $LockedName
                    ActiveProfile = [string]$safety.ActiveProfile
                    Decision = $decision
                    ResultCode = [string]$safety.Result
                    CredentialSource = [string]$safety.CredentialSource
                }
            if ([string]$safety.Result -cne 'PROFILE_DELETE_SAFE') {
                throw (New-SafeException -Code ([string]$safety.Result))
            }
            $removeResult = Invoke-RemoveCodexProfileUnlocked `
                -Name $LockedName `
                -ProfilesDirectory $script:ProfilesDirectory `
                -StateDirectory $script:StateDirectory `
                -ConfirmDelete:$LockedConfirmation
            if ([string]$removeResult.Result -ceq 'PROFILE_REMOVE_SUCCESS') {
                Write-QiehaoDiagnosticEvent -Event 'DELETE_SUCCESS' `
                    -Result 'PROFILE_REMOVE_SUCCESS' `
                    -Data @{ Profile = $LockedName; Decision = 'ALLOW' }
            }
            else {
                Write-QiehaoDiagnosticEvent -Event 'DELETE_FAILED' `
                    -Level 'ERROR' -Result ([string]$removeResult.Result) `
                    -Data @{
                        Profile = $LockedName
                        ResultCode = [string]$removeResult.Result
                    }
            }
            return $removeResult
        } -ArgumentList @($Name, [bool]$ConfirmDelete)
    }
    catch {
        $deleteFailureCode = if ($_.Exception.Message -match `
            '^[A-Z][A-Z0-9_]+$') { $_.Exception.Message }
            else { 'PROFILE_REMOVE_FAILED' }
        Write-QiehaoDiagnosticEvent -Event 'DELETE_FAILED' `
            -Level 'ERROR' -Result $deleteFailureCode -Data @{
                Profile = $Name
                ResultCode = $deleteFailureCode
            }
        throw
    }
}

function Invoke-RenameCodexProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$OldName,

        [Parameter(Mandatory = $true)]
        [string]$NewName,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [ValidateRange(0, 3)]
        [int]$SimulateFailureAfterMoveCount = 0
    )

    $oldSafeName = ConvertTo-SafeProfileName -Name $OldName
    $newSafeName = ConvertTo-SafeProfileName -Name $NewName
    $oldPaths = Get-StrictProfileArtifactPaths -Name $oldSafeName `
        -ProfilesDirectory $ProfilesDirectory
    $newPaths = Get-StrictProfileArtifactPaths -Name $newSafeName `
        -ProfilesDirectory $ProfilesDirectory

    if (-not (Test-AnyProfileArtifactExists -Paths $oldPaths)) {
        throw (New-SafeException -Code 'PROFILE_NOT_FOUND')
    }
    if (-not [System.IO.File]::Exists($oldPaths.EncryptedPath) -or
        -not [System.IO.File]::Exists($oldPaths.IdentityMarkerPath) -or
        -not [System.IO.File]::Exists($oldPaths.MetadataPath)) {
        throw (New-SafeException -Code 'PROFILE_INCOMPLETE')
    }
    if (Test-AnyProfileArtifactExists -Paths $newPaths) {
        throw (New-SafeException -Code 'PROFILE_NAME_ALREADY_EXISTS')
    }

    $metadataState = Get-ProfileMetadataState -Name $oldSafeName `
        -ProfilesDirectory $ProfilesDirectory
    if (-not $metadataState.IsValid) {
        throw (New-SafeException -Code 'PROFILE_METADATA_INVALID')
    }
    $activeState = Read-ActiveProfileState -StateDirectory $StateDirectory
    $renamingActive = $activeState.ActiveProfile.Equals(
        $oldSafeName,
        [StringComparison]::OrdinalIgnoreCase
    )

    $originalMetadataBytes = $null
    $newMetadataBytes = $null
    $movedPairs = @()
    $mutationStarted = $false
    try {
        $originalMetadataBytes = [System.IO.File]::ReadAllBytes($oldPaths.MetadataPath)
        $newMetadata = [ordered]@{
            schema_version = 1
            profile_name = $newSafeName
            created_at = [string]$metadataState.RawObject.created_at
            updated_at = [DateTime]::UtcNow.ToString('o')
            encrypted_file_name = $newSafeName + '.auth.dpapi'
            encrypted_file_size = ([System.IO.FileInfo]$oldPaths.EncryptedPath).Length
            dpapi_scope = 'CurrentUser'
        }
        $newMetadataJson = $newMetadata | ConvertTo-Json -Compress
        $newMetadataBytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes(
            $newMetadataJson
        )
        $newMetadata = $null
        $newMetadataJson = $null

        $movePairs = @(
            [pscustomobject]@{ Type = 'AuthFile'; Old = $oldPaths.EncryptedPath; New = $newPaths.EncryptedPath },
            [pscustomobject]@{ Type = 'IdentityMarker'; Old = $oldPaths.IdentityMarkerPath; New = $newPaths.IdentityMarkerPath },
            [pscustomobject]@{ Type = 'Metadata'; Old = $oldPaths.MetadataPath; New = $newPaths.MetadataPath }
        )
        $completedMoves = @()
        foreach ($pair in $movePairs) {
            [System.IO.File]::Move($pair.Old, $pair.New)
            $mutationStarted = $true
            $completedMoves += $pair
            if ($SimulateFailureAfterMoveCount -gt 0 -and
                $completedMoves.Count -eq $SimulateFailureAfterMoveCount) {
                throw (New-Object System.IO.IOException('SIMULATED_RENAME_FAILURE'))
            }
        }

        Write-AtomicByteFile -Path $newPaths.MetadataPath -Bytes $newMetadataBytes `
            -Force -NoBackup
        if ($renamingActive) {
            # File moves and non-secret metadata are complete. Active state is
            # the final durable commit, matching the switch transaction model.
            Write-ActiveProfileState -Name $newSafeName -StateDirectory $StateDirectory
        }

        return [pscustomobject]@{
            Result = 'PROFILE_RENAME_SUCCESS'
            From = $oldSafeName
            To = $newSafeName
            ActiveProfileRenamed = $renamingActive
        }
    }
    catch {
        $originalException = $_.Exception
        if ($mutationStarted) {
            $rollbackFailed = $false
            for ($index = $completedMoves.Count - 1; $index -ge 0; $index--) {
                $pair = $completedMoves[$index]
                try {
                    if ([System.IO.File]::Exists($pair.New) -and
                        -not [System.IO.File]::Exists($pair.Old)) {
                        [System.IO.File]::Move($pair.New, $pair.Old)
                    }
                }
                catch {
                    $rollbackFailed = $true
                }
            }
            try {
                if ($null -ne $originalMetadataBytes -and
                    [System.IO.File]::Exists($oldPaths.MetadataPath)) {
                    Write-AtomicByteFile -Path $oldPaths.MetadataPath `
                        -Bytes $originalMetadataBytes -Force -NoBackup
                }
            }
            catch {
                $rollbackFailed = $true
            }
            if ($rollbackFailed) {
                throw (New-SafeException -Code 'PROFILE_RENAME_ROLLBACK_FAILED')
            }
            throw (New-SafeException -Code 'PROFILE_RENAME_FAILED_ROLLED_BACK')
        }
        if ($originalException.Message -match '^[A-Z][A-Z0-9_]+$') {
            throw $originalException
        }
        throw (New-SafeException -Code 'PROFILE_RENAME_FAILED')
    }
    finally {
        if ($null -ne $originalMetadataBytes -and $originalMetadataBytes.Length -gt 0) {
            [Array]::Clear($originalMetadataBytes, 0, $originalMetadataBytes.Length)
        }
        if ($null -ne $newMetadataBytes -and $newMetadataBytes.Length -gt 0) {
            [Array]::Clear($newMetadataBytes, 0, $newMetadataBytes.Length)
        }
        $metadataState = $null
    }
}

function Rename-CodexProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$OldName,

        [Parameter(Mandatory = $true, Position = 1)]
        [string]$NewName
    )

    return Invoke-WithCodexWriteLock -Operation {
        param($LockedOldName, $LockedNewName)
        Invoke-RenameCodexProfile -OldName $LockedOldName -NewName $LockedNewName `
            -ProfilesDirectory $script:ProfilesDirectory `
            -StateDirectory $script:StateDirectory
    } -ArgumentList @($OldName, $NewName)
}

function Invoke-VerifyCodexProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [Parameter(Mandatory = $true)]
        [string]$CodexHome,

        [object[]]$ProcessData,

        [switch]$UseProvidedProcessData
    )

    $profileAuthBytes = $null
    $currentAuthBytes = $null
    $profileContext = $null
    $comparison = $null
    $profileComparison = $null
    $credentialSource = $null
    $metadataState = $null
    $currentContext = $null
    Write-QiehaoDiagnosticEvent -Event 'VERIFY_START' -Result 'STARTED' `
        -Data @{ Profile = $Name }
    try {
        Assert-CodexNotRunning -ProcessData $ProcessData `
            -UseProvidedProcessData:$UseProvidedProcessData `
            -DiagnosticOperation 'VERIFY'
        $credentialSource = Assert-CodexFileCredentialSource `
            -CodexHome $CodexHome
        $safeName = ConvertTo-SafeProfileName -Name $Name
        $paths = Get-StrictProfileArtifactPaths -Name $safeName `
            -ProfilesDirectory $ProfilesDirectory
        if (-not (Test-AnyProfileArtifactExists -Paths $paths)) {
            throw (New-SafeException -Code 'PROFILE_NOT_FOUND')
        }
        if (-not [System.IO.File]::Exists($paths.EncryptedPath) -or
            -not [System.IO.File]::Exists($paths.IdentityMarkerPath) -or
            -not [System.IO.File]::Exists($paths.MetadataPath)) {
            throw (New-SafeException -Code 'PROFILE_INCOMPLETE')
        }
        $metadataState = Get-ProfileMetadataState -Name $safeName `
            -ProfilesDirectory $ProfilesDirectory
        if (-not $metadataState.IsValid) {
            throw (New-SafeException -Code 'PROFILE_METADATA_INVALID')
        }

        $profileAuthBytes = Read-CodexAccountSlotBytes -Name $safeName `
            -ProfilesDirectory $ProfilesDirectory
        $profileComparison = Assert-CodexAuthMatchesProfileIdentity `
            -Name $safeName -AuthBytes $profileAuthBytes `
            -ProfilesDirectory $ProfilesDirectory `
            -MismatchCode 'PROFILE_IDENTITY_MISMATCH'
        $profileContext = Get-CodexAuthIdentityContext -Bytes $profileAuthBytes
        $profileIdentityHash = Get-QiehaoDiagnosticIdentityHash `
            -IdentityBytes $profileContext.AccountIdBytes
        Write-QiehaoDiagnosticEvent -Event 'PROFILE_INTEGRITY_RESULT' `
            -Result 'COMPLETE' -Data @{
                Profile = $safeName
                ProfileIntegrity = 'Complete'
                SavedWorkspaceType = [string]$profileContext.WorkspaceClass
                IdentityHash = $profileIdentityHash
            }
        Write-QiehaoDiagnosticEvent -Event 'WORKSPACE_DETECT' `
            -Result ([string]$profileContext.WorkspaceClaimStatus) -Data @{
                Role = 'VERIFY_SAVED_PROFILE'
                WorkspaceType = [string]$profileContext.WorkspaceClass
                IdentityHash = $profileIdentityHash
                ParseResult = [string]$profileContext.WorkspaceClaimStatus
            }

        $authPath = Join-Path -Path $CodexHome -ChildPath 'auth.json'
        $currentAuthBytes = Read-SensitiveFileBytes -Path $authPath
        $null = Test-CodexAuthBytes -Bytes $currentAuthBytes
        $currentContext = Get-CodexAuthIdentityContext -Bytes $currentAuthBytes
        $currentIdentityHash = Get-QiehaoDiagnosticIdentityHash `
            -IdentityBytes $currentContext.AccountIdBytes
        Write-QiehaoDiagnosticEvent -Event 'CURRENT_IDENTITY_RESULT' `
            -Result 'PARSED' -Data @{
                Profile = $safeName
                CredentialSource = [string]$credentialSource.Source
                CurrentWorkspaceType = [string]$currentContext.WorkspaceClass
                IdentityHash = $currentIdentityHash
            }
        Write-QiehaoDiagnosticEvent -Event 'WORKSPACE_RESULT' `
            -Result ([string]$currentContext.WorkspaceClaimStatus) -Data @{
                Profile = $safeName
                CurrentWorkspaceType = [string]$currentContext.WorkspaceClass
                SavedWorkspaceType = [string]$profileContext.WorkspaceClass
                IdentityHash = $currentIdentityHash
                ParseResult = [string]$currentContext.WorkspaceClaimStatus
            }
        $comparison = Compare-CodexAuthToProfileIdentity -Name $safeName `
            -AuthBytes $currentAuthBytes -ProfilesDirectory $ProfilesDirectory
        if (-not $comparison.Matches) {
            if ([string]$profileContext.WorkspaceClass -cne 'Unknown' -and
                [string]$comparison.CurrentWorkspaceClass -cne 'Unknown' -and
                [string]$profileContext.WorkspaceClass -cne
                    [string]$comparison.CurrentWorkspaceClass) {
                Write-QiehaoDiagnosticEvent `
                    -Event 'WORKSPACE_TYPE_MISMATCH' `
                    -Level 'WARNING' `
                    -Result 'PROFILE_VERIFY_IDENTITY_MISMATCH' `
                    -Data @{
                        Profile = $safeName
                        saved_workspace_type =
                            [string]$profileContext.WorkspaceClass
                        current_workspace_type =
                            [string]$comparison.CurrentWorkspaceClass
                        IdentityHash = $currentIdentityHash
                        ResultCode = 'PROFILE_VERIFY_IDENTITY_MISMATCH'
                    }
            }
            Write-QiehaoDiagnosticEvent -Event 'VERIFY_MISMATCH' `
                -Level 'WARNING' -Result 'PROFILE_VERIFY_IDENTITY_MISMATCH' `
                -Data @{
                    Profile = $safeName
                    SavedWorkspaceType = [string]$profileContext.WorkspaceClass
                    CurrentWorkspaceType = [string]$comparison.CurrentWorkspaceClass
                    ResultCode = 'PROFILE_VERIFY_IDENTITY_MISMATCH'
                }
            return [pscustomobject]@{
                Result = 'PROFILE_VERIFY_IDENTITY_MISMATCH'
                Profile = $safeName
                ProfileIntegrity = 'Complete'
                SavedWorkspaceClass = [string]$profileContext.WorkspaceClass
                CurrentWorkspaceClass =
                    [string]$comparison.CurrentWorkspaceClass
                WorkspaceContextStatus =
                    [string]$comparison.WorkspaceContextStatus
                CredentialSource = [string]$credentialSource.Source
                CredentialSourceConfidence =
                    [string]$credentialSource.Confidence
            }
        }
        if ([string]$profileComparison.WorkspaceContextStatus -cne
            'Confirmed' -or
            [string]$comparison.WorkspaceContextStatus -cne 'Confirmed') {
            Write-QiehaoDiagnosticEvent -Event 'VERIFY_FAILED' `
                -Level 'WARNING' `
                -Result 'PROFILE_VERIFY_WORKSPACE_CONTEXT_UNKNOWN' `
                -Data @{
                    Profile = $safeName
                    SavedWorkspaceType = [string]$profileContext.WorkspaceClass
                    CurrentWorkspaceType = [string]$comparison.CurrentWorkspaceClass
                    ResultCode = 'PROFILE_VERIFY_WORKSPACE_CONTEXT_UNKNOWN'
                }
            return [pscustomobject]@{
                Result = 'PROFILE_VERIFY_WORKSPACE_CONTEXT_UNKNOWN'
                Profile = $safeName
                ProfileIntegrity = 'Complete'
                SavedWorkspaceClass = [string]$profileContext.WorkspaceClass
                CurrentWorkspaceClass =
                    [string]$comparison.CurrentWorkspaceClass
                WorkspaceContextStatus = 'LegacyUnknown'
                CredentialSource = [string]$credentialSource.Source
                CredentialSourceConfidence =
                    [string]$credentialSource.Confidence
            }
        }
        Write-QiehaoDiagnosticEvent -Event 'VERIFY_SUCCESS' `
            -Result 'PROFILE_VERIFY_SUCCESS' -Data @{
                Profile = $safeName
                SavedWorkspaceType = [string]$profileContext.WorkspaceClass
                CurrentWorkspaceType = [string]$comparison.CurrentWorkspaceClass
                IdentityHash = $currentIdentityHash
            }
        return [pscustomobject]@{
            Result = 'PROFILE_VERIFY_SUCCESS'
            Profile = $safeName
            ProfileIntegrity = 'Complete'
            SavedWorkspaceClass = [string]$profileContext.WorkspaceClass
            CurrentWorkspaceClass = [string]$comparison.CurrentWorkspaceClass
            WorkspaceContextStatus = 'Confirmed'
            CredentialSource = [string]$credentialSource.Source
            CredentialSourceConfidence = [string]$credentialSource.Confidence
        }
    }
    catch {
        $verifyFailureCode = if ($_.Exception.Message -match `
            '^[A-Z][A-Z0-9_]+$') { $_.Exception.Message }
            else { 'PROFILE_VERIFY_FAILED' }
        Write-QiehaoDiagnosticEvent -Event 'VERIFY_FAILED' `
            -Level 'ERROR' -Result $verifyFailureCode -Data @{
                Profile = $Name
                ResultCode = $verifyFailureCode
            }
        throw
    }
    finally {
        foreach ($buffer in @($profileAuthBytes, $currentAuthBytes)) {
            if ($null -ne $buffer -and $buffer.Length -gt 0) {
                [Array]::Clear($buffer, 0, $buffer.Length)
            }
        }
        Clear-CodexAuthIdentityContext -Context $profileContext
        Clear-CodexAuthIdentityContext -Context $currentContext
        $metadataState = $null
    }
}

function Test-CodexProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name
    )

    return Invoke-WithCodexWriteLock -Operation {
        param($LockedName)
        $codexHome = Get-CodexHome
        Invoke-VerifyCodexProfile -Name $LockedName `
            -ProfilesDirectory $script:ProfilesDirectory `
            -CodexHome $codexHome
    } -ArgumentList @($Name)
}

function Get-CodexAccountSlotState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory
    )

    if (-not [System.IO.Directory]::Exists($ProfilesDirectory)) {
        return
    }

    $activeName = $null
    $activeKnown = $false
    try {
        $activeState = Read-ActiveProfileState -StateDirectory $StateDirectory
        $activeName = $activeState.ActiveProfile
        $activeKnown = $true
    }
    catch {
        $activeKnown = $false
    }

    $unsafeArtifactFound = $false
    foreach ($artifactFile in Get-ChildItem -LiteralPath $ProfilesDirectory -File `
        -Force -ErrorAction SilentlyContinue) {
        foreach ($suffix in @('.auth.dpapi', '.identity.dpapi', '.meta.json')) {
            if ($artifactFile.Name.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) {
                $artifactStem = $artifactFile.Name.Substring(
                    0,
                    $artifactFile.Name.Length - $suffix.Length
                )
                if (-not (Test-SafeProfileFileStem -Name $artifactStem)) {
                    $unsafeArtifactFound = $true
                }
                break
            }
        }
    }
    if ($unsafeArtifactFound) {
        [pscustomobject]@{
            Profile = '<UNSAFE_PROFILE_FILENAME>'
            Active = $null
            AuthFile = 'UNKNOWN'
            IdentityMarker = 'UNKNOWN'
            Metadata = 'UNKNOWN'
            Health = 'UNKNOWN'
            CreatedAt = '<UNAVAILABLE>'
            UpdatedAt = '<UNAVAILABLE>'
            DPAPIScope = '<UNAVAILABLE>'
            EncryptedFileExists = $false
        }
    }

    foreach ($profileName in @(Get-ProfileNamesFromArtifacts `
        -ProfilesDirectory $ProfilesDirectory)) {
        try {
            $paths = Get-StrictProfileArtifactPaths -Name $profileName `
                -ProfilesDirectory $ProfilesDirectory
            $authExists = [System.IO.File]::Exists($paths.EncryptedPath)
            $markerExists = [System.IO.File]::Exists($paths.IdentityMarkerPath)
            $metadataState = Get-ProfileMetadataState -Name $profileName `
                -ProfilesDirectory $ProfilesDirectory
            $metadataExists = $metadataState.Exists

            if (-not $authExists -or -not $markerExists -or -not $metadataExists) {
                $health = 'INCOMPLETE_PROFILE'
            }
            elseif (-not $metadataState.IsValid) {
                $health = 'INVALID_METADATA'
            }
            else {
                $health = 'READY'
            }

            [pscustomobject]@{
                Profile = $profileName
                Active = if ($activeKnown) {
                    $activeName.Equals($profileName, [StringComparison]::OrdinalIgnoreCase)
                } else { $null }
                AuthFile = if ($authExists) { 'PRESENT' } else { 'MISSING' }
                IdentityMarker = if ($markerExists) { 'PRESENT' } else { 'MISSING' }
                Metadata = if (-not $metadataExists) {
                    'MISSING'
                } elseif ($metadataState.IsValid) {
                    'VALID'
                } else {
                    'INVALID'
                }
                Health = $health
                CreatedAt = $metadataState.CreatedAt
                UpdatedAt = $metadataState.UpdatedAt
                DPAPIScope = $metadataState.DPAPIScope
                EncryptedFileExists = $authExists
            }
        }
        catch {
            [pscustomobject]@{
                Profile = $profileName
                Active = $null
                AuthFile = 'UNKNOWN'
                IdentityMarker = 'UNKNOWN'
                Metadata = 'UNKNOWN'
                Health = 'UNKNOWN'
                CreatedAt = '<UNAVAILABLE>'
                UpdatedAt = '<UNAVAILABLE>'
                DPAPIScope = '<UNAVAILABLE>'
                EncryptedFileExists = $false
            }
        }
        finally {
            $metadataState = $null
        }
    }
}

function Get-CodexAccountSlot {
    [CmdletBinding()]
    param()

    return Invoke-WithCodexWriteLock -Operation {
        $recovery = Invoke-RecoverCodexProfileDeleteTransactionsUnlocked `
            -ProfilesDirectory $script:ProfilesDirectory `
            -StateDirectory $script:StateDirectory
        foreach ($warningCode in @($recovery.WarningCodes)) {
            Write-SafeLog -Event $warningCode
        }
        Get-CodexAccountSlotState -ProfilesDirectory $script:ProfilesDirectory `
            -StateDirectory $script:StateDirectory
    }
}

Export-ModuleMember -Function @(
    'Initialize-QiehaoRuntimeDirectories',
    'Write-QiehaoAppStartDiagnostic',
    'Get-CodexHome',
    'Get-CodexCredentialSourceInfo',
    'Test-CodexAuthFile',
    'Protect-CodexAuthBytes',
    'Unprotect-CodexAuthBytes',
    'Test-CodexProcessesStopped',
    'Request-CodexDesktopClose',
    'Request-CodexDesktopNativeQuit',
    'Save-CodexAccountSlot',
    'Save-CodexActiveProfile',
    'Get-CodexAccountSlot',
    'Add-CodexProfile',
    'Remove-CodexProfile',
    'Get-CodexProfileDeleteSafety',
    'Rename-CodexProfile',
    'Test-CodexProfile',
    'Initialize-CodexProfileIdentityMarker',
    'Initialize-CodexActiveProfile',
    'Get-CodexActiveProfile',
    'Test-CodexActiveIdentity',
    'Sync-CodexActiveProfile',
    'Switch-CodexAccountProfile'
)
