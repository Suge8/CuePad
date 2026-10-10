import CueEditor
import CueStore
import CueText
import SwiftUI

/// 瀑布墙：列数随宽度变化，每张卡按实测高度放进当前最短的列，墙底边尽量齐。
struct MasonryLayout: Layout {
    var minColumnWidth: CGFloat = 220
    var maxColumns = 4
    var spacing: CGFloat = 16

    private static let idealWidth: CGFloat = 900

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // 问理想尺寸（nil）或最大尺寸（无穷）时给一个常规宽度：墙本身没有固有宽度，无穷宽会让列数换算崩溃
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? Self.idealWidth
        let frames = place(subviews, width: width)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, place(subviews, width: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    /// 墙没有文字基线可对齐；默认实现会逐个询问子视图，侧栏开合时每帧都付这笔账（时间分析里约 4%）。
    func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        let columns = max(1, min(maxColumns, Int((width + spacing) / (minColumnWidth + spacing))))
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var heights = Array(repeating: CGFloat(0), count: columns)
        return subviews.map { subview in
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let frame = CGRect(x: CGFloat(column) * (columnWidth + spacing), y: heights[column], width: columnWidth, height: height)
            heights[column] += height + spacing
            return frame
        }
    }
}

/// 卡片上的元信息：时间、发送目标，以及任务、浮回、资料标记。Mac 用固定小字，iOS 随动态字体。
struct CardMeta: View {
    let card: Card
    let text: CardText
    let lastTarget: String?
    let floated: Bool
    var font: Font = Typography.caption2
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Text(DateLabel.short(card.modifiedAt))
            // 第一个链接的域名：长段文字里一眼认出是哪张
            if let host = text.linkHost {
                Label(host, systemImage: "link").labelStyle(.titleAndIcon).lineLimit(1).truncationMode(.middle).layoutPriority(-1)
            }
            if let lastTarget { SentMark(target: lastTarget) }
            Spacer(minLength: 0)
            if card.isTask { Image(systemName: "checklist").help("任务").accessibilityLabel("任务") }
            if floated { Image(systemName: "arrow.up").help("刚从更早的灵感里拿回来").accessibilityLabel("刚从更早的灵感里拿回来") }
            if card.isPinned { Image(systemName: "books.vertical.fill").help("资料").accessibilityLabel("资料") }
        }
        .font(font)
        .foregroundStyle(palette.ink3)
    }
}

/// 发过的卡的标记：浅灰小纸飞机 + 目标名。没发过是默认状态，什么都不显示。卡片与列表共用这一种。
struct SentMark: View {
    let target: String

    var body: some View {
        Label(target, systemImage: "paperplane").labelStyle(.titleAndIcon).lineLimit(1)
            // 纸飞机是装饰：整体读作一句"已发给 …"；同项目时的"已发过"已经是完整文案。
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(target == SendCopy.sameProject ? target : "已发给 \(target)")
    }
}

/// 附件缩略图：按内容哈希从附件目录降采样读取，读不到时显示占位底色。
struct Thumbnail: View {
    let hash: String
    var height: CGFloat
    var radius: CGFloat = 10
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(palette.fill)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        // 深色下截图多是亮底，原样放在暗纸上刺眼：压暗一层
                        .overlay { if palette.dark { Color.black.opacity(0.14) } }
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder((palette.dark ? Color.white : .black).opacity(0.1)))
            .task(id: hash) {
                guard let url = services.store.files.fileURL(for: hash) else { return }
                let pixels = Int(height * 3 * scale)
                image = await Task.detached(priority: .utility) { Thumbnails.image(at: url, maxPixel: pixels) }.value
            }
    }
}

/// 预览文字里的 `{{变量}}`：墨色字垫深一级的底（`Palette.variable`）。
enum VariableText {
    static func styled(_ text: String, _ palette: Palette) -> AttributedString {
        var result = AttributedString(text)
        let utf16 = text.utf16
        for range in CueVariables.ranges(in: text, within: NSRange(location: 0, length: utf16.count)) {
            guard let swiftRange = Range(range, in: text), let attributed = Range(swiftRange, in: result) else { continue }
            result[attributed].foregroundColor = palette.variable
            result[attributed].backgroundColor = palette.variableBackground
        }
        return result
    }
}

/// 搜索命中的标法（灵感搜索、⌘K、Agent 页的会话搜索同一条）：搜索词按空格分开，每个词命中处加底色（大小写不敏感）。
enum Highlight {
    static func matches(_ text: String, _ query: String, base: AttributedString? = nil) -> AttributedString {
        var result = base ?? AttributedString(text)
        for term in query.split(whereSeparator: \.isWhitespace) {
            var searchStart = result.startIndex
            while searchStart < result.endIndex,
                  let range = result[searchStart...].range(of: term, options: .caseInsensitive) {
                result[range].backgroundColor = Palette.searchMatch
                searchStart = range.upperBound
            }
        }
        return result
    }
}

extension EnvironmentValues {
    /// 此刻的搜索词：列表里的会话行据此标出命中（`Highlight`）。
    @Entry var searchHighlight = ""
}

/// "更早"分组的标题：周是日期区间，月是"9 月"（跨年写"2025 年 12 月"）。
enum OlderGroupTitle {
    static func text(_ period: OlderGroup.Period, now: Date = .now, calendar: Calendar = .current) -> String {
        let chinese = Locale(identifier: "zh_CN")
        switch period {
        case .all:
            return "更早"
        case .week(let start):
            // 两端都写成"月/日"，与卡片行上的日期同一种写法
            let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
            let day = Date.FormatStyle.dateTime.month(.defaultDigits).day().locale(chinese)
            return "\(start.formatted(day)) – \(end.formatted(day))"
        case .sparseMonth(let start), .month(let start):
            // 同一年里只写月，跨年才带年份；数字两边各空一格，与"24 条灵感"同一种排法
            let month = calendar.component(.month, from: start)
            return calendar.isDate(start, equalTo: now, toGranularity: .year) ? "\(month) 月" : "\(calendar.component(.year, from: start)) 年 \(month) 月"
        }
    }
}
