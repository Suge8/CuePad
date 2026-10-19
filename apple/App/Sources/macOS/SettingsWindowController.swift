#if os(macOS)
import AppKit
import SwiftUI

/// 设置窗口（⌘, 与菜单"设置…"）：工具栏上一排标签切换几页（`SettingsPane`），窗口跟着这一页的内容变高变矮；标题不显示，标签就是标题，
/// Cue 那一页的标签随它的名字改。
/// 关闭只是隐藏，再次打开复用同一个窗口、停在上次那一页；窗口与内容在第一次打开时才建，在屏幕中间。
/// 不记窗口位置与大小（`WindowFrameKeeper`）：高度随页变，记下的是另一页的高度，摆回去再改一次就是一次多余的缩放动画。
final class SettingsWindowController {
    private let makePane: (SettingsPane) -> NSViewController
    private let cueName: @MainActor @Sendable () -> String
    private var built: (window: NSWindow, tabs: NSTabViewController)?
    private var naming: Task<Void, Never>?

    init(cueName: @escaping @MainActor @Sendable () -> String, content: @escaping (SettingsPane) -> some View) {
        self.cueName = cueName
        makePane = { pane in
            let host = NSHostingController(rootView: content(pane))
            host.sizingOptions = .preferredContentSize
            return host
        }
    }

    /// `pane` 为 nil 时停在上次那一页。
    func show(_ pane: SettingsPane? = nil) {
        let (window, tabs) = built ?? build(showing: pane ?? .cue)
        if let pane { tabs.selectedTabViewItemIndex = Self.index(pane) }
        DebugHooks.present(window)
    }

    private static func index(_ pane: SettingsPane) -> Int { SettingsPane.allCases.firstIndex(of: pane)! }

    /// 第一次打开：先选好要看的那一页再建窗口（窗口按它的高度建，不从第一页动画过去）。
    private func build(showing pane: SettingsPane) -> (window: NSWindow, tabs: NSTabViewController) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for each in SettingsPane.allCases {
            let item = NSTabViewItem(viewController: makePane(each))
            item.label = each.title(cue: cueName())
            item.image = each.icon.platformImage
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = Self.index(pane)
        let cueItem = tabs.tabViewItems[Self.index(.cue)]
        naming = Task { [cueName] in
            for await name in Observations(cueName) { cueItem.label = SettingsPane.cue.title(cue: name) }
        }
        let window = WindowFactory.settings(tabs)
        window.center()
        built = (window, tabs)
        return (window, tabs)
    }
}
#endif
