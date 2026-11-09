#if os(macOS)
import AppKit

/// 用 AppKit 的菜单：SwiftUI 的 `Menu` 没有从代码打开的接口，在 Mac 上还会丢掉菜单项里的图片。
extension ChoiceMenu {
    static func popUp(_ sections: [Section], below anchor: NSView) {
        let menu = NSMenu()
        for (index, section) in sections.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            if let title = section.title, sections.count > 1 {
                let header = NSMenuItem.sectionHeader(title: String(localized: title))
                show(section.image?.nsImage, on: header)
                menu.addItem(header)
            }
            for choice in section.choices { menu.addItem(item(choice)) }
        }
        let gap: CGFloat = 4
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.maxY + gap : -gap), in: anchor)
    }

    private static func item(_ choice: Choice) -> NSMenuItem {
        let handler = Handler(choice.choose)
        // 停用项没有动作：菜单按没有动作的项画成灰、点不了
        let item = NSMenuItem(title: String(localized: choice.title), action: choice.disabled ? nil : #selector(Handler.fire), keyEquivalent: "")
        item.target = handler
        // 菜单项只弱引用目标：由它自己留住
        item.representedObject = handler
        item.subtitle = choice.subtitle.map { String(localized: $0) }
        show(choice.image?.nsImage, on: item)
        item.state = choice.checked == true ? .on : .off
        return item
    }

    /// macOS 27 起菜单默认藏起菜单项的图片，只有标明要显示的才画；这里的图标说的是"哪一家"（对象而非动作），要显示。
    private static func show(_ image: NSImage?, on item: NSMenuItem) {
        guard let image else { return }
        item.image = image
        if #available(macOS 27, *) { item.preferredImageVisibility = .visible }
    }

    private final class Handler: NSObject {
        let choose: () -> Void
        init(_ choose: @escaping () -> Void) { self.choose = choose }
        @objc func fire() { choose() }
    }
}

extension ChoiceMenu.Glyph {
    var nsImage: NSImage? {
        switch self {
        case .icon(let icon): icon.platformImage
        case .brand(let mark): mark.nsImage
        }
    }
}
#endif
