#!/usr/bin/env python3
"""发布入口（xc.sh release 经它进 release-<平台>.sh）：全机每个平台一把发布锁持有到发布结束，每次尝试一个新目录，源码取自固定提交。
用法：release-context.py run <mac|ios> [--dry-run] [--resume <公证 id>]   拿锁、建或找回尝试目录（CUEPAD_RELEASE_OUT），再 exec 发布脚本
      release-context.py seal <尝试目录> <归档> <release_versions 的输出…>  归档与导出产物都要符合快照的 bundle id 与本次版本，打印构建号
      release-context.py id <尝试目录>                                     打印 submission.json 里的公证 ID
新的发布（不含 --dry-run 与 --resume）只认主干那一遍云端检查全绿的提交（verified）。
发布凭据只在这台 Mac，锁不跨机器。恢复只认 submission.json 的公证 ID 唯一匹配：响应缺失或不完整就是结果未知，不猜、不重投。
"""
import fcntl, json, os, plistlib, re, subprocess, sys, tarfile, tempfile, time, zipfile
from pathlib import Path

sys.dont_write_bytecode = True
from app_env import APPLE, CHECKOUT, RUNTIME  # noqa: E402

RELEASES = Path(APPLE) / ".derived/release"
USAGE = "用法：xc.sh release mac [--dry-run] [--resume <公证 id>] | xc.sh release ios"


def fail(message):
    sys.exit(f"发布：{message}")


def notary_id(attempt):
    try:
        found = json.loads((attempt / "submission.json").read_text())["id"]
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return found if isinstance(found, str) and found else None


def hold(platform):
    os.makedirs(RUNTIME, exist_ok=True)
    path = Path(RUNTIME) / f"release-{platform}.lock"
    lock = os.open(path, os.O_RDWR | os.O_CREAT)
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        fail(f"这台 Mac 已有 {platform} 发布在运行（{path.read_text().strip()}），等它结束再发")
    os.ftruncate(lock, 0)
    os.write(lock, f"{CHECKOUT}，PID {os.getpid()}\n".encode())
    os.set_inheritable(lock, True)  # exec 后由发布脚本和它起的进程持有，全部结束才放


def verified(commit):
    """合并前的本机签核只跑真 Agent 的冒烟、不跑 iOS；全量只有合并进主干后云端那一遍（swift.yml），用户拿到的构建只从它全绿的提交出。"""
    runs = json.loads(subprocess.check_output(
        ["gh", "run", "list", "--workflow", "swift.yml", "--commit", commit, "--json", "status,conclusion,url"], cwd=CHECKOUT, text=True))
    if any(run["conclusion"] == "success" for run in runs):
        return
    seen = "；".join(f"{run['conclusion'] or run['status']} {run['url']}" for run in runs) or "这个提交没有跑过（不在主干上，或排队时被后来的合并顶掉）"
    fail(f"{commit[:9]} 的主干检查没有全绿，不发布：{seen}。在跑就等它跑完；红了先修主干（runner 自己崩的就 gh run rerun <id> --failed）；没跑过就从主干最新的提交发，或 gh workflow run swift.yml 补跑")


def attempt(platform, resume, gated):
    fixed = RELEASES / platform
    if fixed.exists() or fixed.is_symlink():
        fail(f"旧版留下的 {fixed} 还在：是链接就删掉；是目录先确认里面没有待恢复的公证（submission.json），再手工删掉或移走（docs/release.md）")
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
        return matches[0]
    commit = subprocess.check_output(["git", "-C", CHECKOUT, "rev-parse", "HEAD"], text=True).strip()
    if gated:
        verified(commit)
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
    rest, resume = [], None
    while args:
        flag = args.pop(0)
        if platform == "mac" and flag == "--resume" and args:
            resume = args.pop(0)
        elif platform == "mac" and flag == "--dry-run":
            rest.append(flag)
        else:
            fail(USAGE)
    hold(platform)
    out = attempt(platform, resume, gated="--dry-run" not in rest)
    print(f"发布尝试：{out}", file=sys.stderr, flush=True)
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
