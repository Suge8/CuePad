# shellcheck shell=bash
# xc.sh 的入口锁，三条规则：
# 1. 同一检出一次一个任务（<检出>/apple/.derived/xc.lock）：同一产物目录上的两个 xcodebuild 会抢构建数据库、互相覆盖产物。
#    不同检出之间不设上限：实测同时 9 个增量编译测试，不排队比限 3 个快（链接、签名、起测试宿主时 CPU 空着，并发正好填上）。
# 2. 只有前台、和交互预算比的 Mac 测量（xc.sh perf mac … -CuePadForeground YES）独占机器：普通任务持运行目录（app_env.py 的 RUNTIME）里 machine 的共享锁，
#    它要独占锁，并先占闸门（gate）让后来的普通任务停在门外，不被源源不断的新任务饿死。别的测量只比指令数，不独占。
# 3. iOS 的测试、截图、录屏从固定的 SIM_POOL 台模拟器里领一台（每台一把锁，见 _sim.sh），全占着就等空出一台。
#    先领模拟器再进 machine：排队等模拟器的任务不占着机器（曾经占着，测量就跟着整条模拟器队列一起等）。
# 锁都是 flock，只由这里的入口进程持有（Python 打开的文件不传给子进程），它退出时内核释放，崩了也不留死锁。持有者把 CUEPAD_SIM=<模拟器号，没领为空> 传给子进程，
# 脚本再调脚本不重复进锁。任务最多跑 HOLD_LIMIT 秒，超了连同它起的全部进程结束，防止卡死的任务一直占着。
# 谁拿着锁记在运行目录的 holders/<PID>.json（PID、检出、完整命令行、持有的每把锁与真正拿到它的时刻、在等的锁），入口退出时删掉；
# 被 KILL 留下的、PID 已不是那个进程的，读的人当场清掉。排队时开头与每 LOCK_REPORT 秒列一次持有者：每把锁持有了多久（不含排队），命令截成一行，
# 停住的进程标出来（它不受时限管）；
# 等满 LOCK_WAIT 秒还没轮到就列出持有者、以 75 退出，不静默挂着。
# 用法：xc_enter <plain|sim|exclusive> <命令…>，在锁里 exec 这条命令（通常是 "$0" "$@"）；exclusive 只给前台的 Mac 交互测量。
# 拿锁、登记、守时限的是 _lock.py，这里只放常量与入口。

SIM_POOL=3
HOLD_LIMIT=1800
LOCK_REPORT=30
# 前面的任务都受 HOLD_LIMIT 管，正常排队等不过一个任务的时限（另留收尾的余量）；超过它，是前面有停住的进程、
# 或排着不止一件长任务，报出来让人处理。等得起更久的给 CUEPAD_LOCK_WAIT=<秒>
LOCK_WAIT=${CUEPAD_LOCK_WAIT:-$((HOLD_LIMIT + 300))}

xc_enter() {
  [ -z "${CUEPAD_SIM+set}" ] || return 0
  # 独占期间所有检出的新任务都停在闸门外：别的脚本借它（实测有借来录一批屏的）就挡住所有人
  if [ "$1" = exclusive ] && [ "${2##*/}" != perf-mac.sh ]; then
    echo "独占机器只给前台和预算比的交互测量（xc.sh perf mac … -CuePadForeground YES）；录屏、截图与别的测量照普通任务跑，前后对比看指令数" >&2
    exit 2
  fi
  exec python3 "$APPLE_DIR/scripts/_lock.py" "$HOLD_LIMIT" "$LOCK_WAIT" "$LOCK_REPORT" "$SIM_POOL" "$@"
}
