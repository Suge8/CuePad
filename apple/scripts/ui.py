#!/usr/bin/env python3
"""按元素操作调试实例的界面：读、点、拖、输入、等文字、截图（模拟器经 AXe，Mac 经 bcu，都是薄封装）。
用法：ui.py <mac|sim|UDID|iphone|ipad> <命令> …，mac、sim 是本检出起着的 Mac 实例与 `xc.sh run` 留着的那台模拟器，iphone、ipad 是 `xc.sh fleet up` 起的那一台。
  read [--all]               屏上的元素，每行 类型⇥标签⇥值⇥x,y,宽,高（点）；--all 连屏外的与没标签的一起列
  tap <标签|#id|x,y> [--type T] [--nth N]   按元素点它的中心：标签先全等后包含，只数屏上的；有几个就报错列出，--nth 从 0 起挑一个
  drag <x1,y1> <x2,y2> [中间点数=6] [--rec 片.mp4]
                             按住再拖：按下、逐点挪过去、抬手。axe drag 按下就走（带 --pre-delay 也是），按住才浮起来的东西（看板的卡）它拎不动。
                             每个点约 1.5 秒（axe 1.8.0 实测），整趟是慢动作：验的是放下的结果与抬手之后的动效，不是拖着时的手感。
                             --rec 把这一趟录下来（抬手后再录 2 秒），打印抬手在片里的秒数；逐帧看用 xc.sh sheet -from
  type <文字>                 在有焦点的输入框里按键打字，屏上读回才算成。只打得出键盘上有的字符，拼音键盘下字母还停在候选里（数字直接上屏）。
                             模拟器的剪贴板与这台 Mac 共用，不经它粘贴；要中文内容用启动参数预置（-CuePadSpeech、-CuePadCueDraft，DebugScene+Args*.swift）
  key <cmd+n|esc|…>           组合键：修饰键 cmd ctrl alt shift，键 a–z 0–9 return esc tab space delete left right up down
  wait <文字> [秒=20]          读到标签或值包含它为止，打印用时；超时以 1 退出
  shot [图.png]               截图
不靠固定等待：点完用 wait 等结果。
mac 的命令同名，差别：
  坐标是 shot 那张图的像素（bcu 把窗口缩到 1600 宽，不是点）；read 是 bcu 折叠过的树，没有框
  tap 的 --type 是 bcu 的角色（button、textarea…），没有 #id；type、key 打进此刻有键盘焦点的元素
  focus                      有键盘焦点的元素：角色、名字、值、框（并排的几块回复框同名，按框的 x 认是哪一块）
  shot                       打印截图路径
  tap、drag、key 认 --rec 片.mov（从动作前录 4 秒，打印动作在片里投出的时刻）与 --front
  每个动作印出 bcu 的结论行：worked 是有证据，unverified 是投了、读不到证据，看界面再定，别重做。
  默认在后台投，不动用户的键盘与指针。--front 占前台（apple/scripts/AGENTS.md「占前台」），只有这两样要它：
  菜单快捷键（⌘⌥←：后台按下去是 unverified、块没挪）；实例不在前台时的拖放。带 --front 的 drag 先把指针停到起点再按下：
  胶囊的把手靠指针进出事件锁住窗口，没悬停就按下，拖走的是整扇窗口。
"""
import json
import os
import re
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True
from _lock import holding, live  # noqa: E402
from app_env import CHECKOUT, READY, SLOT_NAME  # noqa: E402

FLEET = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".derived/fleet/fleet.json")
KEYS = {**{c: 4 + i for i, c in enumerate("abcdefghijklmnopqrstuvwxyz")}, **{c: 30 + i for i, c in enumerate("1234567890")},
        "return": 40, "esc": 41, "delete": 42, "tab": 43, "space": 44, "right": 79, "left": 80, "down": 81, "up": 82}
