import CueStore
import Foundation
import Testing
@testable import CuePad

/// 会话回复框的草稿只有一份（`AppSettings`，iOS 与 Mac 同一份）：离开会话再回来还在；文字存在本机偏好、跨退出保留，
/// 带上的卡片与图片只留在这次运行；iOS"发到 Mac"带来的卡片写进同一份草稿；发出后清空。
/// 数每个键被写了几次的偏好套件。
nonisolated private final class CountingDefaults: UserDefaults, @unchecked Sendable {
    private(set) var writes: [String: Int] = [:]

    override func set(_ value: Any?, forKey key: String) {
        writes[key, default: 0] += 1
        super.set(value, forKey: key)
    }
}

@MainActor
struct ReplyDraftTests {
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

    @Test func 发出后清空_退出再回来也没有() {
        let suite = "drafts-\(UUID())", session = UUID()
        let settings = settings(suite)
        var draft = settings.replyDraft(for: session)
        draft.text = "发出去的话"
        settings.setReplyDraft(draft, for: session)

        settings.setReplyDraft(ComposerDraft(), for: session)

        #expect(settings.replyDraft(for: session).text.isEmpty)
        settings.flush()
        #expect(self.settings(suite).replyDraft(for: session).text.isEmpty)
    }

    /// 回复框每个键都改草稿：界面立即读到新字，偏好只在停手后写一次；退出前冲刷把还没写的立即写下（没有未写的草稿时什么也不做）。
    @Test func 连续输入只在停手后写一次偏好_冲刷立即写下() async {
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
        await eventually { defaults.writes["replyTexts"] != nil }
        try? await Task.sleep(for: .milliseconds(600))
        #expect(defaults.writes["replyTexts"] == 1)

        settings.setReplyDraft(ComposerDraft(text: "没写完"), for: session)
        settings.flush()
        settings.flush()
        #expect(defaults.writes["replyTexts"] == 2)
        #expect(AppSettings(defaults: defaults, launchArguments: [:]).replyDraft(for: session).text == "没写完")
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
