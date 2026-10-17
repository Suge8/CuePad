#if os(macOS)
import AppKit
import SwiftUI

/// 设置窗口（⌘, 与菜单"设置…"）：关闭只是隐藏，再次打开复用同一个窗口；窗口与内容在第一次打开时才建。
final class SettingsWindowController {
    private let makeWindow: () -> NSWindow
    private let settings: AppSettings
    private var window: NSWindow?
    private var frameKeeper: WindowFrameKeeper?

    init(settings: AppSettings, content: @escaping () -> some View) {
        self.settings = settings
        makeWindow = { WindowFactory.utility(title: "设置", content: content()) }
    }

    func show() {
        DebugHooks.present(window ?? firstWindow())
    }

    private func firstWindow() -> NSWindow {
        let window = makeWindow()
        frameKeeper = WindowFrameKeeper(window: window, name: "settings", settings: settings)
        self.window = window
        return window
    }
}
#endif
