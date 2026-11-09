#!/usr/bin/env python3
"""一个检出里同时开 Mac、iPhone 模拟器、iPad 模拟器三个隔离实例，共用一朵模拟云（SharedCloud，不连 iCloud）。xc.sh fleet 调它。
  fleet up [--keep] [mac] [iphone] [ipad]   起实例（缺省三个）：云与各端的库先清空，--keep 沿用上次的；每个实例经 xc.sh run 起，
                                            存活 CUEPAD_RUN_SECONDS 秒（缺省 30 分钟）；打印每一端的 PID 或 UDID，写进 .derived/fleet/fleet.json（ui.py 按角色名认）
  fleet status                              各端还在不在
  fleet down                                结束本检出 run 起的全部实例（同 xc.sh stop）
  fleet accept [秒=60]                      验收：iPhone 上 ⌘N 建一条灵感、粘进一句话 → 在跑的其余端（Mac、iPad）的屏上读到它（ui.py 读界面，不查库）；打印各端看到的时刻，没读到以 1 退出
  fleet cloud-sims                          建（已有就复用）两台专用模拟器 "CuePad Cloud iPhone"、"CuePad Cloud iPad"，打印 UDID：不在槽位池里，真云验收时在里面登测试账号
  fleet up --real [iphone] [ipad]           真云：两台专用模拟器连 CloudKit 开发环境（-CuePadCloudKit YES），用模拟器里登着的测试账号，两台登同一个账号才互相同步；
                                            库在 .derived/fleet-real（down 不删，免得每次从头拉）。没登账号时 App 照常起、不同步。Mac 的真云在虚拟机里跑，不在这里起
隔离：每端一份库（.derived/fleet/<角色>/library）与连接目录，共用 .derived/fleet/cloud；本检出的 Mac 实例最多一个（app.py 规则 2），
iPhone、iPad 各占一个槽位（_lock.sh）、各有角色名（CUEPAD_RUN_ROLE，app.py 的 sim_run），同一个检出里互不收掉。
云没有延迟模型（不睡）：时刻反映的是同步代码与界面刷新，不是真网络；门铃照常连正式中转（房间按这朵云自己的密钥）。
"""
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
import app_proc  # noqa: E402
import ui  # noqa: E402
from app_env import APPLE, sim_run  # noqa: E402

DIR = f"{APPLE}/.derived/fleet"
STATE = f"{DIR}/fleet.json"
CLOUD = f"{DIR}/cloud"
REAL_LIBRARIES = f"{APPLE}/.derived/fleet-real"
CLOUD_SIMS = {"iphone": ("CuePad Cloud iPhone", os.environ.get("CUEPAD_IOS_DEVICE", "iPhone 17")),
              "ipad": ("CuePad Cloud iPad", os.environ.get("CUEPAD_IPAD_DEVICE", "iPad Pro 11-inch (M5)"))}
# 角色 → (xc.sh 的平台, 启动参数)：iPhone 停在 Cue 页（建灵感的一端），Mac 与 iPad 打开默认项目页（新灵感出现的地方）
ROLES = {
    "mac": ("mac", ["-CuePadScene", "project", "-CuePadProject", "默认"]),
    "iphone": ("ios", ["-CuePadScene", "cue"]),
    "ipad": ("ipad", ["-CuePadScene", "project", "-CuePadProject", "默认"]),
}


def load():
    try:
        with open(STATE) as f:
            return json.load(f)
    except (OSError, ValueError):
        return {}


def alive(role, note):
    if note["platform"] == "mac":
        return subprocess.run(["kill", "-0", str(note["pid"])], capture_output=True).returncode == 0
    try:
        with open(sim_run(role)) as f:
            return app_proc.alive(json.load(f))
    except (OSError, ValueError):
        return False


def cloud_sims():
    """专用模拟器的 UDID（没有就建，只建不开机）。"""
    found = {}
    listing = json.loads(subprocess.run(["xcrun", "simctl", "list", "devices", "-j"], capture_output=True, text=True, check=True).stdout)["devices"]
    for role, (name, model) in CLOUD_SIMS.items():
        udid = next((d["udid"] for ds in listing.values() for d in ds if d["name"] == name and d["isAvailable"]), None)
        found[role] = udid or subprocess.run(["xcrun", "simctl", "create", name, model], capture_output=True, text=True, check=True).stdout.strip()
    return found


