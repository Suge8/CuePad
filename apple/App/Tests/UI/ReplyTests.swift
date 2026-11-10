import CueStore
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct ReplyTests {
    /// 偏好放在临时目录（`TempDefaults`）：按名字开的套件落进本机的 ~/Library/Preferences，每跑一次留一个文件。
    private func settings(_ preferences: TempDefaults) -> AppSettings {
        AppSettings(defaults: preferences.reopened(), launchArguments: [:])
    }

    @Test func 离开再回来草稿还在_文字跨退出保留_卡片只留在这次运行() {
        let preferences = TempDefaults(), session = UUID()
        let settings = settings(preferences)
        var draft = settings.replyDraft(for: session)
        draft.text = "改完再跑一遍"
        draft.attachments = [Outbox(content: "接口约定", card: UUID())]
        settings.setReplyDraft(draft, for: session)

        #expect(settings.replyDraft(for: session).text == "改完再跑一遍")
        #expect(settings.replyDraft(for: session).attachments.first?.content == "接口约定")

        settings.flush()  // 退出前
        let relaunched = self.settings(preferences)
        #expect(relaunched.replyDraft(for: session).text == "改完再跑一遍")
        #expect(relaunched.replyDraft(for: session).attachments.isEmpty)
    }

    @Test func 批注跨退出保留_随下一句发出时只带头尾摘录() async throws {
        let preferences = TempDefaults()
        let app = TestApp()
        try await PiStateRecorder(store: app.services.store, hostID: "mac").update(sessionID: "s", state: .tool, title: "s")
        let session = try #require(try await app.services.store.piSessionPage(.live).items.first?.state)
        let settings = settings(preferences)
        var draft = settings.replyDraft(for: session.id)
        draft.text = "按这个改"
        draft.notes = [
            ReplyNote(entry: UUID(), run: 0, location: 2, quote: "• 绑定时不碰草稿，既不提示，也不丢弃。\n• 补上后，绑定时“删草稿、塞进回复框”这条特殊路径可以整段删掉", note: "同意，先做这条"),
            ReplyNote(entry: UUID(), run: 1, location: 0, quote: "会话 ↔ 任务改成多对一", note: "这条先不做"),
        ]
        settings.setReplyDraft(draft, for: session.id)
        settings.flush()

        let request = try await Workspace(services: app.services).said(self.settings(preferences).replyDraft(for: session.id), to: session, mode: .send)

        #expect(request.content == """
            对你回答的批注（「」里是原话摘录）：
            1.「绑定时不碰草稿，既不提示…这条特殊路径可以整段删掉」同意，先做这条
            2.「会话 ↔ 任务改成多对一」这条先不做

            按这个改
            """)
    }

    @Test func 回复框收附件_作答框只有文字() {
        let image = "![](cuepad://file/\(String(repeating: "a", count: 64)).png)"
        let draft = ComposerDraft(text: "按这张改", attachments: [Outbox(content: "登录页\n\n\(image)\n\n按钮改圆角", card: UUID())])

        #expect(draft.accepting(.reply).stored.contains(image))

        let answer = draft.accepting([]).stored
        #expect(!answer.contains("cuepad://file"))
        #expect(answer.contains("按钮改圆角") && answer.contains("按这张改"))
    }
}
