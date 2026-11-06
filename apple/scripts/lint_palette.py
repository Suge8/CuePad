#!/usr/bin/env python3
# 落地页与 App 同一套颜色：落地页令牌里与 Palette 同名的（--signature-fill 对 signatureFill），浅、深两档都要与色板相等。
# 只认两种写法：#rrggbb，与 color-mix(in srgb, var(--另一个令牌) N%, transparent)（对应色板里的 .opacity）
# 用法（lint.sh 在 apple 目录里调）：lint_palette.py <Palette.swift> <landing base.css>
import re, sys
palette, css = (open(p).read() for p in sys.argv[1:])

def side(expr, dark):
    "色板里一档的值：('#rrggbb', 1.0) 或 (底色令牌名, 透明度)；认不出返回 None"
    m = re.fullmatch(r"Color\(hex: 0x(\w{6})\)", expr.strip())
    if m: return ("#" + m[1].lower(), 1.0)
    m = re.fullmatch(r"(\w+)\.opacity\((.+)\)", expr.strip())
    if not m: return None
    a = re.sub(r"^highContrast \? [\d.]+ : ", "", m[2].strip())
    a = amounts.get(a, a)
    d = re.fullmatch(r"\(?dark \? ([\d.]+) : ([\d.]+)\)?", a)
    a = d[1 if dark else 2] if d else a
    return (m[1], float(a)) if re.fullmatch(r"[\d.]+", a) else None

# 透明度写成具名量的（ink.opacity(fillAmount)），先换回它的式子
amounts = dict(re.findall(r"var (\w+): Double \{ (.+?) \}", palette))
theirs = {}
for name, body in re.findall(r"^    var (\w+): Color \{(.*?)\}$", palette, re.M | re.S):
    body = " ".join(body.split())
    if m := re.fullmatch(r"dark \? (.+?) : (.+)", body):
        theirs[name] = (side(m[2], False), side(m[1], True))
    elif m := re.search(r"case \(false, false\): (Color\(hex: 0x\w{6}\)).*case \(true, false\): (Color\(hex: 0x\w{6}\))", body):
        theirs[name] = (side(m[1], False), side(m[2], True))
    else:
        theirs[name] = (side(body, False), side(body, True))

def css_side(v):
    v = v.strip()
    if re.fullmatch(r"#[0-9a-fA-F]{6}", v): return (v.lower(), 1.0)
    m = re.fullmatch(r"color-mix\(in srgb, var\(--([\w-]+)\) ([\d.]+)%, transparent\)", v)
    return (re.sub(r"-(\w)", lambda c: c[1].upper(), m[1]), round(float(m[2]) / 100, 4)) if m else None

bad = []
for name, value in re.findall(r"^\s*--([\w-]+):\s*([^;]+);", css, re.M):
    key = re.sub(r"-(\w)", lambda c: c[1].upper(), name)
    if key not in theirs: continue
    value = " ".join(value.split())
    m = re.fullmatch(r"light-dark\(\s*(.+?),\s*((?:#|color-mix).+)\)", value)
    ours = (css_side(m[1]), css_side(m[2])) if m else (css_side(value),) * 2
    if None in ours or None in theirs[key]:
        bad.append(f"--{name}：认不出写法（落地页 {value}）")
    elif ours != theirs[key]:
        fmt = lambda p: " / ".join(f"{c}" + ("" if a == 1 else f" {a:g}") for c, a in p)
        bad.append(f"--{name}：落地页 {fmt(ours)}，色板 {fmt(theirs[key])}（浅 / 深）")
if bad:
    print("landing/src/styles/base.css\n" + "\n".join("  " + b for b in bad))
    print("  → 落地页与 App 只有一套颜色，出处是 Palette.swift：改色先改色板，再把落地页同名令牌改成同值；落地页自己要的颜色另起不与色板同名的令牌\n")
    sys.exit(1)
