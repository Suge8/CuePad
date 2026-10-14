#if os(macOS)
import AppKit
import SwiftUI

/// CuePad 的窗口外框都在这里创建时定好，界面不再在运行时改窗口样式：内容铺到透明标题栏下，
/// 页面的底色一直连到窗口上沿（侧栏通顶；设置等窗口不留一条系统色的标题栏和分隔线）。
enum WindowFactory {
    /// 主窗口：可缩放，标题隐藏（顶上是界面自己的工具栏）。
    static func main(content: some View) -> NSWindow {
        let window = dress(DebugHooks.MainWindowClass(
            contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false), content: content)
        window.title = "CuePad"
        window.titleVisibility = .hidden
        window.contentMinSize = NSSize(width: 720, height: 520)
        window.setContentSize(NSSize(width: 1200, height: 760)) // 须在设置 contentViewController 之后，否则被内容尺寸覆盖
        return window
    }

    /// 设置、资料库读不出这类辅助窗口：有标题、可关闭，尺寸由内容定。内容自己让开标题栏（安全区），滚进去的只在栏下沿淡出（`fadesUnderBars`）。
    static func utility(title: String, content: some View) -> NSWindow {
        let window = dress(NSWindow(
            contentRect: .zero, styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false), content: content)
        window.title = title
        return window
    }

    private static func dress(_ window: NSWindow, content: some View) -> NSWindow {
        window.titlebarAppearsTransparent = true
        window.contentViewController = NSHostingController(rootView: content)
        window.isReleasedWhenClosed = false
        return window
    }
}
#endif
