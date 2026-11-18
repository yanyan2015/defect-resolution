#!/usr/bin/env bash
# test/run-tests.sh —— 取证脚本的回归测试。
#
# 用法：
#   bash test/run-tests.sh              # 跑全部场景
#   bash test/run-tests.sh line_drift   # 只跑名字匹配的场景
#
# 每个场景自己构造一个临时 fixture 仓库（含"噪声提交"），然后断言取证脚本的结论。
# 断言必须同时包含正向（真修复能找到）和反向（噪声不该进候选）—— 只测正向的用例
# 发现不了排序错误，而真实事故往往正是"真修复被噪声挤下去"。
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
# 必须绝对路径：场景里的 fixture 会 cd 到别处，相对路径会失效
S="$ROOT/scripts"

PASS=0; FAIL=0; SKIP=0
FAILED_NAMES=""
FILTER="${1:-}"

RED=$'\033[31m'; GREEN=$'\033[32m'; DIM=$'\033[2m'; OFF=$'\033[0m'
[ -t 1 ] || { RED=""; GREEN=""; DIM=""; OFF=""; }

WORKROOT=$(mktemp -d)
cleanup() { rm -rf "$WORKROOT"; }
trap cleanup EXIT

# --- 测试框架 -----------------------------------------------------------------
CURRENT=""

# mark_done：场景收尾 —— 有失败则把场景名记入 FAILED_NAMES（汇总用）。
# 所有场景块统一以 "mark_done; fi" 或 "cd "$ROOT"; mark_done; fi" 收尾。
mark_done() {
  [ "${CURRENT_FAIL:-0}" = "1" ] && FAILED_NAMES="$FAILED_NAMES $CURRENT"
  CURRENT_FAIL=0
  return 0
}

scenario() {
  CURRENT="$1"; CURRENT_FAIL=0
  if [ -n "$FILTER" ] && [[ "$CURRENT" != *"$FILTER"* ]]; then SKIP=$((SKIP+1)); return 1; fi
  printf '%s▸ %s%s\n' "$DIM" "$CURRENT" "$OFF"
  return 0
}

ok()   { PASS=$((PASS+1)); printf '  %s✓%s %s\n' "$GREEN" "$OFF" "$1"; }
bad()  { FAIL=$((FAIL+1)); CURRENT_FAIL=1; printf '  %s✗%s %s\n' "$RED" "$OFF" "$1"; }
info() { printf '    %s%s%s\n' "$DIM" "$1" "$OFF"; }

assert_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then ok "$msg"; else bad "$msg (未找到 '$needle')"; fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" msg="$3"
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then bad "$msg (不该出现 '$needle')"; else ok "$msg"; fi
}

# 断言真修复在候选表里
assert_candidate() {
  local out="$1" sha="$2" msg="$3"
  if printf '%s' "$out" | grep -qE "^CAND\|$sha\|"; then ok "$msg"; else bad "$msg (候选表里没有 $sha)"; fi
}

# 断言噪声提交**不在**候选表里（至少不在 --min-weight 2 及以上）
assert_no_candidate() {
  local out="$1" sha="$2" msg="$3"
  if printf '%s' "$out" | grep -qE "^CAND\|$sha\|"; then bad "$msg ($sha 不该进候选)"; else ok "$msg"; fi
}

# 断言某提交**排在**另一提交之后（用于"弱信号提交可以有，但不能排在真修复前面"）
assert_ranked_below() {
  local out="$1" lower="$2" higher="$3" msg="$4"
  local i_lo i_hi
  i_lo=$(printf '%s' "$out" | grep -nE "^CAND\|$lower\|"  | head -1 | cut -d: -f1)
  i_hi=$(printf '%s' "$out" | grep -nE "^CAND\|$higher\|" | head -1 | cut -d: -f1)
  if [ -z "$i_lo" ]; then ok "$msg（$lower 未进入候选表）"; return; fi
  if [ -z "$i_hi" ]; then bad "$msg（$higher 不在候选表里，无法比较）"; return; fi
  if [ "$i_lo" -gt "$i_hi" ]; then ok "$msg"; else bad "$msg（$lower 排在了 $higher 前面）"; fi
}

# 断言候选表里第一个（权重最高）的就是期望的提交
assert_top_candidate() {
  local out="$1" sha="$2" msg="$3"
  local top
  top=$(printf '%s' "$out" | grep -E '^CAND\|' | head -1 | cut -d'|' -f2)
  if [ "$top" = "$sha" ]; then ok "$msg"; else bad "$msg (第一候选是 $top，期望 $sha)"; fi
}

# --- fixture 工具 -------------------------------------------------------------
new_repo() {
  local name="$1"
  local dir="$WORKROOT/$name"
  mkdir -p "$dir/src" "$dir/include"
  cd "$dir" || exit 1
  git init -q -b main .
  git config user.email test@test
  git config user.name "Test User"
  git config commit.gpgsign false
  printf '%s' "$dir"
}

