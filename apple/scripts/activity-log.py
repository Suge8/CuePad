#!/usr/bin/env python3
"""xc.sh activity-log 的只读 CloudKit 入口：只签/起隔离副本，不启动 AppDelegate、不打开或同步资料库。"""
import pathlib
import plistlib
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
from app_env import APPLE, BUNDLE_ID
from provision import KEYCHAIN, PROFILES_DIR, local_identity

app = pathlib.Path(sys.argv[1])
output = pathlib.Path(sys.argv[2]).resolve()
root = pathlib.Path(APPLE) / ".derived-activity-reader"
copy = root / "Build/Products/Debug/CuePad.app"
if output == root or root in output.parents:
    raise SystemExit("输出文件不能放在用后清理的活动取证副本目录里")


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


try:
    identity = local_identity("Developer ID Application")
    if not identity:
        raise SystemExit("缺少 Developer ID Application 签名身份（见 docs/release.md）")
    profile = None
    for candidate in pathlib.Path(PROFILES_DIR).glob("*.provisionprofile"):
        decoded = run("security", "cms", "-D", "-i", str(candidate), capture_output=True).stdout
        values = plistlib.loads(decoded)
        if values.get("Name") == "CuePad macOS DeveloperID":
            profile = (candidate, values)
            break
    if not profile:
        raise SystemExit("缺少 CuePad macOS DeveloperID 描述文件")
    if root.exists():
        shutil.rmtree(root)
    shutil.copytree(app, copy, symlinks=True)
    shutil.copyfile(profile[0], copy / "Contents/embedded.provisionprofile")
    entitlements = {
        key: value for key, value in profile[1]["Entitlements"].items()
        if key in ["com.apple.application-identifier", "com.apple.developer.team-identifier",
                   "com.apple.developer.icloud-container-identifiers"]
    }
    entitlements["com.apple.developer.icloud-container-environment"] = "Production"
    expected = "iCloud." + BUNDLE_ID
    if expected not in entitlements.get("com.apple.developer.icloud-container-identifiers", []):
        raise SystemExit("描述文件不属于当前 App 的 iCloud 容器")
    entitlements["com.apple.developer.icloud-container-identifiers"] = [expected]
    entitlements["com.apple.developer.icloud-services"] = ["CloudKit"]
    entitlement_file = root / "reader.entitlements"
    entitlement_file.write_bytes(plistlib.dumps(entitlements))
    run("codesign", "--force", "--keychain", KEYCHAIN, "--sign", identity, "--entitlements", str(entitlement_file), str(copy))
    run(sys.executable, str(pathlib.Path(APPLE) / "scripts/app.py"), "exec", str(copy), str(root / "library"),
        "--", "-CuePadActivityDiagnosticsRead", str(output), timeout=60)
finally:
    if root.exists():
        shutil.rmtree(root)
