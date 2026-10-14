# shellcheck shell=bash
# 被 xc.sh 与 perf-ios.sh source：每个槽位（_slot.sh）每种机型一台固定的模拟器，名为"CuePad <机型> #<槽号>"，
# 第一次用时新建，开机后一直开着给后来的任务复用（脚本不关）：冷启动一次要 15–30 秒。
# 开机时停用系统的 PosterBoard（管壁纸与锁屏海报）：iOS 27.0 模拟器里它的海报库会坏，之后每次开机都反复崩溃，
# 每崩一次 Mac 上弹一个"PosterBoard 意外退出"；开关机越频繁越容易坏。App 的截图与测试用不到它，停用后桌面与 App 照常。

# sim_udid <机型>：输出本槽这台设备的 UDID，没有就建（只建不开机）。
sim_udid() {
  local name="CuePad $1 #$CUEPAD_SLOT" udid
  udid="$(xcrun simctl list devices -j | jq -r --arg n "$name" 'first(.devices[][] | select(.name == $n and .isAvailable) | .udid) // empty')"
  [ -n "$udid" ] || udid="$(xcrun simctl create "$name" "$1")"
  echo "$udid"
}

# sim_boot <UDID>：没开机就开机、等系统起好，并停用 PosterBoard（停用记在设备里，以后开机都不再起它）。
sim_boot() {
  [ "$(xcrun simctl list devices -j | jq -r --arg u "$1" '.devices[][] | select(.udid == $u) | .state')" != Booted ] || return 0
  xcrun simctl bootstatus "$1" -b >/dev/null
  local service="user/$UID/com.apple.PosterBoard"
  xcrun simctl spawn "$1" launchctl disable "$service"
  # 新设备第一次开机时它已经起来了：停掉这一个；之后的开机它本就不起，bootout 报"没有这个服务"
  xcrun simctl spawn "$1" launchctl bootout "$service" 2>/dev/null || true
}
