// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "CuePadKit",
    // 界面字由 Xcode 抽进 App 的 String Catalog：包声明了开发语言，Xcode 才对包里的目标抽字
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v26), .iOS(.v27)],
    products: [
        .library(name: "CueText", targets: ["CueText"]),
        .library(name: "CueStore", targets: ["CueStore"]),
        .library(name: "CueEditor", targets: ["CueEditor"]),
        .library(name: "CueBridge", targets: ["CueBridge"]),
        .library(name: "CueSync", targets: ["CueSync"]),
        .library(name: "CueAgent", targets: ["CueAgent"]),
        .library(name: "CueScreen", targets: ["CueScreen"]),
        .executable(name: "cuepad", targets: ["CueCLI"]),
        // 测试共用的支撑：Kit 的测试目标与 App 的测试目标都用它（App 的测试目标经工程里的产品依赖链接）
        .library(name: "CueTestSupport", targets: ["CueTestSupport"]),
    ],
    targets: [
        .target(name: "CueText"),
        .target(name: "CueStore", dependencies: ["CueText"]),
        .target(name: "CueEditor", dependencies: ["CueText"]),
        // 仅 macOS，iOS 目标不依赖。
        .target(name: "CueBridge", dependencies: ["CueStore", "CueText", "CueAgent"], exclude: ["README.md"], resources: [.copy("Extension"), .copy("Brain/claude-subscription.ts"), .copy("Brain/cue-tools.ts"), .copy("Dsh/dsh-cuepad.mjs")]),
        .target(name: "CueSync", dependencies: ["CueStore", "CueText"]),
        .target(name: "CueAgent", dependencies: ["CueStore", "CueText"]),
        .target(name: "CueTestSupport", dependencies: ["CueStore"], path: "Tests/CueTestSupport"),
        .testTarget(name: "CueSyncTests", dependencies: ["CueSync", "CueTestSupport"]),
        // 把一块屏变成本机网页（`cuepad live sim`、`cuepad live app`）。仅 macOS。
        // Sources/CueScreenHost 不是包的目标：工程的 CuePadScreenHost 目标把它与 CueScreen 的源码编成一个库，载进别的应用里取它的窗口。
        .target(name: "CueScreen"),
        .executableTarget(name: "CueCLI", dependencies: ["CueStore", "CueText", "CueAgent", "CueScreen"]),
        .testTarget(name: "CueCLITests", dependencies: ["CueCLI", "CueScreen", "CueTestSupport"]),
        .testTarget(name: "CueTextTests", dependencies: ["CueText"]),
        .testTarget(name: "CueStoreTests", dependencies: ["CueStore", "CueText", "CueTestSupport"]),
        .testTarget(name: "CueEditorTests", dependencies: ["CueEditor", "CueTestSupport"]),
        .testTarget(name: "CueBridgeTests", dependencies: ["CueBridge", "CueStore", "CueTestSupport"], exclude: ["Fixtures"]),
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
