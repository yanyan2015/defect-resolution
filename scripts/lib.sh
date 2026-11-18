#!/usr/bin/env bash
# lib.sh —— defect-resolution 取证脚本的共用函数。
# 只被同目录脚本 source，不单独执行。
# 兼容：Git Bash (MINGW64) / Linux / macOS，bash 4+。

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
note() { printf '%s\n' "$*" >&2; }

# 冒烟测试脚本自身是否有 bug 的开关：DR_DEBUG=1 会打印每条关键命令
run() {
  if [ "${DR_DEBUG:-0}" = "1" ]; then printf '+ %s\n' "$*" >&2; fi
  "$@"
}

require_git_repo() {
  local repo="$1"
  [ -n "$repo" ] || die "缺少 repo 参数"
  [ -d "$repo" ] || die "仓库目录不存在: $repo"
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || die "不是 git 仓库: $repo"
  git -C "$repo" rev-parse --verify HEAD >/dev/null 2>&1 || die "仓库没有任何提交: $repo"
}

require_commit() {
  local repo="$1" what="$2"
  [ -n "$what" ] || die "缺少 $2 参数"
  git -C "$repo" rev-parse --verify --quiet "${what}^{commit}" >/dev/null 2>&1 \
    || die "$2 无法解析为 commit: $what"
}

# 把 tag / 分支 / 短 hash / HEAD / HEAD~3 解析成完整 commit；失败返回非 0。
resolve_ref() {
  local repo="$1" ref="$2" out
  [ -n "$ref" ] || return 1
  if out=$(git -C "$repo" rev-parse --verify --quiet "${ref}^{commit}"); then
    printf '%s\n' "$out"; return 0
  fi
  if out=$(git -C "$repo" rev-parse --verify --quiet "$ref"); then
    printf '%s\n' "$out"; return 0
  fi
  return 1
}

