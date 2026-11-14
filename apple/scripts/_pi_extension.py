"""Pi 桥扩展在 Python 里的唯一一份：版本声明的读法，与冒充扩展的脚本（假扩展）发的消息。路径相对 apple/。
入口里 `const EXTENSION_VERSION = <数>;` 的精确排版是跨语言接口（CueBridge/README.md「协议」：在跑的扩展、Swift 也按它读）。
消息照扩展的 session.ts 写，CuePad 怎么读看 PiWire.swift：那边加了必读的字段，这里跟着加。"""
import json, os, re, sys

EXTENSION = "CuePadKit/Sources/CueBridge/Extension/cuepad-bridge"
ENTRY = f"{EXTENSION}/index.ts"
_DECLARATION = re.compile(r"const EXTENSION_VERSION = (\d+);")


def extension_version(source):
    found = _DECLARATION.search(source)
    if not found: sys.exit(f"{ENTRY}：没有 const EXTENSION_VERSION = <数>;")
    return int(found[1])


def version_in(apple):
    """apple/ 目录 apple 那份检出的扩展版本：假扩展报它，CuePad 才当作读得懂的随包扩展。"""
    return extension_version(open(f"{apple}/{ENTRY}", encoding="utf-8").read())


def hello(version, session_id, cwd, state, **info):
    """socket 文件名得是 `<session_id>.<本进程 pid>.sock`（CuePad 核对）。info 是可选的会话信息（name、firstMessage…，格式见 PiWire.Info）。
    hosted：CuePad 只收由它托管的会话。"""
    return {"t": "hello", "extensionVersion": version, "sessionId": session_id, "sessionFile": None, "pid": os.getpid(),
            "cwd": cwd, "hosted": True, "state": state, **info}


def state(value): return {"t": "state", "state": value}
def bye(reason): return {"t": "bye", "reason": reason}
def ack(request_id): return {"t": "ack", "id": request_id, "ok": True}
def line(message): return (json.dumps(message) + "\n").encode()
