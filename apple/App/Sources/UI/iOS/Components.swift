#if os(iOS)
import CueStore
import SwiftUI
import UIKit

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

/// 一张卡的纸面行（搜索结果与输入框的卡片选择共用）：可选的项目与时间、标题、摘要，右侧首图。
struct CardRow: View {
    let entry: CardEntry
    /// 标出所属项目（卡片选择里不属于本项目的那组）；nil 不标（搜索已按项目分组）。
    var project: Project??
    /// 命中的词（空格分隔），每个都标底色。
    var highlight = ""
    /// 点一下选中这张卡（卡片选择）；nil 时点开卡片，长按是卡片操作。
    var pick: ((Card) -> Void)?
    @Environment(\.palette) private var palette
    @Environment(\.zoomNamespace) private var zoom

    var body: some View {
        if let pick {
            Button { pick(entry.card) } label: { row }.buttonStyle(CardPressStyle())
        } else {
            NavigationLink(value: Navigation.Route.card(entry.card.id)) { row }
                .buttonStyle(CardPressStyle())
                .zoomSource(entry.card.id, in: zoom)
                .contextMenu { CardActions(card: entry.card) }
        }
    }

    private var row: some View {
        let card = entry.card, text = entry.text
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    if let project {
                        Text(project?.name ?? "未归档")
                            .foregroundStyle(project.map { Palette.projectTint($0.color) } ?? palette.ink3)
                    }
                    Text(DateLabel.short(card.modifiedAt)).foregroundStyle(palette.ink3)
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

    /// 独占底部的页（卡片纸页、Pi 会话页）：在屏幕上时 iPhone 收起标签栏（见 `Navigation.bottomPages`）。
    func ownsBottomEdge() -> some View { modifier(BottomEdgeOwner()) }

    /// 选项少的切换：平时是分段控件；辅助字号下分段控件不随字号放大，改成跟随字号的菜单按钮。
    func scalingPickerStyle() -> some View { modifier(ScalingPickerStyle()) }

    /// 长按项目（书架、侧栏）：抬起这一项作预览，菜单是共用的项目操作，有 Pi 会话时菜单标题写明它的状态
    /// （说清旁边那个点是什么意思）。nil（未归档）没有菜单。
    func projectActions(_ project: Project?, radius: CGFloat, pi: PiShown?) -> some View {
        modifier(ProjectContextMenu(project: project, radius: radius, pi: pi))
    }
}

private struct ProjectContextMenu: ViewModifier {
    let project: Project?
    let radius: CGFloat
    let pi: PiShown?
    @Environment(Navigation.self) private var navigation

    func body(content: Content) -> some View {
        if let project {
            content
                .contentShape(.contextMenuPreview, .rect(cornerRadius: radius, style: .continuous))
                .contextMenu {
                    let actions = ProjectActions(project: project) { navigation.projectForm = .init(project: project) }
                    if let pi { Section(pi.presence) { actions } } else { actions }
                }
        } else {
            content
        }
    }
}

private struct BottomEdgeOwner: ViewModifier {
    @Environment(Navigation.self) private var navigation
    @State private var counted = false

    func body(content: Content) -> some View {
        content.background {
            PageAppearance { visible in
                guard visible != counted else { return }
                counted = visible
                navigation.bottomPages += visible ? 1 : -1
            }
        }
    }
}

/// 页面在屏幕上（含推入、返回途中）的起止，跟 UIKit 的出现回调走：手势返回在手指开始拖时就收到"将消失"，
/// 取消返回再收到"将出现"。SwiftUI 的导航路径要到松手才变，跟它走标签栏会晚出现。
private struct PageAppearance: UIViewControllerRepresentable {
    let changed: (Bool) -> Void

    func makeUIViewController(context: Context) -> Probe { Probe() }
    func updateUIViewController(_ probe: Probe, context: Context) { probe.changed = changed }

    final class Probe: UIViewController {
        var changed: (Bool) -> Void = { _ in }
        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            changed(true)
        }
        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            changed(false)
        }
    }
}

private struct ScalingPickerStyle: ViewModifier {
    @Environment(\.dynamicTypeSize) private var typeSize

    @ViewBuilder func body(content: Content) -> some View {
        if typeSize.isAccessibilitySize { content.pickerStyle(.menu) } else { content.pickerStyle(.segmented) }
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
    /// ↩ ↪ 这类箭头在 iOS 上默认画成彩色 emoji 按键：加文字样式选择符，按普通字形显示。
    var textGlyphs: String {
        guard contains(where: { Self.emojiDefaulted.contains($0) }) else { return self }
        return String(flatMap { Self.emojiDefaulted.contains($0) ? [$0, "\u{FE0E}"] : [$0] })
    }

    private static let emojiDefaulted: Set<Character> = ["↩", "↪", "⤴", "⤵", "↔", "↕"]
}
#endif
