#!/bin/bash
# 生成宣传物料用的隔离演示库并启动 CuePad
# 用法: ./make-demo-db.sh [dark]   — 传 dark 生成深色主题版
set -euo pipefail
cd "$(dirname "$0")/../.."

USER_DATA=/tmp/cuepad-promo/user-data
DB="$USER_DATA/cuepad.db"
rm -rf /tmp/cuepad-promo
mkdir -p "$USER_DATA"

for f in migrations/*.sql; do
  sqlite3 "$DB" < "$f"
done
sqlite3 "$DB" "CREATE TABLE IF NOT EXISTS schema_migrations (version INTEGER PRIMARY KEY, applied_at INTEGER NOT NULL);
INSERT INTO schema_migrations (version, applied_at)
VALUES (1, strftime('%s','now')*1000), (2, strftime('%s','now')*1000), (3, strftime('%s','now')*1000),
       (4, strftime('%s','now')*1000), (5, strftime('%s','now')*1000);"
sqlite3 "$DB" < design/promo/demo-data.sql
if [ "${1:-}" = "dark" ]; then
  sqlite3 "$DB" "UPDATE app_settings SET value = '\"dark\"' WHERE key = 'theme';"
fi

echo "演示库已生成: $DB"
echo "启动: release/mac-arm64/CuePad.app/Contents/MacOS/CuePad --user-data-dir=$USER_DATA"
