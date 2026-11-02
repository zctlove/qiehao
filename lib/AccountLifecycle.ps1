# Runs inside CodexAuth module scope. Existing local transactions remain intact.
function Get-QiehaoTokenNeedsRefresh {
    param([byte[]]$Bytes)
    $text = $null; $payloadBytes = $null; $payloadText = $null
    try {
        $text = (New-Object Text.UTF8Encoding($false,$true)).GetString($Bytes)
        $auth = $text | ConvertFrom-Json -ErrorAction Stop
        $segments = ([string]$auth.tokens.access_token).Split('.')
        if ($segments.Length -ne 3) { return $true }
        $payloadBytes = ConvertFrom-CodexBase64Url -Value $segments[1]
        $payloadText = (New-Object Text.UTF8Encoding($false,$true)).GetString($payloadBytes)
        $payload = $payloadText | ConvertFrom-Json -ErrorAction Stop
        $expiry = $payload.PSObject.Properties['exp']
        if ($null -eq $expiry -or $expiry.Value -is [string] -or $expiry.Value -is [bool]) { return $true }
        $seconds = [double]$expiry.Value
        if ([double]::IsNaN($seconds) -or [double]::IsInfinity($seconds)) { return $true }
        return ($seconds -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 600)
    } catch { return $true }
    finally {
        if ($null -ne $payloadBytes) { [Array]::Clear($payloadBytes,0,$payloadBytes.Length) }
        $text = $null; $auth = $null; $payload = $null; $payloadText = $null
    }
}

function Save-QiehaoRefreshedProfileBytes {
    param([string]$Name,[byte[]]$AuthBytes,[string]$ProfilesDirectory)
    $null = Assert-CodexAuthMatchesProfileIdentity -Name $Name -AuthBytes $AuthBytes `
        -ProfilesDirectory $ProfilesDirectory -MismatchCode 'PROFILE_IDENTITY_MISMATCH'
    $paths = Get-StrictProfileArtifactPaths -Name $Name -ProfilesDirectory $ProfilesDirectory
    $oldEncrypted = $null; $oldMetadata = $null; $encrypted = $null; $metadataBytes = $null; $readback = $null
    $started = $false
    try {
        $oldEncrypted = [IO.File]::ReadAllBytes($paths.EncryptedPath)
        $oldMetadata = [IO.File]::ReadAllBytes($paths.MetadataPath)
        $metadata = (New-Object Text.UTF8Encoding($false,$true)).GetString($oldMetadata) | ConvertFrom-Json
        $encrypted = Protect-CodexAuthBytes -Data $AuthBytes
        $metadata.updated_at = [DateTime]::UtcNow.ToString('o')
        $metadata.encrypted_file_size = $encrypted.Length
        $metadataBytes = (New-Object Text.UTF8Encoding($false)).GetBytes(($metadata | ConvertTo-Json -Depth 8 -Compress))
        $started = $true
        Write-AtomicByteFile -Path $paths.EncryptedPath -Bytes $encrypted -Force
        Write-AtomicByteFile -Path $paths.MetadataPath -Bytes $metadataBytes -Force
        $readback = Read-CodexAccountSlotBytes -Name $Name -ProfilesDirectory $ProfilesDirectory
        if (-not (Test-ByteArraysEqual $AuthBytes $readback)) { throw 'AUTH_REFRESH_SAVE_FAILED' }
        $null = Assert-CodexAuthMatchesProfileIdentity -Name $Name -AuthBytes $readback `
            -ProfilesDirectory $ProfilesDirectory -MismatchCode 'PROFILE_IDENTITY_MISMATCH'
        Write-QiehaoDiagnosticEvent -Event 'ACTIVE_PROFILE_AUTH_REFRESHED' -Result 'SUCCESS' -Data @{ Profile = $Name }
    } catch {
        if ($started) {
            try {
                Write-AtomicByteFile -Path $paths.EncryptedPath -Bytes $oldEncrypted -Force
                Write-AtomicByteFile -Path $paths.MetadataPath -Bytes $oldMetadata -Force
                if (-not (Test-ByteArraysEqual $oldEncrypted ([IO.File]::ReadAllBytes($paths.EncryptedPath))) -or
                    -not (Test-ByteArraysEqual $oldMetadata ([IO.File]::ReadAllBytes($paths.MetadataPath)))) { throw 'ROLLBACK_FAILED' }
            } catch { throw (New-SafeException -Code 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED') }
        }
        throw (New-SafeException -Code 'AUTH_REFRESH_SAVE_FAILED')
    } finally {
        foreach ($b in @($oldEncrypted,$oldMetadata,$encrypted,$metadataBytes,$readback)) {
            if ($null -ne $b) { [Array]::Clear($b,0,$b.Length) }
        }
        $metadata = $null
    }
}

function Get-QiehaoRecoveryConsent {
    param([string]$Name,[string]$CodexHome,[string]$ProfilesDirectory,[string]$StateDirectory)
    $current = $null; $saved = $null; $payload = $null
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $null = Assert-CodexFileCredentialSource -CodexHome $CodexHome
        $active = Read-ActiveProfileState -StateDirectory $StateDirectory
        if ($active.ActiveProfile -cne $Name) { throw 'IDENTITY_RECOVERY_NOT_APPLICABLE' }
        $paths = Get-StrictProfileArtifactPaths -Name $Name -ProfilesDirectory $ProfilesDirectory
        if (-not (Get-ProfileMetadataState -Name $Name -ProfilesDirectory $ProfilesDirectory).IsValid) { throw 'PROFILE_METADATA_INVALID' }
        $saved = Read-CodexAccountSlotBytes -Name $Name -ProfilesDirectory $ProfilesDirectory
        $self = Assert-CodexAuthMatchesProfileIdentity -Name $Name -AuthBytes $saved -ProfilesDirectory $ProfilesDirectory -MismatchCode PROFILE_IDENTITY_MISMATCH
        if ($self.WorkspaceContextStatus -cne 'Confirmed' -or $self.SavedWorkspaceClass -cne 'Team') { throw 'IDENTITY_RECOVERY_NOT_APPLICABLE' }
        $current = Read-SensitiveFileBytes -Path (Join-Path $CodexHome 'auth.json')
        $null = Test-CodexAuthBytes -Bytes $current
        $comparison = Compare-CodexAuthToProfileIdentity -Name $Name -AuthBytes $current -ProfilesDirectory $ProfilesDirectory
        if ($comparison.Matches -or $comparison.WorkspaceContextStatus -cne 'Confirmed' -or $comparison.CurrentWorkspaceClass -cne 'Personal') { throw 'IDENTITY_RECOVERY_NOT_APPLICABLE' }
        # This exception is restricted to the confirmed Plus -> saved Team case.
        $auth = (New-Object Text.UTF8Encoding($false,$true)).GetString($current) | ConvertFrom-Json
        $payload = ConvertFrom-CodexBase64Url -Value (([string]$auth.tokens.id_token).Split('.')[1])
        $claims = (New-Object Text.UTF8Encoding($false,$true)).GetString($payload) | ConvertFrom-Json
        if ([string]$claims.'https://api.openai.com/auth'.chatgpt_plan_type -cne 'plus') { throw 'IDENTITY_RECOVERY_NOT_APPLICABLE' }
        $stamps = @([Convert]::ToBase64String($sha.ComputeHash($current)))
        foreach ($path in @($paths.EncryptedPath,$paths.IdentityMarkerPath,$paths.MetadataPath,(Join-Path $StateDirectory 'active-profile.json'))) {
            $bytes = Read-SensitiveFileBytes -Path $path
            try { $stamps += [Convert]::ToBase64String($sha.ComputeHash($bytes)) }
            finally { [Array]::Clear($bytes,0,$bytes.Length) }
        }
        return [pscustomobject]@{ Profile = $Name; Stamp = ($stamps -join '.'); CurrentWorkspace = 'Plus'; SavedWorkspace = 'Team' }
    } finally {
        foreach ($b in @($current,$saved,$payload)) { if ($null -ne $b) { [Array]::Clear($b,0,$b.Length) } }
        $auth = $null; $claims = $null; $sha.Dispose()
    }
}

