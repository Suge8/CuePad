#if DEBUG
import CueStore
import CueText
import SwiftUI

/// 演示库里的 Cue（`-CuePadScene cue`、`cuememory`，配 `-CuePadDemo YES`）：在演示 Mac 上值班，管着圆桌的"乱序"（步骤在 Agent 会话里跑，
/// 部署那一步发来一张截图、在等你允许推送）与 CuePad 的"导入旧数据"（会话出错）；"README 截图换成 Swift 版"Cue 确认做完了（结果带证据与截图）。
/// 对话里有你的话（一句带图）、Cue 的话、折起的动态、一次换新（交接备忘）、一条结果与一条"等你"（正文带一段测试输出）；atlas 会话里有一句 Cue 发的话；
/// 记忆有钉住的与其他，还有一条忘掉的；上下文用到换新线的七成（`CueContext`）。cuerun（仅 Mac）让 Cue 运行在这台 Mac，"运行情况"才有。
/// `-CuePadCuePresence <answered|thinking|tool|sending|asleep|disabled>`：answered 是"等你"那一条你选了"可以"（回到对话里、带着你的回答），
/// 之后你又说了一句、Cue 跑了一轮（经过那一行）、连着回了两句（看问询回到对话里的样子、一串气泡；配 `-showsCueSteps YES` 看工具步骤那一行）；你的最后一句已交给 Cue（气泡旁的纸飞机）、它在想（thinking）或在用工具（tool：看会话进展）、
/// 刚说的还没交出去（sending：话在路上，时限内气泡转圈）、
/// 演示 Mac 不在线、两分钟前说的一直没交出去（asleep：它在睡觉，气泡过了等回执的时限 `Speech.receiptLimit`、没能送达可重发；
/// 隔离库没有同步，要配 `-CuePadDemoMac YES` 才算同步通着、说它在睡觉）、
/// 没启用；away 是你答了"等你"、说了句去睡了，一夜里 Cue 陆续说了几句（Cue 页的新消息，`CueViewing`）。演示 Mac 不值班，在线记录与此刻在做什么直接写进库（`CueStore.recordMacPresence`、`setCueState`；在线管一个期限 `MacPresence.lifetime`）。
extension DebugScene {
    /// 演示记忆：长短不一（一句话到接近一条的上限）、钉住的与其他、你记的与 Cue 记的，时间从刚刚到几个月前。
    private static var demoMemory: [SeedCueLine] {
        let hour: TimeInterval = 3600, day = 24 * hour
        func ago(_ seconds: TimeInterval) -> Date { .now.addingTimeInterval(-seconds) }
        return [
            SeedCueLine("回复要短，先说结论", source: .you, pinned: true, createdAt: ago(80 * day)),
            SeedCueLine("部署前先在测试群说一声，等有人回了再推；周五下午之后不发版，紧急修复除外", source: .you, pinned: true, createdAt: ago(40 * day)),
            SeedCueLine("提交信息用中文，一个提交只做一件事", source: .you, pinned: true, createdAt: ago(9 * day)),
            SeedCueLine(
                "改界面之前先拍改前截图，深浅色各一张；做完拍改后的放在一起比，交给我看的时候发到手机上，不要只贴本机路径",
                source: .cue, pinned: true, createdAt: ago(2 * day)),
            SeedCueLine("圆桌的预发环境是 staging-2，正式环境要过 CI 才部署", source: .cue, createdAt: ago(60 * day)),
            SeedCueLine("用户住在上海，晚上十一点以后别叫醒", source: .cue, createdAt: ago(33 * day)),
            SeedCueLine("CuePad 的发布只在干净检出里跑 release，对外发布要先问", source: .cue, createdAt: ago(21 * day)),
            SeedCueLine("喜欢先看原型截图再定方案", source: .cue, createdAt: ago(12 * day)),
            SeedCueLine(
                "登录回调的超时问题：等 token 刷新时没设超时，网络慢会一直挂着；改成 10 秒超时、超时后回登录页重新授权",
                source: .cue, createdAt: ago(6 * day)),
            SeedCueLine("atlas 会话用 Claude，别的用默认模型", source: .you, createdAt: ago(4 * day)),
            SeedCueLine("周会是每周一上午十点", source: .cue, createdAt: ago(3 * day)),
            SeedCueLine("乱序的根因在重连时重新入队，修复要保留首次加入的时间", source: .cue, createdAt: ago(day + 2 * hour)),
            SeedCueLine("README 的截图换成 Swift 版", source: .you, createdAt: ago(20 * hour)),
            SeedCueLine("导入旧数据会话上回卡在 schema 迁移，再开工前先看它的报错", source: .cue, createdAt: ago(5 * hour)),
            SeedCueLine("测试只用替身，不向别的应用发键鼠事件", source: .cue, createdAt: ago(40 * 60)),
            SeedCueLine("今天先把圆桌发了", source: .you, createdAt: ago(3 * 60)),
        ]
    }

