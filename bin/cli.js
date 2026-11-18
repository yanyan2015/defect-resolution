#!/usr/bin/env node
/**
 * defect-resolution —— Claude Code skill 安装器（npm bin 入口）。
 *
 * 用法：
 *   npx @yanyan2015/defect-resolution install    # 把 skill 装进 ~/.claude/skills/defect-resolution
 *   npx @yanyan2015/defect-resolution uninstall  # 卸载
 *   npx @yanyan2015/defect-resolution --help     # 帮助
 *
 * 设计（对齐 @colbymchenry/codegraph 的模式）：
 *   npm i -g @yanyan2015/defect-resolution 装包 → defect-resolution install 装进 agent。
 *   npx 则一步到位（临时下载 + 运行）。
 *
 * 只做文件复制，不联网、不执行仓库内容、不改 PATH。
 * skill 运行时依赖 git/bash，与 Node 无关 —— 这里只是搬运工。
 */
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');

const SKILL_NAME = 'defect-resolution';
// 包根（package.json 所在目录）；npx / 全局安装 / 本地 node bin/cli.js 三种方式都成立
const PKG_ROOT = path.resolve(__dirname, '..');
const SKILL_DIR = path.join(os.homedir(), '.claude', 'skills', SKILL_NAME);

// 安装的文件清单（与 install.ps1 保持一致）
const ITEMS = [
  'SKILL.md',
  'scripts',
  'references',
  '.claude-plugin',
  'LICENSE',
  'README.md',
];

function log(msg) { process.stdout.write(msg + '\n'); }
function ok(msg) { log(`  \x1b[32m✓\x1b[0m ${msg}`); }
function warn(msg) { log(`  \x1b[33m!\x1b[0m ${msg}`); }
function die(msg) {
  process.stderr.write(`ERROR: ${msg}\n`);
  process.exit(1);
}

function rmrf(p) {
  fs.rmSync(p, { recursive: true, force: true });
}

function copyItem(name) {
  const src = path.join(PKG_ROOT, name);
  if (!fs.existsSync(src)) {
    warn(`跳过（包内不存在）：${name}`);
    return;
  }
  const dst = path.join(SKILL_DIR, name);
  rmrf(dst);
  fs.cpSync(src, dst, { recursive: true });
  ok(`已安装 ${name}`);
}

// skill 运行时依赖检查 —— 只提示，不阻断（安装仍可完成）
function checkRuntime() {
  const isWindows = process.platform === 'win32';
  // Windows 上 PATH 里的 git/bash 可能是 .exe，用单字符串命令避免 shell 拼接告警
  const git = require('child_process').spawnSync('git --version', {
    encoding: 'utf8',
    shell: isWindows,
  });
  if (git.status !== 0) {
    warn('未找到 git —— 取证脚本依赖 git 2.20+，请先安装：https://git-scm.com');
  } else {
    ok(git.stdout.trim());
  }
  const bash = require('child_process').spawnSync('bash --version', {
    encoding: 'utf8',
    shell: isWindows,
  });
  if (bash.status !== 0) {
    if (isWindows) {
      warn('未找到 bash —— Windows 需要 Git for Windows 自带的 Git Bash：https://git-scm.com/download/win');
      log('        （或改用仓库里的 install.ps1，它会配置 PATH）');
    } else {
      warn('未找到 bash —— 脚本需要 bash 4+');
    }
  } else {
    ok(bash.stdout.split('\n')[0].trim());
  }
}

function install() {
  log(`安装 defect-resolution skill → ${SKILL_DIR}`);
  if (!fs.existsSync(SKILL_DIR)) {
    fs.mkdirSync(SKILL_DIR, { recursive: true });
    ok('已创建目标目录');
  }
  for (const item of ITEMS) copyItem(item);
  ok('安装完成');
  checkRuntime();
  log('');
  log('  使用方式（重启 Claude Code 后生效）：');
  log('');
  log('   帮我确认这个 bug 是在哪个版本、哪次提交修好的：');
  log('   仓库：<本地目录 或 https://github.com/owner/repo.git>');
  log('   问题版本：v1.0.0   修复版本：v2.0.0');
  log('   报错：<粘贴错误日志>');
  log('   出问题的地方：<文件:行范围>');
  log('');
}

function uninstall() {
  if (!fs.existsSync(SKILL_DIR)) {
    log(`${SKILL_DIR} 不存在，无需卸载`);
    return;
  }
  rmrf(SKILL_DIR);
  log(`已卸载：${SKILL_DIR}`);
}

function showHelp() {
  log(`defect-resolution —— 开源软件缺陷归因 skill（Claude Code）

用法：
  defect-resolution install     把 skill 装进 ~/.claude/skills/defect-resolution
  defect-resolution uninstall   卸载
  defect-resolution --help      本帮助

一步到位（无需全局安装）：
  npx @yanyan2015/defect-resolution install

或先全局安装再运行：
  npm i -g @yanyan2015/defect-resolution
  defect-resolution install

skill 本体：${PKG_ROOT}
安装器只复制文件 —— 不联网、不改 PATH。skill 运行时依赖 git 与 bash（与 Node 无关）。`);
}

const cmd = (process.argv[2] || '').replace(/^--?/, '').toLowerCase() || 'help';
switch (cmd) {
  case 'install': install(); break;
  case 'uninstall': uninstall(); break;
  case 'help': showHelp(); break;
  default: die(`未知命令: ${process.argv[2]}（可用: install / uninstall / --help）`);
}
