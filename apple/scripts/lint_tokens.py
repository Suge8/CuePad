#!/usr/bin/env python3
"""lint.sh 的一条规则（在 apple/ 下跑）：样式令牌每一档都进样式总览（`-CuePadScene tokens`，Debug/TokenSheet*.swift）。
令牌是一堆 static let，编译期列不全；这里按声明对总览里的引用（`Radius.chip`、`palette.ink`）。
字号与图标尺寸里写成 `: CGFloat` 的是字形背后的数，不单列；嵌套类型（Motion.Spring 这类）与函数不算。Elevation 是 CaseIterable，总览自己取全。
"""
import glob, re
member = r"^    (?:nonisolated )?static (?:let|var) (\w+)\b(?!: CGFloat)"
tokens = [
    ("App/AppGroup/Palette.swift", r"^    var (\w+): Color\??\s*\{", "palette"),
    ("App/AppGroup/Palette.swift", r"^    static let (\w+)\b", "Palette"),
    ("App/AppGroup/Motion.swift", member, "Motion"),
    ("App/Sources/UI/Shared/Theme/Radius.swift", r"^    static (?:let|var) (\w+)\b", "Radius"),
    ("App/Sources/UI/Shared/Theme/Spacing.swift", r"^    static let (\w+)\b", "Spacing"),
    ("App/Sources/UI/Shared/Theme/Glyph.swift", member, "Glyph"),
    ("App/Sources/UI/Shared/Theme/Typography.swift", member, "Typography"),
]
sheet = "".join(open(p, encoding="utf-8").read() for p in glob.glob("App/Sources/UI/Debug/TokenSheet*.swift"))
missing = sorted({f"{owner}.{name}" for path, pattern, owner in tokens
                  for name in re.findall(pattern, open(path, encoding="utf-8").read(), re.M)
                  if not re.search(rf"\b{owner}\.{name}\b", sheet)})
if missing:
    print("App/Sources/UI/Debug/TokenSheet*.swift 缺：" + "、".join(missing))
    print("  → 新加的令牌档放进样式总览（-CuePadScene tokens）的那一组：改一档截一张图就看得到整套\n")
    raise SystemExit(1)
