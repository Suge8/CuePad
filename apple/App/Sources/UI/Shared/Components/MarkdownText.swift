import CueText
import SwiftUI

/// Pi 回答的 Markdown 渲染（块见 `MarkdownBlock`）：相邻的非表格块排成**一段**带属性的文字（`AttributedString`），交给 `Paragraphs`——
/// Mac 上是一个 `Text`，一条回答的段落、列表、标题、引用、代码块是一个选择单元：双击选词、三击选段、⌘A、拖着连选、右键复制都是系统的文字选择，
/// 不用每块各开一套；iOS 上逐段一个 `Text`（整串一个时排版随段数成倍变慢，见 `Paragraphs`）。表格单独一块、整张横向滚，自己可选（一格一个选择单元，选不到表格外；
/// 表格前后的正文是两段，也不连在一起）。
/// `Text` 只认字体、颜色、底色、链接、下划线这类行内属性，不认段落缩进与段距，所以结构用字符摆：块与块之间隔一个小字号的空行当段距，
/// 列表项是缩进的空格加序号，引用前一个竖条字符，代码块是等宽字加底色；回答里列表项折行时回到左边，不悬挂缩进：
/// 悬挂缩进要每项一个视图（`Text` 不认段落样式的 headIndent，Xcode 27 实测），Mac 上一条回答就不能连着拖选了，连选更要紧。
/// 文字可选（`selectable()`）给每个 `Text` 多一个交互视图与一份 TextKit 版面，约占滚动一帧的一成半到两成半；表格一格一个，表格多的回答每帧更贵。
/// 否决的方案：gonzalezreal/textual 0.5.0（能跨块选择，但 macOS 上整段排进一帧的短回答选不上，上游修复 #71 没合；内容更新时选区崩溃 #87；
/// 还带数学公式与语法高亮两个用不到的依赖）。
struct MarkdownText: View, Equatable {
    nonisolated enum Style: Equatable { case reply, document }

