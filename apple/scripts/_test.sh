# shellcheck shell=bash
# 被 xc.sh source：`xc.sh test <mac|ios|ipad|kit> [xcodebuild 参数…]` 的全部（编译、跑、过滤输出、收尾结论）。
# 用到 xc.sh 的 APPLE_DIR、DERIVED、platform、destination、device、TEST_TIME_LIMIT（调用时才读）；参数原样是 xc.sh 的 "$@"。
# 退出码是 xcodebuild 的（exit，不返回）。
xc_test() {
  # 用例断言的是中文界面：不随跑测试那台机器的系统语言变
  limits=(-test-timeouts-enabled YES -maximum-test-execution-time-allowance "$TEST_TIME_LIMIT" -testLanguage zh-Hans -testRegion CN)
  # 先开好领到的模拟器（并瘦身，见 _sim.sh），xcodebuild 就用开着的这台。
  # 再卸掉上一次装的 App：它开着的实时活动在重装时被系统结束，系统随即把 App 叫到后台（不带测试的环境），
  # 正撞上测试宿主的启动，测试进程就连不上（"The test runner hung before establishing connection"）。卸掉时活动一起没了，没有这一下
  if [ -n "${device:-}" ]; then phase 开机 sim_boot "$device"; xcrun simctl uninstall "$device" "$CUEPAD_APP_ID"; fi
  # 屏幕上只留编译的警告与错误、失败的用例（带原因）与汇总：编译的每一步、App 与测试宿主的日志、每条用例的开始与通过一次就是几千行，
  # 会把失败挤出 Agent 的输出上限。所以先 -quiet 编（只出警告与错误），再不带 -quiet 跑（-quiet 连失败的原因也吞掉），跑的输出滤掉上面那些；
  # 完整输出写进 log
  log="$DERIVED/test.log"; : >"$log"; echo "完整输出（含 App 日志）：$log" >&2
  zwsp="$(printf '\342\200\213')"  # Swift Testing 在部分行首加零宽空格
  # 噪音：开始与通过的逐条记录（留着「✔ Test run with」汇总与失败）、跳过（汇总里按原因列）、XCTest 的空汇总（Executed 0 tests 只数 XCTest，Swift Testing 的在汇总里）、Xcode 与系统的杂讯
  noise="^($zwsp)*(➜ |↳ (Testing Library Version|Target Platform)|✔ Suite .* passed after|✔ Test ([^ (]+\\(|\").* passed after)|^Test (Case|Suite) .* (started|passed)|^[[:space:]]+Executed [0-9]+ tests?, with 0 failures"
  noise+='|DVTAssertions|IDETestOperationsObserverDebug|IDERunDestination|^(Details|Object|Method|Thread): |^Please file a bug|^\{ platform:|^--- xcodebuild: WARNING: Using the first|^CoreGraphics PDF has logged'
  noise+='|^Testing started$|^(Command line invocation|Build settings from command line|Resolve Package Graph|Resolved source packages)|^    (/Applications/|[A-Z_]+ = )|^  (CuePadKit|SparkleBinary): '
  # 多行的记录：日志记录以时间戳起头（SQLite 报错带多行语句、WebKit 的 XPC 沙箱报错），Swift Testing 的「◇ Test case passing … started」带着多行的参数值
  # （XCTestOutputBarrier 还会把它们的行首切碎，所以「◇ Test」不限行首）。后续行没有记号，跟着记录头一起丢，丢到下一条别的输出起头
  head="^($zwsp)*[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9:.]+[+-][0-9]{4} [^ ]+\\[[0-9]+:[0-9a-f]+\\] |◇ (Test|Suite) "
  start="^($zwsp)*(◇|✔|✘|↳|➜|Test |Testing |/|\\*\\*|Failing tests|[0-9]{4}-)"
  shown() {
    # 正则走环境变量：awk -v 会再解一遍反斜杠
    tee -a "$log" | NOISE="$noise" HEAD="$head" START="$start" awk '
      BEGIN { noise = ENVIRON["NOISE"]; head = ENVIRON["HEAD"]; start = ENVIRON["START"] }
      NF == 0 { next }
      $0 ~ start { dropping = 0 }
      $0 ~ head { dropping = 1; next }
      $0 ~ noise || dropping { next }
      { print; fflush() }'
  }
  # 编译只认收窄参数（只编要跑的测试目标）；-test-iterations 这类只给跑的那一步
  narrowed() { local a; for a in "$@"; do case "$a" in -only-testing:*|-skip-testing:*) printf '%s\0' "$a" ;; esac; done; }
  kit_test() {
    local narrow=(); while IFS= read -r -d '' a; do narrow+=("$a"); done < <(narrowed "$@")
    (cd "$APPLE_DIR/CuePadKit" && built "$DERIVED/kit-$platform/build-key" "$DERIVED/kit-$platform/Build/Products" "${narrow[*]:-all}" xcodebuild -quiet build-for-testing -scheme CuePadKit-Package -destination "$destination" -derivedDataPath "$DERIVED/kit-$platform" ${compile_cache[@]+"${compile_cache[@]}"} ${narrow[@]+"${narrow[@]}"} 2>&1 \
      && xcodebuild test-without-building -scheme CuePadKit-Package -destination "$destination" -derivedDataPath "$DERIVED/kit-$platform" "${limits[@]}" "$@" 2>&1) \
      | { grep --line-buffered -v 'failed with exit code 0 but produced no further output' || true; }
  }
  # iOS/iPad：同一个入口也在模拟器上跑 CuePadKit 的测试（iOS 编辑器等只在这里跑；macOS 上的 Kit 测试是 test kit）。
  # 带了收窄参数（-only-testing 等）时只跑 App 那部分；两部分都跑完再按其一失败退出。
  # 点名真 Agent 的套件或用例时跑全量档：冒烟档会把点名的跳过（RealAgents.swift）
  if [[ " ${*:3}" == *" -only-testing:CuePiTests/Real"* ]]; then export TEST_RUNNER_CUEPAD_AGENT_TESTS="${TEST_RUNNER_CUEPAD_AGENT_TESTS:-all}"; fi
  status=0
  if [ "$platform" = kit ]; then
    kit_test "${@:3}" | shown || status=$?
  else
    narrow=(); while IFS= read -r -d '' a; do narrow+=("$a"); done < <(narrowed "${@:3}")
    { xcd "${narrow[*]:-all}" ${narrow[@]+"${narrow[@]}"} && xcb test-without-building "${limits[@]}" "${@:3}"; } | shown || status=$?
    if [ "$platform" != mac ] && [ "$#" -le 2 ]; then kit_test | shown || status=$?; fi
  fi
  # 点名的测试一个也没对上（名字或所在的 Suite 写错）时 xcodebuild 照样报成功。并行跑（-parallel-testing-enabled YES）时没有那两行汇总，
  # 只有每条用例一行 Test case '…' passed/failed on '…'
  if [[ " ${*:3}" == *" -only-testing:"* ]] && ! grep -aqE 'Test run with [1-9]|Executed [1-9][0-9]* tests?,|^Test case .* (passed|failed) on ' "$log"; then
    echo "-only-testing 一个测试也没对上：Swift Testing 写 <测试目标>/<Suite 类型名>/<函数名>()，用例所在的类型以源码为准" >&2
    status=1
  fi
  python3 -I "$APPLE_DIR/scripts/test_summary.py" "$log" "$status" || echo "test_summary.py 出错了，上面的输出和退出码照旧有效" >&2
  exit $status
}
