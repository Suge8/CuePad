#!/usr/bin/env bash
# 合并前的门（xc.sh signoff 进这里）：在本机跑 check、test kit、test mac，全过就给 HEAD 这个提交在 GitHub 上记一条通过的状态 `signoff`；
# 主干的规则（仓库的 ruleset「保护 main」）见到这条状态才让 PR 合并。状态记在提交上：之后再改就是新提交，重跑。
# PR 不在云端跑：GitHub 给个人账号的 macOS runner 是 M1 3 核、同时最多 5 台，同样三项要等 10 分钟以上、几个 PR 一起时再排半小时；
# 开发机上冷跑约 5 分半、改一个文件后约 3 分半（2026-11 实测）。云端只在合并进主干后跑一遍全量兜底（swift.yml），发布只认那一遍全绿的提交。
# 签的是别人拿得到的那一份：提交已推送、工作区干净（连未跟踪的文件）、签的那一刻含最新的 origin/main。
# 签完主干又前进了，这条状态照样算数（不要求重签：每合进一个 PR 其余的都得重跑）：与后来合进主干的改动合起来才坏的，由主干那一遍兜住。
# 真 Agent 用例跑每家的冒烟、钉住的家缺一家就红（xc.sh 头注释），动了读会话与对话落库的代码就全量跑；没动 apple/ 的改动（文档、设计稿、落地页）只跑 lint。
set -euo pipefail
xc="$1"
scripts="$(cd "$(dirname "$0")" && pwd)"
cd "$scripts/../.."

stop() { echo "签核：$1" >&2; exit 1; }
clean() { [ -z "$(git status --porcelain)" ] || stop "工作区有没提交的改动或未跟踪的文件：提交或清掉再签"; }
clean
head="$(git rev-parse HEAD)"
git fetch -q origin main
git merge-base --is-ancestor origin/main HEAD || stop "这个提交不含最新的 origin/main：先 git merge origin/main、推送，再签"
report() { gh api "repos/{owner}/{repo}/statuses/$head" -f state="$1" -f context=signoff -f description="$2" >/dev/null; }
report pending "本机在跑" || stop "记不上状态：这个提交还没推送到 GitHub（先 git push），或 gh 没登录"

outcome=failure note="本机没过"
trap 'report "$outcome" "$note"' EXIT
if git diff --quiet origin/main HEAD -- apple; then
  "$scripts/lint.sh"
  passed="lint（没动 apple/）"
else
  export TEST_RUNNER_CUEPAD_AGENT_MATRIX=full
  # 读会话与对话落库的代码动了就把真 Agent 的用例全量跑上（缺省只跑一小组）：云端 CI 全量跑，这里不跑就要等合并后才知道红
  git diff --quiet origin/main HEAD -- apple/CuePadKit/Sources/CueBridge apple/CuePadKit/Sources/CueStore || export TEST_RUNNER_CUEPAD_AGENT_TESTS=all
  "$xc" agents install
  "$xc" check
  "$xc" test kit
  "$xc" test mac
  passed="check、test kit、test mac"
fi
[ "$(git rev-parse HEAD)" = "$head" ] || stop "跑的中途 HEAD 变了：结果不对应 $head，重跑"
clean
outcome=success note="本机通过：$passed"
echo "签核通过：${head:0:9}（${passed}）"
