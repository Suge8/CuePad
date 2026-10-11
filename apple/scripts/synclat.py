#!/usr/bin/env python3
"""同步延迟分析：读 CuePad 的到达日志（子系统 com.sugeh.cuepad，类别 sync-latency），按场景算推送延迟、丢失率、主动拉取先到多少。

用法（经 xc.sh）：
  xc.sh synclat                        读本机（Mac）统一日志，默认最近 1 天
  xc.sh synclat --last 3h              时间窗口（log show 的 --last）
  xc.sh synclat --archive 手机.logarchive   本机日志之外再读 .logarchive，合在一起算（手机：iPhone 用线连着 Mac，
                                       sudo log collect --device --last 1h --output 手机.logarchive；或 sysdiagnose 里的 system_logs.logarchive）；可重复
  xc.sh synclat --no-local --archive 手机.logarchive   只读 .logarchive
  xc.sh synclat --lines 文件           读已抽出的 "latency …" 行（每行一条）

字段约定见 CueSync/ArrivalLog.swift；结论的回归用例：python3 apple/scripts/synclat_test.py。lag 起点是服务器时间、终点是本机时钟，误差零点几秒；超过 STALE 秒的是离线积压，不进分位数，单独计数。
"""
import argparse, json, re, subprocess, sys
from collections import defaultdict

STALE = 120.0           # 超过这么久才到的，是 App 没开期间攒下的，不是推送延迟
MIN_SAMPLES = 20        # 少于这个数不下结论
PREDICATE = 'subsystem == "com.sugeh.cuepad" AND category == "sync-latency"'


