# Contributing to Defect Resolution

感谢你愿意参与。这个项目的价值建立在**结论可信**之上 —— 所以贡献不只是加功能，更重要的是**提高证据强度或降低误判**。

如果你要修的是一个取证逻辑的 bug，请先读 [DESIGN.md](DESIGN.md) 的「已知技术债」一节 —— 那里列出的每一条都是已知且被接受的状态，欢迎直接接手。

---

## 选择合适的贡献路径

| 你想做的事 | 从这里开始 |
|---|---|
| 报一个 bug | 开 issue，附上复现步骤和实际输出 |
| 提一个想法 | 开 issue 讨论，先对齐再写代码 |
| 加一条取证通道 | 见下方「新增取证通道」 |
| 改判据 / 权重 | 见下方「修改证据模型」 |
| 修文档 | 直接改，提 PR |
| 改脚本 | 见下方「本地开发与验证」 |

**大改动（新增通道、改权重表、重构脚本）请先开 issue 对齐**，避免 PR 被拒在设计层面。

---

## 提交一个可评审的改动

1. **一个 PR 一件事。** 混在一起的 PR 很难评审。
2. **说清动机。** PR 描述里回答：现在什么不对？你怎么发现的？改完之后什么对了？
3. **附上证据。** 如果是取证逻辑的改动，附上"改之前漏了 / 误判了"的具体例子，以及"改之后"的输出。
4. **带上回归测试。** 新增或修改取证逻辑，必须在 `test/run-tests.sh` 里加一个场景。
5. **不要改动无关文件。** 格式化、换行、重命名混在功能改动里会让 diff 无法阅读。

---

## 本地开发与验证

```bash
git clone https://github.com/yanyan2015/defect-resolution.git
cd defect-resolution

# 跑全部回归测试
bash test/run-tests.sh

# 只跑一个场景
bash test/run-tests.sh line_drift
bash test/run-tests.sh cross_path
```

Windows PowerShell 下：

```powershell
git clone https://github.com/yanyan2015/defect-resolution.git
cd defect-resolution
& 'C:\Program Files\Git\bin\bash.exe' test/run-tests.sh
```

### 仓库布局

```
.
├── SKILL.md              skill 定义（Claude Code 读这个）
├── scripts/              取证脚本（bash + 一个 python）
│   ├── lib.sh            脚本间的共用函数
│   ├── acquire.sh        阶段 0：获取仓库
│   ├── anchor.sh         阶段 1：版本锚点
│   ├── version_bisect.sh 阶段 1.5：版本维度判定
│   ├── extract_symbols.py 阶段 2：符号抽取
│   ├── collect.sh        阶段 2：六通道取证
│   ├── inspect.sh        阶段 3：候选卡片
│   └── verify.sh         阶段 4：验证
├── references/           按需加载的速查文档
├── test/run-tests.sh     回归测试
├── bin/cli.js            npm 安装器（npx @yanyan2015/defect-resolution install）
├── package.json          npm 包清单（scoped 包 @yanyan2015/defect-resolution；运行时零依赖）
├── install.ps1           Windows PowerShell 安装脚本
└── .claude-plugin/       plugin 清单与图标
```

> skill 本体放在**仓库根目录**（不是 `.claude/skills/` 下），这样仓库既可以作为
> plugin 安装（`claude plugin install`），也可以整仓 clone 到 `~/.claude/skills/` 当普通 skill 用。

### 测试怎么写

回归测试用**构造 fixture 仓库**的方式：脚本自己 `git init` 一个临时仓库，造出"有 bug 的版本 + 噪声提交 + 修复提交"，然后断言取证脚本给出的结论。

```bash
# 造一个仓库：v1 有缺陷，v2 修好了
make_fixture() {
  local dir="$1"
  mkdir -p "$dir/src" && cd "$dir"
  git init -q -b main .
  git config user.email test@test
  git config user.name test
  # ... 写文件、commit ...
}
```

断言写成"检查脚本输出里有没有出现期望的 commit"：

```bash
assert_candidate "$OUT" "$FIX_COMMIT" "真修复必须在候选里"
assert_no_candidate "$OUT" "$NOISE_COMMIT" "噪声提交不该进候选"
```

**关键：每个测试场景要包含一个"噪声提交"**。只有正向断言（真修复能被发现）的测试无法发现排序错误 —— 真实事故往往是真修复被噪声提交挤下去。

### 代码风格

- Shell 脚本：`bash -n` 必须通过；变量用小写 + 下划线；引用变量一律加双引号。
- **必须加 `|| true` 或 `return 0`** —— 在 `set -e` 下，管道消费者函数的最后一个命令返回非 0 会直接杀死脚本。这是个已踩过的坑，新写函数时请特别注意。
- Python：标准库 only，不引入第三方依赖。
- 注释写"为什么"，不写"是什么"。代码本身能说明的事不用重复。

---

## 新增取证通道

这是最常见的贡献形式。一条新通道要满足：

1. **正交性。** 它能抓到其它通道抓不到的东西。如果它只是"现有通道换个参数"，请改现有通道而不是新增。
2. **独立权重。** 在 `collect.sh` 的权重表里给出权重，并说明为什么是这个值。权重不是拍脑袋 —— 它反映"这条证据有多难被误触发"。
3. **有回归测试。** 构造一个场景：其它通道都会漏，只有新通道能捞出来。
4. **写进 `references/git-forensics.md`。** 解释这条通道依赖的 git 语义，以及它的盲区。

新通道的标准位置是 `collect.sh` 里按编号排列的通道块，输出格式统一为：

```bash
record "$full_sha" <权重> "<证据类型>" "<人类可读说明>"
```

---

## 修改证据模型

改权重或改判据是很敏感的改动 —— 它会改变所有结论的排序和定级。请在 PR 里附上**改动前后对同一批 fixture 的候选排序对比**。

判断标准：

- 调高某条证据的权重 → 需要说明为什么它比现在更可信
- 调低 → 需要说明它现在会被什么情况误触发
- 改可信度门槛 → 需要同步更新 `SKILL.md` 的打分表和 `references/verification.md` 的验证矩阵

**权重和可信度是两回事**，见 DESIGN.md 第 2 节。改动请保持这个区分。

---

## AI 辅助与责任归属

欢迎使用 AI 辅助开发。请注意：

- **PR 作者对代码负责。** AI 生成的代码和人工写的代码承担同样的评审标准。
- 如果使用了 AI，请在 PR 描述里说明用在了哪些部分，以及你是怎么验证它的。
- 涉及取证逻辑的改动，**必须**由人实际跑过完整流程并检查输出 —— 取证脚本的错误往往不会报错，而是安静地给出错误结论。

---

## Commit 约定

用 [Conventional Commits](https://www.conventionalcommits.org/)：

```
feat: 新增跨路径扩散通道（构建文件变更检测）
fix: 修正 blame 行漂移导致的归属错位
docs: 补充 bisect 判据方向说明
test: 增加修复在别处的回归场景
refactor: 提取 pickaxe 通道的公共逻辑
```

---

## License

提交即表示你同意你的贡献以 [MIT License](LICENSE) 发布。

---

## 需要帮助？

- 讨论设计 → 开 issue 或 discussion
- 报告安全问题 → 见 [SECURITY.md](SECURITY.md)，**不要**开公开 issue
