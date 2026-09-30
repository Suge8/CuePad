#!/usr/bin/env python3
"""TestFlight 内部测试：建内部测试组、把测试员加进去、查构建处理状态。
用法：testflight.py group [邮箱]    建/取内部测试组「内部」（能访问全部构建），并把账号里该邮箱的用户加进去（默认账号持有人）
      testflight.py builds          列出构建：版本、处理状态、是否过期
凭据见 asc.py。
"""
import json, os, sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(__file__))
import asc

APP_BUNDLE_ID = "com.sugeh.cuepad"
GROUP_NAME = "内部"


def api(method, path, body=None):
    status, text = asc.request(method, path, json.dumps(body) if body else None)
    data = json.loads(text) if text.strip() else {}
    if status >= 300:
        raise SystemExit(f"{method} {path} 失败（HTTP {status}）：{data.get('errors', [{}])[0].get('detail', text[:200])}")
    return data


def app_id():
    apps = api("GET", f"/v1/apps?filter[bundleId]={APP_BUNDLE_ID}")["data"]
    if not apps:
        raise SystemExit("App Store Connect 里没有这个 App 记录")
    return apps[0]["id"]


def ensure_group(app):
    for group in api("GET", f"/v1/apps/{app}/betaGroups?limit=200")["data"]:
        if group["attributes"]["name"] == GROUP_NAME and group["attributes"].get("isInternalGroup"):
            return group["id"]
    body = {"data": {"type": "betaGroups", "attributes": {"name": GROUP_NAME, "isInternalGroup": True, "hasAccessToAllBuilds": True},
                     "relationships": {"app": {"data": {"type": "apps", "id": app}}}}}
    print(f"已创建内部测试组「{GROUP_NAME}」")
    return api("POST", "/v1/betaGroups", body)["data"]["id"]


def ensure_tester(group, email):
    users = [u for u in api("GET", f"/v1/users?filter[username]={email}")["data"]]
    if not users:
        raise SystemExit(f"账号里没有用户 {email}（内部测试员必须是 App Store Connect 用户）")
    user = users[0]["attributes"]
    testers = api("GET", f"/v1/betaGroups/{group}/betaTesters?limit=200")["data"]
    if any(t["attributes"].get("email", "").lower() == email.lower() for t in testers):
        print(f"{email} 已在测试组里")
        return
    body = {"data": {"type": "betaTesters", "attributes": {"email": email, "firstName": user.get("firstName", ""), "lastName": user.get("lastName", "")},
                     "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group}]}}}}
    api("POST", "/v1/betaTesters", body)
    print(f"已把 {email} 加入测试组")


def builds():
    app = app_id()
    for build in api("GET", f"/v1/builds?filter[app]={app}&sort=-uploadedDate&limit=10")["data"]:
        a = build["attributes"]
        print(a["version"], a["processingState"], "已过期" if a.get("expired") else "有效", a["uploadedDate"])


if __name__ == "__main__":
    command = sys.argv[1] if len(sys.argv) > 1 else ""
    if command == "group":
        app = app_id()
        group = ensure_group(app)
        ensure_tester(group, sys.argv[2] if len(sys.argv) > 2 else "nnyless@foxmail.com")
        builds()
    elif command == "builds":
        builds()
    else:
        sys.exit(__doc__)
