#!/usr/bin/env python3
"""lint.sh 的一条规则（在 apple/ 下跑）：Pi 桥扩展与 Swift 各写着一份、协议里没法只留一份的两样，要一致：
- 思考强度的档位与先后：扩展的 THINKING_LEVELS（它拿来验 CuePad 发来的档位）与 CueStore 的 ThinkingLevel（夹档按先后算）。
- 粗状态：扩展的 phaseOf（状态起点只在它变时前进，随状态报给 CuePad）与 WorkState.phase（CuePad 自己比前后两次状态）；
  扩展的每种状态按 PiWire 的对照换成 WorkState 后，两边得落在同一档。"""
import re, sys

sys.dont_write_bytecode = True
from _pi_extension import EXTENSION  # noqa: E402

INFO, EVENTS = f"{EXTENSION}/info.ts", f"{EXTENSION}/events.ts"
LEVELS, WORK, WIRE = "CuePadKit/Sources/CueStore/SessionParts.swift", "CuePadKit/Sources/CueStore/WorkState.swift", "CuePadKit/Sources/CueBridge/PiWire.swift"
# 扩展的粗状态名 → WorkState.phase 的数
PHASES = {"working": 0, "waiting": 1, "error": 2, "idle": 3}


def read(path): return open(path, encoding="utf-8").read()


def found(pattern, path, what, flags=0):
    hit = re.search(pattern, read(path), flags)
    if not hit: sys.exit(f"{path}：找不到{what}，lint_pi_mirror.py 认的写法变了就跟着改")
    return hit


problems = []
ts_levels = re.findall(r'"(\w+)"', found(r"const THINKING_LEVELS\b[^=]*=\s*\[([^\]]*)\]", INFO, " THINKING_LEVELS")[1])
swift_levels = re.findall(r"\w+", found(r"enum ThinkingLevel\b[^{]*\{\s*case ([\w, ]+)", LEVELS, " ThinkingLevel 的 case")[1])
if ts_levels != swift_levels:
    problems.append(f"思考强度：{INFO} 是 {ts_levels}，{LEVELS} 是 {swift_levels}")

body = found(r"export function phaseOf\b.*?\n\}", EVENTS, " phaseOf", re.S)[0]
default = found(r"default:\s*return \"(\w+)\"", EVENTS, " phaseOf 的 default")[1]
ts_phase = {}
for cases, phase in re.findall(r"((?:case \"\w+\":\s*)+)return \"(\w+)\"", body):
    for kind in re.findall(r'case "(\w+)"', cases): ts_phase[kind] = PHASES[phase]
kinds = re.findall(r'\{ kind: "(\w+)"', found(r"export type State =.*?;\n", EVENTS, " State", re.S)[0])

working = re.findall(r"\.(\w+)", found(r"var isWorking\b.*?case ([^:]+): true", WORK, " isWorking", re.S)[1])
phase_body = found(r"public var phase: Int \{.*?\n  \}", WORK, " WorkState.phase", re.S)[0]
numbered = {name: int(n) for name, n in re.findall(r"case \.(\w+): return (\d)", phase_body)}
other = int(re.search(r"default: return (\d)", phase_body)[1])
wire = {}
for names, case in re.findall(r'case ((?:"\w+",?\s*)+): \(\.(\w+)', read(WIRE)):
    for name in re.findall(r'"(\w+)"', names): wire[name] = case

names = {v: k for k, v in PHASES.items()}
for kind in kinds:
    if kind not in wire:
        problems.append(f"粗状态：扩展的状态 {kind} 在 {WIRE} 里没有对照")
        continue
    case = wire[kind]
    swift = 0 if case in working else numbered.get(case, other)
    ts = ts_phase.get(kind, PHASES[default])
    if ts != swift:
        problems.append(f"粗状态：{kind} 在 {EVENTS} 的 phaseOf 是 {names[ts]}，换成 WorkState.{case} 在 {WORK} 是 {names[swift]}")

if problems:
    print("\n".join(problems))
    print("  → 两边改成一样；改了扩展要升 EXTENSION_VERSION（lint_extension.py）")
    sys.exit(1)
