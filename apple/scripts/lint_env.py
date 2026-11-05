#!/usr/bin/env python3
"""lint.sh 的一条规则（在 apple/ 下跑）：环境值（@Entry、EnvironmentKey 的 defaultValue）的类型里带闭包的，要可比。
读它的视图在环境值变了时重算，SwiftUI 比不了闭包：放它的那一层每更新一次（每次都新建闭包），读它的视图就全部重算。
直接是闭包的编译器报警告（xc.sh check 见警告就失败），包在结构体里的编译器不报，这里查：
带闭包存储属性的结构体要声明 Equatable 并自己写 ==，按"是哪一个"比（ClosePanel 按浮层，ChatJump 按对话栏）；类按引用比，不查。"""
import os, re
texts = {}
for root in ("App", "CuePadKit"):
    for folder, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d != ".build"]
        for name in names:
            if name.endswith(".swift"):
                path = os.path.join(folder, name)
                texts[path] = "\n".join(line.split("//", 1)[0] for line in open(path, encoding="utf-8").read().split("\n"))

def body(text, start):
    "从 start 处的 { 起到配对的 } 为止"
    depth = 0
    for i in range(start, len(text)):
        if text[i] == "{": depth += 1
        elif text[i] == "}":
            depth -= 1
            if depth == 0: return text[start + 1:i]
    return text[start + 1:]

structs = {}
for path, text in texts.items():
    for m in re.finditer(r"\bstruct\s+(\w+)([^{]*)\{", text):
        structs.setdefault(m[1], []).append((path, text.count("\n", 0, m.start()) + 1, m[2], body(text, m.end() - 1)))
conforms = {m[1]: m[2] for text in texts.values() for m in re.finditer(r"\bextension\s+(?:[\w.]+\.)?(\w+)\s*:([^{]*)\{", text)}
equals = {m[1] for text in texts.values() for m in re.finditer(r"\bextension\s+(?:[\w.]+\.)?(\w+)[^{]*\{", text) if "static func ==" in body(text, m.end() - 1)}

stored_closure = re.compile(r"^(?:\s*@\w+(?:\([^)]*\))?)*\s*(?:(?:private|fileprivate|internal|public|nonisolated(?:\(unsafe\))?)(?:\(set\))?\s+)*(?:let|var)\s+\w+\s*:[^={]*->[^{]*$")

def depth1(text):
    "只留结构体自己那一层（不进嵌套类型与方法体）"
    out, depth = [], 0
    for c in text:
        if c == "}": depth -= 1
        if depth == 0: out.append(c)
        if c == "{": depth += 1
    return "".join(out)

def type_of(annotation, default):
    if annotation:
        return annotation.strip()
    chain = re.match(r"\s*([A-Z][\w.]*)", default or "")
    if not chain: return None
    parts = chain[1].split(".")
    return next((p for p in reversed(parts) if p in structs), parts[0])

values = []
for path, text in texts.items():
    for m in re.finditer(r"@Entry\s+var\s+(\w+)\s*(?::\s*([^=\n]+?))?\s*(?:=\s*([^\n]+))?$", text, re.M):
        values.append((path, text.count("\n", 0, m.start()) + 1, type_of(m[2], m[3])))
    for m in re.finditer(r"\bEnvironmentKey\b[^{]*\{", text):
        d = re.search(r"static\s+(?:let|var)\s+defaultValue\s*(?::\s*([^=\n]+?))?\s*(?:=\s*([^\n]+))?$", body(text, m.end() - 1), re.M)
        if d: values.append((path, text.count("\n", 0, m.start()) + 1, type_of(d[1], d[2])))

hits = set()
for path, line, kind in values:
    if not kind: continue
    kind = kind.rstrip("?! ")
    if "->" in kind:
        hits.add(f"{path}:{line}: 环境值直接是闭包")
        continue
    name = re.split(r"[<\s.]", kind.split(".")[-1])[0]
    for decl_path, decl_line, header, members in structs.get(name, []):
        if not any(stored_closure.match(l) for l in depth1(members).split("\n")): continue
        equatable = re.search(r"\b(Equatable|Hashable)\b", header + conforms.get(name, ""))
        if not equatable or ("static func ==" not in members and name not in equals):
            hits.add(f"{decl_path}:{decl_line}: {name} 带闭包、作环境值（{path}:{line}），没有自己写的 Equatable ==")
if hits:
    print("\n".join(sorted(hits)))
    print("  → 环境值里的闭包没法比：放它的那一层每更新一次，读它的视图全部重算（#74）。能从 Workspace 的方法直接调就别经环境交（LaneAdd）；"
          "非交不可的包一层结构体，声明 Equatable、自己写 ==，按\"是哪一个\"比（ClosePanel 按浮层的 token，ChatJump 按对话栏）。"
          "比出相等时读它的视图留着旧闭包，所以相等的两个必须做同一件事\n")
    raise SystemExit(1)
