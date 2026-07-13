#!/bin/zsh
# WDIO 经 launchctl bootstrap 启动测试 bundle：LaunchAgent 的 TCC 责任进程是
# CuePad 自身（legacy submit / open / spawn 均归责本会话宿主终端并继承其
# 辅助功能信任），只有这条路径能测到真实 AXIsProcessTrusted() == false。
set -eu

root=${0:A:h:h}
binary="$root/src-tauri/target/debug/bundle/macos/CuePad.app/Contents/MacOS/cuepad"

# 并发串行化由 run.zsh 的全管线锁保证（同锁文件在此再加锁会死锁）
label="com.sugeh.cuepad.wdio.$TAURI_WEBDRIVER_PORT"
plist="/tmp/$label.plist"
uid=$(id -u)
waiter=

cleanup() {
  launchctl bootout "gui/$uid/$label" 2>/dev/null || true
  if [[ -n "$waiter" ]]; then kill "$waiter" 2>/dev/null || true; fi
  rm -f "$plist"
}
trap cleanup EXIT INT TERM HUP

cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$binary</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>TAURI_WEBDRIVER_PORT</key><string>$TAURI_WEBDRIVER_PORT</string>
    <key>WDIO_EMBEDDED_SERVER</key><string>true</string>
  </dict>
  <key>RunAtLoad</key><true/>
</dict></plist>
EOF

# 防幽灵：残留测试实例占着端口会让 service 连上错误责任链的进程。
# 只清理能确认是本测试 bundle 的进程；未知占用者明确报错，绝不盲杀。
stale=$(lsof -nP -tiTCP:$TAURI_WEBDRIVER_PORT -sTCP:LISTEN 2>/dev/null || true)
for pid in ${(f)stale}; do
  if [[ "$(ps -o comm= -p $pid 2>/dev/null)" == "$binary" ]]; then
    kill "$pid" 2>/dev/null || true
    sleep 1
  else
    print -u2 "port $TAURI_WEBDRIVER_PORT is held by non-test process $pid; aborting"
    exit 1
  fi
done

launchctl bootout "gui/$uid/$label" 2>/dev/null || true
launchctl bootstrap "gui/$uid" "$plist"

tail -f /dev/null &
waiter=$!
wait "$waiter"
