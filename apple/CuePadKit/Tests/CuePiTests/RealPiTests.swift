#if os(macOS)
import Foundation
import Testing
@testable import CuePi

private let longCommand = "echo " + String(repeating: "a", count: 200)
private let cjkCommand = "echo " + String(repeating: "你", count: 130)

/// 端到端：真实 Pi（`~/.local/bin/pi`，已验证到 0.99.1）+ 安装器装进临时 agent 目录的真实扩展 + 假模型 + `PiBridge`。
@MainActor
@Suite(.enabled(if: realPiAvailable, "需要 ~/.local/bin/pi"))
struct RealPiTests {
    /// 起 Pi、等桥发现它，测试体结束后停掉 Pi 与桥（Pi 进程的生命周期必须覆盖整个测试体）。
    private func withRig(_ body: (PiProcess, PiBridge, PiSession) async throws -> Void) async throws {
        let pi = try await PiProcess()
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        try await eventually("桥发现真实 Pi 会话", timeout: .seconds(20)) { !bridge.sessions.isEmpty }
        try await body(pi, bridge, bridge.sessions[0])
    }

    private func history(of session: PiSession) throws -> PiSessionHistory {
        try PiHistory.index(file: #require(session.sessionFile), from: nil).history
    }

    /// 会话文件里的消息（文件顺序）：角色、文字、图片数。真实 Pi 写出的内容，作为投送是否到达模型的证据。
    private func messages(of session: PiSession) -> [(role: String, text: String, images: Int)] {
        guard let file = session.sessionFile, let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "message", let message = object["message"] as? [String: Any],
                  let role = message["role"] as? String else { return nil }
            let blocks = message["content"] as? [[String: Any]] ?? []
            let text = (message["content"] as? String) ?? blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            return (role, text, blocks.filter { $0["type"] as? String == "image" }.count)
        }
    }

    private func replies(of session: PiSession) -> [String] { messages(of: session).filter { $0.role == "assistant" }.map(\.text) }

