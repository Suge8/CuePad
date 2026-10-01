#if os(macOS)
import AppKit
import SwiftUI

/// 主窗口的外框在创建时定好：内容铺到透明标题栏下（侧栏可以通顶），标题隐藏，界面不再在运行时改窗口样式。
@MainActor
enum MainWindowFactory {
    static func make<Content: View>(content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "CuePad"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: 720, height: 520)
        let host = NSHostingController(rootView: content)
        // 窗口尺寸由这里和窗口位置记忆决定，不跟随 SwiftUI 内容：默认的尺寸联动会在侧栏开合等布局变化的每一帧
        // 重算整棵视图的最小/理想/最大尺寸并改窗口约束
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 1200, height: 760)) // 须在设置 contentViewController 之后，否则被内容尺寸覆盖
        window.isReleasedWhenClosed = false
        return window
    }
}
#endif
