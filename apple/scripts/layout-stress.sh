#!/usr/bin/env bash
# 布局反馈环压力场景：对一个 CuePad.app 跑三组隔离实例，任何一组出现布局循环或崩溃就以 1 退出。
#   1. 屏幕外最小窗口，Pi 会话快速结束/新建并在"思考中/出错"之间跳
#   2. 1280×907 窗口，Pi 会话全状态快速轮换
#   3. 常驻滚动条下边加卡边逐点拉宽窗口（-CuePadBench churn）
#   4. 本机有真实 pi（~/.local/bin/pi）时：真实 Pi 会话"发提示词 → 出错/完成 → 开新会话 → 立刻再发"，会话文件真实落盘；并断言这条路径确实走到了：Pi 写出的会话文件不少于轮数的一半、应用历史里至少有一条，
#      否则判为"没覆盖到"，同样以 1 退出
# 判定依据是该进程的系统日志："Geometry action is cycling"（SwiftUI 几何回调来回翻转）与
# "has continued for 300 iterations"（AppKit 布局迭代超限，随后抛异常退出）。需要 DEBUG 条件编译的构建（调试场景参数）。
# 用法：scripts/layout-stress.sh [--inject-loop] [CuePad.app]（缺省 $CUEPAD_DERIVED/Build/Products/Debug/CuePad.app）
# 某组进程中途退出时报出退出码或终止信号，并保留它的隔离库目录（资料库、Pi 目录、这段进程的系统日志 process.log），打印路径不删。
# --inject-loop：每组都挂上刻意的几何回写环（-CuePadGeometryLoop YES），检测器有效时脚本必须以 1 退出——用来证明它抓得到这类环。
set -u
APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
inject=()
if [ "${1:-}" = --inject-loop ]; then inject=(-CuePadGeometryLoop YES); shift; fi
app="${1:-${CUEPAD_DERIVED:-$APPLE_DIR/.derived}/Build/Products/Debug/CuePad.app}"
failed=0
# 假 Pi 会话的工作目录取演示库 CuePad 项目绑定的目录（从 Debug/DemoLibrary.swift 读，不另存一份），会话由此归到该项目；
# 真实 pi 要求目录存在，用仓库根
DEMO_DIR="$HOME/$(sed -n 's/.*name: "CuePad".*directory: "\\(home)\([^"]*\)".*/\1/p' "$APPLE_DIR/App/Sources/UI/Debug/DemoLibrary.swift")"
REAL_DIR="$(cd "$APPLE_DIR/.." && pwd)"
READY_TIMEOUT="${CUEPAD_STRESS_READY_TIMEOUT:-60}" # 等资料库文件出现的秒数上限

run() { # 名称 Pi模式(none/all/error/real) 轮数 启动参数…
  local name=$1 mode=$2 rounds=$3; shift 3
  local lib sock start pid alive
  lib="$(mktemp -d /tmp/cuepad-stress.XXXXXX)"; sock="$(mktemp -d /tmp/cps.XXXXXX)"; chmod 700 "$sock"
  start="$(date "+%Y-%m-%d %H:%M:%S")"
  CUEPAD_LIBRARY_DIR="$lib" PI_CODING_AGENT_DIR="$lib/pi-agent" CUEPAD_PI_SOCKET_DIR="$sock" "$app/Contents/MacOS/CuePad" \
    -CuePadDemo YES -CuePadProject CuePad ${inject[@]+"${inject[@]}"} "$@" >/dev/null 2>&1 &
  pid=$!
  if [ "$mode" != none ]; then
    # 资料库文件出现即 App 已起来
    local waited=0
    until [ -f "$lib/cuepad.db" ] || ! kill -0 "$pid" 2>/dev/null; do
      if [ "$waited" -ge $((READY_TIMEOUT * 10)) ]; then
        echo "${name}：$READY_TIMEOUT 秒内没有出现资料库文件，App 进程仍存活（未响应启动）" >&2
        kill -9 "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        echo "  证据留在 ${lib}" >&2; rm -rf "$sock"; failed=1; return
      fi
      sleep 0.1; waited=$((waited + 1))
    done
  fi
  if [ "$mode" = none ]; then
    wait "$pid"
  elif [ "$mode" = real ]; then
    python3 "$APPLE_DIR/scripts/pi-real-churn.py" "$lib/pi-agent" "$sock" "$REAL_DIR" "$rounds" || echo "  真实 pi 提前退出，按已跑的轮数判定覆盖"
  else
    python3 "$APPLE_DIR/scripts/pi-churn.py" "$sock" "$DEMO_DIR" "$rounds" "$mode"
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
    files=$(find "$lib/pi-agent/sessions" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
    rows=$(sqlite3 "$lib/cuepad.db" 'select count(*) from piSessions;' 2>/dev/null || echo 0)
    coverage="  Pi 会话文件 $files  应用历史 $rows"
    if [ "$files" -lt $((rounds / 2)) ] || [ "$rows" -lt 1 ]; then coverage="${coverage}（没覆盖到）"; failed=1; fi
  fi
  local ending=进程正常
  if [ "$crashed" = 1 ]; then
    if [ "$status" -gt 128 ]; then ending="进程中途退出（信号 SIG$(kill -l $((status - 128)))）"; else ending="进程中途退出（退出码 $status）"; fi
  fi
  echo "${name}：几何循环 $cycles  布局迭代超限 $iterations  $ending$coverage"
  if [ "$cycles" -gt 0 ] || [ "$iterations" -gt 0 ] || [ "$crashed" = 1 ]; then failed=1; fi
  [ -f "$lib/pi-agent/pi-stderr.log" ] && cp "$lib/pi-agent/pi-stderr.log" "/tmp/layout-stress-pi-$(date +%s).log"
  if [ "$crashed" = 1 ]; then
    # 留证：隔离库（资料库、Pi 目录）原样不删，这段进程的系统日志写进去
    printf '%s\n' "$log" > "$lib/process.log"
    echo "  证据留在 ${lib}（资料库与 Pi 目录；进程日志 process.log）"
    rm -rf "$sock"
  else
    rm -rf "$lib" "$sock"
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
