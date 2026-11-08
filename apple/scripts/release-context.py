#!/usr/bin/env python3
"""发布上下文：固定提交快照，封存导出产物，公证 id 只绑定该次提交的 zip。
版本只读产物 Info.plist；context.json 记录来源与摘要，不另存版本。
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def save(out, context):
    temporary = out / "context.json.tmp"
    temporary.write_text(json.dumps(context, indent=2) + "\n")
    temporary.replace(out / "context.json")


def load(out):
    if not (out / "context.json").is_file():
        raise ValueError("缺少发布记录，重新归档；不能从当前 HEAD 猜测旧产物来源")
    return json.loads((out / "context.json").read_text())


def digest(path):
    result = hashlib.sha256()
    paths = sorted(path.rglob("*")) if path.is_dir() else [path]
    for item in paths:
        name = str(item.relative_to(path)) if item != path else item.name
        if item.is_symlink():
            data = [name, "link", os.readlink(item)]
        elif item.is_file():
            with item.open("rb") as stream:
                checksum = hashlib.file_digest(stream, "sha256").hexdigest()
            data = [name, item.stat().st_mode & 0o777, checksum]
        else:
            continue
        result.update(json.dumps(data).encode() + b"\n")
    return result.hexdigest()


def artifact(out, platform):
    return out / ("artifact/CuePad.app" if platform == "mac" else "export/CuePad.ipa")


def info(path, platform):
    if platform == "mac":
        return plistlib.loads((path / "Contents/Info.plist").read_bytes())
    with zipfile.ZipFile(path) as package:
        return plistlib.loads(package.read("Payload/CuePad.app/Info.plist"))


def submission_id(out):
    try:
        response = json.loads((out / "submission.json").read_text())
        submission = response["id"]
        if not isinstance(submission, str) or not submission:
            raise ValueError("missing id")
        return submission
    except (OSError, ValueError, KeyError, TypeError):
        raise ValueError("公证结果未知：响应缺失或不完整；保留产物，核实苹果提交记录后再处理，不能猜测 ID 或重新提交") from None


def verify(out, context, submission=None):
    platform = context["platform"]
    path = artifact(out, platform)
    if not path.exists() or digest(path) != context.get("artifactDigest"):
        raise ValueError("发布产物与记录不匹配，重新归档")
    if platform == "mac":
        package = out / "notarize.zip"
        if not package.is_file() or digest(package) != context.get("notaryDigest"):
            raise ValueError("公证 zip 与记录不匹配，重新归档")
        if submission is not None and submission != submission_id(out):
            raise ValueError("公证 ID 与发布记录不匹配")
    return info(path, platform)


def release_tag(repo, context, version, create=False):
    tag = f"{context['platform']}/{version}"
    ref = f"refs/tags/{tag}"
    subprocess.run(["git", "check-ref-format", ref], check=True)
    found = subprocess.run(["git", "-C", str(repo), "show-ref", "--verify", "--quiet", ref])
    if found.returncode == 0:
        if git(repo, "rev-parse", f"{ref}^{{commit}}") != context["source"]:
            raise ValueError(f"标签 {tag} 已指向另一来源提交")
    elif found.returncode != 1:
        raise ValueError(f"无法查询标签 {tag}")
    elif create:
        git(repo, "tag", tag, context["source"])
    return tag


def prepare(repo, out, platform, submission):
    if git(repo, "status", "--porcelain", "--untracked-files=no"):
        raise ValueError("工作区有没提交的改动，不发布；在干净的检出里发")
    if submission:
        context = load(out)
        if context["platform"] != platform:
            raise ValueError("发布记录的平台不匹配")
        built = verify(out, context, submission)
        release_tag(repo, context, built["CFBundleVersion"])
    else:
        context = {"source": git(repo, "rev-parse", "HEAD"), "platform": platform}
        if out.exists():
            previous = load(out)
            started = previous.get("archive") or any(path.name not in ("context.json", "source") for path in out.iterdir())
            if not previous.get("completed") and started:
                raise ValueError("已有未完成的发布，保留原产物；请恢复，或明确将整个产物目录移走后再开始")
            shutil.rmtree(out)
        out.mkdir(parents=True)
        save(out, context)
    source = context["source"]
    # 不用现有工作树，未跟踪与被忽略的源码均进不了归档。
    snapshot = out / "source"
    if snapshot.exists():
        shutil.rmtree(snapshot)
    snapshot.mkdir()
    with tempfile.TemporaryFile() as stream:
        subprocess.run(["git", "-C", str(repo), "archive", source], stdout=stream, check=True)
        stream.seek(0)
        with tarfile.open(fileobj=stream) as archive:
            archive.extractall(snapshot, filter="data")
    print(source)


def seal(out, archive, versions):
    context = load(out)
    platform = context["platform"]
    path = artifact(out, platform)
    built = info(path, platform)
    archived = archive / "Products/Applications/CuePad.app" / ("Contents/Info.plist" if platform == "mac" else "Info.plist")
    original = plistlib.loads(archived.read_bytes())
    settings = dict(value.split("=", 1) for value in versions)
    config = (out / "source/apple/App/Config/Signing.xcconfig").read_text()
    bundle = re.search(r"^CUEPAD_APP_ID *= *(\S+)", config, re.M)[1]
    expected = {"CFBundleIdentifier": bundle, "CFBundleVersion": settings["CURRENT_PROJECT_VERSION"],
                "CFBundleShortVersionString": settings["MARKETING_VERSION"]}
    for key, value in expected.items():
        if built.get(key) != value or original.get(key) != value:
            raise ValueError(f"归档或导出产物的 {key} 与快照身份/本次构建输入不一致")
    context.update(archive=str(archive), artifactDigest=digest(path))
    if platform == "mac":
        context["notaryDigest"] = digest(out / "notarize.zip")
    save(out, context)
    verify(out, context)


def main():
    command, *args = sys.argv[1:]
    if command == "run":
        repo, platform, script, *arguments = args
        locks = Path(repo) / "apple/.derived/release"
        locks.mkdir(parents=True, exist_ok=True)
        with (locks / f"{platform}.lock").open("w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError(f"此检出已有 {platform} 发布在运行") from None
            return subprocess.call([script, *arguments], pass_fds=(lock.fileno(),))
    if command == "prepare":
        repo, out, platform, *submission = args
        prepare(Path(repo), Path(out), platform, submission[0] if submission else None)
        return 0
    out = Path(args[0])
    if command == "archive":
        context = load(out)
        context["archive"] = args[1]
        save(out, context)
    elif command == "seal":
        seal(out, Path(args[1]), args[2:])
    elif command == "submission":
        verify(out, load(out))
        print(submission_id(out))
    elif command == "complete":
        context = load(out)
        verify(out, context)
        context["completed"] = True
        save(out, context)
    elif command == "publish":
        from _release_publish import publish
        context = load(out)
        built = verify(out, context)
        release_tag(Path(args[1]), context, built["CFBundleVersion"])
        publish(out, Path(args[1]), *args[2:], context=context, built=built)
        release_tag(Path(args[1]), context, built["CFBundleVersion"], create=True)
        context["completed"] = True
        save(out, context)
    elif command in ("verify", "tag"):
        context = load(out)
        built = verify(out, context)
        tag = release_tag(Path(args[1]), context, built["CFBundleVersion"], create=command == "tag")
        print(tag if command == "tag" else built["CFBundleVersion"])
    else:
        raise ValueError(f"未知操作：{command}")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError, zipfile.BadZipFile) as error:
        sys.exit(f"发布上下文：{error}")
