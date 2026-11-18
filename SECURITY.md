# Security Policy

## Supported Versions

| Version | Supported |
|---------|:---------:|
| latest  | ✅        |

本项目处于早期阶段，仅维护最新版本。

## Reporting a Vulnerability

如果发现安全问题，请**不要**开公开 issue。

1. **不要**公开披露，也不要在公开 issue / PR / discussion 里提及细节。
2. 使用 [GitHub Security Advisory](https://github.com/yanyan2015/defect-resolution/security/advisories/new) 私下报告。
3. 请包含：
   - 复现步骤
   - 受影响文件与行号
   - 潜在影响范围
   - 你建议的修复方式（如有）

我们会在 **5 个工作日**内确认收到，并与你协同修复。

## Scope

本政策适用于 [yanyan2015/defect-resolution](https://github.com/yanyan2015/defect-resolution) 仓库。

## 威胁模型

这个 skill 会**执行 git 命令**，其中一部分会改动状态。理解信任边界是判断报告价值的前提。

### 信任边界

| 输入 | 信任级别 | 处理方式 |
|---|---|---|
| 仓库内容（文件、commit message、blob） | **不可信** | 只作为数据处理；绝不 `eval`，绝不当作命令执行 |
| `--run-cmd` 判据命令 | **用户授权** | 用户显式提供，等同于用户自己敲了这条命令 |
| 报错文本 | **不可信** | 抽取符号时过滤；绝不直接拼进 shell 命令 |
| 仓库地址 | **半可信** | 仅用于 `git clone`；不拼接进其他命令 |

### 具体防护措施

1. **不执行仓库内容。** 从报错信息中抽取的符号只用于 `git log -S` 的**参数**（单引号包裹），永远不会被作为命令执行。仓库里的任何文件、脚本、Makefile target 都不会被 skill 自动运行。
2. **写操作隔离。** 所有会改动工作树的操作（`bisect` / `revert` / `checkout`）都在**临时 `git worktree`** 中进行，用户的工作区与索引完全不受影响。
3. **临时目录清理。** 脚本通过 `trap` 保证异常退出时也会清理临时目录与临时 worktree。
4. **不修改用户配置。** 不改动 `~/.gitconfig`，不改全局 git 设置，不碰用户的分支、标签或远程配置。
5. **网络边界。** 只在 `git clone` 以及 blobless clone 首次按需取 blob 时联网。**不会**向任何第三方服务发送报错内容、代码片段或仓库内容。
6. **参数注入防护。** 所有来自用户输入的参数（符号、路径、判据命令）都经过引用处理；`git log -S` / `-G` 的参数一律用单引号包裹，避免 shell 展开。

### 私有仓库的额外边界

非开源 ≠ 非 git。大多数私有项目用 git，只是不公开。这类场景多一条泄露通道：**fetch 本身就会泄露信息** —— 向远端请求一个 ref，等于告诉远端"有人在查这个分支"。

因此：

- **本地私有仓库默认零网络。** 取证流程不需要 fetch，所有脚本都在本地仓库里操作。
- **`acquire.sh --offline` 可强制零网络**：禁用 `GIT_TERMINAL_PROMPT`（不弹认证框）、禁用代理变量、跳过 fetch、强制使用完整 clone（因为 blobless 的按需取 blob 需要联网）。
- **私有仓库的远程 URL 需要 clone 才能取证**，这必然走网络。正确做法是先向用户确认，而不是默默 clone。若你已经在处理敏感仓库，请优先提供本地路径。
- skill **不会**读取与取证无关的文件（如 `~/.ssh`、`~/.aws` 等凭据目录）。

```bash
# 私有仓库：强制零网络
bash acquire.sh /path/to/private-repo <ref> --offline
```

### 明确的越界（不会做的事）

为了避免误解，这里明确列出本 skill **不会**执行的操作：

- ❌ 不会执行用户仓库里的任何脚本、测试或 `make` target（除非用户通过 `--run-cmd` 显式指定）。
- ❌ 不会把报错内容、代码片段、仓库内容或 commit message 发送到任何外部服务（包括搜索引擎、LLM API、遥测）。
- ❌ 不会修改、删除或重置用户的分支、标签、stash 或远程配置。
- ❌ 不会在你的仓库里创建分支 —— 所有临时状态都在独立的临时 worktree 中。
- ❌ 不会读取与取证无关的文件（如 `~/.ssh`、`~/.aws` 等凭据目录）。

## 风险提示：使用 `--run-cmd` 时

`--run-cmd` 是本 skill 唯一会执行**你提供的命令**的地方，也是唯一需要你自行承担判断的地方：

- 判据命令会在**临时 worktree** 中执行，工作目录是那个临时目录。
- 它**继承你的 shell 环境**（包括 `PATH`、代理设置、环境变量）。请不要把含凭据的变量当作必要输入。
- 它**可能有网络访问能力**（比如 `make` 触发依赖下载）。如果你在处理不可信仓库，请确认这条命令不会做你不希望它做的事。
- 建议判据尽量简单、可离线、只读。例如：

  ```bash
  # ✅ 好的判据：只读、离线、明确
  --run-cmd 'grep -q "error: .FOO_H. undeclared" <(make foo.o 2>&1)'

  # ⚠️ 需要警惕：会执行仓库里的构建脚本
  --run-cmd './run_all_tests.sh'
  ```

### npm 安装器（`npx @yanyan2015/defect-resolution install`）的行为

`bin/cli.js` 在任何平台上都会：

- **写** 目标 skill 目录（`~/.claude/skills/defect-resolution`）—— 只做文件复制与删除该目录。
- **读** `git --version` / `bash --version` 做运行时依赖检查 —— 只读，失败仅提示不阻断。

它**不会**：联网（`npm install` 本身除外）、修改 PATH 或任何环境变量、执行 skill 的取证脚本、读取或改动目标目录之外的任何文件。

### Windows 安装器的行为

`install.ps1` 在 Windows 上会：

- **读** Git for Windows 的安装位置（PATH、常见安装路径、注册表）—— 只读。
- **写** 目标 skill 目录（默认 `%USERPROFILE%\.claude\skills\defect-resolution`）。
- **写** 用户级 `PATH` 环境变量 —— 只添加 Git Bash 目录，且在 `.install-info.json` 里记录「是否由本脚本添加」。卸载时**只移除自己添加的那条**，不会误删你原有的 PATH 配置。
- **执行** 临时 smoke 测试脚本（在系统临时目录创建、用完即删）。

它**不会**：

- 修改 `HKLM` 或其它需要管理员权限的注册表项。
- 修改系统级 PATH（`AllUsers` 作用域也只写用户级 PATH）。
- 执行仓库里的任何脚本（除了本仓库自带的 `scripts/*.sh`，用于自检）。
- 访问网络。

**执行策略**：Windows 默认禁止运行未签名脚本。若报"禁止运行脚本"，执行：

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

这条命令只影响当前用户，是安全的常用设置。

## Non-security Bugs

普通 bug、功能请求、使用问题请直接开 issue —— 不需要走私下披露流程。

## Disclosure

- 在我们发布修复之前，请不要公开披露问题细节。
- 我们会在 release notes 中致谢报告者（除非你希望匿名）。
