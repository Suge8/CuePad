#!/usr/bin/env python3
"""CuePad 的调试实例：起一份隔离实例，做一件事，一定退出。xc.sh 构建完调它，perf-mac.sh 用 exec。
用法：app.py <shot|rec|run> <mac|ios|ipad> <CuePad.app> <库目录> [--device <UDID>] [--out <图|片>] [-- 启动参数…]
      app.py exec <CuePad.app> <库目录> [-- 启动参数…]   占住本检出那一份后 exec 成 CuePad（量完自己退出的 bench 用，$! 就是 CuePad）
      app.py wait <就绪文件> <PID> [秒=60]              等 exec 起的实例写下就绪文件（kqueue）；它先退出或超时以 1 退出
      app.py stop                                       结束本检出 run 起的 Mac 实例
      app.py sockets                                    本检出实例的连接目录（终端里的会话 export CUEPAD_PI_SOCKET_DIR 为它才连得上）
      app.py preflight                                  Mac 截图、录屏前查台前调度
规则：
1. 只起 apple/.derived* 里的构建；库、偏好、各家 Agent 的配置目录、命令行链接与连接目录都在库目录或本检出的 SOCKETS 下
   （isolated_env 是唯一一份，sync-bench.py 也用它），不碰真实资料库、~/.pi、~/.local/bin、~/CuePad（项目工作区）与 ~/Applications/CuePad.app。
   CUEPAD_FAKE_HOME：改落在假家目录的缺省位置（docs/verify.md「陌生人第一次打开」）。
2. Mac 每个检出最多一份：看守进程（就是本进程）持 apple/.derived/mac-app.lock 的 flock，锁随看守进程释放，崩了也不留；
   新起的直接换掉 run 留着的旧实例。检出之间互不等待：几个 Agent 并行开发时各自截图、验收。
3. 一定退出：做完、出错、被打断（TERM、INT、HUP）、超时（截图类 HOLD 秒，run 是 RUN_TTL，
   CUEPAD_RUN_SECONDS 改它，验完就 stop）都走 quit：先 TERM 走 App 的正常退出，
   5 秒不退再 KILL，连同它起的子进程（Cue 的 pi、cuepad mcp）一起结束。exec 起的 bench 由调用方按 PID 结束，锁随 CuePad 进程释放。
   看守或调用方自己被 KILL、来不及收时，实例发现父进程没了也会正常退出（DebugHooks.exitsWithParent）。
4. 不靠固定等待：Debug 构建摆好画面后写就绪文件（CUEPAD_SHOT_READY，DebugScene.signalReady），这里用 kqueue 等它出现或 App 退出。
   这里起的实例都带它（exec 没给就用本检出那一份），App 据此认出是脚本起的（DebugHooks.scripted），测试宿主不带。
   本机构建一律在后台跑、不抢前台（DebugHooks.present）；不进程序坞是包里声明的（xc.sh 的 LSUIElement）。
   给了 -CuePadForeground YES 的实例要占前台时写 FRONT，front_keeper 经系统事件把它拉到前台（App 自己 activate 会被系统忽略）。
5. Mac 截图、录屏按窗口拍（wincap.swift，尺寸对不上就失败）；启动参数没给窗口尺寸时用 WINDOW。
iOS、iPadOS：模拟器里本就隔离，同一台上再 launch 就换掉旧的；状态栏固定成 9:41、满格满电，做完 terminate，run 留着。
   模拟器的系统外观跟 -theme 走（没给是浅色）：App 钉的外观与系统的不同时，启动屏与状态栏先按系统的画、App 起来后状态栏才淡过去，
   空库这类一起来就就绪的画面会拍到半途的状态栏（深色下 9:41 还是黑字）。
"""
import re
import signal
import sys

sys.dont_write_bytecode = True
from app_env import READY_TIMEOUT, SOCKETS, die  # noqa: E402
from app_mac import exec_mac, mac, preflight, stop  # noqa: E402
from app_proc import interrupted, wait_ready  # noqa: E402
from app_sim import sim  # noqa: E402


def main(argv):
    for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGALRM):
        signal.signal(s, interrupted)
    launch_args = argv[argv.index("--") + 1:] if "--" in argv else []
    argv = argv[:argv.index("--")] if "--" in argv else argv
    cmd = argv[0] if argv else ""
    if cmd == "stop":
        return stop()
    if cmd == "preflight":
        return preflight()
    if cmd == "sockets":
        return print(SOCKETS)
    if cmd == "wait":
        return wait_ready(argv[1], int(argv[2]), timeout=float(argv[3]) if len(argv) > 3 else READY_TIMEOUT)
    if cmd == "exec":
        return exec_mac(argv[1], argv[2], launch_args)
    if cmd not in ("shot", "rec", "run") or len(argv) < 4:
        die(__doc__)
    platform, app, library = argv[1:4]
    options = dict(zip(argv[4::2], argv[5::2]))
    derived = re.sub(r"/Build/Products/.*", "", app)
    out = options.get("--out") or {"shot": f"{derived}/shot-{platform}.png", "rec": f"{derived}/rec-{platform}.mov"}.get(cmd)
    if platform == "mac":
        return mac(cmd, app, library, out, launch_args)
    sim(cmd, options["--device"], app, library, out, launch_args)


if __name__ == "__main__":
    main(sys.argv[1:])
