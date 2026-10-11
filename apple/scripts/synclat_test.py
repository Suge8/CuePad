#!/usr/bin/env python3
"""synclat.py 的结论回归：构造日志，断言什么情况下建议删除/放慢/保持。运行：python3 apple/scripts/synclat_test.py"""
import os, subprocess, sys, tempfile, unittest

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "synclat.py")
STATE = "app=active lock=no screen=on wake=none power=ac"


def run(lines):
    with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
        f.write("\n".join(lines) + "\n")
    try:
        return subprocess.run([sys.executable, SCRIPT, "--lines", f.name], capture_output=True, text=True, check=True).stdout
    finally:
        os.unlink(f.name)


def push(rec, lag, pull_lag=None):
    extra = f" pullLag={pull_lag:.2f}" if pull_lag is not None else ""
    return f"latency arrive dev=mac path=push kind=request rec={rec} v=1 lag={lag:.2f}{extra} {STATE}"


def pull(rec, lag):
    return f"latency arrive dev=mac path=pull kind=request rec={rec} v=1 lag={lag:.2f} {STATE}"


def superseded(rec):
    return f"latency superseded dev=mac kind=request rec={rec} v=1 pullLag=1.00 after=300 {STATE}"


class Verdict(unittest.TestCase):
    def test_fast_push_only_may_delete(self):
        self.assertIn("可放到 30–60 秒或删除", run([push(f"a{i:07d}", 1.0) for i in range(25)]))

    def test_superseded_requests_block_deletion(self):
        lines = [push(f"a{i:07d}", 1.0) for i in range(20)]
        for i in range(20):
            lines += [pull(f"b{i:07d}", 1.0), superseded(f"b{i:07d}")]
        out = run(lines)
        self.assertNotIn("可放到 30–60 秒或删除", out)
        self.assertIn("保持 2 秒", out)

    def test_a_few_superseded_cap_at_ten_seconds(self):
        lines = [push(f"a{i:07d}", 1.0) for i in range(30)] + [pull("b0000000", 1.0), superseded("b0000000")]
        out = run(lines)
        self.assertNotIn("可放到 30–60 秒或删除", out)
        self.assertIn("只放到 10 秒，不删", out)

    def test_slow_push_seen_by_the_pull_counts(self):
        lines = [push(f"a{i:07d}", 1.0) for i in range(20)]
        for i in range(20):
            lines += [pull(f"b{i:07d}", 1.0), push(f"b{i:07d}", 150.0, pull_lag=1.0)]
        out = run(lines)
        self.assertNotIn("可放到 30–60 秒或删除", out)
        self.assertIn("保持 2 秒", out)

    def test_requests_the_pull_got_first_and_not_yet_settled_block_any_verdict(self):
        lines = [push(f"a{i:07d}", 1.0) for i in range(20)] + [pull(f"b{i:07d}", 1.0) for i in range(20)]
        out = run(lines)
        self.assertNotIn("可放到 30–60 秒或删除", out)
        self.assertIn("没结案", out)
        self.assertIn("等满 5 分钟", out)

    def test_settled_pull_first_requests_that_were_pushed_later_do_not_block(self):
        lines = [push(f"a{i:07d}", 1.0) for i in range(20)]
        for i in range(20):
            lines += [pull(f"b{i:07d}", 1.0), push(f"b{i:07d}", 1.5, pull_lag=1.0)]
        self.assertIn("可放到 30–60 秒或删除", run(lines))

    def test_requests_a_manual_fetch_took_first_count_as_unobserved(self):
        lines = [push(f"a{i:07d}", 1.0) for i in range(20)]
        for i in range(20):
            lines += [pull(f"b{i:07d}", 1.0), f"latency arrive dev=mac path=manual kind=request rec=b{i:07d} v=1 lag=2.00 pullLag=1.00 {STATE}"]
        out = run(lines)
        self.assertNotIn("可放到 30–60 秒或删除", out)
        self.assertIn("保持 2 秒", out)

    def test_unconfirmed_backlog_blocks_deletion(self):
        lines = [push(f"a{i:07d}", 1.0) for i in range(25)] + [push(f"d{i:07d}", 900.0) for i in range(3)]
        out = run(lines)
        self.assertNotIn("可放到 30–60 秒或删除", out)
        self.assertIn("不删", out)


if __name__ == "__main__":
    unittest.main()
