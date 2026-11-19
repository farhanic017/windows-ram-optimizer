#!/usr/bin/env node
const { program } = require('commander');
const chalk = require('chalk');
const ora = require('ora');
const pkg = require('../package.json');
const { Core, getRAM, getMMA, isAdmin } = require('../src/optimizer');

program
  .name('ramfix')
  .description('windows-ram-optimizer — 1.6GB idle, debloat, compression & watchdog (ReviOS-grade)')
  .version(pkg.version)
  .option('--gui', 'launch one-click GUI')
  .option('--aggressive', 'also set extra services to Manual (Spooler/BT etc)')
  .option('--no-telemetry', 'skip telemetry/spyware removal')
  .option('--no-cam', 'skip CAM 50MB overlay setup')
  .option('--revert', 'undo everything: services, telemetry, watchdog task, Run key, Defender exclusion')
  .option('--status', 'show RAM/MMA/task status only');

program.parse(process.argv);
const opts = program.opts();

async function main() {
  if (opts.gui) return launchGui();
  if (opts.status) return showStatus();
  if (opts.revert) return doRevert();

  if (!isAdmin()) {
    console.log(chalk.red('✗ Run as Administrator (right-click → Run as admin).'));
    console.log(chalk.gray('  npx windows-ram-optimizer  needs admin for services/registry.'));
    process.exit(1);
  }

  console.log(chalk.cyan.bold('\n⚡ windows-ram-optimizer  (ReviOS 1.6GB profile)\n'));
  const before = getRAM();
  console.log(chalk.gray(`Before: ${before.used}MB / ${before.total}MB (${before.usedGB}GB)`));

  const spinner = ora('Fixing MemoryCompression + RAM watchdog (EmptyStandby every 2min)...').start();
  try {
    const res = Core.runAll({ aggressive: !!opts.aggressive, telemetry: opts.telemetry, camOverlay: opts.cam });
    spinner.succeed('Done');
    console.log(chalk.green(`After:  ${res.ramAfter.used}MB / ${res.ramAfter.total}MB (${res.ramAfter.usedGB}GB)  saved ${(before.used - res.ramAfter.used)}MB`));
    console.log(chalk.gray(`MMA: MemoryCompression=${res.mma.MemoryCompression} PageCombining=${res.mma.PageCombining}`));
    console.log(chalk.gray(`Task: ReviOS-EmptyStandby → Logon + every 2min (silent wscript launcher, no console window)`));
    console.log(chalk.gray(`CAM:  50MB overlay → Desktop\\CAM Overlay 50MB.lnk (on-demand)`));
    console.log(chalk.yellow('\n✔ Permanent — survives reboot (ProgramData + Logon trigger + HKLM Run). Reboot to lock 1.6GB.'));
    console.log(chalk.gray(`  Revert: npx windows-ram-optimizer --revert`));
  } catch (e) {
    spinner.fail(chalk.red(e.message));
    process.exit(1);
  }
}

function showStatus() {
  const r = getRAM(); const m = getMMA();
  console.log(chalk.cyan(`RAM: ${r.used}MB / ${r.total}MB (${r.usedGB}GB)`));
  console.log(chalk.gray(`MMA: ${JSON.stringify(m)}`));
  console.log(chalk.gray(`Admin: ${isAdmin() ? 'yes' : 'no'}`));
  try {
    const { execSync } = require('child_process');
    console.log(execSync('powershell -NoProfile -Command "Get-ScheduledTaskInfo -TaskName ReviOS-EmptyStandby | Format-List LastRunTime,NextRunTime,LastTaskResult"', { encoding: 'utf8' }));
  } catch { console.log(chalk.gray('Task: ReviOS-EmptyStandby not registered yet (run without --status first).')); }
}
function doRevert() {
  if (!isAdmin()) { console.log(chalk.red('✗ Run as Administrator (right-click → Run as admin).')); process.exit(1); }
  const spinner = ora('Reverting...').start();
  try {
    const d = Core.revert();
    spinner.succeed('Reverted');
    console.log(chalk.gray(`  tasks removed:     ${d.tasks.length ? d.tasks.join(', ') : 'none'}`));
    console.log(chalk.gray(`  services restored: ${d.services.length}`));
    console.log(chalk.gray(`  HKLM Run key:      ${d.runKey ? 'removed' : 'unchanged'}`));
    console.log(chalk.gray(`  startup .bak:      ${d.startup} moved back`));
    console.log(chalk.green('\n✔ Done. Memory compression is left ON.'));
  } catch (e) {
    spinner.fail(chalk.red(e.message));
    process.exit(1);
  }
}
function launchGui() {
  const path = require('path');
  const { spawn } = require('child_process');
  const gui = path.join(__dirname, '..', 'src', 'gui', 'server.js');
  // process.execPath (not "node") so this also works when node is only on PATH via npx
  const child = spawn(process.execPath, [gui], { stdio: 'inherit' });
  child.on('exit', (code, signal) => process.exit(signal ? 1 : (code || 0)));
}

main();
