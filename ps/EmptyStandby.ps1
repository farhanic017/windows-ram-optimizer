<#
    EmptyStandby.ps1 — graphics-safe RAM watchdog (port of farhanic017/windows-ram-optimizer)

    Upstream behaviour kept:
      * Enable-MMAgent -MemoryCompression / -PageCombining
      * EmptyWorkingSet sweep over processes
      * NtSetSystemInformation(80, 0/1/2) standby + modified list purge
      * [GC]::Collect()

    Graphics-safe additions (this is why dragging windows no longer loses frames):
      * never trims: DWM / shell / audio / Defender / critical system processes,
        any process owning a visible window, the foreground process,
        any process currently using the GPU (GPU Engine counters)
      * only trims processes that were CPU-idle since the previous run
      * standby purge is skipped entirely while a mouse button is down or the
        cursor moved within the last ~1.3s  -> no purge during/just after a drag
      * standby purge is skipped while a 3D/video/interactive GPU workload runs
      * removes the HKCU "NZXT.CAM" autostart entry (repo parity, no logon UAC popup)

    Run by the scheduled task "ReviOS-EmptyStandby" (interactive, elevated).
#>
param(
    [switch]$ForcePurge,   # ignore the drag / GPU guards for this run (manual "purge now")
    [switch]$SimulateDrag, # test hook: pretend a drag is in progress, used to verify the guard
    [switch]$NoLog
)

$ErrorActionPreference = 'SilentlyContinue'
$PermDir = 'C:\ProgramData\ReviOS'
$StateFile = Join-Path $PermDir 'watchdog-state.json'
$LogFile   = Join-Path $PermDir 'watchdog.log'
try { New-Item -ItemType Directory -Path $PermDir -Force -ErrorAction Stop | Out-Null } catch {}

function Write-WLog([string]$Message) {
    if ($NoLog) { return }
    try {
        $log = Join-Path $PermDir 'watchdog.log'
        if ((Test-Path $log) -and ((Get-Item $log).Length -gt 512KB)) { Remove-Item $log -Force }
        Add-Content -LiteralPath $log -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message)
    } catch {}
}

# ---------------------------------------------------------------- Win32 layer
if (-not ('RamFix.Guard' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace RamFix
{
    public struct POINT { public int X; public int Y; }

    public static class Guard
    {
        public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc lpEnumFunc, IntPtr lParam);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("psapi.dll", SetLastError = true)] public static extern bool EmptyWorkingSet(IntPtr hProcess);

        [DllImport("ntdll.dll")] public static extern uint NtSetSystemInformation(int infoClass, IntPtr info, int length);

        // --- privilege plumbing: the memory-list purge needs SeProfileSingleProcessPrivilege,
        //     which admins hold but is DISABLED by default (=> STATUS_PRIVILEGE_NOT_HELD).
        [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint LowPart; public int HighPart; }
        [StructLayout(LayoutKind.Sequential)] public struct TOKEN_PRIVILEGES { public int PrivilegeCount; public LUID Luid; public uint Attributes; }
        [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
        [DllImport("advapi32.dll", SetLastError = true)] public static extern bool OpenProcessToken(IntPtr h, uint access, out IntPtr t);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] public static extern bool LookupPrivilegeValue(string sys, string name, out LUID luid);
        [DllImport("advapi32.dll", SetLastError = true)] public static extern bool AdjustTokenPrivileges(IntPtr t, bool disableAll, ref TOKEN_PRIVILEGES newState, int bufferLength, IntPtr previousState, IntPtr returnLength);

        public static bool EnableProfilePrivilege()
        {
            try
            {
                IntPtr tok;
                if (!OpenProcessToken(GetCurrentProcess(), 0x28 /* QUERY|ADJUST_PRIVILEGES */, out tok)) return false;
                LUID luid;
                if (!LookupPrivilegeValue(null, "SeProfileSingleProcessPrivilege", out luid)) return false;
                TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
                tp.PrivilegeCount = 1;
                tp.Luid = luid;
                tp.Attributes = 0x2; // SE_PRIVILEGE_ENABLED
                if (!AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) return false;
                return Marshal.GetLastWin32Error() == 0;
            }
            catch { return false; }
        }

        // every process that owns a visible top-level window -> never trimmed
        public static int[] VisibleWindowPids()
        {
            HashSet<int> set = new HashSet<int>();
            EnumWindows(delegate(IntPtr h, IntPtr l)
            {
                try
                {
                    if (IsWindowVisible(h))
                    {
                        uint pid;
                        GetWindowThreadProcessId(h, out pid);
                        if (pid != 0) set.Add((int)pid);
                    }
                }
                catch { }
                return true;
            }, IntPtr.Zero);
            int[] arr = new int[set.Count];
            set.CopyTo(arr);
            return arr;
        }

        public static uint PurgeMemoryLists()
        {
            EnableProfilePrivilege();   // without this the call fails with STATUS_PRIVILEGE_NOT_HELD
            uint firstFailure = 0;
            for (int k = 0; k <= 2; k++)
            {
                IntPtr p = Marshal.AllocHGlobal(4);
                uint status;
                try
                {
                    Marshal.WriteInt32(p, k);
                    status = NtSetSystemInformation(80, p, 4);   // SystemMemoryListInformation
                }
                finally { Marshal.FreeHGlobal(p); }
                if (status != 0 && firstFailure == 0) firstFailure = status;
            }
            return firstFailure;   // 0 = STATUS_SUCCESS
        }
    }
}
'@
}

