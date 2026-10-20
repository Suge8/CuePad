# shellcheck shell=bash
# 被 xc.sh 与发布脚本 source：读取 App Store Connect 凭据与团队，产出发布与真机构建给 xcodebuild 的签名设置 team_signing。
# 凭据文件（默认 ~/.appstoreconnect/cuepad.env，可用 CUEPAD_ASC_ENV 指定）字段：ASC_KEY_ID、ASC_ISSUER_ID、ASC_KEY_PATH、CUEPAD_TEAM_ID。
# 文件缺失时 team_signing 为空：本机 ad-hoc 构建与测试照常，只有发布命令会报错（require_asc）。绝不回显凭据内容。
# 工程默认是本机 ad-hoc（Signing.xcconfig）；team_signing 换上团队与带 iCloud 的 macOS 权限文件，证书与描述文件名在工程的各 target 里。
ASC_ENV="${CUEPAD_ASC_ENV:-$HOME/.appstoreconnect/cuepad.env}"
team_signing=()
if [ -f "$ASC_ENV" ]; then
  set -a
  # shellcheck source=/dev/null
  . "$ASC_ENV"
  set +a
  team_signing=(DEVELOPMENT_TEAM="$CUEPAD_TEAM_ID" CUEPAD_MAC_ENTITLEMENTS=App/Config/CuePad-macOS.entitlements)
fi

# 导出选项 plist：export_options <文件> <method> <证书> [bundleID=描述文件名…]；手动签名
export_options() {
  local file=$1 method=$2 cert=$3; shift 3
  local profiles="" pair
  for pair in "$@"; do profiles+="<key>${pair%%=*}</key><string>${pair#*=}</string>"$'\n'; done
  cat > "$file" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>$method</string>
<key>teamID</key><string>$CUEPAD_TEAM_ID</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>$cert</string>
<key>provisioningProfiles</key><dict>
$profiles</dict>
$([ "$method" = app-store-connect ] && echo '<key>destination</key><string>export</string>')
</dict></plist>
PLIST
}

# 发布版本的 xcodebuild 设置，由同一个时间戳推出：显示版本是日期（2026.10.13），构建号是分钟（2610131639）。
# TestFlight 与 Sparkle 都按构建号比较新旧，所以它必须递增：发布是串行的，一次要几分钟（公证），分钟精度够；同日多次发布显示版本相同，Sparkle 的更新提示会补上构建号区分。
release_versions() {
  local now; now="$(date +%s)"
  echo "MARKETING_VERSION=$(date -r "$now" +%Y.%-m.%-d) CURRENT_PROJECT_VERSION=$(date -r "$now" +%y%m%d%H%M)"
}

# 发布的归档按构建号存进 Xcode 的归档目录，不放产物目录：产物目录每次发布先清空、发布用的干净检出用完就删，
# 真机崩溃（MetricKit、TestFlight）的栈只能靠归档里的 dSYM 还原；Xcode 的 Organizer 列得出它，Spotlight 按 UUID 找得到 dSYM。
# 用法：release_archive <ios|mac> <release_versions 的输出…>
release_archive() {
  echo "$HOME/Library/Developer/Xcode/Archives/$(date +%F)/CuePad $1 ${3#CURRENT_PROJECT_VERSION=}.xcarchive"
}

require_asc() {
  [ "${#team_signing[@]}" -gt 0 ] || { echo "缺少 App Store Connect 凭据文件：$ASC_ENV（字段见 apple/scripts/_signing.sh 头注释）" >&2; exit 1; }
  [ -f "$ASC_KEY_PATH" ] || { echo "ASC_KEY_PATH 指向的密钥文件不存在" >&2; exit 1; }
}
