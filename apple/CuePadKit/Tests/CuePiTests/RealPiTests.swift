#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

private let longCommand = "echo " + String(repeating: "a", count: 200)

/// 端到端：真实 Pi（`~/.local/bin/pi`，已验证到 0.99.1）+ 安装器装进临时 agent 目录的真实扩展 + 假模型 + `PiBridge`。
@MainActor
@Suite(RealAgents.taped(.pi), .agentTape(.pi), RealAgents.serialWhenRecording(.pi), RealAgents.timeLimit(.minutes(5)))
struct RealPiTests {
    /// 起 Pi、等桥发现它，测试体结束后停掉 Pi 与桥（Pi 进程的生命周期必须覆盖整个测试体）。
    func withRig(_ body: (PiProcess, PiBridge, PiSession) async throws -> Void) async throws {
        let pi = try await PiProcess()
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        try await eventually("桥发现真实 Pi 会话") { !bridge.sessions.isEmpty }
        try await body(pi, bridge, bridge.sessions[0])
    }

    @Test func installedExtensionIsLoadedByPiAndReportsTheSession() async throws {
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

    /// 换模型与思考强度走真实 Pi 的扩展接口：会话上报的模型、强度与可选列表随之更新；模型不支持的强度被 Pi 夹取，找不到的模型被拒绝。
    @Test func configureSwitchesTheRealSessionsModelAndThinking() async throws {
        try await withRig { _, bridge, s in
            #expect(s.availableModels.map(\.key.id).sorted() == ["echo", "echo-b", "echo-think"])
            #expect(s.availableModels.first { $0.key.id == "echo" }?.thinkingLevels == [.off])
            #expect(s.availableModels.first { $0.key.id == "echo-think" }?.thinkingLevels == [.off, .minimal, .low, .medium, .high])

            try await bridge.configure(model: PiModelKey(provider: "fake", id: "echo-think"), thinking: .high, in: s.id)
            try await eventually("上报跟上") { bridge.sessions.first?.model?.key.id == "echo-think" && bridge.sessions.first?.thinking == .known(.high) }

            try await bridge.configure(thinking: .low, in: s.id)
            try await eventually("只改强度") { bridge.sessions.first?.thinking == .known(.low) }

            try await bridge.configure(model: PiModelKey(provider: "fake", id: "echo"), thinking: .high, in: s.id)
            try await eventually("不支持思考的模型把强度夹到 off") { bridge.sessions.first?.model?.key.id == "echo" && bridge.sessions.first?.thinking == .known(.off) }

            await #expect(throws: PiBridgeError.unknownModel(.pi)) {
                try await bridge.configure(model: PiModelKey(provider: "fake", id: "nope"), in: s.id)
            }

            // 换到不能看图的模型：不能再发图片（界面的"图片文件…"跟着能力表收起），换回来又能
            #expect(bridge.sessions.first?.capabilities.contains(.images) == true)
            try await bridge.configure(model: PiModelKey(provider: "fake", id: "echo-b"), in: s.id)
            try await eventually("不能看图") { bridge.sessions.first?.capabilities.contains(.images) == false }
            await #expect(throws: PiBridgeError.unsupported) {
                try await bridge.send(PiMessage(text: "看图", images: [PiImage(mimeType: "image/png", data: Data([0x89]))]), to: s.id)
            }
            try await bridge.configure(model: PiModelKey(provider: "fake", id: "echo"), in: s.id)
            try await eventually("又能看图") { bridge.sessions.first?.capabilities.contains(.images) == true }

            // 改名同一条路（Pi 设置会话名的接口），会话名随即上报；空名拒绝
            try await bridge.configure(name: "登录修复", in: s.id)
            try await eventually("改名") { bridge.sessions.first?.displayName == "登录修复" }
            await #expect(throws: PiBridgeError.rejected("bad_request")) { try await bridge.configure(name: "  ", in: s.id) }
        }
    }

    /// 配了模型范围（`--models`）时，手机可选的就是范围内的（与 Pi 的 /model 一致）；当前模型总在其中。
    @Test func choicesFollowPisModelScopeAndAlwaysIncludeTheCurrentModel() async throws {
        let pi = try await PiProcess(extraArguments: ["--model", "fake/echo", "--models", "fake/echo-think"])
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        try await eventually("桥发现真实 Pi 会话") { !bridge.sessions.isEmpty }
        #expect(bridge.sessions[0].availableModels.map(\.key.id).sorted() == ["echo", "echo-think"])  // echo 是当前模型，不在范围内也列出
    }

    /// 显示名与 Pi 自己的会话列表同一规则：`/name` 设的名字 → 首条用户消息（单行）→ 工作目录名。
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

    /// 刚用完的会话要立即进历史，不等下次启动扫描（会话目录可能在开始监听后才由 Pi 建出，见 HistoryIndexerTests）。
    /// 结束的会话仍可按 id 查到（界面据此显示"已结束"）。
    @Test func endedSessionIsInHistoryRightAwayAndTheEndEventCarriesItsName() async throws {
        try await withRig { pi, bridge, s in
            let ended = ChangeLog(bridge)
            let history = HistoryEventLog(PiHistoryIndexer(agent: .pi, paths: AgentPaths(pi: pi.paths), files: scratchFiles) { _ in nil }!, following: bridge.sessionFiles)
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

    /// 一段连续处理的计时：思考与工具来回切换时 `stateSince`、`busySince` 都不变（都是开始那一刻），歇下来后 `busySince` 为 nil。
    @Test func aWorkingStretchKeepsOneClockAcrossThinkingAndToolsAndClearsWhenIdle() async throws {
        try await withRig { pi, bridge, _ in
            let log = ChangeLog(bridge)
            try pi.prompt("[[tool:sleep 0.3]]")
            try await eventually("一轮结束") { log.states.last == .settled }
            let working = log.changes.compactMap { change -> PiSession? in
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

    /// 工具状态只带一句话摘要：bash 取命令首行，超长截到 120 字符（含省略号），不上报完整参数。
    @Test(arguments: [
        ("echo first\\necho second", "echo first"),
        (longCommand, String(longCommand.prefix(119)) + "…"),
    ])
    func bashToolDetailIsTheFirstLineTruncatedTo120Characters(command: String, expected: String) async throws {
        AgentTape.variant("\(command.count)")
        try await withRig { pi, bridge, _ in
            let log = ChangeLog(bridge)
            try pi.prompt("[[tool:\(command)]]")
            try await eventually("一轮结束") { log.states.last == .settled }
            let prefix = "bash\(PiSessionState.detailSeparator)"
            let details = log.details.compactMap { $0?.hasPrefix(prefix) == true ? String($0!.dropFirst(prefix.count)) : nil }
            #expect(details.first == expected)
            #expect(details.allSatisfy { $0.count <= 120 && !$0.contains("second") })
        }
    }

    @Test func fileToolDetailIsTheFileName() async throws {
        try await withRig { pi, bridge, _ in
            let log = ChangeLog(bridge)
            try pi.prompt("[[write:\(pi.cwd.path)/notes/hello.txt]]")
            try await eventually("一轮结束") { log.states.last == .settled }
            try await eventually("日志记下了") { log.details.contains("write · hello.txt") }
        }
    }

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