MODS = {"ctrl": 224, "shift": 225, "alt": 226, "cmd": 227}


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def resolve(target):
    """返回 (UDID 或 PID, 是不是 Mac)。mac、sim 问持有者登记（_lock.py），不用从 run 的输出里抄 PID。"""
    if re.fullmatch(r"[0-9A-F-]{36}", target):
        return target, False
    if target == "mac":
        held = holding(SLOT_NAME)
        if not held or "app" not in held:
            fail("本检出没有起着的 Mac 实例：xc.sh run mac …")
        return held["app"], True
    if target == "sim":
        kept = [h for h, _ in live() if h["checkout"] == CHECKOUT and h.get("role") == ""]
        if not kept:
            fail("本检出没有 run 留着的模拟器实例：xc.sh run ios|ipad …")
        return kept[0]["device"], False
    try:
        with open(FLEET) as f:
            role = json.load(f)[target]
    except (OSError, KeyError, ValueError):
        fail(f"{target} 不是 UDID，也不是 xc.sh fleet up 起的角色（{FLEET}）")
    return role["udid"], False


def axe(*args):
    p = subprocess.run(["axe", *args], capture_output=True, text=True)
    if p.returncode:
        fail(f"axe {args[0]} 失败：{(p.stderr or p.stdout).strip()}")
    return p.stdout


def read(udid, everything=False):
    """屏上有标签（或是输入框、按钮）的元素。AXe 的树含屏外页与零尺寸的重名分身：按框过滤，不然按标签点会点到别的页。"""
    tree = json.loads(axe("describe-ui", "--udid", udid))[0]
    screen = tree["frame"]
    found, seen = [], set()

    def walk(n):
        f = n["frame"]
        inside = f["width"] > 0 and f["height"] > 0 and f["x"] < screen["width"] and f["y"] < screen["height"] and f["x"] + f["width"] > 0 and f["y"] + f["height"] > 0
        label, value = n.get("AXLabel"), n.get("AXValue")
        if everything or (inside and (label or value or n["type"] in ("Button", "TextField", "TextArea"))):
            key = (n["type"], label, value, tuple(f[k] for k in ("x", "y", "width", "height")))
            if key not in seen:
                seen.add(key)
                found.append({"type": n["type"], "label": label, "value": value, "id": n.get("AXUniqueId"), "f": f})
        for c in n.get("children") or []:
            walk(c)

    walk(tree)
    return found


def matches(elements, key, kind=None):
    pool = [e for e in elements if kind in (None, e["type"])]
    if key.startswith("#"):
        return [e for e in pool if e["id"] == key[1:]]
    return [e for e in pool if e["label"] == key] or [e for e in pool if key in (e["label"] or "")]


def center(e):
    return e["f"]["x"] + e["f"]["width"] / 2, e["f"]["y"] + e["f"]["height"] / 2


def tap(udid, key, kind=None, nth=None):
    if re.fullmatch(r"\d+(\.\d+)?,\d+(\.\d+)?", key):
        x, y = map(float, key.split(","))
    else:
        hits = matches(read(udid), key, kind)
        if not hits:
            fail(f"屏上没有 {key}")
        if nth is None and len({center(e) for e in hits}) > 1:
            fail(f"屏上有 {len(hits)} 个 {key}，用 --nth 挑一个：" + "；".join(f"{i}: {e['type']} {tuple(round(v) for v in center(e))}" for i, e in enumerate(hits)))
        x, y = center(hits[nth or 0])
    # axe tap 报成功时，标题菜单的 PopUpButton、回复框常没反应（axe 1.8.0）；按下停一下再抬起才认
    axe("touch", "-x", str(x), "-y", str(y), "--down", "--up", "--delay", "0.12", "--udid", udid)


