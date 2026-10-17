#if DEBUG
import CueStore
import CueText
import SwiftUI

/// 演示库里的 Cue（`-CuePadScene cue`、`cuememory`，配 `-CuePadDemo YES`）：在演示 Mac 上值班，管着圆桌的"乱序"（步骤在 Agent 会话里跑，
/// 部署那一步发来一张截图、在等你允许推送）与 CuePad 的"导入旧数据"（会话出错）；"README 截图换成 Swift 版"Cue 确认做完了（结果带证据与截图）。
/// 对话里有你的话（一句带图）、Cue 的话、折起的动态、一次换新（交接备忘）、一条结果与一条"等你"（正文带一段测试输出）；atlas 会话里有一句 Cue 发的话；
/// 记忆有钉住的与其他，还有一条忘掉的；上下文用到换新线的七成（`CueContext`）。cuerun（仅 Mac）让 Cue 住在这台 Mac，"运行情况"才有。
/// `-CuePadCuePresence <thinking|tool|sending|asleep|disabled>`：你的最后一句已交给 Cue（气泡下"已送达"）、它在想（thinking）或在用工具（tool：看会话进展）、
/// 刚说的还没交出去（sending：话在路上，时限内气泡转圈）、
/// 演示 Mac 不在线、两分钟前说的一直没交出去（asleep：它在睡觉，气泡过了等回执的时限 `Speech.receiptLimit`、没能送达可重发；
/// 隔离库没有同步，要配 `-CuePadDemoMac YES` 才算同步通着、说它在睡觉）、
/// 没启用。演示 Mac 不值班，在线记录与此刻在做什么直接写进库（`CueStore.recordMacPresence`、`setCueState`；在线管一个期限 `MacPresence.lifetime`）。
extension DebugScene {
    static func seedCue(_ services: AppServices) async {
        let store = services.store
        guard (try? await store.cueMessages(limit: 1).isEmpty) == true else { return }
        let presence = defaults.string(forKey: "CuePadCuePresence")
        // "运行情况"只在 Cue 值班的这台 Mac 上有：cuerun 让它住在这台（大脑在隔离目录里起不来，几轮是空的或出错）
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
            await seedEvidence(store, session: "deploy", title: "预发上的发言顺序")
            await seedEvidence(store, session: "notes", title: "README 截图（浅色）")
            // Cue 发进 atlas 会话的一句（还在路上）：会话页的气泡上标着 Cue
            _ = try await store.requestDelivery(
                "排序改完后把 scheduler 的测试全跑一遍，结果贴给我", to: SendTarget(kind: .piSession, name: "atlas", ref: "atlas"), on: "demo-mac", cue: true)

            func you(_ text: String) async throws {
                let message = try await store.addCueMessage(.you, text: text)
                try await store.markCueMessagesDelivered([message.id])
            }
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
            for (note, tools) in [
                ("看了圆桌：复现乱序完成，原因是重连的人拿到了新的加入时间", process(step(.read, "看「发言轮次乱序」的近况", order))),
                ("让 atlas 改成按首次加入时间排序，正在跑 scheduler 的测试", process(
                    step(.read, "看「发言轮次乱序」的近况", order), step(.talk, "对「发言轮次乱序」说：按首次加入时间排序，改完把 scheduler 的测试全跑一遍", order))),
                ("CuePad 导入旧数据的会话出错了：模型拒绝了请求（prompt 太长），等你回来再说", process(
                    step(.read, "看板"), step(.read, "看「导入旧数据」的近况", importing), step(.search, "导入旧数据 prompt 太长"))),
                ("", process(
                    step(.read, "看「README 截图」的近况", panel), step(.talk, "对「README 截图」说：深色那张也按参考图拍，拍完发给我", panel),
                    step(.other, "记下：README 截图要浅色深色各一张"))),
            ] {
                try await store.recordCueRound(nil, startedAt: .now, answersYou: false, tools: tools)
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
            let shot = CueFormat.imageMarkup(id: try store.files.store(swatchPNG()))
            try await you("README 的截图也交给你，换成 Swift 版的样子，参考这张\n" + shot)
            // Cue 确认做完了：结果的正文与 Cue 的 done 同一个拼法（`CueReport.text`）
            if let panel { _ = try await store.finishTask(panel.id, evidence: ["浅色深色各一张，都按你给的参考图", "README 里的旧截图都换掉了"]) }
            _ = try await store.addCueMessage(
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
                    """, ask: .push, task: order?.id)
            for (text, pinned) in [("部署前先在测试群说一声", true), ("回复要短，先说结论", true), ("圆桌的预发环境是 staging-2", false), ("周五不发版", false)] {
                _ = try await store.noteCueLine(text, source: pinned ? .you : .cue, pinned: pinned)
            }
            let forgotten = try await store.noteCueLine("旧的计费脚本还在用", source: .cue)
            try await store.forgetCueLine(forgotten.line.id)
            // 这个班次两个半小时前起，用到换新线的七成（上下文用量那一块加深一档）
            try await store.setCueContext(CueContext(used: 41_800, window: 200_000, since: .now.addingTimeInterval(-9_000)))
            switch presence {
            case "thinking":
                try await you("顺便看看登录回调那个超时")
                try await store.setCueState(.thinking)
            case "tool":
                try await you("顺便看看登录回调那个超时")
                let row = try await store.recordCueRound(nil, startedAt: .now, answersYou: true, tools: process(
                    step(.read, "看板"), step(.search, "登录回调 超时"), step(.add, "建任务「登录回调超时」"), step(.start, "开工「登录回调超时」")))
                try await store.setCueState(.tool, detail: "跟会话说话", round: row)
            case "sending":
                _ = try await store.addCueMessage(.you, text: "顺便看看登录回调那个超时")
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
    /// 带上叫醒它的会话（`CueState.woke`，同值班的 Mac 起一轮时写下的样子），醒 1.5 秒后歇下；叫醒的会话从在线会话的前三个里轮着挑，
    /// 一次一个、一次两个交替（看几道光错开）；给了 `-CuePadSession`（session 画面）时它排第一个，每次都有它。
    /// 录"叫醒"的动效用（`CueWakeStage`）；隔离库里 Cue 不值班，没有别人改它的状态。
    /// `-CuePadWakeLog <路径>`：每次叫醒前歇着的 `probe` 秒与叫醒后的 `probe` 秒各量一段，一段一行 JSON 追加到这个文件：
    /// 主线程每帧的 display link 间隔（掉帧、最长一帧）、每圈 run loop 的主线程 CPU、进程的指令数与能量（`TurnLog.metrics`、`energyMillijoules`）。
    /// 叫醒那段减去歇着那段是一次叫醒在 App 进程里的开销；配 `-CuePadReduceMotion YES` 再跑一遍当对照（状态照样变、不飞），两者之差是飞的那一下。
    /// 不抢前台：窗口在后台、留在屏上（display link 照走）；动画本身在渲染服务里插值，渲染服务的开销不在这个进程里，量不到。
    static func wakeIfAsked(_ workspace: Workspace) async {
        let every = defaults.double(forKey: "CuePadWake")
        guard every > 0 else { return }
        let store = workspace.services.store
        let log = defaults.string(forKey: "CuePadWakeLog").map { URL(fileURLWithPath: $0) }
        let probe = log == nil ? 0 : wakeProbe
        var round = 0
        while !Task.isCancelled {
            // 叫醒的间隔是演示节奏，不是在等别的事
            try? await Task.sleep(for: .seconds(max(every - probe, 0)))
            if let log { await measureWake("idle", seconds: probe, into: log) }
            // 演示会话的 sessionID 与会话名相同
            let opened = defaults.string(forKey: "CuePadSession")
            let live = Array(workspace.liveSessionRows.filter { $0.state != .known(.ended) && $0.sessionID != opened }.prefix(3).map(\.sessionID))
            let count = round % 2 + 1
            var woke = (0..<min(count, live.count)).map { live[(round + $0) % live.count] }
            if let opened { woke = [opened] + woke.prefix(count - 1) }
            round += 1
            guard !woke.isEmpty else { continue }
            try? await store.setCueState(.thinking, woke: CueWoke(at: .now, sessions: woke))
            if let log { await measureWake("wake", seconds: probe, into: log) }
            try? await Task.sleep(for: .seconds(max(1.5 - probe, 0)))
            try? await store.setCueState(.settled)
        }
    }

    #if os(macOS)
    /// `-CuePadClosed <秒>`（仅 Mac）：画面就绪后这么久关上主窗口（同点关闭钮：内容摘下，`MainShellWindow`），配 `-CuePadWakeLog` 量关着窗时
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

    /// 量的一段比叫醒的那一下（约 1.3 秒）长一点。
    private static let wakeProbe = 1.5

    private static func measureWake(_ kind: String, seconds: Double, into log: URL) async {
        let turns = TurnLog(), frames = FrameRecorder()
        let instructions = instructionsMillions(), energy = energyMillijoules()
        #if os(macOS)
        // 主窗口关着（`-CuePadClosed`）时没有可挂 display link 的窗口：只量指令、CPU 与能量
        if let view = NSApp.windows.first(where: \.isVisible)?.contentView { frames.start(in: view) }
        #else
        frames.start()
        #endif
        turns.begin(CACurrentMediaTime(), root: nil)
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

    /// `-CuePadLongChat YES`：演示对话前面多 36 轮更早的来回，中间换过两次新上下文（看 Cue 页往上翻、刻度滑条与换新的分隔）。
    private static func seedLongCueChat(you: (String) async throws -> Void, store: CueStore) async throws {
        let asks = ["今天先看哪件？", "把计费那个会话的进展说一下", "圆桌的预发什么时候能好？", "帮我记一下：周五不发版", "README 截图换完了吗？", "重连用例加了几个？"]
        let replies = ["先看圆桌：乱序会影响所有 5 人以上的房间。", "计费会话卡在额度接口的签名上，我让它先把请求原文打出来。", "测试在跑，大概二十分钟后能部署到预发。",
                       "记下了，周五不发版。", "浅色那张换好了，深色的还在拍。", "加了 2 个，第 3 个等排序改完再补。"]
        for round in 0..<36 {
            if round == 12 || round == 26 {
                _ = try await store.addCueMessage(.handoff, text: "**在做**\n- 圆桌乱序：在改排序，测试在跑。\n\n**下一步**\n- 测试过了派重连用例，再部署预发。")
            }
            try await you("第 \(round + 1) 句：" + asks[round % asks.count])
            _ = try await store.addCueMessage(.cue, text: replies[round % replies.count])
        }
    }

    /// `-CuePadScene cuerows`（不配演示库）：Cue 在值班，五个会话——Pi、Codex、Claude Code 各一，标题长短都有，
    /// 停着的、在跑的、等回答的都有（Claude Code 那个是 CuePad 答得了的确认，等 Cue 回答；Codex 那个只是一句话，等你确认）；各绑一件任务。上下文 50%（行上不写）、75%（加粗）、94%（胭脂）三档都有；
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
            let task = try await store.createTask(row.title, in: nil)
            try await store.linkCard(task.id, toSession: row.id)
        }
    }

    /// 会话发来一张截图：卡片与"等你"上的证据。
    private static func seedEvidence(_ store: CueStore, session: String, title: String) async {
        let file = FileManager.default.temporaryDirectory.appending(path: "cuepad-demo-\(session).png")
        try? swatchPNG().write(to: file)
        _ = try? await store.addPreviews(filesAt: [file], title: title, sessionID: session)
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
