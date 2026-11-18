#!/usr/bin/env python
# extract_symbols.py —— 阶段 2.0：从报错信息中抽取 pickaxe 符号 / grep 关键词 / 文件行号。
#
# 用法：
#   extract_symbols.py <error-file|->                 # 带注释的 TSV（供人阅读）
#   extract_symbols.py <error-file|-> --kind syms     # 一行一个符号 → collect.sh --symfile
#   extract_symbols.py <error-file|-> --kind greps    # 一行一个关键词 → collect.sh --grep
#   extract_symbols.py <error-file|-> --kind paths    # file:line → 每行 "path<TAB>line"
#
# 抽取优先级（rank 越小越可信）：
#   1  报错行里的引号字面量（error: 'X' undeclared / NameError: name 'x' …）
#   2  「未定义/未声明/找不到/不存在/无此成员」句式点名的符号
#   3  带 () 的函数/方法名、宏名（全大写+下划线）
#   4  源码字符串字面量（含空格的长串 —— 断言/oops 常带原文，pickaxe 几乎唯一命中）
#   5  错误码 / errno / 信号名
#   6  其它标识符
# 输出纯文本，无第三方依赖；已在 Python 3.8+ 上验证。
import re
import sys

RULES = [
    # (rank, 描述, 正则)  —— 正则的第 1 组是抽出来的 token
    (1, "undefined/undeclared/not-defined 点名的符号",
     r"(?:undeclared|undefined|not declared|was not declared|is not defined|"
     r"undefined reference to|no attribute|has no member|does not exist|"
     r"unknown identifier|unknown type name|implicit declaration of function|"
     r"未定义|未声明|找不到|不存在|没有成员)"
     r"[^'\n`\"\w]{0,24}[`'\"]([^`'\"\n]{1,80})[`'\"]"),
    (2, "异常/断言里的引号字面量",
     r"[`'\"]([^`'\"\n]{3,120})[`'\"]"),
    (3, "文件:行号",
     r"\b([\w./\\+-]+\.[A-Za-z0-9_+]{1,8}):(\d{1,7})\b"),
    (4, "带括号的函数/方法名",
     r"\b([A-Za-z_]\w{2,60})\s*\(\s*\)"),
    (5, "宏名（全大写下划线）",
     r"\b([A-Z][A-Z0-9_]{3,60})\b"),
    (6, "错误码 / errno / 信号",
     r"\b(E[A-Z]{2,20}|errno\s*=?\s*\d{1,4}|SIG[A-Z]{2,12}|CVE-\d{4}-\d{3,7})\b"),
    (7, "issue 编号",
     r"(#\d{2,7}|\b[A-Z][A-Z0-9]{1,10}-\d{1,6}\b)"),
    (8, "其它标识符",
     r"\b([A-Za-z_][A-Za-z0-9_]{2,60})\b"),
]

# 明确不是符号的词
STOP = {
    "the", "and", "for", "not", "was", "are", "this", "that", "with", "from",
    "error", "errors", "warning", "failed", "failure", "exception", "traceback",
    "assert", "assertion", "during", "while", "line", "file", "called", "call",
    "return", "returns", "expected", "actual", "found", "cannot", "could",
    "should", "must", "have", "has", "been", "into", "out", "its", "his",
    "her", "their", "you", "your", "our", "all", "any", "some", "none",
    "null", "nil", "none", "true", "false", "self", "int", "char", "void",
    "string", "str", "list", "dict", "object", "type", "value", "arg",
    "args", "name", "code", "test", "tests", "main", "init", "static",
    "const", "struct", "class", "def", "let", "var", "new", "err", "msg",
    "info", "debug", "fatal", "log", "stdin", "stdout", "stderr", "at",
    "in", "on", "of", "to", "by", "is", "it", "as", "or", "if", "be", "de",
    "segmentation", "fault", "abort", "trace", "stack", "frame", "thread",
    "process", "signal", "exit", "status", "number", "module", "package",
}

NOISE_PREFIX = ("http://", "https://", "mailto:")
NOISE_SUBSTR = ("<", ">", "{", "}", "%s", "%d", "…", "path/to")


def is_symbolish(tok: str) -> bool:
    if not tok or len(tok) < 3 or len(tok) > 120:
        return False
    if tok.lower() in STOP:
        return False
    if tok.startswith(NOISE_PREFIX):
        return False
    if any(s in tok for s in NOISE_SUBSTR):
        return False
    if not re.search(r"[A-Za-z_]", tok):
        return False
    # 纯数字/纯标点
    if re.fullmatch(r"[\W\d_]+", tok):
        return False
    return True


