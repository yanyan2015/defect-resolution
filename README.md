<p align="center">
  <b>简体中文</b> | <a href="README_EN.md">English</a>
</p>

<p align="center">
  <h1>Defect Resolution</h1>
  <b>确认开源软件在某个版本上的 bug，是在哪个版本、哪次提交解决的</b>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-yellow?style=flat-square" alt="MIT License" /></a>
  <img src="https://img.shields.io/badge/git-2.20%2B-F05032?style=flat-square&logo=git&logoColor=white" alt="Git 2.20+" />
  <img src="https://img.shields.io/badge/python-3.8%2B-3776AB?style=flat-square&logo=python&logoColor=white" alt="Python 3.8+" />
  <img src="https://img.shields.io/badge/shell-bash-4.0%2B-4EAA25?style=flat-square&logo=gnu-bash&logoColor=white" alt="Bash 4+" />
  <img src="https://img.shields.io/badge/platforms-Windows%20%7C%20Linux%20%7C%20macOS-471717?style=flat-square" alt="Cross platform" />
</p>

<p align="center">
  <a href="#快速开始">快速开始</a> &nbsp;·&nbsp;
  <a href="#它解决什么问题">解决什么问题</a> &nbsp;·&nbsp;
  <a href="#适用场景与价值">适用场景与价值</a> &nbsp;·&nbsp;
  <a href="#工作原理">工作原理</a> &nbsp;·&nbsp;
  <a href="#输入契约">输入契约</a> &nbsp;·&nbsp;
  <a href="#输出">输出</a> &nbsp;·&nbsp;
  <a href="#脚本参考">脚本参考</a> &nbsp;·&nbsp;
  <a href="#证据模型">证据模型</a> &nbsp;·&nbsp;
  <a href="#已知局限">已知局限</a> &nbsp;·&nbsp;
  <a href="#参与贡献">贡献</a>
</p>

---

## 快速开始

把 skill 装进 Claude Code，然后给它三样东西：**报错信息**、**出错的代码路径**、**版本区间**。

### 安装

<details open>
<summary><b>npm（跨平台，一步到位）</b> —— 推荐</summary>

```bash
# 无需全局安装，npx 直接跑安装器
npx @yanyan2015/defect-resolution install

# 或先全局安装，再运行安装命令（全局命令名是 defect-resolution）
npm install -g @yanyan2015/defect-resolution
defect-resolution install

# 卸载
defect-resolution uninstall
```

安装器把 skill 文件复制到 `~/.claude/skills/defect-resolution`，并检查 `git` / `bash`
是否可用（只提示，不联网、不改 PATH）。重启 Claude Code 后生效。

</details>

<details>
<summary><b>Windows（PowerShell）</b></summary>

```powershell
# 在仓库目录下
.\install.ps1

# 可选参数
.\install.ps1 -Scope AllUsers     # 为所有用户安装（需管理员）
.\install.ps1 -Target "D:\tools\dr" # 装到指定目录
.\install.ps1 -NoPath             # 不改 PATH
.\install.ps1 -Uninstall          # 卸载
```

安装脚本会：定位 Git Bash → 复制 skill 文件 → 把 Git Bash 目录加入用户 PATH →
跑一遍**真实冒烟测试**（建临时仓库、走完取证管线）→ 报告结果。

**前置要求**：Git for Windows（自带 Git Bash）。没有的话脚本会明确提示并给出下载地址。
Python 是可选的，只影响 `extract_symbols.py` 符号抽取器。

> ⚠️ 执行策略：若提示"禁止运行脚本"，先执行
> `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned`

</details>

<details>
<summary><b>macOS / Linux</b></summary>

```bash
# 作为 skill 安装
git clone https://github.com/yanyan2015/defect-resolution.git ~/.claude/skills/defect-resolution

# 或作为 Claude Code plugin 安装
claude plugin install yanyan2015/defect-resolution
```

需要：`git` 2.20+、`bash` 4+；`python` 3.8+ 可选（用于符号抽取器）。

</details>

<details>
<summary><b>Windows（Git Bash）</b></summary>

```bash
git clone https://github.com/yanyan2015/defect-resolution.git ~/.claude/skills/defect-resolution
```

或直接用上面的 `install.ps1` / `npx @yanyan2015/defect-resolution install`（后者会一并做依赖检查）。

</details>

### 使用

装好之后直接说：

