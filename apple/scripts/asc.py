#!/usr/bin/env python3
"""App Store Connect API 的最小客户端：用 ~/.appstoreconnect/cuepad.env 里的密钥签 JWT。
用法：asc.py get <路径> | post <路径> <JSON> ；只输出响应，绝不输出密钥。
"""
import base64, json, os, subprocess, sys, time, urllib.error, urllib.request

sys.dont_write_bytecode = True

ENV = os.path.expanduser(os.environ.get("CUEPAD_ASC_ENV", "~/.appstoreconnect/cuepad.env"))


def load_env():
    values = {}
    for line in open(ENV):
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            values[key] = os.path.expanduser(os.path.expandvars(value.strip().strip(chr(34))))
    return values


def b64(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def der_to_raw(der):
    # ECDSA DER 签名 → JWT 要求的 r||s（各 32 字节）
    assert der[0] == 0x30
    i = 2 if der[1] < 0x80 else 2 + (der[1] - 0x80)
    parts = []
    for _ in range(2):
        assert der[i] == 0x02
        length = der[i + 1]
        parts.append(int.from_bytes(der[i + 2 : i + 2 + length], "big"))
        i += 2 + length
    return b"".join(p.to_bytes(32, "big") for p in parts)


def token(env):
    header = b64(json.dumps({"alg": "ES256", "kid": env["ASC_KEY_ID"], "typ": "JWT"}).encode())
    claims = b64(json.dumps({"iss": env["ASC_ISSUER_ID"], "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{header}.{claims}".encode()
    der = subprocess.run(["openssl", "dgst", "-sha256", "-sign", env["ASC_KEY_PATH"]], input=signing_input, capture_output=True, check=True).stdout
    return f"{header}.{claims}.{b64(der_to_raw(der))}"


def request(method, path, body=None):
    env = load_env()
    url = path if path.startswith("http") else "https://api.appstoreconnect.apple.com" + path
    req = urllib.request.Request(url, method=method.upper(), data=body.encode() if body else None)
    req.add_header("Authorization", "Bearer " + token(env))
    if body:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as response:
            return response.status, response.read().decode()
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


if __name__ == "__main__":
    method, path = sys.argv[1], sys.argv[2]
    status, text = request(method, path, sys.argv[3] if len(sys.argv) > 3 else None)
    print(f"HTTP {status}", file=sys.stderr)
    print(text)
    sys.exit(0 if status < 300 else 1)