function Get-CodexIdentityRecoveryConsent {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    return Invoke-WithCodexWriteLock -Operation {
        param($n)
        Assert-CodexNotRunning
        Get-QiehaoRecoveryConsent -Name $n -CodexHome (Get-CodexHome) -ProfilesDirectory $script:ProfilesDirectory -StateDirectory $script:StateDirectory
    } -ArgumentList @($Name)
}

function Invoke-QiehaoAccountVerification {
    param([string]$Name,[string]$CodexHome,[string]$ProfilesDirectory,
        [hashtable]$OwnedProcessRegistry,[object[]]$ProcessData,[switch]$UseProvidedProcessData,
        [string]$TestExecutablePath,[string]$TestProcessArguments,
        [int]$PrimaryBudgetMilliseconds = 8000,[switch]$PreserveSavedProfile)
    $before = $null; $after = $null; $context = $null
    $state = 'TransientFailure'; $transport = $null; $failure = ''
    Write-QiehaoDiagnosticEvent -Event 'ACCOUNT_VERIFY_START' -Result 'STARTED' -Data @{ Profile = $Name }
    try {
        $null = Assert-CodexFileCredentialSource -CodexHome $CodexHome
        Assert-CodexNotRunning -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData
        $authPath = Join-Path $CodexHome 'auth.json'
        $before = Read-SensitiveFileBytes -Path $authPath
        $null = Test-CodexAuthBytes -Bytes $before
        $null = Assert-CodexAuthMatchesProfileIdentity -Name $Name -AuthBytes $before `
            -ProfilesDirectory $ProfilesDirectory -MismatchCode 'PROFILE_IDENTITY_MISMATCH'
        $context = Get-CodexAuthIdentityContext -Bytes $before
        if ($null -ne $OwnedProcessRegistry) { $OwnedProcessRegistry.Stage = 'ACCOUNT_VERIFY_START' }
        $client = Import-Module (Join-Path $PSScriptRoot '..\tools\AccountClient.psm1') -PassThru
        $transport = & $client {
            param($c,$r,$refresh,$exe,$argsText,$budget)
            Invoke-QiehaoAccountTransport -CodexHome $c -OwnedProcessRegistry $r -NeedsRefresh $refresh `
                -TestExecutablePath $exe -TestProcessArguments $argsText -PrimaryBudgetMilliseconds $budget
        } $CodexHome $OwnedProcessRegistry (Get-QiehaoTokenNeedsRefresh $before) $TestExecutablePath $TestProcessArguments $PrimaryBudgetMilliseconds
        $state = [string]$transport.VerificationState
        $failure = [string]$transport.FailureCode
        if (-not $transport.CleanupSucceeded) { throw 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED' }
        if ($transport.RefreshAttempted) {
            Write-QiehaoDiagnosticEvent -Event 'ACCOUNT_REFRESH_START' -Result 'STARTED' -Data @{ Profile = $Name }
            Write-QiehaoDiagnosticEvent -Event 'ACCOUNT_REFRESH_RESULT' -Result $state -Data @{ Profile = $Name; VerificationState = $state }
        }
        # Identity is rechecked even on timeout/permanent failure, before any save.
        $after = Read-SensitiveFileBytes -Path $authPath
        $null = Test-CodexAuthBytes -Bytes $after
        $comparison = Assert-CodexAuthMatchesProfileIdentity -Name $Name -AuthBytes $after `
            -ProfilesDirectory $ProfilesDirectory -MismatchCode 'PROFILE_IDENTITY_MISMATCH'
        Clear-CodexAuthIdentityContext $context
        $context = Get-CodexAuthIdentityContext -Bytes $after
        if ($state -ceq 'Verified') {
            $serverWorkspace = Get-CodexWorkspaceClass -PlanType ([string]$transport.PlanType)
            if ($serverWorkspace -cne 'Unknown' -and $context.WorkspaceClass -cne 'Unknown' -and
                $serverWorkspace -cne $context.WorkspaceClass) { throw 'SWITCH_POST_VERIFY_IDENTITY_MISMATCH' }
            if ($context.WorkspaceClaimStatus -cne 'Confirmed' -or
                $comparison.WorkspaceContextStatus -cne 'Confirmed') { $state = 'Unsupported' }
            else {
                Assert-CodexNotRunning -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData
                if (-not $PreserveSavedProfile -and -not (Test-ByteArraysEqual $before $after)) {
                    Write-QiehaoDiagnosticEvent -Event 'AUTH_REFRESH_DETECTED' -Result 'DETECTED' -Data @{ Profile = $Name }
                    Save-QiehaoRefreshedProfileBytes -Name $Name -AuthBytes $after -ProfilesDirectory $ProfilesDirectory
                }
            }
        }
    } catch {
        $failure = [string]$_.Exception.Message
        if ($failure -eq 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED') { throw }
        $state = switch ($failure) {
            'SWITCH_POST_VERIFY_IDENTITY_MISMATCH' { 'IdentityMismatch' }
            'PROFILE_IDENTITY_MISMATCH' { 'IdentityMismatch' }
            { $_ -in @('AUTH_JSON_INVALID','AUTH_SCHEMA_UNEXPECTED','AUTH_IDENTITY_SCHEMA_UNRECOGNIZED',
                'AUTH_FILE_NOT_FOUND','AUTH_FILE_EMPTY','AUTH_FILE_READ_FAILED',
                'PROFILE_IDENTITY_MARKER_MISSING','PROFILE_IDENTITY_MARKER_INVALID') } { 'IdentityMismatch' }
            'AUTH_CREDENTIAL_SOURCE_UNSUPPORTED' { 'CredentialStoreMismatch' }
            'AUTH_CREDENTIAL_SOURCE_AMBIGUOUS' { 'CredentialStoreMismatch' }
            default { 'TransientFailure' }
        }
        if ($failure -notmatch '^[A-Z][A-Z0-9_]+$') { $failure = 'ACCOUNT_TRANSIENT_FAILURE' }
    } finally {
        foreach ($b in @($before,$after)) { if ($null -ne $b) { [Array]::Clear($b,0,$b.Length) } }
        Clear-CodexAuthIdentityContext $context
        Write-QiehaoDiagnosticEvent -Event 'ACCOUNT_VERIFY_RESULT' -Result $state `
            -Data @{ Profile = $Name; VerificationState = $state; ResultCode = $failure }
    }
    return [pscustomobject]@{ VerificationState = $state; FailureCode = $failure }
}

