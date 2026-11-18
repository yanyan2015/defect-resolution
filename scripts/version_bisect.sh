#!/usr/bin/env bash
# version_bisect.sh —— 在**版本维度**上定位"这个 bug 在哪个发布版本被修好"。
#
# 这是主场景的核心能力。commit 维度的取证（collect.sh）回答"哪次提交改的"，
# 而本脚本回答"哪个发布版本里 bug 消失了"——两者互为补充，且能互相印证。
#
# 为什么需要它：
#   用户通常只知道"v1.0.0 有 bug，v2.0.0 好了"。但从 v1.0.0 到 v2.0.0 之间
#   可能有几十个提交、多个中间版本，其中还夹着大量无关重构。
#   直接在 commit 区间上取证，范围大、噪音多。
#   而**版本序列是离散的、可逐个检查的** —— 这是一个天然的粗筛粒度。
#
# 用法：
#   version_bisect.sh <repo> <坏版本ref> <好版本ref> [选项]
#
# 选项：
#   --path PATH        出错文件（可多次）
#   --range S,E        出错行范围（基于坏版本）
#   --sym SYM          判据符号：文件里不再含它 → 视为已修复（可多次）
#   --contains TEXT    判据：文件里不再含这段文本 → 视为已修复
#   --missing TEXT     判据：文件里**开始**含这段文本 → 视为已修复（用于"补上了缺失的宏"）
#   --run-cmd CMD      判据命令：返回 0 = 该版本仍有 bug；非 0 = 已修复
#                      （与 verify.sh 的 bisect 约定一致）
#   --tag-list         只列出区间内的版本序列，不做判定
#   --all-versions     列出仓库所有发布版本（不限区间）
#
# 判定逻辑：
#   对版本序列里的每个 tag，从早到晚检查判据：
#     · 判据仍成立 → 该版本仍有 bug
#     · 判据不再成立 → **这个 tag 就是修复落地的版本**
#   若到好版本为止都没找到转变点 → 说明修复在好版本之后，或判据不对
#
# 输出：
#   FIX_VERSION=<tag>          首个不再有 bug 的版本
#   STILL_BROKEN_BEFORE=<tag>  最后一个仍有 bug 的版本
#   CHECKED=<n>                检查了几个版本
#   VERSION_TABLE              逐版本判定明细
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

REPO=""; BAD_REF=""; GOOD_REF=""
PATHS=(); SYMS=(); CONTAINS=(); MISSING=(); RUNCMD=""
RANGE=""
TAGLIST_ONLY=0; ALL_VERSIONS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --path)       PATHS+=("${2:-}"); shift 2 ;;
    --path=*)     PATHS+=("${1#*=}"); shift ;;
    --range)      RANGE="${2:-}"; shift 2 ;;
    --range=*)    RANGE="${1#*=}"; shift ;;
    --sym)        SYMS+=("${2:-}"); shift 2 ;;
    --sym=*)      SYMS+=("${1#*=}"); shift ;;
    --contains)   CONTAINS+=("${2:-}"); shift 2 ;;
    --contains=*) CONTAINS+=("${1#*=}"); shift ;;
    --missing)    MISSING+=("${2:-}"); shift 2 ;;
    --missing=*)  MISSING+=("${1#*=}"); shift ;;
    --run-cmd)    RUNCMD="${2:-}"; shift 2 ;;
    --run-cmd=*)  RUNCMD="${1#*=}"; shift ;;
    --tag-list)   TAGLIST_ONLY=1; shift ;;
    --all-versions) ALL_VERSIONS=1; shift ;;
    -h|--help)    sed -n '2,30p' "$0"; exit 0 ;;
    -*)           die "未知参数: $1" ;;
    *)            if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$BAD_REF" ]; then BAD_REF="$1"
                  elif [ -z "$GOOD_REF" ]; then GOOD_REF="$1"; else die "多余参数: $1"; fi; shift ;;
  esac
done
[ -n "$REPO" ] && [ -n "$BAD_REF" ] && [ -n "$GOOD_REF" ] \
  || die "用法: version_bisect.sh <repo> <bad-ref> <good-ref> [选项]"
