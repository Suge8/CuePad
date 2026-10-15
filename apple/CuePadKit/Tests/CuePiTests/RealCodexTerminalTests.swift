#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 端到端：终端里开着的 Codex（真终端界面、真常驻服务、真模型）——CuePad 经钩子看到它，经常驻服务的控制接口对它说话、停止、改设置，
/// 权限确认按人在不在分给终端或 CuePad。
@MainActor
@Suite(RealAgents.live(.codex, "断言的是伪终端里真终端界面的输出与按键、真常驻服务"), .serialized, .timeLimit(.minutes(6)))
struct RealCodexTerminalTests {
    @Test func aTerminalSessionIsSeenAndDrivenFromCuePad() async throws {
        try await withCodexRig(approvals: "on-request") { rig in
            let terminal = try CodexTerminal(rig.codex)
            defer { terminal.stop() }
            try await eventually("终端界面起来了", timeout: .seconds(60)) { terminal.printed("OpenAI Codex") }

            // 在终端里说的话：会话出现在 CuePad 里（不是托管的），做完后歇下
            try terminal.type("Reply with the single word READY.")
            try await eventually("终端会话的回答", timeout: .seconds(120)) {
                rig.session.map { rig.replies($0).last?.uppercased().contains("READY") == true && $0.state == .settled } ?? false
            }
            let session = try #require(rig.session)
            #expect(!session.hosted && session.agent == .codex)
            let id = session.id

            // 从 CuePad 说：空闲时马上开始，会话文件里认得出是这次投送
            let hello = UUID()
            #expect(try await rig.bridge.send(PiMessage(text: "Reply with the single word PONG.", deliveryID: hello.uuidString), to: id) == .immediate)
            try await eventually("回答了 CuePad 的话", timeout: .seconds(120)) { rig.replies(session).last?.uppercased().contains("PONG") == true }
            #expect(try rig.transcript(session).messages.contains { $0.deliveryID == hello && $0.text == "Reply with the single word PONG." })
            try await eventually("终端里也显示了这句话") { terminal.printed("PONG") }

            // 马上说：插进在跑的这一轮
            _ = try await rig.bridge.send(PiMessage(text: "Run the shell command `sleep 8`, then reply with the single word DONE."), to: id)
            try await eventually("在跑命令", timeout: .seconds(120)) { rig.bridge.session(id: id)?.detail?.contains("sleep 8") == true }
            #expect(try await rig.bridge.send(PiMessage(text: "Also append the word STEERED to your final reply.", whenBusy: .steer), to: id) == .queued(.steer))
            try await eventually("插话进了这一轮的回答", timeout: .seconds(120)) {
                rig.bridge.session(id: id)?.state == .settled && rig.replies(session).last?.uppercased().contains("STEERED") == true
            }

            // 停止这一轮
            _ = try await rig.bridge.send(PiMessage(text: "Run the shell command `sleep 60`, then reply with the single word LATE."), to: id)
            try await eventually("在跑命令", timeout: .seconds(120)) { rig.bridge.session(id: id)?.detail?.contains("sleep 60") == true }
            try await rig.bridge.abort(id)
            try await eventually("停下了", timeout: .seconds(20)) { rig.bridge.session(id: id)?.state == .settled }
            // 停下时还没说出那句回答（这一轮说过的过程说明照对话规则算它的回答）
            #expect(rig.replies(session).last?.uppercased().contains("LATE") != true, "\(rig.replies(session))")

            // 改名、换强度、压缩
            try await rig.bridge.configure(thinking: .medium, name: "终端里的会话", in: id)
            #expect(rig.bridge.session(id: id)?.displayName == "终端里的会话")
            #expect(rig.bridge.session(id: id)?.thinking == .known(.medium))
            try await rig.bridge.command("/compact", in: id)
            try await eventually("压缩了上下文", timeout: .seconds(120)) {
                (try? rig.transcript(session).messages.contains { $0.role == .known(.system) }) == true
            }
            try await eventually("压完歇下", timeout: .seconds(60)) { rig.bridge.session(id: id)?.state == .settled }

            // CuePad 晚于终端里的会话启动、而它正在跑一轮：从常驻服务里认出它与名字，能插话、能停下这一轮
            _ = try await rig.bridge.send(PiMessage(text: "Run the shell command `sleep 45`, then reply with the single word LATE."), to: id)
            try await eventually("在跑命令", timeout: .seconds(120)) { rig.bridge.session(id: id)?.detail?.contains("sleep 45") == true }
            let later = PiBridge(socketDirectory: rig.codex.root.appending(path: "s2"))
            try later.start()
            let runtime = CodexRuntime(bridge: later, paths: rig.codex.paths, hooks: rig.hooks, locate: { [locator = rig.codex.locator] in locator })
            try runtime.start()
            try await eventually("认出了终端里正在跑的会话") {
                later.session(sessionID: session.sessionID).map { $0.displayName == "终端里的会话" && $0.state.isWorking } ?? false
            }
            let lateID = try #require(later.session(sessionID: session.sessionID)?.id)
            #expect(try await later.send(PiMessage(text: "Also append the word LATER.", whenBusy: .steer), to: lateID) == .queued(.steer))
            try await later.abort(lateID)
            try await eventually("停下了", timeout: .seconds(20)) { later.session(id: lateID)?.state == .settled }
            await runtime.stop()()
            later.stop()
        }
    }

