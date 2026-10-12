<#
    ramfix.ps1 — PowerShell port of farhanic017/windows-ram-optimizer (GPL-3.0-or-later)
    Graphics-safe profile: same RAM wins, but the watchdog never trims DWM / shell /
    visible / GPU-active processes and never purges standby memory during a drag.

    Modes:
        .\ramfix.ps1 -Mode Apply       apply the safe profile (prompts UAC)
        .\ramfix.ps1 -Mode Status      show RAM / MMAgent / task / watchdog log
        .\ramfix.ps1 -Mode PurgeNow    one guarded-free purge now (ignores drag guard)
        .\ramfix.ps1 -Mode CamSetup    NZXT CAM 50MB overlay setup (run after installing CAM)
        .\ramfix.ps1 -Mode Reduce      deep process reduction (services + startup + svchost grouping)
        .\ramfix.ps1 -Mode Repair      re-apply Reduce's targets now (also runs once per boot automatically)
        .\ramfix.ps1 -Mode Revert      restore services / telemetry / task / exclusions
        .\ramfix.ps1 -Mode Apply -Aggressive   also cut Spooler/BT/Maps/etc (not recommended)
#>
[CmdletBinding()]
param(
    [ValidateSet('Apply', 'Status', 'PurgeNow', 'CamSetup', 'Revert', 'Reduce', 'Repair')]
    [string]$Mode = 'Apply',

    [switch]$Aggressive,

    # internal: elevated child writes a transcript here for the non-elevated parent
    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

$PermDir      = 'C:\ProgramData\ReviOS'
$PermScript   = Join-Path $PermDir 'EmptyStandby.ps1'
$FixMMA       = Join-Path $PermDir 'FixMMAgent.ps1'
$CamOverlay   = Join-Path $PermDir 'CAM-Overlay.ps1'
$RepairScript = Join-Path $PermDir 'Repair.ps1'
$TargetsF     = Join-Path $PermDir 'targets.json'
$FixMMVbs     = Join-Path $PermDir 'run-fixmm-hidden.vbs'
$SvcSnap      = Join-Path $PermDir 'services-before.json'
$Assets     = Join-Path $PSScriptRoot 'ps'
$Desktop    = Join-Path ([Environment]::GetFolderPath('Desktop')) 'CAM Overlay 50MB.lnk'

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Windows Terminal is the default terminal on Win11, so -WindowStyle Hidden is IGNORED: a plain
# powershell Run entry flashes a visible terminal at every logon. wscript + window style 0 is the
# silent way to start a console script (same trick used for the watchdog task).
function Get-FixMMRunValue {
    try {
        $vbs = 'Set sh = CreateObject("WScript.Shell")' + "`r`n" +
               'sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""' + $FixMMA + '""", 0, False' + "`r`n"
        [System.IO.File]::WriteAllText($FixMMVbs, $vbs, (New-Object System.Text.UTF8Encoding($false)))
        return ('wscript.exe "{0}"' -f $FixMMVbs)
    } catch {
        return ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $FixMMA)
    }
}

