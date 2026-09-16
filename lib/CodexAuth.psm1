Set-StrictMode -Version 2.0

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:ProfilesDirectory = Join-Path -Path $script:ProjectRoot -ChildPath 'profiles'
$script:LogsDirectory = Join-Path -Path $script:ProjectRoot -ChildPath 'logs'
$script:StateDirectory = Join-Path -Path $script:ProjectRoot -ChildPath 'state'
$script:EntropyText = 'CodexAccountSwitcher-v1'
$script:IdentityEntropyText = 'CodexAccountSwitcher-Identity-v1'
$script:MaximumAuthFileBytes = 16MB
$script:ExpectedAuthKeys = @('auth_mode', 'OPENAI_API_KEY', 'tokens', 'last_refresh')
$script:IdentityMarkerHeader = [byte[]](0x51, 0x48, 0x49, 0x44, 0x01, 0x01)
$script:MaximumIdentityBytes = 2048
$script:MaximumMetadataFileBytes = 64KB
$script:WriteMutexName = 'Local\Qiehaoqu.CodexAccountSwitcher.WriteOperation.v1'
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

    # Windows PowerShell 5.1 does not ship System.Text.Json. Its built-in JSON
    # parser requires an in-memory UTF-8 string. The string is never emitted,
    # logged, persisted, or included in exceptions.
    $jsonText = $null
    $jsonObject = $null
    try {
        $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
        $jsonText = $strictUtf8.GetString($Bytes)
        $jsonObject = ConvertFrom-Json -InputObject $jsonText -ErrorAction Stop
        if ($null -eq $jsonObject -or -not ($jsonObject -is [pscustomobject])) {
            throw (New-SafeException -Code 'AUTH_SCHEMA_UNEXPECTED')
        }

        $names = @($jsonObject.PSObject.Properties | ForEach-Object { $_.Name })
        return $names
    }
    catch [System.InvalidOperationException] {
        throw
    }
    catch {
        throw (New-SafeException -Code 'AUTH_JSON_INVALID')
    }
    finally {
        $jsonObject = $null
        $jsonText = $null
    }
}

