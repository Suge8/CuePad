#if os(macOS)
import CueAgent
import CuePi
@testable import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 多日记忆：Cue 已值了两周班，库里预置这两周的历史（对话、动态与每轮经过一千五百条以上，若干做完的任务与会话回复，记忆九十多行），
/// 远超一次视图能原样放下；启用 Cue 之前写好，新班次从库里接上（现做法是交接与之后的对话，混合做法是对话视图）。
/// 在不同年纪埋下事实：13 天前他顺口说的事、9 天前会话报告里顺带的细节、5 天前他否掉的方案与理由、2 天前 Cue 答应他的事、1 天前他改过的偏好。
/// 先给 Cue 空闲合并记忆的机会（合并的开销单列），再逐件问起；缓存时长缩短，场景里插几段静止模拟隔了一阵才回来（冷醒来）。跑法见 docs/verify.md「Cue 评测」。
@Suite(.enabled(if: evalEnvironment["CUEPAD_CUE_EVAL"] == "1", "CUEPAD_CUE_EVAL=1 才跑"), .timeLimit(.minutes(60)))
struct CueEvalDaysTests {
    @Test func 多日记忆() async throws {
        let history = DaysHistory()
        try await CueEval.run("多日", expect: Days.expect, rig: {
            try await CueHostTests.Rig(
                brain: .current, mergeAfter: Days.mergeAfter, cacheLifetime: Days.cacheLifetime, prepare: { try await history.write(into: $0) })
        }) { try await Days($0, history).play() }
    }
}

/// 剧本与判定。
@MainActor
private final class Days: EvalScript {
    static let expect = """
        已值两周班，逐件问起不同年纪的事：13 天前顺口说的考级日期、9 天前 CI 报告里的镜像版本、5 天前否掉的 S3 与理由、\
        2 天前答应的告诉他访问量、1 天前改成中文的提交信息；冷醒来换新后不重做、不重复问
        """
    /// 三个时长的先后照正式的（空闲 10 分钟合并、缓存 1 小时）缩短：合并在缓存还热时醒来；他走开的时长比合并加缓存还长，
    /// 中途若冒出合并醒来，他回来时离那次请求也已过了缓存时长，仍是冷醒来。
    static let mergeAfter = Duration.seconds(10)
    static let cacheLifetime = Duration.seconds(20)
    static let away = Duration.seconds(40)
    /// 开跑前至多等这么多次合并醒来（记忆预置成正好这么多块待合并）
    static let merges = 4

    private let history: DaysHistory
    private var mergeRounds: [CueRound] = []

    init(_ eval: CueEval, _ history: DaysHistory) {
        self.history = history
        super.init(eval)
        sessions = [history.storage, history.weekly].compactMap(\.self)
    }

    func play() async throws -> [Check] {
        do {
            let checks = try await script()
            await summarize()
            return checks
        } catch {
            await summarize()
            throw error
        }
    }

    private func script() async throws -> [Check] {
        try await letItMerge()
        let date = try await say("他：问考级日期", "我女儿钢琴考级是哪天来着？")
        await quietPeriod(Self.away)
        let image = try await say("他：问 CI 报告里的镜像（冷）", "之前查 CI 变慢那份报告里，runner 用的镜像是哪个版本？")
        let storage = try #require(history.storage), site = try #require(history.weekly)
        let s3 = try await event("图片存储：问要不要迁 S3", on: storage) {
            try await storage.ask(
                said: "图片压缩做完了：上传时转 WebP、按三档宽度出图，存储用量从 182 GB 降到 61 GB，单元测试 27 个全过。",
                question: "存储要不要顺便迁到 S3？\nA. 迁到 S3（生命周期规则与 CloudFront 现成）\nB. 留在 R2", options: ["A", "B"], rig: rig)
        }
        let why = try await say("他：问为什么没选 S3", "上次图片存储为什么没选 S3 来着？")
        await quietPeriod(Self.away)
        let csv = try await say("他：派一件写代码的活（冷）", "演示项目的看板加一个导出 CSV 的按钮，直接开工。")
        let language = try await say("他：问提交信息用什么语言", "提交信息现在用中文还是英文来着？")
        let report = try await event("官网周报：交回数据", on: site) {
            try await site.deliver(pageShot("官网 2026 年 10 月周报", Script.weeklyShot), title: "官网十月周报", rig: rig)
            try await site.settle(Script.weekly, rig: rig)
        }
        await quietPeriod(Self.away)
        let wrap = try await say("他：问这几天的事（冷）", "这几天的事现在都怎么样了？")
        return try await judge(Points(date: date, image: image, s3: s3, why: why, csv: csv, language: language, report: report, wrap: wrap, storage: storage))
    }

