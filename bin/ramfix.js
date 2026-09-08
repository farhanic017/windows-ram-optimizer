#!/usr/bin/env node
const { program } = require('commander');
const chalk = require('chalk');
const ora = require('ora');
const inquirer = require('inquirer');
const { Core, getRAM, getMMA, isAdmin } = require('../src/optimizer');

program
  .name('ramfix')
  .description('win-ram-optimizer — 1.6GB idle, debloat, compression & watchdog (ReviOS-grade)')
  .version('1.0.0')
  .option('--gui', 'launch one-click GUI')
  .option('--aggressive', 'also set extra services to Manual (Spooler/BT etc)')
  .option('--no-telemetry', 'skip telemetry/spyware removal')
  .option('--no-cam', 'skip CAM 50MB overlay setup')
  .option('--revert', 'revert WSearch/SysMain/task to defaults')
  .option('--status', 'show RAM/MMA/task status only');

program.parse(process.argv);
const opts = program.opts();

async function main() {
  if (opts.gui) return launchGui();
  if (opts.status) return showStatus();
  if (opts.revert) return doRevert();

  if (!isAdmin()) {
    console.log(chalk.red('✗ Run as Administrator (right-click → Run as admin).'));
    console.log(chalk.gray('  npx win-ram-optimizer  needs admin for services/registry.'));
    process.exit(1);
  }

  console.log(chalk.cyan.bold('\n⚡ win-ram-optimizer  (ReviOS 1.6GB profile)\n'));
  const before = getRAM();
  console.log(chalk.gray(`Before: ${before.used}MB / ${before.total}MB (${before.usedGB}GB)`));

  const spinner = ora('Fixing MemoryCompression + RAM watchdog (EmptyStandby every 2min)...').start();
  try {
    const res = Core.runAll({ aggressive: !!opts.aggressive, telemetry: opts.telemetry, camOverlay: opts.cam });
    spinner.succeed('Done');
    console.log(chalk.green(`After:  ${res.ramAfter.used}MB / ${res.ramAfter.total}MB (${res.ramAfter.usedGB}GB)  saved ${(before.used - res.ramAfter.used)}MB`));
    console.log(chalk.gray(`MMA: MemoryCompression=${res.mma.MemoryCompression} PageCombining=${res.mma.PageCombining}`));
    console.log(chalk.gray(`Task: ReviOS-EmptyStandby → Boot + every 2min (C:\\ProgramData\\ReviOS\\EmptyStandby.ps1)`));
    console.log(chalk.gray(`CAM: 50MB overlay → Desktop\\CAM Overlay 50MB.lnk (on-demand)`));
    console.log(chalk.yellow('\n✔ Permanent — survives reboot (ProgramData + Boot trigger + HKLM Run). Reboot to lock 1.6GB.'));
    console.log(chalk.gray('  Revert: npx win-ram-optimizer --revert'));
  } catch (e) {
    spinner.fail(chalk.red(e.message));
    process.exit(1);
  }
}

function showStatus() {
  const r=getRAM(); const m=getMMA();
  console.log(chalk.cyan(`RAM: ${r.used}MB / ${r.total}MB (${r.usedGB}GB)`));
  console.log(chalk.gray(`MMA: ${JSON.stringify(m)}`));
  try { const {execSync}=require('child_process'); console.log(execSync('powershell -Command "Get-ScheduledTaskInfo -TaskName ReviOS-EmptyStandby | Format-List LastRunTime,NextRunTime,LastTaskResult"',{encoding:'utf8'})); } catch {}
}
function doRevert() {
  if (!isAdmin()) { console.log(chalk.red('Admin required')); process.exit(1); }
  Core.revert(); console.log(chalk.green('Reverted WSearch/SysMain/task.'));
}
function launchGui() {
  const path=require('path'); const {spawn}=require('child_process');
  const gui=path.join(__dirname,'..','src','gui','server.js');
  // simple: open GUI server which serves HTML and triggers same Core
  spawn('node',[gui],{stdio:'inherit', detached:false});
}

main();
