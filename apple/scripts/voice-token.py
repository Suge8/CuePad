#!/usr/bin/env python3
# 和 Cue 通话的验收用令牌：向本机 Codex（app-server 的 getAuthStatus，includeToken、refreshToken 为 false）只读地要当前的 ChatGPT 访问令牌，
# 写进 <文件>（权限 600），给 xc.sh run 起的实例经 -CuePadVoiceToken 读（DebugHooks.voiceToken）。
# 这个脚本在终端里跑、用的是你真实的 Codex：隔离实例自己不碰 ~/.codex。不续期、不读写 Codex 的文件（续期令牌只能用一次，见 CodexAccess 头注释）。
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
