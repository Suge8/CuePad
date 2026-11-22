import SwiftUI

struct PreviewRow: Layout {
    let maxHeight: CGFloat
    let gap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(proposal, subviews)
        let height = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: widths.reduce(0, +) + gaps(subviews), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(proposal, subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading, proposal: ProposedViewSize(width: width, height: nil))
            x += width + gap
        }
    }

    private func widths(_ proposal: ProposedViewSize, _ subviews: Subviews) -> [CGFloat] {
        let aspects = subviews.map { $0[PreviewAspect.self] }
        let room = (proposal.width ?? .infinity) - gaps(subviews)
        let height = min(maxHeight, room / aspects.reduce(0, +))
        return aspects.map { ($0 * height).rounded(.down) }
    }

    private func gaps(_ subviews: Subviews) -> CGFloat { gap * CGFloat(max(subviews.count - 1, 0)) }
}

nonisolated struct PreviewAspect: LayoutValueKey {
    static let defaultValue: CGFloat = 4 / 3
}
