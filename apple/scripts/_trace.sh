# shellcheck shell=bash
# 被 perf-mac.sh、perf-launch.sh source：CUEPAD_TRACE=<xctrace 模板> 时按 PID 录 trace。App 带 -CuePadTraceWait YES 起，写一行 AWAIT trace <PID> 停着等
# （Probes.swift 的 waitForTracer）；trace_attach 开录后发 SIGUSR1 放它往下走，没开录成（输出里没有 Starting recording）就结束它，这一次算没量完。
# xctrace 报 Starting recording 后采样还要一会儿才真的开始（实测头 0.47 秒没有样本），没有别的信号可等：停 TRACE_WARMUP 秒再放行。
TRACE_WARMUP=1

# trace_attach <PID> <trace 路径>：录到那个进程退出，xctrace 的输出在同名 .log
trace_attach() {
  local pid="$1" trace="$2"
  xcrun xctrace record --template "$CUEPAD_TRACE" --attach "$pid" --output "$trace" 2>&1 | tee "$trace.log" | {
    if grep -q 'Starting recording'; then sleep "$TRACE_WARMUP"; kill -USR1 "$pid"; else echo "xctrace 没开录，见 $trace.log" >&2; kill -TERM "$pid"; fi
    cat >/dev/null
  }
}