```text
帮我确认这个 bug 是在哪个版本、哪次提交修好的：

仓库：https://github.com/curl/curl.git
问题版本：v8.4.0
修复版本：v8.5.0
报错：
  src/lib/curl_easy.c:1204: warning: implicit declaration of function 'Curl_getdate'
  src/lib/transfer.c:88: error: 'conn->bits.close' undeclared
出问题的地方：src/lib/transfer.c 第 80-95 行
```

Defect Resolution 会输出：

```markdown
## 结论
- **修复 commit**：`a1b2c3d4`（`transfer: fix connection reuse after TLS renegotiation`）
- **修复版本**：v8.4.1（首次包含该修复的发布版本，2026-01-14）
- **缺陷版本**：v8.4.0（最后一个仍含此缺陷的发布版本）
- **所属分支**：main
- **可信度**：高 —— 强候选唯一 + 真实 bisect 通过 + message 关联 issue #9876

## 证据链
1. 版本锚点：问题版本 c1f23bc（v8.4.0），修复版本 d4e5f6a（v8.5.0），候选范围 412 个 commit
   - 版本序列：v8.4.0 → v8.4.1 → v8.5.0（修复落在其中 v8.4.1）
2. 定位依据：
   - blame：v8.4.1:src/lib/transfer.c:88 归属 a1b2c3d4（父版本中该行归属 9f8e7d6）
   - pickaxe：`git log -S'close'` 命中 a1b2c3d4；`-G'bits\.close'` 命中 a1b2c3d4
   - -L：80,95:src/lib/transfer.c 变更历史中的 a1b2c3d4
3. 语义筛选：diff 把 `conn->bits.close` 的写入移入 `Curl_conn_shutdown()`，
   修复了 reuse 路径上未初始化位的读取
4. 交叉验证：
   - 方法 A（真实 bisect）：first bad commit = a1b2c3d4 ✓
   - 方法 B（父提交对比）：父提交中该位未初始化；候选提交中已初始化 ✓
   - 方法 C（反向验证）：revert 后触发条件重建 ✓
5. 版本归属：首次包含该修复的发布版本 v8.4.1；上一个仍含缺陷的版本 v8.4.0
```

> 注意：**修复不一定在用户说的那个"修复版本"上**。用户通常只知道「v8.4.0 有 bug，v8.5.0 好了」，而修复可能早在中间的 v8.4.1 就合入了。Defect Resolution 会在**版本维度**上逐个检查发布版本，先确定 bug 在哪个版本消失，再在那个更窄的区间里锁定具体提交。

### 也适用于非开源的本地代码

**非开源 ≠ 非 git。** 绝大多数私有项目使用 git，只是仓库不公开 —— 取证流程与开源场景完全一致，且全程本地进行：

```text
帮我确认这个 bug 是在哪个版本、哪次提交修好的：

仓库：D:\projects\my-private-service（本地 git 仓库）
问题版本：v2.3.0
修复版本：v2.4.0
报错：
  src/session.py:88: AttributeError: 'NoneType' object has no attribute 'get'
出问题的地方：src/session.py 第 80-95 行
```

私有仓库默认**零网络访问**，代码、报错内容、commit message 都不会离开你的机器。

---

## 它解决什么问题

开源项目里，一个报错摆在面前时，真正的问题从来不是「怎么修」——而是**「这是谁、哪一次改动造成的，上游是在哪个提交修掉的」**。

你手上通常有：

- 一段报错日志 / 堆栈 / 编译错误
- 一个大概知道出问题的文件（或函数）
- 一个「已经好了」的版本或一段修好的代码

缺的是那条因果链。手工找的代价是：

| 手工做法 | 代价 |
|---|---|
| `git log --oneline` 翻几百条 | 修复常常被后续重构淹没，看不出来 |
| `git blame` 看某一行 | blame 显示的是「最后一次触碰」，可能是个格式化提交 |
| `git log -S<符号>` | 符号太常见时命中一堆，无关的排前面 |
| 读 diff 猜 | 读到最后只能靠"感觉像"，给不出可信度 |

Defect Resolution 把这件事变成一条**可复现、可审计、可交叉验证**的流水线：六条互补取证通道 → 加权证据表 → 语义分档 → 至少两种方法交叉验证 → 带可信度的结论。

它的输出不是"我觉得是这里"，而是**每一条结论都挂着产出它的那条命令**。

---

## 适用场景与价值

**覆盖主流 Linux 发行版**：CentOS、Ubuntu、openEuler、AnolisOS、UOS、麒麟（KylinOS）等桌面与服务器系统均在支持范围内。当某个系统上运行的开源软件找不到对应的源码时，通常也能在开源社区里找到替代 —— 同一版本的 RPM 软件包，在这些系统之间的源码几乎完全一致，差异只在包文件后缀。也就是说，**从任何一个发行版的源码包出发，都能归因到上游的修复提交**。

