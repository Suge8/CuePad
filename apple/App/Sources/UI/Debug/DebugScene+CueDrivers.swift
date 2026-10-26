#if DEBUG
import CueStore
import CueText
import Foundation

extension DebugScene {
    /// `-CuePadWake <秒>`（配 `-CuePadDemo YES`，画面就绪后开始、一直循环）：每隔这么久 Cue 被在线会话叫醒一次——此刻的状态写成在想、
    /// 带上叫醒它的会话（这一轮的经过那一行上的 `CueMessage.wake`，同值班的 Mac 起一轮时写下的样子，对话里随之多一行），醒 1.5 秒后歇下；叫醒的会话从在线会话的前三个里轮着挑，
    /// 一次一个、一次两个交替（看几道光错开），两个的那次歇下前动手说一句（录 Cue 页那一行从在跑到做完）；给了 `-CuePadSession`（session 画面）时它排第一个，每次都有它。
    /// 录"叫醒"的动效用（`CueRelayStage`）；隔离库里 Cue 不值班，没有别人改它的状态。
    /// `-CuePadFlightLog <路径>`：每次叫醒（或交给，见 `relayIfAsked`）前歇着的 `probe` 秒与之后的 `probe` 秒各量一段，一段一行 JSON 追加到这个文件：
    /// 主线程 display link 的全部间隔、总帧数、超 16ms 的帧与掉帧（超过刷新间隔 1.5 倍）、每圈 run loop 的主线程 CPU、进程的指令数与能量（`TurnLog.metrics`、`energyMillijoules`）。
    /// 那一下的那段减去歇着那段是一次接力在 App 进程里的开销；配 `-CuePadReduceMotion YES` 再跑一遍当对照（库照样变、不飞），两者之差是飞的那一下。
    /// 不抢前台：窗口在后台、留在屏上（display link 照走）；动画本身在渲染服务里插值，渲染服务的开销不在这个进程里，量不到。

    static func wakeIfAsked(_ workspace: Workspace) async {
        let store = workspace.services.store
        var round = 0
        await everyIfAsked("CuePadWake") {
            // 演示会话的 sessionID 与会话名相同
            let opened = defaults.string(forKey: "CuePadSession")
            let live = Array(workspace.liveWork.filter { $0.state != .known(.ended) && $0.sessionID != opened }.prefix(3).map(\.sessionID))
            let count = round % 2 + 1
            var woke = (0..<min(count, live.count)).map { live[(round + $0) % live.count] }
            if let opened { woke = [opened] + woke.prefix(count - 1) }
            round += 1
            let wake = CueWake.sessionActivity(woke.map { CueStir(kind: .settled, session: $0) })
            guard !woke.isEmpty, let row = try? await store.recordCueRound(nil, startedAt: .now, answersYou: false, tools: nil, wake: wake),
                (try? await store.setCueState(.thinking, round: row)) != nil
            else { return nil }
            // 隔一次动手说一句再歇下（同真的一轮：醒来、动手、说话、歇下）
            let acts = round % 2 == 0
            return ("wake", {
                if acts {
                    var tools = PiChatMessage.Tools()
                    tools.record(.init(
                        kind: .talk, target: String(localized: "对 \(woke[0]) 说：测试跑完把结果贴过来", table: "Demo"), name: woke[0], session: PiSessionState.recordID(sessionID: woke[0])))
                    _ = try? await store.recordCueRound(row, startedAt: .now, answersYou: false, tools: tools)
                    _ = try? await store.addCueMessage(.note, text: String(localized: "催了 \(woke[0])：测试跑完把结果贴过来", table: "Demo"))
                }
                try? await store.setCueState(.settled)
            })
        }
    }

