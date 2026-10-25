#if os(macOS)
import AppKit

/// 回复框的选择菜单（内容见 `ChoiceMenu`）：点模型胶囊与 ⌘⇧M 弹模型、⌘⇧E 弹思考强度。系统菜单弹在控件下沿，方向键选、↩ 确认、Esc 关。
/// 用 AppKit 的菜单：SwiftUI 的 `Menu` 没有从代码打开的接口，在 Mac 上还会丢掉菜单项里的图片。
/// 分组标题与选项可带标志（提供方的产品、模型的家族）：符号是模板图，菜单按文字的颜色画，高亮时随文字反白。
extension ChoiceMenu {
    /// 弹在 `anchor`（控件背景里的空视图，`PopUpAnchor`）下沿。
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
