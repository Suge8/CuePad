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

require_asc() {
  [ "${#asc_auth[@]}" -gt 0 ] || { echo "缺少 App Store Connect 凭据文件：$ASC_ENV（字段见 docs/development.md「签名与发布」）" >&2; exit 1; }
  [ -f "$ASC_KEY_PATH" ] || { echo "ASC_KEY_PATH 指向的密钥文件不存在" >&2; exit 1; }
}
