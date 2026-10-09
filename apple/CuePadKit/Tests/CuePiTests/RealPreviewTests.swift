#if os(macOS)
import Foundation
import Testing
@testable import CuePi

/// "发到手机预览"的端到端：真实 Pi + 安装器装进临时目录的真实扩展 + 假模型 + `PiBridge`。
/// 模型调用扩展注册的 `cuepad_show` 工具 → 扩展经 socket 请求 CuePad（这里是测试里的处理函数）→ 结果回到工具 → 会话文件里留下一行带预览 id 的结果。
@MainActor
@Suite(.enabled(if: realPiAvailable, "需要 ~/.local/bin/pi"))
struct RealPreviewTests {
    private struct Refused: LocalizedError { var errorDescription: String? { "文件太大，上限 20 MB" } }

    /// 一次工具调用的 `tool_execution_end`：是否出错与结果文字
    private func toolResult(_ pi: PiProcess) throws -> (isError: Bool, text: String) {
        let event = try #require(pi.events.last { $0["type"] as? String == "tool_execution_end" && $0["toolName"] as? String == "cuepad_show" })
        let blocks = (event["result"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return (event["isError"] as? Bool == true, blocks.compactMap { $0["text"] as? String }.joined())
    }

    private func finished(_ pi: PiProcess) async throws {
        _ = try await pi.waitForEvent("工具调用结束", { $0["type"] as? String == "tool_execution_end" && $0["toolName"] as? String == "cuepad_show" })
        _ = try await pi.waitForEvent("这一轮结束", { $0["type"] as? String == "agent_end" })
    }

    @Test func theToolSendsTheFileToCuePadAndTheConversationGetsAPreviewAtThatPlace() async throws {
        let pi = try await PiProcess()
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        var received: [PiShowRequest] = []
        let preview = UUID().uuidString.lowercased()
        bridge.showHandler = { _, request in
            received.append(request)
            return PiShowReply(preview: preview, note: "页面引用了 style.css，手机上看不到")
        }
        try bridge.start()
        try await eventually("桥发现真实 Pi 会话", timeout: .seconds(20)) { !bridge.sessions.isEmpty }
        try "<h1>登录页</h1>".write(to: pi.cwd.appending(path: "demo.html"), atomically: true, encoding: .utf8)

        try pi.prompt("[[show:demo.html|登录页改好了]] 给我看看")
        try await finished(pi)

        // 相对路径按工作目录解析成绝对路径（Pi 的工作目录是真实路径，/tmp 在 macOS 上是 /private/tmp 的链接）
        #expect(received.map { URL(filePath: $0.path).resolvingSymlinksInPath() } == [pi.cwd.appending(path: "demo.html").resolvingSymlinksInPath()])
        #expect(received.first?.title == "登录页改好了")
        let result = try toolResult(pi)
        #expect(!result.isError && result.text.contains("登录页改好了") && result.text.contains("style.css"))
        let transcript = try PiHistory.index(file: #require(bridge.sessions.first?.sessionFile), from: nil).transcript
        #expect(transcript.map(\.role) == [.user, .preview, .pi])
        #expect(transcript[1].text == preview)
    }

    @Test func aRefusedFileFailsTheToolWithTheReasonAndLeavesNoPreview() async throws {
        let pi = try await PiProcess()
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        bridge.showHandler = { _, _ in throw Refused() }
        try bridge.start()
        try await eventually("桥发现真实 Pi 会话", timeout: .seconds(20)) { !bridge.sessions.isEmpty }

        try pi.prompt("[[show:big.pdf]] 给我看看")
        try await finished(pi)

        let result = try toolResult(pi)
        #expect(result.isError && result.text.contains("文件太大，上限 20 MB"))
        let transcript = try PiHistory.index(file: #require(bridge.sessions.first?.sessionFile), from: nil).transcript
        #expect(transcript.map(\.role) == [.user, .pi])
    }

    /// CuePad 没在运行（没有客户端连着这个会话）：工具立即失败并说明，不挂着等、不假装发出去了。
    @Test func withoutCuePadConnectedTheToolFailsRightAway() async throws {
        let pi = try await PiProcess()
        defer { pi.stop() }
        try pi.prompt("[[show:demo.html]] 给我看看")
        try await finished(pi)

        let result = try toolResult(pi)
        #expect(result.isError && result.text.contains("CuePad"))
    }
}
#endif
