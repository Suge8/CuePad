#if os(macOS)
import AppKit

/// 菜单栏图标（`Icon.menuBar`，同 logo 的墨块符号）。图标是模板图，随菜单栏明暗自动着色，形一直不变；
/// 有要你管的（拍板加待回复，`CueNow.needsYou`，同 Dock 角标与名牌）时图标右边写几件，没有不写（`show(badge:)`，`AppDelegate` 接的）。
/// 左键弹出面板；右键（或 Control 点击）弹出菜单。
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let togglePanel: @MainActor (CGRect) -> Void
    private let toggleWindow: @MainActor () -> Void

    /// `togglePanel` 收到图标在屏幕坐标里的位置。
    init(togglePanel: @escaping @MainActor (CGRect) -> Void, toggleWindow: @escaping @MainActor () -> Void) {
        self.togglePanel = togglePanel
        self.toggleWindow = toggleWindow
        super.init()
        // 20pt 的符号实高约 16pt（同系统菜单栏图标），在 22pt 高的菜单栏里上下各留一点；模板图随菜单栏明暗着色
        guard let image = Icon.menuBar.platformImage?.withSymbolConfiguration(.init(pointSize: 20, weight: .regular)) else {
            preconditionFailure("缺少菜单栏符号 cue.menubar")
        }
        image.isTemplate = true
        guard let button = item.button else { preconditionFailure("菜单栏图标没有按钮") }
        button.image = image
        button.toolTip = "CuePad"
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// 菜单栏的字随菜单栏明暗着色，不另上色：数字跟在图标右边、与图标同一条中线。
    func show(badge count: Int) {
        guard let button = item.button else { return }
        button.imagePosition = count > 0 ? .imageLeading : .imageOnly
        button.attributedTitle = count > 0
            ? NSAttributedString(string: "\(count)", attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)])
            : NSAttributedString()
        button.setAccessibilityValue(count > 0 ? String(localized: "\(count) 件要你管") : nil)
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func clicked() {
        guard let button = item.button, let window = button.window else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePanel(window.frame)
        }
    }

    /// 菜单只在右键时临时挂上，否则左键也会弹菜单而不是面板。
    private func showMenu() {
        let menu = NSMenu()
        let toggle = menu.addItem(withTitle: String(localized: "显示 / 隐藏"), action: #selector(toggleMainWindow), keyEquivalent: "")
        toggle.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "退出 CuePad"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func toggleMainWindow() {
        toggleWindow()
    }
}
#endif
