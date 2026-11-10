import SwiftUI

extension View {
    /// 全 App 只这一种胶囊：外形就是 `ControlSurface` 的次按钮，不另画一份。
    /// 带菜单 ⇔ 有箭头：点开是菜单（系统菜单、`MenuButton`、Mac 弹的 AppKit 菜单）的给 `menu`，末尾一枚展开箭头；点了直接换、开气泡的不给。按钮外面套 `PressStyle()`，菜单的标签直接挂。
    func chip(on: Bool = false, menu: Bool = false, size: ControlSize = .inline, level: ControlSurface.Level? = nil) -> some View {
        modifier(Chip(on: on, menu: menu, size: size, level: level))
    }
}

private struct Chip: ViewModifier {
    let on: Bool
    let menu: Bool
    let size: ControlSize
    let level: ControlSurface.Level?
    @Environment(\.palette) private var palette

    private static let gap: CGFloat = 4

    func body(content: Content) -> some View {
        HStack(spacing: Self.gap) {
            content
            if menu { Chevron(.expand).foregroundStyle(on ? palette.ink2 : palette.ink3) }
        }
        .lineLimit(1)
        .modifier(ControlSurface(kind: .secondary, size: size, selected: on, level: level))
    }
}
