#if os(macOS)
import AppKit

/// 菜单栏图标与菜单。图标是模板图，随菜单栏明暗自动着色。
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let toggle: @MainActor () -> Void

    init(toggle: @escaping @MainActor () -> Void) {
        self.toggle = toggle
        super.init()
        guard let image = NSImage(named: "MenuBarIcon") else { preconditionFailure("缺少 MenuBarIcon 资源") }
        image.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "CuePad"

        let menu = NSMenu()
        let toggleItem = menu.addItem(withTitle: "显示 / 隐藏", action: #selector(toggleWindow), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 CuePad", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
    }

    func remove() {
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func toggleWindow() {
        toggle()
    }
}
#endif
