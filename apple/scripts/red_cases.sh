#!/usr/bin/env bash
# 一遍云端检查里红的用例，一行一条：xc.sh 结论页的首个失败，与测试宿主崩掉时 xcodebuild 自己列的那几条。
# 合并停下时列给人看（land.sh），主干红了记进偶发红台账 #187（.github/workflows/red.yml）。
# 用法：red_cases.sh <run> [第几遍]
set -euo pipefail
log="$(gh run view "$1" ${2:+--attempt "$2"} --log-failed)"
# 日志每行是 任务<Tab>步骤<Tab>时刻 正文
cut -f3- <<<"$log" | cut -d' ' -f2- | grep -E '首个失败：|^[[:space:]]+-\[' | sort -u | head -10 || true
