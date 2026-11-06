# Mac 侧诊断服务：连上后每 2 秒主动推一行（带本机毫秒时刻），同时回显收到的每行
import socket, threading, time
srv = socket.socket(socket.AF_INET6); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); srv.bind(("::1", 5175)); srv.listen()
def handle(c):
    def push():
        for i in range(8):
            time.sleep(2); c.sendall(f"push {i} {int(time.time()*1000)}\n".encode())
    threading.Thread(target=push, daemon=True).start()
    f = c.makefile("rb")
    for line in f: c.sendall(b"echo " + line)
while True:
    c, _ = srv.accept(); threading.Thread(target=handle, args=(c,), daemon=True).start()
