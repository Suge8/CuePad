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

        weak var shown: CueTextView?
        var address = ""
        do {
            workspace.openLibrary(.instruction(.global))
            // 建窗、关窗都会把窗口放进当前的自动释放池；CI 上没有事件进来，事件循环那一层池子一直不排空，关上的窗口连带视图图、正文与库就一直活着
            //（CI 上 leaks --traceTree 查到的唯一强引用根是主线程的自动释放池）。各包一层当场排空，不靠外层的池子
            let window = autoreleasepool {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false  // 默认关窗时 AppKit 自己再释放一次，与 ARC 重复：测试进程随后在自动释放池里崩掉
                window.contentView = NSHostingView(rootView: LibraryFileLayer().environment(workspace).environment(services))
                window.makeKeyAndOrderFront(nil)
                return window
            }
            defer { autoreleasepool { window.close() } }
            try await eventually("文件页挂上、正文拿到键盘") { window.firstResponder is CueTextView }
            let editor = try #require(window.firstResponder as? CueTextView)
            shown = editor
            address = "\(Unmanaged.passUnretained(editor).toOpaque())"
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
        let deadline = ContinuousClock.now + .seconds(10)
        while shown != nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        if shown != nil { Issue.record(Comment(rawValue: "关窗 10 秒后正文仍没放掉，引用链：\n" + Self.referrers(of: address))) }
    }

    /// 取证：`leaks --traceTree` 列出谁攥着这个地址的对象；完整输出打到标准输出（CI 上传的 test.log 里），返回带类型名的强引用行。
    static func referrers(of address: String) -> String {
        let process = Process(), out = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/leaks")
        process.arguments = ["--traceTree=\(address)", "\(getpid())"]
        process.standardOutput = out
        process.standardError = out
        do { try process.run() } catch { return "leaks 起不来：\(error)" }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        print("LEAKS-TRACE BEGIN\n\(text)\nLEAKS-TRACE END")
        let lines = text.split(separator: "\n")
        let strong = lines.filter { $0.contains("__strong") || $0.contains("Region") || $0.contains("block_invoke") || $0.contains("Thread") }
        return (lines.prefix(12) + strong.prefix(80)).map { String($0.prefix(240)) }.joined(separator: "\n")
    }
}
#endif
