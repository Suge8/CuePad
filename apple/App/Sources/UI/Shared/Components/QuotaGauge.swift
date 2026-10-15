import CueStore
import SwiftUI

/// 订阅额度的仪表（读数规则在 `QuotaMeter`）。
///
/// - `QuotaStrip`：Agent 页顶部（Mac 与 iOS）与 Mac 菜单栏面板的总览，一排放得下就并排、放不下一个一行（`QuotaFlow`，每个账号只量一次），
///   每个账号一枚 `QuotaChip`：仪表加两行字——账号名（数据陈旧时接一句"x 分钟前"），下面一句：超了匀速刻度写"照这速度约 X 后用完"，
///   否则写卡着的窗口多久后重置（计时文字，系统只在整分钟换字），过了重置时间还没有新观测的写"已重置"。
///   点开是明细（`QuotaDetail`）：各窗口的用量条、按模型的周额度、"更新于 x 分钟前"；弹出框只在点开时挂上，平时不建。还没有额度记录时整条不出现。
/// - `QuotaRings`：一块画布画全部的圈与刻度（与中间的提供方图标）：外圈是短窗口（5 小时），内圈是长窗口（本周）；只有一个窗口（Codex 常见）就一圈。
///   弧从 12 点顺时针铺到已用的比例，弧上一道刻度是匀速刻度（窗口已过的时间该用到多少），刻度在弧外面压出一道缝，任何底色上都读得出。
///   回复框的模型胶囊（`ModelBadge`）用同一块画布画一圈、不画刻度。
///
/// 配色只用墨：余量足是次要墨色，七成起是墨色，九成起与用完是胭脂（同上下文快满的口径，不借赭黄、不用靛青）。
/// 读数在新观测到达时变，另外在每个窗口的重置时刻各变一次（`QuotaMoments`：等到重置是业务语义，不是周期刷新）：
/// 弧与刻度用无回弹弹簧过去，减弱动态效果时换成短淡入淡出；没有常驻动画与周期定时器。
/// 这一条在 Agent 页第一次出现时整条现建：圈不拆成一段一个视图、排法不量两遍、弹出框不预先挂，第一次建的成本才不盖过整页。
struct QuotaStrip: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        let quotas = services.accountQuotas.items
        if !quotas.isEmpty {
            QuotaMoments(quotas) { now in
                QuotaFlow {
                    ForEach(quotas.map { QuotaMeter($0, at: now) }.filter { !$0.rings.isEmpty }, id: \.provider) { QuotaChip(meter: $0) }
                }
            }
        }
    }
}

/// 一排放得下就并排（间距 22），放不下就一个一行（行距 12）：每枚只按理想尺寸量一次。
private struct QuotaFlow: Layout {
    private static let spacing: CGFloat = 22
    private static let lineSpacing: CGFloat = 12

    func makeCache(subviews: Subviews) -> [CGSize] { subviews.map { $0.sizeThatFits(.unspecified) } }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) -> CGSize {
        if fitsRow(proposal.width, cache) {
            return CGSize(width: rowWidth(cache), height: cache.map(\.height).max() ?? 0)
        }
        let gaps = Self.lineSpacing * CGFloat(max(cache.count - 1, 0))
        return CGSize(width: cache.map(\.width).max() ?? 0, height: cache.map(\.height).reduce(0, +) + gaps)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) {
        let row = fitsRow(bounds.width, cache)
        var origin = bounds.origin
        for (subview, size) in zip(subviews, cache) {
            let y = row ? bounds.midY - size.height / 2 : origin.y
            subview.place(at: CGPoint(x: origin.x, y: y), proposal: ProposedViewSize(size))
            if row { origin.x += size.width + Self.spacing } else { origin.y += size.height + Self.lineSpacing }
        }
    }

    private func rowWidth(_ sizes: [CGSize]) -> CGFloat {
        sizes.map(\.width).reduce(0, +) + Self.spacing * CGFloat(max(sizes.count - 1, 0))
    }

    private func fitsRow(_ width: CGFloat?, _ sizes: [CGSize]) -> Bool { width.map { rowWidth(sizes) <= $0 } ?? true }
}

/// 按额度读数画的内容：此刻画一次，之后只在下一个重置时刻再画一次（等到那一刻是业务语义：`task(id:)` 睡到那一刻，不周期刷新），
/// 过了重置时间的窗口随即按已重置画（`QuotaWindow.used(at:)`）；画完再等下一个。新观测到达时照常重画、重新算下一个时刻。
/// 否决的方案：`TimelineView(.explicit(时刻))`——iOS 27 模拟器实测只在头一次画时调用内容（给的日期是时刻表里第一个时刻，
/// 还没到就按已到画），到了那一刻并不重画。
struct QuotaMoments<Content: View>: View {
    let quotas: [AccountQuota]
    @ViewBuilder let content: (Date) -> Content
    /// 睡到的那个重置时刻：读数不早于它（醒来与重画之间读 `.now` 不会还差一丝没到）
    @State private var reached = Date.distantPast