    /// 权限确认按人在不在这台 Mac 前分：人在，终端照常弹框，CuePad 里只显示；人不在，钩子挂住、在 CuePad 里答；
    /// 挂着时人回来了，终端补弹确认框，CuePad 里收起成只显示。
    /// 终端里的这一轮出错（账号用不了的模型，Codex 回 400）：会话停在出错，说明是 Codex 的原话，不是笼统的一句。
    /// 原话只在开出线程的连接上，常驻服务只广播 systemError。
    @Test func aFailedTerminalTurnShowsTheReason() async throws {
        try await withCodexRig { rig in
            let terminal = try CodexTerminal(rig.codex, arguments: ["-m", "no-such-model-xyz"])
            defer { terminal.stop() }
            try await eventually("终端界面起来了", timeout: .seconds(60)) { terminal.printed("OpenAI Codex") }
            try terminal.type("Reply OK.")
            try await eventually("这一轮失败，带着原因", timeout: .seconds(120)) {
                rig.session?.state == .error && rig.session?.errorMessage?.contains("no-such-model-xyz") == true
            }
        }
    }

    @Test func aPermissionRequestGoesWhereThePersonIs() async throws {
        try await withCodexRig(approvals: "on-request") { rig in
            let terminal = try CodexTerminal(rig.codex)
            defer { terminal.stop() }
            try await eventually("终端界面起来了", timeout: .seconds(60)) { terminal.printed("OpenAI Codex") }
            try terminal.type("Reply with the single word READY.")
            try await eventually("终端会话的回答", timeout: .seconds(120)) { rig.session?.state == .settled && rig.session.map { !rig.replies($0).isEmpty } == true }
            let id = try #require(rig.session?.id)
            // 允许的那一项：联网时是 "Yes, just this once"
            let approval = "Yes, "
            @MainActor func fetch(_ file: String) async throws {
                let text = "Run exactly this shell command, requesting escalated sandbox permissions up front because it needs network access: curl -s -o \(file) https://example.com"
                _ = try await rig.bridge.send(PiMessage(text: text), to: id)
            }
            // 一条命令 Codex 可能先后要两次确认（提权、联网），每次都允许，直到这一轮做完
            // 在终端里答：确认框弹出来后（从 `since` 起找）按 y，界面偶尔吞掉刚弹出时的按键，还在等就每秒再按；在 CuePad 里答：每个问题答一次
            @MainActor func fetched(_ file: String, inTerminalSince since: Int? = nil) async throws {
                var pressed: ContinuousClock.Instant?
                var answered: Set<String> = []
                try await eventually("都允许了、这一轮做完", timeout: .seconds(120)) {
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
            try await eventually("等你确认", timeout: .seconds(120)) { rig.bridge.session(id: id)?.question != nil }
            let shown = try #require(rig.bridge.session(id: id)?.question)
            #expect(!shown.isAnswerable && shown.kind == .known(.confirm) && shown.text.contains("here.html"))
            #expect(rig.bridge.session(id: id)?.state == .waitingForUser)
            try await eventually("终端弹出确认框", timeout: .seconds(20)) { terminal.printed(approval, since: mark) }
            try await fetched("here.html", inTerminalSince: mark)
            #expect(!log.changes.contains { if case .stateChanged(let s, _) = $0 { s.question?.isAnswerable == true } else { false } })

            // 人不在：终端不弹，在 CuePad 里允许
            rig.presence.isPresent = false
            mark = terminal.printedCount
            try await fetch("away.html")
            try await eventually("等你在 CuePad 里确认", timeout: .seconds(120)) { rig.bridge.session(id: id)?.question?.isAnswerable == true }
            let asked = try #require(rig.bridge.session(id: id)?.question)
            #expect(asked.text.contains("away.html") && !terminal.printed(approval, since: mark))
            try await fetched("away.html")
            #expect(!terminal.printed(approval, since: mark))

            // 挂着时人回来了：终端补弹确认框，CuePad 里收起成只显示；在终端里允许
            mark = terminal.printedCount
            try await fetch("back.html")
            try await eventually("等你在 CuePad 里确认", timeout: .seconds(120)) { rig.bridge.session(id: id)?.question?.isAnswerable == true }
            #expect(!terminal.printed(approval, since: mark))
            rig.presence.isPresent = true
            try await eventually("CuePad 里收起成只显示") {
                rig.bridge.session(id: id).map { $0.state == .waitingForUser && $0.question?.isAnswerable == false } ?? false
            }
            try await eventually("终端补弹确认框", timeout: .seconds(20)) { terminal.printed(approval, since: mark) }
            try await fetched("back.html", inTerminalSince: mark)
        }
    }
}
#endif
