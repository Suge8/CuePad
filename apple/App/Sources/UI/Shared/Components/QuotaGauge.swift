import CueStore
import SwiftUI

/// 订阅额度的明细（读数规则在 `QuotaMeter`）：点额度环（`QuotaRings`）才展开——手机会话页顶栏那颗胶囊长出的面板、Mac 会话页的气泡、
/// 菜单栏面板里就地展开的那一块；还没有额度记录时那里写还没有额度、怎么才会有（`QuotaEmpty`）。
///
/// 每个账号一块（`QuotaAccount`），排法同旁边的列表行：头一行是 20 点宽的图标列里的产品标志加账号名（数据陈旧时接"x 分钟前"），
/// 下面每个窗口一行，与账号名左对齐：窗口名与多久后重置（计时文字，只在整分钟换字，`LiveText`；过了重置时间还没有新观测写"已重置"），
/// 右边是还剩多少的大号等宽数字，下面一条剩余条（`MarkedBar`，刻线是匀速线）。超了匀速线（照这速度重置前会用完）在条下多一行"照这速度约 X 后用完"。
/// 这就是最后一层，不再有点开的：不是按钮、没有按压。放得下时账号并排成等宽的几栏，否则一个一块往下排（`QuotaColumns`）。
///
/// 配色只用墨：余量足是次要墨色，用过七成是墨色，九成起与用完是胭脂（同上下文快满的口径，不借赭黄、不用靛青）；胭脂时数字一起变色。
/// 读数在新观测到达时变，另外在每个窗口的重置时刻各变一次（`Moments` 睡到 `nextReset(after:)`：等到重置是业务语义，不是周期刷新）：
/// 条与匀速线用无回弹弹簧过去、数字滚动换字，减弱动态效果时直接到终态；没有常驻动画与周期定时器。
struct QuotaDetail: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let quotas = services.accountQuotas.items
        if quotas.isEmpty {
            QuotaEmpty()
        } else {
            Moments(next: quotas.nextReset(after:)) { now in
                QuotaColumns {
                    ForEach(quotas.map { QuotaMeter($0, at: now) }.filter { !$0.windows.isEmpty }, id: \.provider) { QuotaAccount(meter: $0) }
                }
            }
        }
    }
}

/// 还没有额度记录时明细那里的两行：没有，与怎么才会有；铺满所在那一块（Mac 的气泡、菜单栏面板、手机长出的面板）。
private struct QuotaEmpty: View {
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("还没有额度").font(Typography.secondary.weight(.medium)).foregroundStyle(palette.ink)
            Text("Agent 会话用订阅账号跑过一轮后，这里显示每个窗口还剩多少、多久后重置")
                .font(Typography.meta).foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 放得下每栏 `column` 宽就并排成等宽的几栏（顶对齐），否则一个一块往下排。
private struct QuotaColumns: Layout {
    private static let column: CGFloat = 280
    private static let gap: CGFloat = 32
    private static let lineSpacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Self.column
        if let column = columnWidth(width, subviews.count) {
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: column, height: nil)).height }
            return CGSize(width: width, height: heights.max() ?? 0)
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + Self.lineSpacing * CGFloat(max(heights.count - 1, 0)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let column = columnWidth(bounds.width, subviews.count)
        var origin = bounds.origin
        for subview in subviews {
            let size = ProposedViewSize(width: column ?? bounds.width, height: nil)
            subview.place(at: origin, proposal: size)
            if let column { origin.x += column + Self.gap } else { origin.y += subview.sizeThatFits(size).height + Self.lineSpacing }
        }
    }

    private func columnWidth(_ width: CGFloat, _ count: Int) -> CGFloat? {
        guard count > 1 else { return nil }
        let column = (width - Self.gap * CGFloat(count - 1)) / CGFloat(count)
        return column >= Self.column ? column : nil
    }
}

extension View {
    /// 额度视图出现（Mac 的页在前台、手机回到前台）或有了可问的（会话连上）时，数据陈旧就查一次（节流在 `AccountQuotas`）。
    func refreshesQuota() -> some View { modifier(QuotaRefreshOnAppear()) }
}

private struct QuotaRefreshOnAppear: ViewModifier {
    @Environment(AppServices.self) private var services
    @Environment(\.pageActive) private var active
    #if os(iOS)
    // 手机回到前台再看一次；Mac 的窗口由 AppKit 托管，没有 SwiftUI 场景，场景阶段一直不是 active，只看页在不在前台
    @Environment(\.scenePhase) private var phase
    private var foreground: Bool { phase == .active }
    #else
    private var foreground: Bool { true }
    #endif

    func body(content: Content) -> some View {
        let shown = active && foreground
        content.task(id: shown && services.canRefreshQuota) {
            guard shown else { return }
            await services.refreshQuotaIfStale()
        }
    }
}

/// 一个账号：标志与账号名一行，下面每个窗口一行。
private struct QuotaAccount: View {
    let meter: QuotaMeter
    @Environment(\.palette) private var palette

