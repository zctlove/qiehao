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

function Invoke-QiehaoAccountVerification {
    param([string]$Name,[string]$CodexHome,[string]$ProfilesDirectory,
        [hashtable]$OwnedProcessRegistry,[object[]]$ProcessData,[switch]$UseProvidedProcessData,
        [string]$TestExecutablePath,[string]$TestProcessArguments,
        [int]$PrimaryBudgetMilliseconds = 4800)
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
                if (-not (Test-ByteArraysEqual $before $after)) {
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
        [string]$TestExecutablePath,[string]$TestProcessArguments,[int]$PrimaryBudgetMilliseconds = 4800)
    $local = Invoke-CodexAccountSwitch -Name $Name -CodexHome $CodexHome `
        -ProfilesDirectory $ProfilesDirectory -StateDirectory $StateDirectory `
        -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData
    $verification = Invoke-QiehaoAccountVerification -Name $Name -CodexHome $CodexHome `
        -ProfilesDirectory $ProfilesDirectory -OwnedProcessRegistry $OwnedProcessRegistry `
        -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData `
        -TestExecutablePath $TestExecutablePath -TestProcessArguments $TestProcessArguments `
        -PrimaryBudgetMilliseconds $PrimaryBudgetMilliseconds
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
    $operation = @{ Id = [Guid]::NewGuid().ToString('N'); Finished = $false; FinalState = 'FAILED'; Code = 'ACCOUNT_LOGIN_FAILED' }
    if ($null -ne $OwnedProcessRegistry) {
        $OwnedProcessRegistry.OperationId = $operation.Id
        $OwnedProcessRegistry.OperationFinished = $false
        $OwnedProcessRegistry.LoginTimings = @{}
        $OwnedProcessRegistry.NewProfileCommitted = $false
    }
    Write-QiehaoDiagnosticEvent -Event 'ACCOUNT_LOGIN_START' -Result 'STARTED' -Data @{ OperationId = $operation.Id }
    try {
        Assert-CodexNotRunning -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData
        $null = Assert-CodexFileCredentialSource -CodexHome $CodexHome
        $authPath = Join-Path $CodexHome 'auth.json'
        try { $active = [string](Read-ActiveProfileState -StateDirectory $StateDirectory).ActiveProfile } catch {
            if ($_.Exception.Message -cne 'ACTIVE_PROFILE_NOT_INITIALIZED') { throw }
        }
        if ([IO.File]::Exists($authPath)) { $original = Read-SensitiveFileBytes -Path $authPath }
        if (-not [string]::IsNullOrWhiteSpace($active)) {
            $null = Assert-CodexAuthMatchesProfileIdentity -Name $active -AuthBytes $original -ProfilesDirectory $ProfilesDirectory
            Save-QiehaoRefreshedProfileBytes -Name $active -AuthBytes $original -ProfilesDirectory $ProfilesDirectory
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
        # A failed/cancelled ceremony must not strand an existing active account.
        try {
            if ($loginStarted -and -not $saved -and -not [string]::IsNullOrWhiteSpace($active)) {
                Restore-QiehaoSwitchAfterIdentityMismatch -Name $active -CodexHome $CodexHome `
                    -ProfilesDirectory $ProfilesDirectory -StateDirectory $StateDirectory `
                    -ProcessData $ProcessData -UseProvidedProcessData:$UseProvidedProcessData
            }
        } catch {
            $operation.FinalState = 'MANUAL_RECOVERY_REQUIRED'
            $operation.Code = 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED'
            throw (New-SafeException -Code $operation.Code)
        } finally {
            if ($operation.Code -ceq 'DO_NOT_START_CODEX_MANUAL_RECOVERY_REQUIRED') { $operation.FinalState = 'MANUAL_RECOVERY_REQUIRED' }
            foreach ($b in @($original,$candidate)) { if ($null -ne $b) { [Array]::Clear($b,0,$b.Length) } }
            Clear-CodexAuthIdentityContext $context
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
