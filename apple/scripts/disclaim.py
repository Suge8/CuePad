#!/usr/bin/env python3
"""disclaim.py <程序> [参数…]：把自己换成 <程序>（PID 不变，同 exec），并放弃 TCC 的责任链，让它成为自己的责任进程。

为什么：从终端、Agent 会话里起的进程，TCC 记在责任进程头上（Pi 会话跑在正式版 CuePad 下面，责任进程就是正式版）。
调试实例要麦克风等权限时，系统查的是正式版的授权与签名声明，正式版没声明就直接拒、连弹窗都没有。
做法同 Qt Creator 的 disclaim 与 LLDB：posix_spawn 带 POSIX_SPAWN_SETEXEC 与 responsibility_spawnattrs_setdisclaim（libSystem 的私有接口，
Xcode 起调试进程也走它）。环境、文件描述符原样交过去，PID 不变，调用方手里的 Popen、按 PID 结束照旧。
"""
import ctypes, os, sys

POSIX_SPAWN_SETEXEC = 0x0040


def main(argv):
    libc = ctypes.CDLL(None, use_errno=True)
    attr = ctypes.c_void_p()
    check(libc.posix_spawnattr_init(ctypes.byref(attr)), "posix_spawnattr_init")
    check(libc.posix_spawnattr_setflags(ctypes.byref(attr), ctypes.c_short(POSIX_SPAWN_SETEXEC)), "posix_spawnattr_setflags")
    check(libc.responsibility_spawnattrs_setdisclaim(ctypes.byref(attr), ctypes.c_bool(True)), "responsibility_spawnattrs_setdisclaim")
    args = (ctypes.c_char_p * (len(argv) + 1))(*[a.encode() for a in argv], None)
    env = [f"{k}={v}".encode() for k, v in os.environ.items()]
    envp = (ctypes.c_char_p * (len(env) + 1))(*env, None)
    pid = ctypes.c_int()
    # 成功时不返回（已换成目标程序）
    check(libc.posix_spawn(ctypes.byref(pid), argv[0].encode(), None, ctypes.byref(attr), args, envp), f"posix_spawn {argv[0]}")


def check(code, what):
    if code != 0:
        sys.exit(f"disclaim.py：{what} 失败：{os.strerror(code)}")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    main(sys.argv[1:])
