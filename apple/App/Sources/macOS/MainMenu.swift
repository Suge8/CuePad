#if os(macOS)
import AppKit

/// 无 nib 的标准主菜单：⌘Q 退出、⌘W 关闭（即隐藏）、新建（"文件"：⌘N 记一条灵感、⌥⌘N 新会话）、编辑快捷键、搜索、任务面板与侧栏的开关（"显示"），
/// 以及会话回复框的快捷键（"回复"，`ReplyShortcut`）。⌘N 已是记一条灵感，新会话用 ⌥⌘N（Mac 上"另一种新建"的惯例）。
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
            // 更新等后台会话做完再装时才出现：一行写等几个（停用的说明），一行现在就装（`AppDelegate.validateMenuItem`）
            .item("", #selector(AppDelegate.installUpdateNow(_:)), "", tag: AppDelegate.updateNoteTag),
            .item("现在就装", #selector(AppDelegate.installUpdateNow(_:)), ""),
            .separator,
            .item("设置…", #selector(AppDelegate.showSettings(_:)), ","),
            .separator,
            .item("隐藏 CuePad", #selector(NSApplication.hide(_:)), "h"),
            .separator,
            .item("退出 CuePad", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu(title: "文件", items: [
            .item("记一条灵感", #selector(AppDelegate.newCard(_:)), "n"),
            .item("新会话…", #selector(AppDelegate.newSession(_:)), "n", [.option, .command]),
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
        main.addItem(submenu(title: "显示", items: [
            .item("搜索", #selector(AppDelegate.toggleSearch(_:)), "k"),
            .item("任务", #selector(AppDelegate.toggleTasks(_:)), "T"),
            // macOS 标准的显示/隐藏侧栏；不用 ⌘\：常见的 1Password 把它占作全局快捷键，按键到不了 App
            .item("侧栏", #selector(AppDelegate.toggleCueSidebar(_:)), "s", [.control, .command]),
        ]))
        main.addItem(replyMenu())
        let window = submenu(title: "窗口", items: [
            .item("关闭", #selector(NSWindow.performClose(_:)), "w"),
            .item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        main.addItem(window)
        return main
    }

    /// 会话回复框的快捷键：动作经响应链交给回复框的文字区（`GrowingTextView.performReplyShortcut`），回复框没聚焦时停用。
    private static func replyMenu() -> NSMenuItem {
        let menu = NSMenu(title: "回复")
        for key in ReplyShortcut.menu {
            let item = menu.addItem(withTitle: key.title, action: #selector(GrowingTextView.performReplyShortcut(_:)), keyEquivalent: key.input)
            item.keyEquivalentModifierMask = key.shift ? [.command, .shift] : .command
            item.tag = key.rawValue
        }
        let holder = NSMenuItem()
        holder.title = menu.title
        holder.submenu = menu
        return holder
    }

    private enum Entry {
        case item(String, Selector, String, NSEvent.ModifierFlags = .command, tag: Int = 0)
        case separator
    }

    private static func submenu(title: String, items: [Entry]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        for entry in items {
            switch entry {
            case let .item(title, action, key, modifiers, tag):
                let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key)
                item.keyEquivalentModifierMask = modifiers
                item.tag = tag
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