# ------------------------------------------------------- never-trim protect list
# compositor + shell + audio + security + critical system processes
$protectNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
@(
    'dwm', 'explorer', 'sihost', 'ShellExperienceHost', 'StartMenuExperienceHost',
    'SearchHost', 'SearchApp', 'SearchUI', 'TextInputHost', 'ctfmon', 'LockApp',
    'ApplicationFrameHost', 'SystemSettings', 'Taskmgr', 'RuntimeBroker',
    'audiodg', 'MsMpEng', 'NisSrv', 'SecurityHealthService',
    'csrss', 'wininit', 'winlogon', 'smss', 'lsass', 'services', 'fontdrvhost',
    'System', 'Registry', 'Memory Compression', 'Secure System'
) | ForEach-Object { [void]$protectNames.Add($_) }

# svchost.exe hosts are deliberately NOT blanket-protected: an idle host's pages
# move to the standby list when trimmed (re-fault at RAM speed, no hitch), and
# they are a large part of the RAM win on an 8GB machine.

# ------------------------------------- user-approved exception: trim the GAME while it plays
# Chosen 2026-09-28: trimming a foreground / GPU-active game can cost the odd hitch, but it is the
# only thing that actually lowers "In use" RAM on an 8GB box (idle background processes were
# already trimmed every run). Everything in $protectNames above stays untouchable regardless.
# NZXT CAM is in here for the same reason: in overlay mode it owns a visible HUD window, so the
# normal guards would spare it forever and it would creep back to full-app size (~250MB+).
$trimGameAlways = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
@('GenshinImpact', 'NZXT CAM', 'cam_helper') | ForEach-Object { [void]$trimGameAlways.Add($_) }

$protectPids = @{}   # pid -> reason

# --- GPU-active processes (iGPU shares system RAM; these must keep their pages)
$gpuBusy3D = $false
try {
    $samples = (Get-Counter '\GPU Engine(*)\Utilization Percentage' -ErrorAction Stop).CounterSamples
    foreach ($s in $samples) {
        if ($s.CookedValue -le 0) { continue }
        if ($s.InstanceName -match '^pid_(\d+)_') {
            $gpuPid = [int]$Matches[1]
            if (-not $protectPids.ContainsKey($gpuPid)) { $protectPids[$gpuPid] = 'gpu' }
            if ($s.InstanceName -match 'engtype_(3D|Video|Interactive)' -and $s.CookedValue -ge 5) { $gpuBusy3D = $true }
        }
    }
} catch {}