    /// `-CuePadReplyBlink <秒>`（配 `-CuePadDemo YES -CuePadScene cue`，画面就绪后开始、一直循环）：每隔这么久 Cue 把一个歇着的会话留给你回
    /// （同值班的 Mac 写下的样子，`leaveToYou`），1.5 秒后那个会话又跑起来、不再待回复，看 Cue 页的待回复提示（`CueReplyTip`）怎么进出。
    static func replyBlinkIfAsked(_ store: CueStore) async {
        let recorder = PiStateRecorder(store: store, hostID: "demo-mac")
        let title = String(localized: "底栏换系统液态玻璃", table: "Demo")
        func set(_ state: PiWorkState) async throws {
            _ = try await recorder.update(sessionID: "blink", state: state, title: title, directory: "CuePad", agent: .claudeCode)
        }
        await everyIfAsked("CuePadReplyBlink") {
            guard (try? await set(.settled)) != nil, (try? await store.leaveToYou("blink")) != nil else { return nil }
            return ("reply", { try? await set(.thinking) })
        }
    }

    /// `-CuePadNoAsks YES`（配 `-CuePadDemo YES`）：演示库里等你回答的会话都改成歇着、Cue 还没结束的提问都由它撤回（同 Cue 的 withdraw），
    /// "等你"为 0：看只有新消息时 Cue 入口上的样子（石绿点）。
    static func settleAsks(_ store: CueStore) async {
        for asked in (try? await store.cueMessagesWaitingForYou()) ?? [] { _ = try? await store.endCueQuestion(asked.id, .withdrawn) }
        for session in (try? await store.piSessionPage(PiSessionQuery(limit: 500)))?.items.map(\.state) ?? [] where session.state == .known(.waitingForUser) {
            _ = try? await PiStateRecorder(store: store, hostID: session.hostID).update(sessionID: session.sessionID, state: .settled, title: session.title)
        }
    }

    /// `-CuePadCueSays <秒>`（配 `-CuePadDemo YES`）：画面就绪后这么久 Cue 自己说一句（同值班的 Mac 做完一件事时写下的样子），
    /// 看你切到别的 App 或别的页时来了新话、回到 Cue 页的样子。之前的都先算读过，开始时没有新消息。
    /// `-CuePadVisitCue <秒>`：说完这么久去 Cue 页（`visit`），停够读到它再回原来那页（`back`），录"别处时有提示、读过就没了"。
    static func saysIfAsked(_ services: AppServices, visit: @MainActor () -> Void = {}, back: @MainActor () -> Void = {}) async {
        let delay = defaults.double(forKey: "CuePadCueSays")
        guard delay > 0 else { return }
        try? await services.store.markCueRead(through: .now)
        try? await Task.sleep(for: .seconds(delay))
        _ = try? await services.store.addCueMessage(.cue, text: String(localized: "圆桌的预发部署好了，5 人以上的房间发言顺序都对了。", table: "Demo"))
        let visitAfter = defaults.double(forKey: "CuePadVisitCue")
        guard visitAfter > 0 else { return }
        try? await Task.sleep(for: .seconds(visitAfter))
        visit()
        try? await Task.sleep(for: .seconds(3))
        back()
    }

    /// 你不在的一夜里 Cue 陆续说的几句（中间夹一条它自己醒来的动态）：之前的对话一段段挪早，最后一句是刚说的。
    /// `aged` 为 false 时不挪，都是此刻说的（连着 iCloud 的实例里挪早会挪进别的设备写过的对话中间）。
    static func seedAway(_ store: CueStore, aged: Bool = true) async throws {
        let hour: TimeInterval = 3600
        for (hours, author, text) in [
            (2.5, CueAuthor.cue, String(localized: "推上去了，CI 在跑正式环境的部署。", table: "Demo")),
            (1.5, .note, String(localized: "看了圆桌：正式环境部署完成，冒烟测试全过", table: "Demo")),
            (2, .cue, String(localized: "正式环境部署好了。5 人以上的房间我开了两个试过，发言顺序都对，重连后也保持首次加入的顺序。", table: "Demo")),
            (1, .cue, String(localized: """
                导入旧数据那个会话又出错了：模型拒绝了请求（prompt 太长）。我打算拆成按年份导：

                - 2019–2021 一批
                - 2022–2023 一批
                - 2024 至今一批

                每批单独开会话，等你点头再开工。
                """, table: "Demo")),
            (0.5, .cue, String(localized: "README 的深色截图也补上了，和浅色那张一起在任务里。", table: "Demo")),
            (0.25, .cue, String(localized: "今天的看板：圆桌做完了，导入旧数据等你定怎么拆，别的都在跑。", table: "Demo")),
        ] {
            if aged { try await store.seedAgeCueMessages(by: hours * hour) }
            _ = try await store.addCueMessage(author, text: text)
        }
    }