**它为两类使用者省下真金白银：**

| 使用者 | 能得到什么 |
|---|---|
| **开源软件的使用方**（企业 / 团队） | 遇到开源软件的报错时**自助定位补丁**：找到官方修复提交、确认该升级到哪个版本、把上游补丁 backport 到自己的版本 —— 不必为每个报错购买原厂咨询服务，降低研发投入与咨询支出 |
| **系统厂商**（OSV / 发行版维护者） | 显著提升售前、售后运维与技术支持团队的排障效率：报障进来后快速产出**问题分析报告**（修复版本 + 修复提交 + 证据链 + 解决机制），把研发级技术支持的成本压到最低 —— 让研发资源聚焦核心研发与更有价值的事情，而不是替一线支持逐个查 commit |

---

## 工作原理

```text
  阶段 0                 阶段 1                  阶段 1.5                阶段 2
  仓库就绪      ──▶    建立版本锚点      ──▶   版本维度判定     ──▶   定位变更历史
  ─────────────          ─────────────          ──────────────         ─────────────────
  本地/远程获取          A/B 解析成 commit     逐个发布版本检查        ① -L 行范围历史
  完整性体检              merge-base             "bug 还在吗？"         ② 两版 blame 对比
                        候选范围计数            → FIX_VERSION          ③ pickaxe -S/-G
                        版本序列               → 收窄取证区间         ④ 已修复代码反查
                                                                 ⑤ commit message
                                                                 ⑥ 跨路径扩散
                        │                          │                          │
                        ▼                          ▼                          ▼
  阶段 5                 阶段 4                  阶段 3
  解释机制       ◀──▶    确定性验证       ◀──▶    语义筛选
  ─────────────          ─────────────          ─────────────
  触发条件                A 二分(bisect)          强候选/弱候选/排除
  变更内容                B 父提交对比            ──▶ 确认闸门 ⏸
  消除机制                C 反向验证(revert)            （等你点头）
  反事实自检                D 版本归属                     │
                                                    ▼
                                              阶段 6 输出结论
```

几个关键设计：

**先定版本，再定提交。** 用户问的是"哪个版本修好的"，而发布版本序列是**离散的、可逐个检查的** —— 这是一个天然的粗筛粒度。先在版本维度上找到"bug 消失"的第一个版本，再在那个更窄的区间里做提交级取证。区间常常从几百个提交缩到个位数。

**行漂移免疫。** 报错里的行号属于**问题版本**；修复版本因为插入/删除行会整体位移。所以 blame 判定用**内容锚定**而不是行号筛选：把报错区的行内容逐行在修复版本里定位，得到锚定区间，再看区间内哪些行的归属提交落在候选范围内。这同时覆盖"改写报错行"和"在报错行前插入守卫"两种修复形态。

**证据加权而非计数。** 命中"已修复代码的原文行"（权重 5）远强于命中"同目录下另一个文件被改过"（权重 1）。排序反映的是证据强度，不是出现次数。

**验证是硬性的。** 阶段 4 至少两种方法交叉验证，跑不了就明说"无法验证"并降级可信度 —— 不用推测填空。

**人机闸门。** 阶段 3 之后停下，把强/弱/排除三档摆给你看，等你确认再往下走。避免在错误候选上浪费构建和 bisect 的时间。

---

## 输入契约

| 输入 | 必需 | 形态 | 缺失时怎么办 |
|---|:---:|---|---|
| 报错信息 | ✅ | 完整日志 / 堆栈 / 编译错误 | — |
| 问题代码路径 | ✅ | `文件[:函数][:行范围]` | — |
| 仓库 | ✅ | **本地目录**（开源仓库副本 / 私有项目）或 `https://…/owner/repo.git` | — |
| 问题版本 | 强烈建议 | tag / branch / commit / 本地 HEAD | 取修复 commit 的父提交 |
| 修复版本 | 建议 | tag / branch / commit | 见下方降级链 |
| 已修复代码 | 选填 | (a) 可解析的版本引用 (b) 文本片段 (c) 两者 | 见下方降级链 |
| 复现命令 | 选填 | 一行能在"坏"版本失败、在"好"版本成功的命令 → 使真实 `git bisect run` 可用 | 只做静态验证，可信度封顶「中」 |

