#!/usr/bin/env python3
"""测试用的真 Agent：按 CuePadKit/Tests/agents.json 钉住的版本装进专用缓存，不碰用户 PATH 上的版本与登录。

  xc.sh agents status [家…]     列出每家钉住的版本、装没装、装在哪
  xc.sh agents install [家…]    装缺的（不给家就全装）；装好的不重装

缓存根是 CUEPAD_AGENTS_CACHE（默认 ~/Library/Caches/cuepad-agents），每家一个 <家>/<版本>/ 目录，可执行文件在其中的 bin/<命令>
（npm 装的旁边还有装它用的 node）。
先装进同级的临时目录、跑通 --version 再改名过去：目录在就是装完整了（测试只认这个，CueTestSupport 的 PinnedAgent）。
npm 用缓存里自己的配置与下载缓存（不读用户的 ~/.npmrc，免得带上那里的令牌）；代理照环境变量。
"""
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

MANIFEST = Path(__file__).resolve().parent.parent / "CuePadKit/Tests/agents.json"
ROOT = Path(os.environ.get("CUEPAD_AGENTS_CACHE") or Path.home() / "Library/Caches/cuepad-agents")


def target(name, spec):
    return ROOT / name / spec["version"]


def npm_install(spec, into):
    npm_home = ROOT / ".npm"
    npm_home.mkdir(parents=True, exist_ok=True)
    (npm_home / "npmrc").touch()
    env = {**os.environ, "npm_config_userconfig": str(npm_home / "npmrc"), "npm_config_cache": str(npm_home / "cache"),
           "npm_config_update_notifier": "false", "npm_config_fund": "false", "npm_config_audit": "false"}
    packages = [f"{spec['npm']}@{spec['version']}"] + spec.get("with", [])
    subprocess.run(["npm", "install", "--prefix", str(into), "--no-save", "--loglevel=error", *packages], env=env, check=True)
    (into / "bin").mkdir()
    (into / "bin" / spec["bin"]).symlink_to(Path("../node_modules/.bin") / spec["bin"])
    # 装它的那个 Node 一起放进 bin：测试只把 bin 放进 PATH（不用跑测试的环境里的 PATH）
    (into / "bin/node").symlink_to(shutil.which("node"))


def url_install(spec, into):
    with urllib.request.urlopen(spec["url"]) as response:
        data = response.read()
    digest = hashlib.sha256(data).hexdigest()
    if digest != spec["sha256"]:
        sys.exit(f"{spec['url']} 的 sha256 是 {digest}，清单里是 {spec['sha256']}")
    (into / "bin").mkdir(parents=True)
    binary = into / "bin" / spec["bin"]
    binary.write_bytes(data)
    binary.chmod(0o755)


def install(name, spec):
    final = target(name, spec)
    if final.exists():
        return
    final.parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{spec['version']}-", dir=final.parent))
    try:
        print(f"装 {name} {spec['version']} → {final}", file=sys.stderr)
        (npm_install if "npm" in spec else url_install)(spec, staging)
        with tempfile.TemporaryDirectory() as home:
            subprocess.run([str(staging / "bin" / spec["bin"]), "--version"], check=True, stdout=subprocess.DEVNULL, timeout=120,
                           env={**os.environ, "HOME": home, "GROK_DISABLE_AUTOUPDATER": "1", "DISABLE_AUTOUPDATER": "1"})
        staging.rename(final)
    finally:
        shutil.rmtree(staging, ignore_errors=True)


def main():
    command, *names = sys.argv[1:] or ["status"]
    manifest = json.loads(MANIFEST.read_text())
    unknown = set(names) - manifest.keys()
    if command not in ("status", "install") or unknown:
        sys.exit(f"用法：xc.sh agents <status|install> [{'|'.join(manifest)}…]" + (f"（没有这家：{', '.join(unknown)}）" if unknown else ""))
    failed = []
    for name in names or manifest:
        spec = manifest[name]
        if command == "install":
            try:
                install(name, spec)
            except (subprocess.CalledProcessError, subprocess.TimeoutExpired, OSError) as error:
                failed.append(name)
                print(f"{name} {spec['version']} 没装上：{error}", file=sys.stderr)
        where = target(name, spec)
        print(f"{name:9} {spec['version']:12} {'已装 ' + str(where) if where.exists() else '没装'}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
