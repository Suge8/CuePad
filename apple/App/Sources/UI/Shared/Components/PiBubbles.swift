import CueStore
import CueText
import SwiftUI

extension AnyTransition {
    /// 对话里一条出现或消失：只淡入淡出，动画随过渡自带。不给整段对话挂动画：其余各行的位移若也跟着动画，
    /// 底部锚定下正在读的那段会先被推走再滑回来
    static let entry = AnyTransition.opacity.animation(HandOff.quick)
}

/// 你的话那颗气泡长什么样，两处各一种，只在这里分：
/// - 会话页（`session`）：四角同圆的一颗，新到的淡入。会话页是 Agent 干活的记录，回答全宽、不成泡，你的话只标出哪句是你说的，不画两边对说的样子。
/// - Cue 页（`cue`）：两边对说的对话气泡，说话那一边下角收成小角、连着说的收成一串（`CueBubble`），由回复框那头的发出动画接上。
enum BubbleLook: Equatable {
    case session
    /// `joined`：上面紧挨着你的另一句。
    case cue(joined: Bool)

    private static let sessionRadius: CGFloat = 20

    var shape: UnevenRoundedRectangle {
        switch self {
        case .session: UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
            topLeading: Self.sessionRadius, bottomLeading: Self.sessionRadius, bottomTrailing: Self.sessionRadius, topTrailing: Self.sessionRadius),
            style: .continuous)
        case .cue(let joined): CueBubble.shape(.trailing, joined: joined)
        }
    }

    var padding: EdgeInsets {
        switch self {
        case .session: EdgeInsets(top: 11, leading: 16, bottom: 11, trailing: 16)
        case .cue: CueBubble.padding
        }
    }

    /// 没能送达时气泡下那一行（"未送达 · 重发"）离气泡多远、离右缘多远：Cue 页的旁注对着气泡里的字（`CueBubble.noteInset`）。
    var statusSpacing: CGFloat { self == .session ? 6 : 2 }
    var statusInset: CGFloat { self == .session ? 0 : CueBubble.noteInset }
}

/// 你的一句话：右侧气泡（样子见 `BubbleLook`），最宽到所在一栏的 `widthFraction`；到哪了画在气泡左下角外（`BubbleTrip`）。长按（Mac 右键）是 `menu`，预览就是这颗气泡。
/// `stored` 是存储格式正文（`CueFormat`）：文字在气泡里，带的图片是气泡下面的缩略图（`ChatImages`）；送达前后同一个样子。
/// 用斜杠技能说的（`PiSkillCall`）气泡里是你发的样子，技能正文收在气泡下，点开看（`SkillBody`）。
struct UserBubble<Menu: View>: View {
    /// 长的话折到这么多行，点"展开"看全：会话页的重点是回答，你自己写的长提示词不该是整屏最重的一块。
    static var foldedLines: Int { 6 }
    static var widthFraction: CGFloat { 0.78 }

    let stored: String
    let look: BubbleLook
    var trip = BubbleTrip.arrived
    var highlighted = false
    /// Cue 发进会话的话：气泡上面一行 Cue 的小头像与名字（`CueByline`）。
    var fromCue = false
    /// 这句是你对一个提问的回答：气泡里字上面一行答的是哪个问题（`BubbleQuote`）。
    var quote: BubbleQuote?
    @ViewBuilder var menu: Menu
    @State private var expanded = false
    /// 折起时文字确实被截掉了（按同一宽度量全文的高度比较）。
    @State private var truncated = false

    var body: some View {
        let text = CueFormat.plainText(stored), images = CueFormat.imageHashes(in: stored), skill = PiSkillCall.parse(text)
        BubbleWidth(fraction: Self.widthFraction, edge: .trailing) {
            VStack(alignment: .trailing, spacing: 6) {
                if fromCue { CueByline() }
                // 到哪了的记号挂在最下面那一块（文字气泡，带图时是图）的左边
                if !text.isEmpty || images.isEmpty {
                    BubbleText(
                        text: skill?.line ?? text, look: look, highlighted: highlighted, trip: trip, lineLimit: expanded ? nil : Self.foldedLines,
                        truncated: $truncated, expand: truncated && !expanded ? { expanded = true } : nil, quote: quote)
                    .tripMark(images.isEmpty ? trip : .arrived, above: look.padding.bottom)
                }
                if let skill, !skill.body.isEmpty { SkillBody(skill: skill) }
                if !images.isEmpty { ChatImages(hashes: images, trip: trip).tripMark(trip, above: 0) }
            }
            #if os(iOS)
            .contentShape(.contextMenuPreview, look.shape)
            #endif
            .contextMenu { menu }
        }
        .transition(.entry)
    }
}

/// 技能正文：气泡下一行旁注"技能 名字 的正文"，点开在细线下看全文（与机器消息的卡片同一种收放），占满气泡这一栏的宽。
private struct SkillBody: View {
    let skill: PiSkillCall
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var open = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Button { open.toggle() } label: {
                NoteLine(icon: .readFile, open: open) { Text("技能 \(skill.name) 的正文").foregroundStyle(palette.ink3) }
            }
            .buttonStyle(PressStyle())
            .accessibilityExpanded(open)
            if open { NoteThread { MarkdownText(source: skill.body).equatable() }.frame(maxWidth: .infinity, alignment: .leading) }
        }
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: open)
    }
}

