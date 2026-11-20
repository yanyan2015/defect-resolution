#!/usr/bin/env bash
# collect.sh —— 阶段 2：三条互补追溯（-L / 两版 blame / pickaxe）+ 去重 + 证据表。
#
# 用法：
#   collect.sh <repo> <A> <B> [选项]
#
# 选项：
#   --path PATH        限定文件路径（可多次）
#   --range S,E        报错相关行范围（行号基于问题版本 <A> 的文件）
#   --func NAME        函数名（无 --range 时用于 -L :func:path）
#   --sym SYM          报错中的关键符号（可多次）
#   --symfile FILE     逐行读符号（可接 extract_symbols.py --kind syms 的输出）
#   --error-file FILE  报错原文：自动抽 issue 号 / 长短语做 message 搜索
#   --fixed FILE       "已修复代码"文本：逐行做 pickaxe（最强信号）
#   --grep KW          按 commit message 关键词搜（可多次）
#   --wide             全仓 pickaxe（默认仅在限路径无命中时回退全仓）
#   --no-fallback      关闭"限路径无命中则回退全仓"
#   --limit N          每通道最多记录条数（默认 200）
#   --min-weight N     只输出权重 >= N 的候选（默认 2；纯路径噪声权重为 1）
#
# 证据权重（同一候选的权重累加，不同符号各自计分）：
#   pickaxe 修复代码行(限路径) 5 | (全仓) 4 | -G(限路径) 3
#   pickaxe 报错符号(限路径)   4 | (全仓) 3 | -G(限路径) 3 | -G(全仓) 2
#   log -L 行范围变更          3
#   blame 修复版本中该区域行的归属 / 含报错符号行的归属   3
#   commit message 命中关键词  2 | 命中报错长短语 1 | 最近改动该路径 1
#
# 输出：候选表（按权重排序）+ 证据明细 + 机器可读行 CAND|short|full|weight|n|date|subject
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=lib.sh
. "$HERE/lib.sh"

REPO=""; A=""; B=""
PATHS=(); SYMS=(); GREPS=(); FIXLINES=()
RANGE=""; FUNC=""; SYMFILE=""; ERRFILE=""; FIXED=""; GREPFILE=""
WIDE=0; FALLBACK=1; LIMIT=200; MINWEIGHT=2; NO_G=0

while [ $# -gt 0 ]; do
  case "$1" in
    --path)        PATHS+=("${2:-}"); shift 2 ;;
    --path=*)      PATHS+=("${1#*=}"); shift ;;
    --sym)         SYMS+=("${2:-}"); shift 2 ;;
    --sym=*)       SYMS+=("${1#*=}"); shift ;;
    --grep)        GREPS+=("${2:-}"); shift 2 ;;
    --grep=*)      GREPS+=("${1#*=}"); shift ;;
    --grepfile)    GREPFILE="${2:-}"; shift 2 ;;
    --grepfile=*)  GREPFILE="${1#*=}"; shift ;;
    --range)       RANGE="${2:-}"; shift 2 ;;
    --range=*)     RANGE="${1#*=}"; shift ;;
    --func)        FUNC="${2:-}"; shift 2 ;;
    --func=*)      FUNC="${1#*=}"; shift ;;
    --symfile)     SYMFILE="${2:-}"; shift 2 ;;
    --symfile=*)   SYMFILE="${1#*=}"; shift ;;
    --error-file)  ERRFILE="${2:-}"; shift 2 ;;
    --error-file=*) ERRFILE="${1#*=}"; shift ;;
    --fixed)       FIXED="${2:-}"; shift 2 ;;
    --fixed=*)     FIXED="${1#*=}"; shift ;;
    --wide)        WIDE=1; shift ;;
    --no-G)        NO_G=1; shift ;;
    --no-fallback) FALLBACK=0; shift ;;
    --limit)       LIMIT="${2:-200}"; shift 2 ;;
    --limit=*)     LIMIT="${1#*=}"; shift ;;
    --min-weight)  MINWEIGHT="${2:-2}"; shift 2 ;;
    --min-weight=*) MINWEIGHT="${1#*=}"; shift ;;
    -h|--help)     sed -n '2,29p' "$0"; exit 0 ;;
    -*)            die "未知参数: $1" ;;
    *)             if [ -z "$REPO" ]; then REPO="$1"; elif [ -z "$A" ]; then A="$1"
                   elif [ -z "$B" ]; then B="$1"; else die "多余参数: $1"; fi; shift ;;
  esac
