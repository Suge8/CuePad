import SwiftUI

/// 当帧按理想宽度选排并放置，不依赖布局后的回调或视图状态。
struct LedgerFit: Layout {
    struct Line {
        /// 子视图（`items`）的序号。
        let items: [Int]
        let gap: CGFloat
    }

    /// 各排里出现过的项，各一次。
    let items: [CueNow.Entry]
    let lines: [Line]
    /// 序号小于它的是要你管的那组。
    let yours: Int

    /// `CueNow.ledger` 的各排，再是最粗那排收紧间距，再是只写要你管的那组（没有要你管的就停在收紧那排）。
    init(_ now: CueNow, gap: CGFloat) {
        let rows = now.ledger
        let items = rows.reduce(into: [CueNow.Entry]()) { items, row in items += row.filter { !items.contains($0) } }
        let index = { (entries: [CueNow.Entry]) in entries.map { items.firstIndex(of: $0)! } }
        let urgent = index(now.yours)
        self.items = items
        lines = rows.map { Line(items: index($0), gap: gap) } + [Line(items: index(rows[rows.count - 1]), gap: gap / 2)]
            + (urgent.isEmpty ? [] : [Line(items: urgent, gap: gap / 2)])
        yours = urgent.count
    }

    static let groupGap: CGFloat = 1.75

    func makeCache(subviews: Subviews) -> [CGSize] { subviews.map { $0.sizeThatFits(.unspecified) } }

    func updateCache(_ cache: inout [CGSize], subviews: Subviews) { cache = makeCache(subviews: subviews) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) -> CGSize {
        let line = pick(proposal.width, cache)
        return CGSize(width: width(line, cache), height: line.items.map { cache[$0].height }.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) {
        let line = pick(proposal.width, cache)
        for index in subviews.indices where !line.items.contains(index) {
            subviews[index].place(at: bounds.origin, proposal: .zero)
        }
        var x = bounds.minX
        for (position, index) in line.items.enumerated() {
            if position > 0 { x += spacing(line, after: line.items[position - 1], before: index) }
            let size = cache[index]
            subviews[index].place(at: CGPoint(x: x, y: bounds.midY - size.height / 2), proposal: ProposedViewSize(size))
            x += size.width
        }
    }

    private func pick(_ width: CGFloat?, _ sizes: [CGSize]) -> Line {
        guard let width else { return lines[0] }
        return lines.first { self.width($0, sizes) <= width } ?? lines[lines.count - 1]
    }

    private func width(_ line: Line, _ sizes: [CGSize]) -> CGFloat {
        zip(line.items, line.items.dropFirst()).reduce(line.items.map { sizes[$0].width }.reduce(0, +)) { total, pair in
            total + spacing(line, after: pair.0, before: pair.1)
        }
    }

    private func spacing(_ line: Line, after: Int, before: Int) -> CGFloat {
        (after < yours) == (before < yours) ? line.gap : line.gap * Self.groupGap
    }
}

