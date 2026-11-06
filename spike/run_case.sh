#!/bin/bash
# 起一次隔离实例跑网页预览原型，等页面就绪后改文件量 HMR，把这次的日志切出来并出报告。
# 用法：run_case.sh <标签> <hmr 轮数> -- <传给 App 的启动参数…>
set -u
label=$1; rounds=$2; shift 3
S=/tmp/cuepad-fsm/preview-spike; W=$(cd "$(dirname "$0")/.." && pwd); L=$W/apple/.derived/app-sim.log
before=$(wc -l < "$L" 2>/dev/null || echo 0)
"$W/apple/scripts/xc.sh" run ios -- -CuePadScene livepreview "$@" > "$S/run-$label.log" 2>&1 || { echo "xc.sh run 失败"; tail -5 "$S/run-$label.log"; exit 1; }
timeout 120 bash -c "until tail -n +$((before+1)) '$L' | grep -q suite-done; do sleep 1; done" || echo "等 suite-done 超时"
[ "$rounds" -gt 0 ] && "$W/spike/hmr_drive.py" "$S/vite-app" "$rounds" 1.5 > "$S/edits-$label.log"
sleep 1
tail -n +$((before+1)) "$L" | grep -E "^(LP|CT) " > "$S/app-$label.log"
grep -E "load-start|nav-finish|case-result|reload|iroh|CT " "$S/app-$label.log" | cut -c1-220
[ "$rounds" -gt 0 ] && "$W/spike/hmr_report.py" "$S/edits-$label.log" "$S/app-$label.log"
exit 0
