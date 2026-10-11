#if os(macOS)
import AppKit

/// 菜单栏图标。图标是模板图，随菜单栏明暗自动着色。
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
        guard let image = NSImage(named: "MenuBarIcon") else { preconditionFailure("缺少 MenuBarIcon 资源") }
        image.isTemplate = true
        guard let button = item.button else { preconditionFailure("菜单栏图标没有按钮") }
        button.image = image
        button.toolTip = "CuePad"
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
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
        let toggle = menu.addItem(withTitle: "显示 / 隐藏", action: #selector(toggleMainWindow), keyEquivalent: "")
        toggle.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 CuePad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func toggleMainWindow() {
        toggleWindow()
    }
}
#endif
