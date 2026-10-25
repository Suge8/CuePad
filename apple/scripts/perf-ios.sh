#!/usr/bin/env bash
# 用法：xc.sh perf ios [次数=3] [启动参数…]   启动参数原样传给 App，如任务多时：xc.sh perf ios 3 -CuePadManyTasks 150 -CuePadProject CuePad
#   iPhone 模拟器上的单次交互（-CuePadBench interact，`IOSInteractionBench`）：演示库（给了 CUEPAD_PERF_SEED=<库目录> 时每次从那份库的克隆起，
#   如真实库的只读副本：冷启动进 Cue 页要量真实大小的对话），每次全新进程，逐项量点击回合、合计、最重一圈
#   （主线程 CPU 毫秒）、进程指令数（百万条）与掉帧，按"第几次"分开取各次的中位数列成表；"落点"是量完时的根与推入的页（各次不同时都列出）。
#   模拟器的合成与 GPU 和真机不同：只看主线程 CPU 与指令数，掉帧只作参考；第一次的数里有模拟器才有的 Swift 一致性查找，真机要另量。
#   长按菜单与手势在进程内没有入口：App 写 `AWAIT 名 x y`（按）或 `AWAIT 名 x y x2 y2 swipe|drag 秒`（快滑或慢拖），这里用 axe（https://github.com/cameroncooke/AXe）
#   在模拟器上真按（长按菜单按住 0.8 秒；收起在 App 里做）、真滑（axe swipe）、真拖（axe drag，每秒 60 个移动点）。
#   某一次没写完（App 写了 FAIL、中途退出或超时）整次失败、以 1 退出，不出部分结果的表。
#   CUEPAD_TRACE=<xctrace 模板>（如 'Time Profiler'）：每次量的同时录整段 trace（启动前开录，含冷启动），存本检出的 apple/.derived-perf/Build/traces/interact-ios-<第几次>.trace。
#   录的是整机（模拟器里的进程 xctrace 按 PID、按名字都认不出），按打印的 PID 筛；INTERACT 行的 at（墙钟）减 trace 的开始时刻就是各项在 trace 里的位置。
#   xctrace 连设备卡住（不出"Starting recording"、收到 Ctrl-C 也不退）时这里 60 秒后放弃并以 1 退出，不带着卡住的录制往下量。
# xc.sh 构建好 Release（带 DEBUG 条件，只为留下测量代码；产物在 apple/.derived-perf）、领到一台模拟器后调这里（不独占机器：只比指令数与主线程 CPU），第一个参数是 CuePad.app；
# 设备是领到的那台（机型 CUEPAD_IOS_DEVICE，默认 iPhone 17；见 _sim.sh）。
set -euo pipefail
command -v axe >/dev/null || { echo "需要 axe（brew install cameroncooke/axe/axe）" >&2; exit 1; }

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=_sim.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_sim.sh"
# shellcheck source=_signing.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_signing.sh"
APP="$1"
runs="${2:-3}"
DERIVED="$(dirname "$(dirname "$(dirname "$APP")")")"
BUNDLE_ID=$CUEPAD_APP_ID
udid="$(sim_udid "${CUEPAD_IOS_DEVICE:-iPhone 17}")"

# 每次从刚开机的模拟器量：开着很久的模拟器上（尤其用过 axe 查界面、点按之后）同一交互的指令数能高出一倍。量完开着留给别的任务
xcrun simctl shutdown "$udid" 2>/dev/null || true
sim_boot "$udid"
xcrun simctl install "$udid" "$APP"

