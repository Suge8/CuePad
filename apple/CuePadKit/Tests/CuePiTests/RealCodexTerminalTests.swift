#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

@MainActor
@Suite(RealAgents.live(.codex, "断言的是伪终端里真终端界面的输出与按键、真常驻服务"), .serialized, .timeLimit(.minutes(6)))
struct RealCodexTerminalTests {
    @Test func aTerminalSessionIsSeenAndDrivenFromCuePad() async throws {
        try await withCodexRig(approvals: "on-request") { rig in
            let terminal = try CodexTerminal(rig.codex)
            defer { terminal.stop() }
            try await eventually("终端界面起来了") { terminal.printed("OpenAI Codex") }

            try terminal.type("Reply with the single word READY.")
            try await eventually("终端会话的回答") {
                rig.session.map { rig.replies($0).last?.uppercased().contains("READY") == true && $0.state == .settled } ?? false
            }
            let session = try #require(rig.session)
            #expect(!session.hosted && session.agent == .codex)
            let id = session.id

            let hello = UUID()
            try await rig.bridge.send(PiMessage(text: "Reply with the single word PONG.", deliveryID: hello.uuidString), to: id)
            try await eventually("回答了 CuePad 的话") { rig.replies(session).last?.uppercased().contains("PONG") == true }
            #expect(try rig.transcript(session).messages.contains { $0.deliveryID == hello && $0.text == "Reply with the single word PONG." })
            try await eventually("终端里也显示了这句话") { terminal.printed("PONG") }

            // 在跑时说：停下这一轮（连同在跑的命令），以这句开新一轮。回答用生造的词：被停下那一轮说过的过程说明也算它的回答，可能提到要说的词
            try await rig.bridge.send(PiMessage(text: "Run the shell command `sleep 60`, then reply with the single word ZEBRA."), to: id)
            try await eventually("在跑命令") { rig.bridge.session(id: id)?.detail?.contains("sleep 60") == true }
            let now = UUID(), busy = ChangeLog(rig.bridge)
            try await rig.bridge.send(PiMessage(text: "Reply with the single word MANGO.", deliveryID: now.uuidString), to: id)
            try await eventually("这句开的新一轮答完") {
                rig.bridge.session(id: id)?.state == .settled && rig.replies(session).last?.uppercased().contains("MANGO") == true
                    && busy.states.last == .settled
            }
            #expect(busy.settles == 1, "被停下的那一轮不算歇下：\(busy.states)")
            let said = try rig.transcript(session).messages
            let mango = try #require(said.firstIndex { $0.deliveryID == now })
            #expect(said[..<mango].last { $0.role != .known(.pi) }?.text == PiNotice.stopped.rawValue, "被停下的那一轮留了一行已停止")

            try await rig.bridge.send(PiMessage(text: "Run the shell command `sleep 60`, then reply with the single word LATE."), to: id)
            try await eventually("在跑命令") { rig.bridge.session(id: id)?.detail?.contains("sleep 60") == true }
            try await rig.bridge.abort(id)
            try await eventually("停下了") { rig.bridge.session(id: id)?.state == .settled }
            // 停下时还没说出那句回答（这一轮说过的过程说明照对话规则算它的回答）
            #expect(rig.replies(session).last?.uppercased().contains("LATE") != true, "\(rig.replies(session))")

            try await rig.bridge.configure(PiConfig(thinking: .medium, name: "终端里的会话"), in: id)
            #expect(rig.bridge.session(id: id)?.displayName == "终端里的会话")
            #expect(rig.bridge.session(id: id)?.thinking == .known(.medium))
            try await rig.bridge.command("/compact", in: id)
            try await eventually("压缩了上下文") {
                (try? rig.transcript(session).messages.contains { $0.role == .known(.system) && $0.text == PiNotice.compacted.rawValue }) == true
            }
            try await eventually("压完歇下") { rig.bridge.session(id: id)?.state == .settled }

            try await rig.bridge.send(PiMessage(text: "Run the shell command `sleep 45`, then reply with the single word LATE."), to: id)
            try await eventually("在跑命令") { rig.bridge.session(id: id)?.detail?.contains("sleep 45") == true }
            let later = PiBridge(socketDirectory: rig.codex.root.appending(path: "s2"))
            try later.start()
            let runtime = CodexRuntime(
                bridge: later, paths: rig.codex.paths, hooks: rig.hooks, codex: { [locator = rig.codex.locator] in locator.candidates("codex").first },
                locate: { [locator = rig.codex.locator] in locator }, timing: noDeadline)
            try runtime.start()
            runtime.follow(.all)  // 测试台装了钩子：同 App 检测出接入了
            try await eventually("认出了终端里正在跑的会话") {
                later.session(sessionID: session.sessionID).map { $0.displayName == "终端里的会话" && $0.state.isWorking } ?? false
            }
            let lateID = try #require(later.session(sessionID: session.sessionID)?.id)
            try await later.send(PiMessage(text: "Reply with the single word KIWI."), to: lateID)
            try await eventually("停下那一轮、答了新的一句") {
                later.session(id: lateID)?.state == .settled && rig.replies(session).last?.uppercased().contains("KIWI") == true
            }
            await runtime.stop()()
            later.stop()
        }
    }

