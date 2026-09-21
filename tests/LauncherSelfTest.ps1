[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$launcherNames = @('Start-Qiehao.cmd', 'Start-Qiehao.bat')

function Assert-LauncherTest {
    param(
        [Parameter(Mandatory = $true)][bool]$Condition,
        [Parameter(Mandatory = $true)][string]$Code
    )

    if (-not $Condition) { throw $Code }
}

function Test-QiehaoLauncher {
    param(
        [Parameter(Mandatory = $true)][string]$LauncherName,
        [Parameter(Mandatory = $true)][string]$TempBase
    )

    $launcherPath = Join-Path $projectRoot $LauncherName
    Assert-LauncherTest -Condition ([System.IO.File]::Exists($launcherPath)) -Code ($LauncherName + '_NOT_FOUND')

    $launcherText = [System.IO.File]::ReadAllText($launcherPath)
    Assert-LauncherTest -Condition ($launcherText -match '(?im)^@echo off\s*$') -Code ($LauncherName + '_ECHO_NOT_DISABLED')
    Assert-LauncherTest -Condition ($launcherText -match '(?i)powershell\.exe') -Code ($LauncherName + '_NOT_USING_WINDOWS_POWERSHELL')
    Assert-LauncherTest -Condition ($launcherText -match '(?i)-NoProfile') -Code ($LauncherName + '_NO_PROFILE_FLAG_MISSING')
    Assert-LauncherTest -Condition ($launcherText -match '(?i)-ExecutionPolicy\s+Bypass') -Code ($LauncherName + '_EXECUTION_POLICY_SCOPE_INVALID')
    Assert-LauncherTest -Condition ($launcherText -match '(?i)-STA') -Code ($LauncherName + '_STA_FLAG_MISSING')
    Assert-LauncherTest -Condition (
        $launcherText -match '(?i)-File\s+"%~dp0gui\\QiehaoGui\.ps1"'
    ) -Code ($LauncherName + '_SELF_DIRECTORY_PATH_INVALID')
    Assert-LauncherTest -Condition (
        $launcherText -notmatch '(?i)\b(?:setx|reg(?:\.exe)?\s+add|runas|Start-Process)\b'
    ) -Code ($LauncherName + '_FORBIDDEN_SYSTEM_MUTATION')

    $extension = [System.IO.Path]::GetExtension($LauncherName).TrimStart('.')
    $testRoot = [System.IO.Path]::GetFullPath((Join-Path $TempBase (
        'qiehao ' + $extension + ' launcher test ' + [Guid]::NewGuid().ToString('N')
    )))
    $foreignCwd = [System.IO.Path]::GetFullPath((Join-Path $TempBase (
        'qiehao ' + $extension + ' launcher foreign ' + [Guid]::NewGuid().ToString('N')
    )))

    foreach ($path in @($testRoot, $foreignCwd)) {
        Assert-LauncherTest -Condition ($path.StartsWith(
            $TempBase + [System.IO.Path]::DirectorySeparatorChar,
            [StringComparison]::OrdinalIgnoreCase
        )) -Code ($LauncherName + '_TEST_PATH_INVALID')
        [System.IO.Directory]::CreateDirectory($path) | Out-Null
    }

    try {
        $testGuiDirectory = Join-Path $testRoot 'gui'
        [System.IO.Directory]::CreateDirectory($testGuiDirectory) | Out-Null
        $testLauncher = Join-Path $testRoot $LauncherName
        [System.IO.File]::Copy($launcherPath, $testLauncher, $false)

        $markerPath = Join-Path $testRoot 'launcher.marker'
        $fakeGuiPath = Join-Path $testGuiDirectory 'QiehaoGui.ps1'
        $fakeGui = (@(
            '$markerPath = Join-Path (Split-Path -Parent $PSScriptRoot) ''launcher.marker'''
            '$payload = ([System.Environment]::CurrentDirectory + [Environment]::NewLine + $PSScriptRoot)'
            '[System.IO.File]::WriteAllText($markerPath, $payload)'
        ) -join [Environment]::NewLine)
        [System.IO.File]::WriteAllText(
            $fakeGuiPath,
            $fakeGui,
            (New-Object System.Text.UTF8Encoding($false))
        )

        $startInfo = New-Object System.Diagnostics.ProcessStartInfo
        $startInfo.FileName = $env:ComSpec
        $startInfo.Arguments = '/d /s /c ""' + $testLauncher + '""'
        $startInfo.WorkingDirectory = $foreignCwd
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true

        $process = [System.Diagnostics.Process]::Start($startInfo)
        if (-not $process.WaitForExit(30000)) {
            try { $process.Kill() } catch {}
            throw ($LauncherName + '_TEST_TIMEOUT')
        }

        $safeStdout = $process.StandardOutput.ReadToEnd()
        $safeStderr = $process.StandardError.ReadToEnd()
        Assert-LauncherTest -Condition ($process.ExitCode -eq 0) -Code ($LauncherName + '_PROCESS_FAILED')
        Assert-LauncherTest -Condition ([System.IO.File]::Exists($markerPath)) -Code ($LauncherName + '_FAKE_ENTRY_NOT_CALLED')

        $markerLines = @([System.IO.File]::ReadAllLines($markerPath))
        Assert-LauncherTest -Condition (
            $markerLines.Count -eq 2 -and
            [System.IO.Path]::GetFullPath($markerLines[0]) -ceq $foreignCwd -and
            [System.IO.Path]::GetFullPath($markerLines[1]) -ceq $testGuiDirectory
        ) -Code ($LauncherName + '_FOREIGN_CWD_RESOLUTION_FAILED')

        Assert-LauncherTest -Condition ([string]::IsNullOrWhiteSpace($safeStdout)) -Code ($LauncherName + '_UNEXPECTED_STDOUT')
        Assert-LauncherTest -Condition ([string]::IsNullOrWhiteSpace($safeStderr)) -Code ($LauncherName + '_UNEXPECTED_STDERR')

        Write-Output ($LauncherName + ': OwnDirectory=True')
        Write-Output ($LauncherName + ': SupportsSpaces=True')
        Write-Output ($LauncherName + ': ForeignCwd=True')
        Write-Output ($LauncherName + ': CorrectArguments=True')
    }
    finally {
        foreach ($path in @($foreignCwd, $testRoot)) {
            if ([System.IO.Directory]::Exists($path)) {
                [System.IO.Directory]::Delete($path, $true)
            }
        }
    }
}

$tempBase = [System.IO.Path]::GetFullPath(
    [System.IO.Path]::GetTempPath()
).TrimEnd([System.IO.Path]::DirectorySeparatorChar)

foreach ($launcherName in $launcherNames) {
    Test-QiehaoLauncher -LauncherName $launcherName -TempBase $tempBase
}

Write-Output 'LauncherUsesOwnDirectory=True'
Write-Output 'LauncherSupportsSpaces=True'
Write-Output 'LauncherForeignCwdPass=True'
Write-Output 'LauncherCorrectArguments=True'
Write-Output 'ProductionGuiStarted=False'
Write-Output 'LAUNCHER_SELFTEST_PASS'
