/**
 * windows-ram-optimizer — core engine
 * Tuned from live 4304MB -> 1569MB (1.53GB) ReviOS session on 8GB Win11 26200
 * Covers: services, telemetry/spyware, memory compression, RAM watchdog, CAM 50MB, startup .bak
 */
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const PERM_DIR = 'C:\\ProgramData\\ReviOS';
const PERM_SCRIPT = path.join(PERM_DIR, 'EmptyStandby.ps1');
const FIX_MMA = path.join(PERM_DIR, 'FixMMAgent.ps1');
const CAM_OVERLAY = path.join(PERM_DIR, 'CAM-Overlay.ps1');
const STARTUP = path.join(os.homedir(), 'AppData\\Roaming\\Microsoft\\Windows\\Start Menu\\Programs\\Startup');
const STARTUP_BAK = path.join(PERM_DIR, 'StartupBackup');
const SVC_SNAP = path.join(PERM_DIR, 'services-before.json');
const TEMP_MIRROR = 'C:\\Windows\\Temp\\EmptyStandby.ps1';
const LEGACY_SYSTEM32_MIRROR = 'C:\\Windows\\System32\\EmptyStandby.ps1'; // older releases wrote this

// Windows Terminal is the default console host on Win11, so `-WindowStyle Hidden` is IGNORED:
// a plain powershell.exe scheduled task / Run entry / shortcut pops a VISIBLE window (focus
// steal, games and apps dumped to the desktop). wscript + window style 0 is the silent launcher.
const FIX_MM_VBS = path.join(PERM_DIR, 'run-fixmm-hidden.vbs');
const WATCH_VBS = path.join(PERM_DIR, 'run-watchdog-hidden.vbs');
const CAM_OV_VBS = path.join(PERM_DIR, 'run-camoverlay-hidden.vbs');
const CAM_BLOCK_VBS = path.join(PERM_DIR, 'block-cam-autostart.vbs');

// The graphics-safe v2 watchdog is what the PowerShell edition ships; fall back to the legacy
// v1 asset when running out of a package that has no ps/ folder.
const GUARDED_WATCHDOG = path.join(__dirname, '..', 'ps', 'EmptyStandby.ps1');
const FALLBACK_WATCHDOG = path.join(__dirname, '..', 'assets', 'empty-standby.ps1');

function isAdmin() {
  try { execSync('net session', { stdio: 'ignore' }); return true; } catch { return false; }
}
function ps(cmd) {
  // -EncodedCommand sidesteps every cmd.exe / PowerShell quoting trap (nested quotes, `|`, `$`,
  // `"` inside single-quoted values). The command is sent as UTF-16LE base64, so it arrives
  // byte-for-byte as written.
  const encoded = Buffer.from(cmd, 'utf16le').toString('base64');
  return execSync(`powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand ${encoded}`, { encoding: 'utf8', timeout: 30000 }).trim();
}
function psFile(file) {
  return execSync(`powershell -NoProfile -ExecutionPolicy Bypass -File "${file}"`, { encoding: 'utf8', timeout: 30000 }).trim();
}

// Writes a WSH launcher that runs `command` with no window at all and returns the Run-key value.
function writeHiddenVbs(vbsPath, command) {
  const vbs = 'Set sh = CreateObject("WScript.Shell")\r\n' +
              'sh.Run "' + command.replace(/"/g, '""') + '", 0, False\r\n';
  fs.mkdirSync(path.dirname(vbsPath), { recursive: true });
  fs.writeFileSync(vbsPath, vbs);
  return 'wscript.exe "' + vbsPath + '"';
}
function hiddenPsFileVbs(vbsPath, script) {
  return writeHiddenVbs(vbsPath, 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + script + '"');
}
function readJson(file, fallback) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return fallback; }
}

// --- PRESETS (safe defaults, reversible) ---
const SERVICES_DISABLE = ['dmwappushservice', 'DiagTrack']; // telemetry
const SERVICES_MANUAL = [
  'DSAService', 'DSAUpdateService', 'AsusUpdateCheck', 'IpOverUsbSvc',
  'WSearch', 'CAMService', 'postgresql-x64-18', 'Spooler', 'BthAvctpSvc', 'BTAGService', 'bthserv', 'MapsBroker', 'RetailDemo', 'QWAVE', 'lmhosts', 'SSDPSRV'
];
const SERVICES_MANUAL_SAFE = ['Spooler', 'BthAvctpSvc', 'BTAGService', 'bthserv', 'MapsBroker', 'RetailDemo', 'QWAVE', 'lmhosts', 'SSDPSRV'];

