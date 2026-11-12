#if DEBUG
import CueStore
import CueText
import Foundation

/// `-CuePadCuePresence asleep` 要配 `-CuePadDemoMac YES`：隔离库没有同步，要演示 Mac 才算同步通着、说它在睡觉。
/// 配 fresh 时 notes-edit 也结束，没有拍板：名牌说几个会话待回复。
/// `cuerun`（仅 Mac）让 Cue 运行在这台 Mac，"运行情况"才有。
/// 演示 Mac 不值班，在线记录与此刻在做什么直接写进库（`CueStore.recordMacPresence`、`setCueState`）。
extension DebugScene {
    static func seedCue(_ services: AppServices) async {
        let store = services.store
        let presence = args.cueOpts.presence
        if presence == "unchosen" { return }
        // "运行情况"只在 Cue 值班的这台 Mac 上有：cuerun 让它运行在这台（大脑在隔离目录里起不来，几轮是空的或出错）
        #if os(macOS)
        let host = scene == "cuerun" ? services.hostID : "demo-mac"
        #else
        let host = "demo-mac"
        #endif
        do {
            guard try await store.cueMessages(limit: 1).isEmpty else { return }
            _ = try await store.updateCueProfile { profile in
                profile.hostID = host
                profile.enabledAt = presence == "disabled" ? nil : .now
            }
            if presence != "asleep" { try await store.recordMacPresence(host: host, bootID: boot(of: host)) { true } }
            if presence == "fresh" {
                let replies = args.replies
                if replies > 0 { try await demoRecorder(store).end(sessionID: "notes-edit") }
                return try await seedReplies(replies, store: store)
            }
            let tasks = try await store.tasks(.todo, .inProgress, .done).flatMap(\.tasks)
            func task(_ prefix: String) -> Card? { tasks.first { $0.parentID == nil && $0.body.hasPrefix(prefix) } }
            let order = task(String(localized: "发言轮次乱序", table: "Demo")), importing = task(String(localized: "导入旧数据时保留回收站", table: "Demo")), panel = task(String(localized: "README 截图换成 Swift 版", table: "Demo"))
            if let importing { try await store.linkCard(importing.id, toSession: "billing") }
            if let panel { try await store.linkCard(panel.id, toSession: "notes") }
            let evidence = try await seedEvidence(store, session: "notes", title: String(localized: "README 截图（浅色）", table: "Demo"), png: readmePNG())
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
            if args.longChat { try await seedLongCueChat(you: you, store: store) }
            try await you(String(localized: "圆桌那个 5 人以上乱序的 bug 交给你，修好之后部署到预发", table: "Demo"))
            try await store.recordCueRound(nil, startedAt: .now, answersYou: true, tools: process(
                step(.read, String(localized: "看板", table: "Demo")), step(.add, String(localized: "建任务「发言轮次乱序」", table: "Demo"), order), step(.other, String(localized: "改「发言轮次乱序」", table: "Demo"), order), step(.start, String(localized: "开工「发言轮次乱序」", table: "Demo"), order),
                step(.talk, String(localized: "对「发言轮次乱序」说：先复现 5 人以上的乱序，再改成按首次加入时间排序", table: "Demo"), order)))
            _ = try await store.addCueMessage(
                .cue, text: String(localized: "好。拆成四步：复现、改成按首次加入时间排序、补 3 个重连用例、部署到预发。第一步已经复现了，现在在改排序。", table: "Demo"), task: order?.id)
            func stirred(_ kind: CueChange.Kind, _ session: String) -> CueWake { .sessionActivity([CueStir(kind: kind, session: session)]) }
            let meeting = try await store.cueMemory().lines.first { $0.text.hasPrefix(String(localized: "周会是每周一上午十点", table: "Demo")) }
            for (wake, tools) in [
                (stirred(.settled, "atlas"), process(
                    step(.read, String(localized: "看「发言轮次乱序」的近况", table: "Demo"), order), step(.talk, String(localized: "对 atlas 说：复现了，接着改", table: "Demo"), session: "atlas"))),
                (stirred(.settled, "atlas"), process(
                    step(.read, String(localized: "看「发言轮次乱序」的近况", table: "Demo"), order), step(.talk, String(localized: "对「发言轮次乱序」说：按首次加入时间排序，改完把 scheduler 的测试全跑一遍", table: "Demo"), order))),
                (stirred(.failed, "billing"), process(
                    step(.read, String(localized: "看板", table: "Demo")), step(.read, String(localized: "看「导入旧数据」的近况", table: "Demo"), importing),
                    step(.leave, String(localized: "「billing」留给你回", table: "Demo"), session: "billing"))),
                (CueWake.schedule(meeting.map { [CueFire(line: $0.id, due: .now)] } ?? []), process(
                    step(.read, String(localized: "看「README 截图」的近况", table: "Demo"), panel), step(.talk, String(localized: "对「README 截图」说：深色那张也按参考图拍，拍完发给我", table: "Demo"), panel),
                    step(.other, String(localized: "记下：README 截图要浅色深色各一张", table: "Demo")))),
                (stirred(.settled, "notes"), process(
                    step(.read, String(localized: "看「README 截图」的近况", table: "Demo"), panel), step(.leave, String(localized: "「notes」留给你回", table: "Demo"), session: "notes"))),
                (.idle, process(step(.read, String(localized: "看板", table: "Demo")))),
            ] {
                try await later(12)
                try await store.recordCueRound(nil, startedAt: .now, answersYou: false, tools: tools, wake: wake)
            }
            try await seedDeliveries(store)
            try await later(20)
            let shot = CueFormat.imageMarkup(key: try store.files.store(appShotPNG()))
            try await you(String(localized: "README 的截图也交给你，换成 Swift 版的样子，参考这张", table: "Demo") + "\n" + shot)
            try await store.recordCueRound(nil, startedAt: .now, answersYou: true, tools: process(
                step(.read, String(localized: "看「README 截图」的近况", table: "Demo"), panel), step(.talk, String(localized: "对「README 截图」说：换成 Swift 版的样子，按你给的参考图拍", table: "Demo"), panel),
                step(.read, String(localized: "看「导入旧数据」的近况", table: "Demo"), importing), step(.read, String(localized: "看「发言轮次乱序」的近况", table: "Demo"), order)))
            _ = try await store.addCueMessage(.cue, text: String(localized: "交给 notes 会话按参考图重拍了。", table: "Demo"))
            // Cue 确认做完了：结果的正文与 Cue 的 done 同一个拼法（`CueReport.text`）
            if let panel {
                _ = try await store.finishTask(
                    panel.id, evidence: [String(localized: "浅色深色各一张，都按你给的参考图", table: "Demo"), String(localized: "README 里的旧截图都换掉了", table: "Demo")],
                    shots: [CueShot(preview: evidence.id, look: String(localized: "浅色：新的 README 截图", table: "Demo"))])
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
            // 第二张"等你"（答完第一张接着露出来）只在要各种等你时写：默认的演示里拍板是这一张与 notes-edit 在编辑器里问的那个，共两个
            if !cueFlows, args.driveOpts.waitKinds, let billing = task(String(localized: "清理旧的计费脚本", table: "Demo")) {
                _ = try await store.addCueMessage(
                    .cue, text: String(localized: "旧的计费脚本目录 `scripts/billing-legacy` 已经没有调用方了，CI 里也不再跑。要删掉吗？", table: "Demo"),
                    ask: try CueAsking(.delete, action: String(localized: "删掉 scripts/billing-legacy 目录", table: "Demo")), task: billing.id)
            }
            if let variant = args.cueOpts.ask { try await seedAsk(variant, store: store, task: order?.id) }
            let forgotten = try await store.noteCueLine(String(localized: "旧的计费脚本还在用", table: "Demo"), source: .cue)
            try await store.forgetCueLine(forgotten.id)
            for (minutes, wake, tools) in [
                (9.0, CueWake.idle, process(step(.read, String(localized: "看板", table: "Demo")))),
                (7, stirred(.failed, "billing"), process(
                    step(.read, String(localized: "看「导入旧数据」的近况", table: "Demo"), importing), step(.leave, String(localized: "「billing」留给你回", table: "Demo"), session: "billing"))),
                (6, stirred(.settled, "atlas"), process(
                    step(.read, String(localized: "看「发言轮次乱序」的近况", table: "Demo"), order), step(.talk, String(localized: "对「发言轮次乱序」说：测试过了，接着补 3 个重连用例", table: "Demo"), order))),
                (11, .sessionActivity([
                    CueStir(kind: .waitingForUser, session: "deploy"), CueStir(kind: .stalled, task: importing?.id), CueStir(kind: .settled, session: "notes"),
                ]), process(step(.read, String(localized: "看板", table: "Demo")), step(.leave, String(localized: "「deploy」留给你回", table: "Demo"), session: "deploy"))),
                (5, stirred(.waitingForUser, "notes-edit"), process(
                    step(.read, String(localized: "看 notes-edit 的近况", table: "Demo")), step(.leave, String(localized: "「notes-edit」留给你回", table: "Demo"), session: "notes-edit"))),
                (2, stirred(.settled, "relay"), process(
                    step(.read, String(localized: "看 relay 的近况", table: "Demo"), session: "relay"), step(.done, String(localized: "收掉 relay", table: "Demo"), session: "relay"))),
            ] {
                try await later(minutes)
                try await store.recordCueRound(nil, startedAt: .now, answersYou: false, tools: tools, wake: wake)
            }
            try await later(1)
            try await store.recordCueRound(nil, startedAt: .now, answersYou: false, tools: process(
                step(.read, String(localized: "看 docs 的近况", table: "Demo"), session: "docs"),
                step(.talk, String(localized: "对 cuepad 说：补丁合进去后告诉 docs 填投送队列的数据", table: "Demo"), session: "cuepad")), wake: stirred(.settled, "docs"))
            try await seedSchedules(store, task: task(String(localized: "续费域名", table: "Demo")))
            let context = CueContext(used: 70_000)
            try await store.setDemoCueState(.settled, context: context)
            _ = try await store.leaveToYou("notes")
            if args.driveOpts.waitKinds {
                for id in ["homepage", "deploy", "rename"] { _ = try await store.leaveToYou(id) }
                // 已完成列里一件带成果图的
                if let done = try await store.tasks(.done).flatMap(\.tasks).first(where: { $0.parentID == nil }) {
                    _ = try await store.addCueMessage(.cue, text: String(localized: "做完了，预发上是这个样子。", table: "Demo"), shots: try await deployShots(store), task: done.id)
                }
                try await store.markCueRead(through: .now)
            }
            try await seedReplies(args.replies, store: store)
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
