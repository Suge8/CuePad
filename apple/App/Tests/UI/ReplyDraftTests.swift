#if os(iOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// 会话回复框的草稿只有一份（Navigation）：离开会话再回来还在；文字存在本机偏好、跨退出保留，带上的卡片与图片只留在这次运行；
/// "发到 Mac"带来的卡片写进同一份草稿；发出后清空。
@MainActor
struct ReplyDraftTests {
    private func settings(_ suite: String) -> AppSettings {
        AppSettings(defaults: UserDefaults(suiteName: suite)!, launchArguments: [:])
    }

    @Test func 离开再回来草稿还在_文字跨退出保留_卡片只留在这次运行() {
        let suite = "drafts-\(UUID())", session = UUID()
        let navigation = Navigation(settings: settings(suite))
        var draft = navigation.replyDraft(for: session)
        draft.text = "改完再跑一遍"
        draft.attachment = Navigation.Outbox(content: "目标卡", card: UUID())
        navigation.setReplyDraft(draft, for: session)

        #expect(navigation.replyDraft(for: session).text == "改完再跑一遍")
        #expect(navigation.replyDraft(for: session).attachment?.content == "目标卡")

        let relaunched = Navigation(settings: settings(suite))
        #expect(relaunched.replyDraft(for: session).text == "改完再跑一遍")
        #expect(relaunched.replyDraft(for: session).attachment == nil)
    }

    @Test func 发到Mac带来的卡片写进同一份草稿_已经写的字还在() {
        let session = UUID()
        let navigation = Navigation(settings: settings("drafts-\(UUID())"))
        var draft = navigation.replyDraft(for: session)
        draft.text = "补一句"
        navigation.setReplyDraft(draft, for: session)

        navigation.openSession(session, draft: Navigation.Outbox(content: "接口约定", card: UUID()))

        #expect(navigation.replyDraft(for: session).text == "补一句")
        #expect(navigation.replyDraft(for: session).attachment?.content == "接口约定")
    }

    @Test func 发出后清空_退出再回来也没有() {
        let suite = "drafts-\(UUID())", session = UUID()
        let navigation = Navigation(settings: settings(suite))
        var draft = navigation.replyDraft(for: session)
        draft.text = "发出去的话"
        navigation.setReplyDraft(draft, for: session)

        navigation.setReplyDraft(ComposerDraft(), for: session)

        #expect(navigation.replyDraft(for: session).text.isEmpty)
        #expect(Navigation(settings: settings(suite)).replyDraft(for: session).text.isEmpty)
    }
}
#endif
