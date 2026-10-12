# CAM-Overlay.ps1 — NZXT CAM in 50MB overlay-only mode (repo parity, from src/optimizer.js)
# Blocks NZXT's heavy UI autostart, restarts CAM with GPU acceleration off, trims its working set.
$cam = 'C:\Program Files\NZXT CAM\NZXT CAM.exe'
if (-not (Test-Path $cam)) { Write-Host 'CAM not found'; exit }

# NZXT re-registers its own login item while startupCAM is on — only our overlay entry may survive
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
foreach ($n in 'NZXT.CAM', 'NZXT CAM') {
    try { Remove-ItemProperty -Path $runKey -Name $n -ErrorAction Stop } catch {}
}

# restart so the --disable-gpu flags are guaranteed to apply to the new instance
Get-Process -Name 'NZXT CAM', 'cam_helper' -ErrorAction SilentlyContinue | ForEach-Object {
    try { $_.Kill(); [void]$_.WaitForExit(5000) } catch {}
}
Start-Sleep 1

# start CAM detached from this console: a GUI process started from powershell INHERITS the console,
# cam_helper then logs into it and keeps the window alive forever (that is the stuck terminal bug).
# CreateNoWindow -> CREATE_NO_WINDOW: no console to inherit, so ours closes when this script ends.
try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = $cam
    $psi.Arguments              = '--disable-gpu --disable-hardware-acceleration --in-process-gpu --startup'
    $psi.WorkingDirectory       = 'C:\Program Files\NZXT CAM'
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    [void][System.Diagnostics.Process]::Start($psi)
} catch {
    Start-Process -FilePath $cam -ArgumentList '--disable-gpu --disable-hardware-acceleration --in-process-gpu --startup' -WindowStyle Minimized
}
Start-Sleep 8

try {
    Add-Type 'using System; using System.Runtime.InteropServices; public class T { [DllImport("psapi.dll")] public static extern bool EmptyWorkingSet(IntPtr h); }'
    Get-Process 'NZXT CAM', 'cam_helper' -ErrorAction SilentlyContinue | ForEach-Object { try { [T]::EmptyWorkingSet($_.Handle) | Out-Null } catch {} }
} catch {}

Get-Process 'NZXT CAM', 'cam_helper' -ErrorAction SilentlyContinue |
    Select-Object Name, @{ N = 'WS_MB'; E = { [math]::Round($_.WorkingSet64 / 1MB, 1) } } |
    Format-Table -AutoSize
