#!/usr/bin/env bash
# 只读核对生产环境的 CloudKit 结构：导出生产结构，和 apple/CloudKit/cuepad.ckdb 逐字段比（字段名与整条定义：类型、加密、索引），
# 生产缺的列出来、以 1 退出。生产里写没部署的字段或类型会让整条记录保存失败，所以 release-mac.sh 打包前先跑它；缺的照 docs/release.md 部署。
# 管理令牌在钥匙串 cuepad-cloudkit-management-token（见 docs/release.md），团队来自凭据文件的 CUEPAD_TEAM_ID。
set -euo pipefail
APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=_signing.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_signing.sh"
require_asc

token="$(security find-generic-password -a cuepad -s cuepad-cloudkit-management-token -w)" \
  || { echo "钥匙串里没有 CloudKit 管理令牌 cuepad-cloudkit-management-token（见 docs/release.md）" >&2; exit 1; }
production="$(mktemp)"
trap 'rm -f "$production"' EXIT
CLOUDKIT_MANAGEMENT_TOKEN="$token" xcrun cktool export-schema --team-id "$CUEPAD_TEAM_ID" \
  --container-id iCloud.com.sugeh.cuepad --environment production --output-file "$production"

# 每个字段一行"记录类型 字段 定义"：去掉行尾逗号、引号，空白归一（服务端导出时按字母序重排并补系统字段，只比本地有的）
fields() {
  awk '/RECORD TYPE/ { type = $3; next }
       type && /^ *\);/ { type = ""; next }
       type && !/GRANT/ { sub(/,$/, ""); gsub(/"/, ""); $1 = $1; print type " " $0 }' "$1" | sort
}
missing="$(comm -23 <(fields "$APPLE_DIR/CloudKit/cuepad.ckdb") <(fields "$production"))"
if [ -n "$missing" ]; then
  printf '生产环境的 CloudKit 结构缺这些字段（或定义不同），先部署再发布：\n%s\n' "$missing" >&2
  exit 1
fi
echo "生产环境的 CloudKit 结构包含 cuepad.ckdb 的全部字段"
