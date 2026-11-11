import CueStore
import SwiftUI

/// 这就是最后一层，不再有点开的：不是按钮、没有按压。打开明细本身就会刷新，不另放刷新钮。
/// 配色只用墨：余量足是次要墨色，用过七成是墨色，九成起与用完是胭脂（同上下文快满的口径，不借赭黄、不用靛青）。
/// 读数在新观测到达、变陈旧与每个窗口的重置时刻变化时才变（`Moments` 睡到 `nextReset(after:)`）；没有常驻动画与周期定时器。
struct QuotaDetail: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let quotas = services.accountQuotas.items
        VStack(alignment: .leading, spacing: Spacing.block) {
            if quotas.isEmpty {
                QuotaEmpty()
            } else {
                readings(quotas)
            }
            QuotaRefreshNote()
        }
    }

    private func readings(_ quotas: [AccountQuota]) -> some View {
        Moments(next: quotas.nextReset(after:)) { now in
            let meters = QuotaMeter.all(quotas, at: now)
            VStack(alignment: .leading, spacing: Spacing.block) {
                // 读屏按定好的顺序：两栏的块上沿相近时，系统按几何会先读左栏下面那块
                QuotaColumns {
                    ForEach(Array(meters.enumerated()), id: \.element.id) { index, meter in
                        QuotaAccount(meter: meter).accessibilitySortPriority(Double(meters.count - index))
                    }
                }
                if let updated = meters.filter({ $0.status == nil }).compactMap(\.updatedAt).min() {
                    LiveText(style: SessionClock.ago(updated).live(.list)) { Text("\($0)更新") }
                        .font(Typography.caption).foregroundStyle(palette.ink3)
                        .help(updated.formatted(date: .abbreviated, time: .standard))
                }
            }
        }
    }
}

#if os(macOS)
extension QuotaDetail {
    /// Mac 侧栏气泡的宽：两个账号起放得下两栏（`QuotaColumns`），否则一栏、同别的气泡最宽那一档。定宽：读数随时间变，宽不跟着跳。
    static func bubbleWidth(accounts: Int) -> BubblePlacement.Width {
        .fixed(accounts > 1 ? QuotaColumns.column * 2 + QuotaColumns.gap + SidebarQuota.padding * 2 : BubblePlacement.maxWidth)
    }
}
#endif

private struct QuotaEmpty: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            Text("还没有额度").font(Typography.secondary.weight(.medium)).foregroundStyle(palette.ink)
            Text("连接 Agent 会话后，这里显示订阅额度与 API 余额")
                .font(Typography.meta).foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 账号放得下就排成两栏：按顺序（`QuotaMeter.ordered`）一块块放进当时较矮的那一栏，一样高放左栏（块高矮不一，按行对齐会留空洞）。