def extract(text: str):
    """返回 [(rank, reason, token)]，按 rank 排序去重。"""
    out = []
    seen = set()

    def add(rank, reason, tok):
        tok = tok.strip().strip("'\"`")
        if not is_symbolish(tok):
            return
        key = tok.lower()
        if key in seen:
            return
        seen.add(key)
        out.append((rank, reason, tok))

    for rank, reason, pat in RULES:
        if rank == 3:  # 文件:行号 单独处理
            for m in re.finditer(pat, text):
                path, line = m.group(1), m.group(2)
                key = f"{path}:{line}"
                if key.lower() in seen:
                    continue
                seen.add(key.lower())
                out.append((3, "报错位置 文件:行号", f"{path}:{line}"))
            continue
        if rank == 7:  # issue 编号单独归类
            for m in re.finditer(pat, text):
                add(7, "issue/CVE 编号", m.group(1))
            continue
        for m in re.finditer(pat, text):
            add(rank, reason, m.group(1))

    out.sort(key=lambda r: (r[0], -len(r[2])))
    return out


def main(argv):
    kind = None
    src = None
    i = 1
    while i < len(argv):
        a = argv[i]
        if a in ("--kind", "-k"):
            i += 1
            kind = argv[i]
        elif a.startswith("--kind="):
            kind = a.split("=", 1)[1]
        elif a in ("-h", "--help"):
            print("用法: extract_symbols.py <error-file|-> [--kind syms|greps|paths]")
            return 0
        elif src is None:
            src = a
        else:
            print(f"多余参数: {a}", file=sys.stderr)
            return 2
        i += 1

    if src is None:
        print("用法: extract_symbols.py <error-file|-> [--kind syms|greps|paths]", file=sys.stderr)
        return 2

    if src == "-":
        text = sys.stdin.read()
    else:
        try:
            with open(src, "r", encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError as e:
            print(f"ERROR: 无法读取 {src}: {e}", file=sys.stderr)
            return 2

    items = extract(text)
    pathpat = re.compile(r"[\w./\\+-]+\.[A-Za-z0-9_+]{1,8}:\d+")

    def is_path_item(rank, tok):
        return rank == 3 or bool(pathpat.fullmatch(tok))

    if kind == "syms":
        for rank, _reason, tok in items:
            if rank == 7 or is_path_item(rank, tok):
                continue
            print(tok)
        return 0

    if kind == "greps":
        # greps 的语义：**用于 commit message 搜索的关键词**，不是符号。
        # 包含：issue 号 / CVE / 报错原文里的关键短语（英文小写词组）。
        # 不包含：泛化标识符（getenv 这类会淹没搜索结果）。
        out = []
        seen = set()

        def push(tok, minlen=4):
            tok = tok.strip()
            if len(tok) < minlen or tok.lower() in seen:
                return
            seen.add(tok.lower())
            out.append(tok)

        # ① issue / CVE / ticket 编号（长度阈值放宽，#42 只有 3 字符）
        for m in re.finditer(r"(#\d{2,7}|CVE-\d{4}-\d{3,7}|[A-Z][A-Z0-9]{1,10}-\d{1,6})", text):
            push(m.group(1), 2)
        # ①b URL 里的 issue 路径：.../issues/1234、.../pull/1234
        for m in re.finditer(r"/(?:issues|pull|pulls|merge_requests)/(\d{1,7})", text):
            push("#" + m.group(1), 2)
        # ② 报错原文里的多词短语（>=2 个词，含空格）—— commit message 常复述这些
        for m in re.finditer(r"[A-Za-z][A-Za-z0-9_]*(?: [A-Za-z][A-Za-z0-9_]*){1,5}", text):
            phrase = m.group(0)
            if len(phrase) >= 12 and not phrase.islower():
                push(phrase)
        # ③ 报错行里被引号包住的整句（如 "cannot open file X"）
        for rank, _reason, tok in items:
            if rank == 2 and " " in tok and len(tok) >= 8:
                push(tok)
        for kw in out[:12]:
            print(kw)
        if not out:
            print("# 未抽取到 commit message 关键词（报错中可能没有 issue 号或可检索短语）", file=sys.stderr)
            return 1
        return 0

    if kind == "paths":
        for rank, reason, tok in items:
            if rank == 3:
                path, line = tok.rsplit(":", 1)
                print(f"{path}\t{line}")
        return 0

    if kind is not None:
        print(f"ERROR: 未知 --kind: {kind}", file=sys.stderr)
        return 2

    print("# rank\ttag\ttoken\treason")
    for rank, reason, tok in items:
        if is_path_item(rank, tok):
            tag = "PATH"
        elif rank in (2, 7):
            tag = "GREP"
        else:
            tag = "SYM"
        print(f"{rank}\t{tag}\t{tok}\t{reason}")
    if not items:
        print("# 未能从报错信息中抽取到可用符号：请把更完整的报错原文或堆栈喂进来，"
              "或手动用 --sym / --grep 传入。", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
