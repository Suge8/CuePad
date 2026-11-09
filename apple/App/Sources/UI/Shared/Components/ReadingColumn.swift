import SwiftUI

extension EnvironmentValues {
    @Entry var readingColumnBleeds = false
}

/// 不用 `containerRelativeFrame`：它量的是滚动区，不是对话所在的阅读栏——宽窗口里阅读栏比滚动区窄得多，气泡的框比栏宽，靠右就伸出栏外、贴到窗口右缘。里面那一个按给的宽量一次就记下：量与摆是同一个宽，长回答的字不排两遍；对齐线不问里面（默认实现会逐个问子视图要文字的对齐）。
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
