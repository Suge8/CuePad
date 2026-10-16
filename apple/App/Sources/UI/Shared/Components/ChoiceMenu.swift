import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 选择菜单的内容（分组、每项的名字、副标题、标志、打勾、做什么），两端同一份：Mac 弹 AppKit 菜单（`ChoiceMenu.popUp`，回复框的模型与思考强度，
/// 键盘也弹得出），`MenuButton` 是点开它的按钮。只有一组时不写组名。
enum ChoiceMenu {
    struct Section {
        var title: String? = nil
        var image: Glyph? = nil
        let choices: [Choice]
    }

    struct Choice {
        let title: String
        var subtitle: String? = nil
        var image: Glyph? = nil
        /// nil 是动作（不打勾），否则是选项、当前的打勾。
        var checked: Bool? = nil
        var destructive = false
        let choose: () -> Void
    }

    /// 菜单项与组名旁的图：系统符号，或品牌标志（`BrandMark`）。说的是"哪一个"（对象而非动作），两端都要显示出来。
    enum Glyph {
        case symbol(String)
        case brand(BrandMark)

        var image: Image {
            switch self {
            case .symbol(let name): Image(systemName: name)
            case .brand(let mark): mark.image
            }
        }
    }
}

/// 点开选择菜单的按钮：`label` 是它的样子，给了 `primary` 时点按做它、长按出菜单（回复框的发送钮），否则点按出菜单。
/// 读屏念的是 `accessibilityLabel`（与 `value`、`hint`），样子本身不念。
/// 手机上菜单挂在一颗盖在样子上的透明 UIKit 按钮上：系统菜单开着时输入法的候选栏收起、键盘矮一截，贴着键盘的输入框会跟着往下掉再弹回来；
/// SwiftUI 的 `Menu` 不说它开没开，UIKit 的按钮说（`willDisplayMenu`、`willEnd`），开着的这段由 `KeyboardHold` 把键盘上方的位置锁住。
/// Mac 上是 SwiftUI 的菜单（没有键盘的事）。
struct MenuButton<Label: View>: View {
    let sections: [ChoiceMenu.Section]
    var primary: (() -> Void)? = nil
    var press = Press.control
    let accessibilityLabel: String
    var value: String? = nil
    var hint: String? = nil
    @ViewBuilder let label: () -> Label

    #if os(iOS)
    @Environment(Navigation.self) private var navigation: Navigation?
    @Environment(\.isEnabled) private var isEnabled
    @State private var pressed = false

    var body: some View {
        label()
            .modifier(PressFeedback(pressed: pressed, kind: press))
            .accessibilityHidden(true)
            .overlay {
                MenuTrigger(
                    sections: sections, primary: primary, isEnabled: isEnabled, label: accessibilityLabel, value: value, hint: hint,
                    pressed: { pressed = $0 }, presented: { navigation?.menuOpen = $0 })
            }
    }
    #else
    var body: some View {
        Group {
            if let primary {
                Menu { ChoiceMenuItems(sections: sections) } label: { label() } primaryAction: { primary() }
            } else {
                Menu { ChoiceMenuItems(sections: sections) } label: { label() }
            }
        }
        .menuStyle(.button).buttonStyle(PressStyle(press)).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(value ?? "")
        .accessibilityHint(hint ?? "")
    }
    #endif
}

#if os(macOS)
/// Mac 上 SwiftUI 菜单里的项（`MenuButton` 与右键菜单共用）。
struct ChoiceMenuItems: View {
    let sections: [ChoiceMenu.Section]

    var body: some View {
        ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
            if sections.count > 1, let title = section.title {
                Section(title) { choices(section) }
            } else {
                Section { choices(section) }
            }
        }
    }

    private func choices(_ section: ChoiceMenu.Section) -> some View {
        ForEach(Array(section.choices.enumerated()), id: \.offset) { _, choice in item(choice) }
    }

    @ViewBuilder private func item(_ choice: ChoiceMenu.Choice) -> some View {
        if let checked = choice.checked {
            Toggle(isOn: Binding(get: { checked }, set: { if $0 { choice.choose() } })) { content(choice) }
        } else {
            Button(role: choice.destructive ? .destructive : nil, action: choice.choose) { content(choice) }
        }
    }

    @ViewBuilder private func content(_ choice: ChoiceMenu.Choice) -> some View {
        Text(choice.title)
        if let subtitle = choice.subtitle { Text(subtitle) }
        choice.image?.image
    }
}
#endif

#if os(iOS)
/// 透明的 UIKit 按钮：盖在样子上接点按，菜单开、关时告诉 SwiftUI（`presented`），按下的样子交回 SwiftUI 画（`pressed`）。
/// 菜单项在打开的那一刻按最新的内容现建（`UIDeferredMenuElement.uncached`），内容变了不用重设菜单。
private struct MenuTrigger: UIViewRepresentable {
    let sections: [ChoiceMenu.Section]
    let primary: (() -> Void)?
    let isEnabled: Bool
    let label: String
    let value: String?
    let hint: String?
    let pressed: (Bool) -> Void
    let presented: (Bool) -> Void

