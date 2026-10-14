#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 端到端：终端里开着的 Codex（真终端界面、真常驻服务、真模型）——CuePad 经钩子看到它，经常驻服务的控制接口对它说话、停止、改设置，
/// 经阻塞的钩子回答它的权限确认。
@MainActor
@Suite(.enabled(if: realCodexSignedIn, "需要本机装有并登录了 codex"), .timeLimit(.minutes(6)))
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
            let replies = rig.replies(session).count
            _ = try await rig.bridge.send(PiMessage(text: "Run the shell command `sleep 60`, then reply with the single word LATE."), to: id)
            try await eventually("在跑命令", timeout: .seconds(120)) { rig.bridge.session(id: id)?.detail?.contains("sleep 60") == true }
            try await rig.bridge.abort(id)
            try await eventually("停下了", timeout: .seconds(20)) { rig.bridge.session(id: id)?.state == .settled }
            #expect(rig.replies(session).count == replies)

            // 权限确认：终端里不弹框，在 CuePad 里允许后命令照常跑
            _ = try await rig.bridge.send(PiMessage(text: "Run exactly this shell command, requesting escalated sandbox permissions up front because it needs network access: curl -s -o page.html https://example.com"), to: id)
            try await eventually("等你确认", timeout: .seconds(120)) { rig.bridge.session(id: id)?.question?.promptID != nil }
            let question = try #require(rig.bridge.session(id: id)?.question)
            #expect(question.kind == .known(.confirm) && question.text.contains("curl"))
            try await rig.bridge.answer(.confirmed(true), to: question.promptID!, in: id)
            try await eventually("这一轮做完", timeout: .seconds(120)) { rig.bridge.session(id: id)?.state == .settled }
            #expect(FileManager.default.fileExists(atPath: rig.codex.work.appending(path: "page.html").path))

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
            let runtime = CodexRuntime(bridge: later, paths: rig.codex.paths, hooks: rig.hooks, locator: rig.codex.locator)
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
}
#endif