    init(_ quotas: [AccountQuota], @ViewBuilder content: @escaping (Date) -> Content) {
        self.quotas = quotas
        self.content = content
    }

    var body: some View {
        let now = max(Date.now, reached)
        let next = quotas.flatMap(\.windows).map(\.resetsAt).filter { $0 > now }.min()
        content(now)
            .task(id: next) {
                guard let next, (try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow))) != nil else { return }
                reached = next
            }
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
        Button { showsDetail = true } label: { label }
            .buttonStyle(PressStyle(.control))
            // 弹出框只在点开时挂上：挂在与这枚同大的空底上，关掉随即卸下
            .background {
                if showsDetail {
                    Color.clear.popover(isPresented: $showsDetail, arrowEdge: Self.arrowEdge) {
                        QuotaDetail(meter: meter).presentationCompactAdaptation(.popover)
                    }
                }
            }
            .accessibilityLabel(meter.spoken)
            .onAppear { if DebugHooks.preset.quotaDetail == meter.provider { DebugHooks.later(.milliseconds(400)) { showsDetail = true } } }
    }

    /// 朝哪边弹：总览在页顶，手机上固定朝上会被截（不翻面），交给系统按空间定；Mac 给的是首选边（弹在锚点的哪一边），
    /// 放不下系统自己翻，首选下边：朝上会盖住窗口顶上的工具栏，菜单栏面板上方是菜单栏。
    #if os(macOS)
    private static let arrowEdge: Edge? = .bottom
    #else
    private static let arrowEdge: Edge? = nil
    #endif

    private var label: some View {
        HStack(spacing: 10) {
            QuotaDial(meter: meter)
            VStack(alignment: .leading, spacing: 1) {
                title
                summary.font(Typography.meta).lineLimit(1)
            }
            .fixedSize()
        }
        .contentShape(.rect)
    }

    private var title: some View {
        Text("\(Text(meter.account).font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink))\(stale)")
    }

    /// 数据陈旧时接在账号名后面的"· x 分钟前"。
    private var stale: Text {
        meter.isStale
            ? Text("\(Dotted.inline)\(Text(.currentDate, format: PiClock.ago(meter.updatedAt).live(.list)))")
                .font(Typography.meta).foregroundStyle(palette.ink3)
            : Text(verbatim: "")
    }

    /// 卡着的那个窗口一句话：用完了写多久后重置（胭脂），超了刻度写照这速度多久用完，否则写多久后重置。
    private var summary: Text {
        guard let window = meter.binding else { return Text(verbatim: "") }
        if window.hasReset { return Text("\(window.name)\(Dotted.inline)已重置").foregroundStyle(palette.ink3) }
        if window.isSpent { return Text("已用完\(Dotted.inline)\(window.countdown)后重置").foregroundStyle(palette.failure) }
        if let runway = window.runway(from: .now) {
            return Text("照这速度\(runway)后用完").foregroundStyle(window.level == .critical ? palette.failure : palette.ink2)
        }
        return Text("\(window.name)\(Dotted.inline)\(window.countdown)后重置").foregroundStyle(palette.ink3)
    }
}

extension QuotaMeter.Window {
    /// 到重置还有多久，自己走字（`QuotaMeter.Countdown`）。
    var countdown: Text { Text(.currentDate, format: QuotaMeter.Countdown(end: resetsAt)).monospacedDigit() }
}

/// 总览里的仪表：两圈加中间的提供方图标，一块画布。
private struct QuotaDial: View {
    let meter: QuotaMeter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let size: CGFloat = 34

    var body: some View {
        let line = max(1.5, Self.size * 0.064)
        QuotaRings(Array(meter.rings.prefix(2)), line: line, gap: line * 0.95, showsPace: true, mark: PiProvider(id: meter.provider).image)
            .frame(width: Self.size, height: Self.size)
            .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: meter.rings)
    }
}

/// 一到两圈额度弧（外到内），一块画布画完：底圈、铺到已用比例的弧、匀速刻度（两侧压出缝），可选中间的图标。
/// 已用与刻度随动画插值（`animatableData`），档位的颜色直接换。
struct QuotaRings: View, Animatable {
    private var values: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>>
    private let levels: [PiContextMeter.Level]
    private let line: CGFloat
    private let gap: CGFloat
    private let showsPace: Bool
    private let mark: Image?
    @Environment(\.palette) private var palette

