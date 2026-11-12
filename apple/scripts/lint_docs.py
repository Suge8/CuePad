#!/usr/bin/env python3
"""lint.sh 的一条规则（在 apple/ 下跑，要 git）：文档指向的东西得还在，改名、删掉后文档当场变红，不靠人记得回头改。
查三样：
0. 仓库里的 Markdown 都在清单里（AGENT_DOCS、OTHER_DOCS）。
1. 给 agent 读的文档（AGENT_DOCS）里反引号中的名字：类型与成员（`Workspace.speak`）、文件（`sync-bench.py`，可带 *）、
   启动参数（-CuePadScene）、环境变量（CUEPAD_…，TEST_RUNNER_ 前缀不算）在源码里找得到；后两样连代码块里的也查。
2. 源码与文档里写的文档路径（apple/…、relay/… 等开头的 .md）存在。
3. 「<文档>.md「节名」」指的那一节存在（WORDS.md 认加粗的词条）。
系统与第三方的名字（源码里没出现的）列在 FOREIGN；新加一个之前先确认它不是自家改了名的类型。"""
import fnmatch, os, re, subprocess, sys

sys.dont_write_bytecode = True
ROOT = os.path.abspath("..")
# 仓库里的 Markdown 只有这些：新加一份先想它是不是该写成报错、lint 或代码旁的注释（AGENTS.md「文档」），确要加再登记
AGENT_DOCS = """AGENTS.md WORDS.md landing/AGENTS.md design/tools/AGENTS.md relay/README.md apple/scripts/AGENTS.md
apple/App/Strings/AGENTS.md apple/CloudKit/AGENTS.md apple/App/Config/AGENTS.md apple/CuePadKit/Sources/CueBridge/README.md""".split()
OTHER_DOCS = "README.md README.zh-CN.md THIRD-PARTY-NOTICES.md .github/CONTRIBUTING.md .github/SECURITY.md".split()
DOCS = re.compile("^(?:" + "|".join(map(re.escape, AGENT_DOCS)) + ")$")
SOURCE = (".swift", ".ts", ".mjs", ".py", ".sh", ".xcconfig", ".plist", ".entitlements", ".svelte", ".css", ".yml", ".pbxproj")
FOREIGN = set("""
AXStatusLabel preferences.plist MemoryDenyWriteExecute LoadCredential
""".split())

tracked = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.split("\n")
tracked = [p for p in tracked if p and os.path.isfile(os.path.join(ROOT, p))]
read = lambda p: open(os.path.join(ROOT, p), encoding="utf-8", errors="replace").read()
texts = {p: read(p) for p in tracked if p.endswith(SOURCE + (".md",))}
words = set()
for path, text in texts.items():
    if not path.endswith(".md"):
        words.update(re.findall(r"[A-Za-z_][A-Za-z0-9_]*", text))
names = {os.path.basename(p) for p in tracked}

TYPE = re.compile(r"^[A-Z][A-Za-z0-9]*[a-z][A-Za-z0-9]*(?:[.+][A-Za-z_][A-Za-z0-9_]*)*(?:\(.*\))?$")
FILE = re.compile(r"^[\w+*./-]*[\w*]\.(?:swift|py|sh|ts|mjs|xcconfig|ckdb|entitlements|plist|xcstrings|svelte|css)$")
ARG = re.compile(r"(?<![\w-])-(CuePad[A-Za-z]+)")
ENV = re.compile(r"\b(?:TEST_RUNNER_)?(CUEPAD_[A-Z][A-Z_]*[A-Z])\b")
MD = re.compile(r"(?<![\w/.~-])((?:docs|apple|relay|landing|design)/[\w./+-]*\.md)")
SECTION = re.compile(r"((?:[\w.-]+/)*[\w.-]+\.md)\)?((?:「[^」\n]+」)+)")
hits = [f"{p}: 这份 Markdown 不在清单里（lint_docs.py 的 AGENT_DOCS）" for p in tracked if p.endswith(".md") and p not in AGENT_DOCS + OTHER_DOCS]


def known(token):
    token = re.sub(r"\(.*\)$", "", token)
    if token + ".swift" in names:
        return True
    parts = [p for p in re.split(r"[.+]", token) if p]
    return all(p in words or p in FOREIGN for p in parts)


def has_file(token):
    if token in FOREIGN:
        return True
    if "/" in token:
        return any(fnmatch.fnmatch(p, "*" + token.lstrip("./")) for p in tracked)
    return any(fnmatch.fnmatch(n, token) for n in names)


def resolve(ref, source):
    for base in (os.path.dirname(source), "", "docs"):
        path = os.path.normpath(os.path.join(base, ref))
        if path in texts:
            return path
    return None


for path, text in sorted(texts.items()):
    for number, line in enumerate(text.split("\n"), 1):
        where = f"{path}:{number}"
        if DOCS.match(path):
            for token in re.findall(r"`([^`\n]+)`", line):
                token = token.strip()
                if FILE.match(token):
                    has_file(token) or hits.append(f"{where}: 没有文件 {token}")
                elif TYPE.match(token) and len(token) > 3:
                    known(token) or hits.append(f"{where}: 源码里没有 {token}")
            for arg in ARG.findall(line):
                arg in words or hits.append(f"{where}: 没有启动参数 -{arg}")
            for env in ENV.findall(line):
                env in words or hits.append(f"{where}: 源码里没有环境变量 {env}")
        if "Pi 的 docs/" not in line and not path.endswith("lint_docs.py"):
            for ref in MD.findall(line):
                ref in texts or hits.append(f"{where}: 没有文档 {ref}")
            for ref, sections in SECTION.findall(line):
                target = resolve(ref, path)
                if not target or not DOCS.match(target):
                    continue
                heads = set(re.findall(r"^#+ +(.+?) *$", texts[target], re.M))
                heads |= set(re.findall(r"\*\*(.+?)\*\*", texts[target])) if target == "WORDS.md" else set()
                for section in re.findall(r"「([^」]+)」", sections):
                    section in heads or hits.append(f"{where}: {target} 没有「{section}」这一节")

if hits:
    print("\n".join(hits))
    print("  → 文档指向的名字、文件或章节不在了：改了名就一起改这一处，删了就把这句也删掉（规则在 lint_docs.py 头注释）\n")
    sys.exit(1)
