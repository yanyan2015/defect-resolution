# Git 取证命令语义与陷阱（阶段 1–3 速查）

按实际语义整理，执行时回查。所有示例假设 `REPO` 已定位、`A`=问题版本、`B`=修复版本。

## 1. 版本锚点

```bash
git -C $REPO rev-parse --verify 'v1.2.3^{commit}'   # tag → commit；分支同理
git -C $REPO rev-parse --verify 'HEAD^{commit}'
git -C $REPO merge-base A B                          # 分叉点；为空 = 无关历史（通常意味着锚点给错了）
git -C $REPO rev-list --count A..B                   # 候选范围（B 可达、A 不可达）
```

- tag 可能是 annotated：`^{commit}` 剥掉 tag 对象；不加会拿到 tag 对象的 sha。
- 分支名必须解析成 commit 才算锚点建立；`A..B` 的语义是「在 B 不在 A」，与时间顺序无关。
- 若 A 不是 B 的祖先（分叉历史），`A..B` 仍有效但含义变成「B 侧独有」；此时补看 `git log --oneline --boundary A...B`（三点 + boundary）确认两侧差异。

## 2. 行级追溯：`git log -L`

```bash
git -C $REPO log -L 100,140:src/foo.c A..B        # 行范围在两版之间的完整演变
git -C $REPO log -L :func_name:src/foo.c A..B     # 整个函数（git 自行识别函数边界）
```

- `-L` **不能**与 `--follow` 同用；也不接受路径限定符以外的 pathspec。
- 行号以**起始 commit 侧**的文件为准；`-L` 自己跟踪行漂移，跨版本比对行号前先跑 `-L` 确认漂移量。
- 函数识别对 C 系可靠，对 Python/Rust 等缩进语言可能失败 —— 失败就退回行范围。
- 输出里每个 commit 的 diff 就是「这个 commit 对该区域做了什么」，可直接用于阶段 3。

## 3. blame 对比

```bash
git -C $REPO blame --line-porcelain B -- src/foo.c > /tmp/b.txt
git -C $REPO blame --line-porcelain A -- src/foo.c > /tmp/a.txt
```

- 用 `--line-porcelain`：默认格式给范围外边界提交加 `^` 前缀（如 `^abcd123`），直接解析会污染候选集。
- porcelain 头行结构：`<40位sha> <原始行号> <最终行号> [<行数>]`；随后若干以 `\t` 开头的内容行。
- 「修复版本中报错相关行的归属 commit ∈ A..B」是强证据；「A、B 两版同一行归属不同」说明该行被改写，两侧 commit 都进候选。
- blame 反映的是**最后一次触碰**，不是「修复」——后续格式化会覆盖真实修复的归属。这就是必须配合 pickaxe 的原因。

## 4. pickaxe：`-S` 与 `-G`

```bash
git -C $REPO log --oneline -S'symbol' A..B -- src/foo.c   # 出现次数变化（增/删）
git -C $REPO log --oneline -G'regex'  A..B -- src/foo.c   # 匹配行内容变化（改写）
```

| 场景 | `-S` | `-G` |
|---|---|---|
| 删除/新增宏定义、函数、字段 | ✅ | ✅（碰巧） |
| `if (p)` 改成 `if (p != NULL)`（符号出现次数不变） | ❌ | ✅ |
| `MAX_LEN` 的值 64→128（引用次数不变） | ❌ | ✅ |
| 跨行重排（内容变了但正则单行匹配不到） | ❌ | ❌（只能靠 -L/blame） |

- `-S` 的参数是**字面字符串**；`-G` 是**扩展正则**（POSIX ERE，非 PCRE）—— 括号、加号等元字符在 ERE 里有特殊含义，**必须转义**：`foo(bar)` 要写成 `foo\(bar\)`（`lib.sh` 的 `re_escape` 已处理）。实测确认：未转义的 `foo(bar)` 匹配不到 `foo(bar);` 这行代码。
- **性能**：每个符号 `-S` 和 `-G` 各跑一次 `git log`，Windows 上 git 进程启动 ~70ms，候选富化（`tag --contains` / `branch --contains`）每个候选又是数条调用。`collect.sh` 已做三项优化：短 hash 解析按候选缓存（`REVMAP`）、版本/分支归属只对前 `DR_TOPN`（默认 10）个候选富化、`--no-G` 跳过 `-G` 通道。大仓库（>10k tags）上 `--no-G` + 提高 `--min-weight` 可显著缩短运行时间。
- pickaxe 会**穿过 merge**：`git log -S` 检查的是每棵树的实际内容变化，修复由另一分支开发再 merge 进来时，`--no-merges` 的 log 会漏掉它，但 pickaxe 的 `-m` 缺省行为能对上内容变化。怀疑 merge 带入时：

