#if os(macOS)
import CuePi
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

@MainActor
struct VoiceFlowTests {
    private func setup() async throws -> (TestApp, VoiceFlowFixture) {
        let app = TestApp(), host = TestApp.hostID
        try await app.services.store.updateCueProfile { $0.enabledAt = .now; $0.hostID = host }
        return (app, VoiceFlowFixture(app.services))
    }

    @Test func 保存请求与Cue接走分开_合批回复不能代替接走回执() async throws {
        let (app, fixture) = try await setup(), store = app.services.store
        defer { fixture.call.hangUp(); app.services.cancelBackgroundWork() }
        try await fixture.connect()
        let first = try await fixture.handoff("保存但未接走 A")
        let second = try await fixture.handoff("保存但未接走 B")
        try await finish(store, "合批结果先到", requests: [first, second])
        try await eventually("合批结果进入界面") { fixture.workspace.voicePresentation?.replies.count == 3 }
        #expect(fixture.workspace.voicePresentation?.replies.allSatisfy { $0.request?.delivery != .delivered } == true)
        try await store.markCueMessagesDelivered([first])
        try await eventually("A 的真实回执到达") { fixture.call.requests.first?.record?.deliveredAt != nil }
        #expect(fixture.workspace.voicePresentation?.replies.last?.request?.delivery != .delivered)
        try await store.markCueMessagesDelivered([second])
        try await eventually("全部收到回执才显示接走") {
            fixture.workspace.voicePresentation?.replies.allSatisfy { $0.request?.delivery == .delivered } == true
        }
        try await fixture.hangUp()
    }

    @Test func 闲聊不派活_重复交接只写一次_乱序与合批回复各归原请求() async throws {
        let (app, fixture) = try await setup(), store = app.services.store
        defer { fixture.call.hangUp(); app.services.cancelBackgroundWork() }
        try await fixture.connect()
        fixture.received?(.success(.turn(id: "chat", assistant: false, done: true, text: "今天阳光很好")))
        fixture.received?(.success(.turn(id: "chat-reply", assistant: true, done: true, text: "是啊")))
        let first = try await fixture.handoff("先建卡", id: "replayed")
        fixture.received?(.success(.delegation(.init(id: "replayed", turn: nil, text: "先建卡"))))
        let second = try await fixture.handoff("再改期")
        #expect(try await store.cueMessages().filter { $0.author == .known(.you) }.map(\.id).count == 2)
        try await finish(store, "改期的结果", requests: [second])
        try await finish(store, "建卡的结果", requests: [first])
        try await finish(store, "两件一起回答", requests: [first, second])
        try await finish(store, "另一个入口的私有回复", requests: [UUID()])
        try await eventually("三条结果进入界面") { fixture.call.replies.count == 3 && fixture.controls[0].sends.count == 3 }
        let rows = try #require(fixture.workspace.voicePresentation?.replies)
        #expect(rows.map(\.text) == ["", "建卡的结果", "", "改期的结果", "两件一起回答"])
        #expect(rows.last?.request?.text == "先建卡\n\n再改期")
        #expect(rows.filter { $0.request?.delivery == .sending }.count == 3)
        #expect(rows.filter { !$0.text.isEmpty }.allSatisfy { $0.note == nil })
        try await fixture.hangUp()
    }

    @Test func 未知来源后补为另一入口_撤下结果且不能再说_主动更新仍可播报() async throws {
        let (app, fixture) = try await setup(), store = app.services.store
        defer { fixture.call.hangUp(); app.services.cancelBackgroundWork() }
        try await fixture.connect()
        _ = try await fixture.handoff("本次通话请求")
        let foreign = try await store.addCueMessage(.you, text: "另一入口的请求")
        let reply = try await store.addCueMessage(.cue, text: "另一入口的结果", answeredRequests: nil)
        try await eventually("来源未知先可见但不自动播报") { fixture.call.replies.contains { $0.id == reply.id } }
        #expect(fixture.controls[0].sends.isEmpty)
        try await store.associateCueReply(reply.id, answering: [foreign.id])
        let marker = try await store.addCueMessage(.cue, text: "合法主动更新", answeredRequests: [])
        try await eventually("已消费来源更新之后的记录") {
            fixture.call.replies.contains { $0.id == marker.id && $0.delivery == .submitted }
        }
        #expect(fixture.workspace.voicePresentation?.replies.contains { $0.id == reply.id } == false)
        fixture.call.repeatReply(reply.id)
        let later = try await store.addCueMessage(.cue, text: "后续主动更新", answeredRequests: [])
        try await eventually("后续发送仍畅通") { fixture.call.replies.contains { $0.id == later.id && $0.delivery == .submitted } }
        #expect(fixture.controls[0].sends.count == 2, "旧结果没有再发送，只有两条真实主动更新")
        try await fixture.hangUp()
    }

