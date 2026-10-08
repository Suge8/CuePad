import CueStore
import Foundation
import Testing
@testable import CuePad

/// 会话回复框的草稿只有一份（`AppSettings`，iOS 与 Mac 同一份）：离开会话再回来还在；文字存在本机偏好、跨退出保留，
/// 带上的卡片与图片只留在这次运行；iOS"发到 Mac"带来的卡片写进同一份草稿；发出后清空。
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
        draft.attachments = [Outbox(content: "目标卡", card: UUID())]
        settings.setReplyDraft(draft, for: session)

        #expect(settings.replyDraft(for: session).text == "改完再跑一遍")
        #expect(settings.replyDraft(for: session).attachments.first?.content == "目标卡")

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
        #expect(self.settings(suite).replyDraft(for: session).text.isEmpty)
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