    @Test func installedExtensionIsLoadedByPiAndReportsTheSession() async throws {
        try await withRig { pi, _, s in
            #expect(s.pid == pi.pid)
            #expect(s.cwd.resolvingSymlinksInPath().path == pi.cwd.resolvingSymlinksInPath().path)
            #expect(s.mode == "rpc")
            #expect(s.model?.id == "echo" && s.thinking == "off")
            #expect(s.extensionVersion == PiExtensionBundle.version && !s.hasOutdatedExtension)
            #expect(s.state == .idle)
            #expect(s.terminal.program == "test-term" && s.terminal.bundleID == "com.example.term")
            #expect(s.terminal.tmuxPane == "%9" && s.terminal.tmuxSocketPath == "/tmp/tmux-test/default")
            #expect(s.sessionFile?.path.hasPrefix(pi.paths.sessionsDirectory.resolvingSymlinksInPath().path) == true
                    || s.sessionFile?.path.hasPrefix(pi.paths.sessionsDirectory.path) == true)
        }
    }

    /// 换模型与思考强度走真实 Pi 的扩展接口：会话上报的模型、强度与可选列表随之更新；模型不支持的强度被 Pi 夹取，找不到的模型被拒绝。
    @Test func configureSwitchesTheRealSessionsModelAndThinking() async throws {
        try await withRig { _, bridge, s in
            #expect(s.availableModels.map(\.id).sorted() == ["echo", "echo-b", "echo-think"])
            #expect(s.availableModels.first { $0.id == "echo" }?.thinkingLevels == ["off"])
            #expect(s.availableModels.first { $0.id == "echo-think" }?.thinkingLevels == ["off", "minimal", "low", "medium", "high"])

            try await bridge.configure(model: PiModelRef(provider: "fake", id: "echo-think"), thinking: "high", in: s.id)
            try await eventually("上报跟上") { bridge.sessions.first?.model?.id == "echo-think" && bridge.sessions.first?.thinking == "high" }

            try await bridge.configure(thinking: "low", in: s.id)
            try await eventually("只改强度") { bridge.sessions.first?.thinking == "low" }

            try await bridge.configure(model: PiModelRef(provider: "fake", id: "echo"), thinking: "high", in: s.id)
            try await eventually("不支持思考的模型把强度夹到 off") { bridge.sessions.first?.model?.id == "echo" && bridge.sessions.first?.thinking == "off" }

            await #expect(throws: PiBridgeError.rejected("unknown_model")) {
                try await bridge.configure(model: PiModelRef(provider: "fake", id: "nope"), in: s.id)
            }
            await #expect(throws: PiBridgeError.rejected("bad_request")) { try await bridge.configure(thinking: "ultra", in: s.id) }
        }
    }

    /// 配了模型范围（`--models`）时，手机可选的就是范围内的（与 Pi 的 /model 一致）；当前模型总在其中。
    @Test func choicesFollowPisModelScopeAndAlwaysIncludeTheCurrentModel() async throws {
        let pi = try await PiProcess(extraArguments: ["--models", "fake/echo-think"])
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        try await eventually("桥发现真实 Pi 会话", timeout: .seconds(20)) { !bridge.sessions.isEmpty }
        #expect(bridge.sessions[0].availableModels.map(\.id).sorted() == ["echo", "echo-think"])  // echo 是当前模型，不在范围内也列出
    }

    @Test func aPromptRunReportsStatesInOrderAndHistoryShowsTheTurn() async throws {
        try await withRig { pi, bridge, s in
            let log = ChangeLog(bridge)
            try pi.prompt("hello")
            try await eventually("一轮结束", timeout: .seconds(20)) { log.states.last == .done(aborted: false) }

            let states = log.states
            #expect(states.first == .thinking)
            let outputting = try #require(states.firstIndex(of: .outputting))
            #expect(outputting < states.count - 1, "outputting 在 done 之前")

            try await eventually("会话文件写入回复", timeout: .seconds(20)) { self.replies(of: s) == ["ECHO hello IMAGES[]"] }
            #expect(try history(of: s).displayName == "hello")
        }
    }

    /// 显示名与 Pi 自己的会话列表同一规则：`/name` 设的名字 → 首条用户消息（单行）→ 工作目录名。
    @Test func displayNameFollowsPisSessionListAndUpdatesOnRename() async throws {
        try await withRig { pi, bridge, s in
            let log = ChangeLog(bridge)
            #expect(s.displayName == pi.cwd.lastPathComponent)  // 还没有名字，也没有消息

            try pi.prompt("修好登录\n顺便看看日志")
            try await eventually("首条消息成为显示名", timeout: .seconds(20)) {
                bridge.sessions.first?.displayName == "修好登录 顺便看看日志"
            }

            try pi.send(["type": "set_session_name", "name": "登录修复"])  // 与 /name 同一路径
            try await eventually("改名后显示名跟上", timeout: .seconds(20)) { bridge.sessions.first?.displayName == "登录修复" }
            #expect(log.changes.contains { if case .infoChanged(let renamed) = $0 { renamed.displayName == "登录修复" } else { false } })
        }
    }

    /// 刚用完的会话要立即进历史，不等下次启动扫描（会话目录可能在开始监听后才由 Pi 建出，见 HistoryIndexerTests）。
    /// 结束的会话仍可按 id 查到（界面据此显示"已结束"）。
    @Test func endedSessionIsInHistoryRightAwayAndStaysLookupable() async throws {
        try await withRig { pi, bridge, s in
            let history = HistoryEventLog(PiHistoryIndexer(root: pi.paths.sessionsDirectory) { _ in nil })
            try await eventually("回填完成") { history.finishedBackfill }

            try pi.prompt("记进历史")
            try await eventually("回复写入", timeout: .seconds(20)) { !self.replies(of: s).isEmpty }
            pi.kill(SIGTERM)

            try await eventually("退出的会话在历史里", timeout: .seconds(5)) {
                history.updates.contains { $0.history.displayName == "记进历史" }
            }
            try await eventually("会话结束") { bridge.sessions.isEmpty }
            #expect(bridge.endedSessions[s.id]?.displayName == "记进历史")
        }
    }

    /// 一段连续处理的计时：思考与工具来回切换时 `stateSince`、`busySince` 都不变（都是开始那一刻），歇下来后 `busySince` 为 nil。
    @Test func aWorkingStretchKeepsOneClockAcrossThinkingAndToolsAndClearsWhenIdle() async throws {
        try await withRig { pi, bridge, _ in
            let log = ChangeLog(bridge)
            try pi.prompt("[[tool:sleep 0.3]]")
            try await eventually("一轮结束", timeout: .seconds(20)) { log.states.last == .done(aborted: false) }
            let working = log.changes.compactMap { change -> PiSession? in
                guard case .stateChanged(let session, _) = change else { return nil }
                switch session.state {
                case .thinking, .outputting, .tool: return session
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

    /// CuePad 开的新会话：Mac 经环境变量把发起方的认领标识交给 Pi，扩展在 hello 里带回。
    @Test func aLaunchTokenFromTheEnvironmentComesBackInHello() async throws {
        let pi = try await PiProcess(env: ["CUEPAD_LAUNCH_TOKEN": "tok-1"])
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        try await eventually("桥发现会话", timeout: .seconds(20)) { !bridge.sessions.isEmpty }
        #expect(bridge.sessions.first?.launchToken == "tok-1")
    }

    @Test func toolExecutionShowsToolStateWithItsName() async throws {
        try await withRig { pi, bridge, s in
            let log = ChangeLog(bridge)
            try pi.prompt("[[tool:echo hi]]")
            try await eventually("一轮结束", timeout: .seconds(20)) { log.states.last == .done(aborted: false) }
            #expect(log.states.contains { if case .tool(let name, let running, _) = $0 { name == "bash" && running == ["bash"] } else { false } })
            try await eventually("回复", timeout: .seconds(20)) { self.replies(of: s).last == "TOOL_DONE" }
        }
    }

    /// 工具状态只带一句话摘要：bash 取命令首行，超长截到 120 字符（含省略号），不上报完整参数。
    @Test(arguments: [
        ("echo hi", "echo hi"),
        ("echo first\\necho second", "echo first"),
        (longCommand, String(longCommand.prefix(119)) + "…"),
        (cjkCommand, String(cjkCommand.prefix(119)) + "…"),
    ])
    func bashToolDetailIsTheFirstLineTruncatedTo120Characters(command: String, expected: String) async throws {
        try await withRig { pi, bridge, _ in
            let log = ChangeLog(bridge)
            try pi.prompt("[[tool:\(command)]]")
            try await eventually("一轮结束", timeout: .seconds(20)) { log.states.last == .done(aborted: false) }
            let details = log.states.compactMap { if case .tool(_, _, let detail) = $0 { detail } else { nil } }
            #expect(details.first == expected)
            #expect(details.allSatisfy { $0.count <= 120 && !$0.contains("second") })
        }
    }

    @Test func fileToolDetailIsTheFileName() async throws {
        try await withRig { pi, bridge, _ in
            let log = ChangeLog(bridge)
            try pi.prompt("[[write:\(pi.cwd.path)/notes/hello.txt]]")
            try await eventually("一轮结束", timeout: .seconds(20)) { log.states.last == .done(aborted: false) }
            #expect(log.states.contains(.tool(name: "write", running: ["write"], detail: "hello.txt")))
        }
    }

    @Test func sendDeliversTextAndImageIntoTheModelContext() async throws {
        try await withRig { _, bridge, s in
            let delivery = try await bridge.send(PiMessage(text: "look", images: [PiImage(mimeType: "image/png", data: tinyPNG)]), to: s.id)
            #expect(delivery == .immediate)
            try await eventually("回复写入", timeout: .seconds(20)) { !self.replies(of: s).isEmpty }
            let prompt = try #require(messages(of: s).first { $0.role == "user" })
            #expect(prompt.text.hasPrefix("look") && prompt.images == 1)
            let reply = replies(of: s)[0]
            #expect(reply.contains("IMAGES[image/png:"), "假模型看到了图片：\(reply)")
        }
    }

    @Test func steerAndFollowUpAreQueuedWhileBusyAndBothProcessedInOrder() async throws {
        try await withRig { pi, bridge, s in
            try pi.prompt("[[slow]] first")
            try await eventually("进入忙碌") { bridge.sessions.first?.state != .idle }

            let steer = try await bridge.send(PiMessage(text: "STEER-ME", whenBusy: .steer), to: s.id)
            let follow = try await bridge.send(PiMessage(text: "FOLLOW-ME"), to: s.id) // 缺省 followUp
            #expect(steer == .queued(.steer))
            #expect(follow == .queued(.followUp))

            try await eventually("三轮都回复", timeout: .seconds(30)) { self.replies(of: s).count == 3 }
            let replies = replies(of: s)
            #expect(replies[1].hasPrefix("ECHO STEER-ME") && replies[2].hasPrefix("ECHO FOLLOW-ME"))
        }
    }

    @Test func pasteReachesPisEditor() async throws {
        try await withRig { pi, bridge, s in
            try await bridge.paste("draft from CuePad", into: s.id)
            let request = try await pi.waitForEvent("Pi 收到编辑器文本") {
                $0["type"] as? String == "extension_ui_request" && $0["method"] as? String == "set_editor_text"
            }
            #expect(request["text"] as? String == "draft from CuePad")
        }
    }

    /// 等待用户时 `question` 是弹窗：种类、文案（确认框的标题与说明，换行分隔）、选项与这次弹窗的标识；在 Pi 里回答后清空。
    @Test func extensionDialogShowsWaitingUserWithTheQuestionThenResumes() async throws {
        try await withRig { pi, bridge, _ in
            try pi.prompt("/ask")
            try await eventually("等待用户", timeout: .seconds(20)) {
                bridge.sessions.first?.state == .waitingUser(kind: "confirm", title: "Proceed?")
            }
            let confirm = try #require(bridge.sessions.first?.question)
            #expect(confirm.kind == "confirm" && confirm.text == "Proceed?\ntest dialog" && confirm.options.isEmpty && confirm.id != nil)
            let dialog = try await pi.waitForEvent("对话框请求") { $0["method"] as? String == "confirm" }
            try pi.send(["type": "extension_ui_response", "id": dialog["id"] as Any, "confirmed": true])
            try await eventually("回到空闲", timeout: .seconds(20)) { bridge.sessions.first?.state == .idle }
            #expect(bridge.sessions.first?.question == nil)

            try pi.prompt("/pick")
            try await eventually("选择框的问题带选项", timeout: .seconds(20)) { bridge.sessions.first?.question?.options == ["Alpha", "Beta"] }
            #expect(bridge.sessions.first?.question?.kind == "select" && bridge.sessions.first?.question?.text == "Which one?")
            let select = try await pi.waitForEvent("选择框请求") { $0["method"] as? String == "select" }
            try pi.send(["type": "extension_ui_response", "id": select["id"] as Any, "value": "Alpha"])
            try await eventually("回答后清空", timeout: .seconds(20)) { bridge.sessions.first?.question == nil }
        }
    }

    /// 从 CuePad 作答：选择框选中第二项、确认框答"是"，Pi 那边的调用拿到这个答案，弹窗收起、问题清空。
    @Test func answeringThroughTheBridgeResolvesThePiDialog() async throws {
        try await withRig { pi, bridge, s in
            try pi.prompt("/pick")
            try await eventually("选择框", timeout: .seconds(20)) { bridge.sessions.first?.question?.options == ["Alpha", "Beta"] }
            let pick = try #require(bridge.sessions.first?.question?.id)
            try await bridge.answer(.option("Beta"), to: pick, in: s.id)
            _ = try await pi.waitForEvent("扩展拿到选中的第二项") { $0["method"] as? String == "notify" && $0["message"] as? String == "picked:Beta" }
            try await eventually("问题清空", timeout: .seconds(20)) { bridge.sessions.first?.question == nil }

            try pi.prompt("/ask")
            try await eventually("确认框", timeout: .seconds(20)) { bridge.sessions.first?.question?.kind == "confirm" }
            let ask = try #require(bridge.sessions.first?.question?.id)
            try await bridge.answer(.confirmed(true), to: ask, in: s.id)
            _ = try await pi.waitForEvent("扩展拿到确认") { $0["method"] as? String == "notify" && $0["message"] as? String == "confirmed:true" }
            try await eventually("问题清空", timeout: .seconds(20)) { bridge.sessions.first?.question == nil }
        }
    }

    /// 弹窗已经答过（或换了一个）时，拿旧标识作答被拒绝，不会答到别的弹窗上。
    @Test func answeringAStalePromptIsRejected() async throws {
        try await withRig { pi, bridge, s in
            try pi.prompt("/pick")
            try await eventually("选择框", timeout: .seconds(20)) { bridge.sessions.first?.question?.id != nil }
            let first = try #require(bridge.sessions.first?.question?.id)
            try await bridge.answer(.option("Alpha"), to: first, in: s.id)
            try await eventually("问题清空", timeout: .seconds(20)) { bridge.sessions.first?.question == nil }
            await #expect(throws: PiBridgeError.rejected("no_prompt")) { try await bridge.answer(.option("Alpha"), to: first, in: s.id) }

            try pi.prompt("/pick")
            try await eventually("新的选择框", timeout: .seconds(20)) { bridge.sessions.first?.question?.id.map { $0 != first } == true }
            await #expect(throws: PiBridgeError.rejected("stale_prompt")) { try await bridge.answer(.option("Alpha"), to: first, in: s.id) }
            let current = try #require(bridge.sessions.first?.question?.id)
            await #expect(throws: PiBridgeError.rejected("bad_answer")) { try await bridge.answer(.option("Gamma"), to: current, in: s.id) }
        }
    }

    /// 摘要（读会话文件）：你说的话单行、回答保留换行且不含工具输出；机器消息不算你说的，它触发的那轮回答照常算；超长截断。
    @Test func recapIsTheLastPromptAndTheFinalReplyWithoutToolOutput() async throws {
        try await withRig { pi, bridge, s in
            try pi.prompt("第一行\n第二行")
            try await eventually("回答到了", timeout: .seconds(20)) { recap(of: s)?.lastReply == "ECHO 第一行\n第二行 IMAGES[]" }
            #expect(recap(of: s)?.lastPrompt == "第一行 第二行")

            try pi.prompt("[[tool:echo TOOL-OUTPUT-42]]")
            try await eventually("工具轮的最终回答", timeout: .seconds(20)) { recap(of: s)?.lastReply == "TOOL_DONE" }
            #expect(recap(of: s)?.lastPrompt == "[[tool:echo TOOL-OUTPUT-42]]")

            // 整条只由 `<名字>\n…\n</名字>` 块组成的是扩展投进来的机器消息：不算你说的，它触发的那轮回答照常算
            try pi.prompt("<some_event>\n子任务完成\n</some_event>\n<other_note>\n两行\n内容\n</other_note>")
            try await eventually("机器消息那轮的回答", timeout: .seconds(20)) { recap(of: s)?.lastReply?.contains("子任务完成") == true }
            #expect(recap(of: s)?.lastPrompt == "[[tool:echo TOOL-OUTPUT-42]]")

            // 块与块之间夹着真人文字就不是机器消息
            let mixed = "<some_event>\n机器一\n</some_event>\n请解释这个结果\n<some_event>\n机器二\n</some_event>"
            try pi.prompt(mixed)
            try await eventually("夹着真人文字的那轮回答", timeout: .seconds(20)) { recap(of: s)?.lastReply?.contains("请解释这个结果") == true }
            #expect(recap(of: s)?.lastPrompt?.contains("请解释这个结果") == true)

            let long = String(repeating: "长", count: 1300)
            try pi.prompt(long)
            try await eventually("长回答截断", timeout: .seconds(20)) { recap(of: s)?.lastReply?.hasPrefix("ECHO 长") == true }
            let summary = try #require(recap(of: s))
            #expect(summary.lastPrompt?.count == 500 && summary.lastPrompt?.hasSuffix("…") == true)
            #expect(summary.lastReply?.count == 1200 && summary.lastReply?.hasSuffix("…") == true)
        }
    }

    /// 上次在一轮中途退出（工具还在跑）的会话：摘要仍是之前那一轮做完的问答，不把半截的助手消息当成回答。
    @Test func anInterruptedRoundLeavesTheLastCompletedExchangeInTheRecap() async throws {
        try await withRig { pi, bridge, s in
            try pi.prompt("第一问")
            try await eventually("第一轮做完", timeout: .seconds(20)) { recap(of: s)?.lastReply == "ECHO 第一问 IMAGES[]" }
            try pi.prompt("[[tool:sleep 30]]")
            try await eventually("工具在跑", timeout: .seconds(20)) {
                if case .tool = bridge.sessions.first?.state { true } else { false }
            }
            pi.kill(SIGKILL)
            try await eventually("会话结束", timeout: .seconds(20)) { bridge.sessions.isEmpty }

            let summary = try #require(recap(of: s))
            #expect(summary.lastPrompt == "第一问" && summary.lastReply == "ECHO 第一问 IMAGES[]")
        }
    }

    @Test func modelFailureShowsError() async throws {
        try await withRig { pi, bridge, _ in
            try pi.prompt("[[fail]]")
            try await eventually("error 状态", timeout: .seconds(30)) {
                if case .error(let message)? = bridge.sessions.first?.state { message.contains("fake model failure") } else { false }
            }
        }
    }

    @Test func killedPiEndsTheSessionAndItsSocketIsCleanedUp() async throws {
        try await withRig { pi, bridge, s in
            let log = ChangeLog(bridge)
            let socket = pi.paths.socketDirectory.appending(path: "\(s.id).sock")
            pi.kill(SIGKILL)
            try await eventually("会话结束", timeout: .seconds(20)) { !log.ended.isEmpty }
            #expect(log.ended.first?.1 == .disconnected)
            try await eventually("残留 socket 被删") { fileGone(socket) }
        }
    }

    @Test func gracefulExitSaysByeAndRemovesItsSocket() async throws {
        try await withRig { pi, bridge, s in
            let log = ChangeLog(bridge)
            pi.kill(SIGTERM)
            try await eventually("会话结束", timeout: .seconds(20)) { !log.ended.isEmpty }
            #expect(log.ended.first?.1 == .closed(reason: "quit"))
            try await eventually("socket 被删") { fileGone(pi.paths.socketDirectory.appending(path: "\(s.id).sock")) }
        }
    }

    @Test func newSessionClosesTheOldSocketAndOpensANewOne() async throws {
        try await withRig { pi, bridge, first in
            let log = ChangeLog(bridge)
            try pi.send(["type": "new_session"])
            try await eventually("旧会话以 new 结束，新会话出现", timeout: .seconds(20)) {
                log.ended.first?.1 == .closed(reason: "new") && bridge.sessions.contains { $0.sessionID != first.sessionID }
            }
            #expect(bridge.sessions.first?.pid == first.pid)
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
        // pi -p 是脚本/其他工具的一次性调用：没有界面，不该出现在会话列表里
        let socketDirectory = try makeTempDirectory()
        let bridge = PiBridge(socketDirectory: socketDirectory)
        defer { bridge.stop() }
        try bridge.start()
        let log = ChangeLog(bridge)
        let pi = try await PiProcess(socketDirectory: socketDirectory, oneShotPrompt: "[[slow]] hello") // 至少跑 1.5 秒
        await pi.waitUntilExit()
        try await Task.sleep(for: .milliseconds(200))
        #expect(log.changes.isEmpty)
        #expect(bridge.sessions.isEmpty)
    }
}
#endif
