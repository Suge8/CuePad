#!/usr/bin/env bash
# 合并（xc.sh land [PR 号或分支] [--red]）：主干最近跑完的一遍云端检查是绿的才合，合完把主检出快进。不带 PR 时合当前分支的。
# 红着就停下、列出红的用例。改动造成的：修，或回退那次合并。偶发的：gh run rerun <run> --failed，把 run 链接与失败原文记进 issue #187。
# 只看跑完的：还在跑的不等，重跑起来的那一遍也就不再挡；被后一次合并顶掉的（cancelled）不算。--red 留给修主干的那个 PR。
# 签核不在这里查：主干的规则见不到 signoff 状态，gh pr merge 自己会拒。
set -euo pipefail
red="" pr=""
for arg in "$@"; do case "$arg" in --red) red=1 ;; *) pr="$arg" ;; esac; done

latest="$(gh run list --branch main --workflow swift.yml --status completed --limit 10 --json databaseId,conclusion,displayTitle \
  -q '[.[] | select(.conclusion != "cancelled")][0] | "\(.databaseId) \(.conclusion) \(.displayTitle)"')"
read -r run conclusion title <<<"$latest"
if [ "$run" = null ] && [ -z "$red" ]; then
  echo "主干最近十遍云端检查没有一遍跑完（都被后一次合并顶掉了），没合：gh run list --branch main 看一眼，没问题带 --red" >&2
  exit 1
fi
if [ "$conclusion" != success ] && [ -z "$red" ]; then
  echo "主干最近一遍是红的，没合：$title（run $run）" >&2
  # 日志每行是 任务<Tab>步骤<Tab>时刻 正文：留结论页的首个失败，与测试宿主崩掉时 xcodebuild 自己列的那几条
  gh run view "$run" --log-failed 2>/dev/null | cut -f3- | cut -d' ' -f2- | grep -E '首个失败：|^[[:space:]]+-\[' | sort -u | head -10 >&2 || true
  echo "先处理再合：偶发的重跑（gh run rerun $run --failed）并记进 #187，重跑起来就不再挡；修主干的 PR 带 --red" >&2
  exit 1
fi
gh pr merge ${pr:+"$pr"} --merge
main="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
git -C "$main" pull --ff-only || echo "主检出没快进（多半被本地改动挡住）：留着，在交回里说" >&2
