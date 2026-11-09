// swift-tools-version: 6.2
import PackageDescription

// 通话媒体用 stasel/WebRTC 的官方二进制 xcframework（Google libwebrtc 原样编译，不改源码）：系统框架没有 WebRTC，
// ChatGPT 账号的实时语音只开放 WebRTC（直连 WebSocket 被拒），WKWebView 里的 WebRTC 进后台就停。
// 升级版本时同时改 url 与 checksum（`swift package compute-checksum <zip>`），版本只有这一处。
// WebRTCAudioDevice 给 macOS 补上 RTCAudioDevice 的声明（理由见它的头文件）。
let package = Package(
    name: "WebRTCBinary",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [.library(name: "WebRTC", targets: ["WebRTC", "WebRTCAudioDevice"])],
    targets: [
        .binaryTarget(
            name: "WebRTC",
            url: "https://github.com/stasel/WebRTC/releases/download/157.0.0/WebRTC-M157.xcframework.zip",
            checksum: "ffb1221be2138ecc6bc92300ae4f0157e18694d652db9921e4251992ea91a328"),
        .target(name: "WebRTCAudioDevice", dependencies: ["WebRTC"]),
    ]
)
