import CueStore
import SwiftUI

/// Cue 页的对话气泡（你的话、Cue 的话）：只有 Cue 页是两边对说，会话页你的话是另一种（`BubbleLook.session`）。
/// 说话的那一边下角收成小角，像从那一边递过来的一张纸条：一眼分得出谁说的，不画尾巴；
/// 同一边连着说的几颗收紧成一串（`joinedGap`），后面几颗那一边的上角也收小，连成一列。圆角、内边距只在这里定。
enum CueBubble {
    static let radius: CGFloat = 22
    static let corner: CGFloat = 6
    #if os(macOS)
    static let padding = EdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18)
    #else
    static let padding = EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
    #endif
    static let joinedGap: CGFloat = 4
    /// 气泡旁的旁注（经过、醒来记录，`NoteLine`、`CueNoteLog`）离那一边的距离：图标对着气泡里的字。
    static let noteInset: CGFloat = padding.leading
    /// Cue 的话最宽占所在一栏的比例：回答常带列表与代码，比你的话（`UserBubble.widthFraction`）宽（手机上窄，再宽一点）。
    #if os(macOS)
    static let cueWidth: CGFloat = 0.86
    #else
    static let cueWidth: CGFloat = 0.9
    #endif

    /// `joined`：上面紧挨着同一边的一颗。
    static func shape(_ edge: HorizontalEdge, joined: Bool = false) -> UnevenRoundedRectangle {
        let top = joined ? corner : radius
        return switch edge {
        case .trailing: UnevenRoundedRectangle(topLeadingRadius: radius, bottomLeadingRadius: radius, bottomTrailingRadius: corner, topTrailingRadius: top, style: .continuous)
        case .leading: UnevenRoundedRectangle(topLeadingRadius: top, bottomLeadingRadius: corner, bottomTrailingRadius: radius, topTrailingRadius: radius, style: .continuous)
        }
    }

    /// 新说出的一颗淡入。贴着最新时滚动区先把上面的对话撑上去、让出它的位置（`ChatScroll.rise`，渲染端平移），让开了它再在终位淡入：
    /// 让的途中它还在回复框的玻璃后面，那时露出来会被折射成怪字。不缩放：有字的一块缩放时每帧重画字形（`Bubble.swift`）。
    static let arrival = AnyTransition.opacity.animation(HandOff.quick.delay(Motion.moveDuration))
}

/// Cue 说的一句：靠左的一颗纸做的气泡（`cueBubble`），里面是 Markdown（同会话里 Agent 的回答），下面是它点名的图（`CueShots`：结束了回到问的位置的提问，
/// 你的回答在答的那一刻另成一格，见 `CueAnswer`、`CueThread.rows`）；它第一次提到一件活时底下一行这件活（`CueTaskLine`）。
/// `card`：结果卡（点名了图的做完，哪句算只在 `CueThread.rows` 定）——不是气泡而是一张纸（`paper`），不与上下的气泡连成一串；
/// 第一行是一句平常的话时（"「X」做完了"）单独加粗作标题，一眼先读到做完了什么，再看证据与图。
/// 结束了的提问（答了、撤回、你没选直接说了）回到对话里时字与"等你"卡上同一句：代码写的问句（`CueAsking.question`，规矩那一类下面一行引的规矩），
/// 淡一档（次一级的墨、不加粗：已经过去了，还在等你的在输入框上方的等你卡里，`CueWaitDock`），Cue 的原话收着、点"原话"展开（`CueOriginalToggle`）；
/// 答之前读的与答之后回看的不是两种说法，你回答气泡里引的也是这一句。
/// 长按（Mac 右键）是消息菜单（`MessageMenu.Kind.cue`），预览就是这颗气泡或这张纸。
struct CueSays: View {
    let message: CueMessage
    var task: CueTaskRef?
    /// Cue 点名的图（`CueThread.shots`）与点开一张：全屏左右翻的就是这几张，底栏是关于它对 Cue 说
    var shots: [CueShown] = []
    var open: (PreviewOpening) -> Void = { _ in }
    var card = false
    /// 上面紧挨着 Cue 的另一句（`CueBubble.shape`）。
    var joined = false
    @Environment(\.palette) private var palette
    @State private var selecting = false
    /// 提问的原话展开着。
    @State private var reading = false

