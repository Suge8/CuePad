# shellcheck shell=bash
# 被 xc.sh 与 perf-ios.sh source：每个产物目录一台自己的模拟器，名为"CuePad <机型> @ <产物目录>"，第一次按机型新建、之后复用。
# 并行的多路各用各的 CUEPAD_DERIVED，就各有各的设备：不排队、不抢同一台，也不碰用户自己开着的模拟器。

# sim_udid <产物目录> <机型>：输出这台设备的 UDID，没有就建（只建不启动）。
sim_udid() {
  local name="CuePad $2 @ $1" udid
  udid="$(xcrun simctl list devices -j | jq -r --arg n "$name" 'first(.devices[][] | select(.name == $n and .isAvailable) | .udid) // empty')"
  [ -n "$udid" ] || udid="$(xcrun simctl create "$name" "$2")"
  echo "$udid"
}

sim_state() { xcrun simctl list devices -j | jq -r --arg u "$1" '.devices[][] | select(.udid == $u) | .state'; }

# 删掉产物目录已不存在、或运行时已卸载的那些设备；别的模拟器不动。
sim_clean() {
  local udid name available
  while IFS=$'\t' read -r udid name available; do
    if [ "$available" = true ] && [ -d "${name##* @ }" ]; then continue; fi
    xcrun simctl shutdown "$udid" 2>/dev/null || true
    xcrun simctl delete "$udid"
    echo "删掉 $name"
  done < <(xcrun simctl list devices -j | jq -r '.devices[][] | select(.name | startswith("CuePad ")) | [.udid, .name, .isAvailable] | @tsv')
}
