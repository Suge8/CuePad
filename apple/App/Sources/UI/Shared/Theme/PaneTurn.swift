import SwiftUI

extension Motion {
    /// 换页只这一种，各处的切页都经它。
    /// 两页的占高也随进度换（出去的收、进来的长，`TurnHeight`），装两页的是 `TurnStack`：贴底的任务气泡、"更多"的高连续地变，不在转场开头或结尾一下跳到终点的高。页里不随页滑的一块（两个范围共用的分段）挂 `turnSteady`，原地淡换。
    /// 动画是触发它的那一下给的 `nudge`。两段都一直挂着、只换看得见的那一段的用 `paneTurn`（同一段距离与方向）。
    static func turn(from edge: HorizontalEdge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .modifier(active: TurnPage(progress: 0, shift: Turn.offset(edge)), identity: TurnPage(progress: 1, shift: Turn.offset(edge)))
    }
}

extension EnvironmentValues {
    @Entry var turnShift: CGFloat = 0
}

extension View {
    /// 这一块不随换页滑（`Motion.turn`）：两页上同一处同一样东西（搜索两个范围顶上的分段），原地淡换，看着就是没动。
    func turnSteady() -> some View { modifier(TurnSteady()) }
}

private struct TurnSteady: ViewModifier {
    @Environment(\.turnShift) private var shift

    func body(content: Content) -> some View { content.offset(x: -shift) }
}

private struct TurnPage: ViewModifier, Animatable {
    var progress: CGFloat
    let shift: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let x = shift * (1 - progress)
        TurnHeight(factor: progress) {
            content.environment(\.turnShift, x).offset(x: x).opacity(progress)
        }
    }
}

/// 否决了 `ZStack`：它取较高的那页，两页各报一半高时容器塌下去一截再长回来。
struct TurnStack: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(proposal) }
        return CGSize(width: sizes.map(\.width).max() ?? 0, height: sizes.map(\.height).reduce(0, +))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: proposal.height)) }
    }
}

private struct TurnHeight: Layout {
    let factor: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews[0].sizeThatFits(proposal)
        return CGSize(width: size.width, height: size.height * factor)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: proposal.height))
    }
}

extension View {
    /// 平移在渲染端（`visualEffect`，页不每帧重排）；出去的那一段淡得比进来的快（`Motion.fade`），两段叠着半透明的那几帧短、字不糊在一起。
    func paneTurn(_ index: Int, of selected: Int) -> some View { modifier(PaneTurn(index: index, selected: selected)) }
}

private struct PaneTurn: ViewModifier {
    let index: Int
    let selected: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let shown = index == selected
        let x = shown || reduceMotion ? 0 : Motion.Turn.offset(index < selected ? .leading : .trailing)
        content
            .visualEffect { effect, _ in effect.offset(x: x) }
            .opacity(shown ? 1 : 0)
            .transaction(value: shown) { if !shown, $0.animation != nil { $0.animation = Motion.fade } }
            .allowsHitTesting(shown)
            .readerHidden(!shown)
    }
}
