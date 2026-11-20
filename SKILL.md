---
name: defect-resolution
description: "从 Git 历史取证，确认开源软件在某个版本上的 bug 是在哪个版本、哪次提交解决的；也能定位非开源的本地代码。Find which release and which commit fixed a given error, plus why that commit eliminates it. Use when the user supplies an error log / stack trace / compile error plus the offending code path and asks which version/commit fixed it — 触发词：缺陷归因、这个 bug 在哪个版本修好的、哪个版本修复了这个报错、定位修复的 commit、是哪个 commit 修好了、找到引入/修复 bug 的提交、这个报错是哪个提交解决的、explain what fixed this error、find the fix commit、upstream fix attribution、root-cause commit hunting、本地代码/私有仓库的 bug 归因。Do NOT use for: 编写新修复、纯 blame 作者归属提问、常规 git 操作、代码评审、与具体报错无关的历史考古。"
---

# 缺陷归因（Defect Resolution）

**角色**：开源软件缺陷归因专家。目标是从 Git 历史中确认**某个版本上的 bug 是在哪个版本、哪次提交解决的**，并解释该 commit 的代码**为何**能消除该报错。

**主场景**：用户知道"在 X 版本上有这个报错，在 Y 版本上没有了"（或只有报错本身），需要确定：

1. **在哪个版本修好的** —— 首次包含该修复的发布版本
2. **哪次提交修的** —— 具体 commit
3. **为什么能修好** —— 触发条件如何被破坏

**同样适用**：非开源的本地代码 / 私有仓库 —— 只要是 git 仓库，取证流程完全一致，且全程本地进行、不会外发任何代码。

**输入 → 输出**：报错信息 + 出错代码路径 + 版本区间（或已修复代码）→ 修复 commit + **修复版本** + 可信度 + 证据链 + 消除机制。

## 何时用 / 何时不用

用：用户给了报错信息和代码路径，问"哪个版本/哪个 commit 修好了 / 为什么报错消失了 / 修复点在哪"。
不用：用户要写一个新修复（这是改代码任务）；只问某行代码的作者（`git blame` 一句话就能回答）；修 bug 的 commit 已知、只需解释代码（直接读代码）。

**变体（同一套证据链，反向使用）**：用户问"这个 bug 是**哪个 commit 引入的**"时，锚点对调 —— 问题版本 = 修复版本的父提交，修复版本 = 出问题的那个 commit，阶段 2 的 blame[issue-line] 通道直接给出答案。详见 `references/candidate-triage.md` 的"反向归因"。

## 输入契约

| 输入 | 必需 | 形态 | 缺失时怎么办 |
|---|:---:|---|---|
| 报错信息 | ✅ | 完整日志 / 堆栈 / 编译错误；或最小可识别片段 | — |
| 问题代码路径 | ✅ | `文件[:函数][:行范围]`；可来自本地代码，也可来自社区仓库指定版本 | — |
| 仓库 | ✅ | **本地目录**（开源仓库副本 / 私有项目）或 `https://…/owner/repo.git` | — |
| 问题版本 | 强烈建议 | tag / branch / commit / 本地 HEAD | 取修复 commit 的父提交 |
| 修复版本 | 建议 | tag / branch / commit | 见下方降级链 |
| 已修复代码 | 选填 | (a) 可解析的版本引用 (b) 文本片段 (c) 两者 | 见下方降级链 |
| 复现/构建命令 | 选填 | 一行能在"坏"版本失败、在"好"版本成功的命令 → 使真实 `git bisect run` 可用 | 只做静态验证，可信度上限为「中」 |

### 版本区间是主输入

典型主场景给出的是**两个版本**：「在 v1.2.0 报这个错，v1.3.0 就好了」。此时：

- 问题版本 = v1.2.0，修复版本 = v1.3.0，两者之间是候选区间。
- **但修复未必在 v1.3.0 那个提交上** —— 它可能在 v1.2.1 或某个中间版本。`anchor.sh` 会输出区间内的**版本序列**（`TAG_SEQUENCE`），提醒你逐个核对。
- 最终必须用 `inspect.sh` 的**版本归属**确认：首次包含该修复的发布版本、上一个仍含缺陷的版本。

### 私有代码 / 本地项目

**非开源 ≠ 非 git。** 绝大多数私有项目使用 git，只是仓库不公开 —— 取证流程与开源场景**完全一致**，且：

