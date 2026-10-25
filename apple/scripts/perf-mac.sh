#!/usr/bin/env bash
# 用法：xc.sh perf mac [次数=3] [启动参数…]   启动参数原样传给 App，如只量几项：xc.sh perf mac 3 -CuePadInteractOnly 会话页,长文打字·回复框
#   单次交互：演示库与大库（-CuePadSeed perf：50 项目、5000 卡、300 张大图、200 个 Pi 历史会话，前 12 个带长对话）上的 -CuePadBench interact，
#   逐项量点击回合（动作发出到画面第一次变的主线程 CPU 毫秒）与其中的指令数、每毫秒跑的周期（GHz：活一样多而回合翻倍时它减半，是机器那一刻慢），
#   合计、最重一圈、指令数与掉帧，取各次的中位数，
#   列成表。默认在后台量（不抢前台）：指令数照样前后对比，帧与掉帧偏乐观，不和预算比；
#   要和交互预算（docs/perf.md「交互预算」）比就加 -CuePadForeground YES 在前台量（规则见 docs/verify.md「占前台」），有一项超了就以 1 退出。
#   CUEPAD_PERF_SEED=<库目录>（如真实库的只读副本）：只量这份库，每次从它克隆，换掉演示库与大库；配 -CuePadProject <库里的项目名>（单次交互从项目页起）。
#   -CuePadInteractOnly 项,项 只量列出的几项（前后对比省下整套流程），用法见 docs/perf.md「交互预算」。
#   前台量时"任务气泡开"是真实点击：App 写 AWAIT click x y，这里用 hid.swift 经 HID 点那一行（会移动真实指针，量完放回）。
#   每次量的原始行（每次启动每项一行 JSON，键同 InteractionBench 的 INTERACT 行，另加"库"）留在 apple/.derived-perf/Build/interact.jsonl，
#   表里的中位数就从它算；下一次 perf mac 开跑时清空重写，要留着比就先拷走。
#   CUEPAD_TRACE=<xctrace 模板>（如 'Animation Hitches'、'Time Profiler'）：每次量的同时按 PID 录 trace，存本检出的 apple/.derived-perf/Build/traces/interact-<库>-<第几次>.trace（xctrace 的输出在同名 .log）。
#   按 PID 开录要好几秒，短的几项等不到就量完退出了：App 带 -CuePadTraceWait YES 起，就绪后写 AWAIT trace <PID> 停着等，这里开录了发 SIGUSR1 放它走。
# xc.sh 构建好 Release（带 DEBUG 条件，只为留下测量代码；预算按用户拿到的构建定，产物在 apple/.derived-perf，Instruments 也用这份）、
# 带 -CuePadForeground YES 时独占机器（别的编译、测试同时跑，指令数之外的数都会被拖歪；后台量只比指令数，不独占）后调这里，第一个参数是 CuePad.app。iOS 的单次交互见 perf-ios.sh。
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP="$1"
runs="${2:-3}"
extra=("${@:3}")
DERIVED="$(dirname "$(dirname "$(dirname "$APP")")")"
LIBRARY="$DERIVED/library-perf"
TRACES="$DERIVED/traces"

# 实例经 app.py exec（隔离、占住本检出那一份后 exec 成 CuePad）：后台调用时 $! 就是 CuePad
launch() {
  local library="$1"; shift
  exec python3 "$APPLE_DIR/scripts/app.py" exec "$APP" "$library" -- "$@"
}

# 第一次：写入大库并把大项目设为当前项目，写完结束；之后的运行才是冷启动。
# 等就绪文件而不是数某张表：就绪在 PerfLibrary.seed 整个写完之后（DebugScene.signalReady），数表会在后面的对话还没写完时就结束它。
# 没写完的不留：下一次从头写
if [ ! -f "$LIBRARY/cuepad.db" ]; then
  mkdir -p "$LIBRARY"
  ready="$DERIVED/seed-ready"
  rm -f "$ready"
  CUEPAD_SHOT_READY="$ready" launch "$LIBRARY" -CuePadSeed perf -CuePadProject 大项目 >"$DERIVED/seed.log" 2>&1 &
  pid=$!
  python3 "$APPLE_DIR/scripts/app.py" wait "$ready" "$pid" 900 >/dev/null || { kill -TERM "$pid" 2>/dev/null; wait "$pid" || true; rm -rf "$LIBRARY"; echo "大库没写完，见 $DERIVED/seed.log" >&2; exit 1; }
  kill -TERM "$pid"
  wait "$pid" || true
fi

# 真实点击的小工具（源文件比它新时重编）：App 每写一行 `AWAIT click x y` 就在那一点点一下；`AWAIT trace <PID>` 时按 PID 开录（`$trace`），其余行原样转出
HID="$DERIVED/hid"
if [ ! -x "$HID" ] || [ "$APPLE_DIR/scripts/hid.swift" -nt "$HID" ]; then xcrun swiftc -O "$APPLE_DIR/scripts/hid.swift" -o "$HID"; fi
clicker() {
  local line kind what x y
  while IFS= read -r line; do
    read -r kind what x y <<<"$line"
    if [ "$kind" = AWAIT ] && [ "$what" = trace ]; then record "$x" &
    elif [ "$kind" = AWAIT ]; then "$HID" click "$x" "$y"
    else printf '%s\n' "$line"; fi
  done
  wait
}

