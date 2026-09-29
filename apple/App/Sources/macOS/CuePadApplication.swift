#if os(macOS)
import AppKit

/// 应用对象。主窗口挂着弹窗（sheet、警告框）或有应用级模态面板时，系统的 `terminate(_:)` 会一直等下去、
/// 不会走到 `applicationShouldTerminate`。所以退出前先结束这些弹窗，⌘Q、Dock 退出、SIGTERM 共用这一条路径。
@objc(CuePadApplication)
final class CuePadApplication: NSApplication {
    override func terminate(_ sender: Any?) {
        Self.dismissPresentations(in: windows)
        if modalWindow != nil { abortModal() }
        super.terminate(sender)
    }

    /// 结束挂在这些窗口上的弹窗，嵌套的先结束。
    static func dismissPresentations(in windows: [NSWindow]) {
        for window in windows {
            guard let sheet = window.attachedSheet else { continue }
            dismissPresentations(in: [sheet])
            window.endSheet(sheet)
        }
    }
}
#endif
