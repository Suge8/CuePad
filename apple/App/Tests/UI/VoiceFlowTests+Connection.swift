#if os(macOS)
import CueBridge
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

extension VoiceFlowTests {
    @Test(arguments: ["permission", "login", "quota", "codex"])
    func 连接失败提供原因与重连_修好条件后同一入口恢复(kind: String) async throws {
        let (app, fixture) = try await setup()
        defer { fixture.call.hangUp(); app.services.cancelBackgroundWork() }
        if kind == "permission" { fixture.media.denied = true }
        if kind == "login" { fixture.access = { throw CodexAccessError.signedOut } }
        if kind == "quota" { fixture.connectError = .notAllowed(429) }
        if kind == "codex" { fixture.access = { throw CodexAccessError.unresponsive } }
        let validAccess = VoiceFlowFixture(app.services).access
        fixture.start()
        try await eventually("显示连接失败") { !fixture.call.isLive && fixture.call.phase.isFailure }
        let said = fixture.workspace.voicePresentation?.issues.map { String(localized: $0.message) } ?? []
        #expect(!said.isEmpty)
        if kind == "codex" { #expect(said.contains("Mac 上的 Codex 没响应：看看有没有系统提示在等你确认")) }
        #expect(fixture.workspace.voicePresentation?.canStopExecution == false)
        fixture.media.denied = false
        fixture.connectError = nil
        fixture.access = validAccess
        try await fixture.connect()
        try await fixture.hangUp()
    }

    @Test func 等凭证时挂断不等待网络_不会随后自己接通() async throws {
        let (app, fixture) = try await setup()
        defer { app.services.cancelBackgroundWork() }
        let gate = AsyncStream<Void>.makeStream()
        fixture.access = {
            for await _ in gate.stream { break }
            throw CancellationError()
        }
        fixture.start()
        try await fixture.hangUp()
        gate.continuation.finish()
        #expect(fixture.controls.isEmpty)
        #expect(fixture.workspace.voicePresentation?.activity == .ended)
        #expect(fixture.workspace.voicePresentation?.issues.isEmpty == true)
    }

    @Test(arguments: ["ready", "connecting", "failure"])
    func 关闭完成前不呈现终态_释放后可重连且忽略旧事件(kind: String) async throws {
        let (app, fixture) = try await setup()
        let gate = AsyncStream<Void>.makeStream(), accessGate = AsyncStream<Void>.makeStream()
        defer { gate.continuation.finish(); accessGate.continuation.finish(); app.services.cancelBackgroundWork() }
        let access = fixture.access
        if kind == "connecting" {
            fixture.access = {
                for await _ in accessGate.stream {}
                return try await access()
            }
            fixture.start()
            try await eventually("等待连接") { fixture.call.phase == .connecting }
        } else {
            try await fixture.connect()
            let request = try await fixture.handoff("整理发布清单")
            try await finish(app.services.store, "清单已整理", requests: [request])
            try await eventually("真实结果可见") { fixture.call.replies.count == 1 }
        }
        let oldEvent = fixture.received
        fixture.media.closeGate = gate.stream
        if kind == "failure" { oldEvent?(.success(.error("连接已中断"))) }
        else { fixture.call.hangUp() }
        try await eventually("关闭停在设备边界") { fixture.media.closing }
        #expect(fixture.call.isLive)
        #expect(fixture.workspace.voicePresentation?.activity != .ended)
        #expect(fixture.workspace.voicePresentation?.activity != .failed)
        #expect(fixture.workspace.voicePresentation?.active == true)
        let requests = fixture.call.requests.count
        oldEvent?(.success(.delegation(.init(id: "late", turn: nil, text: "迟到请求"))))
        oldEvent?(.success(.started))
        gate.continuation.finish()
        try await eventually("关闭真正完成") { !fixture.call.isLive }
        #expect(fixture.call.phase.isFailure == (kind == "failure"))
        #expect(fixture.call.requests.count == requests)
        if kind != "connecting" { #expect(fixture.call.replies.first?.text == "清单已整理") }
        fixture.media.closeGate = nil
        fixture.access = access
        accessGate.continuation.finish()
        try await fixture.connect()
        oldEvent?(.success(.error("旧连接迟到错误")))
        oldEvent?(.success(.delegation(.init(id: "late-after-reconnect", turn: nil, text: "旧连接迟到请求"))))
        fixture.received?(.success(.usage(audioMs: 9876)))
        try await eventually("新连接已消费旧事件之后的屏障") { fixture.call.audioMs == 9876 || fixture.call.phase.isFailure }
        #expect(fixture.call.phase == .listening)
        #expect(fixture.call.requests.count == requests)
        try await fixture.hangUp()
    }
}
#endif
