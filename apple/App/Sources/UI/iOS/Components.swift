#if os(iOS)
import CueStore
import SwiftUI

/// 列表行的按下反馈：铺一层底色（整卡用共用的 `CardPressStyle`）。按下即出现，松开 160ms 淡去。
struct RowPressStyle: ButtonStyle {
    @Environment(\.palette) private var palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background { if configuration.isPressed { palette.fill } }
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
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
        var text = CardText(card.body)
        text.title = text.title.textGlyphs
        text.preview = text.preview.textGlyphs
        self.text = text
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
                        Text(marked(text.preview)).font(.subheadline).foregroundStyle(palette.ink2).lineLimit(2)
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
        .buttonStyle(CardPressStyle())
        .zoomSource(card.id, in: zoom)
        .contextMenu { CardActions(card: card) }
    }

    /// 变量照常标色，搜索词再叠一层命中底色。
    private func marked(_ string: String) -> AttributedString {
        highlight.split(whereSeparator: \.isWhitespace).reduce(VariableText.styled(string, palette)) { result, word in
            Highlight.matches(string, String(word), base: result)
        }
    }
}

extension View {
    /// 列表与表单铺在桌面色上，与书架、项目页同一底色。
    func deskBackground() -> some View { modifier(DeskBackground()) }

    /// 主按钮：实心墨色玻璃，字用与墨色相反的颜色（深色模式下墨色是浅的，系统默认的白字会看不见）。
    func prominentButton() -> some View { modifier(ProminentButton()) }

    /// 底部玻璃（标签栏、随手记栏）之下铺实底，之上 48pt 渐隐到桌面色：滚动内容在碰到玻璃前就淡出，玻璃下不叠字。
    /// iPhone 每页底部都有标签栏；宽 iPad 只有项目页一类（`capturePage`）底部浮着随手记栏，右侧面板里没有玻璃。
    func bottomEdgeFade(capturePage: Bool = false) -> some View { modifier(BottomEdgeFade(capturePage: capturePage)) }

    /// 长按项目（书架、侧栏）：抬起这一项作预览，菜单是共用的项目操作。nil（未归档）没有菜单。
    func projectActions(_ project: Project?, radius: CGFloat) -> some View { modifier(ProjectContextMenu(project: project, radius: radius)) }
}

private struct ProjectContextMenu: ViewModifier {
    let project: Project?
    let radius: CGFloat
    @Environment(Navigation.self) private var navigation

    func body(content: Content) -> some View {
        if let project {
            content
                .contentShape(.contextMenuPreview, .rect(cornerRadius: radius, style: .continuous))
                .contextMenu { ProjectActions(project: project) { navigation.projectForm = .init(project: project) } }
        } else {
            content
        }
    }
}

private struct BottomEdgeFade: ViewModifier {
    let capturePage: Bool
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    private static let fade: CGFloat = 48

    @ViewBuilder func body(content: Content) -> some View {
        if navigation.layout == .tabs || capturePage { faded(content) } else { content }
    }

    private func faded(_ content: Content) -> some View {
        content
            .contentMargins(.bottom, Self.fade, for: .scrollContent)
            .overlay(alignment: .bottom) {
                GeometryReader { proxy in
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        LinearGradient(colors: [palette.desk.opacity(0), palette.desk], startPoint: .top, endPoint: .bottom)
                            .frame(height: Self.fade)
                        palette.desk.frame(height: proxy.safeAreaInsets.bottom)
                    }
                    .ignoresSafeArea(edges: .bottom)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

private struct ProminentButton: ViewModifier {
    @Environment(\.palette) private var palette
    func body(content: Content) -> some View { content.buttonStyle(.glassProminent).foregroundStyle(palette.onAccent) }
}

private struct DeskBackground: ViewModifier {
    @Environment(\.palette) private var palette
    func body(content: Content) -> some View { content.scrollContentBackground(.hidden).background(palette.desk) }
}

nonisolated extension String {
    /// 空串为 nil，便于 `?? 占位`。
    var nonEmpty: String? { isEmpty ? nil : self }

    /// ↩ ↪ 这类箭头在 iOS 上默认画成彩色 emoji 按键：加文字样式选择符，按普通字形显示。
    var textGlyphs: String {
        guard contains(where: { Self.emojiDefaulted.contains($0) }) else { return self }
        return String(flatMap { Self.emojiDefaulted.contains($0) ? [$0, "\u{FE0E}"] : [$0] })
    }

    private static let emojiDefaulted: Set<Character> = ["↩", "↪", "⤴", "⤵", "↔", "↕"]
}
#endif
