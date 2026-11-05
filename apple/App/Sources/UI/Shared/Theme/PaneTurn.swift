import SwiftUI

extension Motion {
    /// 换页（只这一种，各处的切页都经它）：同级的分段切页（项目｜进展、规则｜技能、搜索的两个范围）、气泡里往里翻一页与返回（"更多"里的移到项目、任务气泡翻到子任务）。
    /// 这一页从它所在的那一侧（`edge`：分段里靠左的、外面那一页在 `.leading`，靠右的、里面那一页在 `.trailing`）滑进 `Turn.distance` 并淡入，离开时滑回那一侧并淡出：
    /// 往右的段从右边进、往左的从左边进，往里翻从右边进、返回从左边进，同推入与返回。
    /// 两页的占高也随进度换（出去的收、进来的长，`TurnHeight`），装两页的是 `TurnStack`：它的高是两页报的高之和，正是从旧页的高到新页的高按进度插好的那个，
    /// 贴底的任务气泡、"更多"的高连续地变，不在转场开头或结尾一下跳到终点的高。页里不随页滑的一块（两个范围共用的分段）挂 `turnSteady`，原地淡换。
    /// 动画是触发它的那一下给的 `nudge`；减弱动态效果时只淡、高度直接到终点。两段都一直挂着、只换看得见的那一段的用 `paneTurn`（同一段距离与方向）。
    static func turn(from edge: HorizontalEdge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .modifier(active: TurnPage(progress: 0, shift: Turn.offset(edge)), identity: TurnPage(progress: 1, shift: Turn.offset(edge)))
    }
}

extension EnvironmentValues {
    /// 所在那一页此刻随换页挪着的横向距离（`TurnPage`）：`turnSteady` 抵回它。
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

/// 换页的一页：`progress` 0 是在一侧、透明、不占高，1 是原位。每帧只改偏移、透明度与报上去的高（字按终点排好，不重排）。
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

/// 装换页的两页（`Motion.turn`）：两页叠在同一处、贴上沿，高是两页报上来的高之和（只有一页时就是它的高），宽取宽的那页。
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

/// 照给的尺寸排内容、只往上报 `factor` 那么多的高，内容贴上沿、多出的照样画（不裁）。
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
    /// 几段叠着、一直挂着、只换看得见的那一段（窄屏侧栏的项目｜进展、技能与规则的规则｜技能）：换段的样子同 `Motion.turn`——
    /// 这一段在选中那一段的哪一侧就停在哪一侧 `Motion.Turn.distance` 外、透明，换到它时从那一侧滑回原位并淡入，换走时滑向另一侧。
    /// 平移在渲染端（`visualEffect`，页不每帧重排）；出去的那一段淡得比进来的快（`Motion.fade`），两段叠着半透明的那几帧短、字不糊在一起。
    /// 看不见的那段点不到、读屏跳过。动画是换段那一下给的（`PaneSegment` 的 `nudge`）；减弱动态效果时不滑、只淡。
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
