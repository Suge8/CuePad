import SwiftUI

extension Motion {
    static func turn(from edge: HorizontalEdge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .modifier(active: TurnPage(progress: 0, shift: Turn.offset(edge)), identity: TurnPage(progress: 1, shift: Turn.offset(edge)))
    }
}

extension EnvironmentValues {
    @Entry var turnShift: CGFloat = 0
}

extension View {
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
