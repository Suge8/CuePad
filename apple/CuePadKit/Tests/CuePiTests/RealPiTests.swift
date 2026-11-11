#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

private let longCommand = "echo " + String(repeating: "a", count: 200)

/// 端到端：真实 Pi（钉住的版本）+ 安装器装进临时 agent 目录的真实扩展 + 假模型 + `Bridge`。
@MainActor
@Suite(RealAgents.needs(.pi), RealAgents.tiered)
struct RealPiTests {
    /// 起 Pi、等桥发现它，测试体结束后停掉 Pi 与桥（Pi 进程的生命周期必须覆盖整个测试体）。
    func withRig(_ body: (PiProcess, Bridge, Session) async throws -> Void) async throws {
        let pi = try await PiProcess()
        let bridge = Bridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        try await eventually("桥发现真实 Pi 会话") { !bridge.sessions.isEmpty }
        try await body(pi, bridge, bridge.sessions[0])
    }

    @Test(.tags(.smoke)) func installedExtensionIsLoadedByPiAndReportsTheSession() async throws {
        try await withRig { pi, _, s in
            #expect(s.pid == pi.pid)
            #expect(s.cwd.resolvingSymlinksInPath().path == pi.cwd.resolvingSymlinksInPath().path)
            #expect(s.model?.key.id == "echo" && s.thinking == .known(.off))
            #expect(s.state == .settled)
            #expect(s.terminal.program == "test-term" && s.terminal.bundleID == "com.example.term")
            #expect(s.terminal.tmuxPane == "%9" && s.terminal.tmuxSocketPath == "/tmp/tmux-test/default")
            #expect(s.sessionFile?.path.hasPrefix(pi.paths.sessionsDirectory.resolvingSymlinksInPath().path) == true
                    || s.sessionFile?.path.hasPrefix(pi.paths.sessionsDirectory.path) == true)
        }
    }

    @Test func configureSwitchesTheRealSessionsModelAndThinking() async throws {
        try await withRig { _, bridge, s in
            #expect(s.availableModels.map(\.key.id).sorted() == ["echo", "echo-b", "echo-think"])
            #expect(s.availableModels.first { $0.key.id == "echo" }?.thinkingLevels == [.off])
            #expect(s.availableModels.first { $0.key.id == "echo-think" }?.thinkingLevels == [.off, .minimal, .low, .medium, .high])

            try await bridge.configure(SessionConfig(model: ModelKey(provider: "fake", id: "echo-think"), thinking: .high), in: s.id)
            try await eventually("上报跟上") { bridge.sessions.first?.model?.key.id == "echo-think" && bridge.sessions.first?.thinking == .known(.high) }

            try await bridge.configure(SessionConfig(thinking: .low), in: s.id)
            try await eventually("只改强度") { bridge.sessions.first?.thinking == .known(.low) }

            try await bridge.configure(SessionConfig(model: ModelKey(provider: "fake", id: "echo"), thinking: .high), in: s.id)
            try await eventually("不支持思考的模型把强度夹到 off") { bridge.sessions.first?.model?.key.id == "echo" && bridge.sessions.first?.thinking == .known(.off) }

            await #expect(throws: BridgeError.unknownModel(.pi)) {
                try await bridge.configure(SessionConfig(model: ModelKey(provider: "fake", id: "nope")), in: s.id)
            }

            #expect(bridge.sessions.first?.capabilities.contains(.images) == true)
            try await bridge.configure(SessionConfig(model: ModelKey(provider: "fake", id: "echo-b")), in: s.id)
            try await eventually("不能看图") { bridge.sessions.first?.capabilities.contains(.images) == false }
            await #expect(throws: BridgeError.unsupported) {
                try await bridge.send(SessionMessage(text: "看图", images: [MessageImage(mimeType: "image/png", data: Data([0x89]))]), to: s.id)
            }
            try await bridge.configure(SessionConfig(model: ModelKey(provider: "fake", id: "echo")), in: s.id)
            try await eventually("又能看图") { bridge.sessions.first?.capabilities.contains(.images) == true }

            try await bridge.configure(SessionConfig(name: "登录修复"), in: s.id)
            try await eventually("改名") { bridge.sessions.first?.displayName == "登录修复" }
            await #expect(throws: BridgeError.rejected("bad_request")) { try await bridge.configure(SessionConfig(name: "  "), in: s.id) }
        }
    }

    @Test func choicesFollowPisModelScopeAndAlwaysIncludeTheCurrentModel() async throws {
        let pi = try await PiProcess(extraArguments: ["--model", "fake/echo", "--models", "fake/echo-think"])
        let bridge = Bridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        try await eventually("桥发现真实 Pi 会话") { !bridge.sessions.isEmpty }
        #expect(bridge.sessions[0].availableModels.map(\.key.id).sorted() == ["echo", "echo-think"])  // echo 是当前模型，不在范围内也列出
    }

    @Test func displayNameFollowsPisSessionListAndUpdatesOnRename() async throws {
        try await withRig { pi, bridge, s in
            let log = ChangeLog(bridge)
            #expect(s.displayName == pi.cwd.lastPathComponent)  // 还没有名字，也没有消息

            try pi.prompt("修好登录\n顺便看看日志")
            try await eventually("首条消息成为显示名") {
                bridge.sessions.first?.displayName == "修好登录 顺便看看日志"
            }

            try pi.send(["type": "set_session_name", "name": "登录修复"])  // 与 /name 同一路径
            try await eventually("改名后显示名跟上") { bridge.sessions.first?.displayName == "登录修复" }
            try await eventually("日志记下了") { log.changes.contains { if case .infoChanged(let renamed) = $0 { renamed.displayName == "登录修复" } else { false } } }
        }
    }

    /// 会话目录可能在开始监听后才由 Pi 建出（见 HistoryIndexerTests），所以刚用完的会话要立即进历史，不等下次启动扫描。
    @Test func endedSessionIsInHistoryRightAwayAndTheEndEventCarriesItsName() async throws {
        try await withRig { pi, bridge, s in
            let ended = ChangeLog(bridge)
            let history = HistoryEventLog(HistoryIndexer(agent: .pi, paths: AgentPaths(pi: pi.paths), files: scratchFiles) { _ in nil }!, following: bridge.sessionFiles)
            try await eventually("回填完成") { history.finishedBackfill }

            try pi.prompt("记进历史")
            try await eventually("回复写入") { !fileTexts("assistant", in: s.sessionFile).isEmpty }
            pi.kill(SIGTERM)

            try await eventually("退出的会话在历史里") {
                history.updates.contains { $0.history.displayName == "记进历史" }
            }
            try await eventually("会话结束") { bridge.sessions.isEmpty }
            try await eventually("日志记下了") { ended.ended.first?.0.displayName == "记进历史" }
        }
    }

    @Test func aWorkingStretchKeepsOneClockAcrossThinkingAndToolsAndClearsWhenIdle() async throws {
        try await withRig { pi, bridge, _ in
            let log = ChangeLog(bridge)
            pi.model.on("歇一下", .call("bash", ["command": "sleep 0.3"]), .say("TOOL_DONE"))
            try pi.prompt("歇一下")
            try await eventually("一轮结束") { log.states.last == .settled }
            let working = log.changes.compactMap { change -> Session? in
                guard case .stateChanged(let session, _) = change else { return nil }
                switch session.state {
                case .thinking, .tool: return session
                default: return nil
                }
            }
            #expect(Set(working.map { "\($0.state)" }).count >= 2, "至少经过思考与工具两种细状态")
            let start = try #require(working.first?.busySince)
            #expect(working.allSatisfy { $0.busySince == start && $0.stateSince == start })
            let idle = try #require(bridge.sessions.first)
            #expect(idle.busySince == nil && idle.stateSince > start)
        }
    }

    @Test(arguments: [
        ("echo first\necho second", "echo first"),
        (longCommand, String(longCommand.prefix(119)) + "…"),
    ])
    func bashToolDetailIsTheFirstLineTruncatedTo120Characters(command: String, expected: String) async throws {
        try await withRig { pi, bridge, _ in
            let log = ChangeLog(bridge)
            pi.model.on("跑命令", .call("bash", ["command": command]), .say("TOOL_DONE"))
            try pi.prompt("跑命令")
            try await eventually("一轮结束") { log.states.last == .settled }
            let prefix = "bash\(SessionState.detailSeparator)"
            let details = log.details.compactMap { $0?.hasPrefix(prefix) == true ? String($0!.dropFirst(prefix.count)) : nil }
            #expect(details.first == expected)
            #expect(details.allSatisfy { $0.count <= 120 && !$0.contains("second") })
        }
    }

    @Test func fileToolDetailIsTheFileName() async throws {
        try await withRig { pi, bridge, _ in
            let log = ChangeLog(bridge)
            pi.model.on("写个文件", .call("write", ["path": "\(pi.cwd.path)/notes/hello.txt", "content": "x"]), .say("TOOL_DONE"))
            try pi.prompt("写个文件")
            try await eventually("一轮结束") { log.states.last == .settled }
            try await eventually("日志记下了") { log.details.contains("write · hello.txt") }
        }
    }

    @Test(arguments: [SIGKILL, SIGTERM]) func anExitedPiEndsTheSessionAndItsSocketIsRemoved(_ signal: Int32) async throws {
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

    @Test func oneShotPrintRunsDoNotOpenASocket() async throws {
        let socketDirectory = try makeTempDirectory()
        let model = try await FakeModel()
        let gate = model.gate()
        model.on("hello", .held(gate, then: .say("hi")))
        let pi = try await PiProcess(socketDirectory: socketDirectory, oneShotPrompt: "hello", model: model)
        try await gate.reached()  // 假模型停住：扩展早已加载过，要开 socket 此刻已开
        #expect(try FileManager.default.contentsOfDirectory(atPath: socketDirectory.path).filter { $0.hasSuffix(".sock") }.isEmpty)
        gate.open()
        await pi.waitUntilExit()
    }
}
#endif
