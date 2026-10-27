#Requires -Version 5.1
<#
    W11 Tweaker
    Tiered Windows 11 optimisation toggles with an automatic snapshot of every
    original value and one-click restore.

    Required Notice: Copyright (C) 2026 geodnb (https://github.com/geodnb/W11-Tweaker)
    SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
    Free for non-commercial use; selling or commercial use is not permitted without
    permission. Provided WITHOUT ANY WARRANTY. See LICENSE.md for the full terms.
    https://github.com/geodnb/W11-Tweaker

    Launch with "Run W11 Tweaker.cmd" (or right-click > Run with PowerShell).
    It relaunches itself elevated in Windows PowerShell 5.1.

    Data:  %ProgramData%\W11Tweaker\snapshot.json   (original values, written before any change)
           %ProgramData%\W11Tweaker\tweaker.log      (everything the tool did)
           The folder is locked to Administrators and SYSTEM; anything in it owned by
           another account is set aside and never read.
#>
param([switch]$Relaunched, [switch]$SelfTest)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Off

# =====================================================================
#  Elevation / STA / Windows PowerShell 5.1
# =====================================================================
if (-not $SelfTest) {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $isAdmin   = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $isSTA     = [Threading.Thread]::CurrentThread.GetApartmentState() -eq 'STA'
    $isDesktop = $PSVersionTable.PSEdition -ne 'Core'
    if (-not ($isAdmin -and $isSTA -and $isDesktop)) {
        if ($Relaunched) {
            # Relaunched window is hidden, so report through a dialog instead of the console.
            try {
                Add-Type -AssemblyName PresentationFramework
                [System.Windows.MessageBox]::Show('W11 Tweaker needs to run elevated in Windows PowerShell 5.1.', 'W11 Tweaker', 'OK', 'None') | Out-Null
            } catch {}
            exit 1
        }
        # Build the path from the real system directory, not an environment variable a user process could override.
        $ps = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
        $argList = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "{0}" -Relaunched' -f $PSCommandPath
        try { Start-Process -FilePath $ps -ArgumentList $argList -Verb RunAs | Out-Null }
        catch { Write-Host 'Elevation was cancelled.' }
        exit
    }
}

# =====================================================================
#  Types
# =====================================================================
$cs = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace W11T
{
    public class TweakRow : INotifyPropertyChanged
    {
        public event PropertyChangedEventHandler PropertyChanged;
        private void N(string p)
        {
            PropertyChangedEventHandler h = PropertyChanged;
            if (h != null) h(this, new PropertyChangedEventArgs(p));
        }

        public string Id { get; set; }
        public string Name { get; set; }
        public string Category { get; set; }
        public string Tier { get; set; }
        public string RebootText { get; set; }
        public string Summary { get; set; }
        public string Group { get; set; }

        private bool _desired;
        public bool Desired
        {
            get { return _desired; }
            set
            {
                if (_desired == value) return;
                _desired = value;
                N("Desired"); N("Pending"); N("PendingMark");
            }
        }

        private bool _applied;
        public bool Applied
        {
            get { return _applied; }
            set { _applied = value; N("Applied"); N("Pending"); N("PendingMark"); }
        }

        private string _status = "";
        public string Status
        {
            get { return _status; }
            set { _status = value; N("Status"); }
        }

        public bool Pending { get { return _desired != _applied; } }

        public string PendingMark
        {
            get
            {
                if (!Pending) return "";
                return _desired ? "will apply" : "will revert";
            }
        }
    }

    // Asks the display driver (D3DKMT, KMTQAITYPE_WDDM_2_7_CAPS = 70) whether hardware-accelerated
    // GPU scheduling is supported and actually running. Returns -1 if unknown, otherwise
    // bit 0 = supported by at least one adapter, bit 1 = running on at least one adapter.
    public static class Gpu
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct LUID { public uint LowPart; public int HighPart; }
        [StructLayout(LayoutKind.Sequential)]
        private struct ADAPTERINFO { public uint hAdapter; public LUID AdapterLuid; public uint NumOfSources; public int bPrecisePresentRegionsPreferred; }
        [StructLayout(LayoutKind.Sequential)]
        private struct ENUMADAPTERS2 { public uint NumAdapters; public IntPtr pAdapters; }
        [StructLayout(LayoutKind.Sequential)]
        private struct QUERYADAPTERINFO { public uint hAdapter; public int Type; public IntPtr pPrivateDriverData; public uint PrivateDriverDataSize; }
        [StructLayout(LayoutKind.Sequential)]
        private struct CLOSEADAPTER { public uint hAdapter; }

        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("gdi32.dll")] private static extern int D3DKMTEnumAdapters2(ref ENUMADAPTERS2 e);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("gdi32.dll")] private static extern int D3DKMTQueryAdapterInfo(ref QUERYADAPTERINFO q);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("gdi32.dll")] private static extern int D3DKMTCloseAdapter(ref CLOSEADAPTER c);

        public static int HagsState()
        {
            try
            {
                ENUMADAPTERS2 e = new ENUMADAPTERS2();
                if (D3DKMTEnumAdapters2(ref e) != 0 || e.NumAdapters == 0) return -1;
                int size = Marshal.SizeOf(typeof(ADAPTERINFO));
                IntPtr buf = Marshal.AllocHGlobal(size * (int)e.NumAdapters);
                IntPtr caps = Marshal.AllocHGlobal(4);
                try
                {
                    e.pAdapters = buf;
                    if (D3DKMTEnumAdapters2(ref e) != 0) return -1;
                    int result = 0;
                    bool answered = false;
                    for (int i = 0; i < (int)e.NumAdapters; i++)
                    {
                        ADAPTERINFO a = (ADAPTERINFO)Marshal.PtrToStructure(new IntPtr(buf.ToInt64() + (long)i * size), typeof(ADAPTERINFO));
                        Marshal.WriteInt32(caps, 0);
                        QUERYADAPTERINFO q = new QUERYADAPTERINFO();
                        q.hAdapter = a.hAdapter;
                        q.Type = 70;
                        q.pPrivateDriverData = caps;
                        q.PrivateDriverDataSize = 4;
                        if (D3DKMTQueryAdapterInfo(ref q) == 0)
                        {
                            answered = true;
                            uint v = (uint)Marshal.ReadInt32(caps);
                            if ((v & 1) != 0) result |= 1;
                            if ((v & 2) != 0) result |= 2;
                        }
                        CLOSEADAPTER c = new CLOSEADAPTER();
                        c.hAdapter = a.hAdapter;
                        D3DKMTCloseAdapter(ref c);
                    }
                    return answered ? result : -1;
                }
                finally
                {
                    Marshal.FreeHGlobal(buf);
                    Marshal.FreeHGlobal(caps);
                }
            }
            catch { return -1; }
        }
    }

    // Pushes input/accessibility settings to the running session through SystemParametersInfo,
    // the same API the Settings app uses, so they take effect without signing out.
    public static class Live
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct SK { public uint cbSize; public uint dwFlags; }
        [StructLayout(LayoutKind.Sequential)]
        private struct FK { public uint cbSize; public uint dwFlags; public uint iWaitMSec; public uint iDelayMSec; public uint iRepeatMSec; public uint iBounceMSec; }

        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
        private static extern bool SpiSK(uint action, uint uiParam, ref SK pv, uint winIni);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
        private static extern bool SpiFK(uint action, uint uiParam, ref FK pv, uint winIni);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
        private static extern bool SpiInts(uint action, uint uiParam, int[] pv, uint winIni);
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("user32.dll", EntryPoint = "SystemParametersInfoW", SetLastError = true)]
        private static extern bool SpiPtr(uint action, uint uiParam, IntPtr pv, uint winIni);

        private const uint UpdateAndBroadcast = 3;   // SPIF_UPDATEINIFILE | SPIF_SENDCHANGE
        private const uint HotkeyActive = 4;         // SKF/FKF/TKF_HOTKEYACTIVE

        public static bool SetHotkey(string which, bool active)
        {
            if (which == "Keyboard Response")
            {
                FK f = new FK(); f.cbSize = (uint)Marshal.SizeOf(typeof(FK));
                if (!SpiFK(0x0032, f.cbSize, ref f, 0)) return false;          // SPI_GETFILTERKEYS
                f.dwFlags = active ? (f.dwFlags | HotkeyActive) : (f.dwFlags & ~HotkeyActive);
                return SpiFK(0x0033, f.cbSize, ref f, UpdateAndBroadcast);     // SPI_SETFILTERKEYS
            }
            uint getAction, setAction;
            if (which == "StickyKeys") { getAction = 0x003A; setAction = 0x003B; }   // SPI_GET/SETSTICKYKEYS
            else if (which == "ToggleKeys") { getAction = 0x0034; setAction = 0x0035; } // SPI_GET/SETTOGGLEKEYS
            else return false;
            SK s = new SK(); s.cbSize = (uint)Marshal.SizeOf(typeof(SK));
            if (!SpiSK(getAction, s.cbSize, ref s, 0)) return false;
            s.dwFlags = active ? (s.dwFlags | HotkeyActive) : (s.dwFlags & ~HotkeyActive);
            return SpiSK(setAction, s.cbSize, ref s, UpdateAndBroadcast);
        }

        public static bool SetMouse(int threshold1, int threshold2, int speed)
        {
            int[] v = new int[] { threshold1, threshold2, speed };
            return SpiInts(0x0004, 0, v, UpdateAndBroadcast);                  // SPI_SETMOUSE
        }

        public static bool SetKeyboardDelay(int delay)
        {
            return SpiPtr(0x0017, (uint)delay, IntPtr.Zero, UpdateAndBroadcast); // SPI_SETKEYBOARDDELAY
        }

        public static bool SetMenuDelay(int ms)
        {
            return SpiPtr(0x006B, (uint)ms, IntPtr.Zero, UpdateAndBroadcast);    // SPI_SETMENUSHOWDELAY
        }
    }

    public static class Pwr
    {
        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("powrprof.dll", EntryPoint = "PowerSetActiveOverlayScheme")]
        public static extern uint PowerSetActiveOverlayScheme(Guid overlaySchemeGuid);

        [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
        [DllImport("powrprof.dll", EntryPoint = "PowerGetEffectiveOverlayScheme")]
        public static extern uint PowerGetEffectiveOverlayScheme(out Guid effectiveOverlayGuid);
    }
}
'@

# =====================================================================
#  Paths, state
# =====================================================================
$script:Snap             = @{}
$script:SnapCreated      = $null
$script:SnapBroken       = $false
$script:Cache            = @{}
$script:Suppress         = $false
$script:Busy             = $false
$script:UiRunning        = $false
$script:Failures         = 0
$script:LeftAlone        = 0
$script:Quarantined      = @()
$script:BitLockerOn      = $false
$script:LastResult       = ''
$script:DlgFrame         = $null
$script:DlgResult        = ''
$script:DlgPrimary       = 'OK'
$script:DlgEscape        = 'OK'
$script:RestorePointDone = $false
$script:Catalogue        = New-Object System.Collections.ArrayList
$NoDefault               = '__SNAPSHOT_ONLY__'
$NA                      = '<n/a>'
$LogFile                 = $null

trap {
    $m = "W11 Tweaker hit an error:`n`n" + $_.Exception.Message + "`n`nLog: " + $LogFile
    try { if ($LogFile) { Add-Content -LiteralPath $LogFile -Value ((Get-Date -Format s) + ' [FATAL] ' + ($_.Exception.ToString() -replace "[`r`n]+", ' | ')) } } catch {}
    if ($SelfTest) { Write-Host $m; exit 99 }
    if ($script:UiRunning) {
        # Once the window is up, an unexpected error is logged and the app keeps running.
        try { if ($script:LogBox) { $script:LogBox.AppendText('[ERROR] ' + $_.Exception.Message + "`r`n") } } catch {}
        continue
    }
    try {
        Add-Type -AssemblyName PresentationFramework
        [System.Windows.MessageBox]::Show($m, 'W11 Tweaker', 'OK', 'None') | Out-Null
    } catch {}
    exit 1
}

function Test-TrustedOwner([string]$Path) {
    try {
        $o = (Get-Acl -LiteralPath $Path).GetOwner([Security.Principal.SecurityIdentifier]).Value
        return (@('S-1-5-32-544', 'S-1-5-18') -contains $o)
    } catch { return $false }
}

function Initialize-AppDir {
    # The snapshot drives elevated writes, so the folder must only be writable by admins/SYSTEM.
    # Standard users can create items in ProgramData by default; anything they own is quarantined.
    $SID_ADMINS = New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $SID_SYSTEM = New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $dir = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'W11Tweaker'
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    if (Test-Path -LiteralPath $dir) {
        $item = Get-Item -LiteralPath $dir -Force
        $isLink = [bool]($item.Attributes -band [IO.FileAttributes]::ReparsePoint)
        if ($isLink -or -not (Test-TrustedOwner $dir)) {
            Move-Item -LiteralPath $dir -Destination ($dir + '.untrusted-' + $stamp) -Force
            $script:Quarantined += ($dir + '.untrusted-' + $stamp)
        }
    }
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($SID_ADMINS, $SID_SYSTEM)) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        [void]$acl.AddAccessRule($rule)
    }
    try {
        $acl.SetOwner($SID_ADMINS)
        Set-Acl -LiteralPath $dir -AclObject $acl -ErrorAction Stop
    } catch {
        # Setting the owner can be refused on some setups; the access rules alone still lock the folder down.
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @($SID_ADMINS, $SID_SYSTEM)) {
            $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($sid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
            [void]$acl.AddAccessRule($rule)
        }
        Set-Acl -LiteralPath $dir -AclObject $acl -ErrorAction Stop
    }
    foreach ($f in @(Get-ChildItem -LiteralPath $dir -Force | Where-Object { $_.Name -notmatch '\.untrusted-\d{8}-\d{6}$' })) {
        $fLink = [bool]($f.Attributes -band [IO.FileAttributes]::ReparsePoint)
        if ($fLink -or -not (Test-TrustedOwner $f.FullName)) {
            Move-Item -LiteralPath $f.FullName -Destination ($f.FullName + '.untrusted-' + $stamp) -Force
            $script:Quarantined += ($f.FullName + '.untrusted-' + $stamp)
        }
    }
    return $dir
}

if ($SelfTest) {
    $AppDir = Join-Path ([IO.Path]::GetTempPath()) 'W11Tweaker'
    New-Item -ItemType Directory -Path $AppDir -Force | Out-Null
} else {
    $AppDir = Initialize-AppDir
}
$SnapFile = Join-Path $AppDir 'snapshot.json'
$LogFile  = Join-Path $AppDir 'tweaker.log'

# Compile the helper types inside the protected folder rather than the user's TEMP,
# so a non-elevated process can't swap the generated source or DLL.
if (-not ('W11T.TweakRow' -as [type])) {
    $oldTmp = $env:TMP; $oldTemp = $env:TEMP
    if (-not $SelfTest) {
        $tmp = Join-Path $AppDir 'tmp'
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $env:TMP = $tmp; $env:TEMP = $tmp
    }
    try { Add-Type -TypeDefinition $cs -Language CSharp }
    finally { $env:TMP = $oldTmp; $env:TEMP = $oldTemp }
}

$BcdNote = 'Changes boot configuration (BCD). Microsoft lists this setting as ignored by BitLocker''s boot validation, but keep your BitLocker recovery key to hand anyway (aka.ms/myrecoverykey).'
$BitLockerNote = $BcdNote

# =====================================================================
#  Logging / UI pump
# =====================================================================
function Log([string]$Msg, [string]$Level = 'INFO') {
    $clean = ([string]$Msg) -replace "[`r`n]+", ' | '
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $clean
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch {}
    if ($script:LogBox) {
        $script:LogBox.AppendText($line + "`r`n")
        $script:LogBox.ScrollToEnd()
    }
    if ($SelfTest) { Write-Host $line }
}

function Pump {
    if ($script:Window) {
        $script:Window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Background)
    }
}

# =====================================================================
#  Value helpers
# =====================================================================
function IsNA($v)        { ($v -is [string]) -and ($v -eq $NA) }
function IsNoDefault($v) { ($v -is [string]) -and ($v -eq $NoDefault) }

function Norm($v) {
    if ($null -eq $v) { return '<absent>' }
    if ($v -is [array]) { return ($v -join ',') }
    return [string]$v
}

function Format-Val($v) {
    if (IsNA $v) { return 'n/a' }
    if ($null -eq $v) { return '(not set)' }
    if (IsNoDefault $v) { return '(restore from snapshot)' }
    if ($v -is [string] -and $v -eq '') { return '""' }
    return [string]$v
}

function ConvertTo-DWord($v) {
    $l = [int64]$v
    if ($l -gt 2147483647) { $l -= 4294967296 }
    return [int]$l
}

# =====================================================================
#  Low-level getters/setters
# =====================================================================
function RegGet([string]$Path, [string]$Name) {
    try {
        $k = Get-Item -LiteralPath $Path -ErrorAction Stop
        if (-not ($k.GetValueNames() -contains $Name)) { return $null }
        return $k.GetValue($Name, $null, 'DoNotExpandEnvironmentNames')
    } catch { return $null }
}

