#!/usr/bin/env python3
"""单个文件不超过 LIMIT 个令牌（字节数 ÷ 4，约 20KB）：Agent 一次读得完、改得准。
用法：size.py           查暂存区（提交钩子用）：新增的文件超标，或已超标的文件变大，就拦下并给出拆法，退出 1
      size.py --report  列出仓库里此刻超标的文件（从大到小）
已超标的文件改小或不变照常放行：存量随手拆，不卡住并行改它们的会话；拆完后规则不变，就是全拦。
不是 Agent 写的文件（锁文件、生成物、录制的回放、资源、第三方代码）列在同目录的 size-ignore；二进制文件不看。
"""
import glob
import os
import re
import subprocess
import sys

LIMIT = 5000
BYTES_PER_TOKEN = 4
# 拆出来的每份留出余量：刚好卡在上限的文件，下一次改动又超了
TARGET = LIMIT * 3 // 4
IGNORE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "size-ignore")


def git(*args, binary=False):
    out = subprocess.run(["git", *args], capture_output=True, check=True).stdout
    return out if binary else out.decode()


def ignored():
    with open(IGNORE) as f:
        patterns = [line.strip() for line in f if line.strip() and not line.startswith("#")]
    return [re.compile(glob.translate(p, recursive=True, include_hidden=True)) for p in patterns]


def tokens(size):
    return size // BYTES_PER_TOKEN


def blob(spec):
    """spec（如 :path、HEAD:path）的内容；不存在为 None。"""
    result = subprocess.run(["git", "cat-file", "blob", spec], capture_output=True)
    return result.stdout if result.returncode == 0 else None


def is_binary(data):
    return b"\0" in data[:8000]  # 同 git 的判断


# 每种文件的切分点：顶层声明、分段标记、标题。拆的时候整段搬，不从一段中间切开
SPLITS = {
    ".swift": re.compile(r"^(?:\s*//\s*MARK:\s*-?\s*(?P<mark>.+)|(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private|final|nonisolated|indirect)\s+)*(?P<kind>struct|class|enum|actor|protocol|extension|func)\s+(?P<name>[\w.]+))"),
    ".ts": re.compile(r"^(?://\s*(?:MARK:|---+)\s*(?P<mark>.+)|(?:export\s+)?(?:default\s+)?(?:async\s+)?(?P<kind>function|class|interface|type|const|enum)\b\s*(?P<name>\w+)?)"),
    ".py": re.compile(r"^(?:#\s*-{3,}\s*(?P<mark>[^-].*?)\s*-*$|(?P<kind>def|class)\s+(?P<name>\w+))"),
    ".sh": re.compile(r"^(?:#\s*-{3,}\s*(?P<mark>.+)|(?P<name>[\w-]+)\(\)\s*\{)"),
    ".md": re.compile(r"^(?P<mark>#{1,3}\s+.+)"),
}
HEADER = "文件开头（import、常量）"
# 类型里的一级成员：一段太大时在这里再切
MEMBERS = {
    ".swift": re.compile(r"^(?: {4}|\t)(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|package|internal|fileprivate|private|final|nonisolated|static|override|mutating|lazy|convenience|required)\s+)*(?:func|init|struct|class|enum|actor|var|let)\b"),
    ".ts": re.compile(r"^(?:  |\t)(?:(?:async\s+)?function\s+\w+|(?:const|let)\s+\w+\s*=|\w+\.on\(|\w+\.register\w*\()"),
}
HOW = {
    ".swift": "按职责拆：每个顶层类型一个文件，命名同类型名；一个类型太大就按 MARK 段拆成扩展，命名 <类型>+<职责>.swift（同 CueStore+Sync.swift）。"
              "搬进别的文件的扩展用到的 private 成员改成不带 private（同模块可见），或连同它们一起搬走。测试按被测的行为分 Suite，一个 Suite 一个文件。",
    ".ts": "按职责拆成几个模块，入口文件只留接线与导出；共用的类型放一个 types 文件。",
    ".py": "按职责拆成几个模块，入口脚本只留参数解析与调度。",
    ".sh": "把成块的逻辑拆成同目录的 _<职责>.sh，由入口 source（同 _lock.sh、_sim.sh）。",
    ".md": "按二级标题拆：入口文档留概述与指向各篇的链接，每个大节一篇；改了路径就同时改指向它的链接（AGENTS.md 的「碰到这些先读」）。",
}


def sections(path, data):
    """(起始行号, 标题) 的列表，按切分点；第一段从第 1 行起。"""
    ext = os.path.splitext(path)[1]
    pattern = SPLITS.get(ext)
    lines = data.decode(errors="replace").splitlines(keepends=True)
    cuts = [(1, HEADER, None)]
    if pattern:
        for number, line in enumerate(lines, 1):
            m = pattern.match(line)
            if not m:
                continue
            mark, name = m.group("mark"), m.groupdict().get("name")
            title = mark.strip().lstrip("#").strip() if mark else " ".join(x for x in (m.groupdict().get("kind"), name) if x)
            entry = (number, title, None if mark else name)
            if number == 1:
                cuts[0] = entry
            else:
                cuts.append(entry)
    offsets = [0]
    for line in lines:
        offsets.append(offsets[-1] + len(line.encode()))
    def size(start, end):
        return offsets[end] - offsets[start - 1]

    result = []
    for i, (start, title, name) in enumerate(cuts):
        end = (cuts[i + 1][0] if i + 1 < len(cuts) else len(lines) + 1) - 1
        member = MEMBERS.get(ext)
        inner = [n for n in range(start + 1, end + 1) if member and member.match(lines[n - 1])] if tokens(size(start, end)) > LIMIT else []
        if not inner:
            result.append((start, end, title, size(start, end), name, None))
            continue
        # 一段自己就超了：再按它的成员（类型里的方法、Suite 里的用例）切开，搬成扩展
        bounds = [start, *inner, end + 1]
        for a, b in zip(bounds, bounds[1:]):
            label = title if a == start else lines[a - 1].strip()[:60]
            found = None if a == start else re.search(r"(?:func|init|var|let|const|function|struct|class|enum|actor)\s+(\w+)", lines[a - 1])
            result.append((a, b - 1, label, size(a, b - 1), name if a == start else None, found and found[1]))
    return result


