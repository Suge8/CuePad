#!/bin/bash
# 跨网量隧道：远端服务器当替身手机跑 cuetunnel-connect + remote_probe.py，本机改 Vite 文件，按时钟差配对 HMR 消息。
# 用法：[CUETUNNEL_RELAY=<自营中继 url>] remote_run.sh <ssh 别名> <标签> <ticket 文件> [--relay-only]；产物在 /tmp/cuepad-fsm/preview-spike/remote-<标签>.*
set -u
host=$1; label=$2; ticket=$(cat "$3"); extra=${4:-}
S=/tmp/cuepad-fsm/preview-spike; W=$(cd "$(dirname "$0")" && pwd); R=/tmp/cuepad-preview-spike
# 时钟差要用复用的 ssh 连接测：每次新建连接的握手让往返到 1 秒、中点偏几百毫秒
CM="-o ControlMaster=auto -o ControlPath=/tmp/cm-spike-%h -o ControlPersist=300"
ssh $CM "$host" true
ssh $CM "$host" "mkdir -p $R" && cat "$W/cuetunnel/target/x86_64-unknown-linux-musl/release/cuetunnel-connect" | ssh $CM "$host" "cat > $R/cuetunnel-connect && chmod +x $R/cuetunnel-connect" && cat "$W/remote_probe.py" | ssh $CM "$host" "cat > $R/remote_probe.py"
# 时钟差：取往返最短的一次，远端时刻减本机中点
skew=$(for i in 1 2 3 4 5 6; do a=$(python3 -c 'import time;print(int(time.time()*1000))'); r=$(ssh $CM "$host" 'python3 -c "import time;print(int(time.time()*1000))"'); b=$(python3 -c 'import time;print(int(time.time()*1000))'); echo "$((b-a)) $((r-(a+b)/2))"; done | sort -n | head -1)
echo "skew(rtt offset)=$skew" | tee "$S/remote-$label.skew"
ssh $CM "$host" "cd $R && (${CUETUNNEL_RELAY:+CUETUNNEL_RELAY=$CUETUNNEL_RELAY} ./cuetunnel-connect '$ticket' 25173 $extra 2> connect-$label.log & echo \$! > connect.pid); timeout 60 sh -c 'until grep -q forwarding connect-$label.log; do sleep 0.2; done'; python3 remote_probe.py 25173 6 28; sleep 1; kill \$(cat connect.pid); cat connect-$label.log" > "$S/remote-$label.out" 2>&1 &
sshpid=$!
timeout 150 bash -c "until grep -q ws-open '$S/remote-$label.out'; do sleep 0.3; done" || echo "没等到 ws-open"
"$W/hmr_drive.py" "$S/vite-app" 5 2 > "$S/remote-$label.edits"
wait $sshpid
grep -E '"pageload"|ws-open|^CT' "$S/remote-$label.out"
python3 - "$S/remote-$label.edits" "$S/remote-$label.out" "${skew#* }" <<'PY'
import json, sys, statistics
edits = [l.split() for l in open(sys.argv[1]) if l.startswith("EDIT")]
msgs = [json.loads(l) for l in open(sys.argv[2]) if l.startswith("{") and '"ws-msg"' in l]
skew = int(sys.argv[3])
out = {"css": [], "js": []}
for _, kind, i, t in edits:
    t = int(t)
    want = '"update"' if kind == "css" else '"full-reload"'
    m = next((m for m in msgs if m["t"] - skew >= t - 60 and want in m["data"]), None)
    if m: out[kind].append(m["t"] - skew - t)
for k, v in out.items():
    if v: print(f"HMR {k}（写文件→远端收到 WebSocket 消息，已扣时钟差）: 中位 {statistics.median(v)}ms 全部 {v}")
loads = [json.loads(l)["ms"] for l in open(sys.argv[2]) if '"pageload"' in l]
if loads: print(f"首屏资源（三波、6 并发，含 {len(loads)} 次）: 第一次 {loads[0]}ms，之后中位 {statistics.median(loads[1:])}ms")
PY
