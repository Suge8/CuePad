import Foundation

/// 卡片墙的分列。已有的卡一旦分到某列就留在那列：存新卡、删卡都不让别的卡换列，用户记住的位置不作废；
/// 只有列数变化（窗口宽度跨档）时才按顺序重新分配。
///
/// 高度用估计值（`estimatedHeight`）：分列要在排版之前决定，估计只影响各列是否大致齐平，不影响卡片实际大小。
nonisolated struct WallColumns: Equatable, Sendable {
    private(set) var columns: [[UUID]]

    /// 按 `order` 依次放进当前最矮的一列（并列取左边）。
    init(order: [UUID], count: Int, height: (UUID) -> Double) {
        columns = Array(repeating: [], count: max(1, count))
        var heights = Array(repeating: 0.0, count: columns.count)
        for id in order {
            let column = Self.lowest(heights)
            columns[column].append(id)
            heights[column] += height(id)
        }
    }

    /// 跟上新的顺序：离开的卡移除；新出现的卡放进最矮一列——排在所有已有卡之前的放顶部（新建、刚编辑回来的），
    /// 其余放底部；列数变了就整体重新分配。
    mutating func update(order: [UUID], count: Int, height: (UUID) -> Double) {
        guard max(1, count) == columns.count else {
            self = WallColumns(order: order, count: count, height: height)
            return
        }
        let present = Set(order)
        columns = columns.map { $0.filter(present.contains) }
        let placed = Set(columns.joined())
        let firstPlaced = order.firstIndex(where: placed.contains) ?? order.endIndex
        let arrivals = order.enumerated().filter { !placed.contains($0.element) }
        // 放顶部的倒着插，最后插入的在最上面，与 `order` 的先后一致
        for (index, id) in arrivals.reversed() where index < firstPlaced {
            columns[Self.lowest(heights(height))].insert(id, at: 0)
        }
        for (index, id) in arrivals where index >= firstPlaced {
            columns[Self.lowest(heights(height))].append(id)
        }
    }

    private func heights(_ height: (UUID) -> Double) -> [Double] {
        columns.map { $0.reduce(0) { $0 + height($1) } }
    }

    private static func lowest(_ heights: [Double]) -> Int {
        heights.indices.min { heights[$0] < heights[$1] } ?? 0
    }

    /// 列数：列宽落在理想宽度附近，窗口越宽列越多。
    static func count(for width: Double, idealColumnWidth: Double, spacing: Double) -> Int {
        max(1, Int(((width + spacing) / (idealColumnWidth + spacing)).rounded(.down)))
    }

    /// 卡片高度的估计：标题与摘要按每行字数折行，有图加图的高度。
    static func estimatedHeight(of text: CardText, columnWidth: Double) -> Double {
        let charactersPerLine = max(8, columnWidth / 13)
        let titleLines = min(2, (Double(max(1, text.title.count)) / charactersPerLine).rounded(.up))
        let previewLines = text.preview.isEmpty ? 0 : min(text.images.isEmpty ? 4 : 2, (Double(text.preview.count) / charactersPerLine).rounded(.up))
        return 56 + titleLines * 19 + previewLines * 20 + (text.images.isEmpty ? 0 : 124)
    }
}
