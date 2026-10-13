import SwiftUI

/// Pi 回答的 Markdown 渲染（块见 `MarkdownBlock`）：相邻的非表格块排成**一个** `Text`（`AttributedString`），所以一条回答的段落、列表、标题、引用、
/// 代码块是一个选择单元：双击选词、三击选段、⌘A、拖着连选、右键复制都是系统的文字选择，不用每块各开一套。表格单独一块、整张横向滚，自己可选（一格一个选择单元，选不到表格外；
/// 表格前后的正文是两段 `Text`，也不连在一起）。
/// `Text` 只认字体、颜色、底色、链接、下划线这类行内属性，不认段落缩进与段距，所以结构用字符摆：块与块之间隔一个小字号的空行当段距，
/// 列表项是缩进的空格加序号，引用前一个竖条字符，代码块是等宽字加底色；列表项折行时回到左边，不悬挂缩进。
/// 行内：链接加下划线（强调色是墨，不画线就认不出），行内代码垫一层淡底。表格只画细线：表头淡底，行间一道线。
/// 批注过的那几处（`notes`，见 `ReplyNote`）垫选中色的浅底、下面一道签名色的点线，是一个链接：点它打开那条批注。
struct MarkdownText: View, Equatable {
    let source: String
    var notes: [ReplyNote] = []
    @Environment(\.palette) private var palette
    @Environment(\.readingColumnBleeds) private var columnBleeds

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.source == rhs.source && lhs.notes == rhs.notes }

    /// 每段可选文字（相邻的非表格块排成的那一个 `Text`）渲染出来的字，按先后：批注按它认出选区在哪条回答的第几段（`ReplyNote.run`）。
    static func proseTexts(_ source: String) -> [String] {
        Run.of(source, Palette(.light), notes: []).compactMap { run in
            if case .prose(let text) = run { String(text.characters) } else { nil }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Run.of(source, palette, notes: notes).enumerated()), id: \.offset) { _, run in
                switch run {
                case .prose(let text):
                    // 中文正文行距放开一点：长回答是会话页的主角，读起来不挤
                    Text(text).lineSpacing(Typography.readingLineSpacing).selectable()
                case .table(let table):
                    // 表格带着自己的边框整张滚；阅读栏贴着屏幕边（手机）时滚动可以越过页边距滑到屏幕边，栏两边有空白时收在栏内
                    // 贴着屏幕边时被屏幕边切开的那一列本身就看得出还有；收在栏内时右缘淡出
                    ScrollView(.horizontal) { MarkdownTableView(table: table).selectable() }
                        .scrollIndicatorsFlash(onAppear: true)
                        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                        .scrollClipDisabled(columnBleeds)
                        .modifier(MoreToTheRight(enabled: !columnBleeds))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// 回答里相邻的非表格块是一段文字，表格自成一块。
    private enum Run {
        case prose(AttributedString)
        case table(MarkdownTable)

        static func of(_ source: String, _ palette: Palette, notes: [ReplyNote]) -> [Run] {
            var runs: [Run] = []
            var pending: [MarkdownBlock] = []
            var prose = 0
            func flush() {
                guard !pending.isEmpty else { return }
                var text = MarkdownText.attributed(pending, palette)
                for note in notes where note.run == prose { MarkdownText.mark(note, in: &text, palette) }
                runs.append(.prose(text))
                prose += 1
                pending = []
            }
            for block in MarkdownBlock.parse(source) {
                if case .table(let table) = block {
                    flush()
                    runs.append(.table(table))
                } else {
                    pending.append(block)
                }
            }
            flush()
            return runs
        }
    }

    /// 一串块排成一段带属性的文字。块与块之间的段距是一个换行加一个小字号的空行（`Text` 不认段距）；连着的列表项只隔一个换行。
    static func attributed(_ blocks: [MarkdownBlock], _ palette: Palette) -> AttributedString {
        func styled(_ source: String, font: Font, color: Color, background: Color? = nil) -> AttributedString {
            var text = inline(source, palette)
            // 行内代码已经带了自己的字体与底色，其余按这一块的
            for run in text.runs where run.font == nil { text[run.range].font = font }
            text.foregroundColor = color
            if let background { text.backgroundColor = background }
            return text
        }
        func newline(gap: CGFloat? = nil) -> AttributedString {
            var line = AttributedString("\n")
            line.font = .system(size: 1)
            guard let gap else { return line }
            var spacer = AttributedString("\n")
            spacer.font = .system(size: gap)
            return line + spacer
        }
        var result = AttributedString()
        var previous: MarkdownBlock?
        for block in blocks {
            if let previous {
                switch (previous, block) {
                case (.item, .item): result += newline()
                case (_, .heading): result += newline(gap: 8)
                default: result += newline(gap: 2)
                }
            }
            previous = block
            switch block {
            case .paragraph(let text): result += styled(text, font: Typography.reading, color: palette.ink)
            case .heading(let level, let text):
                result += styled(text, font: level <= 2 ? Typography.readingHeading : Typography.reading.weight(.semibold), color: palette.ink)
            case .item(let marker, let text, let depth):
                var lead = AttributedString(String(repeating: "\u{2003}\u{2003}", count: depth) + (marker == "•" && depth > 0 ? "◦" : marker) + "\u{2002}")
                lead.font = Typography.reading
                lead.foregroundColor = palette.ink3
                result += lead + styled(text, font: Typography.reading, color: palette.ink)
            case .quote(let text):
                var bar = AttributedString("▎ ")
                bar.font = Typography.reading
                bar.foregroundColor = palette.ink3
                result += bar + styled(text, font: Typography.reading, color: palette.ink2)
            case .code(let code):
                // 空行也要有一个字，底色才连得上
                let lines = code.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? " " : String($0) }
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

    private static func mark(_ note: ReplyNote, in text: inout AttributedString, _ palette: Palette) {
        guard let range = Range(note.range, in: text), String(text[range].characters) == note.quote else { return }
        text[range].backgroundColor = palette.selection
        text[range].underlineStyle = Text.LineStyle(pattern: .dot, color: palette.signature)
        text[range].link = note.url
    }

    static func inline(_ text: String, _ palette: Palette) -> AttributedString {
        var string = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
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

/// 对话里成块的东西（代码块、表格、一轮回答上方的工具注脚）同一套圆角、底色（`Palette.fill`）与内边距。
enum ChatBlock {
    static let radius: CGFloat = 12
    static let inset: CGFloat = 12
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }
}

/// 表格：按列排开，每格最宽 `cellWidth`、超过就换行；列按 Markdown 的对齐（数字列常是右对齐）。
private struct MarkdownTableView: View {
    let table: MarkdownTable
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
    }

    private func cells(_ texts: [String], header: Bool) -> some View {
        ForEach(Array(texts.enumerated()), id: \.offset) { column, text in
            let alignment = table.alignments[column]
            CappedWidth(cap: Self.cellWidth) {
                Text(MarkdownText.inline(text, palette))
                    .font(header ? Typography.secondary.weight(.semibold) : Typography.secondary)
                    .foregroundStyle(palette.ink)
                    .multilineTextAlignment(alignment.text)
            }
            .padding(.horizontal, ChatBlock.inset).padding(.vertical, 8)
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
/// 横向滚动里没有建议宽度，它会把子视图按一整行排开再截断。
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

/// 横向滚动的块右边还有内容时，右缘 24pt 淡出，看得出能往右滑；滑到头就不淡。只改遮罩，不影响排版。
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
                    LinearGradient(colors: [.black, .black.opacity(more ? 0 : 1)], startPoint: .leading, endPoint: .trailing)
                        .frame(width: Self.width)
                }
            }
    }
}