function RegSet([string]$Path, [string]$Name, [string]$Type, $Value) {
    if ($null -eq $Value) {
        if (Test-Path -LiteralPath $Path) {
            Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
        }
        return
    }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    switch ($Type) {
        'DWord'  { $Value = ConvertTo-DWord $Value }
        'String' { $Value = [string]$Value }
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType $Type -Value $Value -Force -ErrorAction Stop | Out-Null
}

# ---- powercfg ----
$SUB_PROC = '54533251-82be-4824-96c1-47b60b740d00'
function PwrGet([string]$Sub, [string]$Setting, [string]$Scheme = 'SCHEME_CURRENT') {
    $out = & powercfg /query $Scheme $Sub $Setting 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $out) { return $NA }
    $hex = [regex]::Matches(($out -join "`n"), '0x[0-9a-fA-F]{8}')
    if ($hex.Count -lt 2) { return $NA }
    return [int]([Convert]::ToInt64($hex[$hex.Count - 2].Value, 16))
}
function PwrSet([string]$Sub, [string]$Setting, $Value, [string]$Scheme = 'SCHEME_CURRENT') {
    $v = [int]$Value
    & powercfg /setacvalueindex $Scheme $Sub $Setting $v | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "powercfg could not set $Setting on $Scheme" }
    & powercfg /setdcvalueindex $Scheme $Sub $Setting $v 2>$null | Out-Null
    & powercfg /setactive SCHEME_CURRENT | Out-Null
}

# ---- bcdedit ----
function BcdGet([string]$Name) {
    if (-not $script:Cache.ContainsKey('bcd')) {
        $script:Cache['bcd'] = @(& bcdedit /enum '{current}' 2>$null)
        if ($LASTEXITCODE -ne 0) { $script:Cache['bcd'] = $null }
    }
    $lines = $script:Cache['bcd']
    if ($null -eq $lines) { return $NA }
    foreach ($l in $lines) {
        if ($l -match ('^' + [regex]::Escape($Name) + '\s+(.+)$')) { return $matches[1].Trim() }
    }
    return $null
}
function BcdSet([string]$Name, $Value) {
    if ($null -eq $Value) { & bcdedit /deletevalue '{current}' $Name 2>&1 | Out-Null }
    else {
        & bcdedit /set '{current}' $Name ([string]$Value) | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "bcdedit /set $Name failed" }
    }
}

# ---- DirectX global user settings (Settings > Display > Graphics) ----
$DxPath = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
function DxPairs {
    $list = New-Object System.Collections.ArrayList
    $s = RegGet $DxPath 'DirectXUserGlobalSettings'
    if ($s) {
        foreach ($p in ($s -split ';')) {
            if ($p -match '^\s*([^=]+)=(.*)$') { [void]$list.Add(@($matches[1].Trim(), $matches[2].Trim())) }
        }
    }
    return ,$list
}
function DxGet([string]$K) {
    foreach ($p in (DxPairs)) { if ($p[0] -eq $K) { return $p[1] } }
    return $null
}
function DxSet([string]$K, $V) {
    $pairs = DxPairs
    $out = New-Object System.Collections.ArrayList
    foreach ($p in $pairs) { if ($p[0] -ne $K) { [void]$out.Add($p) } }
    if ($null -ne $V) { [void]$out.Add(@($K, [string]$V)) }
    if ($out.Count -eq 0) { RegSet $DxPath 'DirectXUserGlobalSettings' 'String' $null; return }
    $s = (($out | ForEach-Object { '{0}={1}' -f $_[0], $_[1] }) -join ';') + ';'
    RegSet $DxPath 'DirectXUserGlobalSettings' 'String' $s
}

# ---- power plans ----
$GUID_BAL      = '381b4222-f694-41f0-9685-ff5bb260df2e'
$GUID_HP       = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$GUID_ULT_BASE = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
$GUID_ULT      = '7a1e5f00-1111-4c3b-9d2e-0000000000a1'   # this tool's copy of Ultimate
$GUID_HP_COPY  = '7a1e5f00-1111-4c3b-9d2e-0000000000a2'   # used only if High performance is hidden
$OVL_NONE      = '00000000-0000-0000-0000-000000000000'
$OVL_BEST      = 'ded574b5-45a0-4f42-8737-46345c09c238'

$GuidRx = '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
function Get-ActiveScheme {
    if ($script:Cache.ContainsKey('scheme')) { return $script:Cache['scheme'] }
    $o = (& powercfg /getactivescheme) | Out-String
    $g = $null
    if ($o -match '([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})') { $g = $matches[1].ToLower() }
    $script:Cache['scheme'] = $g
    return $g
}
function Get-ActiveSchemeName {
    $o = (& powercfg /getactivescheme) | Out-String
    if ($o -match '\((.+)\)') { return $matches[1] }
    return '?'
}
function Test-Scheme([string]$g) { ((& powercfg /list) | Out-String) -match [regex]::Escape($g) }
function Ensure-Scheme([string]$g, [string]$base) {
    if (-not (Test-Scheme $g)) {
        & powercfg -duplicatescheme $base $g | Out-Null
        if (-not (Test-Scheme $g)) { throw "Could not create power plan $g from $base" }
    }
}
function Set-PlanGuid($g) {
    $g = ([string]$g).ToLower()
    if ($g -notmatch $GuidRx) { throw "Not a power plan GUID: $g" }
    if ($g -eq $GUID_ULT) { Ensure-Scheme $GUID_ULT $GUID_ULT_BASE }
    if ($g -eq $GUID_HP -and -not (Test-Scheme $GUID_HP)) { Ensure-Scheme $GUID_HP_COPY $GUID_HP; $g = $GUID_HP_COPY }
    & powercfg /setactive $g | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "powercfg /setactive $g failed" }
}
function Get-Overlay {
    try {
        $g = [Guid]::Empty
        $r = [W11T.Pwr]::PowerGetEffectiveOverlayScheme([ref]$g)
        if ($r -eq 0) { return $g.ToString().ToLower() }
    } catch {}
    $v = RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes' 'ActiveOverlayAcPowerScheme'
    if ($v) { return ([string]$v).ToLower() }
    return $OVL_NONE
}
function Set-Overlay($g) {
    if ($null -eq $g -or [string]$g -eq '') { $g = $OVL_NONE }
    if (([string]$g).ToLower() -notmatch $GuidRx) { throw "Not an overlay GUID: $g" }
    $r =[W11T.Pwr]::PowerSetActiveOverlayScheme([Guid][string]$g)
    if ($r -ne 0) { throw "PowerSetActiveOverlayScheme returned $r" }
}

# ---- network interfaces (Nagle) ----
$IfBase = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
function Get-ActiveIfKeys {
    Get-ChildItem -LiteralPath $IfBase -ErrorAction SilentlyContinue | Where-Object {
        $p = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue
        $dhcp = [string]$p.DhcpIPAddress
        $ips  = (@($p.IPAddress) -join ',')
        ($dhcp -and $dhcp -ne '0.0.0.0') -or ($ips -and $ips -notmatch '^(0\.0\.0\.0,?)*$')
    }
}

# =====================================================================
#  Operation builders
#  Every op knows how to read its current value and set a value.
#  On  = value when the tweak is applied
#  Off = fallback revert value if no snapshot exists ($null = delete / Windows default,
#        $NoDefault = only revert from snapshot)
# =====================================================================
function RegOp([string]$Path, [string]$Name, [string]$Type, $On, $Off = $null) {
    $shown = $On
    if ($Type -eq 'DWord' -and ([string]$On) -match '^-\d+$') { $shown = '0x{0:X8}' -f [int]$On }
    [pscustomobject]@{
        Kind = 'reg'; Key = "reg:$Path|$Name"; Path = $Path; Name = $Name; Type = $Type
        On = $On; Off = $Off; Post = ''; SvcName = ''; IsOn = $null
        Desc = '{0}\{1} = {2}' -f $Path, $Name, (Format-Val $shown)
    }
}
function SvcOp([string]$Svc, [int]$OnStart) {
    # Services only ever revert to the value saved in the snapshot (never to a guessed default),
    # so a service the user had deliberately disabled is never switched back on by the tool.
    $names = @{ 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }
    $o = RegOp "HKLM:\SYSTEM\CurrentControlSet\Services\$Svc" 'Start' 'DWord' $OnStart $NoDefault
    $o.Post = 'svc'; $o.SvcName = $Svc
    $o.Desc = 'Service {0} startup = {1}' -f $Svc, $names[$OnStart]
    $o
}
function PwrOp([string]$Sub, [string]$Setting, [int]$On, [string]$Label) {
    # The snapshot key includes the plan GUID at the time (see Get-OpKey), so originals are
    # always restored into the plan they came from.
    [pscustomobject]@{
        Kind = 'pwr'; Key = ("pwr:{0}:{1}" -f $Sub, $Setting); Sub = $Sub; Setting = $Setting
        On = $On; Off = $NoDefault; IsOn = $null
        Desc = 'Active power plan: {0} = {1}' -f $Label, $On
    }
}
function Get-OpKey($op) {
    if ($op.Kind -eq 'pwr') { return ('pwr:{0}:{1}:{2}' -f (Get-ActiveScheme), $op.Sub, $op.Setting) }
    return $op.Key
}
function BcdOp([string]$Name, $On, $Off = $NoDefault) {
    $shown = if ($null -eq $On) { '(removed)' } else { $On }
    [pscustomobject]@{
        Kind = 'bcd'; Key = "bcd:$Name"; Name = $Name
        On = $On; Off = $Off; IsOn = $null
        Desc = 'bcdedit {current} ' + $Name + ' = ' + $shown
    }
}
function DxOp([string]$K, $On, $Off = $null) {
    [pscustomobject]@{
        Kind = 'dx'; Key = "dx:$K"; DxKey = $K
        On = $On; Off = $Off; IsOn = $null
        Desc = 'DirectXUserGlobalSettings: {0}={1}' -f $K, $On
    }
}
function ScrOp([string]$Key, [string]$Desc, [scriptblock]$Get, [scriptblock]$Set, $On, $Off = $NoDefault, [scriptblock]$IsOn = $null) {
    [pscustomobject]@{
        Kind = 'script'; Key = $Key; Desc = $Desc; Get = $Get; Set = $Set
        On = $On; Off = $Off; IsOn = $IsOn; Pkgs = @(); Validate = $null
    }
}

# Validates a value read back from the snapshot before it is ever written elevated.
function Test-SafeScalar($v) {
    if ($null -eq $v) { return $true }
    if ($v -is [bool] -or $v -is [int] -or $v -is [long] -or $v -is [double]) { return $true }
    if ($v -is [string]) { return ($v.Length -le 4096) -and ($v -notmatch '[\x00-\x1f]') }
    return $false
}
function Test-SnapValue($op, $v) {
    if (-not (Test-SafeScalar $v)) { return $false }
    switch ($op.Kind) {
        'reg' {
            if ($null -eq $v) { return ($op.Post -ne 'svc') }
            if ($op.Type -eq 'DWord') {
                $n = 0L
                if (-not [long]::TryParse([string]$v, [ref]$n)) { return $false }
                if ($n -lt -2147483648 -or $n -gt 4294967295) { return $false }
                if ($op.Post -eq 'svc') { return (@(2, 3, 4) -contains [int]$n) }
                return $true
            }
            return ($v -is [string] -and $v.Length -le 260)
        }
        'pwr' {
            $n = 0L
            return ([long]::TryParse([string]$v, [ref]$n) -and $n -ge 0 -and $n -le 4294967295)
        }
        'bcd'    { return ($null -eq $v) -or ([string]$v -match '^(Yes|No|On|Off|Auto)$') }
        'dx'     { return ($null -eq $v) -or ([string]$v -match '^[0-9A-Za-z]{1,8}$') }
        'script' {
            if ($op.Validate) { return [bool](& $op.Validate $v $op) }
            return $true
        }
    }
    return $false
}

function Set-ServiceStart([string]$Name, [int]$Start) {
    # Go through the Service Control Manager (sc.exe) so the change takes effect immediately,
    # and keep delayed-auto-start when the service had it.
    $delayed = RegGet "HKLM:\SYSTEM\CurrentControlSet\Services\$Name" 'DelayedAutostart'
    switch ($Start) {
        2 { $mode = if ($delayed -eq 1) { 'delayed-auto' } else { 'auto' } }
        3 { $mode = 'demand' }
        4 { $mode = 'disabled' }
        default { throw "Unsupported start type $Start for $Name" }
    }
    & sc.exe config $Name start= $mode | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "sc.exe config $Name start= $mode failed (exit $LASTEXITCODE)" }
    if ($Start -eq 4) { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
    elseif ($Start -eq 2) { Start-Service -Name $Name -ErrorAction SilentlyContinue }
}

function Invoke-OpGet($op) {
    switch ($op.Kind) {
        'reg' {
            if ($op.Post -eq 'svc' -and -not (Test-Path -LiteralPath $op.Path)) { return $NA }
            return RegGet $op.Path $op.Name
        }
        'pwr'    { return PwrGet $op.Sub $op.Setting }
        'bcd'    { return BcdGet $op.Name }
        'dx'     { return DxGet $op.DxKey }
        'script' { return (& $op.Get $op) }
    }
}

function Invoke-OpSet($op, $v) {
    switch ($op.Kind) {
        'reg' {
            if ($op.Post -eq 'svc') { Set-ServiceStart $op.SvcName ([int]$v) }
            else { RegSet $op.Path $op.Name $op.Type $v }
        }
        'pwr'    { PwrSet $op.Sub $op.Setting $v }
        'bcd'    { BcdSet $op.Name $v }
        'dx'     { DxSet $op.DxKey $v }
        'script' { & $op.Set $op $v }
    }
    $script:Cache = @{}
}

function Test-OpOn($op, $cur) {
    if (IsNA $cur) { return $false }
    if ($op.IsOn) { return [bool](& $op.IsOn $cur) }
    return ((Norm $cur) -eq (Norm $op.On))
}

# =====================================================================
#  Catalogue
# =====================================================================
function Add-Tweak([hashtable]$h) {
    $defaults = @{ Reboot = 'None'; Warning = ''; Evidence = ''; Group = ''; Order = 50; OneWay = $false; Detail = ''; Guard = $null; FailHint = ''; Live = $null }
    foreach ($k in @($defaults.Keys)) { if (-not $h.ContainsKey($k)) { $h[$k] = $defaults[$k] } }
    $h.Ops = @($h.Ops)
    $h.Index = $script:Catalogue.Count
    [void]$script:Catalogue.Add([pscustomobject]$h)
}

$GC  = 'HKCU:\System\GameConfigStore'
$MM  = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
$CDM = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$ADV = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
$POL = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'

# ---------------------------------------------------------------------
#  GAMING & GRAPHICS
# ---------------------------------------------------------------------
$op = RegOp 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 'DWord' 1 $null
$op.IsOn = { param($c) ($null -eq $c) -or ([string]$c -eq '1') }
Add-Tweak @{
    Id = 'game-mode'; Category = 'Gaming & graphics'; Name = 'Game Mode'; Tier = 'Recommended'
    Summary  = 'Prioritises the focused game and stops Windows Update restarts and driver installs mid-session.'
    Detail   = 'Gives the active game scheduling priority, suppresses notifications and defers update activity. On hybrid Intel CPUs it also helps keep game threads on P-cores. Windows treats "not set" as on.'
    Evidence = 'The "turn it off" advice dates from early Windows 10 (2017-18), when it caused stutter. Current testing: leave it on. It smooths frame-time spikes rather than raising average FPS.'
    Warning  = 'Background work (renders, exports, local LLMs) is deprioritised while a game has focus.'
    Ops = @($op)
}

function Get-HagsLive {
    if (-not $script:Cache.ContainsKey('hags')) { $script:Cache['hags'] = [W11T.Gpu]::HagsState() }
    return $script:Cache['hags']
}
$hagsOp = RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 'DWord' 2 $NoDefault
# Newer Windows often leaves HwSchMode unset when HAGS is on by default, so when the value
# is missing, ask the driver whether it's actually running.
$hagsOp.IsOn = {
    param($c)
    if ($null -ne $c) { return ([string]$c -eq '2') }
    $live = Get-HagsLive
    return ($live -ge 0 -and ($live -band 2) -ne 0)
}
Add-Tweak @{
    Id = 'hags'; Category = 'Gaming & graphics'; Name = 'Hardware-accelerated GPU scheduling'; Tier = 'Recommended'; Reboot = 'Reboot'
    Summary  = 'Lets the GPU manage its own scheduling queue. Required for DLSS Frame Generation on RTX 40-series.'
    Detail   = 'Moves frame scheduling from the CPU-side driver to the GPU''s own scheduler. Needs WDDM 2.7+ and a supporting GPU (NVIDIA RTX 20-series and newer, AMD RX 6000 and newer). When Windows hasn''t written the setting (common when HAGS is on by default), the status comes from the graphics driver''s live state.'
    Evidence = 'Most testing shows small or neutral FPS change with slightly lower latency on RTX 30/40 and RX 6000+. NVIDIA requires it for Frame Generation.'
    Ops = @($hagsOp)
}