    static func seedCue(_ services: AppServices) async {
        let store = services.store
        guard (try? await store.cueMessages(limit: 1).isEmpty) == true else { return }
        let presence = defaults.string(forKey: "CuePadCuePresence")
        // "运行情况"只在 Cue 值班的这台 Mac 上有：cuerun 让它运行在这台（大脑在隔离目录里起不来，几轮是空的或出错）
        #if os(macOS)
        let host = scene == "cuerun" ? services.hostID : "demo-mac"
        #else
        let host = "demo-mac"
        #endif
        do {
            _ = try await store.updateCueProfile { profile in
                profile.hostID = host
                profile.enabledAt = presence == "disabled" ? nil : .now
            }
            if presence != "asleep" { try await store.recordMacPresence(host: host) { true } }
            let tasks = try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks)
            func task(_ prefix: String) -> Card? { tasks.first { $0.parentID == nil && $0.body.hasPrefix(prefix) } }
            let order = task("发言轮次"), importing = task("导入旧数据"), panel = task("README 截图")
            if let importing { try await store.linkCard(importing.id, toSession: "billing") }
            // 截图是 notes 会话做的（歇着）：Cue 值班，侧栏与会话列表里它只说"歇着"
            if let panel { try await store.linkCard(panel.id, toSession: "notes") }
            await seedEvidence(store, session: "notes", title: "README 截图（浅色）")
            // Cue 发进 atlas 会话的一句（还在路上）：会话页的气泡上标着 Cue
            _ = try await store.requestDelivery(
                "排序改完后把 scheduler 的测试全跑一遍，结果贴给我", to: SendTarget(kind: .piSession, name: "atlas", ref: "atlas"), on: "demo-mac", cue: true)

            func you(_ text: String) async throws {
                let message = try await store.addCueMessage(.you, text: text)
                try await store.markCueMessagesDelivered([message.id])
            }
            // 记忆先写：提醒到点的那一轮指着其中一条
            try await store.seed(cueLines: demoMemory)
            if defaults.bool(forKey: "CuePadLongChat") { try await seedLongCueChat(you: you, store: store) }
            try await you("圆桌那个 5 人以上乱序的 bug 交给你，修好之后部署到预发")
            // 每一轮的经过（同值班的管理器写下的样子，`CueRound.process`）：排在这一轮开始的位置，动到的任务带着 id，清单里点它打开
            func step(_ kind: PiChatMessage.Tools.Kind, _ target: String, _ task: Card? = nil) -> PiChatMessage.Tools.Item {
                .init(kind: kind, target: target, task: task?.id)
            }
            func process(_ items: PiChatMessage.Tools.Item...) -> PiChatMessage.Tools {
                var tools = PiChatMessage.Tools()
                for item in items { tools.record(item) }
                return tools
            }
            try await store.recordCueRound(nil, startedAt: .now, answersYou: true, tools: process(
                step(.read, "看板"), step(.add, "建任务「发言轮次乱序」", order), step(.other, "改「发言轮次乱序」", order), step(.start, "开工「发言轮次乱序」", order),
                step(.talk, "对「发言轮次乱序」说：先复现 5 人以上的乱序，再改成按首次加入时间排序", order)))
            _ = try await store.addCueMessage(
                .cue, text: "好。拆成四步：复现、改成按首次加入时间排序、补 3 个重连用例、部署到预发。第一步已经复现了，现在在改排序。", task: order?.id)
            // Cue 自己醒来的几轮（同值班的管理器醒来时写下的经过那一行，带着为什么醒）：会话停下、出错、提醒到点，两次只看了看；
            // 连着六轮，Cue 页里折起前面的、两次只看了看的并成一行
            func stirred(_ kind: CueChange.Kind, _ session: String) -> CueWake { .sessionActivity([CueStir(kind: kind, session: session)]) }
            let meeting = try await store.cueMemory().lines.first { $0.text.hasPrefix("周会") }
            for (wake, note, tools) in [
                (stirred(.settled, "atlas"), "看了圆桌：复现乱序完成，原因是重连的人拿到了新的加入时间", process(step(.read, "看「发言轮次乱序」的近况", order))),
                (stirred(.settled, "atlas"), "让 atlas 改成按首次加入时间排序，正在跑 scheduler 的测试", process(
                    step(.read, "看「发言轮次乱序」的近况", order), step(.talk, "对「发言轮次乱序」说：按首次加入时间排序，改完把 scheduler 的测试全跑一遍", order))),
                (stirred(.failed, "billing"), "CuePad 导入旧数据的会话出错了：模型拒绝了请求（prompt 太长），等你回来再说", process(
                    step(.read, "看板"), step(.read, "看「导入旧数据」的近况", importing), step(.search, "导入旧数据 prompt 太长"))),
                (CueWake.reminder(meeting.map { [$0.id] } ?? []), "", process(
                    step(.read, "看「README 截图」的近况", panel), step(.talk, "对「README 截图」说：深色那张也按参考图拍，拍完发给我", panel),
                    step(.other, "记下：README 截图要浅色深色各一张"))),
                (stirred(.settled, "notes"), "", process(step(.read, "看「README 截图」的近况", panel))),
                (.idle, "", process(step(.read, "看板"))),
            ] {
                try await store.recordCueRound(nil, startedAt: .now, answersYou: false, tools: tools, wake: wake)
                if !note.isEmpty { _ = try await store.addCueMessage(.note, text: note) }
            }
            // 上下文到了换新线：写下交接，从这里起换了新上下文（对话里一条分隔，点开是这份备忘）
            _ = try await store.addCueMessage(.handoff, text: """
                **在做**
                - 圆桌「5 人以上乱序」：已复现，原因是重连拿到新的加入时间；atlas 正在改成按首次加入时间排序，测试在跑。
                - CuePad「导入旧数据」：会话出错（prompt 太长），等他回来再定怎么拆。

                **下一步**
                - atlas 测试过了就派「补 3 个重连用例」，然后部署到预发、截图给他看。

                **和他之间没了结的**
                - 推送到 origin/main 要先问他（会触发正式环境部署）。
                """)
            try await seedDeliveries(store)
            let shot = CueFormat.imageMarkup(id: try store.files.store(swatchPNG()))
            try await you("README 的截图也交给你，换成 Swift 版的样子，参考这张\n" + shot)
            // Cue 确认做完了：结果的正文与 Cue 的 done 同一个拼法（`CueReport.text`）
            if let panel { _ = try await store.finishTask(panel.id, evidence: ["浅色深色各一张，都按你给的参考图", "README 里的旧截图都换掉了"]) }
            let asked = try await store.addCueMessage(
                .cue, text: """
                    预发上验过了，截图在这里。重连用例都过了：

                    ```
                    $ swift test --filter Reconnect
                    ✔ 重连后保留首次加入时间 (0.21s)
                    ✔ 6 人同时重连顺序不变 (0.48s)
                    ✔ 断线超过 5 分钟按新人排 (0.12s)
                    ✔ 主持人重连仍在第一位 (0.09s)
                    Executed 4 tests, with 0 failures
                    ```

                    要把改动**推送到 origin/main** 吗？推上去 CI 会自动部署到正式环境。
                    """, ask: try CueAsking(.push, action: "把发言顺序的修复推送到 origin/main"), shots: try await deployShots(store), task: order?.id)
            // 第二张"等你"（答完第一张接着露出来）：还有几条在等的演示
            if !cueFlows, let billing = task("清理旧的计费脚本") {
                _ = try await store.addCueMessage(
                    .cue, text: "旧的计费脚本目录 `scripts/billing-legacy` 已经没有调用方了，CI 里也不再跑。要删掉吗？",
                    ask: try CueAsking(.delete, action: "删掉 scripts/billing-legacy 目录"), task: billing.id)
            }
            if let variant = defaults.string(forKey: "CuePadCueAsk") { try await seedAsk(variant, store: store, task: order?.id) }
            let forgotten = try await store.noteCueLine("旧的计费脚本还在用", source: .cue)
            try await store.forgetCueLine(forgotten.line.id)
            // 这个班次两个半小时前起，用到换新线的七成（上下文用量那一块加深一档）
            let context = CueContext(used: 41_800, window: 200_000, since: .now.addingTimeInterval(-9_000))
            try await store.setCueState(.settled, context: context)
            // 流程演示里"等你"只有它自己出的那一条：演示的这条先答掉，看得到那张卡出现与消失（`DebugScene+CueFlow.swift`）
            if cueFlows { _ = try await store.endCueQuestion(asked.id, .answered(CueAsk.once)) }
            switch presence {
            case "answered":
                _ = try await store.endCueQuestion(asked.id, .answered(CueAsk.once))
                try await you("顺便看看登录回调那个超时")
                _ = try await store.recordCueRound(nil, startedAt: .now, answersYou: true, tools: process(
                    step(.read, "看板"), step(.add, "建任务「登录回调超时」"), step(.start, "开工「登录回调超时」"),
                    step(.talk, "对「登录回调超时」说：先复现回调等 token 刷新时一直挂着")))
                _ = try await store.addCueMessage(.cue, text: "好，我先让 auth 会话复现一下。")
                _ = try await store.addCueMessage(.cue, text: "复现了：回调里等 token 刷新时没设超时，网络慢时会一直挂着。改成 10 秒超时、超时后回登录页重新授权，测试在跑。")
            case "thinking":
                try await you("顺便看看登录回调那个超时")
                try await store.setCueState(.thinking, context: context)
            case "tool":
                try await you("顺便看看登录回调那个超时")
                let row = try await store.recordCueRound(nil, startedAt: .now, answersYou: true, tools: process(
                    step(.read, "看板"), step(.search, "登录回调 超时"), step(.add, "建任务「登录回调超时」"), step(.start, "开工「登录回调超时」")))
                try await store.setCueState(.tool, detail: "跟会话说话", round: row, context: context)
            case "sending":
                _ = try await store.addCueMessage(.you, text: "顺便看看登录回调那个超时")
            case "away":
                _ = try await store.endCueQuestion(asked.id, .answered(CueAsk.once))
                try await you(goingAway)
                try await seedAway(store)
            case "asleep":
                // 两分钟前说的、一直没交出去（之前的对话挪得更早）
                try await store.seedAgeCueMessages(by: 480)
                _ = try await store.addCueMessage(.you, text: "顺便看看登录回调那个超时")
                try await store.seedAgeCueMessages(by: 120)
            default: break
            }
        } catch {
            fatalError("Cue 演示数据没写成：\(error)")
        }
    }

    /// `-CuePadWake <秒>`（配 `-CuePadDemo YES`，画面就绪后开始、一直循环）：每隔这么久 Cue 被在线会话叫醒一次——此刻的状态写成在想、
    /// 带上叫醒它的会话（这一轮的经过那一行上的 `CueMessage.wake`，同值班的 Mac 起一轮时写下的样子，对话里随之多一节动态），醒 1.5 秒后歇下；叫醒的会话从在线会话的前三个里轮着挑，
    /// 一次一个、一次两个交替（看几道光错开）；给了 `-CuePadSession`（session 画面）时它排第一个，每次都有它。
    /// 录"叫醒"的动效用（`CueRelayStage`）；隔离库里 Cue 不值班，没有别人改它的状态。
    /// `-CuePadFlightLog <路径>`：每次叫醒（或交给，见 `relayIfAsked`）前歇着的 `probe` 秒与之后的 `probe` 秒各量一段，一段一行 JSON 追加到这个文件：
    /// 主线程每帧的 display link 间隔（掉帧、最长一帧）、每圈 run loop 的主线程 CPU、进程的指令数与能量（`TurnLog.metrics`、`energyMillijoules`）。
    /// 那一下的那段减去歇着那段是一次接力在 App 进程里的开销；配 `-CuePadReduceMotion YES` 再跑一遍当对照（库照样变、不飞），两者之差是飞的那一下。
    /// 不抢前台：窗口在后台、留在屏上（display link 照走）；动画本身在渲染服务里插值，渲染服务的开销不在这个进程里，量不到。
    /// 推送那条"等你"点名要看的两份：部署会话发来的预发截图与测试报告（`seedDeliveries`）。
    private static func deployShots(_ store: CueStore) async throws -> [CueShot] {
        let sent = try await store.previews(of: "deploy")
        return [("预发上的发言顺序", "预发上 6 人的发言顺序"), ("重连测试报告", "重连用例 4 个都过了")].compactMap { title, look in
            sent.first { $0.title == title }.map { CueShot(preview: $0.id, look: look) }
        }
    }

    static func wakeIfAsked(_ workspace: Workspace) async {
        let store = workspace.services.store
        var round = 0
        await everyIfAsked("CuePadWake") {
            // 演示会话的 sessionID 与会话名相同
            let opened = defaults.string(forKey: "CuePadSession")
            let live = Array(workspace.liveWork.rows.filter { $0.state != .known(.ended) && $0.sessionID != opened }.prefix(3).map(\.sessionID))
            let count = round % 2 + 1
            var woke = (0..<min(count, live.count)).map { live[(round + $0) % live.count] }
            if let opened { woke = [opened] + woke.prefix(count - 1) }
            round += 1
            let wake = CueWake.sessionActivity(woke.map { CueStir(kind: .settled, session: $0) })
            guard !woke.isEmpty, let row = try? await store.recordCueRound(nil, startedAt: .now, answersYou: false, tools: nil, wake: wake),
                (try? await store.setCueState(.thinking, round: row)) != nil
            else { return nil }
            return ("wake", { try? await store.setCueState(.settled) })
        }
    }

    /// `-CuePadNoAsks YES`（配 `-CuePadDemo YES`）：演示库里等你回答的会话都改成歇着、Cue 还没结束的提问都由它撤回（同 Cue 的 withdraw），
    /// "等你"为 0：看只有新消息时 Cue 入口上的样子（石绿点）。
    static func settleAsks(_ store: CueStore) async {
        for asked in (try? await store.cueMessagesWaitingForYou()) ?? [] { try? await store.endCueQuestion(asked.id, .withdrawn) }
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
        _ = try? await services.store.addCueMessage(.cue, text: "圆桌的预发部署好了，5 人以上的房间发言顺序都对了。")
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
            (2.5, CueAuthor.cue, "推上去了，CI 在跑正式环境的部署。"),
            (1.5, .note, "看了圆桌：正式环境部署完成，冒烟测试全过"),
            (2, .cue, "正式环境部署好了。5 人以上的房间我开了两个试过，发言顺序都对，重连后也保持首次加入的顺序。"),
            (1, .cue, """
                导入旧数据那个会话又出错了：模型拒绝了请求（prompt 太长）。我打算拆成按年份导：

                - 2019–2021 一批
                - 2022–2023 一批
                - 2024 至今一批

                每批单独开会话，等你点头再开工。
                """),
            (0.5, .cue, "README 的深色截图也补上了，和浅色那张一起在任务里。"),
            (0.25, .cue, "今天的看板：圆桌做完了，导入旧数据等你定怎么拆，别的都在跑。"),
        ] {
            if aged { try await store.seedAgeCueMessages(by: hours * hour) }
            _ = try await store.addCueMessage(author, text: text)
        }
    }

    private static let goingAway = "推吧。我去睡了，后面的你盯着，明早看"

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

    /// 对一个在线会话说一句（Cue 发起）。
    private static func relaySay(_ workspace: Workspace) async throws -> DeliveryRequest? {
        let rows = workspace.liveWork.rows.filter { $0.state != .known(.ended) }
        guard let session = rows.first(where: { $0.sessionID == defaults.string(forKey: "CuePadSession") }) ?? rows.first else { return nil }
        return try await workspace.services.store.requestDelivery(
            "看一下测试跑完没有，跑完把结果贴给我", to: SendTarget(kind: .piSession, name: session.title, ref: session.sessionID), on: session.hostID, cue: true)
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
        try? await workspace.services.store.setCueState(.tool, detail: "读看板 · 关窗时写下")
        try? await Task.sleep(for: .seconds(reopen / 2))
        shell.show()
    }
    #endif

    /// 量的一段比接力的那一下（约 1.3～1.4 秒）长一点。
    static let flightProbe = 1.6

    /// `act`：开始量之后当场做的那一下（按发送钮，`pressSendIfAsked`）。
    static func measureFlight(_ kind: String, seconds: Double, into log: URL, act: () -> Void = {}) async {
        let turns = TurnLog(), frames = FrameRecorder()
        let instructions = instructionsMillions(), energy = energyMillijoules()
        #if os(macOS)
        // 主窗口关着（`-CuePadClosed`）时没有可挂 display link 的窗口：只量指令、CPU 与能量
        if let view = NSApp.windows.first(where: \.isVisible)?.contentView { frames.start(in: view) }
        #else
        frames.start()
        #endif
        turns.begin(CACurrentMediaTime(), root: nil)
        act()
        try? await Task.sleep(for: .seconds(seconds))
        var line = TurnLog.metrics(turns.finish(), instructions: instructions, frames: frames.stop())
        line["kind"] = kind
        line["energyMJ"] = ((energyMillijoules() - energy) * 10).rounded() / 10
        for key in ["clickMs", "visibleTurns", "seen", "heavy"] { line[key] = nil }
        guard let data = try? JSONSerialization.data(withJSONObject: line, options: .sortedKeys) else { return }
        if let handle = try? FileHandle(forWritingTo: log) {
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        } else {
            try? (data + Data("\n".utf8)).write(to: log)
        }
    }

    /// `-CuePadLongChat YES`：演示对话前面多 110 轮更早的来回（比 Cue 页读得到的 `CueThread.limit` 条多：来一句新的，最早那条就掉出去，同真实库），中间换过三次新上下文（看 Cue 页往上翻、刻度滑条与换新的分隔）。
    /// Cue 的回答高矮悬殊：一句话与会话页长对话同一套长段落、40 行代码块、宽表、长列表轮换（`longChatReply`）；你每 25 轮贴进来一段长文，每 15 轮带一张图。
    /// 量 Cue 页的长对话滚动（`-CuePadBench chatscroll`）就用这一段。
    private static func seedLongCueChat(you: (String) async throws -> Void, store: CueStore) async throws {
        let asks = ["今天先看哪件？", "把计费那个会话的进展说一下", "圆桌的预发什么时候能好？", "帮我记一下：周五不发版", "README 截图换完了吗？", "重连用例加了几个？"]
        let replies = ["先看圆桌：乱序会影响所有 5 人以上的房间。", "计费会话卡在额度接口的签名上，我让它先把请求原文打出来。", "测试在跑，大概二十分钟后能部署到预发。",
                       "记下了，周五不发版。", "浅色那张换好了，深色的还在拍。", "加了 2 个，第 3 个等排序改完再补。"]
        let shot = CueFormat.imageMarkup(id: try store.files.store(swatchPNG()))
        for round in 0..<110 {
            if round % 30 == 12 {
                _ = try await store.addCueMessage(.handoff, text: "**在做**\n- 圆桌乱序：在改排序，测试在跑。\n\n**下一步**\n- 测试过了派重连用例，再部署预发。")
            }
            let ask = round % 25 == 0 ? longChatPrompt(round) : "第 \(round + 1) 句：" + asks[round % asks.count]
            try await you(round % 15 == 7 ? ask + "\n" + shot : ask)
            _ = try await store.addCueMessage(.cue, text: round % 3 == 0 ? replies[round % replies.count] : longChatReply(round))
        }
    }

    /// `-CuePadScene cuerows`（不配演示库）：Cue 在值班，五个会话——Pi、Codex、Claude Code 各一，标题长短都有，
    /// 停着的、在跑的、等回答的都有（Claude Code 那个是 CuePad 答得了的确认，等 Cue 回答；Codex 那个只是一句话，等你确认）；各绑一件任务。
    /// 停着的两个里 faq 是 Cue 留给你回的（"待回复"），README 那个归 Cue 接手（"歇着"），两相对照。上下文 50%（行上不写）、75%（加粗）、94%（胭脂）三档都有；
    /// 两个带模型（Agent 页卡片多一层读数），其余没有（卡片只有两层）。
    /// 看窄处名字优先、Agent 只留标志，状态标与第二层对齐，上下文落在时长下面。
    static func seedCueRows(_ services: AppServices) async {
        do { try await seedCueRows(services.store) } catch { print("cuerows: \(error)") }
    }

    private static func seedCueRows(_ store: CueStore) async throws {
        guard try await store.piSessionCount() == 0 else { return }
        _ = try await store.updateCueProfile { profile in
            profile.hostID = "demo-mac"
            profile.enabledAt = .now
        }
        try await store.recordMacPresence(host: "demo-mac") { true }
        let recorder = PiStateRecorder(store: store, hostID: "demo-mac")
        let asked = "加在「安装」后面吗？"
        let rows: [(id: String, title: String, agent: AgentKind, state: PiWorkState, detail: String?, question: PiQuestion?, tokens: Int, model: Bool)] = [
            ("cue-pi-long", "把 README 的截图换成 Swift 版并补上深色模式的那一张", .pi, .settled, nil, nil, 100_000, true),
            ("cue-codex-short", "greet", .codex, .waitingForUser, "要覆盖 tests/test_greet.py 吗？", nil, 150_000, false),
            ("cue-codex-long", "为 greet 添加 --upper 参数并验证测试输出原文", .codex, .tool, "bash · python3 -m unittest", nil, 188_000, true),
            ("cue-claude-short", "faq", .claudeCode, .settled, nil, nil, 150_000, false),
            ("cue-claude-long", "评估 README 是否需要加一节 FAQ 并跑一遍测试", .claudeCode, .waitingForUser, asked,
             PiQuestion(promptID: "cuerows-confirm", kind: .confirm, text: asked), 100_000, false),
        ]
        for row in rows {
            _ = try await recorder.update(
                sessionID: row.id, state: row.state, detail: row.detail, title: row.title, directory: "greet", question: row.question,
                modelState: row.model ? demoModels(for: row.agent) : nil,
                context: PiContextUsage(tokens: row.tokens, window: 200_000), agent: row.agent)
            try await store.writePiTranscript(PiTranscript(sessionID: row.id, messages: [], recap: PiRecap(lastPrompt: row.title, lastReply: "好了")))
            let task = try await store.createTask(row.title)
            try await store.linkCard(task.id, toSession: row.id)
        }
        try await store.leaveToYou("cue-claude-short")
    }

    /// 会话发来一张截图：卡片与"等你"上的证据。
    static func seedEvidence(_ store: CueStore, session: String, title: String) async {
        let file = FileManager.default.temporaryDirectory.appending(path: "cuepad-demo-\(session).png")
        try? swatchPNG().write(to: file)
        _ = try? await store.addPreviews([(file, title)], sessionID: session)
    }

    /// 一张像截图的演示图：浅底上一列名单。
    private static func swatchPNG() -> Data {
        let view = VStack(alignment: .leading, spacing: 10) {
            Text("发言顺序").font(.system(size: 22, weight: .bold))
            ForEach(["小林", "阿杰", "Mia", "老王", "Sora", "Kai"], id: \.self) { name in
                HStack { Circle().fill(.indigo.opacity(0.7)).frame(width: 18); Text(name) }
            }
        }
        .padding(24).frame(width: 300, height: 360, alignment: .topLeading).background(Color(red: 0.95, green: 0.96, blue: 1))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        return renderer.cgImage.map { DemoLibrary.encode($0) } ?? Data()
    }
}
#endif
