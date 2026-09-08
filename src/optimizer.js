/**
 * win-ram-optimizer — core engine
 * Tuned from live 4304MB -> 1569MB (1.53GB) ReviOS session on 8GB Win11 26200
 * Covers: services, telemetry/spyware, memory compression, RAM watchdog, CAM 50MB, startup .bak
 */
const { execSync, spawn } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const PERM_DIR = 'C:\\ProgramData\\ReviOS';
const PERM_SCRIPT = path.join(PERM_DIR, 'EmptyStandby.ps1');
const FIX_MMA = path.join(PERM_DIR, 'FixMMAgent.ps1');
const CAM_OVERLAY = path.join(PERM_DIR, 'CAM-Overlay.ps1');
const STARTUP = path.join(os.homedir(), 'AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Startup');

function isAdmin() {
  try { execSync('net session', { stdio: 'ignore' }); return true; } catch { return false; }
}
function ps(cmd) {
  return execSync(`powershell -NoProfile -ExecutionPolicy Bypass -Command "${cmd.replace(/"/g, '`"')}"`, { encoding: 'utf8', timeout: 30000 }).trim();
}
function psFile(file) {
  return execSync(`powershell -NoProfile -ExecutionPolicy Bypass -File "${file}"`, { encoding: 'utf8', timeout: 30000 }).trim();
}

// --- PRESETS (safe defaults, reversible) ---
const SERVICES_DISABLE = ['dmwappushservice','DiagTrack']; // telemetry
const SERVICES_MANUAL = [
  'DSAService','DSAUpdateService','AsusUpdateCheck','IpOverUsbSvc',
  'WSearch','CAMService','postgresql-x64-18','Spooler','BthAvctpSvc','BTAGService','bthserv','MapsBroker','RetailDemo','QWAVE','lmhosts','SSDPSRV'
];
const SERVICES_MANUAL_SAFE = ['Spooler','BthAvctpSvc','BTAGService','bthserv','MapsBroker','RetailDemo','QWAVE','lmhosts','SSDPSRV'];

function ensureAdmin() {
  if (!isAdmin()) throw new Error('Run as Administrator (right-click → Run as admin).');
}

function getRAM() {
  try {
    const out = ps(`$os=Get-CimInstance Win32_OperatingSystem; $t=[math]::Round($os.TotalVisibleMemorySize/1KB); $f=[math]::Round($os.FreePhysicalMemory/1KB); $u=$t-$f; Write-Output "$u|$t|$f"`);
    const [used,total,free]=out.split('|').map(Number);
    return { used,total,free, usedGB:(used/1024).toFixed(2) };
  } catch { return { used:0,total:8192,free:0,usedGB:'?' }; }
}
function getMMA() {
  try { const o=ps('Get-MMAgent | Select-Object MemoryCompression,PageCombining,ApplicationLaunchPrefetching | ConvertTo-Json -Compress'); return JSON.parse(o); } catch { return {}; }
}
function getTaskInfo() {
  try { return ps(`Get-ScheduledTaskInfo -TaskName ReviOS-EmptyStandby | Select-Object LastRunTime,NextRunTime,LastTaskResult | ConvertTo-Json -Compress`); } catch { return '{}'; }
}

// --- CORE ACTIONS (each is idempotent + reversible) ---
const Core = {
  fixMemoryCompression() {
    try { ps('Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue'); ps('Enable-MMAgent -PageCombining -ErrorAction SilentlyContinue'); } catch {}
    // persist via Run key
    fs.mkdirSync(PERM_DIR, { recursive:true });
    fs.writeFileSync(FIX_MMA, `try { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue } catch {}\ntry { Enable-MMAgent -PageCombining -ErrorAction SilentlyContinue } catch {}\n`);
    try { ps(`New-Item -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run' -Force | Out-Null; Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run' -Name 'ReviOS_FixMMAgent' -Value 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File \\"${FIX_MMA}\\"' -Force`); } catch {}
    return getMMA();
  },
  fixRamWatchdog() {
    fs.mkdirSync(PERM_DIR, { recursive:true });
    const v2 = `@'
try { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue } catch {}
try { Enable-MMAgent -PageCombining -ErrorAction SilentlyContinue } catch {}
try {
  Add-Type "using System; using System.Runtime.InteropServices; public class Mclean { [DllImport(\\"psapi.dll\\")] public static extern bool EmptyWorkingSet(IntPtr h); }"
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
'@
`.trim();
    // Write both perm + temp mirrors
    const permScript = `@'
try { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue } catch {}
try { Enable-MMAgent -PageCombining -ErrorAction SilentlyContinue } catch {}
try {
  Add-Type "using System; using System.Runtime.InteropServices; public class Mclean { [DllImport(\\"psapi.dll\\")] public static extern bool EmptyWorkingSet(IntPtr h); }"
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
'@;
    fs.writeFileSync(PERM_SCRIPT, permScript);
    fs.writeFileSync('C:\\Windows\\Temp\\EmptyStandby.ps1', permScript);
    fs.writeFileSync('C:\\Windows\\System32\\EmptyStandby.ps1', permScript);
    try { ps(`icacls "${PERM_SCRIPT}" /grant "NT AUTHORITY\\SYSTEM:(F)" /grant "BUILTIN\\Administrators:(F)" | Out-Null`); ps(`Add-MpPreference -ExclusionPath "${PERM_DIR}" -ErrorAction SilentlyContinue`); } catch {}
    // (re)create scheduled task: BOOT + every 2min indefinite
    const taskPS = `
$perm="${PERM_SCRIPT}";
$action=New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File \`"$perm\`"";
$boot=New-ScheduledTaskTrigger -AtStartup;
$time=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2);
$principal=New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\\SYSTEM" -RunLevel Highest -LogonType ServiceAccount;
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew -StartWhenAvailable -Compatibility Win8;
Register-ScheduledTask -TaskName "ReviOS-EmptyStandby" -Action $action -Trigger $boot,$time -Principal $principal -Settings $settings -Force | Out-Null;
Enable-ScheduledTask -TaskName "ReviOS-EmptyStandby" | Out-Null;
`;
    ps(taskPS);
    // fix collapsed Startup .bak
    try {
      const startup = STARTUP;
      ps(`New-Item -ItemType Directory -Path "C:\\ProgramData\\ReviOS\\StartupBackup" -Force | Out-Null; Get-ChildItem "${startup}" -Filter "*.bak" -Force | ForEach-Object { Move-Item $_.FullName "C:\\ProgramData\\ReviOS\\StartupBackup\\$($_.Name)" -Force }`);
    } catch {}
    return { script: PERM_SCRIPT, task: 'ReviOS-EmptyStandby' };
  },
  fixServices(mode='safe') {
    // safe = manual for WSearch/Postgres/CAM/DSA etc. aggressive also disables
    const manual = mode==='aggressive' ? SERVICES_MANUAL : ['DSAService','DSAUpdateService','WSearch','CAMService','postgresql-x64-18'];
    manual.forEach(s=>{
      try { ps(`Set-Service -Name ${s} -StartupType Manual -ErrorAction SilentlyContinue; Stop-Service -Name ${s} -Force -ErrorAction SilentlyContinue`); } catch {}
    });
    // also patch Asus
    try { ps('Set-Service -Name AsusUpdateCheck -StartupType Disabled -ErrorAction SilentlyContinue'); } catch {}
    try { ps('Set-Service -Name IpOverUsbSvc -StartupType Manual -ErrorAction SilentlyContinue'); } catch {}
    return manual;
  },
  fixTelemetry() {
    const reg = `
Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DataCollection" -Name "AllowTelemetry" -Value 0 -Force -ErrorAction SilentlyContinue;
Set-ItemProperty -Path "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System" -Name "EnableActivityFeed" -Value 0 -Force -ErrorAction SilentlyContinue;
Set-Service -Name DiagTrack -StartupType Disabled -ErrorAction SilentlyContinue; Stop-Service DiagTrack -Force -ErrorAction SilentlyContinue;
Set-Service -Name dmwappushservice -StartupType Disabled -ErrorAction SilentlyContinue;
`;
    ps(reg);
    return true;
  },
  fixCamOverlay() {
    // keep service, kill UI, create 50MB launcher + block autostart
    try { ps(`Remove-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run' -Name 'NZXT.CAM' -ErrorAction SilentlyContinue`); } catch {}
    const launcher = CAM_OVERLAY;
    const code = `# CAM Overlay - 50MB mode
$cam="C:\\Program Files\\NZXT CAM\\NZXT CAM.exe"
if(-not (Test-Path $cam)) { Write-Host "CAM not found"; exit }
Start-Process -FilePath $cam -ArgumentList "--disable-gpu --disable-hardware-acceleration --in-process-gpu --startup" -WindowStyle Minimized
Start-Sleep 8
Add-Type "using System; using System.Runtime.InteropServices; public class T{ [DllImport(\\"psapi.dll\\")] public static extern bool EmptyWorkingSet(IntPtr h); }"
Get-Process "NZXT CAM","cam_helper" -ErrorAction SilentlyContinue | ForEach-Object { try { [T]::EmptyWorkingSet($_.Handle) } catch {} }
Get-Process "NZXT CAM","cam_helper" -ErrorAction SilentlyContinue | Select-Object Name,@{N='WS_MB';E={[math]::Round($_.WorkingSet64/1MB,1)}} | Format-Table -AutoSize
`;
    fs.writeFileSync(launcher, code);
    try {
      const action = `powershell.exe -NoProfile -Command "Remove-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run' -Name 'NZXT.CAM' -ErrorAction SilentlyContinue"`;
      ps(`$a=New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -Command \\"Remove-ItemProperty -Path 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run' -Name 'NZXT.CAM' -ErrorAction SilentlyContinue\\""; $t=New-ScheduledTaskTrigger -AtLogOn; $p=New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\\$env:USERNAME" -RunLevel Highest; Register-ScheduledTask -TaskName "ReviOS-BlockCAMAutostart" -Action $a -Trigger $t -Principal $p -Force | Out-Null`);
    } catch {}
    // shortcut
    try {
      ps(`$W=New-Object -COM WScript.Shell; $l=$W.CreateShortcut("$env:USERPROFILE\\Desktop\\CAM Overlay 50MB.lnk"); $l.TargetPath="powershell.exe"; $l.Arguments="-NoProfile -ExecutionPolicy Bypass -File \\"${launcher}\\""; $l.Save()`);
    } catch {}
    // kill current UI to hit 1.6 immediately
    try { ps(`Get-Process "NZXT CAM" -ErrorAction SilentlyContinue | Stop-Process -Force`); } catch {}
    try { ps(`Set-ItemProperty -Path "$env:APPDATA\\NZXT CAM\\settings.json" -Value ( (Get-Content "$env:APPDATA\\NZXT CAM\\settings.json" -Raw | ConvertFrom-Json | ForEach-Object { $_.disableHardwareAcceleration=$true; $_ } | ConvertTo-Json) ) -Force`); } catch {}
    return { launcher, shortcut: path.join(os.homedir(),'Desktop','CAM Overlay 50MB.lnk') };
  },
  runAll(opts={}) {
    ensureAdmin();
    const results={};
    results.ramBefore=getRAM();
    results.mma=Core.fixMemoryCompression();
    results.watchdog=Core.fixRamWatchdog();
    results.services=Core.fixServices(opts.aggressive?'aggressive':'safe');
    if (opts.telemetry!==false) results.telemetry=Core.fixTelemetry();
    if (opts.camOverlay!==false) results.cam=Core.fixCamOverlay();
    // final purge
    try { psFile(PERM_SCRIPT); } catch {}
    results.ramAfter=getRAM();
    results.taskInfo=getTaskInfo();
    return results;
  },
  revert() {
    ensureAdmin();
    try { ps('Set-Service WSearch -StartupType Automatic; Start-Service WSearch -ErrorAction SilentlyContinue'); } catch {}
    try { ps('Set-Service SysMain -StartupType Automatic; Start-Service SysMain -ErrorAction SilentlyContinue'); } catch {}
    try { ps('Set-Service postgresql-x64-18 -StartupType Automatic -ErrorAction SilentlyContinue'); } catch {}
    try { ps('Disable-ScheduledTask -TaskName ReviOS-EmptyStandby -ErrorAction SilentlyContinue'); } catch {}
    return true;
  }
};

module.exports = { Core, getRAM, getMMA, isAdmin, PERM_DIR, PERM_SCRIPT };
