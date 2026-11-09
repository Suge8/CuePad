#!/usr/bin/env bash
# macOS 分发：归档（带正式版标记）→ Developer ID 导出 → 核对身份、标记与资料库位置 → 公证 → 装订 → zip → 生成并签名 appcast → 核对线上版本 → 替换固定 GitHub Release 的资产 → 从公开地址回读校验。
# 只经 xc.sh release mac [--dry-run] [--resume <公证 id>] 运行：release-context.py 拿全机发布锁、给这次尝试一个新目录（CUEPAD_RELEASE_OUT，日志第一行打印路径）。
#   --dry-run  停在尝试目录里的 zip 与 appcast.xml（已用 EdDSA 签名校验），不上传；照样提交公证
#   --resume   找回 submission.json 记着这个公证 ID 的那次尝试，沿用它的提交与产物，接着等公证并发布
# 下载位置只有一处：Release $TAG 的三个资产，不新建 Release，每次发布原地替换；替换资产前在归档来源提交上打 mac/<构建号> 标签并推到远端（这一版源码的唯一记号）；三个资产各自的用途与上传顺序的理由见 docs/release.md。
# 线上（资产与更新源）的构建号比这一版新就不发：迟到的恢复不覆盖新版；同号是同一版的重入，标签已指向别的提交时推送被拒。
# 更新源 SUFeedURL 直接是这里的 appcast.xml（releases/latest/download/appcast.xml），核对与回读都从 App 的 Info.plist 读这个地址。
# 打包前先核对生产环境的 CloudKit 结构（ck-production.sh），缺字段就不发；待部署清单只拦 iOS（release-ios.sh）。
# 也核对发版顺序（check_ios_floor）：这一版的同步下界不高于 TestFlight 上处理好的最新 iOS 版（docs/release.md「发版顺序」）。门铃中转打包前、导出后各核对一次（check_relay）。
# 前提：docs/release.md 里的凭据、Developer ID 证书与 CloudKit 管理令牌；gh 已登录且有仓库写权限。
set -euo pipefail
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPTS/../.." && pwd)"
OUT="${CUEPAD_RELEASE_OUT:?只经 xc.sh release mac 运行}"
source_commit="$(cat "$OUT/commit")"
APPLE_DIR="$OUT/source/apple"
DERIVED="$OUT/build"
context() { python3 "$SCRIPTS/release-context.py" "$@"; }

REPO=Suge8/CuePad
TAG=v0.1.0
TITLE="CuePad for Mac"
NOTES="CuePad for macOS (Apple Silicon), signed with Developer ID and notarized by Apple.

