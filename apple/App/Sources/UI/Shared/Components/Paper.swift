import CueEditor
import CueStore
import CueText
import SwiftUI

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

struct CardMeta: View {
    let card: Card
    let text: CardText
    let lastTarget: String?
    let floated: Bool
    var font: Font = Typography.caption2
    @Environment(\.palette) private var palette

    var body: some View {
        let changed = Text(DateLabel.short(card.modifiedAt)).fixedSize()
        HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
            if let host = text.linkHost {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.item) { changed; Text(host) }.fixedSize()
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        changed
                        Text(host).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)
            } else { changed }
            if let lastTarget { SentMark(target: lastTarget) }
            Spacer(minLength: 0)
            if text.files > 0 { AttachmentMark(count: text.files) }
            if card.isTask { Image(.task).help("任务").iconLabel("任务") }
            if floated { Image(.floated).help("刚从更早的灵感里拿回来").iconLabel("刚从更早的灵感里拿回来") }
            if card.isPinned { Image(.pin).help("已置顶").iconLabel("已置顶") }
        }
        .font(font)
        .foregroundStyle(palette.ink3)
    }
}

/// 图片在预览里看得见的地方只数文件（`CardText.files`），没有预览的行数全部附件。
struct AttachmentMark: View {
    let count: Int

    var body: some View {
        Group {
            if count > 1 {
                Label { Text(verbatim: "\(count)").monospacedDigit() } icon: { Image(.attachment) }.labelStyle(.titleAndIcon)
            } else {
                Image(.attachment)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("带 \(count) 个附件")
    }
}

struct SentMark: View {
    let target: String

    var body: some View {
        Label(target, icon: .handOff).labelStyle(.titleAndIcon).lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(target == SendCopy.sameProject ? Text(target) : Text("已发给 \(target)"))
    }
}

struct Thumbnail: View {
    let hash: String
    var height: CGFloat
    var cornerRadius: CGFloat = Radius.block
    var fitWidth: CGFloat?
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?
    @State private var place = AttachmentPlace.unchecked

    private struct Request: Equatable {
        let hash: String
        let height: CGFloat
        let scale: CGFloat
        let place: AttachmentPlace
    }

    var body: some View {
        Rectangle()
            .fill(palette.fill)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: fitWidth == nil ? .fill : .fit)
                        // 深色下截图多是亮底，原样放在暗纸上刺眼：压暗一层
                        .overlay { palette.mediaDim }
                }
            }
            .frame(width: width, height: height)
            .frame(maxWidth: fitWidth == nil ? .infinity : nil)
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(palette.hair))
            .observingArrival(of: hash, in: services, into: $place)
            .task(id: Request(hash: hash, height: height, scale: scale, place: place)) {
                guard place != .unchecked else { return }
                image = await Self.picture(hash, height: height, scale: scale, in: services.store.files)
            }
    }

    /// 全屏页飞出与占位用的也是它（你的话里带的图、点名图），同一份不另解。不在本机为 nil。
    static func picture(_ hash: String, height: CGFloat, scale: CGFloat, in files: AttachmentFiles) async -> CGImage? {
        guard let url = files.fileURL(for: hash) else { return nil }
        return await decode(url, pixels: Int(height * 3 * scale))
    }

    @concurrent private static func decode(_ url: URL, pixels: Int) async -> CGImage? { Thumbnails.image(at: url, maxPixel: pixels) }

    private var width: CGFloat? {
        guard let fitWidth else { return nil }
        guard let image, image.height > 0 else { return height }
        return min(fitWidth, height * CGFloat(image.width) / CGFloat(image.height))
    }
}

enum VariableText {
    static func styled(_ text: String, _ palette: Palette) -> AttributedString {
        var result = AttributedString(text)
        let utf16 = text.utf16
        for range in CueVariables.ranges(in: text, within: NSRange(location: 0, length: utf16.count)) {
            guard let swiftRange = Range(range, in: text), let attributed = Range(swiftRange, in: result) else { continue }
            result[attributed].foregroundColor = palette.ink
            result[attributed].backgroundColor = palette.fill
        }
        return result
    }
}

/// 灵感搜索、⌘K、Agent 页的会话搜索同一条。
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
    @Entry var searchHighlight = ""
}

enum OlderGroupTitle {
    static func text(_ period: OlderGroup.Period, now: Date = .now, calendar: Calendar = .current) -> String {
        switch period {
        case .all:
            return String(localized: "更早")
        case .week(let start):
            let end = calendar.date(byAdding: .day, value: 6, to: start) ?? start
            return "\(start.formatted(DateLabel.monthDay)) – \(end.formatted(DateLabel.monthDay))"
        case .sparseMonth(let start), .month(let start):
            let sameYear = calendar.isDate(start, equalTo: now, toGranularity: .year)
            return start.formatted(sameYear ? Date.FormatStyle.dateTime.month(.abbreviated) : Date.FormatStyle.dateTime.year().month(.abbreviated))
        }
    }
}
