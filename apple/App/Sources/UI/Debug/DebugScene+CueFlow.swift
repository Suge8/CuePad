#if DEBUG
import CueStore
import Foundation

/// `-CuePadCueFlow YES`（配 `-CuePadScene cue -CuePadDemo YES`，iOS 与 Mac）：画面就绪后按固定节奏（`FlowBeat`，约 17 秒；给了记录文件再多量 4 秒）走一遍完整的一轮，
/// 录 Cue 页各处流转的动效用。每一步走真用户与值班的 Mac 走的那条路，写的都是同一份库：
/// 1. 往输入框逐字写一句，按它的发送钮（`pressSendIfAsked` 交来的就是点按发送钮做的事：飞光、话在路上；说的话按同步一直通着算，`alwaysReachable`），过一会儿记下送达；
/// 2. Cue 在想，再用工具（建任务、开工两步进展，同值班的管理器写下的经过与此刻的状态）；
/// 3. Cue 回复：直接落库。逐字长出的正在说的话（`CueKeeper.speech`）只在 Cue 于这台 Mac 值班时有，演示库里 Cue 运行在演示 Mac 上；
///    让它在这台值班就会真起大脑，管理器每次对账还把此刻的状态写回它自己的（歇着、起不来），盖掉这里写的在想与用工具，所以不喂；
/// 4. 第 2 步建的任务交来一张截图后做完、点名这张（结果卡，同演示库的 `seedEvidence` 加 `finishTask`），再来一条"等你"，停 2 秒替你选"可以"（同点卡上的选项）；
///    演示库原有的那条"等你"写入时就答掉（`seedCue`），这张卡是"等你"里唯一的一张，出现与消失都看得到；
/// 5. 切页：Mac 侧栏点"任务"再点 Cue；iPhone 点底部那一排去任务再点 Cue 回来，iPad 侧栏点"任务"再点 Cue。
/// `-CuePadCueFlowLog <路径>`：同 `measureFlight` 的量法，量"发送"（send：从按下起）与"静止"（idle：走完之后 Cue 歇着、页面不动）各一段，一段一行 JSON 追加进这个文件。
/// 静止放在最后量：刚就绪的几秒里进程还在后台忙（iOS 模拟器上 4 秒能有上百亿条指令，主线程却几乎不动），量不出页面歇着的样子。
extension DebugScene {
    /// 演示节奏（秒）：节奏本身就是要录的内容，不是在等别的事。
    private enum FlowBeat {
        /// 开头空着的一段：Mac 录屏在就绪后才起录
        static let lead = 2.0
        /// 量的一段（发送、静止同长）
        static let probe = 4.0
        static let keystroke = 0.05
        static let beforeSend = 0.6
        static let inTransit = 1.5
        static let thinking = 1.5
        static let toolStep = 1.0
        static let reply = 1.2
        static let result = 1.5
        /// "等你"停着的时长
        static let asking = 2.0
        static let answered = 1.2
        static let away = 1.5
        static let back = 1.5
    }

    private static let flowSaid = String(localized: "顺便看看登录回调那个超时，是不是和重试间隔有关", table: "Demo")
    private static let flowSession = "cueflow"

    #if os(iOS)
    static func cueFlowIfAsked(_ workspace: Workspace) async {
        await runCueFlow(workspace) { away in
            workspace.select(away ? .progress : .cue)
        }
    }
    #else
    static func cueFlowIfAsked(_ workspace: Workspace) async {
        await runCueFlow(workspace) { away in workspace.show(away ? .progress : .cue) }
    }
    #endif

    private static func runCueFlow(_ workspace: Workspace, leave: (_ away: Bool) -> Void) async {
        guard defaults.bool(forKey: "CuePadCueFlow") else { return }
        do {
            try await cueFlow(workspace, leave: leave)
        } catch {
            print("cueflow: \(error)")
        }
    }

