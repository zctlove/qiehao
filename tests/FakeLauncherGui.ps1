Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class FakeLauncherWindow {
    [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr handle);
}
'@
$console = [FakeLauncherWindow]::GetConsoleWindow()
$result = [ordered]@{
    WorkingDirectory = [Environment]::CurrentDirectory
    ScriptDirectory = $PSScriptRoot
    ConsoleHandleZero = ($console -eq [IntPtr]::Zero)
    ConsoleVisible = ($console -ne [IntPtr]::Zero -and [FakeLauncherWindow]::IsWindowVisible($console))
    ApartmentState = [Threading.Thread]::CurrentThread.ApartmentState.ToString()
    PointerSize = [IntPtr]::Size
}
$marker = Join-Path (Split-Path -Parent $PSScriptRoot) 'launch-result.json'
$result | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding UTF8
