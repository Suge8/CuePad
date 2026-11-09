#if os(macOS)
import CuePi
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 真 Cue 进程、真实工具服务与库；语音端和执行 Agent 是外部替身。
/// 断言请求从语音派到任务，再从同一个窗口停止真正收到的会话；旁边的会话及后来的人类回合不受影响。
@Suite(.pinnedPi, .serialized)
@MainActor
struct VoiceExecutionTests {
    @Test func Cue先提问再收尾_两条真实回复都归到原语音请求() async throws {
        let rig = try await CueHostTests.Rig()
        let fixture = VoiceFlowFixture(rig.services)
        defer { fixture.call.hangUp(); rig.services.cancelBackgroundWork(); rig.app.pi.stop(); rig.model.stop() }
        try await fixture.connect()
        let request = try await fixture.handoff("请问我一个问题")
        try await eventually("提问与收尾都可见") { fixture.call.replies.count == 2 }
        #expect(fixture.call.replies.allSatisfy { $0.message.answeredRequests == [request] })
        #expect(fixture.call.replies.map(\.text) == ["要推送吗？", "办好了"])
        try await fixture.hangUp()
        await rig.stop()
    }

    @Test(arguments: [false, true])
    func 只停本次语音实际派出的工作_挂断不影响停止与状态回写(whileClosing: Bool) async throws {
        let rig = try await CueHostTests.Rig()
        let fixture = VoiceFlowFixture(rig.services)
        defer { fixture.call.hangUp(); rig.services.cancelBackgroundWork(); rig.app.pi.stop(); rig.model.stop() }
        try await fixture.connect()
        _ = try await fixture.handoff("请建个任务并开工")
        try await eventually("语音确实经 Cue 建卡开会话") { !rig.app.host.extensions.isEmpty }
        let session = try #require(rig.app.host.extensions.values.first)
        try await eventually("开场请求和工具归属均已落库") { fixture.workspace.voiceExecutions.count == 1 }
        session.setState(["kind": "thinking"])
        let other = try await rig.app.host.connect("unrelated", cwd: rig.folder.path, busy: true)
        try await eventually("只有自己的会话可停止") { fixture.workspace.voiceExecutions.filter { $0.state.canStop }.count == 1 }
        #expect(fixture.workspace.voiceExecutions.map { $0.state.sessionID } == [session.sessionID])
        let prior = session.onCommand
        session.onCommand = { connection, command in
            if command["t"] as? String == "abortTurn" { session.setState(["kind": "idle"]) }
            return prior(connection, command)
        }
        let gate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish() }
        if whileClosing {
            fixture.media.closeGate = gate.stream
            fixture.call.hangUp()
            try await eventually("关闭尚未释放，执行仍可停止") {
                fixture.workspace.voicePresentation?.activity == .closing
                    && fixture.workspace.voicePresentation?.canStopExecution == true
            }
        } else { try await fixture.hangUp() }
        let stop = try await fixture.workspace.stopVoiceExecution(session.sessionID)
        try await eventually("Agent 收到停止且真实库记下歇下") {
            session.received.contains("abortTurn") && fixture.workspace.voiceExecutions.first?.state.canStop == false
        }
        #expect(try await rig.store.outcome(of: stop).status == .known(.succeeded))
        #expect(!other.received.contains("abortTurn"))
        #expect(fixture.workspace.voicePresentation?.canStopExecution == false)
        gate.continuation.finish()
        try await eventually("关闭释放后才到终态") { !fixture.call.isLive }
        await rig.stop()
    }

    @Test func 别处开启新回合后_语音历史不能再授权停止该会话() async throws {
        let rig = try await CueHostTests.Rig()
        let fixture = VoiceFlowFixture(rig.services)
        defer { fixture.call.hangUp(); rig.services.cancelBackgroundWork(); rig.app.pi.stop(); rig.model.stop() }
        try await fixture.connect()
        _ = try await fixture.handoff("请建个任务并开工")
        try await eventually("开出实际会话") { !rig.app.host.extensions.isEmpty }
        let session = try #require(rig.app.host.extensions.values.first)
        try await eventually("开场请求和工具归属均已落库") { fixture.workspace.voiceExecutions.count == 1 }
        session.setState(["kind": "thinking"])
        try await eventually("本回合归属已确认") { fixture.workspace.voiceExecutions.first?.state.canStop == true }
        let file = try #require(rig.app.host.sessionFiles[session.sessionID])
        try file.user("我在终端另开的工作")
        try await eventually("新回合不再属于语音") { fixture.workspace.voiceExecutions.isEmpty }
        await #expect(throws: CueStoreError.self) { _ = try await fixture.workspace.stopVoiceExecution(session.sessionID) }
        #expect(!session.received.contains("abortTurn"))
        #expect(fixture.workspace.voicePresentation?.canStopExecution == false)
        try await fixture.hangUp()
        await rig.stop()
    }
}
#endif