/// 每块落在当时最矮那栏的底下，所以各块上沿随顺序只增不减：从上往下扫就是定好的顺序，读屏同序。
/// 位置只由顺序与各块形状定，刷新不挪；账号失败、少了窗口这类形状变了才可能换栏。
struct QuotaColumns: Layout {
    static let column: CGFloat = 248
    static let gap: CGFloat = 32
    private static let lineSpacing: CGFloat = 18

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (subviews.count > 1 ? Self.column * 2 + Self.gap : Self.column)
        let (_, heights) = arrange(width, subviews)
        return CGSize(width: width, height: heights.max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let (places, _) = arrange(bounds.width, subviews)
        for (subview, place) in zip(subviews, places) {
            subview.place(at: CGPoint(x: bounds.minX + place.x, y: bounds.minY + place.y), proposal: ProposedViewSize(width: place.width, height: nil))
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> ([(x: CGFloat, y: CGFloat, width: CGFloat)], [CGFloat]) {
        let count = subviews.count > 1 && width + 1 >= Self.column * 2 + Self.gap ? 2 : 1
        let column = (width - Self.gap * CGFloat(count - 1)) / CGFloat(count)
        var heights = Array(repeating: CGFloat(0), count: count)
        var places: [(x: CGFloat, y: CGFloat, width: CGFloat)] = []
        for subview in subviews {
            let block = subview.sizeThatFits(ProposedViewSize(width: column, height: nil)).height
            let index = heights.indices.min { heights[$0] < heights[$1] }!
            let y = heights[index] == 0 ? 0 : heights[index] + Self.lineSpacing
            places.append((CGFloat(index) * (column + Self.gap), y, column))
            heights[index] = y + block
        }
        return (places, heights)
    }
}

/// 一个账号：标志、产品名与套餐一行（同一产品有几个账号时接账号名，要标出的状态靠右），下面读数与窗口各占定好的行数。
private struct QuotaAccount: View {
    let meter: QuotaMeter
    @Environment(\.palette) private var palette

    /// 随动态字体放大：图标跟着字放大，定宽的列在大字号下放不下，压到账号名上。
    @ScaledMetric(relativeTo: .subheadline) private var iconColumn: CGFloat = 20
    private static let iconGap: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            HStack(spacing: Self.iconGap) {
                Provider(id: meter.provider).mark?.image
                    .foregroundStyle(palette.ink2)
                    .frame(width: iconColumn)
                MetaLine(gap: Spacing.item) { title } meta: { status }
            }
            if meter.balance != nil || !meter.values.isEmpty || !meter.windows.isEmpty || meter.usageURL != nil {
                VStack(alignment: .leading, spacing: Spacing.item) {
                    if let balance = meter.balance { balanceRow(balance) }
                    ForEach(Array(meter.values.enumerated()), id: \.offset) { _, value in QuotaValueRow(value: value) }
                    ForEach(meter.windows) { QuotaWindowRow(window: $0) }
                    if let url = meter.usageURL { Link("管理用量", destination: url).font(Typography.meta) }
                }
                .padding(.leading, iconColumn + Self.iconGap)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(Dotted([meter.account] + [meter.updatedAt?.formatted(date: .abbreviated, time: .shortened)].compactMap { $0 }).visible)
        .accessibilityElement(children: .contain)
    }

    private var title: some View {
        let who = Dotted([meter.shownIdentity, meter.source].compactMap { $0 })
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: meter.product).font(Typography.secondary.weight(.medium)).foregroundStyle(palette.ink).fixedSize()
            Group {
                if !who.isEmpty { Text("\(Dotted.inline)\(Text(verbatim: who.visible))").truncationMode(.middle).layoutPriority(1) }
                if let plan = meter.plan { Text("\(Dotted.inline)\(Text(verbatim: plan))") }
            }
            .font(Typography.meta).foregroundStyle(palette.ink3).lineLimit(1)
        }
    }

    @ViewBuilder private var status: some View {
        switch meter.status {
        case .stale(let observedAt):
            LiveText(style: SessionClock.ago(observedAt).live(.list)) { Text($0) }
                .font(Typography.meta).foregroundStyle(palette.ink2)
                .accessibilityLabel(Text("上次观测于 \(observedAt, format: .dateTime)"))
        case .failed: Text("查询失败").font(Typography.meta).foregroundStyle(palette.failure)
        case .expired: Text("已过期").font(Typography.meta).foregroundStyle(palette.ink2)
        case .unobserved: Text("尚未观测").font(Typography.meta).foregroundStyle(palette.ink3)
        case .unsupported: Text(meter.usageURL != nil ? "暂无额度数据" : "不提供查询").font(Typography.meta).foregroundStyle(palette.ink3)
        case nil: EmptyView()
        }
    }

    private func balanceRow(_ balance: String) -> some View {
        MetaLine(gap: Spacing.item) {
            Text(meter.owes ? "欠费" : "余额").font(Typography.meta).fontWeight(.medium).foregroundStyle(meter.owes ? palette.failure : palette.ink)
        } meta: {
            Text(verbatim: balance).font(Typography.gaugeNumber).foregroundStyle(meter.owes ? palette.failure : palette.ink)
        }
    }
}

