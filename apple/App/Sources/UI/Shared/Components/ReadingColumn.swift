import SwiftUI

/// 会话的阅读栏（iOS 会话页、Mac 会话页共用）：最宽 `maxWidth`（含左右 `inset`），在容器里居中。
/// 栏里的东西按"所在栏宽"排，规则只在这里：气泡最宽是栏宽的一个比例（`TrailingFraction`）；
/// 横向滚动的表格只在栏贴着容器边（手机、窄窗口：容器不比栏宽）时越过页边距滑到容器边，栏两边还有空白时收在栏内。
extension View {
    func readingColumn(maxWidth: CGFloat, inset: CGFloat) -> some View {
        modifier(ReadingColumn(maxWidth: maxWidth, inset: inset))
    }
}

extension EnvironmentValues {
    /// 所在的阅读栏贴着容器边：横向滚动区可以越过页边距（`readingColumn`）。不在阅读栏里时不越过。
    @Entry var readingColumnBleeds = false
}

private struct ReadingColumn: ViewModifier {
    let maxWidth: CGFloat
    let inset: CGFloat
    @State private var bleeds = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, inset)
            .environment(\.readingColumnBleeds, bleeds)
            .frame(maxWidth: maxWidth)
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: Bool.self) { $0.size.width <= maxWidth } action: { bleeds = $0 }
    }
}

/// 占满给它的宽，里面那一个按"给的宽 × `fraction`"排、靠右。不用 `containerRelativeFrame`：它量的是滚动区，
/// 不是对话所在的阅读栏——宽窗口里阅读栏比滚动区窄得多，气泡的框比栏宽，靠右就伸出栏外、贴到窗口右缘。
struct TrailingFraction: Layout {
    let fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width.map { $0 * fraction }, height: nil))
        return CGSize(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let size = child.sizeThatFits(ProposedViewSize(width: bounds.width * fraction, height: nil))
        child.place(at: CGPoint(x: bounds.maxX, y: bounds.minY), anchor: .topTrailing, proposal: ProposedViewSize(size))
    }
}
