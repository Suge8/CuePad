#!/usr/bin/env bash
# iOS：testflight = 归档 → 导出并上传 App Store Connect；device = 开发构建并装到连接的真机。
# 手动签名：证书与描述文件由 provision.py 经 API 创建（Xcode 自动签名的 API 密钥管不了 App Group / iCloud 容器）。
# 前提：docs/release.md。
set -euo pipefail
APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=_signing.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_signing.sh"
require_asc

mode="${1:-}"
DERIVED="${CUEPAD_DERIVED:-$APPLE_DIR/.derived}"
OUT="$DERIVED/release/ios"
provision="$APPLE_DIR/scripts/provision.py"

case "$mode" in
  testflight)
    rm -rf "$OUT"; mkdir -p "$OUT"
    python3 "$provision" all
    # 版本由 release_versions 推出，命令行设置同时作用于 App 与扩展，两者一致
    read -ra versions <<<"$(release_versions)"
    xcodebuild archive -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad -destination 'generic/platform=iOS' \
      -archivePath "$OUT/CuePad.xcarchive" -derivedDataPath "$DERIVED" "${versions[@]}"
    export_options "$OUT/export.plist" app-store-connect "Apple Distribution" \
      com.sugeh.cuepad="CuePad iOS AppStore" com.sugeh.cuepad.share="CuePad Share iOS AppStore" \
      com.sugeh.cuepad.widget="CuePad Widget iOS AppStore" com.sugeh.cuepad.notify="CuePad Notify iOS AppStore"
    xcodebuild -exportArchive -archivePath "$OUT/CuePad.xcarchive" -exportOptionsPlist "$OUT/export.plist" \
      -exportPath "$OUT/export"
    # 上传走 altool（xcodebuild 的 destination=upload 用 API 密钥时会报"账号凭据过期"）
    xcrun altool --upload-app -f "$OUT/export/CuePad.ipa" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
    echo "已上传 ${versions[*]}，App Store Connect 处理完成后出现在 TestFlight"
    python3 "$APPLE_DIR/scripts/testflight.py" group
    ;;
  device)
    # 取第一台已连接的真机；未登记则登记，再刷新 Development 描述文件
    info="$(xcrun devicectl list devices --json-output /dev/stdout 2>/dev/null | python3 -c '
import json, sys
text = sys.stdin.read()
devices = json.loads(text[text.index("{"):])["result"]["devices"]
for d in devices:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("reality") == "physical" and conn.get("tunnelState") == "connected":
        print(d["identifier"], hw.get("udid", ""), d["deviceProperties"]["name"].replace(" ", "_")); break
')"
    [ -n "$info" ] || { echo "没有连接的 iPhone/iPad（数据线连接并信任这台 Mac；开发者模式需已开启）" >&2; exit 1; }
    read -r device_id udid name <<<"$info"
    python3 "$provision" device "$udid" "${name//_/ }" # 已登记则跳过
    python3 "$provision" identity development
    python3 "$provision" profiles
    xcodebuild build -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad -configuration Debug \
      -destination "id=$udid" -derivedDataPath "$DERIVED"
    app="$DERIVED/Build/Products/Debug-iphoneos/CuePad.app"
    xcrun devicectl device install app --device "$device_id" "$app"
    xcrun devicectl device process launch --device "$device_id" com.sugeh.cuepad
    ;;
  *) echo "用法：$0 <testflight|device>" >&2; exit 2 ;;
esac
