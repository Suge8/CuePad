#!/usr/bin/env python3
"""lint.sh 的一条规则（在 apple/ 下跑）：注释里带到期或退役意味的写法（TODO、FIXME、过渡、临时方案、"…后删""等…再删"）必须在同一段注释里附工单编号（#123）：
没有编号的"以后再删"没人认领，也就永远没人删。现行含义不拦（"临时目录""动画过渡""提交后删旧文件"不在词表里）；词表只收向前看的退役说法，新说法漏了就补在 WORDS 里。
注释 = Swift/TypeScript 的 // 与 /* … */ 行，Python/shell 的 # 行；连续的注释行算一段。"""
import os, re, sys

sys.dont_write_bytecode = True
WORDS = re.compile(
    r"\b(?:TODO|FIXME|HACK|XXX)\b"
    r"|过渡(?:期|方案|写法|兼容|阶段|代码)|临时(?:方案|做法|兼容|补丁|绕过|办法|写法|垫片)|暂时(?:保留|留着|兼容|先|这样)|迟早|待(?:删|移除|下线|清理)"
    r"|等[^，。；（）]{0,20}(?:发布|上线|稳定|合入|都升|都更新|过期|没人用|不再有人)[^，。；（）]{0,12}再(?:删|去掉|移除|拿掉)"
    r"|(?:发布|上线|稳定|都升级|都更新|没人用|不再有人用|迁移完|全部迁移)[^，。；（）]{0,12}(?:之后|以后|后)(?:就|可以|再|即可)?(?:删|去掉|移除|拿掉|下线)"
    r"|(?:以后|日后|将来)(?:就|可以|再|应该|会)?(?:删|去掉|移除|拿掉|下线)")
TICKET = re.compile(r"#\d+|issues/\d+")
SLASH = re.compile(r"(?<![:\w\"'])//(.*)|^\s*/\*+(.*)|^\s*\*(?!/)(.*)")
HASH = re.compile(r"^\s*#(?!\[|!)(.*)")
SKIP = re.compile(r"(?:^|/)(?:lint\w*\.(?:py|sh)|\.derived|\.build)(?:/|$)")


def comment(path, line):
    pattern = HASH if path.endswith((".py", ".sh")) else SLASH
    match = pattern.search(line)
    return next((g for g in match.groups() if g is not None), None) if match else None


hits = []
for root in ("App", "CuePadKit", "scripts"):
    for folder, dirs, names in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".build", ".derived")]
        for name in names:
            path = os.path.join(folder, name)
            if not name.endswith((".swift", ".py", ".sh", ".ts")) or SKIP.search(path): continue
            lines = open(path, encoding="utf-8").read().splitlines()
            block, start = [], 0
            for n, line in enumerate(lines + [""], 1):
                text = comment(path, line) if n <= len(lines) else None
                if text is not None:
                    if not block: start = n
                    block.append((n, text))
                    continue
                if block and not any(TICKET.search(t) for _, t in block):
                    hits += [f"{path}:{k}:{t.strip()}" for k, t in block if WORDS.search(t)]
                block = []
if hits:
    print("\n".join(hits))
    print("  → 注释里的到期或退役写法要附工单编号（同一段注释里写 #123）：没有编号的“以后再删”没人认领。已到期的连代码一起删；没有工单就先开一张（gh issue create）\n")
    sys.exit(1)