def percentile(values, p):
    ordered = sorted(values)
    return ordered[max(0, min(len(ordered) - 1, -(-len(ordered) * p // 100) - 1))] if ordered else None


def fmt(value):
    return "-" if value is None else f"{value:.1f}s"


def log_lines(args):
    texts = []
    for path in args.lines:
        texts += open(path, encoding="utf-8").read().splitlines()
    runs = [["--archive", a] + (["--last", args.last] if args.last else []) for a in args.archive]
    if not args.lines and not args.no_local:
        runs.append(["--last", args.last or "1d"])
    for extra in runs:
        out = subprocess.run(["log", "show", *extra, "--style", "ndjson", "--predicate", PREDICATE], capture_output=True, text=True)
        if out.returncode != 0:
            sys.exit(f"log show 失败：{out.stderr.strip()}")
        for raw in out.stdout.splitlines():
            try:
                texts.append(json.loads(raw).get("eventMessage", ""))
            except json.JSONDecodeError:
                continue
    return [line.strip() for line in texts if line.strip().startswith("latency ")]


KEYS = {"dev", "path", "kind", "rec", "v", "server", "at", "lag", "pullLag", "after"}


def parse(line):
    parts = line.split()
    fields, state = {}, []
    for token in parts[2:]:
        key, _, value = token.partition("=")
        if key in KEYS:
            fields[key] = value
        else:
            state.append(token)
    return parts[1], fields, " ".join(state)


def scenario(dev, state):
    s = dict(token.split("=", 1) for token in state.split() if "=" in token)
    if dev == "mac":
        if s.get("lock") == "yes": label = "锁屏"
        elif s.get("screen") == "off": label = "屏幕关闭"
        elif s.get("wake", "none") != "none": label = "刚唤醒"
        else: label = {"active": "前台", "inactive": "后台", "hidden": "隐藏"}.get(s.get("app"), s.get("app", "?"))
        return label + ("·电池" if s.get("power") == "battery" else "")
    app = {"active": "前台", "inactive": "切换中", "background": "后台"}.get(s.get("app"), s.get("app", "?"))
    net = {"wifi": "Wi-Fi", "cellular": "蜂窝", "wired": "有线", "other": "其他网络", "none": "无网络"}.get(s.get("net"), s.get("net", "?"))
    return f"{app}·{net}"


def direction(dev, kind):
    return {("mac", "request"): "手机→Mac（请求）", ("phone", "result"): "Mac→手机（结果）"}.get((dev, kind), f"{dev} {kind}")


def collect(lines):
    samples = {}
    for line in lines:
        event, f, state = parse(line)
        key = (f.get("dev"), f.get("rec"), f.get("v"))
        sample = samples.setdefault(key, {"dev": f.get("dev"), "kind": f.get("kind"), "state": state, "arrivals": {}, "lost": False, "superseded": False})
        if event == "arrive":
            sample["arrivals"].setdefault(f["path"], float(f["lag"]))
        elif event == "lost":
            sample["lost"] = True
        elif event == "superseded":
            sample["superseded"] = True
    return samples


def summarize(samples):
    groups = defaultdict(list)
    for s in samples.values():
        groups[(direction(s["dev"], s["kind"]), scenario(s["dev"], s["state"]))].append(s)
    return groups


def is_backlog(s):
    """很晚才经推送到、又没有主动拉取早早拿到过的：可能是 App 没开期间攒下的，也可能是推送真的慢，没法分。
    主动拉取早早拿到过同一版本、推送却很晚才到的，是确凿的慢推送，要算进去。"""
    arrivals = s["arrivals"]
    return arrivals.get("push", 0) > STALE and arrivals.get("pull", STALE + 1) > STALE


def outcome(s):
    """每条样本的结局，互斥且完备：push 推送已观测（含主动拉取先到后引擎补拿）；lost 推送丢失；superseded 被更新版本取代（推送量不到）；
    manual 被本机手动拉取先拿走（引擎令牌已越过，推送量不到）；pending 只有主动拉取到达、还没结案。
    后三种都是"推送没观测到"，不能当作推送可靠的证据。"""
    if "push" in s["arrivals"]:
        return "push"
    if s["lost"]:
        return "lost"
    if s["superseded"]:
        return "superseded"
    if "manual" in s["arrivals"]:
        return "manual"
    return "pending"


def stats(group):
    outcomes = [outcome(s) for s in group]
    count = {name: outcomes.count(name) for name in ("push", "lost", "superseded", "manual", "pending")}
    pushed = [s for s, o in zip(group, outcomes) if o == "push"]
    push = [s["arrivals"]["push"] for s in pushed if not is_backlog(s)]
    backlog = sum(1 for s in pushed if is_backlog(s))
    pulled = [s for s in group if "pull" in s["arrivals"]]
    early = [s["arrivals"]["push"] - s["arrivals"]["pull"] for s in pulled if "push" in s["arrivals"] and not is_backlog(s)]
    measurable = len(push) + count["lost"]
    return {
        "n": measurable, "p50": percentile(push, 50), "p90": percentile(push, 90), "max": max(push) if push else None,
        "lost": count["lost"], "lossRate": count["lost"] / measurable if measurable else None,
        "pullFirst": len(pulled) / len(group) if group else 0, "early50": percentile(early, 50), "early90": percentile(early, 90),
        "backlog": backlog, "manual": count["manual"], "superseded": count["superseded"], "pending": count["pending"],
    }


def row(label, st):
    loss = "-" if st["lossRate"] is None else f"{st['lossRate'] * 100:.0f}%（{st['lost']}）"
    warn = "  ← 样本太少" if st["n"] < 5 else ""
    return (f"  {label:<18} 样本 {st['n']:>3}  推送 p50 {fmt(st['p50']):>6} p90 {fmt(st['p90']):>6} 最大 {fmt(st['max']):>6}  丢失 {loss:<9} "
            f"拉取先到 {st['pullFirst'] * 100:>3.0f}%（提前 p50 {fmt(st['early50'])} p90 {fmt(st['early90'])}）"
            + (f"  积压 {st['backlog']}" if st["backlog"] else "")
            + (f"  推送未观测 {unobserved(st)}（{unobserved_share(st) * 100:.0f}%：被取代 {st['superseded']}、手动 {st['manual']}）" if unobserved(st) else "")
            + (f"  未结案 {st['pending']}" if st["pending"] else "") + warn)


def unobserved(st):
    """已结案、但推送没能观测到的（被取代 + 被手动拉取先拿走）。丢失另算，在 n 里。"""
    return st["superseded"] + st["manual"]


def unobserved_share(st):
    total = st["n"] + unobserved(st)
    return unobserved(st) / total if total else 0.0


def verdict(st):
    if st["n"] < MIN_SAMPLES:
        return f"样本 {st['n']} 条，不足 {MIN_SAMPLES}：先别下结论，再多测一些（正常用一两天也会攒）"
    p90, loss, superseded = st["p90"] or 0, st["lossRate"] or 0, unobserved_share(st)
    if p90 > 5 or loss > 0.05:
        return "推送 p90 > 5 秒或丢失 > 5%：保持 2 秒主动拉取"
    if st["pending"]:
        return (f"还有 {st['pending']} 条主动拉取先拿到的请求没结案（引擎最多要 5 分钟才会带来或判丢；App 中途退出的也停在这里）："
                "最后一条操作后等满 5 分钟再取数，现在不下结论")
    # 被取代 = 主动拉取先拿到、Mac 领取执行写回之后引擎只剩最新版本：推送没能抢在拉取与执行之前，旧版本的推送延迟量不到。
    # 这不是丢失，但恰恰是主动拉取在起作用的请求；把它们排除在外会把"能删"高估。
    if superseded > 0.2:
        return f"{superseded * 100:.0f}% 的请求是主动拉取先拿到、推送没观测到（被取代 {st['superseded']}、手动拉取先拿走 {st['manual']}）：主动拉取在实际起作用，保持 2 秒"
    if p90 <= 2 and loss < 0.01:
        if superseded > 0.01:
            return (f"推送 p90 与丢失率达标，但 {superseded * 100:.0f}% 的请求（被取代 {st['superseded']}、手动拉取先拿走 {st['manual']}）推送没观测到，"
                    "它们的推送延迟量不到：只放到 10 秒，不删")
        if st["backlog"]:
            return (f"推送 p90 与丢失率达标，但有 {st['backlog']} 条超过 {STALE:.0f} 秒才经推送到、没有主动拉取佐证的记录（没排除是推送慢）："
                    "先确认它们是不是 App 没开期间攒下的，确认前只放到 10 秒，不删")
        return "推送 p90 ≤ 2 秒且丢失 < 1%：Mac 主动拉取可放到 30–60 秒或删除"
    return "介于两者之间：保守放到 10 秒，再测一轮；不要删"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--last", default=None, help="时间窗口，默认 1d")
    parser.add_argument("--archive", action="append", default=[], help=".logarchive，可重复")
    parser.add_argument("--no-local", action="store_true", help="不读本机日志，只读 --archive")
    parser.add_argument("--lines", action="append", default=[], help="已抽出的日志行文件，可重复")
    args = parser.parse_args()
    lines = log_lines(args)
    if not lines:
        sys.exit("没有找到到达日志。确认 App 是带这个埋点的构建，并且这段时间里发生过别的设备写来的请求或会话状态。")
    samples = collect(lines)
    groups = summarize(samples)
    print(f"到达日志 {len(lines)} 行，{len(samples)} 个版本。lag = 本机到达时刻 − 服务器时间（时钟误差零点几秒）；推送 = 引擎自己调度的拉取（含启动与周期拉取，所以是推送延迟的上界）。\n")
    for name in sorted({k[0] for k in groups}):
        print(name)
        members = [s for k, v in groups.items() if k[0] == name for s in v]
        for (d, label), group in sorted(groups.items()):
            if d == name:
                print(row(label, stats(group)))
        total = stats(members)
        print(row("合计", total))
        if name.startswith("手机→Mac"):
            print("  结论（Mac 主动拉取）：" + verdict(total))
        print()


if __name__ == "__main__":
    main()
