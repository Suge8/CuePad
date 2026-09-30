#if os(iOS)
import CueStore
import SwiftUI

/// 按下即反馈：整卡轻微下沉（0.97），行只铺一层底色。按下 90ms，松开 180ms，都是缓出；减弱动态效果时卡片不缩放。
struct PressableStyle: ButtonStyle {
    enum Kind { case card, row }
    var kind: Kind = .card
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .background { if kind == .row && pressed { palette.fill } }
            .scaleEffect(kind == .card && pressed && !reduceMotion ? 0.97 : 1)
            .animation(.easeOut(duration: pressed ? 0.09 : 0.18), value: pressed)
    }
}

/// 分段标题：名称 + 可选计数；读屏作为一个标题。
struct SectionHeader: View {
    let title: String
    var count: Int?
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink2)
            if let count { Text("\(count)").font(.footnote.monospacedDigit()).foregroundStyle(palette.ink3) }
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// 卡片与它的摘要。摘要在读数据时算好（Store 的执行体上），渲染与滚动时不在主线程解析正文。
nonisolated struct CardEntry: Identifiable, Sendable {
    let card: Card
    let text: CardText
    var id: UUID { card.id }

    init(_ card: Card) {
        self.card = card
        text = CardText(card.body)
    }
}

/// 一张卡的纸面行（今天流与搜索结果共用）：可选的项目与时间、标题、摘要、块数，右侧首图。
struct CardRow: View {
    let entry: CardEntry
    /// 标出所属项目（今天流）；nil 不标（搜索已按项目分组）。
    var project: Project??
    /// 命中的词（空格分隔），每个都标底色。
    var highlight = ""
    @Environment(\.palette) private var palette
    @Environment(\.zoomNamespace) private var zoom

    var body: some View {
        let card = entry.card, text = entry.text
        NavigationLink(value: Navigation.Route.card(card.id)) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        if let project {
                            Text(project?.name ?? "未归档")
                                .foregroundStyle(project.map { Palette.projectTint($0.color) } ?? palette.ink3)
                        }
                        Text(DateLabel.short(card.modifiedAt)).foregroundStyle(palette.ink3)
                        if text.blockCount > 1 { Text("\(text.blockCount) 块").foregroundStyle(palette.ink3) }
                    }
                    .font(.caption.weight(.medium))
                    Text(marked(text.title.nonEmpty ?? "空白卡片")).font(.headline).foregroundStyle(palette.ink).lineLimit(2)
                    if !text.preview.isEmpty {
                        Text(highlight.isEmpty ? VariableText.styled(text.preview, palette) : marked(text.preview))
                            .font(.subheadline).foregroundStyle(palette.ink2).lineLimit(2)
                    }
                }
                .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if let image = text.images.first {
                    Thumbnail(hash: image, height: 64, radius: 8).frame(width: 80)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper(radius: 16)
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(PressableStyle())
        .zoomSource(card.id, in: zoom)
        .contextMenu { CardActions(card: card, isGoal: false) }
    }

    private func marked(_ string: String) -> AttributedString {
        highlight.split(whereSeparator: \.isWhitespace).reduce(AttributedString(string)) { result, word in
            Highlight.matches(string, String(word), base: result)
        }
    }
}

extension View {
    /// 列表与表单铺在桌面色上，与书架、项目页同一底色。
    func deskBackground() -> some View { modifier(DeskBackground()) }
}

private struct DeskBackground: ViewModifier {
    @Environment(\.palette) private var palette
    func body(content: Content) -> some View { content.scrollContentBackground(.hidden).background(palette.desk) }
}

nonisolated extension String {
    /// 空串为 nil，便于 `?? 占位`。
    var nonEmpty: String? { isEmpty ? nil : self }
}
#endif
