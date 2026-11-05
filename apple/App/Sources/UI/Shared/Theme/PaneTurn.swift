import SwiftUI

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
