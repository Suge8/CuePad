import SwiftUI

/// 让滚动区贴着内容的高：放得下就是内容那么高（外面的玻璃不往下多长一截），放不下就是给的那么高、在里面滚。
/// 手机 Cue 页头的面板与 Mac 菜单栏面板的"在做"用它。不用 `ViewThatFits` 排两份：两份内容各有各的状态
/// （"还有 N 个"展开了，量出来放不下，就换成另一份收着的）。
struct HugHeight: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let scroll = subviews.first else { return .zero }
        let ideal = scroll.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, proposal.height ?? ideal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
