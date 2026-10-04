[CmdletBinding()]
param([string]$PackageRoot = '')
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($PackageRoot)) { $PackageRoot = $projectRoot }
$exe = Join-Path $PackageRoot 'Qiehao.exe'
function Assert-ExeTest([bool]$Condition, [string]$Code) {
    if (-not $Condition) { throw $Code }
}
Assert-ExeTest ([IO.File]::Exists($exe)) 'EXE_MISSING'
Assert-ExeTest ([IO.File]::Exists((Join-Path $PackageRoot 'Start-Qiehao.cmd'))) 'CMD_MISSING'
Assert-ExeTest (-not [IO.File]::Exists((Join-Path $PackageRoot 'Start-Qiehao.bat'))) 'BAT_PRESENT'
$bytes = [IO.File]::ReadAllBytes($exe)
$pe = [BitConverter]::ToInt32($bytes,60)
Assert-ExeTest ([BitConverter]::ToUInt16($bytes,$pe+92) -eq 2) 'EXE_NOT_GUI_SUBSYSTEM'
$version = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe)
Assert-ExeTest ($version.FileVersion -eq '1.1.0.0' -and $version.ProductVersion -eq '1.1.0') 'EXE_VERSION'
Assert-ExeTest ($version.ProductName -eq 'Qiehao' -and $version.CompanyName -ne 'OpenAI') 'EXE_PRODUCT'
$source = [IO.File]::ReadAllText((Join-Path $projectRoot 'launcher\QiehaoLauncher.cs'))
Assert-ExeTest ($source -notmatch '(?i)cmd\.exe|Start-Qiehao\.cmd\s*\)|auth\.json|DPAPI|app-server|HttpClient|WebRequest|GetProcesses|CredentialManager|Mutex|refresh_token|access_token') 'FORBIDDEN_LAUNCHER_LOGIC'

