#!/usr/bin/env python3
"""
windows-ram-optimizer — Python edition

Optional: the PowerShell edition (ramfix.ps1) does the same job with zero installs,
so you only need this file if you already have Python.

Usage (a normal terminal is fine — it asks for UAC by itself):
    python optimizer.py            apply the 1.6GB profile
    python optimizer.py --gui      one-click Tkinter window
    python optimizer.py --status   RAM / MMAgent / task
    python optimizer.py --revert   undo everything this edition changed
"""
import ctypes
import json
import os
import pathlib
import subprocess
import sys

PERM_DIR = r"C:\ProgramData\ReviOS"
PERM_SCRIPT = os.path.join(PERM_DIR, "EmptyStandby.ps1")
FIX_MMA = os.path.join(PERM_DIR, "FixMMAgent.ps1")
SVC_SNAP = os.path.join(PERM_DIR, "services-before.json")
WATCH_VBS = os.path.join(PERM_DIR, "run-watchdog-hidden.vbs")
FIX_MM_VBS = os.path.join(PERM_DIR, "run-fixmm-hidden.vbs")
TEMP_MIRROR = r"C:\Windows\Temp\EmptyStandby.ps1"

# graphics-safe v2 watchdog when the ps/ folder is present, legacy v1 asset otherwise
_REPO = pathlib.Path(__file__).resolve().parent.parent
GUARDED_WATCHDOG = _REPO / "ps" / "EmptyStandby.ps1"
FALLBACK_WATCHDOG = _REPO / "assets" / "empty-standby.ps1"

WATCH_SERVICES = [
    "DiagTrack", "dmwappushservice", "WSearch", "SysMain", "AsusUpdateCheck", "IpOverUsbSvc",
    "Spooler", "BthAvctpSvc", "BTAGService", "bthserv", "MapsBroker", "RetailDemo", "QWAVE",
    "lmhosts", "SSDPSRV", "DSAService", "DSAUpdateService", "postgresql-x64-18", "CAMService",
]


def is_admin():
    try:
        return ctypes.windll.shell32.IsUserAnAdmin() != 0
    except Exception:
        return False


def elevate():
    """Re-launch this script elevated and stop here (no admin prompt to click twice)."""
    if is_admin():
        return
    exe = sys.executable or "python.exe"
    script = os.path.abspath(__file__)
    args = " ".join('"%s"' % a for a in sys.argv[1:])
    verb = ctypes.windll.shell32.ShellExecuteW
    rc = verb(None, "runas", exe, ('"%s" %s' % (script, args)).strip(), None, 1)
    if rc <= 32:
        raise PermissionError("Elevation failed — right-click your terminal → Run as administrator.")
    sys.exit(0)


def ps(cmd, timeout=60):
    return subprocess.check_output(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", cmd],
        text=True, timeout=timeout, stderr=subprocess.STDOUT,
    ).strip()


def write_hidden_vbs(vbs_path, command):
    """WSH launcher that runs `command` with no window at all.

    Windows Terminal is the default console host on Win11, so -WindowStyle Hidden is IGNORED:
    a plain powershell.exe task / Run entry pops a VISIBLE window (focus steal, games dumped
    to the desktop). wscript + window style 0 is the silent launcher.
    """
    os.makedirs(os.path.dirname(vbs_path), exist_ok=True)
    vbs = 'Set sh = CreateObject("WScript.Shell")\r\nsh.Run "%s", 0, False\r\n' % command.replace('"', '""')
    with open(vbs_path, "w", encoding="utf-8") as f:
        f.write(vbs)
    return 'wscript.exe "%s"' % vbs_path


def read_json(path, fallback):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return fallback


def save_baseline():
    """Merge-only snapshot of service start modes, taken before the first change."""
    os.makedirs(PERM_DIR, exist_ok=True)
    snap = read_json(SVC_SNAP, {})
    if len(snap) >= len(WATCH_SERVICES):
        return snap
    try:
        raw = ps("Get-CimInstance Win32_Service | Select-Object Name,StartMode | ConvertTo-Json -Compress")
        rows = json.loads(raw or "[]")
        if isinstance(rows, dict):
            rows = [rows]
    except Exception:
        return snap
    by_name = {r.get("Name"): r.get("StartMode") for r in rows if isinstance(r, dict)}
    for n in WATCH_SERVICES:
        if n not in snap and by_name.get(n):
            snap[n] = by_name[n]
    try:
        with open(SVC_SNAP, "w", encoding="utf-8") as f:
            json.dump(snap, f, indent=2)
    except Exception:
        pass
    return snap


