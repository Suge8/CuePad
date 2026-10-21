#if DEBUG
import CueStore
import Foundation

/// Cue 此刻的几份样例（`-CuePadCueNow <名字>`，`DebugHooks.Preset.cueNow`）：页头、侧栏、小组件与实时活动按同一份画，截各态、录切换用。
/// 时刻都从此刻往前推，计时与"x 分钟前"截出来是合理的数。
enum CueNowSamples {
    private static func ago(_ minutes: Double) -> Date { .now.addingTimeInterval(-minutes * 60) }

    private static func bead(_ id: String, _ kind: CueNow.Bead.Kind, _ name: String, _ minutes: Double, subagents: Int = 0) -> CueNow.Bead {
        CueNow.Bead(id: id, kind: kind, name: name, since: ago(minutes), subagents: subagents, sessions: [id])
    }

    private static let push = CueNow.Wait(
        title: "推送 v1.4 到 TestFlight", detail: "Cue 请你允许推送代码", open: DeepLink.cue.url,
        allow: CueNow.Allow(message: UUID(), choice: CueAsk.once))

    private static func now(
        _ mood: CueMood, _ cue: CueNow.Brain, _ beads: [CueNow.Bead], advancing: Int, first: CueNow.Wait? = nil, resting: CueMood = .listening
    ) -> CueNow {
        CueNow(name: "Cue", mood: mood, restingMood: resting, cue: cue, beads: beads, hidden: 0, advancing: advancing, first: first, at: .now)
    }

    /// 被会话叫醒、在看它交回的结果；一件在跑、一件等子代理。
    static let woke = now(.thinking, .working(woke: "被 canvas-zoom 叫醒", doing: "读取 Sources/Zoom.swift", since: ago(0.7)), [
        bead("homepage", .running, "首页改版", 0.97),
        bead("notes", .delegating, "发言顺序修复", 12.05, subagents: 2),
        bead("canvas", .resting, "画布缩放", 2),
    ], advancing: 3)

    /// Cue 歇着，交出去的活在跑、等子代理交回。
    static let delegating = now(.listening, .idle, [
        bead("canvas", .running, "画布缩放", 4.2),
        bead("notes", .delegating, "发言顺序修复", 12.05, subagents: 2),
        bead("homepage", .delegating, "首页改版", 6.5, subagents: 1),
    ], advancing: 3)

    /// 一件要你拍板（推送），其余在跑。
    static let asks = now(.waiting, .idle, [
        bead("ask", .asks, "推送 v1.4 到 TestFlight", 3),
        bead("canvas", .running, "画布缩放", 4.2),
        bead("notes", .delegating, "发言顺序修复", 12.05, subagents: 2),
    ], advancing: 2, first: push, resting: .waiting)

    /// 刚做完一件，还有一件在跑。
    static let done = now(.done, .idle, [
        bead("canvas", .running, "画布缩放", 4.2),
        bead("readme", .done, "README 截图换成 Swift 版", 0.5),
    ], advancing: 1, resting: .done)

    /// 推进中的都歇着：实时活动结束，页头照写。
    static let quiet = now(.listening, .idle, [
        bead("canvas", .resting, "画布缩放", 18),
        bead("notes", .resting, "发言顺序修复", 40),
    ], advancing: 2)

    /// 它运行的那台 Mac 没开。
    static let away = now(.sleeping, .away("「Mac Studio」没开", failed: false), [
        bead("canvas", .resting, "画布缩放", 60),
    ], advancing: 1, resting: .sleeping)

    static let all: [String: CueNow] = [
        "woke": woke, "delegating": delegating, "asks": asks, "done": done, "quiet": quiet, "away": away,
    ]
    /// 录切换时轮流走的先后。
    static let tour = [woke, delegating, asks, done, quiet]

    /// 实时活动里的额度一瞥：Claude 本周快重置（倒数），Codex 宽松。
    static let quotas = [
        CueActivityState.Quota(account: "Claude", windows: [
            .init(name: "5 小时", left: 0.68, level: .roomy, resetsAt: .now.addingTimeInterval(2.2 * 3600), near: false),
            .init(name: "本周", left: 0.41, level: .roomy, resetsAt: .now.addingTimeInterval(2.4 * 3600), near: true),
        ]),
        CueActivityState.Quota(account: "Codex", windows: [
            .init(name: "本周", left: 0.8, level: .roomy, resetsAt: .now.addingTimeInterval(4 * 86400), near: false),
        ]),
    ]
}
#endif