    let source: String
    var notes: [ReplyNote] = []
    var style = Style.reply
    @Environment(\.palette) private var palette
    @Environment(\.readingColumnBleeds) private var columnBleeds

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.source == rhs.source && lhs.notes == rhs.notes && lhs.style == rhs.style }

    /// 批注按它认出选区在哪条回答的第几段（`ReplyNote.run`）。
    static func proseTexts(_ source: String) -> [String] {
        Run.of(source, Palette(dark: false), notes: [], style: .reply).compactMap { run in
            if case .prose(let text) = run { String(text.characters) } else { nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            ForEach(Array(Run.of(source, palette, notes: notes, style: style).enumerated()), id: \.offset) { _, run in
                switch run {
                case .prose(let text):
                    Paragraphs(text, lineSpacing: Typography.readingLineSpacing)
                case .table(let block):
                    if case .table(let table) = block.content {
                        ScrollView(.horizontal) { MarkdownBlockFrame(block: block) { MarkdownTableView(table: table).selectable() } }
                            .scrollIndicatorsFlash(onAppear: true)
                            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                            .scrollClipDisabled(columnBleeds)
                            .modifier(MoreToTheRight(enabled: !columnBleeds))
                    }
                case .list(let items):
                    ListRows(items: items)
                case .code(let block):
                    if case .code(let code) = block.content {
                        MarkdownBlockFrame(block: block) {
                            ScrollView(.horizontal) {
                                Text(verbatim: code).font(Typography.code).foregroundStyle(palette.ink).fixedSize().textSelection(.enabled)
                                    .padding(ChatBlock.inset)
                            }
                            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                            .background(palette.fill, in: ChatBlock.shape)
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private enum Run {
        case prose(AttributedString)
        case table(MarkdownBlock)
        case code(MarkdownBlock)
        case list([MarkdownBlock])

        static func of(_ source: String, _ palette: Palette, notes: [ReplyNote], style: Style) -> [Run] {
            var runs: [Run] = []
            var pending: [MarkdownBlock] = []
            var prose = 0
            var items: [MarkdownBlock] = []
            func flushList() {
                guard !items.isEmpty else { return }
                runs.append(.list(items))
                items = []
            }
            func flushProse() {
                guard !pending.isEmpty else { return }
                var text = MarkdownText.attributed(pending, palette, style: style)
                for note in notes where note.run == prose { MarkdownText.mark(note, in: &text, palette) }
                runs.append(.prose(text))
                prose += 1
                pending = []
            }
            func flush() {
                flushList()
                flushProse()
            }
            for block in MarkdownBlock.parse(source) {
                if case .table = block.content {
                    flush()
                    runs.append(.table(block))
                } else if style == .document, case .code = block.content {
                    flush()
                    runs.append(.code(block))
                } else if style == .document, block.isList {
                    flushProse()
                    items.append(block)
                } else {
                    flushList()
                    pending.append(block)
                }
            }
            flush()
            return runs
        }
    }

    static func attributed(_ blocks: [MarkdownBlock], _ palette: Palette, style: Style = .reply) -> AttributedString {
        func styled(_ source: String, font: Font, color: Color, background: Color? = nil) -> AttributedString {
            var text = inline(source, palette)
            for run in text.runs where run.font == nil { text[run.range].font = font }
            text.foregroundColor = color
            if let background { text.backgroundColor = background }
            return text
        }
        func newline(gap: CGFloat? = nil) -> AttributedString {
            var line = AttributedString("\n")
            line.font = Typography.gap(1)
            guard let gap else { return line }
            var spacer = AttributedString("\n")
            spacer.font = Typography.gap(gap)
            return line + spacer
        }
        var result = AttributedString()
        var previous: MarkdownBlock?
        for block in blocks {
            if let previous {
                if previous.isList && block.isList { result += newline() }
                else if case .heading = block.content { result += newline(gap: Spacing.item) }
                else { result += newline(gap: Spacing.hair) }
            }
            previous = block
            var lead = AttributedString(block.textIndent)
            lead.font = Typography.reading
            lead.foregroundColor = palette.ink3
            result += lead
            switch block.content {
            case .paragraph(let text): result += styled(text, font: Typography.reading, color: palette.ink)
            case .heading(let level, let text):
                result += styled(text, font: Self.heading(level, style), color: palette.ink)
            case .quote(let text):
                var bar = AttributedString("▎ ")
                bar.font = Typography.reading
                bar.foregroundColor = palette.ink3
                result += bar + styled(text, font: Typography.reading, color: palette.ink2)
            case .code(let code):
                // 空行也要有一个字，底色才连得上
                let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map { ($0.isEmpty ? " " : String($0)) }
                var block = AttributedString(lines.joined(separator: "\n"))
                block.font = Typography.code
                block.foregroundColor = palette.ink
                block.backgroundColor = palette.fill
                result += block
            case .rule:
                var rule = AttributedString("———")
                rule.font = Typography.reading
                rule.foregroundColor = palette.hair
                result += rule
            case .table: break
            }
        }
        return result
    }

    private static func heading(_ level: Int, _ style: Style) -> Font {
        switch (style, level) {
        case (.document, 1): Typography.documentTitle
        case (.document, 2): Typography.documentHeading
        case (.document, 3), (.reply, ...2): Typography.readingHeading
        default: Typography.reading.weight(.semibold)
        }
    }

    private static func mark(_ note: ReplyNote, in text: inout AttributedString, _ palette: Palette) {
        guard let range = Range(note.range, in: text), String(text[range].characters) == note.quote else { return }
        text[range].backgroundColor = palette.selection
        text[range].underlineStyle = Text.LineStyle(pattern: .dot, color: palette.signature)
        text[range].link = note.url
    }

    static func inline(_ text: String, _ palette: Palette) -> AttributedString {
        styledInline(AttributedString(inlineMarkdown: text), palette)
    }

    static func styledInline(_ text: AttributedString, _ palette: Palette) -> AttributedString {
        var string = text
        for run in string.runs {
            if run.link != nil { string[run.range].underlineStyle = .single }
            if run.inlinePresentationIntent?.contains(.code) == true {
                string[run.range].backgroundColor = palette.fill
                // 等宽字在同字号下比中文显得大：小一档，句子中间不鼓出一块
                string[run.range].font = Typography.inlineCode
            }
        }
        return string
    }
}

private struct ListRows: View {
    let items: [MarkdownBlock]
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .body) private var marker: CGFloat = 24

    var body: some View {
        VStack(alignment: .leading, spacing: Typography.readingLineSpacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                if let list = item.list.last {
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(verbatim: list.marker).font(Typography.reading).foregroundStyle(palette.ink3)
                            .frame(width: marker, alignment: .leading)
                            .opacity(item.startsItem ? 1 : 0).readerHidden(!item.startsItem)
                        Text(MarkdownText.attributed([MarkdownBlock(content: item.content)], palette, style: .document))
                            .lineSpacing(Typography.readingLineSpacing).selectable()
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.depth) * marker)
                }
            }
        }
        .padding(.vertical, Spacing.item)
    }
}

enum ChatBlock {
    static let inset = Spacing.group
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.block) }
}

