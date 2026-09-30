// swift-tools-version: 6.2
import PackageDescription

// Sparkle 以官方发布的二进制 xcframework 引入（EdDSA 校验的更新流程与增量更新，系统框架没有等价物）；
// 不依赖 Sparkle 的源码仓库。升级版本时同时改这里的 url 与 checksum（`swift package compute-checksum <zip>`）；
// scripts/sparkle.sh 从这里读同一份 url 与 checksum 取出命令行工具，版本只有这一处。
let package = Package(
    name: "SparkleBinary",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Sparkle", targets: ["Sparkle"])],
    targets: [
        .binaryTarget(
            name: "Sparkle",
            url: "https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-for-Swift-Package-Manager.zip",
            checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959")
    ]
)