def drag(udid, start, end, points=6, rec=None):
    """返回抬手在片里的秒数（没录是 None）。"""
    (x0, y0), (x1, y1) = start, end
    steps = [f"touch -x {x0 + (x1 - x0) * i / points:.0f} -y {y0 + (y1 - y0) * i / points:.0f} --down" for i in range(points + 1)]
    steps.append(f"touch -x {x1:.0f} -y {y1:.0f} --up")
    recorder = began = None
    if rec:
        recorder = subprocess.Popen(["axe", "record-video", "--udid", udid, "--fps", "30", "--output", rec], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        if "Recording" not in recorder.stderr.readline():  # 开录时它先说这一句：片里的时间从这里起算
            fail(f"axe record-video 没开录（退出码 {recorder.wait()}）")
        began = time.time()
    axe("batch", "--udid", udid, *(a for s in steps for a in ("--step", s)))
    lifted = time.time()
    if recorder:
        time.sleep(2)
        recorder.send_signal(signal.SIGINT)
        recorder.communicate()
        return lifted - began


def key(udid, combo):
    parts = combo.lower().split("+")
    if parts[-1] not in KEYS or not set(parts[:-1]) <= set(MODS):
        fail(f"不认得 {combo}：修饰键 {' '.join(MODS)}，键 {' '.join(KEYS)}")
    mods, code = [MODS[m] for m in parts[:-1]], KEYS[parts[-1]]
    if mods:
        axe("key-combo", "--modifiers", ",".join(map(str, mods)), "--key", str(code), "--udid", udid)
    else:
        axe("key", str(code), "--udid", udid)


def type_in(udid, text):
    axe("type", text, "--udid", udid)
    try:
        return wait(udid, text, 5)
    except SystemExit:
        fail(f"打了 {text}，屏上没读到：输入框没有焦点？先 tap 它")


def bcu(*args):
    p = subprocess.run(["bcu", *args], capture_output=True, text=True)
    if p.returncode:
        fail(p.stderr.strip())
    return p.stdout


def observe(pid):
    """看一眼：(状态号, 截图路径, 有键盘焦点的元素或 None, 窗口的 ref)。"""
    state = json.loads(bcu("observe-ui", "--pid", str(pid), "--image", "always", "--json"))
    if "image" not in state:
        fail("bcu 截不到这扇窗（活预览托着的实例就是这样：从预览那一头操作）")
    focused = next((n for n in state["nodes"] if n.get("state", {}).get("focused")), None)
    return state["stateId"], state["image"]["path"], focused, state["nodes"][0]["ref"]


def act(pid, step, state=None, front=False, rec=None):
    """做一步并印出 bcu 的结论。带 ref 或坐标的要 state；用 find 的不给，bcu 现看现找。"""
    args = ["act-ui", json.dumps(step), *(("--state", state) if state else ("--pid", str(pid))), "--foreground" if front else "--headless"]
    if not rec:
        return sys.stdout.write(bcu(*args))
    from app_mac import wincap
    receipt = f"{rec}.ready"  # 首帧入片后 wincap 写它：片里的时间从这里起算
    if os.path.exists(receipt):
        os.remove(receipt)
    with open(READY) as f:
        size = f.read().split()[:2]
    recorder = subprocess.Popen([wincap(), "rec", str(pid), "4", *size, rec])
    while not os.path.exists(receipt):
        if recorder.poll() is not None:
            fail(f"没开录（wincap 退出码 {recorder.returncode}）")
        time.sleep(0.02)
    began = time.time()
    sys.stdout.write(bcu(*args))
    done = time.time() - began
    if recorder.wait():
        fail(f"录屏失败（wincap 退出码 {recorder.returncode}）")
    print(f"{rec}：动作在片里的前 {done:.2f} 秒内投出")


def mac(pid, cmd, args, opts, front):
    rec = opts.get("rec")
    if cmd == "tap" and re.fullmatch(r"\d+,\d+", args[0]):
        x, y = map(int, args[0].split(","))
        act(pid, [{"action": "click", "x": x, "y": y}], observe(pid)[0], front, rec)
    elif cmd == "tap":
        find = {"name": args[0], **({"role": opts["type"]} if "type" in opts else {}), **({"nth": int(opts["nth"])} if "nth" in opts else {})}
        act(pid, [{"action": "click", "find": find}], None, front, rec)
    elif cmd == "drag":
        start, end = ([int(v) for v in a.split(",")] for a in args[:2])
        hover = [{"action": "moveMouse", "x": start[0], "y": start[1]}, {"action": "wait", "ms": 300}] if front else []
        act(pid, [*hover, {"action": "drag", "path": [start, end]}], observe(pid)[0], front, rec)
    elif cmd in ("type", "key"):
        state, _, focused, window = observe(pid)
        if cmd == "type" and not focused:
            fail("没有元素拿着键盘焦点：先 tap 输入框")
        ref = focused["ref"] if focused else window
        act(pid, [{"action": "typeText", "ref": ref, "text": args[0]} if cmd == "type" else {"action": "keypress", "ref": ref, "keys": [args[0]]}], state, front, rec)
    elif cmd == "focus":
        state, _, focused, _ = observe(pid)
        if not focused:
            fail("没有元素拿着键盘焦点")
        raw = json.loads(bcu("inspect-ui", focused["ref"], "--state", state, "--json"))["node"]
        print("\t".join([focused["role"], focused.get("name") or "", str(raw.get("value") or ""), ",".join(str(round(raw["rect"][k])) for k in "xywh")]))
    elif cmd == "shot":
        print(observe(pid)[1])
    else:
        fail(__doc__)


def seen(target, text):
    """屏上有没有含 text 的标签或值（Mac 读 bcu 的观察）。"""
    ident, is_mac = resolve(target)
    if is_mac:
        # observe-ui 把大多数节点折起来（"N hidden"），找字用 search-ui
        out = subprocess.run(["bcu", "search-ui", "--pid", str(ident), "--text", text], capture_output=True, text=True).stdout
        return bool(re.match(r"[1-9]\d* of", out))  # 没找到也是退出码 0，只看"N of M matches"的 N
    return any(text in (e["label"] or "") or text in str(e["value"] or "") for e in read(ident))


def wait(target, text, seconds=20):
    """等到屏上出现 text；返回 (读到的时刻, 上一次没读到的时刻)，时刻是 time.time()，上一次没有为 None（报告里写成时间窗）。"""
    end, miss = time.time() + seconds, None
    while True:
        began = time.time()
        if seen(target, text):
            return time.time(), miss
        miss = began
        if time.time() >= end:
            fail(f"{seconds} 秒内 {target} 的屏上没出现 {text}")


def main(argv):
    if len(argv) < 2:
        fail(__doc__)
    target, cmd, rest = argv[0], argv[1], argv[2:]
    ident, is_mac = resolve(target)
    valued = ("--type", "--nth", "--rec")
    flags = {a for a in rest if a.startswith("--") and a not in valued}
    opts = {rest[i][2:]: rest[i + 1] for i in range(len(rest) - 1) if rest[i] in valued}
    args = [a for i, a in enumerate(rest) if not a.startswith("--") and not (i and rest[i - 1] in valued)]
    if cmd == "read" and is_mac:
        sys.stdout.write(bcu("observe-ui", "--pid", str(ident)))
    elif is_mac and cmd != "wait":
        mac(ident, cmd, args, opts, "--front" in flags)
    elif cmd == "read":
        for e in read(ident, "--all" in flags):
            print("\t".join([e["type"], e["label"] or "", "" if e["value"] is None else str(e["value"]), ",".join(str(round(e["f"][k])) for k in ("x", "y", "width", "height"))]))
    elif cmd == "tap":
        tap(ident, args[0], opts.get("type"), int(opts["nth"]) if "nth" in opts else None)
    elif cmd == "drag":
        start, end = (tuple(map(float, a.split(","))) for a in args[:2])
        at = drag(ident, start, end, *map(int, args[2:3]), rec=opts.get("rec"))
        if at is not None:
            print(f"{opts['rec']}：抬手在第 {at:.2f} 秒")
    elif cmd == "type":
        type_in(ident, args[0])
    elif cmd == "key":
        key(ident, args[0])
    elif cmd == "wait":
        began = time.time()
        at, _ = wait(target, args[0], float(args[1]) if len(args) > 1 else 20)
        print(f"{args[0]} 出现，等了 {at - began:.1f} 秒")
    elif cmd == "shot":
        axe("screenshot", "--udid", ident, "--output", args[0] if args else f"/tmp/ui-{target}.png")
    else:
        fail(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