    /// 开跑前给它空闲合并记忆的机会：等到没有待合并的块，或合并醒来满 `merges` 次。
    private func letItMerge() async throws {
        let from = Date.now
        try? await eventually("记忆合并完", timeout: .seconds(Double(Self.merges) * 40 + 120)) {
            let done = self.eval.rounds.filter { $0.startedAt >= from && Self.isMerge($0) }
            let pending = CueMemoryView(try await self.rig.store.cueMemory()).merges
            return (pending.isEmpty || done.count >= Self.merges) && done.allSatisfy { $0.finishedAt != nil } && self.eval.rounds.allSatisfy { $0.finishedAt != nil }
        }
        mergeRounds = eval.rounds.filter { $0.startedAt >= from && Self.isMerge($0) }
        let left = CueMemoryView(try await rig.store.cueMemory()).merges.count
        notes.append("开跑前合并醒来 \(mergeRounds.count) 次，还剩 \(left) 块待合并")
    }

    private static func isMerge(_ round: CueRound) -> Bool { round.sent.contains { $0.contains("写回：memory merge") } }

    // MARK: 判定

    struct Points {
        let date, image, s3, why, csv, language, report, wrap: Step
        let storage: ScriptedSession
    }

    private func judge(_ key: Points) async throws -> [Check] {
        for session in sessions { try await session.refresh(rig) }
        let s3Said = says([key.s3], to: key.storage)
        let reasons = try await replies(key.why).joined(separator: "\n")
        let csvTexts = CueEval.calls(in: rounds(key.csv), "task", ["add", "edit", "say", "start"]).map { Self.texts($0.args) }.joined(separator: "\n")
        let preference = csvTexts.contains(/中文/) ? "带了新的（中文）" : csvTexts.contains(/英文|English/) ? "带了旧的（英文）" : "没提"
        let told = try await messages(key.report) + calls(key.report, "tell").compactMap { $0.args["text"] as? String }
        let cold = [key.image, key.csv, key.wrap]
        let renewed = cold.filter { step in eval.renewals.contains { step.window?.contains($0.startedAt) == true } }
        let after = steps.filter { ($0.window?.lowerBound ?? .distantFuture) >= (key.image.window?.lowerBound ?? .distantFuture) }
        let adds = after.flatMap { calls($0, "task", ["add"]) }.filter { !$0.call.failed }
        let extra = adds.filter { ($0.args["title"] as? String)?.contains(/CSV|导出/) != true }
        let toHim = try await eval.said(since: key.date.window?.lowerBound).filter { $0.author == .known(.cue) }.map(\.text)
        let repeatedQuestions = toHim.filter { $0.contains(/？|\?/) }
        let askedTwice = repeatedQuestions.indices.contains { i in repeatedQuestions[(i + 1)...].contains { Self.similar($0, repeatedQuestions[i]) } }
        let resaid = sessions.filter { session in
            let said = says(steps, to: session)
            return said.indices.contains { i in said[(i + 1)...].contains { Self.similar($0, said[i]) } }
        }
        return [
            try await recalled("13 天前顺口说的：考级是 11 月 18 号", key.date, fabricated: { $0.contains(/\d+ ?月 ?\d+|\d+ ?号|\d+\/\d+/) }) {
                $0.contains(/11 ?月 ?18|11\/18|11-18/)
            },
            try await recalled("9 天前报告里顺带的：镜像 node:20.11.1-bookworm", key.image, fabricated: { $0.contains(/node:?\s?\d|\d+\.\d+\.\d+/) }) {
                $0.contains("20.11.1")
            },
            Check("5 天前否掉的：会话问迁不迁 S3，答留在 R2", s3Said.contains { $0.contains(/B|R2|不迁|留在/) } && !s3Said.contains { $0.trimmingCharacters(in: .whitespaces) == "A" }),
            Check("5 天前否掉的理由：贵、团队没人熟 AWS（答出至少一条）" + (reasons.isEmpty ? "（没回）" : ""), reasons.contains(/贵|成本|费用|AWS|不熟|没人熟/)),
            Check("1 天前改的偏好：派活时带的是新的（中文提交信息）——\(preference)", preference.hasPrefix("带了新的")),
            try await recalled("1 天前改的偏好：问起时答中文", key.language, fabricated: { $0.contains("英文") }) { $0.contains("中文") && !$0.contains(/现在.{0,6}英文|用英文写/) },
            Check("2 天前答应的：周报数据出来告诉他访问量 48,210", told.contains { $0.contains(/48,?210|4\.8 ?万|48210/) }),
            Check("冷醒来换新了（\(renewed.count)/\(cold.count) 次：\(renewed.map(\.label).joined(separator: "、"))）", renewed.count == cold.count),
            Check("冷醒来后不重做：除导出 CSV 外没另建任务" + (extra.isEmpty ? "" : "（另建：\(extra.compactMap { $0.args["title"] as? String }.joined(separator: "、"))）"), extra.isEmpty),
            Check("不重复问他、不对同一会话重复说", !askedTwice && resaid.isEmpty),
            Check("问这几天的事：回了他、没派新活", try await reply(key.wrap) != nil && calls(key.wrap, "task", ["add", "start"]).isEmpty),
        ]
    }

