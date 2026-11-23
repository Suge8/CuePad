#!/usr/bin/env python3
"""发布入口（xc.sh release 经它进 release-<平台>.sh）：全机每个平台一把发布锁持有到发布结束，每次尝试一个新目录，源码取自固定提交。
用法：release-context.py run <mac|ios> [提交] [--dry-run] [--resume <公证 id>]   拿锁、建或找回尝试目录（CUEPAD_RELEASE_OUT），再 exec 发布脚本；不给提交就发本检出的 HEAD
      release-context.py seal <尝试目录> <归档> <release_versions 的输出…>  归档与导出产物都要符合快照的 bundle id 与本次版本，打印构建号
      release-context.py id <尝试目录>                                     打印 submission.json 里的公证 ID
会上传的发布（新发的与 --resume 找回的，不含 --dry-run）只认主干那一遍云端检查全绿的提交（verified）。
发布凭据只在这台 Mac，锁不跨机器。恢复只认 submission.json 的公证 ID 唯一匹配：响应缺失或不完整就是结果未知，不猜、不重投。
"""
import json, os, plistlib, re, subprocess, sys, tarfile, tempfile, time, zipfile
from pathlib import Path

sys.dont_write_bytecode = True
import _lock as lock  # noqa: E402
from app_env import APPLE, CHECKOUT, RUNTIME  # noqa: E402

RELEASES = Path(APPLE) / ".derived/release"
USAGE = "用法：xc.sh release mac [提交] [--dry-run] [--resume <公证 id>] | xc.sh release ios [提交]"


def fail(message):
    sys.exit(f"发布：{message}")


def notary_id(attempt):
    try:
        found = json.loads((attempt / "submission.json").read_text())["id"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return found if isinstance(found, str) and found else None


def hold(platform):
    """全机每个平台一把，持有到发布结束（exec 后由发布脚本和它起的进程持有，全部结束才放）；占着就列出持有者、以 75 退出，不排队。"""
    lock.hold(f"{RUNTIME}/release-{platform}.lock", f"{platform} 发布（全机）", f"这台 Mac 已有 {platform} 发布在运行，等它结束再发", 0)


def verified(commit, platform):
    """合并前的本机签核只跑真 Agent 的冒烟、不跑 iOS；全量只有合并进主干后云端那一遍（swift.yml），用户拿到的构建只从它全绿的提交出。
    只认主干上的运行：分支上手动触发的那一遍用的是分支自己的工作流定义。还在跑就在这里等到它出结果（合并后那一遍约一刻钟）。"""
    waiting = False
    while True:
        runs = json.loads(subprocess.check_output(
            ["gh", "run", "list", "--workflow", "swift.yml", "--branch", "main", "--commit", commit, "--json", "status,conclusion,url,event"],
            cwd=CHECKOUT, text=True))
        runs = [run for run in runs if run["event"] != "pull_request"]  # 别的仓库名叫 main 的分支提的 PR 也记成 main
        if any(run["conclusion"] == "success" for run in runs):
            return
        running = [run for run in runs if run["status"] != "completed"]
        if not running:
            break
        if not waiting:
            print(f"{commit[:9]} 的主干检查还在跑，等它出结果：{running[0]['url']}", file=sys.stderr, flush=True)
        waiting = True
        time.sleep(60)
    seen = "；".join(f"{run['conclusion'] or run['status']} {run['url']}" for run in runs) or "这个提交在主干上没有跑过（不在主干上，或排队时被后来的合并顶掉）"
    green = [run for run in json.loads(subprocess.check_output(
        ["gh", "run", "list", "--workflow", "swift.yml", "--branch", "main", "--status", "success", "--limit", "5", "--json", "headSha,displayTitle,event"],
        cwd=CHECKOUT, text=True)) if run["event"] != "pull_request"]
    hint = f"要发的改动已在全绿的提交里就指定它发（最近全绿：{green[0]['headSha'][:9]} {green[0]['displayTitle']}）：xc.sh release {platform} {green[0]['headSha'][:9]}；" if green else ""
    fail(f"{commit[:9]} 的主干检查没有全绿，不发布：{seen}。{hint}红了先修主干（runner 自己崩的就 gh run rerun <id> --failed）；"
         "没跑过就从主干最新的提交发，或 gh workflow run swift.yml --ref main 补跑")


def attempt(platform, resume, uploads, commit):
    if subprocess.run(["git", "-C", CHECKOUT, "status", "--porcelain", "--untracked-files=no"],
                      capture_output=True, text=True, check=True).stdout:
        fail("工作区有没提交的改动，不发布；在干净的检出里发")
    attempts = RELEASES / f"{platform}-attempts"
    if resume:
        matches = [path.parent for path in attempts.glob("*/submission.json") if notary_id(path.parent) == resume]
        if not matches:
            fail(f"公证结果未知：没有哪次尝试的 submission.json 记着 {resume}；保留全部尝试，核实苹果的提交记录，不猜 ID、不重新提交")
        if len(matches) > 1:
            fail(f"公证 ID {resume} 不唯一：{', '.join(map(str, matches))}；保留全部尝试，核实后手工处理")
        if uploads:  # 找回的可能是 --dry-run 留下的：那时没核对
            verified((matches[0] / "commit").read_text().strip(), platform)
        return matches[0]
    found = subprocess.run(["git", "-C", CHECKOUT, "rev-parse", "--verify", "--quiet", f"{commit or 'HEAD'}^{{commit}}"], capture_output=True, text=True)
    if found.returncode:
        fail(f"不认得提交 {commit}：先 git fetch origin main")
    commit = found.stdout.strip()
    if uploads:
        verified(commit, platform)
    attempts.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix=time.strftime("%y%m%d-%H%M%S-"), dir=attempts))
    (out / "commit").write_text(commit + "\n")
    # 只取提交里的文件：未跟踪与被忽略的本地源码进不了产物
    with subprocess.Popen(["git", "-C", CHECKOUT, "archive", commit], stdout=subprocess.PIPE) as source:
        with tarfile.open(fileobj=source.stdout, mode="r|") as archive:
            archive.extractall(out / "source", filter="data")
    if source.returncode:
        fail("git archive 失败")
    return out


