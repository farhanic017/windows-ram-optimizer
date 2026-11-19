#!/usr/bin/env node
'use strict';
/**
 * Smoke test (no framework, no deps) - run by CI as `npm test`.
 *
 * Verifies the editions stay wired up:
 *   - every file the Node/Python editions deploy actually exists
 *   - the JS sources still parse
 *   - the PowerShell edition keeps its mode contract and its safety guards
 *   - no edition re-introduces a VISIBLE console window or a blind trim
 *   - the README's install path needs no Node/Python and no execution-policy change
 */
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const root = path.join(__dirname, '..');
const rel = (p) => path.join(root, p);
const read = (p) => fs.readFileSync(rel(p), 'utf8');

let pass = 0, fail = 0;
function ok(cond, label, extra) {
    if (cond) { pass++; console.log(`  ok    ${label}`); }
    else { fail++; console.error(`  FAIL  ${label}${extra ? ' :: ' + extra : ''}`); }
}

console.log('\n[1/6] required files');
for (const f of [
    'LICENSE', 'README.md', 'package.json',
    'bin/ramfix.js', 'src/optimizer.js', 'src/gui/server.js', 'python/optimizer.py',
    'assets/empty-standby.ps1',
    'ramfix.ps1',
    'ps/EmptyStandby.ps1', 'ps/Repair.ps1', 'ps/CAM-Overlay.ps1', 'ps/FixMMAgent.ps1',
]) ok(fs.existsSync(rel(f)), f);

console.log('\n[2/6] javascript syntax');
for (const f of ['bin/ramfix.js', 'src/optimizer.js', 'src/gui/server.js']) {
    try { execFileSync(process.execPath, ['--check', rel(f)], { stdio: 'pipe' }); ok(true, `${f} parses`); }
    catch (e) { ok(false, `${f} parses`, String(e.stderr || e.message).trim().split('\n')[0]); }
}

console.log('\n[3/6] package.json');
const pkg = JSON.parse(read('package.json'));
ok(pkg.name === 'windows-ram-optimizer', 'name');
ok(pkg.license === 'GPL-3.0-or-later', 'license');
for (const [alias, target] of Object.entries(pkg.bin || {})) {
    ok(fs.existsSync(rel(target)), `bin ${alias} -> ${target}`);
}
for (const f of pkg.files || []) {
    const p = rel(f.replace(/\/$/, ''));
    ok(fs.existsSync(p), `files entry ${f}`);
}
ok((pkg.files || []).includes('assets/'), 'npm package ships assets/ (the fallback watchdog)');
const cli = read('bin/ramfix.js');
ok(cli.includes('.version(pkg.version)'), 'CLI reports package.json version (not a hardcoded one)');

