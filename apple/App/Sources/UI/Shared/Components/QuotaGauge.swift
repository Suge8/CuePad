import CueStore
import SwiftUI

/// 订阅额度的明细（读数规则在 `QuotaMeter`）：点额度环（`QuotaRings`）才展开——手机会话页顶栏那颗胶囊长出的面板、Mac 侧栏那一行额度长出的气泡、
/// 菜单栏面板里就地展开的那一块；还没有额度记录时那里写还没有额度、怎么才会有（`QuotaEmpty`）。
///
/// 每个账号一块（`QuotaAccount`）：头一行是图标列里的产品标志、产品名与套餐，要单独标出的状态（陈旧写"x 分钟前"、失败、过期…）靠右；
/// 下面的读数一样排法，左边是名字、右边是大号等宽的数，窗口再多一条剩余条（`MarkedBar`，刻线是匀速线）。同类条目行数固定：
/// 一个窗口两行，余额与没有周期的计量一行。刚观测过的账号不各写时间，并成底下一行"x 前更新"（取它们里最早的那次），
/// 陈旧与失败仍标在那个账号上。这就是最后一层，不再有点开的：不是按钮、没有按压。宽处排成两栏（`QuotaColumns`）。
///
/// 配色只用墨：余量足是次要墨色，用过七成是墨色，九成起与用完是胭脂（同上下文快满的口径，不借赭黄、不用靛青）；胭脂时数字一起变色，欠费的余额同样。
/// 读数在新观测到达、变陈旧与每个窗口的重置时刻变化（`Moments` 睡到 `nextReset(after:)`：等到重置是业务语义，不是周期刷新）：
/// 条与匀速线用无回弹弹簧过去、数字滚动换字，减弱动态效果时直接到终态；没有常驻动画与周期定时器。
struct QuotaDetail: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let quotas = services.accountQuotas.items
        if quotas.isEmpty {
            QuotaEmpty()
        } else {
            Moments(next: quotas.nextReset(after:)) { now in
                let meters = QuotaMeter.all(quotas, at: now)
                VStack(alignment: .leading, spacing: 14) {
                    QuotaColumns {
                        ForEach(meters, id: \.id) { QuotaAccount(meter: $0) }
                    }
                    if let updated = meters.filter({ $0.status == nil }).compactMap(\.updatedAt).min() {
                        LiveText(style: PiClock.ago(updated).live(.list)) { Text("\($0)更新") }
                            .font(Typography.caption).foregroundStyle(palette.ink3)
                            .help(updated.formatted(date: .abbreviated, time: .standard))
                    }
                }
            }
        }
    }
}

#if os(macOS)
extension QuotaDetail {
    /// Mac 侧栏气泡的宽：两个账号起放得下两栏（`QuotaColumns`），否则同别的气泡。
    static func bubbleWidth(accounts: Int) -> CGFloat {
        accounts > 1 ? QuotaColumns.column * 2 + QuotaColumns.gap + SidebarQuota.padding * 2 : BubblePlacement.width
    }
}
#endif

/// 还没有额度记录时明细那里的两行：没有，与怎么才会有；铺满所在那一块（Mac 的气泡、菜单栏面板、手机长出的面板）。
private struct QuotaEmpty: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("还没有额度").font(Typography.secondary.weight(.medium)).foregroundStyle(palette.ink)
            Text("连接 Agent 会话后，这里显示订阅额度与 API 余额")
                .font(Typography.meta).foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 账号放得下就排成两栏：每块进当时较矮的那一栏（块高矮不一，按行对齐会留空洞），读屏仍按原顺序。
/// 没给宽（Mac 侧栏的气泡）时取两栏的宽；只有一个账号或放不下两栏（手机、菜单栏面板）时一块接一块往下排。
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
            let index = heights.indices.min { heights[$0] < heights[$1] }!
            let y = heights[index] == 0 ? 0 : heights[index] + Self.lineSpacing
            places.append((CGFloat(index) * (column + Self.gap), y, column))
            heights[index] = y + subview.sizeThatFits(ProposedViewSize(width: column, height: nil)).height
        }
        return (places, heights)
    }
}

extension View {
    /// 打开额度或来源改变时读一次清单；不根据已有账号的观测时间阻止发现新账号。
    func refreshesQuota() -> some View { modifier(QuotaRefreshOnAppear()) }
}

private struct QuotaRefreshOnAppear: ViewModifier {
    @Environment(AppServices.self) private var services
    @Environment(Workspace.self) private var workspace
    @Environment(\.pageActive) private var active
    #if os(iOS)
    // 手机回到前台再看一次；Mac 的窗口由 AppKit 托管，没有 SwiftUI 场景，场景阶段一直不是 active，只看页在不在前台
    @Environment(\.scenePhase) private var phase
    private var foreground: Bool { phase == .active }
    #else
    private var foreground: Bool { true }
    #endif

    func body(content: Content) -> some View {
        let shouldRefresh = active && foreground && services.canRefreshQuota
        content.task(id: shouldRefresh ? services.quotaRefreshKey : []) {
            guard shouldRefresh else { return }
            await workspace.refreshQuota()
        }
    }
}

/// 一个账号：标志、产品名与套餐一行（同一产品有几个账号时接账号名，要标出的状态靠右），下面读数与窗口各占定好的行数。
private struct QuotaAccount: View {
    let meter: QuotaMeter
    @Environment(\.palette) private var palette

