# ⚡ Windows RAM Optimizer — 1.6GB Idle RAM for 8GB PCs

> **4304MB → 1569MB** on Windows 11 26200 (8GB). ReviOS-grade, one-click, permanent.

[![npm version](https://img.shields.io/npm/v/windows-ram-optimizer?color=cb3837&cacheSeconds=3600)](https://www.npmjs.com/package/windows-ram-optimizer)
[![GitHub release](https://img.shields.io/github/v/release/farhanic017/windows-ram-optimizer?color=0b7285)](https://github.com/farhanic017/windows-ram-optimizer/releases)
[![License: GPL v3](https://img.shields.io/badge/License-GPLv3-blue.svg)](LICENSE)
[![Windows 11](https://img.shields.io/badge/Windows-11-0078D6?logo=windows)](https://github.com/farhanic017/windows-ram-optimizer)
[![Node >=18](https://img.shields.io/badge/Node-%3E%3D18-339933?logo=node.js)](package.json)

**Tired of 3GB+ idle on 8GB?** This turns your 8GB Windows 11 into a 1.6GB idle machine — game-ready, without breaking daily use. Live-tuned from a real 3.2GB leak (taskhostw 1.4GB, MemoryCompression off, ReviOS task broken 9/6) back to **1.56GB TaskMgr**.

### ✨ Why trending
- 🧠 **RAM watchdog** every 2min + at boot (fixes `ReviOS-EmptyStandby.ps1` deleted `4294770688` fail)
- 🗜️ **Memory compression** (`Enable-MMAgent`) — saves ~700MB
- 🛡️ **Telemetry/spyware removal** (`DiagTrack`, `dmwappushservice`, `AllowTelemetry 0`)
- 🎮 **NZXT CAM 700MB → 50MB** overlay-only (`--disable-gpu` + trim, Desktop shortcut)
- 🧹 **.bak boot popup fix** (`Startup\*.lnk.bak` → `ProgramData\ReviOS\StartupBackup`)
- 🔒 **Permanent** — `C:\ProgramData\ReviOS` (mirrors `System32` + `Temp`), `SYSTEM` task, `HKLM Run`, Defender exclusion, survives reboot & Disk Cleanup
- ♻️ **Fully reversible** — `ramfix --revert`

---

## 🚀 One-click (no terminal needed)

### GUI App (recommended)
```bash
npx windows-ram-optimizer --gui
# or
npm i -g windows-ram-optimizer
ramfix --gui        # same as win-ram-optimizer
```
Opens `http://localhost:8787` → **Fix now — 1.6GB idle (admin)**. Run GUI/terminal as **Administrator** (right-click → Run as admin).

### CLI
```bash
ramfix                 # safe profile
ramfix --aggressive    # also Manual Spooler/BT/Maps
ramfix --status        # RAM / MMA / task
ramfix --revert        # restore WSearch/SysMain
```

### Python (Tkinter)
```bash
python python/optimizer.py --gui
python python/optimizer.py
```

---

## 📊 What it does

| Area | Action | Saved |
|---|---|---|
| **RAM watchdog** | `C:\ProgramData\ReviOS\EmptyStandby.ps1` Boot + every 2min indefinite (`ReviOS-EmptyStandby` SYSTEM) — `EmptyWorkingSet` + `NtSetSystemInformation 80` + `GC` | **~1.2GB** |
| **Memory compression** | `Enable-MMAgent -MemoryCompression/-PageCombining` + `HKLM\Run ReviOS_FixMMAgent` | **~700MB** |
| **Services** | `DSAService/DSAUpdateService/WSearch/CAMService/postgresql-x64-18 → Manual`, `AsusUpdateCheck → Disabled` | **~400MB** |
| **Telemetry** | `DiagTrack/dmwappushservice Disabled`, `AllowTelemetry 0`, `EnableActivityFeed 0` | privacy |
| **CAM 50MB** | Kill `NZXT CAM.exe` UI, keep `CAMService` (10MB) + `cam_helper`; `CAM-Overlay.ps1 --disable-gpu` + trim; block `HKCU Run NZXT.CAM` | **650→50MB** |
| **Pools** | `SystemCacheLimit 1GB`, Defender exclusion | stability |

## 🔄 After reboot

Idle `~1.56-1.75GB` (with `OpenCode`/`MiniMax`), `~1.6GB` clean. Task runs at `Boot` + every `2min` — stays. Use `Desktop\CAM Overlay 50MB.lnk` for overlay on demand.

## 🔙 Revert

```powershell
ramfix --revert
# or
Set-Service WSearch,SysMain -StartupType Automatic; Start-Service WSearch,SysMain
Disable-ScheduledTask ReviOS-EmptyStandby
```

## 🏷️ Tags

`windows11` `ram` `memory` `optimizer` `debloat` `revios` `idle-ram` `memory-compression` `watchdog` `telemetry-removal` `privacy` `performance` `gaming-optimization` `nzxt-cam` `8gb-ram` `low-ram` `windows-optimization`

## 👤 Author

**Farhan Dhrubo** — [@farhanic017](https://github.com/farhanic017)

Copyright (c) 2026 Farhan Dhrubo (GPL-3.0-or-later). Live-tuned on 8GB Win11 Education 26200.

## 🤝 Contribute

`npm install && npm test` — PRs welcome! `npx windows-ram-optimizer --status` to debug.

## ⭐ Star to trend

If this saved your RAM, **star ⭐ + share** — helps 8GB users find it fast.

---

> *Tested 2026-09-07: `taskhostw 1441MB` leak killed, `Standby 3.3GB` purged, `MMA True` → `4148MB→1569MB`.*

