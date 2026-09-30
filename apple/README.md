# CuePad Apple 工程

`CuePad.xcodeproj`：一个多平台 App target（macOS + iOS/iPadOS，最低 26），Swift 6 严格并发；源码在 `App/Sources/` 与 `App/Tests/`（文件夹同步组，增删文件不用改工程文件）：`Shared/AppServices.swift` 是组合根，`Services/` 是其实现，`macOS/` 是壳层（窗口、快捷键、菜单栏图标与面板），`UI/` 是界面。共用 Swift 包在 `CuePadKit/`，方案见 [docs/swift-rewrite.md](../docs/swift-rewrite.md)。

## 命令

统一入口 `scripts/xc.sh <build|test|shot> <mac|ios|ipad> [截图路径]`（`ios` 是 iPhone 模拟器，`ipad` 是 iPad 模拟器，`CUEPAD_IPAD_DEVICE` 换机型），构建产物在 `.derived/`（自带 `.gitignore`），退出码即 xcodebuild 的退出码。**并行的 agent 必须各用一个产物目录**（`CUEPAD_DERIVED=/tmp/xxx apple/scripts/xc.sh …`，截图、隔离库、Pi 目录随之落在该目录下），共用同一个目录时构建与测试会互相覆盖而随机失败。

```bash
apple/scripts/xc.sh build mac
apple/scripts/xc.sh test mac
apple/scripts/xc.sh build ios
apple/scripts/xc.sh test ios
apple/scripts/xc.sh shot mac      # 构建 → 后台启动 → 单窗口截图 → 退出，输出 .derived/shot-mac.png
apple/scripts/xc.sh shot mac out.png -- -CuePadDemo YES -CuePadScene editor -theme dark  # 带启动参数
apple/scripts/xc.sh shot ios      # 构建 → 模拟器安装启动 → 截图 → 终止，输出 .derived/shot-ios.png；同样支持 `-- 启动参数`，库与偏好放进 .derived/library-ios
apple/scripts/xc.sh shot ipad     # 同上，iPad 模拟器
```

## 命令行

`cuepad` 是给人和 agent 读写本机资料库的命令行（源码 `CuePadKit/Sources/CueCLI`，经 CueStore 读写）。安装：`cd apple/CuePadKit && swift build -c release --product cuepad && cp .build/release/cuepad /usr/local/bin/`；用法与 JSON 结构见 `cuepad --help`。

## 约定

- `shot mac` 的 `--` 之后是 App 启动参数。Debug 构建认 `-CuePadDemo YES`（空库时写入演示数据）、`-CuePadProject <名称>`、`-CuePadScene <collapsed|older|editor|search|tasks|trash|settings|menubar>`、`-CuePadSearch`、`-CuePadCard`、`-CuePadWindowSize 1280x800`，说明见 `App/Sources/UI/Debug/DebugScene.swift`；设置项可直接覆盖（`-theme dark`）。`CUEPAD_SHOT_LIBRARY` 换库目录，`CUEPAD_SHOT_SETTLE` 是出窗后等待渲染的秒数。Pi 目录同样隔离（`.derived/pi-agent`、`/tmp/cuepad-shot-<uid>`），截图不含 `~/.pi` 的会话。隔离的 Pi 目录里没装扩展，侧栏底部出现"连接 Pi"征求同意是正确状态；截图不要它时传 `-piExtensionDeclinedVersion '<integer>N</integer>'`，N 取 `cuepad-bridge.ts` 里的 `EXTENSION_VERSION`（这只写入参数域，不改已保存的设置）。`settings`、`menubar` 画面把设置窗口、菜单栏面板的内容放进主窗口拍，因为只截主窗口。
- `shot mac` 用 `open -g` 后台启动，不抢焦点；按 pid 找窗口 ID 后 `screencapture -l` 只截该窗口（首次需给终端授予屏幕录制权限）；以 SIGTERM 退出，走应用正常退出流程。
- 窗口位置/尺寸会被系统记住（`NSWindow Frame main`），截图尺寸以上次为准；要恢复默认：`defaults delete com.sugeh.cuepad "NSWindow Frame main"`。
- iOS 模拟器默认 `iPhone 17`，用 `CUEPAD_IOS_DEVICE` 覆盖。
- 单元测试以 App 为宿主；宿主检测到 `XCTestConfigurationFilePath` 时不启动壳层，避免注册真实全局热键和菜单栏图标。壳层测试只在 macOS 编译，`test ios` 目前执行 0 个测试。
- 测试只用替身或不产生按键事件的系统调用，不向其他应用发送键鼠事件；全局热键的物理触发只能人工验证。
- 签名配置在 `App/Config/Signing.xcconfig`：本机 ad-hoc，分发时按文件内注释改成 Developer ID。
- 链接的 `CuePadKit` products：CueText / CueStore / CueEditor 全平台，CueDispatch / CuePi 仅 macOS（工程里按平台过滤）。
- 资料库在 `~/Library/Application Support/CuePad/Library/`；首次启动从 Electron 版库（`~/Library/Application Support/cuepad/cuepad.db`）导入一次，完成标记是库目录里的 `.electron-import-completed`。环境变量 `CUEPAD_LIBRARY_DIR` 指向隔离目录（必须是绝对路径，否则 App 弹窗说明后退出）：资料库、偏好设置（主题、快捷键、当前项目、窗口位置）都放进这个目录，不导入旧库，不碰真实的 `com.sugeh.cuepad` 偏好域，并行实例互不影响；`shot mac` 用它把库放进 `.derived/library`。
- 壳层：主窗口在 `MainWindowFactory` 创建时就设好外框（内容铺到透明标题栏下），界面不要再在运行时改窗口样式；设置窗口（⌘,）由 `SettingsWindowController` 承载，内容来自 `RootViews.settings`；`CuePadApplication` 在退出前结束挂在窗口上的弹窗，⌘Q 与 SIGTERM 才不会被 sheet/alert 卡住；菜单栏面板 `MenuBarPanel` 随内容尺寸变化，顶边固定在图标下方。
- 服务测试用临时目录、独立 UserDefaults 与记录型替身，不碰真实资料库、`~/.pi` 和其他应用。