def run(platform, args):
    rest, resume, commit = [], None, None
    while args:
        flag = args.pop(0)
        if platform == "mac" and flag == "--resume" and args:
            resume = args.pop(0)
        elif platform == "mac" and flag == "--dry-run":
            rest.append(flag)
        elif not flag.startswith("-") and commit is None:
            commit = flag
        else:
            fail(USAGE)
    if resume and commit:
        fail("--resume 发的是那次尝试记着的提交，不再指定提交")
    hold(platform)
    out = attempt(platform, resume, uploads="--dry-run" not in rest, commit=commit)
    print(f"发布尝试：{out}（提交 {(out / 'commit').read_text().strip()[:9]}）", file=sys.stderr, flush=True)
    script = f"{APPLE}/scripts/release-{platform}.sh"
    os.execve(script, [script, *(rest if platform == "mac" else ["testflight"])], dict(os.environ, CUEPAD_RELEASE_OUT=str(out)))


def info(path):
    if path.suffix == ".ipa":
        with zipfile.ZipFile(path) as package:
            return plistlib.loads(package.read("Payload/CuePad.app/Info.plist"))
    return plistlib.loads((path / "Contents/Info.plist").read_bytes())


def seal(out, archive, versions):
    settings = dict(value.split("=", 1) for value in versions)
    config = (out / "source/apple/App/Config/Signing.xcconfig").read_text()
    expected = {"CFBundleIdentifier": re.search(r"^CUEPAD_APP_ID *= *(\S+)", config, re.M)[1],
                "CFBundleVersion": settings["CURRENT_PROJECT_VERSION"],
                "CFBundleShortVersionString": settings["MARKETING_VERSION"]}
    app = archive / "Products/Applications/CuePad.app"
    mac = out.parent.name == "mac-attempts"
    archived = plistlib.loads((app / ("Contents/Info.plist" if mac else "Info.plist")).read_bytes())
    exported = info(out / ("export/CuePad.app" if mac else "export/CuePad.ipa"))
    for key, value in expected.items():
        if archived.get(key) != value or exported.get(key) != value:
            fail(f"归档或导出产物的 {key} 与快照身份或本次版本不一致")
    print(expected["CFBundleVersion"])


def main():
    command, *args = sys.argv[1:] or [""]
    if command == "run" and args and args[0] in ("mac", "ios"):
        run(args[0], args[1:])
    elif command == "seal":
        seal(Path(args[0]), Path(args[1]), args[2:])
    elif command == "id":
        print(notary_id(Path(args[0])) or fail("公证结果未知：submission.json 缺失或不完整；保留这次尝试，核实苹果的提交记录，不猜 ID、不重新提交"))
    else:
        fail(USAGE)


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        fail(error)
