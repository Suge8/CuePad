# CuePad 模块索引

Swift 原生应用（macOS / iOS / iPadOS）。产品说明见 [README.md](README.md)；开发命令、架构约定、验收环境与发布见 [docs/development.md](docs/development.md)，改动前先读。并行的 agent 各用独立的 `CUEPAD_DERIVED` 产物目录，否则构建与测试会互相覆盖。

| 路径 | 职责 |
| --- | --- |
| `apple/CuePad.xcodeproj` | 多平台 App 工程：macOS 与 iOS/iPadOS 主 App、分享扩展、小组件、命令行目标；签名事实源 `apple/App/Config/Signing.xcconfig` |
| `apple/App/Sources/Shared`、`Services` | 组合根 `AppServices` 与服务：发送、同步、Pi 扩展管理、命令行工具安装、快照 |
| `apple/App/Sources/macOS` | Mac 壳层：窗口、全局快捷键、菜单栏图标与面板 |
| `apple/App/Sources/iOS`、`apple/App/AppGroup`、`ShareExtension`、`Widget` | iOS/iPadOS 入口、App Group 位置与快照、分享扩展、小组件 |
| `apple/App/Sources/UI` | 界面：`Shared/` 组件、主题、规则、工作区状态；`macOS/`、`iOS/` 各平台界面；`Debug/` 视觉验收场景与演示数据 |
| `apple/App/Tests` | 以 App 为宿主的服务与界面规则测试 |
| `apple/CuePadKit/Sources/CueText` | 卡片正文纯文本模型：解析/序列化、分块、变量、光标规范化（仅 Foundation） |
| `apple/CuePadKit/Sources/CueStore` | SQLite 唯一事实源：表结构、仓储、搜索、资料库位置、跨进程变更通知、旧库导入 |
| `apple/CuePadKit/Sources/CueEditor` | TextKit 2 编辑器，AppKit/UIKit 宿主 |
| `apple/CuePadKit/Sources/CueSync` | CKSyncEngine ↔ CueStore 的记录映射、待推送、冲突与附件 |
| `apple/CuePadKit/Sources/CueDispatch` | macOS 通用投送：前台应用、剪贴板、定向 `Cmd+V` |
| `apple/CuePadKit/Sources/CuePi` | macOS Pi 桥：扩展、socket 协议（[README](apple/CuePadKit/Sources/CuePi/README.md)）、会话历史、终端跳转 |
| `apple/CuePadKit/Sources/CueCLI` | `cuepad` 命令行；`cuepad --help` 是其唯一文档 |
| `apple/CuePadKit/Tests` | 各模块的 Swift Testing 测试 |
| `apple/scripts` | `xc.sh`（build/test/shot/release/provision）与签名、发布脚本 |
| `landing/` | 双语营销落地页（SvelteKit + GSAP，部署 Vercel），见 [landing/AGENTS.md](landing/AGENTS.md) |
| `design/` | 品牌 IP 与 logo 定稿（`final/`）、宣传素材源与合成模板（`promo/`）、图标脚本（`tools/`） |