require_git_repo "$REPO"
REPO=$(cd "$REPO" && pwd)
BAD_SHA=$(resolve_ref "$REPO" "$BAD_REF") || die "坏版本无法解析: $BAD_REF"
GOOD_SHA=$(resolve_ref "$REPO" "$GOOD_REF") || die "好版本无法解析: $GOOD_REF"
for i in "${!PATHS[@]}"; do PATHS[$i]=$(rel_path "$REPO" "${PATHS[$i]}"); done

# --- 构造版本序列 -------------------------------------------------------------
# 只保留：祖先关系上位于 [BAD_SHA, GOOD_SHA] 区间内的 tag，按时间排序。
SEQ=""
while read -r tname tcommit; do
  [ -n "$tname" ] || continue
  if [ "$ALL_VERSIONS" = "1" ]; then
    SEQ="$SEQ $tname"
    continue
  fi
  # tag 必须在好版本（含）之前
  git -C "$REPO" merge-base --is-ancestor "$tcommit" "$GOOD_SHA" 2>/dev/null || continue
  # 且不在坏版本之前（坏版本及其祖先排除；坏版本本身保留）
  if git -C "$REPO" merge-base --is-ancestor "$tcommit" "$BAD_SHA" 2>/dev/null; then
    # tcommit 是坏版本的祖先 → 在坏版本之前，跳过（但坏版本本身若正好有 tag 要保留）
    [ "$(git -C "$REPO" rev-parse "$tcommit")" = "$BAD_SHA" ] && SEQ="$SEQ $tname"
    continue
  fi
  SEQ="$SEQ $tname"
done < <(list_tags "$REPO")

printf '=== 版本序列（%s → %s）===\n' "$BAD_REF" "$GOOD_REF"
if [ -z "$SEQ" ]; then
  printf '（区间内没有任何发布标签）\n'
  printf 'TAG_SEQUENCE=\n'
  if [ "$TAGLIST_ONLY" = "1" ]; then exit 0; fi
  warn "该仓库在此区间无 tag，无法做版本维度判定。"
  warn "可能原因：项目用 release 分支发版、tag 命名不同、或区间内确实没有发版。"
  warn "替代方案：用分支/commit 作为版本锚点，或用 --all-versions 列出全部标签再确认范围。"
  exit 0
fi
printf '%s\n' "$SEQ" | tr ' ' '\n' | grep -v '^$' | while read -r t; do
  printf '  %-20s %s\n' "$t" "$(git -C "$REPO" log -1 --format='%ad  %s' --date=short "$t^{commit}" 2>/dev/null)"
done
printf 'TAG_SEQUENCE=%s\n' "$(printf '%s' "$SEQ" | sed 's/^ //')"

if [ "$TAGLIST_ONLY" = "1" ]; then exit 0; fi

# --- 构造判据 -----------------------------------------------------------------
# 自动判据（若用户没给显式判据）：从坏版本的出错文件/行范围提取内容，
# 检查该内容在每个版本里是否还在 —— 还在 = bug 还在。
AUTO_CONTENT=""
# --missing 的内容必须在**坏版本里不存在**（否则"它出现了"说明不了任何事）
MISSING_VALID=""
# --contains 的内容必须在**坏版本里存在**（否则"它消失了"一开始就成立，等于没判据）
CONTAINS_VALID=""
if [ "${#PATHS[@]}" -gt 0 ]; then
  p0="${PATHS[0]}"
  BADTEXT=$(git -C "$REPO" show "$BAD_SHA:$p0" 2>/dev/null || true)
  if [ -n "$BADTEXT" ]; then
    for c in ${CONTAINS[@]+"${CONTAINS[@]}"}; do
      if printf '%s' "$BADTEXT" | grep -qF -- "$c"; then
        CONTAINS_VALID="$CONTAINS_VALID$c
"
      else
        warn "--contains '$c' 在坏版本中就不存在，不能用于判定「该内容已消失」，已忽略"
        warn "              请改用坏版本里**确实存在**的报错现场文本（如报错那一行代码）"
      fi
    done
    for m in ${MISSING[@]+"${MISSING[@]}"}; do
      if printf '%s' "$BADTEXT" | grep -qF -- "$m"; then
        warn "--missing '$m' 在坏版本中就存在，不能用于判定「补上了缺失的东西」，已忽略"
      else
        MISSING_VALID="$MISSING_VALID$m
