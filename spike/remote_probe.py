#!/usr/bin/env python3
"""远端（替身手机）上量隧道：按浏览器的三波依赖取 Vite 模板首屏的全部资源（6 条并发连接，同 WebKit 每主机上限），
再连 HMR 的 WebSocket，打下每条消息到达的本机时刻（毫秒）。只用标准库。
用法：remote_probe.py <本机端口> <首屏次数> <听 HMR 秒数>"""
import base64, http.client, json, os, re, socket, sys, threading, time
from concurrent.futures import ThreadPoolExecutor

port, loads, listen = int(sys.argv[1]), int(sys.argv[2]), float(sys.argv[3])
ms = lambda: int(time.time() * 1000)
WAVES = [["/"], ["/@vite/client", "/src/main.js"],
         ["/src/style.css", "/src/counter.js", "/src/assets/hero.png", "/src/assets/javascript.svg", "/src/assets/vite.svg",
          "/node_modules/vite/dist/client/env.mjs", "/icons.svg", "/favicon.svg"]]
local = threading.local()


def get(path):
    try:
        conn = getattr(local, "conn", None)
        if conn is None:
            conn = local.conn = http.client.HTTPConnection("localhost", port, timeout=30)
        conn.request("GET", path, headers={"Host": "localhost:5173"})
        r = conn.getresponse()
        body = r.read()
        return r.status, len(body)
    except Exception as error:
        local.conn = None
        print(json.dumps({"type": "error", "path": path, "error": repr(error)}), flush=True)
        return 0, 0


def page_load():
    start = time.time()
    total, statuses = 0, []
    with ThreadPoolExecutor(6) as pool:
        for wave in WAVES:
            for status, size in pool.map(get, wave):
                statuses.append(status)
                total += size
    return round((time.time() - start) * 1000), total, sorted(set(statuses))


for i in range(loads):
    local.__dict__.clear()
    took, size, statuses = page_load()
    print(json.dumps({"type": "pageload", "i": i, "ms": took, "bytes": size, "status": statuses}), flush=True)

client = http.client.HTTPConnection("localhost", port, timeout=30)
client.request("GET", "/@vite/client", headers={"Host": "localhost:5173"})
token = re.search(rb'wsToken = "([^"]+)"', client.getresponse().read()).group(1).decode()
s = socket.create_connection(("localhost", port))
key = base64.b64encode(os.urandom(16)).decode()
began = ms()
s.sendall(f"GET /?token={token} HTTP/1.1\r\nHost: localhost:5173\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
          f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: vite-hmr\r\nOrigin: http://localhost:5173\r\n\r\n".encode())
buf = b""
while b"\r\n\r\n" not in buf:
    buf += s.recv(4096)
head, buf = buf.split(b"\r\n\r\n", 1)
print(json.dumps({"type": "ws-open", "ms": ms() - began, "status": head.split(b"\r\n")[0].decode()}), flush=True)
s.settimeout(0.5)
deadline = time.time() + listen
while time.time() < deadline:
    try:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    except socket.timeout:
        continue
    while len(buf) >= 2:
        length, offset = buf[1] & 0x7F, 2
        if length == 126:
            length, offset = int.from_bytes(buf[2:4], "big"), 4
        elif length == 127:
            length, offset = int.from_bytes(buf[2:10], "big"), 10
        if len(buf) < offset + length:
            break
        payload, buf = buf[offset:offset + length], buf[offset + length:]
        print(json.dumps({"type": "ws-msg", "t": ms(), "data": payload[:120].decode(errors="replace")}), flush=True)
