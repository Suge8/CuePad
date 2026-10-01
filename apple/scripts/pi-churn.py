# 假 Pi 扩展（压力场景）：同一进程里反复"结束会话（bye new）→ 新建会话 → 状态连跳"，复现 Pi 会话列表与状态快速变化。
# 用法：python3 pi-churn.py <socket 目录> [轮数=60] [all|error]；error 只在"思考中"与"出错"之间跳（挑刺官第 2 轮崩溃前的状态）。
# 配合隔离实例：CUEPAD_PI_SOCKET_DIR 指向同一目录；会话工作目录是 ~/Project/cuepad（演示库 CuePad 项目绑定的目录）。
# 判定：跑完后 `log show --predicate 'processID == <pid>'` 里不应出现 "Geometry action is cycling" 与 "has continued for 300 iterations"，进程不应退出。
import json, os, socket, sys, threading, time, random
d = sys.argv[1]; rounds = int(sys.argv[2]) if len(sys.argv) > 2 else 60
os.makedirs(d, mode=0o700, exist_ok=True); os.chmod(d, 0o700)
cwd = os.path.expanduser("~/Project/cuepad")
def now(): return time.time() * 1000
ERR = {"kind": "error", "error": "Error: 402 Payment Required — Your account has insufficient credits for this request (model claude-x). Please top up your balance at https://console.example.com/billing and retry. request_id=req_01JABCDEF"}
states_all = [{"kind": "thinking"}, {"kind": "tool", "tool": "bash", "tools": ["bash"], "detail": "pnpm test -- --run scheduler && pnpm lint --fix src/very/long/path/to/module"},
          {"kind": "outputting"}, {"kind": "waiting_user", "promptKind": "confirm", "title": "要覆盖 public/feed.xml 吗？"},
          {"kind": "error", "error": "Rate limit exceeded: 429 Too Many Requests from upstream provider, retry after 20s"}, {"kind": "done", "aborted": False}]
def session(sid, lifetime):
    path = f"{d}/{sid}.{os.getpid()}.sock"
    s = socket.socket(socket.AF_UNIX); s.bind(path); os.chmod(path, 0o600); s.listen(4); s.settimeout(0.05)
    clients = []
    def broadcast(msg):
        for c in list(clients):
            try: c.sendall((json.dumps(msg) + "\n").encode())
            except OSError: clients.remove(c)
    state = {"kind": "idle", "since": now()}
    end = time.time() + lifetime; nxt = time.time() + 0.1
    while time.time() < end:
        try:
            c, _ = s.accept()
            c.sendall((json.dumps({"t": "hello", "protocol": 1, "extensionVersion": 2, "sessionId": sid, "sessionFile": None, "pid": os.getpid(),
                                   "cwd": cwd, "mode": "tui", "model": "demo", "tty": None, "term": {}, "state": state}) + "\n").encode())
            clients.append(c)
        except socket.timeout: pass
        if time.time() >= nxt:
            state = dict(random.choice(states)); state["since"] = now()
            broadcast({"t": "state", "state": state}); nxt = time.time() + random.uniform(0.03, 0.25)
    broadcast({"t": "bye", "reason": "new"})
    for c in clients: c.close()
    s.close(); os.remove(path)
mode = sys.argv[3] if len(sys.argv) > 3 else "all"
states = [{"kind": "thinking"}, ERR] if mode == "error" else states_all
for i in range(rounds):
    session(f"churn-{i}-{random.randrange(1 << 30)}", random.uniform(0.4, 1.6))