private struct QuotaWindowRow: View {
    let window: QuotaMeter.Window
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let critical = window.level == .critical
        VStack(alignment: .leading, spacing: Spacing.glyph) {
            MetaLine(gap: Spacing.item) {
                heading.font(Typography.meta)
            } meta: {
                Text("剩 \(Text(window.percent).font(Typography.gaugeNumber).foregroundStyle(critical ? palette.failure : palette.ink))")
                    .font(Typography.meta).foregroundStyle(palette.ink3)
                    .contentTransition(.numericText(value: window.left))
            }
            MarkedBar(fill: window.left, mark: window.even, level: window.level)
        }
        .help(Text(window.spoken))
        .animation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), value: window)
    }

    @ViewBuilder private var heading: some View {
        let name = Text(window.name).fontWeight(.medium).foregroundStyle(palette.ink)
        if let runway = window.runway {
            let tone = window.level == .critical ? palette.failure : palette.ink2
            Text("\(name)\(Dotted.inline)\(Text("\(runway)后用完").foregroundStyle(tone))")
        } else {
            LiveText(style: QuotaMeter.Countdown(end: window.resetsAt)) {
                Text("\(name)\(Dotted.inline)\(Text("\(Text($0).monospacedDigit())后重置").foregroundStyle(palette.ink3))")
            }
        }
    }
}

struct QuotaRing: View, Animatable {
    private var left: Double
    private let level: UsageLevel
    @Environment(\.palette) private var palette

    private static let line: CGFloat = 1.5

    init(_ window: QuotaMeter.Window) {
        left = window.left
        level = window.level
    }

    var animatableData: Double {
        get { left }
        set { left = newValue }
    }

    /// 两段描边（不用 Canvas：第一次进有它的页时一张画布就要几毫秒）。
    var body: some View {
        let ring = Circle().inset(by: Self.line / 2)
        ZStack {
            ring.stroke(palette.track, lineWidth: Self.line)
            if left > 0 {
                ring.trim(from: 0, to: min(left, 1))
                    .stroke(level.ink(palette), style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }
}

/// 整排是一颗按钮，点它展开明细（展开在哪由所在的地方定）；`open` 只给读屏说展开没有。
/// 还没有可画的环时（还没有额度记录）环的位置写"额度"二字，照样能点，点开明细那里说怎么才会有（`QuotaDetail`）：一颗空环读不出是什么。
/// 两个字与一颗环差不多宽，菜单栏面板不变宽；手机那块玻璃第一次有额度时窄几点，只变这一次。
struct QuotaRings: View {
    let open: Bool
    let height: CGFloat
    var row = false
    var cell = false
    let action: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private static let limit = 3

    var body: some View {
        let quotas = Array(services.accountQuotas.items.prefix(Self.limit))
        Group {
            if row || cell { button(quotas).buttonStyle(RowStyle(selected: open, cell: cell)) } else { button(quotas).buttonStyle(PressStyle()) }
        }
        .accessibilityExpanded(open)
        .accessibilityHint(open ? "收起" : quotas.isEmpty ? "看怎么才会有额度" : "看每个窗口还剩多少、多久后重置")
    }

    private func button(_ quotas: [AccountQuota]) -> some View {
        Button(action: action) {
            Moments(next: quotas.nextReset(after:)) { now in rings(quotas, at: now) }
                .padding(.horizontal, row ? 0 : Spacing.item)
                .frame(height: height)
                .contentShape(.rect)
        }
    }

    private func rings(_ quotas: [AccountQuota], at now: Date) -> some View {
        let rings = quotas.compactMap { quota in quota.binding(at: now).map { (id: quota.id, provider: quota.provider, window: QuotaMeter.Window($0, at: now)) } }
        return HStack(spacing: Spacing.glyph) {
            if row {
                Text("额度").foregroundStyle(palette.ink3)
                Spacer(minLength: 0)
            } else if rings.isEmpty { Text("额度").font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink3).fixedSize() }
            ForEach(rings, id: \.id) { ModelBadge(mark: Provider(id: $0.provider).mark, binding: $0.window) }
        }
        .foregroundStyle(palette.ink2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("额度")
        .accessibilityValue(Dotted(rings.map { String(localized: "\(Provider(id: $0.provider).account) \($0.window.name)剩 \($0.window.percent)") }).spoken)
    }
}
