#!/usr/bin/env node
'use strict';
/**
 * Smoke test (no framework, no deps) - run by CI as `npm test`.
 *
 * Verifies the two editions stay wired up:
 *   - every file the Node/Python editions deploy actually exists
 *   - the JS sources still parse
 *   - the PowerShell edition keeps its mode contract and its safety guards
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

console.log('\n[1/5] required files');
for (const f of [
    'LICENSE', 'README.md', 'package.json',
    'bin/ramfix.js', 'src/optimizer.js', 'src/gui/server.js', 'python/optimizer.py',
    'assets/empty-standby.ps1',
    'ramfix.ps1',
    'ps/EmptyStandby.ps1', 'ps/Repair.ps1', 'ps/CAM-Overlay.ps1', 'ps/FixMMAgent.ps1',
]) ok(fs.existsSync(rel(f)), f);

console.log('\n[2/5] javascript syntax');
for (const f of ['bin/ramfix.js', 'src/optimizer.js', 'src/gui/server.js']) {
    try { execFileSync(process.execPath, ['--check', rel(f)], { stdio: 'pipe' }); ok(true, `${f} parses`); }
    catch (e) { ok(false, `${f} parses`, String(e.stderr || e.message).trim().split('\n')[0]); }
}

console.log('\n[3/5] package.json');
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

console.log('\n[4/5] PowerShell edition contract');
const ramfix = read('ramfix.ps1');
for (const mode of ['Apply', 'Status', 'PurgeNow', 'CamSetup', 'Reduce', 'Repair', 'Revert']) {
    ok(ramfix.includes(`'${mode}'`), `mode -Mode ${mode}`);
}
ok(ramfix.includes('Join-Path $PSScriptRoot'), 'resolves its ps/ folder relative to the script');

const watchdog = read('ps/EmptyStandby.ps1');
ok(watchdog.includes('GetAsyncKeyState'), 'drag guard (GetAsyncKeyState)');
ok(watchdog.includes('PurgeMemoryLists'), 'standby purge (NtSetSystemInformation)');
ok(watchdog.includes('Repair.ps1'), 'calls the self-heal once per boot');
ok(watchdog.includes('EmptyWorkingSet'), 'working-set trim');

const repair = read('ps/Repair.ps1');
ok(repair.includes('targets.json'), 'reads targets.json');
ok(repair.includes('ReviOS-LogonRepair'), 'self-heals the SYSTEM logon task');
ok(repair.includes('ReviOS-EmptyStandby'), 'self-heals the watchdog task');

const cam = read('ps/CAM-Overlay.ps1');
ok(cam.includes('CreateNoWindow'), 'starts CAM detached from the console (no stuck terminal)');
ok(cam.includes('--disable-gpu'), 'CAM overlay flags');

console.log('\n[5/5] README documents the PowerShell edition');
const readme = read('README.md');
ok(readme.includes('ramfix.ps1'), 'mentions ramfix.ps1');
ok(readme.includes('-Mode Reduce'), 'documents -Mode Reduce');
ok(readme.toLowerCase().includes('self-heal'), 'documents the Windows Update self-heal');

console.log(`\n${pass} passed, ${fail} failed\n`);
process.exit(fail ? 1 : 0);
