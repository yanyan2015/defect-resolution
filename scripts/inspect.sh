#!/usr/bin/env bash
# inspect.sh —— 阶段 3：单个候选 commit 的语义筛选卡片。
#
# 用法：
#   inspect.sh <repo> <commit> [--path P]... [--sym S]... [--symfile FILE]
#              [--range S,E] [--fixed FILE] [--error-file FILE] [--context N]
#
# 输出：
#   * 提交元信息与 message 全文
#   * 改动规模（numstat）与路径清单，标注重命名/复制（代码搬家 → 排除）
#   * 自动排除判定：纯空白 / 纯注释 / 仅文档测试配置版本号
#   * 报错符号在 父提交 vs 候选提交 中的出现次数（语义缺口）
#   * 「已修复代码」每行的落点（候选提交出现 / 父提交未出现 = 理想形态）
#   * diff（默认上下文 3 行；merge 提交按 first-parent 展开）
#   * 末行机器可读：INSPECT|<short>|<+a/-d>|<排除理由或 ->
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

REPO=""; C=""
PATHS=(); SYMS=(); SYMFILE=""; RANGE=""; FIXED=""; ERRFILE=""; CTX=3
while [ $# -gt 0 ]; do
  case "$1" in
    --path)        PATHS+=("${2:-}"); shift 2 ;;
    --path=*)      PATHS+=("${1#*=}"); shift ;;
    --sym)         SYMS+=("${2:-}"); shift 2 ;;
    --sym=*)       SYMS+=("${1#*=}"); shift ;;
    --symfile)     SYMFILE="${2:-}"; shift 2 ;;
    --symfile=*)   SYMFILE="${1#*=}"; shift ;;
    --range)       RANGE="${2:-}"; shift 2 ;;
    --range=*)     RANGE="${1#*=}"; shift ;;
    --fixed)       FIXED="${2:-}"; shift 2 ;;
    --fixed=*)     FIXED="${1#*=}"; shift ;;
    --error-file)  ERRFILE="${2:-}"; shift 2 ;;
    --error-file=*) ERRFILE="${1#*=}"; shift ;;
    --context)     CTX="${2:-3}"; shift 2 ;;
    --context=*)   CTX="${1#*=}"; shift ;;
    -h|--help)     sed -n '2,17p' "$0"; exit 0 ;;
    -*)            die "未知参数: $1" ;;
    *)             if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$C" ]; then C="$1"; else die "多余参数: $1"; fi; shift ;;
  esac
done
[ -n "$REPO" ] && [ -n "$C" ] || die "用法: inspect.sh <repo> <commit> [选项]"
require_git_repo "$REPO"
REPO=$(cd "$REPO" && pwd)
C=$(resolve_ref "$REPO" "$C") || die "commit 无法解析: $C"
P=$(git -C "$REPO" rev-parse --verify --quiet "${C}^" 2>/dev/null || true)

if [ "${#PATHS[@]}" -gt 0 ]; then
  for i in "${!PATHS[@]}"; do PATHS[$i]=$(rel_path "$REPO" "${PATHS[$i]}"); done
fi
if [ -n "$SYMFILE" ] && [ -f "$SYMFILE" ]; then
  while IFS= read -r l; do
    [ -n "$l" ] && SYMS+=("$l")
  done < <(tr -d '\r' < "$SYMFILE" | awk -F'\t' 'NF>2{print $3; next} {print $1}' | awk '!seen[$0]++')
fi

IS_MERGE=0
[ "$(git -C "$REPO" rev-list --no-walk --count --merges "$C" 2>/dev/null || echo 0)" = "1" ] && IS_MERGE=1

# 所有"看 diff"的命令都带上 --first-parent -m：
# merge 提交默认 show 不出 diff，必须显式展开（--first-parent 只对比第一父提交，最接近"本次合入的内容"）
SHOW_SCOPE=(-m --first-parent)
show_path() { git -C "$REPO" cat-file -p "$1:$2" 2>/dev/null || true; }
occ() { # <text> <fixed-string> → 出现次数
  [ -n "$1" ] || { printf '0'; return 0; }
  printf '%s' "$1" | grep -oF -- "$2" 2>/dev/null | wc -l | tr -d ' '
  return 0
}

echo "=== 提交元信息 ==="
git -C "$REPO" show -s --format='commit  %H%nshort   %h%nauthor  %an <%ae>%nauthor° %ad%ncommit° %cd' --date=iso "$C" 2>/dev/null || true
printf 'parents %s' "$(git -C "$REPO" show -s --format='%p' "$C")"
[ "$IS_MERGE" = "1" ] && printf '   << MERGE 提交（diff 按 first-parent 展开）'
printf '\n'

