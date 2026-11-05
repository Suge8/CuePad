import CueStore
import SwiftUI

/// 分组格会话条：等你在上面、推进中在下面独立滚。尺寸只影响排版，三端共用数据、注意顺序与动画预算。
/// 手机（`phone`，60 点竖条）：每组一张纸（列的纸色），格铺满纸，在默认字号、650 点高内完整放下十个会话。
/// 宽屏（`wide`）：不铺纸，组就是会话条那一块上的一段行，靠组头与间距分开；每个会话一行（`RailLine`），行首那一列是会话的状态标（`PiStateDot`），名字在它右边。
/// 组头是小号淡字组名加着色计数，左沿同行首那一列、字贴着下沿，离它那一组近、离上一组远。
/// 等你组每行两行高（`Chrome.tallRow`），推进中一行一种高（`Chrome.row`），长相在 `SessionRailCell`。
/// 等你过多时自身也能滚、最多占一半可用高度，不能把推进中或待回复挤到再也点不到。两组为空时保留列宽，不重排对话。
/// 宽屏的行增删：留下的行按 `Motion.nudge` 让位，进出的淡入淡出（减弱动态效果时不挪、只淡）。
/// 点按只回报会话与意图（`Opening`：默认，或 ⌘ 点的并排）；右键是会话的菜单（`OpenSessionBeside` 与 `SessionActions`，同会话出现的每一处）。`marked` 是调用方主区开着的会话投影，不在组件内记选中。
/// 被否决的：宽屏每组一张纸（等你赭黄、推进中白纸）——三种材质叠在侧栏底上像一摞卡片，不像一条栏；行首放 Agent 标志——同一家的都一样，零信息，状态挤成标志底下一截细线读不出。
struct SessionRail: View {
    enum Form {
        case phone, wide
        /// 手机竖条定宽；宽屏跟着会话条那一块的宽。
        var width: CGFloat? { self == .phone ? 60 : nil }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal = SessionRailReveal()

    private var phone: Bool { form == .phone }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: Chrome.groupGap) {
                if !rows.waiting.isEmpty {
                    group(rows.waiting, column: .waiting, moving: [])
                        .frame(height: min(idealHeight(rows.waiting), geometry.size.height * (rows.advancing.isEmpty ? 1 : 0.5)))
                }
                if !rows.advancing.isEmpty {
                    group(rows.advancing, column: .advancing, moving: rows.moving)
                        .frame(maxHeight: idealHeight(rows.advancing))
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

    /// 相邻两个会话之间：手机的格隔一道纸缝，宽屏的行同会话条上别的行一道缝。
    private var cellGap: CGFloat { phone ? Chrome.cellGap : Spacing.hair }

    private func rowHeight(_ item: SessionRailRows.Item) -> CGFloat {
        if phone { return tileHeight }
        return item.waiting == nil ? Chrome.row : Chrome.tallRow
    }

    private func idealHeight(_ items: [SessionRailRows.Item]) -> CGFloat {
        Chrome.groupHeader + items.map(rowHeight).reduce(0, +) + CGFloat(max(0, items.count - 1)) * cellGap + Chrome.pad
    }

    private func group(_ items: [SessionRailRows.Item], column: TaskBoard.Column, moving: Set<String>) -> some View {
        VStack(spacing: 0) {
            SessionRailHeader(column: column, count: items.count, form: form)
                .frame(height: Chrome.groupHeader)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: cellGap) {
                        ForEach(items) { item in
                            SessionRailCell(item: item, form: form, moves: moving.contains(item.id), selected: marked.contains(item.id), open: open)
                                .frame(height: rowHeight(item))
                                .id(item.id)
                                .transition(.opacity)
                        }
                    }
                    // 行底伸出行框：滚动内容自己留出伸出的那一截（滚动区按自己的边裁）；手机的格铺满纸
                    .padding(.horizontal, phone ? 0 : RowMetrics.bleed)
                    .scrollTargetLayout()
                    .safeAreaPadding(.bottom, Chrome.pad)
                }
                .scrollIndicators(.hidden)
                .animation(phone ? nil : Motion.spatial(Motion.nudge, reduceMotion: reduceMotion) ?? Motion.fade, value: items.map(\.id))
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
        .modifier(GroupSurface(phone: phone, wash: column.paper(palette)))
    }
}

/// 一组的底：手机是一张纸（列的纸色、格铺满纸），宽屏不铺、组就是会话条那一块上的一段行（行容器是那一块，`WideRail`）。
private struct GroupSurface: ViewModifier {
    let phone: Bool
    let wash: Color?

    func body(content: Content) -> some View {
        if phone {
            content
                .rowContainer(.rect(cornerRadius: Radius.block), flush: true)
                .clipShape(.rect(cornerRadius: Radius.block))
                .paper(cornerRadius: Radius.block, wash: wash)
                .padding(.horizontal, SessionRail.phoneInset)
        } else {
            content
        }
    }
}

/// 组头：手机竖条上记号与个数居中；宽屏是淡字组名加着色计数，左沿同行首那一列，字贴着下沿。
private struct SessionRailHeader: View {
    let column: TaskBoard.Column
    let count: Int
    let form: SessionRail.Form
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if form == .phone {
                HStack(spacing: Spacing.tight) {
                    BoardLaneMark(column: column, size: Self.mark)
                    tally
                }
                .font(Typography.caption.weight(.semibold))
                .padding(.horizontal, Spacing.hair)
            } else {
                HStack(spacing: Spacing.glyph) {
                    Text(column.title).foregroundStyle(palette.ink3).lineLimit(1)
                    tally
                }
                .font(Typography.label)
                .padding(.horizontal, RowMetrics.bleed)
                .padding(.bottom, Spacing.tight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(column.title)
        .accessibilityValue(Text(count, format: .number))
        .accessibilityAddTraits(.isHeader)
    }

    private var tally: some View {
        Text(count, format: .number).foregroundStyle(column.countInk(palette)).monospacedDigit()
    }

    private static let mark: CGFloat = 14
}
