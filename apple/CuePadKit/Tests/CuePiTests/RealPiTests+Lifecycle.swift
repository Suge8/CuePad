#if os(macOS)
import CueTestSupport
import Foundation
import Testing
import CueStore
@testable import CuePi

extension RealPiTests {
    /// Pi 退出：被强杀是断开，正常退出是告别（quit）；两种都结束会话、删掉它的 socket。
    @Test(arguments: [SIGKILL, SIGTERM]) func anExitedPiEndsTheSessionAndItsSocketIsRemoved(_ signal: Int32) async throws {
        AgentTape.variant(signal == SIGKILL ? "kill" : "term")
        try await withRig { pi, bridge, s in
            let log = ChangeLog(bridge)
            pi.kill(signal)
            try await eventually("会话结束") { !log.ended.isEmpty }
            try await eventually("日志记下了") { log.ended.first?.1 == (signal == SIGKILL ? .disconnected : .closed(reason: "quit")) }
            try await eventually("socket 被删") { fileGone(pi.paths.socketDirectory.appending(path: "\(s.id).sock")) }
        }
    }

    @Test func extensionRefusesAnInsecureSocketDirectoryAndTellsTheUser() async throws {
        let dir = try makeTempDirectory()
        chmod(dir.path, 0o755)
        let pi = try await PiProcess(socketDirectory: dir)
        _ = try await pi.waitForEvent("Pi 提示桥被禁用") {
            $0["method"] as? String == "notify" && ($0["message"] as? String)?.contains("CuePad") == true
        }
        let sockets = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".sock") }) ?? []
        #expect(sockets.isEmpty)
    }

    /// `pi -p` 是脚本、其他工具的一次性调用：没有界面，不开 socket、不出现在会话列表里。
    @Test func oneShotPrintRunsDoNotOpenASocket() async throws {
        let socketDirectory = try makeTempDirectory()
        let pi = try await PiProcess(socketDirectory: socketDirectory, oneShotPrompt: "[[slow]] hello")
        try await pi.waitUntilHeld()  // 假模型停住：扩展早已加载过，要开 socket 此刻已开
        #expect(try FileManager.default.contentsOfDirectory(atPath: socketDirectory.path).filter { $0.hasSuffix(".sock") }.isEmpty)
        try pi.release()
        await pi.waitUntilExit()
    }
}
#endif
