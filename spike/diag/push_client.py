# 远端：连本机隧道端口，每秒发一行 ping（记往返），并记服务器主动推送到达的延迟（远端时刻 − 推送里的 Mac 时刻 − 时钟差）
import socket, sys, threading, time
skew = int(sys.argv[2]); s = socket.create_connection(("127.0.0.1", int(sys.argv[1])))
s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
def ping():
    for i in range(16):
        s.sendall(f"{int(time.time()*1000)}\n".encode()); time.sleep(1)
threading.Thread(target=ping, daemon=True).start()
f = s.makefile("rb"); end = time.time() + 18
for line in f:
    now = int(time.time()*1000); p = line.decode().split()
    if p[0] == "echo": print("rtt", now - int(p[1]), flush=True)
    else: print("push", p[1], now - skew - int(p[2]), flush=True)
    if time.time() > end: break
