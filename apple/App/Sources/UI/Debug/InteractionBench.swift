#if os(macOS) && DEBUG
import AppKit
import CueStore
import Darwin
import QuartzCore

/// `-CuePadBench interact`：单次交互那一下的主线程耗时，逐项与预算（docs/verify.md「交互预算」）比较，
/// 每项结果作为一行 `INTERACT {json}` 打到标准输出，量完退出。配 `-CuePadDemo YES`（演示库）或 `-CuePadSeed perf`（大库）。
/// 动作就是点击、快捷键最终调用的工作区方法（`show`、`openCard`、`toggle`；侧栏发主菜单的动作），不经事件投递（那一段只有 1～5ms）。
/// - **点击回合**：动作发出到画面第一次变（含这次变化的第一帧提交）为止，主线程的全部 CPU 毫秒，跨多圈 run loop 求和：挪到下一帧的活照样算进去，
///   直到画面第一次变（画面的变化看窗口图层树里看得见的层，见 `TurnLog`）；CPU 时间不随机器忙闲变，墙钟会。
/// - **合计、最重一圈、指令数**：动作后 800ms 里主线程 CPU 的总数与最重的一圈（点击回合小而合计大，是活被挪到了后面的帧里，不是没了）；进程执行的指令数（百万）不随机器忙闲变，前后对比以它为准。两端同一份探针与键名（`Probes.swift`）。
/// - **掉帧**：动作后 800ms 内窗口 display link 相邻两次回调间隔超过 1.5 帧的次数与最长一次（毫秒）。
/// - **到对话出现**（`contentMs`，只有"Cue 页首访"）：动作发出到 Cue 页的对话排出来的墙钟毫秒（`PerfProbe` 的 `cue`）；第一次变的画面可能还是空的页。
/// 开头把本实例调到前台：后台量的数字偏乐观（前台才有玻璃等实际合成），所以会抢一下焦点，量完退出。
enum InteractionBench {
    /// 每项的预算：点击回合上限（毫秒）与掉帧次数上限。预算是目标，不是现状：没达到的项如实报超预算，不改数字迁就。
    /// 依据：144Hz 一帧 6.9ms；对点击的回应在两帧（14ms）内人感觉是"跟手"，要建内容的在四帧（28ms）内不觉得顿；掉帧最多两次。
    /// 回访页面、收起、关闭只是换可见性，对点击要跟手；首访、打开要建视图，给四帧。
    /// 会话页单独给 90ms（人对 100ms 内的回应感知为即时）：它的第一帧必须带标题与最新的对话，晚一帧出内容的空白闪动比慢一点更差，
    /// 而页面壳加最新对话的构建本身就在 45～70ms（工具栏与回复框等次要部分已挪到后面的帧，见 `SessionPage`）。
    private static let budgets: [String: (clickMs: Double, hitches: Int)] = [
        "页面回访": (14, 1),
        "页面首访": (28, 2),
        "Agent 页首访": (28, 2),
        "会话页": (90, 2),
        "Cue 页首访": (90, 2),
        "开编辑页": (28, 2),
        "收编辑页": (14, 2),
        "任务面板开": (28, 2),
        "任务面板关": (14, 2),
        "⌘K 面板开": (28, 2),
        "⌘K 面板关": (14, 2),
        "侧栏收起": (28, 2),
        "侧栏展开": (28, 2),
        "展开任务": (28, 2),
        "收起任务": (14, 2),
        "发送·会话页": (14, 1),
        "发送·Cue 页": (14, 1),
    ]

    private static let turns = TurnLog()

