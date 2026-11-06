import SwiftUI

/// 会话页里一两份交付物的排法（`PreviewBatch`）：几张同高、宽按各自画面的比例分（同"照片"与 Telegram 相册的对齐排法），整排不宽过给的宽、不高过 `maxHeight`；
/// 纸跟着整排收窄。否决的是各占等宽一半、各自按比例放进去：一横一竖并排时一高一矮、竖的那半右边空一截，一份时纸比图宽出一大块。
/// 每张的比例由格子自己报（`PreviewAspect`），读到画面前按类型猜，读到时整排按真比例重排一次（同主图）。
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

    /// 同一个高：放得下 `maxHeight` 就是它，放不下就按给的宽除以比例之和；没给宽（问理想尺寸）时按 `maxHeight`。
    private func widths(_ proposal: ProposedViewSize, _ subviews: Subviews) -> [CGFloat] {
        let aspects = subviews.map { $0[PreviewAspect.self] }
        let room = (proposal.width ?? .infinity) - gaps(subviews)
        let height = min(maxHeight, room / aspects.reduce(0, +))
        return aspects.map { ($0 * height).rounded(.down) }
    }

    private func gaps(_ subviews: Subviews) -> CGFloat { gap * CGFloat(max(subviews.count - 1, 0)) }
}

/// 格子画面的宽高比（宽 / 高，`DeliverableTile.aspect`），`PreviewRow` 按它分宽。
nonisolated struct PreviewAspect: LayoutValueKey {
    static let defaultValue: CGFloat = 4 / 3
}