function Test-CodexAuthBytes {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    if ($null -eq $Bytes -or $Bytes.Length -eq 0) {
        throw (New-SafeException -Code 'AUTH_FILE_EMPTY')
    }

    $actualKeys = @(Get-AuthTopLevelPropertyNames -Bytes $Bytes)
    $schemaMatches = $actualKeys.Count -eq $script:ExpectedAuthKeys.Count

    if ($schemaMatches) {
        foreach ($expectedKey in $script:ExpectedAuthKeys) {
            if (-not ($actualKeys -ccontains $expectedKey)) {
                $schemaMatches = $false
                break
            }
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

    return [pscustomobject]@{
        IsValidJson = $true
        RootIsObject = $true
        SchemaExpected = $true
    }
}

function Get-CodexAuthIdentityBytes {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Bytes
    )

    # Identity schema v1 deliberately uses the explicit TokenData account_id
    # field. It does not decode or depend on any JWT claim. Codex refreshes the
    # token strings independently while account_id identifies the selected
    # ChatGPT account/workspace. Any missing, duplicate, non-string, empty, or
    # unexpectedly shaped field fails closed.
    $null = Test-CodexAuthBytes -Bytes $Bytes
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
            # Windows PowerShell 5.1 has no System.Text.Json. Its JSON parser
            # necessarily materializes values as managed strings. They are
            # never emitted, logged, persisted, or included in exceptions and
            # references are discarded in finally; .NET cannot promise an
            # absolute erasure of those immutable strings.
            $jsonText = $null
            $jsonObject = $null
            try {
                $strictUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
                $jsonText = $strictUtf8.GetString($Bytes)
                $jsonObject = ConvertFrom-Json -InputObject $jsonText -ErrorAction Stop
                if ($null -eq $jsonObject -or -not ($jsonObject -is [pscustomobject])) {
                    throw (New-SafeException -Code 'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED')
                }

                $authModeProperties = @($jsonObject.PSObject.Properties | Where-Object {
                    $_.Name -ceq 'auth_mode'
                })
                $tokensProperties = @($jsonObject.PSObject.Properties | Where-Object {
                    $_.Name -ceq 'tokens'
                })
                if ($authModeProperties.Count -ne 1 -or
                    -not ($authModeProperties[0].Value -is [string]) -or
                    $authModeProperties[0].Value -cne 'chatgpt' -or
                    $tokensProperties.Count -ne 1 -or
                    -not ($tokensProperties[0].Value -is [pscustomobject])) {
                    throw (New-SafeException -Code 'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED')
                }

                $accountIdProperties = @(
                    $tokensProperties[0].Value.PSObject.Properties | Where-Object {
                        $_.Name -ceq 'account_id'
                    }
                )
                if ($accountIdProperties.Count -ne 1 -or
                    -not ($accountIdProperties[0].Value -is [string])) {
                    throw (New-SafeException -Code 'AUTH_IDENTITY_SCHEMA_UNRECOGNIZED')
                }
                $identityText = $accountIdProperties[0].Value
            }
            finally {
                $jsonObject = $null
                $jsonText = $null
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
            'ExecutablePath'
        ) -ErrorAction Stop)

        foreach ($process in $cimProcesses) {
            $processPath = [string]$process.ExecutablePath
            [pscustomobject]@{
                ProcessName = [string]$process.Name
                Id = [int]$process.ProcessId
                ParentProcessId = [int]$process.ParentProcessId
                ParentReadStatus = 'Readable'
                ExecutablePath = $processPath
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
        try {
            $processPath = $process.Path
            if (-not [string]::IsNullOrWhiteSpace($processPath)) {
                $pathReadStatus = 'Readable'
            }
        }
        catch {
            # Do not expose the exception or attempt to read the command line.
        }

        [pscustomobject]@{
            ProcessName = $process.ProcessName
            Id = $process.Id
            ParentProcessId = $null
            ParentReadStatus = 'Unavailable'
            ExecutablePath = $processPath
            PathReadStatus = $pathReadStatus
        }
    }
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
        [object[]]$ProcessData
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
            ReasonCode = 'CODEX_PROCESS_RUNNING'
        }
    }
    if ($uncertain.Count -gt 0) {
        return [pscustomobject]@{
            SafeToSave = $false
            BlockingProcesses = @()
            UncertainProcesses = @($uncertain)
            BrowserExtensionHosts = @($browserExtensionHosts)
            ReasonCode = 'CODEX_PROCESS_STATE_UNKNOWN'
        }
    }

    return [pscustomobject]@{
        SafeToSave = $true
        BlockingProcesses = @()
        UncertainProcesses = @()
        BrowserExtensionHosts = @($browserExtensionHosts)
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
        [scriptblock]$CloseMainWindowAction
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
            }
        }
    }

    $processState = Test-CodexProcessesStopped -ProcessData $snapshot
    if ($processState.ReasonCode -ceq 'CODEX_PROCESSES_STOPPED') {
        return [pscustomobject]@{
            Result = 'CODEX_ALREADY_STOPPED'
            CloseRequested = $false
            RequestedCount = 0
        }
    }
    if ($processState.ReasonCode -cne 'CODEX_PROCESS_RUNNING') {
        return [pscustomobject]@{
            Result = 'CODEX_PROCESS_STATE_UNKNOWN'
            CloseRequested = $false
            RequestedCount = 0
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
        if (-not $blockingIds.ContainsKey([string]$processId) -or
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
            try {
                if ([bool](& $CloseMainWindowAction $item)) {
                    $requestedCount++
                }
            }
            catch {
                # A failed normal-close request is not escalated to termination.
            }
            continue
        }

        $liveProcess = $null
        try {
            $liveProcess = Get-Process -Id $processId -ErrorAction Stop
            $livePath = [string]$liveProcess.Path
            if (-not (Test-NativeCodexChatGptPath -Path $livePath) -or
                [int64]$liveProcess.MainWindowHandle -eq 0) {
                continue
            }
            if ([bool]$liveProcess.CloseMainWindow()) {
                $requestedCount++
            }
        }
        catch {
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
        }
    }
    return [pscustomobject]@{
        Result = 'CODEX_MAIN_WINDOW_NOT_FOUND'
        CloseRequested = $false
        RequestedCount = 0
    }
}

function Assert-CodexNotRunning {
    param(
        [object[]]$ProcessData,

        [switch]$UseProvidedProcessData
    )

    if ($UseProvidedProcessData) {
        $processState = Test-CodexProcessesStopped -ProcessData $ProcessData
    }
    else {
        $processState = Test-CodexProcessesStopped
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

    $authIdentityBytes = $null
    $markerIdentityBytes = $null
    try {
        $markerIdentityBytes = Read-CodexProfileIdentityMarker -Name $Name `
            -ProfilesDirectory $ProfilesDirectory
        $authIdentityBytes = Get-CodexAuthIdentityBytes -Bytes $AuthBytes
        if (-not (Test-IdentityByteArraysEqual -Left $markerIdentityBytes `
            -Right $authIdentityBytes)) {
            throw (New-SafeException -Code $MismatchCode)
        }
        return $true
    }
    finally {
        foreach ($buffer in @($authIdentityBytes, $markerIdentityBytes)) {
            if ($null -ne $buffer -and $buffer.Length -gt 0) {
                [Array]::Clear($buffer, 0, $buffer.Length)
            }
        }
    }
}