**版本区间是主输入。** 典型场景给的是两个版本：「在 v1.2.0 报这个错，v1.3.0 就好了」。skill 会先在**版本维度**上逐个检查区间内的发布版本，确定 bug 在哪个版本消失，然后在那个更窄的区间里锁定具体提交。

**降级链**（缺输入时不干等，按此降级并在结论中标注）：

1. 只有修复代码文本 → 逐行 pickaxe 反查，这是最强信号（权重 5）
2. 只有修复版本 → 问题版本锚定为 `<fix>^`
3. 只有问题版本 → 修复版本取默认分支 HEAD，靠 pickaxe 定位
4. 仓库没有 tag（项目不打版本标签）→ 用分支或 commit 作为版本锚点，并在结论中说明"该仓库无发布标签，无法给出发布版本号，只能给出 commit 与分支"
5. 仓库历史不完整 → 先 `git fetch --unshallow`，否则明确标注可信度受限
6. **非 git 的代码目录** → 无法做版本归因（没有历史就没有证据链）。skill 会说明原因并给出三条出路，而不是硬凑一个结论

---

## 输出

固定模板，四段式：**结论 → 证据链 → 解决机制 → 未确定项**。

- **结论**：commit、所属版本、可信度（高/中/低）+ 依据
- **证据链**：版本锚点 → 定位依据（blame / pickaxe / -L 具体命中）→ 语义筛选 → 交叉验证 → 其它佐证
- **解决机制**：报错触发条件 → 变更内容 → 消除机制 → 反事实自检（只回退这一行，报错是否必然重现？）
- **未确定项**：多候选时列出全部候选、各自可信度，以及一条可执行的区分建议

**可信度判定**（不是拍脑袋，有明确门槛）：

| 等级 | 条件 |
|---|---|
| **高** | 强候选唯一 + 方法 B 通过 + 下列任一：真实 bisect 通过 / 反向验证通过 / message 与 issue 明确对应 |
| **中** | 强候选唯一但只有静态证据；或多候选但其中一个在 3 条通道命中而其余只有 1 条 |
| **低** | 仅单通道命中、语义关联弱；或候选无法区分；或仓库历史不完整 |

降级理由必须写进「可信度」行，不允许只给等级。

---

## 脚本参考

skill 自带 6 个取证脚本，都可以直接单独调用。

| 脚本 | 用途 | 关键选项 |
|---|---|---|
| `acquire.sh` | 阶段 0：获取仓库 | `--checkout` `--full` `--offline`（强制零网络） |
| `anchor.sh` | 阶段 1：版本锚点 | `--path` `--limit`；修复版本传 `-` 进入降级模式 |
| `version_bisect.sh` | 阶段 1.5：**版本维度**判定 | `--path` `--range` `--contains` `--sym` `--missing` `--run-cmd` `--tag-list` |
| `extract_symbols.py` | 阶段 2：符号/关键词抽取 | `--kind syms\|greps\|paths` |
| `collect.sh` | 阶段 2：六通道取证 | `--path` `--range` `--sym` `--symfile` `--grepfile` `--fixed` `--wide` |
| `inspect.sh` | 阶段 3：候选语义卡片 + 版本归属 | `--path` `--sym` `--fixed` `--error-file` `--context` |
| `verify.sh` | 阶段 4：三种验证方法 | `--A` `--B` `--path` `--sym` `--range` `--fixed` `--run-cmd` |

`collect.sh` 的输出是**加权证据表**，机器可读行格式：

```text
CAND|<short-sha>|<full-sha>|<权重>|<证据条数>|<日期>|<标题>|<所在分支>
```

单独用某个脚本：

```bash
# 在仓库目录下
S=./scripts

# 第一步：版本维度 —— 先确定 bug 在哪个版本消失
bash "$S/version_bisect.sh" <repo> v1.0.0 v2.0.0 \
  --path src/foo.c --contains 'strcpy(buf, s);'
# → FIX_VERSION=v1.1.0   STILL_BROKEN_BEFORE=v1.0.1

# 第二步：在收窄后的区间里做提交级取证
bash "$S/collect.sh" <repo> v1.0.1 v1.1.0 \
  --path src/foo.c --range 80,95 \
  --fixed /tmp/fixed.txt --error-file /tmp/error.log

# 第三步：拿真实 bisect 证据（判据：触发条件仍在 → exit 0）
bash "$S/verify.sh" <repo> <candidate> --A v1.0.1 --B v1.1.0 \
  --path src/foo.c --run-cmd 'make 2>&1 | grep -q "error: .FOO_H. undeclared"'
```

