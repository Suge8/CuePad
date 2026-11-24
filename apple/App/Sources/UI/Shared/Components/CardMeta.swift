import CueEditor
import CueStore
import CueText
import SwiftUI

struct CardMeta: View {
    let card: Card
    let text: CardText
    let floated: Bool
    var font: Font = Typography.caption2
    @Environment(\.palette) private var palette

    var body: some View {
        let changed = Text(DateLabel.short(card.modifiedAt)).fixedSize()
        HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
            if let host = text.linkHost {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Spacing.item) { changed; Text(host) }.fixedSize()
                    VStack(alignment: .leading, spacing: Spacing.hair) {
                        changed
                        Text(host).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .layoutPriority(1)
            } else { changed }
            Spacer(minLength: 0)
            if text.files > 0 { AttachmentMark(count: text.files) }
            if card.isTask { Image(.task).help("任务").iconLabel("任务") }
            if floated { Image(.floated).help("刚从更早的灵感里拿回来").iconLabel("刚从更早的灵感里拿回来") }
            if card.isPinned { Image(.pin).help("已置顶").iconLabel("已置顶") }
        }
        .font(font)
        .foregroundStyle(palette.ink3)
    }
}

struct AttachmentMark: View {
    let count: Int

    var body: some View {
        Group {
            if count > 1 {
                Label { Text(verbatim: "\(count)") } icon: { Image(.attachment) }.labelStyle(.titleAndIcon)
            } else {
                Image(.attachment)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("带 \(count) 个附件")
    }
}

enum VariableText {
    static func styled(_ text: String, _ palette: Palette) -> AttributedString {
        var result = AttributedString(text)
        let utf16 = text.utf16
        for range in CueVariables.ranges(in: text, within: NSRange(location: 0, length: utf16.count)) {
            guard let swiftRange = Range(range, in: text), let attributed = Range(swiftRange, in: result) else { continue }
            result[attributed].foregroundColor = palette.ink
            result[attributed].backgroundColor = palette.fill
        }
        return result
    }
}
