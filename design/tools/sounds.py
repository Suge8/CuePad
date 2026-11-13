"""App 里全部声音（`Sound`）的来源：从 UI SFX（https://uisfx.com，音频 CC0）的一套音色里取这几段，转成 apple/App/Sources/Sounds/ 下的 caf。
用法：npm pack uisfx 解开后，python3 design/tools/sounds.py <解开的 package/sounds/soft> apple/App/Sources/Sounds（要 ffmpeg；afconvert 系统自带）。
整套换音色只换第一个参数的目录；一套里各段出自同一组合成配方，音色与响度是配好的，不从别处单拣一段混进来。
原件峰值约 -8 dBFS。通知的两段压到约 -11：比系统提示音（Glass、Tink 约 -25 LUFS）高一点，隔着屋子听得见；
操作音跟在手上的动作后面、一天响很多次，压到约 -18。"""
import os, subprocess, sys, tempfile

SOURCE, OUT = sys.argv[1], sys.argv[2]
ALERT, UI = -3, -10
# 我们的名字: (那一套里的 cue, 增益 dB)
SOUNDS = {
    'ask': ('mention', ALERT),
    'done': ('complete', ALERT),
    'send': ('send', UI),
    'check': ('check', UI),
    'act': ('delete', UI),
    'undo': ('undo', UI),
    'fail': ('error', UI),
    'drop': ('drop', UI),
}
os.makedirs(OUT, exist_ok=True)
for name, (cue, gain) in SOUNDS.items():
    with tempfile.NamedTemporaryFile(suffix='.wav') as wav:
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', os.path.join(SOURCE, cue + '.ogg'), '-af', f'volume={gain}dB', wav.name], check=True)
        subprocess.run(['afconvert', '-f', 'caff', '-d', 'LEI16', wav.name, os.path.join(OUT, name + '.caf')], check=True)
