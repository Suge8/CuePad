#if os(iOS)
import AppIntents
import SwiftUI
import WidgetKit

/// 紧凑态左位是 Cue 与一个读数（等你优先，否则活跃 Agent，不是任务数；旧快照没有读数时写破折号，不猜），右位是一只系统自己走的钟（`CueNow.clock`）。
/// 岛上持续在动的只有这只钟：循环动画系统不保证播，为了动而重发同一份内容会吃掉推送预算。其余的动是内容更新时系统做的短过渡。
/// 最小态与窄紧凑位（横屏）只有 28pt 圆：图形加至多 9+ 的读数，不缩字号；完整数在展开态与读屏名称里。
/// 展开态最高 160pt：头像、读数与钟排在摄像头两侧，下面是 `Details.room` 行；全放在摄像头下面那一块时，头一排就占掉三成高。
/// 岛的底系统钉死是黑的，状态的实色（`Palette.signal`，同锁屏那张卡）只铺在小块上：紧凑态与最小态等你时
/// 右位的钟、最小态那颗圆，展开态那颗对勾钮——常驻在状态栏里的平时只上字色，轮到你了才亮成一块。
/// 锁屏是另一张（`CueLockScreen`）：那块的底归我们，整块按状态上色、一个主角。
/// 调试画面复用这些视图，但不能代替系统灵动岛的宽度与状态栏验收（`-CuePadLiveActivity YES`）。
struct CueActivityViews {
    private let now: CueNow
    private let stale: Bool

    init(_ state: CueActivityState, at date: Date) {
        now = state.now.shown(at: date)
        stale = date >= state.now.staleAt
    }

    var lockScreen: some View { CueLockScreen(now: now, stale: stale).withPalette() }
    /// 锁屏那张卡的底色：系统里由 `activityBackgroundTint` 铺，调试画面自己铺。
    func lockFill(_ palette: Palette) -> Color { CueLockScreen(now: now, stale: stale).fill(palette) }
    var compactLeading: some View { CompactLeading(now: now).island() }
    var compactTrailing: some View { CompactTrailing(now: now).island() }
    var minimal: some View { NarrowCount(now: now).island() }
    var expandedLeading: some View { Reading(now: now).frame(height: Self.head).padding(.leading, Self.inset).island() }
    var expandedTrailing: some View { Clock(now: now).font(IslandType.clock).frame(height: Self.head).padding(.trailing, Self.inset).island() }
    var expandedBottom: some View { Details(now: now).island() }
    /// 调试画面里展开态的样子：三块照系统摆的位置拼在一起。
    var expanded: some View { ActivityBody(now: now).island() }
    var keyline: Color { now.keyTone.color(Palette(dark: true)) }

    static let staleOpacity = 0.55
    static let maxType = DynamicTypeSize.xLarge
    /// 头一排的高：同摄像头那一条，读数与钟排在它两侧。
    fileprivate static let head: CGFloat = 36
    fileprivate static let inset: CGFloat = 6
}

private extension View {
    func island() -> some View { withPalette().environment(\.colorScheme, .dark).dynamicTypeSize(...CueActivityViews.maxType) }
}

extension CueNow {
    /// 岛上那只钟从哪一刻起算：有等你的，是等得最久的那件；否则 Cue 这一轮，再否则最早在跑的那件。没有在等、在跑的（歇着、状态未确认）不画钟。
    var clock: Date? {
        func earliest(_ kinds: Set<Item.Kind>) -> Date? { items.filter { kinds.contains($0.kind) }.map(\.since).min() }
        if let waiting = earliest([.asks, .reply]) { return waiting }
        if case .working(_, _, let since) = cue { return since }
        return earliest([.running, .delegating])
    }
}

/// 所有尺寸共用口径与读屏名称；紧凑位写到 99+，28pt 圆位写到 9+，完整数在展开态。
private struct ActivityCount {
    let now: CueNow
    init(_ now: CueNow) { self.now = now }
    var waiting: Bool { now.needsYou > 0 }
    var value: Int? { waiting ? now.needsYou : now.agentCount }
    func digits(upTo limit: Int? = nil) -> String {
        guard let value else { return "—" }
        if let limit, value > limit { return "\(limit)+" }
        return value.formatted(.number.grouping(.never))
    }
    var line: String {
        if waiting { return String(localized: "\(now.needsYou) 等你") }
        if let agents = now.agentCount { return String(localized: "\(agents) 个活跃 Agent") }
        return String(localized: "活跃 Agent 数未知")
    }
    var tone: CueNow.Tone { waiting ? (now.tally.asks > 0 ? .asks : .reply) : .moving }
    /// 同会话状态标的图形：有拍板是气泡问号，只剩新回复是信封，没有等你的是 Agent。
    var glyph: Image { (now.tally.asks > 0 ? WidgetIcon.waiting : waiting ? .mail : .agent).image }
}

private struct Digits: View {
    let now: CueNow
    var limit: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        let count = ActivityCount(now)
        Text(count.digits(upTo: limit)).monospacedDigit()
            .contentTransition(dimmed ? .identity : reduceMotion ? .opacity : .numericText())
            .animation(dimmed ? nil : Motion.fading(Motion.nudge, reduceMotion: reduceMotion), value: count.value)
    }
}

