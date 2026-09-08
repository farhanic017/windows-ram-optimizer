try { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue } catch {}
try { Enable-MMAgent -PageCombining -ErrorAction SilentlyContinue } catch {}
try {
  Add-Type "using System; using System.Runtime.InteropServices; public class Mclean { [DllImport(\"psapi.dll\")] public static extern bool EmptyWorkingSet(IntPtr h); }"
  Get-Process | ForEach-Object { try { [Mclean]::EmptyWorkingSet($_.Handle) | Out-Null } catch {} }
} catch {}
try {
  Add-Type @"
using System; using System.Runtime.InteropServices;
public class Sclean { [DllImport("ntdll.dll")] public static extern uint NtSetSystemInformation(int c, IntPtr i, int l); public static void DoClean(){ for(int k=0;k<=2;k++){ IntPtr p=Marshal.AllocHGlobal(4); Marshal.WriteInt32(p,k); NtSetSystemInformation(80,p,4); Marshal.FreeHGlobal(p); } } }
"@
  [Sclean]::DoClean()
} catch {}
[GC]::Collect()
