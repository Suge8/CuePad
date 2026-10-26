#if os(iOS)
import AppIntents
import SwiftUI
import WidgetKit

/// 实时活动的几种样子（`CueActivityState`）。小组件扩展按系统给的态画（`CueActivityWidget`）；主 App 也编进了这个文件，
/// 调试画面用同一份视图画出各态（`DebugActivityStage`）：系统的上下文（`ActivityViewContext`）造不出来，这里只吃内容与画的时刻。
/// 数字账与头像就是 App 里名牌的同一份（`CueNowViews`）。画的是推出的那一份到此刻的样子（`CueNow.shown(at:)`：
/// 过时了只信慢的事实，刚做完的到点收掉）；每一份的 `staleDate` 是它下一次变的那一刻（`CueLiveActivity`），系统到点重画，App 不用醒。
/// - 紧凑态：数字账那一排拆在摄像头两侧——左边要你管的那一组（拍板、待回复），右边"N 推进中"；没有要你管的，左边"N 推进中"、右边"M 子代理"。没有可数的只写短词（`CueNow.quietWord`）。
///   不计时：哪件的秒在走看不出，计时留在展开态每一行里。横屏窄紧凑态（`isDynamicIslandLimitedInWidth`）左边只留头像，右边是最前那一项的数。
/// - 最小态（与别的实时活动同在）：头像加角标（要你管的几件，`CueNow.needsYou`）。
/// - 展开态：头一行数字账，Cue 自己此刻那一步另起一行（`CueNow.step`），第一件等你带"允许一次"（`AllowOnceIntent`），其余几件一件一行，最后一行各家额度（快重置时倒数，`QuotaReminder.isNear`）。展开态与锁屏都不高过 160 点。
/// - 锁屏：同展开态的内容排在纸上；过时时整张变淡，右上写这一份是多久前的。
/// 灵动岛的底永远是黑的，岛里一律按深色取色板。
struct CueActivityViews {
    /// 画的那一份：推出的那一份到画的时刻的样子，各态都画它。
    private let state: CueActivityState
    private let stale: Bool

    init(_ state: CueActivityState, at date: Date) {
        var shown = state
        shown.now = state.now.shown(at: date)
        (self.state, self.stale) = (shown, date >= state.now.staleAt)
    }

    var lockScreen: some View { LockScreen(state: state, stale: stale).withPalette().dynamicTypeSize(...Self.maxType) }

    /// `limited`：横屏窄紧凑态；不给时读系统的（`isDynamicIslandLimitedInWidth`，只有系统能设，调试画面直接给）。
    func compactLeading(limited: Bool? = nil) -> some View { CompactLeading(now: state.now, forced: limited).island() }

    func compactTrailing(limited: Bool? = nil) -> some View { CompactTrailing(now: state.now, forced: limited).island() }

    var minimal: some View { CueNowFace(now: state.now, size: 24, badge: true, rim: .black).island() }

    var expandedLeading: some View { CueNowFace(now: state.now, size: 44, rim: .black).padding(.leading, 2).island() }

    /// 右上不放东西：数字账在头一行，计时在每一行里。
    var expandedTrailing: some View { EmptyView() }

    var expandedCenter: some View { Headline(now: state.now, island: true).island() }

    /// 岛的下沿两角是圆的、贴边的字会被系统按圆角裁掉：下半往里收、往上抬，最后一行落在圆角外。
    var expandedBottom: some View { Details(state: state, island: true).padding(.horizontal, 6).padding(.bottom, 8).island() }

    var keyline: Color { state.now.keyTone.color(Palette(dark: true)) }

    /// 过时时整张的不透明度。
    static let staleOpacity = 0.55
    /// 展开态与锁屏不高过 160 点：下半能少列的都少列了（`Details`），字号再大，头一行加 Cue 此刻那一步与第一件等你也放不下。
    static let maxType = DynamicTypeSize.xLarge
}

private extension View {
    func island() -> some View { withPalette().environment(\.colorScheme, .dark).dynamicTypeSize(...CueActivityViews.maxType) }

    /// 计时文字在实时活动里会撑满给它的宽：按 `template` 在此处字号下的宽摆它，字号变大跟着变宽，不被截成省略号。
    func timerWidth(_ template: String) -> some View {
        Text(template).monospacedDigit().lineLimit(1).hidden().overlay(alignment: .trailing) { self }
    }
}

/// 走秒：从 `since` 往上数，系统每秒自己换字。
private struct Clock: View {
    let since: Date

    var body: some View {
        // 这一份画出来后要走一阵才有下一份：按快走到的那一档留宽（一小时内是"分:秒"，再往上带小时）
        let hours = Date.now.timeIntervalSince(since) > 50 * 60
        Text(timerInterval: since...since.addingTimeInterval(Self.span), countsDown: false, showsHours: hours)
            .monospacedDigit().multilineTextAlignment(.trailing).lineLimit(1)
            .timerWidth(hours ? "0:00:00" : "00:00")
    }

    /// 计时最多走多久（一天）：过了就停在那里，不倒回去。
    private static let span: TimeInterval = 24 * 3600
}

/// 紧凑态左边：头像接要你管的那一组（拍板、待回复，同名牌那一排）；没有要你管的接推进中的头一项；没有可数的接短词。横屏窄处只留头像。
private struct CompactLeading: View {
    let now: CueNow
    let forced: Bool?
    @Environment(\.palette) private var palette
    @Environment(\.isDynamicIslandLimitedInWidth) private var narrow
    private var limited: Bool { forced ?? narrow }