    // MARK: 统计

    func summarize() async {
        let rounds = eval.rounds.filter { $0.wake != .enabled }
        let durations = rounds.compactMap { round in round.finishedAt.map { $0.timeIntervalSince(round.startedAt) } }.sorted()
        let median = durations.isEmpty ? "—" : seconds(durations[durations.count / 2])
        let usage = rig.brainDirectory.map(BrainUsage.rounds(in:)) ?? []
        let all = eval.rounds
        // 开销按轮对齐（大脑报的与记下的轮按先后对应）
        let mergeUsage = all.indices.filter { Self.isMerge(all[$0]) && $0 < usage.count }.map { usage[$0] }.reduce(BrainUsage(), +)
        let total = usage.reduce(BrainUsage(), +)
        let renewals = eval.renewals
        let renewedAt = renewals.compactMap { round in steps.firstIndex { $0.window?.contains(round.startedAt) == true }.map { "第 \($0 + 1) 步「\(steps[$0].label)」" } }
        let cells = { (usage: BrainUsage) in usage.cells.replacingOccurrences(of: " | ", with: "、") }
        eval.overview = (rounds.reduce(0) { $0 + $1.calls.count }, "中位 \(median)")
        var lines = [
            "", "## 多日", "",
            "- 预置历史：对话 \(history.logged) 条、记忆 \(history.memoryLines) 行（\(history.pinned) 行一直记着）、做完的任务 \(history.doneTasks) 件",
            "- 醒来 \(rounds.count) 次（不含预热；其中合并 \(mergeRounds.count) 次，剧本叫醒 \(steps.count) 次），换新 \(renewals.count) 次（大脑开了新的对话）"
                + (renewedAt.isEmpty ? "" : "，在" + renewedAt.joined(separator: "、")),
            "- 每轮用时中位 \(median)",
            "- 合计（含预热与合并）：\(BrainUsage.header.replacingOccurrences(of: " | ", with: "、")) = \(cells(total))",
            "- 其中合并：\(cells(mergeUsage))",
        ]
        lines += notes.map { "- \($0)" }
        lines += ["", "| 步 | 叫醒的事 | 轮数 | 工具调用 |", "| --- | --- | --- | --- |"]
        for (index, step) in steps.enumerated() {
            let rounds = self.rounds(step)
            lines.append("| \(index + 1) | \(step.label) | \(rounds.count) | \(rounds.flatMap(\.calls).map(\.name).joined(separator: "、")) |")
        }
        eval.report = lines
    }
}