在 Windows PowerShell 里（假设 Git Bash 在 `C:\Program Files\Git`）：

```powershell
& 'C:\Program Files\Git\bin\bash.exe' 'C:\path\to\defect-resolution\scripts\collect.sh' `
    <repo> v1.0 v2.0 --path src/foo.c --range 80,95
```

---

## 证据模型

每条证据带权重，权重和决定候选排序。**权重高 ≠ 可信度高** —— 可信度还要看验证结果。

| 证据 | 权重 | 说明 |
|---|:---:|---|
| 修复代码行 pickaxe（限路径） | 5 | 最强信号：修复版原文出现在该提交里 |
| 报错符号 pickaxe（限路径） | 4 | `-S` 命中 |
| `-G` 正则命中（限路径） | 3 | 内容改写但出现次数不变（条件判断、边界计算） |
| `-L` 行范围变更历史 | 3 | 该行区间的完整演变 |
| blame 锚定区间归属 | 3 | 报错区在修复版本中的实际位置归属 |
| 报错行被删除/改写 | 3 | 内容在修复版本中消失 |
| 报错符号 pickaxe（全仓） | 3 | 修复可能在别处 |
| commit message 命中 issue 号 | 2 | `#1234` / `fixes #1234` / `Closes:` |
| 问题版本报错行的原始归属 | 2 | |
| 同目录兄弟文件 / 构建文件 / 符号全仓改动 | 1 | **弱信号，必须人工确认** |

---

## 什么时候该用 / 不该用

**该用：**

- 上游项目报了个错，想知道官方**在哪个版本**修好的
- 上游项目报了个错，想知道官方是**哪次提交**修的
- 需要确认某个 backport / cherry-pick 是否包含真正的修复
- 想定位「这个 bug 是哪次改动引入的」（反向归因，同一套证据链）
- 排查 CI 偶发失败：是哪个提交开始出现的（真 bisect）
- **私有项目 / 本地代码**的同类问题（只要是 git 仓库，流程一致，全程本地）
- 给团队解释「这个报错到底为什么消失了」

**不该用：**

- 要**写**一个新修复（这是改代码任务，不是取证任务）
- 只问某行代码是谁写的（`git blame` 一句话的事）
- 修复 commit 已经知道了，只需要解释代码
- 代码评审、常规 git 操作

---

## 已知局限

诚实地说明边界，比假装什么都能干有用：

- **浅克隆会让结论失真。** blame / pickaxe / merge-base 全部依赖完整历史。skill 会强制 blobless clone 并做体检，但如果你自己喂了一个 `--depth=1` 的仓库，可信度要下调。
- **上游 rebase / squash 会抹掉原始提交。** 修复被压扁后原始 commit 不存在了，此时只能给出"包含该修复的首个发布 tag"，并在可信度里说明。
- **没有复现命令就没有真实 bisect。** 静态证据只能排除"更早的等价修复"，不能证明原报错真的消失 —— 结论里会如实标注，可信度封顶「中」。
- **修复不在报错文件里时信号很弱。** 改 Makefile、头文件、依赖 pin、CI 配置的场景，通道 6 只能给出权重 1 的弱线索，需要人工确认。
- **版本判定依赖发布标签。** 项目不打 tag、用 release 分支发版、或"版本"对应 tarball 而非 git tag 时，无法给出发布版本号 —— 此时只给 commit 与分支，并如实说明。
- **同一 bug 可能有多个修复。** 主干和 `X.Y-stable` 各自修一次（backport）时，skill 会给出两个候选并标明各自适用的分支与版本。
- **只覆盖 Git。** Mercurial / SVN 的历史无法直接分析。
- **不联网查 issue 内容。** issue 号只用于在 commit message 里做本地匹配；要看 issue 正文请自行打开链接。

---

## 参与贡献

发现 bug、想加一条取证通道、或者想改进判据设计，都欢迎。

```bash
git clone https://github.com/yanyan2015/defect-resolution.git
cd defect-resolution
bash test/run-tests.sh        # 跑取证脚本的回归测试
```

提交 PR 前请读 [CONTRIBUTING.md](CONTRIBUTING.md)。安全相关问题请按 [SECURITY.md](SECURITY.md) 私下报告，不要开公开 issue。

设计取舍与取舍理由见 [DESIGN.md](DESIGN.md)。

---

## License

[MIT](LICENSE) © 2026 yanshuai

脚本与文档均以 MIT 协议发布。你可以在自己的项目里自由使用、修改、分发。
