import SwiftUI

extension View {
    func chip(on: Bool = false, menu: Bool = false, size: ControlSize = .inline, level: ControlSurface.Level? = nil) -> some View {
        modifier(Chip(on: on, menu: menu, size: size, level: level))
    }
}

extension EnvironmentValues {
    @Entry var chipHeight: CGFloat?
}

private struct Chip: ViewModifier {
    let on: Bool
    let menu: Bool
    let size: ControlSize
    let level: ControlSurface.Level?
    @Environment(\.palette) private var palette
    @Environment(\.chipHeight) private var height

    private static let gap = Spacing.tight

    func body(content: Content) -> some View {
        HStack(spacing: Self.gap) {
            WholePoints { content }
            if menu { Chevron(.expand).foregroundStyle(on ? palette.ink2 : palette.ink3) }
        }
        .lineLimit(1)
        .modifier(ControlSurface(kind: .secondary, size: size, selected: on, level: level, height: height))
    }
}

/// 内容的宽取整到整点。胶囊的框摆出来要按像素对齐，带小数的宽在有的位置会被削掉零点几，
/// 胶囊里"放不下就换短写法"的 `ViewThatFits` 就差这一点换掉（实测模型胶囊要 118.17、给成 118.0，名字没了）；整点宽对齐时不削。
private struct WholePoints: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(proposal)
        return CGSize(width: size.width.rounded(.up), height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(bounds.size))
    }
}
