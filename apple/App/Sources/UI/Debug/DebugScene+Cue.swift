#if DEBUG
import CueStore
import CueText
import Foundation

/// 演示库里的 Cue（`-CuePadScene cue`、`cuememory`，配 `-CuePadDemo YES`）：在演示 Mac 上值班，管着圆桌的"乱序"（步骤在 Agent 会话里跑，
/// 部署那一步发来一张截图、在等你允许推送）与 CuePad 的"导入旧数据"（会话出错）；"README 截图换成 Swift 版"Cue 确认做完了（结果带证据与截图）。
/// 对话里有你的话（一句带图）、Cue 的话、每一轮的经过（碰到 1 处、3 处）、折起的动态、一条结果与一条"等你"（正文带一段测试输出）；atlas 会话里有一句 Cue 发的话；
/// 记忆有钉住的与其他，还有一条忘掉的，最上面三条定时（`seedSchedules`）；上下文用到换新线的七成（`CueContext`）。cuerun（仅 Mac）让 Cue 运行在这台 Mac，"运行情况"才有。
/// `-CuePadWaitKinds YES`：等你里各种问题都有（Cue 把 homepage 的选择题、deploy 的确认题、rename 的文字题留给你答），对话都看过了、页停在最新处。
/// `-CuePadReplies <N>`、`-CuePadAtlas`、`-CuePadAtlasTitle` 见 `DebugScene+CueSessions.swift`。
/// 配 fresh 时 notes-edit 也结束，没有拍板：名牌说几个会话待回复。
/// `-CuePadCuePresence <unchosen|fresh|answered|thinking|tool|woke|sending|asleep|disabled>`：unchosen 是还没选过在哪台 Mac 上运行（演示的几台 Mac 都在，手机 Cue 面板就地选）；fresh 是刚启用、还没说过话（空态里那几句能直接说的话，`CueStarters`）；answered 是"等你"那一条你选了"可以"（回到对话里、带着你的回答），
/// 之后你又说了一句、Cue 跑了一轮（碰到 5 处，经过折起）、连着回了两句（看问询回到对话里的样子、一串气泡）；你的最后一句已交给 Cue（气泡旁的纸飞机）、它在想（thinking）或在用工具（tool：经过碰到 3 处、还在往下长，末行是此刻在做的）、Cue 自己醒来的一轮还在跑（woke：醒来那一行下面挂这一轮的经过，碰到 4 处，折成 2 处、"还有 2 处"与在跑那一行；改过又看过的那件写"修改"）、
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
            if presence == "fresh" {
                let replies = defaults.integer(forKey: "CuePadReplies")
                if replies > 0 { try await PiStateRecorder(store: store, hostID: "demo-mac").end(sessionID: "notes-edit") }
                return try await seedReplies(replies, store: store)
            }
            let tasks = try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks)
            func task(_ prefix: String) -> Card? { tasks.first { $0.parentID == nil && $0.body.hasPrefix(prefix) } }
            let order = task(String(localized: "发言轮次乱序", table: "Demo")), importing = task(String(localized: "导入旧数据时保留回收站", table: "Demo")), panel = task(String(localized: "README 截图换成 Swift 版", table: "Demo"))
            if let importing { try await store.linkCard(importing.id, toSession: "billing") }
            // 截图是 notes 会话做的（歇着）：Cue 值班，侧栏与会话列表里它只说"歇着"
            if let panel { try await store.linkCard(panel.id, toSession: "notes") }
            let evidence = await seedEvidence(store, session: "notes", title: String(localized: "README 截图（浅色）", table: "Demo"), png: readmePNG())
            // Cue 发进 atlas 会话的一句（还在路上）：会话页的气泡上标着 Cue
            _ = try await store.requestDelivery(
                String(localized: "排序改完后把 scheduler 的测试全跑一遍，结果贴给我", table: "Demo"), to: SendTarget(kind: .piSession, name: "atlas", ref: "atlas"), on: "demo-mac", cue: true)

            // 接下来写的比之前的晚这么多分钟（之前的都挪早）：对话里的时刻像真的一样错开
            func later(_ minutes: Double) async throws { try await store.seedAgeCueMessages(by: minutes * 60) }
            func you(_ text: String) async throws {
                let message = try await store.addCueMessage(.you, text: text)
                try await store.markCueMessagesDelivered([message.id])
            }
            // 记忆先写：定时到点的那一轮指着其中一条
            try await store.seed(cueLines: demoMemory)
            if defaults.bool(forKey: "CuePadLongChat") { try await seedLongCueChat(you: you, store: store) }
            try await you(String(localized: "圆桌那个 5 人以上乱序的 bug 交给你，修好之后部署到预发", table: "Demo"))
            // 每一轮的经过（同值班的管理器写下的样子，`CueActivity.item`）：排在这一轮开始的位置，碰到的任务与会话带着名字与 id，点它去那里
            try await store.recordCueRound(nil, startedAt: .now, answersYou: true, tools: process(
                step(.read, String(localized: "看板", table: "Demo")), step(.add, String(localized: "建任务「发言轮次乱序」", table: "Demo"), order), step(.other, String(localized: "改「发言轮次乱序」", table: "Demo"), order), step(.start, String(localized: "开工「发言轮次乱序」", table: "Demo"), order),
                step(.talk, String(localized: "对「发言轮次乱序」说：先复现 5 人以上的乱序，再改成按首次加入时间排序", table: "Demo"), order)))
            _ = try await store.addCueMessage(
                .cue, text: String(localized: "好。拆成四步：复现、改成按首次加入时间排序、补 3 个重连用例、部署到预发。第一步已经复现了，现在在改排序。", table: "Demo"), task: order?.id)
            // Cue 自己醒来的几轮（同值班的管理器醒来时写下的经过那一行，带着为什么醒）：会话停下、出错、定时到点，两次只看了看；
            // 连着六轮，Cue 页里折起前面的、两次只看了看的并成一行
            func stirred(_ kind: CueChange.Kind, _ session: String) -> CueWake { .sessionActivity([CueStir(kind: kind, session: session)]) }
            let meeting = try await store.cueMemory().lines.first { $0.text.hasPrefix(String(localized: "周会是每周一上午十点", table: "Demo")) }
            for (wake, note, tools) in [
                (stirred(.settled, "atlas"), String(localized: "看了圆桌：复现乱序完成，原因是重连的人拿到了新的加入时间", table: "Demo"), process(step(.read, String(localized: "看「发言轮次乱序」的近况", table: "Demo"), order))),
                (stirred(.settled, "atlas"), String(localized: "让 atlas 改成按首次加入时间排序，正在跑 scheduler 的测试", table: "Demo"), process(
                    step(.read, String(localized: "看「发言轮次乱序」的近况", table: "Demo"), order), step(.talk, String(localized: "对「发言轮次乱序」说：按首次加入时间排序，改完把 scheduler 的测试全跑一遍", table: "Demo"), order))),
                (stirred(.failed, "billing"), String(localized: "CuePad 导入旧数据的会话出错了：模型拒绝了请求（prompt 太长），等你回来再说", table: "Demo"), process(
                    step(.read, String(localized: "看板", table: "Demo")), step(.read, String(localized: "看「导入旧数据」的近况", table: "Demo"), importing), step(.search, String(localized: "导入旧数据 prompt 太长", table: "Demo")))),
                (CueWake.schedule(meeting.map { [CueFire(line: $0.id, due: .now)] } ?? []), "", process(
                    step(.read, String(localized: "看「README 截图」的近况", table: "Demo"), panel), step(.talk, String(localized: "对「README 截图」说：深色那张也按参考图拍，拍完发给我", table: "Demo"), panel),
                    step(.other, String(localized: "记下：README 截图要浅色深色各一张", table: "Demo")))),
                (stirred(.settled, "notes"), "", process(step(.read, String(localized: "看「README 截图」的近况", table: "Demo"), panel))),
                (.idle, "", process(step(.read, String(localized: "看板", table: "Demo")))),
            ] {
                try await later(12)
                try await store.recordCueRound(nil, startedAt: .now, answersYou: false, tools: tools, wake: wake)
                if !note.isEmpty { _ = try await store.addCueMessage(.note, text: note) }
            }
            try await seedDeliveries(store)
            try await later(20)
            let shot = CueFormat.imageMarkup(id: try store.files.store(appShotPNG()))
            try await you(String(localized: "README 的截图也交给你，换成 Swift 版的样子，参考这张", table: "Demo") + "\n" + shot)
            try await store.recordCueRound(nil, startedAt: .now, answersYou: true, tools: process(
                step(.read, String(localized: "看「README 截图」的近况", table: "Demo"), panel), step(.talk, String(localized: "对「README 截图」说：换成 Swift 版的样子，按你给的参考图拍", table: "Demo"), panel),
                step(.read, String(localized: "看「导入旧数据」的近况", table: "Demo"), importing), step(.read, String(localized: "看「发言轮次乱序」的近况", table: "Demo"), order)))
            _ = try await store.addCueMessage(.cue, text: String(localized: "交给 notes 会话按参考图重拍了。", table: "Demo"))
            // Cue 确认做完了：结果的正文与 Cue 的 done 同一个拼法（`CueReport.text`）
            if let panel {
                _ = try await store.finishTask(
                    panel.id, evidence: [String(localized: "浅色深色各一张，都按你给的参考图", table: "Demo"), String(localized: "README 里的旧截图都换掉了", table: "Demo")],
                    shots: evidence.map { [CueShot(preview: $0.id, look: String(localized: "浅色：新的 README 截图", table: "Demo"))] } ?? [])
            }
            try await later(25)
            let asked = try await store.addCueMessage(
                .cue, text: String(localized: """
                    预发上验过了，截图在这里。重连用例都过了：

                    ```
                    $ swift test --filter Reconnect
                    ✔ \(String(localized: "重连后保留首次加入时间", table: "Demo")) (0.21s)
                    ✔ \(String(localized: "6 人同时重连顺序不变", table: "Demo")) (0.48s)
                    ✔ \(String(localized: "断线超过 5 分钟按新人排", table: "Demo")) (0.12s)
                    ✔ \(String(localized: "主持人重连仍在第一位", table: "Demo")) (0.09s)
                    Executed 4 tests, with 0 failures
                    ```

                    要把改动**推送到 origin/main** 吗？推上去 CI 会自动部署到正式环境。
                    """, table: "Demo"), ask: try CueAsking(.push, action: String(localized: "把发言顺序的修复推送到 origin/main", table: "Demo")), shots: try await deployShots(store), task: order?.id)
            // 第二张"等你"（答完第一张接着露出来）：还有几条在等的演示
            if !cueFlows, let billing = task(String(localized: "清理旧的计费脚本", table: "Demo")) {
                _ = try await store.addCueMessage(
                    .cue, text: String(localized: "旧的计费脚本目录 `scripts/billing-legacy` 已经没有调用方了，CI 里也不再跑。要删掉吗？", table: "Demo"),
                    ask: try CueAsking(.delete, action: String(localized: "删掉 scripts/billing-legacy 目录", table: "Demo")), task: billing.id)
            }
            if let variant = defaults.string(forKey: "CuePadCueAsk") { try await seedAsk(variant, store: store, task: order?.id) }
            let forgotten = try await store.noteCueLine(String(localized: "旧的计费脚本还在用", table: "Demo"), source: .cue)
            try await store.forgetCueLine(forgotten.line.id)
            // 对话末尾 Cue 自己又醒了五轮（隔几分钟一轮，Cue 页每轮一行）：空闲巡视（只看了看）、billing 出错（说了一句）、atlas 停下了（催了一句，此刻又在跑）、
            // 三处一起有动静（只看了看：deploy 在等回答、一件任务的子代理卡住、notes 停下）、notes-edit 在等回答（只能在编辑器里答，此刻在等你）
            for (minutes, wake, note, tools) in [
                (9.0, CueWake.idle, "", process(step(.read, String(localized: "看板", table: "Demo")))),
                (7, stirred(.failed, "billing"), String(localized: "被模型拒了（prompt 太长），要拆成几段读，等你回来定", table: "Demo"), process(step(.read, String(localized: "看「导入旧数据」的近况", table: "Demo"), importing))),
                (6, stirred(.settled, "atlas"), String(localized: "scheduler 测试全过了，让它接着补 3 个重连用例", table: "Demo"), process(
                    step(.read, String(localized: "看「发言轮次乱序」的近况", table: "Demo"), order), step(.talk, String(localized: "对「发言轮次乱序」说：测试过了，接着补 3 个重连用例", table: "Demo"), order))),
                (11, .sessionActivity([
                    CueStir(kind: .waitingForUser, session: "deploy"), CueStir(kind: .stalled, task: importing?.id), CueStir(kind: .settled, session: "notes"),
                ]), "", process(step(.read, String(localized: "看板", table: "Demo")))),
                (5, stirred(.waitingForUser, "notes-edit"), String(localized: "要你在编辑器里改好提交说明再保存，这一步我替不了", table: "Demo"), process(step(.read, String(localized: "看 notes-edit 的近况", table: "Demo")))),
            ] {
                try await later(minutes)
                try await store.recordCueRound(nil, startedAt: .now, answersYou: false, tools: tools, wake: wake)
                if !note.isEmpty { _ = try await store.addCueMessage(.note, text: note) }
            }
            // docs 停下后 Cue 把要的数据转给了 cuepad、自己留着等它打完补丁：会话行与看板卡上歇着的 docs 写 Cue 对它做的这件事（`CueDid`）
            try await later(1)
            try await store.recordCueRound(nil, startedAt: .now, answersYou: false, tools: process(
                step(.read, String(localized: "看 docs 的近况", table: "Demo"), session: "docs"),
                step(.talk, String(localized: "对 cuepad 说：补丁合进去后告诉 docs 填投送队列的数据", table: "Demo"), session: "cuepad")), wake: stirred(.settled, "docs"))
            _ = try await store.addCueMessage(.note, text: String(localized: "已转给 cuepad，等它打补丁", table: "Demo"))
            try await seedSchedules(store, task: task(String(localized: "续费域名", table: "Demo")))
            // 用到换新线的七成（上下文用量那一块加深一档）
            let context = CueContext(used: 70_000)
            try await store.setCueState(.settled, context: context)
            // 等你里各种问题都有：Cue 把选择题、确认题、文字题留给你答（值班时它们本来归 Cue 答），都看过了（页停在最新处）
            if defaults.bool(forKey: "CuePadWaitKinds") {
                for id in ["homepage", "deploy", "rename"] { _ = try await store.leaveToYou(id) }
                try await store.markCueRead(through: .now)
            }
            try await seedReplies(defaults.integer(forKey: "CuePadReplies"), store: store)
            try await atlasIfAsked(store)
            try await taskLinesIfAsked(store)
            // 流程演示里"等你"只有它自己出的那一条：演示的这条先答掉，看得到那张卡出现与消失（`DebugScene+CueFlow.swift`）
            if cueFlows { _ = try await store.endCueQuestion(asked.id, .answered(CueAsk.once)) }
            try await seedPresence(presence, store: store, asked: asked, order: order, panel: panel, importing: importing, context: context, you: you)
        } catch {
            abandon("Cue 演示数据没写成", error)
        }
    }
}
#endif