```bash
git -C $REPO log --oneline -S'sym' A..B            # 含 merge 视角的命中
git -C $REPO log --oneline --no-merges -S'sym' A..B
git -C $REPO show -m --stat <merge-commit>          # 把 merge 按每一侧父提交展开
```

- pickaxe 命中数多（常见符号）时，加路径限定；仍多就提高符号特异性（用报错原文里的引号字面量，而不是泛化标识符）。

## 5. message 搜索

```bash
git -C $REPO log --oneline --grep='1234' --grep='segfault' -i A..B   # 多个 --grep 默认 OR
git -C $REPO log --oneline --all-match --grep='fix' --grep='null' A..B  # AND
git -C $REPO log --oneline --grep='error: null divisor' -F A..B      # -F 固定串（含冒号空格时用）
```

- issue 号搜裸数字 `1234` 容易误伤（行号、版本号）；优先 `#1234`、`fixes #1234`、trailer（`Closes:`/`Fixes:`）。

## 6. 查看单个提交

```bash
git -C $REPO show <c> -- src/foo.c                  # 该文件上的 diff
git -C $REPO show -w <c> -- src/foo.c               # 忽略空白：为空 ⇒ 纯格式提交（直接排除）
git -C $REPO show --stat --find-renames <c>          # 重命名检测（默认相似度 50%）
git -C $REPO show <c>^:src/foo.c                     # 父提交版本的文件内容
git -C $REPO show <c>:src/foo.c
git -C $REPO show -m --first-parent <merge>          # merge 按 first-parent 展开
```

- merge 提交不带 `-m` 时 `git show` **没有 diff 输出**——不是「没改动」，是默认不展开。这是最常见的误判来源。

## 7. 版本归属：哪个 tag 包含这个修复

```bash
# 该 tag 是否已包含这个提交？（tag 的 commit 是提交的祖先 → 已包含）
git -C $REPO merge-base --is-ancestor <fix> <tag>^{commit}

# 遍历所有 tag（按时间序）
git -C $REPO for-each-ref --format='%(refname:short) %(objectname)' --sort=creatordate refs/tags

# 哪些 tag 包含它
git -C $REPO tag --contains <fix>

# 哪些分支包含它（判断是否只合入了维护分支）
git -C $REPO branch -a --contains <fix>
```

**陷阱**：`git describe --tags --abbrev=0 <fix>` 返回的是**最近的上游 tag**，不是"首次包含它的 tag"。修复落在两个 tag 之间时它给出上一个 tag —— 那个还带着 bug 的版本。详见 `version-attribution.md`。

## 8. 历史完整性与重写

```bash
git -C $REPO rev-parse --is-shallow-repository       # true ⇒ 浅克隆，历史不完整
git -C $REPO log --oneline | wc -l vs rev-list --count HEAD   # log 管道可能被分页器截断，用 rev-list 计数
git -C $REPO log --follow --name-status -- src/foo.c # 找文件改名点
```

- shallow 仓库里 blame/pickaxe/merge-base 的结论只覆盖已拉取的历史；先 `git fetch --unshallow`（需要网络）。
- squash/rebase 重写历史后，原始修复 commit 不存在，只能给出「包含该修复的首个 tag」；commit message 里常留 `[backport]`/`cherry picked from <sha>` 可反查上游原 commit。

## 9. Windows / Git Bash 注意

- 路径一律正斜杠；`git -C <repo>` 优于 `cd`。
- `-S`/`-G`/`--grep` 参数用**单引号**包裹，避免 shell 展开（`$`、`*`、`?` 在双引号里仍会被解释）。
- `core.quotepath` 默认会把非 ASCII 路径转义，影响 `--name-only` 解析；分析时加 `-c core.quotepath=false`。
- Windows 的 `mktemp`、进程替换 `<(...)` 在 Git Bash 下可用；`timeout` 命令可能不存在，脚本需容错。
