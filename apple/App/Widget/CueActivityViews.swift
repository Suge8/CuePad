#if os(iOS)
import AppIntents
import SwiftUI
import WidgetKit

/// 紧凑态只留 Cue、语义图形与一个读数：等你优先，否则活跃 Agent（不是任务数）；旧快照没有读数时写破折号，不猜。
/// 展开与锁屏才显示完整读数、此刻那一步与必要明细。没有周期动画，内容更新时由系统做短过渡。
/// 调试画面复用这些视图，但不能代替系统灵动岛的宽度与状态栏验收。
struct CueActivityViews {
    private let now: CueNow
    private let stale: Bool

    init(_ state: CueActivityState, at date: Date) {
        now = state.now.shown(at: date)
        stale = date >= state.now.staleAt
    }

    var lockScreen: some View { LockScreen(now: now, stale: stale).withPalette().dynamicTypeSize(...Self.maxType) }
    var compactLeading: some View { CueNowFace(now: now, size: 24, rim: .black).island() }
    var compactTrailing: some View { CompactCount(now: now).island() }
    var minimal: some View {
        HStack { CueNowFace(now: now, size: 24, rim: .black) }
            .accessibilityElement(children: .ignore).accessibilityLabel(ActivityCount(now).line).island()
    }
    var expanded: some View {
        ActivityBody(now: now, rim: .black).padding(.horizontal, 6).padding(.bottom, 8).island()
    }
    var keyline: Color { now.keyTone.color(Palette(dark: true)) }

    static let staleOpacity = 0.55
    static let maxType = DynamicTypeSize.xLarge
}

private extension View {
    func island() -> some View { withPalette().environment(\.colorScheme, .dark).dynamicTypeSize(...CueActivityViews.maxType) }
}

/// 显示口径与完整读屏名称共用；紧凑位最多三个字符，超过两位明确写 99+，完整数留在展开态。
private struct ActivityCount {
    let now: CueNow
    init(_ now: CueNow) { self.now = now }
    var waiting: Bool { now.needsYou > 0 }
    var value: Int? { waiting ? now.needsYou : now.agentCount }
    var compact: String {
        guard let value else { return "—" }
        return value > 99 ? "99+" : value.formatted(.number.grouping(.never))
    }
    var line: String {
        if waiting { return String(localized: "\(now.needsYou) 等你") }
        if let agents = now.agentCount { return String(localized: "\(agents) 个活跃 Agent") }
        return String(localized: "活跃 Agent 数未知")
    }
    var tone: CueNow.Tone { waiting ? (now.tally.asks > 0 ? .asks : .reply) : .moving }
}

private struct CompactCount: View {
    let now: CueNow
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        let count = ActivityCount(now)
        HStack(spacing: 4) {
            (count.waiting ? WidgetIcon.waiting : .agent).image
                .font(IslandType.marker).frame(width: IslandType.markerWidth)
                .contentTransition(.opacity)
            Text(count.compact).font(IslandType.count).monospacedDigit()
                .contentTransition(dimmed ? .identity : reduceMotion ? .opacity : .numericText())
                .animation(dimmed ? nil : Motion.fading(Motion.nudge, reduceMotion: reduceMotion), value: count.value)
                .frame(width: IslandType.countWidth)
        }
        .foregroundStyle(count.tone.color(palette))
        .accessibilityElement(children: .ignore).accessibilityLabel(count.line)
    }
}

private struct Headline: View {
    let now: CueNow
    @Environment(\.palette) private var palette

    var body: some View {
        let count = ActivityCount(now)
        VStack(alignment: .trailing, spacing: 3) {
            Text(count.line).font(.headline).foregroundStyle(count.tone.color(palette)).monospacedDigit()
            if count.waiting, let agents = now.agentCount {
                Text("\(agents) 个活跃 Agent").font(.subheadline).foregroundStyle(palette.ink2).monospacedDigit()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 最要紧的那件在前：拍板问题、Cue 此刻那一步、至多两件活。额度与逐秒时钟不属于岛的任务。
private struct Details: View {
    let now: CueNow
    @Environment(\.palette) private var palette

    private var step: String? {
        switch now.cue {
        case .working(let woke, let doing, _): doing ?? woke ?? CueNow.thinking
        case .hearing: String(localized: "你的话在路上")
        case .away(let reason, _): reason
        case .idle: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let first = now.first { FirstWait(wait: first) }
            if let step {
                Text(step).font(.subheadline).foregroundStyle(palette.ink2).lineLimit(1)
                    .contentTransition(.opacity)
            }
            if now.first == nil, step == nil {
                ForEach(now.items.filter { $0.kind != .asks }.prefix(2)) { item in
                    HStack(spacing: 12) {
                        Text(item.name).foregroundStyle(palette.ink).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(item.kind.label).foregroundStyle(item.kind.tone.color(palette)).fixedSize()
                    }
                    .font(.subheadline)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ActivityBody: View {
    let now: CueNow
    var rim: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CueNowFace(now: now, size: 40, rim: rim)
                Spacer(minLength: 0)
                Headline(now: now)
            }
            Details(now: now)
        }
    }
}

private struct LockScreen: View {
    let now: CueNow
    let stale: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ActivityBody(now: now)
            if stale {
                Text(now.at, style: .relative).font(.caption).foregroundStyle(palette.ink3)
            }
        }
        .padding(16)
        .opacity(stale ? CueActivityViews.staleOpacity : 1)
        .activityBackgroundTint(palette.paper)
        .activitySystemActionForegroundColor(palette.ink)
    }
}

private struct FirstWait: View {
    let wait: CueNow.Wait
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            Link(destination: wait.open) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(wait.title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(wait.detail == nil ? 2 : 1)
                    if let detail = wait.detail { Text(detail).font(.caption).foregroundStyle(palette.ink2).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let allow = wait.allow {
                Button(intent: AllowOnceIntent(allow)) {
                    Text("允许一次").font(.footnote.weight(.semibold)).foregroundStyle(palette.onFill)
                        .padding(.horizontal, 12).frame(minHeight: 36).background(palette.signatureFill, in: .capsule)
                }
                .buttonStyle(.plain).fixedSize()
            }
        }
    }
}
#endif
