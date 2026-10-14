#if os(macOS)
import AppKit

/// 回复框的选择菜单：点模型胶囊与 ⌘⇧M 弹模型、⌘⇧E 弹思考强度。系统菜单弹在控件下沿，方向键选、↩ 确认、Esc 关。
/// 用 AppKit 的菜单：SwiftUI 的 `Menu` 没有从代码打开的接口，在 Mac 上还会丢掉菜单项里的图片。
/// 分组标题与选项可带图标（模型的提供方），一律次要墨色。
enum ChoiceMenu {
    struct Section {
        let title: String?
        var image: NSImage? = nil
        let choices: [Choice]
    }

    struct Choice {
        let title: String
        let subtitle: String?
        var image: NSImage? = nil
        let checked: Bool
        let choose: () -> Void
    }

    /// 弹在 `anchor`（控件背景里的空视图，`PopUpAnchor`）下沿。
    static func popUp(_ sections: [Section], below anchor: NSView) {
        let menu = NSMenu()
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            if let title = section.title, sections.count > 1 {
                let header = NSMenuItem.sectionHeader(title: title)
                show(section.image, on: header)
                menu.addItem(header)
            }
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
        show(choice.image, on: item)
        item.state = choice.checked ? .on : .off
        return item
    }

    /// macOS 27 起菜单默认藏起菜单项的图片，只有标明要显示的才画；这里的图标说的是"哪一家"（对象而非动作），要显示。
    private static func show(_ image: NSImage?, on item: NSMenuItem) {
        guard let image else { return }
        item.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.secondaryLabelColor])) ?? image
        if #available(macOS 27, *) { item.preferredImageVisibility = .visible }
    }

    private final class Handler: NSObject {
        let choose: () -> Void
        init(_ choose: @escaping () -> Void) { self.choose = choose }
        @objc func fire() { choose() }
    }
}
#endif
