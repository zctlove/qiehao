[CmdletBinding()]
param([string]$OutputPath = '')

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Qiehao.exe'
}
$windowsDirectory = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows)
$compiler = Join-Path $windowsDirectory 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not [IO.File]::Exists($compiler)) {
    $compiler = Join-Path $windowsDirectory 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not [IO.File]::Exists($compiler)) { throw 'LAUNCHER_OFFLINE_COMPILER_NOT_FOUND' }
$source = Join-Path $PSScriptRoot 'QiehaoLauncher.cs'
$output = [IO.Path]::GetFullPath($OutputPath)
if (-not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($output))) {
    throw 'LAUNCHER_OUTPUT_DIRECTORY_NOT_FOUND'
}
$compilerArgs = @('/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
    '/debug-', '/codepage:65001', '/reference:System.Windows.Forms.dll',
    ('/out:' + $output), $source)
& $compiler @compilerArgs
if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($output)) { throw 'LAUNCHER_BUILD_FAILED' }
$info = [Diagnostics.FileVersionInfo]::GetVersionInfo($output)
if ($info.FileVersion -ne '1.1.0.0' -or $info.ProductVersion -ne '1.1.0') {
    throw 'LAUNCHER_BUILD_VERSION_INVALID'
}
Write-Output ('LauncherBytes=' + ([IO.FileInfo]$output).Length)
Write-Output ('LauncherSHA256=' + (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash)
Write-Output 'OfflineBuild=True'
Write-Output 'LAUNCHER_BUILD_PASS'
