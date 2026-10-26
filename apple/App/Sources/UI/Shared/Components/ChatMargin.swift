import SwiftUI

/// 对话里除了谁对谁说的话（气泡、回答）以外的东西只有两种样子，没有底色块、没有边框，与说的话一眼分开：
/// - 旁注（`NoteLine`）：属于一边的一行小字——一轮的经过、此刻在做什么、这一轮怎么结束的；Cue 页的经过与醒来那几轮是同一种行（`CueNoteRow`）。你的话到哪了不是一行，是气泡左下角外的记号（`BubbleTrip`）。
///   前面一个图标位，能展开的末尾一个箭头，展开的清单挂在标题图标下的一条细线右边（`NoteThread`）。贴着哪一边、离边多远由所在的页面给
///   （Cue 页与 Cue 气泡的左缘对齐，会话页与回答对齐）。
/// - 居中的标记（`ChatMarker`）：不属于哪一边的一行——几点、哪天（`ChatTime`），上下文从这里换了，上面还有更早的。
enum Note {
    /// 图标位的宽（常规字号下）：标题行的图标、清单的细线都对着它的中线。随动态字体放大，只经 `noteGlyph`。
    static let glyphWidth: CGFloat = 14
    static let spacing: CGFloat = 6
    /// 一行的最小高：一串旁注排得齐，点按区也够。
    static let lineHeight: CGFloat = 24
}

struct NoteLine<Glyph: View, Label: View>: View {
    /// 能展开时是此刻开没开（末尾的箭头）；不能展开为 nil。
    var open: Bool?
    @ViewBuilder let glyph: Glyph
    @ViewBuilder let label: Label
    @Environment(\.palette) private var palette

    var body: some View {
        // 按第一行字对齐：字折成两行时图标对着第一行
        HStack(alignment: .firstTextBaseline, spacing: Note.spacing) {
            glyph.foregroundStyle(palette.ink3).noteGlyph().accessibilityHidden(true)
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

/// 展开的旁注清单：挂在标题行图标下的一条细线右边，像一串注脚；字与标题行的字对齐。
struct NoteThread<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) { content }
            .noteGlyph(.indent)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                palette.hair.frame(width: 1).noteGlyph(.center).padding(.bottom, 4)
            }
            .transition(.opacity)
    }
}

/// 对话末尾此刻在做什么那一行的位置（Cue 页 `CueEnding`、会话页 `PiConversation`）：一直占着一行旁注的高（离上一格 `gap`），没有时留白。
/// 不占位的话，它一出一收，贴着最新的整段对话跟着当帧上下跳一行（内容变高矮时底锚，`ChatScroll`），回复紧接着到时还与新到的那一条的上滑叠成一抖。
/// 代价：歇着时对话末尾多一行空白；放进来的那一行只写一行（长的截断）。在跑的经过往下长出几行是内容，照常长。
struct ChatLiveSlot<Content: View>: View {
    let gap: CGFloat
    /// 那一行字的字号：占位按它量高。
    var font: Font = Typography.caption
    @ViewBuilder let content: Content

    var body: some View {
        ZStack(alignment: .topLeading) {
            NoteLine(icon: .pondering) { Text(verbatim: " ").font(font) }.hidden().accessibilityHidden(true)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, gap)
    }
}

extension View {
    /// 旁注的图标位（`Note.glyphWidth`）：`column` 是图标本身占的位，`indent` 让出图标位与它到字的空（清单、第二行的字对着标题行的字），
    /// `center` 挪到图标位的中线（清单的细线）。宽随动态字体放大：图标跟着字放大，定宽的位在大字号下放不下，图标压到后面的字上。
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

/// 对话中间居中的一行小字。`ruled`：两边各一条细线（上下文从这里换了，线以上的它不再逐句看得到）；
/// `highlighted`：从刻度滑条跳过来时垫一层选中色；给了 `action` 是一颗按钮（排开更早的）。
struct ChatMarker<Label: View>: View {
    var ruled = false
    var highlighted = false
    var action: (() -> Void)?
    @ViewBuilder let label: Label
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 10) {
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
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background { if highlighted { Capsule().fill(palette.selection).transition(.opacity) } }
            .animation(HandOff.quick, value: highlighted)
        if let action {
            Button(action: action) { text.contentShape(.capsule) }
                .buttonStyle(PressStyle(.button))
                .frame(minHeight: 44)
        } else {
            text.accessibilityElement(children: .combine)
        }
    }
}

/// 几点、哪天（对话里隔了一阵的地方居中写一行，`CueThread.stamps`）：今天只写几点；昨天、这周写"昨天""周二"，再早写日期，跨年带年份。
nonisolated enum ChatTime {
    /// 隔了这么久另起一段写时间（同 iMessage 的一小时）。
    static let gap: TimeInterval = 3600

    /// 哪天：今天不写（nil），其余同 `DateLabel.day`。
    static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String? {
        calendar.isDate(date, inSameDayAs: now) ? nil : DateLabel.day(date, now: now, calendar: calendar)
    }

    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
}

/// 对话里隔了一阵的地方：哪天（不是今天时，稍重）与几点。
struct ChatTimeMarker: View {
    let date: Date
    @Environment(\.palette) private var palette

    var body: some View {
        ChatMarker {
            if let day = ChatTime.day(date) {
                Text("\(Text(day).fontWeight(.medium).foregroundStyle(palette.ink2)) \(ChatTime.time(date))")
            } else {
                Text(ChatTime.time(date))
            }
        }
    }
}