    private static func cueFlow(_ workspace: Workspace, leave: (_ away: Bool) -> Void) async throws {
        let store = workspace.services.store
        try await beat(FlowBeat.lead)

        for count in 1...flowSaid.count {
            workspace.cue.draft.text = String(flowSaid.prefix(count))
            try await beat(FlowBeat.keystroke)
        }
        try await beat(FlowBeat.beforeSend)
        guard let press = flowPress else { return print("cueflow: Cue 页的输入框不在") }
        flowPress = nil
        flowPressed = true
        // 量在这里而不在输入框的任务里：手机上发出后输入框的任务会被取消，量到一半就断了
        let sending = Task {
            guard let log = cueFlowLog else { return press.resume() }
            await measureFlight("send", seconds: FlowBeat.probe, into: log) { press.resume() }
        }
        try await beat(FlowBeat.inTransit)
        guard let said = try await store.cueMessages(limit: 5).last(where: { $0.author == .known(.you) && $0.text == flowSaid }) else {
            return print("cueflow: 那一句没有写进库")
        }
        let startedAt = Date.now
        try await store.markCueMessagesDelivered([said.id], at: startedAt)

        let context = try await store.cueState()?.context
        try await store.setCueState(.thinking, context: context)
        try await beat(FlowBeat.thinking)
        // 同值班的管理器（`CueKeeper.handle`）：调用开始时写此刻碰到的那一处（`CueState.step`），做完一步整份经过写回那一行
        let roundtable = try await store.projects().first { $0.name == String(localized: "圆桌", table: "Demo") }?.id
        let name = String(localized: "登录回调超时", table: "Demo")
        var tools = PiChatMessage.Tools()
        tools.record(.init(kind: .read, target: String(localized: "看板", table: "Demo")))
        let row = try await store.recordCueRound(nil, startedAt: startedAt, answersYou: true, tools: tools)
        try await store.setCueState(.tool, step: .init(kind: .add, name: name), round: row, context: context)
        try await beat(FlowBeat.toolStep)
        let task = try await store.createTask(name, in: roundtable ?? Project.defaultID)
        tools.record(.init(kind: .add, target: String(localized: "建任务「登录回调超时」", table: "Demo"), task: task.id, name: name))
        _ = try await store.recordCueRound(row, startedAt: startedAt, answersYou: true, tools: tools)
        try await store.setCueState(.tool, step: .init(kind: .start, name: name, task: task.id), round: row, context: context)
        try await beat(FlowBeat.toolStep)
        try await store.linkCard(task.id, toSession: flowSession)
        tools.record(.init(kind: .start, target: String(localized: "开工「登录回调超时」", table: "Demo"), task: task.id, name: name))
        _ = try await store.recordCueRound(row, startedAt: startedAt, answersYou: true, tools: tools)
        try await store.setCueState(.thinking, round: row, context: context)
        try await beat(FlowBeat.toolStep)

        _ = try await store.addCueMessage(.cue, text: String(localized: "复现了：回调里等 token 刷新时没设超时，网络慢时会一直挂着。改成 10 秒超时、超时后回登录页重新授权，测试在跑。", table: "Demo"), task: task.id)
        try await store.setCueState(.settled, context: context)
        try await beat(FlowBeat.reply)

        let evidence = await seedEvidence(store, session: flowSession, title: String(localized: "登录页（超时后）", table: "Demo"), png: loginTimeoutPNG())
        _ = try await store.finishTask(
            task.id, evidence: [String(localized: "等授权超过 10 秒就回到登录页，说明了原因", table: "Demo"), String(localized: "超时用例 3 个都过了", table: "Demo")],
            shots: evidence.map { [CueShot(preview: $0.id, look: String(localized: "超时后回到登录页", table: "Demo"))] } ?? [])
        try await beat(FlowBeat.result)
        let asked = try await store.addCueMessage(.cue, text: String(localized: "登录回调的修复验过了，要**推送到 origin/main** 吗？", table: "Demo"), ask: try CueAsking(.push, action: String(localized: "把登录回调的超时修复推送到 origin/main", table: "Demo")), task: task.id)
        try await beat(FlowBeat.asking)
        try await workspace.services.answerCueQuestion(asked.id, CueAsk.once)
        try await beat(FlowBeat.answered)

        leave(true)
        try await beat(FlowBeat.away)
        leave(false)
        try await beat(FlowBeat.back)
        await sending.value
        if let log = cueFlowLog { await measureFlight("idle", seconds: FlowBeat.probe, into: log) }
    }

    private static var cueFlowLog: URL? { defaults.string(forKey: "CuePadCueFlowLog").map { URL(fileURLWithPath: $0) } }

    private static func beat(_ seconds: Double) async throws { try await Task.sleep(for: .seconds(seconds)) }

    /// Cue 页输入框交来的按发送钮（点按做的事只在按下的那一刻借得到）：流程到第 1 步时放行。
    private static var flowPress: CheckedContinuation<Void, Never>?
    /// 已经按过：之后又出现的输入框（iPhone 切回来）不再等。
    private static var flowPressed = false

    /// 在 `pressSendIfAsked` 里等流程放行，按下。
    static func pressForCueFlow(_ press: () -> Void) async {
        guard !flowPressed, flowPress == nil else { return }
        await withCheckedContinuation { flowPress = $0 }
        press()
    }

    static var cueFlows: Bool { defaults.bool(forKey: "CuePadCueFlow") }
}
#endif
