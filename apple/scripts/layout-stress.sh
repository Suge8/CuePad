#!/usr/bin/env bash
# 布局反馈环压力场景：对一个 CuePad.app 跑三组隔离实例，任何一组出现布局循环或崩溃就以 1 退出。
#   1. 屏幕外最小窗口，Pi 会话快速结束/新建并在"思考中/出错"之间跳（挑刺官第 2 轮崩溃前的情形）
#   2. 1280×907 窗口，Pi 会话全状态快速轮换
#   3. 常驻滚动条下边加卡边逐点拉宽窗口（-CuePadBench churn）
#   4. 本机有真实 pi（~/.local/bin/pi）时：真实 Pi 会话"发提示词 → 出错/完成 → 开新会话 → 立刻再发"，会话文件真实落盘
#      （挑刺官第 2 轮崩溃前的操作）；并断言这条路径确实走到了：Pi 写出的会话文件不少于轮数的三分之一、应用历史里至少有一条，
#      否则判为"没覆盖到"，同样以 1 退出
# 判定依据是该进程的系统日志："Geometry action is cycling"（SwiftUI 几何回调来回翻转）与
# "has continued for 300 iterations"（AppKit 布局迭代超限，随后抛异常退出）。需要 DEBUG 条件编译的构建（调试场景参数）。
# 用法：scripts/layout-stress.sh [CuePad.app]（缺省 $CUEPAD_DERIVED/Build/Products/Debug/CuePad.app）
set -u
APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-${CUEPAD_DERIVED:-$APPLE_DIR/.derived}/Build/Products/Debug/CuePad.app}"
failed=0

run() { # 名称 Pi模式(none/all/error/real) 轮数 启动参数…
  local name=$1 mode=$2 rounds=$3; shift 3
  local lib sock start pid alive
  lib="$(mktemp -d /tmp/cuepad-stress.XXXXXX)"; sock="$(mktemp -d /tmp/cps.XXXXXX)"; chmod 700 "$sock"
  start="$(date "+%Y-%m-%d %H:%M:%S")"
  CUEPAD_LIBRARY_DIR="$lib" PI_CODING_AGENT_DIR="$lib/pi-agent" CUEPAD_PI_SOCKET_DIR="$sock" "$app/Contents/MacOS/CuePad" \
    -CuePadDemo YES -CuePadProject CuePad -piExtensionDeclinedVersion '<integer>99</integer>' "$@" >/dev/null 2>&1 &
  pid=$!
  if [ "$mode" = none ]; then
    wait "$pid"
  elif [ "$mode" = real ]; then
    sleep 3
    python3 "$APPLE_DIR/scripts/pi-real-churn.py" "$lib/pi-agent" "$sock" ~/Project/cuepad "$rounds" || echo "  真实 pi 提前退出，按已跑的轮数判定覆盖"
  else
    sleep 3
    python3 "$APPLE_DIR/scripts/pi-churn.py" "$sock" "$rounds" "$mode"
  fi
  if kill -0 "$pid" 2>/dev/null; then alive=1; kill -TERM "$pid"; sleep 2; kill -9 "$pid" 2>/dev/null; else alive=0; fi
  sleep 1
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
    if [ "$files" -lt $((rounds / 3)) ] || [ "$rows" -lt 1 ]; then coverage="$coverage（没覆盖到）"; failed=1; fi
  fi
  echo "${name}：几何循环 $cycles  布局迭代超限 $iterations  $([ $crashed = 1 ] && echo 进程中途退出 || echo 进程正常)$coverage"
  if [ "$cycles" -gt 0 ] || [ "$iterations" -gt 0 ] || [ "$crashed" = 1 ]; then failed=1; fi
  rm -rf "$lib" "$sock"
}

run "Pi 轮换·屏幕外最小窗口" error 40 -CuePadWindowSize 720x520 -CuePadWindowOrigin -3000,-3000
run "Pi 轮换·1280×907" all 40 -CuePadWindowSize 1280x907
run "边加卡边拉宽·常驻滚动条" none 0 -CuePadWindowSize 1000x800 -AppleShowScrollBars Always -CuePadBench churn
if [ -x ~/.local/bin/pi ]; then
  run "真实 Pi 结束/新建·屏幕外" real 24 -CuePadWindowSize 1280x907 -CuePadWindowOrigin -3000,-3000
  run "真实 Pi 结束/新建·最小窗口" real 24 -CuePadWindowSize 720x520
else
  echo "本机没有 ~/.local/bin/pi，跳过真实 Pi 组"
fi
exit $failed
