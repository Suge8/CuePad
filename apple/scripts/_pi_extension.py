"""Pi 桥扩展的版本声明。入口里 `const EXTENSION_VERSION = <数>;` 的精确排版是跨语言接口（CueBridge/README.md「协议」：在跑的扩展、Swift 也按它读），
Python 的读法只在这里。路径相对 apple/。"""
import re, sys

EXTENSION = "CuePadKit/Sources/CueBridge/Extension/cuepad-bridge"
ENTRY = f"{EXTENSION}/index.ts"
_DECLARATION = re.compile(r"const EXTENSION_VERSION = (\d+);")


def extension_version(source):
    found = _DECLARATION.search(source)
    if not found: sys.exit(f"{ENTRY}：没有 const EXTENSION_VERSION = <数>;")
    return int(found[1])