/// 两周的历史：启用 Cue 之前写进库（时刻往回倒），在做的两件事挂着假会话。
@MainActor
final class DaysHistory {
    private(set) var storage: ScriptedSession?
    private(set) var weekly: ScriptedSession?
    private(set) var logged = 0, memoryLines = 0, pinned = 0, doneTasks = 0

    func write(into rig: CueHostTests.Rig) async throws {
        let store = rig.store
        let site = try await store.createProject(name: "官网", color: "green")
        let siteFolder = rig.app.directory.appending(path: "site", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: siteFolder, withIntermediateDirectories: true)
        try await store.setDirectory(siteFolder.path, for: site.id)
        let demo = try #require(try await store.projects().first { $0.name == "演示" })

        var log: [Seeded] = []
        let calendar = Calendar(identifier: .gregorian)
        func at(_ day: Int, _ minute: Int) -> Date {
            calendar.date(byAdding: .minute, value: 9 * 60 + minute, to: calendar.startOfDay(for: calendar.date(byAdding: .day, value: -day, to: .now)!))!
        }
        // 日常来回：每天二十八轮，他的话、这一轮的经过、Cue 的回复、Cue 自己醒来的动态
        for day in stride(from: 14, through: 1, by: -1) {
            for turn in 0..<28 {
                let topic = Script.routine[(day * 28 + turn) % Script.routine.count]
                let minute = turn * 20
                log.append(Seeded(.you, topic.ask, at(day, minute)))
                log.append(Seeded(.round, "", at(day, minute) + 5, tools: [topic.step]))
                log.append(Seeded(.cue, topic.reply, at(day, minute) + 40))
                log.append(Seeded(.note, topic.note, at(day, minute + 12)))
            }
        }
        // 埋的事实
        log.append(Seeded(.you, "顺便说一句，我女儿 11 月 18 号钢琴考级，那天我请一天假。", at(13, 7 * 60 + 3)))
        log.append(Seeded(.cue, "好的，祝考级顺利。", at(13, 7 * 60 + 4)))
        log.append(Seeded(.cue, "图片存储我打算迁到 S3：生命周期规则和 CloudFront 都现成，压缩做完一起迁。你点头我就让会话准备。", at(5, 5 * 60)))
        log.append(Seeded(.you, "不用 S3，太贵，而且团队没人熟 AWS，就继续用 R2。", at(5, 5 * 60 + 6)))
        log.append(Seeded(.cue, "好，图片存储留在 R2，不迁 S3。", at(5, 5 * 60 + 7)))
        log.append(Seeded(.handoff, Script.handoff, at(3, 9 * 60)))
        log.append(Seeded(.you, "官网十月周报那件，数据出来告诉我访问量。", at(2, 6 * 60)))
        log.append(Seeded(.cue, "好，周报数据一出来我就告诉你访问量。", at(2, 6 * 60 + 1)))
        log.append(Seeded(.you, "提交信息以后改用中文写吧，英文的大家看着费劲。", at(1, 4 * 60)))
        log.append(Seeded(.cue, "好，以后让会话的提交信息都用中文写。", at(1, 4 * 60 + 1)))
        try await store.seed(log.sorted { $0.at < $1.at })
        logged = log.count

        // 记忆：先是一直记着的（含后来改掉的那条旧偏好），再是日常学到的，最后是 1 天前改的新偏好；共 94 行、6 行一直记着
        let pins = ["改数据库结构前先问我", "推送到远端前先问我", "提交信息用英文写", "界面方案先给几个让我在卡上选", "回复用中文、一两句", "官网的改动不要碰 blog 子目录"]
        // 序号按写下的先后：同一毫秒写下的按 id 排，所以一条一条隔开写
        let lines = pins.map { ($0, true) } + (0..<87).map { (Script.learned[$0 % Script.learned.count] + "（\($0 + 1)）", false) }
            + [("他 10/20 说：提交信息以后改用中文写", false)]
        for (line, pin) in lines {
            _ = try await store.noteCueLine(line, source: .cue, pinned: pin)
            await quietPeriod(.milliseconds(3))
        }
        memoryLines = pins.count + 88
        pinned = pins.count

        // 做完的任务（会话回复里带细节）
        for (index, task) in Script.done.enumerated() {
            try await doneTask(task.title, task.body, task.reply, day: task.day, project: demo.id, store: store, at: at, index: index)
        }
        doneTasks = Script.done.count

        // 在做的两件：图片存储（5 天前开工）、官网十月周报（2 天前开工），会话在干活
        storage = try await working(
            "优化图片存储", "上传的图片压缩成 WebP、按宽度出三档；存储留在 R2。", rig: rig, project: demo.id, folder: rig.folder,
            replies: [("接口与转码好了，在补存量图片的批处理。", at(4, 3 * 60))], started: at(5, 5 * 60 + 10))
        weekly = try await working(
            "整理官网十月周报", "从统计后台导出十月的访问量、来源与转化，整理成周报。", rig: rig, project: site.id, folder: siteFolder,
            replies: [("统计后台的导出接口在排队，数据要明天才出得来。", at(1, 2 * 60))], started: at(2, 6 * 60 + 5))
    }

