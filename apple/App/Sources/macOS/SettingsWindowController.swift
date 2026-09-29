#if os(macOS)
import AppKit
import SwiftUI

/// 标准设置窗口（⌘, 与菜单"设置…"）：有标题栏、可关闭、尺寸随内容，关闭只是隐藏，再次打开复用同一个窗口。
/// 内容视图在第一次打开时才创建。
@MainActor
final class SettingsWindowController {
    private let makeContent: () -> AnyView
    private let settings: AppSettings
    private var window: NSWindow?
    private var frameKeeper: WindowFrameKeeper?

    init(settings: AppSettings, content: @escaping () -> some View) {
        self.settings = settings
        makeContent = { AnyView(content()) }
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.show()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "设置"
        window.contentViewController = NSHostingController(rootView: makeContent())
        window.isReleasedWhenClosed = false
        let keeper = WindowFrameKeeper(window: window, name: "settings", settings: settings)
        if !keeper.restore() { window.center() }
        frameKeeper = keeper
        return window
    }
}
#endif
