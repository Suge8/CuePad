import CueStore
import SwiftUI

/// 一件拍板（`TaskBoard.Wait`，出自 `CueStore.cueTally`）在 Cue 页拍板卡（`CueWaitDock`）上写什么：眉题 `CueWaitEyebrow` 的 `title` 与 `project`，
/// 问句 `CueQuestionLine` 的 `asked`（进展页悬停的问句也是它）；怎么答是 `WaitAnswer`。进展页的卡写什么在 `TaskBoard.Held`。
nonisolated extension TaskBoard.Wait {
    /// 要你定什么与下面那一句：Cue 的是代码写的问句（`CueMessage.headline`）与 `CueAsking.why`（只有规矩那一类有）；
    /// 会话的是问题的第一行，`detail` 是第二行起的说明——选项不写进来（它们是下面的胶囊）。会话在等却没报出问题时是它此刻那一句（`PiProgress.line`）。
    var asked: (line: String, detail: String?) {
        switch wait {
        case .message(let message, _): return (message.headline ?? "", message.asking?.why)
        case .session(let session, _):
            let lines = (session.question?.text ?? PiProgress.line(of: session) ?? "").split(separator: "\n", maxSplits: 1).map(String.init)
            return (lines.first ?? "", lines.count > 1 ? lines[1] : nil)
        }
    }
}

/// 一排胶囊靠右，放不下换行（等你的选项）：每行按自己的宽靠右排；一颗比整行还长时独占一行、字折行。
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews)
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height(rows))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews) {
            var x = bounds.maxX - row.width
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