    func makeUIView(context: Context) -> TriggerButton {
        let button = TriggerButton()
        button.deferred = UIMenu(children: [UIDeferredMenuElement.uncached { [weak button] done in done(button?.elements ?? []) }])
        button.addAction(UIAction { [weak button] _ in button?.primary?() }, for: .primaryActionTriggered)
        return button
    }

    func updateUIView(_ button: TriggerButton, context: Context) {
        button.sections = sections
        // 没有可选的（带上的卡片不能拿掉时）就没有菜单：长按什么都不出
        button.menu = sections.allSatisfy(\.choices.isEmpty) ? nil : button.deferred
        button.primary = primary
        button.showsMenuAsPrimaryAction = primary == nil
        button.isEnabled = isEnabled
        button.accessibilityLabel = label
        button.accessibilityValue = value
        button.accessibilityHint = hint
        button.pressed = pressed
        button.presented = presented
    }
}

private final class TriggerButton: UIButton {
    var sections: [ChoiceMenu.Section] = []
    var deferred: UIMenu?
    var primary: (() -> Void)?
    var pressed: (Bool) -> Void = { _ in }
    var presented: (Bool) -> Void = { _ in }

    override var isHighlighted: Bool {
        didSet { if isHighlighted != oldValue { pressed(isHighlighted) } }
    }

    var elements: [UIMenuElement] {
        sections.map { section in
            UIMenu(
                title: sections.count > 1 ? section.title ?? "" : "", image: section.image?.uiImage, options: .displayInline,
                children: section.choices.map { choice in
                    let action = UIAction(title: choice.title, subtitle: choice.subtitle, image: choice.image?.uiImage) { _ in choice.choose() }
                    if choice.destructive { action.attributes = .destructive }
                    action.state = choice.checked == true ? .on : .off
                    return action
                })
        }
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        pressed(false)
        presented(true)
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        presented(false)
    }
}

extension ChoiceMenu.Glyph {
    var uiImage: UIImage? {
        switch self {
        case .symbol(let name): UIImage(systemName: name)
        case .brand(let mark): mark.uiImage
        }
    }
}

/// 系统菜单开着的这段（`Navigation.menuOpen`）锁住键盘上方的位置：内容的框与底部安全区（含键盘）都定在菜单开之前那一刻，
/// 这段里不跟键盘走（候选栏收起、键盘变矮）；关了之后等键盘回到原高再放开，键盘因菜单里的动作往下收（比开着时还矮）就立刻放开、跟着它走。
/// 锁成一个写死高度（原高加原底部安全区）、顶边对齐的框，放在不随孩子撑大的框（minHeight 0）里：忽略安全区不放大外面给的尺寸，
/// 只垫底部安全区的话内容（有最小高度，如 Cue 页的页头、等你卡片与输入框）加垫的那截超出外面给的高度，撑大的这一层被外面居中，顶边被挤出屏幕；
/// 只锁高度不垫底部安全区又会改了滚动区的框，对话的锚点跟着跳。
/// 挂在跟着键盘走的那一层：导航栈里的每一页（`RouteView`，页在 UIKit 的宿主里自己让键盘，外层管不到）、iPad 的 Cue 面板与浮起的输入框（`FloatingInput`）。
/// 键盘变矮的通知可能比"菜单开了"的状态先到这里，所以锁的是菜单开之前最后一次的读数，不是开的那一刻的。
/// 读数记在引用里（不进状态），只在开、关与放开时取用，不形成布局反馈环。
struct KeyboardHold: ViewModifier {
    @Environment(Navigation.self) private var navigation
    @State private var held: Reading?
    @State private var readings = Readings()

    /// 外面给的这一层：高度与底部安全区（含键盘）。
    nonisolated private struct Reading: Equatable {
        var height: CGFloat = 0
        var bottom: CGFloat = 0
    }

    private final class Readings {
        var now = Reading()
        /// 没有菜单开着时的最后一次。
        var steady = Reading()
        /// 菜单开着以来最矮的底部安全区（候选栏收起的那一截）。
        var lowest: CGFloat = 0
    }

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.bottom, held?.bottom ?? 0)
            .frame(height: held.map { $0.height + $0.bottom })
            .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea(held == nil ? [] : .all, edges: .bottom)
            // 读的是外面给的：挂在背景上，不受上面这层忽略的影响
            .background { Color.clear.onGeometryChange(for: Reading.self) { Reading(height: $0.size.height, bottom: $0.safeAreaInsets.bottom) } action: { now in
                readings.now = now
                guard held != nil || navigation.menuOpen else {
                    readings.steady = now
                    return
                }
                let lower = now.bottom < readings.lowest - 0.5
                readings.lowest = min(readings.lowest, now.bottom)
                if let held, !navigation.menuOpen, now.bottom >= held.bottom - 0.5 || lower { release() }
            } }
            .onChange(of: navigation.menuOpen) { _, open in
                if open {
                    held = readings.steady
                    readings.lowest = min(readings.steady.bottom, readings.now.bottom)
                } else if let held, readings.now.bottom >= held.bottom - 0.5 {
                    release()
                }
            }
    }

    private func release() {
        held = nil
        readings.steady = readings.now
    }
}
#endif
