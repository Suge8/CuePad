import CueStore
import SwiftUI

/// C 轻重分层（看板的轻重搬到会话条上）：不分颜色块、不画组头，要不要你管直接写在行的分量上，一条从重到轻的流。
/// - 要你管的（等你、出错、上下文快满）是重行（`Chrome.tallRow`）：大号状态标，名字下面一行写它要什么——状态词着状态色，
///   后面是问题原文、留给你回的那句或出错原因，不点开就知道该拍什么板；
/// - 在跑的是中行（`Chrome.control`）：中号状态标，行尾一截正在走的线（`BoardLine` 的现在，同看板卡；运行了多久在悬停提示里，给名字让位）；
/// - 歇着的是轻行（`Chrome.lightRow`）：小号灰标、次要字号淡墨，只写多久前。
/// 收起时一列状态标从上往下由大到小，重的在上：一眼看出要你管的有几个、有没有在跑的。
struct RailProtoC: View {
    let rows: SessionRailRows
    let wide: Bool
    let marked: Set<String>

    var body: some View {
        RailProtoGroups(rows: rows, wide: wide, marked: marked, headerHeight: 0, height: Weight.height(item:)) { _, _ in
            EmptyView()
        } row: { item, moves, selected in
            RowC(item: item, wide: wide, selected: selected, moves: moves)
        }
    }
}

/// 一行的分量：重、中、轻三档，行高与状态标的大小只按它。
private enum Weight {
    case heavy, running, light

    init(_ item: SessionRailRows.Item) {
        self = item.needsYou ? .heavy : item.pulse.tier == .running ? .running : .light
    }

    static func height(item: SessionRailRows.Item) -> CGFloat { Weight(item).height }

    var height: CGFloat {
        switch self {
        case .heavy: Chrome.tallRow
        case .running: Chrome.control
        case .light: Chrome.lightRow
        }
    }

    /// 状态标的基准直径：重的大一档、轻的小一档（`PiStateDot.size`）。
    var mark: CGFloat {
        switch self {
        case .heavy: Chrome.railMark * 1.2
        case .running: Chrome.railMark
        case .light: Chrome.railMark * 0.7
        }
    }
}

private struct RowC: View {
    let item: SessionRailRows.Item
    let wide: Bool
    let selected: Bool
    let moves: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        let weight = Weight(item)
        ProtoLine(wide: wide, height: weight.height) {
            PiStateDot(shown: item.shownState, size: weight.mark)
        } rest: {
            switch weight {
            case .heavy: heavy
            case .running:
                name(Typography.body, palette.ink)
                Spacer(minLength: Spacing.item)
                BoardLine(pulse: item.pulse, moves: moves, detail: .now).frame(width: Chrome.trace)
            case .light:
                name(Typography.secondary, palette.ink3)
                Spacer(minLength: Spacing.item)
                ProtoTime(item: item).font(Typography.caption).fixedSize()
            }
        }
    }

    private func name(_ font: Font, _ ink: Color) -> some View {
        Text(verbatim: item.session.title).font(font.weight(selected ? .semibold : .regular)).foregroundStyle(ink).lineLimit(1)
    }

    private var heavy: some View {
        VStack(alignment: .leading, spacing: Spacing.hair) {
            HStack(spacing: Spacing.item) {
                name(Typography.body, palette.ink)
                Spacer(minLength: 0)
                ProtoTime(item: item).font(Typography.caption).fixedSize()
            }
            ask.font(Typography.caption).lineLimit(1)
        }
    }

    /// 它要什么：状态词（状态色、半粗），后面是原文——问题、留给你回的那句、出错原因或上下文用量。
    @ViewBuilder private var ask: some View {
        let shown = item.shownState
        HStack(spacing: Spacing.tight) {
            if item.waiting == nil, case .context(let meter) = item.pulse.word {
                ContextFact(meter: meter)
            } else {
                Text(shown.label).fontWeight(.semibold).foregroundStyle(shown.labelTint(palette)).fixedSize()
                if let detail { Dot().foregroundStyle(palette.ink3); Text(verbatim: detail).foregroundStyle(palette.ink2) }
            }
        }
    }

    private var detail: String? {
        let session = item.session
        let text: String? = switch item.waiting {
        case .asking: session.question?.displayText ?? session.detail
        case .awaitsReply: session.lastReply
        default: session.detail
        }
        return text.map { $0.split(whereSeparator: \.isNewline).first.map(String.init) ?? $0 }.flatMap { $0.isEmpty ? nil : $0 }
    }
}