    static let goingAway = String(localized: "推吧。我去睡了，后面的你盯着，明早看", table: "Demo")

    /// `-CuePadAwayAfter <秒>`：就绪后这么久离开 Cue 页（`leave`），你说一句去睡了、Cue 接着说一夜的那几句，再回来（`back`）。
    /// 手机录"离开很久后回来"的定位；Mac 在两台设备同步读到哪时当写下新消息的那台（停在设置画面，不回来）。
    /// 不挪早：连着 iCloud 时挪早会挪进别的设备写过的对话中间；等这么久是先把 iCloud 里已有的拉完，之前的都在你这一句之前，不算新的。
    static func awayIfAsked(_ store: CueStore, leave: @MainActor () -> Void = {}, back: @MainActor () -> Void = {}) async {
        let delay = defaults.double(forKey: "CuePadAwayAfter")
        guard delay > 0 else { return }
        try? await Task.sleep(for: .seconds(delay))
        leave()
        _ = try? await store.addCueMessage(.you, text: goingAway)
        try? await seedAway(store, aged: false)
        try? await Task.sleep(for: .seconds(1.5))
        back()
    }

    /// `-CuePadRelay <秒>`（配 `-CuePadDemo YES`，画面就绪后开始、一直循环）：每隔这么久 Cue 交给会话一次——写一条 Cue 发起的投送请求
    /// （同 Cue 的 say 与 start 写下的样子，`CueFlight`），轮流两种：对一个在线会话说一句（给了 `-CuePadSession` 是它，否则在线会话的第一个），
    /// 给一件还没交出去的待办开新会话（带着那张卡；演示 Mac 0.8 秒后开出会话、写下带认领标识的记录，光这时飞到新会话那一行）；`-CuePadRelayKind say|start` 只做其中一种。
    /// 隔离库里没有执行器，请求停在待领取；1.5 秒后删掉，开出的会话结束。录"交给"的动效用（`CueRelayStage`），`-CuePadFlightLog` 同叫醒。
    static func relayIfAsked(_ workspace: Workspace) async {
        let store = workspace.services.store
        let kind = defaults.string(forKey: "CuePadRelayKind")
        let launcher = PiStateRecorder(store: store, hostID: "demo-mac")
        var round = 0
        await everyIfAsked("CuePadRelay") {
            let starts = kind.map { $0 == "start" } ?? !round.isMultiple(of: 2)
            round += 1
            if starts {
                guard let (request, session) = try? await relayStart(store, on: launcher) else { return nil }
                return ("start", {
                    try? await store.deleteDelivery(request.id)
                    try? await launcher.end(sessionID: session)
                })
            }
            guard let request = try? await relaySay(workspace) else { return nil }
            return ("say", { try? await store.deleteDelivery(request.id) })
        }
    }

    private static func relaySay(_ workspace: Workspace) async throws -> DeliveryRequest? {
        let rows = workspace.liveWork.filter { $0.state != .known(.ended) }
        guard let session = rows.first(where: { $0.sessionID == defaults.string(forKey: "CuePadSession") }) ?? rows.first else { return nil }
        return try await workspace.services.store.requestDelivery(
            String(localized: "看一下测试跑完没有，跑完把结果贴给我", table: "Demo"), to: SendTarget(kind: .piSession, name: session.title, ref: session.sessionID), on: session.hostID, cue: true)
    }