# --- every process owning a visible window (nothing on screen is ever trimmed)
try {
    foreach ($pidVis in [RamFix.Guard]::VisibleWindowPids()) {
        if (-not $protectPids.ContainsKey([int]$pidVis)) { $protectPids[[int]$pidVis] = 'visible-window' }
    }
} catch {}

# --- foreground process
try {
    $fgHwnd = [RamFix.Guard]::GetForegroundWindow()
    if ($fgHwnd -ne [IntPtr]::Zero) {
        $fgPid = [uint32]0
        [void][RamFix.Guard]::GetWindowThreadProcessId($fgHwnd, [ref]$fgPid)
        if ($fgPid -gt 0 -and -not $protectPids.ContainsKey([int]$fgPid)) { $protectPids[[int]$fgPid] = 'foreground' }
    }
} catch {}

# ------------------------------------------------------------------ 1) memory compression (upstream parity)
try { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue | Out-Null } catch {}
try { Enable-MMAgent -PageCombining   -ErrorAction SilentlyContinue | Out-Null } catch {}

# ------------------------------------------------------------------ 2) trim only IDLE, off-screen processes
# load previous CPU snapshot to decide what has been idle since last run
$prevCpu = @{}
$prevStart = @{}
$haveState = $false
try {
    if (Test-Path $StateFile) {
        $st = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
        foreach ($p in $st.cpu.PSObject.Properties) { $prevCpu[$p.Name] = [double]$p.Value }
        foreach ($p in $st.started.PSObject.Properties) { $prevStart[$p.Name] = [string]$p.Value }
        $haveState = $true
    }
} catch {}

$cpuNow = @{}
$startNow = @{}
$trimmed = 0
$kept = 0
$gameTrimmed = @()

foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) {
    $key = [string]$p.Id
    $cpu = $null
    try { $cpu = $p.CPU } catch {}
    if ($null -ne $cpu) { $cpuNow[$key] = [math]::Round([double]$cpu, 0) }
    try { $startNow[$key] = $p.StartTime.ToFileTimeUtc().ToString() } catch {}

    # ---- the game is exempt from every runtime guard (foreground / visible / GPU-busy / CPU-busy)
    $forceTrim = $false
    try { if ($trimGameAlways.Contains($p.ProcessName)) { $forceTrim = $true } } catch {}

    # ---- protect: name list (SYSTEM-owned processes keep no .Handle here, they are skipped anyway)
    try { if ($protectNames.Contains($p.ProcessName)) { $kept++; continue } } catch {}
    if (-not $forceTrim -and $protectPids.ContainsKey($p.Id)) { $kept++; continue }

    # ---- only trim what was idle since the previous run (the game never is, while you play)
    if (-not $forceTrim) {
        $idle = $false
        if ($prevCpu.ContainsKey($key)) {
            $delta = 0.0
            if ($null -ne $cpu) { $delta = [double]$cpu - $prevCpu[$key] }
            $idle = ($delta -le 0.5)
        } elseif ($haveState) {
            # brand-new process: only treat as idle once it has been alive a while
            try {
                $age = (Get-Date) - $p.StartTime
                $idle = ($age.TotalSeconds -gt 120)
            } catch { $idle = $false }
        } else {
            $idle = $true   # first ever run: trim non-protected processes (upstream behaviour)
        }
        if (-not $idle) { $kept++; continue }
    }

    # ---- tiny working sets are not worth the fault traffic
    try { if ($p.WorkingSet64 -lt 4MB) { continue } } catch {}

    try {
        if ([RamFix.Guard]::EmptyWorkingSet($p.Handle)) {
            $trimmed++
            if ($forceTrim) { $gameTrimmed += ('{0}({1}) {2}MB' -f $p.ProcessName, $p.Id, [int]($p.WorkingSet64 / 1MB)) }
        } else { $kept++ }
    } catch { $kept++ }
}

if ($gameTrimmed.Count -gt 0) { Write-WLog ('game-trim ' + ($gameTrimmed -join '; ')) }