def plan(path, data):
    """把相邻的段依次装进不超过 TARGET 的几份，输出每份放哪几段；装不下的单段原样列出（要在段内再按职责拆）。"""
    ext = os.path.splitext(path)[1]
    stem = os.path.splitext(os.path.basename(path))[0]
    parts, current = [], []
    for section in sections(path, data):
        # 文件开头（import）跟着后面那段走，不单独成一份
        only_header = len(current) == 1 and current[0][2] == HEADER
        if current and not only_header and tokens(sum(s[3] for s in current) + section[3]) > TARGET:
            parts.append(current)
            current = []
        current.append(section)
    if current:
        parts.append(current)
    out = [f"  怎么拆：{HOW.get(ext, '按职责拆成几个文件，每个只管一件事；入口文件只留接线。')}",
           f"  按现有的分段依次装成 {len(parts)} 份，每份不超过约 {TARGET} 令牌（文件名取这份的第一段，按它真正的职责改成项目惯用的英文名）："]
    def named(n, part):
        first = part[1] if part[0][2] == HEADER and len(part) > 1 else part[0]  # 第一份的开头是 import，按其后那段命名
        if first[4]:
            return f"{first[4]}{ext}"  # 顶层声明：以它命名
        return f"{stem}{'-' if ext == '.md' else '+'}{first[5] or re.sub(r'[^\w]+', '', first[2])[:24] or n}{ext}"

    names = [named(n, part) for n, part in enumerate(parts, 1)]
    if os.path.basename(path) not in names:
        names[0] = os.path.basename(path)  # 第一份留在原文件里
    for n, part in enumerate(parts, 1):
        name = names[n - 1]
        out.append(f"    {name}（约 {tokens(sum(s[3] for s in part))} 令牌）：")
        shown = part if len(part) <= 6 else [*part[:3], None, *part[-2:]]
        for section in shown:
            if section is None:
                out.append(f"      …（这份共 {len(part)} 段）")
                continue
            start, end, title, size = section[:4]
            flag = "  ← 这一段自己就超了，要在段内再按职责拆" if tokens(size) > LIMIT else ""
            out.append(f"      第 {start}–{end} 行  {title[:70]}（{tokens(size)}）{flag}")
    return "\n".join(out)


def report():
    patterns = ignored()
    rows = []
    for path in git("ls-files", "-z").split("\0"):
        if not path or any(p.match(path) for p in patterns) or not os.path.isfile(path):
            continue
        with open(path, "rb") as f:
            data = f.read()
        if tokens(len(data)) > LIMIT and not is_binary(data):
            rows.append((tokens(len(data)), path))
    for count, path in sorted(rows, reverse=True):
        print(f"{count:>7}  {path}")
    print(f"共 {len(rows)} 个文件超过 {LIMIT} 令牌")


def staged():
    patterns = ignored()
    # 改名与复制按原文件比大小：搬个家不算新增
    entries = git("diff", "--cached", "--name-status", "-z", "-M", "--diff-filter=ACMR").split("\0")
    failures = []
    i = 0
    while i < len(entries) - 1:
        status = entries[i]
        if status[0] in "RC":
            source, path = entries[i + 1], entries[i + 2]
            i += 3
        else:
            source = path = entries[i + 1]
            i += 2
        if any(p.match(path) for p in patterns):
            continue
        data = blob(f":{path}")
        if data is None or is_binary(data) or tokens(len(data)) <= LIMIT:
            continue
        before = blob(f"HEAD:{source}")
        now = tokens(len(data))
        if before is not None and len(data) <= len(before):
            continue
        why = (f"新文件 {now} 令牌" if before is None
               else f"{tokens(len(before))} → {now} 令牌（已超标的文件只能改小，不能再变大）")
        failures.append(f"{path}：{why}，上限 {LIMIT}（字节数 ÷ {BYTES_PER_TOKEN}）\n{plan(path, data)}")
    if failures:
        print("单个文件超过上限：Agent 一次读不完、改不准。拆完再提交（只拆不改行为；拆的提交里文件都变小了，照常放行）。\n", file=sys.stderr)
        print("\n\n".join(failures), file=sys.stderr)
        print(f"\n不是手写的文件（生成物、录制的回放、资源）加进 {os.path.relpath(IGNORE)}。", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    os.chdir(git("rev-parse", "--show-toplevel").strip())
    report() if sys.argv[1:] == ["--report"] else staged()