def run_all(aggressive=False):
    if not is_admin():
        elevate()
        return
    os.makedirs(PERM_DIR, exist_ok=True)
    save_baseline()

    # 1. memory compression + silent Run entry
    try:
        ps("Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue; Enable-MMAgent -PageCombining -ErrorAction SilentlyContinue")
    except Exception:
        pass
    with open(FIX_MMA, "w", encoding="utf-8") as f:
        f.write("try { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue } catch {}\n"
                "try { Enable-MMAgent -PageCombining -ErrorAction SilentlyContinue } catch {}\n")
    run_value = write_hidden_vbs(
        FIX_MM_VBS, 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%s"' % FIX_MMA)
    ps("New-Item -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run' -Force | Out-Null; "
       "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run' "
       "-Name 'ReviOS_FixMMAgent' -Value '%s' -Force" % run_value)

    # 2. watchdog: graphics-safe script when available + silent wscript task
    source = GUARDED_WATCHDOG if GUARDED_WATCHDOG.exists() else FALLBACK_WATCHDOG
    text = source.read_text(encoding="utf-8")
    with open(PERM_SCRIPT, "w", encoding="utf-8") as f:
        f.write(text)
    try:
        with open(TEMP_MIRROR, "w", encoding="utf-8") as f:
            f.write(text)
    except Exception:
        pass
    try:
        ps('icacls "%s" /grant "NT AUTHORITY\\SYSTEM:(F)" /grant "BUILTIN\\Administrators:(F)" | Out-Null' % PERM_SCRIPT)
        ps('Add-MpPreference -ExclusionPath "%s" -ErrorAction SilentlyContinue' % PERM_DIR)
    except Exception:
        pass

    write_hidden_vbs(WATCH_VBS, 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%s"' % PERM_SCRIPT)
    ps("; ".join([
        "$vbs='%s'" % WATCH_VBS,
        "$action=New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('\"{0}\"' -f $vbs)",
        "$logon=New-ScheduledTaskTrigger -AtLogOn",
        "$repeat=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2)",
        "$principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest",
        "$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew -StartWhenAvailable -Compatibility Win8",
        "Register-ScheduledTask -TaskName 'ReviOS-EmptyStandby' -Action $action -Trigger $logon,$repeat -Principal $principal -Settings $settings -Force | Out-Null",
        "Enable-ScheduledTask -TaskName 'ReviOS-EmptyStandby' | Out-Null",
    ]))

    # 3. services
    manual = ["Spooler", "BthAvctpSvc", "BTAGService", "bthserv", "MapsBroker",
              "RetailDemo", "QWAVE", "lmhosts", "SSDPSRV"] if aggressive else []
    for s in ["DSAService", "DSAUpdateService", "WSearch", "CAMService", "postgresql-x64-18"] + manual:
        try:
            ps("Set-Service -Name %s -StartupType Manual -ErrorAction SilentlyContinue; "
               "Stop-Service -Name %s -Force -ErrorAction SilentlyContinue" % (s, s))
        except Exception:
            pass

    # 4. telemetry
    try:
        ps("Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DataCollection' "
           "-Name 'AllowTelemetry' -Value 0 -Force -ErrorAction SilentlyContinue; "
           "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System' "
           "-Name 'EnableActivityFeed' -Value 0 -Force -ErrorAction SilentlyContinue; "
           "Set-Service -Name DiagTrack -StartupType Disabled -ErrorAction SilentlyContinue; "
           "Stop-Service DiagTrack -Force -ErrorAction SilentlyContinue; "
           "Set-Service -Name dmwappushservice -StartupType Disabled -ErrorAction SilentlyContinue")
    except Exception:
        pass

    print("Done — 1.6GB profile applied. Reboot to lock it in.")


def status():
    print(ps("$os=Get-CimInstance Win32_OperatingSystem; "
             "$t=[math]::Round($os.TotalVisibleMemorySize/1KB); "
             "$f=[math]::Round($os.FreePhysicalMemory/1KB); "
             "\"RAM: {0}MB used / {1}MB total\" -f ($t-$f), $t"))
    print(ps("Get-MMAgent | Select-Object MemoryCompression,PageCombining | Format-List | Out-String").strip())
    try:
        print(ps("Get-ScheduledTaskInfo -TaskName ReviOS-EmptyStandby | "
                 "Select-Object LastRunTime,NextRunTime,LastTaskResult | Format-List | Out-String").strip())
    except Exception:
        print("Task: ReviOS-EmptyStandby not registered yet (run without --status first).")
    print("Admin: %s" % ("yes" if is_admin() else "no"))


def revert():
    if not is_admin():
        elevate()
        return
    done = {"tasks": 0, "services": 0, "startup": 0}

    for t in ("ReviOS-EmptyStandby", "ReviOS-BlockCAMAutostart"):
        try:
            ps("Disable-ScheduledTask -TaskName '%s' -ErrorAction SilentlyContinue; "
               "Unregister-ScheduledTask -TaskName '%s' -Confirm:$false -ErrorAction SilentlyContinue" % (t, t))
            done["tasks"] += 1
        except Exception:
            pass

    snap = read_json(SVC_SNAP, {})
    fallback = {
        "WSearch": "Automatic", "SysMain": "Automatic", "postgresql-x64-18": "Automatic",
        "DiagTrack": "Automatic", "dmwappushservice": "Manual", "CAMService": "Automatic",
        "DSAService": "Automatic", "DSAUpdateService": "Automatic", "AsusUpdateCheck": "Automatic",
        "Spooler": "Automatic", "MapsBroker": "Manual", "RetailDemo": "Disabled", "QWAVE": "Manual",
        "lmhosts": "Manual", "SSDPSRV": "Manual", "IpOverUsbSvc": "Manual",
        "BthAvctpSvc": "Manual", "BTAGService": "Manual", "bthserv": "Manual",
    }
    mode_map = {"Auto": "Automatic", "Automatic": "Automatic", "Manual": "Manual", "Disabled": "Disabled"}
    for n in dict.fromkeys(list(snap) + list(fallback)):
        mode = mode_map.get(str(snap.get(n) or fallback.get(n) or ""))
        if not mode:
            continue
        try:
            ps("Set-Service -Name '%s' -StartupType %s -ErrorAction SilentlyContinue" % (n, mode))
            if mode == "Automatic":
                ps("Start-Service -Name '%s' -ErrorAction SilentlyContinue" % n)
            done["services"] += 1
        except Exception:
            pass

    try:
        ps("Remove-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DataCollection' "
           "-Name 'AllowTelemetry' -ErrorAction SilentlyContinue; "
           "Remove-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System' "
           "-Name 'EnableActivityFeed' -ErrorAction SilentlyContinue; "
           "Remove-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run' "
           "-Name 'ReviOS_FixMMAgent' -ErrorAction SilentlyContinue; "
           "Remove-MpPreference -ExclusionPath '%s' -ErrorAction SilentlyContinue" % PERM_DIR)
    except Exception:
        pass

    for f in (WATCH_VBS, FIX_MM_VBS, PERM_SCRIPT, FIX_MMA, TEMP_MIRROR,
              r"C:\Windows\System32\EmptyStandby.ps1"):
        try:
            if os.path.exists(f):
                os.remove(f)
        except Exception:
            pass

    print("Reverted (%d tasks, %d services). Memory compression is left ON." %
          (done["tasks"], done["services"]))


def gui():
    import tkinter as tk
    from tkinter import messagebox

    root = tk.Tk()
    root.title("windows-ram-optimizer 1.6GB")
    root.geometry("440x300")
    root.configure(bg="#0a0f1e")

    def log(msg):
        txt.insert("end", str(msg) + "\n")
        txt.see("end")

    def do_fix():
        btn.configure(state="disabled")
        try:
            run_all()
            log("Done — reboot to lock in ~1.6GB idle.")
            messagebox.showinfo("Done", "1.6GB profile applied. Reboot recommended.")
        except Exception as e:
            log("Error: %s" % e)
            messagebox.showerror("Error", str(e))
        finally:
            btn.configure(state="normal")

    tk.Label(root, text="⚡ windows-ram-optimizer", font=("Segoe UI", 16, "bold"),
             bg="#0a0f1e", fg="#e6edf3").pack(pady=(14, 2))
    tk.Label(root, text="ReviOS-grade — one click, permanent", bg="#0a0f1e", fg="#9aa8c3").pack()
    btn = tk.Button(root, text="Fix now — 1.6GB idle", bg="#3b82f6", fg="white",
                    font=("Segoe UI", 11, "bold"), command=do_fix, relief="flat", pady=8)
    btn.pack(fill="x", padx=24, pady=14)
    txt = tk.Text(root, height=7, bg="#0b1224", fg="#9aa8c3", relief="flat",
                  font=("Consolas", 9))
    txt.pack(fill="both", expand=True, padx=24, pady=(0, 14))
    log("Admin: %s" % ("yes — ready" if is_admin() else "will ask for UAC"))
    log("Watchdog: ReviOS-EmptyStandby (silent, every 2 min)")
    root.mainloop()


if __name__ == "__main__":
    if "--gui" in sys.argv:
        try:
            gui()
        except ImportError:
            # no tkinter in this Python build -> fall back to the CLI
            run_all()
    elif "--status" in sys.argv:
        status()
    elif "--revert" in sys.argv:
        revert()
    else:
        run_all()