    /// 图标列宽（随动态字体放大：图标跟着字放大，定宽的列在大字号下放不下，压到账号名上）与它到字的距离，同面板里的列表行。
    @ScaledMetric(relativeTo: .subheadline) private var iconColumn: CGFloat = 20
    private static let iconGap: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: Self.iconGap) {
                PiProvider(id: meter.provider).mark?.image
                    .foregroundStyle(palette.ink2)
                    .frame(width: iconColumn)
                MetaLine(gap: 8) { title } meta: { status }
            }
            if meter.balance != nil || !meter.values.isEmpty || !meter.windows.isEmpty || meter.usageURL != nil {
                VStack(alignment: .leading, spacing: 10) {
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

    /// 产品名，后面是要区分时的账号名与多处网关时的来源、再后面是套餐；放不下时先省套餐，再省账号名的中间，产品名不省。
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
            LiveText(style: PiClock.ago(observedAt).live(.list)) { Text($0) }
                .font(Typography.meta).foregroundStyle(palette.ink2)
                .accessibilityLabel(Text("上次观测于 \(observedAt, format: .dateTime)"))
        case .failed: Text("查询失败").font(Typography.meta).foregroundStyle(palette.failure)
        case .expired: Text("已过期").font(Typography.meta).foregroundStyle(palette.ink2)
        case .unobserved: Text("尚未观测").font(Typography.meta).foregroundStyle(palette.ink3)
        case .unsupported: Text(meter.usageURL != nil ? "暂无额度数据" : "不提供查询").font(Typography.meta).foregroundStyle(palette.ink3)
        case nil: EmptyView()
        }
    }

    /// 余额与窗口同一种排法：左边名字、右边大号的数；欠费时名字写欠费、数用胭脂，原串不改。
    private func balanceRow(_ balance: String) -> some View {
        MetaLine(gap: 8) {
            Text(meter.owes ? "欠费" : "余额").font(Typography.meta).fontWeight(.medium).foregroundStyle(meter.owes ? palette.failure : palette.ink)
        } meta: {
            Text(verbatim: balance).font(Typography.gaugeNumber).foregroundStyle(meter.owes ? palette.failure : palette.ink)
        }
    }
}

/// 一个窗口两行：窗口名与多久后重置（照这速度会在重置前用完时，改写多久后用完）、右边还剩多少；下面一条剩余条。
private struct QuotaWindowRow: View {
    let window: QuotaMeter.Window
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let critical = window.level == .critical
        VStack(alignment: .leading, spacing: 6) {
            MetaLine(gap: 8) {
                heading.font(Typography.meta)
            } meta: {
                Text("剩 \(Text(window.percent).font(Typography.gaugeNumber).foregroundStyle(critical ? palette.failure : palette.ink))")
                    .font(Typography.meta).foregroundStyle(palette.ink3)
                    .contentTransition(.numericText(value: window.left))
            }
            // 剩余条：剩的少于匀速线就是用快了
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

/// 回复框模型胶囊上标志外的一圈细环：卡着的那个窗口还剩多少，从 12 点顺时针铺（`ModelBadge`）。
/// 还剩随动画插值，档位的颜色直接换。
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

/// 每个账号一颗小额度环（产品标志在环里，同回复框模型胶囊上那颗 `ModelBadge`）：环是卡着的那个窗口还剩多少，只用颜色说余量、不写数。
/// 整排是一颗按钮，点它展开明细（`QuotaDetail`，展开在哪由所在的地方定）；`open` 只给读屏说展开没有。
/// 手机会话页顶栏那颗胶囊的右半、菜单栏面板的 Cue 那一行、Mac 侧栏的一行（`SidebarQuota`）。账号多时只放前 `limit` 颗；
/// 还没有可画的环时（还没有额度记录）环的位置写"额度"二字，照样能点，点开明细那里说怎么才会有（`QuotaDetail`）：一颗空环读不出是什么。
/// 两个字与一颗环差不多宽，菜单栏面板不变宽；手机那块玻璃第一次有额度时窄几点，只变这一次。
/// `row`：铺满宽的一行（Mac 侧栏）：左边一直写"额度"（字号随所在处）、环靠右，按下与展开着是行的底（`RowStyle`）。
struct QuotaRings: View {
    let open: Bool
    let height: CGFloat
    var row = false
    let action: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private static let limit = 3

    var body: some View {
        let quotas = Array(services.accountQuotas.items.prefix(Self.limit))
        Group {
            if row { button(quotas).buttonStyle(RowStyle(selected: open)) } else { button(quotas).buttonStyle(PressStyle()) }
        }
        .accessibilityExpanded(open)
        .accessibilityHint(open ? "收起" : quotas.isEmpty ? "看怎么才会有额度" : "看每个窗口还剩多少、多久后重置")
    }

    private func button(_ quotas: [AccountQuota]) -> some View {
        Button(action: action) {
            Moments(next: quotas.nextReset(after:)) { now in rings(quotas, at: now) }
                .padding(.horizontal, row ? 0 : 10)
                .frame(height: height)
                .contentShape(.rect)
        }
    }

    private func rings(_ quotas: [AccountQuota], at now: Date) -> some View {
        let rings = quotas.compactMap { quota in quota.binding(at: now).map { (id: quota.id, provider: quota.provider, window: QuotaMeter.Window($0, at: now)) } }
        return HStack(spacing: 6) {
            if row {
                Text("额度").foregroundStyle(palette.ink3)
                Spacer(minLength: 0)
            } else if rings.isEmpty { Text("额度").font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink3).fixedSize() }
            ForEach(rings, id: \.id) { ModelBadge(mark: PiProvider(id: $0.provider).mark, binding: $0.window) }
        }
        .foregroundStyle(palette.ink2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("额度")
        .accessibilityValue(Dotted(rings.map { String(localized: "\(PiProvider(id: $0.provider).account) \($0.window.name)剩 \($0.window.percent)") }).spoken)
    }
}
