#!/usr/bin/env python3
# Cue 的替身大脑（配 Debug 启动参数 -CuePadCueBrain，运行时选 Pi）：说 Pi 的 RPC，只认 get_state 与 prompt，其余一律回成功。
# 每次 prompt 开一轮，等 CUE_STUB_DELAY 秒（默认 0）说一句"知道了。"再歇下；正在一轮里收到的话插进这一轮，不另开（同 Pi 的 steer）。
# 给了 CUE_STUB_LOG=<文件> 时把每次交来的话记成一行 JSON（时刻与原文），比对叫醒次数与信封内容用。
import json, os, sys, threading, time

log, delay = os.environ.get("CUE_STUB_LOG"), float(os.environ.get("CUE_STUB_DELAY", "0"))
lock, busy = threading.Lock(), False
model = {"provider": "fake", "id": "echo", "name": "Echo", "input": ["text"], "contextWindow": 100000}


def out(message):
    with lock:
        sys.stdout.write(json.dumps(message, ensure_ascii=False) + "\n")
        sys.stdout.flush()


def turn():
    global busy
    time.sleep(delay)
    reply = {"role": "assistant", "content": [{"type": "text", "text": "知道了。"}], "stopReason": "stop",
             "usage": {"input": 1000, "cacheRead": 0, "cacheWrite": 0}}
    out({"type": "message_start", "message": {"role": "assistant", "content": []}})
    out({"type": "message_end", "message": reply})
    with lock:
        busy = False
    out({"type": "agent_settled"})


for line in sys.stdin:
    try:
        command = json.loads(line)
    except ValueError:
        continue
    kind, cid = command.get("type"), command.get("id")
    if kind != "prompt":
        out({"type": "response", "command": kind, "success": True, "id": cid, "data": {"model": model} if kind == "get_state" else {}})
        continue
    if log:
        with open(log, "a") as f:
            f.write(json.dumps({"t": time.time(), "message": command.get("message")}, ensure_ascii=False) + "\n")
    out({"type": "response", "command": kind, "success": True, "id": cid})
    with lock:
        start, busy = not busy, True
    if start:
        out({"type": "agent_start"})
        threading.Thread(target=turn, daemon=True).start()
