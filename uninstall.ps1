# Removes UpsideDown. Leaves AutoHotkey installed (other scripts may use it).
$InstallDir = Join-Path $env:LOCALAPPDATA 'UpsideDown'
$Shortcut   = Join-Path ([Environment]::GetFolderPath('Startup')) 'UpsideDown.lnk'

Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" |
    Where-Object { $_.CommandLine -like '*upsidedown.ahk*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

if (Test-Path $Shortcut)   { Remove-Item $Shortcut -Force }
if (Test-Path $InstallDir) { Remove-Item $InstallDir -Recurse -Force }

Write-Host ''
Write-Host '  UpsideDown removed. AutoHotkey is still installed; remove it from Settings > Apps if you like.' -ForegroundColor Green
