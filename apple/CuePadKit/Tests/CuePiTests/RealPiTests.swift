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
            #expect(s.model == "echo")
            #expect(s.extensionVersion == PiExtensionBundle.version && !s.hasOutdatedExtension)
            #expect(s.state == .idle)
            #expect(s.terminal.program == "test-term" && s.terminal.bundleID == "com.example.term")
            #expect(s.terminal.tmuxPane == "%9" && s.terminal.tmuxSocketPath == "/tmp/tmux-test/default")
            #expect(s.sessionFile?.path.hasPrefix(pi.paths.sessionsDirectory.resolvingSymlinksInPath().path) == true
                    || s.sessionFile?.path.hasPrefix(pi.paths.sessionsDirectory.path) == true)
        }
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

    /// 等待用户时 `question` 是弹窗的文案（确认框的标题与说明、选择框的标题与各选项，换行分隔），回答后清空。
    @Test func extensionDialogShowsWaitingUserWithTheQuestionThenResumes() async throws {
        try await withRig { pi, bridge, _ in
            try pi.prompt("/ask")
            try await eventually("等待用户", timeout: .seconds(20)) {
                bridge.sessions.first?.state == .waitingUser(kind: "confirm", title: "Proceed?")
            }
            #expect(bridge.sessions.first?.question == "Proceed?\ntest dialog")
            let dialog = try await pi.waitForEvent("对话框请求") { $0["method"] as? String == "confirm" }
            try pi.send(["type": "extension_ui_response", "id": dialog["id"] as Any, "confirmed": true])
            try await eventually("回到空闲", timeout: .seconds(20)) { bridge.sessions.first?.state == .idle }
            #expect(bridge.sessions.first?.question == nil)

            try pi.prompt("/pick")
            try await eventually("选择框的问题带选项", timeout: .seconds(20)) { bridge.sessions.first?.question == "Which one?\nAlpha\nBeta" }
            let select = try await pi.waitForEvent("选择框请求") { $0["method"] as? String == "select" }
            try pi.send(["type": "extension_ui_response", "id": select["id"] as Any, "value": "Alpha"])
            try await eventually("回答后清空", timeout: .seconds(20)) { bridge.sessions.first?.question == nil }
        }
    }

    /// 近况：最后一条提问（单行）与助手最后一轮的最终回答（保留换行，不含工具输出）。
    @Test func recapIsTheLastPromptAndTheFinalReplyWithoutToolOutput() async throws {
        try await withRig { pi, bridge, _ in
            try pi.prompt("第一行\n第二行")
            try await eventually("回答到了", timeout: .seconds(20)) { bridge.sessions.first?.lastReply == "ECHO 第一行\n第二行 IMAGES[]" }
            #expect(bridge.sessions.first?.lastPrompt == "第一行 第二行")

            try pi.prompt("[[tool:echo TOOL-OUTPUT-42]]")
            try await eventually("工具轮的最终回答", timeout: .seconds(20)) { bridge.sessions.first?.lastReply == "TOOL_DONE" }
            #expect(bridge.sessions.first?.lastPrompt == "[[tool:echo TOOL-OUTPUT-42]]")

            // 整条只由 `<名字>\n…\n</名字>` 块组成的是扩展投进来的机器消息：不算你说的，它触发的那轮回答照常算
            try pi.prompt("<some_event>\n子任务完成\n</some_event>\n<other_note>\n两行\n内容\n</other_note>")
            try await eventually("机器消息那轮的回答", timeout: .seconds(20)) { bridge.sessions.first?.lastReply?.contains("子任务完成") == true }
            #expect(bridge.sessions.first?.lastPrompt == "[[tool:echo TOOL-OUTPUT-42]]")

            let long = String(repeating: "长", count: 1300)
            try pi.prompt(long)
            try await eventually("长回答截断", timeout: .seconds(20)) { bridge.sessions.first?.lastReply?.hasPrefix("ECHO 长") == true }
            let session = try #require(bridge.sessions.first)
            #expect(session.lastPrompt?.count == 500 && session.lastPrompt?.hasSuffix("…") == true)
            #expect(session.lastReply?.count == 1200 && session.lastReply?.hasSuffix("…") == true)
        }
    }

    /// 接上已有会话（恢复会话文件）时，近况从会话文件里补回来。
    @Test func recapIsRestoredFromTheSessionFileOnResume() async throws {
        try await withRig { pi, bridge, s in
            try pi.prompt("记住这个")
            try await eventually("回答到了", timeout: .seconds(20)) { bridge.sessions.first?.lastReply != nil }
            let log = ChangeLog(bridge)
            try pi.send(["type": "switch_session", "sessionPath": try #require(s.sessionFile).path])
            try await eventually("重新连上", timeout: .seconds(20)) { log.changes.contains { if case .appeared = $0 { true } else { false } } }
            let again = try #require(bridge.sessions.first { $0.sessionID == s.sessionID })
            #expect(again.lastPrompt == "记住这个" && again.lastReply == "ECHO 记住这个 IMAGES[]")
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
