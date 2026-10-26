#!/usr/bin/env bash
# iOS：testflight = 归档 → 导出并上传 App Store Connect；device = 开发构建并装到连接的真机。
# 手动签名：证书与描述文件由 provision.py 经 API 创建（Xcode 自动签名的 API 密钥管不了 App Group / iCloud 容器）。
# testflight 打包前先过两关，没部署完就不发：docs/release.md「待部署到生产」还有条目（订阅定义 cktool 看不到，只有手机会建，只拦 iOS）；
# 生产环境的 CloudKit 结构缺字段（ck-production.sh，Mac 发版也跑）；门铃中转打包前、归档后各核对一次（check_relay）。
# 上传后在这个提交上打 ios/<构建号> 标签：release-mac.sh 据它核对发版顺序（docs/release.md「发版顺序」）。
# 前提：docs/release.md。
set -euo pipefail
APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=_signing.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_signing.sh"
require_asc

mode="${1:-}"
DERIVED="$APPLE_DIR/.derived"
OUT="$DERIVED/release/ios"
provision="$APPLE_DIR/scripts/provision.py"

case "$mode" in
  testflight)
    docs="$APPLE_DIR/../docs/release.md"
    grep -q '^### 待部署到生产$' "$docs" || { echo "docs/release.md 里没有「### 待部署到生产」这一节" >&2; exit 1; }
    pending="$(awk '/^### 待部署到生产$/ { on = 1; next } /^#/ { on = 0 } on && /^- /' "$docs")"
    [ -z "$pending" ] || { printf 'docs/release.md「待部署到生产」还有没部署的，部署完删掉条目再发 iOS 版：\n%s\n' "$pending" >&2; exit 1; }
    "$APPLE_DIR/scripts/ck-production.sh"
    check_relay
    rm -rf "$OUT"; mkdir -p "$OUT"
    python3 "$provision" all
    # 版本由 release_versions 推出，命令行设置同时作用于 App 与扩展，两者一致
    read -ra versions <<<"$(release_versions)"
    archive="$(release_archive ios "${versions[@]}")"
    xcodebuild archive -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad -destination 'generic/platform=iOS' \
      -archivePath "$archive" -derivedDataPath "$DERIVED" "${versions[@]}" "${team_signing[@]}"
    check_relay "$archive/Products/Applications/CuePad.app/Info.plist"
    export_options "$OUT/export.plist" app-store-connect "Apple Distribution" \
      "$CUEPAD_APP_ID"="CuePad iOS AppStore" "$CUEPAD_APP_ID".share="CuePad Share iOS AppStore" \
      "$CUEPAD_APP_ID".widget="CuePad Widget iOS AppStore" "$CUEPAD_APP_ID".notify="CuePad Notify iOS AppStore"
    xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$OUT/export.plist" \
      -exportPath "$OUT/export"
    # 上传走 altool（xcodebuild 的 destination=upload 用 API 密钥时会报"账号凭据过期"）
    xcrun altool --upload-app -f "$OUT/export/CuePad.ipa" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
    git -C "$APPLE_DIR" tag "ios/${versions[1]#CURRENT_PROJECT_VERSION=}"
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
      -destination "id=$udid" -derivedDataPath "$DERIVED" "${team_signing[@]}"
    app="$DERIVED/Build/Products/Debug-iphoneos/CuePad.app"
    xcrun devicectl device install app --device "$device_id" "$app"
    xcrun devicectl device process launch --device "$device_id" "$CUEPAD_APP_ID"
    ;;
  *) echo "用法：$0 <testflight|device>" >&2; exit 2 ;;
esac
