#!/usr/bin/env bash
# macOS 分发：归档 → Developer ID 导出 → 公证 → 装订 → zip。产物：<产物目录>/release/mac/CuePad-<版本>-mac.zip
# 前提：apple/README.md「签名与发布」里的凭据与 Developer ID 证书。
set -euo pipefail
APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
. "$APPLE_DIR/scripts/_signing.sh"
require_asc

DERIVED="${CUEPAD_DERIVED:-$APPLE_DIR/.derived}"
OUT="$DERIVED/release/mac"
rm -rf "$OUT"; mkdir -p "$OUT"

python3 "$APPLE_DIR/scripts/provision.py" unlock # 本机若有 Developer ID 证书，它在专用钥匙串里

xcodebuild archive -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad -destination 'generic/platform=macOS' \
  -archivePath "$OUT/CuePad.xcarchive" -derivedDataPath "$DERIVED" "${asc_auth[@]}"

# 自动签名：优先本机专用钥匙串里的 Developer ID 证书，没有则用账号里云端托管的（需要密钥有该权限）
cat > "$OUT/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>${CUEPAD_TEAM_ID}</string>
<key>signingStyle</key><string>automatic</string>
<key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$OUT/CuePad.xcarchive" -exportOptionsPlist "$OUT/export.plist" \
  -exportPath "$OUT/export" "${asc_auth[@]}"

app="$OUT/export/CuePad.app"
codesign --verify --deep --strict --verbose=2 "$app"
version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")"

# 公证：提交 zip，等待结果，通过后把票据装订进 app
ditto -c -k --keepParent "$app" "$OUT/notarize.zip"
notary=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
submission="$(xcrun notarytool submit "$OUT/notarize.zip" --wait "${notary[@]}")"
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