    var body: some View {
        HStack(spacing: 5) {
            CueNowFace(now: now, size: 24, rim: .black)
            if !limited {
                if !now.yours.isEmpty {
                    // 拍板与待回复都有时收紧一号：两项加头像仍在摄像头左边那一半里
                    let both = now.yours.count > 1
                    HStack(spacing: both ? 5 : 6) { ForEach(now.yours) { CompactEntry(entry: $0, size: both ? 13 : 14) } }
                } else if let lead = now.moving.first {
                    CompactEntry(entry: lead)
                } else if let word = now.quietWord {
                    Text(word).font(.system(size: 14, weight: .semibold)).foregroundStyle(palette.ink2).lineLimit(1).fixedSize()
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(now.spoken)
    }
}

/// 紧凑态右边：有要你管的时是"N 推进中"，没有时是"M 子代理"；横屏窄处是要你管的几件（没有时推进中几件）。
private struct CompactTrailing: View {
    let now: CueNow
    let forced: Bool?
    @Environment(\.palette) private var palette
    @Environment(\.isDynamicIslandLimitedInWidth) private var narrow
    private var limited: Bool { forced ?? narrow }

    var body: some View {
        Group {
            if limited {
                if now.needsYou > 0 {
                    Text(now.needsYou, format: .number).font(.system(size: 14, weight: .bold)).monospacedDigit().foregroundStyle(palette.waiting)
                } else if !now.moving.isEmpty {
                    Text(now.advancing, format: .number).font(.system(size: 14, weight: .bold)).monospacedDigit().foregroundStyle(palette.signature)
                }
            } else if let entry = Self.trailing(now) {
                CompactEntry(entry: entry)
            }
        }
        .accessibilityHidden(true)
    }

    private static func trailing(_ now: CueNow) -> CueNow.Entry? {
        now.yours.isEmpty ? now.moving.dropFirst().first : now.moving.first
    }
}

/// 紧凑态的一项：着色的数接词。
private struct CompactEntry: View {
    let entry: CueNow.Entry
    var size: CGFloat = 14
    @Environment(\.palette) private var palette

    var body: some View {
        entry.text(number: entry.tone.color(palette)).monospacedDigit().foregroundStyle(palette.ink2)
            .contentTransition(.numericText(value: Double(entry.count)))
            .font(.system(size: size, weight: .semibold))
            .lineLimit(1).fixedSize()
    }
}

/// 头一行：数字账（摄像头下与锁屏头一行都窄，排不下就并、再截断）。
private struct Headline: View {
    let now: CueNow
    let island: Bool

    var body: some View {
        CueLedger(now: now, gap: island ? 9 : 8)
            .font(island ? .headline : .subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 展开态与锁屏的下半：Cue 此刻那一步、第一件等你、放得下的几份活、各家额度。高度有上限（160 点，超出的系统直接裁掉）：
/// 系统给多高就排多少（`ViewThatFits`），放不下时先少列活、再省掉额度；没列出的活在头一行的数字账里。
private struct Details: View {
    let state: CueActivityState
    let island: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        let works = state.now.items.filter { $0.kind != .asks }
        ViewThatFits(in: .vertical) {
            ForEach((0...works.count).reversed(), id: \.self) { shown in
                column(Array(works.prefix(shown)), quotas: !state.quotas.isEmpty)
            }
            column([], quotas: false)
        }
    }

    private func column(_ works: [CueNow.Item], quotas: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let step = state.now.step {
                Text(step).font(.footnote).foregroundStyle(palette.ink2).lineLimit(1)
                    .id(step).transition(.handOff)
            }
            if let first = state.now.first { FirstWait(wait: first, island: island) }
            if !works.isEmpty { Works(items: works) }
            if quotas { Quotas(quotas: state.quotas) }
        }
    }
}

/// 几件活，一件一行：名字、样子（着意思的色，等子代理写几个），右边走秒（刚做完、歇着、待回复写多久前）。
private struct Works: View {
    let items: [CueNow.Item]
    @Environment(\.palette) private var palette

    /// 多久前（`Text(_:style: .relative)`）最宽写成的样子：一天内最多两段，"小时、分钟"比"分钟、秒"宽。
    static let relative = String(localized: "00小时00分钟")

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(items) { item in
                HStack(spacing: 8) {
                    Text(item.name).font(.subheadline.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1)
                    (item.kind == .delegating && item.subagents > 0 ? Text("等 \(item.subagents) 个子代理") : Text(item.kind.label))
                        .font(.footnote).foregroundStyle(item.kind.tone.color(palette)).lineLimit(1).fixedSize()
                    Spacer(minLength: 6)
                    if [.done, .resting, .reply].contains(item.kind) {
                        Text(item.since, style: .relative).monospacedDigit().foregroundStyle(palette.ink3)
                            .multilineTextAlignment(.trailing).timerWidth(Self.relative).font(.footnote)
                    } else {
                        Clock(since: item.since).font(.footnote).foregroundStyle(palette.ink3)
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
                                .foregroundStyle(palette.ink).multilineTextAlignment(.trailing).timerWidth("0:00:00")
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
                CueNowFace(now: now, size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(now.name).font(.caption.weight(.semibold)).foregroundStyle(palette.ink3)
                    Headline(now: now, island: false)
                }
                Spacer(minLength: 6)
                if stale {
                    Text(now.at, style: .relative).monospacedDigit().foregroundStyle(palette.ink3)
                        .multilineTextAlignment(.trailing).timerWidth(Works.relative).font(.footnote)
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
