"""调试实例的路径、时限与隔离环境（app.py 的规则 1：isolated_env 是唯一一份）。"""
import hashlib
import os
import re
import sys

APPLE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECKOUT = os.path.dirname(APPLE)
# App 身份前缀：唯一定义在 Signing.xcconfig 的 CUEPAD_APP_ID
BUNDLE_ID = re.search(r"^CUEPAD_APP_ID *= *(\S+)", open(f"{APPLE}/App/Config/Signing.xcconfig").read(), re.M)[1]
RUNTIME = f"/tmp/cuepad-xc-{os.getuid()}"  # 与 _lock.sh 同一处；模拟器的就绪文件放这里（按设备分）
SLOT, READY = f"{APPLE}/.derived/mac-app.lock", f"{APPLE}/.derived/mac-ready"
# 实例借着前台却没到前台时写它（DebugForeground），看守替它拉到前台：别的应用在前台时 App 自己 activate 会被系统忽略
FRONT = f"{APPLE}/.derived/mac-front"
FRONT_POLL = 0.3
# 连接目录放 /tmp 下按检出分：socket 路径受 sun_path 104 字节限制，检出路径太长
SOCKETS = f"/tmp/cuepad-app-{os.getuid()}-{hashlib.sha1(CHECKOUT.encode()).hexdigest()[:8]}"
BUILD = re.compile(r".*/apple/\.derived[^/]*/Build/Products/[^/]+/CuePad\.app")
WINDOW = "1440x900"
READY_TIMEOUT = 60
HOLD = 300  # 截图类的看守上限（另加录屏、测量的秒数）：卡在哪一步都不留实例
# 一轮 bcu 交互验收用不完；不够就再 run 一次（换掉旧的），要等长任务（在 App 里装 Agent）时用 CUEPAD_RUN_SECONDS 放长。忘了收的实例曾活过 14 小时
RUN_TTL = int(os.environ.get("CUEPAD_RUN_SECONDS", 5 * 60))
REC_SECONDS = float(os.environ.get("CUEPAD_REC_SECONDS", 12))


def die(message):
    print(message, file=sys.stderr, flush=True)
    sys.exit(1)


REAL_LIBRARY = os.path.expanduser("~/Library/Application Support/CuePad")


def isolated_env(library, sockets=SOCKETS):
    library = os.path.realpath(library)
    if library == REAL_LIBRARY or library.startswith(REAL_LIBRARY + "/"):
        die(f"{library} 是真实资料库：本机构建一打开就升级结构、改写并同步出去。用只读副本（docs/verify.md「真实数据复现」）")
    agents = f"{library}/agents"
    # 锁的内部变量不带进实例：实例里的 Agent 再调 xc.sh 要照常进锁
    inherited = {k: v for k, v in os.environ.items() if k not in ("CUEPAD_SIM", "CUEPAD_FAKE_HOME")}
    env = dict(inherited, CUEPAD_LIBRARY_DIR=library, CUEPAD_PI_SOCKET_DIR=sockets)
    fake_home = os.environ.get("CUEPAD_FAKE_HOME")
    if fake_home:
        # 各家配置、~/.local/bin、~/CuePad 落在假家目录的缺省位置；连接目录照样另起，不抢正式版的
        home = os.path.realpath(fake_home)
        if home == os.path.realpath(os.path.expanduser("~")):
            die("CUEPAD_FAKE_HOME 不能是真的家目录")
        for key in ("CUEPAD_BIN_DIR", "CUEPAD_WORKSPACE_DIR", *AGENT_HOMES, "XDG_CONFIG_HOME"):
            env.pop(key, None)
        # Foundation 的家目录看 CFFIXED_USER_HOME；没给 CLAUDE_CONFIG_DIR 的 Claude Code 从钥匙串读真实的登录
        return dict(env, HOME=home, CFFIXED_USER_HOME=home, CLAUDE_CONFIG_DIR=f"{home}/.claude")
    return dict(env, CUEPAD_BIN_DIR=f"{library}/bin", CUEPAD_WORKSPACE_DIR=f"{library}/CuePad",
                **{key: f"{agents}/{name}" for key, name in AGENT_HOMES.items()})


# 各家配置目录的变量 → 隔离库里的目录名
AGENT_HOMES = {"PI_CODING_AGENT_DIR": "pi", "CLAUDE_CONFIG_DIR": "claude", "CODEX_HOME": "codex", "OPENCODE_CONFIG_DIR": "opencode"}
