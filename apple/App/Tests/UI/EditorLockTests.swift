import CueEditor
import CueTestSupport
import SwiftUI
import Testing
@testable import CuePad

/// 编辑器被盖住时（技能与规则文件页标出合并，`MergeBar`）：交出键盘、打字不改正文、读屏跳过；不盖了再拿回键盘、接着打。
/// 在真窗口里挂文件页用的那个编辑器宿主（`EditorHost`、`IOSEditorHost`），打字照键盘那样送给拿着键盘的那一个。
@MainActor
struct EditorLockTests {
    @Observable
    final class Lock {
        var editable = true
    }

    #if os(macOS)
    @Test func 标出合并时打字不改正文_退出后键盘回到正文() async throws {
        let app = TestApp()
        let lock = Lock(), handle = EditorHandle()
        var changes: [String] = []
        let host = NSHostingView(rootView: Probe(lock: lock, handle: handle) { changes.append($0) }.environment(app.services))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await eventually("编辑器挂上、拿到键盘") {
            handle.focus()
            return window.firstResponder is CueTextView
        }
        let textView = try #require(window.firstResponder as? CueTextView)
        func type(_ text: String) { _ = window.firstResponder?.tryToPerform(#selector(NSResponder.insertText(_:)), with: text) }

        lock.editable = false
        try await eventually("交出键盘") { !(window.firstResponder is NSTextView) }
        type("x")
        #expect(handle.text == "正文\n" && changes.isEmpty, "盖着时打字不改正文")
        #expect(!textView.isAccessibilityElement() && !textView.isEditable, "读屏跳过、不接输入")

        lock.editable = true
        try await eventually("键盘回到正文") { window.firstResponder === textView }
        type("y")
        #expect(changes.last?.contains("y") == true)
    }
    #else
    @Test func 标出合并时收起键盘_不接输入_退出后键盘回到正文() async throws {
        let app = TestApp()
        let lock = Lock(), handle = IOSEditorHandle()
        var changes: [String] = []
        let scene = try #require(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: Probe(lock: lock, handle: handle) { changes.append($0) }.environment(app.services))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await eventually("编辑器挂上") { handle.text == "正文\n" }
        handle.focus()
        let textView = try #require(window.subviews(of: CueTextView.self).first)
        try await eventually("拿到键盘") { textView.isFirstResponder }

        lock.editable = false
        try await eventually("收起键盘") { !textView.isFirstResponder }
        #expect(!textView.isEditable && !textView.isAccessibilityElement, "不接输入、读屏跳过")
        #expect(handle.text == "正文\n" && changes.isEmpty)

        lock.editable = true
        try await eventually("键盘回到正文") { textView.isFirstResponder }
        textView.insertText("y")
        #expect(changes.last?.contains("y") == true)
    }
    #endif

    private struct Probe: View {
        let lock: Lock
        #if os(macOS)
        let handle: EditorHandle
        #else
        let handle: IOSEditorHandle
        #endif
        let onChange: (String) -> Void
        @Environment(\.palette) private var palette

        var body: some View {
            #if os(macOS)
            EditorHost(initialText: "正文\n", theme: .editor(palette, horizontalInset: 20), handle: handle, onChange: onChange, editable: lock.editable)
            #else
            IOSEditorHost(initialText: "正文\n", theme: .editor(palette, horizontalInset: 20), handle: handle, onChange: onChange, editable: lock.editable)
            #endif
        }
    }
}

#if os(iOS)
private extension UIView {
    func subviews<T: UIView>(of type: T.Type) -> [T] { subviews.flatMap { ($0 as? T).map { [$0] } ?? $0.subviews(of: type) } }
}
#endif