    private func doneTask(
        _ title: String, _ body: String, _ reply: String, day: Int, project: UUID, store: CueStore, at: (Int, Int) -> Date, index: Int
    ) async throws {
        let first = "\(title)\n\(body)", id = "done-\(index)", delivery = UUID()
        let task = try await store.createTask(first, in: project)
        try await store.recordSend(first, to: SendTarget(kind: .piSession, name: title, ref: id), card: task.id, delivery: delivery, origin: .known(.cue))
        let prompt = PiChatMessage(sessionID: id, entryID: "u1", seq: 1, role: .user, text: first, at: at(day, 60), deliveryID: delivery)
        let answer = PiChatMessage(sessionID: id, entryID: "a1", seq: 2, role: .pi, text: reply, at: at(day, 180))
        try await store.writePiTranscript(PiTranscript(sessionID: id, messages: [prompt, answer], recap: PiRecap(lastPrompt: title, lastReply: reply, answeredAt: at(day, 180))))
        try await store.setStatus(task.id, .done)
    }

    private func working(
        _ title: String, _ body: String, rig: CueHostTests.Rig, project: UUID, folder: URL, replies: [(String, Date)], started: Date
    ) async throws -> ScriptedSession {
        let first = "\(title)\n\(body)", id = "s-\(UUID().uuidString.prefix(8).lowercased())", delivery = UUID()
        let task = try await rig.store.createTask(first, in: project)
        try await rig.store.recordSend(first, to: SendTarget(kind: .piSession, name: title, ref: id), card: task.id, delivery: delivery, origin: .known(.cue))
        let fake = try await rig.app.host.connect(id, cwd: folder.path, busy: true)
        fake.sendInfo(["name": title])
        var history = [PiChatMessage(sessionID: id, entryID: "e1", seq: 1, role: .user, text: first, at: started, deliveryID: delivery)]
        for (text, at) in replies {
            history.append(PiChatMessage(sessionID: id, entryID: "e\(history.count + 1)", seq: Int64(history.count + 1), role: .pi, text: text, at: at))
            history.append(PiChatMessage(sessionID: id, entryID: "e\(history.count + 1)", seq: Int64(history.count + 1), role: .user, text: "继续", at: at + 60))
        }
        try await rig.store.writePiTranscript(PiTranscript(sessionID: id, messages: history, recap: PiRecap(pendingPrompt: "继续")))
        try await eventually("\(title) 在干活写进库") { try await rig.store.sessions(matching: id).first?.state.isWorking == true }
        return ScriptedSession(session: fake, task: task, history: history)
    }
}