- 全程在本地仓库操作，不 clone、不推送、不访问远程（除非用户明确要求）。
- **不会**把代码、报错内容、commit message 发送到任何外部服务。
- 如果用户给的是**非 git 的代码目录**（纯文件、无 `.git`）：**无法做版本归因** —— 没有历史就没有证据链。此时应做的是：明确说明无法归因，并建议用户确认是否有上游仓库、或提供 git 历史（`git init` + 提交历史只能建立"当前快照"，不能回答"哪个版本修好的"）。

**缺失时的降级策略**（不要停下来干等，按此降级并在结论中标注）：

- 只有已修复代码文本、没有修复版本引用 → 修复版本锚点取仓库默认分支 HEAD，改用 `pickaxe` 反查（把修复代码的特征行拿去 `git log -S`），这是最强信号，见阶段 2 通道 4。
- 只有修复版本、问题版本未知 → 把"问题版本"锚定为修复 commit 的第一个父提交或其最近 tag（`git describe --tags --abbrev=0 <fix>^`），候选范围收紧为"最后一次改动该路径之前的 N 个提交"。
- 只有问题版本 → 修复版本取默认分支 HEAD，靠 pickaxe 定位。
- 仓库没有 tag（项目不打版本标签）→ 用分支或 commit 作为版本锚点，并在结论中说明"该仓库无发布标签，无法给出发布版本号，只能给出 commit 与分支"。
- 没有可复现命令 → 阶段 4 只能做静态验证，可信度上限为「中」。

## 硬性规则（违反即判定失败）

1. **不得跳步**：阶段 0→6 顺序执行。任何阶段无证据不得进入下一阶段。
2. **禁止编造**：hash、行号、issue 号、`git show` 输出一律来自实际命令的真实输出。没跑过就不许写。
3. **不污染用户工作区**：任何需要改动工作树的操作（`checkout`、`revert`、`bisect`、`apply`）**必须**在临时 `git worktree` 或临时 clone 中进行；结束前清理。
4. **每条结论挂证据**：候选 commit 必须写明"为何被选中"（blame 行 / pickaxe 命中 / `-L` 命中 / commit message / issue）。
5. **无法验证要说"无法验证"**，并给出原因与降级后的可信度，不许用推测填充。
6. **多候选不得强行择一**：若证据无法区分，列出全部候选及各自可信度。
7. **所有 git 命令**用 `git -C <repo> …` 或在已 `cd` 进仓库后执行；Windows/Git Bash 下列出路径用正斜杠。

## 脚本

本 skill 目录下的 `scripts/` 提供取证脚本，用**绝对路径**调用（下文记作 `$S`，即 `<本 SKILL.md 所在目录>/scripts`）。脚本只读，除 `verify.sh --run-cmd` 外不改仓库状态；`verify.sh` 的所有写操作都发生在临时 worktree 中。

| 脚本 | 用途 |
|---|---|
| `acquire.sh` | 阶段 0：本地/远程获取仓库（blobless clone，保留完整历史；`--offline` 强制零网络） |
| `anchor.sh` | 阶段 1：解析锚点、merge-base、候选范围计数、版本序列 |
| `version_bisect.sh` | 阶段 1.5：**版本维度**判定 —— 逐个发布版本检查，确定 bug 在哪个版本消失 |
| `extract_symbols.py` | 阶段 2：从报错信息抽取 pickaxe 符号 / commit message 关键词 / 文件行号 |
| `collect.sh` | 阶段 2：六条互补追溯 + 去重 + 加权证据表（`--no-G` 可跳过 `-G` 通道省时，大仓库用） |
| `inspect.sh` | 阶段 3：单个候选的语义筛选卡片 + 版本归属 |
| `verify.sh` | 阶段 4：父提交对比 / 报错区对比 / 区间扫描 / 临时 worktree 反向验证 / 真实 bisect |

先读一次脚本的 `--help` 或源码顶部注释以确认参数，再调用。

---

## 阶段 0：仓库就绪

1. 判定来源形态：
   - 本地目录：`git -C <dir> rev-parse --git-dir` 通过即可用。
   - 远程仓库：用 `$S/acquire.sh <url> <ref>` 拉到临时目录（**强制 blobless clone**：`--filter=blob:none`，完整历史 + 按需取 blob；**禁止 `--depth=1`**，浅克隆会让 blame/pickaxe/merge-base 全部失真）。
