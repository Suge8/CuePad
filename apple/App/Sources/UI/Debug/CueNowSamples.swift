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
        _ cue: CueNow.Brain, _ items: [CueNow.Item], advancing: Int, first: CueNow.Wait? = nil, subagents: Int? = nil, agents: Int? = nil
    ) -> CueNow {
        let count = { (kinds: Set<CueNow.Item.Kind>) in items.count { kinds.contains($0.kind) } }
        let tally = CueNow.Tally(asks: count([.asks]), reply: count([.reply]), moving: count([.running, .delegating]), delegating: count([.delegating]))
        let children = subagents ?? items.reduce(0) { $0 + $1.subagents }
        return CueNow(
            name: "Cue", cue: cue, tally: tally, advancing: advancing,
            subagents: children, items: items, first: first, at: .now,
            agentCount: agents ?? count([.running, .delegating]) + children)
    }

    static let woke = now(.working(woke: String(localized: "被 canvas-zoom 叫醒", table: "Demo"), doing: String(localized: "读取 Sources/Zoom.swift", table: "Demo"), since: ago(0.7)), [
        item("homepage", .running, String(localized: "首页改版", table: "Demo"), 0.97),
        item("notes", .delegating, String(localized: "发言顺序修复", table: "Demo"), 12.05, subagents: 2),
        item("canvas", .resting, String(localized: "画布缩放", table: "Demo"), 2),
    ], advancing: 3)

    static let delegating = now(.idle, [
        item("canvas", .running, String(localized: "画布缩放", table: "Demo"), 4.2),
        item("notes", .delegating, String(localized: "发言顺序修复", table: "Demo"), 12.05, subagents: 2),
        item("homepage", .delegating, String(localized: "首页改版", table: "Demo"), 6.5, subagents: 1),
    ], advancing: 3)

    static let asks = now(.idle, [
        item("ask", .asks, String(localized: "推送 v1.4 到 TestFlight", table: "Demo"), 3),
        item("canvas", .running, String(localized: "画布缩放", table: "Demo"), 4.2),
        item("notes", .delegating, String(localized: "发言顺序修复", table: "Demo"), 12.05, subagents: 2),
    ], advancing: 2, first: push)

    static let done = now(.idle, [
        item("canvas", .running, String(localized: "画布缩放", table: "Demo"), 4.2),
        item("readme", .done, String(localized: "README 截图换成 Swift 版", table: "Demo"), 0.5),
    ], advancing: 1)

    /// 刚做完的那件再过 20 秒就到 `doneWindow`：录头像的做完与"刚做完"那一句同一刻收掉。
    static let doneExpiring = now(.idle, [
        item("readme", .done, String(localized: "README 截图换成 Swift 版", table: "Demo"), CueNow.doneWindow / 60 - 20.0 / 60),
    ], advancing: 0)

    /// 做完一件后又派出三件在跑，做完的那件已过了留它的时候（`doneWindow`）：岛该说在跑的，不再停在做完。
    static let afterDone = now(.idle, [
        item("board", .running, String(localized: "出手机任务看板方案", table: "Demo"), 0.95),
        item("header", .running, String(localized: "出 iOS header 收口方案", table: "Demo"), 0.97),
        item("dock", .running, String(localized: "底部 tab 切页丝滑收口", table: "Demo"), 0.97),
        item("release", .done, String(localized: "推送并发新版", table: "Demo"), 25.1),
    ], advancing: 3)

    static let crowded = now(.working(woke: String(localized: "被 canvas-zoom 叫醒", table: "Demo"), doing: String(localized: "读取 Sources/Zoom.swift", table: "Demo"), since: ago(0.7)), [
        item("ask", .asks, String(localized: "推送 v1.4 到 TestFlight", table: "Demo"), 3),
        item("board", .running, String(localized: "出手机任务看板方案", table: "Demo"), 0.95),
        item("header", .running, String(localized: "出 iOS header 收口方案", table: "Demo"), 0.97),
        item("dock", .running, String(localized: "底部 tab 切页丝滑收口", table: "Demo"), 0.97),
        item("notes", .delegating, String(localized: "发言顺序修复", table: "Demo"), 12.05, subagents: 2),
        item("readme", .done, String(localized: "README 截图换成 Swift 版", table: "Demo"), 2),
    ], advancing: 4, first: push)

    /// 他报的那一刻：Cue 歇着，推进中 4 件——3 件在跑、1 件歇着等它派出的 1 个子代理交回。
    static let four = now(.idle, [
        item("board", .running, String(localized: "出手机任务看板方案", table: "Demo"), 3.2),
        item("header", .running, String(localized: "出 iOS header 收口方案", table: "Demo"), 1.4),
        item("dock", .running, String(localized: "底部 tab 切页丝滑收口", table: "Demo"), 0.9),
        item("notes", .delegating, String(localized: "发言顺序修复", table: "Demo"), 12.05, subagents: 1),
    ], advancing: 4)

    static let fourAsks = now(.idle, [
        item("ask", .asks, String(localized: "推送 v1.4 到 TestFlight", table: "Demo"), 3),
        item("reply/glass", .reply, String(localized: "玻璃按钮重做", table: "Demo"), 9),
        item("board", .running, String(localized: "出手机任务看板方案", table: "Demo"), 3.2),
        item("header", .running, String(localized: "出 iOS header 收口方案", table: "Demo"), 1.4),
        item("dock", .running, String(localized: "底部 tab 切页丝滑收口", table: "Demo"), 0.9),
        item("notes", .delegating, String(localized: "发言顺序修复", table: "Demo"), 12.05, subagents: 1),
    ], advancing: 4, first: push)

    static let fourWorking = now(.working(woke: String(localized: "被 notes 叫醒", table: "Demo"), doing: String(localized: "读取 Sources/Zoom.swift", table: "Demo"), since: ago(0.7)), [
        item("board", .running, String(localized: "出手机任务看板方案", table: "Demo"), 3.2),
        item("header", .running, String(localized: "出 iOS header 收口方案", table: "Demo"), 1.4),
        item("dock", .running, String(localized: "底部 tab 切页丝滑收口", table: "Demo"), 0.9),
        item("notes", .delegating, String(localized: "发言顺序修复", table: "Demo"), 12.05, subagents: 1),
    ], advancing: 4)

    /// 真实规模：一件拍板、一个会话待回复；推进中 4 件，一共 12 个子代理在跑。
    static let busy = now(.idle, [
        item("ask", .asks, String(localized: "推送 v1.4 到 TestFlight", table: "Demo"), 3),
        item("reply/glass", .reply, String(localized: "玻璃按钮重做", table: "Demo"), 9),
        item("board", .running, String(localized: "出手机任务看板方案", table: "Demo"), 3.2),
        item("header", .running, String(localized: "出 iOS header 收口方案", table: "Demo"), 1.4),
        item("dock", .running, String(localized: "底部 tab 切页丝滑收口", table: "Demo"), 0.9),
        item("notes", .delegating, String(localized: "发言顺序修复", table: "Demo"), 12.05, subagents: 7),
    ], advancing: 4, first: push, subagents: 12, agents: 17)

    static let awayBusy = now(.away(String(localized: "「Mac Studio」没开", table: "Demo"), failed: false), [
        item("ask", .asks, String(localized: "推送 v1.4 到 TestFlight", table: "Demo"), 3),
        item("reply/glass", .reply, String(localized: "玻璃按钮重做", table: "Demo"), 9),
        item("board", .running, String(localized: "出手机任务看板方案", table: "Demo"), 3.2),
        item("header", .running, String(localized: "出 iOS header 收口方案", table: "Demo"), 1.4),
        item("dock", .running, String(localized: "底部 tab 切页丝滑收口", table: "Demo"), 0.9),
    ], advancing: 3, first: push)

    /// 推进中的都歇着：实时活动结束，页头照写。
    static let quiet = now(.idle, [
        item("canvas", .resting, String(localized: "画布缩放", table: "Demo"), 18),
        item("notes", .resting, String(localized: "发言顺序修复", table: "Demo"), 40),
    ], advancing: 2)

    static let away = now(.away(String(localized: "「Mac Studio」没开", table: "Demo"), failed: false), [
        item("canvas", .resting, String(localized: "画布缩放", table: "Demo"), 60),
    ], advancing: 1)

    static let hearing = now(.hearing, [
        item("canvas", .running, String(localized: "画布缩放", table: "Demo"), 4.2),
    ], advancing: 1)

    static let failed = now(.away(String(localized: "Pi 没能启动", table: "Demo"), failed: true), [
        item("canvas", .resting, String(localized: "画布缩放", table: "Demo"), 60),
    ], advancing: 1)

    static let all: [String: CueNow] = [
        "hearing": hearing, "failed": failed, "woke": woke, "delegating": delegating, "asks": asks, "done": done, "doneExpiring": doneExpiring, "afterDone": afterDone, "crowded": crowded,
        "quiet": quiet, "away": away, "four": four, "fourAsks": fourAsks, "fourWorking": fourWorking, "awayBusy": awayBusy, "busy": busy,
    ]
    static let tour = [quiet, hearing, woke, delegating, asks, done, failed, away]

}
#endif
