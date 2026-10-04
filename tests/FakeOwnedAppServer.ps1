param([int]$ExitDelayMilliseconds=250)
$ErrorActionPreference='Stop'
while ($null -ne [Console]::In.ReadLine()) { }
[Threading.Thread]::Sleep($ExitDelayMilliseconds)
