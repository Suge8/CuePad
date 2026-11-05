import CueStore
import SwiftUI

/// A 平铺克制（Linear、Things 3 一路）：状态就是行首那一格。
/// - 行首是会话状态标（`PiStateDot`，全 App 同一份图形）：拍板赭黄问号圆带一圈外扩的波纹、待回复墨点、出错胭脂叹号、在跑靛青心电线、歇着灰；
///   Agent 标志不再占行首（同一家的都一样，零信息），在悬停提示与读屏里。
/// - 组头是小号组名加计数，与名字同一条左边；收起时组名淡去、计数留在行首那一列正中。
/// - 行尾一个读数：要你管的写状态词（同状态色），其余写此刻这个状态待了多久。
/// - 一行一种高（`Chrome.control`），选中只有中性底与半粗字。
struct RailProtoA: View {
    let rows: SessionRailRows
    let wide: Bool
    let marked: Set<String>

    var body: some View {
        RailProtoGroups(rows: rows, wide: wide, marked: marked, height: { _ in Chrome.control }) { column, count in
            HeaderA(column: column, count: count, wide: wide)
        } row: { item, _, selected in
            RowA(item: item, wide: wide, selected: selected)
        }
    }
}

private struct HeaderA: View {
    let column: TaskBoard.Column
    let count: Int
    let wide: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        ProtoLine(wide: wide, height: Chrome.groupHeader) {
            Text(count, format: .number).foregroundStyle(column.countInk(palette))
                .opacity(wide ? 0 : 1)
                .animation(Motion.fade, value: wide)
        } rest: {
            Text(column.title).foregroundStyle(palette.ink2)
            Text(count, format: .number).foregroundStyle(column.countInk(palette))
            Spacer(minLength: 0)
        }
        .font(Typography.label.monospacedDigit())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(column.title)
        .accessibilityValue(Text(count, format: .number))
        .accessibilityAddTraits(.isHeader)
    }
}

private struct RowA: View {
    let item: SessionRailRows.Item
    let wide: Bool
    let selected: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        ProtoLine(wide: wide) {
            PiStateDot(shown: item.shownState, size: Chrome.railMark)
        } rest: {
            Text(verbatim: item.session.title)
                .font(Typography.body.weight(selected ? .semibold : .regular))
                .foregroundStyle(item.resting ? palette.ink2 : palette.ink)
                .lineLimit(1)
            Spacer(minLength: Spacing.item)
            ProtoReadout(item: item)
        }
    }
}
