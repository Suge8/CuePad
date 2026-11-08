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
        try await eventually("合批结果进入界面") { fixture.call.replies.count == 1 }
        #expect(fixture.trip(first) != .delivered && fixture.trip(second) != .delivered)
        try await store.markCueMessagesDelivered([first])
        try await eventually("A 的真实回执到达") { fixture.call.requests.first?.record?.deliveredAt != nil }
        #expect(fixture.trip(second) != .delivered)
        try await store.markCueMessagesDelivered([second])
        try await eventually("全部收到回执才显示接走") {
            fixture.trip(first) == .delivered && fixture.trip(second) == .delivered
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
        let rows = try await store.cueMessages().filter { $0.author == .known(.cue) }
        #expect(rows.first { $0.text == "建卡的结果" }?.answeredRequests == [first])
        #expect(rows.first { $0.text == "改期的结果" }?.answeredRequests == [second])
        #expect(rows.first { $0.text == "两件一起回答" }?.answeredRequests == [first, second])
        #expect(fixture.trip(first) == .sending && fixture.trip(second) == .sending)
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
        let reading = try #require(fixture.workspace.voicePresentation?.readings.first { $0.id == reply.id })
        try await fixture.workspace.recoverVoice(try #require(reading.recovery))
        try await eventually("明确手动朗读不必等来源关联") { fixture.call.replies.first { $0.id == reply.id }?.delivery == .submitted }
        #expect(fixture.controls[0].sends.count == 1)
        try await store.associateCueReply(reply.id, answering: [foreign.id])
        let marker = try await store.addCueMessage(.cue, text: "合法主动更新", answeredRequests: [])
        try await eventually("已消费来源更新之后的记录") {
            fixture.call.replies.contains { $0.id == marker.id && $0.delivery == .submitted }
        }
        #expect(!fixture.call.replies.contains { $0.id == reply.id })
        await #expect(throws: VoiceIssue.originalMissing) {
            try await fixture.workspace.recoverVoice(.repeatReply(reply.id))
        }
        let later = try await store.addCueMessage(.cue, text: "后续主动更新", answeredRequests: [])
        try await eventually("后续发送仍畅通") { fixture.call.replies.contains { $0.id == later.id && $0.delivery == .submitted } }
        #expect(fixture.controls[0].sends.count == 3, "只有一次明确手动朗读与两条主动更新，已确认为其他入口的旧结果不能重说")
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
        let call = fixture.call
        try await fixture.hangUp()
        #expect(fixture.workspace.voice === call)
        #expect(fixture.workspace.voicePresentation?.active == false)
        #expect(fixture.workspace.voicePresentation?.needsAttention == false)
        try await finish(store, "挂断后到达的进展", requests: [request])
        try await eventually("挂断后仍能看结果") { fixture.call.replies.count == 2 }
        try await fixture.connect()
        try await eventually("只提交晚到的那条") { fixture.controls[1].sends.count == 1 }
        let first = try #require(fixture.call.replies.first?.id)
        let reading = try #require(fixture.workspace.voicePresentation?.readings.first { $0.id == first })
        #expect(fixture.call.replies.first { $0.id == first }?.delivery == .submitted)
        let recovery = try #require(reading.recovery)
        #expect(recovery == .repeatReply(first))
        try await fixture.workspace.recoverVoice(recovery)
        try await eventually("明确再说才再次提交") { fixture.controls[1].sends.count == 2 }
        #expect(try await store.cueMessages().filter { $0.author == .known(.you) }.count == 1)
        #expect(fixture.call.replies.count == 2)
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
        #expect(fixture.call.replies.last?.text == result)
        try await fixture.connect()
        let marker = try await store.addCueMessage(.cue, text: "重连后的主动更新", answeredRequests: [])
        try await eventually("新连接处理后续结果，不重投半条") {
            fixture.call.replies.contains { $0.id == marker.id && $0.delivery == .submitted }
        }
        #expect(fixture.controls[1].sends.count == 1)
        let first = try #require(fixture.call.replies.first?.id)
        let reading = try #require(fixture.workspace.voicePresentation?.readings.first { $0.id == first })
        try await fixture.workspace.recoverVoice(try #require(reading.recovery))
        try await eventually("完整回复重新提交") { fixture.call.replies.first?.delivery == .submitted }
        #expect(fixture.controls[1].sends.count == 2)
        #expect(fixture.controls[1].fragments.count > 2)
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
        #expect(fixture.workspace.voicePresentation?.issues.isEmpty == false)
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

    @Test(arguments: ["failed", "unconfirmed"])
    func 原请求失败或未确认后新请求已接走_恢复按原对象且不重复投送(kind: String) async throws {
        let originalText = "整理下周客户演示需要的发布清单，分别核对桌面端、手机端的已完成事项和仍待确认的限制，保留每项的原始依据，完成后先发给我审核，请先保留末尾这项约束"
        let clock = ManualTiming(), app = TestApp(timing: clock.timing)
        let store = app.services.store, host = TestApp.hostID
        try await store.updateCueProfile { $0.enabledAt = clock.now; $0.hostID = host }
        app.services.startSpeechClock()
        let fixture = VoiceFlowFixture(app.services)
        defer { fixture.call.hangUp(); app.services.cancelBackgroundWork() }
        try await fixture.connect()
        let db = RawDB(app.databaseURL)
        if kind == "failed" {
            try db.exec("CREATE TRIGGER voice_write_failure BEFORE INSERT ON cueMessages WHEN NEW.author = 'you' BEGIN SELECT RAISE(FAIL, 'voice test write failed'); END")
            fixture.received?(.success(.delegation(.init(id: "write-failed", turn: nil, text: originalText))))
            try await eventually("界面能看到未交出与原文") { fixture.workspace.voicePresentation?.issues.first?.recovery == .retryRequest("write-failed") }
            fixture.received?(.success(.delegation(.init(id: "other-failed", turn: nil, text: "另一件未落库的请求"))))
            try await eventually("多个失败各自保留恢复身份") {
                fixture.workspace.voicePresentation?.issues.map(\.recovery) == [.retryRequest("write-failed"), .retryRequest("other-failed")]
            }
            try db.exec("DROP TRIGGER voice_write_failure")
        } else {
            _ = try await fixture.handoff(originalText, id: "write-failed")
            clock.advance(.seconds(Speech.receiptLimit + 1))
            try await eventually("A 未确认") { fixture.trip()?.unconfirmedReason != nil }
        }
        #expect(fixture.call.requests.first?.text == originalText)
        let later = try await fixture.handoff("后来的请求已接走")
        try await store.markCueMessagesDelivered([later])
        try await eventually("B 已接走而恢复仍指向 A") {
            fixture.trip(later) == .delivered && (kind == "failed"
                ? fixture.workspace.voicePresentation?.issues.first?.recovery == .retryRequest("write-failed")
                : fixture.trip()?.unconfirmedReason != nil)
        }
        let recovery = fixture.workspace.voicePresentation?.issues.first?.recovery
        if kind == "failed" {
            let issue = try #require(fixture.workspace.voicePresentation?.issues.first)
            #expect(String(localized: issue.message).contains(originalText))
            #expect(String(localized: issue.message).contains("voice test write failed"))
            #expect(recovery == .retryRequest("write-failed"))
        } else {
            #expect(recovery == nil)
            let original = try #require(fixture.call.requests.first?.message)
            #expect(fixture.trip(original)?.unconfirmedReason?.contains("可能已经执行") == true)
        }
        try await fixture.hangUp()
        #expect(fixture.workspace.voicePresentation?.activity == .ended)
        #expect(fixture.workspace.voicePresentation?.active == false)
        try await fixture.connect()
        if kind == "failed" {
            let recovery = try #require(recovery)
            try await fixture.workspace.recoverVoice(recovery)
            try await eventually("重试后有真实记录") { fixture.call.requests.first?.record != nil }
            try await eventually("恢复 A 不移除另一件失败") {
                fixture.workspace.voicePresentation?.issues.map(\.recovery) == [.retryRequest("other-failed")]
            }
            clock.advance(.seconds(Speech.receiptLimit + 1))
            try await eventually("重试后的 A 等不到确认") { fixture.trip()?.unconfirmedReason != nil }
            await #expect(throws: SendError.alreadyHanded) { try await fixture.workspace.recoverVoice(recovery) }
            let original = try #require(fixture.call.requests.first?.message)
            try await store.markCueMessagesDelivered([original])
            try db.exec("CREATE TRIGGER voice_write_failure BEFORE INSERT ON cueMessages WHEN NEW.author = 'you' BEGIN SELECT RAISE(FAIL, 'later request failed'); END")
            fixture.received?(.success(.delegation(.init(id: "later-failed", turn: nil, text: "第三个请求"))))
            try await eventually("C 失败成为新的恢复对象") {
                fixture.workspace.voicePresentation?.issues.contains { $0.recovery == .retryRequest("later-failed") } == true
            }
            try db.exec("DROP TRIGGER voice_write_failure")
            await #expect(throws: SendError.alreadyHeard) { try await fixture.workspace.recoverVoice(recovery) }
            #expect(fixture.call.requests.last?.failure != nil)
        } else {
            await #expect(throws: SendError.alreadyHanded) { try await fixture.workspace.retryVoiceRequest("write-failed") }
            #expect(fixture.trip()?.unconfirmedReason != nil)
        }
        #expect(try await store.cueMessages().filter { $0.author == .known(.you) }.count == 2)
        #expect(try await store.cueMessages([later]).first?.deliveredAt != nil)
        #expect(fixture.call.requests.first { $0.message == later }?.text == "后来的请求已接走")
        try await fixture.hangUp()
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

    private func finish(_ store: CueStore, _ text: String, requests: [UUID]) async throws {
        _ = try await store.finishCueRound(nil, startedAt: .now, answersYou: true, tools: nil, reply: text, as: .cue,
                                           context: nil, answeredRequests: requests)
    }
}
#endif
