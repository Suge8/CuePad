"""lint_extension.py、lint_schema.py 共用：在 apple/ 下跑 git，失败时说清要什么样的检出。"""
import subprocess, sys


def git(*args):
    return subprocess.run(["git", *args], check=True, capture_output=True, text=True).stdout


def fail(what, error):
    sys.exit(f"{what}：{error.stderr.strip()}\n  → 需要完整的 Git 检出（git clone 出来的，含 origin/main 与发布标签）：浅克隆先 git fetch --unshallow --tags，"
             "缺 origin/main 就 git fetch origin main；git archive 导出的副本没有 .git，跑不了这条 lint")
