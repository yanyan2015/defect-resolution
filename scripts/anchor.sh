#!/usr/bin/env bash
# anchor.sh —— 阶段 1：建立版本锚点，输出候选 commit 范围。
#
# 用法：
#   anchor.sh <repo> <问题版本ref> <修复版本ref> [--path PATH] [--limit N]
#   anchor.sh <repo> <问题版本ref> -               # 修复版本未知（降级模式，见下）
#
# 降级模式（修复版本 = "-"）：无法给出 A..B 范围，改为打印 pickaxe-only 的建议命令。
#
# 输出（机器可读 KV + 人类可读锚点卡）：
#   ISSUE_COMMIT / FIXED_COMMIT / MERGE_BASE / CANDIDATES_* / SHALLOW
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

REPO=""; ISSUE_REF=""; FIXED_REF=""; PATHSPEC=""; LIMIT=50
while [ $# -gt 0 ]; do
  case "$1" in
    --path)  PATHSPEC="${2:-}"; shift 2 ;;
    --path=*) PATHSPEC="${1#*=}"; shift ;;
    --limit) LIMIT="${2:-50}"; shift 2 ;;
    --limit=*) LIMIT="${1#*=}"; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -) if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$ISSUE_REF" ]; then ISSUE_REF="$1"
       elif [ -z "$FIXED_REF" ]; then FIXED_REF="$1"; else die "多余参数: $1"; fi; shift ;;
    --) shift; while [ $# -gt 0 ]; do
          if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$ISSUE_REF" ]; then ISSUE_REF="$1"
          elif [ -z "$FIXED_REF" ]; then FIXED_REF="$1"; else die "多余参数: $1"; fi; shift
        done ;;
    -*) die "未知参数: $1" ;;
    *) if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$ISSUE_REF" ]; then ISSUE_REF="$1"
       elif [ -z "$FIXED_REF" ]; then FIXED_REF="$1"; else die "多余参数: $1"; fi; shift ;;
  esac
done
[ -n "$REPO" ] && [ -n "$ISSUE_REF" ] && [ -n "$FIXED_REF" ] || die "用法: anchor.sh <repo> <issue-ref> <fixed-ref|-> [--path PATH]"

require_git_repo "$REPO"
REPO=$(cd "$REPO" && pwd)

ISSUE_SHA=$(resolve_ref "$REPO" "$ISSUE_REF") || die "问题版本 ref 无法解析: $ISSUE_REF"

emit_anchor() { # $1=label $2=raw $3=sha
  printf '%-12s %s\n' "$1" "$3"
  printf '  ref        : %s\n' "$2"
  printf '  short      : %s\n' "$(short_sha "$REPO" "$3")"
  printf '  date       : %s\n' "$(date_of "$REPO" "$3")"
  printf '  nearest tag: %s\n' "$(nearest_tag "$REPO" "$3")"
  printf '  subject    : %s\n' "$(subject_of "$REPO" "$3")"
}

printf '=== 锚点卡 ===\n'
emit_anchor "问题版本" "$ISSUE_REF" "$ISSUE_SHA"
printf 'ISSUE_COMMIT=%s\n' "$ISSUE_SHA"

SHALLOW=$(git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null || echo unknown)
[ "$SHALLOW" = "true" ] && warn "浅克隆：blame/pickaxe/merge-base 不可信，先 git fetch --unshallow"

if [ "$FIXED_REF" = "-" ] || [ -z "$FIXED_REF" ]; then
  printf '%-12s %s\n' "修复版本" "(未知 —— 降级为 pickaxe 反查模式)"
  printf 'DEGRADED_MODE=pickaxe-only\n'
  printf 'FIXED_COMMIT=\n'
  cat <<'EOS'

降级建议：用"已修复代码"的特征行直接反查（最强信号）
  1) 把修复版代码逐行拆开做 pickaxe（先限路径，无命中再全仓）：
       git -C <repo> log --format='%h %s' -S'<修复代码中的特征行>' <问题版本>..HEAD -- <path>
       git -C <repo> log --format='%h %s' -S'<修复代码中的特征行>' --all -- <path>
  2) 报错涉及符号的引入/删除：
       git -C <repo> log --format='%h %s' -S'<symbol>' --all
       git -C <repo> log --format='%h %s' -G'<regex>'  --all
  3) 命中后把命中 commit 当作修复版本锚点，再回来跑: anchor.sh <repo> <问题版本ref> <命中commit>
EOS
  exit 0
fi

FIXED_SHA=$(resolve_ref "$REPO" "$FIXED_REF") || die "修复版本 ref 无法解析: $FIXED_REF"
emit_anchor "修复版本" "$FIXED_REF" "$FIXED_SHA"
printf 'FIXED_COMMIT=%s\n' "$FIXED_SHA"

MB=$(git -C "$REPO" merge-base "$ISSUE_SHA" "$FIXED_SHA") || MB=""
printf '%-12s %s\n' "merge-base" "${MB:-<none>}"
printf 'MERGE_BASE=%s\n' "$MB"

