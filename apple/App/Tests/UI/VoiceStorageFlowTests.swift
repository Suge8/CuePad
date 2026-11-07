#if os(macOS)
import CueStore
@testable import CueSync
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

@MainActor
struct VoiceStorageFlowTests {
    @Test func 跨设备保存与发出都不冒充Cue已接走() async throws {
        let cloud = ReceiptTests.WeakCloud()
        await cloud.setDown(true)
        let app = TestApp(sync: .built { CloudSync(store: $0) { cloud } })
        let services = app.services!, store = services.store
        try await store.updateCueProfile { $0.hostID = "mac-cue"; $0.enabledAt = .now }
        services.startSync()
        services.startSpeechClock()
        let voice = VoiceFlowFixture(services)
        defer { voice.call.hangUp(); services.cancelBackgroundWork() }
        try await voice.connect()
        let request = try await voice.handoff("离线先保存，接通后交给另一台 Mac")
        #expect(voice.workspace.voicePresentation?.replies.first?.request?.delivery == .sending)
        await cloud.setDown(false)
        await services.syncNow()
        try await eventually("服务器收下，但 Cue 尚未领取") {
            await cloud.holds(request) && voice.workspace.voicePresentation?.replies.first?.request?.delivery == .sent
        }
        #expect(voice.call.requests.first?.record?.deliveredAt == nil)
        try await store.markCueMessagesDelivered([request])
        try await eventually("接走回执才显示送达") { voice.workspace.voicePresentation?.replies.first?.request?.delivery == .delivered }
        try await voice.hangUp()
    }

    @Test(arguments: [90, 91])
    func 正式已发布库升级后_晚到回复关联仍送到通话(version: Int) async throws {
        let app = TestApp(), oldStore = app.services.store, host = TestApp.hostID
        try await oldStore.updateCueProfile { $0.hostID = host; $0.enabledAt = .now }
        let db = RawDB(app.databaseURL)
        let previous = try await oldStore.addCueMessage(.you, text: "升级前的问题")
        try db.restoreVersion90()
        // 91 只清理派生摘要；这里没有缓存，表结构与 90 相同。
        try db.exec("PRAGMA user_version = \(version)")
        let services = app.relaunch(), store = services.store
        #expect(try await store.cueMessages([previous.id]).first?.text == "升级前的问题")
        let voice = VoiceFlowFixture(services)
        defer { voice.call.hangUp(); services.cancelBackgroundWork() }
        try await voice.connect()
        let request = try await voice.handoff("升级后询问进展")
        let reply = try await store.addCueMessage(.cue, text: "真实结果先到，来源随后到", answeredRequests: nil)
        try await eventually("先显示没有来源的真实结果") { voice.call.replies.contains { $0.id == reply.id } }
        #expect(voice.controls[0].sends.isEmpty)
        let cursor = try await store.cueMessagePage(after: 0).through
        try await store.associateCueReply(reply.id, answering: [request])
        let updates = try await store.cueMessagePage(after: cursor).entries
        try #require(updates.contains { $0.message.id == reply.id }, "升级后晚到关联必须通知正在看通话的消费者")
        try await eventually("来源补齐后交给语音一次") { voice.controls[0].sends.count == 1 }
        #expect(voice.call.replies.first?.message.answeredRequests == [request])
        #expect(voice.workspace.voicePresentation?.replies.last?.text == "真实结果先到，来源随后到")
        try await voice.hangUp()
    }
}
#endif