2. **完整性体检**（不可省略）：`git rev-parse --is-shallow-repository`、`git rev-list --count HEAD`、`git log --oneline | wc -l`。若 shallow 或历史明显被截断 → `git fetch --unshallow`（或明确告知用户结论可信度受限于不完整历史）。
3. 记录 `REPO=<绝对路径>` 与当前 `HEAD`，后续所有命令基于它。**不要**依赖调用方的 cwd。

输出：`REPO=`、`HISTORY_COMPLETE=yes/no`、`HEAD=`。

---

## 阶段 1：建立版本锚点

```bash
$S/anchor.sh <repo> <问题版本ref> <修复版本ref> [--path <问题代码路径>] [--limit 50]
```

该脚本完成并输出：

- `git rev-parse --verify "<ref>^{commit}"` 把 tag / 分支名 / 短 hash 解析成具体 commit（分支名必须解析，不许停在分支名上）。
- 每个锚点的：完整 hash、短 hash、作者日期、`git describe --tags --abbrev=0 --always` 最近 tag、提交标题。
- `git merge-base <问题版本> <修复版本>`，并用 `git log --oneline <A>..<B> | wc -l` 给出候选 commit 总数。
- 同时给出三个维度计数，便于判断范围是否过大：全部提交 / 排除 merge（`--no-merges`）/ 仅 `--first-parent` / 限定 `--path` 后。
- **版本序列**（`TAG_SEQUENCE`）：区间内的所有发布版本，按时间排序。这告诉你修复可能落在其中哪一个。
- 历史不完整时打 `SHALLOW=yes`。

**范围过大时先收窄，再进阶段 2**（候选 > 2000 或全部提交中 95% 与该路径无关时）：

```bash
git -C <repo> log --oneline --no-merges <A>..<B> -- <path> --follow   # 路径收窄（-S/-L 之外的兜底）
git -C <repo> log --oneline <A>..<B> --grep='<报错关键词>' -i        # message 收窄
```

**注意 merge commit**：修复可能由另一分支开发、在 merge 时进入主线。此时 `--no-merges` 会漏掉，修复的真正内容仍能通过 `git log -S` 找到（pickaxe 会穿过 merge 展开）。若怀疑此情形，用 `git log --oneline <A>..<B>`（含 merge）与 `--no-merges` 两次对比，并对差异 commit 跑 `git show -m`。

**注意维护分支**：开源项目常有 `main`（开发）与 `X.Y-stable`（维护）两条线，修复可能先落在维护分支再回合主线，或反之。若区间内包含多个分支，`git branch -a --contains <fix>` 能告诉你修复在哪些分支上 —— 这对判断"哪个版本真的拿到了修复"很关键。

输出（锚点卡）：

```
问题版本 commit: <sha> (<ref>, <date>, 最近 tag <tag>)
修复版本 commit: <sha> (<ref>, <date>, 最近 tag <tag>)
merge-base:      <sha>
候选范围:        <N> 个 commit（含 merge）/ <M> 个（不含 merge）/ <K> 个（限定 <path>）
版本序列:        <v1.0.0 → v1.1.0 → v2.0.0>
```

---

## 阶段 1.5：版本维度判定（主场景的关键一步）

阶段 1 给出的是**提交区间**。但用户问的是**版本**：「这个 bug 在哪个版本修好的」。

这两个粒度不同，而且**提交区间通常远大于版本区间**。从 v1.0.0 到 v2.0.0 之间可能有几百个提交、几十个中间版本，其中夹着大量无关重构 —— 直接在提交区间上取证，噪音大、效率低。

**发布版本序列是离散的、可逐个检查的** —— 这是一个天然的粗筛粒度。先用它把范围收窄，再在窄区间上做提交级取证。

```bash
# 先看版本序列
$S/version_bisect.sh <repo> <坏版本> <好版本> --tag-list

# 逐版本判定，自动找到"bug 消失"的第一个版本
$S/version_bisect.sh <repo> <坏版本> <好版本> \
  --path <file> --range <s>,<e> \
  --contains '<报错现场的特征文本>'      # 该文本消失 = 已修复
# 或
  --sym '<报错符号>'                      # 该符号消失 = 已修复
# 或
  --missing '<修复版才有的内容>'          # 该内容出现 = 已修复
# 或
  --run-cmd '<复现命令>'                  # 与 bisect 同约定：0 = 仍有 bug
```