function Restore-QiehaoSwitchAfterIdentityMismatch {
    param([string]$Name,[string]$CodexHome,[string]$ProfilesDirectory,[string]$StateDirectory,
        [object[]]$ProcessData,[switch]$UseProvidedProcessData)
    $bytes = $null; $readback = $null
    try {
        Assert-CodexNotRunning -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData
        $bytes = Read-CodexAccountSlotBytes -Name $Name -ProfilesDirectory $ProfilesDirectory
        $null = Assert-CodexAuthMatchesProfileIdentity -Name $Name -AuthBytes $bytes `
            -ProfilesDirectory $ProfilesDirectory -MismatchCode 'PROFILE_IDENTITY_MISMATCH'
        $authPath = Join-Path $CodexHome 'auth.json'
        Write-CodexAuthFileBytes -AuthPath $authPath -AuthBytes $bytes
        $readback = Read-SensitiveFileBytes -Path $authPath
        if (-not (Test-ByteArraysEqual $bytes $readback)) { throw 'ROLLBACK_FAILED' }
        Write-ActiveProfileState -Name $Name -StateDirectory $StateDirectory
    } catch { throw (New-SafeException -Code 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED') }
    finally {
        foreach ($b in @($bytes,$readback)) { if ($null -ne $b) { [Array]::Clear($b,0,$b.Length) } }
    }
}

function Invoke-QiehaoVerifiedSwitch {
    param([string]$Name,[string]$CodexHome,[string]$ProfilesDirectory,[string]$StateDirectory,
        [hashtable]$OwnedProcessRegistry,[object[]]$ProcessData,[switch]$UseProvidedProcessData,
        [string]$TestExecutablePath,[string]$TestProcessArguments,[int]$PrimaryBudgetMilliseconds = 8000,
        [object]$IdentityRecoveryConsent)
    $local = Invoke-CodexAccountSwitch -Name $Name -CodexHome $CodexHome `
        -ProfilesDirectory $ProfilesDirectory -StateDirectory $StateDirectory `
        -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData -IdentityRecoveryConsent $IdentityRecoveryConsent
    try {
    $verification = Invoke-QiehaoAccountVerification -Name $Name -CodexHome $CodexHome `
        -ProfilesDirectory $ProfilesDirectory -OwnedProcessRegistry $OwnedProcessRegistry `
        -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData `
        -TestExecutablePath $TestExecutablePath -TestProcessArguments $TestProcessArguments `
        -PrimaryBudgetMilliseconds $PrimaryBudgetMilliseconds -PreserveSavedProfile:($null -ne $IdentityRecoveryConsent)
    } catch {
        if ($null -eq $IdentityRecoveryConsent) { throw }
        Write-QiehaoDiagnosticEvent -Event 'SWITCH_UNVERIFIED' -Result 'SWITCH_RECOVERY_LOCAL_COMMITTED_MANUAL_CHECK_REQUIRED' -Data @{ LocalCommitted = $true }
        return [pscustomobject]@{ Result = 'SWITCH_RECOVERY_LOCAL_COMMITTED_MANUAL_CHECK_REQUIRED'; From = $local.From; To = $Name; LocalCommitted = $true; VerificationState = 'Unverified' }
    }
    if ($null -ne $IdentityRecoveryConsent -and $verification.VerificationState -cne 'Verified') {
        Write-QiehaoDiagnosticEvent -Event 'SWITCH_UNVERIFIED' -Result 'SWITCH_RECOVERY_LOCAL_COMMITTED_UNVERIFIED' `
            -Data @{ LocalCommitted = $true; VerificationState = $verification.VerificationState }
        return [pscustomobject]@{ Result = 'SWITCH_RECOVERY_LOCAL_COMMITTED_UNVERIFIED'; From = $local.From; To = $Name; LocalCommitted = $true; VerificationState = $verification.VerificationState }
    }
    $code = switch ($verification.VerificationState) {
        'Verified' { 'SWITCH_VERIFIED_SUCCESS' }
        'ReauthRequired' { 'SWITCH_REAUTH_REQUIRED' }
        'IdentityMismatch' { 'SWITCH_POST_VERIFY_IDENTITY_MISMATCH' }
        default { 'SWITCH_AUTH_UNVERIFIED_TRANSIENT' }
    }
    if ($verification.VerificationState -ceq 'IdentityMismatch') {
        Restore-QiehaoSwitchAfterIdentityMismatch -Name $local.From -CodexHome $CodexHome `
            -ProfilesDirectory $ProfilesDirectory -StateDirectory $StateDirectory `
            -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData
    }
    $localCommitted = ($verification.VerificationState -cne 'IdentityMismatch')
    $event = switch ($code) { 'SWITCH_VERIFIED_SUCCESS' {'SWITCH_SUCCESS'} 'SWITCH_AUTH_UNVERIFIED_TRANSIENT' {'SWITCH_UNVERIFIED'} default {'SWITCH_FAILED'} }
    Write-QiehaoDiagnosticEvent -Event $event -Result $code `
        -Data @{ ActiveProfile = $(if ($localCommitted) {$Name} else {$local.From}); TargetProfile = $Name; LocalCommitted = $localCommitted; VerificationState = $verification.VerificationState }
    return [pscustomobject]@{ Result = $code; From = $local.From; To = $Name; LocalCommitted = $localCommitted; VerificationState = $verification.VerificationState }
}

function Complete-QiehaoAccountLoginOperation {
    param([hashtable]$Operation, [hashtable]$Registry)
    if ($Operation.Finished) { return }
    $Operation.Finished = $true
    $data = @{ OperationId = $Operation.Id; FinalState = $Operation.FinalState }
    if ($null -ne $Registry -and $Registry.ContainsKey('LoginTimings')) {
        foreach ($key in @('AppServerSpawnMs','InitializeMs','LoginStartRpcMs','BrowserLaunchMs')) {
            $data[$key] = [long]$Registry.LoginTimings[$key]
        }
    }
    Write-QiehaoDiagnosticEvent -Event ('ACCOUNT_LOGIN_' + $Operation.FinalState) -Result $Operation.Code -Data $data
    Write-QiehaoDiagnosticEvent -Event 'ACCOUNT_LOGIN_FINISH' -Result $Operation.Code -Data $data
    if ($null -ne $Registry) { $Registry.OperationFinished = $true; $Registry.FinalState = $Operation.FinalState }
}

function Invoke-QiehaoManagedAdd {
    param([string]$Name,[string]$CodexHome,[string]$ProfilesDirectory,[string]$StateDirectory,
        [hashtable]$OwnedProcessRegistry,[scriptblock]$BrowserProvider,
        [object[]]$ProcessData,[switch]$UseProvidedProcessData,
        [string]$TestExecutablePath,[string]$TestProcessArguments,[int]$LoginBudgetMilliseconds = 180000)
    $original = $null; $candidate = $null; $context = $null; $active = ''; $loginStarted = $false; $saved = $false
    $originalContext = $null; $activeBytes = $null; $activeContext = $null
    $refreshPaths = $null; $oldEncrypted = $null; $oldMetadata = $null; $refreshed = $false
    $operation = @{ Id = [Guid]::NewGuid().ToString('N'); Finished = $false; FinalState = 'FAILED'; Code = 'ACCOUNT_LOGIN_FAILED' }
    if ($null -ne $OwnedProcessRegistry) {
        $OwnedProcessRegistry.OperationId = $operation.Id
        $OwnedProcessRegistry.OperationFinished = $false
        $OwnedProcessRegistry.LoginTimings = @{}
        $OwnedProcessRegistry.NewProfileCommitted = $false
        $OwnedProcessRegistry.AddIdentityWarning = ''
        $OwnedProcessRegistry.LoginStateMayHaveChanged = $false
    }
    Write-QiehaoDiagnosticEvent -Event 'ACCOUNT_LOGIN_START' -Result 'STARTED' -Data @{ OperationId = $operation.Id }
    try {
        Assert-CodexNotRunning -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData
        $null = Assert-CodexFileCredentialSource -CodexHome $CodexHome
        $authPath = Join-Path $CodexHome 'auth.json'
        try { $active = [string](Read-ActiveProfileState -StateDirectory $StateDirectory).ActiveProfile } catch {
            if ($_.Exception.Message -cne 'ACTIVE_PROFILE_NOT_INITIALIZED') { throw }
        }
        if ([IO.File]::Exists($authPath) -or -not [string]::IsNullOrWhiteSpace($active)) {
            $original = Read-SensitiveFileBytes -Path $authPath
            $null = Test-CodexAuthBytes -Bytes $original
            $originalContext = Get-CodexAuthIdentityContext -Bytes $original
            if ($originalContext.WorkspaceClaimStatus -cne 'Confirmed') { throw 'ACCOUNT_LOGIN_IDENTITY_MISMATCH' }
        }
        if (-not [string]::IsNullOrWhiteSpace($active)) {
            # Validate the saved profile independently: corrupt markers/credentials
            # must never be mistaken for a valid, different Desktop login.
            $activeBytes = Read-CodexAccountSlotBytes -Name $active -ProfilesDirectory $ProfilesDirectory
            $null = Assert-CodexAuthMatchesProfileIdentity -Name $active -AuthBytes $activeBytes -ProfilesDirectory $ProfilesDirectory
            $activeContext = Get-CodexAuthIdentityContext -Bytes $activeBytes
            $comparison = Compare-CodexAuthToProfileIdentity -Name $active -AuthBytes $original -ProfilesDirectory $ProfilesDirectory
            if ($comparison.Matches) {
                if (-not (Test-ByteArraysEqual $original $activeBytes)) {
                    $refreshPaths = Get-StrictProfileArtifactPaths -Name $active -ProfilesDirectory $ProfilesDirectory
                    $oldEncrypted = Read-SensitiveFileBytes -Path $refreshPaths.EncryptedPath
                    $oldMetadata = Read-SensitiveFileBytes -Path $refreshPaths.MetadataPath
                    Save-QiehaoRefreshedProfileBytes -Name $active -AuthBytes $original -ProfilesDirectory $ProfilesDirectory
                    $refreshed = $true
                }
            } elseif (-not $originalContext.SupplementalContextKnown -or
                (Test-IdentityByteArraysEqual $originalContext.AccountIdBytes $activeContext.AccountIdBytes)) {
                throw 'ACTIVE_PROFILE_IDENTITY_MISMATCH'
            }
            # A confirmed different account proceeds to official OAuth without
            # updating the old profile. ADD retains its original duplicate gate.
        }
        $client = Import-Module (Join-Path $PSScriptRoot '..\tools\AccountClient.psm1') -PassThru
        $loginStarted = $true
        $operationId = $operation.Id
        $diagnosticModule = $ExecutionContext.SessionState.Module
        $stageLogger = {
            param($event,$timings)
            & $diagnosticModule { param($event,$id) Write-QiehaoDiagnosticEvent -Event $event -Result 'READY' -Data @{ OperationId = $id } } $event $operationId
        }.GetNewClosure()
        $login = & $client {
            param($c,$r,$b,$exe,$argsText,$budget,$logger)
            Invoke-QiehaoManagedLoginTransport -CodexHome $c -OwnedProcessRegistry $r -BrowserProvider $b `
                -TestExecutablePath $exe -TestProcessArguments $argsText -LoginBudgetMilliseconds $budget -EventProvider $logger
        } $CodexHome $OwnedProcessRegistry $BrowserProvider $TestExecutablePath $TestProcessArguments $LoginBudgetMilliseconds $stageLogger
        if ($null -ne $OwnedProcessRegistry -and $OwnedProcessRegistry.ContainsKey('LoginDiagnostics')) {
            Write-QiehaoDiagnosticEvent -Event 'ACCOUNT_LOGIN_DIAGNOSTIC' -Result ([string]$login.FailureCode) -Data $OwnedProcessRegistry.LoginDiagnostics
        }
        if (-not $login.CleanupSucceeded) { throw 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED' }
        if ($login.VerificationState -ceq 'Unsupported') {
            $operation.Code = 'ACCOUNT_LOGIN_MANUAL_FALLBACK_REQUIRED'
            return [pscustomobject]@{ Result = 'ACCOUNT_LOGIN_MANUAL_FALLBACK_REQUIRED'; VerificationState = 'Unsupported' }
        }
        if ($login.VerificationState -cne 'Verified') {
            $code = switch ($login.VerificationState) {
                'Cancelled' { 'ACCOUNT_LOGIN_CANCELLED' }
                'Timeout' { 'ACCOUNT_LOGIN_TIMEOUT' }
                default { 'ACCOUNT_LOGIN_FAILED' }
            }
            if ($login.FailureCode -in @('ACCOUNT_LOGIN_REJECTED','ACCOUNT_LOGIN_COMPLETION_INVALID',
                'ACCOUNT_LOGIN_PROCESS_EXITED','ACCOUNT_LOGIN_CONNECTION_CLOSED','ACCOUNT_LOGIN_INITIALIZE_TIMEOUT',
                'ACCOUNT_LOGIN_START_TIMEOUT','ACCOUNT_LOGIN_READ_TIMEOUT','ACCOUNT_LOGIN_COMPLETION_ID_MISMATCH',
                'ACCOUNT_LOGIN_VERIFY_FAILED','ACCOUNT_TRANSIENT_FAILURE')) { $code = [string]$login.FailureCode }
            $operation.Code = $code
            $operation.FinalState = switch ($login.VerificationState) { 'Cancelled' {'CANCELLED'} 'Timeout' {'TIMEOUT'} default {'FAILED'} }
            return [pscustomobject]@{ Result = $code; VerificationState = $login.VerificationState }
        }
        Assert-CodexNotRunning -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData
        $verificationDeadline = [DateTime]::UtcNow.AddSeconds(5)
        $candidate = Read-SensitiveFileBytes -Path $authPath
        $null = Test-CodexAuthBytes -Bytes $candidate
        $context = Get-CodexAuthIdentityContext -Bytes $candidate
        $serverWorkspace = Get-CodexWorkspaceClass -PlanType ([string]$login.PlanType)
        if ($context.WorkspaceClaimStatus -cne 'Confirmed' -or
            ($serverWorkspace -cne 'Unknown' -and $serverWorkspace -cne $context.WorkspaceClass)) {
            throw (New-SafeException -Code 'ACCOUNT_LOGIN_IDENTITY_MISMATCH')
        }
        if ([DateTime]::UtcNow -ge $verificationDeadline) { throw 'ACCOUNT_TIMEOUT' }
        if ($null -ne $OwnedProcessRegistry -and $OwnedProcessRegistry.ContainsKey('RequestProfileName') -and
            $OwnedProcessRegistry.RequestProfileName) {
            $OwnedProcessRegistry.Stage = 'ACCOUNT_LOGIN_NAME_REQUIRED'
            $nameDeadline = [DateTime]::UtcNow.AddMilliseconds($LoginBudgetMilliseconds)
            while ([string]::IsNullOrWhiteSpace([string]$OwnedProcessRegistry.PickedProfileName)) {
                if ($OwnedProcessRegistry.CancelRequested -or [DateTime]::UtcNow -ge $nameDeadline) {
                    $operation.FinalState = if ($OwnedProcessRegistry.CancelRequested) { 'CANCELLED' } else { 'TIMEOUT' }
                    $operation.Code = 'ACCOUNT_LOGIN_' + $operation.FinalState
                    return [pscustomobject]@{ Result = $operation.Code; VerificationState = $operation.FinalState }
                }
                [Threading.Thread]::Sleep(25)
            }
            $Name = [string]$OwnedProcessRegistry.PickedProfileName
        }
        if ($null -ne $OwnedProcessRegistry) { $OwnedProcessRegistry.Stage = 'ACCOUNT_LOGIN_SAVING' }
        # Local reread/identity preparation has its own short budget. Never stop
        # or reverse the existing atomic ADD transaction after its commit point.
        $verificationDeadline = [DateTime]::UtcNow.AddSeconds(5)
        if ($null -ne $OwnedProcessRegistry -and $OwnedProcessRegistry.CancelRequested) {
            throw 'ACCOUNT_CANCELLED'
        }
        $latestBytes = $null; $latestContext = $null
        try {
            $latestBytes = Read-SensitiveFileBytes -Path $authPath
            $null = Test-CodexAuthBytes -Bytes $latestBytes
            $latestContext = Get-CodexAuthIdentityContext -Bytes $latestBytes
            if (-not (Test-IdentityByteArraysEqual $context.AccountIdBytes $latestContext.AccountIdBytes) -or
                $latestContext.WorkspaceClaimStatus -cne 'Confirmed' -or
                $context.WorkspaceClass -cne $latestContext.WorkspaceClass -or
                ($null -ne $context.UserIdBytes -and -not (Test-IdentityByteArraysEqual $context.UserIdBytes $latestContext.UserIdBytes))) {
                throw (New-SafeException -Code 'ACCOUNT_LOGIN_IDENTITY_MISMATCH')
            }
        } finally {
            if ($null -ne $latestBytes) { [Array]::Clear($latestBytes,0,$latestBytes.Length) }
            Clear-CodexAuthIdentityContext $latestContext
        }
        if ([DateTime]::UtcNow -ge $verificationDeadline) { throw 'ACCOUNT_TIMEOUT' }
        if ($null -ne $OwnedProcessRegistry -and $OwnedProcessRegistry.CancelRequested) { throw 'ACCOUNT_CANCELLED' }
        $result = Invoke-AddCodexProfile -Name $Name -CodexHome $CodexHome `
            -ProfilesDirectory $ProfilesDirectory -StateDirectory $StateDirectory `
            -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData
        $saved = $true
        $operation.FinalState = 'SUCCEEDED'; $operation.Code = 'ADD_VERIFIED_SUCCESS'
        if ($null -ne $OwnedProcessRegistry) { $OwnedProcessRegistry.NewProfileCommitted = $true }
        return [pscustomobject]@{ Result = 'ADD_VERIFIED_SUCCESS'; Profile = $result.Profile; VerificationState = 'Verified' }
    } catch {
        $operation.Code = [string]$_.Exception.Message
        if ($operation.Code -notmatch '^[A-Z][A-Z0-9_]+$') { $operation.Code = 'ACCOUNT_LOGIN_FAILED' }
        if ($operation.Code -ceq 'ACCOUNT_CANCELLED') {
            $operation.FinalState = 'CANCELLED'; $operation.Code = 'ACCOUNT_LOGIN_CANCELLED'
            return [pscustomobject]@{ Result = $operation.Code; VerificationState = 'Cancelled' }
        }
        if ($operation.Code -ceq 'ACCOUNT_TIMEOUT') {
            $operation.FinalState = 'TIMEOUT'; $operation.Code = 'ACCOUNT_LOGIN_TIMEOUT'
            return [pscustomobject]@{ Result = $operation.Code; VerificationState = 'Timeout' }
        }
        throw
    } finally {
        # Undo only our optional profile refresh. OAuth owns current auth.json;
        # failure/cancellation must never restore an old login or active state.
        try {
            if ($refreshed -and -not $saved) {
                Write-AtomicByteFile -Path $refreshPaths.EncryptedPath -Bytes $oldEncrypted -Force
                Write-AtomicByteFile -Path $refreshPaths.MetadataPath -Bytes $oldMetadata -Force
                if (-not (Test-ByteArraysEqual $oldEncrypted ([IO.File]::ReadAllBytes($refreshPaths.EncryptedPath))) -or
                    -not (Test-ByteArraysEqual $oldMetadata ([IO.File]::ReadAllBytes($refreshPaths.MetadataPath)))) { throw 'ROLLBACK_FAILED' }
            }
            if ($loginStarted -and -not $saved) {
                $currentBytes = $null; $currentContext = $null; $warning = ''
                try {
                    $null = Assert-CodexFileCredentialSource -CodexHome $CodexHome
                    $currentBytes = Read-SensitiveFileBytes -Path $authPath
                    if ($null -eq $original -or -not (Test-ByteArraysEqual $original $currentBytes)) {
                        if ($null -ne $OwnedProcessRegistry) { $OwnedProcessRegistry.LoginStateMayHaveChanged = $true }
                        $warning = 'ACCOUNT_LOGIN_STATE_CHANGED_NOT_SAVED'
                    }
                    $null = Test-CodexAuthBytes -Bytes $currentBytes
                    $currentContext = Get-CodexAuthIdentityContext -Bytes $currentBytes
                    if ($currentContext.WorkspaceClaimStatus -cne 'Confirmed') { $warning = 'ACCOUNT_LOGIN_IDENTITY_MISMATCH' }
                    elseif (-not [string]::IsNullOrWhiteSpace($active)) {
                        $comparison = Compare-CodexAuthToProfileIdentity -Name $active -AuthBytes $currentBytes -ProfilesDirectory $ProfilesDirectory
                        if (-not $comparison.Matches -and -not $warning) { $warning = 'ACTIVE_PROFILE_OUT_OF_SYNC' }
                    }
                } catch {
                    $warning = 'ACCOUNT_LOGIN_IDENTITY_MISMATCH'
                } finally {
                    if ($null -ne $currentBytes) { [Array]::Clear($currentBytes,0,$currentBytes.Length) }
                    Clear-CodexAuthIdentityContext $currentContext
                }
                if ($null -ne $OwnedProcessRegistry -and $OwnedProcessRegistry.ContainsKey('LoginStateMayHaveChanged') -and $OwnedProcessRegistry.LoginStateMayHaveChanged) { $warning = 'ACCOUNT_LOGIN_STATE_CHANGED_NOT_SAVED' }
                if ($warning) {
                    if ($null -ne $OwnedProcessRegistry) { $OwnedProcessRegistry.AddIdentityWarning = $warning }
                    Write-QiehaoDiagnosticEvent -Event 'CURRENT_IDENTITY_RESULT' -Result $warning -Data @{ ActiveProfile = $active }
                }
            }
        } catch {
            $operation.FinalState = 'MANUAL_RECOVERY_REQUIRED'
            $operation.Code = 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED'
            throw (New-SafeException -Code $operation.Code)
        } finally {
            if ($operation.Code -ceq 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED') { $operation.FinalState = 'MANUAL_RECOVERY_REQUIRED' }
            foreach ($b in @($original,$candidate,$activeBytes,$oldEncrypted,$oldMetadata)) { if ($null -ne $b) { [Array]::Clear($b,0,$b.Length) } }
            Clear-CodexAuthIdentityContext $context
            Clear-CodexAuthIdentityContext $originalContext
            Clear-CodexAuthIdentityContext $activeContext
            Complete-QiehaoAccountLoginOperation -Operation $operation -Registry $OwnedProcessRegistry
        }
    }
}

