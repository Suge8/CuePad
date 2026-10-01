# 真实 Pi 压力驱动：隔离 agent 目录里用真实 pi（RPC 模式、离线、假模型）反复
# "发提示词 → 思考中 → 出错/完成 → 开新会话 → 立刻再发提示词"，会话文件真实落盘（侧栏历史随之变化）。
# 复现挑刺官第 2 轮崩溃前的操作序列。只发普通文字与 [[fail]]，假模型不会调用工具、不改工作目录。
# 用法：python3 pi-real-churn.py <agent 目录> <socket 目录> <工作目录> [轮数=20]
import json, os, shutil, subprocess, sys, time
agent, sock, cwd = sys.argv[1], sys.argv[2], os.path.expanduser(sys.argv[3])
rounds = int(sys.argv[4]) if len(sys.argv) > 4 else 20
here = os.path.dirname(os.path.abspath(__file__))
kit = os.path.join(here, "..", "CuePadKit")
pi = os.path.expanduser("~/.local/bin/pi")
os.makedirs(os.path.join(agent, "extensions"), exist_ok=True)
shutil.copy(os.path.join(kit, "Sources/CuePi/Extension/cuepad-bridge.ts"), os.path.join(agent, "extensions"))
os.makedirs(sock, mode=0o700, exist_ok=True); os.chmod(sock, 0o700)
env = {k: v for k, v in os.environ.items() if not k.startswith(("HERDR", "TMUX"))}
env.update(PI_CODING_AGENT_DIR=agent, CUEPAD_PI_SOCKET_DIR=sock)
proc = subprocess.Popen(
    [pi, "--mode", "rpc", "--offline", "--no-context-files", "--no-skills", "--no-prompt-templates", "--no-themes",
     "--model", "fake/echo", "--thinking", "off", "-e", os.path.join(kit, "Tests/CuePiTests/Fixtures/fake-model.ts")],
    cwd=cwd, env=env, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, text=True)
def send(command):
    if proc.poll() is not None:
        sys.exit(f"pi 提前退出（退出码 {proc.returncode}）")
    proc.stdin.write(json.dumps(command) + "\n"); proc.stdin.flush()
time.sleep(2)
for i in range(rounds):
    send({"type": "prompt", "message": f"第 {i} 轮提示词 [[slow]]" + (" [[fail]]" if i % 2 == 0 else "")})
    time.sleep(0.3 + (i % 4) * 0.4)
    send({"type": "new_session"})
    time.sleep(0.05 * (i % 3))
send({"type": "prompt", "message": "收尾 [[fail]]"})
time.sleep(2)
proc.terminate(); proc.wait(5)