输出：

```
FIX_VERSION=v1.2.0            ← bug 在这个版本修好了
STILL_BROKEN_BEFORE=v1.1.0    ← 上一个版本仍有问题
VERSION_TABLE=v1.0.0=broken,v1.1.0=broken,v1.2.0=fixed,
```

**拿到 `FIX_VERSION` 后，把阶段 2 的取证区间收窄到 `[STILL_BROKEN_BEFORE .. FIX_VERSION]`** —— 这时区间里通常只有个位数的提交，取证精度和效率都大幅提升。

**判据的选择**（决定这一步的可靠性）：

| 判据 | 含义 | 适用 |
|---|---|---|
| `--contains '<文本>'` | 该文本消失 = 已修复 | 报错现场的那行代码（最常用） |
| `--sym '<符号>'` | 该符号消失 = 已修复 | 报错点名的函数/宏/变量 |
| `--missing '<内容>'` | 该内容出现 = 已修复 | 修复补上的宏定义、判空守卫（内容必须在坏版本中**不存在**，否则会被忽略并警告） |
| `--run-cmd '<命令>'` | 命令 0 = 仍有 bug | 有可复现/可编译的判据时最准 |
| 自动判据 | 坏版本中该文件的内容是否还在 | 兜底；给 `--path` 即可启用 |

**没找到转变点时**（`FIX_VERSION` 为空）按序排查：判据选错 → 修复在好版本之后未发版 → 修复不在 `--path` 指定的文件里（去掉 `--path` 用 `--all-versions` 重查）→ 仓库无 tag（改用分支锚点）。

---

## 阶段 2：定位问题代码的变更历史

先抽取符号，再跑三条互补追溯。

### 2.0 符号抽取

```bash
$S/extract_symbols.py <error-file>              # 带注释的 TSV，供人读
$S/extract_symbols.py <error-file> --kind syms  # 一行一个符号 → collect.sh --symfile（用于 pickaxe）
$S/extract_symbols.py <error-file> --kind greps # 一行一个关键词 → collect.sh --grepfile（用于 commit message 搜索）
$S/extract_symbols.py <error-file> --kind paths # file:line → 每行 "path<TAB>line"
```

> Python 是**可选**依赖 —— 只影响符号抽取器。没有 python 就跳过这步，
> 直接从报错里人工挑 2–3 个高特异性的符号喂给 `collect.sh --sym`。
> 需要显式调用时用 `python3`（macOS 只有 `python3`，没有 `python`）。

抽取的优先级（rank 越小越可信）：
**syms**（用于 pickaxe）：报错中的**引号字面量**（如 `error: 'X' undeclared` 里的 `X`）> 「未定义/未声明/不存在」句式点名的符号 > 文件:行号 > 宏名/函数名 > 通用标识符 > 错误码/errno/信号名。
**greps**（用于 message 搜索）：issue 号（含 URL 里的 `/issues/1234`）> CVE > 报错原文的多词短语 > 引号整句。
最理想的 pickaxe 目标是**报错信息里的源码字符串字面量**（断言/SIGABRT/oops 常带原文），它几乎唯一命中。

### 2.1 三条互补追溯（全部执行）

```bash
# ① 行范围完整变更历史
git -C <repo> log --format='%h %s' -L <start>,<end>:<file> <A>..<B>
git -C <repo> log --format='%h %s' -L :<函数名>:<file> <A>..<B>      # 已知函数名时
```
注意：`-L` 与 `--follow` 不可同时使用；行号以**问题版本**为准，`-L` 会自行跟踪跨版本的行漂移。

```bash
# ② 两版 blame 对比（注意行号漂移，详见下方"行漂移"条目）
git -C <repo> blame --line-porcelain <A> -- <file> > /tmp/blameA.txt
git -C <repo> blame --line-porcelain <B> -- <file> > /tmp/blameB.txt
```
判据（`collect.sh` 已实现，**不要手工用行号筛修复版本的 blame**）：
- 报错行内容在**问题版本**中的归属 commit ∈ `A..B` → 候选（这些提交改过报错现场）。
- 报错区内容在**修复版本**中的行号（内容锚定区间）落在归属 commit ∈ `A..B` 的行上 → 强候选（改写或**插入守卫**都落在这里）。
- 报错区的某行内容在修复版本中已消失 → 被删除/改写，其原始归属提交可疑。
- 含报错符号的行在修复版本中的归属 ∈ `A..B` → 强候选（符号行不受行漂移影响，最稳）。
`blame` 用 `--line-porcelain`（40 位完整哈希、无 `^` 前缀干扰）。

