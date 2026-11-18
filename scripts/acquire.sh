#!/usr/bin/env bash
# acquire.sh —— 阶段 0：获取待归因的仓库（本地直用，远程 blobless clone）。
#
# 用法：
#   acquire.sh <repo-path 或 url> [ref] [--dest DIR] [--checkout] [--full]
#
# 说明：
#   * 远程 clone 强制使用 --filter=blob:none（完整提交历史 + 按需取 blob）。
#     绝不用 --depth=1 / --shallow-since：浅克隆会让 blame / pickaxe /
#     merge-base / bisect 全部失真，而本 skill 的核心恰恰全依赖这些。
#   * 默认不 checkout（--no-checkout），只取历史；需要读工作树文件时加 --checkout。
#   * 输出 REPO= / HISTORY_COMPLETE= / HEAD= 三行，供后续脚本消费；clone 目录不自动删除，
#     归因结束后由调用方删除（把路径打印在 CLEANUP= 行里）。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

SRC=""; REF=""; DEST=""; DO_CHECKOUT=0; FULL=0; OFFLINE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dest)     DEST="${2:-}"; shift 2 ;;
    --dest=*)   DEST="${1#*=}"; shift ;;
    --checkout) DO_CHECKOUT=1; shift ;;
    --full)     FULL=1; shift ;;
    --offline)  OFFLINE=1; shift ;;
    -h|--help)  sed -n '2,16p' "$0"; exit 0 ;;
    -*)         die "未知参数: $1" ;;
    *)          if [ -z "$SRC" ]; then SRC="$1"; elif [ -z "$REF" ]; then REF="$1"; else die "多余参数: $1"; fi; shift ;;
  esac
done
[ -n "$SRC" ] || die "用法: acquire.sh <repo-path|url> [ref] [--dest DIR] [--checkout] [--offline]"

# --offline：强制不联网。用于私有/敏感仓库 —— 确保整个取证过程零外发。
# blobless clone 在首次取 blob 时可能触发隐式 fetch，离线模式下必须用完整 clone。
if [ "$OFFLINE" = "1" ]; then
  export GIT_TERMINAL_PROMPT=0
  export GIT_ASKPASS=true
  export GIT_ALLOW_PROTOCOL=none
  export http_proxy='' https_proxy='' HTTP_PROXY='' HTTPS_PROXY=''
  note "--offline：已禁用一切网络访问（私有/敏感仓库模式）"
fi

if [ -d "$SRC" ]; then
  REPO=$(cd "$SRC" && pwd)
  if ! git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    # 非 git 目录：明确诊断，给出可行出路，而不是笼统报错
    cat >&2 <<EOS
ERROR: '$REPO' 不是 git 仓库，无法做版本归因。

原因：版本归因依赖 Git 历史（blame / pickaxe / merge-base / bisect）。
      没有历史就没有证据链，"哪个版本修好的"这个问题无法回答。

可行出路：
  1) 如果这是某个开源项目的副本 → 告诉我仓库地址，我会 clone 后取证
     （例：https://github.com/owner/repo.git）
  2) 如果这是私有项目 → 确认它是否被 git 管理过：
       git -C "$REPO" rev-parse --git-dir
     若有 .git 目录但当前目录不是仓库根，请给出仓库根路径
  3) 如果确实没有版本历史 → 只能做"当前代码的静态分析"，
     无法给出修复版本与 commit。请明确告知用户这个边界。
EOS
    exit 2
  fi
  printf 'REPO=%s\n' "$REPO"
  printf 'SOURCE=local\n'
  printf 'NETWORK=not-used\n'
else
  case "$SRC" in
    *://*|git@*|*/*.git|*github.com/*|*gitlab.com/*|*gitee.com/*) : ;;
    *) die "'$SRC' 既不是本地目录，也不像仓库 URL" ;;
  esac
  [ -n "$DEST" ] || DEST=$(mktmpdir)/repo
  mkdir -p "$(dirname "$DEST")"
  [ -e "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null || true)" ] && die "目标目录非空: $DEST"
  if [ "$FULL" = "1" ] || [ "$OFFLINE" = "1" ]; then
    [ "$OFFLINE" = "1" ] && warn "--offline：使用完整 clone（blobless 首次取 blob 需要联网）"
    [ "$FULL" = "1" ] && [ "$OFFLINE" = "0" ] && warn "--full：拉取全部 blob（慢但离线可用）"
    run git clone --no-checkout "$SRC" "$DEST"
  else
    note "blobless clone（完整历史，按需取 blob）: $SRC → $DEST"
    run git clone --filter=blob:none --no-checkout "$SRC" "$DEST" \
      || { warn "--filter=blob:none 不被支持，退回完整 clone"; run git clone --no-checkout "$SRC" "$DEST"; }
  fi
  REPO=$(cd "$DEST" && pwd)
  printf 'REPO=%s\n' "$REPO"
  printf 'SOURCE=remote\n'
  printf 'CLEANUP=rm -rf %s\n' "$(dirname "$DEST")"
fi

if [ -n "$REF" ]; then
  if ! git -C "$REPO" rev-parse --verify --quiet "${REF}^{commit}" >/dev/null 2>&1; then
    note "本地没有 ref '$REF'，尝试 fetch"
    if [ "$OFFLINE" = "1" ]; then
      warn "--offline：跳过 fetch（不会联网）。该 ref 必须已在本地存在。"
    else
      run git -C "$REPO" fetch --tags --quiet origin "$REF" 2>/dev/null \
        || run git -C "$REPO" fetch --tags --all --quiet 2>/dev/null || true
    fi
  fi
  require_commit "$REPO" "$REF"
  REF_SHA=$(resolve_ref "$REPO" "$REF")
  printf 'REF=%s\n' "$REF"
  printf 'REF_COMMIT=%s\n' "$REF_SHA"
  if [ "$DO_CHECKOUT" = "1" ]; then
    run git -C "$REPO" checkout --quiet --detach "$REF_SHA"
    note "已 checkout --detach $REF_SHA"
  fi
fi

SHALLOW=$(git -C "$REPO" rev-parse --is-shallow-repository 2>/dev/null || echo unknown)
if [ "$SHALLOW" = "true" ]; then
  warn "这是一个浅克隆：blame / pickaxe / merge-base 结果不可信。修复：git -C '$REPO' fetch --unshallow"
  printf 'HISTORY_COMPLETE=no\n'
else
  printf 'HISTORY_COMPLETE=yes\n'
fi
printf 'COMMIT_COUNT=%s\n' "$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo '?')"
printf 'HEAD=%s\n' "$(resolve_ref "$REPO" HEAD || echo '?')"
