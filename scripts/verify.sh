#!/usr/bin/env bash
# verify.sh —— 阶段 4：对强候选做确定性验证（方法 A 二分 / B 父提交对比 / C 反向验证）。
#
# 用法：
#   verify.sh <repo> <candidate> --A <问题版本> --B <修复版本>
#             [--path P]... [--sym S]... [--symfile FILE] [--range S,E]
#             [--fixed FILE] [--run-cmd 'CMD'] [--no-run] [--keep] [--context N]
#
# 安全：所有需要改工作树的操作（bisect / revert）都在**临时 worktree** 中执行，
#       绝不触碰用户仓库的工作区与索引（--keep 保留临时 worktree 供人工排查）。
#
# --run-cmd 的判据约定（决定结论强度）——方向不能反：
#       判据测试「报错触发条件是否仍成立」：成立 → exit 0；报错已消失 → exit 非 0。
#       git bisect 的 first bad commit = 首个判据非 0 的提交 = 首个让报错消失的提交 = 修复 commit。
#       例（条件仍在 → 0）：
#         grep -q "error: .FOO_H. undeclared" <(make foo.o 2>&1)   # 编译错误还在
#         grep -q "strcpy(dst, src)" src/foo.c                     # 危险调用还在
#       反例（方向反了，会得到无意义结果）：
#         grep -q "define FOO_H" include/foo.h                     # 这测的是"修复特征存在"
#       若确实只有"修复特征"可测，用 ! 反转：! grep -q "define FOO_H" include/foo.h
#       git bisect 约定：0=good，1-127=bad，125=skip，>127=abort。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

REPO=""; CAND=""; AA=""; BB=""
PATHS=(); SYMS=(); SYMFILE=""; RANGE=""; FIXED=""
RUNCMD=""; NO_RUN=0; KEEP=0; CTX=3
while [ $# -gt 0 ]; do
  case "$1" in
    --A)           AA="${2:-}"; shift 2 ;;
    --A=*)         AA="${1#*=}"; shift ;;
    --B)           BB="${2:-}"; shift 2 ;;
    --B=*)         BB="${1#*=}"; shift ;;
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
    --run-cmd)     RUNCMD="${2:-}"; shift 2 ;;
    --run-cmd=*)   RUNCMD="${1#*=}"; shift ;;
    --no-run)      NO_RUN=1; shift ;;
    --keep)        KEEP=1; shift ;;
    --context)     CTX="${2:-3}"; shift 2 ;;
    --context=*)   CTX="${1#*=}"; shift ;;
    -h|--help)     sed -n '2,22p' "$0"; exit 0 ;;
    -*)            die "未知参数: $1" ;;
    *)             if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$CAND" ]; then CAND="$1"; else die "多余参数: $1"; fi; shift ;;
  esac
done
[ -n "$REPO" ] && [ -n "$CAND" ] || die "用法: verify.sh <repo> <candidate> --A A --B B [选项]"
require_git_repo "$REPO"
REPO=$(cd "$REPO" && pwd)
CAND=$(resolve_ref "$REPO" "$CAND") || die "候选 commit 无法解析: $CAND"
CAND_P=$(git -C "$REPO" rev-parse --verify --quiet "${CAND}^" 2>/dev/null || true)
[ -n "$CAND_P" ] || die "候选 commit 没有父提交（根提交），无法做父提交对比"

RES_A="n/a"; RES_B="n/a"; RES_C="n/a"
if [ "${#PATHS[@]}" -gt 0 ]; then
  for i in "${!PATHS[@]}"; do PATHS[$i]=$(rel_path "$REPO" "${PATHS[$i]}"); done
fi
if [ -n "$SYMFILE" ] && [ -f "$SYMFILE" ]; then
  while IFS= read -r l; do [ -n "$l" ] && SYMS+=("$l"); done \
    < <(tr -d '\r' < "$SYMFILE" | awk -F'\t' 'NF>2{print $3; next} {print $1}' | awk '!seen[$0]++')
fi
if [ -n "$AA" ]; then AA=$(resolve_ref "$REPO" "$AA") || die "--A 无法解析"; fi
if [ -n "$BB" ]; then BB=$(resolve_ref "$REPO" "$BB") || die "--B 无法解析"; fi

show_path() { git -C "$REPO" cat-file -p "$1:$2" 2>/dev/null || true; }
occ() {
  [ -n "$1" ] || { printf '0'; return 0; }
  printf '%s' "$1" | grep -oF -- "$2" 2>/dev/null | wc -l | tr -d ' '
  return 0
}
SHOW_SCOPE=(-m --first-parent)
[ "$(git -C "$REPO" rev-list --no-walk --count --merges "$CAND" 2>/dev/null || echo 0)" = "1" ] \
  && SCOPENOTE="（merge 提交，按 first-parent 展开）" || SCOPENOTE=""

