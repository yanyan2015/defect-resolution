# 版本归属：这个 bug 在哪个版本修好的？

主场景的核心问题。回答它需要区分三个不同的概念，混淆它们会给出**错误答案**。

---

## 三个概念

| 概念 | 含义 | 正确算法 |
|---|---|---|
| **最近上游 tag** | `git describe --tags --abbrev=0 <fix>` | ❌ **不能用来回答这个问题** |
| **首次包含修复的发布版本** | 最早的、已包含该修复的 tag | ✅ 这是要回答的 |
| **最后一个仍含缺陷的版本** | 最早的、尚未包含该修复的 tag | ✅ 配套给出 |

### 为什么 `git describe` 是错的

```bash
$ git log --oneline --decorate
  aaa1111 (HEAD -> main, tag: v2.0.0) later work
  bbb2222 fix: guard NULL before strcpy     <- 修复在这里
  ccc3333 (tag: v1.0.0) v1.0.0: initial     <- 这里还有 bug

$ git describe --tags --abbrev=0 bbb2222
v1.0.0          # ← 错！v1.0.0 是有 bug 的版本
```

`git describe` 找的是**最近的可达祖先 tag**，而不是"包含它的最早 tag"。修复落在两个 tag 之间时，它给出的是**上一个** tag —— 恰恰是那个还带着 bug 的版本。

用这个结果回答"在哪个版本修好的"，会得到「v1.0.0 就修好了」这种荒谬结论。

### 正确算法

```bash
# 该 tag 是否已包含这个修复？= 该 tag 的 commit 是修复 commit 的后代
git merge-base --is-ancestor <fix> <tag>^{commit}
```

遍历所有 tag，取**满足条件的最早**那个（按 tag 的 creatordate 排序）：

```bash
git for-each-ref --format='%(refname:short) %(objectname)' --sort=creatordate refs/tags
```

`lib.sh` 的 `first_containing_tag()` 实现了这个逻辑，`inspect.sh` 与 `verify.sh` 都会打印结果：

```
=== 版本归属 ===
首次包含该修复的发布版本: v1.1.0  (2026-11-16)
同时包含该修复的其它版本: v2.0.0
上一个发布版本（仍含此缺陷）: v1.0.0
描述用的最近 tag:          v1.0.0   <- 仅供定位，不要当作"修复版本"
```

---

## 配套检查

```bash
# 修复在哪些分支上？—— 判断它是否进了主干
git branch -a --contains <fix>

# 哪些发布版本包含此修复？
git tag --contains <fix>

# 该修复是否被 cherry-pick / backport 过？（同一 bug 可能有多个修复 commit）
git log --all --oneline --grep='<issue 号>' -S'<符号>'
git log --all --cherry-mark --left-right --oneline <main>...<stable>
```

---

## 开源项目的真实复杂性

### 1. 维护分支

大多数开源项目有两条线：

```
main         (开发)     ──────┬───────► v3.0.0
                          fix
X.Y-stable  (维护)     ───fix──► v2.9.1
```

同一个修复可能有**两个 commit**：

- `main` 上的原始修复
- `X.Y-stable` 上的 backport（cherry-pick，message 常带 `[2.9]` 或 `backport`）

此时应给出**两个候选**，各自标明分支与版本：

> 修复 commit `aaa1111`（main，首次包含于 v3.0.0）；backport `bbb2222`（2.9-stable，首次包含于 v2.9.1）。2.9.1 用户需要的是后者。

### 2. 修复只在一侧

如果修复只在 `X.Y-stable` 上，主干还没有 —— 那么"升级到最新版本"并不能解决用户的 bug。结论里必须点明这一点，否则用户会误以为升到最新版就好了。

### 3. 没有 tag 的项目

很多项目用 release 分支而非 tag 发版，或者 tag 命名不统一（`v1.2.3` / `1.2.3` / `release-1.2.3` / `2024.01.15`）。

此时：

```bash
git tag -l | grep 1.2.3      # 模糊匹配
git branch -a | grep release  # 找发布分支
git log --oneline --grep='1\.2\.3'  # message 里带版本号
```

如果实在找不到发布标记，结论里写「该仓库无发布标签，无法给出发布版本号，只能定位到 commit `<hash>` 与分支 `<branch>`」—— 而不是硬套一个 `nearest_tag`。

### 4. 快照式发行版

有些项目的"版本"对应的是 tarball/zip 下载，而不是 git tag。这种情况下 git 历史里的 commit 与"用户下载的版本"没有一一对应关系。应如实说明无法把 commit 映射到发行版。

---

## 与取证流程的衔接

版本归属不是独立的一步，而是取证结论的**组成部分**：

```
阶段 1  建立锚点（A=问题版本, B=用户认为修好的版本）
         └─ 输出 TAG_SEQUENCE：区间内的发布版本序列
              → 提醒：修复可能落在其中任一个，不一定是 B
阶段 2-3  定位候选 commit
阶段 4  方法 D：版本归属确认
         └─ 首次包含修复的发布版本 + 上一个仍含缺陷的版本
阶段 6  输出：修复版本 + 修复 commit + 可信度
```

**为什么阶段 1 要输出版本序列**：因为用户给的"修复版本"通常只是"我确认这个版本是好的"，修复可能早在中间某个版本就合入了。如果不提醒，agent 会把候选范围当成"最后一次发布前的所有改动"，浪费取证精力在无关提交上。
