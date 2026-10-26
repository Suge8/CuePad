import CueStore
import SwiftUI

/// 一问要你定什么，问句只这一套画法：问句（Cue 的是代码写的 `CueMessage.headline`，会话的是问题第一行）与下面那一句
/// （`note`：Cue 的只有规矩那一类引他的原话 `CueAsking.why`，会话的是问题的说明），两行同一条左缘、都不限行；`below` 接在同一条左缘下面（原话）。
/// Cue 页拍板卡、全屏预览的底栏与对话里答完的问句共用，按 `Tone` 分两档：
/// - `card`：拍板卡与预览底栏上，左边赭黄问号（全卡唯一的状态色），问句是标题字；
/// - `ended`：对话里已结束的（`CueSays`），不挂问号、正文字不加粗、次一级的墨，与还在等你的一眼分开。
struct CueQuestionLine<Below: View>: View {
    enum Tone { case card, ended }

    let question: String
    let note: String?
    var tone = Tone.card
    @ViewBuilder var below: Below
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            if tone != .ended { PiStateGlyph(status: .asking).font(Typography.title).accessibilityHidden(true) }
            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                    line.fixedSize(horizontal: false, vertical: true)
                    if let note {
                        Text(CueQuestionLine<EmptyView>.keepingTail(note)).font(Typography.secondary).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                // 读屏读成一句（问句，下面那一句）
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
        case .ended: line.font(Typography.reading).foregroundStyle(palette.ink2).lineSpacing(Typography.readingLineSpacing)
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

    /// 拍板卡上的一件（Cue 的提问或会话在问的，`TaskBoard.Wait.asked`）。
    init(wait: TaskBoard.Wait) {
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

/// Cue 一问的选项，一行排完：第一项"可以"是按字宽的实底主按钮（全卡唯一的靛青）靠右，其余（"以后……不用问"）是同一行左边的小字链接：
/// 一问的主动作只有"可以"，放宽规矩是顺手的事，不和它抢。拍板的答法（`WaitAnswer`：Cue 页拍板卡）与全屏预览的底栏共用；会话的选项胶囊同样靠右（`WaitAnswer`）。
/// 主按钮总在右下角同一处，不随卡宽铺开，不窄过 `onceWidth`；链接长了在左边折行。辅助功能字号时竖排：按钮在上、链接在下，都靠右。
/// Cue 停用着答不了时（`CueSession.canHear`）写"启用 Cue 后再答"在左边链接的位置；只留"可以"、降成次级并停用，不和启用那颗主按钮抢（同屏只一个主动作），启用后恢复。
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
    /// 按钮左右的内边距（`ControlSurface`）：最小宽要扣掉它才是字的宽
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
            VStack(alignment: .trailing, spacing: 4) {
                primary
                side
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            HStack(spacing: 12) {
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

    /// 链接上下让出的点按余量：小字本身太矮，按不准。
    private static let linkInset: CGFloat = 6

    private func note(_ text: String) -> some View {
        Text(text).font(Typography.meta).foregroundStyle(palette.ink2)
    }

    /// 主按钮"可以"：按字宽，不窄过 `onceWidth`；停用着降成次级并停用。
    private func once(_ option: String, paused: Bool) -> some View {
        Button { pick(option) } label: {
            Text(message.shownChoice(option)).multilineTextAlignment(.center).frame(minWidth: Self.onceWidth - Self.inset)
        }
        .buttonStyle(ControlButtonStyle(kind: paused ? .secondary : .primary))
        .accessibilityLabel(message.shownChoice(option))
        .disabled(disabled || paused)
    }
}

/// Cue 点名要你看的图（提问卡与结果卡，`CueShown`，至多 `CueShot.limit` 张），按 Cue 给的先后：一排靠左、一行排完不横滑，每张同样大的方形缩略图
/// （边长 `ShotRow`：放得下就是 `side`，不然几张平分可用宽），取细节最多的那一段填满（`LookBox.framed`）。缩略图本来看不全、都要点开，它只管认出是哪张、邀请点开；
/// 要看什么由每张正下方那一句说（与图同宽、向下换行；含"："的拆两行，前半加粗是名字、后半是说明），辅助功能字号下也一样。
/// 格窄、一行只排得下七八个字，折行时句尾几个字粘成一块（`CueQuestionLine.keepingTail`），不剩一两个字挂在下一行。
/// 点一张全屏看整张，左右翻的就是这几张，页顶写看什么；底栏按 `reply`（拍板卡里是那几个选项，没给照 Cue 页的）。
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

    /// 在 `width` 宽里排 `count` 张时每张的边长（`ShotRow` 照它排）：放得下是 `side`，不然几张平分。
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
                VStack(alignment: .leading, spacing: 8) {
                    DeliverableTile(
                        preview: shot.preview, label: shot.look, shape: .shot(side: Self.side, chosen: shot.id == chosen), captioned: false,
                        zoom: PreviewZoomKey(group: group, preview: shot.id)
                    ) { open(PreviewOpening(preview: $0, batch: batch, group: group, reply: reply, looks: looks)) }
                    caption(shot.look)
                }
            }
        }
    }

    /// 看什么：读屏读图的标签（`DeliverableTile` 的 label），这里只给眼睛看。
    private func caption(_ look: String) -> some View {
        // 名字与说明之间是"："（英文是": "）
        let split = look.range(of: "：") ?? look.range(of: ": ")
        let parts = split.map { [String(look[..<$0.lowerBound]), String(look[$0.upperBound...])] } ?? [look]
        return VStack(alignment: .leading, spacing: 1) {
            Text(CueQuestionLine.keepingTail(parts.first ?? look)).fontWeight(.semibold).foregroundStyle(palette.ink)
            if parts.count > 1 { Text(CueQuestionLine.keepingTail(parts[1])).foregroundStyle(palette.ink2) }
        }
        .font(Typography.meta)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityHidden(true)
    }
}

/// 一排等宽的格，靠左、顶端对齐、一行排完不横滑：格宽是 `CueShots.cell`。
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
