"""App 里全部声音（`Sound`）的来源：Freesound 上的 CC0 录音，按下面的配方修成 apple/App/Sources/Sounds/ 下的 caf。
用法：python3 design/tools/sounds.py apple/App/Sources/Sounds（要联网与 ffmpeg；afconvert 系统自带）。
选材只认两样：CC0，和听过的人留下的证据（评分人数与下载量，写在每行后面，2026-11 查的）——挑的人听不到。
拿来的是各家各录的散件，所以都修一遍：去掉开头的空白，尾巴淡出（原件多是硬切，会"哒"一声），
带音高的移到同一个调（A 大调五声：A B C# E F#）上，放在一起不打架；响度按最响那 50ms 的均方根对齐，
通知两段 -19 dBFS（比系统提示音 Glass、Tink 高一点，隔着屋子听得见），操作音跟在手上的动作后面、一天响很多次，-27；
一下就没的短促声按均方根会被推得太响，所以峰值另有上限（通知 -9、操作音 -15）。"""
import os, re, subprocess, sys, tempfile, urllib.request

OUT = sys.argv[1]
ALERT, UI = (-19, -9), (-27, -15)
# 名字: (Freesound 编号/预览文件, 作者, 移几个半音, 留多长秒, 尾巴淡出秒, (最响 50ms 的均方根, 峰值上限))
SOUNDS = {
    'ask': ('235/235911_2391840', 'yfjesse', 0.8, 0.45, 0.06, ALERT),          # Notification Sound ↓21641 ★4.7(137)，降 E 的八度叠音 → E
    # [UI Sound] Approval ↓3992 ★4.8(80)。原件在 1.8–2.6kHz（耳朵最敏感那一段）连响 0.7 秒，一天听几十遍会刺；降五个半音到 1.3–2kHz，音还在调上（B A F# E 下行）
    'done': ('625/625174_13251199', 'GabFitzgerald', -5, 0.90, 0.15, ALERT),
    'send': ('760/760370_8331855', 'Froey_', 0, 0.18, 0.08, UI),               # Message Sent ↓2895 ★4.8(46)
    'check': ('320/320181_274531', 'dland', -1.08, 0.25, 0.05, UI),            # hint.wav ↓25780 ★4.6(217)，C 的八度 → B
    'act': ('405/405548_6436863', 'Raclure', 0, 0.20, 0.05, UI),               # Cancel/miss chime ↓3062 ★4.9(42)，低低的一声 E
    'undo': ('418/418231_6616210', 'KieranKeegan', 0, 0.50, 0.08, UI),         # UI back sound ↓2016 ★4.8(25)
    'fail': ('701/701703_7862587', 'StavSounds', 0, 0.28, 0.06, UI),           # ui-mistake.wav ↓1888 ★4.9(51)，E 上压一个三全音，故意不协和
    'drop': ('702/702806_6142149', 'LilMati', 0, 0.40, 0.12, UI),              # Waterdrop Click ↓2980 ★4.6(68)
}

def ffmpeg(*args):
    return subprocess.run(['ffmpeg', '-hide_banner', '-nostats', '-y', *args], check=True, capture_output=True, text=True).stderr

os.makedirs(OUT, exist_ok=True)
with tempfile.TemporaryDirectory() as tmp:
    for name, (source, _, semitones, keep, fade, (target, ceiling)) in SOUNDS.items():
        mp3, shaped, wav = (os.path.join(tmp, name + ext) for ext in ('.mp3', '-shaped.wav', '.wav'))
        request = urllib.request.Request(f'https://cdn.freesound.org/previews/{source}-hq.mp3', headers={'User-Agent': 'Mozilla/5.0 cuepad-sounds'})
        with urllib.request.urlopen(request, timeout=60) as response, open(mp3, 'wb') as file:
            file.write(response.read())
        ratio = 2 ** (semitones / 12)
        shape = (f'aresample=48000,silenceremove=start_periods=1:start_threshold=-50dB,asetrate={48000 * ratio:.0f},aresample=48000,'
                 f'atrim=end={keep},afade=t=in:d=0.003,afade=t=out:st={keep - fade}:d={fade}')
        ffmpeg('-i', mp3, '-ac', '1', '-af', shape, shaped)
        stats = ffmpeg('-i', shaped, '-af', 'astats', '-f', 'null', '-')
        loudest, peak = (max(float(x) for x in re.findall(rf'{key} dB: (-?[\d.]+)', stats)) for key in ('RMS peak', 'Peak level'))
        ffmpeg('-i', shaped, '-af', f'volume={min(target - loudest, ceiling - peak):.2f}dB', wav)
        subprocess.run(['afconvert', '-f', 'caff', '-d', 'LEI16', wav, os.path.join(OUT, name + '.caf')], check=True)
