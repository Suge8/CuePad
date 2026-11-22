import CueStore
import SwiftUI

struct CueShots: View {
    let shots: [CueShown]
    let group: String
    let open: (PreviewOpening) -> Void
    @Environment(\.palette) private var palette

    #if os(macOS)
    nonisolated static let side: CGFloat = 140
    #else
    nonisolated static let side: CGFloat = 120
    #endif
    nonisolated fileprivate static let gap = PreviewBatch.gap

    nonisolated static func cell(count: Int, width: CGFloat) -> CGFloat {
        let gaps = gap * CGFloat(count - 1)
        guard width.isFinite else { return side }
        return max(0, min(side, ((width - gaps) / CGFloat(count)).rounded(.down)))
    }

    static func floor(count: Int, width: CGFloat) -> CGFloat { count == 0 ? 0 : cell(count: count, width: width) }

    var body: some View {
        let batch = shots.map(\.preview), looks = Dictionary(uniqueKeysWithValues: shots.map { ($0.id, $0.look) })
        ShotRow {
            ForEach(shots) { shot in
                VStack(alignment: .leading, spacing: Spacing.item) {
                    DeliverableTile(
                        preview: shot.preview, label: shot.look, shape: .shot(side: Self.side), captioned: false,
                        zoom: PreviewZoomKey(group: group, preview: shot.id)
                    ) { open(PreviewOpening(preview: $0, batch: batch, group: group, looks: looks)) }
                    caption(shot.look)
                }
            }
        }
    }

    private func caption(_ look: String) -> some View {
        let split = look.range(of: "：") ?? look.range(of: ": ")
        let parts = split.map { [String(look[..<$0.lowerBound]), String(look[$0.upperBound...])] } ?? [look]
        return VStack(alignment: .leading, spacing: Spacing.hair) {
            Text(Self.keepingTail(parts.first ?? look)).fontWeight(.semibold).foregroundStyle(palette.ink)
            if parts.count > 1 { Text(Self.keepingTail(parts[1])).foregroundStyle(palette.ink2) }
        }
        .font(Typography.meta)
        .fixedSize(horizontal: false, vertical: true)
        .readerHidden(true)
    }

    /// 只给显示：句尾最后 4 个字（汉字一个算一个，英文单词、数字一整段算一个，不算标点）连同其间与其后的标点粘成一块，
    /// 换行时不会只剩"我选」。"这样的尾巴挂在下一行。块与块之间插字连接符（U+2060，不占宽、不显示）；不插进单词里面：
    /// 插在字母之间时排版反倒在那里断开（"ma / in"）。没有汉字的（英文界面里 Cue 写的）照常按词折行、不粘：
    /// 窄格一行只排得下两三个词，几个词粘成一块就比格还宽，排版只能在词中间断（"scr / eenshot"）。存储、通知、读屏、复制都用原文。
    private static func keepingTail(_ text: String) -> String {
        func latin(_ character: Character) -> Bool { character.isASCII && (character.isLetter || character.isNumber) }
        guard text.contains(where: { !$0.isASCII && $0.isLetter }) else { return text }
        var rest = Substring(text), pieces: [Substring] = [], counted = 0
        while counted < tailLength, let last = rest.last {
            let length = latin(last) ? rest.reversed().prefix(while: latin).count : 1
            pieces.insert(rest.suffix(length), at: 0)
            rest = rest.dropLast(length)
            if last.isLetter || last.isNumber { counted += 1 }
        }
        guard counted == tailLength else { return text }
        return rest + pieces.joined(separator: "\u{2060}")
    }

    private static let tailLength = 4
}

private struct ShotRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let cell = CueShots.cell(count: subviews.count, width: proposal.width ?? .infinity)
        let height = subviews.map { $0.sizeThatFits(ProposedViewSize(width: cell, height: nil)).height }.max() ?? 0
        return CGSize(width: cell * CGFloat(subviews.count) + CueShots.gap * CGFloat(subviews.count - 1), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let cell = CueShots.cell(count: subviews.count, width: proposal.width ?? .infinity)
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + CGFloat(index) * (cell + CueShots.gap), y: bounds.minY), proposal: ProposedViewSize(width: cell, height: nil))
        }
    }
}
