#!/usr/bin/env bash
# 布局反馈环压力场景：对一个 CuePad.app 跑下面几组隔离实例，任何一组出现布局循环或崩溃就以 1 退出。
#   1. 屏幕外最小窗口，Pi 会话快速结束/新建并在"思考中/出错"之间跳
#   2. 1280×907 窗口，Pi 会话全状态快速轮换
#   3. 常驻滚动条下边加卡边逐点拉宽窗口（-CuePadBench churn）
#   4. 本机有真实 pi（~/.local/bin/pi）时：真实 Pi 会话"发提示词 → 出错/完成 → 开新会话 → 立刻再发"，会话文件真实落盘；并断言这条路径确实走到了：Pi 写出的会话文件不少于轮数的一半、应用历史里至少有一条，
#      否则判为"没覆盖到"，同样以 1 退出
# 判定依据是该进程的系统日志："Geometry action is cycling"（SwiftUI 几何回调来回翻转）与
# "has continued for 300 iterations"（AppKit 布局迭代超限，随后抛异常退出）。需要 DEBUG 条件编译的构建（调试场景参数）。
# 用法：scripts/layout-stress.sh [--inject-loop] [CuePad.app]（缺省 apple/.derived/Build/Products/Debug/CuePad.app，先 xc.sh build mac）
# 某组进程中途退出时报出退出码或终止信号，并保留它的隔离库目录（资料库、Pi 目录、这段进程的系统日志 process.log），打印路径不删。
# --inject-loop：每组都挂上刻意的几何回写环（-CuePadGeometryLoop YES），证明检测器抓得到这类环：每组都抓到才以 0 退出；
#   哪组没抓到，或因为没就绪、崩溃、没覆盖到这些别的原因失败，都以 1 退出（只看退出码 1 分不出是不是抓到了环）。
set -u
APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# 进本检出的入口锁：实例经 app.py 占本检出那一份，同检出的 shot、rec 不能同时在跑
# shellcheck source=_lock.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_lock.sh"
xc_enter plain "$0" "$@"
inject=()
if [ "${1:-}" = --inject-loop ]; then inject=(-CuePadGeometryLoop YES); shift; fi
app="${1:-$APPLE_DIR/.derived/Build/Products/Debug/CuePad.app}"
failed=0
# 假 Pi 会话的工作目录取演示库 CuePad 项目绑定的目录（从 Debug/DemoLibrary.swift 读，不另存一份），会话由此归到该项目；
# 真实 pi 要求目录存在，用仓库根
DEMO_DIR="$HOME/$(sed -n 's/.*name: "CuePad".*directory: "\\(home)\([^"]*\)".*/\1/p' "$APPLE_DIR/App/Sources/UI/Debug/DemoLibrary.swift")"
REAL_DIR="$(cd "$APPLE_DIR/.." && pwd)"
READY_TIMEOUT="${CUEPAD_STRESS_READY_TIMEOUT:-60}" # 等画面就绪的秒数上限
SOCK="$(python3 "$APPLE_DIR/scripts/app.py" sockets)"

run() { # 名称 Pi模式(none/all/error/real) 轮数 启动参数…
  local name=$1 mode=$2 rounds=$3; shift 3
  local lib start pid alive
  rm -rf "$SOCK" # 上一组留下的连接，免得这一组连到不在了的会话
  lib="$(mktemp -d /tmp/cuepad-stress.XXXXXX)"
  start="$(date "+%Y-%m-%d %H:%M:%S")"
  # 隔离与每个检出一份经 app.py exec：它占住那一份后 exec 成 CuePad，$! 就是 CuePad
  CUEPAD_SHOT_READY="$lib/ready" python3 "$APPLE_DIR/scripts/app.py" exec "$app" "$lib" -- \
    -CuePadDemo YES -CuePadProject CuePad ${inject[@]+"${inject[@]}"} "$@" >/dev/null 2>&1 &
  pid=$!
  # 画面就绪（演示库写好、摆好）再开始搅；App 先退出时照常往下，崩溃在后面判
  if [ "$mode" != none ] && ! python3 "$APPLE_DIR/scripts/app.py" wait "$lib/ready" "$pid" "$READY_TIMEOUT" 2>/dev/null && kill -0 "$pid" 2>/dev/null; then
    echo "${name}：$READY_TIMEOUT 秒内画面没有就绪，App 进程仍存活（未响应启动）" >&2
    kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    echo "  证据留在 ${lib}" >&2; failed=1; return
  fi
  if [ "$mode" = none ]; then
    wait "$pid"
  elif [ "$mode" = real ]; then
    python3 "$APPLE_DIR/scripts/pi-real-churn.py" "$lib/agents/pi" "$SOCK" "$REAL_DIR" "$rounds" || echo "  真实 pi 提前退出，按已跑的轮数判定覆盖"
  else
    python3 "$APPLE_DIR/scripts/pi-churn.py" "$SOCK" "$DEMO_DIR" "$rounds" "$mode"
  fi
  # 中途退出时 wait 拿到它自己的退出码：大于 128 是被信号结束（减 128 是信号号）
  local status=""
  if kill -0 "$pid" 2>/dev/null; then alive=1; kill -TERM "$pid"; { sleep 10; kill -9 "$pid" 2>/dev/null; } & watchdog=$!; wait "$pid" || true; kill "$watchdog" 2>/dev/null; wait "$watchdog" 2>/dev/null; else alive=0; wait "$pid"; status=$?; fi
  sleep 1 # 系统日志没有"已落盘"的通知
  local log cycles iterations
  log="$(log show --start "$start" --predicate "processID == $pid" --style compact 2>/dev/null)"
  cycles=$(grep -c 'Geometry action is cycling' <<<"$log")
  iterations=$(grep -c 'has continued for 300 iterations' <<<"$log")
  local crashed=0
  [ "$mode" != none ] && [ "$alive" = 0 ] && crashed=1
  local coverage=""
  if [ "$mode" = real ]; then
    local files rows
    files=$(find "$lib/agents/pi/sessions" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
    rows=$(sqlite3 "$lib/cuepad.db" 'select count(*) from piSessions;' 2>/dev/null || echo 0)
    coverage="  Pi 会话文件 $files  应用历史 $rows"
    if [ "$files" -lt $((rounds / 2)) ] || [ "$rows" -lt 1 ]; then coverage="${coverage}（没覆盖到）"; failed=1; fi
  fi
  local ending=进程正常
  if [ "$crashed" = 1 ]; then
    if [ "$status" -gt 128 ]; then ending="进程中途退出（信号 SIG$(kill -l $((status - 128)))）"; else ending="进程中途退出（退出码 $status）"; fi
  fi
  echo "${name}：几何循环 $cycles  布局迭代超限 $iterations  $ending$coverage"
  if [ "$crashed" = 1 ]; then failed=1
  elif [ ${#inject[@]} -gt 0 ]; then [ "$cycles" -gt 0 ] || { echo "  没抓到注入的环"; failed=1; }
  elif [ "$cycles" -gt 0 ] || [ "$iterations" -gt 0 ]; then failed=1; fi
  [ -f "$lib/agents/pi/pi-stderr.log" ] && cp "$lib/agents/pi/pi-stderr.log" "/tmp/layout-stress-pi-$(date +%s).log"
  if [ "$crashed" = 1 ]; then
    # 留证：隔离库（资料库、Pi 目录）原样不删，这段进程的系统日志写进去
    printf '%s\n' "$log" > "$lib/process.log"
    echo "  证据留在 ${lib}（资料库与 Pi 目录；进程日志 process.log）"
  else
    rm -rf "$lib"
  fi
}

run "Pi 轮换·屏幕外最小窗口" error 40 -CuePadWindowSize 720x520 -CuePadOffscreen YES
run "Pi 轮换·1280×907" all 40 -CuePadWindowSize 1280x907
run "边加卡边拉宽·常驻滚动条" none 0 -CuePadWindowSize 1000x800 -AppleShowScrollBars Always -CuePadBench churn
if [ -x ~/.local/bin/pi ]; then
  run "真实 Pi 结束/新建·屏幕外" real 24 -CuePadWindowSize 1280x907 -CuePadOffscreen YES
  run "真实 Pi 结束/新建·最小窗口" real 24 -CuePadWindowSize 720x520
else
  echo "本机没有 ~/.local/bin/pi，跳过真实 Pi 组"
fi
exit $failed
