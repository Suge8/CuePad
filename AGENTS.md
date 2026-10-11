# CuePad 模块索引

Swift 原生应用（macOS / iOS / iPadOS）。产品说明见 [README.md](README.md)。开发命令与约定见 [docs/development.md](docs/development.md)，改动前先读；碰到下面的事再读对应文件：同步、投送请求、CloudKit 订阅 → [docs/sync.md](docs/sync.md)；界面配色、动效、布局、渲染性能 → [docs/ui.md](docs/ui.md)；截图验收、性能测量、崩溃诊断 → [docs/verify.md](docs/verify.md)；签名、发布、Sparkle、CloudKit 结构部署 → [docs/release.md](docs/release.md)；Pi 桥与 socket 协议 → CuePi README（见下表）。

## 术语

界面词只有：**灵感**、**任务**、**提示词**、**Agent**、**未分类**（没有项目的灵感）、**资料**（项目里长期参考的灵感，`isPinned`）、**归档**、**回收站**。主动线是任务优先：记下灵感 → 挂到任务（成为提示词）→ 在提示词上交给 Agent →（看结果）→ 完成并归档；灵感本身不直接交给 Agent（一条卡能做什么只在 `CardMenu`）。代码里灵感与任务是同一种记录 `Card`（一张 `cards` 表、一种同步记录）：`todoAt` 为空是灵感，非空是任务（"设为任务 / 改回灵感"只翻它，改回时下级提到它的位置）；状态由 `startedAt`/`completedAt` 推出；`archivedAt` 有值是归档（连同下级）。任务是一件要做成的事，正文只有标题与一句说明（`CueTask`）；挂在任务下的任务是**子任务**、挂在任务下的灵感是**提示词**（要交给 Agent 的话，同一个 `parentID`；只有任务能当上级，最多三级）。提示词交给的会话在发出后歇下就算"已回复"（由发送记录与会话状态推出，不存字段）；任务不自动完成。项目只是容器，带一句可选的 `intro`（介绍）；没有目标卡。

| 路径 | 职责 |
| --- | --- |
| `apple/CuePad.xcodeproj` | 多平台 App 工程：macOS 与 iOS/iPadOS 主 App、分享扩展、小组件、命令行目标；签名事实源 `apple/App/Config/Signing.xcconfig` |
| `apple/App/Sources/Shared`、`Services` | 组合根 `AppServices` 与服务：发送、同步、Pi 扩展管理、命令行工具安装、快照 |
| `apple/App/Sources/macOS` | Mac 壳层：窗口、全局快捷键、菜单栏图标与面板 |
| `apple/App/Sources/iOS`、`apple/App/AppGroup`、`ShareExtension`、`Widget`、`NotificationService` | iOS/iPadOS 入口、App Group 位置与快照、分享扩展、小组件、通知服务扩展 |
| `apple/App/Sources/UI` | 界面：`Shared/` 组件、主题、规则、工作区状态；`macOS/`、`iOS/` 各平台界面；`Debug/` 视觉验收场景与演示数据 |
| `apple/App/Tests` | 以 App 为宿主的测试 |
| `apple/CuePadKit/Sources/CueText` | 卡片正文纯文本模型：解析/序列化、标题与按行规则（转为任务）、分割线、变量、光标规范化（仅 Foundation） |
| `apple/CuePadKit/Sources/CueStore` | SQLite 唯一事实源：表结构、仓储、搜索、资料库位置、跨进程变更通知 |
| `apple/CuePadKit/Sources/CueEditor` | TextKit 2 编辑器，AppKit/UIKit 宿主 |
| `apple/CuePadKit/Sources/CueSync` | CKSyncEngine ↔ CueStore 的记录映射、待推送、冲突与附件 |
| `apple/CuePadKit/Sources/CuePi` | macOS Pi 桥：扩展、socket 协议（[README](apple/CuePadKit/Sources/CuePi/README.md)）、会话历史、终端跳转 |
| `apple/CuePadKit/Sources/CueCLI` | `cuepad` 命令行；`cuepad --help` 是其唯一文档 |
| `apple/CuePadKit/Tests` | 各模块的 Swift Testing 测试 |
| `apple/scripts` | `xc.sh`（构建、测试、截图、发布的入口，用法见头注释）与测量、签名、发布脚本 |
| `landing/` | 双语营销落地页（SvelteKit + GSAP，部署 Vercel），见 [landing/AGENTS.md](landing/AGENTS.md) |
| `design/` | 品牌 IP 与 logo 定稿（`final/`）、宣传素材源与合成模板（`promo/`）、图标脚本（`tools/`） |
