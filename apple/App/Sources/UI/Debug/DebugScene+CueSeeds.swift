#if DEBUG
import CueStore
import CueText
import SwiftUI

extension DebugScene {
    /// 演示记忆：长短不一（一句话到接近一条的上限）、钉住的与其他、你说的与 Cue 记的，时间从刚刚到几个月前。
    static var demoMemory: [SeedCueLine] {
        let hour: TimeInterval = 3600, day = 24 * hour
        func ago(_ seconds: TimeInterval) -> Date { .now.addingTimeInterval(-seconds) }
        return [
            SeedCueLine(String(localized: "回复要短，先说结论", table: "Demo"), source: .you, pinned: true, createdAt: ago(80 * day)),
            SeedCueLine(String(localized: "部署前先在测试群说一声，等有人回了再推；周五下午之后不发版，紧急修复除外", table: "Demo"), source: .you, pinned: true, createdAt: ago(40 * day)),
            SeedCueLine(String(localized: "提交信息用中文，一个提交只做一件事", table: "Demo"), source: .you, pinned: true, createdAt: ago(9 * day)),
            SeedCueLine(
                String(localized: "改界面之前先拍改前截图，深浅色各一张；做完拍改后的放在一起比，交给我看的时候发到手机上，不要只贴本机路径", table: "Demo"),
                source: .cue, pinned: true, createdAt: ago(2 * day)),
            SeedCueLine(String(localized: "圆桌的预发环境是 staging-2，正式环境要过 CI 才部署", table: "Demo"), source: .cue, createdAt: ago(60 * day)),
            SeedCueLine(String(localized: "用户住在上海，晚上十一点以后别叫醒", table: "Demo"), source: .cue, createdAt: ago(33 * day)),
            SeedCueLine(String(localized: "CuePad 的发布只在干净检出里跑 release，对外发布要先问", table: "Demo"), source: .cue, createdAt: ago(21 * day)),
            SeedCueLine(String(localized: "喜欢先看原型截图再定方案", table: "Demo"), source: .cue, createdAt: ago(12 * day)),
            SeedCueLine(
                String(localized: "登录回调的超时问题：等 token 刷新时没设超时，网络慢会一直挂着；改成 10 秒超时、超时后回登录页重新授权", table: "Demo"),
                source: .cue, createdAt: ago(6 * day)),
            SeedCueLine(String(localized: "atlas 会话用 Claude，别的用默认模型", table: "Demo"), source: .you, createdAt: ago(4 * day)),
            SeedCueLine(String(localized: "周会是每周一上午十点", table: "Demo"), source: .cue, createdAt: ago(3 * day)),
            SeedCueLine(String(localized: "乱序的根因在重连时重新入队，修复要保留首次加入的时间", table: "Demo"), source: .cue, createdAt: ago(day + 2 * hour)),
            SeedCueLine(String(localized: "README 的截图换成 Swift 版", table: "Demo"), source: .you, createdAt: ago(20 * hour)),
            SeedCueLine(String(localized: "导入旧数据会话上回卡在 schema 迁移，再开工前先看它的报错", table: "Demo"), source: .cue, createdAt: ago(5 * hour)),
            SeedCueLine(String(localized: "测试只用替身，不向别的应用发键鼠事件", table: "Demo"), source: .cue, createdAt: ago(40 * 60)),
            SeedCueLine(String(localized: "今天先把圆桌发了", table: "Demo"), source: .you, createdAt: ago(3 * 60)),
        ]
    }

    /// 推送那条"等你"点名要看的两份：部署会话发来的预发截图与测试报告（`seedDeliveries`）。
    static func deployShots(_ store: CueStore) async throws -> [CueShot] {
        let sent = try await store.previews(of: "deploy")
        return [(String(localized: "预发上的发言顺序", table: "Demo"), String(localized: "预发上 6 人的发言顺序", table: "Demo")), (String(localized: "重连测试报告", table: "Demo"), String(localized: "重连用例 4 个都过了", table: "Demo"))].compactMap { title, look in
            sent.first { $0.title == title }.map { CueShot(preview: $0.id, look: look) }
        }
    }