Add-Tweak @{
    Id = 'windowed-opt'; Category = 'Gaming & graphics'; Name = 'Optimizations for windowed games'; Tier = 'Recommended'
    Summary  = 'Upgrades DX10/11 borderless and windowed games to the flip presentation model.'
    Detail   = 'Brings borderless-windowed latency close to exclusive fullscreen, and is required for Auto HDR. Per-game overrides in Settings > Display > Graphics still win.'
    Evidence = 'Microsoft says it significantly improves latency for windowed DX10/11 games. Widely recommended, no downside reported.'
    Ops = @(DxOp 'SwapEffectUpgradeEnable' '1' $null)
}

Add-Tweak @{
    Id = 'dx-vrr'; Category = 'Gaming & graphics'; Name = 'Variable refresh rate for games (Windows VRR)'; Tier = 'Situational'
    Summary  = 'Lets older DX11 games without native VRR support use G-Sync/FreeSync.'
    Detail   = 'Only affects games that don''t already handle VRR themselves. Harmless alongside G-Sync.'
    Evidence = 'Useful on VRR monitors for older titles; no effect on games that already support VRR.'
    Ops = @(DxOp 'VRROptimizeEnable' '1' $null)
}

Add-Tweak @{
    Id = 'gamedvr-off'; Category = 'Gaming & graphics'; Name = 'Turn off Game Bar captures'; Tier = 'Situational'
    Summary  = 'Turns off Game Bar capture entirely, including "record what happened" background recording.'
    Detail   = 'Use this if you capture with the NVIDIA app (Instant Replay uses NVENC with lower overhead) or don''t capture at all.'
    Evidence = '"Record what happened" is off by default, so this only gains anything if it had been turned on. With it on, background recording has a real cost.'
    Warning  = 'Win+Alt+R recording and Game Bar screenshots stop working.'
    Ops = @(
        (RegOp $GC 'GameDVR_Enabled' 'DWord' 0 1),
        (RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 'DWord' 0 $null),
        (RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'HistoricalCaptureEnabled' 'DWord' 0 $null)
    )
}

Add-Tweak @{
    Id = 'gamebar-button'; Category = 'Gaming & graphics'; Name = 'Stop the controller Xbox button opening Game Bar'; Tier = 'Situational'
    Summary  = 'Stops the Xbox/guide button on a controller popping up Game Bar.'
    Detail   = 'Game Mode keeps working without it. Win+G still opens Game Bar.'
    Evidence = 'Convenience, not performance.'
    Ops = @(RegOp 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 'DWord' 0 $null)
}

Add-Tweak @{
    Id = 'fso-off'; Category = 'Gaming & graphics'; Name = 'Disable fullscreen optimizations globally'; Tier = 'Unproven'
    Summary  = 'Forces legacy exclusive fullscreen for DX9-11 games that request fullscreen.'
    Detail   = 'An old Windows 10 fix. On Windows 11 the flip model already gives fullscreen-level latency, and disabling FSO can break Auto HDR, fast alt-tab and overlays. If one game misbehaves, disable it per-exe instead (Properties > Compatibility).'
    Evidence = 'Modern testing mostly finds no gain. Some older titles behave better without it. Several of these values are often already set on stock installs, so this may show as Partial.'
    Ops = @(
        (RegOp $GC 'GameDVR_FSEBehaviorMode' 'DWord' 2 $NoDefault),
        (RegOp $GC 'GameDVR_HonorUserFSEBehaviorMode' 'DWord' 1 $NoDefault),
        (RegOp $GC 'GameDVR_FSEBehavior' 'DWord' 2 $NoDefault),
        (RegOp $GC 'GameDVR_DXGIHonorFSEWindowsCompatible' 'DWord' 1 $NoDefault)
    )
}

