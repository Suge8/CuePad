"""生成 3000 个合成 Pi 会话文件（与 Pi 一样紧凑的 JSON、同样的键序）（其中 60 个在 7 天内修改过），给首次回填的基准用（HistoryBackfillBenchmark）。
用法：python3 apple/scripts/gen-pi-sessions.py <输出目录>"""
import json, os, random, sys, time, uuid
random.seed(7)
root = os.path.join(sys.argv[1], '--work-proj--')
os.makedirs(root, exist_ok=True)
now = time.time()
def ts(t): return time.strftime('%Y-%m-%dT%H:%M:%S', time.gmtime(t)) + '.000Z'
words = '修好 登录 测试 构建 失败 原因 改动 文件 代码 函数 断言 分支 提交 日志 the build test fix error output value'.split()
def text(n): return ' '.join(random.choice(words) for _ in range(n))
total = 0
for i in range(3000):
    recent = i < 60
    start = now - (random.uniform(0, 6) if recent else random.uniform(8, 200)) * 86400
    sid = str(uuid.UUID(int=random.getrandbits(128)))
    lines = [json.dumps({"type":"session","version":3,"id":sid,"timestamp":ts(start),"cwd":f"/work/p{i%40}"}, separators=(",", ":"))]
    parent = None; t = start; n = 0
    rounds = random.choice([2, 4, 8, 16, 40])
    def add(obj):
        global parent, n
        n += 1; obj = {"type": obj.pop("type"), "id": f"e{n}", "parentId": parent, "timestamp": ts(t), **obj}
        parent = obj["id"]; lines.append(json.dumps(obj, ensure_ascii=False, separators=(',', ':')))
    for r in range(rounds):
        t += 30
        add({"type":"message","message":{"role":"user","content":[{"type":"text","text":text(random.randint(5,200))}],"timestamp":int(t*1000)}})
        if r == 1 and random.random() < 0.3:
            add({"type":"session_info","name":f"会话 {i}"})
        for k in range(random.choice([0,1,3,6])):
            t += 5
            add({"type":"message","message":{"role":"assistant","content":[{"type":"text","text":text(random.randint(5,60))},{"type":"toolCall","id":f"c{n}","name":"bash","arguments":{"command":text(8)}}],"stopReason":"toolUse","timestamp":int(t*1000)}})
            add({"type":"message","message":{"role":"toolResult","toolCallId":f"c{n}","content":[{"type":"text","text":text(random.choice([50,500,4000,20000]))}],"timestamp":int(t*1000)}})
        t += 10
        add({"type":"message","message":{"role":"assistant","content":[{"type":"thinking","thinking":text(300)},{"type":"text","text":text(random.randint(50,800))}],"stopReason":"stop","timestamp":int(t*1000)}})
    path = os.path.join(root, sid + '.jsonl')
    with open(path, 'w') as f: f.write('\n'.join(lines) + '\n')
    os.utime(path, (t, t))
    total += os.path.getsize(path)
print('files 3000 bytes', total)