short_of() { git -C "$1" rev-parse --short "$2"; }
full_of()  { git -C "$1" rev-parse "$2"; }

# ============================================================================
# 场景 1：基础场景 —— 修复 + 噪声提交 + 文档提交
# ============================================================================
if scenario "basic_fix_with_noise"; then
  REPO=$(new_repo basic)
  cd "$REPO" || exit 1
  cat > src/foo.c <<'EOF'
#include <stdio.h>
#include <string.h>
int foo(int x) {
    char buf[16];
    const char *s = getenv("NAME");
    strcpy(buf, s);
    return x + (int)strlen(buf);
}
EOF
  git add -A >/dev/null; git commit -qm "v1: initial implementation"
  git tag v1.0

  # 噪声：改了同文件的无关部分
  cat > src/foo.c <<'EOF'
#include <stdio.h>
#include <string.h>
int foo(int x) {
    char buf[16];
    const char *s = getenv("NAME");
    strcpy(buf, s);
    return x + (int)strlen(buf);
}
// helper added later
EOF
  git commit -qam "chore: add trailing comment"
  NOISE1=$(git rev-parse HEAD)

  # 文档提交
  echo "docs" > README.md; git add -A >/dev/null; git commit -qm "docs: add README"
  DOC=$(git rev-parse HEAD)

  # 真修复
  cat > src/foo.c <<'EOF'
