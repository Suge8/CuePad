#if os(macOS)
import AppKit
import SwiftUI

/// 设置窗口（⌘, 与菜单"设置…"）：工具栏上一排标签切换几页（`SettingsPane`），窗口跟着这一页的内容变高变矮；标题不显示，标签就是标题。
/// 关闭只是隐藏，再次打开复用同一个窗口、停在上次那一页；窗口与内容在第一次打开时才建，在屏幕中间。
/// 不记窗口位置与大小（`WindowFrameKeeper`）：高度随页变，记下的是另一页的高度，摆回去再改一次就是一次多余的缩放动画。
final class SettingsWindowController {
    private let makePane: (SettingsPane) -> NSViewController
    private var built: (window: NSWindow, tabs: NSTabViewController)?

    init(content: @escaping (SettingsPane) -> some View) {
        makePane = { pane in
            let host = NSHostingController(rootView: content(pane))
            host.sizingOptions = .preferredContentSize
            return host
        }
    }

    /// `pane` 为 nil 时停在上次那一页。
    func show(_ pane: SettingsPane? = nil) {
        let (window, tabs) = built ?? build(showing: pane ?? .general)
        if let pane { tabs.selectedTabViewItemIndex = Self.index(pane) }
        DebugHooks.present(window)
        // 窗口第一次排出来时 AppKit 把焦点交给键盘顺序里第一个能接的（通用页最上面 Cue 的名字），名字整段选中、一打字就盖掉；
        // 同系统各应用的设置窗口，打开时谁都不拿焦点，点哪个输入框才进编辑
        window.makeFirstResponder(nil)
    }

    private static func index(_ pane: SettingsPane) -> Int { SettingsPane.allCases.firstIndex(of: pane)! }

    /// 第一次打开：先选好要看的那一页再建窗口（窗口按它的高度建，不从第一页动画过去）。
    private func build(showing pane: SettingsPane) -> (window: NSWindow, tabs: NSTabViewController) {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        for each in SettingsPane.allCases {
            let item = NSTabViewItem(viewController: makePane(each))
            item.label = each.title
            item.image = each.icon.platformImage
            tabs.addTabViewItem(item)
        }
        tabs.selectedTabViewItemIndex = Self.index(pane)
        let window = WindowFactory.settings(tabs)
        // 这一页的高度要等窗口装上工具栏、排过一遍才算准（顶上让出工具栏）；不先按它定好，窗口从默认大小动画长到这一页的高度，
        // 途中内容高过窗口、滚动条闪出来
        window.contentView?.layoutSubtreeIfNeeded()
        window.setContentSize(tabs.tabViewItems[Self.index(pane)].viewController!.preferredContentSize)
        window.center()
        built = (window, tabs)
        return (window, tabs)
    }
}
#endif
