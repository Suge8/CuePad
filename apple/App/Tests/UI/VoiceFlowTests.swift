#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

@MainActor
@Suite(.releasesLibraries)
struct VoiceFlowTests {
    func setup() async throws -> (TestApp, VoiceFlowFixture) {
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
        try await eventually("合批结果进入界面") { fixture.voiceRecord.replies.count == 1 }
        #expect(fixture.trip(first) != .delivered && fixture.trip(second) != .delivered)
        try await store.markCueMessagesDelivered([first])
        try await eventually("A 的真实回执到达") { fixture.stored()?.deliveredAt != nil }
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
        try await eventually("三条结果进入界面") { fixture.voiceRecord.replies.count == 3 && fixture.controls[0].sends.count == 3 }
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
        try await eventually("来源未知先可见但不自动播报") { fixture.voiceRecord.replies.contains { $0.id == reply.id } }
        #expect(fixture.controls[0].sends.isEmpty)
        try await eventually("详情里可以再说") { try fixture.details().readings.first { $0.id == reply.id }?.recovery == .repeatReply(reply.id) }
        try await fixture.workspace.performVoice(.repeatReply(reply.id))
        try await eventually("明确手动朗读不必等来源关联") { fixture.voiceRecord.replies.first { $0.id == reply.id }?.delivery == .submitted }
        #expect(fixture.controls[0].sends.count == 1)
        try await store.associateCueReply(reply.id, answering: [foreign.id])
        let marker = try await store.addCueMessage(.cue, text: "合法主动更新", answeredRequests: [])
        try await eventually("已消费来源更新之后的记录") {
            fixture.voiceRecord.replies.contains { $0.id == marker.id && $0.delivery == .submitted }
        }
        #expect(!fixture.voiceRecord.replies.contains { $0.id == reply.id })
        #expect(try await fixture.workspace.performVoice(.repeatReply(reply.id)) == .rejected(reason: .originalMissing))
        let later = try await store.addCueMessage(.cue, text: "后续主动更新", answeredRequests: [])
        try await eventually("后续发送仍畅通") { fixture.voiceRecord.replies.contains { $0.id == later.id && $0.delivery == .submitted } }
        #expect(fixture.controls[0].sends.count == 3, "只有一次明确手动朗读与两条主动更新，已确认为其他入口的旧结果不能重说")
        try await fixture.hangUp()
    }

    @Test func 挂断保留晚到结果_新的一通从空记录开始_再说不重新派活_静音等设备确认() async throws {
        let (app, fixture) = try await setup(), store = app.services.store
        defer { fixture.call.hangUp(); app.services.cancelBackgroundWork() }
        try await fixture.connect()
        fixture.call.setMuted(true)
        try await eventually("设备与界面都已静音") { fixture.media.muted && fixture.call.isMuted }
        let request = try await fixture.handoff("记一件事")
        try await finish(store, "已记下", requests: [request])
        try await eventually("第一条提交给语音") { fixture.controls[0].sends.count == 1 }
        let first = try #require(fixture.voiceRecord.replies.first?.id)
        try await eventually("已提交的可以再说") { try fixture.details().readings.first { $0.id == first }?.recovery == .repeatReply(first) }
        try await fixture.workspace.performVoice(.repeatReply(first))
        try await eventually("明确再说才再次提交") { fixture.controls[0].sends.count == 2 }
        let call = fixture.call
        try await fixture.hangUp()
        #expect(fixture.workspace.voice === call)
        try await eventually("界面已挂断且没有要处理的") { try !fixture.details().active && !fixture.details().needsAttention }
        try await finish(store, "挂断后到达的进展", requests: [request])
        try await eventually("挂断后仍能看结果") { fixture.voiceRecord.replies.count == 2 }
        #expect(try await fixture.workspace.performVoice(.repeatReply(first)) == .rejected(reason: .originalMissing), "挂断后不能再说")
        try await fixture.connect()
        #expect(fixture.workspace.voice !== call)
        #expect(fixture.voiceRecord.replies.isEmpty && fixture.voiceRecord.requests.isEmpty, "新的一通不带上一通的记录")
        let marker = try await store.addCueMessage(.cue, text: "新一通里的主动更新", answeredRequests: [])
        try await eventually("新一通只提交它开始之后的结果") { fixture.controls[1].sends.count == 1 && fixture.voiceRecord.replies.map(\.id) == [marker.id] }
        #expect(try await store.cueMessages().filter { $0.author == .known(.you) }.count == 1)
        try await fixture.hangUp()
    }