done
[ -n "$REPO" ] && [ -n "$A" ] && [ -n "$B" ] || die "用法: collect.sh <repo> <A> <B> [选项]"
require_git_repo "$REPO"
REPO=$(cd "$REPO" && pwd)
A=$(resolve_ref "$REPO" "$A") || die "A 无法解析: $A"
B=$(resolve_ref "$REPO" "$B") || die "B 无法解析: $B"

TMP=$(mktmpdir)
trap 'rm -rf "$TMP"' EXIT
EVID="$TMP/evidence.txt"    # sha<TAB>weight<TAB>type<TAB>detail
: > "$EVID"
REVMAP="$TMP/revmap.txt"    # 短hash→长hash 缓存（跨通道共享，进程启动开销优化）
: > "$REVMAP"

record() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$EVID"; }

# 从 "sha subject" 行流记录证据（在管道子 shell 中调用，故只写文件、不用变量）
# 性能：resolve_ref 每行一次 git 调用，Windows 上进程启动 ~100ms。
# 用每候选缓存：同一短 hash 在本进程中只解析一次（后续命中缓存文件）。
record_log() {
  local weight="$1" type="$2" detail="$3" n=0 line sha full
  while IFS= read -r line; do
    sha=${line%% *}
    case "$sha" in ''|*[!0-9a-fA-F]*) continue ;; esac
    [ "${#sha}" -ge 7 ] || continue
    full=""
    if [ -n "$REVMAP" ]; then
      full=$(awk -v k="$sha" '$1==k{print $2; exit}' "$REVMAP" 2>/dev/null)
    fi
    if [ -z "$full" ]; then
      full=$(resolve_ref "$REPO" "$sha") || { printf '%s\t%s\n' "$sha" "-" >> "$REVMAP" 2>/dev/null || true; continue; }
      [ -n "$REVMAP" ] && printf '%s\t%s\n' "$sha" "$full" >> "$REVMAP" 2>/dev/null || true
    fi
    [ "$full" = "-" ] && continue
    record "$full" "$weight" "$type" "$detail"
    n=$((n+1)); [ "$n" -ge "$LIMIT" ] && break
  done
  return 0
}

# ---------- 输入归一化 --------------------------------------------------------
if [ "${#PATHS[@]}" -gt 0 ]; then
  for i in "${!PATHS[@]}"; do PATHS[$i]=$(rel_path "$REPO" "${PATHS[$i]}"); done
fi

SYMLIST="$TMP/syms.txt"; : > "$SYMLIST"
if [ -n "$SYMFILE" ]; then
  [ -f "$SYMFILE" ] || die "找不到 --symfile: $SYMFILE"
  tr -d '\r' < "$SYMFILE" | while IFS= read -r l; do
    case "$l" in \#*) continue ;; esac
    if printf '%s' "$l" | grep -q "$(printf '\t')"; then
      l=$(printf '%s' "$l" | awk -F'\t' 'NF>2{print $3; next} {print $1}')
    fi
    l=$(printf '%s' "$l" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$l" ] && printf '%s\n' "$l"
  done | awk '!seen[$0]++' > "$SYMLIST"
fi
for s in ${SYMS[@]+"${SYMS[@]}"}; do printf '%s\n' "$s"; done | awk '!seen[$0]++' >> "$SYMLIST"
if [ -s "$SYMLIST" ]; then
  while IFS= read -r l; do SYMS+=("$l"); done < "$SYMLIST"
else
  SYMS=()
fi

if [ -n "$ERRFILE" ]; then
  [ -f "$ERRFILE" ] || die "找不到 --error-file: $ERRFILE"
  while IFS= read -r kw; do [ -n "$kw" ] && GREPS+=("$kw"); done < <(
    tr -d '\r' < "$ERRFILE" \
      | grep -oE '(#[0-9]{2,7}|CVE-[0-9]{4}-[0-9]{3,7}|[A-Z][A-Z0-9]{1,10}-[0-9]{1,6})' | sort -u || true)
fi

# --grepfile：读 extract_symbols.py --kind greps 的输出（issue 号 / 关键短语）
# 注意：extract_symbols.py 的输出可能带 "# " 开头的注释行，但 "#42" 这种 issue 号不是注释
if [ -n "$GREPFILE" ]; then
  [ -f "$GREPFILE" ] || die "找不到 --grepfile: $GREPFILE"
  while IFS= read -r kw; do
    case "$kw" in
      "" ) continue ;;
      "# "*|"#\t"* ) continue ;;   # 真正的注释行
    esac
    GREPS+=("$kw")
  done < <(tr -d '\r' < "$GREPFILE")
