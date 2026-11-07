#!/usr/bin/env python3
# 和 Cue 通话的验收用令牌：向本机 Codex app-server 请求 getAuthStatus（includeToken=true、refreshToken=false），
# 写进 <文件>（权限 600），给 xc.sh run 起的实例经 -CuePadVoiceToken 读（DebugHooks.voiceToken）。
# 脚本使用真实 Codex，但不直接读写其凭证文件或自行续期；refreshToken=false 不强制续期，Codex 自身仍可能在临近过期时续期并写回。
# 因而获取令牌不保证整个调用链只读；隔离实例只读取指定的令牌文件。
# 用法：voice-token.py <文件>；打印账号方式与还剩几小时，令牌过期就重跑。
import base64, json, os, subprocess, sys, time

if len(sys.argv) != 2:
    sys.exit("用法：voice-token.py <文件>")
codex = subprocess.Popen(["codex", "app-server", "--listen", "stdio://"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL, text=True)


def call(id, method, params):
    codex.stdin.write(json.dumps({"id": id, "method": method, "params": params}) + "\n")
    codex.stdin.flush()
    for line in codex.stdout:
        message = json.loads(line)
        if message.get("id") == id:
            return message["result"]
    sys.exit("Codex app-server 没回就退出了")


try:
    call(1, "initialize", {"clientInfo": {"name": "cuepad-voice-token", "version": "0"}})
    codex.stdin.write(json.dumps({"method": "initialized"}) + "\n")
    status = call(2, "getAuthStatus", {"includeToken": True, "refreshToken": False})
finally:
    codex.terminate()
token = status.get("authToken")
if status.get("authMethod") != "chatgpt" or not token:
    sys.exit(f"Codex 没用 ChatGPT 账号登录（{status.get('authMethod')}）：在 Codex 里登录后重跑")
payload = token.split(".")[1]
claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
fd = os.open(sys.argv[1], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.write(fd, token.encode())
os.close(fd)
print(f"chatgpt 令牌已写入 {sys.argv[1]}，还剩 {(claims['exp'] - time.time()) / 3600:.1f} 小时")