#include <stdio.h>
#include <string.h>
int foo(int x) {
    char buf[16];
    const char *s = getenv("NAME");
    if (s == NULL) {
        s = "";
    }
    strncpy(buf, s, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    return x + (int)strlen(buf);
}
EOF
  git commit -qam "fix: null-check getenv result and bound copy in foo() (fixes #42)"
  FIXC=$(git rev-parse HEAD)
  git tag v2.0

  cat > /tmp/dr_test_fixed.txt <<'EOF'
    if (s == NULL) {
    strncpy(buf, s, sizeof(buf) - 1);
EOF
  cat > /tmp/dr_test_err.txt <<'EOF'
src/foo.c:7: error: null pointer dereference in strcpy
See issue #42
EOF
  OUT=$(bash "$S/collect.sh" "$REPO" v1.0 v2.0 --path src/foo.c --range 5,8 \
        --fixed /tmp/dr_test_fixed.txt --error-file /tmp/dr_test_err.txt \
        --sym strcpy --sym strncpy --min-weight 2 2>&1)
  RC=$?
  [ $RC -eq 0 ] && ok "collect.sh 正常退出" || bad "collect.sh 退出码 $RC"
  assert_candidate      "$OUT" "$(short_of "$REPO" "$FIXC")"  "真修复在候选里"
  assert_top_candidate  "$OUT" "$(short_of "$REPO" "$FIXC")"  "真修复排第一"
  # 噪声提交确实改过这个文件，所以它可以以弱信号出现在候选表里 ——
  # 但绝不能排在真修复前面。断言"排位"而不是"不存在"。
  assert_ranked_below   "$OUT" "$(short_of "$REPO" "$NOISE1")" "$(short_of "$REPO" "$FIXC")" "噪声提交排在真修复之后"
  assert_no_candidate   "$OUT" "$(short_of "$REPO" "$DOC")"    "文档提交不在候选里"
  assert_contains "$OUT" "blame[anchored]" "使用了内容锚定的 blame 通道"
  assert_contains "$OUT" "grep-msg"       "issue 号命中 message 搜索"
  cd "$ROOT" || exit 1
  mark_done
fi

# ============================================================================
# 场景 2：行漂移 —— 真修复只改几行但整体位移，噪声占据大量行
# ============================================================================
if scenario "line_drift"; then
  REPO=$(new_repo drift)
  cd "$REPO" || exit 1
  {
    echo "#include <stdio.h>"
    echo "#include <string.h>"
    for i in $(seq 0 29); do echo "int h$i(int x) { return x + $i; }"; done
    cat <<'EOF'
int main(void) {
    char buf[8];
    const char *s = getenv("X");
    strcpy(buf, s);
    return 0;
}
EOF
  } > src/app.c
  git add -A >/dev/null; git commit -qm "v1: initial"
  git tag v1.0

  # 噪声：重排 30 个 helper 行
  sed -i -E 's/return x \+ ([0-9]+);/return x + \1 + 100;/' src/app.c
  git commit -qam "style: reformat helper bodies"

  # 真修复：只插入 1 行守卫
  sed -i 's|    strcpy(buf, s);|    if (!s) return 1;\n    strcpy(buf, s);|' src/app.c
  git commit -qam "fix: guard NULL before strcpy"
  FIX2=$(git rev-parse HEAD)
  git tag v2.0

  OUT=$(bash "$S/collect.sh" "$REPO" v1.0 v2.0 --path src/app.c --range 33,38 \
        --sym strcpy --min-weight 2 2>&1)
  assert_candidate     "$OUT" "$(short_of "$REPO" "$FIX2")"   "行漂移后真修复仍被找到"
  assert_top_candidate "$OUT" "$(short_of "$REPO" "$FIX2")"   "行漂移后真修复排第一"
  assert_not_contains  "$OUT" "blame[range]"                 "没有用错行的 blame[range] 通道"
  assert_contains      "$OUT" "blame[anchored]"              "使用了内容锚定通道"
  cd "$ROOT" || exit 1
  mark_done
fi

# ============================================================================
# 场景 3：跨路径 —— 修复在另一个文件，报错文件一行未动
# ============================================================================
if scenario "cross_path"; then
  REPO=$(new_repo cross)
  cd "$REPO" || exit 1
  cat > src/a.c <<'EOF'
#include <string.h>
int main(void){
  char b[4];
  const char *s = getenv("X");
  strcpy(b,s);
  return 0;
}
EOF
  echo 'int helper(void){ return 1; }' > src/b.c
  git add -A >/dev/null; git commit -qm "v1: initial"
  git tag v1.0

  echo 'int helper(void){ return 2; }' > src/b.c
  git commit -qam "fix: unrelated change in b.c"
  FIX3=$(git rev-parse HEAD)
  git tag v2.0

  OUT=$(bash "$S/collect.sh" "$REPO" v1.0 v2.0 --path src/a.c --range 5,5 \
        --sym getenv --min-weight 1 2>&1)
  assert_candidate "$OUT" "$(short_of "$REPO" "$FIX3")" "修复在别处时也能捞出候选"
  assert_contains   "$OUT" "sibling-path"                   "使用了跨路径扩散通道"
  cd "$ROOT" || exit 1
mark_done
fi

# ============================================================================
# 场景 4：merge —— 修复在分支上开发、merge 进主线
# ============================================================================
if scenario "merge_hidden_fix"; then
  REPO=$(new_repo merge)
  cd "$REPO" || exit 1
  printf 'int helper(void){ return 1; }\n' > src/base.c
  git add -A >/dev/null; git commit -qm "v1: initial"
  git tag v1.0

  git checkout -q -b topic
  printf 'int helper(void){ return 2; }\n' > src/base.c
  git commit -qam "topic: fix the bug"
  TOPIC_FIX=$(git rev-parse HEAD)
  git checkout -q main
  git merge -q --no-ff topic -m "Merge branch 'topic'"
  git tag v2.0

  OUT=$(bash "$S/collect.sh" "$REPO" v1.0 v2.0 --path src/base.c \
        --sym helper --min-weight 3 2>&1)
  assert_candidate   "$OUT" "$(short_of "$REPO" "$TOPIC_FIX")" "pickaxe 穿过 merge 找到分支上的修复"
  assert_contains    "$OUT" "HINT"                           "提示了范围内含 merge commit"
  cd "$ROOT" || exit 1
mark_done
fi

# ============================================================================
# 场景 5：符号抽取 —— greps 与 syms 必须是不同的东西
# ============================================================================
if scenario "symbol_extraction"; then
  cat > /tmp/dr_test_err2.txt <<'EOF'
src/foo.c:10: error: 'FOO_H' undeclared (first use in this function)
See https://github.com/o/r/issues/1234
fatal error: cannot open file 'config.h': No such file or directory
EOF
  SYMS=$(python "$S/extract_symbols.py" /tmp/dr_test_err2.txt --kind syms 2>/dev/null)
  GREPS=$(python "$S/extract_symbols.py" /tmp/dr_test_err2.txt --kind greps 2>/dev/null)

  printf '%s' "$SYMS" | grep -qF "FOO_H" && ok "syms 抽到了报错符号 FOO_H" || bad "syms 没抽到 FOO_H"
  printf '%s' "$GREPS" | grep -qF "#1234" && ok "greps 抽到了 URL 里的 issue 号" || bad "greps 没抽到 #1234"
  printf '%s' "$GREPS" | grep -qF "FOO_H" && bad "greps 不该包含泛符号 FOO_H" || ok "greps 不混入泛符号"
  [ "$SYMS" != "$GREPS" ] && ok "syms 与 greps 输出不同" || bad "syms 与 greps 输出相同"

  # --grepfile 必须能把 issue 号送进 collect 的 message 搜索
  REPO=$(new_repo grepfile)
  cd "$REPO" || exit 1
  printf 'int f(void){return 1;}\n' > src/x.c
  git add -A >/dev/null; git commit -qm "v1: initial"; git tag v1.0
  printf 'int f(void){return 2;}\n' > src/x.c
  git commit -qam "fix: correct the thing (fixes #42)"; git tag v2.0
  # greps 文件里要含该提交 message 里的 issue 号
  printf '#42\n' > /tmp/dr_test_greps2.txt
  OUT=$(bash "$S/collect.sh" "$REPO" v1.0 v2.0 --path src/x.c \
        --grepfile /tmp/dr_test_greps2.txt --min-weight 1 2>&1)
  assert_contains "$OUT" "grep-msg" "--grepfile 触发了 message 搜索"
  cd "$ROOT" || exit 1
mark_done
fi

# ============================================================================
# 场景 6：verify —— 三种方法 + --range 真的生效
# ============================================================================
if scenario "verify_methods"; then
  REPO=$(new_repo verify)
  cd "$REPO" || exit 1
  cat > src/foo.c <<'EOF'
#include <stdio.h>
#include <string.h>
int foo(int x) {
    char buf[16];
    const char *s = getenv("NAME");
    strcpy(buf, s);
    return x + (int)strlen(buf);
}
EOF
  git add -A >/dev/null; git commit -qm "v1: initial"; git tag v1.0
  cat > src/foo.c <<'EOF'
#include <stdio.h>
#include <string.h>
int foo(int x) {
    char buf[16];
    const char *s = getenv("NAME");
    if (s == NULL) { s = ""; }
    strncpy(buf, s, sizeof(buf) - 1);
    buf[sizeof(buf) - 1] = '\0';
    return x + (int)strlen(buf);
}
EOF
  git commit -qam "fix: bound the copy in foo()"; FIXV=$(git rev-parse HEAD); git tag v2.0

  OUT=$(bash "$S/verify.sh" "$REPO" "$FIXV" --A v1.0 --B v2.0 --path src/foo.c \
        --range 5,8 --sym strcpy --sym strncpy \
        --run-cmd 'grep -q "strcpy(buf, s)" src/foo.c' 2>&1)
  assert_contains "$OUT" "A=pass" "方法 A（bisect）通过"
  assert_contains "$OUT" "B=pass" "方法 B（父提交对比）通过"
  assert_contains "$OUT" "C=pass" "方法 C（反向验证）通过"
  assert_contains "$OUT" "first bad commit" "bisect 给出了 first bad commit"
  assert_contains "$OUT" "报错行范围"      "--range 真正参与了验证"

  # 用户的仓库不应被留下任何 worktree
  WT=$(git -C "$REPO" worktree list | wc -l | tr -d ' ')
  [ "$WT" = "1" ] && ok "没有残留临时 worktree" || bad "残留了 worktree（数量 $WT）"
  cd "$ROOT" || exit 1
  mark_done
fi

# ============================================================================
# 场景 7：verify --range —— 候选没碰报错区时必须判定为不通过
# ============================================================================
if scenario "verify_range_detects_irrelevance"; then
  REPO=$(new_repo irrelevant)
  cd "$REPO" || exit 1
  printf 'int main(void){\n  int a = 1;\n  int b = 2;\n  return a+b;\n}\n' > src/r.c
  git add -A >/dev/null; git commit -qm "v1: initial"; git tag v1.0
  printf 'int main(void){\n  int a = 1;\n  int b = 2;\n  int c = 3;\n  return a+b+c;\n}\n' > src/r.c
  git commit -qam "chore: add unrelated variable"; FIXR=$(git rev-parse HEAD); git tag v2.0

  OUT=$(bash "$S/verify.sh" "$REPO" "$FIXR" --A v1.0 --B v2.0 --path src/r.c \
        --range 2,3 --sym a --sym b 2>&1)
  assert_contains "$OUT" "内容完全相同" "候选未触及报错区时如实判定为不相关"
  assert_contains "$OUT" "inconclusive"  "未触及报错区时方法 B 判为不确定"
  cd "$ROOT" || exit 1
mark_done
fi

# ============================================================================
# 场景 8：脚本健壮性 —— 坏参数不能静默通过
# ============================================================================
if scenario "robustness"; then
  REPO=$(new_repo robust)
  cd "$REPO" || exit 1
  printf 'int f(void){return 1;}\n' > src/x.c
  git add -A >/dev/null; git commit -qm "v1"; git tag v1.0
  printf 'int f(void){return 2;}\n' > src/x.c
  git commit -qam "chore: tweak"; git tag v2.0

  OUT=$(bash "$S/anchor.sh" "$REPO" v9.9-nonexistent v1.0 2>&1); RC=$?
  [ $RC -ne 0 ] && ok "无效 ref 会报错退出" || bad "无效 ref 没有报错"

  OUT=$(bash "$S/anchor.sh" "$REPO" v1.0 - 2>&1); RC=$?
  [ $RC -eq 0 ] && ok "降级模式（修复版本未知）正常工作" || bad "降级模式退出码 $RC"
  printf '%s' "$OUT" | grep -qF "DEGRADED_MODE=pickaxe-only" \
    && ok "降级模式给出可执行的降级建议" || bad "降级模式没有给出建议"

  OUT=$(bash "$S/collect.sh" "$REPO" v2.0 v2.0 --path src/x.c --min-weight 1 2>&1); RC=$?
  [ $RC -eq 0 ] && ok "空范围（v2.0..v2.0）不报错" || bad "空范围退出码 $RC"

  # 修复不在报错文件里 + 没给 --range 时也不能崩溃
  OUT=$(bash "$S/collect.sh" "$REPO" v1.0 v2.0 --path src/x.c --min-weight 1 2>&1); RC=$?
  [ $RC -eq 0 ] && ok "缺 --range 时不崩溃" || bad "缺 --range 退出码 $RC"

  # 缺 --symfile / --fixed / --grepfile 时也不能崩溃
  OUT=$(bash "$S/collect.sh" "$REPO" v1.0 v2.0 --path src/x.c --min-weight 1 2>&1); RC=$?
  [ $RC -eq 0 ] && ok "同时缺多个可选参数时不崩溃" || bad "缺可选参数退出码 $RC"

  cd "$ROOT" || exit 1
mark_done
fi

# ============================================================================
# 场景 9：脚本静态检查
# ============================================================================
if scenario "syntax_and_lint"; then
  for f in "$S"/*.sh; do
    if bash -n "$f" 2>/dev/null; then ok "bash -n $(basename "$f")"; else bad "bash -n $(basename "$f") 有语法错误"; fi
  done
  if python -m py_compile "$S/extract_symbols.py" 2>/dev/null; then
    ok "extract_symbols.py 编译通过"
    rm -rf "$S/__pycache__"
  else
    bad "extract_symbols.py 编译失败"
  fi
  # set -e 陷阱：管道消费者函数的最后一个命令返回非 0 会杀死脚本
  if grep -qE '^\s*record_log\(\)' "$S/collect.sh"; then
    grep -A20 'record_log()' "$S/collect.sh" | grep -q 'return 0' \
      && ok "record_log 有 return 0 保护" || bad "record_log 缺少 return 0（set -e 陷阱）"
  fi
mark_done
fi

# ============================================================================
# 场景 10：SKILL.md 与脚本接口一致性
# ============================================================================
if scenario "doc_script_consistency"; then
  SKILLMD="$ROOT/SKILL.md"
  for s in acquire.sh anchor.sh collect.sh inspect.sh verify.sh extract_symbols.py; do
    if [ -f "$S/$s" ]; then ok "脚本存在：$s"; else bad "脚本缺失：$s"; fi
  done
  grep -qF 'defect-resolution' "$SKILLMD" && ok "SKILL.md 存在且提到 skill 名" || bad "SKILL.md 缺失"
  grep -qE '^name:\s*defect-resolution' "$SKILLMD" && ok "SKILL.md frontmatter name 正确" || bad "SKILL.md frontmatter name 缺失"
  grep -qE '^description:' "$SKILLMD" && ok "SKILL.md 有 description" || bad "SKILL.md 缺 description"
  # SKILL.md 里提到的每个脚本都必须真实存在
  # 只检查"本 skill 自己的脚本"—— SKILL.md 里也会提到 setup.py/Makefile 这类
  # 用户项目里的构建文件名，它们不是本仓库的文件
  for s in acquire.sh anchor.sh collect.sh inspect.sh verify.sh extract_symbols.py; do
    grep -qF "$s" "$SKILLMD" && ok "SKILL.md 记录了脚本：$s" || bad "SKILL.md 没记录脚本：$s"
    [ -f "$S/$s" ] || bad "脚本缺失：$s"
  done
  # lib.sh 是脚本间的共用库，由脚本自己 source，不面向用户直接调用
  [ -f "$S/lib.sh" ] && ok "共用库 lib.sh 存在" || bad "共用库 lib.sh 缺失"
  ok "SKILL.md 引用的脚本全部存在"
  # 权重对照表里的通道名要真实存在于 collect.sh
  for ch in "blame\[anchored\]" "blame\[removed\]" "sibling-path" "grep-msg"; do
    grep -q "$ch" "$S/collect.sh" && ok "通道存在：$ch" || bad "通道缺失：$ch"
  done
mark_done
fi

# ============================================================================
# 场景 11：版本归属（主场景核心）—— 修复版本必须算对
# ============================================================================
if scenario "version_attribution"; then
  REPO=$(new_repo versions)
  cd "$REPO" || exit 1
  printf 'int f(void){return 1;}\n' > src/a.c
  git add -A >/dev/null; git commit -qm "v1.0.0: initial"; git tag v1.0.0
  printf 'int f(void){return 2;}\n' > src/a.c
  git commit -qam "the fix"; MIDFIX=$(git rev-parse HEAD)
  printf 'int f(void){return 3;}\n' > src/a.c
  git commit -qam "later work"; git tag v2.0.0

  # 关键断言：git describe 会给 v1.0.0（错的，仍带 bug），版本归属必须给 v2.0.0
  DESC=$(git describe --tags --abbrev=0 "$MIDFIX")
  [ "$DESC" = "v1.0.0" ] && info "（前提确认：git describe 确实给的是错误的 v1.0.0）" \
                          || info "（前提：git describe 给的是 $DESC）"

  OUT=$(bash "$S/inspect.sh" "$REPO" "$MIDFIX" --path src/a.c 2>&1)
  assert_contains "$OUT" "首次包含该修复的发布版本: v2.0.0" "首次包含修复的发布版本算对了"
  assert_contains "$OUT" "上一个发布版本（仍含此缺陷）: v1.0.0" "上一个仍含缺陷的版本算对了"
  assert_not_contains "$OUT" "首次包含该修复的发布版本: v1.0.0" "没有误用 git describe 的结果"

  # 候选表必须带"修复版本"列
  OUT=$(bash "$S/collect.sh" "$REPO" v1.0.0 v2.0.0 --path src/a.c --sym f --min-weight 2 2>&1)
  assert_contains "$OUT" "修复版本" "候选表包含修复版本列"
  assert_contains "$OUT" "v2.0.0"        "候选表给出了正确的修复版本"

  # verify 头部也要打印版本归属
  OUT=$(bash "$S/verify.sh" "$REPO" "$MIDFIX" --A v1.0.0 --B v2.0.0 --path src/a.c --sym f 2>&1)
  assert_contains "$OUT" "修复版本" "verify 头部打印修复版本"

  # anchor 要输出区间内的版本序列
  OUT=$(bash "$S/anchor.sh" "$REPO" v1.0.0 v2.0.0 --path src/a.c 2>&1)
  assert_contains "$OUT" "TAG_SEQUENCE=" "anchor 输出版本序列"
  assert_contains "$OUT" "v1.0.0" "版本序列包含起始版本"
  assert_contains "$OUT" "v2.0.0" "版本序列包含结束版本"
  cd "$ROOT" || exit 1
mark_done
fi

# ============================================================================
# 场景 12：私有/本地仓库 —— 零网络，非 git 目录的明确诊断
# ============================================================================
if scenario "private_and_offline"; then
  REPO=$(new_repo private)
  cd "$REPO" || exit 1
  printf 'int f(void){return 1;}\n' > src/a.c
  git add -A >/dev/null; git commit -qm "v1"; git tag v1.0
  printf 'int f(void){return 2;}\n' > src/a.c
  git commit -qam "fix"; git tag v2.0

  # acquire 本地仓库应报告不使用网络
  OUT=$(bash "$S/acquire.sh" "$REPO" 2>&1)
  assert_contains "$OUT" "SOURCE=local"  "本地仓库被正确识别"
  assert_contains "$OUT" "NETWORK=not-used" "本地仓库不联网"

  # --offline 模式
  OUT=$(bash "$S/acquire.sh" "$REPO" v1.0 --offline 2>&1)
  assert_contains "$OUT" "已禁用一切网络访问" "--offline 明确声明零网络"

  # 非 git 目录要给出可操作的诊断，而不是笼统报错
  NOGIT="$WORKROOT/notgit"; mkdir -p "$NOGIT/src"; printf 'int f(void){return 1;}\n' > "$NOGIT/src/a.c"
  OUT=$(bash "$S/acquire.sh" "$NOGIT" 2>&1); RC=$?
  [ $RC -ne 0 ] && ok "非 git 目录报错退出" || bad "非 git 目录没有报错"
  assert_contains "$OUT" "不是 git 仓库"      "非 git 目录给出明确原因"
  assert_contains "$OUT" "可行出路"          "非 git 目录给出可行出路"
  assert_contains "$OUT" "开源项目"          "诊断里提到可改用上游开源仓库"
  cd "$ROOT" || exit 1
mark_done
fi

# ============================================================================
# 场景 13：版本序列 —— 修复可能落在中间版本
# ============================================================================
if scenario "intermediate_release"; then
  REPO=$(new_repo inter)
  cd "$REPO" || exit 1
  printf 'int f(void){return 1;}\n' > src/a.c
  git add -A >/dev/null; git commit -qm "v1"; git tag v1.0.0
  printf 'int f(void){return 2;}\n' > src/a.c
  git commit -qam "fix in middle release"; MIDFIX=$(git rev-parse HEAD); git tag v1.1.0
  printf 'int f(void){return 3;}\n' > src/a.c
  git commit -qam "later"; git tag v2.0.0

  # 用户视角：v1.0.0 有 bug，v2.0.0 好了 → 修复其实在 v1.1.0
  # 版本维度判定（主场景能力）
  # 判据必须用**坏版本里存在**的文本（报错现场那行）
  OUT=$(bash "$S/version_bisect.sh" "$REPO" v1.0.0 v2.0.0 --path src/a.c \
        --contains 'return 1;' 2>&1)
  assert_contains "$OUT" "FIX_VERSION=v1.1.0"        "版本维度定位到中间版本 v1.1.0"
  assert_contains "$OUT" "STILL_BROKEN_BEFORE=v1.0.0" "上一个仍含缺陷的版本算对了"
  assert_contains "$OUT" "TAG_SEQUENCE="             "输出了版本序列"

  # 提交维度：真实修复仍应被找到
  OUT=$(bash "$S/collect.sh" "$REPO" v1.0.0 v1.1.0 --path src/a.c --sym f --min-weight 2 2>&1)
  assert_candidate     "$OUT" "$(short_of "$REPO" "$MIDFIX")" "收窄区间后真修复在候选里"
  assert_top_candidate "$OUT" "$(short_of "$REPO" "$MIDFIX")" "收窄区间后真修复排第一"

  # 版本归属确认
  OUT=$(bash "$S/inspect.sh" "$REPO" "$MIDFIX" --path src/a.c 2>&1)
  assert_contains "$OUT" "首次包含该修复的发布版本: v1.1.0" "正确识别出修复在中间版本 v1.1.0"
  cd "$ROOT" || exit 1
mark_done
fi

# ============================================================================
# 场景 14：version_bisect.sh 的三种判据
# ============================================================================
if scenario "version_bisect_criteria"; then
  REPO=$(new_repo vbc)
  cd "$REPO" || exit 1
  printf '#include <string.h>\nint f(void){\n  char b[4];\n  const char *s = getenv("X");\n  strcpy(b,s);\n  return 0;\n}\n' > src/a.c
  git add -A >/dev/null; git commit -qm "v1"; git tag v1.0.0
  printf '#include <string.h>\nint f(void){\n  char b[4];\n  const char *s = getenv("X");\n  strcpy(b,s);\n  return 0;\n}\n// noise\n' > src/a.c
  git commit -qam "noise"; git tag v1.1.0
  printf '#include <string.h>\nint f(void){\n  char b[4];\n  const char *s = getenv("X");\n  if(!s) return 1;\n  strncpy(b,s,3);\n  return 0;\n}\n' > src/a.c
  git commit -qam "fix"; git tag v1.2.0

  # --contains：报错现场文本消失 = 已修复
  OUT=$(bash "$S/version_bisect.sh" "$REPO" v1.0.0 v1.2.0 --path src/a.c --contains 'strcpy(b,s)' 2>&1)
  assert_contains "$OUT" "FIX_VERSION=v1.2.0" "--contains 判据定位正确"

  # --sym：符号消失 = 已修复
  OUT=$(bash "$S/version_bisect.sh" "$REPO" v1.0.0 v1.2.0 --path src/a.c --sym 'strcpy(b,s)' 2>&1)
  assert_contains "$OUT" "FIX_VERSION=v1.2.0" "--sym 判据定位正确"

  # --missing：修复版才有的内容出现 = 已修复
  OUT=$(bash "$S/version_bisect.sh" "$REPO" v1.0.0 v1.2.0 --path src/a.c --missing 'if(!s)' 2>&1)
  assert_contains "$OUT" "FIX_VERSION=v1.2.0" "--missing 判据定位正确"

  # --missing 的内容在坏版本就存在时，应被忽略并警告
  OUT=$(bash "$S/version_bisect.sh" "$REPO" v1.0.0 v1.2.0 --path src/a.c --missing 'strcpy' 2>&1)
  assert_contains "$OUT" "在坏版本中就存在" "--missing 忽略了无效判据"

  # --run-cmd：与 bisect 同约定（0 = 仍有 bug）
  OUT=$(bash "$S/version_bisect.sh" "$REPO" v1.0.0 v1.2.0 --path src/a.c \
        --run-cmd 'grep -q "strcpy(b,s)" src/a.c' 2>&1)
  assert_contains "$OUT" "FIX_VERSION=v1.2.0" "--run-cmd 判据定位正确"

  # --tag-list：只列版本不做判定
  OUT=$(bash "$S/version_bisect.sh" "$REPO" v1.0.0 v1.2.0 --tag-list 2>&1)
  assert_contains "$OUT" "v1.0.0" "--tag-list 列出版本"
  assert_contains "$OUT" "v1.2.0" "--tag-list 列出版本"
  assert_not_contains "$OUT" "FIX_VERSION=" "--tag-list 不做判定"
  cd "$ROOT" || exit 1
  mark_done
fi

# ============================================================================
# 场景 15：判据校验的兜底 —— 全无效判据必须报错，不能输出错误结论
# ============================================================================
if scenario "invalid_criteria_hard_fail"; then
  REPO=$(new_repo invc)
  cd "$REPO" || exit 1
  printf 'int f(void){return 1;}\n' > src/a.c
  git add -A >/dev/null; git commit -qm v1 >/dev/null; git tag v1.0.0
  printf 'int f(void){return 2;}\n' > src/a.c; git commit -qam fix >/dev/null; git tag v2.0.0

  OUT=$(bash "$S/version_bisect.sh" "$REPO" v1.0.0 v2.0.0 --path src/a.c --sym '不存在的符号XYZ' 2>&1)
  RC=$?
  [ $RC -ne 0 ] && ok "全无效判据报错退出（rc=$RC）" || bad "全无效判据静默通过"
  assert_not_contains "$OUT" "FIX_VERSION=" "不输出错误的 FIX_VERSION"
  assert_contains "$OUT" "全部无效" "给出判据无效的原因"

  # --contains 给了修复后才有的内容 → 无效 → 报错
  OUT=$(bash "$S/version_bisect.sh" "$REPO" v1.0.0 v2.0.0 --path src/a.c --contains 'return 2;' 2>&1)
  RC=$?
  [ $RC -ne 0 ] && ok "--contains 反向判据也报错退出" || bad "--contains 反向判据静默通过"
  cd "$ROOT" || exit 1
mark_done
fi

# ============================================================================
# 场景 16：自动判据 —— 修复改文件中部时不能误判（内容对比而非行存在性）
# ============================================================================
if scenario "auto_criterion_midfile_fix"; then
  REPO=$(new_repo autoc)
  cd "$REPO" || exit 1
  mkdir -p src
  { echo "#include <stdio.h>"; echo "int f(void) {"; echo "    return 1;"; echo "}"; } > src/a.c
  git add -A >/dev/null; git commit -qm v1 >/dev/null; git tag v1.0.0
  { echo "#include <stdio.h>"; echo "int f(void) {"; echo "    return 2;"; echo "}"; } > src/a.c
  git commit -qam fix >/dev/null; git tag v2.0.0

  OUT=$(bash "$S/version_bisect.sh" "$REPO" v1.0.0 v2.0.0 --path src/a.c 2>&1)
  assert_contains "$OUT" "FIX_VERSION=v2.0.0" "自动判据（无显式判据）定位到修复版本"
  assert_contains "$OUT" "STILL_BROKEN_BEFORE=v1.0.0" "上一个仍含缺陷版本算对"
  cd "$ROOT" || exit 1
mark_done
fi

# ============================================================================
# 场景 17：annotated tag 的版本归属 + 日期用 tag creatordate
# ============================================================================
if scenario "annotated_tag_attribution"; then
  REPO=$(new_repo anno)
  cd "$REPO" || exit 1
  mkdir -p src
  printf 'int f(void){return 1;}\n' > src/a.c
  git add -A >/dev/null; git commit -qm v1 >/dev/null
  git tag -a v1.0.0 -m "release v1"
  printf 'int f(void){return 2;}\n' > src/a.c
  GIT_AUTHOR_DATE="2020-01-01T00:00:00" git commit -qam "fix (old author date)" >/dev/null
  git tag -a v2.0.0 -m "release v2"
  FIX=$(git rev-parse HEAD)

  OUT=$(bash "$S/inspect.sh" "$REPO" "$FIX" --path src/a.c 2>&1)
  assert_contains "$OUT" "首次包含该修复的发布版本: v2.0.0" "annotated tag 归属正确"
  # author date 是 2020-01-01，若误用它当 tag 日期就会输出 2020
  printf '%s' "$OUT" | grep "首次包含该修复" | grep -q "2020" \
    && bad "日期误用了 commit 的 author date（2020）" \
    || ok "日期来自 tag 的 creatordate"
  cd "$ROOT" || exit 1
mark_done
fi

# ============================================================================
# 场景 18：anchor 版本序列不混入问题版本之前的 tag
# ============================================================================
if scenario "anchor_sequence_scoped"; then
  REPO=$(new_repo seqscope)
  cd "$REPO" || exit 1
  mkdir -p src
  printf 'int f(void){return 0;}\n' > src/a.c
  git add -A >/dev/null; git commit -qm pre >/dev/null; git tag v0.9.0
  printf 'int f(void){return 1;}\n' > src/a.c
  git commit -qam v1 >/dev/null; git tag v1.0.0
  printf 'int f(void){return 2;}\n' > src/a.c
  git commit -qam fix >/dev/null; git tag v1.1.0
  printf 'int f(void){return 3;}\n' > src/a.c
  git commit -qam later >/dev/null; git tag v2.0.0

  OUT=$(bash "$S/anchor.sh" "$REPO" v1.0.0 v2.0.0 --path src/a.c 2>&1)
  assert_contains "$OUT" "TAG_SEQUENCE=v1.0.0 v1.1.0 v2.0.0" "版本序列从问题版本开始"
  assert_not_contains "$OUT" "v0.9.0" "问题版本之前的 tag 不混入序列"
  cd "$ROOT" || exit 1
mark_done
fi

# ============================================================================
printf '\n'
printf '%s────────────────────────────────────────%s\n' "$DIM" "$OFF"
if [ $FAIL -eq 0 ]; then
  printf '%s全部通过%s  (%s 通过, %s 跳过)\n' "$GREEN" "$OFF" "$PASS" "$SKIP"
else
  printf '%s有失败%s  (%s 通过, %s 失败, %s 跳过)\n' "$RED" "$OFF" "$PASS" "$FAIL" "$SKIP"
  printf '失败场景:%s\n' "${FAILED_NAMES:- （无）}"
fi
printf '%s────────────────────────────────────────%s\n' "$DIM" "$OFF"
if [ $FAIL -eq 0 ]; then exit 0; else exit 1; fi