    init(_ windows: [QuotaMeter.Window], line: CGFloat, gap: CGFloat = 0, showsPace: Bool, mark: Image? = nil) {
        func pair(_ index: Int) -> AnimatablePair<Double, Double> {
            windows.indices.contains(index) ? AnimatablePair(windows[index].used, windows[index].pace) : AnimatablePair(0, 0)
        }
        values = AnimatablePair(pair(0), pair(1))
        levels = windows.prefix(2).map(\.level)
        self.line = line
        self.gap = gap
        self.showsPace = showsPace
        self.mark = mark
    }

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<Double, Double>> {
        get { values }
        set { values = newValue }
    }

    var body: some View {
        let rings = [values.first, values.second].prefix(levels.count)
        let (track, tick, markInk) = (palette.ink.opacity(0.1), palette.ink.opacity(0.85), palette.ink2)
        let fills = levels.map { QuotaInk.fill($0, palette) }
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            for (index, ring) in rings.enumerated() {
                let radius = min(size.width, size.height) / 2 - CGFloat(index) * (line + gap) - line / 2
                // 每圈一层：刻度压出的缝只挖自己这一圈
                context.drawLayer { layer in
                    layer.stroke(Self.arc(center, radius, to: 1), with: .color(track), lineWidth: line)
                    if ring.first > 0 {
                        layer.stroke(Self.arc(center, radius, to: ring.first), with: .color(fills[index]), style: StrokeStyle(lineWidth: line, lineCap: .round))
                    }
                    guard showsPace, ring.second > 0 else { return }
                    let mark = Self.tick(center, radius, at: ring.second, length: line + 3)
                    layer.blendMode = .destinationOut
                    layer.stroke(mark, with: .color(.black), style: StrokeStyle(lineWidth: 3.2, lineCap: .round))
                    layer.blendMode = .normal
                    layer.stroke(mark, with: .color(tick), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                }
            }
            if let mark {
                context.draw(context.resolve(Text(mark).font(.system(size: 13)).foregroundStyle(markInk)), at: center)
            }
        }
    }

    /// 从 12 点顺时针铺到 `fraction` 的弧。
    private static func arc(_ center: CGPoint, _ radius: CGFloat, to fraction: Double) -> Path {
        Path { $0.addArc(center: center, radius: radius, startAngle: .degrees(-90), endAngle: .degrees(-90 + 360 * min(fraction, 1)), clockwise: false) }
    }

    /// 圈上 `fraction` 处一道沿半径的短线。
    private static func tick(_ center: CGPoint, _ radius: CGFloat, at fraction: Double, length: CGFloat) -> Path {
        let angle = fraction * 2 * .pi - .pi / 2
        let (dx, dy) = (cos(angle), sin(angle))
        return Path {
            $0.move(to: CGPoint(x: center.x + dx * (radius - length / 2), y: center.y + dy * (radius - length / 2)))
            $0.addLine(to: CGPoint(x: center.x + dx * (radius + length / 2), y: center.y + dy * (radius + length / 2)))
        }
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

/// 明细：各窗口的用量条（带匀速刻度）、多久后重置或照这速度多久用完，按模型的周额度在后，右上角写更新于几分钟前。点开时才建。
struct QuotaDetail: View {
    let meter: QuotaMeter
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(meter.account).font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink)
                Spacer(minLength: 12)
                Text("更新于 \(Text(.currentDate, format: PiClock.ago(meter.updatedAt).live(.list)))").font(Typography.caption).foregroundStyle(palette.ink3)
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
                Text(window.hasReset ? "\(Dotted.inline)已重置" : "\(Dotted.inline)\(window.countdown)后重置")
                    .font(Typography.caption).foregroundStyle(palette.ink3)
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

    /// 细条：铺到已用，匀速刻度一道竖线（两侧压出缝），一块画布。
    private var bar: some View {
        let (used, pace) = (window.used, window.pace)
        let (track, fill, tick) = (palette.ink.opacity(0.1), QuotaInk.fill(window.level, palette), palette.ink.opacity(0.85))
        return Canvas { context, size in
            let y = size.height / 2
            context.fill(Path(roundedRect: CGRect(x: 0, y: y - 2, width: size.width, height: 4), cornerRadius: 2), with: .color(track))
            if used > 0 {
                context.fill(Path(roundedRect: CGRect(x: 0, y: y - 2, width: max(size.width * min(used, 1), 4), height: 4), cornerRadius: 2), with: .color(fill))
            }
            guard pace > 0 else { return }
            let x = size.width * pace
            context.blendMode = .destinationOut
            context.fill(Path(roundedRect: CGRect(x: x - 1.6, y: 0, width: 3.2, height: size.height), cornerRadius: 1.6), with: .color(.black))
            context.blendMode = .normal
            context.fill(Path(roundedRect: CGRect(x: x - 0.6, y: 0, width: 1.2, height: size.height), cornerRadius: 0.6), with: .color(tick))
        }
        .frame(height: 10)
    }
}
