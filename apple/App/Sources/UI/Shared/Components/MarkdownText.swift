import SwiftUI

/// Pi 回答的 Markdown 渲染（块见 `MarkdownBlock`）：块内用系统的行内 Markdown，链接加下划线（强调色是墨，不画线就认不出），
/// 行内代码垫一层淡底。标题分两级字号；列表保留缩进与序号；引用左侧一道竖线；代码块与表格等宽或按列排开，宽了横向滚，
/// 出现时闪一下滚动条提示还有内容。表格只画细线：表头淡底，行间一道线。
struct MarkdownText: View {
    let source: String
    @Environment(\.palette) private var palette
    @Environment(\.readingColumnBleeds) private var columnBleeds

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { index, block in
                // 选择按块开（一个块是一个独立的文本，选区本来就不跨块），悬停时只重建指针下的这一块
                self.block(block)
                    .selectableOnHover()
                    // 标题与上一块拉开一点，标出新的一节
                    .padding(.top, index > 0 && block.isHeading ? 6 : 0)
            }
        }
        // 中文正文行距放开一点：长回答是会话页的主角，读起来不挤
        .lineSpacing(Typography.readingLineSpacing)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func block(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Self.inline(text, palette)).font(Typography.reading).foregroundStyle(palette.ink)
        case .heading(let level, let text):
            Text(Self.inline(text, palette)).font(level <= 2 ? Typography.readingHeading : Typography.reading.weight(.semibold))
                .foregroundStyle(palette.ink)
                .accessibilityAddTraits(.isHeader)
        case .item(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker == "•" && depth > 0 ? "◦" : marker).font(Typography.reading.monospacedDigit()).foregroundStyle(palette.ink3)
                Text(Self.inline(text, palette)).font(Typography.reading).foregroundStyle(palette.ink)
            }
            .padding(.leading, CGFloat(depth) * 18)
        case .quote(let text):
            Text(Self.inline(text, palette)).font(Typography.reading).foregroundStyle(palette.ink2)
                .padding(.leading, 14)
                .overlay(alignment: .leading) { Capsule().fill(palette.ink3.opacity(0.5)).frame(width: 3) }
        case .code(let code):
            // 底色是固定的框，代码在框里滚
            ScrollView(.horizontal) {
                Text(code).font(Typography.code).foregroundStyle(palette.ink).padding(ChatBlock.inset)
            }
            .scrollIndicatorsFlash(onAppear: true)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .modifier(MoreToTheRight())
            .background(palette.fill, in: ChatBlock.shape)
        case .table(let table):
            // 表格带着自己的边框整张滚；阅读栏贴着屏幕边（手机）时滚动可以越过页边距滑到屏幕边，栏两边有空白时收在栏内
            // 贴着屏幕边时被屏幕边切开的那一列本身就看得出还有；收在栏内时右缘淡出
            ScrollView(.horizontal) { MarkdownTableView(table: table) }
                .scrollIndicatorsFlash(onAppear: true)
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                .scrollClipDisabled(columnBleeds)
                .modifier(MoreToTheRight(enabled: !columnBleeds))
        case .rule:
            Rectangle().fill(palette.hair).frame(height: 1).padding(.vertical, 4)
        }
    }

    static func inline(_ text: String, _ palette: Palette) -> AttributedString {
        var string = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
        for run in string.runs {
            if run.link != nil { string[run.range].underlineStyle = .single }
            if run.inlinePresentationIntent?.contains(.code) == true { string[run.range].backgroundColor = palette.fill }
        }
        return string
    }
}

private extension MarkdownBlock {
    var isHeading: Bool { if case .heading = self { true } else { false } }
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