fi

FIXLIST="$TMP/fixed_lines.txt"; : > "$FIXLIST"
if [ -n "$FIXED" ]; then
  [ -f "$FIXED" ] || die "找不到 --fixed: $FIXED"
  awk '
    { line=$0; sub(/\r$/,"",line); gsub(/^[ \t]+|[ \t]+$/,"",line);
      if (length(line) < 8) next;
      if (line ~ /^[[:punct:][:space:]]+$/) next;
      print line }
  ' "$FIXED" | awk '!seen[$0]++' | head -n 30 > "$FIXLIST"
  while IFS= read -r l; do FIXLINES+=("$l"); done < "$FIXLIST"
fi

# ---------- pickaxe 通道 ------------------------------------------------------
# pickaxe <token> <label> <weight_path> <weight_wide> <weight_Gpath> <weight_Gwide>
# -S 抓增删，-G 抓改写（if(p) → if(p!=NULL)）—— 两者证据独立，默认都跑。
# 大仓库上为省时可用 --no-G 跳过 -G（会少一类证据，SKILL.md 有说明）。
pickaxe() {
  local tok="$1" label="$2" w1="$3" w2="$4" w3="$5" w4="$6" out esc
  esc=$(re_escape "$tok")
  if [ "${#PATHS[@]}" -gt 0 ]; then
    out=$(git -C "$REPO" log --format='%h %s' -S"$tok" "$A..$B" -- "${PATHS[@]}" 2>/dev/null || true)
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | record_log "$w1" "pickaxe-S[path]:$label" "-S'$tok' 命中(限路径)"
    elif [ "$FALLBACK" = "1" ] || [ "$WIDE" = "1" ]; then
      out=$(git -C "$REPO" log --format='%h %s' -S"$tok" "$A..$B" 2>/dev/null || true)
      if [ -n "$out" ]; then
        printf '%s\n' "$out" | record_log "$w2" "pickaxe-S[wide]:$label" "-S'$tok' 命中(全仓)"
      fi
    fi
    # -G 默认双跑（抓改写，-S 看不见）；--no-G 跳过（省时取舍，证据会少一类）
    if [ "$NO_G" = "0" ]; then
      out=$(git -C "$REPO" log --format='%h %s' -G"$esc" "$A..$B" -- "${PATHS[@]}" 2>/dev/null || true)
      if [ -n "$out" ]; then
        printf '%s\n' "$out" | record_log "$w3" "pickaxe-G[path]:$label" "-G'$tok' 命中(限路径)"
      elif [ "$FALLBACK" = "1" ] || [ "$WIDE" = "1" ]; then
        out=$(git -C "$REPO" log --format='%h %s' -G"$esc" "$A..$B" 2>/dev/null || true)
        if [ -n "$out" ]; then
          printf '%s\n' "$out" | record_log "$w4" "pickaxe-G[wide]:$label" "-G'$tok' 命中(全仓)"
        fi
      fi
    fi
  else
    out=$(git -C "$REPO" log --format='%h %s' -S"$tok" "$A..$B" 2>/dev/null || true)
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | record_log "$w2" "pickaxe-S[wide]:$label" "-S'$tok' 命中(全仓)"
    fi
    if [ "$NO_G" = "0" ]; then
      out=$(git -C "$REPO" log --format='%h %s' -G"$esc" "$A..$B" 2>/dev/null || true)
      if [ -n "$out" ]; then
        printf '%s\n' "$out" | record_log "$w4" "pickaxe-G[wide]:$label" "-G'$tok' 命中(全仓)"
      fi
    fi
  fi
  return 0
}