    @Test func aSubagentLeftRunningInTheTerminalIsReadBackBeforeSettling() async throws {
        try await withCodexRig { rig in
            let terminal = try CodexTerminal(rig.codex)
            defer { terminal.stop() }
            try await eventually("终端界面起来了") { terminal.printed("OpenAI Codex") }
            let log = ChangeLog(rig.bridge)

            try terminal.type("Spawn exactly one subagent with task name fruit. Tell it: sleep 30 seconds with the sleep tool, then reply with exactly the word BANANA. Do not wait for it: end your turn right away, replying only DISPATCHED. When its result reaches you later, reply with exactly the word it sent you.")
            try await eventually("这一轮结束、在等子代理") { rig.session?.state == .delegating }
            let session = try #require(rig.session)

            let later = PiBridge(socketDirectory: rig.codex.root.appending(path: "s2"))
            try later.start()
            let runtime = CodexRuntime(
                bridge: later, paths: rig.codex.paths, hooks: AgentHookServer(path: rig.codex.root.appending(path: "s2/hooks.sock")),
                codex: { [locator = rig.codex.locator] in locator.candidates("codex").first }, locate: { [locator = rig.codex.locator] in locator },
                timing: noDeadline)
            try runtime.start()
            runtime.follow(.all)
            try await eventually("晚启动也认出在等子代理") {
                later.session(sessionID: session.sessionID).map { $0.state == .delegating && $0.subagents.map(\.name) == ["fruit"] } ?? false
            }
            #expect(later.session(sessionID: session.sessionID)?.subagents.first?.phase == .known(.running))
            await runtime.stop()()
            later.stop()

            try terminal.press("my half-typed draft")
            try await eventually("读到结果后歇下") {
                rig.session.map { $0.state == .settled && rig.replies($0).last?.uppercased().contains("BANANA") == true } ?? false
                    && log.states.last == .settled
            }
            #expect(log.settles == 1, "\(log.states)")
            #expect(rig.session?.subagents.first?.phase == .known(.done))
            try await eventually("终端里也答出了结果") { terminal.printed("BANANA") }
            try terminal.press("\r")
            try await eventually("打了一半的话照常发出") {
                (try? rig.transcript(session).messages.contains { $0.role == .known(.user) && $0.text == "my half-typed draft" }) == true
            }
        }
    }

    /// 原话只在开出线程的连接上，常驻服务只广播 systemError。
    @Test func aFailedTerminalTurnShowsTheReason() async throws {
        try await withCodexRig { rig in
            let terminal = try CodexTerminal(rig.codex, arguments: ["-m", "no-such-model-xyz"])
            defer { terminal.stop() }
            try await eventually("终端界面起来了") { terminal.printed("OpenAI Codex") }
            try terminal.type("Reply OK.")
            try await eventually("这一轮失败，带着原因") {
                rig.session?.state == .error && rig.session?.errorMessage?.contains("no-such-model-xyz") == true
            }
        }
    }

