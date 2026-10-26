#if os(macOS)
import AppKit
import SwiftUI

/// CuePad 的窗口外框都在这里创建时定好，界面不再在运行时改窗口样式：内容铺到透明标题栏下，
/// 页面的底色一直连到窗口上沿（侧栏通顶；设置等窗口不留一条系统色的标题栏和分隔线）。
enum WindowFactory {
    /// 主窗口：可缩放，标题隐藏（顶上是界面自己的工具栏）。`place` 在挂上内容之前摆好位置与大小（记下的、居中或屏幕外）：
    /// 整窗的 SwiftUI 布局是冷启动的大头，挂上内容后再改大小就按新大小从头再排一遍。
    /// 窗口大小只由人定（`contentMinSize` 是下限），托管控制器不按内容改它（`sizingOptions` 为空），也就不在每次更新时算整窗的理想大小。
    static func main(content: some View, place: (NSWindow) -> Void) -> MainShellWindow {
        let window = DebugHooks.MainWindowClass(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 1200, height: 760)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "CuePad"
        window.delegate = window
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: 720, height: 520)
        place(window)
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        // 挂上内容控制器时窗口改成它的视图的大小
        controller.view.frame.size = window.contentRect(forFrameRect: window.frame).size
        return dress(window, controller: controller)
    }

    /// 资料库读不出这类辅助窗口：有标题、可关闭，尺寸由内容定。内容自己让开标题栏（安全区）。
    static func utility(title: String, content: some View) -> NSWindow {
        let window = dress(NSWindow(
            contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false),
            controller: NSHostingController(rootView: content))
        window.title = title
        return window
    }

    /// 设置窗口：系统设置窗口的工具栏标签（`tabs` 的样式是 toolbar），标题"设置"只给读屏与"窗口"菜单、不显示（选中的标签就是这一页的名字），尺寸随选中那一页。
    static func settings(_ tabs: NSTabViewController) -> NSWindow {
        tabs.canPropagateSelectedChildViewControllerTitle = false
        let window = dress(NSWindow(
            contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false), controller: tabs)
        window.title = String(localized: "设置")
        window.toolbarStyle = .preference
        window.titleVisibility = .hidden
        return window
    }

    private static func dress<Window: NSWindow>(_ window: Window, controller: NSViewController) -> Window {
        window.titlebarAppearsTransparent = true
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        return window
    }
}
#endif