function Add-CodexManagedProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name,[hashtable]$OwnedProcessRegistry)
    return Invoke-WithCodexWriteLock -Operation {
        param($n,$r)
        Invoke-QiehaoManagedAdd -Name $n -OwnedProcessRegistry $r -CodexHome (Get-CodexHome) `
            -ProfilesDirectory $script:ProfilesDirectory -StateDirectory $script:StateDirectory
    } -ArgumentList @($Name,$OwnedProcessRegistry)
}

function Invoke-QiehaoVerifiedLocalAdd {
    param([string]$Name,[string]$CodexHome,[string]$ProfilesDirectory,[string]$StateDirectory,
        [hashtable]$OwnedProcessRegistry,[object[]]$ProcessData,[switch]$UseProvidedProcessData,
        [string]$TestExecutablePath,[string]$TestProcessArguments)
    $before = $null; $after = $null; $initial = $null; $current = $null
    try {
        Assert-CodexNotRunning -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData
        $null = Assert-CodexFileCredentialSource -CodexHome $CodexHome
        $authPath = Join-Path $CodexHome 'auth.json'
        $before = Read-SensitiveFileBytes -Path $authPath
        $null = Test-CodexAuthBytes -Bytes $before
        $initial = Get-CodexAuthIdentityContext -Bytes $before
        $client = Import-Module (Join-Path $PSScriptRoot '..\tools\AccountClient.psm1') -PassThru
        $verification = & $client {
            param($c,$r,$exe,$argsText)
            Invoke-QiehaoAccountTransport -CodexHome $c -OwnedProcessRegistry $r -NeedsRefresh $false `
                -TestExecutablePath $exe -TestProcessArguments $argsText
        } $CodexHome $OwnedProcessRegistry $TestExecutablePath $TestProcessArguments
        if (-not $verification.CleanupSucceeded) { throw 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED' }
        if ($verification.VerificationState -ceq 'ReauthRequired') {
            return [pscustomobject]@{ Result = 'ADD_REAUTH_REQUIRED'; VerificationState = 'ReauthRequired' }
        }
        if ($verification.VerificationState -ceq 'CredentialStoreMismatch') { throw 'AUTH_CREDENTIAL_SOURCE_UNSUPPORTED' }
        $after = Read-SensitiveFileBytes -Path $authPath
        $null = Test-CodexAuthBytes -Bytes $after
        $current = Get-CodexAuthIdentityContext -Bytes $after
        if (-not (Test-IdentityByteArraysEqual $initial.AccountIdBytes $current.AccountIdBytes) -or
            $initial.WorkspaceClass -cne $current.WorkspaceClass -or
            $initial.WorkspaceClaimStatus -cne $current.WorkspaceClaimStatus -or
            ($null -ne $initial.UserIdBytes -and -not (Test-IdentityByteArraysEqual $initial.UserIdBytes $current.UserIdBytes))) {
            throw 'PROFILE_IDENTITY_MISMATCH'
        }
        $state = [string]$verification.VerificationState
        if ($state -ceq 'Verified') {
            $serverWorkspace = Get-CodexWorkspaceClass -PlanType ([string]$verification.PlanType)
            if ($serverWorkspace -cne 'Unknown' -and $serverWorkspace -cne $current.WorkspaceClass) { throw 'PROFILE_IDENTITY_MISMATCH' }
            if ($current.WorkspaceClaimStatus -cne 'Confirmed') { $state = 'Unsupported' }
        }
        Assert-CodexNotRunning -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData
        $added = Invoke-AddCodexProfile -Name $Name -CodexHome $CodexHome `
            -ProfilesDirectory $ProfilesDirectory -StateDirectory $StateDirectory `
            -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData
        $code = if ($state -ceq 'Verified') { 'ADD_VERIFIED_SUCCESS' } else { 'ADD_SUCCESS_UNVERIFIED' }
        return [pscustomobject]@{ Result = $code; Profile = $added.Profile; VerificationState = $state }
    } finally {
        foreach ($bytes in @($before,$after)) { if ($null -ne $bytes) { [Array]::Clear($bytes,0,$bytes.Length) } }
        Clear-CodexAuthIdentityContext $initial
        Clear-CodexAuthIdentityContext $current
    }
}