"
      fi
    done
    # --sym 的符号必须在坏版本里存在，否则"它消失了"一开始就成立
    SYMS_VALID=""
    for s in ${SYMS[@]+"${SYMS[@]}"}; do
      if printf '%s' "$BADTEXT" | grep -qF -- "$s"; then
        SYMS_VALID="$SYMS_VALID$s
"
      else
        warn "--sym '$s' 在坏版本中就不存在，不能用于判定「该符号已消失」，已忽略"
      fi
    done
  fi
fi
if [ "${#CONTAINS[@]}" -eq 0 ] && [ -z "$MISSING_VALID" ] && [ -z "$RUNCMD" ] && [ "${#SYMS[@]}" -eq 0 ]; then
  if [ "${#PATHS[@]}" -gt 0 ]; then
    p="${PATHS[0]}"
    if [ -n "${RANGE:-}" ]; then
      s=${RANGE%%,*}; e=${RANGE##*,}
      AUTO_CONTENT=$(git -C "$REPO" show "$BAD_SHA:$p" 2>/dev/null | sed -n "${s},${e}p" | head -5)
    else
      AUTO_CONTENT=$(git -C "$REPO" show "$BAD_SHA:$p" 2>/dev/null | head -20)
    fi
    [ -n "$AUTO_CONTENT" ] && note "未给显式判据，自动采用「坏版本中该文件的内容是否仍在」作为判据"
  fi
fi
if [ -z "$RUNCMD" ] && [ -z "$CONTAINS_VALID" ] && [ -z "$MISSING_VALID" ] && [ -z "$SYMS_VALID" ] \
   && [ -z "$AUTO_CONTENT" ]; then
  # 用户给了显式判据但全部被校验忽略，或根本没给有效判据 —— 必须报错退出。
  # 静默继续会导致 check_version 对每个版本都返回"已修复"，
  # 从而输出完全错误的 FIX_VERSION=v1.0.0（实测踩过）。
  if [ "${#CONTAINS[@]}" -gt 0 ] || [ "${#MISSING[@]}" -gt 0 ] || [ "${#SYMS[@]}" -gt 0 ]; then
    die "提供的判据全部无效（在坏版本中已存在/不存在），且没有可用的自动判据。
      正确用法：
        --contains / --sym  → 给坏版本里**确实存在**的报错现场文本或符号
        --missing           → 给坏版本里**不存在**、修复后才有的内容
      可先用 git -C <repo> show <坏版本>:<文件> 确认判据文本确实存在于坏版本。"
  fi
  die "没有任何判据可用。请给 --contains / --missing / --sym / --run-cmd 之一，或给 --path（自动判据需要它）。"
fi

# 检查单个版本：该版本是否"仍有 bug"
# 返回 0 = 仍有 bug；返回 1 = 已修复
check_version() {
  local tag="$1" tc
  tc=$(git -C "$REPO" rev-parse --verify --quiet "${tag}^{commit}") || return 0

  # ① 显式命令判据：0 = 仍有 bug
  if [ -n "$RUNCMD" ]; then
    local WT
    WT=$(mktmpdir)/wt
    if git -C "$REPO" worktree add --detach "$WT" "$tc" >/dev/null 2>&1; then
      ( cd "$WT" && bash -c "$RUNCMD" ) >/dev/null 2>&1
      local rc=$?
      git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
      rm -rf "$(dirname "$WT")" 2>/dev/null || true
      [ $rc -eq 0 ] && return 0 || return 1
    fi
    return 0
  fi

  # ② --contains：文本还在 = 仍有 bug
  local text
  for p in ${PATHS[@]+"${PATHS[@]}"}; do
    text=$(git -C "$REPO" show "$tc:$p" 2>/dev/null || true)
    [ -n "$text" ] || continue
    if [ -n "$CONTAINS_VALID" ]; then
      local c
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        printf '%s' "$text" | grep -qF -- "$c" && return 0   # 文本还在 → 仍有 bug
      done <<< "$CONTAINS_VALID"
      return 1                                          # 判据文本都不在了 → 已修复
    fi
    # --missing：内容开始出现 = 已修复
    # 只用 --missing 时：内容**还没出现** → 仍有 bug（return 0），必须明确返回
    if [ -n "$MISSING_VALID" ]; then
      local any_missing=1
      while IFS= read -r m; do
        [ -n "$m" ] || continue
        printf '%s' "$text" | grep -qF -- "$m" && { any_missing=0; break; }
      done <<< "$MISSING_VALID"
      [ "$any_missing" = "0" ] && return 1   # 内容出现了 → 已修复
      [ "${#CONTAINS[@]}" -eq 0 ] && [ "${#SYMS[@]}" -eq 0 ] && [ -z "$AUTO_CONTENT" ] && return 0
    fi
    # --sym：符号消失 = 已修复（符号还在则说明还带着这个 bug）
    # 符号必须在坏版本里存在，否则判据无意义
    if [ -n "$SYMS_VALID" ]; then
      local sym_found=0 s
      while IFS= read -r s; do
        [ -n "$s" ] || continue
        printf '%s' "$text" | grep -qF -- "$s" && { sym_found=1; break; }
      done <<< "$SYMS_VALID"
      [ "$sym_found" = "1" ] && return 0   # 符号还在 → 仍有 bug
      return 1                             # 符号都没了 → 已修复
    fi
    # 自动判据：坏版本中该范围的内容与该版本是否一致。
    # 不能用"内容存在性"判定 —— 文件头部的 #include 等稳定行永远存在，
    # 修复只改中部几行时会被误判为"仍有 bug"。必须直接 diff 对比。
    if [ -n "$AUTO_CONTENT" ]; then
      local now
      if [ -n "${RANGE:-}" ]; then
        s=${RANGE%%,*}; e=${RANGE##*,}
        now=$(printf '%s' "$text" | sed -n "${s},${e}p")
      else
        now=$(printf '%s' "$text" | head -20)
      fi
      if [ "$(printf '%s' "$AUTO_CONTENT" | grep -c '')" -eq "$(printf '%s' "$now" | grep -c '')" ] \
         && [ "$AUTO_CONTENT" = "$now" ]; then
        return 0   # 内容与坏版本完全一致 → bug 还在
      fi
      return 1     # 有任何差异 → 已改写，视为已修复
    fi
  done
  return 1
}

# --- 逐版本判定 ---------------------------------------------------------------
printf '\n=== 逐版本判定 ===\n'
FIX_VERSION=""
STILL_BROKEN_BEFORE=""
CHECKED=0
for t in $SEQ; do
  CHECKED=$((CHECKED+1))
  if check_version "$t"; then
    printf '  %-20s 仍有 bug\n' "$t"
    STILL_BROKEN_BEFORE="$t"
  else
    printf '  %-20s ✓ 已修复\n' "$t"
    FIX_VERSION="$t"
    break
  fi
done

printf '\nVERSION_TABLE=\n'
for t in $SEQ; do
  if check_version "$t"; then printf '%s=broken,' "$t"; else printf '%s=fixed,' "$t"; break; fi
done
printf '\n'

if [ -n "$FIX_VERSION" ]; then
  printf 'FIX_VERSION=%s\n' "$FIX_VERSION"
  [ -n "$STILL_BROKEN_BEFORE" ] && printf 'STILL_BROKEN_BEFORE=%s\n' "$STILL_BROKEN_BEFORE"
  printf 'CHECKED=%s\n' "$CHECKED"
  cat <<EOS

解读：这个 bug 在 **$FIX_VERSION** 被修好；**$STILL_BROKEN_BEFORE** 仍有问题。
下一步：用 collect.sh 在 [$STILL_BROKEN_BEFORE .. $FIX_VERSION] 这个**更窄的区间**上取证，
      锁定具体是哪次提交做的修改。
      bash collect.sh <repo> $STILL_BROKEN_BEFORE $FIX_VERSION --path <file> --range <s>,<e> ...
EOS
else
  printf 'FIX_VERSION=\n'
  printf 'CHECKED=%s\n' "$CHECKED"
  warn "在给出的版本区间内没找到"bug 消失"的转变点。可能原因："
  warn "  1) 判据不对（文本/符号选错了）—— 换判据重试"
  warn "  2) 修复发生在好版本之后的某个提交（但尚未发版）"
  warn "  3) 修复在好版本里，但不在 --path 指定的文件里 —— 去掉 --path 用 --all-versions 重查"
fi