    var body: some View {
        BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
            VStack(alignment: .leading, spacing: card ? 12 : 8) {
                words
                if !shots.isEmpty { CueShots(shots: shots, group: message.id.uuidString, reply: .cue, open: open) }
                if let task { CueTaskLine(ref: task) }
            }
            .modifier(CueSaysSurface(card: card, joined: joined))
            .contextMenu { MessageActions(text: message.text, kind: .cue, selectText: { selecting = true }) }
        }
        #if os(iOS)
        .sheet(isPresented: $selecting) { SelectableTextSheet(text: message.text) }
        #endif
    }

    @ViewBuilder private var words: some View {
        if message.asking != nil, !card {
            asked
        } else {
            said
        }
    }

    private var asked: some View {
        CueQuestionLine(message: message, tone: .ended) {
            if reading {
                MarkdownText(source: message.text).equatable().font(Typography.secondary).foregroundStyle(palette.ink2).padding(.top, 6)
                    .transition(.opacity)
            }
            CueOriginalToggle(open: $reading)
        }
        .animation(HandOff.quick, value: reading)
    }

    @ViewBuilder private var said: some View {
        let parts: (title: String?, body: String) = card ? Self.headline(message.text) : (nil, message.text)
        if let title = parts.title {
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.inline(title)).font(Typography.reading.weight(.semibold)).foregroundStyle(palette.ink)
                    .lineSpacing(Typography.readingLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
                if !parts.body.isEmpty { MarkdownText(source: parts.body).equatable() }
            }
        } else {
            MarkdownText(source: parts.body).equatable()
        }
    }

    /// 第一行是平常的一句话（不是标题、列表、引用、代码、表格）时拆出来作标题，其余是正文。
    private static func headline(_ text: String) -> (title: String?, body: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = lines.first.map(String.init), !first.isEmpty, !Self.isMarkup(first) else { return (nil, trimmed) }
        let rest = lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        return (first, rest)
    }

    /// 标题行里的行内记号（粗体、代码、链接）照样认，不露出星号与反引号。
    private static func inline(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line)
    }

    private static func isMarkup(_ line: String) -> Bool {
        if ["#", "-", "*", "+", ">", "`", "|", "!["].contains(where: line.hasPrefix) { return true }
        return line.prefix { $0.isNumber }.count > 0 && line.drop { $0.isNumber }.hasPrefix(".")
    }
}

/// `CueSays` 的底：气泡（`cueBubble`），或结果卡的一张纸；长按的预览照这个形状裁。
private struct CueSaysSurface: ViewModifier {
    let card: Bool
    let joined: Bool

    func body(content: Content) -> some View {
        if card {
            content.padding(CueBubble.padding).frame(maxWidth: .infinity, alignment: .leading).paper(radius: CueBubble.radius)
                #if os(iOS)
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: CueBubble.radius, style: .continuous))
                #endif
        } else {
            content.cueBubble(joined: joined)
                #if os(iOS)
                .contentShape(.contextMenuPreview, CueBubble.shape(.leading, joined: joined))
                #endif
        }
    }
}

/// 你对 Cue 一条提问的回答（`CueThread.Row.answer`）：你那一边的一颗气泡（`AnswerBubble`，同会话里的作答），是选的那一项（更旧版本存下的另外一句照原文）；
/// 问的那句隔开了（`quoted`）才在字上面引一行答的是哪张卡（`CueMessage.headline`，点它跳回问的那句）。从刻度滑条跳过来时描一圈。
struct CueAnswer: View {
    let question: CueMessage
    let quoted: Bool
    var joined = false
    @Environment(\.chatHighlight) private var highlight

    var body: some View {
        let id = CueThread.Row.answerID(of: question.id), answer = question.answer ?? ""
        AnswerBubble(
            answer: answer, quote: quoted ? question.headline.map { BubbleQuote(text: $0, target: question.id) } : nil, look: .cue(joined: joined),
            highlighted: highlight == id
        ) {
            MessageActions(text: answer, kind: .cue)
        }
    }
}

extension View {
    /// Cue 的话的气泡：纸色实底（`Palette.paper`，比桌面亮一级），你的话是比桌面深一级的牛皮纸色（`Palette.bubble`）。正在说的话（Mac）与说完落库的那句同一颗。
    /// 只铺一层底：不用卡片那套渐变、一线高光与描边（`paper()`）——气泡小，看不出差别，长对话滚动时每颗多出的层逐帧都要更新；
    /// 增强对比度时才描边（`Palette.bubbleEdge`）。`onLane`：浮在看板上的那颗（等你那一列）是纯白（`Palette.laneBubble`），与旁边纸色的卡分得开。
    func cueBubble(joined: Bool, onLane: Bool = false) -> some View {
        modifier(CueBubbleSurface(shape: CueBubble.shape(.leading, joined: joined), onLane: onLane))
    }
}

private struct CueBubbleSurface: ViewModifier {
    let shape: UnevenRoundedRectangle
    let onLane: Bool
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.padding(CueBubble.padding).background(onLane ? palette.laneBubble : palette.paper, in: shape).overlay { if let edge = palette.bubbleEdge { shape.strokeBorder(edge) } }
    }
}