function Add-CodexVerifiedLocalProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name,[hashtable]$OwnedProcessRegistry)
    return Invoke-WithCodexWriteLock -Operation {
        param($n,$r)
        Invoke-QiehaoVerifiedLocalAdd -Name $n -OwnedProcessRegistry $r -CodexHome (Get-CodexHome) `
            -ProfilesDirectory $script:ProfilesDirectory -StateDirectory $script:StateDirectory
    } -ArgumentList @($Name,$OwnedProcessRegistry)
}

# OAuth completion may be rejected after Desktop changed auth.json. Inspect the
# current identity without refreshing tokens or changing any saved state.
function Invoke-QiehaoInspectOAuthFallback {
    param([string]$CodexHome,[string]$ProfilesDirectory,
        [hashtable]$OwnedProcessRegistry,[object[]]$ProcessData,
        [switch]$UseProvidedProcessData,[string]$TestExecutablePath,
        [string]$TestProcessArguments)
    $before = $null; $after = $null; $identity = $null; $context = $null
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        Assert-CodexNotRunning -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData
        $null = Assert-CodexFileCredentialSource -CodexHome $CodexHome
        $authPath = Join-Path $CodexHome 'auth.json'
        $before = Read-SensitiveFileBytes -Path $authPath
        $null = Test-CodexAuthBytes -Bytes $before
        $context = Get-CodexAuthIdentityContext -Bytes $before
        if (-not $context.SupplementalContextKnown -or
            (Get-QiehaoTokenNeedsRefresh $before)) {
            return [pscustomobject]@{ Result = 'ACCOUNT_FALLBACK_IDENTITY_UNVERIFIED' }
        }
        $identity = Get-CodexAuthIdentityBytes -Bytes $before
        if ((Test-ProfileIdentityExists -IdentityBytes $identity -AuthBytes $before `
                -ProfilesDirectory $ProfilesDirectory).Exists) {
            return [pscustomobject]@{ Result = 'ACCOUNT_FALLBACK_IDENTITY_ALREADY_SAVED' }
        }
        $client = Import-Module (Join-Path $PSScriptRoot '..\tools\AccountClient.psm1') -PassThru
        $verification = & $client {
            param($c,$r,$exe,$argsText)
            Invoke-QiehaoAccountTransport -CodexHome $c -OwnedProcessRegistry $r `
                -NeedsRefresh $false -NoRefresh -TestExecutablePath $exe `
                -TestProcessArguments $argsText
        } $CodexHome $OwnedProcessRegistry $TestExecutablePath $TestProcessArguments
        if (-not $verification.CleanupSucceeded) { throw 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED' }
        $after = Read-SensitiveFileBytes -Path $authPath
        if (-not (Test-ByteArraysEqual $before $after)) {
            throw 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED'
        }
        $serverWorkspace = Get-CodexWorkspaceClass -PlanType ([string]$verification.PlanType)
        if ($verification.VerificationState -cne 'Verified' -or
            $serverWorkspace -ceq 'Unknown' -or
            $serverWorkspace -cne $context.WorkspaceClass) {
            return [pscustomobject]@{ Result = 'ACCOUNT_FALLBACK_IDENTITY_UNVERIFIED' }
        }
        return [pscustomobject]@{
            Result = 'ACCOUNT_FALLBACK_IDENTITY_VERIFIED'
            Consent = [pscustomobject]@{
                AuthHash = [Convert]::ToBase64String($sha.ComputeHash($before))
                CheckedUtc = [DateTime]::UtcNow.ToString('o')
            }
        }
    } catch {
        if ($_.Exception.Message -ceq 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED') { throw }
        return [pscustomobject]@{ Result = 'ACCOUNT_FALLBACK_IDENTITY_UNVERIFIED' }
    } finally {
        foreach ($b in @($before,$after,$identity)) {
            if ($null -ne $b) { [Array]::Clear($b,0,$b.Length) }
        }
        Clear-CodexAuthIdentityContext $context
        $sha.Dispose()
    }
}