```bash
# ③ pickaxe：符号的引入/删除
git -C <repo> log --format='%h %s' -S'<sym>'    <A>..<B> -- <file>
git -C <repo> log --format='%h %s' -S'<sym>'    <A>..<B>                # 路径不确定时全仓
git -C <repo> log --format='%h %s' -G'<正则>'   <A>..<B> -- <file>      # 内容改写但出现次数不变时的补充
```
`-S` 统计出现次数变化（增删符号），`-G` 统计内容匹配（改写）。**两者都要跑**：只改条件判断、不动符号个数的修复只能被 `-G` 抓到；纯删掉宏定义的修复只能被 `-S` 抓到。

### 2.2 最强信号：用"已修复代码"反查

若已修复代码是文本片段，把它按行拆开做 pickaxe —— 修复 commit 几乎必然命中：

```bash
`$S/collect.sh … --fixed <fixed_code.txt>` 会用修复代码的每一行跑 -S（先限路径，无命中再全仓）
```

### 2.3 跨路径扩散（修复可能不在报错文件里）

**常见但容易漏**：修复改的是**别的载体** —— 头文件、Makefile/CMakeLists/setup.py、依赖锁定文件、CI 配置、子模块指针、编译选项。此时报错文件本身一行未改，上面所有通道都会哑火。

`collect.sh` 的通道 6 已覆盖：同目录兄弟文件、构建/依赖文件、报错符号的全仓改动。命中权重为 1（弱）—— **必须人工确认**，不能直接当结论。

### 2.4 一次跑完

```bash
$S/collect.sh <repo> <A> <B> \
  --path <file> [--range <s>,<e>] \
  --symfile /tmp/syms.txt \
  --grepfile /tmp/greps.txt \
  --error-file <error-file> \
  --fixed <fixed_code.txt> \
  --limit 200
```

输出：候选 commit 集合（去重、按证据**权重**排序）+ 每个候选的命中证据（哪条通道、哪一行、哪个符号）+ 机器可读行 `CAND|short|full|weight|证据数|日期|标题`。

**权重对照**（决定候选排序，不是可信度）：

| 证据 | 权重 |
|---|---|
| 修复代码行 pickaxe（限路径） | 5 |
| 报错符号 pickaxe（限路径） | 4 |
| `-G` 正则命中（限路径） | 3 |
| `-L` 行范围变更 / blame 锚定区间 / 报错行被删除 | 3 |
| 报错符号 pickaxe（全仓）/ 修复代码行 pickaxe（全仓） | 3–4 |
| commit message 命中 issue 号 | 2 |
| 问题版本报错行的原始归属 | 2 |
| 同目录兄弟文件 / 构建文件 / 符号全仓改动 | 1（弱，需人工确认） |

**候选集为空时**（不要就此收工，按顺序尝试）：放宽到全仓（去掉 `--path`）→ 用 `-G` 代替 `-S` → 扩大范围到 `<A>^..<B>` → 怀疑修复在 merge 中带入（`git show -m`）→ 怀疑文件被重命名（`git log --follow --name-status -- <file>`）→ **怀疑修复在别处（构建文件/头文件/依赖）** → 怀疑问题是**外部变更**（依赖版本、配置、编译器）而非本文件，此时明确告知用户"该报错不由本仓库本路径的提交修复"。

---

## 阶段 3：语义筛选候选 commit（→ 确认闸门）

对每个候选（至少覆盖 collect 输出的前 10 个或全部强候选）：

```bash
$S/inspect.sh <repo> <candidate> --path <file> --sym <sym>... [--fixed <fixed_code.txt>] [--range <s>,<e>]
```

逐条判定（三档）：

- **强候选**：diff **语义性地**改变了与报错相关的代码路径 —— 引入/删除/修改了报错涉及的符号、宏、函数调用、条件判断、类型、初始化顺序或资源生命周期；或 commit message 提及相关 bug / 报错关键词 / 关联 issue 编号。
- **弱候选**：改到了该文件/邻近区域，但无法一眼建立与报错的语义联系（例如同一次提交里的无关清理）。
- **排除**：纯格式/空白/缩进、纯注释、纯变量重命名、代码搬家（`--find-renames` 显示为 rename/move）、仅文档/测试/版本号/生成文件、只改无关路径。理由必须写明（例如"`git show -w --stat` 为空 → 纯空白改动"）。