function Restart-Elevated {
    if ($OutFile -and (Test-Path $OutFile)) { Remove-Item $OutFile -Force -ErrorAction SilentlyContinue }
    $arg = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Mode $Mode"
    if ($Aggressive) { $arg += ' -Aggressive' }
    if ($OutFile)    { $arg += " -OutFile `"$OutFile`"" }
    Write-Host "Elevation required -> click 'Yes' on the UAC prompt..." -ForegroundColor Yellow
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arg -Wait
    } catch {
        Write-Host "Elevation cancelled: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
    if ($OutFile -and (Test-Path $OutFile)) {
        Get-Content -LiteralPath $OutFile | ForEach-Object { Write-Host $_ }
    }
    exit 0
}

function Get-Ram {
    $os = Get-CimInstance Win32_OperatingSystem
    $total = [math]::Round($os.TotalVisibleMemorySize / 1KB)
    $free  = [math]::Round($os.FreePhysicalMemory / 1KB)
    [pscustomobject]@{ Total = $total; Free = $free; Used = ($total - $free); UsedGB = [math]::Round(($total - $free) / 1024, 2) }
}

function Set-ServiceMode([string]$Name, [string]$Mode_, [switch]$Stop) {
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { return $false }
    Set-Service -Name $Name -StartupType $Mode_ -ErrorAction SilentlyContinue
    if ($Stop -and $svc.Status -eq 'Running') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
    return $true
}

function Get-Baseline {
    $b = @{}
    if (Test-Path $SvcSnap) {
        try {
            $json = Get-Content $SvcSnap -Raw | ConvertFrom-Json
            foreach ($prop in $json.PSObject.Properties) { $b[$prop.Name] = $prop.Value }
        } catch {}
    }
    return $b
}

function Save-Baseline([hashtable]$B) {
    New-Item -ItemType Directory -Path $PermDir -Force -ErrorAction SilentlyContinue | Out-Null
    $B | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $SvcSnap -Encoding UTF8 -ErrorAction SilentlyContinue
}

function Get-ProcStats {
    $all = @(Get-Process -ErrorAction SilentlyContinue)
    $os = Get-CimInstance Win32_OperatingSystem
    [pscustomobject]@{
        Total     = $all.Count
        Session0  = @($all | Where-Object { $_.SessionId -eq 0 }).Count
        User      = @($all | Where-Object { $_.SessionId -ne 0 }).Count
        Svchost   = @($all | Where-Object { $_.ProcessName -eq 'svchost' }).Count
        Services  = @(Get-Service | Where-Object { $_.Status -eq 'Running' }).Count
        UsedMB    = [math]::Round(($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / 1KB)
    }
}

function Invoke-Apply {
    # ---------------------------------------------------------------- 0) snapshot defaults (for clean -Revert; merge-only so later runs never overwrite the original values)
    New-Item -ItemType Directory -Path $PermDir -Force -ErrorAction SilentlyContinue | Out-Null
    $snap = Get-Baseline
    $watch = 'DiagTrack', 'dmwappushservice', 'WSearch', 'SysMain', 'AsusUpdateCheck', 'IpOverUsbSvc',
             'Spooler', 'BthAvctpSvc', 'BTAGService', 'bthserv', 'MapsBroker', 'RetailDemo', 'QWAVE',
             'lmhosts', 'SSDPSRV', 'DSAService', 'DSAUpdateService', 'postgresql-x64-18', 'CAMService'
    foreach ($n in $watch) {
        if ($snap.ContainsKey($n)) { continue }
        $q = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
        if ($q) { $snap[$n] = $q.StartMode }
    }
    if (-not $snap.ContainsKey('__CAM_RUN')) {
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $camProp = Get-ItemProperty -Path $runKey -Name 'NZXT.CAM' -ErrorAction SilentlyContinue
        if ($camProp) { $snap['__CAM_RUN'] = [string]$camProp.'NZXT.CAM' }
    }
    Save-Baseline $snap

    $before = Get-Ram
    Write-Host ("Before: {0}MB used / {1}MB total ({2}GB)" -f $before.Used, $before.Total, $before.UsedGB) -ForegroundColor Cyan

    # ---------------------------------------------------------------- 1) files
    New-Item -ItemType Directory -Path $PermDir -Force | Out-Null
    Copy-Item (Join-Path $Assets 'EmptyStandby.ps1') $PermScript -Force
    Copy-Item (Join-Path $Assets 'FixMMAgent.ps1')   $FixMMA     -Force
    Copy-Item (Join-Path $Assets 'CAM-Overlay.ps1')  $CamOverlay -Force
    Copy-Item (Join-Path $Assets 'Repair.ps1')       $RepairScript -Force
    # repo mirrors the script into Windows\Temp as well (System32 mirror intentionally skipped)
    Copy-Item $PermScript 'C:\Windows\Temp\EmptyStandby.ps1' -Force -ErrorAction SilentlyContinue
    icacls $PermScript /grant 'NT AUTHORITY\SYSTEM:(F)' /grant 'BUILTIN\Administrators:(F)' | Out-Null

    # Defender exclusion for our script folder (repo parity: otherwise behaviour-based
    # detection can quarantine a script that calls NtSetSystemInformation)
    $exclAdded = $false
    try {
        $cur = (Get-MpPreference).ExclusionPath
        if ($cur -notcontains $PermDir) {
            Add-MpPreference -ExclusionPath $PermDir -ErrorAction Stop
            $exclAdded = $true
        }
    } catch { Write-Host "  Defender exclusion skipped: $($_.Exception.Message)" -ForegroundColor DarkYellow }

    # ---------------------------------------------------------------- 2) memory compression
    try { Enable-MMAgent -MemoryCompression -ErrorAction Stop   | Out-Null } catch { Write-Host "  MMAgent MemoryCompression: $($_.Exception.Message)" -ForegroundColor DarkYellow }
    try { Enable-MMAgent -PageCombining    -ErrorAction Stop    | Out-Null } catch {}
    $rk = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    New-Item -Path $rk -Force | Out-Null
    Set-ItemProperty -Path $rk -Name 'ReviOS_FixMMAgent' -Value (Get-FixMMRunValue) -Force

    # ---------------------------------------------------------------- 3) scheduled task (interactive so the drag guard can SEE the mouse)
    $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
                 -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PermScript`""
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
    $tLogon  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    $tRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2)
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden `
                  -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew `
                  -StartWhenAvailable -Compatibility Win8
    Register-ScheduledTask -TaskName 'ReviOS-EmptyStandby' -Action $action -Trigger $tLogon,$tRepeat `
        -Principal $principal -Settings $settings -Force | Out-Null
    Enable-ScheduledTask -TaskName 'ReviOS-EmptyStandby' | Out-Null

    # ---------------------------------------------------------------- 4) services
    $svcList = if ($Aggressive) {
        @('DSAService', 'DSAUpdateService', 'WSearch', 'CAMService', 'postgresql-x64-18',
          'Spooler', 'BthAvctpSvc', 'BTAGService', 'bthserv', 'MapsBroker', 'RetailDemo',
          'QWAVE', 'lmhosts', 'SSDPSRV')
    } else {
        @('DSAService', 'DSAUpdateService', 'WSearch', 'CAMService', 'postgresql-x64-18')
    }
    $applied = @()
    foreach ($s in $svcList) { if (Set-ServiceMode $s 'Manual' -Stop) { $applied += $s } }
    if (Set-ServiceMode 'AsusUpdateCheck' 'Disabled') { $applied += 'AsusUpdateCheck(disabled)' }
    if (Set-ServiceMode 'IpOverUsbSvc' 'Manual')       { $applied += 'IpOverUsbSvc' }
    Write-Host ("  Services -> Manual: {0}" -f ($applied -join ', ')) -ForegroundColor DarkGray

    # ---------------------------------------------------------------- 5) telemetry / spyware
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 0 -Type DWord -Force
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Force | Out-Null
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'EnableActivityFeed' -Value 0 -Type DWord -Force
    Set-ServiceMode 'DiagTrack' 'Disabled' -Stop        | Out-Null
    Set-ServiceMode 'dmwappushservice' 'Disabled' -Stop | Out-Null

    # ---------------------------------------------------------------- 6) ReviOS startup .bak popup fix
    $startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    $bakDir  = Join-Path $PermDir 'StartupBackup'
    New-Item -ItemType Directory -Path $bakDir -Force | Out-Null
    $moved = @(Get-ChildItem -LiteralPath $startup -Filter '*.bak' -Force -ErrorAction SilentlyContinue)
    foreach ($f in $moved) { Move-Item -LiteralPath $f.FullName -Destination (Join-Path $bakDir $f.Name) -Force }
    if ($moved.Count) { Write-Host "  Moved $($moved.Count) Startup .bak -> $bakDir" -ForegroundColor DarkGray }

    # ---------------------------------------------------------------- 7) CAM 50MB overlay (only if CAM is installed)
    Invoke-CamSetup -Quiet | Out-Null

    # ---------------------------------------------------------------- 8) first guarded run
    Write-Host "`nRunning graphics-safe watchdog once (drag guard active)..." -ForegroundColor Cyan
    & powershell -NoProfile -ExecutionPolicy Bypass -File $PermScript
    Start-Sleep -Seconds 1
    $after = Get-Ram
    Write-Host ("After:  {0}MB used / {1}MB total ({2}GB)   saved {3}MB" -f `
        $after.Used, $after.Total, $after.UsedGB, ($before.Used - $after.Used)) -ForegroundColor Green
    Write-Host @"

Applied (safe profile$(if ($Aggressive) { ' + aggressive' })):
  * RAM watchdog   : ReviOS-EmptyStandby  (logon + every 2 min, guarded)
  * MMAgent        : MemoryCompression + PageCombining (persisted via HKLM Run)
  * Services       : WSearch/AsusUpdateCheck -> Manual/Disabled
  * Telemetry      : DiagTrack + dmwappushservice disabled, AllowTelemetry=0
  * Defender       : exclusion added for $PermDir
  * Revert         : .\ramfix.ps1 -Mode Revert
"@ -ForegroundColor White
}

function Invoke-CamSetup([switch]$Quiet) {
    $cam = 'C:\Program Files\NZXT CAM\NZXT CAM.exe'
    if (-not (Test-Path $cam)) {
        if (-not $Quiet) { Write-Host "NZXT CAM not installed yet - run this again after installing it." -ForegroundColor Yellow }
        return $false
    }
    New-Item -ItemType Directory -Path $PermDir -Force | Out-Null
    Copy-Item (Join-Path $Assets 'CAM-Overlay.ps1') $CamOverlay -Force
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $snap   = Get-Baseline

    # ---- Revert support: snapshot CAM's settings files once, before we edit them
    $camBak = Join-Path $PermDir 'cam-backup'
    New-Item -ItemType Directory -Path $camBak -Force | Out-Null
    $camFiles = @(
        @{ Label = 'app-settings';    Path = (Join-Path $env:APPDATA 'NZXT CAM\settings.json') },
        @{ Label = 'user-settings';   Path = (Join-Path $env:APPDATA 'NZXT CAM\DataStorage\latest\user\settings.json') },
        @{ Label = 'known-good-user'; Path = (Join-Path $env:APPDATA 'NZXT CAM\DataStorage\.last-known-good\user\settings.json') }
    )
    foreach ($f in $camFiles) {
        $bak = Join-Path $camBak ($f.Label + '.json')
        if ((Test-Path -LiteralPath $f.Path) -and -not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $f.Path -Destination $bak -Force }
    }
    if (-not $snap.ContainsKey('__CAM_OVERLAY_RUN')) { $snap['__CAM_OVERLAY_RUN'] = '(absent)'; Save-Baseline $snap }

    # ---- block NZXT's heavy UI autostart (repo parity; it re-registers while startupCAM is on)
    foreach ($n in 'NZXT.CAM', 'NZXT CAM') { Remove-ItemProperty -Path $runKey -Name $n -ErrorAction SilentlyContinue }

    # ---- autostart: launch CAM directly, with NO console process at logon.
    # The powershell launcher had to go: Windows Terminal is the default terminal, so
    # -WindowStyle Hidden did not hide the window, and cam_helper inherited that console and
    # kept it open for the whole session. RAM is held down by the watchdog's 2-min force trim.
    Set-ItemProperty -Path $runKey -Name 'NZXT CAM Overlay' -Force -Value `
        ('"{0}" --disable-gpu --disable-hardware-acceleration --in-process-gpu --startup' -f $cam)

    # ---- CAM's own settings: HW accel off, open straight into the mini-mode HUD overlay
    foreach ($f in $camFiles) {
        try {
            if (-not (Test-Path -LiteralPath $f.Path)) { continue }
            $j = Get-Content -LiteralPath $f.Path -Raw | ConvertFrom-Json
            foreach ($kv in @(
                @('miniModeOnStartup', $true),
                @('startCAMMinimized', $true),
                @('startMinimized', $true)
            )) {
                if ($j.PSObject.Properties.Name -contains $kv[0]) { $j.($kv[0]) = $kv[1] }
                else { $j | Add-Member -NotePropertyName $kv[0] -NotePropertyValue $kv[1] }
            }
            if ($f.Label -eq 'app-settings') {
                if ($j.PSObject.Properties.Name -contains 'disableHardwareAcceleration') { $j.disableHardwareAcceleration = $true }
            }
            # Node reads these files: write UTF-8 WITHOUT a BOM
            [System.IO.File]::WriteAllText($f.Path, ($j | ConvertTo-Json -Depth 16), (New-Object System.Text.UTF8Encoding($false)))
        } catch { Write-Host ("  settings edit failed ({0}): {1}" -f $f.Label, $_.Exception.Message) -ForegroundColor DarkYellow }
    }

    # ---- desktop shortcut: overlay-only launcher, started SILENTLY.
    # A console shortcut under Windows Terminal pops a visible window (-WindowStyle Hidden is
    # ignored there), so wrap it in wscript window-style 0, exactly like the watchdog task.
    try {
        $camVbs = Join-Path $PermDir 'run-camoverlay-hidden.vbs'
        $vbsTxt = 'Set sh = CreateObject("WScript.Shell")' + "`r`n" +
                  'sh.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -File ""' + $CamOverlay + '""", 0, False' + "`r`n"
        [System.IO.File]::WriteAllText($camVbs, $vbsTxt, (New-Object System.Text.UTF8Encoding($false)))

        $w = New-Object -COM WScript.Shell
        $l = $w.CreateShortcut($Desktop)
        $l.TargetPath = 'wscript.exe'
        $l.Arguments  = ('"{0}"' -f $camVbs)
        $l.WorkingDirectory = 'C:\Program Files\NZXT CAM'
        $l.WindowStyle = 1
        $l.Description = 'NZXT CAM in 50MB overlay-only mode'
        $l.Save()
    } catch { Write-Host "  Shortcut failed: $($_.Exception.Message)" -ForegroundColor DarkYellow }

    # CAM's own service back to the installer default so it is up before the overlay starts
    Set-ServiceMode 'CAMService' 'Automatic' | Out-Null

    # drop the running full-UI instance; the relaunch happens from the unelevated shell (CAM stays non-admin)
    Get-Process -Name 'NZXT CAM', 'cam_helper' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    if (-not $Quiet) { Write-Host "CAM 50MB overlay: logon autostart + mini-mode startup ready -> $Desktop" -ForegroundColor Green }
    return $true
}

function Invoke-Reduce {
    # Deep process reduction: services + startup + svchost grouping (your choice: keep Bluetooth)
    New-Item -ItemType Directory -Path $PermDir -Force -ErrorAction SilentlyContinue | Out-Null
    $snap = Get-Baseline
    $before = Get-ProcStats
    Write-Host ("BEFORE   total={0}  (session0={1}, user={2}, svchost={3}, running services={4}, RAM={5}MB)" -f `
        $before.Total, $before.Session0, $before.User, $before.Svchost, $before.Services, $before.UsedMB) -ForegroundColor Cyan

    # ------------------------------------------------------------------ 1) services
    # deploy the updated watchdog (game-trim override) - the task action path never changes
    try {
        Copy-Item (Join-Path $Assets 'EmptyStandby.ps1') $PermScript -Force -ErrorAction Stop
        Write-Host '  watchdog deployed: game-trim override live on the next 2-min cycle' -ForegroundColor DarkGray
    } catch { Write-Host ('  watchdog deploy FAILED: ' + $_.Exception.Message) -ForegroundColor Red }

    # Disabled: diagnostics / telemetry / discovery / transition plumbing - nothing you use
    $disableList = @(
        'DPS', 'WdiSystemHost', 'wuqisvc', 'whesvc', 'PcaSvc', 'DoSvc', 'DusmSvc', 'lfsvc',
        'SensorService', 'SSDPSRV', 'NcbService', 'TrkWks', 'WinHttpAutoProxySvc', 'lmhosts', 'iphlpsvc'
    )
    # Manual (= demand-start): features you said you don't use; still recoverable if you ever need them
    $manualList = @(
        'Spooler', 'ClickToRunSvc', 'igccservice', 'igfxCUIService2.0.0.0', 'jhi_service',
        'WMIRegistrationService', 'WSearch', 'InstallService', 'LicenseManager', 'wlidsvc',
        'TokenBroker', 'ClipSVC', 'DeviceAssociationService', 'seclogon', 'StorSvc', 'LanmanServer',
        'WpnService', 'NPSMSvc', 'WSAIFabricSvc', 'TimeBrokerSvc', 'CloudBackupRestoreSvc'
    )
    $perUserTemplates = @('WpnUserService', 'CDPUserSvc', 'NPSMSvc', 'CloudBackupRestoreSvc')   # per-user singletons, 1 process each

    # baseline everything we are about to change (only the first time)
    foreach ($n in @($disableList + $manualList)) {
        if ($snap.ContainsKey($n)) { continue }
        $q = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
        if ($q) { $snap[$n] = $q.StartMode }
    }
    foreach ($base in $perUserTemplates) {
        $tk = "HKLM:\SYSTEM\CurrentControlSet\Services\$base"
        if ((Test-Path $tk) -and -not $snap.ContainsKey("__START_$base")) {
            $snap["__START_$base"] = (Get-ItemProperty -Path $tk -Name 'Start').Start
        }
        foreach ($s in @(Get-Service -Name "$base*" -ErrorAction SilentlyContinue)) {
            if ($snap.ContainsKey($s.Name)) { continue }
            $q = Get-CimInstance Win32_Service -Filter "Name='$($s.Name)'" -ErrorAction SilentlyContinue
            if ($q) { $snap[$s.Name] = $q.StartMode }
        }
    }
    Save-Baseline $snap

    $failed = @()
    $stopped = 0
    foreach ($n in $disableList) {
        try   { Set-Service -Name $n -StartupType Disabled -ErrorAction Stop; $stopped++ }
        catch { $failed += "$n(set)" }
        try   { Stop-Service -Name $n -Force -ErrorAction Stop } catch {}
    }
    foreach ($n in $manualList) {
        try   { Set-Service -Name $n -StartupType Manual -ErrorAction Stop; $stopped++ }
        catch { $failed += "$n(set)" }
        try   { Stop-Service -Name $n -Force -ErrorAction Stop } catch {}
    }
    # per-user: template goes Manual so no instance is spawned next logon; stop the live ones too
    foreach ($base in $perUserTemplates) {
        $tk = "HKLM:\SYSTEM\CurrentControlSet\Services\$base"
        try { if (Test-Path $tk) { Set-ItemProperty -Path $tk -Name 'Start' -Value 3 -Type DWord -ErrorAction Stop } } catch { $failed += "$base(tpl)" }
        foreach ($s in @(Get-Service -Name "$base*" -ErrorAction SilentlyContinue)) {
            try { Set-Service -Name $s.Name -StartupType Manual -ErrorAction Stop } catch {}
            try { Stop-Service -Name $s.Name -Force -ErrorAction Stop; $stopped++ } catch {}
        }
    }
    # some services refuse Set-Service (protected DACL) -> fall back to the service registry Start value
    # Start: 2 = Automatic, 3 = Manual (demand), 4 = Disabled
    foreach ($n in $disableList) {
        if ($failed -notcontains "$n(set)") { continue }
        try {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$n" -Name 'Start' -Value 4 -Type DWord -ErrorAction Stop
            $failed = @($failed | Where-Object { $_ -ne "$n(set)" })
        } catch { $failed += "$n(reg)" }
    }
    foreach ($n in $manualList) {
        if ($failed -notcontains "$n(set)") { continue }
        try {
            Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$n" -Name 'Start' -Value 3 -Type DWord -ErrorAction Stop
            $failed = @($failed | Where-Object { $_ -ne "$n(set)" })
        } catch { $failed += "$n(reg)" }
    }

    # final sweep: stop everything on the lists once more (some services refuse the first stop)
    foreach ($n in @($disableList + $manualList)) {
        $s = Get-Service -Name $n -ErrorAction SilentlyContinue
        if ($s -and $s.Status -eq 'Running') {
            try { Stop-Service -Name $n -Force -ErrorAction Stop; $stopped++ } catch { $failed += "$n(stop)" }
        }
    }
    # per-user live instances again (Set-Service cannot change their start type - Stop only)
    foreach ($base in $perUserTemplates) {
        foreach ($s in @(Get-Service -Name "$base*" -ErrorAction SilentlyContinue)) {
            if ($s.Status -eq 'Running') { try { Stop-Service -Name $s.Name -Force -ErrorAction Stop; $stopped++ } catch { $failed += "$s(stop)" } }
        }
    }
    # Bluetooth stays exactly as it was (bthserv / BTAGService / BthAvctpSvc untouched)
    Write-Host "  services changed: $stopped   (failures: $(if ($failed) { $failed -join ', ' } else { 'none' }))" -ForegroundColor DarkGray

    # ------------------------------------------------------------------ 2) startup entries
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $removedRun = @()
    foreach ($p in @((Get-ItemProperty -Path $runKey -ErrorAction SilentlyContinue).PSObject.Properties |
                     Where-Object { $_.Name -notlike 'PS*' })) {
        if ($p.Name -like 'OneDrive*' -or $p.Name -like 'MicrosoftEdgeAutoLaunch*') {
            if (-not $snap.ContainsKey("__RUN_$($p.Name)")) { $snap["__RUN_$($p.Name)"] = [string]$p.Value }
            Remove-ItemProperty -Path $runKey -Name $p.Name -ErrorAction SilentlyContinue
            $removedRun += $p.Name
        }
    }
    Save-Baseline $snap
    Write-Host "  startup removed: $(if ($removedRun) { $removedRun -join ', ' } else { 'none' })" -ForegroundColor DarkGray

    # ------------------------------------------------------------------ 3) Widgets platform (policy, reversible)
    $polPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'
    if (-not $snap.ContainsKey('__WIDGETSPOLICY')) {
        $old = (Get-ItemProperty -Path $polPath -Name 'AllowNewsAndInterests' -ErrorAction SilentlyContinue).AllowNewsAndInterests
        $snap['__WIDGETSPOLICY'] = if ($null -eq $old) { '(absent)' } else { $old }
    }
    try {
        $curW = (Get-ItemProperty -LiteralPath $polPath -Name 'AllowNewsAndInterests' -ErrorAction SilentlyContinue).AllowNewsAndInterests
        if ($null -ne $curW -and [int]$curW -eq 0) {
            Write-Host '  widgets policy: 0 (already set)' -ForegroundColor DarkGray
        } else {
            if (-not (Test-Path -LiteralPath $polPath)) { New-Item -Path $polPath -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -LiteralPath $polPath -Name 'AllowNewsAndInterests' -Value 0 -Type DWord -Force -ErrorAction Stop
            Write-Host '  widgets policy: 0 (platform disabled)' -ForegroundColor DarkGray
        }
    } catch {
        $curW2 = (Get-ItemProperty -LiteralPath $polPath -Name 'AllowNewsAndInterests' -ErrorAction SilentlyContinue).AllowNewsAndInterests
        Write-Host ('  widgets policy: unchanged (current=' + $curW2 + ') note: ' + $_.Exception.Message) -ForegroundColor Yellow
    }

    # ------------------------------------------------------------------ 4) svchost grouping (takes effect after reboot)
    if (-not $snap.ContainsKey('__SPLIT_THRESHOLD')) {
        $ctrl = 'HKLM:\SYSTEM\CurrentControlSet\Control'
        $old = (Get-ItemProperty -Path $ctrl -Name 'SvcHostSplitThresholdInKB' -ErrorAction SilentlyContinue).SvcHostSplitThresholdInKB
        $snap['__SPLIT_THRESHOLD'] = if ($null -eq $old) { '(absent)' } else { $old }
    }
    Save-Baseline $snap
    # threshold > installed RAM (8GB = 8388608 KB) => services share hosts again instead of 1 process each
    try {
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'SvcHostSplitThresholdInKB' -Value 16777216 -Type DWord -Force -ErrorAction Stop
        Write-Host '  svchost grouping: threshold 16777216 KB (reboot to activate)' -ForegroundColor DarkGray
    } catch { Write-Host ('  svchost grouping: note: ' + $_.Exception.Message) -ForegroundColor Yellow }

    # ------------------------------------------------------------------ 4b) page file = the "RAM extender"
    # your old PC had a 16GB page file on D:; rebuilt on C: (NVMe) instead - paging to an HDD
    # mid-game is what turns a trimmed working set into a visible hitch.
    if (-not $snap.ContainsKey('__PAGEFILE_AUTO')) {
        try {
            $autoNow = [bool](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).AutomaticManagedPagefile
            $origPf = @(Get-CimInstance Win32_PageFileSetting -ErrorAction Stop)
            $snap['__PAGEFILE_AUTO'] = [string]$autoNow
            if ($origPf.Count -eq 0) { $snap['__PAGEFILE_SETTING'] = '(auto)' }
            else { $snap['__PAGEFILE_SETTING'] = (($origPf | ForEach-Object { '{0}|{1}|{2}' -f $_.Name, $_.InitialSize, $_.MaximumSize }) -join ';') }
        } catch {
            Write-Host ('  pagefile baseline not recorded (pagefile left out of Revert): ' + $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    Save-Baseline $snap
    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        if ($cs.AutomaticManagedPagefile) {
            Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop
        }
        # the C: entry already exists on this box -> resize it (Set-WmiInstance = Create, which fails as duplicate)
        $pfW = @((Get-WmiObject -Class Win32_PageFileSetting -ErrorAction Stop) | Where-Object { $_.Name -like 'C:*' })
        if ($pfW.Count -gt 0) {
            $pfW[0].InitialSize = 16384
            $pfW[0].MaximumSize = 16384
            [void]$pfW[0].Put()
        } else {
            Set-WmiInstance -Class Win32_PageFileSetting -Arguments @{
                Name = 'C:\pagefile.sys'; InitialSize = 16384; MaximumSize = 16384
            } -ErrorAction Stop | Out-Null
        }
        # any page file on other drives would dilute the headroom - remove them
        foreach ($other in @(Get-WmiObject -Class Win32_PageFileSetting -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike 'C:*' })) {
            try { $other.Delete() | Out-Null } catch {}
        }
        $pfNow = (@(Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue) |
                  ForEach-Object { '{0} {1}/{2}MB' -f $_.Name, $_.InitialSize, $_.MaximumSize }) -join '; '
        $pfNote = $pfNow + '  -> commit limit 8+16 = 24GB (reboot to activate)'
    } catch { $pfNote = 'FAILED: ' + $_.Exception.Message }
    Write-Host ('  pagefile: ' + $pfNote) -ForegroundColor DarkGray

    # ------------------------------------------------------------------ 6) persistence
    # Windows Update resets service start modes, re-adds startup entries and can drop tasks.
    # targets.json = desired state; Repair.ps1 re-applies it (SYSTEM at logon + watchdog).
    try {
        Copy-Item (Join-Path $Assets 'Repair.ps1') $RepairScript -Force -ErrorAction Stop
        $svcTargets = [ordered]@{}
        foreach ($n in $disableList)                      { $svcTargets[$n] = 'Disabled' }
        foreach ($n in $manualList)                       { $svcTargets[$n] = 'Manual'   }
        foreach ($n in @('DSAService', 'DSAUpdateService', 'WSearch', 'postgresql-x64-18', 'IpOverUsbSvc')) { $svcTargets[$n] = 'Manual' }
        $svcTargets['AsusUpdateCheck']  = 'Disabled'
        $svcTargets['DiagTrack']        = 'Disabled'
        $svcTargets['dmwappushservice'] = 'Disabled'
        $svcTargets['CAMService']       = 'Automatic'
        $regTargets = [ordered]@{}
        foreach ($n in $perUserTemplates) { $regTargets[$n] = 3 }
        $tj = [ordered]@{
            generated                 = (Get-Date).ToString('s')
            services                  = $svcTargets
            registryStart             = $regTargets
            runAbsentPatterns         = @('OneDrive*', 'MicrosoftEdgeAutoLaunch*', 'NZXT.CAM', 'NZXT CAM')
            policies                  = [ordered]@{
                'HKLM:\SOFTWARE\Policies\Microsoft\Dsh::AllowNewsAndInterests'            = 0
                'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection::AllowTelemetry' = 0
                'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System::EnableActivityFeed'    = 0
            }
            svcHostSplitThresholdInKB = 16777216
            pagefile                  = [ordered]@{ auto = $false; name = 'C:\pagefile.sys'; initial = 16384; max = 16384 }
            mma                       = [ordered]@{ MemoryCompression = $true; PageCombining = $true }
            defenderExclusion         = $PermDir
            hkmlRun                   = [ordered]@{ ReviOS_FixMMAgent = (Get-FixMMRunValue) }
        }
        [System.IO.File]::WriteAllText($TargetsF, ($tj | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($false)))
        Write-Host '  targets.json written -> self-heal armed (SYSTEM at logon + watchdog)' -ForegroundColor DarkGray
    } catch { Write-Host ('  targets.json FAILED: ' + $_.Exception.Message) -ForegroundColor Red }

    # run the self-heal now: registers ReviOS-LogonRepair, validates the watchdog task, sweeps leftovers
    if (Test-Path -LiteralPath $RepairScript) {
        try { & powershell -NoProfile -ExecutionPolicy Bypass -File $RepairScript -Force }
        catch { Write-Host ('  repair pass: ' + $_.Exception.Message) -ForegroundColor DarkYellow }
    }

    # ------------------------------------------------------------------ 5) stop the background instances now
    $edgeOpen = @(Get-Process -Name 'msedge' -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle -ne '' }).Count
    if ($edgeOpen -eq 0) { Stop-Process -Name 'msedge' -Force -ErrorAction SilentlyContinue }
    Stop-Process -Name 'OneDrive' -Force -ErrorAction SilentlyContinue
    Stop-Process -Name 'OneDrive.Sync.Service' -Force -ErrorAction SilentlyContinue
    Stop-Process -Name 'Widgets' -Force -ErrorAction SilentlyContinue
    Stop-Process -Name 'WidgetService' -Force -ErrorAction SilentlyContinue

    Start-Sleep -Seconds 2
    $after = Get-ProcStats
    Write-Host ("AFTER    total={0}  (session0={1}, user={2}, svchost={3}, running services={4}, RAM={5}MB)   -{6} processes" -f `
        $after.Total, $after.Session0, $after.User, $after.Svchost, $after.Services, $after.UsedMB,
        ($before.Total - $after.Total)) -ForegroundColor Green

    if ($edgeOpen -gt 0) { Write-Host "  note: Edge had $edgeOpen window(s) open - left running, autostart still removed." -ForegroundColor Yellow }
    Write-Host @"

Reboot to activate svchost grouping (79 svchost -> ~12) - that is what gets you under 80.
After reboot run:  .\ramfix.ps1 -Mode Reduce   again is NOT needed; use -Mode Status to check counts.

Undo everything:   .\ramfix.ps1 -Mode Revert
"@ -ForegroundColor White
}

function Invoke-Status {
    $ps = Get-ProcStats
    Write-Host ("PROCS   total={0}  (session0={1}, user={2}, svchost={3})   running services={4}" -f `
        $ps.Total, $ps.Session0, $ps.User, $ps.Svchost, $ps.Services) -ForegroundColor Green
    $r = Get-Ram
    Write-Host ("RAM:    {0}MB used / {1}MB total ({2}GB)  free {3}MB" -f $r.Used, $r.Total, $r.UsedGB, $r.Free) -ForegroundColor Cyan
    $thr = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'SvcHostSplitThresholdInKB' -ErrorAction SilentlyContinue).SvcHostSplitThresholdInKB
    Write-Host ("svchost grouping: SvcHostSplitThresholdInKB={0}  ({1})" -f $thr, $(if ($thr -gt 8388608) { 'grouping ON - active after reboot' } else { 'default - one process per service' })) -ForegroundColor Cyan
    try {
        $m = Get-MMAgent
        Write-Host ("MMA:   MemoryCompression={0}  PageCombining={1}" -f $m.MemoryCompression, $m.PageCombining) -ForegroundColor Cyan
    } catch { Write-Host "MMA:   (needs admin)" -ForegroundColor DarkYellow }
    try {
        $t = Get-ScheduledTask -TaskName 'ReviOS-EmptyStandby' -ErrorAction Stop
        $i = Get-ScheduledTaskInfo -TaskName 'ReviOS-EmptyStandby'
        Write-Host ("Task:  {0}  LastRun={1}  NextRun={2}  LastResult={3}" -f `
            $t.State, $i.LastRunTime, $i.NextRunTime, $i.LastTaskResult) -ForegroundColor Cyan
    } catch { Write-Host "Task:  not registered" -ForegroundColor DarkYellow }
    foreach ($n in 'WSearch', 'SysMain', 'DiagTrack', 'dmwappushservice', 'CAMService', 'AsusUpdateCheck', 'Spooler') {
        $s = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
        if ($s) { Write-Host ("Svc:   {0,-18} {1,-9} {2}" -f $n, $s.State, $s.StartMode) -ForegroundColor DarkGray }
    }
    $log = Join-Path $PermDir 'watchdog.log'
    if (Test-Path $log) {
        Write-Host "`nLast watchdog cycles:" -ForegroundColor Cyan
        Get-Content -LiteralPath $log -Tail 6 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
    }
}

