import SwiftUI

enum Note {
    static let glyphWidth: CGFloat = 14
    static let spacing = Spacing.glyph
    static let lineHeight: CGFloat = 24
}

struct NoteLine<Glyph: View, Label: View>: View {
    var open: Bool?
    @ViewBuilder let glyph: Glyph
    @ViewBuilder let label: Label
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Note.spacing) {
            glyph.foregroundStyle(palette.ink3).readerHidden(true).noteGlyph()
            label
            if let open { DisclosureChevron(open: open) }
        }
        .font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink2)
        .frame(minHeight: Note.lineHeight)
        .contentShape(.rect)
    }
}

extension NoteLine where Glyph == Image {
    init(icon: Icon, open: Bool? = nil, @ViewBuilder label: () -> Label) {
        self.init(open: open, glyph: { Image(icon) }, label: label)
    }
}

struct NoteThread<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hair) { content }
            .noteGlyph(.indent)
            .padding(.bottom, Spacing.tight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                palette.hair.frame(width: 1).noteGlyph(.center).padding(.bottom, Spacing.tight)
            }
            .transition(.opacity)
    }
}

/// 不占位的话，它一出一收，贴着最新的整段对话跟着当帧上下跳一行（内容变高矮时底锚，`ChatScroll`），回复紧接着到时还与新到的那一条的上滑叠成一抖。
/// 这段留白也是叠在底部那一块上方的提示（`floatingAbove`：会话页回复框上的说明）落下的地方，两样共用一段、不各留一份：
/// 至少让出 `floating`（提示最高多高，连同离那一块的间隔）减去对话末尾本来的边（`ChatLayout.edge`）与列给它上面留的 `spacing`，
/// 提示在时最后一条内容露在它上方，提示出没、这一行出没都不改排版。提示与这一行同时在时提示盖住这一行（提示垫实底）。
/// 否决的方案：滚动区按提示另加一段留白——平时空着一大截；随提示改滚动范围——iOS 贴底时系统追底，对话跳一下。
/// 代价：歇着时对话末尾多一行空白；放进来的那一行只写一行（长的截断）。在跑的经过往下长出几行是内容，照常长。
struct ChatLiveSlot<Content: View>: View {
    var gap: CGFloat = 0
    var spacing: CGFloat = 0
    var font: Font = Typography.caption
    var floating: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            NoteLine(icon: .pondering) { Text(verbatim: " ").font(font) }.hidden().readerHidden(true)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, gap)
        .frame(minHeight: max(0, floating - ChatLayout.edge - spacing), alignment: .top)
    }
}

extension View {
    func noteGlyph(_ use: NoteGlyph.Use = .column) -> some View { modifier(NoteGlyph(use: use)) }
}

struct NoteGlyph: ViewModifier {
    enum Use { case column, indent, center }

    let use: Use
    @ScaledMetric(relativeTo: .caption) private var width = Note.glyphWidth

    func body(content: Content) -> some View {
        switch use {
        case .column: content.frame(width: width)
        case .indent: content.padding(.leading, width + Note.spacing)
        case .center: content.padding(.leading, width / 2)
        }
    }
}

struct ChatMarker<Label: View>: View {
    var ruled = false
    var highlighted = false
    var glassed = false
    var action: (() -> Void)?
    @ViewBuilder let label: Label
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: Spacing.item) {
            if ruled { rule }
            marker.layoutPriority(1)
            if ruled { rule }
        }
        .frame(maxWidth: .infinity, minHeight: Note.lineHeight)
        .transition(.entry)
    }

    private var rule: some View { palette.hair.frame(height: 1) }

    @ViewBuilder private var marker: some View {
        let text = label
            .font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink3).lineLimit(1)
            .padding(.horizontal, Spacing.item).padding(.vertical, Spacing.tight)
            .background { if highlighted { Capsule().fill(palette.selection).transition(.opacity) } }
            .glass(in: .capsule, shown: glassed)
            .animation(Motion.fade, value: highlighted)
        if let action {
            Button(action: action) { text.contentShape(.capsule) }
                .buttonStyle(PressStyle(.button))
                .frame(minHeight: 44)
        } else {
            text.accessibilityElement(children: .combine)
        }
    }
}

nonisolated enum ChatTime {
    static let gap: TimeInterval = 3600

    static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String? {
        calendar.isDate(date, inSameDayAs: now) ? nil : DateLabel.day(date, now: now, calendar: calendar)
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

struct ChatTimeMarker: View {
    let date: Date
    @Environment(\.palette) private var palette

    var body: some View {
        ChatMarker(glassed: true) {
            if let day = ChatTime.day(date) {
                Text("\(Text(day).fontWeight(.medium).foregroundStyle(palette.ink2)) \(ChatTime.time(date))")
            } else {
                Text(ChatTime.time(date))
            }
        }
    }
}