Download **[CuePad-mac-arm64.zip](https://github.com/$REPO/releases/latest/download/CuePad-mac-arm64.zip)**, unzip, and drag \`CuePad.app\` to Applications. The app keeps itself up to date from this page.

Site: https://cue-pad.com"
ASSET=CuePad-mac-arm64.zip
DOWNLOAD="https://github.com/$REPO/releases/latest/download"

dry_run=false
[ "${1:-}" != --dry-run ] || dry_run=true
# shellcheck source=_signing.sh source-path=SCRIPTDIR
. "$SCRIPTS/_signing.sh"
# shellcheck source=_lock.sh source-path=SCRIPTDIR
. "$SCRIPTS/_lock.sh"
require_asc
notary=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")

# 某个提交里的同步下界（Schema.peerFloor）。
schema_floor() {
  git -C "$REPO_DIR" show "$1:apple/CuePadKit/Sources/CueStore/Schema.swift" | sed -n 's/^ *static let peerFloor = \([0-9][0-9]*\)$/\1/p'
}

# iOS 的标签（release-ios.sh 打的 ios/<构建号>）里最新一个处理好（VALID）的，下界要不低于这一版的。
check_ios_floor() {
  local here valid tag
  here="$(schema_floor "$source_commit")"
  valid="$(python3 "$APPLE_DIR/scripts/testflight.py" builds | awk '$2 == "VALID" { print $1 }')"
  for tag in $(git -C "$REPO_DIR" tag -l 'ios/*' --sort=-version:refname); do
    grep -qx "${tag#ios/}" <<<"$valid" || continue
    [ "$(schema_floor "$tag")" -ge "$here" ] && return 0
    break
  done
  echo "这一版的同步下界是 ${here}，TestFlight 上处理好的 iOS 版还没到：先 xc.sh release ios，等 testflight.py builds 显示 VALID 再发 Mac（docs/release.md「发版顺序」）" >&2
  exit 1
}
# 上传要 gh 能写这个 Release：打包要几分钟，先确认
$dry_run || gh release view "$TAG" -R "$REPO" --json tagName >/dev/null
$dry_run || check_ios_floor
"$APPLE_DIR/scripts/ck-production.sh"
check_relay

app="$OUT/export/CuePad.app"
# 有了公证响应就是恢复：产物沿用，不重新归档
if [ ! -e "$OUT/submission.json" ]; then
# Developer ID 证书在专用钥匙串里；描述文件（含 iCloud）由 API 创建并安装。
# 手动签名：Xcode 的自动签名用 API 密钥时管不了 iCloud 容器，工程的 Release 配置已指定证书与描述文件名。
# 描述文件全机一份，生成到导出完持着签名锁（_lock.sh 规则 3），公证不在锁里
signing_begin
python3 "$APPLE_DIR/scripts/provision.py" unlock
python3 "$APPLE_DIR/scripts/provision.py" profiles

read -ra versions <<<"$(release_versions)"
archive="$(release_archive mac "${OUT##*/}" "${versions[@]}")"
xcodebuild archive -project "$APPLE_DIR/CuePad.xcodeproj" -scheme CuePad -destination 'generic/platform=macOS' \
  -archivePath "$archive" -derivedDataPath "$DERIVED" "${versions[@]}" "${team_signing[@]}" CUEPAD_RELEASE=YES

export_options "$OUT/export.plist" developer-id "Developer ID Application" "$CUEPAD_APP_ID"="CuePad macOS DeveloperID"
xcodebuild -exportArchive -archivePath "$archive" -exportOptionsPlist "$OUT/export.plist" -exportPath "$OUT/export"
signing_end
context seal "$OUT" "$archive" "${versions[@]}" >/dev/null
fi

plist() { /usr/libexec/PlistBuddy -c "Print $1" "$app/Contents/Info.plist"; }
build_version="$(plist CFBundleVersion)"
check_relay "$app/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$app"
# 正式版标记（Signing.xcconfig 的 CUEPAD_RELEASE）：包里是 YES，包里的命令行在空家目录下找的是正式资料库 CuePad/Library、不是开发库 CuePad Dev。
# 少了它，装上的正式版会去开开发库，用户看到的是空库
[ "$(plist CuePadRelease)" = YES ] || { echo "包里的 CuePadRelease 不是 YES" >&2; exit 1; }
probe_home="$(mktemp -d)"
probe="$(HOME="$probe_home" CFFIXED_USER_HOME="$probe_home" "$app/Contents/Helpers/cuepad" project list 2>&1 || true)"
rm -rf "$probe_home"
grep -qF "/Library/Application Support/CuePad/Library/cuepad.db" <<<"$probe" || { echo "包里的命令行没去找正式资料库：$probe" >&2; exit 1; }

# 公证：提交 zip，等待结果，通过后把票据装订进 app。响应先完整落盘再读 ID：之后进程被杀也能按 ID 恢复
if [ ! -e "$OUT/submission.json" ]; then
  ditto -c -k --keepParent "$app" "$OUT/notarize.zip"
  xcrun notarytool submit "$OUT/notarize.zip" --output-format json "${notary[@]}" >"$OUT/submission.json"
fi
notary_id="$(context id "$OUT")"
echo "恢复此产物：xc.sh release mac --resume $notary_id"
submission="$(xcrun notarytool wait "$notary_id" "${notary[@]}")"
echo "$submission"
# --wait 在公证被拒时退出码也是 0，必须看状态
if ! grep -q "status: Accepted" <<<"$submission"; then
  xcrun notarytool log "$notary_id" "${notary[@]}" >&2
  echo "公证未通过" >&2
  exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"

zip="$OUT/$ASSET"
update="$OUT/${ASSET%.zip}-${build_version}.zip"
ditto -c -k --keepParent "$app" "$zip"
cp "$zip" "$update"
appcast="$("$APPLE_DIR/scripts/sparkle.sh" appcast "$update" "$DOWNLOAD/")"
"$APPLE_DIR/scripts/sparkle.sh" verify "$update" "$appcast"
echo "$(plist CFBundleShortVersionString)（${build_version}）：$zip $update $appcast"
if $dry_run; then exit 0; fi

names="$(gh release view "$TAG" -R "$REPO" --json assets --jq '.assets[].name')"
feed="$(curl -fsSL "$(plist SUFeedURL)")" || { echo "读不到线上的更新源 $(plist SUFeedURL)，不发布" >&2; exit 1; }
online="$(printf '%s\n' "$names" "$feed" | sed -nE "s/.*${ASSET%.zip}-([0-9]+)\.zip.*/\1/p" | sort -n | tail -1)"
[ "${online:-0}" -le "$build_version" ] || { echo "拒绝发布旧版 ${build_version}：线上已是 ${online}" >&2; exit 1; }
release_tag mac "$build_version" "$source_commit"
# 顺序的理由见 docs/release.md：带构建号的新包 → appcast → 官网包 → 删上一版带构建号的包
for path in "$update" "$appcast" "$zip"; do gh release upload "$TAG" "$path" -R "$REPO" --clobber; done
for old in $names; do
  case "$old" in
    "${update##*/}") ;;
    "${ASSET%.zip}-"*.zip) gh release delete-asset "$TAG" "$old" -R "$REPO" -y ;;
  esac
done
gh release edit "$TAG" -R "$REPO" --title "$TITLE" --notes "$NOTES"

# 回读校验：从 App 实际使用的更新源取 appcast，再按它的 enclosure 与官网地址取包，都与本地一致且签名通过
check="$OUT/check"; mkdir -p "$check"
curl -fsSL -o "$check/appcast.xml" "$(plist SUFeedURL)"
cmp "$check/appcast.xml" "$appcast"
curl -fsSL -o "$check/update.zip" "$(sed -n 's/.*enclosure url="\([^"]*\)".*/\1/p' "$check/appcast.xml")"
curl -fsSL -o "$check/$ASSET" "$DOWNLOAD/$ASSET"
cmp "$check/update.zip" "$update"
cmp "$check/$ASSET" "$zip"
"$APPLE_DIR/scripts/sparkle.sh" verify "$check/update.zip" "$check/appcast.xml"
echo "已发布：$DOWNLOAD/${ASSET}（mac/${build_version}）"