def up(xc, roles, keep, real=False):
    if real and "mac" in roles:
        raise SystemExit("--real 只起 iphone、ipad：Mac 的真云在虚拟机里跑")
    if not keep:
        subprocess.run([xc, "stop"], check=True)
        shutil.rmtree(DIR, ignore_errors=True)
    os.makedirs(CLOUD if not real else DIR, exist_ok=True)
    state = load() if keep else {}
    pins = cloud_sims() if real else {}
    for role in roles:
        platform, args = ROLES[role]
        began = time.time()
        env = dict(os.environ, CUEPAD_SHOT_LIBRARY=f"{REAL_LIBRARIES if real else DIR}/{role}/library", CUEPAD_RUN_ROLE=role,
                   CUEPAD_RUN_SECONDS=os.environ.get("CUEPAD_RUN_SECONDS", "1800"))
        if real:
            env["CUEPAD_PIN_SIM"] = pins[role]
        cloud = ["-CuePadCloudKit", "YES"] if real else ["-CuePadSharedCloud", CLOUD]
        p = subprocess.run([xc, "run", platform, "--", *cloud, *args], env=env, stdout=subprocess.PIPE, text=True)
        if p.returncode:
            raise SystemExit(f"{role} 起不来（xc.sh run {platform} 退出 {p.returncode}），已起的用 fleet down 收")
        m = re.search(r"^(\d+)(?: ([0-9A-F-]{36}))?$", p.stdout, re.M)
        state[role] = {"platform": platform, "pid": int(m[1]), "udid": m[2], "up_s": round(time.time() - began, 1), "dedicated": real}
        with open(STATE, "w") as f:
            json.dump(state, f)
        print(f"{role}\t{m[2] or 'pid ' + m[1]}\t起了 {state[role]['up_s']} 秒", flush=True)


def accept(timeout):
    state = load()
    if "iphone" not in state or len(state) < 2:
        raise SystemExit("至少要 iphone 和另一端在跑：先 xc.sh fleet up")
    phone = state["iphone"]["udid"]
    stamp = f"灵感{time.strftime('%H%M%S')}验收"
    line = []

    def mark(who, what, at=None):
        line.append((at or time.time(), who, what))

    t0 = time.time()
    ui.key(phone, "cmd+n")
    mark("iPhone", "⌘N 建一条灵感")
    ui.wait(phone, "正文", 20)
    mark("iPhone", "编辑页出现")
    ui.tap(phone, "正文", "TextArea")  # 编辑页出现时输入框未必已拿到焦点：粘贴落空过一次
    windows, errors = {}, {}

    def watch(role):
        try:
            windows[role] = ui.wait(role, stamp, timeout)
        except SystemExit:
            errors[role] = True

    # 先开始轮询再粘贴：每一轮"读完时有没有"都记着，看到的时刻才不被手机这边的确认拖后
    threads = [threading.Thread(target=watch, args=(r,)) for r in state if r != "iphone"]
    [t.start() for t in threads]
    t_paste = time.time()
    ui.paste(phone, stamp)
    mark("iPhone", f"粘进「{stamp}」", t_paste)
    ui.wait(phone, stamp, 10)
    mark("iPhone", "自己的正文里读回了它")
    [t.join() for t in threads]
    for role, (at, miss) in windows.items():
        mark("Mac" if role == "mac" else "iPad", "屏上读到" + (f"（上一轮从 +{miss - t0:.1f} 秒开始读、那时还没有）" if miss and miss > t_paste else ""), at)
    for t, who, what in sorted(line):
        print(f"t+{t - t0:5.1f}s  {who:6} {what}")
    for role in errors:
        print(f"没读到：{role} 的屏上 {timeout:g} 秒内没出现「{stamp}」", file=sys.stderr)
    for role, (at, _) in windows.items():
        print(f"{role}\t粘贴后 {at - t_paste:.1f} 秒读到")
    raise SystemExit(1 if errors else 0)


def main(argv):
    xc = argv[0]
    cmd, rest = (argv[1], argv[2:]) if len(argv) > 1 else ("", [])
    if cmd == "up":
        real = "--real" in rest
        roles = [a for a in rest if a in ROLES] or (["iphone", "ipad"] if real else list(ROLES))
        up(xc, roles, "--keep" in rest, real)
    elif cmd == "cloud-sims":
        for role, udid in cloud_sims().items():
            print(f"{role}\t{CLOUD_SIMS[role][0]}\t{udid}")
    elif cmd == "status":
        for role, note in load().items():
            print(f"{role}\t{'在' if alive(role, note) else '不在'}\t{note['udid'] or 'pid ' + str(note['pid'])}")
    elif cmd == "down":
        subprocess.run([xc, "stop"], check=True)
        for note in load().values():  # 专用模拟器没人复用，不像槽位里的一直开着
            if note.get("dedicated"):
                subprocess.run(["xcrun", "simctl", "shutdown", note["udid"]], capture_output=True)
        shutil.rmtree(DIR, ignore_errors=True)
    elif cmd == "accept":
        accept(float(rest[0]) if rest else 60)
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
