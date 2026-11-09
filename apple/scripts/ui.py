#!/usr/bin/env python3
"""模拟器里按元素操作界面：读、点、输入、等文字、截图（AXe 的薄封装，docs/verify.md「模拟器里按元素操作」）。
用法：ui.py <UDID|iphone|ipad|mac> <命令> …，iphone、ipad、mac 是 `xc.sh fleet up` 起的那一台（fleet.json）。
  read [--all]               屏上的元素，每行 类型⇥标签⇥值⇥x,y,宽,高（点）；--all 连屏外的与没标签的一起列
  tap <标签|#id|x,y> [--type T] [--nth N] [--physical]   按元素点它的中心：标签先全等后包含，只数屏上的；有几个就报错列出，--nth 从 0 起挑一个
  paste <文字>                把文字放进模拟器剪贴板再 ⌘V：中文、表情都行（axe type 只认美式键盘）
  key <cmd+n|esc|…>           组合键：修饰键 cmd ctrl alt shift，键 a–z 0–9 return esc tab space delete
  wait <文字> [秒=20]          读到标签或值包含它为止，打印用时；超时以 1 退出
  shot [图.png]               截图
mac 只有 read（bcu observe-ui，折叠）与 wait（bcu search-ui），都按 PID。不靠固定等待：点完用 wait 等结果。
"""
import json
import os
import re
import subprocess
import sys
import time

FLEET = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), ".derived/fleet/fleet.json")
KEYS = {**{c: 4 + i for i, c in enumerate("abcdefghijklmnopqrstuvwxyz")}, **{c: 30 + i for i, c in enumerate("1234567890")},
        "return": 40, "esc": 41, "delete": 42, "tab": 43, "space": 44}
MODS = {"ctrl": 224, "shift": 225, "alt": 226, "cmd": 227}


def fail(message):
    print(message, file=sys.stderr)
    raise SystemExit(1)


def resolve(target):
    """UDID，或 fleet 角色（返回 (UDID 或 PID, 是不是 Mac)）。"""
    if re.fullmatch(r"[0-9A-F-]{36}", target):
        return target, False
    try:
        with open(FLEET) as f:
            role = json.load(f)[target]
    except (OSError, KeyError, ValueError):
        fail(f"{target} 不是 UDID，也不是 xc.sh fleet up 起的角色（{FLEET}）")
    return (role["pid"], True) if role["platform"] == "mac" else (role["udid"], False)


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
    if key.startswith("#"):
        hits = [e for e in elements if e["id"] == key[1:]]
    else:
        hits = [e for e in elements if e["label"] == key] or [e for e in elements if key in (e["label"] or "")]
    return [e for e in hits if kind in (None, e["type"])]


def center(e):
    return e["f"]["x"] + e["f"]["width"] / 2, e["f"]["y"] + e["f"]["height"] / 2


def tap(udid, key, kind=None, nth=None, physical=False):
    if re.fullmatch(r"\d+(\.\d+)?,\d+(\.\d+)?", key):
        x, y = map(float, key.split(","))
    else:
        hits = matches(read(udid), key, kind)
        if not hits:
            fail(f"屏上没有 {key}")
        if nth is None and len({center(e) for e in hits}) > 1:
            fail(f"屏上有 {len(hits)} 个 {key}，用 --nth 挑一个：" + "；".join(f"{i}: {e['type']} {tuple(round(v) for v in center(e))}" for i, e in enumerate(hits)))
        x, y = center(hits[nth or 0])
    axe("tap", "-x", str(x), "-y", str(y), "--udid", udid, *(["--tap-style", "physical"] if physical else []))


def key(udid, combo):
    parts = combo.lower().split("+")
    mods, code = [MODS[m] for m in parts[:-1]], KEYS[parts[-1]]
    if mods:
        axe("key-combo", "--modifiers", ",".join(map(str, mods)), "--key", str(code), "--udid", udid)
    else:
        axe("key", str(code), "--udid", udid)


def paste(udid, text):
    subprocess.run(["xcrun", "simctl", "pbcopy", udid], input=text, text=True, check=True)
    key(udid, "cmd+v")


def seen(target, text):
    """屏上有没有含 text 的标签或值（Mac 读 bcu 的观察）。"""
    ident, is_mac = resolve(target)
    if is_mac:
        # observe-ui 把大多数节点折起来（"N hidden"），找字用 search-ui
        out = subprocess.run(["bcu", "search-ui", "--pid", str(ident), "--text", text], capture_output=True, text=True).stdout
        return bool(re.match(r"[1-9]\d* of", out))  # 没找到也是退出码 0，只看"N of M matches"的 N
    return any(text in (e["label"] or "") or text in (e["value"] or "") for e in read(ident))


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
    if is_mac and cmd not in ("read", "wait"):
        fail("mac 只有 read 与 wait")
    flags = {a for a in rest if a.startswith("--") and a not in ("--type", "--nth")}
    opts = {rest[i][2:]: rest[i + 1] for i in range(len(rest) - 1) if rest[i] in ("--type", "--nth")}
    args = [a for i, a in enumerate(rest) if not a.startswith("--") and not (i and rest[i - 1] in ("--type", "--nth"))]
    if cmd == "read" and is_mac:
        sys.stdout.write(subprocess.run(["bcu", "observe-ui", "--pid", str(ident)], capture_output=True, text=True).stdout)
    elif cmd == "read":
        for e in read(ident, "--all" in flags):
            print("\t".join([e["type"], e["label"] or "", e["value"] or "", ",".join(str(round(e["f"][k])) for k in ("x", "y", "width", "height"))]))
    elif cmd == "tap":
        tap(ident, args[0], opts.get("type"), int(opts["nth"]) if "nth" in opts else None, "--physical" in flags)
    elif cmd == "paste":
        paste(ident, args[0])
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
