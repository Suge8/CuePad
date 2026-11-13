import CueText
import CueStore
import SwiftUI

/// 圆角、内边距只在这里定。
enum CueBubble {
    #if os(macOS)
    static let padding = EdgeInsets(top: Spacing.group, leading: Spacing.block, bottom: Spacing.group, trailing: Spacing.block)
    #else
    static let padding = EdgeInsets(top: Spacing.group, leading: Spacing.inset, bottom: Spacing.group, trailing: Spacing.inset)
    #endif
    static let joinedGap = Spacing.tight
    /// Cue 的话最宽占所在一栏的比例：回答常带列表与代码，比你的话（`UserBubble.widthFraction`）宽（手机上窄，再宽一点）。
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

/// `card`：结果卡（点名了图的做完，哪句算只在 `CueThread.rows` 定），不是气泡而是一张纸。
/// 结束了的提问回到对话里时字与拍板卡上同一句（代码写的问句 `CueAsking.question`），Cue 的原话收着、点"原话"展开：答之前读的与答之后回看的不是两种说法，你回答气泡里引的也是这一句。
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
    @State private var reading = DebugHooks.preset.toolsOpen

    var body: some View {
        BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
            VStack(alignment: .leading, spacing: card ? Spacing.group : Spacing.item) {
                words
                if !shots.isEmpty { CueShots(shots: shots, group: message.id.uuidString, open: open) }
                if asks {
                    foot
                } else if let task {
                    CueTaskLine(task: task, message: message)
                }
            }
            .animation(Motion.fade, value: reading)
            .modifier(CueSaysSurface(card: card, joined: joined))
            .contextMenu { MessageActions(text: message.text, kind: .cue, selectText: { selecting = true }) }
        }
        #if os(iOS)
        .sheet(isPresented: $selecting) { SelectableTextSheet(text: message.text) }
        #endif
    }

    private var asks: Bool { message.asking != nil && !card }

    @ViewBuilder private var words: some View {
        if asks {
            CueQuestionLine(message: message, tone: .ended)
            if reading {
                MarkdownText(source: message.text).equatable().font(Typography.secondary).foregroundStyle(palette.ink2)
                    .padding(Spacing.group).frame(maxWidth: .infinity, alignment: .leading)
                    .background(palette.fill, in: .rect(cornerRadius: Radius.block))
                    .transition(.opacity)
            }
        } else {
            said
        }
    }

    /// 问句底下只一排小字：没记成的结局、它关于的任务、看原话，不各占一行。
    private var foot: some View {
        HStack(spacing: Spacing.group) {
            if message.asking?.ask == .habit, message.answer == nil, message.setAsideBy == nil {
                Text("没记").font(Typography.meta).foregroundStyle(palette.ink3)
            }
            if let task { CueTaskLine(task: task, message: message) }
            OriginalToggle(open: $reading)
        }
        .frame(minHeight: CueTaskLine.lineHeight)
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

struct CueAnswer: View {
    let question: CueMessage
    let quoted: Bool
    var joined = false
    @Environment(\.chatHighlight) private var highlight

    var body: some View {
        let id = CueThread.Row.answerID(of: question.id), answer = question.answer.map(question.shownChoice) ?? ""
        AnswerBubble(
            answer: answer, quote: quoted ? question.headline.map { BubbleQuote(text: $0, target: question.id) } : nil, look: .cue(joined: joined),
            highlighted: highlight == id
        ) {
            MessageActions(text: answer, kind: .cue)
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

private struct OriginalToggle: View {
    @Binding var open: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: Spacing.tight) {
                Text("原话")
                Chevron(.expand).rotationEffect(.degrees(open ? 180 : 0))
            }
            .font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink2)
            // 不另占一行高：按得到的范围往外扩一圈，不撑高气泡
            .contentShape(.rect.inset(by: -Self.reach))
        }
        .buttonStyle(PressStyle(.inline))
        .accessibilityLabel(open ? "收起原话" : "看 Cue 的原话")
    }

    private static let reach: CGFloat = 10
}
