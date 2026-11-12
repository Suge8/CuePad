import CueStore
import SwiftUI

nonisolated extension CueWait {
    /// Cue 的是代码写的问句（`CueMessage.headline`）与 `CueAsking.why`（只有规矩那一类有）；会话的见 `SessionState.asked`。
    var asked: (line: String, detail: String?) {
        switch wait {
        case .message(let message, _): (message.headline ?? "", message.asking?.why)
        case .session(let session, _): session.asked
        }
    }
}

nonisolated extension SessionState {
    /// 选项不写进来（它们是胶囊）。在等却没报出问题时是它此刻那一句（`SessionProgress.line`）。
    var asked: (line: String, detail: String?) {
        let lines = (question?.text ?? SessionProgress.line(of: self) ?? "").split(separator: "\n", maxSplits: 1).map(String.init)
        return (lines.first ?? "", lines.count > 1 ? lines[1] : nil)
    }
}

struct ChipFlow: Layout {
    var spacing = Spacing.item
    /// 每一排靠左（默认靠右：Cue 页的卡上选项贴着卡的右沿）。
    var leading = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews)
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height(rows))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews) {
            var x = leading ? bounds.minX : bounds.maxX - row.width
            for (index, size) in row.items {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [(Int, CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func height(_ rows: [Row]) -> CGFloat {
        rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
    }

    private func rows(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (index, subview) in subviews.enumerated() {
            var size = subview.sizeThatFits(.unspecified)
            // 一行放不下的长选项按整行宽折行显示全文，不截断：选项的区别常在末尾
            if size.width > width { size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width { rows.append(Row()) }
            var row = rows[rows.count - 1]
            row.width += (row.items.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.items.append((index, size))
            rows[rows.count - 1] = row
        }
        return rows
    }
}
