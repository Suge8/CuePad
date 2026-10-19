#if os(macOS)
import AppKit
import SwiftUI

/// 设置窗口（⌘, 与菜单"设置…"）：工具栏上一排标签切换几页（`SettingsPane`），窗口跟着这一页的内容变高变矮；标题不显示，标签就是标题。
/// 关闭只是隐藏，再次打开复用同一个窗口、停在上次那一页；窗口与内容在第一次打开时才建。
final class SettingsWindowController {
    private let makePane: (SettingsPane) -> NSViewController
    private let settings: AppSettings
    private var tabs: NSTabViewController?
    private var frameKeeper: WindowFrameKeeper?

    init(settings: AppSettings, content: @escaping (SettingsPane) -> some View) {
        self.settings = settings
        makePane = { pane in
            let host = NSHostingController(rootView: content(pane))
            host.sizingOptions = .preferredContentSize
            return host
        }
    }

    /// `pane` 为 nil 时停在上次那一页。
    func show(_ pane: SettingsPane? = nil) {
        let tabs = tabs ?? firstTabs()
        if let pane { tabs.selectedTabViewItemIndex = pane.rawValue }
        if let window = tabs.view.window { DebugHooks.present(window) }
    }

    private func firstTabs() -> NSTabViewController {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for pane in SettingsPane.allCases {
            let item = NSTabViewItem(viewController: makePane(pane))
            item.label = pane.title
            item.image = pane.icon.platformImage
            tabs.addTabViewItem(item)
        }
        let window = WindowFactory.settings(tabs)
        frameKeeper = WindowFrameKeeper(window: window, name: "settings", settings: settings)
        self.tabs = tabs
        return tabs
    }
}
#endif
