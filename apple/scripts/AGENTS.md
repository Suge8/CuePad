# 脚本

每个脚本的用法在它的头注释里，命令表是 `xc.sh help`。这里只有做错了伤到用户数据、线上用户或正式版，而脚本拦不住的事。

## 真实数据复现

首帧、滚动、输入类问题在演示库上好了不算修好：条数、正文长短与图片和真实库差得远。在真实库的只读副本上复现：

```bash
CUEPAD_SHOT_LIBRARY="$(apple/scripts/xc.sh real copy)" apple/scripts/xc.sh shot mac …
```

人要自己点着看就 `xc.sh real`。副本里是用户的私人内容，只留在本检出的 `.derived`，不拷到别处。

## 占前台

占前台会抢用户的键盘、移指针，只用在两处：要和交互预算比的数字，一次量够、不连跑，新加的只经 `DebugForeground`；后台投递不动的交互验收（Mac 看板的系统拖放：bcu 的 `drag` 在后台报 unverified、卡不动），加 `--foreground` 拖一趟，不用等用户离开。

## 共用的东西

- 机器上常开着正式版和别的检出的实例：bcu、xctrace 只按 PID 认，按名字或 bundle id 会认到正式版。
- 模拟器槽位全机共用：在里面改过的系统设置（旁白、语言、减少动态效果）验完还原再 `xc.sh stop`，否则下一个任务接着带着。
- 真机日志（`xc.sh diag`）里可能有用户的内容：只在本机读，回给用户与写进报告的只放条数和脱敏后的样子。

## 查日志

App 日志的 subsystem 是 App 身份前缀（`Signing.xcconfig` 的 `CUEPAD_APP_ID`），类别是各处 `Logger(category:)` 写的；CloudKit 自己的在 `com.apple.cloudkit`。

```bash
id=$(sed -n 's/^CUEPAD_APP_ID *= *//p' apple/App/Config/Signing.xcconfig)
log show --last 30m --info --debug --predicate "subsystem == \"$id\" OR (process == \"CuePad\" AND subsystem BEGINSWITH \"com.apple.cloudkit\")"
```
