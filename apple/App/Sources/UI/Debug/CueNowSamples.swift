#if DEBUG
import CueStore
import Foundation

/// Cue 此刻的几份样例（`-CuePadCueNow <名字>`，`DebugHooks.Preset.cueNow`）：页头、侧栏、小组件与实时活动按同一份画，截各态、录切换用。
/// 时刻都从此刻往前推，计时与"x 分钟前"截出来是合理的数。
enum CueNowSamples {
    private static func ago(_ minutes: Double) -> Date { .now.addingTimeInterval(-minutes * 60) }

    private static func item(_ id: String, _ kind: CueNow.Item.Kind, _ name: String, _ minutes: Double, subagents: Int = 0) -> CueNow.Item {
        CueNow.Item(id: id, kind: kind, name: name, since: ago(minutes), subagents: subagents)
    }

    private static let push = CueNow.Wait(
        title: String(localized: "可以推送 v1.4 到 TestFlight 吗？", table: "Demo"), detail: nil, open: DeepLink.cue.url,
        allow: CueNow.Allow(message: UUID(), choice: CueAsk.once))

    private static func now(
        _ mood: CueMood, _ cue: CueNow.Brain, _ items: [CueNow.Item], advancing: Int, first: CueNow.Wait? = nil, resting: CueMood = .listening
    ) -> CueNow {
        let count = { (kind: CueNow.Item.Kind) in items.count { $0.kind == kind } }
        let tally = CueNow.Tally(asks: count(.asks), reply: count(.reply), running: count(.running), delegating: count(.delegating))
        return CueNow(name: "Cue", mood: mood, restingMood: resting, cue: cue, tally: tally, advancing: advancing, items: items, first: first, at: .now)
    }

    /// 被会话叫醒、在看它交回的结果；一件在跑、一件等子代理。
    static let woke = now(.thinking, .working(woke: String(localized: "被 canvas-zoom 叫醒", table: "Demo"), doing: String(localized: "读取 Sources/Zoom.swift", table: "Demo"), since: ago(0.7)), [
        item("homepage", .running, String(localized: "首页改版", table: "Demo"), 0.97),
        item("notes", .delegating, String(localized: "发言顺序修复", table: "Demo"), 12.05, subagents: 2),
        item("canvas", .resting, String(localized: "画布缩放", table: "Demo"), 2),
    ], advancing: 3)

    /// Cue 歇着，交出去的活在跑、等子代理交回。
    static let delegating = now(.listening, .idle, [
        item("canvas", .running, String(localized: "画布缩放", table: "Demo"), 4.2),
        item("notes", .delegating, String(localized: "发言顺序修复", table: "Demo"), 12.05, subagents: 2),
        item("homepage", .delegating, String(localized: "首页改版", table: "Demo"), 6.5, subagents: 1),
    ], advancing: 3)

    /// 一件要你拍板（推送），其余在跑。
    static let asks = now(.waiting, .idle, [
        item("ask", .asks, String(localized: "推送 v1.4 到 TestFlight", table: "Demo"), 3),
        item("canvas", .running, String(localized: "画布缩放", table: "Demo"), 4.2),
        item("notes", .delegating, String(localized: "发言顺序修复", table: "Demo"), 12.05, subagents: 2),
    ], advancing: 2, first: push, resting: .waiting)

    /// 刚做完一件，还有一件在跑。
    static let done = now(.done, .idle, [
        item("canvas", .running, String(localized: "画布缩放", table: "Demo"), 4.2),
        item("readme", .done, String(localized: "README 截图换成 Swift 版", table: "Demo"), 0.5),
    ], advancing: 1, resting: .done)

    /// 做完一件后又派出三件在跑，做完的那件已过了留它的时候（`doneWindow`）：岛该说在跑的，不再停在做完。
    static let afterDone = now(.listening, .idle, [
        item("board", .running, String(localized: "出手机任务看板方案", table: "Demo"), 0.95),
        item("header", .running, String(localized: "出 iOS header 收口方案", table: "Demo"), 0.97),
        item("dock", .running, String(localized: "底部 tab 切页丝滑收口", table: "Demo"), 0.97),
        item("release", .done, String(localized: "推送并发新版", table: "Demo"), 25.1),
    ], advancing: 3, resting: .done)

    /// 一屏放不下的：Cue 被叫醒在用工具，一件等你允许，四件推进中，刚做完一件。
    static let crowded = now(.thinking, .working(woke: String(localized: "被 canvas-zoom 叫醒", table: "Demo"), doing: String(localized: "读取 Sources/Zoom.swift", table: "Demo"), since: ago(0.7)), [
        item("ask", .asks, String(localized: "推送 v1.4 到 TestFlight", table: "Demo"), 3),
        item("board", .running, String(localized: "出手机任务看板方案", table: "Demo"), 0.95),
        item("header", .running, String(localized: "出 iOS header 收口方案", table: "Demo"), 0.97),
        item("dock", .running, String(localized: "底部 tab 切页丝滑收口", table: "Demo"), 0.97),
        item("notes", .delegating, String(localized: "发言顺序修复", table: "Demo"), 12.05, subagents: 2),
        item("readme", .done, String(localized: "README 截图换成 Swift 版", table: "Demo"), 2),
    ], advancing: 4, first: push, resting: .waiting)