# --- 版本归属（"这个 bug 在哪个版本修好的"）---
first_containing_tag "$REPO" "$C"
previous_tag "$REPO" "$C"
printf '\n=== 版本归属 ===\n'
if [ -n "$FIRST_CONTAINING_TAG" ]; then
  printf '首次包含该修复的发布版本: %s  (%s)\n' "$FIRST_CONTAINING_TAG" "$FIRST_CONTAINING_DATE"
  [ -n "$ALSO_CONTAINING_TAGS" ] && printf '同时包含该修复的其它版本: %s\n' "$ALSO_CONTAINING_TAGS"
else
  printf '首次包含该修复的发布版本: (无 —— 该提交尚未进入任何 tag；可能尚未发布)\n'
fi
[ -n "$PREVIOUS_TAG" ] && printf '上一个发布版本（仍含此缺陷）: %s\n' "$PREVIOUS_TAG"
printf '描述用的最近 tag:          %s   <- 仅供定位，不要当作"修复版本"\n' "$(nearest_tag "$REPO" "$C")"
echo
echo "--- message 全文 ---"
git -C "$REPO" show -s --format='%B' "$C"

echo "=== 改动规模 ==="
git -C "$REPO" show "${SHOW_SCOPE[@]}" --stat --find-renames --find-copies --format='' "$C" ${PATHS[@]+-- "${PATHS[@]}"} 2>/dev/null || true
printf '\n--- numstat（增\t删\t文件）---\n'
git -C "$REPO" show "${SHOW_SCOPE[@]}" --numstat --find-renames --find-copies --format='' "$C" ${PATHS[@]+-- "${PATHS[@]}"} 2>/dev/null || true

echo
echo "=== 自动排除判定 ==="
EXCLUDE_REASON=""
WS=$(git -C "$REPO" show "${SHOW_SCOPE[@]}" --stat --format='' -w "$C" ${PATHS[@]+-- "${PATHS[@]}"} 2>/dev/null | tr -d ' \n\t' || true)
FULL=$(git -C "$REPO" show "${SHOW_SCOPE[@]}" --stat --format='' "$C" ${PATHS[@]+-- "${PATHS[@]}"} 2>/dev/null | tr -d ' \n\t' || true)
if [ -z "$FULL" ]; then
  printf 'ok 该 commit 在该路径/该范围内没有内容改动（空 diff）\n'
elif [ -z "$WS" ]; then
  EXCLUDE_REASON="纯空白/格式改动（git show -w 为空）"
  printf '!! %s\n' "$EXCLUDE_REASON"
else
  printf 'ok 非纯空白改动\n'
fi

# 纯注释改动
COMMENTONLY=1
SAW_CHANGE=0
while IFS= read -r l; do
  case "$l" in
    +++*|---*|@@*) continue ;;
    +*|-*) : ;;
    *) continue ;;
  esac
  SAW_CHANGE=1
  body=${l:1}
  if ! printf '%s' "$body" | grep -qE '^[[:space:]]*(//|#|/\*|\*|<!--|--)'; then COMMENTONLY=0; break; fi
done < <(git -C "$REPO" show "${SHOW_SCOPE[@]}" --format='' --unified=0 "$C" ${PATHS[@]+-- "${PATHS[@]}"} 2>/dev/null || true)
if [ "$COMMENTONLY" = "1" ] && [ "$SAW_CHANGE" = "1" ]; then
  EXCLUDE_REASON="${EXCLUDE_REASON:+$EXCLUDE_REASON; }纯注释改动"
  printf '!! 纯注释改动\n'
fi

# 重命名 / 复制（代码搬家）
RENAMES=$(git -C "$REPO" show "${SHOW_SCOPE[@]}" --summary --find-renames --find-copies --format='' "$C" 2>/dev/null | grep -E 'rename|copy' || true)
if [ -n "$RENAMES" ]; then
  printf '!! 存在重命名/复制（若报错只与搬家有关，属排除档）：\n%s\n' "$RENAMES"
fi

# 仅文档 / 测试 / 配置 / 版本号
ONLY_META=1
CHANGED=$(git -C "$REPO" show "${SHOW_SCOPE[@]}" --name-only --format='' "$C" 2>/dev/null | grep -v '^$' | awk '!seen[$0]++' || true)
if [ -n "$CHANGED" ]; then
  while IFS= read -r f; do
    printf '%s' "$f" | grep -qiE '(^|/)(docs?|man|examples?)/|\.(md|rst|txt|adoc|po|pot)$|(^|/)(README|CHANGELOG|LICENSE|AUTHORS|NEWS|VERSION)|(^|/)(test|tests|spec|testing)(/|_)|\.test\.|\.spec\.|_test\.|version\.h$|CMakeLists\.txt$|(^|/)configure$' \
      || ONLY_META=0
  done <<< "$CHANGED"
  if [ "$ONLY_META" = "1" ]; then
    EXCLUDE_REASON="${EXCLUDE_REASON:+$EXCLUDE_REASON; }仅文档/测试/配置/版本号类文件"
    printf '!! 仅文档/测试/配置/版本号类文件：\n%s\n' "$CHANGED"
  fi
