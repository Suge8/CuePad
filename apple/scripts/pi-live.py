# 假 Pi 扩展：给资料库里每个有对话的会话（再加几个没有对话的）各开一个桥连接，会话 id 相同，Mac 就把它们当在线会话。
# 切会话测量（`-CuePadBench switch`，见 docs/development.md「性能测量」）要在线会话才复现"点开后对话区空白"：在线会话不等资料库读完就有状态。
# 用法：python3 pi-live.py <socket 目录> <cuepad.db> <存活秒数> [busy]；busy 时各会话每隔零点几秒到一两秒随机换一次状态。
# 配合隔离实例：CUEPAD_PI_SOCKET_DIR 指向同一目录。
import json, os, random, socket, sqlite3, sys, threading, time

directory, library, lifetime = sys.argv[1], sys.argv[2], float(sys.argv[3])
busy = len(sys.argv) > 4 and sys.argv[4] == "busy"
PROTOCOL = 6  # PiWire.protocolVersion
os.makedirs(directory, mode=0o700, exist_ok=True)
os.chmod(directory, 0o700)
db = sqlite3.connect(library)
ids = [row[0] for row in db.execute("SELECT DISTINCT sessionID FROM piMessages")]
ids += [row[0] for row in db.execute(
    "SELECT sessionID FROM piSessionStates WHERE sessionID NOT IN (SELECT DISTINCT sessionID FROM piMessages) ORDER BY sessionID LIMIT 6")]
STATES = [{"kind": "thinking"}, {"kind": "outputting"}, {"kind": "tool", "tool": "bash", "tools": ["bash"], "detail": "pnpm test"}, {"kind": "done", "aborted": False}]


def now():
    return time.time() * 1000


def send(connection, message):
    connection.sendall((json.dumps(message) + "\n").encode())


def serve(session_id):
    listener = socket.socket(socket.AF_UNIX)
    path = f"{directory}/{session_id}.{os.getpid()}.sock"
    listener.bind(path)
    os.chmod(path, 0o600)
    listener.listen(4)
    listener.settimeout(0.1)
    clients, state = [], {"kind": "idle", "since": now()}
    end, change = time.time() + lifetime, time.time() + random.uniform(0.5, 2)
    while time.time() < end:
        try:
            client, _ = listener.accept()
            send(client, {"t": "hello", "protocol": PROTOCOL, "extensionVersion": 2, "sessionId": session_id, "sessionFile": None, "pid": os.getpid(),
                          "cwd": os.path.expanduser("~"), "mode": "tui", "tty": None, "term": {}, "state": state})
            clients.append(client)
        except socket.timeout:
            pass
        if busy and time.time() >= change:
            state = dict(random.choice(STATES), since=now())
            for client in list(clients):
                try:
                    send(client, {"t": "state", "state": state})
                except OSError:
                    clients.remove(client)
            change = time.time() + random.uniform(0.3, 1.5)
    for client in clients:
        client.close()
    listener.close()
    os.remove(path)


threads = [threading.Thread(target=serve, args=(session_id,)) for session_id in ids]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
