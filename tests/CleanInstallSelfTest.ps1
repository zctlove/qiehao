[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$tempBase = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::GetTempPath()
).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
$testRoot = [System.IO.Path]::GetFullPath((Join-Path $tempBase (
    'qiehao-clean-install-' + [Guid]::NewGuid().ToString('N')
)))
$hostExecutable = [string](Get-Process -Id $PID).Path

function Assert-CleanInstallTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Code
    )
    if (-not $Condition) { throw $Code }
}

function New-FakeAuthBytes {
    param([Parameter(Mandatory = $true)][string]$Identity)
    $value = [ordered]@{
        auth_mode = 'chatgpt'
        OPENAI_API_KEY = $null
        tokens = [ordered]@{
            id_token = 'CLEAN-INSTALL-FAKE-ID'
            access_token = 'CLEAN-INSTALL-FAKE-ACCESS'
            refresh_token = 'CLEAN-INSTALL-FAKE-REFRESH'
            account_id = $Identity
        }
        last_refresh = '2000-01-01T00:00:00Z'
    }
    $json = $value | ConvertTo-Json -Compress
    try {
        return ,(New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    }
    finally {
        $value = $null
        $json = $null
    }
}

function Copy-CleanRuntime {
    param([Parameter(Mandatory = $true)][string]$Destination)
    [System.IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($fileName in @('Start-Qiehao.cmd', 'qiehao.ps1')) {
        [System.IO.File]::Copy(
            (Join-Path $projectRoot $fileName),
            (Join-Path $Destination $fileName)
        )
    }
    foreach ($directoryName in @('gui', 'lib', 'tools')) {
        Copy-Item -LiteralPath (Join-Path $projectRoot $directoryName) `
            -Destination (Join-Path $Destination $directoryName) -Recurse
    }
}

Assert-CleanInstallTest -Condition (
    $testRoot.StartsWith(
        $tempBase + [System.IO.Path]::DirectorySeparatorChar,
        [StringComparison]::OrdinalIgnoreCase
    )
) -Code 'CLEAN_INSTALL_TEMP_PATH_INVALID'

$windowsIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object System.Security.Principal.WindowsPrincipal(
    $windowsIdentity
)
$isAdministrator = $principal.IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator
)
$windowsIdentity.Dispose()

try {
    [System.IO.Directory]::CreateDirectory($testRoot) | Out-Null
    $recoveryWarningLogAccepted = $false
    $chineseUser = -join @(
        [char]0x6D4B, [char]0x8BD5, [char]0x7528, [char]0x6237
    )
    $chineseDesktop = -join @([char]0x684C, [char]0x9762)
    $chineseApp = -join @([char]0x5207, [char]0x53F7, [char]0x5668)
    $chineseProfile = -join @(
        [char]0x5E72, [char]0x51C0, [char]0x5B89, [char]0x88C5
    )
    foreach ($case in @(
        [pscustomobject]@{
            Name = 'SpacePath'
            Root = Join-Path $testRoot 'Test User\Desktop\Qiehao'
            Profile = 'Clean Space'
        },
        [pscustomobject]@{
            Name = 'ChinesePath'
            Root = Join-Path $testRoot (
                $chineseUser + '\' + $chineseDesktop + '\' + $chineseApp
            )
            Profile = $chineseProfile
        }
    )) {
        Copy-CleanRuntime -Destination $case.Root
        foreach ($forbiddenName in @(
            '.git', 'tests', 'profiles', 'state', 'logs', 'backup'
        )) {
            Assert-CleanInstallTest -Condition (-not [System.IO.Directory]::Exists(
                (Join-Path $case.Root $forbiddenName)
            )) -Code ('CLEAN_INSTALL_NOT_BLANK_' + $case.Name)
        }

        $guiOutput = @(& $hostExecutable -NoProfile -STA `
            -File (Join-Path $case.Root 'gui\QiehaoGui.ps1') `
            -SelfTest 2>&1)
        Assert-CleanInstallTest -Condition ($LASTEXITCODE -eq 0 -and
            @($guiOutput | ForEach-Object { [string]$_ }) -contains
                'GUI_SELFTEST_READY') `
            -Code ('CLEAN_INSTALL_GUI_FAILED_' + $case.Name)

        foreach ($runtimeName in @('profiles', 'state', 'logs', 'backup')) {
            $runtimePath = Join-Path $case.Root $runtimeName
            Assert-CleanInstallTest -Condition (
                [System.IO.Directory]::Exists($runtimePath) -and
                -not ((Get-Item -LiteralPath $runtimePath -Force).Attributes `
                    -band [System.IO.FileAttributes]::ReparsePoint)
            ) -Code ('CLEAN_INSTALL_DIRECTORY_MISSING_' +
                $case.Name + '_' + $runtimeName)
        }
        Assert-CleanInstallTest -Condition (
            -not [System.IO.Directory]::Exists((Join-Path $case.Root '.git')) -and
            -not [System.IO.Directory]::Exists((Join-Path $case.Root 'tests'))
        ) -Code ('CLEAN_INSTALL_DEPENDED_ON_DEVELOPMENT_FILES_' + $case.Name)

        $fakeHome = Join-Path $case.Root 'fake-codex-home'
        [System.IO.Directory]::CreateDirectory($fakeHome) | Out-Null
        $fakeBytes = New-FakeAuthBytes -Identity (
            'CLEAN-INSTALL-' + $case.Name
        )
        $module = $null
        try {
            [System.IO.File]::WriteAllBytes(
                (Join-Path $fakeHome 'auth.json'),
                $fakeBytes
            )
            $module = @(Import-Module `
                (Join-Path $case.Root 'lib\CodexAuth.psm1') `
                -Force -PassThru)[0]
            if (-not $recoveryWarningLogAccepted) {
                & $module {
                    Write-SafeLog -Event `
                        'PROFILE_REMOVE_QUARANTINE_CLEANUP_FAILED'
                }
                $safeLogPath = Join-Path $case.Root 'logs\qiehao.log'
                $safeLogText = [System.IO.File]::ReadAllText($safeLogPath)
                $safeLogEntries = @(
                    [System.IO.File]::ReadAllLines($safeLogPath) |
                        ForEach-Object {
                            ConvertFrom-Json -InputObject $_ -ErrorAction Stop
                        }
                )
                $recoveryWarningLogAccepted = (
                    @($safeLogEntries | Where-Object {
                        [string]$_.event -ceq
                            'PROFILE_REMOVE_QUARANTINE_CLEANUP_FAILED' -and
                        [string]$_.level -ceq 'WARNING'
                    }).Count -eq 1 -and
                    $safeLogText -notmatch
                        '(?i)access_token|refresh_token|id_token|authorization|cookie'
                )
            }
            $addResult = & $module {
                param($Home, $Profiles, $State, $Name)
                Invoke-AddCodexProfile -Name $Name -CodexHome $Home `
                    -ProfilesDirectory $Profiles -StateDirectory $State `
                    -ProcessData @() -UseProvidedProcessData
            } $fakeHome (Join-Path $case.Root 'profiles') `
                (Join-Path $case.Root 'state') $case.Profile
            Assert-CleanInstallTest -Condition (
                $addResult.Result -ceq 'PROFILE_ADD_SUCCESS' -and
                @(Get-ChildItem -LiteralPath (Join-Path $case.Root 'profiles') `
                    -File).Count -eq 3 -and
                [System.IO.File]::Exists(
                    (Join-Path $case.Root 'state\active-profile.json')
                )
            ) -Code ('CLEAN_INSTALL_FAKE_ADD_FAILED_' + $case.Name)
        }
        finally {
            if ($null -ne $fakeBytes -and $fakeBytes.Length -gt 0) {
                [Array]::Clear($fakeBytes, 0, $fakeBytes.Length)
            }
            if ($null -ne $module) {
                Remove-Module -ModuleInfo $module -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # A file or reparse point at a reserved runtime path must never be followed
    # or overwritten by bootstrap.
    $unsafeRoot = Join-Path $testRoot 'unsafe-runtime-path'
    Copy-CleanRuntime -Destination $unsafeRoot
    [System.IO.File]::WriteAllText(
        (Join-Path $unsafeRoot 'profiles'),
        'DO-NOT-OVERWRITE',
        (New-Object System.Text.UTF8Encoding($false))
    )
    $unsafeCode = $null
    try {
        Import-Module (Join-Path $unsafeRoot 'lib\CodexAuth.psm1') `
            -Force -ErrorAction Stop
    }
    catch { $unsafeCode = [string]$_.Exception.Message }
    Assert-CleanInstallTest -Condition (
        $unsafeCode -ceq 'RUNTIME_DIRECTORY_UNSAFE' -and
        [System.IO.File]::ReadAllText(
            (Join-Path $unsafeRoot 'profiles')
        ) -ceq 'DO-NOT-OVERWRITE'
    ) -Code 'CLEAN_INSTALL_UNSAFE_PATH_NOT_REJECTED'
    Assert-CleanInstallTest -Condition $recoveryWarningLogAccepted `
        -Code 'CLEAN_INSTALL_RECOVERY_WARNING_LOG_REJECTED'

    Write-Output 'RuntimeDirectoriesAutoCreated=True'
    Write-Output 'CleanInstallSpacePath=True'
    Write-Output 'CleanInstallChinesePath=True'
    Write-Output ('NonAdministratorExecution=' + [string](-not $isAdministrator))
    Write-Output 'CleanInstallGuiStarted=True'
    Write-Output 'CleanInstallFakeAdd=True'
    Write-Output 'NoGitOrTestsDependency=True'
    Write-Output 'UnsafeRuntimePathRejected=True'
    Write-Output 'RecoveryWarningLogAccepted=True'
    Write-Output 'RealAuthOrProfileRead=False'
    Write-Output 'RealQuotaRpc=False'
    Write-Output 'CLEAN_INSTALL_SELFTEST_PASS'
}
finally {
    if ([System.IO.Directory]::Exists($testRoot)) {
        [System.IO.Directory]::Delete($testRoot, $true)
    }
}