function Invoke-Revert {
    Write-Host 'Reverting...' -ForegroundColor Yellow

    # task
    Disable-ScheduledTask -TaskName 'ReviOS-EmptyStandby' -ErrorAction SilentlyContinue | Out-Null
    Unregister-ScheduledTask -TaskName 'ReviOS-EmptyStandby' -Confirm:$false -ErrorAction SilentlyContinue
    # self-heal task + its state (targets.json / marker / Repair.ps1 live in $PermDir, removed below)
    Disable-ScheduledTask -TaskName 'ReviOS-LogonRepair' -ErrorAction SilentlyContinue | Out-Null
    Unregister-ScheduledTask -TaskName 'ReviOS-LogonRepair' -Confirm:$false -ErrorAction SilentlyContinue

    # services: restore what Apply/Reduce snapshotted (fallback: repo defaults)
    $snap = Get-Baseline
    $fallback = @{ WSearch = 'Automatic'; SysMain = 'Automatic'; 'postgresql-x64-18' = 'Automatic' }
    $modeMap = @{ 'Auto' = 'Automatic'; 'Automatic' = 'Automatic'; 'Manual' = 'Manual'; 'Disabled' = 'Disabled' }
    foreach ($n in (@($snap.Keys) + @($fallback.Keys) | Select-Object -Unique)) {
        if ($n -eq '__CAM_RUN') { continue }
        if ($n -eq '__CAM_OVERLAY_RUN') {
            Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'NZXT CAM Overlay' -ErrorAction SilentlyContinue
            continue
        }

        # --- special baseline entries ---
        if ($n.StartsWith('__RUN_')) {
            $runName = $n.Substring(6)
            $val = $snap[$n]
            if ($val) { Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $runName -Value $val -Force -ErrorAction SilentlyContinue }
            continue
        }
        if ($n -eq '__SPLIT_THRESHOLD') {
            $ctrl = 'HKLM:\SYSTEM\CurrentControlSet\Control'
            $v = $snap[$n]
            if ($v -eq '(absent)' -or $null -eq $v) { Remove-ItemProperty -Path $ctrl -Name 'SvcHostSplitThresholdInKB' -ErrorAction SilentlyContinue }
            else { Set-ItemProperty -Path $ctrl -Name 'SvcHostSplitThresholdInKB' -Value ([int]$v) -Type DWord -Force -ErrorAction SilentlyContinue }
            continue
        }
        if ($n -eq '__WIDGETSPOLICY') {
            $pol = 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh'
            $v = $snap[$n]
            if ($v -eq '(absent)' -or $null -eq $v) { Remove-ItemProperty -Path $pol -Name 'AllowNewsAndInterests' -ErrorAction SilentlyContinue }
            else { Set-ItemProperty -Path $pol -Name 'AllowNewsAndInterests' -Value ([int]$v) -Type DWord -Force -ErrorAction SilentlyContinue }
            continue
        }
        if ($n.StartsWith('__START_')) {
            $base = $n.Substring(8)
            $tk = "HKLM:\SYSTEM\CurrentControlSet\Services\$base"
            if (Test-Path $tk) { Set-ItemProperty -Path $tk -Name 'Start' -Value ([int]$snap[$n]) -Type DWord -Force -ErrorAction SilentlyContinue }
            continue
        }
        if ($n -eq '__PAGEFILE_SETTING') {
            $v = [string]$snap[$n]
            try {
                if ($v -eq '(auto)' -or -not $v) {
                    foreach ($pf in @(Get-WmiObject Win32_PageFileSetting -ErrorAction SilentlyContinue)) { $pf.Delete() | Out-Null }
                } else {
                    foreach ($part in ($v -split ';')) {
                        $f = $part -split '\|'
                        if ($f.Count -eq 3) {
                            Set-WmiInstance -Class Win32_PageFileSetting -Arguments @{ Name = $f[0]; InitialSize = [int]$f[1]; MaximumSize = [int]$f[2] } -ErrorAction SilentlyContinue | Out-Null
                        }
                    }
                }
            } catch {}
            continue
        }
        if ($n -eq '__PAGEFILE_AUTO') {
            try {
                $csPf = Get-CimInstance Win32_ComputerSystem
                Set-CimInstance -InputObject $csPf -Property @{ AutomaticManagedPagefile = ([string]$snap[$n] -eq 'True') } -ErrorAction Stop
            } catch {}
            continue
        }

        # --- ordinary service ---
        $mode = $snap[$n]
        if (-not $mode) { $mode = $fallback[$n] }
        if (-not $mode) { continue }
        $mode = $modeMap[[string]$mode]
        if (-not $mode) { continue }
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        Set-Service -Name $n -StartupType $mode -ErrorAction SilentlyContinue
        if ($mode -eq 'Automatic' -and $svc.Status -ne 'Running') { Start-Service -Name $n -ErrorAction SilentlyContinue }
    }

    # telemetry
    Set-Service -Name 'DiagTrack' -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service -Name 'DiagTrack' -ErrorAction SilentlyContinue
    Set-Service -Name 'dmwappushservice' -StartupType Manual -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'EnableActivityFeed' -ErrorAction SilentlyContinue

    # Run key + Defender exclusion
    Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'ReviOS_FixMMAgent' -ErrorAction SilentlyContinue
    try { if ((Get-MpPreference).ExclusionPath -contains $PermDir) { Remove-MpPreference -ExclusionPath $PermDir -ErrorAction SilentlyContinue } } catch {}

    # CAM settings files back to their pre-CamSetup snapshots
    $camBak = Join-Path $PermDir 'cam-backup'
    if (Test-Path -LiteralPath $camBak) {
        $camMap = @{
            'app-settings.json'    = (Join-Path $env:APPDATA 'NZXT CAM\settings.json')
            'user-settings.json'   = (Join-Path $env:APPDATA 'NZXT CAM\DataStorage\latest\user\settings.json')
            'known-good-user.json' = (Join-Path $env:APPDATA 'NZXT CAM\DataStorage\.last-known-good\user\settings.json')
        }
        foreach ($k in @($camMap.Keys)) {
            $b = Join-Path $camBak $k
            $dst = $camMap[$k]
            if ((Test-Path -LiteralPath $b) -and (Test-Path -LiteralPath (Split-Path $dst -Parent))) {
                Copy-Item -LiteralPath $b -Destination $dst -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # CAM autostart back
    $camRun = $null
    if (Test-Path $SvcSnap) { try { $camRun = (Get-Content $SvcSnap -Raw | ConvertFrom-Json).__CAM_RUN } catch {} }
    if ($camRun) {
        Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'NZXT.CAM' -Value $camRun -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $Desktop -Force -ErrorAction SilentlyContinue

    # scripts (keep watchdog.log + service snapshot out of the way: they go too)
    Remove-Item -LiteralPath $PermDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath 'C:\Windows\Temp\EmptyStandby.ps1' -Force -ErrorAction SilentlyContinue

    Write-Host 'Reverted. Memory compression is left ON (Disable-MMAgent -MemoryCompression if you want it off).' -ForegroundColor Green
    Write-Host 'Note: SysMain/WSearch/Spooler/Bluetooth take effect after reboot if they were running.' -ForegroundColor DarkGray
}

# --------------------------------------------------------------------- dispatch
$needsAdmin = $Mode -in 'Apply', 'Revert', 'CamSetup', 'PurgeNow', 'Reduce', 'Repair'
if ($needsAdmin -and -not (Test-IsAdmin)) { Restart-Elevated }

if ($OutFile) {
    try { Start-Transcript -Path $OutFile -Force | Out-Null } catch {}
}

try {
    switch ($Mode) {
        'Apply'    { Invoke-Apply }
        'Status'   { Invoke-Status }
        'PurgeNow' { & powershell -NoProfile -ExecutionPolicy Bypass -File $PermScript -ForcePurge }
        'CamSetup' { if (Invoke-CamSetup) { Write-Host 'Done.' -ForegroundColor Green } }
        'Reduce'   { Invoke-Reduce }
        'Repair'   {
            if (Test-Path -LiteralPath $RepairScript) {
                & powershell -NoProfile -ExecutionPolicy Bypass -File $RepairScript -Force
            } else { Write-Host 'Repair.ps1 not deployed yet - run .\ramfix.ps1 -Mode Reduce first.' -ForegroundColor Yellow }
        }
        'Revert'   { Invoke-Revert }
    }
} catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    if ($_.ScriptStackTrace) { Write-Host $_.ScriptStackTrace -ForegroundColor DarkRed }
    exit 1
} finally {
    if ($OutFile) { try { Stop-Transcript | Out-Null } catch {} }
}
