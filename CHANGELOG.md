# Changelog

本项目遵循 [Semantic Versioning](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Added

- **npm 安装方式**（`npx @yanyan2015/defect-resolution install`）：scoped 包自带 bin 安装器，把 skill 复制进 `~/.claude/skills/defect-resolution` 并检查 git/bash 可用性（只提示，不联网、不改 PATH）。跨平台，与 PowerShell 安装器、git clone 方式并存
- **版本维度判定**（`version_bisect.sh`，阶段 1.5）：在版本序列上逐个检查，确定 bug 在**哪个发布版本**消失。产出 `FIX_VERSION` / `STILL_BROKEN_BEFORE`，并把提交级取证区间收窄到个位数。四种判据：`--contains`（文本消失）/ `--sym`（符号消失）/ `--missing`（内容出现）/ `--run-cmd`（与 bisect 同约定）
- **版本归属**（方法 D）：给定 commit，算出首次包含它的发布版本 + 上一个仍含缺陷的版本。`inspect.sh` 与 `verify.sh` 均输出，「修复版本」也是 `collect.sh` 候选表的一列
- **版本序列输出**（`anchor.sh` 的 `TAG_SEQUENCE`）：提示修复可能落在区间内任一版本，而不只是用户给的"修复版本"那个
- **私有/本地项目支持**：`acquire.sh --offline` 强制零网络（禁用认证提示与代理、跳过 fetch、强制完整 clone）；非 git 目录给出明确诊断与三条出路，而非笼统报错
- **维护分支感知**：候选表附「所在分支」列；`references/candidate-triage.md` 新增 backport 场景的处理方式（同 bug 在主干与维护分支各修一次时给出两个候选）
- **`references/version-attribution.md`**：版本归属专篇 —— 三个概念的区分、开源项目的维护分支 / 无 tag / 快照发行版等真实复杂性
- **取证管线**：六条互补通道（`-L` 行范围历史、两版 blame 内容锚定、pickaxe `-S`/`-G`、已修复代码反查、commit message、跨路径扩散）+ 加权证据表
- **验证方法**：真实 `git bisect run`、父提交对比、反向验证（临时 worktree 内 revert），三者可交叉
- **语义筛选卡片**（`inspect.sh`）：自动排除纯空白/纯注释/仅文档测试/重命名搬家的提交
- **确认闸门**：阶段 3 后暂停，把强/弱/排除三档呈现给用户确认
- **降级链**：修复版本未知 / 问题版本未知 / 无复现命令 / 历史不完整 / 仓库无 tag，各有明确降级路径并标注可信度
- **反向归因**：同一套证据链可定位「是哪个提交引入了这个缺陷」
- **回归测试套件**（`test/run-tests.sh`）：14 个场景、94 项断言，覆盖行漂移、跨路径、merge 场景、符号抽取、四种验证方法、版本归属、版本维度判定、私有仓库、脚本健壮性、文档一致性
- **开源文档**：中英文 README、DESIGN.md（设计取舍与被否决方案）、SECURITY.md（威胁模型与信任边界）、CONTRIBUTING.md、CODE_OF_CONDUCT.md
- **CI**：Linux / macOS / Windows 三平台回归测试 + shellcheck + 仓库自检
- **`install.ps1`**：Windows PowerShell 5.1+ 安装脚本
  - 定位 Git Bash（PATH / 常见安装路径 / 注册表三条路）
  - 复制 skill 文件到目标目录（幂等，重复运行覆盖而非堆副本）
  - 把 Git Bash 目录加入用户 PATH，并记录是否由本脚本添加 —— 卸载时只移除自己加的，不误删用户原有配置
  - 跑**真实冒烟测试**：建临时仓库 → 走完取证管线 → 验证产出候选
  - 写 `.install-info.json` 记录环境
  - 参数：`-Target` / `-Scope User|AllUsers` / `-NoPath` / `-Uninstall`
  - **UTF-8 BOM**：Windows PowerShell 5.1 用 ANSI 读取无 BOM 的 .ps1，中文注释直接导致语法错误。文件以 BOM 形式提交；`.gitattributes` 里注明不用 `working-tree-encoding=UTF-8-BOM`（它会在 checkout 时剥掉 BOM）
  - **不用 `bash -lc "..."` 内嵌引号** —— 含分号的参数会被提前解释。改为 `bash <script> <args...>`，脚本写临时文件
- **CI 的 Windows 安装器 job**：安装 → 校验文件 → 跑已安装的脚本 → 卸载