TOTAL=$(cnt "$REPO" "$ISSUE_SHA" "$FIXED_SHA")
NOMERGE=$(cnt "$REPO" "$ISSUE_SHA" "$FIXED_SHA" --no-merges)
FIRSTPAR=$(cnt "$REPO" "$ISSUE_SHA" "$FIXED_SHA" --first-parent)
printf 'CANDIDATES_TOTAL=%s\n' "$TOTAL"
printf 'CANDIDATES_NO_MERGES=%s\n' "$NOMERGE"
printf 'CANDIDATES_FIRST_PARENT=%s\n' "$FIRSTPAR"

if [ -n "$PATHSPEC" ]; then
  RP=$(rel_path "$REPO" "$PATHSPEC")
  PVALID=1
  git -C "$REPO" cat-file -e "$FIXED_SHA:$RP" 2>/dev/null || PVALID=0
  PS=$(cnt "$REPO" "$ISSUE_SHA" "$FIXED_SHA" -- "$RP")
  PNM=$(cnt "$REPO" "$ISSUE_SHA" "$FIXED_SHA" --no-merges -- "$RP")
  printf 'PATH=%s\n' "$RP"
  printf 'CANDIDATES_PATH=%s\n' "$PS"
  printf 'CANDIDATES_PATH_NO_MERGES=%s\n' "$PNM"
  [ "$PVALID" = "1" ] || warn "该路径在修复版本中不存在（可能改名/删除）：$RP"
  if [ "$PS" = "0" ]; then
    warn "限定路径后候选为 0：文件可能被重命名，试 git -C '$REPO' log --follow --name-status <A>..<B> -- '$RP'"
  fi
fi

printf 'SHALLOW=%s\n' "$SHALLOW"

# --- 版本序列分析（"这个 bug 在哪个版本修好的"）-----------------------------
# 从问题版本到修复版本之间，所有 tag 的序列。
# 这是主场景的核心信息：用户给两个版本，我们要说清"中间的哪个版本开始是好的"。
# 序列从**问题版本**（含）开始 —— 问题版本之前的 tag 与本次归因无关，不应混入。
printf '\n=== 版本序列（问题版本 → 修复版本）===\n'
SEQ_TAGS=""
while read -r tname tcommit; do
  [ -n "$tname" ] || continue
  # tag 必须能到达修复版本（含修复版本本身）
  if ! git -C "$REPO" merge-base --is-ancestor "$tcommit" "$FIXED_SHA" 2>/dev/null; then continue; fi
  # tag 在问题版本的祖先侧（严格早于问题版本）→ 排除。
  # 问题版本自身的 tag 保留 —— 它是序列的起点（"仍有 bug"的第一个版本）。
  if git -C "$REPO" merge-base --is-ancestor "$tcommit" "$ISSUE_SHA" 2>/dev/null; then
    [ "$(git -C "$REPO" rev-parse "$tcommit")" = "$ISSUE_SHA" ] || continue
  fi
  SEQ_TAGS="$SEQ_TAGS $tname"
done < <(list_tags "$REPO")
printf '区间内的发布版本:%s\n' "${SEQ_TAGS:- (无 tag —— 项目可能未打版本标签)}"
if [ -z "$SEQ_TAGS" ]; then
  printf '提示: 该区间没有任何 tag。若项目用 release 分支而非 tag 发版，\n'
  printf '      请改用分支/commit 作为版本锚点，或用 --grep 搜 message 里的版本号。\n'
else
  printf '注意: 修复可能落在其中**任意一个**版本，不一定是用户给的"修复版本"那个。\n'
  printf '      取证完成后必须用 inspect.sh 的"版本归属"确认**首次包含修复的发布版本**。\n'
fi
printf 'TAG_SEQUENCE=%s\n' "$(printf '%s' "$SEQ_TAGS" | sed 's/^ //')"

printf '\n=== 范围概览（含 merge）===\n'
LOG_ARGS=(log --oneline --no-decorate -n "$LIMIT" "$ISSUE_SHA..$FIXED_SHA")
if [ -n "$PATHSPEC" ]; then LOG_ARGS+=(-- "$(rel_path "$REPO" "$PATHSPEC")"); fi
git -C "$REPO" "${LOG_ARGS[@]}" || true
if [ "$TOTAL" -gt "$LIMIT" ] 2>/dev/null; then
  printf '… 共 %s 个（仅显示前 %s 个）\n' "$TOTAL" "$LIMIT"
fi

case "$TOTAL" in
  ''|*[!0-9]*) : ;;
  *) if [ "$TOTAL" -gt 2000 ]; then
       warn "候选范围 $TOTAL 个提交，过大。先收窄再进阶段 2（见 SKILL.md 阶段 1 的收窄命令）"
     fi ;;
esac

if [ "$TOTAL" = "0" ]; then
  warn "A..B 为空：问题版本可能就是修复版本的祖先之外，或两 ref 相同。检查锚点是否正确。"
fi
