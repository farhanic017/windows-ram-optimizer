# Repair.ps1 - self-heal for the windows-ram-optimizer profile (persistence across Windows Update)
#
# Windows Update (and app updaters) quietly reset service start modes, re-add startup entries
# and sometimes drop scheduled tasks. This script re-applies everything -Mode Reduce applied,
# reading the desired state from targets.json (written by Reduce), at most once per boot.
#
# Runners:
#   * ReviOS-LogonRepair  (SYSTEM, at every logon - session 0, never shows a window)
#   * ReviOS-EmptyStandby (every 2 min, first cycle after boot - covers a missing logon task)
#
# Cheap checks (HKCU startup) run on every invocation; the heavy sweep runs once per boot.
param(
    [switch]$Force,     # ignore the once-per-boot marker
    [switch]$Quiet
)
$ErrorActionPreference = 'SilentlyContinue'
$PermDir   = 'C:\ProgramData\ReviOS'
$TargetsF  = Join-Path $PermDir 'targets.json'
$Marker    = Join-Path $PermDir 'repair-boot.marker'
$LogF      = Join-Path $PermDir 'watchdog.log'
$repairs   = New-Object System.Collections.Generic.List[string]
$problems  = New-Object System.Collections.Generic.List[string]

function WLog([string]$m) {
    $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
    try { Add-Content -LiteralPath $script:LogF -Value $line -Encoding UTF8 } catch {}
    if (-not $script:Quiet) { Write-Host $line }
}

# ------------------------------------------------------------------ once-per-boot gate
$boot = $null
try { $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToFileTimeUtc().ToString() } catch {}
$heavy = $true
if ($boot -and -not $Force) {
    $done = $null
    try { if (Test-Path -LiteralPath $Marker) { $done = (Get-Content -LiteralPath $Marker -Raw).Trim() } } catch {}
    if ($done -eq $boot) { $heavy = $false }
}

$targets = $null
if (Test-Path -LiteralPath $TargetsF) {
    try { $targets = Get-Content -LiteralPath $TargetsF -Raw | ConvertFrom-Json } catch { $problems += "targets.json unreadable" }
}
if (-not $targets) {
    if ($heavy) { WLog 'repair: targets.json missing - re-run  ramfix.ps1 -Mode Reduce  to regenerate' }
    # even without targets, keep the startup cleanup running (patterns are built in)
    $targets = [pscustomobject]@{ runAbsentPatterns = @('OneDrive*', 'MicrosoftEdgeAutoLaunch*', 'NZXT.CAM', 'NZXT CAM') }
    if (-not $heavy) { return }
}

