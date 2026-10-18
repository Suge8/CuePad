import CueStore
import SwiftUI

/// 订阅额度的总览（读数规则在 `QuotaMeter`）：手机 Cue 页头的面板、Mac Agent 页顶部与菜单栏面板，还没有额度记录时整条不出现。
///
/// 每个账号一块（`QuotaAccount`），排法同旁边的列表行：头一行是 20 点宽的图标列里的产品标志加账号名（数据陈旧时接"x 分钟前"），
/// 下面每个窗口一行，与账号名左对齐：窗口名与多久后重置（计时文字，只在整分钟换字，`LiveText`；过了重置时间还没有新观测写"已重置"），
/// 右边是还剩多少的大号等宽数字，下面一条剩余条（`MarkedBar`，刻线是匀速线）。超了匀速线（照这速度重置前会用完）在条下多一行"照这速度约 X 后用完"。
/// 主视图把要看的都写出来了，所以不再有点开的明细：总览不是按钮、没有按压。
/// 宽处（Mac Agent 页）账号并排成等宽的几栏，窄处（手机、菜单栏面板）一个一块往下排（`QuotaColumns`）。
///
/// 配色只用墨：余量足是次要墨色，用过七成是墨色，九成起与用完是胭脂（同上下文快满的口径，不借赭黄、不用靛青）；胭脂时数字一起变色。
/// 读数在新观测到达时变，另外在每个窗口的重置时刻各变一次（`Moments` 睡到 `nextReset(after:)`：等到重置是业务语义，不是周期刷新）：
/// 条与匀速线用无回弹弹簧过去、数字滚动换字，减弱动态效果时直接到终态；没有常驻动画与周期定时器。
struct QuotaStrip: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let quotas = services.accountQuotas.items
        if !quotas.isEmpty {
            Moments(next: quotas.nextReset(after:)) { now in
                QuotaColumns {
                    ForEach(quotas.map { QuotaMeter($0, at: now) }.filter { !$0.windows.isEmpty }, id: \.provider) { QuotaAccount(meter: $0) }
                }
            }
        }
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

    /// 图标列宽与它到字的距离，同面板里的列表行。
    private static let iconColumn: CGFloat = 20
    private static let iconGap: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: Self.iconGap) {
                PiProvider(id: meter.provider).mark?.image
                    .foregroundStyle(palette.ink2)
                    .frame(width: Self.iconColumn)
                title.lineLimit(1)
            }
            .font(Typography.secondary.weight(.medium))
            VStack(alignment: .leading, spacing: 10) {
                ForEach(meter.windows) { QuotaWindowRow(window: $0) }
            }
            .padding(.leading, Self.iconColumn + Self.iconGap)
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
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(window.name).font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink)
                reset.font(Typography.meta).foregroundStyle(palette.ink3).lineLimit(1)
                Spacer(minLength: 8)
                Text("剩 ").font(Typography.meta).foregroundStyle(palette.ink3)
                Text(window.percent).font(Self.number).foregroundStyle(critical ? palette.failure : palette.ink)
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

    @ViewBuilder private var reset: some View {
        if window.hasReset {
            Text("\(Dotted.inline)已重置")
        } else {
            LiveText(style: QuotaMeter.Countdown(end: window.resetsAt)) { Text("\(Dotted.inline)\(Text($0).monospacedDigit())后重置") }
        }
    }
}

/// 回复框模型胶囊上标志外的一圈细环：卡着的那个窗口还剩多少，从 12 点顺时针铺（`ModelBadge`）。
/// 还剩随动画插值，档位的颜色直接换。
struct QuotaRing: View, Animatable {
    private var left: Double
    private let level: PiContextMeter.Level
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

    var body: some View {
        let (track, fill, left) = (palette.track, level.ink(palette), left)
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - Self.line / 2
            let ring = Path { $0.addArc(center: center, radius: radius, startAngle: .degrees(0), endAngle: .degrees(360), clockwise: false) }
            context.stroke(ring, with: .color(track), lineWidth: Self.line)
            guard left > 0 else { return }
            let arc = Path {
                $0.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(left, 1)), clockwise: false)
            }
            context.stroke(arc, with: .color(fill), style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
        }
    }
}
