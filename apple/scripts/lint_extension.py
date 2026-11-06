#!/usr/bin/env python3
"""lint.sh 的一条规则（在 apple/ 下跑，只查工作区）：Pi 桥扩展（cuepad-bridge）的源码相对 origin/main 改了，入口的 EXTENSION_VERSION 就要升
（CuePi/README.md「协议」：扩展改了就升）。版本相同的会话 CuePad 不发 upgrade，跑着的旧扩展就一直不换，按新含义发的命令它照旧含义答。
是否改了按与 origin/main 的分叉点比（含未提交、未跟踪的文件），不把主线后来的改动算成本分支的；版本要高过分叉点与 origin/main 两边：
主线在这期间也升过的，同号的两版就是两个扩展。"""
import re, subprocess, sys

EXTENSION = "CuePadKit/Sources/CuePi/Extension/cuepad-bridge"
ENTRY = f"{EXTENSION}/index.ts"
VERSION = re.compile(r"const EXTENSION_VERSION = (\d+);")


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def version(source):
    found = VERSION.search(source)
    if not found: sys.exit(f"{ENTRY}：没有 const EXTENSION_VERSION = <数>;")
    return int(found[1])


try:
    base = git("merge-base", "HEAD", "origin/main").strip()
except subprocess.CalledProcessError as error:
    sys.exit(f"lint_extension.py 要 origin/main 来认扩展改没改：{error.stderr.strip()}（先 git fetch origin main）")
changed = git("diff", "--name-only", base, "--", EXTENSION).split() + git("ls-files", "--others", "--exclude-standard", "--", EXTENSION).split()
if not changed: sys.exit(0)

current = version(open(ENTRY, encoding="utf-8").read())
above = max(version(git("show", f"{base}:apple/{ENTRY}")), version(git("show", f"origin/main:apple/{ENTRY}")))
if current <= above:
    print("\n".join(changed))
    print(f"  → Pi 桥扩展相对 origin/main 改了，{ENTRY} 的 EXTENSION_VERSION 还是 {current}：升到 {above + 1}（高过分叉点与 origin/main 的版本）。"
          "版本不变时 CuePad 不让跑着的会话换上新扩展；改了已有命令的含义或 CuePad 读的格式，再把 PiWire.oldestExtension 提到这一版（CuePi/README.md「协议」）\n")
    sys.exit(1)
