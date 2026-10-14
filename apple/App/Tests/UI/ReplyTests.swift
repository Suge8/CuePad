import CueStore
import Foundation
import Testing
@testable import CuePad

/// 会话回复框：草稿只有一份（`AppSettings`，iOS 与 Mac 同一份）：离开会话再回来还在；文字与批注存在本机偏好、跨退出保留，
/// 带上的卡片与图片只留在这次运行；批注随下一句发出；iOS"发到 Mac"带来的卡片写进同一份草稿；排队的话在回复框上方一叠、没被 Mac 领取前可撤回。
/// 数每个键被写了几次的偏好套件。
nonisolated private final class CountingDefaults: UserDefaults, @unchecked Sendable {
    private(set) var writes: [String: Int] = [:]

    override func set(_ value: Any?, forKey key: String) {
        writes[key, default: 0] += 1
        super.set(value, forKey: key)
    }
}

struct ReplyTests {
    private func settings(_ suite: String) -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: suite)!, launchArguments: [:])
    }

    @Test func 离开再回来草稿还在_文字跨退出保留_卡片只留在这次运行() {
        let suite = "drafts-\(UUID())", session = UUID()
        let settings = settings(suite)
        var draft = settings.replyDraft(for: session)
        draft.text = "改完再跑一遍"
        draft.attachments = [Outbox(content: "接口约定", card: UUID())]
        settings.setReplyDraft(draft, for: session)

        #expect(settings.replyDraft(for: session).text == "改完再跑一遍")
        #expect(settings.replyDraft(for: session).attachments.first?.content == "接口约定")

        settings.flush()  // 退出前
        let relaunched = self.settings(suite)
        #expect(relaunched.replyDraft(for: session).text == "改完再跑一遍")
        #expect(relaunched.replyDraft(for: session).attachments.isEmpty)
    }

    /// 回复框每个键都改草稿：界面立即读到新字，偏好只在停手后写一次；退出前冲刷把还没写的立即写下（没有未写的草稿时什么也不做）。
    @Test func 连续输入只在停手后写一次偏好_冲刷立即写下() async throws {
        let defaults = CountingDefaults(suiteName: "drafts-\(UUID())")!
        let settings = AppSettings(defaults: defaults, launchArguments: [:])
        let session = UUID()
        for count in 1...200 {
            var draft = settings.replyDraft(for: session)
            draft.text = String(repeating: "字", count: count)
            settings.setReplyDraft(draft, for: session)
        }

        #expect(settings.replyDraft(for: session).text.count == 200)
        #expect(defaults.writes["replyTexts"] == nil)
        try await eventually("defaults.writes[\"replyTexts\"] != nil") { defaults.writes["replyTexts"] != nil }
        await quietPeriod(.milliseconds(600))
        #expect(defaults.writes["replyTexts"] == 1)

        settings.setReplyDraft(ComposerDraft(text: "没写完"), for: session)
        settings.flush()
        settings.flush()
        #expect(defaults.writes["replyTexts"] == 2)
        #expect(AppSettings(defaults: defaults, launchArguments: [:]).replyDraft(for: session).text == "没写完")
    }

    /// 批注随下一句发出，排在你写的话前面：原文已在 Agent 的上下文里，只带认得出位置的摘录（列表符、换行收掉，过长只留头尾），
    /// 不重发原文。
    @Test func 批注跨退出保留_随下一句发出时只带头尾摘录() async throws {
        let suite = "notes-\(UUID())"
        let app = TestApp()
        try await PiStateRecorder(store: app.services.store, hostID: "mac").update(sessionID: "s", state: .tool, title: "s")
        let session = try #require(try await app.services.store.piSessionPage(.live).items.first?.state)
        let settings = settings(suite)
        var draft = settings.replyDraft(for: session.id)
        draft.text = "按这个改"
        draft.notes = [
            ReplyNote(entry: UUID(), run: 0, location: 2, quote: "• 绑定时不碰草稿，既不提示，也不丢弃。\n• 补上后，绑定时“删草稿、塞进回复框”这条特殊路径可以整段删掉", note: "同意，先做这条"),
            ReplyNote(entry: UUID(), run: 1, location: 0, quote: "会话 ↔ 任务改成多对一", note: "这条先不做"),
        ]
        settings.setReplyDraft(draft, for: session.id)
        settings.flush()

        let request = try await app.services.requestMacDelivery(self.settings(suite).replyDraft(for: session.id), to: session, mode: .send)

        #expect(request.content == """
            对你回答的批注（「」里是原话摘录）：
            1.「绑定时不碰草稿，既不提示…这条特殊路径可以整段删掉」同意，先做这条
            2.「会话 ↔ 任务改成多对一」这条先不做

            按这个改
            """)
    }

    private func message(_ seq: Int64, _ text: String, delivery: UUID?) -> PiChatMessage {
        PiChatMessage(sessionID: "s", entryID: "e\(seq)", seq: seq, role: .user, text: text, at: Date(timeIntervalSince1970: 1_000_000 + Double(seq)), deliveryID: delivery)
    }

    /// 在跑时"等它做完再说"发出、还没进对话的话在回复框上方一叠，不再同时是对话末尾的气泡；
    /// 没能送达的仍是气泡（在对话里重发或移除），进了对话的两处都没有。
    @Test func 排队的话只在回复框上方_不再是末尾的气泡() async throws {
        let app = TestApp()
        try await PiStateRecorder(store: app.services.store, hostID: "mac").update(sessionID: "s", state: .tool, title: "s")
        let live = try #require(try await app.services.store.piSessionPage(.live).items.first?.state)
        let queued = try await app.services.requestMacDelivery("改完再看看超时", to: live, mode: .followUp)
        let arrived = try await app.services.requestMacDelivery("顺便跑一遍", to: live, mode: .followUp)
        let now = try await app.services.requestMacDelivery("先停下这个", to: live, mode: .steer)
        let messages = [message(1, "顺便跑一遍", delivery: arrived.id)]

        #expect(PiChat.queued([queued, arrived, now], messages: messages).map(\.id) == [queued.id])
        #expect(PiChat.outgoing([queued, arrived, now], messages: messages).map(\.id) == [now.id])
    }

    /// 撤回与改为马上说只对还没被 Mac 领取的（Pi 扩展收不回已交给 Pi 的话）。
    @Test func 还没被Mac领取的可撤回或改为马上说_领取后不行() async throws {
        let app = TestApp()
        let store = app.services.store
        try await PiStateRecorder(store: store, hostID: "mac").update(sessionID: "s", state: .tool, title: "s")
        let live = try #require(try await store.piSessionPage(.live).items.first?.state)
        let first = try await app.services.requestMacDelivery("改完再看看超时", to: live, mode: .followUp)
        let second = try await app.services.requestMacDelivery("顺便跑一遍", to: live, mode: .followUp)
        #expect(first.isWithdrawable && second.isWithdrawable)

        #expect(try await store.promoteDelivery(first.id))
        #expect(try await store.deliveryRequest(first.id)?.mode == .known(.steer))
        #expect(try await store.withdrawDelivery(second.id))
        #expect(try await store.deliveryRequest(second.id) == nil)

        let executor = DeliveryExecutor(store: store, hostID: "mac", onIssue: { _ in }) { _ in .succeeded }
        let third = try await app.services.requestMacDelivery("再加一句", to: live, mode: .followUp)
        try await executor.start()
        for try await current in store.observe({ try $0.deliveryRequest(third.id) }) where current?.isOpen == false { break }
        await executor.stop()
        let handed = try #require(try await store.deliveryRequest(third.id))
        #expect(!handed.isWithdrawable)
        #expect(try await !store.withdrawDelivery(third.id))
        #expect(try await !store.promoteDelivery(third.id))
        #expect(try await store.deliveryRequest(third.id)?.mode == .known(.followUp))
    }

    #if os(iOS)
    @Test func 发到Mac带来的卡片写进同一份草稿_已经写的字还在() {
        let session = UUID()
        let settings = settings("drafts-\(UUID())")
        var draft = settings.replyDraft(for: session)
        draft.text = "补一句"
        settings.setReplyDraft(draft, for: session)

        Navigation(settings: settings).openSession(session, draft: Outbox(content: "接口约定", card: UUID()), store: TestApp().services.store)

        #expect(settings.replyDraft(for: session).text == "补一句")
        #expect(settings.replyDraft(for: session).attachments.first?.content == "接口约定")
    }
    #endif
}
