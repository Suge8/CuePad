#!/usr/bin/env bash
# 只读核对生产环境的 CloudKit 结构，两样有一样不对就以 1 退出、列出缺什么；release-mac.sh 与 release-ios.sh 打包前都先跑它，缺的照 docs/release.md 部署：
# 1. docs/release.md「待部署到生产」还有条目：订阅定义这类 cktool 看不到的部署只记在那里，有条目就是还没部署。
# 2. 导出生产结构，和 apple/CloudKit/cuepad.ckdb 逐字段比（字段名与整条定义：类型、加密、索引），列出生产缺的。生产里写没部署的字段或类型会让整条记录保存失败。
# 管理令牌在钥匙串 cuepad-cloudkit-management-token（见 docs/release.md），团队来自凭据文件的 CUEPAD_TEAM_ID。
set -euo pipefail
APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=_signing.sh source-path=SCRIPTDIR
. "$APPLE_DIR/scripts/_signing.sh"
require_asc

docs="$APPLE_DIR/../docs/release.md"
grep -q '^### 待部署到生产$' "$docs" || { echo "docs/release.md 里没有「### 待部署到生产」这一节" >&2; exit 1; }
pending="$(awk '/^### 待部署到生产$/ { on = 1; next } /^#/ { on = 0 } on && /^- /' "$docs")"
if [ -n "$pending" ]; then
  printf 'docs/release.md「待部署到生产」还有没部署的，部署完删掉条目再发布：\n%s\n' "$pending" >&2
  exit 1
fi

token="$(security find-generic-password -a cuepad -s cuepad-cloudkit-management-token -w)" \
  || { echo "钥匙串里没有 CloudKit 管理令牌 cuepad-cloudkit-management-token（见 docs/release.md）" >&2; exit 1; }
production="$(mktemp)"
trap 'rm -f "$production"' EXIT
CLOUDKIT_MANAGEMENT_TOKEN="$token" xcrun cktool export-schema --team-id "$CUEPAD_TEAM_ID" \
  --container-id "iCloud.$CUEPAD_APP_ID" --environment production --output-file "$production"

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