console.log('\n[4/6] PowerShell edition contract');
const ramfix = read('ramfix.ps1');
for (const mode of ['Apply', 'Status', 'PurgeNow', 'CamSetup', 'Reduce', 'Repair', 'Revert']) {
    ok(ramfix.includes(`'${mode}'`), `mode -Mode ${mode}`);
}
ok(ramfix.includes('Join-Path $PSScriptRoot'), 'resolves its ps/ folder relative to the script');
ok(ramfix.includes("New-ScheduledTaskAction -Execute 'wscript.exe'"), 'watchdog task uses the silent wscript action');
ok(!/New-ScheduledTaskAction\s+-Execute\s+["']powershell\.exe["']/.test(ramfix), 'watchdog task is not a bare powershell action');
ok(ramfix.includes('-OutFile "$env:TEMP\\ramfix.ps1"') || ramfix.includes('raw.githubusercontent.com'),
    'ramfix.ps1 can be downloaded on its own (fetches ps/ when missing)');

const watchdog = read('ps/EmptyStandby.ps1');
ok(watchdog.includes('GetAsyncKeyState'), 'drag guard (GetAsyncKeyState)');
ok(watchdog.includes('PurgeMemoryLists'), 'standby purge (NtSetSystemInformation)');
ok(watchdog.includes('Repair.ps1'), 'calls the self-heal once per boot');
ok(watchdog.includes('EmptyWorkingSet'), 'working-set trim');

const repair = read('ps/Repair.ps1');
ok(repair.includes('targets.json'), 'reads targets.json');
ok(repair.includes('ReviOS-LogonRepair'), 'self-heals the SYSTEM logon task');
ok(repair.includes('ReviOS-EmptyStandby'), 'self-heals the watchdog task');
ok(repair.includes('wscript'), 'self-heal re-registers the task with the silent action');

const cam = read('ps/CAM-Overlay.ps1');
ok(cam.includes('CreateNoWindow'), 'starts CAM detached from the console (no stuck terminal)');
ok(cam.includes('--disable-gpu'), 'CAM overlay flags');

console.log('\n[5/6] no edition pops a visible console (the focus-steal / game-to-desktop bug)');
// Windows Terminal is the default host on Win11 and IGNORES -WindowStyle Hidden, so any
// scheduled task or Run entry that executes powershell.exe directly opens a real window.
for (const f of ['src/optimizer.js', 'python/optimizer.py', 'ramfix.ps1', 'ps/Repair.ps1']) {
    const src = read(f);
    ok(!/New-ScheduledTaskAction\s+-Execute\s+["']powershell\.exe["']/.test(src),
        `${f}: no powershell.exe task action`);
    ok(src.includes('wscript'), `${f}: has the silent wscript launcher`);
}
// the legacy fallback watchdog's Add-Type used a backslash-escaped quote, which PowerShell does
// NOT treat as an escape -> Add-Type threw and the trim silently never ran (ignore comment lines)
const asset = read('assets/empty-standby.ps1');
const assetCode = asset.split(/\r?\n/).filter((l) => !l.trim().startsWith('#')).join('\n');
ok(!assetCode.includes('DllImport(\\"'), 'assets/empty-standby.ps1: Add-Type does not use the broken \\" escape');
ok(asset.includes('Dragging()'), 'assets/empty-standby.ps1: has a drag guard');
// both editions must deploy the graphics-safe watchdog when ps/ is present
for (const f of ['src/optimizer.js', 'python/optimizer.py']) {
    const src = read(f);
    ok(/['"]ps['"]\s*[,.]?\s*['"]EmptyStandby\.ps1['"]/.test(src) ||
       src.includes(`'ps', 'EmptyStandby.ps1'`) ||
       src.includes(`"ps" / "EmptyStandby.ps1"`),
        `${f}: prefers ps/EmptyStandby.ps1`);
}

// GUI hardening: localhost-only bind, no CORS wildcard (any site in your browser could
// otherwise POST to :8787 and drive these admin endpoints), and admin-gated mutations.
const gui = read('src/gui/server.js');
ok(gui.includes("'127.0.0.1'"), 'GUI binds to 127.0.0.1 only');
ok(!/setHeader\(\s*['"]Access-Control-Allow-Origin/.test(gui), 'GUI sends no CORS wildcard');
ok(gui.includes('needAdmin'), 'GUI admin-gates its endpoints');
const py = read('python/optimizer.py');
ok(py.includes('elevate('), 'Python edition self-elevates');
ok(py.includes('--revert'), 'Python edition has --revert');

console.log('\n[6/6] README install path (must work on a stock Windows, without AI)');
const readme = read('README.md');
ok(readme.includes('ramfix.ps1'), 'mentions ramfix.ps1');
ok(readme.includes('-Mode Reduce'), 'documents -Mode Reduce');
ok(readme.toLowerCase().includes('self-heal'), 'documents the Windows Update self-heal');
ok(readme.includes('ExecutionPolicy Bypass -File'), 'runs via -ExecutionPolicy Bypass -File (no policy change needed)');
ok(!readme.includes('Set-ExecutionPolicy -Scope Process Bypass -Force\n.\\ramfix.ps1'),
    'no longer requires Set-ExecutionPolicy in the same window');
ok(readme.includes('raw.githubusercontent.com'), 'documents the single-line download');
ok(readme.includes('no Node') || readme.includes('No Node'), 'states that Node is not required');
ok(readme.toLowerCase().includes('running scripts is disabled') ||
   readme.includes('Manual install not working?'), 'documents the common manual-install failures');
ok(!readme.includes('yourname/') && !read('src/gui/server.js').includes('yourname/'), 'no placeholder repo links');

console.log(`\n${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