    /// 图标列宽（随动态字体放大：图标跟着字放大，定宽的列在大字号下放不下，压到账号名上）与它到字的距离，同面板里的列表行。
    @ScaledMetric(relativeTo: .subheadline) private var iconColumn: CGFloat = 20
    private static let iconGap: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Self.iconGap) {
                PiProvider(id: meter.provider).mark?.image
                    .foregroundStyle(palette.ink2)
                    .frame(width: iconColumn)
                title
            }
            .font(Typography.secondary.weight(.medium))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(meter.windows) { QuotaWindowRow(window: $0) }
            }
            .padding(.leading, iconColumn + Self.iconGap)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meter.spoken)
    }

    /// 账号名，数据陈旧时接"· x 分钟前"。
    @ViewBuilder private var title: some View {
        let account = Text(meter.account).foregroundStyle(palette.ink)
        if meter.isStale {
            LiveText(style: PiClock.ago(meter.updatedAt).live(.list)) { ago in
                Text("\(account)\(Text("\(Dotted.inline)\(ago)").font(Typography.meta).foregroundStyle(palette.ink3))")
            }
        } else {
            account
        }
    }
}

/// 一个窗口：窗口名与多久后重置、右边还剩多少，下面一条剩余条；超了匀速线再写照这速度多久用完。
private struct QuotaWindowRow: View {
    let window: QuotaMeter.Window
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 还剩多少的数字（Mac 没有动态字体，给固定字号）。
    #if os(macOS)
    private static let number = Font.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit()
    #else
    private static let number = Font.system(.body, design: .rounded, weight: .semibold).monospacedDigit()
    #endif

    var body: some View {
        let critical = window.level == .critical
        VStack(alignment: .leading, spacing: 5) {
            // 窗口名（按模型的写着模型名）与多久后重置是一段字，放不下就折行、不截；还剩多少不折，辅助字号下挪到下一行
            MetaLine(gap: 8) {
                heading.font(Typography.meta).foregroundStyle(palette.ink3)
            } meta: {
                Text("剩 \(Text(window.percent).font(Self.number).foregroundStyle(critical ? palette.failure : palette.ink))")
                    .font(Typography.meta).foregroundStyle(palette.ink3)
                    .contentTransition(.numericText(value: window.left))
            }
            // 剩余条：剩的少于匀速线就是用快了
            MarkedBar(fill: window.left, mark: window.even, level: window.level)
            if let runway = window.runway {
                Text("照这速度\(runway)后用完").font(Typography.caption).foregroundStyle(critical ? palette.failure : palette.ink2)
                    .transition(.opacity)
            }
        }
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: window)
    }

    @ViewBuilder private var heading: some View {
        let name = Text(window.name).fontWeight(.medium).foregroundStyle(palette.ink)
        if window.hasReset {
            Text("\(name)\(Dotted.inline)已重置")
        } else {
            LiveText(style: QuotaMeter.Countdown(end: window.resetsAt)) { Text("\(name)\(Dotted.inline)\(Text($0).monospacedDigit())后重置") }
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
/// 手机会话页顶栏那颗胶囊的右半、Mac 会话页顶上那一排、菜单栏面板的 Cue 那一行。账号多时只放前 `limit` 颗；
/// 还没有可画的环时（还没有额度记录）环的位置写"额度"二字，照样能点，点开明细那里说怎么才会有（`QuotaDetail`）：一颗空环读不出是什么。
/// 两个字与一颗环差不多宽，Mac 工具栏那一格与菜单栏面板不变宽；手机那块玻璃第一次有额度时窄几点，只变这一次。
struct QuotaRings: View {
    let open: Bool
    let height: CGFloat
    let action: () -> Void
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private static let limit = 3

    var body: some View {
        let quotas = Array(services.accountQuotas.items.prefix(Self.limit))
        Button(action: action) {
            Moments(next: quotas.nextReset(after:)) { now in rings(quotas, at: now) }
                .padding(.horizontal, 10)
                .frame(height: height)
                .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .accessibilityExpanded(open)
        .accessibilityHint(open ? "收起" : quotas.isEmpty ? "看怎么才会有额度" : "看每个窗口还剩多少、多久后重置")
    }

    private func rings(_ quotas: [AccountQuota], at now: Date) -> some View {
        let rings = quotas.compactMap { quota in quota.binding(at: now).map { (provider: quota.provider, window: QuotaMeter.Window($0, at: now)) } }
        return HStack(spacing: 6) {
            if rings.isEmpty { Text("额度").font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink3).fixedSize() }
            ForEach(rings, id: \.provider) { ModelBadge(mark: PiProvider(id: $0.provider).mark, binding: $0.window) }
        }
        .foregroundStyle(palette.ink2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("额度")
        .accessibilityValue(Dotted(rings.map { String(localized: "\(PiProvider(id: $0.provider).account) \($0.window.name)剩 \($0.window.percent)") }).spoken)
    }
}
