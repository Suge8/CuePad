import CueStore
import SwiftUI

/// 问句只这一套画法：拍板卡、全屏预览的底栏与对话里答完的问句共用。
struct CueQuestionLine<Below: View>: View {
    enum Tone { case card, ended }

    let question: String
    let note: String?
    var tone = Tone.card
    @ViewBuilder var below: Below
    @ScaledMetric(relativeTo: .body) private var readingSpacing = Typography.readingLineSpacing
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
            if tone != .ended { StateGlyph(status: .asking).font(Typography.title).readerHidden(true) }
            VStack(alignment: .leading, spacing: Spacing.tight) {
                VStack(alignment: .leading, spacing: Spacing.tight) {
                    line.fixedSize(horizontal: false, vertical: true)
                    if let note {
                        Text(CueQuestionLine<EmptyView>.keepingTail(note)).font(Typography.secondary).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel([question, note].compactMap(\.self).joined(separator: "，"))
                below
            }
            if tone == .card { Spacer(minLength: 0) }
        }
    }

    @ViewBuilder private var line: some View {
        let line = Text(CueQuestionLine<EmptyView>.keepingTail(question))
        switch tone {
        case .card: line.font(Typography.title).foregroundStyle(palette.ink)
        case .ended: line.font(Typography.reading).foregroundStyle(palette.ink2).lineSpacing(readingSpacing)
        }
    }
}

extension CueQuestionLine {
    init(message: CueMessage, tone: Tone = .card, @ViewBuilder below: () -> Below) {
        self.init(question: message.headline ?? "", note: message.asking?.why, tone: tone, below: below)
    }
}

extension CueQuestionLine where Below == EmptyView {
    init(message: CueMessage, tone: Tone = .card) {
        self.init(message: message, tone: tone) { EmptyView() }
    }

    init(wait: CueWait) {
        let asked = wait.asked
        self.init(question: asked.line, note: asked.detail) { EmptyView() }
    }

    /// 只给显示：句尾最后 4 个字（汉字一个算一个，英文单词、数字一整段算一个，不算标点）连同其间与其后的标点粘成一块，
    /// 换行时不会只剩"我选」。"这样的尾巴挂在下一行。块与块之间插字连接符（U+2060，不占宽、不显示）；不插进单词里面：
    /// 插在字母之间时排版反倒在那里断开（"ma / in"）。没有汉字的（英文界面里 Cue 写的）照常按词折行、不粘：
    /// 窄格一行只排得下两三个词，几个词粘成一块就比格还宽，排版只能在词中间断（"scr / eenshot"）。存储、通知、读屏、复制都用原文。
    static func keepingTail(_ text: String) -> String {
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

/// 一问的主动作只有"可以"，放宽规矩是顺手的事，不和它抢。
/// Cue 停用着答不了时（`CueWatch.canHear`）只留"可以"、降成次级并停用，不和启用那颗主按钮抢（同屏只一个主动作），启用后恢复。
struct CueChoices: View {
    let message: CueMessage
    var disabled = false
    let pick: (String) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.palette) private var palette

    #if os(macOS)
    static let onceWidth: CGFloat = 96
    #else
    static let onceWidth: CGFloat = 88
    #endif
    /// `ControlSurface` 按钮左右内边距之和：最小宽要扣掉它才是字的宽。
    private static let inset: CGFloat = 32

    var body: some View {
        // 停用着只留停用的"可以"：别的选项此刻同样选不了
        let cue = workspace.cue, paused = !cue.canHear, accessible = typeSize.isAccessibilitySize, options = message.choices ?? []
        let side = VStack(alignment: accessible ? .trailing : .leading, spacing: 0) {
            if paused { note(String(localized: "启用 \(cue.name) 后再答")) }
            if !paused { ForEach(options.dropFirst(), id: \.self) { link($0) } }
        }
        .multilineTextAlignment(accessible ? .trailing : .leading)
        let primary = once(options.first ?? CueAsk.once, paused: paused).lineLimit(1).fixedSize()
        if accessible {
            VStack(alignment: .trailing, spacing: Spacing.tight) {
                primary
                side
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            HStack(spacing: Spacing.group) {
                side
                Spacer(minLength: 0)
                primary
            }
        }
    }

    /// 次要的选项：一行小字，点了照样答这一项（存下的原文；写的是这台设备语言的那句，`CueMessage.shownChoice`）。
    private func link(_ option: String) -> some View {
        Button { pick(option) } label: {
            Text(message.shownChoice(option)).font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink2)
                .padding(.vertical, Self.linkInset).contentShape(.rect)
        }
        .buttonStyle(PressStyle(.inline))
        .disabled(disabled)
    }

    private static let linkInset: CGFloat = 6

    private func note(_ text: String) -> some View {
        Text(text).font(Typography.meta).foregroundStyle(palette.ink2)
    }

    private func once(_ option: String, paused: Bool) -> some View {
        Button { pick(option) } label: {
            Text(message.shownChoice(option)).multilineTextAlignment(.center).frame(minWidth: Self.onceWidth - Self.inset)
        }
        .buttonStyle(ControlButtonStyle(kind: paused ? .secondary : .primary))
        .accessibilityLabel(message.shownChoice(option))
        .disabled(disabled || paused)
    }
}

/// 缩略图本来看不全、都要点开，它只管认出是哪张、邀请点开；要看什么由每张正下方那一句说。
/// `chosen`："可以"选的就是其中这一张（`chosen(for:in:)`），它描一圈主按钮的靛青。
struct CueShots: View {
    let shots: [CueShown]
    let group: String
    var reply: PreviewReply?
    var chosen: UUID?
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

