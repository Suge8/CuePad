#!/usr/bin/env python3
"""lint.sh 的一条规则（在 apple/ 下跑）：App/Tests 里每个有 @Test 的类型（连同它的 extension）都挂 .releasesLibraries。
资料库有没有在用例收尾时释放，只在这个作用域里查（LibraryRelease.swift）；Swift Testing 没有进程级的作用域，只能逐个套件挂。
在没挂的套件里建 TestApp 运行时也报错，这里补上运行时查不到的：要环境变量才跑的、经帮手间接建 TestApp 的套件。"""
import os, re, sys
# 顶层声明（行首起）；它的特性是紧挨在上面、到空行或注释为止的几行（特性可以跨行）
decl = re.compile(r"^(?:(?:nonisolated|final|private|fileprivate|public)\s+)*(?:struct|class|enum|actor|extension)\s+(\w+)", re.M)

def attributes(text, start):
    lines = text[:start].split("\n")[:-1]
    head = []
    while lines and lines[-1].strip() and not lines[-1].lstrip().startswith(("//", "}", "import", "#")):
        head.append(lines.pop())
    return "\n".join(head)

suites, marked = {}, set()
for folder, _, names in os.walk("App/Tests"):
    for name in names:
        if not name.endswith(".swift"): continue
        path = os.path.join(folder, name)
        text = open(path, encoding="utf-8").read()
        found = list(decl.finditer(text))
        for i, m in enumerate(found):
            end = found[i + 1].start() if i + 1 < len(found) else len(text)
            if re.search(r"@Test\b", text[m.end():end]):
                suites.setdefault(m[1], f"{path}:{text.count(chr(10), 0, m.start()) + 1}")
            if ".releasesLibraries" in attributes(text, m.start()):
                marked.add(m[1])
missing = sorted(set(suites) - marked)
for name in missing:
    print(f"{suites[name]}: 套件 {name} 要挂 @Suite(.releasesLibraries)：用例收尾时查它建过的资料库都释放了（LibraryRelease.swift）", file=sys.stderr)
sys.exit(1 if missing else 0)
