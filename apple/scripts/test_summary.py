#!/usr/bin/env python3
"""xc.sh test 收尾时给 Agent 看的一页结论。用法：test_summary.py <完整日志> <xc.sh test 的退出码>

只读完整日志（xcodebuild 的原始输出，一次调用里 Kit 与 App 两段都在里面），不改退出码。分两家数：
- Swift Testing：`✔/✘ Test run with N tests …`（有已知问题 `withKnownIssue` 时这类行以 `━` 开头） 给总数，`✘ Test … failed after`、`➜ Test … skipped` 给失败与跳过；
- XCTest：每个测试包收尾的 `Test Suite 'All tests'|'Selected tests'` 后一行 `Executed N tests, with … skipped and … failures`。
钉住的 Agent 没装时它的用例跳过、原因里带「未覆盖：」（CueTestSupport 的 PinnedAgent）：单列成「没跑、不算通过的」，不混进普通的跳过。
按家参数化的用例跳过的那一例（`Test.cancel`）日志里没有任何一行，汇总把整个用例算通过：所以跑过真 Agent 用例时另列没装的家（agents.py status）。
用例的耗时取 `passed after`（Swift Testing，参数化的取汇总行，不取每个参数一行）与 `passed (x seconds)`（XCTest）。"""
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict

log_path, status = sys.argv[1], int(sys.argv[2])
lines = [l.replace("\u200b", "").rstrip("\n") for l in open(log_path, encoding="utf-8", errors="replace")]
# 输出被切开时，原因里的中文有时以八进制转义的字节出来（"未覆\347\233\226"）：还原成字，「未覆盖：」才认得出
octal = lambda text: re.sub(r"(?:\\[0-7]{3})+", lambda m: bytes(int(b, 8) for b in m[0].split("\\")[1:]).decode("utf-8", "replace"), text)

st_total = st_failed = st_skipped = xc_total = xc_failed = xc_skipped = 0
failed_names, durations = set(), []
skip_reason, skip_suites = {}, defaultdict(list)
first_failure = None
runtime_warnings = Counter()
expect_executed = False

for i, line in enumerate(lines):
    if m := re.match(r"[✔✘━] Test run with (\d+) tests? ", line):
        st_total += int(m[1])
    elif m := re.match(r"✘ Test (.+?) failed after ", line):
        failed_names.add(m[1])
    elif m := re.match(r'➜ Test (.+?) skipped: "(.*)"$', line):
        skip_reason[m[1]] = octal(m[2])
    elif m := re.match(r'➜ Suite (.+?) skipped: "(.*)"$', line):
        skip_suites[octal(m[2])].append(m[1])
    elif m := re.match(r"[✔━] Test (.+) passed after ([\d.]+) seconds", line):
        if not re.search(r" with \d+ arguments? ", m[1]):
            durations.append((float(m[2]), m[1]))
    elif m := re.match(r"Test Case '-\[(\S+) (\S+)\]' passed \(([\d.]+) seconds\)", line):
        durations.append((float(m[3]), f"{m[1]}.{m[2]}"))
    elif re.match(r"Test Suite '(All tests|Selected tests)' (passed|failed) at", line):
        expect_executed = True
    elif expect_executed and (m := re.match(r"\s+Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?", line)):
        expect_executed = False
        xc_total += int(m[1]); xc_skipped += int(m[2] or 0); xc_failed += int(m[3])
    elif m := re.match(r"(Thread Performance Checker|Main Thread Checker)", line):
        runtime_warnings[m[1]] += 1

    if first_failure is None:
        if m := re.match(r"✘ Test (.+?) recorded an issue(?: with \d+ arguments? (.+?))? at (\S+?:\d+):\d+: (.*)$", line):
            detail = [d for d in lines[i + 1:i + 6] if d.startswith("↳ ")]
            name = m[1] + (f"（参数 {m[2]}）" if m[2] else "")
            first_failure = (name, m[3], [m[4], *detail])
        elif m := re.match(r"(\S+\.swift:\d+): error: -\[(\S+) (\S+)\] : (.*)$", line):
            first_failure = (f"{m[2]}.{m[3]}", m[1], [m[4]])
        elif "Time limit was exceeded" in line:
            first_failure = ("超时", "", [line.strip()])

st_skipped = len(skip_reason)
st_failed = len(failed_names)
passed = lambda total, failed, skipped: max(total - failed - skipped, 0)
ran = st_total + xc_total > 0
verdict = "通过" if status == 0 else "未通过"
print(f"\n── 测试结论：{verdict}（退出码 {status}）──")
if not ran:
    print("没有任何用例的结果：多半是编译失败或没跑起来，看上面的错误；完整日志：" + log_path)
    sys.exit(0)
print(f"Swift Testing  通过 {passed(st_total, st_failed, st_skipped)}  失败 {st_failed}  跳过 {st_skipped}")
print(f"XCTest         通过 {passed(xc_total, xc_failed, xc_skipped)}  失败 {xc_failed}  跳过 {xc_skipped}")
if first_failure:
    name, where, detail = first_failure
    print(f"首个失败：{name}" + (f"  {where}" if where else ""))
    for d in detail:
        print(f"  {d}")
elif status != 0:
    print("用例都过了但命令失败：看上面的错误输出（编译、超时、测试宿主崩溃）")
by_reason = defaultdict(list)
for name, reason in skip_reason.items():
    by_reason[reason].append(name)
uncovered = defaultdict(int)
for reason, names in by_reason.items():
    if "未覆盖：" in reason:
        uncovered[reason[reason.index("未覆盖：") + len("未覆盖："):]] += len(names)
if uncovered:
    print("没跑、不算通过的：")
    for reason, count in sorted(uncovered.items()):
        print(f"  {reason}（{count} 个用例）")
if any("CuePiTests" in l for l in lines):
    cache = os.environ.get("TEST_RUNNER_CUEPAD_AGENTS_CACHE") or os.environ.get("CUEPAD_AGENTS_CACHE")
    agents = os.path.join(os.path.dirname(os.path.abspath(__file__)), "agents.py")
    listing = subprocess.run([sys.executable, "-I", agents, "status"], capture_output=True, text=True,
                             env={**os.environ, **({"CUEPAD_AGENTS_CACHE": cache} if cache else {})}).stdout
    absent = [" ".join(l.split()[:2]) for l in listing.splitlines() if l.split()[-1:] == ["没装"]]
    if absent:
        print("没装的 Agent（它的用例都没跑，按家参数化的用例里它那一例也没跑、却随整个用例算进了通过）：" + "、".join(absent))
for reason, names in by_reason.items():
    if "未覆盖：" in reason:
        continue
    suites = skip_suites.get(reason, [])
    shown = suites or names
    more = f" 等 {len(shown)} 个" if len(shown) > 3 else ""
    print(f"跳过 {len(names)} 个用例：{reason}（{'套件' if suites else '用例'} {'、'.join(shown[:3])}{more}）")
if runtime_warnings:
    print("运行时警告：" + "，".join(f"{k} {v} 条" for k, v in runtime_warnings.items()) + "（日志里搜这个名字）")
print("最慢 5 个：" + "；".join(f"{d:.2f}s {n}" for d, n in sorted(durations, reverse=True)[:5]))
print("完整日志：" + log_path)
