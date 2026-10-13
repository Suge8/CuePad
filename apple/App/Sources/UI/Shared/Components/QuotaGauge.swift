import CueStore
import SwiftUI

/// 订阅额度的仪表（读数规则在 `QuotaMeter`）。
///
/// - `QuotaStrip`：Agent 页顶部（Mac 与 iOS）与 Mac 菜单栏面板的总览，一排放得下就并排、放不下一个一行，每个账号一枚 `QuotaChip`：仪表加两行字——账号名
///   （数据陈旧时接一句"x 分钟前"），下面一句：超了匀速刻度写"照这速度约 X 后用完"，否则写卡着的窗口多久后重置（系统计时文字，自己走），
///   过了重置时间还没有新观测的写"已重置"。
///   点开是明细（`QuotaDetail`）：各窗口的用量条、按模型的周额度、"更新于 x 分钟前"。还没有额度记录时整条不出现。
/// - `QuotaDial`：提供方图标外两圈细弧，外圈是短窗口（5 小时），内圈是长窗口（本周）；只有一个窗口（Codex 常见）就一圈。
///   弧从 12 点顺时针铺到已用的比例，弧上一道刻度是匀速刻度（窗口已过的时间该用到多少），刻度在弧外面压出一道缝，任何底色上都读得出。
///
/// 配色只用墨：余量足是次要墨色，七成起是墨色，九成起与用完是胭脂（同上下文快满的口径，不借赭黄、不用靛青）。
/// 读数在新观测到达时变，另外在每个窗口的重置时刻各变一次（`QuotaMoments`：等到重置是业务语义，不是周期刷新）：
/// 弧与刻度用无回弹弹簧过去，减弱动态效果时淡入淡出；没有常驻动画与周期定时器。
struct QuotaStrip: View {
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    var body: some View {
        let quotas = services.accountQuotas.items
        if !quotas.isEmpty {
            QuotaMoments(quotas) { now in
                let meters = quotas.map { QuotaMeter($0, at: now) }.filter { !$0.rings.isEmpty }
                // 一排放得下就并排，放不下（手机竖屏）一个账号一行
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 22) { chips(meters) }
                    VStack(alignment: .leading, spacing: 12) { chips(meters) }
                }
            }
        }
    }

    private func chips(_ meters: [QuotaMeter]) -> some View {
        ForEach(meters, id: \.provider) { QuotaChip(meter: $0) }
    }
}

/// 按额度读数画的内容：此刻画一次，之后只在还没到的各个重置时刻各重画一次（`TimelineView` 的显式时刻表，由系统在那一刻唤醒），
/// 过了重置时间的窗口随即按已重置画（`QuotaWindow.used(at:)`）。
struct QuotaMoments<Content: View>: View {
    let moments: [Date]
    @ViewBuilder let content: (Date) -> Content

    init(_ quotas: [AccountQuota], @ViewBuilder content: @escaping (Date) -> Content) {
        let now = Date.now
        moments = Set(quotas.flatMap(\.windows).map(\.resetsAt).filter { $0 > now }).sorted()
        self.content = content
    }

