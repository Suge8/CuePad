#!/usr/bin/env python3
"""lint.sh 的一条规则（在 apple/ 下跑，只查工作区）：`Schema.baseVersion`（能打开的最老结构版本）不得高于 mac/、ios/ 各自最新一个发布标签那时的结构版本中的较小值，
否则装着那一版的设备的库升级后打不开（`schemaTooOld`）。更早的标签不算：只有作者自己的设备在用，都装着各平台最新的那一版。标签那时的结构版本 = 那时 Schema.swift 的 `baseVersion` 加 `upgrades` 数组的元素个数（同 `Schema.version`）。
没有任何发布标签（浅克隆、没拉标签）时不能放过：算不出就退出 1，提示 git fetch --tags。"""
import re, subprocess, sys

sys.dont_write_bytecode = True
from lint_git import fail, git  # noqa: E402
SCHEMA = "apple/CuePadKit/Sources/CueStore/Schema.swift"
BASE = re.compile(r"static let baseVersion = (\d+)")


def version(source):
    """数 `upgrades` 数组字面量的顶层元素：跳过注释与字符串（含多行、原始字符串与插值），按顶层逗号分。"""
    i = source.index("= [", source.index("static let upgrades")) + 3
    depth, count, item = 0, 0, False
    while True:
        if source.startswith("//", i):
            i = source.index("\n", i)
            continue
        if source.startswith("/*", i):
            i = source.index("*/", i) + 2
            continue
        quote = re.match(r'(#*)("""|")', source[i:])
        if quote:
            i, item = skip_string(source, i, *quote.groups()), True
            continue
        c = source[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            if depth == 0:
                return int(BASE.search(source).group(1)) + count + item
            depth -= 1
        elif c == "," and depth == 0:
            count, item = count + item, False
            i += 1
            continue
        item = item or not c.isspace()
        i += 1


def skip_string(source, i, hashes, quote):
    close, i = quote + hashes, i + len(hashes) + len(quote)
    while not source.startswith(close, i):
        if source[i] == "\\" and source.startswith("\\" + hashes + "(", i):
            i, depth = i + len(hashes) + 2, 1
            while depth:
                depth += {"(": 1, ")": -1}.get(source[i], 0)
                i += 1
        else:
            i += 2 if source[i] == "\\" and not hashes else 1
    return i + len(close)


try:
    tags = git("tag", "--list", "mac/*", "ios/*").split()
except subprocess.CalledProcessError as error:
    fail("lint_schema.py 要发布标签（mac/、ios/）来认 baseVersion 够不够老", error)
if not tags:
    sys.exit("lint_schema.py 要发布标签（mac/、ios/）来认 baseVersion 够不够老：先 git fetch --tags")
latest = [max(t for t in tags if t.startswith(p)) for p in ("mac/", "ios/") if any(t.startswith(p) for t in tags)]
versions = {}
for tag in latest:
    try: versions[tag] = version(git("show", f"{tag}:{SCHEMA}"))
    except (subprocess.CalledProcessError, ValueError) as error:
        sys.exit(f"lint_schema.py 读不出 {tag} 那时的结构版本：{error}")
lowest = min(versions, key=versions.get)
base = int(BASE.search(open("CuePadKit/Sources/CueStore/Schema.swift", encoding="utf-8").read()).group(1))
if base > versions[lowest]:
    print(f"{SCHEMA}: baseVersion = {base}")
    print(f"  → baseVersion 高过标签 {lowest} 那时的结构版本 {versions[lowest]}：用那个构建建的库升级后会因 schemaTooOld 打不开。"
          f"起点要不高于各平台最新发布标签的结构版本（算法与怎么挪起点见 Schema.baseVersion 的注释）\n")
    sys.exit(1)
