# shellcheck shell=bash
# xc.sh 的入口锁，两条规则：
# 1. 同一检出一次一个任务（<检出>/apple/.derived/xc.lock）：同一产物目录上的两个 xcodebuild 会抢构建数据库、互相覆盖产物。
#    不同检出之间不设上限：实测同时 9 个增量编译测试，不排队比限 3 个快（链接、签名、起测试宿主时 CPU 空着，并发正好填上）。
#    前台的 Mac 测量（perf mac … -CuePadForeground YES）也照普通任务跑：整机独占要先关闸门排空在跑的任务（实测每次 10–18 分钟），挡住所有检出的新任务，得不偿失。
#    机器忙时帧与回合时长不可比，perf 结束的用时行带着 1 分钟负载（高于核数就只比指令数）。
# 2. iOS 的测试、截图、录屏、测量从全机共 SIM_SLOTS 个槽位里领一个（每个槽位一把锁，见 _sim.sh），全占着就等空出一个。
#    每个槽位同一时刻最多开着一台"CuePad <机型> #<槽位号>"：换机型时先关掉这个槽位上别的机型的；领槽位时先挑已开着这一机型的，少重开机。
#    机型再多，全机开着的 CuePad 模拟器也不超过 SIM_SLOTS 台（按机型各开一池、不关时，实测同时开了 16 台、交换区满）。
# 锁都是 flock，只由这里的入口进程持有（Python 打开的文件不传给子进程），它退出时内核释放，崩了也不留死锁。持有者把 CUEPAD_SIM=<槽位号，没领为空> 传给子进程，
# 脚本再调脚本不重复进锁。任务最多跑 HOLD_LIMIT 秒，超了连同它起的全部进程结束，防止卡死的任务一直占着。
# 谁拿着锁记在运行目录（app_env.py 的 RUNTIME）的 holders/<PID>.json（PID、检出、完整命令行、持有的每把锁与真正拿到它的时刻、在等的锁），入口退出时删掉；
# 被 KILL 留下的、PID 已不是那个进程的，读的人当场清掉。排队时开头与每 LOCK_REPORT 秒列一次持有者：每把锁持有了多久（不含排队），命令截成一行，
# 停住的进程标出来（它不受时限管）；
# 等满 LOCK_WAIT 秒还没轮到就列出持有者、以 75 退出，不静默挂着。
# 任务结束时入口往 stderr 打一行用时：排队、命令自己量的段、其余（测试、实例、没单列的开机），加 1 分钟负载。命令量段用 phase <名> <命令…>：
# 跑命令、把用时记给入口（环境变量 CUEPAD_PHASES 指的文件），退出码照传。
# 用法：xc_enter <机型，不要模拟器给空串> <命令…>，在锁里 exec 这条命令（通常是 "$0" "$@"）。
# 拿锁、登记、守时限、打用时的是 _lock.py，这里只放常量与入口。

SIM_SLOTS=4
# 任务时限从测试时限推出：一个测试最长跑 TEST_TIME_LIMIT 秒（正常的几秒内跑完，最慢的也不到一分钟；挂住的曾让测试宿主停了 34 分钟没人发现），
# 任务要装得下它加编译与起宿主的余量；评测给 CUEPAD_TEST_TIME_LIMIT=3600 时，任务时限跟着变大，不会在测试时限之前被锁杀掉
TEST_TIME_LIMIT=${CUEPAD_TEST_TIME_LIMIT:-120}
HOLD_LIMIT=$((TEST_TIME_LIMIT + 600 > 1800 ? TEST_TIME_LIMIT + 600 : 1800))
LOCK_REPORT=30
# 前面的任务都受 HOLD_LIMIT 管，正常排队等不过一个任务的时限（另留收尾的余量）；超过它，是前面有停住的进程、
# 或排着不止一件长任务，报出来让人处理。等得起更久的给 CUEPAD_LOCK_WAIT=<秒>
LOCK_WAIT=${CUEPAD_LOCK_WAIT:-$((HOLD_LIMIT + 300))}

# 不用 || 接退出码：那会让函数体里的 set -e 失效（sim_boot 这类靠它半路停下）。失败又没人接着时脚本照 set -e 退出，这一段不记，进"其余"
phase() {
  local name="$1" began=$SECONDS; shift
  "$@"
  local status=$?
  echo "$name $((SECONDS - began))" >>"${CUEPAD_PHASES:-/dev/null}"
  return $status
}

xc_enter() {
  [ -z "${CUEPAD_SIM+set}" ] || return 0
  local model="$1"; shift
  exec python3 "$APPLE_DIR/scripts/_lock.py" "$HOLD_LIMIT" "$LOCK_WAIT" "$LOCK_REPORT" "$SIM_SLOTS" "$model" "$@"
}
