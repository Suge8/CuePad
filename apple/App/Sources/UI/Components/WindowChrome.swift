#if os(macOS)
import AppKit
import SwiftUI

/// 让内容铺到标题栏下：侧栏玻璃通顶，工具栏浮在桌面色上。窗口由壳层创建，外框样式属于界面，所以在这里补上。
struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ view: NSView, context: Context) {}

    private final class ChromeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
    }
}
#endif
