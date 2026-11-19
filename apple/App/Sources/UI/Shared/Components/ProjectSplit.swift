import CueStore
import SwiftUI

/// 项目页的两块怎么摆（三端同一份）：窄时任务在上、灵感墙在下；宽到 `sideBySide` 时任务在左、墙在右——宽窗口里一条任务栏靠左、右边整片空着，像页没排完。
/// 是排版不是两套视图：Cue 那一栏开合让宽度跨过这条线时，两块是挪过去的（`ProjectSplit` 带动画），任务区的开合也留着。
struct ProjectSplit<Content: View>: View {
    var project: Project?
    let gap: CGFloat
    @ViewBuilder let content: Content
    /// 上一帧量到的宽够不够并排；nil 是还没量到，头一帧由排版自己按宽度定，不从上下排滑过来。
    @State private var side: Bool?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.part) {
            if let project { ProjectBanner(project: project) }
            ProjectColumns(gap: gap, side: side) { content }
        }
            .onGeometryChange(for: Bool.self) { $0.size.width >= ProjectColumns.sideBySide } action: { side = $0 }
            .animation(Motion.spatial(Motion.travel, reduceMotion: reduceMotion), value: side)
    }
}

struct ProjectColumns: Layout {
    /// 上下排时两块之间的距离。
    var gap: CGFloat
    var side: Bool?

    static let sideBySide: CGFloat = 1000
    private static let gutter: CGFloat = 40

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? Self.sideBySide
        let frames = frames(subviews, width: width)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(width: frame.width, height: nil))
        }
    }

    private func frames(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        if subviews.count == 2, side ?? (width >= Self.sideBySide) {
            // 任务栏只占三成：标题多是一行短字，再宽中间就空出一条沟，两块像不相干
            let lead = min(400, max(320, width * 0.3)), rest = width - lead - Self.gutter
            return [
                CGRect(x: 0, y: 0, width: lead, height: subviews[0].sizeThatFits(ProposedViewSize(width: lead, height: nil)).height),
                CGRect(x: lead + Self.gutter, y: 0, width: rest, height: subviews[1].sizeThatFits(ProposedViewSize(width: rest, height: nil)).height),
            ]
        }
        var y: CGFloat = 0
        return subviews.map { subview in
            let height = subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
            defer { y += height + gap }
            return CGRect(x: 0, y: y, width: width, height: height)
        }
    }
}

/// 位置只由顺序与宽度推出，不记"哪张在哪列"：墙上的顺序本身是稳定的（`WallArrangement`：同一次打开里编辑过的卡原地不动），记分列的话删卡、改成任务留下的空列会一直空着。
struct MasonryLayout: Layout {
    var minColumnWidth: CGFloat = 220
    var maxColumns = 4
    var spacing = Spacing.block

    private static let idealWidth: CGFloat = 900

    /// 同一轮排版里 SwiftUI 先量（`sizeThatFits`）再摆（`placeSubviews`），每张卡只量一遍。
    final class Memo {
        var width: CGFloat?
        var frames: [CGRect] = []
    }

    func makeCache(subviews: Subviews) -> Memo { Memo() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) -> CGSize {
        let width = fit(proposal.width).width
        return CGSize(width: width, height: frames(subviews, width: width, memo: cache).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) {
        for (subview, frame) in zip(subviews, frames(subviews, width: bounds.width, memo: cache)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    /// 墙没有文字基线可对齐；默认实现会逐个询问子视图，侧栏开合时每帧都付这笔账（时间分析里约 4%）。
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Memo) -> CGFloat? { nil }

    /// 墙没有固有宽度：问理想尺寸（nil）或最大尺寸（无穷）时按 `idealWidth` 排——无穷宽换算列数会让整数转换崩溃。
    private func fit(_ proposed: CGFloat?) -> (width: CGFloat, count: Int) {
        let width = proposed.flatMap { $0.isFinite ? $0 : nil } ?? Self.idealWidth
        return (width, max(1, min(maxColumns, Int(((width + spacing) / (minColumnWidth + spacing)).rounded(.down)))))
    }

    private func frames(_ subviews: Subviews, width: CGFloat, memo: Memo) -> [CGRect] {
        if memo.width == width { return memo.frames }
        let count = fit(width).count
        let columnWidth = max((width - spacing * CGFloat(count - 1)) / CGFloat(count), 0)
        var heights = Array(repeating: CGFloat(0), count: count)
        let frames = subviews.map { subview in
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let frame = CGRect(x: CGFloat(column) * (columnWidth + spacing), y: heights[column], width: columnWidth, height: height)
            heights[column] += height + spacing
            return frame
        }
        memo.width = width
        memo.frames = frames
        return frames
    }
}
