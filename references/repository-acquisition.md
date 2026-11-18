# 仓库获取与版本解析（阶段 0–1 速查）

## 来源形态判定

| 用户给的 | 动作 |
|---|---|
| 本地目录（含 `.git`） | 直接用：`acquire.sh <dir>`；确认 `rev-parse --git-dir` 通过 |
| 本地目录（**非 git**） | **无法做版本归因** —— 没有历史就没有证据链。`acquire.sh` 会给出明确诊断与三条出路（给上游仓库地址 / 确认是否被 git 管理过 / 降级为静态分析）。不要用 `git init` 伪造历史来"凑"证据 |
| 远程 URL + ref | `acquire.sh <url> <ref>` → blobless clone 到临时目录 |
| 只给仓库名（如 `curl/curl`） | 先确认归属平台（github/gitlab/gitee），构造 URL；gh 可用：`gh repo view <name> --json url` |
| patch/邮件列表 | 用 `git apply --check` 定位目标版本，再回到仓库归因（patch 本身往往就是修复 commit 的内容） |

## 私有仓库 / 本地项目

**非开源 ≠ 非 git。** 绝大多数私有项目使用 git，只是仓库不公开。取证流程与开源场景完全一致。

**隐私边界（重要）**：

- 全程在本地仓库操作：**不 clone、不推送、不访问远程**（除非用户明确要求）。
- **不会**把代码、报错内容、commit message、commit hash 发送到任何外部服务。
- 本地仓库若缺少目标 ref，`acquire.sh` 默认会尝试 `git fetch` —— 对私有仓库这可能触发认证提示或向远端泄露"我在查这个 ref"。用 `--offline` 禁止：

  ```bash
  bash acquire.sh <私有仓库路径> <ref> --offline
  ```

  `--offline` 会：禁用 `GIT_TERMINAL_PROMPT`（不弹认证）、禁用代理、跳过 fetch、强制使用完整 clone（因为 blobless 的按需取 blob 需要联网）。

- 如果用户给的是**私有仓库的远程 URL**（如 `git@github.com:company/private.git`），需要 clone 才能取证 —— 这会走网络。此时应当**先向用户确认**是否允许 clone，以及远端凭据是否可用。

## clone 策略

**默认 blobless**：`git clone --filter=blob:none --no-checkout <url> <dest>`

- 完整 commit 历史 + tree，blob 按需取 —— blame/pickaxe/log 全部可用，首次触碰文件时自动联网取 blob。
- 禁止 `--depth=1`/`--shallow-since`：浅克隆让 `A..B`、merge-base、blame 全部失真，且 `--unshallow` 需要服务端支持。
- 仓库极小或需要离线反复验证时用完整 clone（`--full`）。
- 超大仓库（linux、chromium）首次 pickaxe 全仓可能触发大量 blob 下载 —— 尽量限路径。

## 完整性体检（必做）

```bash
git -C $REPO rev-parse --is-shallow-repository   # true ⇒ 不可信，先 unshallow
git -C $REPO rev-list --count HEAD               # 提交总数（0 = 空仓库）
git -C $REPO log -1 --format='%H %cd' --date=iso # 最新提交日期，判断是否是活跃分支的陈旧镜像
```

- 用户给的版本 ref 不在本地：`git fetch --tags origin <ref>` 或 `git fetch --tags --all`。
- fork 场景：修复可能在 fork 的分支上而不在上游 —— 确认用户给的 URL 是哪个 remote，并检查 `git remote -v`。

## ref 解析顺序

1. `git rev-parse --verify '<ref>^{commit}'` —— 覆盖 tag（含 annotated）、分支、短/长 hash、`HEAD~3`。
2. 失败则 `git fetch --tags origin <ref>` 后重试。
3. 仍失败则列出相近候选：`git tag -l '*<fragment>*'`、`git branch -a | grep <fragment>`，让用户选。
4. 用户给的是「版本号」而仓库 tag 风格不同（`v1.2.3` vs `1.2.3` vs `release-1.2.3`）：先 `git tag -l | grep 1.2.3`。

## 降级链（修复版本缺失时）

1. 「已修复代码」是文本片段 → 用片段特征行做 pickaxe（`collect.sh --fixed`），命中 commit 即修复锚点。
2. 连修复代码也没有、只有报错 → 用报错符号 pickaxe + message 搜索，产出候选列表后请用户指认修复版本。
3. 问题版本缺失 → 把修复 commit 的父提交当作问题版本（`<fix>^`），或 `<fix>` 所在分支的最近 tag。

## 清理

`acquire.sh` 打印的 `CLEANUP=rm -rf <dir>` 在归因结束、用户确认结论后执行；临时 worktree 由 `verify.sh` 自动清理（`--keep` 除外）。