/// 系统的时间文字：不靠更新自己逐秒走，过一小时写成时:分:秒；常亮屏变暗时系统自己降到不带秒。
/// 岛上能一直动的只有它：给图形加循环动画（`symbolEffect` 的 pulse、无限重复）在 iOS 27 模拟器的系统岛上录过，收起与展开都不播。
struct ActivityElapsed: View {
    let since: Date
    /// 时间文字会占满给它的宽、字靠左：排在右端的（默认）字要贴右缘。
    var alignment = TextAlignment.trailing

    var body: some View { Self.text(since: since).lineLimit(1).multilineTextAlignment(alignment) }

    /// 能嵌进一句里的那只钟（"已等 3:02"）。
    static func text(since: Date) -> Text {
        Text(.currentDate, format: .timer(countingUpIn: since..<Date.distantFuture)).monospacedDigit()
    }
}

private struct Clock: View {
    let now: CueNow
    @Environment(\.palette) private var palette

    var body: some View {
        if let since = now.clock { ActivityElapsed(since: since).foregroundStyle(ActivityCount(now).tone.color(palette)) }
    }
}

/// 系统的窄紧凑位与最小态最多容纳 28pt 圆：主读数放在左位，右位让系统收掉。
private struct CompactLeading: View {
    let now: CueNow
    @Environment(\.palette) private var palette
    @Environment(\.isDynamicIslandLimitedInWidth) private var narrow

    var body: some View {
        if narrow {
            NarrowCount(now: now)
        } else {
            let count = ActivityCount(now)
            HStack(spacing: 4) {
                CueNowFace(now: now, size: 28, rim: .black, disc: false)
                HStack(spacing: 3) {
                    // 一位数时前面带说它数的是什么的图形；两位数起系统给的这一侧排不下，只写数
                    if let value = count.value, value < 10 { count.glyph.font(IslandType.marker) }
                    Digits(now: now, limit: 99).font(IslandType.count)
                }
                .foregroundStyle(count.tone.color(palette))
            }
            .accessibilityElement(children: .ignore).accessibilityLabel(count.line)
        }
    }
}

private struct CompactTrailing: View {
    let now: CueNow
    @Environment(\.palette) private var palette
    @Environment(\.isDynamicIslandLimitedInWidth) private var narrow

    var body: some View {
        if narrow {
            EmptyView()
        } else if let since = now.clock, ActivityCount(now).waiting {
            let signal = palette.signal(ActivityCount(now).tone)
            ActivityElapsed(since: since, alignment: .center).font(IslandType.chipClock).minimumScaleFactor(0.7)
                .foregroundStyle(signal.ink).frame(width: IslandType.chipClockWidth)
                .padding(.horizontal, 6).frame(height: 24).background(signal.fill, in: .capsule)
        } else if now.clock != nil {
            Clock(now: now).font(IslandType.count).minimumScaleFactor(0.7).frame(width: IslandType.clockWidth, alignment: .trailing)
        } else {
            let count = ActivityCount(now)
            count.glyph.font(IslandType.marker).foregroundStyle(count.tone.color(palette))
        }
    }
}

private struct NarrowCount: View {
    let now: CueNow
    @Environment(\.palette) private var palette

    var body: some View {
        let count = ActivityCount(now)
        let signal = palette.signal(count.tone)
        VStack(spacing: 0) {
            count.glyph.resizable().scaledToFit().frame(width: IslandType.narrowMarker, height: IslandType.narrowMarker)
            Digits(now: now, limit: 9).font(IslandType.count).frame(height: IslandType.narrowNumberHeight)
        }
        .frame(width: IslandType.narrowSide, height: IslandType.narrowSide)
        .foregroundStyle(count.waiting ? signal.ink : count.tone.color(palette))
        .background(count.waiting ? signal.fill : .clear, in: .circle)
        .accessibilityElement(children: .ignore).accessibilityLabel(count.line)
    }
}

/// 展开态头一排左半：紧凑态左位的读数放大，前面是说它数的是什么的图形。Cue 不在这一排：它全身站在右下角（`Details`）。
private struct Reading: View {
    let now: CueNow
    @Environment(\.palette) private var palette

    var body: some View {
        let count = ActivityCount(now)
        HStack(spacing: 6) {
            count.glyph.font(IslandType.readingGlyph)
            Digits(now: now).font(IslandType.reading)
        }
        .foregroundStyle(count.tone.color(palette))
        .accessibilityElement(children: .ignore).accessibilityLabel(count.line)
    }
}

/// 头一排下面：左边按行算，一件等你占两行（问题与缘由）或占满（问题与对勾钮），其余一行一件；右边站着全身的 Cue。
/// 它整只站在里面，不像锁屏那张卡探出边去：系统把内容裁在离岛边十几点以内（`contentMargins` 设 0 也一样），探出去是齐刷刷一刀。
/// 岛的底是黑的，状态只上在字、图形与那颗钮上。
/// 有等你的只排等你的与在跑的，不写 Cue 此刻那一步：要你管的时候它在读哪个文件是噪音。歇着的不排。额度不属于岛的任务。
/// 否决过：下面整块铺状态的实色——黑岛里再套一块圆角色块，像盒子装盒子，真机上三行就被岛的下缘截断。
private struct Details: View {
    let now: CueNow
    @Environment(\.palette) private var palette