running() { local list; list="$(xcrun simctl spawn "$udid" launchctl list 2>/dev/null)"; [[ "$list" == *"UIKitApplication:$BUNDLE_ID"* ]]; }
rows="$DERIVED/interact.jsonl"
: >"$rows"
for run in $(seq "$runs"); do
  library="$DERIVED/library-$run"
  rm -rf "$library"
  library_args=(-CuePadDemo YES)
  if [ -n "${CUEPAD_PERF_SEED:-}" ]; then cp -cR "$CUEPAD_PERF_SEED" "$library"; library_args=(); fi
  out="$library/interact.jsonl"
  tracer=""
  if [ -n "${CUEPAD_TRACE:-}" ]; then
    trace="$DERIVED/traces/interact-ios-$run.trace"
    mkdir -p "$DERIVED/traces" && rm -rf "$trace"
    xcrun xctrace record --template "$CUEPAD_TRACE" --device "$udid" --all-processes --output "$trace" >"$trace.log" 2>&1 &
    tracer=$!
    # 开录了再启动，冷启动才录得到
    for _ in $(seq 600); do grep -q 'Starting recording' "$trace.log" && break; sleep 0.1; done
    grep -q 'Starting recording' "$trace.log" || { kill -9 "$tracer"; echo "xctrace 60 秒没开录（多半卡在连设备上，见 $trace.log）" >&2; exit 1; }
  fi
  pid="$(SIMCTL_CHILD_CUEPAD_LIBRARY_DIR="$library" xcrun simctl launch "$udid" "$BUNDLE_ID" ${library_args[@]+"${library_args[@]}"} -CuePadBench interact "${@:3}" | sed 's/.*: //')"
  if [ -n "$tracer" ]; then echo "trace：${trace}（CuePad PID ${pid}）" >&2; fi
  sleep 2
  # 量完自己退出；最多等 5 分钟。其间按 App 要的点真按
  pressed=0 finished=0 deadline=$(( $(date +%s) + 300 )) tick=0
  while [ "$(date +%s)" -lt "$deadline" ]; do
    tick=$((tick + 1))
    # 问模拟器"还在跑吗"要几百毫秒：每秒问一次，按点的请求每 0.1 秒看一次
    if [ $((tick % 10)) = 0 ] && ! running; then finished=1; break; fi
    awaits="$(grep -c '^AWAIT ' "$out" 2>/dev/null || true)"
    if [ "${awaits:-0}" -gt "$pressed" ]; then
      pressed=$((pressed + 1))
      read -r _ name x y x2 y2 how seconds < <(grep '^AWAIT ' "$out" | sed -n "${pressed}p")
      if [ "$how" = drag ]; then
        axe drag --start-x "$x" --start-y "$y" --end-x "$x2" --end-y "$y2" --duration "$seconds" --steps "$(printf '%.0f' "$(echo "$seconds * 60" | bc)")" --udid "$udid" >/dev/null
      elif [ "$how" = swipe ]; then
        axe swipe --start-x "$x" --start-y "$y" --end-x "$x2" --end-y "$y2" --duration "$seconds" --delta 10 --udid "$udid" >/dev/null
      elif [ "$name" = 长按菜单 ]; then
        axe touch -x "$x" -y "$y" --down --udid "$udid" >/dev/null; sleep 0.8; axe touch -x "$x" -y "$y" --up --udid "$udid" >/dev/null
      else
        axe tap -x "$x" -y "$y" --udid "$udid" >/dev/null
      fi
    fi
    sleep 0.1
  done
  if [ -n "$tracer" ]; then
    kill -INT "$tracer"
    for _ in $(seq 600); do kill -0 "$tracer" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$tracer" 2>/dev/null; then kill -9 "$tracer"; echo "xctrace 收到 Ctrl-C 60 秒没写完，$trace 不完整" >&2; exit 1; fi
  fi
  if [ "$finished" = 0 ]; then xcrun simctl terminate "$udid" "$BUNDLE_ID" || true; echo "第 $run 次：5 分钟内没量完" >&2; exit 1; fi
  if grep -q '^FAIL ' "$out" || ! grep -q '^DONE' "$out"; then
    echo "第 $run 次没量完：$(grep '^FAIL ' "$out" || echo 'App 中途退出')" >&2; exit 1
  fi
  sed -n "s/^INTERACT {/{\"run\":$run,/p" "$out" >>"$rows"
done

python3 - "$rows" <<'PY'
import json, sys, statistics
rows, order, seen = {}, [], {}
for line in open(sys.argv[1]):
    r = json.loads(line)
    key = (r["run"], r["name"]); seen[key] = seen.get(key, 0) + 1
    k = (r["name"], seen[key])
    if k not in rows: order.append(k)
    rows.setdefault(k, []).append(r)
print("交互\t第几次\t点击回合ms\t其中指令百万\tGHz\t合计ms\t最重一圈ms\t指令百万\t掉帧\t启动到对话ms\t落点")
for k in order:
    m = lambda f: statistics.median(r[f] for r in rows[k])
    print(f"{k[0]}\t{k[1]}\t{m('clickMs'):.1f}\t{m('clickInstructionsM'):.0f}\t{m('clickGHz'):.2f}\t{m('totalMs'):.1f}\t{m('maxTurnMs'):.1f}\t{m('instructionsM'):.0f}\t{m('hitches'):.0f}\t{m('launchMs') if 'launchMs' in rows[k][0] else ''}\t{' / '.join(dict.fromkeys(r.get('landed', '') for r in rows[k]))}")
PY
