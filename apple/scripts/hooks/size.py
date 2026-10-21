#!/usr/bin/env python3
"""单个文件不超过 LIMIT 个令牌（字节数 ÷ 4，约 20KB）：Agent 一次读得完、改得准。
用法：size.py           查暂存区（提交钩子）：新文件超标、已超标的文件变大就拦下，给出拆法，退出 1
      size.py --report  列出此刻超标的文件
已超标的文件改小或不变照常放行：存量随手拆，不卡并行改它们的会话；拆完后就是全拦。不是手写的文件列在同目录的 size-ignore，二进制不看。
"""
import glob
import os
import re
import subprocess
import sys

LIMIT = 5000
BYTES_PER_TOKEN = 4
TARGET = LIMIT * 3 // 4  # 拆出的每份留余量：卡在上限的文件下次一改又超
IGNORE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "size-ignore")
HEADER = "文件开头"
# 切分点：顶层声明（name 组）与分段标记、标题（mark 组）；整段搬，不从中间切
SPLITS = {
    ".swift": re.compile(r"^(?:\s*//\s*MARK:\s*-?\s*(?P<mark>.+)|(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private|final|nonisolated|indirect)\s+)*(?:struct|class|enum|actor|protocol|extension|func)\s+(?P<name>[\w.]+))"),
    ".ts": re.compile(r"^(?://\s*(?:MARK:|---+)\s*(?P<mark>.+)|(?:export\s+)?(?:default\s+)?(?:async\s+)?(?:function|class|interface|type|const|enum)\b\s*(?P<name>\w+)?)"),
    ".md": re.compile(r"^#{1,3}\s+(?P<mark>.+)"),
}
# 一段自己就超了时再按一级成员切（类型里的方法、Suite 里的用例），搬成扩展
MEMBERS = {
    ".swift": re.compile(r"^(?: {4}|\t)(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private|final|nonisolated|static|override|mutating|lazy|convenience|required)\s+)*(?:func|init|struct|class|enum|actor|var|let)\b"),
    ".ts": re.compile(r"^(?:  |\t)(?:(?:async\s+)?function\s+\w+|(?:const|let)\s+\w+\s*=|\w+\.on\(|\w+\.register\w*\()"),
}
HOW = {
    ".swift": "每个顶层类型一个文件；类型太大按 MARK 段或成员拆成 <类型>+<职责>.swift 扩展，搬走的代码用到的 private 去掉；测试按 Suite 拆",
    ".md": "入口留概述与链接，每个大节一篇，改了路径同时改指向它的链接",
}


def git(*args):
    return subprocess.run(["git", *args], capture_output=True, check=True).stdout.decode()


def blob(spec):
    """spec（:path、HEAD:path）的内容；不存在为 None。"""
    result = subprocess.run(["git", "cat-file", "blob", spec], capture_output=True)
    return result.stdout if result.returncode == 0 else None


def tokens(size):
    return size // BYTES_PER_TOKEN


def oversized(data):
    return tokens(len(data)) > LIMIT and b"\0" not in data[:8000]  # 二进制同 git 的判断


def ignored():
    with open(IGNORE) as f:
        patterns = [line.strip() for line in f if line.strip() and not line.startswith("#")]
    rules = [re.compile(glob.translate(p, recursive=True, include_hidden=True)) for p in patterns]
    return lambda path: any(rule.match(path) for rule in rules)