echo "################################################################"
printf '候选       %s  %s\n' "$(short_sha "$REPO" "$CAND")" "$(subject_of "$REPO" "$CAND")"
printf '父提交     %s\n' "$(short_sha "$REPO" "$CAND_P")"
[ -n "$AA" ] && printf '问题版本   %s（用户给的问题版本锚点）\n' "$(short_sha "$REPO" "$AA")"
[ -n "$BB" ] && printf '好版本     %s（用户给的好版本锚点）\n' "$(short_sha "$REPO" "$BB")"
printf '路径       %s\n' "${PATHS[*]:-<未限定，符号对比将跳过>}"

# 版本归属（"这个 bug 在哪个版本修好的"）
first_containing_tag "$REPO" "$CAND"
previous_tag "$REPO" "$CAND"
printf '修复版本   %s（首次包含该修复提交的发布版本）\n' "${FIRST_CONTAINING_TAG:-<尚未进入任何发布 tag>}"
[ -n "$PREVIOUS_TAG" ] && printf '上个版本   %s（仍含此缺陷）\n' "$PREVIOUS_TAG"
echo "################################################################"

# ---------------------------------------------------------------- 方法 B
echo
echo "=== 方法 B：父提交对比 ${SCOPENOTE}==="
printf -- '--- git show -U%s <cand> ---\n' "$CTX"
git -C "$REPO" show "${SHOW_SCOPE[@]}" --format='' -U"$CTX" "$CAND" ${PATHS[@]+-- "${PATHS[@]}"} 2>/dev/null | head -n 160 || true

echo
printf -- '--- 报错相关符号：父提交 vs 候选提交 ---\n'
if [ "${#SYMS[@]}" -gt 0 ] && [ "${#PATHS[@]}" -gt 0 ]; then
  DISAPPEARED=0; APPEARED=0; SAME=0
  for p in "${PATHS[@]}"; do
    PTXT=$(show_path "$CAND_P" "$p"); CTXT=$(show_path "$CAND" "$p")
    printf -- '-- %s\n   %-46s %8s %8s %s\n' "$p" "符号" "父提交" "候选提交" "判定"
    for s in "${SYMS[@]}"; do
      a=$(occ "$PTXT" "$s"); b=$(occ "$CTXT" "$s")
      if [ "$a" -gt 0 ] && [ "$b" -eq 0 ]; then verdict="父有/候选无 → 触发条件被消除"; DISAPPEARED=$((DISAPPEARED+1))
      elif [ "$a" -eq 0 ] && [ "$b" -gt 0 ]; then verdict="父无/候选有 → 补上了缺失的东西"; APPEARED=$((APPEARED+1))
      elif [ "$a" != "$b" ]; then verdict="数量变化 ${a}→$b"
      else verdict="数量不变（此符号不是改动点）"; SAME=$((SAME+1)); fi
      printf '   %-46s %8s %8s %s\n' "$s" "$a" "$b" "$verdict"
    done
  done
  printf '\n符号层面: 被消除 %s 个 / 被补上 %s 个 / 无变化 %s 个\n' "$DISAPPEARED" "$APPEARED" "$SAME"
  if [ "$DISAPPEARED" -gt 0 ] || [ "$APPEARED" -gt 0 ]; then
    RES_B="pass(符号层面)"
    printf '判定: 该 commit 在符号层面改变了报错相关代码 → 方法 B 通过\n'
  else
    RES_B="inconclusive"
    printf '判定: 符号出现次数未变 —— 改动可能在条件判断/顺序/类型层面。\n'
    printf '      需要人工看上面的 diff：若 diff 修改的正是报错逻辑行，方法 B 仍算通过；否则视为不确定。\n'
  fi
else
  printf '（缺少 --sym 与 --path，无法自动判定；请人工核对上面 diff 是否改变报错相关逻辑）\n'
fi

