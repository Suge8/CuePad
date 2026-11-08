# 图标生成

- `cue-symbols.py`：唯一写入入口，生成 App、Widget、名录与 Swift 状态路径。
- `verify-symbols.py`：只读校验资源同源、三字重拓扑、等宽与圆角相切、反白孔。
- `ink/rounded/`：功能图标，按基础、动作、状态与项目分族；`shared.py` 是线宽与轮廓工艺。
- `ink/mascot.py`：Cue 品牌几何，改功能图标时保持字节不变。
- `ink/state_geometry.py`：从同一中线导出 Swift 路径，不在 App 内另画副本。

修改几何后依次运行两个入口；界面验收仍只经 `apple/scripts/xc.sh`。
