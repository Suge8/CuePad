"""固定 GitHub Release 的公开变化：远端 Git 引用互斥，拿到后再核对线上版本与来源。
锁不自动过期：被杀或断网后留下引用，须确认原发布进程已结束才可清除，不能让迟到上传越过新持有者。
"""
from pathlib import Path
import os
import re
import subprocess
import tempfile
from urllib.parse import urlparse
import uuid
import xml.etree.ElementTree as ET


LOCK = "refs/tags/cuepad-publication-lock"


def run(*args, env=None):
    return subprocess.check_output([str(arg) for arg in args], text=True, env=env).strip()


def remote_git(repo):
    return ["git", "-C", str(repo), "-c", "credential.helper=",
            "-c", "credential.https://github.com.helper=!gh auth git-credential"]


def package_version(name, asset):
    match = re.fullmatch(re.escape(asset.removesuffix(".zip")) + r"-(\d+)\.zip", name)
    return int(match[1]) if match else None


def enclosure(path):
    root = ET.parse(path).getroot()
    entries = list(root.iter("enclosure"))
    if len(entries) != 1:
        raise ValueError("更新源应只有一个 enclosure")
    return entries[0].attrib["url"]


def remote_source(repo, remote, version):
    ref = f"refs/tags/mac/{version}"
    refs = dict(line.split()[::-1] for line in run(*remote_git(repo), "ls-remote", remote, ref, ref + "^{}").splitlines())
    return refs.get(ref + "^{}", refs.get(ref))


def check_current(out, repo, remote, github, release, asset, version, source):
    target_source = remote_source(repo, remote, version)
    if target_source and target_source != source:
        raise ValueError(f"远端版本 {version} 的来源提交不匹配")
    names = run("gh", "release", "view", release, "-R", github, "--json", "assets", "--jq", ".assets[].name").splitlines()
    versions = [value for name in names if (value := package_version(name, asset)) is not None]
    if "appcast.xml" in names:
        with tempfile.TemporaryDirectory(dir=out) as directory:
            run("gh", "release", "download", release, "-R", github, "--pattern", "appcast.xml", "--dir", directory)
            current = package_version(Path(urlparse(enclosure(Path(directory) / "appcast.xml")).path).name, asset)
            if current is None:
                raise ValueError("远端更新源没有可核对的构建号，停止发布")
            versions.append(current)
    if not versions:
        if names:
            raise ValueError("远端资产没有可核对的版本，停止发布")
        return names, target_source
    current = max(versions)  # 中断在包上传后、更新源替换前，也不让旧版删除这份较新产物。
    previous_source = target_source if current == version else remote_source(repo, remote, current)
    if not previous_source:
        raise ValueError(f"远端版本 {current} 缺少来源标签，停止发布")
    if version < current:
        raise ValueError(f"拒绝发布旧版 {version}：远端已经是 {current}")
    return names, target_source


def publish(out, repo, github, release, asset, download, title, notes, *, context, built):
    remote = f"https://github.com/{github}.git"
    source = context["source"]
    version = int(built["CFBundleVersion"])
    # 每次尝试用不同对象；已有 tag 的 push 必定拒绝，不能把 up-to-date 当成拿到了锁。
    token = run("git", "-C", repo, "commit-tree", f"{source}^{{tree}}", "-p", source,
                "-m", f"CuePad publication {uuid.uuid4()}",
                env=dict(os.environ, GIT_AUTHOR_NAME="CuePad Release", GIT_AUTHOR_EMAIL="release@cue-pad.com",
                         GIT_COMMITTER_NAME="CuePad Release", GIT_COMMITTER_EMAIL="release@cue-pad.com"))
    with (out / "publication-locks").open("a") as receipt:
        receipt.write(token + "\n")
    print(f"准备申请远端发布锁：{token}（记录在 {out / 'publication-locks'}）", flush=True)
    acquired = subprocess.run([*remote_git(repo), "push", remote, f"{token}:{LOCK}"])
    if acquired.returncode:
        raise ValueError(f"远端发布锁申请未确认，可能已取得 {LOCK}；本次对象 {token}，核对远端与保留记录，不能绕过锁上传")
    print(f"已取得公开资产发布锁：{token}（mac/{version}）", flush=True)
    release_lock = True
    try:
        old_assets, target_source = check_current(out, repo, remote, github, release, asset, version, source)
        # 公开写入报错可能只是响应丢失；留锁，不能让下一位与远端尚未结束的请求交错。
        release_lock = False
        # 先公开来源标签，之后中断的更新源/包也始终有可核对的来源。
        if not target_source:
            run(*remote_git(repo), "push", remote, f"{source}:refs/tags/mac/{version}")
        update = out / f"{asset.removesuffix('.zip')}-{built['CFBundleVersion']}.zip"
        feed = out / "appcast.xml"
        for path in (update, feed, out / asset):
            run("gh", "release", "upload", release, path, "-R", github, "--clobber")
        for name in old_assets:
            if package_version(name, asset) is not None and name != update.name:
                run("gh", "release", "delete-asset", release, name, "-R", github, "-y")
        run("gh", "release", "edit", release, "-R", github, "--title", title, "--notes", notes)
        check = out / "check"
        check.mkdir(exist_ok=True)
        run("curl", "-fsSL", "-o", check / "appcast.xml", built["SUFeedURL"])
        run("curl", "-fsSL", "-o", check / "update.zip", enclosure(check / "appcast.xml"))
        run("curl", "-fsSL", "-o", check / asset, f"{download}/{asset}")
        for downloaded, original in ((check / "appcast.xml", feed), (check / "update.zip", update), (check / asset, out / asset)):
            run("cmp", downloaded, original)
        run(out / "source/apple/scripts/sparkle.sh", "verify", check / "update.zip", check / "appcast.xml")
        release_lock = True
    finally:
        if release_lock:
            # 删除也带预期对象；清锁绝不能误删另一持有者的引用。
            run(*remote_git(repo), "push", f"--force-with-lease={LOCK}:{token}", remote, f":{LOCK}")
        else:
            print(f"公开写入未确认完成，保留发布锁 {token}；确认原请求已结束后再条件清锁恢复", flush=True)