# 按 PID 开录，开录了放 App 往下量；没开录成（输出里没有 Starting recording）就结束它，这一次算没量完
record() {
  local pid="$1"
  xcrun xctrace record --template "$CUEPAD_TRACE" --attach "$pid" --output "$trace" 2>&1 | tee "$trace.log" | {
    if grep -q 'Starting recording'; then kill -USR1 "$pid"; else echo "xctrace 没开录，见 $trace.log" >&2; kill -TERM "$pid"; fi
    cat >/dev/null
  }
}

# 每次都是全新进程（首访就是首访）与一份没量过的库：量的动作会写库（发送），同一份库连跑，后几次量的是越来越长的对话。
# 演示库每次重建；大库每次从写好的那份 APFS 克隆（不占时间也不占空间）
collect() {
  local label="$1" source="$2" library="$DERIVED/library-run" out="$DERIVED/interact-run.log" pipe="$DERIVED/interact-run.fifo"; shift 2
  local tracing=()
  [ -z "${CUEPAD_TRACE:-}" ] || tracing=(-CuePadTraceWait YES)
  for run in $(seq "$runs"); do
    rm -rf "$library" "$pipe"
    local trace="$TRACES/interact-$label-$run.trace"
    if [ -n "${CUEPAD_TRACE:-}" ]; then
      mkdir -p "$TRACES" && rm -rf "$trace" "$trace.log"
      echo "trace：$trace" >&2
    fi
    if [ -n "$source" ]; then cp -cR "$source" "$library"; fi
    mkfifo "$pipe"
    clicker <"$pipe" >"$out" &
    local reader=$!
    launch "$library" "$@" -CuePadBench interact -CuePadWindowSize 1440x900 ${tracing[@]+"${tracing[@]}"} ${extra[@]+"${extra[@]}"} >"$pipe" 2>/dev/null &
    local pid=$!
    local status=0
    wait "$pid" || status=$?
    wait "$reader"
    if [ "$status" != 0 ]; then
      sed -n 's/^BENCH-ERR /CuePad 没量完（'"$label"'）：/p' "$out" >&2
      return "$status"
    fi
    sed -n 's/^INTERACT //p' "$out" | sed "s/^{/{\"库\":\"$label\",/"
  done
  rm -rf "$library" "$out" "$pipe"
}
rows="$DERIVED/interact.jsonl"
: >"$rows"
if [ -n "${CUEPAD_PERF_SEED:-}" ]; then
  collect 真实库 "$CUEPAD_PERF_SEED" >>"$rows"
else
  collect 演示库 "" -CuePadDemo YES -CuePadProject 圆桌 >>"$rows"
  collect 大库 "$LIBRARY" -CuePadProject 大项目 >>"$rows"
fi
python3 - "$rows" <<'PY'
import json, statistics as st, sys
rows = [json.loads(line) for line in open(sys.argv[1])]
order = []
for row in rows:
    key = (row["库"], row["name"])
    if key not in order:
        order.append(key)
over = 0
foreground = all(r.get("foreground") for r in rows)
if not foreground:
    print("后台量的：帧与掉帧偏乐观，不和预算比（加 -CuePadForeground YES 在前台量才比）")
print(f"{'库':6}{'交互':14}{'点击回合 ms':>12}{'预算':>7}{'其中指令 M':>10}{'GHz':>6}{'合计 ms':>9}{'指令 M':>8}{'最重一圈':>9}{'掉帧':>6}{'预算':>6}{'最长帧 ms':>10}  结果")
for key in order:
    samples = [r for r in rows if (r["库"], r["name"]) == key]
    click = st.median(r["clickMs"] for r in samples)
    hitches = st.median(r["hitches"] for r in samples)
    worst = max(r["worstMs"] for r in samples)
    total = st.median(r["totalMs"] for r in samples)
    instructions = st.median(r["instructionsM"] for r in samples)
    heaviest = st.median(r["maxTurnMs"] for r in samples)
    click_instructions = st.median(r["clickInstructionsM"] for r in samples)
    ghz = st.median(r["clickGHz"] for r in samples)
    budget_click, budget_hitches = samples[0]["budgetClickMs"], samples[0]["budgetHitches"]
    ok = click <= budget_click and hitches <= budget_hitches
    over += foreground and not ok
    unseen = '，未见变化' if not all(r["seen"] for r in samples) else ''
    print(f"{key[0]:6}{key[1]:14}{click:12.1f}{budget_click:7.0f}{click_instructions:10.0f}{ghz:6.2f}{total:9.0f}{instructions:8.0f}{heaviest:9.1f}{hitches:6.0f}{budget_hitches:6d}{worst:10.1f}  {('ok' if ok else '超预算') if foreground else '-'}{unseen}")
sys.exit(1 if over else 0)
PY
