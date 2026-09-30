#!/usr/bin/env python3
"""经 App Store Connect API 开通标识、能力、证书与描述文件（Xcode 自动签名的 API 密钥管不了 App Group 与 iCloud 容器，
所以 iOS 走手动签名：证书与描述文件都由这里创建）。幂等，可重复运行。

用法：provision.py <ids|identity|profiles|device|devid-csr|devid-import|unlock|all> ...
  ids                           创建 App ID（主 App、分享扩展、小组件）并开启能力（App Groups、iCloud、推送）
  identity <distribution|development>  本机没有该证书的私钥时创建证书，放进专用钥匙串
  profiles                      创建并安装 iOS 描述文件（App Store；有已登记设备时再建 Development）
  device <UDID> <名称>          登记一台真机
  devid-csr                     为 Developer ID Application 证书生成私钥与 CSR（证书只有账号持有人能创建，见 README）
  devid-import <.cer 路径>      把网页上下载的 Developer ID 证书连同私钥导入专用钥匙串
  unlock                        解锁专用钥匙串并加入搜索列表（发布脚本用）
  all                           ids → identity distribution → profiles
凭据见 asc.py；私钥只存在专用钥匙串（~/.appstoreconnect/cuepad-signing.keychain-db），不落盘明文。
"""
import base64, json, os, plistlib, secrets, subprocess, sys, tempfile

sys.dont_write_bytecode = True

sys.path.insert(0, os.path.dirname(__file__))
import asc

HOME = os.path.expanduser("~/.appstoreconnect")
KEYCHAIN = os.path.join(HOME, "cuepad-signing.keychain-db")
KEYCHAIN_PASS = os.path.join(HOME, "keychain.pass")
PROFILES_DIR = os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles")

APP_ID = "com.sugeh.cuepad"
# (标识, 名称, 平台, 描述文件名前缀, 能力)
BUNDLES = [
    (APP_ID, "CuePad", "UNIVERSAL", "CuePad", ["APP_GROUPS", "PUSH_NOTIFICATIONS", "ICLOUD"]),
    (APP_ID + ".share", "CuePad Share", "IOS", "CuePad Share", ["APP_GROUPS"]),
    (APP_ID + ".widget", "CuePad Widget", "IOS", "CuePad Widget", ["APP_GROUPS"]),
]
CERTIFICATES = {  # 种类 → (证书类型, 钥匙串里的身份名前缀, 描述文件类型)
    "distribution": ("DISTRIBUTION", "Apple Distribution", "IOS_APP_STORE"),
    "development": ("DEVELOPMENT", "Apple Development", "IOS_APP_DEVELOPMENT"),
}
PROFILE_SUFFIX = {"distribution": "iOS AppStore", "development": "iOS Development"}


def api(method, path, body=None):
    status, text = asc.request(method, path, json.dumps(body) if body else None)
    data = json.loads(text) if text.strip() else {}
    if status >= 300:
        detail = data.get("errors", [{}])[0].get("detail", text[:200])
        raise SystemExit(f"{method} {path} 失败（HTTP {status}）：{detail}")
    return data


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout


# ---- 钥匙串 ----