    var body: some View {
        // 时刻表开始前的那一帧，时刻表给的日期可能早于此刻：取两者较晚的
        TimelineView(.explicit(moments)) { context in content(max(context.date, .now)) }
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

/// 一个账号：仪表加两行字，点开看明细。
struct QuotaChip: View {
    let meter: QuotaMeter
    @Environment(\.palette) private var palette
    @State private var showsDetail = false

    var body: some View {
        Button { showsDetail.toggle() } label: {
            HStack(spacing: 10) {
                QuotaDial(meter: meter, size: 34) { QuotaMark(provider: meter.provider) }
                VStack(alignment: .leading, spacing: 1) {
                    title
                    QuotaSummary(meter: meter).font(Typography.meta).lineLimit(1)
                }
                .fixedSize()
            }
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(.control))
        .popover(isPresented: $showsDetail, arrowEdge: .bottom) { QuotaDetail(meter: meter).presentationCompactAdaptation(.popover) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(meter.spoken)
        .accessibilityAddTraits(.isButton)
        .onAppear { if DebugHooks.preset.quotaDetail == meter.provider { DebugHooks.later(.milliseconds(400)) { showsDetail = true } } }
    }

    private var title: some View {
        HStack(spacing: 0) {
            Text(meter.account).font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink)
            if meter.isStale {
                Text("\(Dotted.inline)\(Text(meter.updatedAt, style: .relative))前")
                    .font(Typography.meta).foregroundStyle(palette.ink3).monospacedDigit()
            }
        }
    }
}

/// 卡着的那个窗口一句话：用完了写多久后重置（胭脂），超了刻度写照这速度多久用完，否则写多久后重置。
private struct QuotaSummary: View {
    let meter: QuotaMeter
    @Environment(\.palette) private var palette

    var body: some View {
        if let window = meter.binding {
            if window.hasReset {
                Text("\(window.name)\(Dotted.inline)已重置").foregroundStyle(palette.ink3)
            } else if window.isSpent {
                Text("已用完\(Dotted.inline)\(Text(window.resetsAt, style: .relative))后重置").foregroundStyle(palette.failure)
            } else if let runway = window.runway(from: .now) {
                Text("照这速度\(runway)后用完").foregroundStyle(window.level == .critical ? palette.failure : palette.ink2)
            } else {
                Text("\(window.name)\(Dotted.inline)\(Text(window.resetsAt, style: .relative))后重置").foregroundStyle(palette.ink3)
            }
        }
    }
}

/// 仪表：外圈短窗口、内圈长窗口；中间放提供方图标。
struct QuotaDial<Center: View>: View {
    let meter: QuotaMeter
    let size: CGFloat
    @ViewBuilder let center: Center
    @Environment(\.palette) private var palette

    private var line: CGFloat { max(1.5, size * 0.064) }
    private var gap: CGFloat { line * 0.95 }

    var body: some View {
        ZStack {
            ForEach(Array(meter.rings.prefix(2).enumerated()), id: \.element.id) { index, window in
                QuotaArc(window: window, inset: CGFloat(index) * (line + gap), line: line)
            }
            center
        }
        .frame(width: size, height: size)
    }
}

/// 一圈：底圈、铺到已用比例的弧，弧上压出一道缝再画匀速刻度。
struct QuotaArc: View {
    let window: QuotaMeter.Window
    let inset: CGFloat
    let line: CGFloat
    var showsPace = true
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let ring = Circle().inset(by: inset + line / 2)
        ZStack {
            ring.stroke(palette.ink.opacity(0.1), lineWidth: line)
            ring.trim(from: 0, to: window.used)
                .stroke(QuotaInk.fill(window.level, palette), style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsPace, window.pace > 0 {
                // 刻度两侧压出一道缝（与底色无关），再画刻度
                PaceTick(fraction: window.pace, radiusInset: inset + line / 2, length: line + 3)
                    .stroke(.black, style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                    .blendMode(.destinationOut)
                PaceTick(fraction: window.pace, radiusInset: inset + line / 2, length: line + 3)
                    .stroke(palette.ink.opacity(0.85), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
        }
        .compositingGroup()
        .id(reduceMotion ? window.percent : "")
        .transition(.opacity)
        .animation(reduceMotion ? Motion.quick : Motion.snappy, value: window)
    }
}

/// 匀速刻度：圈上 `fraction` 处一道沿半径的短线（从 12 点顺时针）。
private nonisolated struct PaceTick: Shape {
    var fraction: Double
    let radiusInset: CGFloat
    let length: CGFloat

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2 - radiusInset
        let angle = fraction * 2 * .pi - .pi / 2
        let (dx, dy) = (cos(angle), sin(angle))
        let center = CGPoint(x: rect.midX, y: rect.midY)
        var path = Path()
        path.move(to: CGPoint(x: center.x + dx * (radius - length / 2), y: center.y + dy * (radius - length / 2)))
        path.addLine(to: CGPoint(x: center.x + dx * (radius + length / 2), y: center.y + dy * (radius + length / 2)))
        return path
    }
}

/// 仪表中间的提供方图标（`PiProvider`，次要墨色）。
struct QuotaMark: View {
    let provider: String
    @Environment(\.palette) private var palette

    var body: some View {
        PiProvider(id: provider).image.font(.system(size: 13)).foregroundStyle(palette.ink2)
    }
}

/// 额度的墨：余量足次要墨色，七成起墨色，九成起胭脂。
enum QuotaInk {
    static func fill(_ level: PiContextMeter.Level, _ palette: Palette) -> Color {
        switch level {
        case .roomy: palette.ink2
        case .tight: palette.ink
        case .critical: palette.failure
        }
    }
}

/// 明细：各窗口的用量条（带匀速刻度）、多久后重置或照这速度多久用完，按模型的周额度在后，右上角写更新于几分钟前。
struct QuotaDetail: View {
    let meter: QuotaMeter
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.account).font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink)
                Spacer(minLength: 12)
                Text("更新于 \(Text(meter.updatedAt, style: .relative))前").font(Typography.caption).foregroundStyle(palette.ink3)
                    .monospacedDigit()
            }
            ForEach(meter.rings + meter.scoped) { QuotaBarRow(window: $0) }
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
    }
}

private struct QuotaBarRow: View {
    let window: QuotaMeter.Window
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(window.name).font(Typography.meta.weight(.medium)).foregroundStyle(palette.ink)
                Group {
                    if window.hasReset {
                        Text("\(Dotted.inline)已重置")
                    } else {
                        Text("\(Dotted.inline)\(Text(window.resetsAt, style: .relative))后重置")
                    }
                }
                .font(Typography.caption).foregroundStyle(palette.ink3).monospacedDigit()
                Spacer(minLength: 8)
                Text(window.percent).font(Typography.meta.monospacedDigit()).fontWeight(window.level == .roomy ? .medium : .bold)
                    .foregroundStyle(window.level == .critical ? palette.failure : palette.ink)
            }
            bar
            if window.isSpent {
                Text("已用完").font(Typography.caption).foregroundStyle(palette.failure)
            } else if let runway = window.runway(from: .now) {
                Text("照这速度\(runway)后用完").font(Typography.caption)
                    .foregroundStyle(window.level == .critical ? palette.failure : palette.ink2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// 细条：铺到已用，匀速刻度一道竖线（两侧压出缝）。
    private var bar: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(palette.ink.opacity(0.1)).frame(height: 4)
                Capsule().fill(QuotaInk.fill(window.level, palette)).frame(width: max(width * window.used, window.used > 0 ? 4 : 0), height: 4)
                if window.pace > 0 {
                    Capsule().fill(.black).frame(width: 3.2, height: 10).offset(x: width * window.pace - 1.6).blendMode(.destinationOut)
                    Capsule().fill(palette.ink.opacity(0.85)).frame(width: 1.2, height: 10).offset(x: width * window.pace - 0.6)
                }
            }
            .frame(height: 10)
            .compositingGroup()
        }
        .frame(height: 10)
        .animation(Motion.snappy, value: window)
    }
}
