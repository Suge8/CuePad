#!/usr/bin/env bash
# Sparkle 自动更新的发布侧：EdDSA 密钥（专用钥匙串，不入库）与 appcast 生成。
# 用法：sparkle.sh key              确保密钥存在，打印公钥（SUPublicEDKey）
#       sparkle.sh appcast <zip>    把公证后的 zip 收进 updates/ 并生成/更新 appcast.xml（含增量更新）
# 产出都在 <产物目录>/release/mac/：updates/（历史 zip 与增量包，要保留才能生成增量）、appcast.xml。
# 更新包的下载地址前缀用 CUEPAD_UPDATE_URL_PREFIX（默认 https://cue-pad.com/downloads/）；是否部署由人决定。
set -euo pipefail
APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEYCHAIN="$HOME/.appstoreconnect/cuepad-signing.keychain-db"
KEY_SERVICE=cuepad-sparkle-ed25519
TOOLS="$HOME/.appstoreconnect/sparkle"
DERIVED="${CUEPAD_DERIVED:-$APPLE_DIR/.derived}"
PREFIX="${CUEPAD_UPDATE_URL_PREFIX:-https://cue-pad.com/downloads/}"

# 命令行工具随 Sparkle 的二进制发布包分发；版本与校验和只在 Vendor/Sparkle/Package.swift 里写一份
tools() {
  local package="$APPLE_DIR/Vendor/Sparkle/Package.swift"
  local url checksum dir
  url="$(sed -n 's/.*url: "\([^"]*\)".*/\1/p' "$package")"
  checksum="$(sed -n 's/.*checksum: "\([^"]*\)".*/\1/p' "$package")"
  dir="$TOOLS/$checksum"
  if [ ! -x "$dir/bin/generate_appcast" ]; then
    mkdir -p "$dir"
    curl -fsSL -o "$dir/sparkle.zip" "$url"
    [ "$(shasum -a 256 "$dir/sparkle.zip" | cut -d' ' -f1)" = "$checksum" ] || { echo "Sparkle 发布包校验和不符" >&2; rm -f "$dir/sparkle.zip"; exit 1; }
    unzip -q -o "$dir/sparkle.zip" -d "$dir"
  fi
  echo "$dir/bin"
}

unlock() { python3 "$APPLE_DIR/scripts/provision.py" unlock; }

private_key() { security find-generic-password -s "$KEY_SERVICE" -a sparkle -w "$KEYCHAIN" 2>/dev/null; }

ensure_key() {
  unlock
  if ! private_key >/dev/null; then
    local generated seed
    generated="$(swift "$APPLE_DIR/scripts/sparkle-key.swift" generate)"
    seed="$(head -1 <<<"$generated")"
    security add-generic-password -s "$KEY_SERVICE" -a sparkle -w "$seed" -T /usr/bin/security "$KEYCHAIN"
    echo "已生成 EdDSA 密钥并存入专用钥匙串" >&2
  fi
  private_key | swift "$APPLE_DIR/scripts/sparkle-key.swift" public
}

case "${1:-}" in
  key) ensure_key ;;
  appcast)
    zip="${2:?用法：sparkle.sh appcast <zip>}"
    ensure_key >/dev/null
    bin="$(tools)"
    updates="$DERIVED/release/mac/updates"
    mkdir -p "$updates"
    cp "$zip" "$updates/"
    private_key | "$bin/generate_appcast" --ed-key-file - --download-url-prefix "$PREFIX" \
      --link "https://cue-pad.com" "$updates"
    cp "$updates/appcast.xml" "$DERIVED/release/mac/appcast.xml"
    echo "$DERIVED/release/mac/appcast.xml"
    ;;
  *) echo "用法：$0 <key|appcast <zip>>" >&2; exit 2 ;;
esac