/// 气泡本身（颜色是 `Palette.bubble`）。Mac 上可以直接拖选文字。
struct BubbleText: View {
    let text: String
    let look: BubbleLook
    var highlighted = false
    var trip = BubbleTrip.arrived
    var lineLimit: Int?
    /// 给了时报告文字是否被 `lineLimit` 截掉。
    var truncated: Binding<Bool>?
    /// 折起着时：最后一行末尾渐隐，接着是"展开"（在气泡里，就在被截断的地方）。
    var expand: (() -> Void)?
    var quote: BubbleQuote?
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = look.shape
        VStack(alignment: .leading, spacing: 6) {
            if let quote { QuoteLine(quote: quote) }
            Paragraphs(verbatim: text, lineLimit: lineLimit)
                .font(Typography.reading).foregroundStyle(palette.ink)
                .background(alignment: .topLeading) { if let truncated, mayTruncate { fullHeight(truncated) } }
                .overlay(alignment: .bottomTrailing) { if let expand { expandButton(expand) } }
        }
            .padding(look.padding)
            .background(palette.bubble, in: shape)
            .overlay { edge(shape) }
            .opacity(trip.opacity)
            .animation(HandOff.quick, value: highlighted)
            .animation(HandOff.quick, value: trip)
    }

    /// 折起着、而且长到可能被截：每个气泡多挂一份量全文高的视图（每个几何读数都是一次布局回调），所以短的话（绝大多数）不挂。
    /// 一行至少放得下 40 个字节（窄到手机上的气泡，拉丁字母约 7pt 宽、汉字三字节），没到 `lineLimit` 行的字节数、又没有那么多换行的话排不满。
    private var mayTruncate: Bool {
        guard let lineLimit else { return false }
        return text.utf8.count > 40 * lineLimit || text.utf8.lazy.filter { $0 == 10 }.count >= lineLimit
    }

    private func expandButton(_ expand: @escaping () -> Void) -> some View {
        HStack(spacing: 0) {
            LinearGradient(colors: [palette.bubble.opacity(0), palette.bubble], startPoint: .leading, endPoint: .trailing).frame(width: 36)
            Button("展开", action: expand)
                .font(Typography.reading.weight(.semibold)).foregroundStyle(palette.ink2)
                .buttonStyle(PressStyle(.inline))
                .padding(.leading, 4)
                .background(palette.bubble)
        }
        .fixedSize()
    }

    /// 同一宽度下排全文要多高，与折起后的高度比，量出有没有被截掉；只读几何、不影响自己的排版（藏起的全文不占位）。
    private func fullHeight(_ truncated: Binding<Bool>) -> some View {
        GeometryReader { shown in
            let folded = shown.size.height
            Paragraphs(verbatim: text).font(Typography.reading).fixedSize(horizontal: false, vertical: true)
                .frame(width: shown.size.width, alignment: .leading)
                .hidden()
                .onGeometryChange(for: Bool.self) { $0.size.height > folded + 1 } action: { truncated.wrappedValue = $0 }
        }
    }

    @ViewBuilder private func edge(_ shape: UnevenRoundedRectangle) -> some View {
        switch trip {
        case .failed: shape.strokeBorder(palette.failure, lineWidth: 1)
        case .arrived, .sending, .delivered:
            if highlighted { shape.strokeBorder(palette.signature, lineWidth: 2) } else if let edge = palette.bubbleEdge { shape.strokeBorder(edge) }
        }
    }
}

/// 你对一个提问的回答（Cue 的提问与会话里的提问同一个组件）：你那一边的一颗气泡（`UserBubble`），字上面一行答的是哪个问题（`BubbleQuote`），
/// 下面是选的那一项（会话里自己写的答案是全文）。各自只从自己的事实推出：Cue 的是那条提问（`CueThread.Row.answer`），会话的是对话里的作答（`PiChatRole.answer`）。
struct AnswerBubble<Menu: View>: View {
    let answer: String
    let quote: BubbleQuote?
    let look: BubbleLook
    var highlighted = false
    @ViewBuilder var menu: Menu

    var body: some View {
        UserBubble(stored: answer, look: look, highlighted: highlighted, quote: quote) { menu }
    }
}

/// 你的一句答的是哪个问题：气泡里字上面一行，回复的箭头接问题。
/// `target` 是对话里那个问题所在的一格，点引用跳回去（`chatJump`）；问题已不在对话里（会话的问题答完就没了）为 nil，不能点。
nonisolated struct BubbleQuote: Equatable, Sendable {
    let text: String
    var target: UUID?
}

private struct QuoteLine: View {
    let quote: BubbleQuote
    @Environment(\.chatJump) private var jump
    @Environment(\.palette) private var palette

    var body: some View {
        let line = Label { Text(quote.text).lineLimit(2).multilineTextAlignment(.leading) } icon: { Image(.yourAnswer).imageScale(.small) }
            .font(Typography.secondary).foregroundStyle(palette.ink2)
            .accessibilityLabel("回答：\(quote.text)")
        if let target = quote.target, let jump {
            Button { jump(target) } label: { line }.buttonStyle(PressStyle()).accessibilityHint("回到那个问题")
        } else {
            line
        }
    }
}