    @Test func 部分发送失败保留文字_重连不重复半条() async throws {
        let (app, fixture) = try await setup(), store = app.services.store
        defer { fixture.call.hangUp(); app.services.cancelBackgroundWork() }
        try await fixture.connect()
        fixture.controls[0].failedAfterFirstFragment = true
        let request = try await fixture.handoff("给我长结果")
        let result = String(repeating: "这是实际结果。", count: 200)
        try await finish(store, result, requests: [request])
        try await eventually("半途失败已收尾") { !fixture.call.isLive }
        #expect(fixture.controls[0].fragments.count == 1)
        #expect(fixture.voiceRecord.replies.last?.text == result)
        try await fixture.connect()
        let marker = try await store.addCueMessage(.cue, text: "重连后的主动更新", answeredRequests: [])
        try await eventually("新连接处理后续结果，不重投半条") {
            fixture.voiceRecord.replies.contains { $0.id == marker.id && $0.delivery == .submitted }
        }
        #expect(fixture.controls[1].sends.count == 1)
        #expect(try await store.cueMessages().filter { $0.author == .known(.you) }.count == 1)
        try await fixture.hangUp()
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
            try await eventually("界面能看到未交出与原文") { try fixture.details().issues.first?.recovery == fixture.recovery(of: "write-failed") }
            fixture.received?(.success(.delegation(.init(id: "other-failed", turn: nil, text: "另一件未落库的请求"))))
            try await eventually("多个失败各自保留恢复身份") {
                try fixture.details().issues.map(\.recovery) == [fixture.recovery(of: "write-failed"), fixture.recovery(of: "other-failed")]
            }
            try db.exec("DROP TRIGGER voice_write_failure")
        } else {
            _ = try await fixture.handoff(originalText, id: "write-failed")
            clock.advance(.seconds(Speech.receiptLimit + 1))
            try await eventually("A 未确认") { fixture.trip()?.unconfirmedReason != nil }
        }
        #expect(fixture.voiceRecord.requests.first?.text == originalText)
        let later = try await fixture.handoff("后来的请求已接走")
        try await store.markCueMessagesDelivered([later])
        try await eventually("B 已接走而恢复仍指向 A") {
            try fixture.trip(later) == .delivered && (kind == "failed"
                ? fixture.details().issues.first?.recovery == fixture.recovery(of: "write-failed")
                : fixture.trip()?.unconfirmedReason != nil)
        }
        let recovery = try fixture.details().issues.first?.recovery
        if kind == "failed" {
            let issue = try #require(try fixture.details().issues.first)
            #expect(String(localized: issue.message).contains(originalText))
            #expect(recovery == fixture.recovery(of: "write-failed"))
        } else {
            #expect(recovery == nil)
            let original = try #require(fixture.voiceRecord.requests.first?.message)
            #expect(fixture.trip(original)?.unconfirmedReason?.contains("可能已经执行") == true)
        }
        let originalMessage = fixture.voiceRecord.requests.first?.message
        try await fixture.hangUp()
        try await eventually("界面已挂断") { try fixture.details().activity == .ended }
        if kind == "failed" {
            let recovery = try #require(recovery)
            #expect(try await fixture.workspace.performVoice(recovery) == .recorded(message: try #require(fixture.voiceRecord.requests.first?.message)))
            try await eventually("重试后有真实记录") { fixture.stored() != nil }
            try await eventually("恢复 A 不移除另一件失败") {
                try fixture.details().issues.map(\.recovery) == [fixture.recovery(of: "other-failed")]
            }
            clock.advance(.seconds(Speech.receiptLimit + 1))
            try await eventually("重试后的 A 等不到确认") { fixture.trip()?.unconfirmedReason != nil }
            let original = try #require(fixture.voiceRecord.requests.first?.message)
            #expect(try await fixture.workspace.performVoice(recovery) == .rejected(reason: .originalMissing), "旧按钮指的未落库那行已不在")
            #expect(try await fixture.workspace.performVoice(.recover(.recorded(message: original))) == .rejected(reason: .unconfirmed))
            try await store.markCueMessagesDelivered([original])
            try await fixture.connect()
            #expect(try fixture.details().issues.isEmpty, "新的一通不带上一通没交出的请求")
            #expect(try await fixture.workspace.performVoice(recovery) == .rejected(reason: .originalMissing))
            try db.exec("CREATE TRIGGER voice_write_failure BEFORE INSERT ON cueMessages WHEN NEW.author = 'you' BEGIN SELECT RAISE(FAIL, 'later request failed'); END")
            fixture.received?(.success(.delegation(.init(id: "later-failed", turn: nil, text: "第三个请求"))))
            try await eventually("C 失败成为新的恢复对象") {
                try fixture.details().issues.contains { $0.recovery == fixture.recovery(of: "later-failed") }
            }
            try db.exec("DROP TRIGGER voice_write_failure")
            #expect(try await fixture.workspace.performVoice(.recover(.recorded(message: original))) == .rejected(reason: .alreadyHandled))
            #expect(fixture.voiceRecord.requests.last?.failure != nil)
        } else {
            try await fixture.connect()
            let original = try #require(originalMessage)
            #expect(try await fixture.workspace.performVoice(.recover(.recorded(message: original))) == .rejected(reason: .unconfirmed))
        }
        #expect(try await store.cueMessages().filter { $0.author == .known(.you) }.count == 2)
        let stored = try #require(try await store.cueMessages([later]).first)
        #expect(stored.text == "后来的请求已接走" && stored.deliveredAt != nil)
        try await fixture.hangUp()
    }

    @Test func 同一命令重发回原结果_关闭中不接再说_接走后不能恢复() async throws {
        let app = TestApp(), store = app.services.store, host = TestApp.hostID
        defer { app.services.cancelBackgroundWork() }
        try await store.updateCueProfile { $0.enabledAt = .now; $0.hostID = host }
        let fixture = VoiceFlowFixture(app.services)
        try await fixture.connect()
        let original = try await store.addCueMessage(.you, text: "original audit request")
        let result = try await store.addCueMessage(.cue, text: "saved result", answeredRequests: nil)
        try await eventually("saved result visible") { fixture.voiceRecord.replies.contains { $0.id == result.id } }
        let command = UUID()
        let recovered = try await app.services.voice.command(.recover(request: .recorded(message: original.id)), id: command)
        #expect(recovered == .recorded(message: original.id))
        let gate = AsyncStream<Void>.makeStream()
        fixture.media.closeGate = gate.stream
        fixture.call.hangUp()
        try await eventually("closing") { fixture.call.phase == .closing }
        let outcome = try await app.services.voice.command(.repeatReply(message: result.id))
        if case .readbackQueued = outcome { Issue.record("Closing media must not accept readback") }
        let duringClose = try await app.services.voice.command(.recover(request: .recorded(message: original.id)), id: command)
        #expect(duringClose == recovered)
        gate.continuation.finish()
        try await eventually("closed") { !fixture.call.isLive }
        try await store.markCueMessagesDelivered([original.id])
        #expect(try await app.services.voice.command(.recover(request: .recorded(message: original.id))) == .rejected(reason: .alreadyHandled))
        #expect(try await store.cueMessages().filter { $0.author == .known(.you) }.map(\.id) == [original.id])
        #expect(fixture.controls[0].sends.isEmpty)
    }

    func finish(_ store: CueStore, _ text: String, requests: [UUID]) async throws {
        _ = try await store.finishCueRound(nil, startedAt: .now, answersYou: true, tools: nil, reply: text, as: .cue,
                                           context: nil, answeredRequests: requests)
    }
}
#endif
