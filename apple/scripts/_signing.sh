# 被 xc.sh 与发布脚本 source：读取 App Store Connect 凭据，产出 xcodebuild 的自动签名参数。
# 凭据文件（默认 ~/.appstoreconnect/cuepad.env，可用 CUEPAD_ASC_ENV 指定）字段：ASC_KEY_ID、ASC_ISSUER_ID、ASC_KEY_PATH、CUEPAD_TEAM_ID。
# 文件缺失时 asc_auth 为空：本机 ad-hoc 构建与测试照常，只有发布命令会报错。绝不回显凭据内容。
ASC_ENV="${CUEPAD_ASC_ENV:-$HOME/.appstoreconnect/cuepad.env}"
asc_auth=()
if [ -f "$ASC_ENV" ]; then
  set -a; . "$ASC_ENV"; set +a
  asc_auth=(-allowProvisioningUpdates
    -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
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

# 构建号：分钟时间戳，每次发布必须递增（TestFlight 与 Sparkle 都按它比较新旧）
build_number() { date +%y%m%d%H%M; }

require_asc() {
  [ "${#asc_auth[@]}" -gt 0 ] || { echo "缺少 App Store Connect 凭据文件：$ASC_ENV（字段见 docs/release.md）" >&2; exit 1; }
  [ -f "$ASC_KEY_PATH" ] || { echo "ASC_KEY_PATH 指向的密钥文件不存在" >&2; exit 1; }
}
