import CueStore
import SwiftUI

/// "等你"那一句要你定什么：两列，左边赭黄问号（全卡唯一的状态色）、右边代码写出的问题（`CueMessage.headline`），规矩那一类下面再一行
/// 引的规矩（`CueAsking.why`），两行同一条左缘、都不限行。"等你"卡与全屏预览的底栏共用。
struct CueQuestionLine: View {
    let message: CueMessage
    @Environment(\.palette) private var palette

    var body: some View {
        let headline = message.headline ?? "", why = message.asking?.why
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            PiStateGlyph(status: .asking).font(Typography.title)
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.keepingTail(headline)).font(Typography.title).foregroundStyle(palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let why {
                    Text(Self.keepingTail(why)).font(Typography.secondary).foregroundStyle(palette.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([headline, why].compactMap(\.self).joined(separator: "，"))
    }

    /// 只给显示：句尾最后 4 个字（汉字一个算一个，英文单词、数字一整段算一个，不算标点）连同其间与其后的标点粘成一块，
    /// 换行时不会只剩"我选」。"这样的尾巴挂在下一行。块与块之间插字连接符（U+2060，不占宽、不显示）；不插进单词里面：
    /// 插在字母之间时排版反倒在那里断开（"ma / in"）。存储、通知、读屏、复制都用原文。
    static func keepingTail(_ text: String) -> String {
        func latin(_ character: Character) -> Bool { character.isASCII && (character.isLetter || character.isNumber) }
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

/// "等你"的选项：第一项"可以"是实底主按钮（全卡唯一的靛青），其余（"以后……不用问"）是次级按钮（浅底细边的胶囊，一眼看得出能点）。"等你"卡与全屏预览的底栏共用。
/// 窄屏（手机、窄窗口的 iPad）竖排："可以"铺满一行在上，次级按钮同宽在它下面、长了折行。摆法不随选项的字长变，主按钮总在同一处、最好按。
/// 宽处（Mac、宽屏 iPad）横排在一行尾端：次级按钮在"可以"左边，"可以"不窄过 `onceWidth`、不随卡宽铺开；一行放不下或辅助功能字号时照样竖排、按字宽收着。
/// `hint`：点名的图里"可以"选的是其中一张时（`CueShots.chosen`），一句告诉你选别的去哪说，竖排在按钮下面、横排在按钮左边。
struct CueChoices: View {
    let options: [String]
    var disabled = false
    var hint: String?
    let pick: (String) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.palette) private var palette
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    #if os(macOS)
    static let onceWidth: CGFloat = 96
    private static let stackGap: CGFloat = 4
    private var stacks: Bool { false }
    #else
    static let onceWidth: CGFloat = 88
    private static let stackGap: CGFloat = 8
    private var stacks: Bool { sizeClass != .regular }
    #endif
    /// 按钮左右的内边距（`ControlSurface`）：最小宽要扣掉它才是字的宽
    private static let inset: CGFloat = 32

    var body: some View {
        let once = options.first ?? CueAsk.once, others = Array(options.dropFirst())
        let stacked = VStack(spacing: Self.stackGap) {
            button(once, kind: .primary, fill: true)
            ForEach(others, id: \.self) { button($0, kind: .secondary, fill: true) }
            if let hint { note(hint).multilineTextAlignment(.center) }
        }
        // 不铺满时竖排也按字宽收着（"可以"与次级按钮同宽）
        .fixedSize(horizontal: !stacks, vertical: false)
        let row = HStack(spacing: 8) {
            if let hint { note(hint).lineLimit(1).padding(.trailing, 4) }
            ForEach(others, id: \.self) { button($0, kind: .secondary).lineLimit(1).fixedSize() }
            button(once, kind: .primary, minWidth: Self.onceWidth).lineLimit(1)
        }
        if stacks || typeSize.isAccessibilitySize {
            stacked
        } else if others.isEmpty {
            // 只有"可以"时一行总放得下，不挑（`ViewThatFits` 两份都要建）
            row
        } else {
            ViewThatFits(in: .horizontal) {
                row
                stacked
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(Typography.meta).foregroundStyle(palette.ink2)
    }

    private func button(_ option: String, kind: ControlButtonStyle.Kind, fill: Bool = false, minWidth: CGFloat = 0) -> some View {
        Button { pick(option) } label: {
            Text(option).multilineTextAlignment(.center)
                .frame(minWidth: max(0, minWidth - Self.inset), maxWidth: fill ? .infinity : nil)
        }
        .buttonStyle(ControlButtonStyle(kind: kind))
        .disabled(disabled)
    }
}

/// Cue 点名要你看的图（提问卡与结果卡，`CueShown`，至多 `CueShot.limit` 张），按 Cue 给的先后：一排靠左、一行排完不横滑，每张同样大的方形缩略图
/// （边长 `ShotRow`：放得下就是 `side`，不然几张平分可用宽），取细节最多的那一段填满（`LookBox.salient`）。缩略图本来看不全、都要点开，它只管认出是哪张、邀请点开；
/// 要看什么由每张正下方那一句说（与图同宽、向下换行；含"："的拆两行，前半加粗是名字、后半是说明），辅助功能字号下也一样。
/// 点一张全屏看整张，左右翻的就是这几张，页顶写看什么；底栏按 `reply`（"等你"里是那几个选项）。
/// `chosen`："可以"选的就是其中这一张（`chosen(for:in:)`），它描一圈主按钮的靛青。
struct CueShots: View {
    let shots: [CueShown]
    let group: String
    let reply: PreviewReply
    var chosen: UUID?
    let open: (PreviewOpening) -> Void
    @Environment(\.palette) private var palette

    #if os(macOS)
    static let side: CGFloat = 140
    #else
    static let side: CGFloat = 120
    #endif
    fileprivate static let gap = PreviewBatch.gap

    /// 在 `width` 宽里排 `count` 张时每张的边长（`ShotRow` 照它排）：放得下是 `side`，不然几张平分。
    static func cell(count: Int, width: CGFloat) -> CGFloat {
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
        let parts = look.split(separator: "：", maxSplits: 1).map(String.init)
        return VStack(alignment: .leading, spacing: 1) {
            Text(parts.first ?? look).fontWeight(.semibold).foregroundStyle(palette.ink)
            if parts.count > 1 { Text(parts[1]).foregroundStyle(palette.ink2) }
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
