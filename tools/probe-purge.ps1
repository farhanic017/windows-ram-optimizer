# probe-purge.ps1 — diagnose why NtSetSystemInformation(80) returns ACCESS_DENIED
param([string]$OutFile)

$ErrorActionPreference = 'SilentlyContinue'

$body = {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    "User        : $($id.Name)"
    "IsAdmin     : $($p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
    "IsSystem    : $($id.IsSystem)"

    "--- token privileges (whoami /priv) ---"
    & whoami /priv | ForEach-Object { "  $_" }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class Probe
{
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
    [StructLayout(LayoutKind.Sequential)] public struct TOKEN_PRIVILEGES { public int PrivilegeCount; public LUID Luid; public uint Attributes; }
    [DllImport("ntdll.dll")] public static extern uint NtSetSystemInformation(int c, IntPtr i, int l);
    [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr t);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode)] public static extern bool LookupPrivilegeValue(string s, string n, out LUID l);
    [DllImport("advapi32.dll", SetLastError=true)] public static extern bool AdjustTokenPrivileges(IntPtr t, bool dis, ref TOKEN_PRIVILEGES n, int nl, IntPtr p, IntPtr rl);

    public static uint RawPurge(int k)
    {
        IntPtr p = Marshal.AllocHGlobal(4);
        uint s;
        try { Marshal.WriteInt32(p, k); s = NtSetSystemInformation(80, p, 4); }
        finally { Marshal.FreeHGlobal(p); }
        return s;
    }

    public static string Enable(string name)
    {
        IntPtr tok;
        if (!OpenProcessToken(GetCurrentProcess(), 0x28, out tok)) return "OpenProcessToken failed err=" + Marshal.GetLastWin32Error();
        LUID luid;
        if (!LookupPrivilegeValue(null, name, out luid)) return "Lookup failed err=" + Marshal.GetLastWin32Error();
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.PrivilegeCount = 1;
        tp.Luid = luid;
        tp.Attributes = 0x2; // SE_PRIVILEGE_ENABLED
        if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return "Adjust failed err=" + Marshal.GetLastWin32Error();
        int err = Marshal.GetLastWin32Error();
        if (err == 1300) return "NOT-ASSIGNED (privilege absent)";
        if (err == 0) return "ENABLED";
        return "err=" + err;
    }
}
'@

    "--- raw purge (k=0,1,2) as-is ---"
    foreach ($k in 0, 1, 2) {
        $st = [Probe]::RawPurge($k)
        "  k=$k status=0x{0:X8} {1}" -f $st, $(if ($st -eq 0) { 'OK' } else { 'FAIL' })
    }

    "--- enable privilege, then retry k=0 ---"
    foreach ($priv in 'SeProfileSingleProcessPrivilege', 'SeIncreaseQuotaPrivilege', 'SeIncreaseWorkingSetPrivilege',
                      'SeCreatePagefilePrivilege', 'SeManageVolumePrivilege', 'SeSystemProfilePrivilege',
                      'SeIncreaseBasePriorityPrivilege', 'SeDebugPrivilege') {
        $r = [Probe]::Enable($priv)
        $st = [Probe]::RawPurge(0)
        "  {0,-38} -> {1,-32} purge=0x{2:X8}" -f $priv, $r, $st
        if ($st -eq 0) { "  ^^^ PURGE WORKS AFTER THIS PRIVILEGE"; break }
    }
}

$res = (& $body | Out-String)
if ($OutFile) { Set-Content -LiteralPath $OutFile -Value $res -Encoding UTF8 }
$res
