import CueStore
import SwiftUI

/// 分组格会话条：等你纸钉在上面、推进中在下面独立滚。尺寸只影响排版，三端共用数据、格子、注意顺序与动画预算。
/// 60 点竖条（手机）在默认字号、650 点高内完整放下十个会话；宽屏收起是图标条（`Chrome.strip`）：每个会话一格（`Chrome.control` 见方，Agent 标志上、状态记号下，
/// 名字在悬停提示里），纸只比格宽出一圈、在条的中轴上；宽屏一行一个会话（`Chrome.rail`）。尺寸全在 `Chrome`。
/// 等你过多时自身也能滚、最多占一半可用高度，不能把推进中或待回复挤到再也点不到。两组为空时保留列宽，不重排对话。
/// 打开只回报会话与意图（`Opening`：默认，或 ⌘ 点、右键"在旁边打开"的并排）；不在这里写导航。`marked` 是调用方主区开着的会话投影，不在组件内记选中。
struct SessionRail: View {
    enum Form {
        case phone, wide, narrow
        var width: CGFloat { switch self { case .phone: 60; case .wide: Chrome.rail; case .narrow: Chrome.strip } }
    }

    static let chatInset: CGFloat = 52
    /// 手机竖条的纸离屏边（格铺满纸）。
    static let phoneInset: CGFloat = 2

    enum Opening { case primary, beside }

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
    @ScaledMetric(relativeTo: .caption2) private var tileHeight: CGFloat = 52

    @Environment(\.relayStage) private var stage
    @Environment(\.pageActive) private var active
    @State private var reveal = SessionRailReveal()

    private var rowHeight: CGFloat {
        switch form {
        case .narrow: Chrome.control
        case .phone: tileHeight
        #if os(macOS)
        case .wide: Chrome.row
        #else
        case .wide: max(Chrome.row, tileHeight)
        #endif
        }
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
            .frame(maxWidth: .infinity)
        }
        .onChange(of: [rows.waiting.map(\.id), rows.advancing.map(\.id)], initial: true) { _, groups in reveal.update(groups) }
        .onChange(of: active, initial: true) { _, active in reveal.active = active }
        .onAppear { stage?.register(reveal); reveal.active = active }
        .onDisappear { reveal.active = false }
        .frame(width: form.width)
    }

    private static var groupGap: CGFloat { Chrome.groupGap }
    private static var cellGap: CGFloat { Chrome.cellGap }
    private static var headerHeight: CGFloat { Chrome.groupHeader }
    private static var bottomInset: CGFloat { Chrome.pad }

    private func idealHeight(_ count: Int) -> CGFloat {
        Self.headerHeight + CGFloat(count) * rowHeight + CGFloat(max(0, count - 1)) * Self.cellGap + Self.bottomInset
    }

    /// 格在纸里让出多少：宽版的行向两边让出底（`Chrome.rowInset`），图标条的格就是底、只留纸的内边（`Chrome.pad`），手机的格铺满纸。
    private var cellInset: CGFloat {
        switch form {
        case .phone: 0
        case .wide: Chrome.rowInset
        case .narrow: Chrome.pad
        }
    }

    private func group(_ items: [SessionRailRows.Item], column: TaskBoard.Column, moving: Set<String>) -> some View {
        VStack(spacing: 0) {
            SessionRailHeader(column: column, count: items.count, wide: form == .wide)
                .frame(height: Self.headerHeight)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Self.cellGap) {
                        ForEach(items) { item in
                            SessionRailCell(item: item, form: form, moves: moving.contains(item.id), selected: marked.contains(item.id), open: open)
                                .frame(width: form == .narrow ? Chrome.control : nil)
                                .frame(minHeight: rowHeight)
                                .id(item.id)
                        }
                    }
                    // 行底伸出行框：滚动内容自己留出让出的那一截（滚动区按自己的边裁）
                    .padding(.horizontal, cellInset)
                    .scrollTargetLayout()
                    .safeAreaPadding(.bottom, Self.bottomInset)
                }
                .scrollIndicators(.hidden)
                .onScrollPhaseChange { _, phase in
                    if phase == .idle { reveal.busy.remove(column) } else { reveal.busy.insert(column) }
                }
                .onScrollTargetVisibilityChange(idType: String.self, threshold: 1) { reveal.visible[column] = Set($0) }
                .onAppear {
                    reveal.register(column) { id in
                        var transaction = Transaction(animation: nil)
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
                .onDisappear { reveal.remove(column) }
            }
        }
        .frame(width: form == .narrow ? Chrome.stripGroup : nil)
        .rowContainer(.rect(cornerRadius: Radius.block), flush: form == .phone)
        .clipShape(.rect(cornerRadius: Radius.block))
        .paper(cornerRadius: Radius.block, wash: column.paper(palette))
        .padding(.horizontal, form == .phone ? SessionRail.phoneInset : form == .wide ? Chrome.gutter : 0)
    }
}

private struct SessionRailHeader: View {
    let column: TaskBoard.Column
    let count: Int
    let wide: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 4) {
            BoardLaneMark(column: column, size: Self.mark)
            if wide { Text(column.title).foregroundStyle(palette.ink2) }
            Text(count, format: .number).foregroundStyle(column.countInk(palette)).monospacedDigit()
            if wide { Spacer(minLength: 0) }
        }
        .font(Typography.caption.weight(.semibold))
        // 宽版的记号与格里的标志同一列（格让出 `Chrome.rowInset`、格里再 `rowLead`，记号在 `Chrome.icon` 那一列里居中）
        .padding(.horizontal, wide ? Chrome.rowInset + Chrome.rowLead + (Chrome.icon - Self.mark) / 2 : 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(column.title)
        .accessibilityValue(Text(count, format: .number))
        .accessibilityAddTraits(.isHeader)
    }

    private static let mark: CGFloat = 14
}
