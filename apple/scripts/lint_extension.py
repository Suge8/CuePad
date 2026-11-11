#!/usr/bin/env python3
"""lint.sh 的一条规则（在 apple/ 下跑，只查工作区）：Pi 桥扩展（cuepad-bridge）的源码相对 origin/main 改了，入口的 EXTENSION_VERSION 就要升
（CueBridge/README.md「协议」：扩展改了就升）。版本相同的会话 CuePad 不发 upgrade，跑着的旧扩展就一直不换，按新含义发的命令它照旧含义答。
是否改了按与 origin/main 的分叉点比（含未提交、未跟踪的文件），不把主线后来的改动算成本分支的；版本要高过分叉点与 origin/main 两边：
主线在这期间也升过的，同号的两版就是两个扩展。"""
import re, subprocess, sys

sys.dont_write_bytecode = True
from _pi_extension import ENTRY, EXTENSION, extension_version as version  # noqa: E402
from lint_git import fail, git  # noqa: E402

# 首行是 CuePad 认"这个目录是自己装的"的记号（PiExtension.swift 的 ownershipMarker），删了就把自己装的当成用户的同名目录。
marker = re.search(r'ownershipMarker = "(.*)"', open("CuePadKit/Sources/CueBridge/PiExtension.swift", encoding="utf-8").read())[1]
if open(ENTRY, encoding="utf-8").readline().rstrip("\n") != marker:
    sys.exit(f"{ENTRY} 首行必须是 {marker}：CuePad 靠它认出自己装的扩展（PiExtension.ownershipMarker）")

try:
    base = git("merge-base", "HEAD", "origin/main").strip()
except subprocess.CalledProcessError as error:
    fail("lint_extension.py 要 origin/main 来认扩展改没改", error)
changed = git("diff", "--name-only", base, "--", EXTENSION).split() + git("ls-files", "--others", "--exclude-standard", "--", EXTENSION).split()
if not changed: sys.exit(0)

current = version(open(ENTRY, encoding="utf-8").read())


def version_at(revision):
    # 那一版里入口不在这个路径（扩展目录挪过）：没有可比的版本，升没升只能靠挪目录的那次改动自己保证
    if not git("ls-tree", "--full-tree", "--name-only", revision, f"apple/{ENTRY}"): return 0
    return version(git("show", f"{revision}:apple/{ENTRY}"))


above = max(version_at(base), version_at("origin/main"))
if current <= above:
    print("\n".join(changed))
    print(f"  → Pi 桥扩展相对 origin/main 改了，{ENTRY} 的 EXTENSION_VERSION 还是 {current}：升到 {above + 1}（高过分叉点与 origin/main 的版本）。"
          "版本不变时 CuePad 不让跑着的会话换上新扩展；改了已有命令的含义或 CuePad 读的格式，再把 PiWire.oldestExtension 提到这一版（CueBridge/README.md「协议」）\n")
    sys.exit(1)