def sections(path, data):
    """[(起行, 止行, 标题, 字节数, 顶层声明名或 None)]"""
    ext = os.path.splitext(path)[1]
    lines = data.decode(errors="replace").splitlines(keepends=True)
    offsets = [0]
    for line in lines:
        offsets.append(offsets[-1] + len(line.encode()))
    cuts = [(1, HEADER, None)]
    for number, line in enumerate(lines, 1):
        m = SPLITS[ext].match(line) if ext in SPLITS else None
        if m:
            entry = (number, (m["mark"] or line.split("{")[0]).strip()[:60], m.groupdict().get("name"))
            cuts = [entry] if number == 1 else [*cuts, entry]
    result = []
    for i, (start, title, name) in enumerate(cuts):
        end = cuts[i + 1][0] - 1 if i + 1 < len(cuts) else len(lines)
        inner = []
        if tokens(offsets[end] - offsets[start - 1]) > LIMIT and ext in MEMBERS:
            inner = [n for n in range(start + 1, end + 1) if MEMBERS[ext].match(lines[n - 1])]
        bounds = [start, *inner, end + 1]
        for a, b in zip(bounds, bounds[1:]):
            label = title if a == start else lines[a - 1].strip()[:60]
            result.append((a, b - 1, label, offsets[b - 1] - offsets[a - 1], name if a == start else None))
    return result


def plan(path, data):
    """相邻的段依次装进不超过 TARGET 的几份；文件开头跟着后一段走。"""
    stem, ext = os.path.splitext(os.path.basename(path))
    parts = []
    for section in sections(path, data):
        last = parts[-1] if parts else None
        if last and (last == [last[0]] and last[0][2] == HEADER or tokens(sum(s[3] for s in last) + section[3]) <= TARGET):
            last.append(section)
        else:
            parts.append([section])
    out = [f"  拆法：{HOW.get(ext, '按职责拆成几个文件，入口只留接线')}。按现有分段装成 {len(parts)} 份（名字按职责改）："]
    for n, part in enumerate(parts, 1):
        named = next((s[4] for s in part if s[4]), None)
        name = os.path.basename(path) if n == 1 else f"{named}{ext}" if named else f"{stem}+{re.sub(r'\W+', '', part[0][2])[:24] or n}{ext}"
        out.append(f"    {name}（约 {tokens(sum(s[3] for s in part))} 令牌）")
        for section in part if len(part) <= 5 else [*part[:2], None, *part[-2:]]:
            if section is None:
                out.append(f"      …共 {len(part)} 段")
                continue
            start, end, title, size, _ = section
            flag = "  ← 单段超标，段内再拆" if tokens(size) > LIMIT else ""
            out.append(f"      {start}–{end} 行 {title}（{tokens(size)}）{flag}")
    return "\n".join(out)


def report(skip):
    rows = []
    for path in filter(None, git("ls-files", "-z").split("\0")):
        if not skip(path) and os.path.isfile(path):
            with open(path, "rb") as f:
                data = f.read()
            if oversized(data):
                rows.append((tokens(len(data)), path))
    for count, path in sorted(rows, reverse=True):
        print(f"{count:>7}  {path}")
    print(f"共 {len(rows)} 个文件超过 {LIMIT} 令牌")


def staged(skip):
    fields = iter(git("diff", "--cached", "--name-status", "-z", "-M", "--diff-filter=AMR").split("\0"))
    failures = []
    for status in fields:
        if not status:
            continue
        source = next(fields)
        path = next(fields) if status[0] == "R" else source  # 改名按原文件比：搬家不算新增
        data = blob(f":{path}")
        if skip(path) or data is None or not oversized(data):
            continue
        before = blob(f"HEAD:{source}")
        if before is not None and len(data) <= len(before):
            continue
        why = f"新文件 {tokens(len(data))}" if before is None else f"{tokens(len(before))} → {tokens(len(data))}，超标的文件只能改小"
        failures.append(f"{path}：{why}（令牌，上限 {LIMIT}）\n{plan(path, data)}")
    if failures:
        print(f"文件超过 {LIMIT} 令牌（字节数 ÷ {BYTES_PER_TOKEN}）就拦：先拆再提交，只拆不改行为。\n", file=sys.stderr)
        print("\n\n".join(failures), file=sys.stderr)
        print(f"\n不是手写的文件加进 {os.path.relpath(IGNORE)}。", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    os.chdir(git("rev-parse", "--show-toplevel").strip())
    (report if sys.argv[1:] == ["--report"] else staged)(ignored())