判定要点：改动规模（`--numstat` 的增删行数）、是否触及报错行/符号、message 与报错的词汇重叠度、是否伴随测试用例新增（强信号：真实修复通常同时加测试，且测试断言/测试名常含报错文本）。

### 确认闸门（必停）

把候选按强/弱/排除三档用表格呈现给用户（commit、日期、标题、改动文件、命中证据、分档理由），然后用 `AskUserQuestion` 询问：

- 「按强候选进入阶段 4 验证」（默认推荐）
- 「调整候选集」（用户会补充/排除 commit 或给出 issue 号、复现命令）
- 「只做静态验证，不构建/不运行」
- 「强候选里再缩小」（例如锁定到某一个）

**得到答复前不得进入阶段 4。** 若强候选恰好唯一且证据链闭合，可把"直接验证该候选"作为推荐项，但仍要停一次。

---

## 阶段 4：确定性验证（关键步骤，不可省略）

对强候选执行**至少两种**验证方法交叉验证。默认顺序：B → D → A → C；用户提供了可复现命令时**必须**跑 A-真实（bisect）。**D（版本归属）是主场景的必做项** —— 它回答"在哪个版本修好的"。

```bash
$S/verify.sh <repo> <candidate> --A <问题版本> --B <修复版本> \
  --path <file> [--sym '<sym>']... [--range <s>,<e>] [--fixed <fixed_code.txt>] \
  [--run-cmd '<一行复现命令>']
```

### 方法 A：二分验证（真实或静态）

- **真实 bisect**（有可复现命令时首选）：`--run-cmd` 会在**临时 worktree** 中执行
  `git bisect start <B> <A>` → `git bisect run <cmd>` → 记录 first bad commit → `git bisect reset`（`trap` 保证清理）。
  判据设计（命令必须把"报错是否出现"变成退出码，见 `references/verification.md`）：非 0 = 坏版本。
  结论形态："该 commit 是首个使报错消失的提交"（bisect 会直接给出 first bad commit）。
- **静态近似**（无法运行时）：
  ```bash
  git -C <repo> log --oneline <cand>^..<B> -- <file>     # 其后是否还有更早能消除报错的提交？若为空/无关 → 该候选即首个修复
  git -C <repo> log --oneline <A>..<cand>^ -- <file>     # 之前是否已有等价修复被漏掉？
  ```
  静态近似**只能排除**"更早的等价修复"，**不能**证明原报错确实消失 —— 在结论里如实标注。

### 方法 B：父提交对比

比对 `git show <cand>^:<file>` 与 `git show <cand>:<file>`，确认报错条件在父提交成立、在候选提交不成立。对每个报错符号，给出两版中的出现次数与所在行，以及语义缺口（例如"父提交中 `FOO_H` 从未定义，候选提交在同一文件补上了 `#define FOO_H`"）。

传入 `--range <s>,<e>` 时额外做**报错现场对比**：把父提交与候选提交中该行范围的内容并排列出。内容变了 = 候选确实触及了报错现场；内容一字未变 = 候选与该报错无关（即使它的 diff 落在同一文件），可信度应大幅下调。

### 方法 D：版本归属确认（主场景必做）

这一条直接回答用户的问题 —— **"这个 bug 在哪个版本修好的"**。

```bash
# 首次包含该修复的发布版本 + 上一个仍含缺陷的版本
$S/inspect.sh <repo> <candidate> --path <file>     # 「版本归属」段
$S/verify.sh  <repo> <candidate> --A <A> --B <B> ... # 头部也会打印
```

**关键陷阱**：不要用 `git describe --tags --abbrev=0 <commit>` 当作"修复版本"。它返回的是**最近的上游 tag**，对于"修复落在两个 tag 之间"的情况会给出**上一个** tag —— 也就是那个**还带着 bug** 的版本。正确算法是：找出所有**包含**该 commit 的 tag，取最早的那个。

判断依据：`git merge-base --is-ancestor <fix> <tag>` 为真即表示该 tag 已包含此修复。

补充检查：

```bash
git -C <repo> branch -a --contains <fix>       # 修复在哪些分支上（main / X.Y-stable）
git -C <repo> tag --contains <fix> | head      # 哪些发布版本包含此修复
```

