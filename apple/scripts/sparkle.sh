#!/usr/bin/env bash
# Sparkle 自动更新的发布侧：EdDSA 密钥（专用钥匙串，不入库）、appcast 生成与签名校验。
# 用法：sparkle.sh key                          确保密钥存在，打印公钥（SUPublicEDKey）
#       sparkle.sh appcast <zip> <下载地址前缀>   在 zip 旁生成只含这一版的 appcast.xml（enclosure = 前缀 + zip 文件名），打印其路径
#       sparkle.sh verify <zip> <appcast.xml>    用 appcast 里 enclosure 的 EdDSA 签名校验 zip
# 只发完整包，不做增量：安装包放在一个固定的 GitHub Release 里，每次发布替换，那里不留历史版本。
set -euo pipefail
APPLE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEYCHAIN="$HOME/.appstoreconnect/cuepad-signing.keychain-db"
KEY_SERVICE=cuepad-sparkle-ed25519
TOOLS="$HOME/.appstoreconnect/sparkle"

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
    zip="${2:?用法：sparkle.sh appcast <zip> <下载地址前缀>}"
    prefix="${3:?用法：sparkle.sh appcast <zip> <下载地址前缀>}"
    ensure_key >/dev/null
    bin="$(tools)"
    # generate_appcast 收录目录里的全部安装包并沿用已有的 appcast.xml：给它一个只有这个 zip 的新目录
    feed="$(mktemp -d)"
    cp "$zip" "$feed/"
    private_key | "$bin/generate_appcast" --ed-key-file - --download-url-prefix "$prefix" --link "https://cue-pad.com" "$feed" >&2
    appcast="$(dirname "$zip")/appcast.xml"
    mv "$feed/appcast.xml" "$appcast"
    rm -rf "$feed"
    echo "$appcast"
    ;;
  verify)
    zip="${2:?用法：sparkle.sh verify <zip> <appcast.xml>}"
    appcast="${3:?用法：sparkle.sh verify <zip> <appcast.xml>}"
    signature="$(sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p' "$appcast")"
    [ "$(wc -l <<<"$signature")" -eq 1 ] && [ -n "$signature" ] || { echo "appcast 里应恰有一个 EdDSA 签名" >&2; exit 1; }
    unlock
    bin="$(tools)"
    private_key | "$bin/sign_update" --verify --ed-key-file - "$zip" "$signature"
    ;;
  *) echo "用法：$0 <key | appcast <zip> <下载地址前缀> | verify <zip> <appcast.xml>>" >&2; exit 2 ;;
esac