    /// 这一块至少多高（Cue 页数格子，`CuePage.floor`）：图的边长，不算下面那句说明，只能数少。
    static func floor(count: Int, width: CGFloat) -> CGFloat { count == 0 ? 0 : cell(count: count, width: width) }

    /// 几张里"可以"选的是哪张：Cue 写的动作（"按方案 1 决定单改提问卡"）里提到的那张图的名字（看什么"："前那半），恰好一张时才算；
    /// 一张都没提到（证据图）或提到不止一张时不标，问句本身说了做什么。
    static func chosen(for asking: CueAsking?, in shots: [CueShown]) -> UUID? {
        guard let action = asking?.action, shots.count > 1 else { return nil }
        let named = shots.filter { action.contains($0.look.split(separator: "：", maxSplits: 1).first ?? "") }
        return named.count == 1 ? named[0].id : nil
    }

    var body: some View {
        let batch = shots.map(\.preview), looks = Dictionary(uniqueKeysWithValues: shots.map { ($0.id, $0.look) })
        ShotRow {
            ForEach(shots) { shot in
                VStack(alignment: .leading, spacing: Spacing.item) {
                    DeliverableTile(
                        preview: shot.preview, label: shot.look, shape: .shot(side: Self.side, chosen: shot.id == chosen), captioned: false,
                        zoom: PreviewZoomKey(group: group, preview: shot.id)
                    ) { open(PreviewOpening(preview: $0, batch: batch, group: group, reply: reply, looks: looks)) }
                    caption(shot.look)
                }
            }
        }
    }

    private func caption(_ look: String) -> some View {
        let split = look.range(of: "：") ?? look.range(of: ": ")
        let parts = split.map { [String(look[..<$0.lowerBound]), String(look[$0.upperBound...])] } ?? [look]
        return VStack(alignment: .leading, spacing: Spacing.hair) {
            Text(CueQuestionLine.keepingTail(parts.first ?? look)).fontWeight(.semibold).foregroundStyle(palette.ink)
            if parts.count > 1 { Text(CueQuestionLine.keepingTail(parts[1])).foregroundStyle(palette.ink2) }
        }
        .font(Typography.meta)
        .fixedSize(horizontal: false, vertical: true)
        .readerHidden(true)
    }
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