    /// 给一件还没交出去、归在项目里的待办叶子开新会话（Cue 发起，带着那张卡），演示 Mac 过一会儿开出它；返回请求与开出的会话 id。
    private static func relayStart(_ store: CueStore, on launcher: PiStateRecorder) async throws -> (DeliveryRequest, String)? {
        let tasks = try await store.tasks(.todo).flatMap(\.tasks)
        let parents = Set(tasks.compactMap(\.parentID))
        guard let task = tasks.first(where: { $0.piSessionID == nil && !parents.contains($0.id) }) else { return nil }
        let token = UUID().uuidString
        let request = try await store.requestLaunch(
            PiLaunch(project: task.projectID, prompt: task.body, token: token), title: task.heading, on: "demo-mac", card: task.id, cue: true)
        // 演示节奏：Mac 开出会话要一会儿
        try await Task.sleep(for: .seconds(0.8))
        let session = "launched-\(token.prefix(8))"
        try await launcher.update(sessionID: session, state: .thinking, title: task.heading, directory: "demo", projectID: task.projectID, launchToken: token)
        return (request, session)
    }

    /// `key` 给了秒数时每隔这么久做一次 `act`（返回量的那段叫什么与 1.5 秒后怎么收回；做不成返回 nil，跳过这一次），配 `-CuePadFlightLog` 前后各量一段。
    private static func everyIfAsked(_ key: String, _ act: () async -> (kind: String, undo: () async -> Void)?) async {
        let every = defaults.double(forKey: key)
        guard every > 0 else { return }
        let log = defaults.string(forKey: "CuePadFlightLog").map { URL(fileURLWithPath: $0) }
        let probe = log == nil ? 0 : flightProbe
        while !Task.isCancelled {
            // 间隔是演示节奏，不是在等别的事
            try? await Task.sleep(for: .seconds(max(every - probe, 0)))
            if let log { await measureFlight("idle", seconds: probe, into: log) }
            guard let done = await act() else { continue }
            if let log { await measureFlight(done.kind, seconds: probe, into: log) }
            try? await Task.sleep(for: .seconds(max(1.5 - probe, 0)))
            await done.undo()
        }
    }

    #if os(macOS)
    /// `-CuePadClosed <秒>`（仅 Mac）：画面就绪后这么久关上主窗口（同点关闭钮：内容摘下，`MainShellWindow`），配 `-CuePadFlightLog` 量关着窗时
    /// 一次叫醒的开销；`-CuePadReopen <秒>`：关上这么久后再打开（真的显示，会到前台），关着的这段中途把 Cue 此刻的状态写成用工具
    /// "读看板 · 关窗时写下"，看重新打开的第一眼是不是关窗期间变过的样子。
    static func closeIfAsked(_ workspace: Workspace) async {
        let after = defaults.double(forKey: "CuePadClosed")
        guard after > 0, let shell = workspace.services.windowShell else { return }
        try? await Task.sleep(for: .seconds(after))
        shell.hide()
        let reopen = defaults.double(forKey: "CuePadReopen")
        guard reopen > 0 else { return }
        try? await Task.sleep(for: .seconds(reopen / 2))
        try? await workspace.services.store.setCueState(.tool, detail: String(localized: "读看板 · 关窗时写下", table: "Demo"))
        try? await Task.sleep(for: .seconds(reopen / 2))
        shell.show()
    }
    #endif

    /// `-CuePadCueCycle YES`：就绪后 Cue 此刻每 2.6 秒换成下一份样例（`CueNowSamples.tour`），页头、侧栏与实时活动的调试画面同一份一起变，录切换的动效。
    static func cueNowTourIfAsked(_ cue: CueWatch) async {
        guard defaults.bool(forKey: "CuePadCueCycle") else { return }
        for index in 0... {
            cue.pin(CueNowSamples.tour[index % CueNowSamples.tour.count])
            guard (try? await Task.sleep(for: .seconds(2.6))) != nil else { return }
        }
    }
}
#endif
