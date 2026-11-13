#!/usr/bin/env python3
"""发版前拿本检出的代码看真实数据：把正式版的资料库拷成一份副本（apple/.derived/real，每次重拷），起一份 Mac 隔离实例开它，窗口排在最前（不抢键盘，点一下激活）。xc.sh real 调它。
  real [-- 启动参数…]   拷副本 → xc.sh run mac；实例存活 CUEPAD_RUN_SECONDS 秒（缺省 30 分钟），xc.sh stop 收
  real copy            只拷副本、打印路径：截图、测量用 CUEPAD_SHOT_LIBRARY 指过去
副本上的改动留在副本里：本机构建不带 iCloud、不同步，也连不上手机和正式版里在跑的会话。新代码在副本上就地升级库结构，升级写坏了在这里先露出来。
库用 sqlite3 的 .backup 拷：正式版开着库时也是一致的一份，直接 cp 会漏掉 WAL 里没落盘的写入。附件是 APFS 克隆，不多占空间。
副本里是用户的私人内容：只留在本检出的 .derived（不入库），不拷到别处。
"""
import os
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
from app_env import APPLE, REAL_LIBRARY  # noqa: E402

COPY = f"{APPLE}/.derived/real"
LIBRARY = f"{REAL_LIBRARY}/Library"
# 附件的本机那份在系统缓存目录，库旁的 Attachments 是还没上传的保底（AttachmentFiles）
ATTACHMENTS = [(os.path.expanduser("~/Library/Caches/CuePadAttachments"), f"{COPY}/Caches/CuePadAttachments"), (f"{LIBRARY}/Attachments", f"{COPY}/Attachments")]


def copy():
    if not os.path.exists(f"{LIBRARY}/cuepad.db"):
        raise SystemExit(f"{LIBRARY} 里没有资料库：这台 Mac 上没用过正式版")
    shutil.rmtree(COPY, ignore_errors=True)
    os.makedirs(f"{COPY}/Caches", mode=0o700)
    os.chmod(COPY, 0o700)
    subprocess.run(["sqlite3", "-readonly", f"{LIBRARY}/cuepad.db", f".backup '{COPY}/cuepad.db'"], check=True)
    for source, target in ATTACHMENTS:
        if os.path.isdir(source):
            subprocess.run(["cp", "-cR", source, target], check=True)


def main(xc, args):
    copy()
    if args[:1] == ["copy"]:
        print(COPY)
        return
    env = dict(os.environ, CUEPAD_SHOT_LIBRARY=COPY, CUEPAD_RUN_SECONDS=os.environ.get("CUEPAD_RUN_SECONDS", "1800"))
    pid = subprocess.run([xc, "run", "mac", "--", "-CuePadOnTop", "YES", *args[1:]], env=env, stdout=subprocess.PIPE, text=True, check=True).stdout.split()[-1]
    print(f"实例 {pid} 开着真实库的副本，{env['CUEPAD_RUN_SECONDS']} 秒后自己退出，xc.sh stop 收")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2:])