如果修复**只**在维护分支而不在主干，说明它还没进入下一个大版本 —— 结论里要说清楚。

### 方法 C：反向验证

在**临时 worktree**（基于修复版本）上 `git revert --no-commit <cand>`，检查：能否干净回滚、回滚后报错条件是否重新成立（符号/条件回到父提交状态）；无复现命令时这是静态推演，如实标注。禁止在用户的工作树里 revert。

输出：每个强候选的"通过 / 不通过 / 无法验证（原因）"，以及由此确定的可信度。

---

## 阶段 5：解决机制解释

对最终确认的修复 commit，按四段式解释"为什么能解决"：

1. **报错触发条件**：修复前，代码在什么条件下产生该报错？引用具体代码行与逻辑（如"`cfg` 为 NULL 时第 812 行进 `strlen()`"）。
2. **commit 的变更内容**：具体改了什么？引用 diff 关键行（带上下文 1–3 行）。
3. **消除机制**：变更如何破坏或绕过触发条件？归到下列类别之一并说明：
   补上缺失的符号/宏定义 · 修正错误的条件判断/边界计算 · 增加空指针/越界检查 · 调整初始化顺序 · 修正类型或函数签名不匹配 · 修正资源获取/释放与并发时序 · 提升依赖/子模块版本 · 补齐配置/默认值 · 修正编译期条件（`#if`/平台判定）。
4. **证据链**：blame 行、diff 行、pickaxe 命中、bisect 结果、commit message、关联 issue —— 每条都写清来源命令。

**反事实自检**（写完必做）：把"消除机制"的结论倒推一遍 —— 如果只把 diff 里的这一行改回去（其他不变），报错是否必然重现？若不能必然重现，说明机制解释不完整或另有共因，回到阶段 4 补充验证，并在结论中降低可信度。

---

## 阶段 6：输出结论

按下方模板输出。若存在多个候选无法唯一确定，**必须**明确说明，并列出所有候选及各自可信度，同时给出"如何进一步区分"的一条具体建议（例如某条命令、某个复现步骤、某个 issue 编号）。

## 输出模板

```markdown
## 结论
- **修复 commit**：`<hash>`（`<commit message 首行>`）
- **修复版本**：`<tag>`（首次包含该修复的发布版本，`<日期>`）—— 若无 tag 则写「该仓库无发布标签，仅能定位到 commit `<hash>`」
- **缺陷版本**：`<tag>`（最后一个仍含此缺陷的发布版本）
- **所属分支**：`<branch>`（若适用）
- **可信度**：高 / 中 / 低 —— `<依据，例如"强候选唯一 + 真实 bisect 通过 + message 关联 issue #1234">`

## 证据链
1. 版本锚点：问题版本 `<commit>`（`<ref>`），修复版本 `<commit>`（`<ref>`），候选范围 `<N>` 个 commit（限定 `<path>` 后 `<K>` 个）
   - 版本序列：`<v1.0.0 → v1.1.0 → v2.0.0>`（区间内的发布版本；修复可能落在其中任一个）
2. 定位依据：
   - blame：`<B>:<file>:<line>` 归属 `<commit>`（父版本中该行为 `<line>`，归属 `<commit2>`）
   - pickaxe：`git log -S'<sym>'` 命中 `<commit>`；`-G'<regex>'` 命中 `<commit>`
   - -L：`<start>,<end>:<file>` 变更历史中的 `<commit>`
3. 语义筛选：`<该 commit 的 diff 为何与报错语义相关，引用关键 diff 行>`
4. 交叉验证：
   - 方法 A（<真实 bisect / 静态区间扫描>）：`<结果>`
   - 方法 B（父提交对比）：`<结果>`
   - 方法 C（反向验证）：`<结果>`
5. 版本归属：首次包含该修复的发布版本 `<tag>`；上一个仍含缺陷的版本 `<tag>`
6. 其它佐证：commit message `<原文关键句>` / issue `#<编号>` / 同提交新增测试 `<测试名>`

## 解决机制
- **报错触发条件**：`<修复前，什么条件触发，引用行与逻辑>`
- **变更内容**：`<diff 关键行>`
- **消除机制**：`<该变更如何破坏/绕过触发条件>`
- **反事实自检**：`<只回退这一行是否必然重现报错？结论>`

