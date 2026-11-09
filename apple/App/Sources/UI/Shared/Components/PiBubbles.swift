import CueStore
import CueText
import SwiftUI

extension AnyTransition {
    /// 对话里一条出现或消失：只淡入淡出，动画随过渡自带。不给整段对话挂动画：其余各行的位移若也跟着动画，
    /// 底部锚定下正在读的那段会先被推走再滑回来
    static let entry = AnyTransition.opacity.animation(Motion.fade)
}

/// 会话页是 Agent 干活的记录，回答全宽、不成泡，你的话只标出哪句是你说的，不画两边对说的样子（`session`）；Cue 页（`cue`）才是两边对说的对话气泡。
enum BubbleLook: Equatable {
    case session
    case cue(joined: Bool)

    var shape: UnevenRoundedRectangle {
        switch self {
        case .session: UnevenRoundedRectangle(cornerRadii: .init(topLeading: Radius.sheet, bottomLeading: Radius.sheet, bottomTrailing: Radius.sheet, topTrailing: Radius.sheet))
        case .cue(let joined): CueBubble.shape(.trailing, joined: joined)
        }
    }

    var padding: EdgeInsets {
        switch self {
        case .session: EdgeInsets(top: Spacing.group, leading: Spacing.block, bottom: Spacing.group, trailing: Spacing.block)
        case .cue: CueBubble.padding
        }
    }

    var statusSpacing: CGFloat { self == .session ? 6 : 2 }
    var statusInset: CGFloat { self == .session ? 0 : CueBubble.padding.trailing }
}

/// `stored` 是存储格式正文（`CueFormat`）：文字在气泡里，带的图片是气泡下面的缩略图（`ChatImages`），文件是再下面的文件牌（`ChatFiles`）；送达前后同一个样子。
struct UserBubble<Menu: View>: View {
    /// 长的话折到这么多行，点"展开"看全：会话页的重点是回答，你自己写的长提示词不该是整屏最重的一块。
    static var foldedLines: Int { 6 }
    static var widthFraction: CGFloat { 0.78 }

    let stored: String
    let look: BubbleLook
    var trip = BubbleTrip.arrived
    var highlighted = false
    var fromCue = false
    var quote: BubbleQuote?
    @ViewBuilder var menu: Menu
    @State private var expanded = false
    @State private var truncated = false

    var body: some View {
        let parts = BubbleParts(stored), text = parts.text, images = parts.images, skill = PiSkillCall.parse(text)
        BubbleWidth(fraction: Self.widthFraction, edge: .trailing) {
            VStack(alignment: .trailing, spacing: Spacing.tight) {
                if fromCue { CueByline() }
                if !text.isEmpty || images.isEmpty {
                    BubbleText(
                        text: skill?.line ?? text, look: look, highlighted: highlighted, trip: trip, lineLimit: expanded ? nil : Self.foldedLines,
                        truncated: $truncated, expand: truncated && !expanded ? { expanded = true } : nil, quote: quote)
                    .tripMark(images.isEmpty && parts.files.isEmpty ? trip : .arrived, above: look.padding.bottom)
                }
                if let skill, !skill.body.isEmpty { SkillBody(skill: skill) }
                if !images.isEmpty { ChatImages(hashes: images, trip: trip).tripMark(parts.files.isEmpty ? trip : .arrived, above: 0) }
                if !parts.files.isEmpty { ChatFiles(files: parts.files, trip: trip).tripMark(trip, above: 0) }
            }
            #if os(iOS)
            .contentShape(.contextMenuPreview, look.shape)
            #endif
            .contextMenu { menu }
        }
        .transition(.entry)
    }
}

nonisolated struct BubbleParts {
    let text: String
    let images: [String]
    let files: [DraftFile]

    init(_ stored: String) {
        guard CueFormat.hasAttachments(stored) else {
            (text, images, files) = (CueFormat.plainText(stored), [], [])
            return
        }
        let tokens = CueFormat.parse(stored)
        text = CueFormat.plainText(tokens.map { if case .text(let text) = $0 { text } else { "" } }.joined())
        var seen = Set<DraftFile>()
        let attached = tokens.compactMap(DraftFile.init).filter { seen.insert($0).inserted }
        images = attached.filter(\.isImage).map(\.key)
        files = attached.filter { !$0.isImage }
    }
}

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
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: open)
    }
}

struct BubbleText: View {
    let text: String
    let look: BubbleLook
    var highlighted = false
    var trip = BubbleTrip.arrived
    var lineLimit: Int?
    var truncated: Binding<Bool>?
    var expand: (() -> Void)?
    var quote: BubbleQuote?
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = look.shape
        VStack(alignment: .leading, spacing: Spacing.tight) {
            if let quote { QuoteLine(quote: quote) }
            Paragraphs(verbatim: text, lineSpacing: Typography.readingLineSpacing, lineLimit: lineLimit)
                .font(Typography.reading).foregroundStyle(palette.ink)
                .background(alignment: .topLeading) { if let truncated, let lineLimit { truncationProbe(truncated, lineLimit: lineLimit) } }
            if let expand { expandButton(expand).frame(maxWidth: .infinity, alignment: .trailing) }
        }
            .padding(look.padding)
            .background(palette.bubble, in: shape)
            .overlay { edge(shape) }
            .opacity(trip.opacity)
            .animation(Motion.fade, value: highlighted)
            .animation(Motion.fade, value: trip)
    }

    private func expandButton(_ expand: @escaping () -> Void) -> some View {
        Button("展开", action: expand)
            .font(Typography.reading.weight(.semibold)).foregroundStyle(palette.ink2)
            .buttonStyle(PressStyle(.inline))
    }

    /// 同一宽度和样式多排一行就能判定截断；短气泡只多量自身，长气泡不必排完整篇。
    private func truncationProbe(_ truncated: Binding<Bool>, lineLimit: Int) -> some View {
        GeometryReader { shown in
            let folded = shown.size.height
            Paragraphs(verbatim: text, lineSpacing: Typography.readingLineSpacing, lineLimit: lineLimit + 1).font(Typography.reading).fixedSize(horizontal: false, vertical: true)
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

/// Cue 的提问与会话里的提问同一个组件，各自只从自己的事实推出：Cue 的是那条提问（`CueThread.Row.answer`），会话的是对话里的作答（`PiChatRole.answer`）。
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