struct MarkdownTableView: View {
    let table: MarkdownTable
    var images: [String: CGImage] = [:]
    var exporting = false
    @Environment(\.palette) private var palette

    private static let cellWidth: CGFloat = 240

    var body: some View {
        let shape = ChatBlock.shape
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow { cells(table.header, header: true) }
            ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                Rectangle().fill(palette.hair).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                GridRow { cells(row, header: false) }
            }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(palette.hair))
        // 表格的宽只由各格定（每格最宽 `cellWidth`）：横向滚动区量高度时不给宽（按理想宽排），摆放时却可能给可见宽——
        // 长对话首次打开时就是这样，各列被挤窄、格里换行，画出来比量好的高，压到下面的回答上，滚一下重排才好。
        // 不接受给的宽，量与摆就是同一张表
        .fixedSize(horizontal: true, vertical: false)
    }

    private func cells(_ texts: [String], header: Bool) -> some View {
        ForEach(Array(texts.enumerated()), id: \.offset) { column, text in
            let alignment = table.alignments[column]
            CappedWidth(cap: Self.cellWidth) {
                MarkdownMediaView(source: text, images: images, exporting: exporting)
                    .font(header ? Typography.secondary.weight(.semibold) : Typography.secondary)
                    .foregroundStyle(palette.ink)
                    .multilineTextAlignment(alignment.text)
            }
            .padding(.horizontal, ChatBlock.inset).padding(.vertical, Spacing.item)
            .frame(maxWidth: .infinity, maxHeight: header ? .infinity : nil, alignment: alignment.frame)
            .background(header ? palette.fill : .clear)
            .gridColumnAlignment(alignment.horizontal)
        }
    }
}

private extension MarkdownTable.Alignment {
    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frame: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var text: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// 只有一个子视图：按它的理想宽度排，但不超过 `cap`（超过就在这个宽度里换行）。`.frame(maxWidth:)` 做不到：
/// 表格不接受给的宽（`fixedSize`），格子量的时候没有建议宽度，它会把子视图按一整行排开再截断。
private struct CappedWidth: Layout {
    let cap: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let width = min(child.sizeThatFits(.unspecified).width, proposal.width ?? .infinity, cap)
        return child.sizeThatFits(ProposedViewSize(width: width, height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

private struct MoreToTheRight: ViewModifier {
    var enabled = true
    @State private var more = false

    private static let width: CGFloat = 24

    func body(content: Content) -> some View {
        // 不淡时连遮罩也不挂：遮罩会切掉越过栏边的内容
        if enabled { faded(content) } else { content }
    }

    private func faded(_ content: Content) -> some View {
        content
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 1
            } action: { _, more in
                self.more = more
            }
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    LinearGradient(colors: [.black, more ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.width)
                }
            }
    }
}
