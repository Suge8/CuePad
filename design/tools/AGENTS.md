# 图标生成

改几何后依次跑 `cue-symbols.py`（唯一写入入口）与 `verify-symbols.py`（只读校验），界面验收仍只经 `apple/scripts/xc.sh`。

- `ink/mascot.py` 是 Cue 品牌几何，改功能图标时保持它的输出字节不变。
- Swift 里的状态路径由 `ink/state_geometry.py` 从同一中线导出，不在 App 内另画副本。