$assembly = [Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($exe))
$type = $assembly.GetType('QiehaoLauncher.Launcher',$true)
$flags = [Reflection.BindingFlags]'Static,NonPublic'
$create = $type.GetMethod('CreateStartInfo',$flags)
$run = $type.GetMethod('Run',$flags)
$quote = $type.GetMethod('QuoteArgument',$flags)
$windowsDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
$info = $create.Invoke($null,@($PackageRoot,$windowsDirectory))
$expectedPowerShell = Join-Path $windowsDirectory 'System32\WindowsPowerShell\v1.0\powershell.exe'
Assert-ExeTest ($info.FileName -ceq $expectedPowerShell) 'EXE_PS_PATH'
Assert-ExeTest ($info.WorkingDirectory -ceq $PackageRoot) 'EXE_CWD'
Assert-ExeTest ($info.CreateNoWindow -and -not $info.UseShellExecute -and $info.WindowStyle -eq [Diagnostics.ProcessWindowStyle]::Hidden) 'EXE_WINDOW_FLAGS'
Assert-ExeTest ($info.Arguments -ceq ('-NoProfile -ExecutionPolicy Bypass -STA -File "' + (Join-Path $PackageRoot 'gui\QiehaoGui.ps1') + '"')) 'EXE_ARGUMENTS'
Assert-ExeTest ($quote.Invoke($null,@('')) -ceq '""') 'QUOTE_EMPTY'
Assert-ExeTest ($quote.Invoke($null,@('end\')) -ceq '"end\\"') 'QUOTE_TRAILING_SLASH'
Assert-ExeTest ($quote.Invoke($null,@('a"b')) -ceq '"a\"b"') 'QUOTE_EMBEDDED'

$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$testRoot = Join-Path $tempBase ('Qiehao-test5-exe-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$foreign = Join-Path $testRoot 'foreign working directory'
[IO.Directory]::CreateDirectory($foreign) | Out-Null
$messages = New-Object 'Collections.Generic.List[string]'
$showError = [Action[string]]{ param($message) $messages.Add($message) }
$mustNotStart = [Action[Diagnostics.ProcessStartInfo]]{ param($unused) throw 'UNEXPECTED_START' }
try {
    $missingRoot = Join-Path $testRoot 'missing-script'
    $code = $run.Invoke($null,@([string]$missingRoot,[string]$windowsDirectory,$mustNotStart,$showError))
    Assert-ExeTest ($code -eq 1 -and $messages[0] -eq $type.GetField('ScriptMissing',$flags).GetRawConstantValue()) 'SAFE_SCRIPT_MISSING'
    $missingWindows = Join-Path $testRoot 'missing-windows'
    $code = $run.Invoke($null,@([string]$PackageRoot,[string]$missingWindows,$mustNotStart,$showError))
    Assert-ExeTest ($code -eq 1 -and $messages[1] -eq $type.GetField('PowerShellMissing',$flags).GetRawConstantValue()) 'SAFE_PS_MISSING'
    $failingStart = [Action[Diagnostics.ProcessStartInfo]]{ param($unused) throw 'token=FAKE_SECRET_NO_OUTPUT' }
    $code = $run.Invoke($null,@([string]$PackageRoot,[string]$windowsDirectory,$failingStart,$showError))
    Assert-ExeTest ($code -eq 1 -and $messages[2] -eq $type.GetField('StartFailed',$flags).GetRawConstantValue()) 'SAFE_START_FAILURE'
    Assert-ExeTest (($messages -join ' ') -notmatch 'FAKE_SECRET|token=|at Qiehao') 'ERROR_LEAK'
    $fakeChinese = [string][char]0x6D4B + [char]0x8BD5 + [char]0x76EE + [char]0x5F55
    foreach ($name in @('Qiehao Test',$fakeChinese,'Qiehao (Test)')) {
        $root = Join-Path $testRoot $name
        $gui = Join-Path $root 'gui'
        [IO.Directory]::CreateDirectory($gui) | Out-Null
        Copy-Item -LiteralPath $exe -Destination (Join-Path $root 'Qiehao.exe')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'FakeLauncherGui.ps1') -Destination (Join-Path $gui 'QiehaoGui.ps1')
        $outer = New-Object Diagnostics.ProcessStartInfo
        $outer.FileName = Join-Path $root 'Qiehao.exe'
        $outer.WorkingDirectory = $foreign
        $outer.UseShellExecute = $false
        $outer.CreateNoWindow = $true
        $outer.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
        $process = [Diagnostics.Process]::Start($outer)
        try {
            Assert-ExeTest ($process.WaitForExit(10000)) 'EXE_DID_NOT_EXIT'
            Assert-ExeTest ($process.ExitCode -eq 0) 'EXE_START_FAILED'
        } finally { $process.Dispose() }
        $marker = Join-Path $root 'launch-result.json'
        $deadline = [Diagnostics.Stopwatch]::StartNew()
        while (-not [IO.File]::Exists($marker) -and $deadline.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 100 }
        Assert-ExeTest ([IO.File]::Exists($marker)) 'FAKE_GUI_NOT_STARTED'
        # A short retry handles the fake writer completing its final flush.
        $result = $null
        for ($attempt=0; $attempt -lt 10; $attempt++) {
            try { $result = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json; if ($null -ne $result) { break } } catch {}
            Start-Sleep -Milliseconds 100
        }
        Assert-ExeTest ($null -ne $result) 'FAKE_RESULT_INVALID'
        Assert-ExeTest ($result.WorkingDirectory -ceq $root -and $result.ScriptDirectory -ceq $gui) 'EXE_PATH_CWD'
        Assert-ExeTest ($result.ConsoleHandleZero -and -not $result.ConsoleVisible) 'CONSOLE_CREATED'
        Assert-ExeTest ($result.ApartmentState -eq 'STA') 'PS_NOT_STA'
        if ([Environment]::Is64BitOperatingSystem) { Assert-ExeTest ($result.PointerSize -eq 8) 'PS_NOT_SYSTEM32_64BIT' }
    }
    Import-Module (Join-Path $projectRoot 'lib\CodexAuth.psm1') -Force -DisableNameChecking
    $gate = Test-CodexProcessesStopped -ProcessData @([pscustomobject]@{
        ProcessName='Qiehao.exe'; Id=76543; ExecutablePath=$exe; PathReadStatus='Readable'
    })
    Assert-ExeTest ($gate.SafeToSave -and @($gate.BlockingProcesses).Count -eq 0 -and @($gate.UncertainProcesses).Count -eq 0) 'EXE_MISCLASSIFIED_AS_CODEX'
    Write-Output 'LauncherWindowsGuiSubsystem=True'
    Write-Output 'LauncherNoConsoleWindow=True'
    Write-Output 'LauncherSpacesChineseParentheses=True'
    Write-Output 'LauncherUsesSystemWindowsPowerShell51=True'
    Write-Output 'LauncherForeignCwdIndependent=True'
    Write-Output 'LauncherExitsAfterStarting=True'
    Write-Output 'LauncherSafeErrors=True'
    Write-Output 'LauncherNotCodex=True'
    Write-Output 'RealAuthOrProfileRead=False'
    Write-Output 'ProductionGuiStarted=False'
    Write-Output 'LAUNCHER_EXE_SELFTEST_PASS'
} finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if (-not $resolved.StartsWith($tempBase + '\',[StringComparison]::OrdinalIgnoreCase) -or -not ([IO.Path]::GetFileName($resolved)).StartsWith('Qiehao-test5-exe-')) {
        throw 'TEST_CLEANUP_TARGET_UNSAFE'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
