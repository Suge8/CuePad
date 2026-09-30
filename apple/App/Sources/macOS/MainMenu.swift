#if os(macOS)
import AppKit

/// 无 nib 的标准主菜单：⌘Q 退出、⌘W 关闭（即隐藏）、编辑快捷键。
@MainActor
enum MainMenu {
    static func install() {
        let main = build()
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.items.last?.submenu
    }

    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(title: "CuePad", items: [
            .item("关于 CuePad", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .item("检查更新…", #selector(AppDelegate.checkForUpdates(_:)), ""),
            .separator,
            .item("设置…", #selector(AppDelegate.showSettings(_:)), ","),
            .separator,
            .item("隐藏 CuePad", #selector(NSApplication.hide(_:)), "h"),
            .separator,
            .item("退出 CuePad", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu(title: "编辑", items: [
            .item("撤销", Selector(("undo:")), "z"),
            .item("重做", Selector(("redo:")), "Z"),
            .separator,
            .item("剪切", #selector(NSText.cut(_:)), "x"),
            .item("拷贝", #selector(NSText.copy(_:)), "c"),
            .item("粘贴", #selector(NSText.paste(_:)), "v"),
            .item("全选", #selector(NSText.selectAll(_:)), "a"),
        ]))
        let window = submenu(title: "窗口", items: [
            .item("关闭", #selector(NSWindow.performClose(_:)), "w"),
            .item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        main.addItem(window)
        return main
    }

    private enum Entry {
        case item(String, Selector, String)
        case separator
    }

    private static func submenu(title: String, items: [Entry]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        for entry in items {
            switch entry {
            case let .item(title, action, key): menu.addItem(withTitle: title, action: action, keyEquivalent: key)
            case .separator: menu.addItem(.separator())
            }
        }
        let holder = NSMenuItem()
        holder.title = title
        holder.submenu = menu
        return holder
    }
}
#endif
