# Legacy v1 watchdog — fallback for the Node / Python editions.
#
# Both editions now deploy ps/EmptyStandby.ps1 (the graphics-safe v2 watchdog) whenever it is
# present; this file is only used when ps/ is missing from the package.
#
# NOTE: PowerShell does NOT treat a backslash-escaped quote as an escape inside a double-quoted
# string (only the backtick works). The old version of this file escaped the quotes in the
# [DllImport("psapi.dll")] line with backslashes, so Add-Type threw and the entire trim block
# silently no-opped. Wrapping the Add-Type string in single quotes fixes it.
try { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue } catch {}
try { Enable-MMAgent -PageCombining -ErrorAction SilentlyContinue } catch {}

if (-not ('RamFixV1' -as [type])) {
    Add-Type 'using System;
using System.Runtime.InteropServices;
public class RamFixV1 {
    [DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr h);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    public struct POINT { public int X; public int Y; }
    public static int LastX = int.MinValue, LastY = int.MinValue;
    public static void MarkCursor() { POINT p; if (GetCursorPos(out p)) { LastX = p.X; LastY = p.Y; } }
    public static bool Dragging() {
        if ((GetAsyncKeyState(0x01) & 0x8000) != 0) return true;   // left button down
        if ((GetAsyncKeyState(0x02) & 0x8000) != 0) return true;   // right button down
        if ((GetAsyncKeyState(0x04) & 0x8000) != 0) return true;   // middle button down
        POINT p; if (!GetCursorPos(out p)) return false;
        return p.X != LastX || p.Y != LastY;                        // cursor moved since last run
    }
}'
}

# Working-set trim: never touch shell / window-owning / critical-system processes, so dragging
# a window (or an iGPU sharing system RAM) never loses graphics.
$Critical = 'System', 'Registry', 'smss', 'csrss', 'wininit', 'winlogon', 'services', 'lsass',
            'svchost', 'dwm', 'explorer', 'sihost', 'ShellExperienceHost', 'SearchHost',
            'StartMenuExperienceHost', 'SearchUI', 'RuntimeBroker', 'fontdrvhost', 'MsMpEng',
            'MemoryCompression', 'WmiPrvSE', 'SearchIndexer', 'csrss'
$Idle = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Id -ne 0 -and $_.MainWindowHandle -eq 0 -and $Critical -notcontains $_.ProcessName } catch { $false }
})
foreach ($p in $Idle) { try { [RamFixV1]::EmptyWorkingSet($p.Handle) | Out-Null } catch {} }

# Standby purge: skip it while a mouse button is down or the cursor moved in the last ~1.3s
# (that is the purge that makes dragging stutter on shared-memory iGPUs).
if (-not [RamFixV1]::Dragging()) {
    try {
        Add-Type @'
using System; using System.Runtime.InteropServices;
public class RamFixV1Purge { [DllImport("ntdll.dll")] public static extern uint NtSetSystemInformation(int c, IntPtr i, int l); public static void DoClean(){ for(int k=0;k<=2;k++){ IntPtr p=Marshal.AllocHGlobal(4); Marshal.WriteInt32(p,k); NtSetSystemInformation(80,p,4); Marshal.FreeHGlobal(p); } } }
'@
        [RamFixV1Purge]::DoClean()
    } catch {}
}
[RamFixV1]::MarkCursor()
[GC]::Collect()
