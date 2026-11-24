#if os(macOS)
import AppKit
import WebKit

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
            .item("添加灵感", #selector(AppDelegate.newCard(_:)), "n"),
            .item("新会话…", #selector(AppDelegate.newSession(_:)), "n", [.option, .command]),
            .separator,
            .item("和 Cue 通话", #selector(AppDelegate.toggleVoiceCall(_:)), ""),
        ]))
        main.addItem(submenu(title: "编辑", items: [
            .item("撤销", Selector(("undo:")), "z"),
            .item("重做", Selector(("redo:")), "Z"),
            .separator,
            .item("剪切", #selector(NSText.cut(_:)), "x"),
            .item("拷贝", #selector(NSText.copy(_:)), "c"),
            .item("粘贴", #selector(NSText.paste(_:)), "v"),
            .item("全选", #selector(NSText.selectAll(_:)), "a"),
            .separator,
            // 系统的查找条（全屏页里的 PDF，`PDFFindHost`）：动作经响应链找接得住的，tag 是 `NSTextFinder.Action`
            .item("查找…", #selector(NSResponder.performTextFinderAction(_:)), "f", tag: NSTextFinder.Action.showFindInterface.rawValue),
            .item("查找下一个", #selector(NSResponder.performTextFinderAction(_:)), "g", tag: NSTextFinder.Action.nextMatch.rawValue),
            .item("查找上一个", #selector(NSResponder.performTextFinderAction(_:)), "G", tag: NSTextFinder.Action.previousMatch.rawValue),
        ]))
        main.addItem(submenu(title: "显示", items: [
            .item("搜索", #selector(AppDelegate.toggleSearch(_:)), "k"),
            .item("进展", #selector(AppDelegate.showProgress(_:)), "T"),
            // macOS 标准的显示/隐藏侧栏；不用 ⌘\：常见的 1Password 把它占作全局快捷键，按键到不了 App
            .item("侧栏", #selector(AppDelegate.toggleCueSidebar(_:)), "s", [.control, .command]),
            .item("右栏", #selector(AppDelegate.toggleCueColumn(_:)), "i", [.control, .command]),
            .item("切换栏焦点", #selector(MainShellWindow.switchWideFocus(_:)), "\t", [.control]),
            .item("会话移到左边", #selector(WideColumnView.moveWideLeft(_:)), "\u{F702}", [.command, .option]),
            .item("会话移到右边", #selector(WideColumnView.moveWideRight(_:)), "\u{F703}", [.command, .option]),
            .separator,
            // 活预览里的网页（同 Safari 的键）：经响应链交给有焦点的网页视图，它按能不能退、进自己停用；触控板双指左右滑也是这两下
            .item("后退", #selector(WKWebView.goBack(_:)), "["),
            .item("前进", #selector(WKWebView.goForward(_:)), "]"),
        ]))
        main.addItem(replyMenu())
        let window = submenu(title: "窗口", items: [
            .item("关闭", #selector(NSWindow.performClose(_:)), "w"),
            .item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ])
        main.addItem(window)
        return main
    }

    private static func replyMenu() -> NSMenuItem {
        let menu = NSMenu(title: String(localized: "回复"))
        for key in ReplyShortcut.allCases {
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
        case item(LocalizedStringResource, Selector, String, NSEvent.ModifierFlags = .command, tag: Int = 0)
        case separator
    }

    private static func submenu(title: LocalizedStringResource, items: [Entry]) -> NSMenuItem {
        let menu = NSMenu(title: String(localized: title))
        for entry in items {
            switch entry {
            case let .item(title, action, key, modifiers, tag):
                let item = menu.addItem(withTitle: String(localized: title), action: action, keyEquivalent: key)
                item.keyEquivalentModifierMask = modifiers
                item.tag = tag
            case .separator: menu.addItem(.separator())
            }
        }
        let holder = NSMenuItem()
        holder.title = menu.title
        holder.submenu = menu
        return holder
    }
}
#endif