# ================================================================== HEAVY PASS (once/boot)
if ($heavy) {
    $modeMap = @{ 'Auto' = 'Automatic'; 'Automatic' = 'Automatic'; 'Manual' = 'Manual'; 'Disabled' = 'Disabled' }
    $startMap = @{ 'Automatic' = 2; 'Manual' = 3; 'Disabled' = 4 }

    # ---- 1) service start modes (Windows Update / app updaters reset these)
    if ($targets.PSObject.Properties.Name -contains 'services') {
        foreach ($p in $targets.services.PSObject.Properties) {
            $name = $p.Name
            $want = $modeMap[[string]$p.Value]
            if (-not $want) { continue }
            $q = Get-CimInstance Win32_Service -Filter "Name='$name'" -ErrorAction SilentlyContinue
            if (-not $q) { continue }                    # service gone (feature removed): nothing to repair
            $cur = $modeMap[[string]$q.StartMode]
            if ($cur -eq $want) { continue }
            $ok = $false
            try { Set-Service -Name $name -StartupType $want -ErrorAction Stop; $ok = $true } catch {}
            if (-not $ok) {                               # protected DACL -> registry fallback
                try {
                    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\$name" -Name 'Start' `
                                     -Value ([int]$startMap[$want]) -Type DWord -ErrorAction Stop
                    $ok = $true
                } catch {}
            }
            if ($ok) {
                $repairs.Add("$name $($q.StartMode)->$want")
                if ($want -eq 'Disabled') { try { Stop-Service -Name $name -Force -ErrorAction Stop } catch {} }
            } else { $problems.Add("$name (cannot set $want)") }
        }
    }

    # ---- 2) per-user service templates (registry Start; instances get a fresh suffix each boot)
    if ($targets.PSObject.Properties.Name -contains 'registryStart') {
        foreach ($p in $targets.registryStart.PSObject.Properties) {
            $tk = "HKLM:\SYSTEM\CurrentControlSet\Services\$($p.Name)"
            if (-not (Test-Path -LiteralPath $tk)) { continue }
            $cur = $null
            try { $cur = (Get-ItemProperty -LiteralPath $tk -Name 'Start' -ErrorAction Stop).Start } catch {}
            if ($null -eq $cur -or [int]$cur -eq [int]$p.Value) { continue }
            try {
                Set-ItemProperty -LiteralPath $tk -Name 'Start' -Value ([int]$p.Value) -Type DWord -ErrorAction Stop
                $repairs.Add("$($p.Name) Start $cur->$([int]$p.Value)")
            } catch { $problems.Add("$($p.Name) (Start not set)") }
        }
    }

    # ---- 3) machine policies
    if ($targets.PSObject.Properties.Name -contains 'policies') {
        foreach ($p in $targets.policies.PSObject.Properties) {
            $parts = $p.Name -split '::'
            if ($parts.Count -ne 2) { continue }
            $path = $parts[0]; $name = $parts[1]; $want = [int]$p.Value
            try {
                $cur = (Get-ItemProperty -LiteralPath $path -Name $name -ErrorAction Stop).$name
            } catch { $cur = $null }
            if ($null -ne $cur -and [int]$cur -eq $want) { continue }
            try {
                if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force -ErrorAction Stop | Out-Null }
                Set-ItemProperty -LiteralPath $path -Name $name -Value $want -Type DWord -Force -ErrorAction Stop
                $repairs.Add("$name -> $want")
            } catch { $problems.Add("$name (policy)") }
        }
    }

    # ---- 4) svchost grouping threshold
    if ($targets.PSObject.Properties.Name -contains 'svcHostSplitThresholdInKB') {
        $want = [int]$targets.svcHostSplitThresholdInKB
        $cur = $null
        try { $cur = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'SvcHostSplitThresholdInKB' -ErrorAction Stop).SvcHostSplitThresholdInKB } catch {}
        if ($null -eq $cur -or [int]$cur -ne $want) {
            try {
                Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'SvcHostSplitThresholdInKB' -Value $want -Type DWord -Force -ErrorAction Stop
                $repairs.Add("SvcHostSplitThresholdInKB $cur->$want (reboot to group svchost again)")
            } catch { $problems.Add('SvcHostSplitThresholdInKB') }
        }
    }

    # ---- 5) page file (the 16GB RAM extender on C:)
    if ($targets.PSObject.Properties.Name -contains 'pagefile') {
        try {
            $pf = $targets.pagefile
            $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
            if ([bool]$pf.auto -ne [bool]$cs.AutomaticManagedPagefile) {
                Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = [bool]$pf.auto } -ErrorAction Stop
                $repairs.Add("AutomaticManagedPagefile -> $($pf.auto)")
            }
            if (-not [bool]$pf.auto) {
                $cur = @((Get-CimInstance Win32_PageFileSetting -ErrorAction Stop) | Where-Object { $_.Name -eq $pf.name })
                if ($cur.Count -eq 1 -and ($cur[0].InitialSize -ne [int]$pf.initial -or $cur[0].MaximumSize -ne [int]$pf.max)) {
                    $w = @(Get-WmiObject -Class Win32_PageFileSetting -ErrorAction Stop | Where-Object { $_.Name -eq $pf.name })
                    if ($w.Count -gt 0) {
                        $w[0].InitialSize = [int]$pf.initial; $w[0].MaximumSize = [int]$pf.max; [void]$w[0].Put()
                        $repairs.Add("pagefile $([int]$pf.initial)/$([int]$pf.max)MB (reboot to activate)")
                    }
                }
            }
        } catch { $problems.Add('pagefile') }
    }

    # ---- 6) memory compression (the update can flip MMAgent back off)
    if ($targets.PSObject.Properties.Name -contains 'mma') {
        $mm = $null
        try { $mm = Get-MMAgent -ErrorAction Stop } catch {}
        foreach ($p in $targets.mma.PSObject.Properties) {
            if (-not [bool]$p.Value) { continue }
            if (-not $mm) { continue }
            if ($p.Name -eq 'MemoryCompression' -and -not $mm.MemoryCompression) {
                try { Enable-MMAgent -MemoryCompression -ErrorAction Stop | Out-Null; $repairs.Add('MemoryCompression on') } catch {}
            }
            if ($p.Name -eq 'PageCombining' -and -not $mm.PageCombining) {
                try { Enable-MMAgent -PageCombining -ErrorAction Stop | Out-Null; $repairs.Add('PageCombining on') } catch {}
            }
        }
    }

    # ---- 7) Defender exclusion (so Windows does not quarantine the watchdog)
    if ($targets.PSObject.Properties.Name -contains 'defenderExclusion') {
        $ex = [string]$targets.defenderExclusion
        try {
            if ($ex -and -not ((Get-MpPreference -ErrorAction Stop).ExclusionPath -contains $ex)) {
                Add-MpPreference -ExclusionPath $ex -ErrorAction Stop
                $repairs.Add("Defender exclusion restored: $ex")
            }
        } catch {}
    }

    # ---- 8) HKLM logon entry (FixMMAgent / hidden wrapper)
    if ($targets.PSObject.Properties.Name -contains 'hkmlRun') {
        $rk = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
        foreach ($p in $targets.hkmlRun.PSObject.Properties) {
            $cur = $null
            try { $cur = (Get-ItemProperty -Path $rk -Name $p.Name -ErrorAction Stop).($p.Name) } catch {}
            if ([string]$cur -eq [string]$p.Value) { continue }
            try {
                if (-not (Test-Path -Path $rk)) { New-Item -Path $rk -Force -ErrorAction Stop | Out-Null }
                Set-ItemProperty -Path $rk -Name $p.Name -Value ([string]$p.Value) -Force -ErrorAction Stop
                $repairs.Add("HKLM Run $($p.Name) restored")
            } catch { $problems.Add("HKLM Run $($p.Name)") }
        }
    }

    # ---- 9) watchdog task self-heal (an update can disable or orphan it)
    $actionOk = $false
    $wt = Get-ScheduledTask -TaskName 'ReviOS-EmptyStandby' -ErrorAction SilentlyContinue
    if ($wt) {
        $a = @($wt.Actions) | Select-Object -First 1
        $file = $null
        if ($a) {
            if ($a.Execute -match 'wscript|cscript') { if ($a.Arguments -match '"([^"]+\.vbs)"') { $file = $Matches[1] } }
            elseif ($a.Arguments -match '"([^"]+\.ps1)"') { $file = $Matches[1] }
            elseif ($a.Arguments -match '(\S+\.ps1)')     { $file = $Matches[1] }
        }
        $actionOk = ($file -and (Test-Path -LiteralPath $file))
        if (-not $actionOk) { $problems += "watchdog task action broken ($file)" }
        if ($wt.State -eq 'Disabled') {
            try { Enable-ScheduledTask -TaskName 'ReviOS-EmptyStandby' | Out-Null; $repairs.Add('watchdog task re-enabled') } catch {}
        }
    } else { $problems.Add('watchdog task missing') }

    if (-not $actionOk) {
        # (re)create with the stock action - preserves nothing user-custom, only used when broken/absent
        try {
            $ps = Join-Path $PermDir 'EmptyStandby.ps1'
            $action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
                          -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ps`""
            $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
            $tLogon  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
            $tRepeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 2)
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden `
                              -ExecutionTimeLimit (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew `
                              -StartWhenAvailable -Compatibility Win8
            Register-ScheduledTask -TaskName 'ReviOS-EmptyStandby' -Action $action -Trigger $tLogon,$tRepeat `
                -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
            Enable-ScheduledTask -TaskName 'ReviOS-EmptyStandby' -ErrorAction Stop | Out-Null
            if (Get-ScheduledTask -TaskName 'ReviOS-EmptyStandby' -ErrorAction SilentlyContinue) {
                $repairs.Add('watchdog task (re)registered')
            } else { $problems.Add('watchdog task: created but not found') }
        } catch { $problems.Add('watchdog task register: ' + $_.Exception.Message) }
    }

    # ---- 10) logon repair task self-heal (SYSTEM, no UAC, session 0 - never a window)
    $rt = Get-ScheduledTask -TaskName 'ReviOS-LogonRepair' -ErrorAction SilentlyContinue
    if (-not $rt -or $rt.State -eq 'Disabled') {
        try {
            $rp   = Join-Path $PermDir 'Repair.ps1'
            $ra   = New-ScheduledTaskAction -Execute 'powershell.exe' `
                        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$rp`""
            $rtr  = New-ScheduledTaskTrigger -AtLogOn
            $rpr  = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            $rst  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden `
                        -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -MultipleInstances IgnoreNew `
                        -StartWhenAvailable -Compatibility Win8
            Register-ScheduledTask -TaskName 'ReviOS-LogonRepair' -Action $ra -Trigger $rtr `
                -Principal $rpr -Settings $rst -Force -ErrorAction Stop | Out-Null
            if (Get-ScheduledTask -TaskName 'ReviOS-LogonRepair' -ErrorAction SilentlyContinue) {
                $repairs.Add('ReviOS-LogonRepair task (re)registered')
            } else { $problems.Add('ReviOS-LogonRepair: created but not found') }
        } catch { $problems.Add('ReviOS-LogonRepair: ' + $_.Exception.Message) }
    }
}

# ================================================================== LIGHT PASS (every run)
# HKCU startup entries: cheap, and this is the one a SYSTEM logon task cannot reach by HKCU,
# so resolve the interactive user's hive by SID instead.
$runAbsent = @()
if ($targets.PSObject.Properties.Name -contains 'runAbsentPatterns') { $runAbsent = @($targets.runAbsentPatterns) }
if ($runAbsent.Count) {
    $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    try {
        $cu = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
        if ($cu) {
            $who = ($cu -split '\\', 2)[1]
            $sid = (New-Object System.Security.Principal.NTAccount($who)).Translate([System.Security.Principal.SecurityIdentifier]).Value
            $alt = "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Run"
            if (Test-Path -LiteralPath $alt) { $runKey = $alt }
        }
    } catch {}
    if (Test-Path -LiteralPath $runKey) {
        $props = @((Get-ItemProperty -LiteralPath $runKey -ErrorAction SilentlyContinue).PSObject.Properties |
                   Where-Object { $_.Name -notlike 'PS*' })
        foreach ($p in $props) {
            foreach ($pat in $runAbsent) {
                if ($p.Name -like $pat) {
                    try { Remove-ItemProperty -LiteralPath $runKey -Name $p.Name -ErrorAction Stop; $repairs.Add("startup removed: $($p.Name)") } catch {}
                    break
                }
            }
        }
    }
}

# ================================================================== report
if ($repairs.Count -gt 0) { WLog ('repair: ' + ($repairs -join '; ')) }
if ($problems.Count -gt 0) { WLog ('repair-FAILED: ' + ($problems -join '; ')) }
if ($heavy -and $boot) {
    try { [System.IO.File]::WriteAllText($Marker, $boot, (New-Object System.Text.UTF8Encoding($false))) } catch {}
}
