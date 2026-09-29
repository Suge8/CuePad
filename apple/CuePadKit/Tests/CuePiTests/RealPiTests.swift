import Foundation
import Testing
@testable import CuePi

/// 端到端：真实 Pi 0.87.1 + 安装器装进临时 agent 目录的真实扩展 + 假模型 + `PiBridge`。
@MainActor
@Suite(.enabled(if: realPiAvailable, "需要 ~/.local/bin/pi"))
struct RealPiTests {
    /// 起 Pi 并等桥发现它。
    private func launch() async throws -> (PiProcess, PiBridge, PiSession) {
        let pi = try await PiProcess()
        let b = PiBridge(socketDirectory: pi.paths.socketDirectory)
        try b.start()
        try await eventually("桥发现真实 Pi 会话", timeout: .seconds(20)) { !b.sessions.isEmpty }
        return (pi, b, b.sessions[0])
    }

    private func history(of session: PiSession) throws -> PiSessionHistory {
        try PiHistory.index(file: #require(session.sessionFile), from: nil).history
    }

    @Test func installedExtensionIsLoadedByPiAndReportsTheSession() async throws {
        let (pi, _, s) = try await launch()
        #expect(s.pid == pi.pid)
        #expect(s.cwd.resolvingSymlinksInPath() == pi.cwd.resolvingSymlinksInPath())
        #expect(s.mode == "rpc")
        #expect(s.model == "echo")
        #expect(s.extensionVersion == PiExtensionBundle.version && !s.hasOutdatedExtension)
        #expect(s.state == .idle)
        #expect(s.terminal.program == "test-term" && s.terminal.bundleID == "com.example.term")
        #expect(s.terminal.tmuxPane == "%9" && s.terminal.tmuxSocketPath == "/tmp/tmux-test/default")
        #expect(s.sessionFile?.path.hasPrefix(pi.paths.sessionsDirectory.resolvingSymlinksInPath().path) == true
                || s.sessionFile?.path.hasPrefix(pi.paths.sessionsDirectory.path) == true)
    }

    @Test func aPromptRunReportsStatesInOrderAndHistoryShowsTheTurn() async throws {
        let (pi, bridge, s) = try await launch()
        let log = ChangeLog(bridge)
        try pi.prompt("hello")
        try await eventually("一轮结束", timeout: .seconds(20)) { log.states.last == .done(aborted: false) }

        let states = log.states
        #expect(states.first == .thinking)
        let outputting = try #require(states.firstIndex(of: .outputting))
        #expect(outputting < states.count - 1, "outputting 在 done 之前")

        try await eventually("会话文件写入回复", timeout: .seconds(20)) { (try? self.history(of: s).turns.first?.status) == .completed }
        let turn = try #require(history(of: s).turns.first)
        #expect(turn.prompt == "hello")
        #expect(turn.reply == "ECHO hello IMAGES[]")
        #expect(turn.promptedAt != nil && turn.repliedAt != nil)
    }

    @Test func toolExecutionShowsToolStateWithItsName() async throws {
        let (pi, bridge, s) = try await launch()
        let log = ChangeLog(bridge)
        try pi.prompt("[[tool:echo hi]]")
        try await eventually("一轮结束", timeout: .seconds(20)) { log.states.last == .done(aborted: false) }
        #expect(log.states.contains(.tool(name: "bash", running: ["bash"])))
        try await eventually("回复", timeout: .seconds(20)) { (try? self.history(of: s).turns.first?.reply) == "TOOL_DONE" }
    }

    @Test func sendDeliversTextAndImageIntoTheModelContext() async throws {
        let (_, bridge, s) = try await launch()
        let delivery = try await bridge.send(PiMessage(text: "look", images: [PiImage(mimeType: "image/png", data: tinyPNG)]), to: s.id)
        #expect(delivery == .immediate)
        try await eventually("回复写入", timeout: .seconds(20)) { (try? self.history(of: s).turns.first?.status) == .completed }
        let turn = try #require(history(of: s).turns.first)
        #expect(turn.prompt.hasPrefix("look"))
        #expect(turn.promptImageCount == 1)
        #expect(turn.reply?.contains("IMAGES[image/png:") == true, "假模型看到了图片：\(turn.reply ?? "nil")")
    }

