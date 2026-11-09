#!/usr/bin/env python3
"""lint.sh 的一条规则（在 apple/ 下跑，只查工作区）：`Schema.baseVersion`（能打开的最老结构版本）不得高于各 mac/、ios/ 发布标签那时的结构版本中的最小值，
否则已发出去的构建建的库升级后打不开（`schemaTooOld`）。标签那时的结构版本 = 那时 Schema.swift 的 `upgrades` 里最后一条步骤注释 `// <版本>：` 的版本号。
没有任何发布标签（浅克隆、没拉标签）时不能放过：算不出就退出 1，提示 git fetch --tags。"""
import re, subprocess, sys

sys.dont_write_bytecode = True
SCHEMA = "apple/CuePadKit/Sources/CueStore/Schema.swift"
STEP = re.compile(r"^    // (\d+)[：:]", re.M)


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def version(source):
    steps = source[source.index("static let upgrades"):]
    found = STEP.findall(steps[:steps.index("\n  ]")])
    return max(map(int, found)) if found else int(re.search(r"static let baseVersion = (\d+)", source).group(1))


tags = git("tag", "--list", "mac/*", "ios/*").split()
if not tags:
    sys.exit("lint_schema.py 要发布标签（mac/、ios/）来认 baseVersion 够不够老：先 git fetch --tags")
versions = {}
for tag in tags:
    try: versions[tag] = version(git("show", f"{tag}:{SCHEMA}"))
    except (subprocess.CalledProcessError, ValueError) as error:
        sys.exit(f"lint_schema.py 读不出 {tag} 那时的结构版本：{error}")
lowest = min(versions, key=versions.get)
base = int(re.search(r"static let baseVersion = (\d+)", open("CuePadKit/Sources/CueStore/Schema.swift", encoding="utf-8").read()).group(1))
if base > versions[lowest]:
    print(f"{SCHEMA}: baseVersion = {base}")
    print(f"  → baseVersion 高过标签 {lowest} 那时的结构版本 {versions[lowest]}：用那个构建建的库升级后会因 schemaTooOld 打不开。"
          f"起点要不高于所有已发布标签的最小结构版本（算法与怎么挪起点见 Schema.baseVersion 的注释）\n")
    sys.exit(1)