fi
[ -z "$EXCLUDE_REASON" ] && printf '→ 未命中自动排除规则，需做语义判断（见下方符号/修复代码行变化）\n'

echo
echo "=== 报错符号 父提交 vs 候选提交（出现次数）==="
if [ "${#SYMS[@]}" -gt 0 ] && [ "${#PATHS[@]}" -gt 0 ]; then
  for p in "${PATHS[@]}"; do
    PTXT=$(show_path "$P" "$p"); CTXT=$(show_path "$C" "$p")
    printf -- '-- %s\n   %-44s %8s %8s %s\n' "$p" "符号" "父提交" "候选提交" "变化"
    for s in "${SYMS[@]}"; do
      a=$(occ "$PTXT" "$s"); b=$(occ "$CTXT" "$s")
      if [ "$a" = "$b" ]; then chg="="; elif [ "$b" -gt "$a" ]; then chg="+ 候选提交多了"; else chg="- 候选提交少了"; fi
      printf '   %-44s %8s %8s %s\n' "$s" "$a" "$b" "$chg"
    done
  done
else
  printf '（未提供 --sym/--symfile 或 --path，跳过）\n'
fi

echo
echo "=== 「已修复代码」行落点（理想形态：候选YES / 父NO）==="
if [ -n "$FIXED" ] && [ -f "$FIXED" ] && [ "${#PATHS[@]}" -gt 0 ]; then
  p="${PATHS[0]}"
  CTXT=$(show_path "$C" "$p"); PTXT=$(show_path "$P" "$p")
  n=0
  while IFS= read -r l; do
    l=$(printf '%s' "$l" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ "${#l}" -ge 8 ] || continue
    printf '%s' "$l" | grep -qE '^[[:punct:][:space:]]+$' && continue
    inC="no"; inP="no"
    if [ -n "$CTXT" ] && printf '%s' "$CTXT" | grep -qF -- "$l"; then inC="YES"; fi
    if [ -n "$PTXT" ] && printf '%s' "$PTXT" | grep -qF -- "$l"; then inP="YES"; fi
    printf '   [候选:%s 父:%s] %s\n' "$inC" "$inP" "$l"
    n=$((n+1)); [ "$n" -ge 15 ] && break
  done < <(tr -d '\r' < "$FIXED" | awk '!seen[$0]++')
elif [ -n "$FIXED" ]; then
  printf '（需要 --path 才能定位行落点）\n'
else
  printf '（未提供 --fixed，跳过；这是判定"强候选"最直接的证据，建议补上）\n'
fi

echo
echo "=== diff（上下文 ${CTX} 行）==="
if [ -n "$RANGE" ] && [ "${#PATHS[@]}" -gt 0 ]; then
  printf '(报错行范围 %s；行号以问题版本为准，diff 行号是候选提交侧的)\n' "$RANGE"
fi
DIFF=$(git -C "$REPO" show "${SHOW_SCOPE[@]}" --format='' -U"$CTX" --find-renames "$C" ${PATHS[@]+-- "${PATHS[@]}"} 2>/dev/null || true)
printf '%s\n' "$DIFF" | head -n 250
DN=$(printf '%s\n' "$DIFF" | grep -c '' || true)
if [ "${DN:-0}" -gt 250 ]; then printf '… diff 共 %s 行，已截断\n' "$DN"; fi

echo
echo "=== message 与报错词汇重叠 ==="
if [ -n "$ERRFILE" ] && [ -f "$ERRFILE" ]; then
  MSG=$(git -C "$REPO" show -s --format='%B' "$C" | tr 'A-Z' 'a-z')
  hit=0
  while IFS= read -r w; do
    [ "${#w}" -ge 5 ] || continue
    wl=$(printf '%s' "$w" | tr 'A-Z' 'a-z')
    if printf '%s' "$MSG" | grep -qF -- "$wl"; then printf '   命中报错词: %s\n' "$w"; hit=$((hit+1)); fi
  done < <(tr -d '\r' < "$ERRFILE" | grep -oE '[A-Za-z_][A-Za-z0-9_]{4,40}' | sort -u | head -n 80)
  printf '   重叠词数: %s\n' "$hit"
else
  printf '（未提供 --error-file，跳过）\n'
fi

printf '\nINSPECT|%s|%s|%s\n' "$(short_sha "$REPO" "$C")" \
  "$(git -C "$REPO" show "${SHOW_SCOPE[@]}" --numstat --format='' "$C" 2>/dev/null | awk '{a+=$1; d+=$2} END{printf "+%d/-%d", a, d}')" \
  "${EXCLUDE_REASON:--}"
