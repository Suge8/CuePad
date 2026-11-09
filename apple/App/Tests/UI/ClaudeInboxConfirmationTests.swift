#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePad
@testable import CuePi

/// 发给终端里的 Claude Code 的话（经它的收件箱，它不回话）：会话文件里出现了才算送达。它挂起（等你在终端里批准）或丢掉的，
/// 到期报未确认、写明可能的原因，不报送达。这些局面由它自己的设置与启动方式决定，CuePad 不预判（`PiSession.confirmsFromHistory`）。
/// 会话都先于 CuePad 开着、钩子不通（`ClaudeRig`），所以 CuePad 只拿到收件箱、没有令牌。
@Suite(
    .enabled(if: PinnedAgent.claude.uncovered == nil, Comment(rawValue: PinnedAgent.claude.uncovered ?? "")),
    .enabled(if: ExecutableLocator.standard.candidates("tmux").first != nil, "要 tmux"), .timeLimit(.minutes(4)))
@MainActor
struct ClaudeInboxConfirmationTests {
    enum Situation: String, CaseIterable, CustomTestStringConvertible {
        /// 默认模式：收下
        case plain
        /// agent view 派发的会话带的继承模式：跳过权限确认，没令牌的话挂起
        case inheritsBypass
        /// 用户设置 `crossSessionInbound: hold`：别的会话来的话一律挂起
        case holdSetting
        /// 用户设置 `crossSessionInbound: refuse`：一律丢掉，终端里也不说
        case refuseSetting

        var testDescription: String { rawValue }

        var arguments: [String] {
            self == .inheritsBypass ? ["--inherit-permission-mode", "bypassPermissions"] : ["--permission-mode", "default"]
        }

        var settings: String {
            let inbound = switch self {
            case .holdSetting: #", "crossSessionInbound": "hold""#
            case .refuseSetting: #", "crossSessionInbound": "refuse""#
            default: ""
            }
            return #"{"skipDangerousModePermissionPrompt": true\#(inbound)}"#
        }
    }

    @Test(arguments: Situation.allCases)
    func 终端会话收没收下只认会话文件_挂起或丢掉的报未确认(_ situation: Situation) async throws {
        let clock = ManualTiming()
        var terminal: ClaudeRig.Terminal?
        try await ClaudeRig.run(settings: situation.settings, timing: clock.timing, before: { terminal = try await $0.terminal(situation.arguments) }) { rig in
            let terminal = try #require(terminal)
            try await eventually("CuePad 补上这个终端会话") { rig.bridge.sessions.contains { $0.pid == terminal.pid } }
            let session = try #require(rig.bridge.sessions.first { $0.pid == terminal.pid })
            let file = try #require(session.sessionFile)
            await Workspace(services: rig.services).send("INBOX-PROBE 只回复 OK", to: AgentTarget(session: session.sessionID)).value
            let request = try #require(try await rig.store.deliveryRequests(toSession: session.sessionID).last)

            if situation == .plain {
                #expect(try await rig.store.outcome(of: request).status == .known(.succeeded))
                #expect(ClaudeRig.texts(in: file, role: "user").contains { $0.contains("INBOX-PROBE") })
                return
            }
            try await eventually("交出了，在等会话文件") { try await rig.store.deliveryRequest(request.id)?.status == .known(.confirming) }
            if situation != .refuseSetting {
                try await eventually("终端里挂起这句话") { await terminal.screen.contains("Held") }
            }
            let deadline = try #require(try await rig.store.deliveryRequest(request.id)?.deadlineAt)
            await clock.waitForSleeper(until: deadline)
            clock.advance(.seconds(Speech.receiptLimit + 1))
            try await eventually("到期报未确认") { try await rig.store.deliveryRequest(request.id)?.status == .known(.unconfirmed) }
            #expect(try await rig.store.deliveryRequest(request.id)?.reason == PiDeliveryConfirmation.notTaken)

            // 跳过权限确认的会话把挂起的话摆在输入框的位置等你选（终端里打不进字）：挂起本身就是它处理过的证据
            guard situation != .inheritsBypass else { return }
            // 它确实处理过收件箱：之后在终端里说的一轮做完了，那句话仍不在会话文件里，CuePad 跟读这个文件也没把它改成送达
            try await terminal.type("TERMINAL-TURN 只回复 OK")
            try await eventually("终端里这一轮做完") { ClaudeRig.texts(in: file, role: "assistant").contains { $0.hasSuffix("TERMINAL-TURN 只回复 OK") } }
            #expect(!ClaudeRig.texts(in: file, role: "user").contains { $0.contains("INBOX-PROBE") })
            #expect(try await rig.store.deliveryRequest(request.id)?.status == .known(.unconfirmed))
        }
    }

    /// 它在跑一轮时送到的话排到这一轮做完才收。钩子不通，桥上还写着歇着，所以 CuePad 照常交出；到期时它还在跑（看它的登记文件）就接着等，
    /// 这一轮做完、它收下了就是送达，中间不报没收下。
    @Test func 忙时送到的话等这一轮做完_收下了算送达() async throws {
        let clock = ManualTiming()
        var terminal: ClaudeRig.Terminal?
        try await ClaudeRig.run(settings: #"{"skipDangerousModePermissionPrompt": true}"#, timing: clock.timing, before: {
            terminal = try await $0.terminal(["--permission-mode", "default"])
        }) { rig in
            let terminal = try #require(terminal)
            let gate = FakeGate()
            rig.model.on({ !$0.tools.isEmpty && $0.prompt.contains("BUSY-TURN") }) { _ in .held(gate, then: .say("BUSY-DONE")) }
            try await eventually("CuePad 补上这个终端会话") { rig.bridge.sessions.contains { $0.pid == terminal.pid } }
            let session = try #require(rig.bridge.sessions.first { $0.pid == terminal.pid })
            let file = try #require(session.sessionFile)
            let registry = rig.root.appending(path: "config/sessions/\(terminal.pid).json")
            try await terminal.type("BUSY-TURN 慢慢答")
            try await gate.reached()
            #expect((try? Data(contentsOf: registry)).flatMap(JSONValue.parse)?["status"]?.string == "busy")
            #expect(session.state.isTurnRunning == false, "桥上不知道它在跑")

            await Workspace(services: rig.services).send("INBOX-PROBE 只回复 OK", to: AgentTarget(session: session.sessionID)).value
            let request = try #require(try await rig.store.deliveryRequests(toSession: session.sessionID).last)
            try await eventually("交出了，在等会话文件") { try await rig.store.deliveryRequest(request.id)?.status == .known(.confirming) }
            let first = try #require(try await rig.store.deliveryRequest(request.id)?.deadlineAt)
            await clock.waitForSleeper(until: first)
            clock.advance(.seconds(Speech.receiptLimit + 1))
            await clock.waitForSleeper(until: clock.now.addingTimeInterval(Speech.receiptLimit))
            #expect(try await rig.store.deliveryRequest(request.id)?.status == .known(.confirming), "到期时它还在跑：接着等，不报没收下")

            gate.open()
            try await eventually("这一轮做完它收下了，送达") { try await rig.store.deliveryRequest(request.id)?.status == .known(.succeeded) }
            #expect(ClaudeRig.texts(in: file, role: "user").contains { $0.contains("INBOX-PROBE") })
        }
    }
}
#endif
