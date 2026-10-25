#if DEBUG
import CueStore
import CueText
import Foundation

/// 演示库里的 Cue（`-CuePadScene cue`、`cuememory`，配 `-CuePadDemo YES`）：在演示 Mac 上值班，管着圆桌的"乱序"（步骤在 Agent 会话里跑，
/// 部署那一步发来一张截图、在等你允许推送）与 CuePad 的"导入旧数据"（会话出错）；"README 截图换成 Swift 版"Cue 确认做完了（结果带证据与截图）。
/// 对话里有你的话（一句带图）、Cue 的话、折起的动态、一条结果与一条"等你"（正文带一段测试输出）；atlas 会话里有一句 Cue 发的话；
/// 记忆有钉住的与其他，还有一条忘掉的；上下文用到换新线的七成（`CueContext`）。cuerun（仅 Mac）让 Cue 运行在这台 Mac，"运行情况"才有。
/// `-CuePadWaitKinds YES`：等你里各种问题都有（Cue 把 homepage 的选择题、deploy 的确认题、rename 的文字题留给你答），对话都看过了、页停在最新处。
/// `-CuePadCuePresence <unchosen|fresh|answered|thinking|tool|sending|asleep|disabled>`：unchosen 是还没选过在哪台 Mac 上运行（演示的几台 Mac 都在，手机 Cue 面板就地选）；fresh 是刚启用、还没说过话（空态里那几句能直接说的话，`CueStarters`）；answered 是"等你"那一条你选了"可以"（回到对话里、带着你的回答），
/// 之后你又说了一句、Cue 跑了一轮（经过那一行）、连着回了两句（看问询回到对话里的样子、一串气泡；配 `-showsCueSteps YES` 看工具步骤那一行）；你的最后一句已交给 Cue（气泡旁的纸飞机）、它在想（thinking）或在用工具（tool：看会话进展）、
/// 刚说的还没交出去（sending：话在路上，时限内气泡转圈）、
/// 演示 Mac 不在线、两分钟前说的一直没交出去（asleep：它在睡觉，气泡过了等回执的时限 `Speech.receiptLimit`、没能送达可重发；
/// 隔离库没有同步，要配 `-CuePadDemoMac YES` 才算同步通着、说它在睡觉）、
/// 没启用；away 是你答了"等你"、说了句去睡了，一夜里 Cue 陆续说了几句（Cue 页的新消息，`CueViewing`）。演示 Mac 不值班，在线记录与此刻在做什么直接写进库（`CueStore.recordMacPresence`、`setCueState`；在线管一个期限 `MacPresence.lifetime`）。
extension DebugScene {
    static func seedCue(_ services: AppServices) async {
        let store = services.store
        guard (try? await store.cueMessages(limit: 1).isEmpty) == true else { return }
        let presence = defaults.string(forKey: "CuePadCuePresence")
        if presence == "unchosen" { return }
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
            if presence == "fresh" { return }
            let tasks = try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks)
            func task(_ prefix: String) -> Card? { tasks.first { $0.parentID == nil && $0.body.hasPrefix(prefix) } }
            let order = task("发言轮次"), importing = task("导入旧数据"), panel = task("README 截图")
            if let importing { try await store.linkCard(importing.id, toSession: "billing") }
            // 截图是 notes 会话做的（歇着）：Cue 值班，侧栏与会话列表里它只说"歇着"
            if let panel { try await store.linkCard(panel.id, toSession: "notes") }
            let evidence = await seedEvidence(store, session: "notes", title: "README 截图（浅色）", png: readmePNG())
            // Cue 发进 atlas 会话的一句（还在路上）：会话页的气泡上标着 Cue
            _ = try await store.requestDelivery(
                "排序改完后把 scheduler 的测试全跑一遍，结果贴给我", to: SendTarget(kind: .piSession, name: "atlas", ref: "atlas"), on: "demo-mac", cue: true)

            // 接下来写的比之前的晚这么多分钟（之前的都挪早）：对话里的时刻像真的一样错开
            func later(_ minutes: Double) async throws { try await store.seedAgeCueMessages(by: minutes * 60) }
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
                try await later(12)
                try await store.recordCueRound(nil, startedAt: .now, answersYou: false, tools: tools, wake: wake)
                if !note.isEmpty { _ = try await store.addCueMessage(.note, text: note) }
            }
            try await seedDeliveries(store)
            try await later(20)
            let shot = CueFormat.imageMarkup(id: try store.files.store(appShotPNG()))
            try await you("README 的截图也交给你，换成 Swift 版的样子，参考这张\n" + shot)
            // Cue 确认做完了：结果的正文与 Cue 的 done 同一个拼法（`CueReport.text`）
            if let panel {
                _ = try await store.finishTask(
                    panel.id, evidence: ["浅色深色各一张，都按你给的参考图", "README 里的旧截图都换掉了"],
                    shots: evidence.map { [CueShot(preview: $0.id, look: "浅色：新的 README 截图")] } ?? [])
            }
            try await later(25)
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
            // 对话末尾 Cue 自己又醒了五轮（隔几分钟一轮，Cue 页每轮一行）：空闲巡视（只看了看）、billing 出错（说了一句）、atlas 停下了（催了一句，此刻又在跑）、
            // 三处一起有动静（只看了看：deploy 在等回答、一件任务的子代理卡住、notes 停下）、notes-edit 在等回答（只能在编辑器里答，此刻在等你）
            for (minutes, wake, note, tools) in [
                (9.0, CueWake.idle, "", process(step(.read, "看板"))),
                (7, stirred(.failed, "billing"), "被模型拒了（prompt 太长），要拆成几段读，等你回来定", process(step(.read, "看「导入旧数据」的近况", importing))),
                (6, stirred(.settled, "atlas"), "scheduler 测试全过了，让它接着补 3 个重连用例", process(
                    step(.read, "看「发言轮次乱序」的近况", order), step(.talk, "对「发言轮次乱序」说：测试过了，接着补 3 个重连用例", order))),
                (11, .sessionActivity([
                    CueStir(kind: .waitingForUser, session: "deploy"), CueStir(kind: .stalled, task: importing?.id), CueStir(kind: .settled, session: "notes"),
                ]), "", process(step(.read, "看板"))),
                (5, stirred(.waitingForUser, "notes-edit"), "要你在编辑器里改好提交说明再保存，这一步我替不了", process(step(.read, "看 notes-edit 的近况"))),
            ] {
                try await later(minutes)
                try await store.recordCueRound(nil, startedAt: .now, answersYou: false, tools: tools, wake: wake)
                if !note.isEmpty { _ = try await store.addCueMessage(.note, text: note) }
            }
            // 这个班次两个半小时前起，用到换新线的七成（上下文用量那一块加深一档）
            let context = CueContext(used: 70_000, since: .now.addingTimeInterval(-9_000))
            try await store.setCueState(.settled, context: context)
            // 等你里各种问题都有：Cue 把选择题、确认题、文字题留给你答（值班时它们本来归 Cue 答），都看过了（页停在最新处）
            if defaults.bool(forKey: "CuePadWaitKinds") {
                for id in ["homepage", "deploy", "rename"] { _ = try await store.leaveToYou(id) }
                try await store.markCueRead(through: .now)
            }
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
                try await store.setCueState(.tool, detail: "对「登录回调超时」说", round: row, context: context)
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
}
#endif