function Test-ProfileIdentityExists {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$IdentityBytes,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

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
        try {
            $existingIdentityBytes = Read-CodexProfileIdentityMarker `
                -Name $profileName -ProfilesDirectory $ProfilesDirectory
            if (Test-IdentityByteArraysEqual -Left $IdentityBytes `
                -Right $existingIdentityBytes) {
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
            if ($null -ne $existingIdentityBytes -and $existingIdentityBytes.Length -gt 0) {
                [Array]::Clear($existingIdentityBytes, 0, $existingIdentityBytes.Length)
            }
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

function Write-SafeLog {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('SAVE_STARTED', 'SAVE_SUCCEEDED', 'SAVE_FAILED')]
        [string]$Event,

        [string]$ProfileName
    )

    if (-not [System.IO.Directory]::Exists($script:LogsDirectory)) {
        return
    }

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    switch ($Event) {
        'SAVE_STARTED' {
            $line = '{0} INFO profile save started: {1}' -f $timestamp, $ProfileName
        }
        'SAVE_SUCCEEDED' {
            $line = '{0} INFO encrypted profile written successfully: {1}' -f $timestamp, $ProfileName
        }
        'SAVE_FAILED' {
            $line = '{0} ERROR profile save failed: SAFE_FAILURE' -f $timestamp
        }
    }

    try {
        $logPath = Join-Path -Path $script:LogsDirectory -ChildPath 'qiehao.log'
        [System.IO.File]::AppendAllText(
            $logPath,
            $line + [Environment]::NewLine,
            (New-Object System.Text.UTF8Encoding($false))
        )
    }
    catch {
        # Logging must never expose an exception object or block secure cleanup.
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

    try {
        Assert-CodexNotRunning -ProcessData $ProcessData `
            -UseProvidedProcessData:$UseProvidedProcessData

        $activeState = Read-ActiveProfileState -StateDirectory $StateDirectory
        $activeName = $activeState.ActiveProfile
        if ($activeName -ceq $targetName) {
            throw (New-SafeException -Code 'ALREADY_ACTIVE')
        }

        $authPath = Join-Path -Path $CodexHome -ChildPath 'auth.json'

        # Preserve the freshest current credentials before attempting to use
        # the target slot; Codex may have refreshed OAuth data while running.
        $currentAuthBytes = Read-SensitiveFileBytes -Path $authPath
        $null = Test-CodexAuthBytes -Bytes $currentAuthBytes
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

        Write-CodexAuthFileBytes -AuthPath $authPath -AuthBytes $targetAuthBytes
        $authWasReplaced = $true

        if ($SimulatePostReplaceVerificationFailure) {
            throw (New-SafeException -Code 'SWITCH_POST_REPLACE_VERIFICATION_FAILED')
        }

        $writtenAuthBytes = Read-SensitiveFileBytes -Path $authPath
        $null = Test-CodexAuthBytes -Bytes $writtenAuthBytes
        if (-not (Test-ByteArraysEqual -Left $targetAuthBytes -Right $writtenAuthBytes)) {
            throw (New-SafeException -Code 'SWITCH_POST_REPLACE_VERIFICATION_FAILED')
        }

        # This is deliberately the final durable state change.
        Write-ActiveProfileState -Name $targetName -StateDirectory $StateDirectory
        $stateWasCommitted = $true

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
                throw (New-SafeException -Code 'SWITCH_FAILED_ROLLED_BACK')
            }
            throw (New-SafeException -Code 'SWITCH_ROLLBACK_FAILED')
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
    try {
        Assert-CodexNotRunning -ProcessData $ProcessData `
            -UseProvidedProcessData:$UseProvidedProcessData
        $safeName = ConvertTo-SafeProfileName -Name $Name
        $paths = Get-StrictProfileArtifactPaths -Name $safeName `
            -ProfilesDirectory $ProfilesDirectory
        if (Test-AnyProfileArtifactExists -Paths $paths) {
            throw (New-SafeException -Code 'PROFILE_NAME_ALREADY_EXISTS')
        }

        $authPath = Join-Path -Path $CodexHome -ChildPath 'auth.json'
        $authBytes = Read-SensitiveFileBytes -Path $authPath
        $null = Test-CodexAuthBytes -Bytes $authBytes
        $identityBytes = Get-CodexAuthIdentityBytes -Bytes $authBytes
        $identityMatch = Test-ProfileIdentityExists -IdentityBytes $identityBytes `
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
                throw (New-SafeException -Code 'PROFILE_ADD_ROLLBACK_FAILED')
            }
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

function Invoke-RemoveCodexProfile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$ProfilesDirectory,

        [Parameter(Mandatory = $true)]
        [string]$StateDirectory,

        [switch]$ConfirmDelete,

        [ValidateSet('', 'AuthFile', 'IdentityMarker', 'Metadata')]
        [string]$SimulateDeleteFailureType = ''
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

    $removedTypes = @()
    $failedTypes = @()
    foreach ($artifact in @(
        [pscustomobject]@{ Type = 'AuthFile'; Path = $paths.EncryptedPath },
        [pscustomobject]@{ Type = 'IdentityMarker'; Path = $paths.IdentityMarkerPath },
        [pscustomobject]@{ Type = 'Metadata'; Path = $paths.MetadataPath }
    )) {
        if (-not [System.IO.File]::Exists($artifact.Path)) {
            continue
        }
        try {
            if ($artifact.Type -ceq $SimulateDeleteFailureType) {
                throw (New-Object System.IO.IOException('SIMULATED_DELETE_FAILURE'))
            }
            [System.IO.File]::Delete($artifact.Path)
            if ([System.IO.File]::Exists($artifact.Path)) {
                throw (New-Object System.IO.IOException('DELETE_DID_NOT_COMPLETE'))
            }
            $removedTypes += $artifact.Type
        }
        catch {
            $failedTypes += $artifact.Type
        }
    }

    if ($failedTypes.Count -gt 0) {
        return [pscustomobject]@{
            Result = 'PROFILE_REMOVE_PARTIAL_FAILURE'
            Profile = $safeName
            RemovedFileTypes = @($removedTypes)
            FailedFileTypes = @($failedTypes)
        }
    }
    return [pscustomobject]@{
        Result = 'PROFILE_REMOVE_SUCCESS'
        Profile = $safeName
        RemovedFileTypes = @($removedTypes)
        FailedFileTypes = @()
    }
}

function Remove-CodexProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string]$Name,

        [switch]$ConfirmDelete
    )

    return Invoke-WithCodexWriteLock -Operation {
        param($LockedName, $LockedConfirmation)
        Invoke-RemoveCodexProfile -Name $LockedName `
            -ProfilesDirectory $script:ProfilesDirectory `
            -StateDirectory $script:StateDirectory `
            -ConfirmDelete:$LockedConfirmation
    } -ArgumentList @($Name, [bool]$ConfirmDelete)
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

        [object[]]$ProcessData,

        [switch]$UseProvidedProcessData
    )

    $authBytes = $null
    try {
        Assert-CodexNotRunning -ProcessData $ProcessData `
            -UseProvidedProcessData:$UseProvidedProcessData
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

        $authBytes = Read-CodexAccountSlotBytes -Name $safeName `
            -ProfilesDirectory $ProfilesDirectory
        $null = Assert-CodexAuthMatchesProfileIdentity -Name $safeName `
            -AuthBytes $authBytes -ProfilesDirectory $ProfilesDirectory `
            -MismatchCode 'PROFILE_IDENTITY_MISMATCH'
        return [pscustomobject]@{
            Result = 'PROFILE_VERIFY_SUCCESS'
            Profile = $safeName
        }
    }
    finally {
        if ($null -ne $authBytes -and $authBytes.Length -gt 0) {
            [Array]::Clear($authBytes, 0, $authBytes.Length)
        }
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
        Invoke-VerifyCodexProfile -Name $LockedName `
            -ProfilesDirectory $script:ProfilesDirectory
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

    return Get-CodexAccountSlotState -ProfilesDirectory $script:ProfilesDirectory `
        -StateDirectory $script:StateDirectory
}

Export-ModuleMember -Function @(
    'Get-CodexHome',
    'Test-CodexAuthFile',
    'Protect-CodexAuthBytes',
    'Unprotect-CodexAuthBytes',
    'Test-CodexProcessesStopped',
    'Request-CodexDesktopClose',
    'Save-CodexAccountSlot',
    'Get-CodexAccountSlot',
    'Add-CodexProfile',
    'Remove-CodexProfile',
    'Rename-CodexProfile',
    'Test-CodexProfile',
    'Initialize-CodexProfileIdentityMarker',
    'Initialize-CodexActiveProfile',
    'Get-CodexActiveProfile',
    'Switch-CodexAccountProfile'
)