def keychain_password():
    if not os.path.exists(KEYCHAIN_PASS):
        os.makedirs(HOME, exist_ok=True)
        with open(os.open(KEYCHAIN_PASS, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as f:
            f.write(secrets.token_hex(24))
    return open(KEYCHAIN_PASS).read().strip()


def unlock_keychain():
    password = keychain_password()
    if not os.path.exists(KEYCHAIN):
        run("security", "create-keychain", "-p", password, KEYCHAIN)
        run("security", "set-keychain-settings", KEYCHAIN)  # 不自动上锁
    run("security", "unlock-keychain", "-p", password, KEYCHAIN)
    current = [line.strip().strip('"') for line in run("security", "list-keychains", "-d", "user").splitlines()]
    if KEYCHAIN not in current:
        run("security", "list-keychains", "-d", "user", "-s", KEYCHAIN, *current)
    return password


def local_identity(prefix):
    unlock_keychain()
    out = run("security", "find-identity", "-v", "-p", "codesigning", KEYCHAIN)
    for line in out.splitlines():
        if f'"{prefix}:' in line:
            return line.split('"')[1]
    return None


def import_identity(cert_der, key_pem):
    password = unlock_keychain()
    with tempfile.TemporaryDirectory() as tmp:
        key_path, cert_path = os.path.join(tmp, "k.pem"), os.path.join(tmp, "c.cer")
        with open(os.open(key_path, os.O_WRONLY | os.O_CREAT, 0o600), "wb") as f:
            f.write(key_pem)
        open(cert_path, "wb").write(cert_der)
        run("security", "import", key_path, "-k", KEYCHAIN, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security")
        run("security", "import", cert_path, "-k", KEYCHAIN)
    run("security", "set-key-partition-list", "-S", "apple-tool:,apple:,codesign:", "-s", "-k", password, KEYCHAIN)


# ---- 命令 ----

def ensure_ids():
    existing = {x["attributes"]["identifier"]: x["id"] for x in api("GET", "/v1/bundleIds?limit=200")["data"]}
    ids = {}
    for identifier, name, platform, _, capabilities in BUNDLES:
        if identifier not in existing:
            body = {"data": {"type": "bundleIds", "attributes": {"identifier": identifier, "name": name, "platform": platform}}}
            existing[identifier] = api("POST", "/v1/bundleIds", body)["data"]["id"]
            print(f"已创建 App ID {identifier}")
        ids[identifier] = existing[identifier]
        enabled = {x["attributes"]["capabilityType"] for x in api("GET", f"/v1/bundleIds/{ids[identifier]}/bundleIdCapabilities")["data"]}
        for capability in capabilities:
            if capability in enabled:
                continue
            attributes = {"capabilityType": capability}
            if capability == "ICLOUD":
                attributes["settings"] = [{"key": "ICLOUD_VERSION", "options": [{"key": "XCODE_6", "enabled": True}]}]
            body = {"data": {"type": "bundleIdCapabilities", "attributes": attributes,
                             "relationships": {"bundleId": {"data": {"type": "bundleIds", "id": ids[identifier]}}}}}
            api("POST", "/v1/bundleIdCapabilities", body)
            print(f"已开启 {identifier} 的 {capability}")
    print("App ID 与能力就绪：" + "、".join(ids))
    return ids


def ensure_identity(kind):
    cert_type, prefix, _ = CERTIFICATES[kind]
    if local_identity(prefix):
        print(f"本机已有 {prefix} 证书")
        return
    with tempfile.TemporaryDirectory() as tmp:
        key, csr = os.path.join(tmp, "k.pem"), os.path.join(tmp, "r.csr")
        run("openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", csr, "-subj", f"/CN=CuePad {kind}/O=CuePad")
        body = {"data": {"type": "certificates", "attributes": {"certificateType": cert_type, "csrContent": open(csr).read()}}}
        data = api("POST", "/v1/certificates", body)["data"]
        import_identity(base64.b64decode(data["attributes"]["certificateContent"]), open(key, "rb").read())
    print(f"已创建并导入 {data['attributes']['name']}")


def local_cert_ids(prefix, cert_type):
    """API 里属于本机私钥的证书 id：按证书内容与钥匙串里的证书比对。"""
    pem = run("security", "find-certificate", "-a", "-c", prefix, "-p", KEYCHAIN)
    local = {base64.b64encode(ssl_der(block)).decode() for block in pem.split("-----END CERTIFICATE-----") if "BEGIN" in block}
    remote = api("GET", f"/v1/certificates?filter[certificateType]={cert_type}&limit=200")["data"]
    return [x["id"] for x in remote if x["attributes"]["certificateContent"] in local]


def ssl_der(block):
    b64 = block.split("-----BEGIN CERTIFICATE-----")[1]
    return base64.b64decode("".join(b64.split()))


def ensure_profiles():
    ids = ensure_ids()
    os.makedirs(PROFILES_DIR, exist_ok=True)
    devices = [x["id"] for x in api("GET", "/v1/devices?filter[platform]=IOS&filter[status]=ENABLED&limit=200")["data"]]
    for kind, (cert_type, prefix, profile_type) in CERTIFICATES.items():
        if kind == "development" and not devices:
            print("没有已登记的 iOS 设备：跳过 Development 描述文件（provision.py device <UDID> <名称> 登记后再运行）")
            continue
        certs = local_cert_ids(prefix, cert_type)
        if not certs:
            print(f"本机没有 {prefix} 证书的私钥：先运行 provision.py identity {kind}")
            continue
        for identifier, _, _, base, _ in BUNDLES:
            name = f"{base} {PROFILE_SUFFIX[kind]}"
            for old in api("GET", f"/v1/profiles?filter[name]={name.replace(' ', '%20')}&limit=50")["data"]:
                api("DELETE", f"/v1/profiles/{old['id']}")
            relationships = {"bundleId": {"data": {"type": "bundleIds", "id": ids[identifier]}},
                             "certificates": {"data": [{"type": "certificates", "id": c} for c in certs]}}
            if kind == "development":
                relationships["devices"] = {"data": [{"type": "devices", "id": d} for d in devices]}
            body = {"data": {"type": "profiles", "attributes": {"name": name, "profileType": profile_type}, "relationships": relationships}}
            profile = api("POST", "/v1/profiles", body)["data"]["attributes"]
            content = base64.b64decode(profile["profileContent"])
            path = os.path.join(PROFILES_DIR, profile["uuid"] + ".mobileprovision")
            open(path, "wb").write(content)
            print(f"已安装描述文件「{name}」")


DEVID_KEY = os.path.join(HOME, "developer-id.key")
DEVID_CSR = os.path.join(HOME, "developer-id.csr")


def devid_csr():
    if not os.path.exists(DEVID_KEY):
        run("openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-keyout", DEVID_KEY, "-out", DEVID_CSR,
            "-subj", "/CN=CuePad Developer ID/O=CuePad")
        os.chmod(DEVID_KEY, 0o600)
    print(DEVID_CSR)


def devid_import(cer_path):
    if not os.path.exists(DEVID_KEY):
        raise SystemExit("没有待配对的私钥：先运行 provision.py devid-csr，并用它生成的 CSR 在网页上创建证书")
    raw = open(cer_path, "rb").read()
    der = raw if not raw.startswith(b"-----") else ssl_der(raw.decode())
    import_identity(der, open(DEVID_KEY, "rb").read())
    os.remove(DEVID_KEY)
    os.remove(DEVID_CSR)
    print("已导入：" + (local_identity("Developer ID Application") or "（没有识别到 Developer ID Application 身份，检查证书类型）"))


def register_device(udid, name):
    if api("GET", f"/v1/devices?filter[udid]={udid}")["data"]:
        print(f"设备 {name} 已登记")
        return
    body = {"data": {"type": "devices", "attributes": {"name": name, "udid": udid, "platform": "IOS"}}}
    api("POST", "/v1/devices", body)
    print(f"已登记设备 {name}")


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "ids":
        ensure_ids()
    elif command == "identity":
        ensure_identity(sys.argv[2])
    elif command == "profiles":
        ensure_profiles()
    elif command == "device":
        register_device(sys.argv[2], sys.argv[3])
    elif command == "devid-csr":
        devid_csr()
    elif command == "devid-import":
        devid_import(sys.argv[2])
    elif command == "unlock":
        unlock_keychain()
    elif command == "all":
        ensure_ids(); ensure_identity("distribution"); ensure_profiles()
    else:
        sys.exit(__doc__)
