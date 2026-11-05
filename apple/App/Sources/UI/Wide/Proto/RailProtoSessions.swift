import CueStore
import SwiftUI

/// 会话那一段（A 平铺克制，等你组借 C）：状态就是行首那一格。
/// - 行首是会话状态标（`PiStateDot`，全 App 同一份图形）：拍板赭黄问号圆带外扩的波纹、待回复墨点、出错胭脂叹号、在跑靛青心电线、歇着灰；
///   Agent 标志不占行首（同一家都一样，零信息），在悬停提示与读屏里。
/// - 组头是小号组名加计数，组名与名字同一条左边；收起时组名淡去、计数留在行首那一列正中。
/// - 等你组每行两行高（`Chrome.tallRow`）：名字与等了多久一行，下面一行写它要什么（状态词着状态色，后面是问题原文或留给你回的那句）。
///   这一行一直占着：没有原文时只写状态词，行高不随状态跳。
/// - 推进中一行一种高（`Chrome.control`），行尾一个读数：要你管的写状态词，其余写此刻这个状态待了多久。
/// - 选中只有中性底与半粗字。
struct RailProtoSessions: View {
    let rows: SessionRailRows
    let wide: Bool
    let marked: Set<String>

    var body: some View {
        RailProtoGroups(rows: rows, wide: wide, marked: marked, height: { $0.waiting == nil ? Chrome.control : Chrome.tallRow }) { column, count in
            Header(column: column, count: count, wide: wide)
        } row: { item, _, selected in
            if item.waiting == nil {
                AdvancingRow(item: item, wide: wide, selected: selected)
            } else {
                WaitingRow(item: item, wide: wide, selected: selected)
            }
        }
    }
}

private struct Header: View {
    let column: TaskBoard.Column
    let count: Int
    let wide: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        ProtoLine(wide: wide, height: Chrome.groupHeader) {
            tally.opacity(wide ? 0 : 1).animation(Motion.fade, value: wide)
        } rest: {
            Text(column.title).foregroundStyle(palette.ink3)
            tally
            Spacer(minLength: 0)
        }
        .font(Typography.label)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(column.title)
        .accessibilityValue(Text(count, format: .number))
        .accessibilityAddTraits(.isHeader)
    }

    private var tally: some View {
        Text(count, format: .number).foregroundStyle(column.countInk(palette)).monospacedDigit()
    }
}

private struct Name: View {
    let item: SessionRailRows.Item
    let selected: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Text(verbatim: item.session.title)
            .font(Typography.body.weight(selected ? .semibold : .regular))
            .foregroundStyle(item.resting ? palette.ink2 : palette.ink)
            .lineLimit(1)
    }
}

private struct AdvancingRow: View {
    let item: SessionRailRows.Item
    let wide: Bool
    let selected: Bool

    var body: some View {
        ProtoLine(wide: wide) {
            PiStateDot(shown: item.shownState, size: Chrome.railMark)
        } rest: {
            Name(item: item, selected: selected)
            Spacer(minLength: Spacing.item)
            ProtoReadout(item: item)
        }
    }
}

private struct WaitingRow: View {
    let item: SessionRailRows.Item
    let wide: Bool
    let selected: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        ProtoLine(wide: wide, height: Chrome.tallRow) {
            PiStateDot(shown: item.shownState, size: Chrome.railMark)
        } rest: {
            VStack(alignment: .leading, spacing: Spacing.hair) {
                HStack(spacing: Spacing.item) {
                    Name(item: item, selected: selected)
                    Spacer(minLength: 0)
                    ProtoTime(item: item).font(Typography.caption).fixedSize()
                }
                ask.font(Typography.caption).lineLimit(1)
            }
        }
    }

    /// 它要什么：状态词（状态色、半粗），后面是原文——要你拍板的问题、留给你回的那句。
    private var ask: some View {
        let shown = item.shownState
        return HStack(spacing: Spacing.tight) {
            Text(shown.label).fontWeight(.semibold).foregroundStyle(shown.labelTint(palette)).fixedSize()
            if let detail {
                Dot().foregroundStyle(palette.ink3)
                Text(verbatim: detail).foregroundStyle(palette.ink2)
            }
        }
    }

    private var detail: String? {
        let session = item.session
        let text = item.waiting == .asking ? session.question?.displayText ?? session.detail : session.lastReply
        let line = text?.split(whereSeparator: \.isNewline).first.map(String.init)
        return line?.isEmpty == false ? line : nil
    }
}