    static let room = 3
    /// 这一块的高，也是 Cue 的身高：头一排与系统上下的留白之外，160pt 里只剩这么多，再高下缘被系统裁掉。
    private static let height: CGFloat = 84
    /// 右边让给 Cue 的宽：行尾的字不排到它身上。
    private static let beside: CGFloat = 104

    private var step: String? {
        guard now.first == nil else { return nil }
        return switch now.cue {
        case .working(let woke, let doing, _): doing ?? woke ?? CueNow.thinking
        case .hearing: String(localized: "你的话在路上")
        case .away(let reason, _): reason
        case .idle: nil
        }
    }

    private var rows: ArraySlice<CueNow.Item> {
        var items = now.items.filter { $0.kind != .resting }
        // 第一件等你已经写在上面（`first` 与拍板那几行同一个次序）
        if now.first != nil, let shown = items.firstIndex(where: { $0.kind == .asks }) { items.remove(at: shown) }
        return items.prefix(Self.room - (now.first.map { $0.allow == nil ? 2 : 3 } ?? 0) - (step == nil ? 0 : 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let first = now.first { FirstWait(wait: first).id(first).transition(.blurReplace) }
            if let step {
                Text(step).font(IslandType.row).foregroundStyle(palette.ink2).lineLimit(1)
                    .contentTransition(.opacity)
            }
            ForEach(rows) { item in
                HStack(spacing: 8) {
                    Text(item.name).font(IslandType.row).foregroundStyle(palette.ink).lineLimit(1)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        item.kind.glyph?.image
                        // 还在动的写做了多久（自己走），停下的写状态词
                        if item.kind.tone == .moving {
                            ActivityElapsed(since: item.since).minimumScaleFactor(0.8).frame(width: IslandType.rowClockWidth, alignment: .trailing)
                        } else {
                            Text(item.label)
                        }
                    }
                    .font(IslandType.rowTail).foregroundStyle(item.kind.tone.color(palette)).fixedSize()
                }
                .accessibilityElement(children: .ignore).accessibilityLabel(Dotted(item.name, item.label).spoken)
                .transition(.blurReplace)
            }
        }
        .padding(.leading, CueActivityViews.inset).padding(.trailing, Self.beside)
        .frame(maxWidth: .infinity, minHeight: Self.height, alignment: .topLeading)
        .overlay(alignment: .bottomTrailing) {
            Image(decorative: "cue-pose-\(now.beat.pose)").resizable().scaledToFit().frame(height: Self.height)
                .padding(.trailing, CueActivityViews.inset)
                .opacity(now.beat.faded ? CueFaceMarks.awayOpacity : 1)
        }
    }
}

extension CueNow.Item.Kind {
    /// 行尾状态词前的图形，同 App 里会话状态标的那几个；歇着、状态未确认只写字。
    var glyph: WidgetIcon? {
        switch self {
        case .asks: .waiting
        case .reply: .mail
        case .running: .session
        case .delegating: .relay
        case .done: .done
        case .resting, .unconfirmed: nil
        }
    }
}

private struct ActivityBody: View {
    let now: CueNow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Reading(now: now)
                Spacer(minLength: 0)
                Clock(now: now).font(IslandType.clock)
            }
            Details(now: now)
        }
    }
}

private struct FirstWait: View {
    let wait: CueNow.Wait
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Link(destination: wait.open) {
                VStack(alignment: .leading, spacing: 2) {
                    // 系统的岛按一行的高来量这一块：不钉住竖向的高，两行的问题被截成一行
                    Text(wait.title).font(IslandType.question).foregroundStyle(palette.ink).lineLimit(wait.detail == nil ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                    if let detail = wait.detail { Text(detail).font(IslandType.row).foregroundStyle(palette.ink2).lineLimit(1) }
                }
            }
            // 岛上铺了实色的只有这颗钮：等你那块赭黄，墨色的勾
            if let allow = wait.allow {
                let signal = palette.signal(.asks)
                AllowTick(allow: allow, fill: signal.fill, tick: signal.ink, size: CGSize(width: 72, height: 36))
            }
        }
    }
}

/// 同 App 里拍板卡答"可以"的那颗钮：只有对勾。带上"允许一次"四个字，iPhone 17 的岛上问题只剩十个字就被截断。
struct AllowTick: View {
    let allow: CueNow.Allow
    let fill: Color
    let tick: Color
    let size: CGSize

    var body: some View {
        Button(intent: AllowOnceIntent(allow)) {
            WidgetIcon.tick.image.font(IslandType.posterTick).foregroundStyle(tick)
                .frame(width: size.width, height: size.height).background(fill, in: .capsule)
        }
        .accessibilityLabel("允许一次")
        .buttonStyle(.plain).fixedSize()
    }
}
#endif