    @Test func aPermissionRequestGoesWhereThePersonIs() async throws {
        try await withCodexRig(approvals: "on-request") { rig in
            let terminal = try CodexTerminal(rig.codex)
            defer { terminal.stop() }
            try await eventually("终端界面起来了") { terminal.printed("OpenAI Codex") }
            try terminal.type("Reply with the single word READY.")
            try await eventually("终端会话的回答") { rig.session?.state == .settled && rig.session.map { !rig.replies($0).isEmpty } == true }
            let id = try #require(rig.session?.id)
            // 允许的那一项：联网时是 "Yes, just this once"
            let approval = "Yes, "
            @MainActor func fetch(_ file: String) async throws {
                let text = "Run exactly this shell command, requesting escalated sandbox permissions up front because it needs network access: curl -s -o \(file) https://example.com"
                try await rig.bridge.send(PiMessage(text: text), to: id)
            }
            // 在终端里答：确认框弹出来后（从 `since` 起找）按 y，界面偶尔吞掉刚弹出时的按键，还在等就每秒再按；在 CuePad 里答：每个问题答一次
            @MainActor func fetched(_ file: String, inTerminalSince since: Int? = nil) async throws {
                var pressed: ContinuousClock.Instant?
                var answered: Set<String> = []
                try await eventually("都允许了、这一轮做完") {
                    let session = rig.bridge.session(id: id)
                    if let since, terminal.printed(approval, since: since), let question = session?.question, !question.isAnswerable,
                       pressed.map({ ContinuousClock.now - $0 > .seconds(1) }) ?? true {
                        pressed = .now
                        try terminal.press("y")
                    }
                    if since == nil, let prompt = session?.question?.promptID, answered.insert(prompt).inserted {
                        try await rig.bridge.answer(.confirmed(true), to: prompt, in: id)
                    }
                    return session?.state == .settled
                }
                #expect(FileManager.default.fileExists(atPath: rig.codex.work.appending(path: file).path))
            }

            // 人在：终端弹框，CuePad 里显示但答不了（一刻也不能答，手机不会收到要你确认的通知）；在终端里允许
            rig.presence.isPresent = true
            let log = ChangeLog(rig.bridge)
            var mark = terminal.printedCount
            try await fetch("here.html")
            try await eventually("等你确认") { rig.bridge.session(id: id)?.question != nil }
            let shown = try #require(rig.bridge.session(id: id)?.question)
            #expect(!shown.isAnswerable && shown.kind == .known(.confirm) && shown.text.contains("here.html"))
            #expect(rig.bridge.session(id: id)?.state == .waitingForUser)
            try await eventually("终端弹出确认框") { terminal.printed(approval, since: mark) }
            try await fetched("here.html", inTerminalSince: mark)
            #expect(!log.changes.contains { if case .stateChanged(let s, _) = $0 { s.question?.isAnswerable == true } else { false } })

            rig.presence.isPresent = false
            mark = terminal.printedCount
            try await fetch("away.html")
            try await eventually("等你在 CuePad 里确认") { rig.bridge.session(id: id)?.question?.isAnswerable == true }
            let asked = try #require(rig.bridge.session(id: id)?.question)
            #expect(asked.text.contains("away.html") && !terminal.printed(approval, since: mark))
            try await fetched("away.html")
            #expect(!terminal.printed(approval, since: mark))

            mark = terminal.printedCount
            try await fetch("back.html")
            try await eventually("等你在 CuePad 里确认") { rig.bridge.session(id: id)?.question?.isAnswerable == true }
            #expect(!terminal.printed(approval, since: mark))
            rig.presence.isPresent = true
            try await eventually("CuePad 里收起成只显示") {
                rig.bridge.session(id: id).map { $0.state == .waitingForUser && $0.question?.isAnswerable == false } ?? false
            }
            try await eventually("终端补弹确认框") { terminal.printed(approval, since: mark) }
            try await fetched("back.html", inTerminalSince: mark)
        }
    }
}
#endif
