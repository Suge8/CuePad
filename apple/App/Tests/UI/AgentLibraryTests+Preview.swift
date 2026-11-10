#if os(macOS)
import AppKit
import CueEditor
import CueStore
import CueTestSupport
import SwiftUI
import Testing
@testable import CuePad

extension AgentLibraryTests {
    @Test
    func 标出合并时打字不改正文_取消后键盘回到正文接着存() async throws {
        let shared = rules
        try write("共用的\n", shared)
        try write("全局规则\n", claude.appending(path: "CLAUDE.md"))
        let keeping = keep()
        defer { await keeping.stop() }
        let workspace = Workspace(services: services)
        let following = Task { await workspace.follow() }
        defer { await following.stop() }
        try await eventually("快照里有要合并的全局规则") { workspace.library?.merge(into: .global) != nil }

        workspace.openLibrary(.instruction(.global))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false  // 默认关窗时 AppKit 自己再释放一次，与 ARC 重复：测试进程随后在自动释放池里崩掉
        window.contentView = NSHostingView(rootView: LibraryFileLayer().environment(workspace).environment(services))
        // 本机关窗后约半秒放掉，GitHub 的 macOS runner 上关窗后再等 15 秒（其间转默认模式的主 run loop，perform 块照常执行）也不放：
        // 运行 42881986575、42884155676、42886191288 的 leaks --traceTree 里，正文的强引用根依次是主线程的自动释放池（关上的窗口）、
        // NSRunLoop 待执行的 perform 块攥着的 AppKit 视图观察闭包（`-[NSView _commonAwake]`）、窗口与视图图之间的引用，每次不同，都在 AppKit 与 SwiftUI 里
        LibraryLedger.heldByFramework(services.store, "文件页挂进真窗口：CI 的 runner 上关窗后 AppKit 与 SwiftUI 仍攥着正文，连带环境里的服务与库", intermittent: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await eventually("文件页挂上、正文拿到键盘") { window.firstResponder is CueTextView }
        let editor = try #require(window.firstResponder as? CueTextView)
        let draft = try #require(workspace.fileDrafts[FileDraftKey(host: TestApp.hostID, file: .instruction(.global))])
        func type(_ text: String) { _ = window.firstResponder?.tryToPerform(#selector(NSResponder.insertText(_:)), with: text) }

        draft.previewing = true
        try await eventually("标出时正文交出键盘") { !(window.firstResponder is NSTextView) }
        #expect(!editor.isEditable && !editor.isAccessibilityElement(), "不接输入、读屏跳过")
        type("x")
        await draft.leave()
        #expect(editor.string == "共用的\n" && read(shared) == "共用的\n", "标出时打的字不进正文、不写进文件")

        draft.previewing = false
        try await eventually("取消后键盘回到正文") { window.firstResponder === editor }
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        type("我加的")
        await draft.leave()
        #expect(read(shared) == "共用的\n我加的")
    }
}
#endif
