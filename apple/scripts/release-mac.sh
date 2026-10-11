#!/usr/bin/env bash
# macOS 分发：归档 → Developer ID 导出 → 公证 → 装订 → zip → appcast。产物：<产物目录>/release/mac/CuePad-<版本>-mac.zip 与 appcast.xml
# 前提：docs/release.md 里的凭据与 Developer ID 证书。
# 公证有时要等很久（新账号首次提交可能数小时）：中断后用 `xc.sh release mac --resume <提交 id>` 接着等这次提交并装订、出 zip。
set -euo pipefail
APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$APPLE_DIR/scripts/_signing.sh"
require_asc

DERIVED="${CUEPAD_DERIVED:-$APPLE_DIR/.derived}"
OUT="$DERIVED/release/mac"
resume=""
if [ "${1:-}" = "--resume" ]; then resume="${2:?用法：release-mac.sh --resume <提交 id>}"; fi
notary=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")

if [ -z "$resume" ]; then
rm -rf "$OUT"; mkdir -p "$OUT"
# Developer ID 证书在专用钥匙串里；描述文件（含 iCloud、推送）由 API 创建并安装。
# 手动签名：Xcode 的自动签名用 API 密钥时管不了 iCloud 容器，工程的 Release 配置已指定证书与描述文件名。
python3 "$APPLE_DIR/scripts/provision.py" unlock
python3 "$APPLE_DIR/scripts/provision.py" profiles

# Sparkle 按 CFBundleVersion 比较新旧，每次发布必须递增：取时间戳
xcodebuild archive -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad -destination 'generic/platform=macOS' \
  -archivePath "$OUT/CuePad.xcarchive" -derivedDataPath "$DERIVED" CURRENT_PROJECT_VERSION="$(build_number)"

export_options "$OUT/export.plist" developer-id "Developer ID Application" com.sugeh.cuepad="CuePad macOS DeveloperID"
xcodebuild -exportArchive -archivePath "$OUT/CuePad.xcarchive" -exportOptionsPlist "$OUT/export.plist" \
  -exportPath "$OUT/export"

fi

app="$OUT/export/CuePad.app"
codesign --verify --deep --strict --verbose=2 "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"

# 公证：提交 zip，等待结果，通过后把票据装订进 app
if [ -n "$resume" ]; then
  submission="$(xcrun notarytool wait "$resume" "${notary[@]}")"
else
  ditto -c -k --keepParent "$app" "$OUT/notarize.zip"
  submission="$(xcrun notarytool submit "$OUT/notarize.zip" --wait "${notary[@]}")"
fi
echo "$submission"
# --wait 在公证被拒时退出码也是 0，必须看状态
if ! grep -q "status: Accepted" <<<"$submission"; then
  xcrun notarytool log "$(awk '/id:/{print $2; exit}' <<<"$submission")" "${notary[@]}" >&2
  echo "公证未通过" >&2
  exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

zip="$OUT/CuePad-$version-mac.zip"
ditto -c -k --keepParent "$app" "$zip"
echo "$zip"
# 自动更新：把这个 zip 收进更新历史目录（在产物目录之外，上面的 rm -rf 不碰它），生成/更新 appcast.xml；部署由人决定
"$APPLE_DIR/scripts/sparkle.sh" appcast "$zip"