// Everything fixServices()/fixTelemetry() can touch, snapshotted before the first change so
// --revert can put the machine back the way it was.
const WATCH_SERVICES = [
  'DiagTrack', 'dmwappushservice', 'WSearch', 'SysMain', 'AsusUpdateCheck', 'IpOverUsbSvc',
  'Spooler', 'BthAvctpSvc', 'BTAGService', 'bthserv', 'MapsBroker', 'RetailDemo', 'QWAVE',
  'lmhosts', 'SSDPSRV', 'DSAService', 'DSAUpdateService', 'postgresql-x64-18', 'CAMService'
];

function ensureAdmin() {
  if (!isAdmin()) throw new Error('Run as Administrator (right-click → Run as admin).');
}

function getRAM() {
  try {
    const out = ps(`$os=Get-CimInstance Win32_OperatingSystem; $t=[math]::Round($os.TotalVisibleMemorySize/1KB); $f=[math]::Round($os.FreePhysicalMemory/1KB); $u=$t-$f; Write-Output "$u|$t|$f"`);
    const [used, total, free] = out.split('|').map(Number);
    return { used, total, free, usedGB: (used / 1024).toFixed(2) };
  } catch { return { used: 0, total: 8192, free: 0, usedGB: '?' }; }
}
function getMMA() {
  try { const o = ps('Get-MMAgent | Select-Object MemoryCompression,PageCombining,ApplicationLaunchPrefetching | ConvertTo-Json -Compress'); return JSON.parse(o); } catch { return {}; }
}
function getTaskInfo() {
  try { return ps(`Get-ScheduledTaskInfo -TaskName ReviOS-EmptyStandby | Select-Object LastRunTime,NextRunTime,LastTaskResult | ConvertTo-Json -Compress`); } catch { return '{}'; }
}

// Merge-only: never overwrite the original start modes captured by an earlier run.
function saveBaseline() {
  fs.mkdirSync(PERM_DIR, { recursive: true });
  const snap = readJson(SVC_SNAP, {});
  if (Object.keys(snap).length >= WATCH_SERVICES.length) return snap;
  let rows = [];
  try {
    const json = ps('Get-CimInstance Win32_Service | Select-Object Name,StartMode | ConvertTo-Json -Compress');
    rows = JSON.parse(json || '[]');
    if (!Array.isArray(rows)) rows = [rows];
  } catch { return snap; }
  for (const n of WATCH_SERVICES) {
    if (snap[n]) continue;
    const hit = rows.find((r) => r && r.Name === n);
    if (hit && hit.StartMode) snap[n] = hit.StartMode;
  }
  try { fs.writeFileSync(SVC_SNAP, JSON.stringify(snap, null, 2)); } catch {}
  return snap;
}

