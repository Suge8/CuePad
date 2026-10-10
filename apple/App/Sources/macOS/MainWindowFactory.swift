#if os(macOS)
import AppKit
import SwiftUI

private typealias WindowClass = DebugHooks.MainWindowClass

/// 主窗口的外框在创建时定好：内容铺到透明标题栏下（侧栏可以通顶），标题隐藏，界面不再在运行时改窗口样式。
@MainActor
enum MainWindowFactory {
    static func make<Content: View>(content: Content) -> NSWindow {
        let window = WindowClass(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "CuePad"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(NSSize(width: 1200, height: 760)) // 须在设置 contentViewController 之后，否则被内容尺寸覆盖
        window.isReleasedWhenClosed = false
        return window
    }
}
#endif
