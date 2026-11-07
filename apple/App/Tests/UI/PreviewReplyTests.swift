import CueStore
import Foundation
import Testing
@testable import CuePad

/// 回复预览：长按缩略图或全屏里点"回复"（`Workspace.quote`），会话的回复框带上"预览「标题」"一行并聚焦，话在回复框里写，
/// 同对回答的批注一起随下一句发出；同一份不重复引用，删掉那一行就不带。
struct PreviewReplyTests {
    @Test func 引用的预览随下一句发出_同批注一起_同一份不重复() async throws {
        let app = TestApp()
        let store = app.services.store
        try await PiStateRecorder(store: store, hostID: "mac").update(sessionID: "s", state: .settled, title: "s")
        let session = try #require(try await store.piSessionPage(.live).items.first?.state)
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

        draft.notes.insert(ReplyNote(entry: UUID(), run: 0, location: 0, quote: "改动都在 login/ 下", note: "好"), at: 0)
        draft.text = "按这个改"
        let request = try await workspace.said(draft, to: session, mode: .send)
        #expect(request.content == """
            对你回答的批注（「」里是原话摘录）：
            「改动都在 login/ 下」好

            预览「改动：错误提示」和预览「评审结论」：按这个改
            """)

        // 删掉那一行就不带；只引用、不写话也能发
        app.services.settings.setReplyDraft(ComposerDraft(), for: session.id)
        workspace.quote(previews[1], in: batch, of: session)
        let only = app.services.settings.replyDraft(for: session.id)
        #expect(!only.isEmpty(accepting: .reply) && only.stored == "预览「评审结论」")
        app.services.settings.removeReplyNote(only.notes[0].id, in: session.id)
        #expect(app.services.settings.replyDraft(for: session.id).isEmpty(accepting: .reply))
    }
}

/// 改动预览（.diff/.patch，`UnifiedDiff`）：段里删去的一行以 "--" 开头、接着加的一行以 "++" 开头，带上前缀成了一对 ---/+++，仍是这一段的改动，
/// 不另起一个文件；段走完后的那对（不带 `diff --git` 的多文件 `diff -u`）才是下一个文件。
struct PreviewDiffTests {
    @Test func 段里以减减加加开头的行仍是改动_段外的那对才是下一个文件() {
        let diff = UnifiedDiff("""
            diff --git a/notes.md b/notes.md
            index 1111111..2222222 100644
            --- a/notes.md
            +++ b/notes.md
            @@ -1,3 +1,3 @@ 标题
             第一行
            --- 旧的分隔线
            +++ 新的强调
             最后一行
            --- a/two.txt
            +++ b/two.txt
            @@ -1 +1 @@
            -a
            +b

            """)
        let files = diff.lines.compactMap { line -> String? in if case .file = line.kind { line.text } else { nil } }
        #expect(files == ["notes.md", "two.txt"])
        let changed = diff.lines.filter { if case .added = $0.kind { true } else if case .removed = $0.kind { true } else { false } }
        #expect(changed.map(\.text) == ["-- 旧的分隔线", "++ 新的强调", "a", "b"])
        #expect(changed.map(\.old) == [2, nil, 1, nil] && changed.map(\.new) == [nil, 2, nil, 1])
        if case .file(let added, let removed) = diff.lines[0].kind { #expect(added == 1 && removed == 1) } else { Issue.record("第一行不是文件抬头") }
    }
}