# ------------------------------------------------------------------ 3) drag / GPU guard for the standby purge
$skipReason = $null
if ($ForcePurge) {
    $skipReason = $null
} elseif ($SimulateDrag) {
    $skipReason = 'test: simulated drag (guard verified)'
} else {
    # (a) any mouse button down => a drag (window or file) is in progress
    $down = $false
    foreach ($k in 1, 2, 4, 5, 6) {
        if (([RamFix.Guard]::GetAsyncKeyState($k) -band 0x8000) -ne 0) { $down = $true; break }
    }
    if ($down) { $skipReason = 'mouse-button-down (drag in progress)' }

    # (b) cursor moved within the last ~1.3s => still interacting / just finished a drag
    if (-not $skipReason) {
        $c1 = New-Object RamFix.POINT
        $c2 = New-Object RamFix.POINT
        [void][RamFix.Guard]::GetCursorPos([ref]$c1)
        Start-Sleep -Milliseconds 1300
        [void][RamFix.Guard]::GetCursorPos([ref]$c2)
        foreach ($k in 1, 2, 4, 5, 6) {
            if (([RamFix.Guard]::GetAsyncKeyState($k) -band 0x8000) -ne 0) { $down = $true; break }
        }
        if ($down) { $skipReason = 'mouse-button-down (drag in progress)' }
        elseif ([math]::Abs($c1.X - $c2.X) -gt 2 -or [math]::Abs($c1.Y - $c2.Y) -gt 2) {
            $skipReason = 'cursor moving (interaction detected)'
        }
    }

    # (c) a 3D / video / interactive GPU workload is running (iGPU shares this RAM)
    if (-not $skipReason -and $gpuBusy3D) { $skipReason = 'GPU 3D/video workload active' }
}

$purged = $false
$purgeStatus = $null
if (-not $skipReason) {
    try {
        $purgeStatus = [RamFix.Guard]::PurgeMemoryLists()
        $purged = ($purgeStatus -eq 0)
    } catch { $purgeStatus = 'exception' }
}

# ------------------------------------------------------------------ 4) repo parity: drop CAM autostart (HKCU)
try {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if ((Get-ItemProperty -Path $runKey -Name 'NZXT.CAM' -ErrorAction SilentlyContinue)) {
        Remove-ItemProperty -Path $runKey -Name 'NZXT.CAM' -ErrorAction SilentlyContinue
    }
} catch {}

# ------------------------------------------------------------------ 5) state + log
try {
    $stateObj = [pscustomobject]@{
        cpu     = $cpuNow
        started = $startNow
        ts      = (Get-Date -Format 'o')
    }
    $stateObj | ConvertTo-Json -Depth 4 -Compress | Set-Content -LiteralPath $StateFile -Encoding UTF8
} catch {}

try { [GC]::Collect() } catch {}

$freeMB = [math]::Round((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB)
$isAdmin = $false
try {
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}
$adminTag = "admin=$isAdmin"
if ($purged) {
    Write-WLog ("trim={0} kept={1} PURGED status=0x{2:X8} free={3}MB {4}" -f $trimmed, $kept, [uint32]$purgeStatus, $freeMB, $adminTag)
} elseif ($skipReason) {
    Write-WLog ("trim={0} kept={1} purge-skipped [{2}] free={3}MB {4}" -f $trimmed, $kept, $skipReason, $freeMB, $adminTag)
} else {
    Write-WLog ("trim={0} kept={1} purge-FAILED status={2} free={3}MB {4}" -f $trimmed, $kept, $purgeStatus, $freeMB, $adminTag)
}

if (-not $NoLog) {
    [pscustomobject]@{ Trimmed = $trimmed; Kept = $kept; Purged = $purged; SkippedBecause = $skipReason; FreeMB = $freeMB }
}

# ------------------------------------------------------------------ 6) self-heal, once per boot
# Windows Update / app updaters reset service start modes, re-add startup entries and can drop
# tasks. Repair.ps1 owns its own once-per-boot marker, so it runs in-process here (no new
# console, no window) and costs one file read on every other cycle.
$Repair = 'C:\ProgramData\ReviOS\Repair.ps1'
if (Test-Path -LiteralPath $Repair) {
    try { & $Repair } catch { Write-WLog ('repair-error: ' + $_.Exception.Message) }
}