## 未确定项（如有）
- 候选 `<hash>`（可信度 中）：`<为何无法排除>`
- 进一步区分建议：`<一条可执行的具体建议>`
```

## 可信度打分

| 等级 | 条件 |
|---|---|
| 高 | 强候选唯一；方法 B 通过（父提交中触发条件成立、候选提交中不成立）；方法 D 通过（能确定首次包含修复的发布版本）；且满足下列任一：真实 bisect 通过 / 方法 C 干净回滚且触发条件复现 / commit message 与 issue 明确对应报错 |
| 中 | 强候选唯一但只有静态证据（无法构建或运行）；或方法 D 无法给出发布版本（仓库无 tag）；或多候选但其中一个在 3 条通道上均有命中且其余候选只有 1 条 |
| 低 | 仅 pickaxe/blame 单通道命中，diff 与报错只是弱语义关联；或候选无法区分；或仓库历史不完整（shallow、被 squash/重写） |

降级理由必须写进「可信度」行，不允许只给等级。

## 常见陷阱（执行前读一遍）

- **浅克隆**：blame/pickaxe/merge-base 全部失真。用 blobless clone（`--filter=blob:none`），不要 `--depth=1`。用 `git rev-parse --is-shallow-repository` 体检。
- **`git describe` 不是"修复版本"（P0）**：`git describe --tags --abbrev=0 <fix>` 返回**最近的上游 tag**，修复落在两个 tag 之间时它给出**上一个** tag —— 那个还带着 bug 的版本。正确算法见方法 D：找出所有**包含**该 commit 的 tag，取最早的那个。
- **修复藏在 merge 里**：`--no-merges` 会漏掉真正的修复；pickaxe 能穿过 merge 找到内容变更的提交。
- **修复只在维护分支**：开源项目常有 `main` 与 `X.Y-stable` 两条线。修复可能只合入了维护分支，还没进下一个大版本。用 `git branch -a --contains <fix>` 确认，结论里要说清楚。
- **维护分支上可能有另一个修复**：同一 bug 在主干和 `X.Y-stable` 上可能被**两次修复**（backport）。此时给出两个候选，各自标明所属分支与版本。
- **`-S` 与 `-G` 不可互相替代**：条件判断改写、常量替换只有 `-G` 能抓到；宏增删只有 `-S` 能抓到。
- **行漂移（P0，最易误判）**：报错里的行号属于**问题版本**；修复版本因插入/删除行而整体下移或上移。**绝不能**拿问题版本的行号去筛修复版本的 blame —— 会完全错位（真修复因此拿不到分，噪声提交反而拿分）。
  正确做法：用**内容锚定** —— 把问题版本报错区的行内容逐行在修复版本里定位，得到锚定区间，再看区间内哪些行的归属 commit ∈ `A..B`。这能同时覆盖"改写报错行"和"在报错行前插入守卫"两种修复形态。`collect.sh` 的 `blame[anchored]` 通道已实现。
- **修复不在报错文件里**：改了 Makefile / 头文件 / 依赖 pin / CI 配置时，报错文件一行未动，所有基于文件内容的通道都会哑火。`collect.sh` 通道 6 会捞出嫌疑提交（弱信号，必须人工确认）。
- **边界提交**：默认 blame 格式会给边界提交加 `^` 前缀，解析用 `--line-porcelain`。
- **重命名**：`--follow` 只对**单个文件**的 `log` 有意义，且与 `-L` 冲突；跨重命名用 `git log --follow --name-status -- <file>` 先确认改名点。
- **"最后一次改动"≠"修复"**：同一文件上后续的格式化/重构提交会排在候选表前面。用阶段 3 的排除规则筛掉，别只看最新的那个。
- **上游 rebase/squash**：若修复在历史重写中被压扁，原始 commit 已不存在，只能给出"包含该修复的首个发布 tag/commit"，并在可信度中说明。
- **Windows/Git Bash**：路径用正斜杠；`-S`/`-G` 的参数用单引号包裹避免 shell 展开；`git -C <repo>` 优先于 `cd`。
- **私有/敏感仓库**：用 `acquire.sh <本地路径> --offline` 强制零网络。整个取证链路默认不联网（本地仓库不需要 fetch）。
- 更多命令语义与判据设计见 `references/git-forensics.md`、`references/repository-acquisition.md`、`references/verification.md`、`references/candidate-triage.md`、`references/version-attribution.md`。