    static func run(_ workspace: Workspace) async {
        if PerfProbe.firstSeen["content"] == nil { await PerfProbe.wait(for: "content") }
        if UserDefaults.standard.bool(forKey: "CuePadDemo") { await DebugScene.seedRemote(workspace.services) }
        // `-CuePadInteractOnly 会话页,开编辑页`：只量这几项，前后对比时省下整套流程（列的项之间要自己够得着，如开编辑页配收编辑页）
        // Cue 页的对话在等之前写好（库里没有时）：用户点开 Cue 页时对话早在库里，空闲时先挂上的那一页（`Prewarm`）也已读到它
        let only = UserDefaults.standard.string(forKey: "CuePadInteractOnly").map { Set($0.split(separator: ",").map(String.init)) }
        let measuresCue = only.map { $0.contains("Cue 页首访") || $0.contains("发送·Cue 页") } ?? true
        if measuresCue { await DebugScene.seedCue(workspace.services) }
        try? await Task.sleep(for: .seconds(3))
        guard let window = NSApp.windows.first(where: { $0.styleMask.contains(.fullSizeContentView) && $0.styleMask.contains(.resizable) }),
              let view = window.contentView
        else { return }
        // 前台才有玻璃等实际合成，后台量的数字偏乐观；给了 CUEPAD_SHOT_READY 时留在后台（不抢用户的前台，指令数仍可前后对比）
        if !DebugHooks.staysInBackground {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        try? await Task.sleep(for: .seconds(1))
        let store = workspace.services.store
        let projects = (workspace.catalog?.projects ?? []).map(\.id)
        let sessions = ((try? await store.piSessionPage(PiSessionQuery(limit: 3)))?.items ?? []).map(\.state.sessionID)
        func step(_ name: String, _ action: () -> Void) async {
            if let only, !only.contains(name) { return }
            let row = await measure(name, in: view, action)
            print("INTERACT " + String(decoding: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]), as: UTF8.self))
            fflush(stdout)
        }
        let a = projects.indices.contains(1) ? projects[1] : nil, b = projects.indices.contains(2) ? projects[2] : nil
        // 页面：第一次去是首访，之后来回是回访
        if let a { await step("页面首访") { workspace.show(.project(a)) } }
        if let b { await step("页面首访") { workspace.show(.project(b)) } }
        if let a, let b {
            for _ in 0..<2 {
                await step("页面回访") { workspace.show(.project(a)) }
                await step("页面回访") { workspace.show(.project(b)) }
            }
        }
        await step("Agent 页首访") { workspace.show(.agent) }
        if let a { await step("页面回访") { workspace.show(.project(a)) } }
        await step("页面回访") { workspace.show(.agent) }
        for id in sessions.prefix(2) { await step("会话页") { workspace.show(.session(id)) } }
        // 发送：回复框里写好几行再按 ⌘↩（主菜单"回复"的项经响应链交给文字区，这里直接交给它），量输入框收起、话贴到对话末尾、滚到最新那一下。
        // 大库在最长的那段对话里发，演示库在最近的会话里发；Cue 页先写好一段对话（库里没有时）
        let longest = try? await store.piSessionPage(PiSessionQuery(id: PiSessionState.recordID(sessionID: PerfLibrary.longestChat))).items.first
        if let id = longest?.state.sessionID ?? sessions.first, only.map({ $0.contains("发送·会话页") }) ?? true {
            workspace.show(.session(id))
            for _ in 0..<2 {
                workspace.services.settings.setReplyDraft(ComposerDraft(text: sample), for: PiSessionState.recordID(sessionID: id))
                await step("发送·会话页") { sendShortcut(in: window, field: "回复") }
            }
        }
        if measuresCue {
            await step("Cue 页首访") { workspace.show(.cue) }
            workspace.show(.cue)
            for _ in 0..<2 {
                workspace.cue.draft = ComposerDraft(text: sample)
                await step("发送·Cue 页") { sendShortcut(in: window, field: "对 ") }
            }
        }
        if let a { await step("页面回访") { workspace.show(.project(a)) } }
        if let card = try? await store.cards(in: workspace.currentProject).first?.id {
            for _ in 0..<2 {
                await step("开编辑页") { workspace.openCard = card }
                await step("收编辑页") { workspace.openCard = nil }
            }
        }
        for _ in 0..<2 {
            await step("任务面板开") { workspace.showsTasks = true }
            await step("任务面板关") { workspace.showsTasks = false }
            await step("⌘K 面板开") { workspace.searching = true }
            await step("⌘K 面板关") { workspace.searching = false }
        }
        // 项目页任务纸点"还有 N 条"展开、再收起：在没做完的任务最多的项目上（配 `-CuePadManyTasks` 量任务多时）
        if only.map({ $0.contains("展开任务") || $0.contains("收起任务") }) ?? true,
           let busiest = workspace.catalog?.openTasks.filter({ $0.key != nil }).max(by: { $0.value < $1.value })?.key {
            workspace.show(.project(busiest))
            try? await Task.sleep(for: .seconds(2))
            for _ in 0..<2 {
                await step("展开任务") { DebugScene.toggleTaskFold() }
                await step("收起任务") { DebugScene.toggleTaskFold() }
            }
        }
        // 侧栏开合在卡最多的项目页上量：整页内容要跟着详情区的宽度重排。走 ⌃⌘S 那条路（主菜单动作经响应链），不直接调方法
        if let big = workspace.catalog?.cardCounts.filter({ $0.key != nil }).max(by: { $0.value < $1.value })?.key {
            await step("页面回访") { workspace.show(.project(big)) }
            for _ in 0..<2 {
                await step("侧栏收起") { NSApp.sendAction(#selector(AppDelegate.toggleCueSidebar(_:)), to: nil, from: nil) }
                await step("侧栏展开") { NSApp.sendAction(#selector(AppDelegate.toggleCueSidebar(_:)), to: nil, from: nil) }
            }
        }
        NSApp.terminate(nil)
    }

    /// 发送时回复框里的话：三行，发出后输入框收回一行。
    private static let sample = "把重连的用例补上，跑一遍全量测试\n失败的贴给我看，别自己改断言\n做完把覆盖率报一下"

    /// ⌘↩：回复框聚焦时主菜单"回复"的发送项交到文字区（`GrowingTextView.performReplyShortcut`）。按读屏标签的开头挑文字区（离开的页面还挂着）。
    private static func sendShortcut(in window: NSWindow, field label: String) {
        guard let field = textViews(in: window.contentView).first(where: { $0.accessibilityLabel()?.hasPrefix(label) == true }) else { return }
        let item = NSMenuItem()
        item.tag = ReplyShortcut.send.rawValue
        field.performReplyShortcut(item)
    }

    private static func textViews(in view: NSView?) -> [GrowingTextView] {
        guard let view else { return [] }
        if let field = view as? GrowingTextView { return [field] }
        return view.subviews.flatMap(textViews)
    }

    private static func measure(_ name: String, in view: NSView, _ action: () -> Void) async -> [String: Any] {
        try? await Task.sleep(for: .milliseconds(900))
        let recorder = FrameRecorder()
        recorder.start(in: view)
        let instructions = instructionsMillions()
        turns.begin(CACurrentMediaTime(), root: view.window?.contentView?.superview?.layer ?? view.layer)
        action()
        try? await Task.sleep(for: .milliseconds(800))
        let began = turns.began
        var row = TurnLog.metrics(turns.finish(), instructions: instructions, frames: recorder.stop())
        if let shown = PerfProbe.lastSeen["cue"], shown >= began { row["contentMs"] = ((shown - began) * 10_000).rounded() / 10 }
        row["name"] = name
        row["budgetClickMs"] = budgets[name]?.clickMs ?? 0
        row["budgetHitches"] = budgets[name]?.hitches ?? 0
        return row
    }
}
#endif