# 仓库内相对路径：把绝对路径 / Windows 反斜杠路径 / . 前缀转成 git 认识的路径。
rel_path() {
  local repo="$1" p="$2" r
  # 统一成绝对路径比较
  r=$(cd "$repo" && pwd)
  p="${p//\\//}"
  case "$p" in
    "$r"/*) p="${p#"$r"/}" ;;
  esac
  while [ "${p#./}" != "$p" ]; do p="${p#./}"; done
  printf '%s\n' "$p"
}

# X 是否落在 A..B 范围内（是 B 的祖先且不是 A 的祖先）。
# 返回码恒为 0，结果放在全局变量 IN_RANGE=yes|no。
# 这样 `in_range ... && record ...` 这类链在 set -e 下不会因"不在范围内"而终止脚本。
IN_RANGE=no
in_range() {
  local repo="$1" x="$2" a="$3" b="$4"
  IN_RANGE=no
  git -C "$repo" merge-base --is-ancestor "$x" "$b" 2>/dev/null || return 0
  if git -C "$repo" merge-base --is-ancestor "$x" "$a" 2>/dev/null; then return 0; fi
  IN_RANGE=yes
  return 0
}

# in_range 的便捷封装：直接用于 if 条件（内部消化返回码）
in_range_test() {
  in_range "$@"
  [ "$IN_RANGE" = "yes" ]
}

# 统一计数入口：cnt <repo> <A> <B> [git rev-list 额外参数...]
# 注意：range 必须在 pathspec 之前（`rev-list --count -- p A..B` 是无效语法）
cnt() {
  local repo="$1" a="$2" b="$3"; shift 3
  git -C "$repo" rev-list --count "$a..$b" "$@" 2>/dev/null || printf '0'
}

short_sha() { git -C "$1" rev-parse --short "$2" 2>/dev/null; }

# ---------------------------------------------------------------------------
# 版本归属：修复 commit 首次出现在哪个发布版本里？
#
# 注意：`git describe --tags --abbrev=0 <commit>` 返回的是**最近的上游 tag**，
# 对「修复落在两个 tag 之间」的情况会给出**上一个** tag —— 也就是那个
# 还带着 bug 的版本。回答「这个 bug 在哪个版本修好的」时这是错的。
#
# 正确算法：找出所有 tag 中**包含**该 commit 的最早发布版本。
#   "包含" = 该 tag 的 commit 是修复 commit 的后代（修复已合入该发布分支）。
#
# 日期语义：用 **tag 的 creatordate**（打标签的时间），不是 commit 的 author
# date —— cherry-pick / backport 会保留原 author date，用它排序会把多年前的
# backport 排错位。
# ---------------------------------------------------------------------------

# 输出所有 tag（名字 + commit），按 tag 的 creatordate 从旧到新
list_tags() {
  local repo="$1"
  git -C "$repo" for-each-ref --format='%(refname:short) %(objectname)' \
    --sort=creatordate refs/tags 2>/dev/null
}

# 该 commit 是否已被 tag 包含（tag 是它的后代）
tag_contains() {
  local repo="$1" tag="$2" sha="$3"
  local tcommit
  tcommit=$(git -C "$repo" rev-parse --verify --quiet "${tag}^{commit}") || return 1
  git -C "$repo" merge-base --is-ancestor "$sha" "$tcommit" 2>/dev/null
}

# 首个包含该 commit 的发布版本。
# 输出三个全局变量（输出契约 —— 调用方 inspect.sh / collect.sh 读取，shellcheck 看不到跨文件使用）：
#   FIRST_CONTAINING_TAG   —— tag 名（无 tag 时为空）
#   FIRST_CONTAINING_DATE  —— 该 tag 的 creatordate（YYYY-MM-DD）
#   ALSO_CONTAINING_TAGS   —— 其它也包含它的 tag（逗号分隔）
FIRST_CONTAINING_TAG=""
FIRST_CONTAINING_DATE=""
ALSO_CONTAINING_TAGS=""
# shellcheck disable=SC2034  # 输出契约：调用方（inspect.sh/collect.sh）跨文件读取
first_containing_tag() {
  local repo="$1" sha="$2"
  FIRST_CONTAINING_TAG=""
  FIRST_CONTAINING_DATE=""
  ALSO_CONTAINING_TAGS=""
  # git tag --contains 本身就是"包含该 commit 的 tag"列表；
  # --sort=creatordate 让最早的发布版本排最前 —— 一次调用替代逐 tag 循环。
  local first=1 tag
  while read -r tag; do
    [ -n "$tag" ] || continue
    if [ "$first" = "1" ]; then
      FIRST_CONTAINING_TAG="$tag"
      FIRST_CONTAINING_DATE=$(git -C "$repo" for-each-ref \
        --format='%(creatordate:short)' "refs/tags/$tag" 2>/dev/null)
      first=0
    else
      ALSO_CONTAINING_TAGS="${ALSO_CONTAINING_TAGS:+$ALSO_CONTAINING_TAGS, }$tag"
    fi
  done < <(git -C "$repo" tag --contains "$sha" --sort=creatordate 2>/dev/null)
  return 0
}

# 上一个已发布的版本（不含该 commit 的 tag 中，最新的那个）
# —— 用于回答"上个版本就有这问题"（用户该升到哪之前）。
PREVIOUS_TAG=""
# shellcheck disable=SC2034  # 输出契约：调用方（inspect.sh）跨文件读取
previous_tag() {
  local repo="$1" sha="$2"
  PREVIOUS_TAG=""
  # 不包含该 commit 的 tag 里，取 creatordate 最新的。
  # git tag --no-contains + --sort=-creatordate：第一条即最新。
  PREVIOUS_TAG=$(git -C "$repo" tag --no-contains "$sha" --sort=-creatordate 2>/dev/null | head -1)
  return 0
}

subject_of() { git -C "$1" log -1 --format=%s "$2" 2>/dev/null; }

date_of() { git -C "$1" log -1 --format=%ad --date=short "$2" 2>/dev/null; }

nearest_tag() {
  local t
  t=$(git -C "$1" describe --tags --abbrev=0 "$2" 2>/dev/null) && printf '%s\n' "$t" || printf '(none)\n'
}

# blame --line-porcelain 输出 → 每行 "final_lineno<TAB>sha"
# 用法：blame_lines <repo> <rev> <path>
blame_lines() {
  local repo="$1" rev="$2" path="$3"
  git -C "$repo" blame --line-porcelain "$rev" -- "$path" 2>/dev/null | awk '
    /^[0-9a-f]{40} / { sha=$1; fl=$3; n=$4; for (i = 0; i < n; i++) print (fl+i) "\t" sha; next }
  '
}

# blame --line-porcelain 输出 → "final_lineno<TAB>sha<TAB>行内容"
# 用法：blame_full <repo> <rev> <path>
blame_full() {
  local repo="$1" rev="$2" path="$3"
  git -C "$repo" blame --line-porcelain "$rev" -- "$path" 2>/dev/null | awk '
    /^[0-9a-f]{40} / { sha=$1; fl=$3; n=$4; idx=0; next }
    /^\t/            { print (fl+idx) "\t" sha "\t" substr($0, 2); idx++; next }
  '
}

# 正则元字符转义（给 git log -G 用）
re_escape() { printf '%s' "$1" | sed 's/[][\.^$*+?(){}|]/\\&/g'; }

# 临时目录（Windows 下 mktemp -d 可用）
mktmpdir() {
  local d
  d=$(mktemp -d 2>/dev/null) || d="${TMPDIR:-/tmp}/dr-$$-$RANDOM"
  mkdir -p "$d"
  printf '%s\n' "$d"
}
