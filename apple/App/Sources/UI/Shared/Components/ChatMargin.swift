import SwiftUI

/// 对话里除了谁对谁说的话（气泡、回答）以外的东西只有两种样子，没有底色块、没有边框，与说的话一眼分开：
/// - 旁注（`NoteLine`）：属于一边的一行小字——一轮的经过、此刻在做什么、这一轮怎么结束的、Cue 自己醒来的那几轮（`CueNoteLog`，每轮一行）。你的话到哪了不是一行，是气泡左下角外的记号（`BubbleTrip`）。
///   前面一个图标位，能展开的末尾一个箭头，展开的清单挂在标题图标下的一条细线右边（`NoteThread`）。贴着哪一边、离边多远由所在的页面给
///   （Cue 页与气泡里的字对齐，会话页与回答对齐）。
/// - 居中的标记（`ChatMarker`）：不属于哪一边的一行——几点、哪天（`ChatTime`），上下文从这里换了，上面还有更早的。
enum Note {
    /// 图标位的宽：标题行的图标、清单的细线都对着它的中线。
    static let glyphWidth: CGFloat = 14
    static let spacing: CGFloat = 6
    /// 一行的最小高：一串旁注排得齐，点按区也够。
    static let lineHeight: CGFloat = 24
}

struct NoteLine<Glyph: View, Label: View>: View {
    /// 能展开时是此刻开没开（末尾的箭头）；不能展开为 nil。
    var open: Bool?
    /// 行末的几点（Cue 页动态里一节的第一行）：按自己的宽排、不换行，对着第一行；地方不够时左边的字折行（各行自己定折不折）。
    var time: Date?
    @ViewBuilder let glyph: Glyph
    @ViewBuilder let label: Label
    @Environment(\.palette) private var palette

    var body: some View {
        // 按第一行字对齐：字折成两行时图标与几点对着第一行
        HStack(alignment: .firstTextBaseline, spacing: Note.spacing) {
            glyph.foregroundStyle(palette.ink3).frame(width: Note.glyphWidth).accessibilityHidden(true)
            // 行末有几点时字先占满（几点按自己的宽、不被挤），不和中间的空白平分
            label.layoutPriority(time == nil ? 0 : 1)
            if let open { DisclosureChevron(open: open) }
            if let time {
                Spacer(minLength: 8)
                Text(ChatTime.time(time)).foregroundStyle(palette.ink3).fixedSize()
            }
        }
        .font(Typography.caption.monospacedDigit()).foregroundStyle(palette.ink2)
        .frame(minHeight: Note.lineHeight)
        .contentShape(.rect)
    }
}

extension NoteLine where Glyph == Image {
    init(icon: Icon, open: Bool? = nil, time: Date? = nil, @ViewBuilder label: () -> Label) {
        self.init(open: open, time: time, glyph: { Image(icon) }, label: label)
    }
}

/// 展开的旁注清单：挂在标题行图标下的一条细线右边，像一串注脚；字与标题行的字对齐。
struct NoteThread<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 2) { content }
            .padding(.leading, Note.glyphWidth + Note.spacing)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .leading) {
                palette.hair.frame(width: 1).padding(.leading, Note.glyphWidth / 2).padding(.bottom, 4)
            }
            .transition(.opacity)
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