/// 预置的一条对话：谁、写什么、在什么时刻；他的话记成当时就交给了 Cue。
struct Seeded {
    let author: CueAuthor
    let text: String
    let at: Date
    var tools: [PiChatMessage.Tools.Item] = []

    init(_ author: CueAuthor, _ text: String, _ at: Date, tools: [PiChatMessage.Tools.Item] = []) {
        (self.author, self.text, self.at, self.tools) = (author, text, at, tools)
    }
}

extension CueStore {
    /// 预置历史：按给的时刻写对话（一轮的经过带清单），他的话标成当时已交给 Cue。只给评测用：正式路径只写此刻。
    func seed(_ log: [Seeded]) throws {
        try write {
            for entry in log {
                let tools = entry.tools.isEmpty ? nil : PiChatMessage.Tools(steps: entry.tools.count, items: entry.tools)
                let message = try insertCueMessage(entry.author, text: entry.text, tools: tools, at: entry.at)
                if entry.author == .you { try db.run("UPDATE cueMessages SET deliveredAt = ? WHERE id = ?", [entry.at, message.id]) }
            }
        }
    }
}

/// 预置历史与会话交回的文字。
private enum Script {
    struct Routine {
        let ask: String, reply: String, note: String
        let step: PiChatMessage.Tools.Item
    }

    /// 日常来回的几种：换着用，凑出两周的量
    static let routine: [Routine] = ([
        ("看下 CI 现在绿不绿", "CI 绿的，最近 20 次构建都过了。", "CI：例行看过，全绿", "CI 构建记录"),
        ("依赖更新的那几个 PR 合了吗", "合了三个，剩一个等测试补完。", "依赖更新：合了 3 个 PR", "依赖更新 PR"),
        ("登录页那个小 bug 修了没", "修了，会话补了测试，已经 done。", "登录页 bug：做完", "登录页 bug"),
        ("看板拖拽卡顿的事有进展吗", "会话定位到重复渲染，正在改。", "看板拖拽：在改重复渲染", "看板拖拽卡顿"),
        ("官网首页文案改好了吗", "改好了，截图发你手机了。", "官网文案：做完", "官网首页文案"),
        ("帮我看看昨晚的报错", "是第三方统计脚本超时，不影响主流程，已让会话加超时降级。", "报错：统计脚本超时，加降级", "昨晚的报错"),
        ("设置页的反馈整理一下", "整理好了，按主题分了五类，放在任务里。", "设置页反馈：整理完", "设置页反馈"),
        ("数据库备份正常吗", "正常，最近 7 天每天都成功，最大一次 3.1 GB。", "备份：例行看过，正常", "数据库备份"),
        ("README 里的安装步骤过时了吗", "过时了两步，已让会话更新。", "README：更新安装步骤", "README 安装步骤"),
        ("这周的发版准备好了吗", "准备好了，等你点头推送。", "发版：等他允许推送", "这周发版"),
        ("移动端的字号再调大一点", "已让会话把正文从 15 调到 16，截图稍后发你。", "移动端字号：在改", "移动端字号"),
        ("搜索变慢是怎么回事", "索引没覆盖新加的字段，会话加了索引，查询从 1.2 秒降到 80 毫秒。", "搜索：加索引，变快", "搜索变慢"),
        ("给通知中心加个全部已读", "加好了，测试过了，已 done。", "通知中心：全部已读做完", "通知中心全部已读"),
        ("把日志保留期改成 30 天", "改了，旧日志下次清理时按新规则删。", "日志保留期：改成 30 天", "日志保留期"),
    ] as [(String, String, String, String)]).map { Routine(ask: $0.0, reply: $0.1, note: $0.2, step: PiChatMessage.Tools.Item(kind: .talk, target: "\($0.3)：让会话跟进")) }

