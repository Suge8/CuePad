// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "CuePadKit",
    platforms: [.macOS(.v26), .iOS(.v27)],
    products: [
        .library(name: "CueText", targets: ["CueText"]),
        .library(name: "CueStore", targets: ["CueStore"]),
        .library(name: "CueEditor", targets: ["CueEditor"]),
        .library(name: "CuePi", targets: ["CuePi"]),
        .library(name: "CueSync", targets: ["CueSync"]),
        .library(name: "CueAgent", targets: ["CueAgent"]),
        .executable(name: "cuepad", targets: ["CueCLI"]),
        // 测试共用的支撑：Kit 的测试目标与 App 的测试目标都用它（App 的测试目标经工程里的产品依赖链接）
        .library(name: "CueTestSupport", targets: ["CueTestSupport"]),
    ],
    targets: [
        // 卡片正文的纯文本模型：解析/序列化、标题与按行规则、分割线、变量、光标规范化。仅依赖 Foundation。
        .target(name: "CueText"),
        // SQLite 唯一事实源、结构与升级、仓储。直接用系统 SQLite3，零第三方依赖。
        .target(name: "CueStore", dependencies: ["CueText"], linkerSettings: [.linkedLibrary("sqlite3")]),
        // TextKit 2 编辑器宿主（AppKit / UIKit）。
        .target(name: "CueEditor", dependencies: ["CueText"]),
        // macOS Pi 桥：扩展（随包资源）、socket 客户端、会话历史索引、终端跳转。仅 macOS，iOS 目标不依赖。
        .target(name: "CuePi", dependencies: ["CueStore", "CueText"], exclude: ["README.md"], resources: [.copy("Extension")]),
        // iCloud 同步：CKSyncEngine ↔ CueStore 的记录映射、待推送变更、冲突与附件。
        .target(name: "CueSync", dependencies: ["CueStore"]),
        // 总控 Agent Cue：MCP 工具与 stdio 服务（`cuepad mcp`）、交给大脑的信封、记忆视图。
        .target(name: "CueAgent", dependencies: ["CueStore", "CueText"]),
        // 测试共用的支撑（临时库目录、独立 sqlite3 连接、测试图片、手动时钟、条件等待），只给测试目标依赖。
        .target(name: "CueTestSupport", dependencies: ["CueStore"], path: "Tests/CueTestSupport"),
        .testTarget(name: "CueSyncTests", dependencies: ["CueSync", "CueTestSupport"]),
        // `cuepad` 命令行：供人和 agent 读写本机资料库（经 CueStore，零第三方依赖）。
        .executableTarget(name: "CueCLI", dependencies: ["CueStore", "CueText", "CueAgent"]),
        .testTarget(name: "CueCLITests", dependencies: ["CueCLI", "CueTestSupport"]),
        .testTarget(name: "CueAgentTests", dependencies: ["CueAgent", "CueTestSupport"]),
        .testTarget(name: "CueTextTests", dependencies: ["CueText"]),
        .testTarget(name: "CueStoreTests", dependencies: ["CueStore", "CueText", "CueTestSupport"]),
        .testTarget(name: "CueEditorTests", dependencies: ["CueEditor"]),
        .testTarget(name: "CuePiTests", dependencies: ["CuePi", "CueStore", "CueTestSupport"], exclude: ["Fixtures"]),
    ]
)

// Approachable Concurrency（与 App 工程的 SWIFT_APPROACHABLE_CONCURRENCY 同一组语义；其余成员在 Swift 6 模式下已默认开启）：
// nonisolated 的 async 函数跑在调用方的隔离上，要离开调用方的写 @concurrent。
// 库不设默认 MainActor：API 保持 nonisolated，由调用方决定在哪里跑。
for target in package.targets {
    target.swiftSettings = (target.swiftSettings ?? []) + [
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("InferIsolatedConformances"),
    ]
}
