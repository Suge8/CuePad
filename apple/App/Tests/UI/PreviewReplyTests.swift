import CueStore
import Foundation
import Testing
@testable import CuePad

@Suite(.releasesLibraries)
struct PreviewReplyTests {
    @Test func 引用的预览随下一句发出_同批注一起_同一份不重复() async throws {
        let app = TestApp()
        let store = app.services.store
        try await StateRecorder(store: store, hostID: "mac").update(sessionID: "s", state: .settled, title: "s")
        let session = try #require(try await store.sessionPage(.live).items.first?.state)
        let folder = FileManager.default.temporaryDirectory.appending(path: "preview-reply-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = ["login.diff", "review.md"].map { folder.appending(path: $0) }
        for file in files { try Data(file.lastPathComponent.utf8).write(to: file) }
        let previews = try await store.addPreviews(zip(files, ["改动：错误提示", "评审结论"]).map { (url: $0, title: $1) }, sessionID: "s").map(\.preview)
        let workspace = Workspace(services: app.services), batch = UUID()

        workspace.quote(previews[0], in: batch, of: session)
        workspace.quote(previews[1], in: batch, of: session)
        workspace.quote(previews[0], in: batch, of: session)
        #expect(workspace.replyFocus == session.id)
        var draft = app.services.settings.replyDraft(for: session.id)
        #expect(draft.notes.map(\.quote) == ["改动：错误提示", "评审结论"] && draft.notes.allSatisfy { $0.entry == batch })
        let digest = try await SessionDigest.read(session.id, sessionID: session.sessionID, from: store)
        #expect(draft.notes.map { $0.quoted(in: digest.previews)?.key } == previews.map(\.key))

        draft.notes.insert(ReplyNote(entry: UUID(), run: 0, location: 0, quote: "改动都在 login/ 下", note: "好"), at: 0)
        draft.text = "按这个改"
        let request = try await workspace.said(draft, to: session, mode: .send)
        #expect(request.content == """
            对你回答的批注（「」里是原话摘录）：
            「改动都在 login/ 下」好

            预览「改动：错误提示」和预览「评审结论」：按这个改
            """)

        try await store.pruneMessages(olderThan: 0, now: .now.addingTimeInterval(60))
        let expired = try await SessionDigest.read(session.id, sessionID: session.sessionID, from: store)
        #expect(expired.previews.isEmpty && draft.notes.allSatisfy { $0.quoted(in: expired.previews) == nil })
        #expect(draft.notes.compactMap(\.kind) == [.diff, .markdown])
        #expect(try await workspace.said(draft, to: session, mode: .send).content.hasSuffix("预览「改动：错误提示」和预览「评审结论」：按这个改"))

        app.services.settings.setReplyDraft(ComposerDraft(), for: session.id)
        workspace.quote(previews[1], in: batch, of: session)
        let only = app.services.settings.replyDraft(for: session.id)
        #expect(!only.isEmpty(accepting: .reply) && only.stored == "预览「评审结论」")
        app.services.settings.removeReplyNote(only.notes[0].id, in: session.id)
        #expect(app.services.settings.replyDraft(for: session.id).isEmpty(accepting: .reply))

        let settings = app.services.settings
        settings.annotate(previews[0], "按钮再大一点", in: batch, for: session.id)
        settings.annotate(previews[1], " 第二处听你的 ", in: batch, for: session.id)
        settings.annotate(previews[0], "按钮改成通栏", in: batch, for: session.id)
        var noted = settings.replyDraft(for: session.id)
        noted.text = "改完发我"
        #expect(try await workspace.said(noted, to: session, mode: .send).content == """
            预览「改动：错误提示」：按钮改成通栏
            预览「评审结论」：第二处听你的

            改完发我
            """)
        settings.annotate(previews[0], "", in: batch, for: session.id)
        #expect(settings.replyDraft(for: session.id).notes.map(\.quote) == ["评审结论"])
    }
}
