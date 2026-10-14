"""Mac 通知提示音的合成源：生成 apple/App/Sources/Sounds/ 下的 4 段 caf（文件名即通知声音名）。
用法：python3 design/tools/notification-sounds.py apple/App/Sources/Sounds（需要 numpy；afconvert 是系统自带的）。
响度对齐系统提示音（Glass、Tink 约 -25 LUFS），所以峰值只到 -11.5 dBFS。"""
import numpy as np, wave, os, sys, subprocess, tempfile
SR = 48000
OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)

def env(n, attack=0.004, decay=0.35):
    t = np.arange(n)/SR
    a = np.clip(t/attack, 0, 1)
    a = np.sin(a*np.pi/2)**2
    return a*np.exp(-t/decay)

def partials(freq, dur, parts, attack=0.004):
    n = int(dur*SR); t = np.arange(n)/SR; y = np.zeros(n)
    for ratio, amp, decay in parts:
        f = freq*ratio
        if f > SR/2*0.9: continue
        y += amp*np.sin(2*np.pi*f*t + 0.3*ratio)*env(n, attack, decay)
    # 每个音自己收尾：最后 30% 余弦淡出，截断处不留爆音
    k = int(n*0.3); y[-k:] *= 0.5*(1+np.cos(np.linspace(0, np.pi, k)))
    return y

# 音色：温和的木琴（马林巴，泛音 1 / 3.93 / 9.2，高泛音很快熄灭）与玻璃钟（非整数泛音，余音长一点）
def marimba(f, dur=0.9):
    return partials(f, dur, [(1,1.0,0.30),(3.93,0.22,0.06),(9.2,0.05,0.02),(2.0,0.08,0.12)], attack=0.003)

def glass(f, dur=1.4):
    return partials(f, dur, [(1,1.0,0.55),(2.0,0.18,0.30),(2.76,0.20,0.22),(5.40,0.07,0.09),(8.93,0.03,0.04)], attack=0.0025)

def place(track, sound, at):
    i = int(at*SR); end = min(len(track), i+len(sound)); track[i:end] += sound[:end-i]

def reverb(y, mix=0.12, length=0.45):
    rng = np.random.default_rng(7); n = int(length*SR)
    ir = rng.standard_normal(n)*np.exp(-np.arange(n)/SR/0.11)
    ir /= np.sqrt((ir**2).sum())
    wet = np.convolve(y, ir)[:len(y)]
    # 混响只要高一点的部分，低频不糊
    return y + mix*wet

def finish(y, peak_db=-11.5, tail=0.03):
    y = reverb(y)
    n = int(tail*SR); y[-n:] *= np.linspace(1,0,n)
    y = y/np.max(np.abs(y))*10**(peak_db/20)
    return y

def write(name, y):
    data = (np.clip(y,-1,1)*32767).astype('<i2')
    with tempfile.NamedTemporaryFile(suffix='.wav') as tmp:
        with wave.open(tmp.name,'wb') as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR); w.writeframes(data.tobytes())
        subprocess.run(['afconvert','-f','caff','-d','LEI16',tmp.name,os.path.join(OUT,name+'.caf')], check=True)

def note(name): # A4=440
    names = {'C':-9,'D':-7,'E':-5,'F':-4,'G':-2,'A':0,'B':2}
    return 440*2**((names[name[0]] + 12*(int(name[1])-4))/12)

# 叮咚：等你确认。上扬的纯五度（G5→D6），像在问"在吗？"，两声玻璃钟相隔 140ms
def chime():
    y = np.zeros(int(1.6*SR))
    place(y, glass(note('G5'))*0.85, 0.0)
    place(y, glass(note('D6')), 0.14)
    return finish(y)

# 轻响：一声柔和的木琴落在主音上，前面带一个很轻的倚音（E6→C6），像"好了"
def tap():
    y = np.zeros(int(0.9*SR))
    place(y, marimba(note('E6'))*0.35, 0.0)
    place(y, marimba(note('C6')), 0.07)
    return finish(y)

# 风铃：大三和弦快速上行琶音（C6 E6 G6），轻快
def bell():
    y = np.zeros(int(1.6*SR))
    for i, n in enumerate(['C6','E6','G6']):
        place(y, glass(note(n), 1.3)*(0.7+0.15*i), 0.075*i)
    return finish(y)

# 水滴：做完了。正弦从低到高快速滑音，带一点木琴尾巴
def drop():
    dur = 0.55; n = int(dur*SR); t = np.arange(n)/SR
    f = 520 + (1500-520)*(1-np.exp(-t/0.035))
    phase = 2*np.pi*np.cumsum(f)/SR
    y = np.sin(phase)*env(n, 0.002, 0.07)
    tail = np.zeros(n); place(tail, marimba(note('G6'), 0.45)*0.25, 0.03)
    return finish(y+tail)

for name, fn in [('chime',chime),('tap',tap),('bell',bell),('drop',drop)]:
    write(name, fn())