echo "### 通道 1/5：-L 行范围变更历史"
if [ -n "$RANGE" ] && [ "${#PATHS[@]}" -gt 0 ]; then
  s=${RANGE%%,*}; e=${RANGE##*,}
  for p in "${PATHS[@]}"; do
    out=$(git -C "$REPO" log --format='%h %s' -L "$s,$e:$p" "$A..$B" 2>/dev/null | grep -E '^[0-9a-f]{7,} ' || true)
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | record_log 3 "log-L:$p:$s-$e" "-L $s,$e:$p"
    fi
  done
elif [ -n "$FUNC" ] && [ "${#PATHS[@]}" -gt 0 ]; then
  for p in "${PATHS[@]}"; do
    out=$(git -C "$REPO" log --format='%h %s' -L ":$FUNC:$p" "$A..$B" 2>/dev/null | grep -E '^[0-9a-f]{7,} ' || true)
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | record_log 3 "log-L:func:$p:$FUNC" "-L :$FUNC:$p"
    fi
  done
else
  note "（未给 --range/--func，跳过 -L 通道；建议补上以获得行级变更历史）"
fi

echo "### 通道 2/5：两版 blame 对比"
for p in "${PATHS[@]}"; do
  AF="$TMP/blameA.txt"; BF="$TMP/blameB.txt"
  blame_full "$REPO" "$A" "$p" > "$AF" || true
  blame_full "$REPO" "$B" "$p" > "$BF" || true
  if [ ! -s "$AF" ]; then warn "blame 无输出（$p 在问题版本中不存在？）"; continue; fi

  # 2a. 报错行范围：行号属于**问题版本**。
  #     策略：先把问题版本报错区的**内容**锚定到修复版本的行号（内容定位，免疫行漂移），
  #     再在修复版本里找"落在锚定区间内、且归属 commit ∈ A..B"的行。
  #     覆盖三种修复形态：
  #       a) 改写了报错行        → 该行归属变成修复提交
  #       b) 在报错行前插入守卫  → 插入行归属是修复提交，且落在锚定区间内
  #       c) 删除了报错行        → 内容在修复版本中找不到
  if [ -n "$RANGE" ]; then
    s=${RANGE%%,*}; e=${RANGE##*,}
    awk -F'\t' -v s="$s" -v e="$e" '$1+0>=s+0 && $1+0<=e+0 {print $1"\t"$2"\t"$3}' "$AF" > "$TMP/rangeA.txt"

    # 问题版本中，报错行的归属 commit（这些提交改过这些行）
    while IFS=$'\t' read -r ln sha content; do
      [ -n "$sha" ] || continue
      in_range "$REPO" "$sha" "$A" "$B"
      if [ "$IN_RANGE" = "yes" ]; then
        record "$sha" 2 "blame[issue-line]:$p" "问题版本第 $ln 行归属该提交（在报错行范围 $s-$e 内）"
      fi
    done < "$TMP/rangeA.txt"

    # 把报错区的内容按顺序映射到修复版本的行号 → 得到"锚定区间" [first,last]
    awk -F'\t' '{ c=$3; sub(/^[[:space:]]+/,"",c); sub(/[[:space:]]+$/,"",c); print c }' "$TMP/rangeA.txt" \
      | awk 'length($0)>=4' > "$TMP/rangeA_content.txt"
    FIRST=0; LAST=0
    while IFS= read -r c; do
      hit=$(awk -F'\t' -v c="$c" '{ t=$3; sub(/^[[:space:]]+/,"",t); sub(/[[:space:]]+$/,"",t); if (t==c) {print $1; exit} }' "$BF")
      [ -n "$hit" ] || continue
      if [ "$FIRST" = "0" ]; then FIRST=$hit; LAST=$hit; else
        [ "$hit" -lt "$FIRST" ] && FIRST=$hit
        [ "$hit" -gt "$LAST" ] && LAST=$hit
      fi
    done < "$TMP/rangeA_content.txt"

    if [ "$FIRST" != "0" ]; then
      # 锚定区间内，归属 ∈ A..B 的行 → 强候选（改写或插入都在这里）
      awk -F'\t' -v f="$FIRST" -v l="$LAST" '$1+0>=f+0 && $1+0<=l+0 {print $1"\t"$2"\t"$3}' "$BF" \
        | while IFS=$'\t' read -r ln sha content; do
            [ -n "$sha" ] || continue
            in_range "$REPO" "$sha" "$A" "$B"
            if [ "$IN_RANGE" = "yes" ]; then
              record "$sha" 3 "blame[anchored]:$p" "修复版本第 $ln 行（报错区锚定区间 $FIRST-$LAST 内）归属该提交"
            fi
          done
    fi

    # 报错区的某行内容在修复版本中已消失 → 被删除/改写 → 其原始归属提交可疑
    while IFS=$'\t' read -r ln sha content; do
      [ -n "$content" ] || continue
      c=$(printf '%s' "$content" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
      [ "${#c}" -ge 4 ] || continue
      found=$(awk -F'\t' -v c="$c" '{ t=$3; sub(/^[[:space:]]+/,"",t); sub(/[[:space:]]+$/,"",t); if (t==c) {print $1; exit} }' "$BF")
      [ -n "$found" ] && continue
      in_range "$REPO" "$sha" "$A" "$B"
      if [ "$IN_RANGE" = "yes" ]; then
        record "$sha" 3 "blame[removed]:$p" "问题版本第 $ln 行内容在修复版本中已不存在 → 该行被删除/改写"
      fi
    done < "$TMP/rangeA.txt"
  fi

  # 2b. 含报错符号的行在**修复版本**中的归属（符号行不受行号漂移影响，安全）
  if [ -s "$SYMLIST" ] && [ -s "$BF" ]; then
    awk -F'\t' '
      NR==FNR { syms[tolower($0)]=1; next }
      { l=tolower($3); for (s in syms) if (index(l,s)>0) { print $1"\t"$2"\t"s; break } }
    ' "$SYMLIST" "$BF" | while IFS=$'\t' read -r ln sha sym; do
      [ -n "$sha" ] || continue
      in_range "$REPO" "$sha" "$A" "$B"
      if [ "$IN_RANGE" = "yes" ]; then
        record "$sha" 3 "blame[sym-line]:$p" "修复版本第 $ln 行含报错符号 '$sym'，归属该提交"
      fi
    done
  fi
done

echo "### 通道 3/6：pickaxe 报错符号（-S 增删 + -G 改写）  [${#SYMS[@]} 个符号]"
for sym in ${SYMS[@]+"${SYMS[@]}"}; do pickaxe "$sym" "sym" 4 3 3 2; done

echo "### 通道 4/6：用「已修复代码」逐行反查（最强信号）  [${#FIXLINES[@]} 行]"
for line in ${FIXLINES[@]+"${FIXLINES[@]}"}; do pickaxe "$line" "fixed-line" 5 4 3 2; done

echo "### 通道 5/6：commit message 与路径活跃度"
# 回滚（revert）引入的缺陷：先修好、后被回滚 —— message 通常含 Revert/revert
for pat in 'Revert' 'revert' 'Regress' 'regression' 'BREAKING'; do
  out=$(git -C "$REPO" log --format='%h %s' --grep="$pat" "$A..$B" 2>/dev/null | head -n 20 || true)
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | record_log 2 "grep-revert" "commit message 含 '$pat' → 可能是回滚引入的缺陷"
  fi
done
for kw in ${GREPS[@]+"${GREPS[@]}"}; do
  out=$(git -C "$REPO" log --format='%h %s' --grep="$kw" -i "$A..$B" 2>/dev/null || true)
  if [ -n "$out" ]; then
    printf '%s\n' "$out" | record_log 2 "grep-msg" "commit message 命中 '$kw'"
  fi
done
if [ -n "$ERRFILE" ]; then
  while IFS= read -r phrase; do
    [ "${#phrase}" -ge 12 ] || continue
    out=$(git -C "$REPO" log --format='%h %s' --grep="$phrase" -i -F "$A..$B" 2>/dev/null || true)
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | record_log 1 "grep-errmsg" "commit message 命中报错短语 '$phrase'"
    fi
  done < <(tr -d '\r' < "$ERRFILE" | grep -oE '[A-Za-z][A-Za-z0-9 _.-]{11,60}' | sort -u | head -n 8 || true)
fi
# 最近改动该路径的提交（弱信号，用于提醒"最新改动 ≠ 修复"）
if [ "${#PATHS[@]}" -gt 0 ]; then
  for p in "${PATHS[@]}"; do
    out=$(git -C "$REPO" log --format='%h %s' -n 10 "$A..$B" -- "$p" 2>/dev/null || true)
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | record_log 1 "path-recent:$p" "该路径在候选范围内的近期改动（弱信号）"
    fi
  done
fi

echo "### 通道 6/6：跨路径扩散（修复可能不在报错文件里）"
# 真实场景：修复改了 Makefile / 头文件 / 依赖 pin / CI 配置 / 子模块，
# 报错文件本身一行未动 —— 此时上面所有通道都会哑火。
# 策略：对范围内每个 commit，看它改了哪些"可能影响报错路径"的载体：
#   ① 同目录的其它文件（头文件、兄弟源文件）
#   ② 构建文件（Makefile/CMakeLists/setup.py/Cargo.toml/package.json）
#   ③ 依赖锁定文件
#   ④ 报错符号的定义处（全仓 pickaxe 该符号的定义所在文件）
for p in ${PATHS[@]+"${PATHS[@]}"}; do
  pdir=$(dirname "$p")
  # ① 同目录（git log --name-only 的格式：commit 行 → 空行 → 文件行…）
  out=$(git -C "$REPO" log --format='%h%x00' --name-only "$A..$B" -- "$pdir" 2>/dev/null \
        | tr '\0' ' ' \
        | awk 'BEGIN{n=0} /^$/ {next} /^[0-9a-f]{7,} /{sha=$1; next} {print sha"\t"$0}' \
        | grep -v -F "$p	" | sort -u | head -n 60 || true)
  if [ -n "$out" ]; then
    while IFS=$'\t' read -r sha f; do
      [ -n "$sha" ] || continue
      full=$(resolve_ref "$REPO" "$sha") || continue
      record "$full" 1 "sibling-path:$p" "同目录($pdir)的 $f 被改动 → 可能影响该路径的编译/行为"
    done <<< "$out"
  fi
  # ② 构建/依赖文件（全仓，不限目录）
  for pat in Makefile makefile GNUmakefile CMakeLists.txt configure.ac configure meson.build \
             setup.py setup.cfg pyproject.toml Cargo.toml go.mod package.json pom.xml build.gradle \
             requirements.txt Pipfile Gemfile Dockerfile .travis.yml .github/workflows; do
    out=$(git -C "$REPO" log --format='%h %s' "$A..$B" -- "$pat" 2>/dev/null | head -n 20 || true)
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | record_log 1 "build-file:$pat" "构建/依赖文件 $pat 被改动 → 可能改变编译结果或依赖版本"
    fi
  done
  # ④ 报错符号的定义处：谁定义/声明了报错符号，那个文件就是嫌疑点
  while IFS= read -r sym; do
    [ "${#sym}" -ge 4 ] || continue
    out=$(git -C "$REPO" log --format='%h %s' -S"$sym" "$A..$B" 2>/dev/null | head -n 20 || true)
    if [ -n "$out" ]; then
      printf '%s\n' "$out" | record_log 1 "sym-wide:$sym" "报错符号 '$sym' 在全仓被改动（可能在别处定义/声明）"
    fi
  done < <(sed -n '1,12p' "$SYMLIST" 2>/dev/null || true)
done

# ---------- 汇总 --------------------------------------------------------------
DEDUP="$TMP/evidence.dedup.txt"
awk '!seen[$0]++' "$EVID" > "$DEDUP"
printf '\n=== 候选 commit（按证据权重排序）===\n'
RANK="$TMP/rank.txt"
awk -F'\t' '{w[$1]+=$2; n[$1]++} END{for (s in w) printf "%d\t%d\t%s\n", w[s], n[s], s}' "$DEDUP" \
  | sort -k1,1nr -k2,2nr -k3,3 \
  | awk -F'\t' -v mw="$MINWEIGHT" '$1+0>=mw+0' > "$RANK"

if [ ! -s "$RANK" ]; then
  printf '（无候选）\n'
  warn "候选集为空或全部低于 --min-weight=${MINWEIGHT}。按 SKILL.md 阶段 2 的顺序放宽：
      去掉 --path → 用 -G 代替 -S → 扩到 <A>^..<B> → 怀疑修复在 merge 中带入 / 文件被重命名 / 问题来自外部依赖"
  printf 'CANDIDATE_COUNT=0\n'
else
  # 版本归属（tag --contains）与分支归属（branch --contains）每个候选要跑多条
  # git 命令，大仓库 × 多候选时会显著拖慢。只对**前 TOPN 个候选**做这两项富化，
  # 其余候选留空 —— 排序靠权重，富化只影响展示。
  TOPN="${DR_TOPN:-10}"
  RANK_N=$(wc -l < "$RANK" | tr -d ' ')

  printf '%-8s %-6s %-10s %-11s %-14s %s\n' "权重" "证据数" "COMMIT" "日期" "修复版本" "标题"
  ROW=0
  while IFS=$'\t' read -r w n sha; do
    ROW=$((ROW+1))
    FIXTAG=""
    if [ "$ROW" -le "$TOPN" ]; then
      first_containing_tag "$REPO" "$sha"
      FIXTAG="${FIRST_CONTAINING_TAG:-未发布}"
    fi
    printf '%-8s %-6s %-10s %-11s %-14s %s\n' "$w" "$n" "$(short_sha "$REPO" "$sha")" \
      "$(date_of "$REPO" "$sha")" "${FIXTAG:-}" "$(subject_of "$REPO" "$sha")"
  done < "$RANK"
  printf '\n=== 证据明细 ===\n'
  while IFS=$'\t' read -r w n sha; do
    printf '%s  %s\n' "$(short_sha "$REPO" "$sha")" "$(subject_of "$REPO" "$sha")"
    awk -F'\t' -v s="$sha" '$1==s{printf "   [w%s] %-34s %s\n", $2, $3, $4}' "$DEDUP" | head -n 24
  done < "$RANK"
  printf '\n=== 机器可读 ===\n'
  ROW=0
  while IFS=$'\t' read -r w n sha; do
    ROW=$((ROW+1))
    # 该修复落在哪些分支上（判断是否只合入了维护分支）—— 仅 Top-N 富化
    br=""
    if [ "$ROW" -le "$TOPN" ]; then
      br=$(git -C "$REPO" branch -a --contains "$sha" 2>/dev/null | sed 's/^[* ] *//' | tr '\n' ',' | sed 's/,$//' || true)
      first_containing_tag "$REPO" "$sha"
      [ -n "$FIRST_CONTAINING_TAG" ] && br="$br|fix:${FIRST_CONTAINING_TAG}"
    fi
    printf 'CAND|%s|%s|%s|%s|%s|%s|%s\n' "$(short_sha "$REPO" "$sha")" "$sha" "$w" "$n" \
      "$(date_of "$REPO" "$sha")" "$(subject_of "$REPO" "$sha")" "${br:-}"
  done < "$RANK"
  printf 'CANDIDATE_COUNT=%s\n' "$RANK_N"
  printf 'ENRICHED_TOP=%s\n' "$TOPN"
fi
TOTAL=$(cnt "$REPO" "$A" "$B")
NOM=$(cnt "$REPO" "$A" "$B" --no-merges)
printf 'RANGE_TOTAL=%s\n' "$TOTAL"
printf 'RANGE_NO_MERGES=%s\n' "$NOM"
if [ "$TOTAL" != "$NOM" ]; then
  printf 'HINT：范围内含 %s 个 merge commit。修复可能由另一分支开发并在 merge 时进入主线；\n' "$((TOTAL - NOM))"
  printf '      pickaxe 能穿过 merge 找到内容变更的提交。若怀疑，对比 -S 命中集合与 --no-merges 的差异，并对差异提交跑 git show -m。\n'
fi