function Get-QiehaoOAuthFallbackIdentity {
    [CmdletBinding()]
    param([hashtable]$OwnedProcessRegistry)
    return Invoke-WithCodexWriteLock -Operation {
        param($r)
        Invoke-QiehaoInspectOAuthFallback -CodexHome (Get-CodexHome) `
            -ProfilesDirectory $script:ProfilesDirectory -OwnedProcessRegistry $r
    } -ArgumentList @($OwnedProcessRegistry)
}

function Invoke-QiehaoSaveCheckedFallback {
    param([string]$Name,[object]$Consent,[string]$CodexHome,
        [string]$ProfilesDirectory,[string]$StateDirectory,
        [object[]]$ProcessData,[switch]$UseProvidedProcessData)
    if ($null -eq $Consent -or
        [string]$Consent.AuthHash -notmatch '^[A-Za-z0-9+/]{43}=$') {
        throw 'ACCOUNT_FALLBACK_CHECK_EXPIRED'
    }
    $checkedUtc = [DateTime]::MinValue
    if (-not [DateTime]::TryParse([string]$Consent.CheckedUtc,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind,[ref]$checkedUtc) -or
        $checkedUtc.Kind -cne [DateTimeKind]::Utc -or
        [DateTime]::UtcNow -lt $checkedUtc -or
        [DateTime]::UtcNow -gt $checkedUtc.AddMinutes(2)) {
        throw 'ACCOUNT_FALLBACK_CHECK_EXPIRED'
    }
    $authStream = $null; $bytes = $null; $identity = $null; $context = $null
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        Assert-CodexNotRunning -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData
        $null = Assert-CodexFileCredentialSource -CodexHome $CodexHome
        $safeName = ConvertTo-SafeProfileName -Name $Name
        $paths = Get-StrictProfileArtifactPaths -Name $safeName -ProfilesDirectory $ProfilesDirectory
        if (Test-AnyProfileArtifactExists -Paths $paths) { throw 'PROFILE_NAME_ALREADY_EXISTS' }
        $authStream = [IO.FileStream]::new((Join-Path $CodexHome 'auth.json'),
            [IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
        $bytes = Read-SensitiveFileBytes -Path (Join-Path $CodexHome 'auth.json')
        if ([Convert]::ToBase64String($sha.ComputeHash($bytes)) -cne [string]$Consent.AuthHash) {
            throw 'ACCOUNT_FALLBACK_STATE_CHANGED'
        }
        $null = Test-CodexAuthBytes -Bytes $bytes
        $context = Get-CodexAuthIdentityContext -Bytes $bytes
        if (-not $context.SupplementalContextKnown -or
            (Get-QiehaoTokenNeedsRefresh $bytes)) { throw 'ACCOUNT_FALLBACK_IDENTITY_UNVERIFIED' }
        $identity = Get-CodexAuthIdentityBytes -Bytes $bytes
        if ((Test-ProfileIdentityExists -IdentityBytes $identity -AuthBytes $bytes `
                -ProfilesDirectory $ProfilesDirectory).Exists) {
            throw 'PROFILE_IDENTITY_ALREADY_EXISTS'
        }
        $added = Invoke-AddCodexProfile -Name $safeName -CodexHome $CodexHome `
            -ProfilesDirectory $ProfilesDirectory -StateDirectory $StateDirectory `
            -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData
        return [pscustomobject]@{
            Result = 'ADD_VERIFIED_SUCCESS'; Profile = $added.Profile
            VerificationState = 'Verified'
        }
    } finally {
        if ($null -ne $authStream) { $authStream.Dispose() }
        foreach ($b in @($bytes,$identity)) {
            if ($null -ne $b) { [Array]::Clear($b,0,$b.Length) }
        }
        Clear-CodexAuthIdentityContext $context
        $sha.Dispose()
    }
}

