# CuePad Apple 工程

`CuePad.xcodeproj`：一个多平台 App target（macOS + iOS/iPadOS，最低 26），Swift 6 严格并发；源码在 `App/Sources/` 与 `App/Tests/`（文件夹同步组，增删文件不用改工程文件）：`Shared/AppServices.swift` 是组合根，`Services/` 是其实现，`macOS/` 是壳层（窗口、快捷键、菜单栏图标与面板），`UI/` 是界面。共用 Swift 包在 `CuePadKit/`，方案见 [docs/swift-rewrite.md](../docs/swift-rewrite.md)。

## 命令

统一入口 `scripts/xc.sh <build|test|shot> <mac|ios> [截图路径]`，构建产物在 `.derived/`（自带 `.gitignore`），退出码即 xcodebuild 的退出码。**并行的 agent 必须各用一个产物目录**（`CUEPAD_DERIVED=/tmp/xxx apple/scripts/xc.sh …`，截图、隔离库、Pi 目录随之落在该目录下），共用同一个目录时构建与测试会互相覆盖而随机失败。

```bash
apple/scripts/xc.sh build mac
apple/scripts/xc.sh test mac
apple/scripts/xc.sh build ios
apple/scripts/xc.sh test ios
apple/scripts/xc.sh shot mac      # 构建 → 后台启动 → 单窗口截图 → 退出，输出 .derived/shot-mac.png
apple/scripts/xc.sh shot mac out.png -- -CuePadDemo YES -CuePadScene editor -theme dark  # 带启动参数
apple/scripts/xc.sh shot ios      # 构建 → 模拟器安装启动 → 截图 → 终止，输出 .derived/shot-ios.png
```

## 约定

- `shot mac` 的 `--` 之后是 App 启动参数。Debug 构建认 `-CuePadDemo YES`（空库时写入演示数据）、`-CuePadProject <名称>`、`-CuePadScene <collapsed|older|editor|search|tasks|trash|settings|menubar>`、`-CuePadSearch`、`-CuePadCard`、`-CuePadWindowSize 1280x800`，说明见 `App/Sources/UI/Debug/DebugScene.swift`；设置项可直接覆盖（`-theme dark`）。`CUEPAD_SHOT_LIBRARY` 换库目录，`CUEPAD_SHOT_SETTLE` 是出窗后等待渲染的秒数。Pi 目录同样隔离（`.derived/pi-agent`、`/tmp/cuepad-shot-<uid>`），截图不含 `~/.pi` 的会话。
- `shot mac` 用 `open -g` 后台启动，不抢焦点；按 pid 找窗口 ID 后 `screencapture -l` 只截该窗口（首次需给终端授予屏幕录制权限）；以 SIGTERM 退出，走应用正常退出流程。
- 窗口位置/尺寸会被系统记住（`NSWindow Frame main`），截图尺寸以上次为准；要恢复默认：`defaults delete com.sugeh.cuepad "NSWindow Frame main"`。
- iOS 模拟器默认 `iPhone 17`，用 `CUEPAD_IOS_DEVICE` 覆盖。
- 单元测试以 App 为宿主；宿主检测到 `XCTestConfigurationFilePath` 时不启动壳层，避免注册真实全局热键和菜单栏图标。壳层测试只在 macOS 编译，`test ios` 目前执行 0 个测试。
- 测试只用替身或不产生按键事件的系统调用，不向其他应用发送键鼠事件；全局热键的物理触发只能人工验证。
- 签名配置在 `App/Config/Signing.xcconfig`：本机 ad-hoc，分发时按文件内注释改成 Developer ID。
- 链接的 `CuePadKit` products：CueText / CueStore / CueEditor 全平台，CueDispatch / CuePi 仅 macOS（工程里按平台过滤）。
- 资料库在 `~/Library/Application Support/CuePad/Library/`；首次启动从 Electron 版库（`~/Library/Application Support/cuepad/cuepad.db`）导入一次，完成标记是库目录里的 `.electron-import-completed`。环境变量 `CUEPAD_LIBRARY_DIR` 指向隔离目录（不导入旧库）；`shot mac` 用它把库放进 `.derived/library`。
- 壳层：主窗口在 `MainWindowFactory` 创建时就设好外框（内容铺到透明标题栏下），界面不要再在运行时改窗口样式；设置窗口（⌘,）由 `SettingsWindowController` 承载，内容来自 `RootViews.settings`；`CuePadApplication` 在退出前结束挂在窗口上的弹窗，⌘Q 与 SIGTERM 才不会被 sheet/alert 卡住；菜单栏面板 `MenuBarPanel` 随内容尺寸变化，顶边固定在图标下方。
- 服务测试用临时目录、独立 UserDefaults 与记录型替身，不碰真实资料库、`~/.pi` 和其他应用。
