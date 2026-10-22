#if os(iOS)
import AppIntents
import SwiftUI
import WidgetKit

/// 实时活动的几种样子（`CueActivityState`）。小组件扩展按系统给的态画（`CueActivityWidget`）；主 App 也编进了这个文件，
/// 调试画面用同一份视图画出各态（`DebugActivityStage`）：系统的上下文（`ActivityViewContext`）造不出来，这里只吃内容与过没过时。
/// 珠子、那一句与头像就是 App 里 Cue 那一行的同一份（`CueNowViews`）；过时了（`staleDate` 到了还没有新的一份）只信慢的事实（`CueNow.settled`）。
/// - 紧凑态：短词、走秒起点与颜色同出 `CueNow.focus`（走秒系统自己走，不耗推送）；横屏窄紧凑态（`isDynamicIslandLimitedInWidth`）只留头像与最前那颗珠子加总数。
/// - 展开态：第一件等你带"允许一次"（`AllowOnceIntent`），最后一行各家额度（快重置时倒数，`QuotaReminder.isNear`）。展开态与锁屏都不高过 160 点。
/// - 锁屏：同展开态的内容排在纸上；过时时整张变淡，右上写这一份是多久前的。
/// 灵动岛的底永远是黑的，岛里一律按深色取色板。
struct CueActivityViews {
    /// 画的那一份：过时了在这里一次换成只信慢的事实，各态都画它。
    private let state: CueActivityState
    private let stale: Bool

    init(_ state: CueActivityState, stale: Bool) {
        var shown = state
        if stale { shown.now = state.now.settled }
        (self.state, self.stale) = (shown, stale)
    }

    var lockScreen: some View { LockScreen(state: state, stale: stale).withPalette() }

    /// `limited`：横屏窄紧凑态；不给时读系统的（`isDynamicIslandLimitedInWidth`，只有系统能设，调试画面直接给）。
    func compactLeading(limited: Bool? = nil) -> some View { CompactLeading(now: state.now, forced: limited).island() }

    func compactTrailing(limited: Bool? = nil) -> some View { CompactTrailing(now: state.now, forced: limited).island() }

    var minimal: some View { CueNowFace(now: state.now, size: 24).island() }

    var expandedLeading: some View { CueNowFace(now: state.now, size: 44).padding(.leading, 2).island() }

    var expandedTrailing: some View { ExpandedTrailing(now: state.now).island() }

    var expandedCenter: some View { Sentence(now: state.now, island: true).island() }

    var expandedBottom: some View { Details(state: state, island: true).padding(.horizontal, 2).island() }

    var keyline: Color { state.now.ring(Palette(dark: true)) }

    /// 过时时整张的不透明度。
    static let staleOpacity = 0.55
}

private extension View {
    func island() -> some View { withPalette().environment(\.colorScheme, .dark) }
}

/// 走秒：从 `since` 往上数，系统每秒自己换字。计时文字在实时活动里会撑满给它的宽，按要写几位定宽。
private struct Clock: View {
    let since: Date

    var body: some View {
        // 这一份画出来后要走一阵才有下一份：按快走到的那一档留宽（一小时内是"分:秒"，再往上带小时）
        let hours = Date.now.timeIntervalSince(since) > 50 * 60
        Text(timerInterval: since...since.addingTimeInterval(Self.span), countsDown: false, showsHours: hours)
            .monospacedDigit().multilineTextAlignment(.trailing).lineLimit(1)
            .frame(width: hours ? 64 : 46, alignment: .trailing)
    }

    /// 计时最多走多久（一天）：过了就停在那里，不倒回去。
    private static let span: TimeInterval = 24 * 3600
}

/// 紧凑态左边：头像接短词（颜色是谁的事）；横屏窄处只留头像。
private struct CompactLeading: View {
    let now: CueNow
    let forced: Bool?
    @Environment(\.palette) private var palette
    @Environment(\.isDynamicIslandLimitedInWidth) private var narrow
    private var limited: Bool { forced ?? narrow }