function Add-CodexCheckedFallbackProfile {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][object]$Consent)
    return Invoke-WithCodexWriteLock -Operation {
        param($n,$approval)
        Invoke-QiehaoSaveCheckedFallback -Name $n -Consent $approval `
            -CodexHome (Get-CodexHome) -ProfilesDirectory $script:ProfilesDirectory `
            -StateDirectory $script:StateDirectory
    } -ArgumentList @($Name,$Consent)
}

function Invoke-QiehaoLayeredVerify {
    param([string]$Name,[string]$CodexHome,[string]$ProfilesDirectory,[string]$StateDirectory,
        [hashtable]$OwnedProcessRegistry,[object[]]$ProcessData,[switch]$UseProvidedProcessData,
        [string]$TestExecutablePath,[string]$TestProcessArguments)
    $active = [string](Read-ActiveProfileState -StateDirectory $StateDirectory).ActiveProfile
    if ($active -cne $Name) {
        $bytes = $null
        try {
            $metadata = Get-ProfileMetadataState -Name $Name -ProfilesDirectory $ProfilesDirectory
            if (-not $metadata.IsValid) { throw 'PROFILE_METADATA_INVALID' }
            $bytes = Read-CodexAccountSlotBytes -Name $Name -ProfilesDirectory $ProfilesDirectory
            $null = Assert-CodexAuthMatchesProfileIdentity -Name $Name -AuthBytes $bytes `
                -ProfilesDirectory $ProfilesDirectory -MismatchCode 'PROFILE_IDENTITY_MISMATCH'
            return [pscustomobject]@{ Result = 'PROFILE_INTEGRITY_ONLY_SUCCESS'; Profile = $Name; ProfileIntegrity = 'Complete'; VerificationState = 'NotApplicable' }
        } finally { if ($null -ne $bytes) { [Array]::Clear($bytes,0,$bytes.Length) } }
    }
    $local = Invoke-VerifyCodexProfile -Name $Name -ProfilesDirectory $ProfilesDirectory `
        -CodexHome $CodexHome -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData
    if ($local.Result -cne 'PROFILE_VERIFY_SUCCESS') { return $local }
    $verification = Invoke-QiehaoAccountVerification -Name $Name -CodexHome $CodexHome `
        -ProfilesDirectory $ProfilesDirectory -OwnedProcessRegistry $OwnedProcessRegistry `
        -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData `
        -TestExecutablePath $TestExecutablePath -TestProcessArguments $TestProcessArguments
    $code = switch ($verification.VerificationState) {
        'Verified' { 'PROFILE_ACCOUNT_VERIFIED' }
        'ReauthRequired' { 'PROFILE_ACCOUNT_REAUTH_REQUIRED' }
        'IdentityMismatch' { 'PROFILE_VERIFY_IDENTITY_MISMATCH' }
        default { 'PROFILE_ACCOUNT_UNVERIFIED' }
    }
    $local.Result = $code
    $local | Add-Member -NotePropertyName VerificationState -NotePropertyValue $verification.VerificationState
    return $local
}
