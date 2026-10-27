#if os(iOS)
import CueEditor
import CueStore
import CueTestSupport
import SwiftUI
import Testing
@testable import CuePad

extension AgentLibraryPhoneTests {
    /// 手机上全局规则的文件页（真窗口里挂着 `LibraryFileScreen`）：Claude Code 另写了一份，点"合并进来"标出会并进来的段时
    /// （`FileDraft.previewing`，按钮做的就是这一下），键盘收起、正文点不进去、读屏跳过，攒着的改动一个字没多；"取消"回到正文，键盘回来，接着打的字攒进去。
    @Test func 标出合并时键盘收起_点不进正文_取消后键盘回来接着改() async throws {
        let claude = "/Users/a/.claude/CLAUDE.md"
        let shared = "共用的\n", own = "全局规则\n"
        let merge = LibraryTidy(id: "global-instructions", kind: .globalInstructions([
            InstructionSource(origin: .shared, path: Self.rulesPath, hash: LibraryEdit.base(of: shared), modifiedAt: nil),
            InstructionSource(origin: .agent(.claudeCode), path: claude, hash: LibraryEdit.base(of: own), modifiedAt: nil),
        ]))
        let library = AgentLibrary(
            hostID: "mac-a", home: "/Users/a", skills: [],
            instructions: [LibraryInstruction(kind: .global, path: Self.rulesPath, hash: LibraryEdit.base(of: shared), modifiedAt: .now, readers: [.pi])],
            tidies: [merge], modifiedAt: .now)
        try await store.recordAgentLibrary(library, texts: [Self.rulesPath: shared, claude: own])
        let workspace = Workspace(services: app.services)
        let following = Task { await workspace.follow() }
        defer { following.cancel() }
        try await eventually("读到要合并的全局规则") { workspace.library?.merge(into: .global) != nil }

        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(
            rootView: NavigationStack { LibraryFileScreen(file: .instruction(.global)) }.environment(workspace).environment(app.services))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await eventually("文件页挂上") { workspace.fileDrafts[FileDraftKey(host: "mac-a", file: .instruction(.global))] != nil }
        let draft = try #require(workspace.fileDrafts[FileDraftKey(host: "mac-a", file: .instruction(.global))])
        let editor = try #require(window.subviews(of: CueTextView.self).first)
        #expect(editor.becomeFirstResponder())

        draft.previewing = true
        try await eventually("标出时键盘收起") { !editor.isFirstResponder }
        #expect(!editor.isEditable && !editor.isAccessibilityElement, "不接输入、读屏跳过")
        #expect(!editor.isUserInteractionEnabled, "点不进正文")
        #expect(draft.body == shared && !draft.dirty)

        draft.previewing = false
        try await eventually("取消后键盘回来") { editor.isFirstResponder }
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        editor.insertText("我加的")
        #expect(draft.body == shared + "我加的" && draft.dirty)
    }
}

private extension UIView {
    func subviews<T: UIView>(of type: T.Type) -> [T] { subviews.flatMap { ($0 as? T).map { [$0] } ?? $0.subviews(of: type) } }
}
#endif
