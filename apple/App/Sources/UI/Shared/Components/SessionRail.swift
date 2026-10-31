import CueStore
import SwiftUI

/// 分组格会话条：等你纸钉在上面、推进中在下面独立滚。尺寸只影响排版，三端共用数据、格子、注意顺序与动画预算。
/// 60 点竖条在默认字号、650 点高内完整放下十个会话；72 点用于宽屏收起；220 点一行一个会话。
/// 等你过多时自身也能滚、最多占一半可用高度，不能把推进中或待回复挤到再也点不到。两组为空时保留列宽，不重排对话。
/// 打开只回报会话与意图；宽屏的 ⌘ 点、右键与拖出都不在这里写导航。`marked` 是调用方两栏已打开的会话投影，不在组件内记选中。
struct SessionRail: View {
    enum Form {
        case phone, wide, narrow
        var width: CGFloat { switch self { case .phone: 60; case .wide: 220; case .narrow: 72 } }
        var inset: CGFloat { self == .phone ? 2 : 8 }
    }

    enum Opening { case primary, leading }

    let data: SessionRailData
    let form: Form
    var marked: Set<String> = []
    let pulse: (PiSessionListItem) -> BoardPulse
    let open: (PiSessionState, Opening) -> Void

    var body: some View {
        let rows = SessionRailRows(data, pulse: pulse)
        if form == .wide {
            SessionRailContent(rows: rows, form: form, marked: marked, open: open)
        } else {
            // 常驻窄列同页头限制可见字号；全文留在读屏标签，不能让大字把组头计数挤成省略号。
            SessionRailContent(rows: rows, form: form, marked: marked, open: open).dynamicTypeSize(...DynamicTypeSize.xxLarge)
        }
    }
}

private struct SessionRailContent: View {
    let rows: SessionRailRows
    let form: SessionRail.Form
    let marked: Set<String>
    let open: (PiSessionState, SessionRail.Opening) -> Void
    @Environment(\.palette) private var palette
    @ScaledMetric(relativeTo: .caption2) private var tileHeight: CGFloat = 54

    private var rowHeight: CGFloat {
        if form != .wide { return tileHeight }
        #if os(macOS)
        return 32
        #else
        return max(44, tileHeight)
        #endif
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: Self.groupGap) {
                if !rows.waiting.isEmpty {
                    group(rows.waiting, column: .waiting, moving: [])
                        .frame(height: min(idealHeight(rows.waiting.count), geometry.size.height * (rows.advancing.isEmpty ? 1 : 0.5)))
                }
                if !rows.advancing.isEmpty {
                    group(rows.advancing, column: .advancing, moving: rows.moving)
                        .frame(maxHeight: idealHeight(rows.advancing.count))
                }
                Spacer(minLength: 0)
            }
        }
        .frame(width: form.width)
    }

    private static let groupGap: CGFloat = 10
    private static let cellGap: CGFloat = 4
    private static let headerHeight: CGFloat = 28
    private static let bottomInset: CGFloat = 4

    private func idealHeight(_ count: Int) -> CGFloat {
        Self.headerHeight + CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * Self.cellGap + Self.bottomInset
    }

    private func group(_ items: [SessionRailRows.Item], column: TaskBoard.Column, moving: Set<String>) -> some View {
        VStack(spacing: 0) {
            SessionRailHeader(column: column, count: items.count, wide: form == .wide)
                .frame(height: Self.headerHeight)
            ScrollView {
                LazyVStack(spacing: Self.cellGap) {
                    ForEach(items) { item in
                        SessionRailCell(item: item, form: form, moves: moving.contains(item.id), selected: marked.contains(item.id), open: open)
                            .frame(minHeight: rowHeight)
                    }
                }
                .safeAreaPadding(.bottom, Self.bottomInset)
            }
            .scrollIndicators(.hidden)
        }
        .rowContainer(.rect(cornerRadius: Radius.block), flush: true)
        .clipShape(.rect(cornerRadius: Radius.block))
        .paper(cornerRadius: Radius.block, wash: column.paper(palette))
        .padding(.horizontal, form.inset)
    }
}

private struct SessionRailHeader: View {
    let column: TaskBoard.Column
    let count: Int
    let wide: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            BoardLaneMark(column: column, size: 14)
            if wide { Text(column.title).foregroundStyle(palette.ink2) }
            Text(count, format: .number).foregroundStyle(column.countInk(palette)).monospacedDigit()
            if wide { Spacer(minLength: 0) }
        }
        .font(Typography.caption.weight(.semibold))
        .padding(.horizontal, wide ? 8 : 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(column.title)
        .accessibilityValue(Text(count, format: .number))
        .accessibilityAddTraits(.isHeader)
    }
}