# 报错行范围对比（--range 真正生效）：
# 父提交与候选提交中，报错区的内容是否发生了变化？变了 = 候选动了报错现场。
if [ -n "$RANGE" ] && [ "${#PATHS[@]}" -gt 0 ]; then
  echo
  printf -- '--- 报错行范围 %s 的内容对比（父提交 vs 候选提交）---\n' "$RANGE"
  rs=${RANGE%%,*}; re=${RANGE##*,}
  for p in "${PATHS[@]}"; do
    PSUB=$(show_path "$CAND_P" "$p" | sed -n "${rs},${re}p")
    CSUB=$(show_path "$CAND" "$p" | sed -n "${rs},${re}p")
    printf -- '-- %s (行 %s-%s)\n' "$p" "$rs" "$re"
    if [ "$PSUB" = "$CSUB" ]; then
      printf '   父提交与候选提交在该行范围内内容完全相同 → 该 commit 未触及报错现场\n'
      printf '   父:\n%s\n' "$PSUB" | sed 's/^/     /'
      if [ "$RES_B" = "n/a" ]; then RES_B="inconclusive(报错区内容未变)"; fi
    else
      printf '   内容发生变化 → 该 commit 触及了报错现场：\n'
      printf '%s\n' "$PSUB"  | sed 's/^/     - /'
      printf '%s\n' "$CSUB"  | sed 's/^/     + /'
      if [ "$RES_B" = "n/a" ] || [ "$RES_B" = "inconclusive" ]; then
        RES_B="pass(报错行范围内容在候选提交中发生改变)"
      fi
    fi
  done
  printf '   判定: %s\n' "$RES_B"
fi

# 已修复代码行落点（B 的最强形态）
if [ -n "$FIXED" ] && [ -f "$FIXED" ] && [ "${#PATHS[@]}" -gt 0 ]; then
  p="${PATHS[0]}"
  PTXT=$(show_path "$CAND_P" "$p"); CTXT=$(show_path "$CAND" "$p")
  YES_C=0; NO_P=0; N=0
  echo
  printf -- '--- 「已修复代码」行落点（理想：候选 YES / 父 NO）---\n'
  while IFS= read -r l; do
    l=$(printf '%s' "$l" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ "${#l}" -ge 8 ] || continue
    printf '%s' "$l" | grep -qE '^[[:punct:][:space:]]+$' && continue
    inC="no"; inP="no"
    [ -n "$CTXT" ] && printf '%s' "$CTXT" | grep -qF -- "$l" && inC="YES"
    [ -n "$PTXT" ] && printf '%s' "$PTXT" | grep -qF -- "$l" && inP="YES"
    printf '   [候选:%s 父:%s] %s\n' "$inC" "$inP" "$l"
    [ "$inC" = "YES" ] && YES_C=$((YES_C+1))
    [ "$inP" = "no" ] && NO_P=$((NO_P+1))
    N=$((N+1)); [ "$N" -ge 15 ] && break
  done < <(tr -d '\r' < "$FIXED" | awk '!seen[$0]++')
  printf '   统计: 检查 %s 行，候选提交命中 %s 行，父提交未命中 %s 行\n' "$N" "$YES_C" "$NO_P"
  if [ "$N" -gt 0 ] && [ "$YES_C" -eq "$N" ] && [ "$NO_P" -eq "$N" ]; then
    RES_B="pass(修复代码行 100% 落点)"
    printf '判定: 修复版代码全部由该 commit 引入、且父提交中都不存在 → 方法 B 强通过\n'
  fi
fi

# ---------------------------------------------------------------- 方法 A
echo
echo "=== 方法 A：二分验证 ==="
if [ -n "$AA" ] && [ -n "$BB" ]; then
  printf -- '--- A1 静态：候选之前（%s..%s^）同一路径的改动 ---\n' "$(short_sha "$REPO" "$AA")" "$(short_sha "$REPO" "$CAND")"
  git -C "$REPO" log --format='%h %s' "$AA..$CAND_P" ${PATHS[@]+-- "${PATHS[@]}"} 2>/dev/null | head -n 30 || true
  printf -- '--- A2 静态：候选之后到修复版本（%s^..%s）同一路径的改动 ---\n' "$(short_sha "$REPO" "$CAND")" "$(short_sha "$REPO" "$BB")"
  git -C "$REPO" log --format='%h %s' "$CAND^..$BB" ${PATHS[@]+-- "${PATHS[@]}"} 2>/dev/null | head -n 30 || true
  printf '解读：A1 若为空或与报错无关 → 候选就是该路径上首个修复；\n'
  printf '      A2 非空 → 检查其后是否又把该修复改回去（若有，需把后续 commit 一并纳入解释）。\n'
  RES_A="static-only"
fi

if [ -n "$RUNCMD" ] && [ "$NO_RUN" = "0" ]; then
  if [ -z "$AA" ] || [ -z "$BB" ]; then
    warn "--run-cmd 需要同时给 --A 与 --B，跳过真实 bisect"
    RES_A="n/a(缺 --A/--B)"
  else
    TMP=$(mktmpdir)
    WT="$TMP/wt"
    cleanup() {
      git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1 || true
      if [ "$KEEP" = "1" ]; then
        printf 'KEEP: 临时 worktree 保留在 %s（用完请手动清理：git -C %s worktree remove --force %s）\n' "$WT" "$REPO" "$WT"
      else
        rm -rf "$TMP"
      fi
    }
    trap cleanup EXIT
    printf -- '--- A3 真实 bisect（临时 worktree: %s）---\n' "$WT"
    note "git worktree add --detach '$WT' '$(short_sha "$REPO" "$BB")'"
    if ! git -C "$REPO" worktree add --detach "$WT" "$BB" >/dev/null 2>&1; then
      warn "worktree add 失败（blobless clone 可能需要联网取 blob；或路径被占用）"
      RES_A="fail(worktree 无法创建)"
    else
      BOUT="$TMP/bisect.out"
      # 判据写成脚本文件再执行，而不是 `bisect run bash -c "<cmd>"`：
      # git bisect run 内部会用 /bin/sh -c 拼接整条命令，嵌套引号在不同
      # 平台的 sh（Linux 的 dash vs macOS 的 bash 3.2 POSIX mode）里解析规则不同，
      # 判据里的双引号会被吃掉。走脚本文件就没有这一层引号嵌套。
      CRIT="$TMP/criterion.sh"
      {
        printf '#!/usr/bin/env bash\n'
        printf 'cd "%s" || exit 125\n' "$WT"
        printf '%s\n' "$RUNCMD"
      } > "$CRIT"
      chmod +x "$CRIT" 2>/dev/null || true
      set +e
      {
        git -C "$WT" bisect start "$BB" "$AA"
        # 125 是 git bisect 的"跳过"码，判据自身出错时用它而不是 1，
        # 免得被误判成"这个提交是坏的"
        git -C "$WT" bisect run "$CRIT"
      } > "$BOUT" 2>&1
      BRC=$?
      # git 2.4x+ 输出带引号：is the first 'bad' commit；老版本无引号
      FBC=$(grep -m1 -E "is the first '?bad'? commit" "$BOUT" | grep -oE '[0-9a-f]{7,40}' | head -1 || true)
      set -e
      tail -n 25 "$BOUT" || true
      if [ -n "$FBC" ]; then
        printf 'first bad commit = %s  (%s)\n' "$FBC" "$(subject_of "$REPO" "$FBC")"
        if [ "$(resolve_ref "$REPO" "$FBC")" = "$CAND" ]; then
          RES_A="pass(首个使报错消失的提交)"
          printf '判定: 该 commit 正是使报错消失的第一个提交 → 方法 A 通过\n'
        else
          RES_A="fail(首个 bad commit 是别的提交)"
          printf '判定: 首个 bad commit 是 %s，与候选不一致 → 需要检查候选是否只是等价/前置改动\n' "$(short_sha "$REPO" "$FBC")"
        fi
      else
        RES_A="inconclusive(bisect 未给出 first bad commit, rc=$BRC)"
        printf '判定: 未能从 bisect 输出中解析出 first bad commit（rc=%s）。检查 --run-cmd 的退出码约定是否符合 0=good/1-127=bad。\n' "$BRC"
      fi
      git -C "$WT" bisect reset >/dev/null 2>&1 || true
    fi
  fi
else
  printf '（未提供 --run-cmd，跳过真实 bisect；见 references/verification.md 了解如何写判据命令）\n'
fi

# ---------------------------------------------------------------- 方法 C
echo
echo "=== 方法 C：反向验证（在临时 worktree 上 revert 候选）==="
if [ -z "$BB" ]; then
  printf '（需要 --B 才能建立反向验证基线，跳过）\n'
  RES_C="n/a(缺 --B)"
else
  CAND_IS_ANCESTOR=1
  git -C "$REPO" merge-base --is-ancestor "$CAND" "$BB" 2>/dev/null || CAND_IS_ANCESTOR=0
  if [ "$CAND_IS_ANCESTOR" = "0" ]; then
    printf '（候选 %s 不是修复版本 %s 的祖先，无法在其上 revert；改用 cherry-pick -n 到修复版本？\n' \
      "$(short_sha "$REPO" "$CAND")" "$(short_sha "$REPO" "$BB")"
    printf '  这里退化为静态推演：见方法 B 的父提交对比）\n'
    RES_C="n/a(候选非修复版本祖先)"
  else
    TMP2=$(mktmpdir)
    WT2="$TMP2/wt"
    if ! git -C "$REPO" worktree add --detach "$WT2" "$BB" >/dev/null 2>&1; then
      warn "worktree add 失败，跳过方法 C"
      RES_C="fail(worktree 无法创建)"
    else
      set +e
      git -C "$WT2" revert --no-commit "$CAND" > "$TMP2/revert.out" 2>&1
      RRC=$?
      set -e
      if [ "$RRC" -ne 0 ]; then
        printf 'revert 未能干净应用（rc=%s）：\n' "$RRC"
        head -n 15 "$TMP2/revert.out" || true
        printf '解读：不能干净回滚 ≠ 候选不是修复；这通常只是后续提交在同一区域继续改过。\n'
        printf '      此时以「方法 B + git show 候选^:file 对比」为准，并在结论里注明反向验证未通过。\n'
        RES_C="inconclusive(revert 未干净应用)"
      else
        printf 'revert 已干净应用（--no-commit）。\n'
        if [ "${#PATHS[@]}" -gt 0 ] && [ "${#SYMS[@]}" -gt 0 ]; then
          printf -- '--- 回滚后 报错相关符号 状态（对比修复版本 / 父提交）---\n'
          RESTORED=0; TOTAL=0
          for p in "${PATHS[@]}"; do
            WTXT=$(cat "$WT2/$p" 2>/dev/null || true)
            BTXT=$(show_path "$BB" "$p"); PTXT=$(show_path "$CAND_P" "$p")
            printf -- '-- %s\n   %-44s %10s %10s %10s\n' "$p" "符号" "修复版本" "回滚后" "父提交"
            for s in "${SYMS[@]}"; do
              b=$(occ "$BTXT" "$s"); r=$(occ "$WTXT" "$s"); a=$(occ "$PTXT" "$s")
              printf '   %-44s %10s %10s %10s\n' "$s" "$b" "$r" "$a"
              TOTAL=$((TOTAL+1))
              [ "$r" = "$a" ] && RESTORED=$((RESTORED+1))
            done
          done
          printf '\n符号状态回到父提交水平的比例: %s/%s\n' "$RESTORED" "$TOTAL"
          if [ "$RESTORED" = "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
            RES_C="pass(回滚后报错形态重建)"
            printf '判定: 回滚该 commit 后，报错相关符号状态完全回到父提交 → 该 commit 是消除该形态的直接原因\n'
          else
            RES_C="inconclusive(回滚后形态与父提交不完全一致)"
          fi
        fi
        if [ -n "$RUNCMD" ] && [ "$NO_RUN" = "0" ]; then
          printf -- '--- 回滚后运行判据命令（约定同 bisect：触发条件仍在 → 0）---\n'
          set +e
          ( cd "$WT2" && bash -c "$RUNCMD" ) > "$TMP2/run.out" 2>&1
          RRC2=$?
          set -e
          tail -n 15 "$TMP2/run.out" || true
          printf '退出码 = %s\n' "$RRC2"
          if [ "$RRC2" -eq 0 ]; then
            RES_C="pass(revert 后触发条件重建(判据=0)，与 bisect 约定一致)"
            printf '判定: 回滚后判据命令重新满足（触发条件回到父提交状态）→ 原 commit 是消除该形态的直接原因\n'
          else
            RES_C="fail(revert 后触发条件未重建)"
            printf '判定: 回滚后判据命令仍不满足 → 触发条件没有随 revert 恢复，该 commit 可能只是修复的一部分\n'
            printf '      （若你的命令是"复现命令：报错重现 → 非 0"的约定，则此解读需反转，请人工复核）\n'
          fi
        fi
      fi
      # 清理未提交的 revert（worktree 即将被删除，重置只是保险）
      git -C "$WT2" reset --hard >/dev/null 2>&1 || true
      git -C "$REPO" worktree remove --force "$WT2" >/dev/null 2>&1 || true
      [ "$KEEP" = "1" ] && printf 'KEEP: 方法 C 的 worktree 未保留（--keep 只对 bisect 生效）\n' || true
      rm -rf "$TMP2"
    fi
  fi
fi

echo
printf 'VERIFY|%s|A=%s|B=%s|C=%s\n' "$(short_sha "$REPO" "$CAND")" "$RES_A" "$RES_B" "$RES_C"
echo
echo "可信度提示："
echo "  高 = B 通过 且（A 通过 或 C 通过）；中 = 仅 B 静态通过；低 = B 也 inconclusive。"
echo "  未通过/无法验证的原因必须写进结论，不允许用推测填充。"