## iOS / iPadOS

- 资料库在 App Group 共享容器 `group.com.sugeh.cuepad` 的 `Library/`（库文件、`Attachments/`、待入库的 `Capture/`、给小组件的 `Snapshots/`），偏好用同名 UserDefaults 套件。`CUEPAD_LIBRARY_DIR` 隔离照旧。模拟器直接可用；真机需要开发者账号给三个目标（App、分享扩展、小组件）签上该 App Group。
- 分享扩展（`CuePadShare`）与小组件（`CuePadWidget`）是 iOS 独有的目标，随 App 嵌入；三者共用 `App/AppGroup/`。资料库始终只有主 App 写：扩展把内容放进 `Capture/`，主 App 在前台、收到扩展的进程间通知时入库；小组件与扩展不打开资料库，只读主 App 写的 JSON 快照。
- 每个窗口（iPad 多窗口）各有一个 `SceneContext`，选中项目不放进全局偏好。界面接入点：`Sources/iOS/IOSRootViews.swift`（每个窗口的根视图）、`App/ShareExtension/ShareViews.swift`、`App/Widget/WidgetViews.swift`。

## 签名与发布

凭据文件 `~/.appstoreconnect/cuepad.env`（不入库）：`ASC_KEY_ID`、`ASC_ISSUER_ID`、`ASC_KEY_PATH`（App Store Connect API 密钥 `.p8` 的路径）、`CUEPAD_TEAM_ID`。缺文件时 build/test/shot 照常（本机 ad-hoc 签名，工程默认的团队与自动签名被 `xc.sh` 覆盖掉），只有下面的发布命令会报错。密钥内容不会打印。

| 命令 | 作用 |
| --- | --- |
| `xc.sh provision` | 幂等：创建 App ID 与能力（App Groups、iCloud、推送）、Apple Distribution 证书（私钥放专用钥匙串 `~/.appstoreconnect/cuepad-signing.keychain-db`）、iOS 描述文件 |
| `xc.sh release mac` | 归档 → Developer ID 导出 → `notarytool` 公证 → 装订 → 产出 `<产物目录>/release/mac/CuePad-<版本>-mac.zip` |
| `xc.sh release ios` | 刷新证书与描述文件 → 归档 → 导出并上传 TestFlight（构建号取时间戳，自动递增） |
| `xc.sh device` | 登记连接的真机 → Development 证书与描述文件 → 开发构建 → 安装并启动 |

前置（只能在网页上做，API 与 `xcodebuild` 的 API 密钥都管不了）：

1. developer.apple.com → Identifiers → App Groups：创建 `group.com.sugeh.cuepad`，再在 App ID `com.sugeh.cuepad`、`.share`、`.widget`（`xc.sh provision` 已创建）里各 Configure 勾选它；之后再跑一次 `xc.sh provision` 刷新描述文件。
2. Developer ID Application 证书只有账号持有人能创建：`xc.sh provision devid-csr` 生成 CSR，网页 Certificates → Developer ID Application 上传它，把下载的 `.cer` 交给 `xc.sh provision devid-import <路径>`。（或者给 API 密钥开通云托管证书权限，则 `release mac` 直接用云端证书。）
3. App Store Connect 里建 App 记录：bundle id `com.sugeh.cuepad`，名称与 SKU 自定；之后 `release ios` 才能上传。
4. iCloud 容器 `iCloud.com.sugeh.cuepad` 与推送在阶段 3 用到：容器同样只能网页创建并挂到 App ID。当前二进制的权限里没有 iCloud、推送（避免描述文件要求），同步落地时再加进 `App/Config/*.entitlements`。

macOS 用自动签名（云端 Apple Development 证书，无需描述文件）；iOS 用手动签名（Release 用 Apple Distribution + App Store 描述文件，Debug 用 Apple Development + Development 描述文件，只对 `iphoneos` 生效，模拟器不受影响）。
