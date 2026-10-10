#!/usr/bin/env bash
# 用法：perf-ios.sh [次数=3]
#   iPhone 模拟器上的单次交互（-CuePadBench interact，`IOSInteractionBench`）：演示库，每次全新进程，逐项量点击回合、合计、最重一圈
#   （主线程 CPU 毫秒）、进程指令数（百万条）与掉帧，按"第几次"分开取各次的中位数列成表。
#   模拟器的合成与 GPU 和真机不同：只看主线程 CPU 与指令数，掉帧只作参考；第一次的数里有模拟器才有的 Swift 一致性查找，真机要另量。
# 用 Release（带 DEBUG 条件，只为留下测量代码）；设备是 CUEPAD_IOS_DEVICE（默认 iPhone 17），产物在 ${CUEPAD_DERIVED:-apple/.derived}-perf-ios。
set -euo pipefail

APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
runs="${1:-3}"
DERIVED="${CUEPAD_DERIVED:-$APPLE_DIR/.derived}-perf-ios"
DEVICE="${CUEPAD_IOS_DEVICE:-iPhone 17}"
BUNDLE_ID=com.sugeh.cuepad

mkdir -p "$DERIVED"
[ -f "$DERIVED/.gitignore" ] || echo '*' > "$DERIVED/.gitignore"
xcodebuild -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad -configuration Release \
  -destination "platform=iOS Simulator,name=$DEVICE" -derivedDataPath "$DERIVED" -quiet build \
  DEVELOPMENT_TEAM= CODE_SIGN_IDENTITY=- 'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) DEBUG' \
  >"$DERIVED/build.log" 2>&1 || { tail -30 "$DERIVED/build.log" >&2; exit 1; }

booted_here=0
xcrun simctl list devices booted | grep -qF "$DEVICE (" || { xcrun simctl boot "$DEVICE"; booted_here=1; }
xcrun simctl bootstatus "$DEVICE" -b >/dev/null
xcrun simctl install "$DEVICE" "$DERIVED/Build/Products/Release-iphonesimulator/CuePad.app"

running() { local list; list="$(xcrun simctl spawn "$DEVICE" launchctl list 2>/dev/null)"; [[ "$list" == *"UIKitApplication:$BUNDLE_ID"* ]]; }
rows="$DERIVED/interact.jsonl"
: >"$rows"
for run in $(seq "$runs"); do
  library="$DERIVED/library-$run"
  rm -rf "$library"
  SIMCTL_CHILD_CUEPAD_LIBRARY_DIR="$library" xcrun simctl launch "$DEVICE" "$BUNDLE_ID" -CuePadDemo YES -CuePadBench interact >/dev/null
  sleep 2
  # 量完自己退出；最多等 4 分钟
  for _ in $(seq 240); do running || break; sleep 1; done
  sed -n "s/^INTERACT {/{\"run\":$run,/p" "$library/interact.jsonl" >>"$rows"
done
[ "$booted_here" = 0 ] || xcrun simctl shutdown "$DEVICE"

python3 - "$rows" <<'PY'
import json, sys, statistics
rows, order, seen = {}, [], {}
for line in open(sys.argv[1]):
    r = json.loads(line)
    key = (r["run"], r["name"]); seen[key] = seen.get(key, 0) + 1
    k = (r["name"], seen[key])
    if k not in rows: order.append(k)
    rows.setdefault(k, []).append(r)
print("交互\t第几次\t点击回合ms\t合计ms\t最重一圈ms\t指令百万\t掉帧")
for k in order:
    m = lambda f: statistics.median(r[f] for r in rows[k])
    print(f"{k[0]}\t{k[1]}\t{m('clickMs'):.1f}\t{m('totalMs'):.1f}\t{m('maxTurnMs'):.1f}\t{m('minstr'):.0f}\t{m('hitches'):.0f}")
PY