    /// 他报的那一刻：Cue 歇着，推进中 4 件——3 件在跑、1 件歇着等它派出的 1 个子代理交回。
    static let four = now(.listening, .idle, [
        item("board", .running, String(localized: "出手机任务看板方案", table: "Demo"), 3.2),
        item("header", .running, String(localized: "出 iOS header 收口方案", table: "Demo"), 1.4),
        item("dock", .running, String(localized: "底部 tab 切页丝滑收口", table: "Demo"), 0.9),
        item("notes", .delegating, String(localized: "发言顺序修复", table: "Demo"), 12.05, subagents: 1),
    ], advancing: 4)

    /// 同上，另有一件要你拍板、一个会话待回复。
    static let fourAsks = now(.waiting, .idle, [
        item("ask", .asks, String(localized: "推送 v1.4 到 TestFlight", table: "Demo"), 3),
        item("reply/glass", .reply, String(localized: "玻璃按钮重做", table: "Demo"), 9),
        item("board", .running, String(localized: "出手机任务看板方案", table: "Demo"), 3.2),
        item("header", .running, String(localized: "出 iOS header 收口方案", table: "Demo"), 1.4),
        item("dock", .running, String(localized: "底部 tab 切页丝滑收口", table: "Demo"), 0.9),
        item("notes", .delegating, String(localized: "发言顺序修复", table: "Demo"), 12.05, subagents: 1),
    ], advancing: 4, first: push, resting: .waiting)

    /// 同上，Cue 自己被叫醒在用工具。
    static let fourWorking = now(.thinking, .working(woke: String(localized: "被 notes 叫醒", table: "Demo"), doing: String(localized: "读取 Sources/Zoom.swift", table: "Demo"), since: ago(0.7)), [
        item("board", .running, String(localized: "出手机任务看板方案", table: "Demo"), 3.2),
        item("header", .running, String(localized: "出 iOS header 收口方案", table: "Demo"), 1.4),
        item("dock", .running, String(localized: "底部 tab 切页丝滑收口", table: "Demo"), 0.9),
        item("notes", .delegating, String(localized: "发言顺序修复", table: "Demo"), 12.05, subagents: 1),
    ], advancing: 4)

    /// 它运行的那台 Mac 没开，手上的活照旧：一件拍板、一个会话待回复、三件在跑。
    static let awayBusy = now(.sleeping, .away(String(localized: "「Mac Studio」没开", table: "Demo"), failed: false), [
        item("ask", .asks, String(localized: "推送 v1.4 到 TestFlight", table: "Demo"), 3),
        item("reply/glass", .reply, String(localized: "玻璃按钮重做", table: "Demo"), 9),
        item("board", .running, String(localized: "出手机任务看板方案", table: "Demo"), 3.2),
        item("header", .running, String(localized: "出 iOS header 收口方案", table: "Demo"), 1.4),
        item("dock", .running, String(localized: "底部 tab 切页丝滑收口", table: "Demo"), 0.9),
    ], advancing: 3, first: push, resting: .sleeping)

    /// 推进中的都歇着：实时活动结束，页头照写。
    static let quiet = now(.listening, .idle, [
        item("canvas", .resting, String(localized: "画布缩放", table: "Demo"), 18),
        item("notes", .resting, String(localized: "发言顺序修复", table: "Demo"), 40),
    ], advancing: 2)

    /// 它运行的那台 Mac 没开。
    static let away = now(.sleeping, .away(String(localized: "「Mac Studio」没开", table: "Demo"), failed: false), [
        item("canvas", .resting, String(localized: "画布缩放", table: "Demo"), 60),
    ], advancing: 1, resting: .sleeping)

    static let all: [String: CueNow] = [
        "woke": woke, "delegating": delegating, "asks": asks, "done": done, "afterDone": afterDone, "crowded": crowded,
        "quiet": quiet, "away": away, "four": four, "fourAsks": fourAsks, "fourWorking": fourWorking, "awayBusy": awayBusy,
    ]
    static let tour = [woke, delegating, asks, done, quiet]

    /// 实时活动里的额度一瞥：Claude 本周快重置（倒数），Codex 宽松。
    static let quotas = [
        CueActivityState.Quota(account: "Claude", windows: [
            .init(name: String(localized: "5 小时", table: "Demo"), left: 0.68, level: .roomy, resetsAt: .now.addingTimeInterval(2.2 * 3600), near: false),
            .init(name: String(localized: "本周", table: "Demo"), left: 0.41, level: .roomy, resetsAt: .now.addingTimeInterval(2.4 * 3600), near: true),
        ]),
        CueActivityState.Quota(account: "Codex", windows: [
            .init(name: String(localized: "本周", table: "Demo"), left: 0.8, level: .roomy, resetsAt: .now.addingTimeInterval(4 * 86400), near: false),
        ]),
    ]
}
#endif