    /// `-CuePadLongChat YES`：演示对话前面多 110 轮更早的来回（比 Cue 页读得到的 `CueThread.limit` 条多：来一句新的，最早那条就掉出去，同真实库）（看 Cue 页往上翻与刻度滑条）。
    /// Cue 的回答高矮悬殊：一句话与会话页长对话同一套长段落、40 行代码块、宽表、长列表轮换（`longChatReply`）；你每 25 轮贴进来一段长文，每 15 轮带一张图。
    /// 量 Cue 页的长对话滚动（`-CuePadBench chatscroll`）就用这一段。
    static func seedLongCueChat(you: (String) async throws -> Void, store: CueStore) async throws {
        let asks = [String(localized: "今天先看哪件？", table: "Demo"), String(localized: "把计费那个会话的进展说一下", table: "Demo"), String(localized: "圆桌的预发什么时候能好？", table: "Demo"), String(localized: "帮我记一下：周五不发版", table: "Demo"), String(localized: "README 截图换完了吗？", table: "Demo"), String(localized: "重连用例加了几个？", table: "Demo")]
        let replies = [String(localized: "先看圆桌：乱序会影响所有 5 人以上的房间。", table: "Demo"), String(localized: "计费会话卡在额度接口的签名上，我让它先把请求原文打出来。", table: "Demo"), String(localized: "测试在跑，大概二十分钟后能部署到预发。", table: "Demo"),
                       String(localized: "记下了，周五不发版。", table: "Demo"), String(localized: "浅色那张换好了，深色的还在拍。", table: "Demo"), String(localized: "加了 2 个，第 3 个等排序改完再补。", table: "Demo")]
        let shot = CueFormat.imageMarkup(key: try store.files.store(stagingOrderPNG()))
        for round in 0..<110 {
            let ask = round % 25 == 0 ? longChatPrompt(round) : String(localized: "第 \(round + 1) 句：", table: "Demo") + asks[round % asks.count]
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
        let asked = String(localized: "加在「安装」后面吗？", table: "Demo")
        let rows: [(id: String, title: String, agent: AgentKind, state: PiWorkState, detail: String?, question: PiQuestion?, tokens: Int, model: Bool)] = [
            ("cue-pi-long", String(localized: "把 README 的截图换成 Swift 版并补上深色模式的那一张", table: "Demo"), .pi, .settled, nil, nil, 100_000, true),
            ("cue-codex-short", "greet", .codex, .waitingForUser, String(localized: "要覆盖 tests/test_greet.py 吗？", table: "Demo"), nil, 150_000, false),
            ("cue-codex-long", String(localized: "为 greet 添加 --upper 参数并验证测试输出原文", table: "Demo"), .codex, .tool, "bash · python3 -m unittest", nil, 188_000, true),
            ("cue-claude-short", "faq", .claudeCode, .settled, nil, nil, 150_000, false),
            ("cue-claude-long", String(localized: "评估 README 是否需要加一节 FAQ 并跑一遍测试", table: "Demo"), .claudeCode, .waitingForUser, asked,
             PiQuestion(promptID: "cuerows-confirm", kind: .confirm, text: asked), 100_000, false),
        ]
        for row in rows {
            _ = try await recorder.update(
                sessionID: row.id, state: row.state, detail: row.detail, title: row.title, directory: "greet", question: row.question,
                modelState: row.model ? demoModels(for: row.agent) : nil,
                context: PiContextUsage(tokens: row.tokens, window: 200_000), agent: row.agent)
            try await store.writePiTranscript(PiTranscript(sessionID: row.id, messages: [], recap: PiRecap(lastPrompt: row.title, lastReply: String(localized: "好了", table: "Demo"))))
            let task = try await store.createTask(row.title)
            try await store.linkCard(task.id, toSession: row.id)
        }
        try await store.leaveToYou("cue-claude-short")
    }

    /// 会话发来一张截图（`png`）：卡片与"等你"上的证据。
    @discardableResult
    static func seedEvidence(_ store: CueStore, session: String, title: String, png: Data) async -> PiPreview? {
        let file = FileManager.default.temporaryDirectory.appending(path: "cuepad-demo-\(session).png")
        try? png.write(to: file)
        return try? await store.addPreviews([(file, title)], sessionID: session).first?.preview
    }
}
#endif

#if DEBUG
extension DebugScene {
    /// 定时（定时页、手机 Cue 面板的定时那一行、任务气泡里那一条）：每天 8:00 的汇总；挂在 `task` 上的每月 1 号 9:00，
    /// 上一次那次错过了、41 分钟后补上（那一轮写在对话里它补上的时刻）；明天 15:00 只这一次的。
    static func seedSchedules(_ store: CueStore, task: Card?) async throws {
        let daily = CueRepeat(.daily, hour: 8, minute: 0)!
        try await store.noteCueLine(
            String(localized: "汇总昨天各项目的进展，发到手机", table: "Demo"), source: .you, remindAt: daily.next(after: .now), repeats: daily)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        try await store.noteCueLine(
            String(localized: "周会前提醒他要讲的三件事", table: "Demo"), source: .cue,
            remindAt: Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: tomorrow))
        guard let task else { return }
        let monthly = CueRepeat(.monthly(1), hour: 9, minute: 0)!
        let line = try await store.noteCueLine(
            String(localized: "查一遍域名哪些快到期，续上", table: "Demo"), source: .cue, remindAt: monthly.next(after: .now), repeats: monthly, task: task.id
        ).line
        let late: TimeInterval = 41 * 60
        let due = CueRepeat(.daily, hour: 9, minute: 0)!.next(after: .now.addingTimeInterval(-late - 86_400))
        try await store.recordCueRound(nil, startedAt: due.addingTimeInterval(late), answersYou: false, tools: nil, wake: .schedule([CueFire(line: line.id, due: due)]))
    }
}
#endif
