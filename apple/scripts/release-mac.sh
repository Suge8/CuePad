#!/usr/bin/env bash
# macOS 分发：归档 → Developer ID 导出 → 公证 → 装订 → zip → 生成并签名 appcast → 替换固定 GitHub Release 的资产 → 从公开地址回读校验。
# 用法：release-mac.sh [--dry-run] [--resume <提交 id>]
#   --dry-run  停在本地产物：<产物目录>/release/mac/ 下的 zip 与 appcast.xml（已用 EdDSA 签名校验），不上传
#   --resume   公证有时要等很久（新账号首次提交可能数小时）：中断后接着等这次提交，再装订并继续后面的步骤
# 下载位置只有一处：Release $TAG 的三个资产，不新建版本或标签，每次发布原地替换；三个资产各自的用途与上传顺序的理由见 docs/release.md。
# 更新源 SUFeedURL 直接是这里的 appcast.xml（releases/latest/download/appcast.xml），回读校验从 App 的 Info.plist 读这个地址。
# 打包前先核对生产环境的 CloudKit 结构（ck-production.sh），缺字段就不发。
# 前提：docs/release.md 里的凭据、Developer ID 证书与 CloudKit 管理令牌；gh 已登录且有仓库写权限。
set -euo pipefail
APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=_signing.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_signing.sh"
require_asc

REPO=Suge8/CuePad
TAG=v0.1.0
TITLE="CuePad for Mac"
NOTES="CuePad for macOS (Apple Silicon), signed with Developer ID and notarized by Apple.

Download **[CuePad-mac-arm64.zip](https://github.com/$REPO/releases/latest/download/CuePad-mac-arm64.zip)**, unzip, and drag \`CuePad.app\` to Applications. The app keeps itself up to date from this page.

Site: https://cue-pad.com"
ASSET=CuePad-mac-arm64.zip
DOWNLOAD="https://github.com/$REPO/releases/latest/download"

DERIVED="$APPLE_DIR/.derived"
OUT="$DERIVED/release/mac"
dry_run=false resume=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=true; shift ;;
    --resume) resume="${2:?用法：release-mac.sh --resume <提交 id>}"; shift 2 ;;
    *) echo "用法：$0 [--dry-run] [--resume <提交 id>]" >&2; exit 2 ;;
  esac
done
notary=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
# 上传要 gh 能写这个 Release：打包要几分钟，先确认
$dry_run || gh release view "$TAG" -R "$REPO" --json tagName >/dev/null
"$APPLE_DIR/scripts/ck-production.sh"

if [ -z "$resume" ]; then
rm -rf "$OUT"; mkdir -p "$OUT"
# Developer ID 证书在专用钥匙串里；描述文件（含 iCloud）由 API 创建并安装。
# 手动签名：Xcode 的自动签名用 API 密钥时管不了 iCloud 容器，工程的 Release 配置已指定证书与描述文件名。
python3 "$APPLE_DIR/scripts/provision.py" unlock
python3 "$APPLE_DIR/scripts/provision.py" profiles

read -ra versions <<<"$(release_versions)"
archive="$(release_archive mac "${versions[@]}")"
xcodebuild archive -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad -destination 'generic/platform=macOS' \
  -archivePath "$archive" -derivedDataPath "$DERIVED" "${versions[@]}"

export_options "$OUT/export.plist" developer-id "Developer ID Application" com.sugeh.cuepad="CuePad macOS DeveloperID"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$OUT/export.plist" \
  -exportPath "$OUT/export"

fi

app="$OUT/export/CuePad.app"
codesign --verify --deep --strict --verbose=2 "$app"

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

plist() { /usr/libexec/PlistBuddy -c "Print $1" "$app/Contents/Info.plist"; }
zip="$OUT/$ASSET"
update="$OUT/${ASSET%.zip}-$(plist CFBundleVersion).zip"
ditto -c -k --keepParent "$app" "$zip"
cp "$zip" "$update"
appcast="$("$APPLE_DIR/scripts/sparkle.sh" appcast "$update" "$DOWNLOAD/")"
"$APPLE_DIR/scripts/sparkle.sh" verify "$update" "$appcast"
echo "$(plist CFBundleShortVersionString)（$(plist CFBundleVersion)）：$zip $update $appcast"
if $dry_run; then exit 0; fi

# 顺序的理由见 docs/release.md：带构建号的新包 → appcast → 官网包 → 删上一版带构建号的包
gh release upload "$TAG" "$update" -R "$REPO" --clobber
gh release upload "$TAG" "$appcast" -R "$REPO" --clobber
gh release upload "$TAG" "$zip" -R "$REPO" --clobber
for old in $(gh release view "$TAG" -R "$REPO" --json assets --jq '.assets[].name'); do
  case "$old" in
    "$(basename "$update")") ;;
    "${ASSET%.zip}-"*.zip) gh release delete-asset "$TAG" "$old" -R "$REPO" -y ;;
  esac
done
gh release edit "$TAG" -R "$REPO" --title "$TITLE" --notes "$NOTES"

# 回读校验：从 App 实际使用的更新源取 appcast，再按它的 enclosure 与官网地址取包，都与本地一致且签名通过
check="$OUT/check"; mkdir -p "$check"
curl -fsSL -o "$check/appcast.xml" "$(plist SUFeedURL)"
cmp "$check/appcast.xml" "$appcast"
enclosure="$(sed -n 's/.*enclosure url="\([^"]*\)".*/\1/p' "$check/appcast.xml")"
curl -fsSL -o "$check/update.zip" "$enclosure"
curl -fsSL -o "$check/$ASSET" "$DOWNLOAD/$ASSET"
cmp "$check/update.zip" "$update"
cmp "$check/$ASSET" "$zip"
"$APPLE_DIR/scripts/sparkle.sh" verify "$check/update.zip" "$check/appcast.xml"
echo "已发布：$DOWNLOAD/$ASSET"