    @Test func 挂断保留晚到结果_重新接通不重投_再说不重新派活_静音等设备确认() async throws {
        let (app, fixture) = try await setup(), store = app.services.store
        defer { fixture.call.hangUp(); app.services.cancelBackgroundWork() }
        try await fixture.connect()
        fixture.call.setMuted(true)
        try await eventually("设备与界面都已静音") { fixture.media.muted && fixture.call.isMuted }
        let request = try await fixture.handoff("记一件事")
        try await finish(store, "已记下", requests: [request])
        try await eventually("第一条提交给语音") { fixture.controls[0].sends.count == 1 }
        try await fixture.hangUp()
        try await finish(store, "挂断后到达的进展", requests: [request])
        try await eventually("挂断后仍能看结果") { fixture.workspace.voicePresentation?.replies.filter { !$0.text.isEmpty }.count == 2 }
        try await fixture.connect()
        try await eventually("只提交晚到的那条") { fixture.controls[1].sends.count == 1 }
        let first = try #require(fixture.call.replies.first?.id)
        fixture.call.repeatReply(first)
        try await eventually("明确再说才再次提交") { fixture.controls[1].sends.count == 2 }
        #expect(try await store.cueMessages().filter { $0.author == .known(.you) }.count == 1)
        #expect(fixture.workspace.voicePresentation?.replies.filter { !$0.text.isEmpty }.count == 2)
        try await fixture.hangUp()
    }

    @Test func 部分发送失败保留文字_重连不重复半条_明确再说才重新提交() async throws {
        let (app, fixture) = try await setup(), store = app.services.store
        defer { fixture.call.hangUp(); app.services.cancelBackgroundWork() }
        try await fixture.connect()
        fixture.controls[0].failedAfterFirstFragment = true
        let request = try await fixture.handoff("给我长结果")
        let result = String(repeating: "这是实际结果。", count: 200)
        try await finish(store, result, requests: [request])
        try await eventually("半途失败已收尾") { !fixture.call.isLive }
        #expect(fixture.controls[0].fragments.count == 1)
        #expect(fixture.workspace.voicePresentation?.replies.last?.text == result)
        try await fixture.connect()
        #expect(fixture.controls[1].sends.isEmpty)
        fixture.call.repeatReply(try #require(fixture.call.replies.first?.id))
        try await eventually("完整回复重新提交") { fixture.controls[1].fragments.count > 1 }
        #expect(try await store.cueMessages().filter { $0.author == .known(.you) }.count == 1)
        try await fixture.hangUp()
    }

    @Test(arguments: ["permission", "login", "quota"])
    func 连接失败提供原因与重连_修好条件后同一入口恢复(kind: String) async throws {
        let (app, fixture) = try await setup()
        defer { fixture.call.hangUp(); app.services.cancelBackgroundWork() }
        if kind == "permission" { fixture.media.denied = true }
        if kind == "login" { fixture.access = { throw CodexAccessError.signedOut } }
        if kind == "quota" { fixture.connectError = .notAllowed(429) }
        let validAccess = VoiceFlowFixture(app.services).access
        fixture.start()
        try await eventually("显示连接失败") { !fixture.call.isLive && fixture.call.phase.isFailure }
        #expect(fixture.workspace.voicePresentation?.issue != nil)
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
    }

    @Test func 写库失败可明确重试_原文保留且只产生一条请求() async throws {
        let (app, fixture) = try await setup(), store = app.services.store
        defer { fixture.call.hangUp(); app.services.cancelBackgroundWork() }
        try await fixture.connect()
        let db = RawDB(app.databaseURL)
        try db.exec("CREATE TRIGGER voice_write_failure BEFORE INSERT ON cueMessages WHEN NEW.author = 'you' BEGIN SELECT RAISE(FAIL, 'voice test write failed'); END")
        fixture.received?(.success(.delegation(.init(id: "write-failed", turn: nil, text: "保留这句话"))))
        try await eventually("界面能看到未交出与原文") { fixture.workspace.voiceRetryRequest?.failure != nil }
        #expect(fixture.workspace.voicePresentation?.replies.first?.request?.text == "保留这句话")
        try db.exec("DROP TRIGGER voice_write_failure")
        try await fixture.workspace.retryVoiceRequest("write-failed")
        try await eventually("重试后有真实记录") { fixture.call.requests.first?.record != nil }
        #expect(try await store.cueMessages().filter { $0.author == .known(.you) }.count == 1)
        try await fixture.hangUp()
    }

    private func finish(_ store: CueStore, _ text: String, requests: [UUID]) async throws {
        _ = try await store.finishCueRound(nil, startedAt: .now, answersYou: true, tools: nil, reply: text, as: .cue,
                                           context: nil, answeredRequests: requests)
    }
}
#endif