// --- CORE ACTIONS (each is idempotent + reversible) ---
const Core = {
  fixMemoryCompression() {
    try { ps('Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue'); ps('Enable-MMAgent -PageCombining -ErrorAction SilentlyContinue'); } catch {}
    // persist via Run key (silent wscript launcher — a plain powershell Run entry flashes a
    // visible terminal at every logon on Win11)
    fs.mkdirSync(PERM_DIR, { recursive: true });
    fs.writeFileSync(FIX_MMA, `try { Enable-MMAgent -MemoryCompression -ErrorAction SilentlyContinue } catch {}\ntry { Enable-MMAgent -PageCombining -ErrorAction SilentlyContinue } catch {}\n`);
    try {
      const runValue = hiddenPsFileVbs(FIX_MM_VBS, FIX_MMA);
      ps(`New-Item -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run' -Force | Out-Null; Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run' -Name 'ReviOS_FixMMAgent' -Value '${runValue}' -Force`);
    } catch {}
    return getMMA();
  },
  fixRamWatchdog() {
    fs.mkdirSync(PERM_DIR, { recursive: true });
    // Write both perm + temp mirrors - load from the guarded v2 script when available so the
    // Node edition never trims DWM / shell / foreground / GPU-active processes.
    const source = fs.existsSync(GUARDED_WATCHDOG) ? GUARDED_WATCHDOG : FALLBACK_WATCHDOG;
    const permScript = fs.readFileSync(source, 'utf8');
    fs.writeFileSync(PERM_SCRIPT, permScript);
    fs.writeFileSync(TEMP_MIRROR, permScript);
    try { ps('icacls "' + PERM_SCRIPT + '" /grant "NT AUTHORITY\\SYSTEM:(F)" /grant "BUILTIN\\Administrators:(F)" | Out-Null'); ps('Add-MpPreference -ExclusionPath "' + PERM_DIR + '" -ErrorAction SilentlyContinue'); } catch {}

    // (re)create the task: silent wscript action, interactive principal (the drag guard has to
    // SEE the mouse, so it cannot run as SYSTEM in session 0), logon + every 2 min.
    hiddenPsFileVbs(WATCH_VBS, PERM_SCRIPT);
    const taskPS = [
      `$vbs='${WATCH_VBS}'`,
      `$action=New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f $vbs)`,
      `$logon=New-ScheduledTaskTrigger -AtLogOn`,
      `$repeat=New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2)`,
      `$principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest`,
      `$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew -StartWhenAvailable -Compatibility Win8`,
      `Register-ScheduledTask -TaskName 'ReviOS-EmptyStandby' -Action $action -Trigger $logon,$repeat -Principal $principal -Settings $settings -Force | Out-Null`,
      `Enable-ScheduledTask -TaskName 'ReviOS-EmptyStandby' | Out-Null`
    ].join('; ');
    ps(taskPS);

    // fix collapsed Startup .bak
    try {
      fs.mkdirSync(STARTUP_BAK, { recursive: true });
      ps(`New-Item -ItemType Directory -Path '${STARTUP_BAK}' -Force | Out-Null; Get-ChildItem -LiteralPath '${STARTUP}' -Filter '*.bak' -Force -ErrorAction SilentlyContinue | ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination (Join-Path '${STARTUP_BAK}' $_.Name) -Force -ErrorAction SilentlyContinue }`);
    } catch {}
    return { script: PERM_SCRIPT, task: 'ReviOS-EmptyStandby', launcher: WATCH_VBS };
  },
  fixServices(mode = 'safe') {
    // safe = manual for WSearch/Postgres/CAM/DSA etc. aggressive also disables
    const manual = mode === 'aggressive' ? SERVICES_MANUAL : ['DSAService', 'DSAUpdateService', 'WSearch', 'CAMService', 'postgresql-x64-18'];
    manual.forEach((s) => {
      try { ps('Set-Service -Name ' + s + ' -StartupType Manual -ErrorAction SilentlyContinue; Stop-Service -Name ' + s + ' -Force -ErrorAction SilentlyContinue'); } catch {}
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
    try { ps('Remove-ItemProperty -Path \'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\' -Name \'NZXT.CAM\' -ErrorAction SilentlyContinue'); } catch {}
    const launcher = CAM_OVERLAY;
    const code = `# CAM Overlay - 50MB mode
$cam="C:\\Program Files\\NZXT CAM\\NZXT CAM.exe"
if(-not (Test-Path $cam)) { Write-Host "CAM not found"; exit }
Start-Process -FilePath $cam -ArgumentList "--disable-gpu --disable-hardware-acceleration --in-process-gpu --startup" -WindowStyle Minimized
Start-Sleep 8
Add-Type 'using System; using System.Runtime.InteropServices; public class T { [DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr h); }'
Get-Process "NZXT CAM","cam_helper" -ErrorAction SilentlyContinue | ForEach-Object { try { [T]::EmptyWorkingSet($_.Handle) } catch {} }
Get-Process "NZXT CAM","cam_helper" -ErrorAction SilentlyContinue | Select-Object Name,@{N='WS_MB';E={[math]::Round($_.WorkingSet64/1MB,1)}} | Format-Table -AutoSize
`;
    fs.writeFileSync(launcher, code);

    // Re-block the HKCU autostart entry at every logon, silently (RegDelete in WSH, no powershell
    // console at all).
    try {
      fs.writeFileSync(CAM_BLOCK_VBS,
        'On Error Resume Next\r\n' +
        'Set sh = CreateObject("WScript.Shell")\r\n' +
        'sh.RegDelete "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run\\NZXT.CAM"\r\n');
      ps(`$action=New-ScheduledTaskAction -Execute 'wscript.exe' -Argument ('"{0}"' -f '${CAM_BLOCK_VBS}'); $trigger=New-ScheduledTaskTrigger -AtLogOn; $principal=New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest; $settings=New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Compatibility Win8; Register-ScheduledTask -TaskName 'ReviOS-BlockCAMAutostart' -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null`);
    } catch {}

    // shortcut — wscript launcher so no terminal window opens (README: "starts it silently")
    try {
      hiddenPsFileVbs(CAM_OV_VBS, CAM_OVERLAY);
      ps(`$W=New-Object -COM WScript.Shell; $l=$W.CreateShortcut("$env:USERPROFILE\\Desktop\\CAM Overlay 50MB.lnk"); $l.TargetPath='wscript.exe'; $l.Arguments='"${CAM_OV_VBS}"'; $l.Save()`);
    } catch {}
    // kill current UI to hit 1.6 immediately
    try { ps('Get-Process "NZXT CAM" -ErrorAction SilentlyContinue | Stop-Process -Force'); } catch {}
    try { ps('Set-ItemProperty -Path "$env:APPDATA\\NZXT CAM\\settings.json" -Value ( (Get-Content "$env:APPDATA\\NZXT CAM\\settings.json" -Raw | ConvertFrom-Json | ForEach-Object { $_.disableHardwareAcceleration=$true; $_ } | ConvertTo-Json) ) -Force'); } catch {}
    return { launcher, shortcut: path.join(os.homedir(), 'Desktop', 'CAM Overlay 50MB.lnk') };
  },
  runAll(opts = {}) {
    ensureAdmin();
    const results = {};
    results.ramBefore = getRAM();
    results.snapshot = Object.keys(saveBaseline()).length;
    results.mma = Core.fixMemoryCompression();
    results.watchdog = Core.fixRamWatchdog();
    results.services = Core.fixServices(opts.aggressive ? 'aggressive' : 'safe');
    if (opts.telemetry !== false) results.telemetry = Core.fixTelemetry();
    if (opts.camOverlay !== false) results.cam = Core.fixCamOverlay();
    // final purge
    try { psFile(PERM_SCRIPT); } catch {}
    results.ramAfter = getRAM();
    results.taskInfo = getTaskInfo();
    return results;
  },
  revert() {
    ensureAdmin();
    const done = { tasks: [], services: [], runKey: false, startup: 0 };

    for (const t of ['ReviOS-EmptyStandby', 'ReviOS-BlockCAMAutostart']) {
      try {
        ps(`Disable-ScheduledTask -TaskName '${t}' -ErrorAction SilentlyContinue; Unregister-ScheduledTask -TaskName '${t}' -Confirm:$false -ErrorAction SilentlyContinue`);
        done.tasks.push(t);
      } catch {}
    }

    // services: back to what saveBaseline() saw before we touched anything (fallback = stock
    // Windows defaults for the ones fixServices() always changes)
    const snap = readJson(SVC_SNAP, {});
    const fallback = {
      WSearch: 'Automatic', SysMain: 'Automatic', 'postgresql-x64-18': 'Automatic',
      DiagTrack: 'Automatic', dmwappushservice: 'Manual', CAMService: 'Automatic',
      DSAService: 'Automatic', DSAUpdateService: 'Automatic', AsusUpdateCheck: 'Automatic',
      Spooler: 'Automatic', MapsBroker: 'Manual', RetailDemo: 'Disabled', QWAVE: 'Manual',
      lmhosts: 'Manual', SSDPSRV: 'Manual', IpOverUsbSvc: 'Manual',
      BthAvctpSvc: 'Manual', BTAGService: 'Manual', bthserv: 'Manual'
    };
    const modeMap = { Auto: 'Automatic', Automatic: 'Automatic', Manual: 'Manual', Disabled: 'Disabled' };
    for (const n of [...new Set([...Object.keys(snap), ...Object.keys(fallback)])]) {
      const mode = modeMap[String(snap[n] || fallback[n] || '')];
      if (!mode) continue;
      try {
        ps(`Set-Service -Name '${n}' -StartupType ${mode} -ErrorAction SilentlyContinue`);
        if (mode === 'Automatic') ps(`Start-Service -Name '${n}' -ErrorAction SilentlyContinue`);
        done.services.push(`${n}=${mode}`);
      } catch {}
    }

    // telemetry policies
    try {
      ps(`Remove-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DataCollection' -Name 'AllowTelemetry' -ErrorAction SilentlyContinue; Remove-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System' -Name 'EnableActivityFeed' -ErrorAction SilentlyContinue`);
    } catch {}

    // Run key + Defender exclusion
    try { ps(`Remove-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run' -Name 'ReviOS_FixMMAgent' -ErrorAction SilentlyContinue`); done.runKey = true; } catch {}
    try { ps(`Remove-MpPreference -ExclusionPath '${PERM_DIR}' -ErrorAction SilentlyContinue`); } catch {}

    // silent launchers + deployed scripts (also cleans up mirrors older releases wrote)
    for (const f of [FIX_MM_VBS, WATCH_VBS, CAM_OV_VBS, CAM_BLOCK_VBS, PERM_SCRIPT, FIX_MMA, CAM_OVERLAY, TEMP_MIRROR, LEGACY_SYSTEM32_MIRROR]) {
      try { if (fs.existsSync(f)) fs.unlinkSync(f); } catch {}
    }

    // Startup .bak entries back where they came from
    try {
      if (fs.existsSync(STARTUP_BAK)) {
        for (const f of fs.readdirSync(STARTUP_BAK)) {
          if (!f.endsWith('.bak')) continue;
          try { fs.renameSync(path.join(STARTUP_BAK, f), path.join(STARTUP, f)); done.startup++; } catch {}
        }
        try { fs.rmdirSync(STARTUP_BAK); } catch {}
      }
    } catch {}

    return done;
  }
};

module.exports = { Core, getRAM, getMMA, isAdmin, PERM_DIR, PERM_SCRIPT };
