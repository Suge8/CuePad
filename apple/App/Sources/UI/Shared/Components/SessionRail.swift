import CueStore
import SwiftUI

/// 分组格会话条：等你纸钉在上面、推进中在下面独立滚。尺寸只影响排版，三端共用数据、格子、注意顺序与动画预算。
/// 60 点竖条（手机）在默认字号、650 点高内完整放下十个会话。宽屏（`wide` 展开、`narrow` 收起）同一套排法（`Chrome` 头注释）：每个会话一行，
/// 行首一格（`Chrome.control` 见方，Agent 标志上、状态记号下）在条的中轴上，名字在它右边，收起时淡去、改在悬停提示里；组头的记号与个数也在那一列，组名在右边。
/// 等你过多时自身也能滚、最多占一半可用高度，不能把推进中或待回复挤到再也点不到。两组为空时保留列宽，不重排对话。
/// 点按只回报会话与意图（`Opening`：默认，或 ⌘ 点的并排）；右键是会话的菜单（`OpenSessionBeside` 与 `SessionActions`，同会话出现的每一处）。`marked` 是调用方主区开着的会话投影，不在组件内记选中。
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
        // 常驻的栏同页头限制可见字号；全文留在读屏标签，不能让大字把组头计数挤成省略号。
        SessionRailContent(rows: SessionRailRows(data, pulse: pulse), form: form, marked: marked, open: open)
            .dynamicTypeSize(...DynamicTypeSize.xxLarge)
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

    private var rowHeight: CGFloat { form == .phone ? tileHeight : Chrome.control }

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

    /// 格在纸里让出多少：宽屏的行就是底、只留纸的内边（`Chrome.pad`），手机的格铺满纸。
    private var cellInset: CGFloat { form == .phone ? 0 : Chrome.pad }

    private func group(_ items: [SessionRailRows.Item], column: TaskBoard.Column, moving: Set<String>) -> some View {
        VStack(spacing: 0) {
            SessionRailHeader(column: column, count: items.count, form: form)
                .frame(height: Self.headerHeight)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: Self.cellGap) {
                        ForEach(items) { item in
                            SessionRailCell(item: item, form: form, moves: moving.contains(item.id), selected: marked.contains(item.id), open: open)
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
        .rowContainer(.rect(cornerRadius: Radius.block), flush: form == .phone)
        .clipShape(.rect(cornerRadius: Radius.block))
        .paper(cornerRadius: Radius.block, wash: column.paper(palette))
        .padding(.horizontal, form == .phone ? SessionRail.phoneInset : Chrome.edge)
    }
}

/// 组头：记号与个数。手机竖条上两者居中；宽屏在行首那一列（与格里的标志同一列），组名在右边、收起时淡去。
private struct SessionRailHeader: View {
    let column: TaskBoard.Column
    let count: Int
    let form: SessionRail.Form
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if form == .phone {
                tally.padding(.horizontal, Spacing.hair)
            } else {
                RailLine(wide: form == .wide, height: Chrome.groupHeader) { tally } rest: { Text(column.title).foregroundStyle(palette.ink2).lineLimit(1) }
                    .padding(.horizontal, Chrome.pad)
            }
        }
        .font(Typography.caption.weight(.semibold))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(column.title)
        .accessibilityValue(Text(count, format: .number))
        .accessibilityAddTraits(.isHeader)
    }

    private var tally: some View {
        HStack(spacing: Spacing.tight) {
            BoardLaneMark(column: column, size: Self.mark)
            Text(count, format: .number).foregroundStyle(column.countInk(palette)).monospacedDigit()
        }
    }

    private static let mark: CGFloat = 14
}
