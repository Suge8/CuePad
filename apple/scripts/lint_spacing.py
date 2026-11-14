#!/usr/bin/env python3
"""lint.sh 的一条规则（在 apple/ 下跑）：间距只经 Spacing 的几档（棘轮清零后的全仓规则）：padding、safeAreaPadding、spacing:、EdgeInsets 的参数里不写数。
具名常量也查：名字说它是间距（gap、margin、inset、spacing、padding）或值是一组边距（EdgeInsets）的，写数就要在它上一行或行尾写一句为什么（组件几何、光学校准），
否则读 Spacing 的档——不然档外的数换个名字就绕过去了（Mac 浮层气泡的上边抄过一份工具栏高 52）。
用 Python 认括号：一次调用的参数里可能套着别的调用（三元式、加减），正则认不准哪段是参数。0 与按比例的乘除（size * 0.08、height / 2）不算
"""
import os, re
skip = re.compile(r"(?:^|/)Theme/|^App/Sources/UI/Debug/|^App/Widget/|/Tests/")
call = re.compile(r"\.(?:padding|safeAreaPadding)\(|\b(?:UI|NS)?EdgeInsets\(")
label = re.compile(r"\bspacing:\s*")
number = re.compile(r"(?<![\w.])\d+(?:\.\d+)?(?![\w.])")
role = re.compile(r"\bstatic\s+(?:let|var)\s+(?:\w*(?:[gG]ap|[mM]argin|[iI]nset|[sS]pacing|[pP]adding)\w*\s*:\s*CGFloat\s*(?:=|\{)|\w+(?:\s*:\s*\w*EdgeInsets)?\s*(?:=|\{)\s*(?:UI|NS)?EdgeInsets\()")
named = re.compile(r"\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:private|fileprivate|internal|public|nonisolated)\s+)*static\s+(?:let|var)\b")

def argument(code, start, stops):
    depth, i = 0, start
    while i < len(code):
        c = code[i]
        if c in "([{": depth += 1
        elif c in ")]}":
            if depth == 0: return code[start:i]
            depth -= 1
        elif c in stops and depth == 0: return code[start:i]
        i += 1
    return code[start:]

def literals(text):
    for m in number.finditer(text):
        if float(m.group()) == 0: continue
        before, after = text[:m.start()].rstrip(), text[m.end():].lstrip()
        if before.endswith(("*", "/")) or after.startswith("*"): continue
        yield m.group()

hits = []
for root in ("App", "CuePadKit"):
    for folder, _, names in os.walk(root):
        for name in names:
            path = os.path.join(folder, name)
            if not name.endswith(".swift") or skip.search(path): continue
            previous = ""
            for n, line in enumerate(open(path, encoding="utf-8"), 1):
                code = line.split("//", 1)[0]
                said, previous = previous.lstrip().startswith("//") or "//" in line, line
                if named.match(code):
                    m = role.search(code)
                    if m and root == "App" and not said and list(literals(code[m.end():])): hits.append(f"{path}:{n}:{line.strip()}")
                    continue
                found = [v for m in call.finditer(code) for v in literals(argument(code, m.end(), ""))]
                found += [v for m in label.finditer(code) for v in literals(argument(code, m.end(), ",{"))]
                if found: hits.append(f"{path}:{n}:{line.strip()}")
if hits:
    print("\n".join(hits))
    print("  → 间距只经 Spacing 的几档（Theme/Spacing.swift，按这段空隔开的是什么取）、ControlSize、Chrome 与组件里有名字的常量：padding、safeAreaPadding、spacing:、EdgeInsets 的参数里写的数是又一套手感，"
          "不在档上的按角色就近落档；确是组件几何或光学校准的提成 static let，写一句为什么。0 与按比例的乘除（size * 0.08、height / 2）不算\n")
    raise SystemExit(1)
