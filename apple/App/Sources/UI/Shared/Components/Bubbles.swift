import CueStore
import CueText
import SwiftUI

extension AnyTransition {
    static let entry = AnyTransition.opacity.animation(Motion.fade)
}

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

struct UserBubble<Menu: View>: View {
    static var foldedLines: Int { 6 }
    static var widthFraction: CGFloat { 0.78 }

    let stored: String
    let look: BubbleLook
    var trip = BubbleTrip.arrived
    var highlighted = false
    var fromCue = false
    var marksTransit = true
    var quote: BubbleQuote?
    var said: Date?
    @ViewBuilder var menu: Menu
    @Environment(\.sendFlight) private var flight

    var body: some View {
        let parts = BubbleParts(stored), text = parts.text, images = parts.images, skill = SkillCall.parse(text)
        let plain = images.isEmpty && parts.files.isEmpty && skill == nil
        let mark: BubbleTrip = switch trip {
        case .sending, .delivered: marksTransit ? trip : .arrived
        case .arrived, .failed: trip
        }
        BubbleWidth(fraction: Self.widthFraction, edge: .trailing) {
            VStack(alignment: .trailing, spacing: Spacing.tight) {
                if !text.isEmpty || images.isEmpty {
                    BubbleText(
                        text: skill?.line ?? text, look: look, highlighted: highlighted, trip: trip, fromCue: fromCue, foldedLines: Self.foldedLines, quote: quote)
                    .tripMark(images.isEmpty && parts.files.isEmpty ? mark : .arrived, above: look.padding.bottom)
                    .flightLanding(plain && flight?.carries(text, said: said) == true ? flight : nil, look: look, opacity: trip.opacity)
                }
                if let skill, !skill.body.isEmpty { SkillBody(skill: skill) }
                if !images.isEmpty { ChatImages(hashes: images, trip: trip).tripMark(parts.files.isEmpty ? mark : .arrived, above: 0) }
                if !parts.files.isEmpty { ChatFiles(files: parts.files, trip: trip).tripMark(mark, above: 0) }
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
    let skill: SkillCall
    @Environment(\.palette) private var palette
    @State private var open = false

    var body: some View {
        Fold(open: $open) {
            NoteLine(icon: .readFile, open: open) { Text("技能 \(skill.name) 的正文").foregroundStyle(palette.ink3) }
        } content: {
            if open { NoteThread { MarkdownText(source: skill.body).equatable() }.frame(maxWidth: .infinity, alignment: .leading) }
        }
    }
}

struct BubbleText: View {
    let text: String
    let look: BubbleLook
    var highlighted = false
    var trip = BubbleTrip.arrived
    var fromCue = false
    var foldedLines: Int?
    var quote: BubbleQuote?
    @Environment(\.palette) private var palette
    @State private var open = false
    @State private var truncated = false

    var body: some View {
        let shape = look.shape
        HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
            if fromCue { CueMark().alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 } }
            VStack(alignment: .leading, spacing: Spacing.tight) {
                if let quote { QuoteLine(quote: quote) }
                if truncated {
                    Fold(open: $open, edge: .bottom) {
                        DisclosureChevron(open: open)
                            .frame(maxWidth: .infinity, minHeight: Self.toggle, alignment: .trailing).contentShape(.rect)
                            .padding(.bottom, -Spacing.item)
                            .accessibilityLabel(open ? Text("收起") : Text("展开"))
                    } content: { words }
                } else {
                    words
                }
            }
        }
            .padding(look.padding)
            .background(fromCue ? .clear : palette.bubble, in: shape)
            .overlay { edge(shape) }
            .opacity(trip.opacity)
            .animation(Motion.fade, value: highlighted)
            .animation(Motion.fade, value: trip)
    }

    private var words: some View {
        Paragraphs(verbatim: text, lineSpacing: Typography.readingLineSpacing, lineLimit: open ? nil : foldedLines)
            .font(Typography.reading).foregroundStyle(palette.ink)
            .background(alignment: .topLeading) { if let foldedLines, !open { truncationProbe(lineLimit: foldedLines) } }
            .fadesEdge(.bottom, when: truncated && !open)
    }

    private static let toggle: CGFloat = 20

    private func truncationProbe(lineLimit: Int) -> some View {
        GeometryReader { shown in
            let folded = shown.size.height
            Paragraphs(verbatim: text, lineSpacing: Typography.readingLineSpacing, lineLimit: lineLimit + 1).font(Typography.reading).fixedSize(horizontal: false, vertical: true)
                .frame(width: shown.size.width, alignment: .leading)
                .hidden()
                .onGeometryChange(for: Bool.self) { $0.size.height > folded + 1 } action: { truncated = $0 }
        }
    }

    @ViewBuilder private func edge(_ shape: UnevenRoundedRectangle) -> some View {
        switch trip {
        case .failed: shape.strokeBorder(palette.failure, lineWidth: 1)
        case .arrived, .sending, .delivered:
            if highlighted {
                shape.strokeBorder(palette.signature, lineWidth: 2)
            } else if fromCue {
                shape.strokeBorder(palette.track)
            } else if let edge = palette.bubbleEdge {
                shape.strokeBorder(edge)
            }
        }
    }
}

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
