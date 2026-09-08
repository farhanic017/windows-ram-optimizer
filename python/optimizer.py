#!/usr/bin/env python3
"""
win-ram-optimizer — Python edition
Same ReviOS 1.56GB profile: services + telemetry + compression + watchdog + CAM 50MB
Usage: python optimizer.py [--gui]  (run as admin)
"""
import subprocess, sys, os, json, ctypes, pathlib

PERM_DIR = r"C:\ProgramData\ReviOS"
PERM_SCRIPT = os.path.join(PERM_DIR, "EmptyStandby.ps1")
FIX_MMA = os.path.join(PERM_DIR, "FixMMAgent.ps1")

def is_admin():
    try: return ctypes.windll.shell32.IsUserAnAdmin() != 0
    except: return False

def ps(cmd):
    return subprocess.check_output(["powershell","-NoProfile","-ExecutionPolicy","Bypass","-Command",cmd], text=True, timeout=30).strip()

def run_all(aggressive=False):
    if not is_admin(): raise PermissionError("Run as Administrator")
    pathlib.Path(PERM_DIR).mkdir(parents=True, exist_ok=True)
    # 1. compression
    try: ps("Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue; Enable-MMAgent -PageCombining -ErrorAction SilentlyContinue")
    except: pass
    open(FIX_MMA,"w").write("try { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue } catch {}\ntry { Enable-MMAgent -PageCombining -ErrorAction SilentlyContinue } catch {}\n")
    ps(f'New-Item -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run" -Force | Out-Null; Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run" -Name "ReviOS_FixMMAgent" -Value \'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{FIX_MMA}"\' -Force')
    # 2. watchdog
    perm = r'''try { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue } catch {}
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
'''
    open(PERM_SCRIPT,"w").write(perm)
    open(r"C:\Windows\Temp\EmptyStandby.ps1","w").write(perm)
    ps(f'icacls "{PERM_SCRIPT}" /grant "NT AUTHORITY\\SYSTEM:(F)" | Out-Null')
    # task
    task_ps = f'''
$perm="{PERM_SCRIPT}";
$action=New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$perm`"";
$boot=New-ScheduledTaskTrigger -AtStartup;
$time=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2);
$principal=New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\\SYSTEM" -RunLevel Highest -LogonType ServiceAccount;
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew -StartWhenAvailable -Compatibility Win8;
Register-ScheduledTask -TaskName "ReviOS-EmptyStandby" -Action $action -Trigger $boot,$time -Principal $principal -Settings $settings -Force | Out-Null;
'''
    ps(task_ps)
    # 3. services
    for s in ["DSAService","DSAUpdateService","WSearch","CAMService","postgresql-x64-18"]:
        try: ps(f"Set-Service -Name {s} -StartupType Manual -ErrorAction SilentlyContinue; Stop-Service -Name {s} -Force -ErrorAction SilentlyContinue")
        except: pass
    # 4. telemetry
    ps('Set-Service -Name DiagTrack -StartupType Disabled -ErrorAction SilentlyContinue; Stop-Service DiagTrack -Force -ErrorAction SilentlyContinue')
    print("Done — 1.6GB profile applied. Reboot to lock.")

if __name__ == "__main__":
    if "--gui" in sys.argv:
        try:
            import tkinter as tk
            from tkinter import messagebox
            root=tk.Tk(); root.title("win-ram-optimizer 1.6GB"); root.geometry("420x280")
            tk.Label(root, text="⚡ win-ram-optimizer", font=("Segoe UI",16,"bold")).pack(pady=10)
            tk.Label(root, text="ReviOS 1.56GB — one click, permanent").pack()
            def do_fix(): 
                try: run_all(); messagebox.showinfo("Done","1.6GB applied. Reboot recommended.")
                except Exception as e: messagebox.showerror("Error",str(e))
            tk.Button(root, text="Fix now — 1.6GB (admin)", bg="#3b82f6", fg="white", font=("Segoe UI",11,"bold"), command=do_fix, height=2).pack(fill="x", padx=20, pady=20)
            tk.Button(root, text="Status", command=lambda: os.system('powershell -Command "Get-MMAgent | Format-List; Get-ScheduledTaskInfo -TaskName ReviOS-EmptyStandby | Format-List"')).pack()
            root.mainloop()
        except: run_all()
    else:
        run_all()