    /// 日常学到的记忆（不 pin）
    static let learned = [
        "演示项目的测试用 vitest，跑全量约 40 秒", "官网用 Astro，部署在 Cloudflare Pages", "CI 跑在自建 runner 上，周末偶尔排队",
        "他早上九点前不看手机", "演示项目的数据库是 Postgres 15", "看板拖拽用的是 dnd-kit", "官网的统计用的是自建的 Plausible",
        "发版通常在周四下午", "设置页的埋点在 analytics/settings-usage.csv", "移动端用 390 宽截图验收",
    ]

    /// 做完的任务：标题、正文、会话的交回、几天前
    static let done: [(title: String, body: String, reply: String, day: Int)] = [
        ("查清 CI 变慢", "最近 CI 从 6 分钟涨到 14 分钟，查清原因。", ciReport, 9),
        ("修好登录页白屏", "Safari 上偶发白屏，查清并修掉。", "修好了：Safari 15 不支持 structuredClone，换成手写深拷贝；补了 3 个测试，全过。", 12),
        ("通知中心加全部已读", "通知中心加一个全部已读按钮。", "加好了：按钮在右上角，接口一次标记全部；测试 8 个全过，截图发到手机了。", 8),
        ("搜索加索引", "搜索变慢，查原因并修。", "索引没覆盖 tags 字段；加了 GIN 索引，查询中位从 1.2 秒降到 80 毫秒。", 6),
        ("更新 README 安装步骤", "README 的安装步骤过时了，更新。", "更新了两步：Node 版本要求改成 20，去掉了已经不用的 yarn 步骤。", 4),
    ]

    static let ciReport = """
        查清楚了：CI 从 6 分钟涨到 14 分钟，主要是依赖缓存失效。

        1. 缓存键用的是 package-lock.json 的哈希，但 10/8 起 lockfile 每次构建都被 npm 重写（npm 版本升级后会改写 lockfileVersion），缓存每次都不命中，npm ci 从 40 秒涨到 6 分半。
        2. e2e 并发从 4 降到了 2（有人为排查不稳定的用例临时改的，忘了改回），又多出 2 分钟。

        改法：缓存键改成 lockfile 内容去掉 lockfileVersion 后的哈希；e2e 并发改回 4。改完三次构建分别是 6 分 10 秒、5 分 58 秒、6 分 05 秒。

        顺带记一下环境：runner 用的镜像是 node:20.11.1-bookworm，缓存目录挂在 /mnt/ci-cache，磁盘还剩 61%。
        """

    static let handoff = """
        在管：1 优化图片存储（演示）：会话在做压缩，留在 R2（他否掉了 S3）。2 设置页反馈整理完，等他看。\
        3 这周发版等他允许推送。和他没了结的：无。
        """

    static let weeklyShot = [
        "访问量 48,210（环比 +12%）  独立访客 31,870", "来源：搜索 46%  直接 29%  社交 17%  其他 8%", "注册 1,204（转化 2.5%）", "最忙：10/15  3,980 次访问",
    ]

    static let weekly = """
        官网十月周报整理好了。统计后台的导出接口今天早上放出来了，数据是刚导出的：

        - 10 月访问量 48,210（环比 +12%），独立访客 31,870
        - 来源：搜索 46%、直接访问 29%、社交 17%、其他 8%
        - 转化：注册 1,204（2.5%），比 9 月高 0.3 个百分点
        - 最忙的一天是 10/15（活动预热），单日 3,980 次访问

        原始数据（Plausible 导出，reports/raw/2026-10-visits.csv 前几行）：
        ```
        date,visits,visitors,source_search,source_direct,source_social,signups
        2026-10-01,1402,951,644,410,236,39
        2026-10-02,1388,940,640,401,239,37
        2026-10-15,3980,2711,1790,1150,690,112
        ...
        合计,48210,31870,22177,13981,8196,1204
        ```
        周报的总览图发到手机了，PDF 在 reports/2026-10.pdf。
        """
}
#endif
