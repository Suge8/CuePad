import SwiftUI

/// 任务行的标题与行尾一次排（`TaskLine`；不用 `ViewThatFits`：它把每个候选都建一遍）：第一格是标题，其后是行尾各格。
/// 标题至少留 `minTitle`（比它短的留它整行）；放不下时行尾按让位的先后收起（`yields`：先是时间，再是没写状态词的标），
/// 写了状态词的（要你管的那件）不让。收起的那格量成零大小、裁掉不画。`trailing`：行尾贴右（手机一列）；否则紧跟标题（iPad 宽栏、Mac）。
/// 行尾各格的首行基线对着标题首行；整块的首行基线就是标题的，外面的圈对着它。
struct TaskLineLayout: Layout {
    let trailing: Bool

    static let gap: CGFloat = 8
    #if os(macOS)
    static let minTitle: CGFloat = 96
    #else
    static let minTitle: CGFloat = 110
    #endif

    /// 行尾一格让位的先后：数大的先让，0 不让。
    struct Yield: LayoutValueKey { static let defaultValue = 0 }

    private struct Plan {
        var title: ProposedViewSize
        var shown: [Bool]
        var sizes: [CGSize]
        var side: CGFloat
        var titleWidth: CGFloat
        /// 各格顶边相对整块顶边的位置（第一格是标题）。
        var tops: [CGFloat]
        var height: CGFloat
    }

    private func plan(_ width: CGFloat?, _ subviews: Subviews) -> Plan {
        let notes = Array(subviews.dropFirst())
        let sizes = notes.map { $0.sizeThatFits(.unspecified) }
        var shown = notes.map { _ in true }
        func side() -> CGFloat { zip(sizes, shown).reduce(0) { $0 + ($1.1 ? $1.0.width + Self.gap : 0) } }
        let ideal = subviews[0].sizeThatFits(.unspecified).width
        if let width {
            for index in notes.indices.sorted(by: { notes[$0][Yield.self] > notes[$1][Yield.self] }) where notes[index][Yield.self] > 0 {
                if width - side() >= min(ideal, Self.minTitle) { break }
                shown[index] = false
            }
        }
        let room = max((width ?? ideal + side()) - side(), 0)
        let titleWidth = trailing && width != nil ? room : min(ideal, room)
        let title = ProposedViewSize(width: titleWidth, height: nil)
        let titleSize = subviews[0].sizeThatFits(title)
        let baseline = subviews[0].dimensions(in: title)[.firstTextBaseline]
        var tops = [0.0], bottoms = [titleSize.height]
        for (index, note) in notes.enumerated() {
            let top = shown[index] ? baseline - note.dimensions(in: ProposedViewSize(sizes[index]))[.firstTextBaseline] : 0
            tops.append(top)
            bottoms.append(top + (shown[index] ? sizes[index].height : 0))
        }
        let lift = -min(tops.min() ?? 0, 0)
        return Plan(
            title: title, shown: shown, sizes: sizes, side: side(), titleWidth: titleWidth,
            tops: tops.map { $0 + lift }, height: (bottoms.max() ?? 0) + lift)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let plan = plan(proposal.width, subviews)
        return CGSize(width: proposal.width ?? plan.titleWidth + plan.side, height: plan.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let plan = plan(bounds.width, subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + plan.tops[0]), proposal: plan.title)
        var x = trailing ? bounds.maxX - plan.side : bounds.minX + plan.titleWidth
        for (index, note) in subviews.dropFirst().enumerated() {
            guard plan.shown[index] else {
                note.place(at: bounds.origin, proposal: .zero)
                continue
            }
            x += Self.gap
            note.place(at: CGPoint(x: x, y: bounds.minY + plan.tops[index + 1]), proposal: ProposedViewSize(plan.sizes[index]))
            x += plan.sizes[index].width
        }
    }

    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? {
        guard guide == .firstTextBaseline, !subviews.isEmpty else { return nil }
        let plan = plan(bounds.width, subviews)
        return bounds.minY + plan.tops[0] + subviews[0].dimensions(in: plan.title)[.firstTextBaseline]
    }
}

extension View {
    /// 任务行行尾的一格（`TaskLineLayout`）：放不下时让位，`first` 的先让；`ever` 为假的不让。
    /// 量自己时是本来的大小，让掉时给零大小、裁掉不画；不让的不裁（等你确认的波纹画在标外面）。
    @ViewBuilder func yields(first: Bool, ever: Bool = true) -> some View {
        if ever {
            fixedSize()
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .layoutValue(key: TaskLineLayout.Yield.self, value: first ? 2 : 1)
        } else {
            fixedSize()
        }
    }
}
