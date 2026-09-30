// swift-tools-version: 6.2
import PackageDescription

// 模块边界见 docs/development.md「代码地图」。每个 target 只有一个写者；依赖变更由主会话统一改本文件。
let package = Package(
    name: "CuePadKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "CueText", targets: ["CueText"]),
        .library(name: "CueStore", targets: ["CueStore"]),
        .library(name: "CueEditor", targets: ["CueEditor"]),
        .library(name: "CueDispatch", targets: ["CueDispatch"]),
        .library(name: "CuePi", targets: ["CuePi"]),
        .library(name: "CueSync", targets: ["CueSync"]),
        .executable(name: "cuepad", targets: ["CueCLI"]),
    ],
    targets: [
        // 卡片正文的纯文本模型：解析/序列化、分块、变量、光标规范化。仅依赖 Foundation。
        .target(name: "CueText"),
        // SQLite 唯一事实源、迁移、仓储、Electron 旧库导入。直接用系统 SQLite3，零第三方依赖。
        .target(name: "CueStore", linkerSettings: [.linkedLibrary("sqlite3")]),
        // TextKit 2 编辑器宿主（AppKit / UIKit）。
        .target(name: "CueEditor", dependencies: ["CueText"]),
        // macOS 通用投送：前台应用追踪、激活、定向粘贴。
        .target(name: "CueDispatch"),
        // macOS Pi 桥：扩展（随包资源）、socket 客户端、会话历史索引、终端跳转。仅 macOS，iOS 目标不依赖。
        .target(name: "CuePi", exclude: ["README.md"], resources: [.copy("Extension")]),
        // iCloud 同步：CKSyncEngine ↔ CueStore 的记录映射、待推送变更、冲突与附件。
        .target(name: "CueSync", dependencies: ["CueStore"]),
        .testTarget(name: "CueSyncTests", dependencies: ["CueSync"]),
        // `cuepad` 命令行：供人和 agent 读写本机资料库（经 CueStore，零第三方依赖）。
        .executableTarget(name: "CueCLI", dependencies: ["CueStore", "CueText"]),
        .testTarget(name: "CueCLITests", dependencies: ["CueCLI"]),
        .testTarget(name: "CueTextTests", dependencies: ["CueText"]),
        .testTarget(name: "CueStoreTests", dependencies: ["CueStore"]),
        .testTarget(name: "CueEditorTests", dependencies: ["CueEditor"]),
        .testTarget(name: "CueDispatchTests", dependencies: ["CueDispatch"]),
        .testTarget(name: "CuePiTests", dependencies: ["CuePi"], exclude: ["Fixtures"]),
    ]
)