    var body: some View {
        HStack(spacing: 5) {
            CueNowFace(now: now, size: 24)
            if !limited {
                Text(now.focus.word).font(.system(size: 14, weight: .semibold)).foregroundStyle(now.focus.tone.color(palette))
                    .lineLimit(1).fixedSize()
                    .contentTransition(.opacity)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(now.headline)
    }
}

/// 紧凑态右边：最前三颗珠子接走秒（不写"+N"：摄像头旁放不下，会被截成省略号，总数在展开态）；横屏窄处只留最前那颗珠子与总数。
private struct CompactTrailing: View {
    let now: CueNow
    let forced: Bool?
    @Environment(\.palette) private var palette
    @Environment(\.isDynamicIslandLimitedInWidth) private var narrow
    private var limited: Bool { forced ?? narrow }

    var body: some View {
        HStack(spacing: 6) {
            if limited {
                if let first = now.beads.first { BeadDot(kind: first.kind, size: 8) }
                Text("\(now.beads.count + now.hidden)").font(.system(size: 14, weight: .semibold)).monospacedDigit().foregroundStyle(palette.ink)
            } else {
                if !now.beads.isEmpty { CueBeads(beads: Array(now.beads.prefix(Self.beads)), size: 7, limit: Self.beads) }
                if let since = now.focus.since {
                    Clock(since: since).font(.system(size: 14, weight: .semibold)).foregroundStyle(now.focus.tone.color(palette))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(now.spoken)
    }

    private static let beads = 3
}

/// 展开态右上：走秒在上，珠子在下（从紧凑态的位置原地长出来）。
private struct ExpandedTrailing: View {
    let now: CueNow
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let since = now.focus.since { Clock(since: since).font(.system(size: 16, weight: .semibold)).foregroundStyle(now.focus.tone.color(palette)) }
            if !now.beads.isEmpty { CueBeads(beads: now.beads, hidden: now.hidden, size: 8, limit: 5) }
        }
        .padding(.trailing, 2)
    }
}

/// 那一句（窄处那一句 `headline`：摄像头下与锁屏头一行都窄；用工具时谁叫醒的另起一行，`CueNow.aside`、`Details`）。
private struct Sentence: View {
    let now: CueNow
    let island: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Text(now.headline).font(island ? .headline : .subheadline.weight(.semibold)).foregroundStyle(palette.ink)
            .lineLimit(1).minimumScaleFactor(0.85)
            .id(now.headline)
            .transition(.push(from: .bottom))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 展开态与锁屏的下半：Cue 此刻那一步、第一件等你、放得下的几份活、各家额度。高度有上限（160 点）：
/// 一共留三行给前三样（等你占两行），活排在最后、有几行列几份。
private struct Details: View {
    let state: CueActivityState
    let island: Bool
    @Environment(\.palette) private var palette

    private static let rows = 3

    var body: some View {
        let now = state.now
        let works = Self.rows - (now.aside == nil ? 0 : 1) - (now.first == nil ? 0 : 2)
        VStack(alignment: .leading, spacing: 7) {
            if let aside = now.aside {
                Text(aside).font(.footnote).foregroundStyle(palette.ink2).lineLimit(1)
                    .id(aside).transition(.push(from: .bottom))
            }
            if let first = now.first { FirstWait(wait: first, island: island) }
            if works > 0 { Works(beads: now.beads.filter { $0.kind != .asks }, limit: works) }
            if !state.quotas.isEmpty { Quotas(quotas: state.quotas) }
        }
    }
}

/// 几份活，一份一行：珠子、名字、样子（等子代理写几个），右边走秒（刚做完写多久前）。
private struct Works: View {
    let beads: [CueNow.Bead]
    let limit: Int
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(beads.prefix(limit)) { bead in
                HStack(spacing: 8) {
                    BeadDot(kind: bead.kind, size: 8)
                    Text(bead.name).font(.subheadline.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1)
                    Text(bead.kind == .delegating && bead.subagents > 0 ? "等 \(bead.subagents) 个子代理" : bead.kind.label)
                        .font(.footnote).foregroundStyle(bead.kind.tone.color(palette)).lineLimit(1).fixedSize()
                    Spacer(minLength: 6)
                    if bead.kind == .done || bead.kind == .resting {
                        Text(bead.since, style: .relative).font(.footnote).monospacedDigit().foregroundStyle(palette.ink3)
                            .multilineTextAlignment(.trailing).frame(width: 64, alignment: .trailing)
                    } else {
                        Clock(since: bead.since).font(.footnote).foregroundStyle(palette.ink3)
                    }
                }
                .transition(.push(from: .bottom))
            }
        }
    }
}

/// 各家额度一行：每个账号写它最紧的那个窗口还剩多少（颜色按档位，`UsageLevel`）；本周快重置时（`QuotaReminder.isNear`）那一段换成倒数，
/// 提醒把额度用掉。放不下时先省掉不在倒数的账号。
private struct Quotas: View {
    let quotas: [CueActivityState.Quota]
    @Environment(\.palette) private var palette

    var body: some View {
        let near = quotas.filter { $0.windows.contains(where: \.near) }
        ViewThatFits(in: .horizontal) {
            line(quotas)
            if !near.isEmpty { line(near) }
        }
        .font(.caption)
        .monospacedDigit()
    }

    private func line(_ quotas: [CueActivityState.Quota]) -> some View {
        HStack(spacing: 12) {
            ForEach(quotas, id: \.account) { quota in
                if let window = quota.windows.first(where: \.near) ?? quota.windows.min(by: { $0.left < $1.left }) {
                    HStack(spacing: 4) {
                        Text(quota.account).fontWeight(.semibold).foregroundStyle(palette.ink2)
                        Text("\(window.name) \(Text(window.percent).foregroundStyle(window.level.ink(palette)))").foregroundStyle(palette.ink3)
                        if window.near {
                            Text(timerInterval: Date.now...window.resetsAt, countsDown: true, showsHours: true)
                                .foregroundStyle(palette.ink).frame(width: 50, alignment: .trailing)
                            Text("后重置").foregroundStyle(palette.ink3)
                        }
                    }
                    .lineLimit(1).fixedSize()
                }
            }
            Spacer(minLength: 0)
        }
    }
}

private struct LockScreen: View {
    let state: CueActivityState
    let stale: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        let now = state.now
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                CueNowFace(now: now, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Sentence(now: now, island: false)
                    Text(now.advancing > 0 ? "推进中 \(now.advancing) 件" : now.name).font(.caption).foregroundStyle(palette.ink3)
                }
                Spacer(minLength: 6)
                if stale {
                    Text(now.at, style: .relative).font(.footnote).monospacedDigit().foregroundStyle(palette.ink3)
                        .multilineTextAlignment(.trailing).frame(width: 72, alignment: .trailing)
                } else {
                    VStack(alignment: .trailing, spacing: 5) {
                        if let since = now.focus.since { Clock(since: since).font(.subheadline.weight(.semibold)).foregroundStyle(now.focus.tone.color(palette)) }
                        if !now.beads.isEmpty { CueBeads(beads: now.beads, hidden: now.hidden, size: 8, limit: 5) }
                    }
                }
            }
            Details(state: state, island: false)
        }
        .padding(16)
        .opacity(stale ? CueActivityViews.staleOpacity : 1)
        .foregroundStyle(palette.ink)
        .activityBackgroundTint(palette.paper)
        .activitySystemActionForegroundColor(palette.ink)
    }
}

/// 第一件等你：赭黄问号、说什么，右边（Cue 带选项的提问才有的）"允许一次"（`AllowOnceIntent`，不打开 App）；点这一行别处是打开它。
private struct FirstWait: View {
    let wait: CueNow.Wait
    let island: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Link(destination: wait.open) {
            HStack(alignment: .center, spacing: 8) {
                WidgetIcon.waiting.image.font(.subheadline).foregroundStyle(palette.waiting)
                VStack(alignment: .leading, spacing: 1) {
                    Text(wait.title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
                    if let detail = wait.detail { Text(detail).font(.caption).foregroundStyle(palette.ink2).lineLimit(1) }
                }
                Spacer(minLength: 6)
                if let allow = wait.allow {
                    Button(intent: AllowOnceIntent(allow)) {
                        Text("允许一次").font(.footnote.weight(.semibold)).foregroundStyle(palette.onFill)
                            .padding(.horizontal, 12).frame(minHeight: 30).background(palette.signatureFill, in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
#endif
