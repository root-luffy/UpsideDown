<#
.SYNOPSIS
  One-click installer for UpsideDown.

.DESCRIPTION
  1. Installs AutoHotkey v2 (via winget) if it's missing.
  2. Detects which monitor input this PC is on and which inputs the monitor supports.
  3. Test-flips to the other computer so you can confirm the right input.
  4. Copies UpsideDown to %LOCALAPPDATA%\UpsideDown, adds it to startup and starts it.

.EXAMPLE
  .\install.ps1                          # interactive, detects everything
  .\install.ps1 -Other 18 -NoTest        # skip detection of the other input
  .\install.ps1 -Hotkey "^!m"            # use Ctrl+Alt+M instead of Ctrl+F12
#>
param(
    [int]$ThisPC,
    [int]$Other,
    [string]$Hotkey = '^F12',
    [switch]$NoTest
)

$ErrorActionPreference = 'Stop'
$InstallDir = Join-Path $env:LOCALAPPDATA 'UpsideDown'
$Startup    = [Environment]::GetFolderPath('Startup')
$Shortcut   = Join-Path $Startup 'UpsideDown.lnk'

function Step($msg) { Write-Host "`n> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "  $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "  $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "`n  $msg" -ForegroundColor Red; exit 1 }

# Common MCCS input codes. Manufacturers don't always follow them, which is why
# the installer test-flips before saving.
$InputNames = @{
    1 = 'VGA 1'; 2 = 'VGA 2'; 3 = 'DVI 1'; 4 = 'DVI 2'
    15 = 'DisplayPort 1'; 16 = 'DisplayPort 2'
    17 = 'HDMI 1'; 18 = 'HDMI 2'; 27 = 'USB-C'
}
function InputLabel([int]$code) {
    $name = $InputNames[$code]
    if ($name) { "$code  (usually $name)" } else { "$code" }
}

# --- DDC/CI via dxva2 -------------------------------------------------------

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class UpsideDownDdc {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct PHYSICAL_MONITOR {
        public IntPtr Handle;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string Description;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
    [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMon, out uint count);
    [DllImport("dxva2.dll")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMon, uint count, [Out] PHYSICAL_MONITOR[] monitors);
    [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitors(uint count, PHYSICAL_MONITOR[] monitors);
    [DllImport("dxva2.dll")] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, IntPtr type, out uint current, out uint max);
    [DllImport("dxva2.dll")] static extern bool SetVCPFeature(IntPtr h, byte code, uint value);
    [DllImport("dxva2.dll")] static extern bool GetCapabilitiesStringLength(IntPtr h, out uint length);
    [DllImport("dxva2.dll", CharSet = CharSet.Ansi)] static extern bool CapabilitiesRequestAndCapabilitiesReply(IntPtr h, StringBuilder caps, uint length);

    static PHYSICAL_MONITOR[] Open() {
        IntPtr hMon = MonitorFromPoint(new POINT(), 1); // primary monitor
        uint n;
        if (!GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, out n) || n == 0) return null;
        var mons = new PHYSICAL_MONITOR[n];
        if (!GetPhysicalMonitorsFromHMONITOR(hMon, n, mons)) return null;
        return mons;
    }

    public static string Name() {
        var m = Open(); if (m == null) return null;
        try { return m[0].Description; } finally { DestroyPhysicalMonitors((uint)m.Length, m); }
    }

    public static int GetInput() {
        var m = Open(); if (m == null) return 0;
        try {
            for (int i = 0; i < 5; i++) {
                uint cur, max;
                if (GetVCPFeatureAndVCPFeatureReply(m[0].Handle, 0x60, IntPtr.Zero, out cur, out max))
                    return (int)(cur & 0xFF);
                System.Threading.Thread.Sleep(100);
            }
            return 0;
        } finally { DestroyPhysicalMonitors((uint)m.Length, m); }
    }

    public static bool SetInput(int value) {
        var m = Open(); if (m == null) return false;
        try {
            for (int i = 0; i < 3; i++) {
                if (SetVCPFeature(m[0].Handle, 0x60, (uint)value)) return true;
                System.Threading.Thread.Sleep(100);
            }
            return false;
        } finally { DestroyPhysicalMonitors((uint)m.Length, m); }
    }

    public static string Capabilities() {
        var m = Open(); if (m == null) return null;
        try {
            for (int i = 0; i < 3; i++) {
                uint len;
                if (!GetCapabilitiesStringLength(m[0].Handle, out len)) continue;
                var sb = new StringBuilder((int)len);
                if (CapabilitiesRequestAndCapabilitiesReply(m[0].Handle, sb, len)) return sb.ToString();
            }
            return null;
        } finally { DestroyPhysicalMonitors((uint)m.Length, m); }
    }
}
'@

function Get-SupportedInputs {
    $caps = [UpsideDownDdc]::Capabilities()
    if ($caps -and $caps -match '(?<![0-9A-Fa-f])60\s*\(([0-9A-Fa-f ]+)\)') {
        return $Matches[1].Trim() -split '\s+' | ForEach-Object { [Convert]::ToInt32($_, 16) }
    }
    return $null
}

function Test-Flip([int]$target, [int]$back) {
    Write-Host ""
    Write-Host "  Switching the monitor to input $target for 8 seconds..." -ForegroundColor White
    Write-Host "  Watch the screen: does your other computer appear?" -ForegroundColor White
    Start-Sleep -Seconds 2
    [void][UpsideDownDdc]::SetInput($target)
    Start-Sleep -Seconds 8
    [void][UpsideDownDdc]::SetInput($back)
    Start-Sleep -Seconds 3
    $answer = Read-Host "  Did your other computer show up? [y/n]"
    return $answer -match '^\s*y'
}

# --- 1. AutoHotkey v2 -------------------------------------------------------

Write-Host ""
Write-Host "  U P S I D E   D O W N" -ForegroundColor Magenta
Write-Host "  one key. two computers. one monitor." -ForegroundColor DarkGray

Step 'Checking for AutoHotkey v2'

function Find-Ahk {
    @(
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey64.exe",
        "$env:LOCALAPPDATA\Programs\AutoHotkey\v2\AutoHotkey32.exe",
        "$env:ProgramFiles\AutoHotkey\v2\AutoHotkey32.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
}

$Ahk = Find-Ahk
if (-not $Ahk) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail 'AutoHotkey v2 is missing and winget is not available. Install it from https://www.autohotkey.com and run this again.'
    }
    Warn 'Not found. Installing AutoHotkey v2 with winget...'
    winget install --id AutoHotkey.AutoHotkey -e --source winget --silent --accept-package-agreements --accept-source-agreements | Out-Host
    $Ahk = Find-Ahk
    if (-not $Ahk) { Fail 'AutoHotkey install did not finish. Install it from https://www.autohotkey.com and run this again.' }
}
Ok "Found $Ahk"

# --- 2. Monitor detection ---------------------------------------------------

Step 'Talking to your monitor (DDC/CI)'

$name = [UpsideDownDdc]::Name()
if (-not $name) { Fail 'No monitor found. Is it connected and turned on?' }
$model = Get-CimInstance -Namespace root\wmi WmiMonitorID -ErrorAction SilentlyContinue | Select-Object -First 1 |
    ForEach-Object { -join ($_.UserFriendlyName | Where-Object { $_ } | ForEach-Object { [char]$_ }) }
if ($model) { $name = $model }
Ok "Monitor: $name (primary display)"

if (-not $ThisPC) {
    $ThisPC = [UpsideDownDdc]::GetInput()
    if (-not $ThisPC) {
        Fail ("Your monitor didn't answer. Turn on 'DDC/CI' in the monitor's on-screen menu " +
              "(usually under System or Other settings) and run this again.")
    }
}
Ok "This PC is on input $(InputLabel $ThisPC)"

if (-not $Other) {
    $supported = Get-SupportedInputs
    if ($supported) {
        Ok "Monitor inputs: $($supported -join ', ')"
        $candidates = @($supported | Where-Object { $_ -ne $ThisPC })
    } else {
        Warn "Monitor didn't list its inputs; trying the common ones."
        $candidates = @(17, 18, 15, 16, 27, 3, 1) | Where-Object { $_ -ne $ThisPC }
    }

    Step 'Which input is your other computer on?'
    Write-Host '  Make sure the other computer is on and awake.' -ForegroundColor White

    while (-not $Other) {
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host ("  [{0}] input {1}" -f ($i + 1), (InputLabel $candidates[$i]))
        }
        $pick = Read-Host "  Pick a number (or type an input code)"
        $code = 0
        if ([int]::TryParse($pick, [ref]$code)) {
            if ($code -ge 1 -and $code -le $candidates.Count) { $code = $candidates[$code - 1] }
        }
        if ($code -le 0) { continue }

        if ($NoTest -or (Test-Flip $code $ThisPC)) {
            $Other = $code
        } else {
            Warn 'No problem, try another input.'
        }
    }
}
Ok "Other computer is on input $(InputLabel $Other)"

# --- 3. Install -------------------------------------------------------------

Step "Installing to $InstallDir"

Get-CimInstance Win32_Process -Filter "Name LIKE 'AutoHotkey%'" |
    Where-Object { $_.CommandLine -like '*upsidedown.ahk*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

New-Item -ItemType Directory -Force $InstallDir | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'src\upsidedown.ahk') $InstallDir -Force

$config = Get-Content (Join-Path $PSScriptRoot 'src\config.ini') -Raw
$config = $config -replace '(?m)^ThisPC=.*$', "ThisPC=$ThisPC" `
                  -replace '(?m)^Other=.*$',  "Other=$Other" `
                  -replace '(?m)^Hotkey=.*$', "Hotkey=$Hotkey"
Set-Content (Join-Path $InstallDir 'config.ini') $config -Encoding ascii
Ok 'Files copied'

$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut($Shortcut)
$lnk.TargetPath       = $Ahk
$lnk.Arguments        = '"' + (Join-Path $InstallDir 'upsidedown.ahk') + '"'
$lnk.WorkingDirectory = $InstallDir
$lnk.Description      = 'UpsideDown monitor input switcher'
$lnk.Save()
Ok 'Starts automatically when you sign in'

Start-Process $Ahk -ArgumentList ('"' + (Join-Path $InstallDir 'upsidedown.ahk') + '"') -WorkingDirectory $InstallDir
Ok 'Running now'

$modNames = @{ '^' = 'Ctrl+'; '!' = 'Alt+'; '+' = 'Shift+'; '#' = 'Win+' }
$keyText = $Hotkey
while ($keyText.Length -gt 1 -and $modNames.ContainsKey([string]$keyText[0])) {
    $keyText = $keyText.Substring(1)
}
$keyText = (($Hotkey.Substring(0, $Hotkey.Length - $keyText.Length).ToCharArray() | ForEach-Object { $modNames[[string]$_] }) -join '') + $keyText
Write-Host ""
Write-Host "  Done! Press $keyText to flip your monitor." -ForegroundColor Green
Write-Host "  Settings: right-click the green H icon in the tray > Edit settings." -ForegroundColor DarkGray
Write-Host ""