    @Test func steerAndFollowUpAreQueuedWhileBusyAndBothProcessedInOrder() async throws {
        let (pi, bridge, s) = try await launch()
        try pi.prompt("[[slow]] first")
        try await eventually("进入忙碌") { bridge.sessions.first?.state != .idle }

        let steer = try await bridge.send(PiMessage(text: "STEER-ME", whenBusy: .steer), to: s.id)
        let follow = try await bridge.send(PiMessage(text: "FOLLOW-ME"), to: s.id) // 缺省 followUp
        #expect(steer == .queued(.steer))
        #expect(follow == .queued(.followUp))

        try await eventually("三轮都回复", timeout: .seconds(30)) {
            let turns = (try? self.history(of: s).turns) ?? []
            return turns.count == 3 && turns.allSatisfy { $0.status == .completed }
        }
        let turns = try history(of: s).turns
        #expect(turns[1].prompt == "STEER-ME" && turns[1].reply?.hasPrefix("ECHO STEER-ME") == true)
        #expect(turns[2].prompt == "FOLLOW-ME" && turns[2].reply?.hasPrefix("ECHO FOLLOW-ME") == true)
    }

    @Test func pasteReachesPisEditor() async throws {
        let (pi, bridge, s) = try await launch()
        try await bridge.paste("draft from CuePad", into: s.id)
        let request = try await pi.waitForEvent("Pi 收到编辑器文本") {
            $0["type"] as? String == "extension_ui_request" && $0["method"] as? String == "set_editor_text"
        }
        #expect(request["text"] as? String == "draft from CuePad")
    }

    @Test func extensionDialogShowsWaitingUserThenResumes() async throws {
        let (pi, bridge, _) = try await launch()
        try pi.prompt("/ask")
        try await eventually("等待用户", timeout: .seconds(20)) {
            bridge.sessions.first?.state == .waitingUser(kind: "confirm", title: "Proceed?")
        }
        let dialog = try await pi.waitForEvent("对话框请求") { $0["method"] as? String == "confirm" }
        try pi.send(["type": "extension_ui_response", "id": dialog["id"] as Any, "confirmed": true])
        try await eventually("回到空闲", timeout: .seconds(20)) { bridge.sessions.first?.state == .idle }
    }

    @Test func modelFailureShowsError() async throws {
        let (pi, bridge, _) = try await launch()
        try pi.prompt("[[fail]]")
        try await eventually("error 状态", timeout: .seconds(30)) {
            if case .error(let message)? = bridge.sessions.first?.state { message.contains("fake model failure") } else { false }
        }
    }

    @Test func killedPiEndsTheSessionAndItsSocketIsCleanedUp() async throws {
        let (pi, bridge, s) = try await launch()
        let log = ChangeLog(bridge)
        let socket = pi.paths.socketDirectory.appending(path: "\(s.id).sock")
        pi.kill(SIGKILL)
        try await eventually("会话结束", timeout: .seconds(20)) { !log.ended.isEmpty }
        #expect(log.ended.first?.1 == .disconnected)
        try await eventually("残留 socket 被删") { fileGone(socket) }
    }

    @Test func gracefulExitSaysByeAndRemovesItsSocket() async throws {
        let (pi, bridge, s) = try await launch()
        let log = ChangeLog(bridge)
        pi.kill(SIGTERM)
        try await eventually("会话结束", timeout: .seconds(20)) { !log.ended.isEmpty }
        #expect(log.ended.first?.1 == .closed(reason: "quit"))
        try await eventually("socket 被删") { fileGone(pi.paths.socketDirectory.appending(path: "\(s.id).sock")) }
    }

    @Test func newSessionClosesTheOldSocketAndOpensANewOne() async throws {
        let (pi, bridge, first) = try await launch()
        let log = ChangeLog(bridge)
        try pi.send(["type": "new_session"])
        try await eventually("旧会话以 new 结束，新会话出现", timeout: .seconds(20)) {
            log.ended.first?.1 == .closed(reason: "new") && bridge.sessions.contains { $0.sessionID != first.sessionID }
        }
        #expect(bridge.sessions.first?.pid == first.pid)
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
}