Add-Tweak @{
    Id = 'mpo-off'; Category = 'Gaming & graphics'; Name = 'Disable multiplane overlay (MPO)'; Tier = 'Situational'; Reboot = 'Reboot'
    Summary  = 'Workaround for flicker, black flashes or stutter with browsers, video or multi-monitor setups.'
    Detail   = 'NVIDIA published this workaround in 2022. Only apply it if you actually see flicker; otherwise MPO saves GPU work and power.'
    Evidence = 'A fix for a specific problem, not a performance gain. The original OverlayTestMode key is widely reported as ignored on 24H2 and later; DisableOverlays is the commonly reported replacement (community-sourced, not documented by Microsoft). Check after a reboot whether the flicker is gone.'
    Ops = @(
        (RegOp 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm' 'OverlayTestMode' 'DWord' 5 $null),
        (RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'DisableOverlays' 'DWord' 1 $null)
    )
}

Add-Tweak @{
    Id = 'mmcss-games'; Category = 'Gaming & graphics'; Name = 'MMCSS "Games" scheduling category = High'; Tier = 'Unproven'; Reboot = 'Reboot'
    Summary  = 'Sets Scheduling Category High for the MMCSS Games profile.'
    Detail   = 'Only affects programs that register with MMCSS as a game, which few do. Guides also set Priority 6 and SFIO High, but Microsoft documents that Priority is treated as 2 when the category is High and that SFIO Priority is unused, so those are left out. "GPU Priority 8" is already the default.'
    Evidence = 'Rated placebo by controlled tests on modern Windows. MMCSS reads these values at boot.'
    Ops = @(RegOp "$MM\Tasks\Games" 'Scheduling Category' 'String' 'High' 'Medium')
}

# ---------------------------------------------------------------------
#  POWER
# ---------------------------------------------------------------------
$planGet = { param($op) $g = Get-ActiveScheme; if ($g) { $g } else { $NA } }
$planSet = { param($op, $v) Set-PlanGuid $v }
$ovlGet  = { param($op) Get-Overlay }
$ovlSet  = { param($op, $v) Set-Overlay $v }

Add-Tweak @{
    Id = 'plan-balanced-best'; Category = 'Power'; Name = 'Balanced plan + "Best performance" power mode (Settings)'; Tier = 'Recommended'; Group = 'plan'; Order = 1
    Summary  = 'Windows'' intended desktop setup: Balanced plan with the Settings power mode on Best performance.'
    Detail   = '"Best performance" is not a separate plan: it''s the Power mode in Settings > System > Power, layered on top of Balanced, so Control Panel only lists Balanced. The Power mode option is hidden while High performance or Ultimate is active. Keeps idle power and temperatures low while boosting quickly under load. Game Mode works with any plan. Per-plan tweaks below (core parking, EPP, USB, PCIe) apply to whichever plan is active, so pick the plan first.'
    Evidence = 'Testing shows High performance and Ultimate give little or no FPS gain over Balanced on modern desktops.'
    Ops = @(
        (ScrOp 'plan:active' 'Active power plan = Balanced' $planGet $planSet $GUID_BAL $GUID_BAL),
        (ScrOp 'plan:overlay' 'Power mode overlay = Best performance' $ovlGet $ovlSet $OVL_BEST $NoDefault)
    )
}

$hpIsOn = { param($c) @($GUID_HP, $GUID_HP_COPY) -contains ([string]$c).ToLower() }
Add-Tweak @{
    Id = 'plan-hp'; Category = 'Power'; Name = 'High performance plan'; Tier = 'Situational'; Group = 'plan'; Order = 1
    Summary  = 'Keeps minimum processor state at 100% so cores don''t drop to idle clocks.'
    Detail   = 'Slightly faster ramp-up for higher idle power and heat.'
    Evidence = 'Small or no FPS difference on modern desktop CPUs. Can help consistency in some latency-sensitive games.'
    Ops = @(ScrOp 'plan:active' 'Active power plan = High performance' $planGet $planSet $GUID_HP $GUID_BAL $hpIsOn)
}

Add-Tweak @{
    Id = 'plan-ult'; Category = 'Power'; Name = 'Ultimate Performance plan'; Tier = 'Situational'; Group = 'plan'; Order = 1
    Summary  = 'Unhides and activates the Ultimate Performance plan.'
    Detail   = 'Creates this tool''s own copy of the hidden plan and switches to it.'
    Evidence = 'A 25H2 comparison found it identical to High performance on AC power except that hard disks never turn off. Expect no gain over High performance.'
    Ops = @(ScrOp 'plan:active' 'Active power plan = Ultimate Performance (tool copy)' $planGet $planSet $GUID_ULT $GUID_BAL)
}

Add-Tweak @{
    Id = 'core-parking-off'; Category = 'Power'; Name = 'Disable core parking (P- and E-cores)'; Tier = 'Unproven'
    Summary  = 'Sets minimum unparked cores to 100% for both core classes on the active plan.'
    Detail   = 'On hybrid CPUs Windows parks P-cores more readily on Balanced. Unparking avoids wake-up latency but raises idle power and can interfere with how Windows steers threads between P- and E-cores.'
    Evidence = 'Mostly placebo on desktops; some players of older latency-sensitive games report smoother pacing. Check with CapFrameX before keeping it. With Balanced + Best performance, the power-mode overlay can override plan values like this one, so it works most predictably on High performance or Ultimate.'
    Ops = @(
        (PwrOp $SUB_PROC '0cc5b647-c1df-4637-891a-dec35c318583' 100 'Core parking min cores (E / all)'),
        (PwrOp $SUB_PROC '0cc5b647-c1df-4637-891a-dec35c318584' 100 'Core parking min cores (P-cores)')
    )
}

Add-Tweak @{
    Id = 'epp-perf'; Category = 'Power'; Name = 'Energy performance preference = maximum performance'; Tier = 'Situational'
    Summary  = 'Tells the CPU''s hardware boost (Speed Shift) to favour performance over efficiency.'
    Detail   = 'EPP 0 makes cores jump to full clocks immediately. High performance already sets this low; Balanced is higher. Raises idle power.'
    Evidence = 'Improves responsiveness in bursty loads; little effect on sustained gaming where cores are already boosting. With Balanced + Best performance, the power-mode overlay sets its own EPP, so this works most predictably on High performance or Ultimate.'
    Ops = @(
        (PwrOp $SUB_PROC '36687f9e-e3a5-4dbf-b1dc-15eb381c6863' 0 'EPP (E / all)'),
        (PwrOp $SUB_PROC '36687f9e-e3a5-4dbf-b1dc-15eb381c6864' 0 'EPP (P-cores)')
    )
}

Add-Tweak @{
    Id = 'usb-ss-off'; Category = 'Power'; Name = 'Disable USB selective suspend'; Tier = 'Situational'
    Summary  = 'Stops Windows powering down idle USB devices.'
    Detail   = 'Fixes mice, controllers and audio interfaces that drop out or lag on first input after idling. Negligible power cost on a desktop.'
    Evidence = 'A fix for a specific problem; no effect if your devices behave.'
    Ops = @(PwrOp '2a737441-1930-4402-8d77-b2bebba308a3' '48e6b7a6-50f5-4782-a5d4-53bb8f07e226' 0 'USB selective suspend')
}

Add-Tweak @{
    Id = 'aspm-off'; Category = 'Power'; Name = 'Disable PCIe Link State Power Management'; Tier = 'Situational'
    Summary  = 'Keeps PCIe links (GPU, NVMe) out of low-power link states.'
    Detail   = 'Can remove tiny wake-up delays and fixes some NVMe or GPU link issues. Slightly higher idle power.'
    Evidence = 'Little measurable difference on most systems; occasionally fixes stutter or device resets.'
    Ops = @(PwrOp '501a4d13-42af-4429-9fd1-a8218c268e20' 'ee12f906-d277-404b-b6da-e5fa1a576df5' 0 'PCIe ASPM')
}

Add-Tweak @{
    Id = 'powerthrottle-off'; Category = 'Power'; Name = 'Disable power throttling (EcoQoS)'; Tier = 'Situational'; Reboot = 'Reboot'
    Summary  = 'Stops Windows pushing background apps onto E-cores at low clocks.'
    Detail   = 'Useful if you run renders, encodes, ComfyUI or LLM jobs in the background and want them at full speed while another window has focus. Costs efficiency.'
    Evidence = 'Real effect on background throughput on hybrid CPUs; no effect on the foreground game.'
    Ops = @(RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 'DWord' 1 $null)
}

Add-Tweak @{
    Id = 'faststartup-off'; Category = 'Power'; Name = 'Disable Fast Startup'; Tier = 'Recommended'
    Summary  = 'Makes Shut down a real shutdown instead of a kernel hibernate.'
    Detail   = 'Fast Startup restores the kernel and drivers from disk on boot, which can carry driver glitches across shutdowns. On NVMe the boot-time saving is small. Takes effect at the next shutdown.'
    Evidence = 'A reliability change rather than a performance one; long-standing enthusiast recommendation.'
    Ops = @(RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 'DWord' 0 1)
}

Add-Tweak @{
    Id = 'hibernate-off'; Category = 'Power'; Name = 'Disable hibernation'; Tier = 'Situational'
    Summary  = 'Deletes hiberfil.sys and disables hibernate and Fast Startup.'
    Detail   = 'hiberfil.sys is sized from your RAM, so it can be tens of GB on machines with lots of memory. You lose the Hibernate option.'
    Evidence = 'Frees disk space; no performance effect.'
    Ops = @(ScrOp 'script:hibernate' 'powercfg /hibernate off' `
        { param($op) $v = RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'; if ($null -eq $v) { 1 } else { $v } } `
        { param($op, $v) if ([string]$v -eq '0') { & powercfg /hibernate off | Out-Null } else { & powercfg /hibernate on | Out-Null } } `
        0 1)
}

# ---------------------------------------------------------------------
#  CPU & TIMERS
# ---------------------------------------------------------------------
Add-Tweak @{
    Id = 'win32prio'; Category = 'CPU & timers'; Name = 'Win32PrioritySeparation = 0x26'; Tier = 'Unproven'
    Summary  = 'Short, variable scheduler quanta with a 3x foreground boost.'
    Detail   = 'Changes how long threads run before the scheduler switches. The default (2) already boosts the foreground app.'
    Evidence = 'Microsoft documents that on client Windows the default (2) already gives short, variable quanta with a 3:1 foreground boost, which is what 0x26 sets explicitly. Expect no change.'
    Ops = @(RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 'DWord' 38 2)
}

Add-Tweak @{
    Id = 'hpet-clear'; Category = 'CPU & timers'; Name = 'Remove forced HPET (useplatformclock)'; Tier = 'Recommended'; Reboot = 'Reboot'; Group = 'hpet'
    Summary  = 'Undoes an old tweak that forces HPET as the system timer.'
    Detail   = 'Forcing HPET makes timer reads slower and has been linked to stutter. "Applied" means the override isn''t set, which is the Windows default.'
    Evidence = 'Modern guidance: let Windows choose (TSC). Forcing HPET is widely reported as worse.'
    Warning  = $BitLockerNote
    Ops = @(BcdOp 'useplatformclock' $null $NoDefault)
}

$op = BcdOp 'disabledynamictick' 'Yes' $null
Add-Tweak @{
    Id = 'dynamictick-off'; Category = 'CPU & timers'; Name = 'Disable dynamic tick'; Tier = 'Unproven'; Reboot = 'Reboot'
    Summary  = 'Keeps the timer interrupt firing at a fixed rate even when idle.'
    Detail   = 'Dynamic tick lets Windows skip timer ticks when idle to save power. Disabling it raises idle power.'
    Evidence = 'Mixed. At least one forum user fixed stutter by reverting this tweak, so test both ways.'
    Warning  = $BitLockerNote
    Ops = @($op)
}

Add-Tweak @{
    Id = 'hpet-force'; Category = 'CPU & timers'; Name = 'Force HPET as platform clock'; Tier = 'Risky'; Reboot = 'Reboot'; Group = 'hpet'
    Summary  = 'Forces HPET instead of TSC as the timer source.'
    Detail   = 'Included only so you can A/B test it. Expect worse frame times and higher timer overhead on modern systems.'
    Evidence = 'Generally reported as worse on modern CPUs; a classic placebo-or-harm tweak.'
    Warning  = $BitLockerNote
    Ops = @(BcdOp 'useplatformclock' 'Yes' $null)
}

Add-Tweak @{
    Id = 'timer-global'; Category = 'CPU & timers'; Name = 'Allow global timer resolution requests'; Tier = 'Unproven'; Reboot = 'Reboot'
    Summary  = 'Restores the pre-Windows 10 2004 behaviour where one app''s high timer resolution applies system-wide.'
    Detail   = 'Since Windows 10 2004, timer resolution requests only affect the process that made them; Windows 11 honours this registry override to make them global again. Raises idle power.'
    Evidence = 'Fixes some games or tools that relied on another process''s timer request (for example unexpected 64 FPS caps). No general gaming gain.'
    Ops = @(RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\kernel' 'GlobalTimerResolutionRequests' 'DWord' 1 $null)
}

# ---------------------------------------------------------------------
#  SECURITY TRADE-OFFS
# ---------------------------------------------------------------------
Add-Tweak @{
    Id = 'hvci-off'; Category = 'Security trade-offs'; Name = 'Turn off Memory Integrity (HVCI)'; Tier = 'Security'; Reboot = 'Reboot'
    Summary  = 'Disables hypervisor-enforced kernel code integrity.'
    Detail   = 'HVCI stops malicious or vulnerable drivers running code in the kernel. Microsoft began enabling it on more eligible PCs from October 2026. The live state is shown at the top of the window. Turning it back ON is left to Windows Security, which checks driver compatibility first; this tool only ever restores the exact value it saved.'
    Evidence = 'Cost is largest when CPU-bound: about 5% at 1080p and 2% at 4K in one recent test; about 8% on a Ryzen 5800X3D under 24H2 (ComputerBase). Newer CPUs with MBEC, including Raptor Lake, lose less.'
    Warning  = 'Some anti-cheats want it on (Riot publishes a guide for enabling it for Vanguard). If it''s enforced by UEFI lock or policy, this change won''t stick.'
    Ops = @(RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 'DWord' 0 $NoDefault)
}

Add-Tweak @{
    Id = 'kss-off'; Category = 'Security trade-offs'; Name = 'Turn off kernel-mode hardware-enforced stack protection'; Tier = 'Security'; Reboot = 'Reboot'
    Summary  = 'Disables CET shadow stacks for kernel code (requires HVCI to be on in the first place).'
    Detail   = 'Blocks return-oriented exploits in the kernel. Some anti-cheat and older drivers are incompatible with it.'
    Evidence = 'No published gaming benchmarks; mostly a compatibility switch.'
    Ops = @(RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\KernelShadowStacks' 'Enabled' 'DWord' 0 $NoDefault)
}

Add-Tweak @{
    Id = 'vbs-off'; Category = 'Security trade-offs'; Name = 'Turn off Virtualization-based Security'; Tier = 'Security'; Reboot = 'Reboot'
    Summary  = 'Disables the isolated environment that HVCI, Credential Guard and others run in.'
    Detail   = 'Turning off HVCI alone can leave VBS running. This turns the platform off. Enhanced sign-in security and some enterprise features need it.'
    Evidence = 'The ~5% CPU-bound figures above are measured with VBS fully off.'
    Warning  = 'If VBS is UEFI-locked this won''t take effect. The hypervisor may still load for WSL2 or Hyper-V. Breaks Windows Hello Enhanced Sign-in Security where enrolled (PIN and password still work).'
    Ops = @(RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard' 'EnableVirtualizationBasedSecurity' 'DWord' 0 $null)
}

$op = BcdOp 'hypervisorlaunchtype' 'Off' $null
Add-Tweak @{
    Id = 'hypervisor-off'; Category = 'Security trade-offs'; Name = 'Stop the Windows hypervisor loading at boot'; Tier = 'Risky'; Reboot = 'Reboot'
    Summary  = 'Guarantees VBS can''t run by not starting Hyper-V.'
    Detail   = 'Sets hypervisorlaunchtype Off. With no entry, Windows still starts the hypervisor when VBS or Memory Integrity is configured, so only an explicit Off counts as applied.'
    Evidence = 'Same gain as turning VBS off; the most thorough way to do it.'
    Warning  = ('Breaks WSL2, Docker Desktop, Windows Sandbox, Hyper-V VMs and VM-based apps. ' + $BitLockerNote)
    Ops = @($op)
}

Add-Tweak @{
    Id = 'spectre-off'; Category = 'Security trade-offs'; Name = 'Disable Spectre v2 / Meltdown OS mitigations'; Tier = 'Security'; Reboot = 'Reboot'
    Summary  = 'Turns off Windows'' software mitigations for CVE-2017-5715 and CVE-2017-5754.'
    Detail   = 'Uses Microsoft''s documented FeatureSettingsOverride values. CPU microcode mitigations still apply.'
    Evidence = 'A big cost on pre-2019 CPUs. Raptor Lake mitigates much of this in hardware, so expect a small gain at most.'
    Ops = @(
        (RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'FeatureSettingsOverride' 'DWord' 3 $null),
        (RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' 'FeatureSettingsOverrideMask' 'DWord' 3 $null)
    )
}

Add-Tweak @{
    Id = 'cfg-off'; Category = 'Security trade-offs'; Name = 'Disable Control Flow Guard system-wide'; Tier = 'Risky'; Reboot = 'Reboot'
    Summary  = 'Turns off the CFG exploit mitigation for all processes.'
    Detail   = 'CFG is compiled into Windows and many apps to block control-flow hijacking.'
    Evidence = 'No reliable gaming gains published.'
    Warning  = 'Some games and anti-cheats refuse to start or crash with CFG off.'
    Ops = @(ScrOp 'script:cfg' 'System process mitigation: CFG = OFF' `
        { param($op) try { [string](Get-ProcessMitigation -System -ErrorAction Stop).CFG.Enable } catch { $NA } } `
        { param($op, $v) if ([string]$v -eq 'OFF') { Set-ProcessMitigation -System -Disable CFG -ErrorAction Stop } else { Set-ProcessMitigation -System -Enable CFG -ErrorAction Stop } } `
        'OFF' 'ON')
}

# ---------------------------------------------------------------------
#  PRIVACY & AI
# ---------------------------------------------------------------------
Add-Tweak @{
    Id = 'telemetry-min'; Category = 'Privacy & AI'; Name = 'Diagnostic data to minimum'; Tier = 'Recommended'
    Summary  = 'Sets the telemetry policy to its lowest level.'
    Detail   = 'On Home and Pro, 0 is treated as "Required", the lowest those editions allow. Settings will show "Some settings are managed by your organization".'
    Evidence = 'Privacy change; no measurable performance effect.'
    Ops = @(RegOp "$POL\DataCollection" 'AllowTelemetry' 'DWord' 0 $null)
}

Add-Tweak @{
    Id = 'diagtrack-off'; Category = 'Privacy & AI'; Name = 'Disable Connected User Experiences and Telemetry service'; Tier = 'Situational'
    Summary  = 'Stops the DiagTrack service that uploads diagnostic data.'
    Detail   = 'Pairs with the telemetry policy above.'
    Evidence = 'Tiny background CPU and network saving.'
    Warning  = 'Can break Feedback Hub and Insider features.'
    Ops = @(SvcOp 'DiagTrack' 4)
}

Add-Tweak @{
    Id = 'adid-off'; Category = 'Privacy & AI'; Name = 'Advertising ID off'; Tier = 'Recommended'
    Summary  = 'Stops apps using your advertising ID for personalised ads.'
    Evidence = 'Privacy change.'
    Ops = @(RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'DWord' 0 1)
}

Add-Tweak @{
    Id = 'tailored-off'; Category = 'Privacy & AI'; Name = 'Tailored experiences off'; Tier = 'Recommended'
    Summary  = 'Stops Microsoft using diagnostic data for personalised tips and ads.'
    Evidence = 'Privacy change.'
    Ops = @(RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'DWord' 0 1)
}

Add-Tweak @{
    Id = 'activity-off'; Category = 'Privacy & AI'; Name = 'Activity history off'; Tier = 'Recommended'
    Summary  = 'Stops Windows collecting and uploading activity history.'
    Evidence = 'Privacy change.'
    Ops = @(
        (RegOp "$POL\System" 'EnableActivityFeed' 'DWord' 0 $null),
        (RegOp "$POL\System" 'PublishUserActivities' 'DWord' 0 $null),
        (RegOp "$POL\System" 'UploadUserActivities' 'DWord' 0 $null)
    )
}

Add-Tweak @{
    Id = 'recall-off'; Category = 'Privacy & AI'; Name = 'Block Recall'; Tier = 'Recommended'; Reboot = 'Reboot'
    Summary  = 'Prevents Recall screen snapshots from being enabled.'
    Detail   = 'Recall only exists on Copilot+ PCs and is off by default, so on other hardware this is a harmless safeguard.'
    Evidence = 'Privacy change.'
    Ops = @(
        (RegOp "$POL\WindowsAI" 'AllowRecallEnablement' 'DWord' 0 $null),
        (RegOp 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 'DWord' 1 $null)
    )
}

Add-Tweak @{
    Id = 'copilot-policy'; Category = 'Privacy & AI'; Name = 'Turn off Windows Copilot (legacy policy)'; Tier = 'Unproven'
    Summary  = 'Sets the old "Turn off Windows Copilot" policy.'
    Detail   = 'Targets the old sidebar Copilot. The newer Copilot app ignores it, so pair it with removing the app below.'
    Evidence = 'Harmless, but does nothing for the 25H2 Copilot app.'
    Ops = @(RegOp 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'DWord' 1 $null)
}

$appxGet = {
    param($op)
    # One package enumeration per refresh, shared by every Appx op.
    if (-not $script:Cache.ContainsKey('appx')) {
        $script:Cache['appx'] = @(Get-AppxPackage -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }
    (@($op.Pkgs | Where-Object { $script:Cache['appx'] -contains $_ }) -join ',')
}
$appxSet = {
    param($op, $v)
    if ([string]::IsNullOrEmpty([string]$v)) {
        foreach ($p in $op.Pkgs) {
            $pk = Get-AppxPackage -Name $p -ErrorAction SilentlyContinue
            if ($pk) {
                try { $pk | Remove-AppxPackage -ErrorAction Stop; Log "    removed $p" }
                catch { $script:Failures++; Log ("    FAILED to remove ${p}: " + $_.Exception.Message) 'ERR' }
            }
        }
    } else {
        Log ("    Can't reinstall automatically: $v. Get them back from the Microsoft Store.") 'WARN'
    }
}
$appxIsOn = { param($c) [string]::IsNullOrEmpty([string]$c) }

$op = ScrOp 'appx:copilot' 'Uninstall the Copilot app for your account' $appxGet $appxSet '' $NoDefault $appxIsOn
$op.Pkgs = @('Microsoft.Copilot')
Add-Tweak @{
    Id = 'copilot-remove'; Category = 'Privacy & AI'; Name = 'Remove the Copilot app'; Tier = 'Situational'; OneWay = $true
    Summary  = 'Uninstalls the Copilot app for your account.'
    Detail   = 'One-way: reinstall from the Microsoft Store to undo.'
    Evidence = 'Removes a background-capable app; no measurable gaming effect.'
    Warning  = 'Windows or Store updates can reinstall it.'
    Ops = @($op)
}

Add-Tweak @{
    Id = 'websearch-off'; Category = 'Privacy & AI'; Name = 'Remove Bing web results from Start search'; Tier = 'Recommended'; Reboot = 'Explorer'
    Summary  = 'Start search only searches your PC.'
    Evidence = 'Faster, more relevant Start search; privacy change.'
    Warning  = 'Also removes recent-search suggestions in File Explorer''s search box, and Search settings show "managed by your organization".'
    Ops = @(RegOp 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'DWord' 1 $null)
}

Add-Tweak @{
    Id = 'start-recs-off'; Category = 'Privacy & AI'; Name = 'Remove Start menu recommendations and account nags'; Tier = 'Recommended'; Reboot = 'Explorer'
    Summary  = 'Turns off "tips, shortcuts, new apps" recommendations and Microsoft account prompts in Start.'
    Evidence = 'Declutter; no performance effect.'
    Ops = @(
        (RegOp $ADV 'Start_IrisRecommendations' 'DWord' 0 $null),
        (RegOp $ADV 'Start_AccountNotifications' 'DWord' 0 $null)
    )
}

Add-Tweak @{
    Id = 'cdm-off'; Category = 'Privacy & AI'; Name = 'Stop suggestions, tips and silent app installs'; Tier = 'Recommended'
    Summary  = 'Disables Content Delivery Manager suggestions and promoted app installs.'
    Detail   = 'Covers Start suggestions, "get even more out of Windows" prompts, suggested content in Settings and auto-installed promoted apps.'
    Evidence = 'Declutter; stops surprise app installs.'
    Ops = @(
        (RegOp $CDM 'SystemPaneSuggestionsEnabled' 'DWord' 0 1),
        (RegOp $CDM 'SilentInstalledAppsEnabled' 'DWord' 0 1),
        (RegOp $CDM 'SoftLandingEnabled' 'DWord' 0 1),
        (RegOp $CDM 'SubscribedContent-338388Enabled' 'DWord' 0 1),
        (RegOp $CDM 'SubscribedContent-338389Enabled' 'DWord' 0 1),
        (RegOp $CDM 'SubscribedContent-310093Enabled' 'DWord' 0 1),
        (RegOp $CDM 'SubscribedContent-353694Enabled' 'DWord' 0 1),
        (RegOp $CDM 'SubscribedContent-353696Enabled' 'DWord' 0 1),
        (RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 'DWord' 0 $null)
    )
}

Add-Tweak @{
    Id = 'lockscreen-tips-off'; Category = 'Privacy & AI'; Name = 'Lock screen tips and fun facts off'; Tier = 'Recommended'
    Summary  = 'Removes the overlay tips and facts on the lock screen.'
    Evidence = 'Declutter.'
    Ops = @(
        (RegOp $CDM 'RotatingLockScreenOverlayEnabled' 'DWord' 0 1),
        (RegOp $CDM 'SubscribedContent-338387Enabled' 'DWord' 0 1)
    )
}

Add-Tweak @{
    Id = 'widgets-off'; Category = 'Privacy & AI'; Name = 'Disable Widgets'; Tier = 'Recommended'; Reboot = 'Explorer'
    Summary  = 'Removes the Widgets board and its background WebView processes (policy).'
    Evidence = 'Saves a few hundred MB of RAM and some background activity.'
    FailHint = 'Windows has locked this policy key on your PC, so even admins can''t write it. Either turn off Settings > Personalization > Taskbar > Widgets, or use "Remove Widgets (Web Experience Pack)" in this tool.'
    Ops = @(RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 'DWord' 0 $null)
}

$op = ScrOp 'appx:widgets' 'Uninstall the Windows Web Experience Pack for your account' $appxGet $appxSet '' $NoDefault $appxIsOn
$op.Pkgs = @('MicrosoftWindows.Client.WebExperience')
Add-Tweak @{
    Id = 'widgets-remove'; Category = 'Privacy & AI'; Name = 'Remove Widgets (Web Experience Pack)'; Tier = 'Situational'; OneWay = $true; Reboot = 'Explorer'
    Summary  = 'Uninstalls the app that powers Widgets. Use this if the Widgets policy is blocked on your PC.'
    Detail   = 'One-way: reinstall "Windows Web Experience Pack" from the Microsoft Store to undo.'
    Evidence = 'Removes the Widgets board and its background processes entirely.'
    Warning  = 'The lock screen "Weather and more" panel also uses it and will stop working. Windows or Store updates can reinstall it.'
    Ops = @($op)
}

Add-Tweak @{
    Id = 'wer-off'; Category = 'Privacy & AI'; Name = 'Disable Windows Error Reporting'; Tier = 'Situational'
    Summary  = 'Stops crash reports being sent to Microsoft.'
    Detail   = 'Blue-screen minidumps are still written. App crash dumps (WER LocalDumps) and Reliability Monitor''s app-crash details are not.'
    Evidence = 'Privacy change; avoids WerFault activity after crashes.'
    Ops = @(RegOp "$POL\Windows Error Reporting" 'Disabled' 'DWord' 1 $null)
}

# ---------------------------------------------------------------------
#  BACKGROUND & UPDATES
# ---------------------------------------------------------------------
Add-Tweak @{
    Id = 'do-p2p-off'; Category = 'Background & updates'; Name = 'Delivery Optimization: no peer-to-peer'; Tier = 'Recommended'
    Summary  = 'Downloads updates from Microsoft only and stops uploading them to other PCs.'
    Evidence = 'Removes background upload traffic.'
    Ops = @(RegOp "$POL\DeliveryOptimization" 'DODownloadMode' 'DWord' 0 $null)
}

Add-Tweak @{
    Id = 'wu-drivers-off'; Category = 'Background & updates'; Name = 'Stop Windows Update installing drivers'; Tier = 'Recommended'
    Summary  = 'Stops Windows Update replacing your GPU or chipset drivers.'
    Detail   = 'Prevents WU swapping your NVIDIA driver for an older OEM build. You then update drivers yourself.'
    Evidence = 'A common cause of "my performance changed overnight".'
    Warning  = 'Microsoft supports this policy on Pro and above; Home may ignore it. It also blocks chipset, Bluetooth and firmware updates through Windows Update.'
    Ops = @(RegOp "$POL\WindowsUpdate" 'ExcludeWUDriversInQualityUpdate' 'DWord' 1 $null)
}

Add-Tweak @{
    Id = 'wu-noreboot'; Category = 'Background & updates'; Name = 'No automatic restart while signed in (legacy policy)'; Tier = 'Unproven'
    Summary  = 'Asks Windows Update not to restart the PC while you''re signed in.'
    Detail   = 'Microsoft documents that this only applies when automatic updates are set to "Auto download and schedule install" (AUOptions=4), which this tool does not change, and that update deadlines still force restarts. Setting Active hours in Settings > Windows Update is the reliable option.'
    Evidence = 'Recent 25H2 reports show forced restarts even with this set.'
    Ops = @(RegOp "$POL\WindowsUpdate\AU" 'NoAutoRebootWithLoggedOnUsers' 'DWord' 1 $null)
}

Add-Tweak @{
    Id = 'bgapps-off'; Category = 'Background & updates'; Name = 'Block Store apps running in the background'; Tier = 'Situational'
    Summary  = 'Stops Microsoft Store apps running when not open.'
    Detail   = 'Doesn''t affect normal desktop programs (Steam, Discord, browsers).'
    Evidence = 'Small background saving.'
    Warning  = 'Breaks notifications and sync for Store apps such as Phone Link, WhatsApp and Mail, and also affects inbox Store apps like the Xbox app and Snipping Tool.'
    Ops = @(RegOp "$POL\AppPrivacy" 'LetAppsRunInBackground' 'DWord' 2 $null)
}

Add-Tweak @{
    Id = 'edge-bg-off'; Category = 'Background & updates'; Name = 'Stop Edge running in the background'; Tier = 'Situational'
    Summary  = 'Disables Edge Startup Boost and background mode.'
    Detail   = 'Edge will show "managed by your organization" because these are policies.'
    Evidence = 'Frees the Edge processes that otherwise stay resident.'
    Ops = @(
        (RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'StartupBoostEnabled' 'DWord' 0 $null),
        (RegOp 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' 'BackgroundModeEnabled' 'DWord' 0 $null)
    )
}

Add-Tweak @{
    Id = 'sysmain-off'; Category = 'Background & updates'; Name = 'Disable SysMain (Superfetch)'; Tier = 'Unproven'
    Summary  = 'Stops Windows preloading frequently used apps into RAM.'
    Detail   = 'With NVMe and plenty of RAM the effect is small either way.'
    Evidence = 'Split verdicts: some testers rate it real, others placebo.'
    Warning  = 'Memory compression is managed through SysMain, so the memory-compression tweak can''t be changed while it''s disabled.'
    Ops = @(SvcOp 'SysMain' 4)
}

Add-Tweak @{
    Id = 'memcomp-off'; Category = 'Background & updates'; Name = 'Disable memory compression'; Tier = 'Unproven'; Reboot = 'Reboot'; Order = 40
    Summary  = 'Stops Windows compressing memory pages instead of paging them out.'
    Detail   = 'With plenty of RAM (32 GB+) you rarely hit memory pressure, so compression rarely runs anyway. Needs SysMain running to change.'
    Evidence = 'Rated placebo in most tests.'
    Ops = @(ScrOp 'script:memcomp' 'Disable-MMAgent -MemoryCompression' `
        { param($op) try { [string](Get-MMAgent -ErrorAction Stop).MemoryCompression } catch { $NA } } `
        { param($op, $v) if ([string]$v -eq 'False') { Disable-MMAgent -MemoryCompression -ErrorAction Stop } else { Enable-MMAgent -MemoryCompression -ErrorAction Stop } } `
        'False' 'True')
}

Add-Tweak @{
    Id = 'wsearch-off'; Category = 'Background & updates'; Name = 'Disable Windows Search indexing'; Tier = 'Situational'
    Summary  = 'Stops the search indexer service.'
    Evidence = 'Placebo for FPS; reduces background disk and CPU after large file changes.'
    Warning  = 'File search in Start and Explorer becomes slow, and Outlook search breaks.'
    Ops = @(SvcOp 'WSearch' 4)
}

Add-Tweak @{
    Id = 'spooler-off'; Category = 'Background & updates'; Name = 'Disable Print Spooler'; Tier = 'Situational'
    Summary  = 'Only if you never print, including to "Microsoft Print to PDF".'
    Evidence = 'Reduces attack surface; negligible performance effect.'
    Ops = @(SvcOp 'Spooler' 4)
}

Add-Tweak @{
    Id = 'xbox-svcs-off'; Category = 'Background & updates'; Name = 'Disable Xbox services'; Tier = 'Unproven'
    Summary  = 'Disables Xbox Live auth, game save, networking and accessory services.'
    Detail   = 'They''re already Manual (start on demand), so disabling saves almost nothing.'
    Evidence = 'Placebo for performance.'
    Warning  = 'Breaks Game Pass, Xbox app sign-in, cloud saves and Xbox controller updates.'
    Ops = @(
        (SvcOp 'XblAuthManager' 4),
        (SvcOp 'XblGameSave' 4),
        (SvcOp 'XboxNetApiSvc' 4),
        (SvcOp 'XboxGipSvc' 4)
    )
}

Add-Tweak @{
    Id = 'startup-delay-off'; Category = 'Background & updates'; Name = 'Remove startup app delay'; Tier = 'Situational'
    Summary  = 'Startup apps launch immediately after sign-in instead of being staggered.'
    Evidence = 'Faster ready-to-use desktop on fast NVMe; slightly busier first seconds.'
    Ops = @(RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 'DWord' 0 $null)
}

$op = ScrOp 'appx:bloat' 'Uninstall preinstalled consumer apps for your account' $appxGet $appxSet '' $NoDefault $appxIsOn
$op.Pkgs = @('Microsoft.BingNews', 'Microsoft.BingWeather', 'Microsoft.BingSearch', 'Clipchamp.Clipchamp',
             'Microsoft.MicrosoftSolitaireCollection', 'Microsoft.MicrosoftOfficeHub',
             'Microsoft.Todos', 'Microsoft.WindowsFeedbackHub', 'Microsoft.PowerAutomateDesktop', 'MSTeams',
             'Microsoft.OutlookForWindows')
Add-Tweak @{
    Id = 'bloat-remove'; Category = 'Background & updates'; Name = 'Remove preinstalled consumer apps'; Tier = 'Situational'; OneWay = $true
    Summary  = 'Uninstalls News, Weather, Bing Search, Clipchamp, Solitaire, Microsoft 365 hub, To Do, Feedback Hub, Power Automate, Teams (personal) and new Outlook.'
    Detail   = 'One-way: reinstall any of them from the Microsoft Store. Get Help is kept because Windows'' troubleshooters now run inside it. Phone Link, Photos, Terminal, Store and Xbox apps are left alone.'
    Evidence = 'Declutter; few of these run in the background.'
    Warning  = 'Windows or Store updates can reinstall some of these.'
    Ops = @($op)
}

# ---------------------------------------------------------------------
#  INPUT
# ---------------------------------------------------------------------
Add-Tweak @{
    Live = {
        $m = 'HKCU:\Control Panel\Mouse'
        $t1 = 6; $t2 = 10; $sp = 1
        [void][int]::TryParse([string](RegGet $m 'MouseThreshold1'), [ref]$t1)
        [void][int]::TryParse([string](RegGet $m 'MouseThreshold2'), [ref]$t2)
        [void][int]::TryParse([string](RegGet $m 'MouseSpeed'), [ref]$sp)
        [W11T.Live]::SetMouse($t1, $t2, $sp)
    }
    Id = 'mouse-accel-off'; Category = 'Input'; Name = 'Turn off "Enhance pointer precision"'; Tier = 'Recommended'
    Summary  = 'Removes Windows mouse acceleration.'
    Detail   = 'Most modern games use raw input and bypass it, but it still affects the desktop, menus and games without raw input.'
    Evidence = 'Consistent 1:1 movement; standard advice for FPS players.'
    Ops = @(
        (RegOp 'HKCU:\Control Panel\Mouse' 'MouseSpeed' 'String' '0' '1'),
        (RegOp 'HKCU:\Control Panel\Mouse' 'MouseThreshold1' 'String' '0' '6'),
        (RegOp 'HKCU:\Control Panel\Mouse' 'MouseThreshold2' 'String' '0' '10')
    )
}

function HotkeyOp([string]$Sub, [string]$Label, [int]$Default) {
    # Only the "hotkey active" bit (0x4) matters; every other flag the user has set is left alone.
    $path = "HKCU:\Control Panel\Accessibility\$Sub"
    $o = ScrOp ('reg:{0}|Flags' -f $path) ('{0} shortcut off (clears bit 0x4 in {1}\Flags)' -f $Label, $path) `
        { param($op) RegGet $op.Path 'Flags' } `
        { param($op, $v)
          if ([string]$v -eq 'clear-hotkey') {
              $cur = RegGet $op.Path 'Flags'
              $n = $op.Default
              if ($null -ne $cur) { [void][int]::TryParse([string]$cur, [ref]$n) }
              RegSet $op.Path 'Flags' 'String' ([string]($n -band (-bnot 4)))
          } else { RegSet $op.Path 'Flags' 'String' $v } } `
        'clear-hotkey' $NoDefault `
        { param($c) $n = 0; if (-not [int]::TryParse([string]$c, [ref]$n)) { return $false }; (($n -band 4) -eq 0) }
    $o | Add-Member -NotePropertyName Path -NotePropertyValue $path
    $o | Add-Member -NotePropertyName Default -NotePropertyValue $Default
    $o.Validate = { param($v, $op) [string]$v -match '^\d{1,6}$' }
    $o
}

Add-Tweak @{
    Live = {
        $ok = $true
        foreach ($w in @(@('StickyKeys', 510), @('Keyboard Response', 126), @('ToggleKeys', 62))) {
            $n = $w[1]
            [void][int]::TryParse([string](RegGet ('HKCU:\Control Panel\Accessibility\' + $w[0]) 'Flags'), [ref]$n)
            if (-not [W11T.Live]::SetHotkey($w[0], (($n -band 4) -ne 0))) { $ok = $false }
        }
        $ok
    }
    Id = 'sticky-off'; Category = 'Input'; Name = 'Disable Sticky / Filter / Toggle Keys shortcuts'; Tier = 'Recommended'
    Summary  = 'Stops the pop-up when you tap Shift five times or hold Shift mid-game.'
    Evidence = 'Quality of life.'
    Detail   = 'Turns off only the keyboard shortcuts; any other Sticky/Filter/Toggle Keys options you''ve set are kept.'
    Ops = @(
        (HotkeyOp 'StickyKeys' 'Sticky Keys' 510),
        (HotkeyOp 'Keyboard Response' 'Filter Keys' 126),
        (HotkeyOp 'ToggleKeys' 'Toggle Keys' 62)
    )
}

Add-Tweak @{
    Live = {
        $d = 1
        [void][int]::TryParse([string](RegGet 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay'), [ref]$d)
        [W11T.Live]::SetKeyboardDelay($d)
    }
    Id = 'kb-fast'; Category = 'Input'; Name = 'Shortest keyboard repeat delay'; Tier = 'Situational'
    Summary  = 'Held keys start repeating sooner.'
    Evidence = 'Preference.'
    Ops = @(RegOp 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' 'String' '0' '1')
}

# ---------------------------------------------------------------------
#  NETWORK
# ---------------------------------------------------------------------
Add-Tweak @{
    Id = 'netthrottle'; Category = 'Network'; Name = 'Disable NetworkThrottlingIndex'; Tier = 'Unproven'; Reboot = 'Reboot'
    Summary  = 'Removes the MMCSS cap on network packet processing while multimedia plays.'
    Detail   = 'Default is 10. 0xFFFFFFFF turns throttling off.'
    Evidence = 'Mixed: some guides report better 1% lows in online games, other testing finds no difference. Cheap to test.'
    Ops = @(RegOp $MM 'NetworkThrottlingIndex' 'DWord' -1 10)
}

Add-Tweak @{
    Id = 'sysresp'; Category = 'Network'; Name = 'MMCSS SystemResponsiveness = 10'; Tier = 'Unproven'; Reboot = 'Reboot'
    Summary  = 'Reserves 10% CPU for background tasks under MMCSS instead of the default 20%.'
    Detail   = 'Guides usually say 0, but Microsoft documents that values below 10 are treated as 20 (the default), so 0 does nothing. 10 is the lowest value honoured.'
    Evidence = 'Only affects MMCSS-registered audio/video threads. No measurable gaming gain shown.'
    Ops = @(RegOp $MM 'SystemResponsiveness' 'DWord' 10 20)
}

$nagleGet = {
    param($op)
    $map = [ordered]@{}
    foreach ($k in (Get-ActiveIfKeys)) {
        $a = RegGet $k.PSPath 'TcpAckFrequency'
        $n = RegGet $k.PSPath 'TCPNoDelay'
        $map[$k.PSChildName] = '{0}|{1}' -f $a, $n
    }
    if ($map.Count -eq 0) { return $NA }
    ($map | ConvertTo-Json -Compress)
}
$nagleSet = {
    param($op, $v)
    if ([string]$v -eq '1') {
        foreach ($k in (Get-ActiveIfKeys)) {
            RegSet $k.PSPath 'TcpAckFrequency' 'DWord' 1
            RegSet $k.PSPath 'TCPNoDelay' 'DWord' 1
        }
    } elseif ($null -eq $v) {
        foreach ($k in (Get-ActiveIfKeys)) {
            RegSet $k.PSPath 'TcpAckFrequency' 'DWord' $null
            RegSet $k.PSPath 'TCPNoDelay' 'DWord' $null
        }
    } else {
        $m = [string]$v | ConvertFrom-Json
        foreach ($p in $m.PSObject.Properties) {
            # Only real, existing interface keys; never create keys from snapshot data.
            if ($p.Name -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { throw "Bad interface name in snapshot: $($p.Name)" }
            $path = Join-Path $IfBase $p.Name
            if (-not (Test-Path -LiteralPath $path)) { continue }
            $parts = ([string]$p.Value) -split '\|', 2
            $a = $null; $n = $null
            if ($parts[0] -ne '') { $a = [int]$parts[0] }
            if ($parts.Count -gt 1 -and $parts[1] -ne '') { $n = [int]$parts[1] }
            RegSet $path 'TcpAckFrequency' 'DWord' $a
            RegSet $path 'TCPNoDelay' 'DWord' $n
        }
    }
}
$nagleIsOn = {
    param($c)
    if (IsNA $c) { return $false }
    $m = [string]$c | ConvertFrom-Json
    $vals = @($m.PSObject.Properties | ForEach-Object { [string]$_.Value })
    ($vals.Count -gt 0) -and (@($vals | Where-Object { $_ -ne '1|1' }).Count -eq 0)
}
Add-Tweak @{
    Id = 'nagle-off'; Category = 'Network'; Name = 'Disable TCP delayed ACK (often sold as "disable Nagle")'; Tier = 'Unproven'
    Summary  = 'Sets TcpAckFrequency=1 (and the legacy TCPNoDelay=1) on every connected IPv4 adapter.'
    Detail   = 'TcpAckFrequency turns off delayed ACKs. Modern Windows doesn''t honour TCPNoDelay in the registry: Nagle can only be turned off by the application itself. Most modern games use UDP, so this only matters for TCP-based games (some MMOs).'
    Evidence = 'Anecdotal gains in older TCP MMOs; no effect on UDP shooters.'
    Ops = @(ScrOp 'script:nagle' 'TcpAckFrequency=1 and TCPNoDelay=1 on active interfaces' $nagleGet $nagleSet '1' $null $nagleIsOn)
}

# ---------------------------------------------------------------------
#  STORAGE
# ---------------------------------------------------------------------
Add-Tweak @{
    Id = 'trim-on'; Category = 'Storage'; Name = 'Make sure TRIM is enabled'; Tier = 'Recommended'
    Summary  = 'Ensures Windows sends TRIM to SSDs.'
    Detail   = 'Should already be on. This repairs it if an old tool turned it off.'
    Evidence = 'Keeps SSD write performance consistent.'
    Ops = @(ScrOp 'script:trim' 'fsutil behavior DisableDeleteNotify (NTFS) = 0' `
        { param($op) $o = (& fsutil behavior query DisableDeleteNotify) -join "`n"; if ($o -match 'NTFS\s+DisableDeleteNotify\s*=\s*(\d)') { [int]$matches[1] } else { $NA } } `
        { param($op, $v) & fsutil behavior set DisableDeleteNotify ([int]$v) | Out-Null } `
        0 $NoDefault)
}

$laOp = RegOp 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'NtfsDisableLastAccessUpdate' 'DWord' -2147483647 -2147483646
$laOp.IsOn = { param($c) if ($null -eq $c) { return $false }; (([int64]$c) -band 1) -eq 1 }
Add-Tweak @{
    Id = 'lastaccess-off'; Category = 'Storage'; Name = 'Disable NTFS last-access timestamps'; Tier = 'Unproven'; Reboot = 'Reboot'
    Summary  = 'Stops NTFS updating the last-access time whenever a file is read.'
    Detail   = 'On large system drives the system-managed default already disables it; any "disabled" setting counts as applied.'
    Evidence = 'Negligible on SSDs.'
    Ops = @($laOp)
}

# ---------------------------------------------------------------------
#  DESKTOP & UI
# ---------------------------------------------------------------------
Add-Tweak @{
    Id = 'transparency-off'; Category = 'Desktop & UI'; Name = 'Turn off transparency effects'; Tier = 'Unproven'
    Summary  = 'Solid taskbar, Start and window backgrounds.'
    Evidence = 'Placebo on any modern GPU; preference.'
    Ops = @(RegOp 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 'DWord' 0 1)
}

Add-Tweak @{
    Id = 'animations-off'; Category = 'Desktop & UI'; Name = 'Turn off window and taskbar animations'; Tier = 'Unproven'; Reboot = 'Sign out'
    Summary  = 'Windows snap open and closed without the minimise/maximise animation.'
    Evidence = 'Feels snappier; no performance gain on a modern GPU.'
    Ops = @(
        (RegOp 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' 'String' '0' '1'),
        (RegOp $ADV 'TaskbarAnimations' 'DWord' 0 1)
    )
}

Add-Tweak @{
    Live = {
        $d = 400
        [void][int]::TryParse([string](RegGet 'HKCU:\Control Panel\Desktop' 'MenuShowDelay'), [ref]$d)
        [W11T.Live]::SetMenuDelay($d)
    }
    Id = 'menu-delay'; Category = 'Desktop & UI'; Name = 'Faster menus (MenuShowDelay 100 ms)'; Tier = 'Situational'
    Summary  = 'Cascading menus open after 100 ms instead of 400 ms.'
    Evidence = 'Preference.'
    Ops = @(RegOp 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' 'String' '100' '400')
}

$classicKey = 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
Add-Tweak @{
    Id = 'classic-menu'; Category = 'Desktop & UI'; Name = 'Classic right-click menu'; Tier = 'Situational'; Reboot = 'Explorer'
    Summary  = 'Brings back the full Windows 10 context menu without "Show more options".'
    Evidence = 'Quality of life.'
    Ops = @(ScrOp 'script:classicmenu' 'HKCU CLSID {86ca1aa0-...}\InprocServer32 (empty default)' `
        { param($op) if (Test-Path -LiteralPath ($classicKey + '\InprocServer32')) { 1 } else { 0 } } `
        { param($op, $v)
          if ([string]$v -eq '1') {
              New-Item -Path ($classicKey + '\InprocServer32') -Force | Out-Null
              Set-ItemProperty -LiteralPath ($classicKey + '\InprocServer32') -Name '(default)' -Value ''
          } else {
              if (Test-Path -LiteralPath $classicKey) { Remove-Item -LiteralPath $classicKey -Recurse -Force }
          } } `
        1 0)
}

Add-Tweak @{
    Id = 'end-task'; Category = 'Desktop & UI'; Name = 'Add "End task" to taskbar right-click'; Tier = 'Recommended'; Reboot = 'Explorer'
    Summary  = 'Kill a frozen app straight from its taskbar icon.'
    Evidence = 'Quality of life.'
    Ops = @(RegOp "$ADV\TaskbarDeveloperSettings" 'TaskbarEndTask' 'DWord' 1 $null)
}

Add-Tweak @{
    Id = 'file-ext'; Category = 'Desktop & UI'; Name = 'Show file extensions'; Tier = 'Recommended'; Reboot = 'Explorer'
    Summary  = 'Shows .exe, .ps1, .pdf and so on in Explorer.'
    Evidence = 'Quality of life, and makes disguised malware (invoice.pdf.exe) obvious.'
    Ops = @(RegOp $ADV 'HideFileExt' 'DWord' 0 1)
}

# =====================================================================
#  Validators and guards for specific ops
# =====================================================================
$OpByKey    = @{}
$TweakIndex = @{}
foreach ($t in $Catalogue) {
    $TweakIndex[$t.Id] = $t
    foreach ($op in $t.Ops) { $OpByKey[$op.Key] = $op }
}

$vGuid = { param($v, $op) ([string]$v).ToLower() -match $GuidRx }
$v01   = { param($v, $op) [string]$v -match '^[01]$' }
foreach ($k in @('plan:active', 'plan:overlay')) { $OpByKey[$k].Validate = $vGuid }
foreach ($k in @('script:hibernate', 'script:trim', 'script:classicmenu')) { $OpByKey[$k].Validate = $v01 }
$OpByKey['script:cfg'].Validate     = { param($v, $op) [string]$v -match '^(ON|OFF|NOTSET)$' }
$OpByKey['script:memcomp'].Validate = { param($v, $op) [string]$v -match '^(True|False)$' }
foreach ($k in @('appx:copilot', 'appx:bloat', 'appx:widgets')) {
    # An empty value would mean "uninstall everything", so it is never accepted from the snapshot.
    $OpByKey[$k].Validate = {
        param($v, $op)
        $s = [string]$v
        if ($s -eq '') { return $false }
        foreach ($n in ($s -split ',')) { if ($op.Pkgs -notcontains $n) { return $false } }
        return $true
    }
}
$OpByKey['script:nagle'].Validate = {
    param($v, $op)
    if ($null -eq $v) { return $true }
    try { $m = [string]$v | ConvertFrom-Json -ErrorAction Stop } catch { return $false }
    foreach ($p in $m.PSObject.Properties) {
        if ($p.Name -notmatch '^\{[0-9A-Fa-f-]{36}\}$') { return $false }
        if ([string]$p.Value -notmatch '^\d{0,10}\|\d{0,10}$') { return $false }
    }
    return $true
}

$DG = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
$lockGuard = {
    if ((RegGet $DG 'Locked') -eq 1 -or (RegGet "$DG\Scenarios\HypervisorEnforcedCodeIntegrity" 'Locked') -eq 1) {
        return 'VBS / Memory Integrity is UEFI-locked on this PC, so registry changes won''t take effect. Use Windows Security or your firmware settings instead.'
    }
    return $null
}
foreach ($id in @('hvci-off', 'vbs-off', 'kss-off')) { $TweakIndex[$id].Guard = $lockGuard }
$TweakIndex['hypervisor-off'].Guard = {
    if ((RegGet $DG 'Mandatory') -eq 1) {
        return 'VBS is set to Mandatory on this PC, so Windows may refuse to boot without the hypervisor. Not applied.'
    }
    & $lockGuard
}

# =====================================================================
#  Snapshot
# =====================================================================
function Get-MachineId { [string](RegGet 'HKLM:\SOFTWARE\Microsoft\Cryptography' 'MachineGuid') }

function Move-Aside([string]$Path, [string]$Tag) {
    $dest = '{0}.{1}-{2}' -f $Path, $Tag, (Get-Date -Format 'yyyyMMdd-HHmmss')
    try { Move-Item -LiteralPath $Path -Destination $dest -Force; return $dest } catch { return $null }
}

function Load-Snapshot {
    $script:Snap = @{}
    $script:SnapBroken = $false
    if (-not (Test-Path -LiteralPath $SnapFile)) { return }
    try {
        $j = Get-Content -LiteralPath $SnapFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $j -or $null -eq $j.ops) { throw 'the file has no "ops" section' }
    } catch {
        $moved = Move-Aside $SnapFile 'corrupt'
        $script:SnapBroken = $true
        Log ("Snapshot could not be read (" + $_.Exception.Message + "). Moved to " + $moved + ".") 'ERR'
        return
    }
    $mid = Get-MachineId
    if ($j.machine -and $mid -and ([string]$j.machine -ne $mid)) {
        $moved = Move-Aside $SnapFile 'other-pc'
        Log ("Snapshot belongs to a different PC and was moved to " + $moved + ". Starting a fresh one.") 'WARN'
        return
    }
    $dropped = 0
    foreach ($p in $j.ops.PSObject.Properties) {
        $key = $p.Name; $val = $p.Value
        $op = $null
        if ($key -match '^pwr:([0-9a-f-]{36}):([0-9a-f-]{36}):([0-9a-f-]{36})$') {
            $op = $OpByKey[('pwr:{0}:{1}' -f $matches[2], $matches[3])]
        } else { $op = $OpByKey[$key] }
        if ($null -eq $op -or -not (Test-SnapValue $op $val)) {
            $dropped++
            Log ("Ignored invalid snapshot entry: " + $key) 'WARN'
            continue
        }
        $script:Snap[$key] = $val
    }
    $script:SnapCreated = [string]$j.created
    Log ("Loaded snapshot with {0} original values (created {1}){2}." -f $script:Snap.Count, $script:SnapCreated, $(if ($dropped) { "; $dropped invalid entries ignored" } else { '' }))
}

function Save-Snapshot {
    if (-not $script:SnapCreated) { $script:SnapCreated = (Get-Date).ToString('s') }
    $obj = [ordered]@{
        version  = 2
        created  = $script:SnapCreated
        updated  = (Get-Date).ToString('s')
        computer = $env:COMPUTERNAME
        machine  = (Get-MachineId)
        user     = $env:USERNAME
        ops      = $script:Snap
    }
    $json = $obj | ConvertTo-Json -Depth 6
    # Write to a temp file and swap it in, so a crash mid-write never leaves a half-written snapshot.
    $tmp = $SnapFile + '.tmp'
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $SnapFile) { [IO.File]::Replace($tmp, $SnapFile, ($SnapFile + '.bak')) }
    else { [IO.File]::Move($tmp, $SnapFile) }
}

# =====================================================================
#  Tweak engine
# =====================================================================
function Get-TweakState($t) {
    $on = 0; $n = 0
    foreach ($op in $t.Ops) {
        try { $cur = Invoke-OpGet $op } catch { $cur = $NA }
        if (IsNA $cur) { continue }
        $n++
        if (Test-OpOn $op $cur) { $on++ }
    }
    if ($n -eq 0)        { return 'Unavailable' }
    if ($on -eq $n)      { return 'Applied' }
    if ($on -eq 0)       { return 'Not applied' }
    return 'Partial'
}

function Apply-Tweak($t) {
    Log ("Apply: {0}" -f $t.Name)
    if ($t.Guard) {
        $why = & $t.Guard
        if ($why) { $script:Failures++; Log ("    Not applied: " + $why) 'WARN'; return }
    }
    foreach ($op in $t.Ops) {
        try {
            $cur = Invoke-OpGet $op
            if (IsNA $cur) { Log ("    skipped (not available on this PC): " + $op.Desc) 'WARN'; continue }
            $key = Get-OpKey $op
            if (-not $script:Snap.ContainsKey($key)) { $script:Snap[$key] = $cur; Save-Snapshot }
            if (Test-OpOn $op $cur) { continue }
            Invoke-OpSet $op $op.On
            Log ("    " + $op.Desc + "   (was " + (Format-Val $cur) + ")")
        } catch {
            $script:Failures++
            Log ("    FAILED: " + $op.Desc + " - " + $_.Exception.Message) 'ERR'
            if ($t.FailHint) { Log ("    Tip: " + $t.FailHint) 'WARN' }
        }
    }
    Invoke-Live $t
}

function Invoke-Live($t) {
    # Push the new registry values to the running session so no sign-out is needed.
    if (-not $t.Live) { return }
    try {
        $ok = & $t.Live
        if ($ok -eq $false) { Log '    Saved, but Windows didn''t take it live; it applies at next sign-in.' 'WARN' }
        else { Log '    Applied to the current session (no sign-out needed).' }
    } catch { Log ('    Saved, but live update failed (applies at next sign-in): ' + $_.Exception.Message) 'WARN' }
}

function Revert-Tweak($t) {
    Log ("Revert: {0}" -f $t.Name)
    if ($t.OneWay) { Log '    One-way tweak: reinstall removed apps from the Microsoft Store.' 'WARN'; return }
    foreach ($op in $t.Ops) {
        try {
            $cur = Invoke-OpGet $op
            if (IsNA $cur) { continue }
            $key = Get-OpKey $op
            if ($script:Snap.ContainsKey($key)) {
                $sv = $script:Snap[$key]
                if (Test-OpOn $op $sv) {
                    # The PC was already like this before the tool touched it, so there is nothing to undo.
                    $script:LeftAlone++
                    Log ("    " + $op.Desc + ": was already set like this before the tool; left as is.")
                    continue
                }
                $target = $sv
            } else { $target = $op.Off }
            if (IsNoDefault $target) { $script:LeftAlone++; Log ("    No saved original for " + $op.Desc + "; left as is.") 'WARN'; continue }
            if ((Norm $cur) -eq (Norm $target)) { continue }
            Invoke-OpSet $op $target
            Log ("    " + $key + " -> " + (Format-Val $target))
        } catch { $script:Failures++; Log ("    FAILED: " + $op.Desc + " - " + $_.Exception.Message) 'ERR' }
    }
    Invoke-Live $t
}

# =====================================================================
#  Self-test (no UI, no changes) - used to validate the catalogue
# =====================================================================
if ($SelfTest) {
    $ids = @{}; $bad = 0
    foreach ($t in $Catalogue) {
        foreach ($f in 'Id', 'Category', 'Name', 'Tier', 'Summary', 'Evidence') {
            if (-not $t.$f) { Write-Host "Missing $f on $($t.Id)"; $bad++ }
        }
        if ($ids.ContainsKey($t.Id)) { Write-Host "Duplicate id $($t.Id)"; $bad++ } else { $ids[$t.Id] = 1 }
        if (@('Recommended', 'Situational', 'Unproven', 'Security', 'Risky') -notcontains $t.Tier) { Write-Host "Bad tier $($t.Tier)"; $bad++ }
        if (@('None', 'Reboot', 'Sign out', 'Explorer') -notcontains $t.Reboot) { Write-Host "Bad reboot $($t.Reboot)"; $bad++ }
        if ($t.Ops.Count -lt 1) { Write-Host "No ops on $($t.Id)"; $bad++ }
        foreach ($op in $t.Ops) { if (-not $op.Key -or -not $op.Desc) { Write-Host "Bad op on $($t.Id)"; $bad++ } }
    }
    $Catalogue | Group-Object Tier | ForEach-Object { Write-Host ('{0,-12} {1}' -f $_.Name, $_.Count) }
    Write-Host ("Total tweaks: {0}; problems: {1}" -f $Catalogue.Count, $bad)
    exit $bad
}

# =====================================================================
#  UI
# =====================================================================
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$XamlText = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="W11 Tweaker" Width="1340" Height="880" MinWidth="1060" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="#16181D" Foreground="#E6E6E6"
        FontFamily="Segoe UI" FontSize="13" UseLayoutRounding="True">
  <Window.Resources>
    <SolidColorBrush x:Key="PanelBrush" Color="#1E2128"/>
    <SolidColorBrush x:Key="LineBrush" Color="#2C313A"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#9AA0A6"/>

    <Style TargetType="Button">
      <Setter Property="Background" Value="#2A2F38"/>
      <Setter Property="Foreground" Value="#E6E6E6"/>
      <Setter Property="BorderBrush" Value="#3A404B"/>
      <Setter Property="Padding" Value="12,6"/>
      <Setter Property="Margin" Value="4,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="4" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Opacity" Value="0.85"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="b" Property="Opacity" Value="0.4"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="PrimaryButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#2F6FEB"/>
      <Setter Property="BorderBrush" Value="#2F6FEB"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#5A2626"/>
      <Setter Property="BorderBrush" Value="#7A3434"/>
    </Style>

    <Style TargetType="TextBox">
      <Setter Property="Background" Value="#11131A"/>
      <Setter Property="Foreground" Value="#E6E6E6"/>
      <Setter Property="BorderBrush" Value="#3A404B"/>
      <Setter Property="CaretBrush" Value="#E6E6E6"/>
      <Setter Property="Padding" Value="6,4"/>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="#E6E6E6"/>
      <Setter Property="Margin" Value="0,0,14,0"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E6E6E6"/>
    </Style>

    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#1E2128"/>
      <Setter Property="Foreground" Value="#9AA0A6"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="8,8"/>
      <Setter Property="BorderBrush" Value="#2C313A"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
    </Style>
    <Style TargetType="DataGridRow">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="ToolTip" Value="{Binding Summary}"/>
      <Style.Triggers>
        <Trigger Property="IsMouseOver" Value="True">
          <Setter Property="Background" Value="#232731"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Foreground" Value="#E6E6E6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Border Background="{TemplateBinding Background}" Padding="8,6">
              <ContentPresenter VerticalAlignment="Center"/>
            </Border>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#25344F"/>
          <Setter Property="Foreground" Value="#FFFFFF"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style x:Key="SectionLabel" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#7F8790"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,6,0,4"/>
    </Style>
  </Window.Resources>

  <Grid>
  <Grid x:Name="MainGrid" Margin="18">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0">
      <TextBlock Text="W11 Tweaker" FontSize="22" FontWeight="SemiBold"/>
      <TextBlock x:Name="InfoText" Foreground="#9AA0A6" Margin="0,4,0,0" TextWrapping="Wrap" Text="Reading system state..."/>
    </StackPanel>

    <DockPanel Grid.Row="1" Margin="0,14,0,10" LastChildFill="False">
      <TextBox x:Name="SearchBox" Width="240" DockPanel.Dock="Left" VerticalContentAlignment="Center" ToolTip="Search tweaks"/>
      <StackPanel Orientation="Horizontal" DockPanel.Dock="Left" Margin="18,0,0,0" VerticalAlignment="Center">
        <RadioButton x:Name="TierAll" Content="All" GroupName="tier" IsChecked="True"/>
        <RadioButton x:Name="TierRecommended" Content="Recommended" GroupName="tier"/>
        <RadioButton x:Name="TierSituational" Content="Situational" GroupName="tier"/>
        <RadioButton x:Name="TierUnproven" Content="Unproven" GroupName="tier"/>
        <RadioButton x:Name="TierSecurity" Content="Security" GroupName="tier"/>
        <RadioButton x:Name="TierRisky" Content="Risky" GroupName="tier"/>
      </StackPanel>
      <CheckBox x:Name="PendingOnly" Content="Pending only" DockPanel.Dock="Left" Margin="6,0,0,0" VerticalAlignment="Center"/>
      <Button x:Name="BtnRecommended" Content="Tick all Recommended" DockPanel.Dock="Right" Margin="4,0,0,0"/>
      <Button x:Name="BtnDiscard" Content="Discard changes" DockPanel.Dock="Right"/>
    </DockPanel>

    <Grid Grid.Row="2">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="420"/>
      </Grid.ColumnDefinitions>

      <Border Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource LineBrush}" BorderThickness="1" CornerRadius="6">
        <DataGrid x:Name="TweakGrid" AutoGenerateColumns="False" IsReadOnly="True" HeadersVisibility="Column"
                  GridLinesVisibility="None" Background="Transparent" RowBackground="Transparent" BorderThickness="0"
                  Foreground="#E6E6E6" SelectionMode="Single" SelectionUnit="FullRow" CanUserAddRows="False"
                  CanUserResizeRows="False" CanUserSortColumns="False" RowHeaderWidth="0"
                  VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
          <DataGrid.GroupStyle>
            <GroupStyle>
              <GroupStyle.HeaderTemplate>
                <DataTemplate>
                  <TextBlock Text="{Binding Name}" FontWeight="SemiBold" FontSize="13" Foreground="#8AB4F8" Margin="10,12,0,4"/>
                </DataTemplate>
              </GroupStyle.HeaderTemplate>
            </GroupStyle>
          </DataGrid.GroupStyle>
          <DataGrid.Columns>
            <DataGridTemplateColumn Header="On" Width="46">
              <DataGridTemplateColumn.CellTemplate>
                <DataTemplate>
                  <CheckBox IsChecked="{Binding Desired, Mode=TwoWay, UpdateSourceTrigger=PropertyChanged}"
                            HorizontalAlignment="Center" VerticalAlignment="Center" Focusable="False"/>
                </DataTemplate>
              </DataGridTemplateColumn.CellTemplate>
            </DataGridTemplateColumn>
            <DataGridTextColumn Header="Tweak" Binding="{Binding Name}" Width="*">
              <DataGridTextColumn.ElementStyle>
                <Style TargetType="TextBlock">
                  <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
                </Style>
              </DataGridTextColumn.ElementStyle>
            </DataGridTextColumn>
            <DataGridTemplateColumn Header="Tier" Width="112">
              <DataGridTemplateColumn.CellTemplate>
                <DataTemplate>
                  <Border CornerRadius="3" Padding="7,1" HorizontalAlignment="Left">
                    <Border.Style>
                      <Style TargetType="Border">
                        <Setter Property="Background" Value="#3A3F4B"/>
                        <Style.Triggers>
                          <DataTrigger Binding="{Binding Tier}" Value="Recommended"><Setter Property="Background" Value="#1E6B42"/></DataTrigger>
                          <DataTrigger Binding="{Binding Tier}" Value="Situational"><Setter Property="Background" Value="#22508F"/></DataTrigger>
                          <DataTrigger Binding="{Binding Tier}" Value="Unproven"><Setter Property="Background" Value="#4A4F5A"/></DataTrigger>
                          <DataTrigger Binding="{Binding Tier}" Value="Security"><Setter Property="Background" Value="#8A5A12"/></DataTrigger>
                          <DataTrigger Binding="{Binding Tier}" Value="Risky"><Setter Property="Background" Value="#8E2A2A"/></DataTrigger>
                        </Style.Triggers>
                      </Style>
                    </Border.Style>
                    <TextBlock Text="{Binding Tier}" Foreground="#FFFFFF" FontSize="11.5"/>
                  </Border>
                </DataTemplate>
              </DataGridTemplateColumn.CellTemplate>
            </DataGridTemplateColumn>
            <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="96">
              <DataGridTextColumn.ElementStyle>
                <Style TargetType="TextBlock">
                  <Style.Triggers>
                    <DataTrigger Binding="{Binding Status}" Value="Applied"><Setter Property="Foreground" Value="#7BD88F"/></DataTrigger>
                    <DataTrigger Binding="{Binding Status}" Value="Partial"><Setter Property="Foreground" Value="#FFCC66"/></DataTrigger>
                    <DataTrigger Binding="{Binding Status}" Value="Unavailable"><Setter Property="Foreground" Value="#6B7078"/></DataTrigger>
                  </Style.Triggers>
                </Style>
              </DataGridTextColumn.ElementStyle>
            </DataGridTextColumn>
            <DataGridTextColumn Header="Needs" Binding="{Binding RebootText}" Width="74">
              <DataGridTextColumn.ElementStyle>
                <Style TargetType="TextBlock"><Setter Property="Foreground" Value="#9AA0A6"/></Style>
              </DataGridTextColumn.ElementStyle>
            </DataGridTextColumn>
            <DataGridTextColumn Header="" Binding="{Binding PendingMark}" Width="88">
              <DataGridTextColumn.ElementStyle>
                <Style TargetType="TextBlock">
                  <Setter Property="Foreground" Value="#6EA8FF"/>
                  <Setter Property="FontStyle" Value="Italic"/>
                </Style>
              </DataGridTextColumn.ElementStyle>
            </DataGridTextColumn>
          </DataGrid.Columns>
        </DataGrid>
      </Border>

      <Border Grid.Column="1" Margin="12,0,0,0" Background="{StaticResource PanelBrush}" BorderBrush="{StaticResource LineBrush}"
              BorderThickness="1" CornerRadius="6" Padding="18,14">
        <ScrollViewer VerticalScrollBarVisibility="Auto">
          <StackPanel>
            <TextBlock x:Name="DName" FontSize="17" FontWeight="SemiBold" TextWrapping="Wrap" Text="Select a tweak"/>
            <TextBlock x:Name="DMeta" Foreground="#9AA0A6" Margin="0,4,0,12" TextWrapping="Wrap"
                       Text="Tick boxes to queue changes, then press Apply. Every original value is saved before anything changes."/>
            <TextBlock x:Name="DSummary" TextWrapping="Wrap" Margin="0,0,0,8"/>
            <TextBlock x:Name="DDetail" TextWrapping="Wrap" Foreground="#C9CDD2" Margin="0,0,0,8"/>
            <TextBlock x:Name="DEvidenceLabel" Text="WHAT THE EVIDENCE SAYS" Style="{StaticResource SectionLabel}" Visibility="Collapsed"/>
            <TextBlock x:Name="DEvidence" TextWrapping="Wrap" Foreground="#C9CDD2" Margin="0,0,0,10"/>
            <Border x:Name="DWarnBox" Background="#3A2A14" CornerRadius="4" Padding="10,8" Margin="0,0,0,10" Visibility="Collapsed">
              <TextBlock x:Name="DWarning" TextWrapping="Wrap" Foreground="#FFCC80"/>
            </Border>
            <TextBlock x:Name="DOpsLabel" Text="WHAT IT CHANGES" Style="{StaticResource SectionLabel}" Visibility="Collapsed"/>
            <TextBlock x:Name="DOps" TextWrapping="Wrap" FontFamily="Consolas" FontSize="11.5" Foreground="#B8BCC2"/>
          </StackPanel>
        </ScrollViewer>
      </Border>
    </Grid>

    <Expander Grid.Row="3" Header="Log" Margin="0,10,0,0" Foreground="#9AA0A6">
      <TextBox x:Name="LogBox" Height="140" Margin="0,6,0,0" IsReadOnly="True" FontFamily="Consolas" FontSize="11.5"
               VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto" TextWrapping="NoWrap"/>
    </Expander>

    <DockPanel Grid.Row="4" Margin="0,12,0,0" LastChildFill="False">
      <Button x:Name="BtnRestorePoint" Content="Create restore point" DockPanel.Dock="Left" Margin="0,0,4,0"/>
      <Button x:Name="BtnExplorer" Content="Restart Explorer" DockPanel.Dock="Left"/>
      <Button x:Name="BtnFolder" Content="Open snapshot folder" DockPanel.Dock="Left"/>
      <Button x:Name="BtnApply" Content="Apply" Style="{StaticResource PrimaryButton}" DockPanel.Dock="Right" Margin="4,0,0,0" IsEnabled="False"/>
      <CheckBox x:Name="ChkRestorePoint" Content="Restore point before first apply" IsChecked="True" DockPanel.Dock="Right"
                VerticalAlignment="Center" Margin="0,0,14,0" Foreground="#9AA0A6"
                ToolTip="Creates a Windows restore point the first time you apply changes in this session."/>
      <Button x:Name="BtnRestoreAll" Content="Restore everything" Style="{StaticResource DangerButton}" DockPanel.Dock="Right" Margin="4,0,14,0"/>
      <TextBlock x:Name="StatusText" DockPanel.Dock="Right" VerticalAlignment="Center" Foreground="#9AA0A6" Margin="0,0,14,0" TextTrimming="CharacterEllipsis"/>
    </DockPanel>
  </Grid>

  <!-- In-window dialog: replaces Windows message boxes, so there are no system sounds. -->
  <Grid x:Name="Overlay" Background="#B3000000" Visibility="Collapsed">
    <Border Background="#1E2128" BorderBrush="#3A404B" BorderThickness="1" CornerRadius="8" Padding="24,20"
            MinWidth="400" MaxWidth="600" HorizontalAlignment="Center" VerticalAlignment="Center">
      <StackPanel>
        <TextBlock x:Name="DlgTitle" FontSize="16" FontWeight="SemiBold" Margin="0,0,0,10" TextWrapping="Wrap"/>
        <ScrollViewer MaxHeight="420" VerticalScrollBarVisibility="Auto">
          <TextBlock x:Name="DlgText" TextWrapping="Wrap" Foreground="#C9CDD2" LineHeight="19"/>
        </ScrollViewer>
        <StackPanel x:Name="DlgButtons" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,20,0,0"/>
      </StackPanel>
    </Border>
  </Grid>
  </Grid>
</Window>
'@

[xml]$xaml = $XamlText
$script:Window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
$names = 'InfoText', 'SearchBox', 'TierAll', 'TierRecommended', 'TierSituational', 'TierUnproven', 'TierSecurity', 'TierRisky',
         'PendingOnly', 'BtnRecommended', 'BtnDiscard', 'TweakGrid', 'DName', 'DMeta', 'DSummary', 'DDetail', 'DEvidenceLabel',
         'DEvidence', 'DWarnBox', 'DWarning', 'DOpsLabel', 'DOps', 'LogBox', 'BtnRestorePoint', 'BtnExplorer', 'BtnFolder',
         'BtnApply', 'BtnRestoreAll', 'StatusText', 'MainGrid', 'Overlay', 'DlgTitle', 'DlgText', 'DlgButtons', 'ChkRestorePoint'
foreach ($n in $names) { Set-Variable -Name $n -Value $script:Window.FindName($n) -Scope Script }
$TierButtons = @($TierAll, $TierRecommended, $TierSituational, $TierUnproven, $TierSecurity, $TierRisky)

# ---- rows ----
$Rows      = New-Object 'System.Collections.ObjectModel.ObservableCollection[object]'
$RowById   = @{}
$TweakById = @{}
foreach ($t in $Catalogue) {
    $r = New-Object W11T.TweakRow
    $r.Id = $t.Id; $r.Name = $t.Name; $r.Category = $t.Category; $r.Tier = $t.Tier
    $r.Summary = $t.Summary; $r.Group = $t.Group
    $r.RebootText = if ($t.Reboot -eq 'None') { '' } else { $t.Reboot }
    $r.Status = '...'
    $r.add_PropertyChanged({
        param($s, $e)
        if ($script:Suppress -or $e.PropertyName -ne 'Desired') { return }
        if ($s.Group) {
            $script:Suppress = $true
            if ($s.Desired) {
                # Only one member of a group (power plan, HPET) can be wanted at a time.
                foreach ($o in $Rows) { if ($o.Group -eq $s.Group -and $o.Id -ne $s.Id) { $o.Desired = $false } }
            } elseif (-not @($Rows | Where-Object { $_.Group -eq $s.Group -and $_.Desired }).Count) {
                # Nothing in the group is wanted any more: put the others back how they are now.
                foreach ($o in $Rows) { if ($o.Group -eq $s.Group -and $o.Id -ne $s.Id) { $o.Desired = $o.Applied } }
            }
            $script:Suppress = $false
        }
        Update-Pending
    })
    [void]$Rows.Add($r)
    $RowById[$t.Id] = $r
    $TweakById[$t.Id] = $t
}

$script:View = [System.Windows.Data.CollectionViewSource]::GetDefaultView($Rows)
$script:View.GroupDescriptions.Add((New-Object System.Windows.Data.PropertyGroupDescription('Category')))
$script:View.Filter = {
    param($r)
    $q = $SearchBox.Text.Trim()
    if ($q) {
        $hit = ($r.Name.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
               ($r.Summary.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0) -or
               ($r.Category.IndexOf($q, [StringComparison]::OrdinalIgnoreCase) -ge 0)
        if (-not $hit) { return $false }
    }
    $tier = 'All'
    foreach ($b in $TierButtons) { if ($b.IsChecked) { $tier = [string]$b.Content } }
    if ($tier -ne 'All' -and $r.Tier -ne $tier) { return $false }
    if ($PendingOnly.IsChecked -and -not $r.Pending) { return $false }
    return $true
}
$TweakGrid.ItemsSource = $script:View

# ---- UI helpers ----
function Safe([scriptblock]$Body) {
    try { & $Body } catch { Log ('UI error: ' + $_.Exception.Message) 'ERR' }
}

function Set-Busy([string]$Msg) {
    $script:Busy = $true
    $MainGrid.IsEnabled = $false
    $script:Window.Cursor = [System.Windows.Input.Cursors]::Wait
    $StatusText.Text = $Msg
    Pump
}
function Clear-Busy {
    $script:Busy = $false
    $MainGrid.IsEnabled = $true
    $script:Window.Cursor = $null
    Update-Pending
}

function Update-Pending {
    $n = @($Rows | Where-Object { $_.Pending }).Count
    if ($n -eq 0) {
        $BtnApply.Content = 'Apply'; $BtnApply.IsEnabled = $false
        $StatusText.Text = if ($script:LastResult) { $script:LastResult } else { 'No pending changes' }
    }
    else          { $BtnApply.Content = ('Apply {0} change{1}' -f $n, $(if ($n -eq 1) { '' } else { 's' })); $BtnApply.IsEnabled = $true; $StatusText.Text = '' }
}

function Get-BitLockerOn {
    try {
        $v = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        return ([string]$v.ProtectionStatus -eq 'On')
    } catch { return $false }
}

function Update-Info {
    $parts = @()
    try {
        $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $parts += ('Windows 11 {0} (build {1}.{2})' -f $cv.DisplayVersion, $cv.CurrentBuild, $cv.UBR)
    } catch {}
    $planText = 'Plan: ' + (Get-ActiveSchemeName)
    if ((Get-ActiveScheme) -eq $GUID_BAL) {
        $ovl = Get-Overlay
        $modeNames = @{ $OVL_NONE = 'Balanced'; $OVL_BEST = 'Best performance'; '961cc777-2547-4f9d-8174-7d86181b8a7a' = 'Best power efficiency' }
        $mode = $modeNames[$ovl]; if (-not $mode) { $mode = 'custom' }
        $planText += ' (mode: ' + $mode + ')'
    }
    $parts += $planText
    try {
        $dg = Get-CimInstance -ClassName Win32_DeviceGuard -Namespace 'root\Microsoft\Windows\DeviceGuard' -ErrorAction Stop
        $vbsNames = @('off', 'enabled, not running', 'running')
        $parts += ('VBS: ' + $vbsNames[[int]$dg.VirtualizationBasedSecurityStatus])
        $parts += ('Memory Integrity: ' + $(if (@($dg.SecurityServicesRunning) -contains 2) { 'running' } else { 'off' }))
    } catch { $parts += 'VBS: unknown' }
    $h = RegGet 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    $live = Get-HagsLive
    $hagsText = switch ($live) { -1 { 'unknown' } 0 { 'not supported' } 1 { 'off' } default { 'on' } }
    $wantOn = if ($null -eq $h) { $null } else { ($h -eq 2) }
    if ($live -ge 1 -and $null -ne $wantOn -and $wantOn -ne (($live -band 2) -ne 0)) { $hagsText += ' (changes after restart)' }
    $parts += ('HAGS: ' + $hagsText)
    $parts += ('BitLocker: ' + $(if ($script:BitLockerOn) { 'on' } else { 'off or unknown' }))
    if ($script:Snap.Count -gt 0) { $parts += ('Snapshot: {0} originals saved since {1}' -f $script:Snap.Count, $script:SnapCreated) }
    else { $parts += 'Snapshot: none yet (created on first apply)' }
    $InfoText.Text = ($parts -join '   |   ')
}

function Refresh-All([switch]$ResetDesired) {
    Set-Busy 'Reading current settings...'
    try {
        $script:Cache = @{}
        $script:Suppress = $true
        foreach ($t in $Catalogue) {
            $r = $RowById[$t.Id]
            $state = Get-TweakState $t
            $wasPending = $r.Pending
            $r.Status = $state
            $applied = ($state -eq 'Applied')
            $r.Applied = $applied
            if ($ResetDesired -or -not $wasPending) { $r.Desired = $applied }
            Pump
        }
        $script:Suppress = $false
        $script:BitLockerOn = Get-BitLockerOn
        Update-Info
        $script:View.Refresh()
    } finally {
        $script:Suppress = $false
        Clear-Busy
    }
    Show-Details
}

function Show-Details {
    $r = $TweakGrid.SelectedItem
    if ($null -eq $r) { return }
    $t = $TweakById[$r.Id]
    $DName.Text = $t.Name
    $meta = @($t.Tier, $t.Category, ('Status: ' + $r.Status))
    if ($t.Reboot -ne 'None') { $meta += ('Needs: ' + $t.Reboot) }
    if ($t.OneWay) { $meta += 'One-way' }
    $DMeta.Text = ($meta -join '  |  ')
    $DSummary.Text = $t.Summary
    $DDetail.Text = $t.Detail
    $DDetail.Visibility = if ($t.Detail) { 'Visible' } else { 'Collapsed' }
    $DEvidence.Text = $t.Evidence
    $DEvidenceLabel.Visibility = if ($t.Evidence) { 'Visible' } else { 'Collapsed' }
    $DWarning.Text = $t.Warning
    $DWarnBox.Visibility = if ($t.Warning) { 'Visible' } else { 'Collapsed' }
    $lines = @()
    foreach ($op in $t.Ops) {
        try { $cur = Invoke-OpGet $op } catch { $cur = $NA }
        $lines += ('- ' + $op.Desc)
        $lines += ('    now: ' + (Format-Val $cur))
        $key = Get-OpKey $op
        if ($script:Snap.ContainsKey($key)) { $lines += ('    original: ' + (Format-Val $script:Snap[$key])) }
    }
    $DOps.Text = ($lines -join "`n")
    $DOpsLabel.Visibility = 'Visible'
}

function Show-Msg([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information') {
    # Silent, themed dialog drawn inside the window. Returns 'OK', 'Cancel', 'Yes' or 'No'.
    $titles = @{ Warning = 'Heads up'; Question = 'Confirm'; Information = 'W11 Tweaker'; Error = 'Something went wrong' }
    $sets = @{
        OK          = @('OK')
        OKCancel    = @('Cancel', 'OK')
        YesNo       = @('No', 'Yes')
        YesNoCancel = @('Cancel', 'No', 'Yes')
    }
    $choices = $sets[$Buttons]; if (-not $choices) { $choices = @('OK') }
    $DlgTitle.Text = $titles[$Icon]; if (-not $DlgTitle.Text) { $DlgTitle.Text = 'W11 Tweaker' }
    $DlgText.Text = $Text
    $DlgButtons.Children.Clear()
    $script:DlgPrimary = $choices[-1]
    $script:DlgEscape  = if ($choices -contains 'Cancel') { 'Cancel' } elseif ($choices -contains 'No') { 'No' } else { 'OK' }
    foreach ($c in $choices) {
        $b = New-Object System.Windows.Controls.Button
        $b.Content = $c
        $b.Tag = $c
        $b.MinWidth = 84
        $b.Margin = New-Object System.Windows.Thickness(8, 0, 0, 0)
        if ($c -eq $script:DlgPrimary) { $b.Style = $script:Window.FindResource('PrimaryButton') }
        $b.add_Click({ param($s, $e) Close-Dialog ([string]$s.Tag) })
        [void]$DlgButtons.Children.Add($b)
    }
    $script:DlgResult = $script:DlgEscape
    $wasEnabled = $MainGrid.IsEnabled
    $MainGrid.IsEnabled = $false
    $Overlay.Visibility = 'Visible'
    $DlgButtons.Children[$DlgButtons.Children.Count - 1].Focus() | Out-Null
    # Run a nested message loop until a button is pressed, so callers get the answer back directly.
    $script:DlgFrame = New-Object System.Windows.Threading.DispatcherFrame
    [System.Windows.Threading.Dispatcher]::PushFrame($script:DlgFrame)
    $Overlay.Visibility = 'Collapsed'
    $MainGrid.IsEnabled = $wasEnabled
    return $script:DlgResult
}
function Close-Dialog([string]$Result) {
    $script:DlgResult = $Result
    if ($script:DlgFrame) { $script:DlgFrame.Continue = $false }
}

function New-RestorePoint {
    Set-Busy 'Creating restore point (can take a minute)...'
    $srKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $prev = RegGet $srKey 'SystemRestorePointCreationFrequency'
    $ok = $false
    try {
        Enable-ComputerRestore -Drive ($env:SystemDrive + '\') -ErrorAction Stop
        RegSet $srKey 'SystemRestorePointCreationFrequency' 'DWord' 0
        Checkpoint-Computer -Description ('W11 Tweaker ' + (Get-Date -Format 'yyyy-MM-dd HH:mm')) -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        $script:RestorePointDone = $true
        $ok = $true
        Log 'System restore point created.'
    } catch {
        Log ('Restore point failed: ' + $_.Exception.Message) 'ERR'
    } finally {
        RegSet $srKey 'SystemRestorePointCreationFrequency' 'DWord' $prev
        Clear-Busy
    }
    return $ok
}

function Restart-Explorer {
    # Windows restarts Explorer itself (non-elevated). Starting it from this elevated
    # process could give you an elevated shell, so the tool never does that.
    Log 'Restarting Explorer.'
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 3000
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Log 'Explorer did not come back by itself. Press Ctrl+Shift+Esc, then File > Run new task > explorer.' 'WARN'
        Show-Msg "Explorer didn't restart by itself.`n`nPress Ctrl+Shift+Esc to open Task Manager, choose Run new task, type explorer and press Enter." 'OK' 'Warning' | Out-Null
    }
}

function Invoke-ApplyChanges {
    if ($script:Busy) { return }
    $pending   = @($Rows | Where-Object { $_.Pending })
    if ($pending.Count -eq 0) { return }
    $toApply   = @($pending | Where-Object { $_.Desired } | ForEach-Object { $TweakById[$_.Id] } |
                   Sort-Object @{ Expression = 'Order' }, @{ Expression = 'Index' })
    $toRevert  = @($pending | Where-Object { -not $_.Desired } | ForEach-Object { $TweakById[$_.Id] } |
                   Sort-Object @{ Expression = 'Order'; Descending = $true }, @{ Expression = 'Index'; Descending = $true })

    # Routine changes apply straight away; the "will apply / will revert" marks already show what's queued.
    # Only ask when something is risky, one-way, or the snapshot had a problem.
    $risky  = @($toApply | Where-Object { $_.Tier -eq 'Security' -or $_.Tier -eq 'Risky' })
    $oneway = @($toApply | Where-Object { $_.OneWay })
    $warn = @()
    if ($risky.Count)  { $warn += "These reduce security or can break things:`n  - " + (($risky | ForEach-Object { $_.Name }) -join "`n  - ") }
    if ($oneway.Count) { $warn += "These can't be undone by Restore (reinstall from the Store):`n  - " + (($oneway | ForEach-Object { $_.Name }) -join "`n  - ") }
    if ($script:SnapBroken) { $warn += "The previous snapshot couldn't be read and was set aside (see the log). Originals recorded from now on are today's values, which may already include earlier tweaks." }
    if ($warn.Count) {
        if ((Show-Msg (($warn -join "`n`n") + "`n`nGo ahead?") 'OKCancel' 'Warning') -ne 'OK') { return }
    }

    if ($ChkRestorePoint.IsChecked -and -not $script:RestorePointDone) {
        if (-not (New-RestorePoint)) {
            if ((Show-Msg "The restore point couldn't be created (see the log). Apply the changes anyway?" 'YesNo' 'Warning') -ne 'Yes') { return }
        }
    }

    # Boot-time security changes (VBS, Memory Integrity, hypervisor, mitigations) are measured by BitLocker.
    $bootSensitive = @(($toApply + $toRevert) | Where-Object { $_.Reboot -eq 'Reboot' -and ($_.Category -eq 'Security trade-offs' -or $_.Category -eq 'CPU & timers') })
    if ($bootSensitive.Count -and (Get-BitLockerOn)) {
        $ans = Show-Msg "BitLocker is on, and some of these change boot-time security settings.`n`nSuspend BitLocker for the next restart, so you aren't asked for the recovery key? It turns itself back on after one reboot.`n`nEither way, make sure your recovery key is backed up (aka.ms/myrecoverykey)." 'YesNoCancel' 'Warning'
        if ($ans -eq 'Cancel') { return }
        if ($ans -eq 'Yes') {
            try { Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 1 -ErrorAction Stop | Out-Null; Log 'BitLocker suspended for one restart.' }
            catch {
                Log ('Could not suspend BitLocker: ' + $_.Exception.Message) 'ERR'
                if ((Show-Msg "BitLocker couldn't be suspended (see the log). Continue anyway?" 'YesNo' 'Warning') -ne 'Yes') { return }
            }
        }
    }

    Set-Busy 'Applying...'
    $script:Failures = 0
    $script:LeftAlone = 0
    try {
        $applyGroups = @($toApply | Where-Object { $_.Group } | ForEach-Object { $_.Group })
        foreach ($t in $toRevert) {
            if ($t.Group -and ($applyGroups -contains $t.Group)) { Log ("Replaced: {0}" -f $t.Name); continue }
            Revert-Tweak $t; Pump
        }
        foreach ($t in $toApply) { Apply-Tweak $t; Pump }
        Save-Snapshot
    } finally {
        Clear-Busy
    }

    $changed = @($toApply) + @($toRevert)
    $needs = @($changed | Where-Object { $_.Reboot -ne 'None' } | ForEach-Object { $_.Reboot } | Sort-Object -Unique)
    Refresh-All -ResetDesired

    # Report quietly in the status line; only failures get a dialog.
    $parts = @(('Applied {0}, reverted {1}' -f $toApply.Count, $toRevert.Count))
    if ($script:LeftAlone)            { $parts += ('{0} already like that, left alone' -f $script:LeftAlone) }
    if ($needs -contains 'Reboot')    { $parts += 'restart needed' }
    if ($needs -contains 'Sign out')  { $parts += 'sign out needed' }
    if ($needs -contains 'Explorer')  { $parts += 'press Restart Explorer to see some changes' }
    $script:LastResult = (Get-Date -Format 'HH:mm') + '  ' + ($parts -join ' | ')
    Update-Pending
    if ($script:Failures) {
        Show-Msg ("{0} change(s) failed or were blocked. The log has the details." -f $script:Failures) 'OK' 'Warning' | Out-Null
    }
}

function Invoke-RestoreAll {
    if ($script:Busy) { return }
    if ($script:Snap.Count -eq 0) { Show-Msg 'There is no snapshot yet, so there is nothing to restore.' | Out-Null; return }
    $ans = Show-Msg ("Put every setting this tool changed back to its saved original ({0} values)?`n`nRemoved apps are not reinstalled." -f $script:Snap.Count) 'OKCancel' 'Warning'
    if ($ans -ne 'OK') { return }
    Set-Busy 'Restoring originals...'
    Log 'Restore everything from snapshot.'
    $keep = @{}
    $done = @{}
    try {
        # 1. Per-plan power settings, each written back into the plan it came from.
        foreach ($k in @($script:Snap.Keys)) {
            if ($k -notmatch '^pwr:([0-9a-f-]{36}):([0-9a-f-]{36}):([0-9a-f-]{36})$') { continue }
            $scheme = $matches[1]; $sub = $matches[2]; $setting = $matches[3]
            $done[$k] = $true
            try {
                if (-not (Test-Scheme $scheme)) { Log ("    $k skipped: that power plan no longer exists.") 'WARN'; continue }
                $cur = PwrGet $sub $setting $scheme
                if ((Norm $cur) -eq (Norm $script:Snap[$k])) { continue }
                PwrSet $sub $setting $script:Snap[$k] $scheme
                Log ("    " + $k + " -> " + (Format-Val $script:Snap[$k]))
            } catch { $keep[$k] = $script:Snap[$k]; Log ("    FAILED: " + $k + " - " + $_.Exception.Message) 'ERR' }
        }
        # 2. Everything else, in reverse dependency order (SysMain before memory compression, plans last).
        $ordered = @($Catalogue | Sort-Object @{ Expression = 'Order'; Descending = $true }, @{ Expression = 'Index'; Descending = $true })
        foreach ($t in $ordered) {
            foreach ($op in $t.Ops) {
                if ($op.Kind -eq 'pwr') { continue }
                $k = $op.Key
                if ($done.ContainsKey($k) -or -not $script:Snap.ContainsKey($k)) { continue }
                $done[$k] = $true
                $sv = $script:Snap[$k]
                if ($t.OneWay) { continue }
                try {
                    $cur = Invoke-OpGet $op
                    if (IsNA $cur) { $keep[$k] = $sv; Log ("    $k could not be read right now; kept for next time.") 'WARN'; continue }
                    if ((Norm $cur) -eq (Norm $sv)) { continue }
                    Invoke-OpSet $op $sv
                    Log ("    " + $k + " -> " + (Format-Val $sv))
                } catch { $keep[$k] = $sv; Log ("    FAILED: " + $k + " - " + $_.Exception.Message) 'ERR' }
            }
            Pump
        }
        foreach ($t in $Catalogue) { if ($t.Live) { Invoke-Live $t } }
        if ($keep.Count -eq 0) {
            $archive = Join-Path $AppDir ('snapshot-restored-{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            try { Move-Item -LiteralPath $SnapFile -Destination $archive -Force; Log "Snapshot archived to $archive" } catch {}
            $script:Snap = @{}
            $script:SnapCreated = $null
        } else {
            # Keep only what still needs restoring, so nothing is lost if a step failed.
            $script:Snap = $keep
            Save-Snapshot
        }
    } finally {
        Clear-Busy
    }
    Refresh-All -ResetDesired
    if ($keep.Count) {
        Show-Msg ("{0} value(s) couldn't be restored and are still saved in the snapshot. See the log, then try Restore everything again (a reboot often helps)." -f $keep.Count) 'OK' 'Warning' | Out-Null
    } else {
        $script:LastResult = (Get-Date -Format 'HH:mm') + '  Originals restored | restart Windows to finish'
        Update-Pending
    }
}

# ---- events ----
$SearchBox.add_TextChanged({ Safe { $script:View.Refresh() } })
foreach ($b in $TierButtons) { $b.add_Checked({ Safe { $script:View.Refresh() } }) }
$PendingOnly.add_Click({ Safe { $script:View.Refresh() } })
$TweakGrid.add_SelectionChanged({ Safe { Show-Details } })

$BtnRecommended.add_Click({ Safe {
    foreach ($r in $Rows) {
        if ($r.Tier -ne 'Recommended' -or $r.Status -eq 'Unavailable') { continue }
        # Don't override a power plan or timer choice you've already applied.
        if ($r.Group -and @($Rows | Where-Object { $_.Group -eq $r.Group -and $_.Applied -and $_.Id -ne $r.Id }).Count) { continue }
        $r.Desired = $true
    }
    $script:View.Refresh()
} })
$BtnDiscard.add_Click({ Safe {
    $script:Suppress = $true
    foreach ($r in $Rows) { $r.Desired = $r.Applied }
    $script:Suppress = $false
    Update-Pending
    $script:View.Refresh()
} })
$BtnApply.add_Click({ Safe { Invoke-ApplyChanges } })
$BtnRestoreAll.add_Click({ Safe { Invoke-RestoreAll } })
$BtnRestorePoint.add_Click({ Safe {
    if (New-RestorePoint) { $script:LastResult = (Get-Date -Format 'HH:mm') + '  Restore point created'; Update-Pending }
    else { Show-Msg "Couldn't create a restore point. See the log for details." 'OK' 'Warning' | Out-Null }
} })
$BtnExplorer.add_Click({ Safe { Restart-Explorer } })
$BtnFolder.add_Click({ Safe { Start-Process explorer.exe $AppDir } })

$script:Window.add_PreviewKeyDown({
    param($s, $e)
    if ($Overlay.Visibility -ne 'Visible') { return }
    if ($e.Key -eq 'Escape') { Close-Dialog $script:DlgEscape; $e.Handled = $true }
    elseif ($e.Key -eq 'Enter') { Close-Dialog $script:DlgPrimary; $e.Handled = $true }
})

$script:Window.add_Closing({
    param($s, $e)
    if ($script:Busy -or $Overlay.Visibility -eq 'Visible') { $e.Cancel = $true; return }
    $n = @($Rows | Where-Object { $_.Pending }).Count
    if ($n -gt 0) {
        if ((Show-Msg "You have $n unapplied change(s). Close anyway?" 'YesNo' 'Question') -ne 'Yes') { $e.Cancel = $true }
    }
})

$script:Window.add_ContentRendered({ Safe {
    $script:UiRunning = $true
    Log ("W11 Tweaker started as {0} ({1} tweaks)." -f $env:USERNAME, $Catalogue.Count)
    Log 'Note: per-user (HKCU) tweaks apply to the account running this elevated window.'
    foreach ($q in $script:Quarantined) { Log ("Set aside an item in the data folder that wasn't owned by Administrators: " + $q) 'WARN' }
    Load-Snapshot
    Refresh-All -ResetDesired
    if ($Rows.Count -gt 0) { $TweakGrid.SelectedIndex = 0 }
    if ($script:Quarantined.Count -or $script:SnapBroken) {
        Show-Msg "Something in the tool's data folder looked wrong and was set aside before it could be used. Details are in the log." 'OK' 'Warning' | Out-Null
    }
} })

[void]$script:Window.ShowDialog()
