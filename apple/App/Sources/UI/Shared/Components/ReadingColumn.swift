import SwiftUI

/// 会话的阅读栏（宽与边距由 `ChatScroll` 定）里按"所在栏宽"排的规则：气泡最宽是栏宽的一个比例（`BubbleWidth`）；
/// 横向滚动的表格只在栏贴着容器边（手机、窄窗口：容器不比栏宽）时越过页边距滑到容器边，栏两边还有空白时收在栏内。
extension EnvironmentValues {
    /// 所在的阅读栏贴着容器边：横向滚动区可以越过页边距（`ChatScroll` 写入）。不在阅读栏里时不越过。
    @Entry var readingColumnBleeds = false
}

/// 占满给它的宽，里面那一个按"给的宽 × `fraction`"排、靠 `edge` 那一边（你的话靠右，Cue 的话靠左）。不用 `containerRelativeFrame`：它量的是滚动区，
/// 不是对话所在的阅读栏——宽窗口里阅读栏比滚动区窄得多，气泡的框比栏宽，靠右就伸出栏外、贴到窗口右缘。
/// 里面那一个按给的宽量一次就记下：量与摆是同一个宽，长回答的字不排两遍；对齐线不问里面（默认实现会逐个问子视图要文字的对齐）。
struct BubbleWidth: Layout {
    let fraction: CGFloat
    let edge: HorizontalEdge

    struct Measured {
        var width: CGFloat?
        var size: CGSize?
    }

    func makeCache(subviews: Subviews) -> Measured { Measured() }

    private func child(_ subviews: Subviews, width: CGFloat?, cache: inout Measured) -> CGSize {
        if let size = cache.size, cache.width == width { return size }
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: width.map { $0 * fraction }, height: nil)) ?? .zero
        cache = Measured(width: width, size: size)
        return size
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Measured) -> CGSize {
        let size = child(subviews, width: proposal.width, cache: &cache)
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Measured) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Measured) -> CGFloat? { nil }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Measured) {
        guard let child = subviews.first else { return }
        let size = self.child(subviews, width: bounds.width, cache: &cache)
        if edge == .trailing {
            child.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing, proposal: ProposedViewSize(size))
        } else {
            child.place(at: bounds.origin, proposal: ProposedViewSize(size))
        }
    }
}
