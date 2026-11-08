#!/usr/bin/env bash
# iOS：testflight = 归档 → 导出并上传 App Store Connect；device = 开发构建并装到连接的真机。
# 手动签名：证书与描述文件由 provision.py 经 API 创建（Xcode 自动签名的 API 密钥管不了 App Group / iCloud 容器）。
# 描述文件全机一份：生成到最后一个签名步骤（归档导出、真机构建）持着签名锁（_lock.sh 规则 3），上传与安装不在锁里。
# testflight 打包前确认部署完成：docs/release.md「待部署到生产」没有条目、CloudKit 生产结构不缺字段（ck-production.sh，Mac 发版也跑）；
# 门铃与实时活动中转打包前、归档后各核对一次（check_relay）。
# 上传后在这个提交上打 ios/<构建号> 标签并推到远端：release-mac.sh 据它核对发版顺序（docs/release.md「发版顺序」），也是这一版源码的唯一记号。
# 前提：docs/release.md。
set -euo pipefail
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPTS/../.." && pwd)"
APPLE_DIR="$REPO_DIR/apple"
mode="${1:-}"
OUT="$APPLE_DIR/.derived/release/ios"
context() { python3 "$SCRIPTS/release-context.py" "$@"; }
if [ "$mode" = testflight ]; then
  context prepare "$REPO_DIR" "$OUT" ios >/dev/null
  APPLE_DIR="$OUT/source/apple"
fi
DERIVED="$REPO_DIR/apple/.derived"
[ "$mode" != testflight ] || DERIVED="$OUT/build"
# shellcheck source=_signing.sh source-path=SCRIPTDIR
. "$SCRIPTS/_signing.sh"
# shellcheck source=_lock.sh source-path=SCRIPTDIR
. "$SCRIPTS/_lock.sh"
require_asc

provision="$APPLE_DIR/scripts/provision.py"

case "$mode" in
  testflight)
    docs="$APPLE_DIR/../docs/release.md"
    grep -q '^### 待部署到生产$' "$docs" || { echo "docs/release.md 里没有「### 待部署到生产」这一节" >&2; exit 1; }
    pending="$(awk '/^### 待部署到生产$/ { on = 1; next } /^#/ { on = 0 } on && /^- /' "$docs")"
    [ -z "$pending" ] || { printf 'docs/release.md「待部署到生产」还有没部署的，部署完删掉条目再发 iOS 版：\n%s\n' "$pending" >&2; exit 1; }
    "$APPLE_DIR/scripts/ck-production.sh"
    check_relay
    signing_begin
    python3 "$provision" all
    # 版本由 release_versions 推出，命令行设置同时作用于 App 与扩展，两者一致
    read -ra versions <<<"$(release_versions)"
    archive="$(release_archive ios "${versions[@]}")"
    xcodebuild archive -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad -destination 'generic/platform=iOS' \
      -archivePath "$archive" -derivedDataPath "$DERIVED" "${versions[@]}" "${team_signing[@]}"
    check_relay "$archive/Products/Applications/CuePad.app/Info.plist"
    export_options "$OUT/export.plist" app-store-connect "Apple Distribution" \
      "$CUEPAD_APP_ID=CuePad iOS AppStore" "$CUEPAD_APP_ID.share=CuePad Share iOS AppStore" \
      "$CUEPAD_APP_ID.widget=CuePad Widget iOS AppStore" "$CUEPAD_APP_ID.notify=CuePad Notify iOS AppStore"
    xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$OUT/export.plist" \
      -exportPath "$OUT/export"
    signing_end
    context seal "$OUT" "$archive"
    build_version="$(context verify "$OUT" "$REPO_DIR")"
    # 上传走 altool（xcodebuild 的 destination=upload 用 API 密钥时会报"账号凭据过期"）
    xcrun altool --upload-app -f "$OUT/export/CuePad.ipa" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
    tag="$(context tag "$OUT" "$REPO_DIR")"
    git -C "$REPO_DIR" push -q origin "$tag"
    echo "已上传 ${build_version}，App Store Connect 处理完成后出现在 TestFlight"
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
    signing_begin
    python3 "$provision" device "$udid" "${name//_/ }" # 已登记则跳过
    python3 "$provision" identity development
    python3 "$provision" profiles
    xcodebuild build -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad -configuration Debug \
      -destination "id=$udid" -derivedDataPath "$DERIVED" "${team_signing[@]}"
    signing_end
    app="$DERIVED/Build/Products/Debug-iphoneos/CuePad.app"
    xcrun devicectl device install app --device "$device_id" "$app"
    xcrun devicectl device process launch --device "$device_id" "$CUEPAD_APP_ID"
    ;;
  *) echo "用法：$0 <testflight|device>" >&2; exit 2 ;;
esac
