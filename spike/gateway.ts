// Mac 侧网关（第 1 步的通道）：只把进来的连接接到唯一被授权的 127.0.0.1:<端口>，不让对端指定目标。
// 用法：bun gateway.ts <监听地址:端口> <授权端口>
const [listen, allowed] = [process.argv[2] ?? "127.0.0.1:9000", Number(process.argv[3] ?? 5173)];
const [lh, lp] = listen.split(":");
const target = process.argv[4] ?? "localhost";
let n = 0;
Bun.listen<{ id: number; peer?: any; pending: Uint8Array[]; up: number; down: number }>({
  hostname: lh, port: Number(lp),
  socket: {
    open(s) {
      s.data = { id: ++n, pending: [], up: 0, down: 0 };
      const t0 = Date.now();
      Bun.connect({ hostname: target, port: allowed, socket: {
        open(p) { s.data.peer = p; for (const b of s.data.pending) p.write(b); s.data.pending = []; console.log(`${Date.now()} gw #${s.data.id} open +${Date.now()-t0}ms`); },
        data(p, d) { s.data.down += d.length; s.write(d); },
        close() { console.log(`${Date.now()} gw #${s.data.id} close up=${s.data.up} down=${s.data.down}`); s.end(); },
        error(p, e) { console.log(`gw #${s.data.id} target error ${e}`); s.end(); },
      }}).catch(e => { console.log(`gw #${s.data.id} connect failed ${e}`); s.end(); });
    },
    data(s, d) { s.data.up += d.length; if (s.data.peer) s.data.peer.write(d); else s.data.pending.push(new Uint8Array(d)); },
    close(s) { s.data.peer?.end(); },
  },
});
console.log(`gateway ${listen} -> 127.0.0.1:${allowed}`);
