#if os(macOS)
import AppKit

/// 键盘打开的选择菜单（回复框的 ⌘⇧M 模型、⌘⇧E 思考强度）：系统菜单弹在控件下沿，方向键选、↩ 确认、Esc 关，与点开胶囊同样的选项。
/// SwiftUI 的 `Menu` 没有从代码打开的接口，所以键盘这条路用 AppKit 的菜单。
@MainActor
enum ChoiceMenu {
    struct Section {
        let title: String?
        let choices: [Choice]
    }

    struct Choice {
        let title: String
        let subtitle: String?
        let checked: Bool
        let choose: () -> Void
    }

    /// 弹在 `anchor`（控件背景里的空视图，`PopUpAnchor`）下沿。
    static func popUp(_ sections: [Section], below anchor: NSView) {
        let menu = NSMenu()
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            if let title = section.title, sections.count > 1 { menu.addItem(.sectionHeader(title: title)) }
            for choice in section.choices { menu.addItem(item(choice)) }
        }
        let gap: CGFloat = 4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.maxY + gap : -gap), in: anchor)
    }

    private static func item(_ choice: Choice) -> NSMenuItem {
        let handler = Handler(choice.choose)
        let item = NSMenuItem(title: choice.title, action: #selector(Handler.fire), keyEquivalent: "")
        item.target = handler
        // 菜单项只弱引用目标：由它自己留住
        item.representedObject = handler
        item.subtitle = choice.subtitle
        item.state = choice.checked ? .on : .off
        return item
    }

    private final class Handler: NSObject {
        let choose: () -> Void
        init(_ choose: @escaping () -> Void) { self.choose = choose }
        @objc func fire() { choose() }
    }
}
#endif
