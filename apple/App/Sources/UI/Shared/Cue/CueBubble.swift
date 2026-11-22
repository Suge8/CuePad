import CueText
import CueStore
import SwiftUI

enum CueBubble {
    #if os(macOS)
    static let padding = EdgeInsets(top: Spacing.group, leading: Spacing.block, bottom: Spacing.group, trailing: Spacing.block)
    #else
    static let padding = EdgeInsets(top: Spacing.group, leading: Spacing.inset, bottom: Spacing.group, trailing: Spacing.inset)
    #endif
    static let joinedGap = Spacing.tight
    #if os(macOS)
    static let cueWidth: CGFloat = 0.86
    #else
    static let cueWidth: CGFloat = 0.9
    #endif

    static func shape(_ edge: HorizontalEdge, joined: Bool = false) -> UnevenRoundedRectangle {
        let top = joined ? Radius.chip : Radius.sheet
        return switch edge {
        case .trailing: UnevenRoundedRectangle(topLeadingRadius: Radius.sheet, bottomLeadingRadius: Radius.sheet, bottomTrailingRadius: Radius.chip, topTrailingRadius: top)
        case .leading: UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: Radius.chip, bottomTrailingRadius: Radius.sheet, topTrailingRadius: Radius.sheet)
        }
    }

    /// 新说出的一颗淡入。贴着最新时滚动区先把上面的对话撑上去、让出它的位置（`ChatScroll.rise`，渲染端平移），让开了它再在终位淡入：
    /// 让的途中它还在回复框的玻璃后面，那时露出来会被折射成怪字。不缩放：有字的一块缩放时每帧重画字形（`Bubble.swift`）。
    static let arrival = AnyTransition.opacity.animation(Motion.fade.delay(Motion.Glide.duration))
}

struct CueSays: View {
    let message: CueMessage
    var task: UUID?
    var shots: [CueShown] = []
    var open: (PreviewOpening) -> Void = { _ in }
    var card = false
    var joined = false
    @ScaledMetric(relativeTo: .body) private var readingSpacing = Typography.readingLineSpacing
    @Environment(\.palette) private var palette
    @State private var selecting = false

    var body: some View {
        BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
            VStack(alignment: .leading, spacing: card ? Spacing.group : Spacing.item) {
                said
                if !shots.isEmpty { CueShots(shots: shots, group: message.id.uuidString, open: open) }
                if let task { CueTaskLine(task: task, message: message) }
            }
            .modifier(CueSaysSurface(card: card, joined: joined))
            .contextMenu { MessageActions(text: message.text, kind: .cue, selectText: { selecting = true }) }
        }
        #if os(iOS)
        .sheet(isPresented: $selecting) { SelectableTextSheet(text: message.text) }
        #endif
    }

    @ViewBuilder private var said: some View {
        let parts: (title: String?, body: String) = card ? Self.headline(message.text) : (nil, message.text)
        if let title = parts.title {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                Text(Self.inline(title)).font(Typography.reading.weight(.semibold)).foregroundStyle(palette.ink)
                    .lineSpacing(readingSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                if !parts.body.isEmpty { MarkdownText(source: parts.body).equatable() }
            }
        } else {
            MarkdownText(source: parts.body).equatable()
        }
    }

    private static func headline(_ text: String) -> (title: String?, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first.map(String.init), !first.isEmpty, !Self.isMarkup(first) else { return (nil, trimmed) }
        let rest = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (first, rest)
    }

    private static func inline(_ line: String) -> AttributedString {
        AttributedString(inlineMarkdown: line)
    }

    private static func isMarkup(_ line: String) -> Bool {
        if ["#", "-", "*", "+", ">", "`", "|", "!["].contains(where: line.hasPrefix) { return true }
        return line.prefix { $0.isNumber }.count > 0 && line.drop { $0.isNumber }.hasPrefix(".")
    }
}

private struct CueSaysSurface: ViewModifier {
    let card: Bool
    let joined: Bool

    func body(content: Content) -> some View {
        if card {
            content.padding(CueBubble.padding).frame(maxWidth: .infinity, alignment: .leading).paper(cornerRadius: Radius.sheet)
                #if os(iOS)
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: Radius.sheet))
                #endif
        } else {
            content.cueBubble(joined: joined)
                #if os(iOS)
                .contentShape(.contextMenuPreview, CueBubble.shape(.leading, joined: joined))
                #endif
        }
    }
}

extension View {
    /// 只铺一层底：不用卡片那套渐变、一线高光与描边（`paper()`）——气泡小，看不出差别，长对话滚动时每颗多出的层逐帧都要更新；
    /// 增强对比度时才描边（`Palette.bubbleEdge`）。
    func cueBubble(joined: Bool) -> some View {
        modifier(CueBubbleSurface(shape: CueBubble.shape(.leading, joined: joined)))
    }
}

private struct CueBubbleSurface: ViewModifier {
    let shape: UnevenRoundedRectangle
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.padding(CueBubble.padding).background(palette.paper, in: shape).overlay { if let edge = palette.bubbleEdge { shape.strokeBorder(edge) } }
    }
}
