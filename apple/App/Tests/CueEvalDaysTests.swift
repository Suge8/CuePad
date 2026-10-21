#if os(macOS)
import CueAgent
import CuePi
@testable import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 多日记忆：Cue 已值了两周班，库里预置这两周的历史（对话、动态与每轮经过一千五百条以上，若干做完的任务与会话回复，记忆九十多行），
/// 远超一次视图能原样放下；启用 Cue 之前写好，新班次从库里接上（记忆视图与最近对话的视图）。
/// 在不同年纪埋下事实：13 天前他顺口说的事、9 天前会话报告里顺带的细节、5 天前他否掉的方案与理由、2 天前 Cue 答应他的事、1 天前他改过的偏好。
/// 开跑前等 Cue 静下来（`settleDown`），再逐件问起；缓存时长缩短，场景里插几段静止模拟隔了一阵才回来（冷醒来）。跑法见 docs/verify.md「Cue 评测」。
@Suite(.enabled(if: evalEnvironment["CUEPAD_CUE_EVAL"] == "1", "CUEPAD_CUE_EVAL=1 才跑"), .timeLimit(.minutes(60)))
struct CueEvalDaysTests {
    @Test func 多日记忆() async throws {
        let history = DaysHistory()
        try await CueEval.run("多日", expect: Days.expect, suite: .days, rig: {
            try await CueHostTests.Rig(
                brain: .current, cacheLifetime: Days.cacheLifetime, prepare: { try await history.write(into: $0) })
        }) { try await Days($0, history).play() }
    }
}

/// 剧本与判定。
@MainActor
private final class Days: EvalScript, Playable {
    static let expect = """
        已值两周班，逐件问起不同年纪的事：13 天前顺口说的考级日期、9 天前 CI 报告里的镜像版本、5 天前否掉的 S3 与理由、\
        2 天前答应的告诉他访问量、1 天前改成中文的提交信息；冷醒来换新后不重做、不重复问
        """
    /// 缓存时长缩短；他走开的时长比它长，回来就是冷醒来，中途若冒出别的醒来，他回来时离那次请求也已过了缓存时长，仍是冷醒来。
    static let cacheLifetime = Duration.seconds(20)
    static let away = Duration.seconds(40)
    /// 开跑前要静这么久：长于空闲合并的间隔（合并在空闲时醒来的方案，测试骨架里空闲 1 秒就请合并），有待合并的块它就在这段里醒；
    /// 又要远短于缓存时长：最后一次请求到那一轮做完还有几秒，静 15 秒第一问就冷了（实测）
    static let quiet = Duration.seconds(5)

    private let history: DaysHistory
    /// 记忆的样子：预置后、开跑前与每一步做完时有几条摘要、记忆视图几行（看合并发生在哪、合并后视图多大）
    private var snapshots: [(label: String, at: Date, summaries: Int, lines: Int)] = []
    /// 补记那段记忆的时刻：之后第一次换新、那次换新起第一次写摘要的那一轮单列
    private var notedAt: Date?

    init(_ eval: CueEval, _ history: DaysHistory) {
        self.history = history
        super.init(eval)
        sessions = [history.storage, history.weekly].compactMap(\.self)
    }

    func script() async throws -> [Check] {
        try await snapshot("预置")
        try await settleDown()
        try await snapshot("开跑前")
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
            try await site.deliver(pageShot("官网 2026 年 10 月周报", DaysScript.weeklyShot), title: "官网十月周报", rig: rig)
            try await site.settle(DaysScript.weekly, rig: rig)
        }
        try await overBudget()
        try await settleDown()
        await quietPeriod(Self.away)
        let parking = try await say("他：问车位（冷，有块要合）", "我车停在哪个车位来着？")
        await quietPeriod(Self.away)
        let wrap = try await say("他：问这几天的事（冷）", "这几天的事现在都怎么样了？")
        return try await judge(Points(
            date: date, image: image, s3: s3, why: why, csv: csv, language: language, report: report, parking: parking, wrap: wrap, storage: storage))
    }

    /// 他发消息触发冷换新、恰好有块要合：一口气补记 10 条记忆（Cue 记下的，第一条是后面要问的车位），记忆视图（开跑前 90 行，预算 96）超出预算、有块待合并。
    /// 合并在空闲时醒来的方案在随后等它静下来时合掉，他这句仍是冷换新；挪到换新那一轮的方案在他这句触发的冷换新里合。
    private func overBudget() async throws {
        notedAt = .now
        for line in DaysScript.notedLater { _ = try await rig.store.noteCueLine(line, source: .cue) }
        try await snapshot("补记 \(DaysScript.notedLater.count) 条后")
    }

    /// 开跑前等 Cue 静下来：没有在跑的轮，且之后静了 `quiet` 没有新的一轮。合并在空闲时醒来的方案（预置了 4 块待合并）在这段里合完；
    /// 合并挪到换新那一轮的方案没有这种醒来，刚启用那一轮做完、静 `quiet` 就开跑。
    private func settleDown() async throws {
        while true {
            try await eventually("Cue 没有在跑的轮", timeout: .seconds(300)) { self.eval.rounds.allSatisfy { $0.finishedAt != nil } }
            let count = eval.rounds.count
            await quietPeriod(Self.quiet)
            if eval.rounds.count == count, eval.rounds.allSatisfy({ $0.finishedAt != nil }) { break }
        }
    }

    override func step(_ label: String, on session: ScriptedSession?, _ act: () async throws -> Void) async throws -> Step {
        let step = try await super.step(label, on: session, act)
        try await snapshot(label)
        return step
    }

    private func snapshot(_ label: String) async throws {
        let memory = try await rig.store.cueMemory()
        snapshots.append((label, .now, memory.summaries.count, CueMemoryView(memory).entries.count))
    }

    /// 合并发生在哪几轮：摘要写下的时刻落在哪一轮（一轮可写几条），那一轮是不是新会话的第一轮（带了视图，`CueEval.opensSession`）、
    /// 在哪一步，那一步做完时视图几行。合并在空闲时醒来还是挪进换新那一轮，都按写下的摘要认。
    private func merges() async -> [[String: Any]] {
        let all = eval.rounds
        let made = ((try? await rig.store.cueMemory().summaries) ?? []).filter { $0.createdAt >= (all.first?.startedAt ?? .distantFuture) }
        let byRound = Dictionary(grouping: made) { summary in all.lastIndex { $0.startedAt <= summary.createdAt } ?? 0 }
        return byRound.keys.sorted().map { index in
            let round = all[index], at = byRound[index]!.map(\.createdAt).max()!
            return [
                "round": index, "wake": "\(round.wake)".prefix(40).description, "renewal": CueEval.opensSession(round), "summaries": byRound[index]!.count,
                "step": steps.first { $0.window?.contains(round.startedAt) == true }?.label
                    ?? steps.last { ($0.window?.upperBound ?? .distantFuture) < round.startedAt }.map { "「\($0.label)」之后" } ?? "开跑前",
                "viewLines": snapshots.first { $0.at >= at }?.lines ?? snapshots.last?.lines ?? 0,
            ]
        }
    }

    // MARK: 判定

    struct Points {
        let date, image, s3, why, csv, language, report, parking, wrap: Step
        let storage: ScriptedSession
    }

    private func judge(_ key: Points) async throws -> [Check] {
        for session in sessions { try await session.refresh(rig) }
        let s3Said = says([key.s3], to: key.storage)
        let reasons = try await replies(key.why).joined(separator: "\n")
        let csvTexts = CueEval.calls(in: rounds(key.csv), "task", ["add", "edit", "say", "start"]).map { Self.texts($0.args) }.joined(separator: "\n")
        let preference = csvTexts.contains(/中文/) ? "带了新的（中文）" : csvTexts.contains(/英文|English/) ? "带了旧的（英文）" : "没提"
        let told = try await self.told(key.report)
        let cold = [key.image, key.csv, key.parking, key.wrap]
        let renewed = cold.filter { step in eval.renewals.contains { step.window?.contains($0.startedAt) == true } }
        let after = steps.filter { ($0.window?.lowerBound ?? .distantFuture) >= (key.image.window?.lowerBound ?? .distantFuture) }
        let adds = after.flatMap { calls($0, "task", ["add"]) }.filter { CueEval.built($0.call) }
        let extra = adds.filter { ($0.args["title"] as? String)?.contains(/CSV|导出/) != true }
        let toHim = try await eval.said(since: key.date.window?.lowerBound).filter { $0.author == .known(.cue) }.map(\.text)
        let repeatedQuestions = toHim.filter { $0.contains(/？|\?/) }
        let askedTwice = repeatedQuestions.indices.contains { i in repeatedQuestions[(i + 1)...].contains { Self.similar($0, repeatedQuestions[i]) } }
        let resaid = self.resaid()
        return [
            try await recalled("13 天前顺口说的：考级是 11 月 18 号", key.date, fabricated: { $0.contains(/\d+ ?月 ?\d+|\d+ ?号|\d+\/\d+/) }) {
                $0.contains(/11 ?月 ?18|11\/18|11-18/)
            },
            try await recalled("9 天前报告里顺带的：镜像 node:20.11.1-bookworm", key.image, fabricated: { $0.contains(/node:?\s?\d|\d+\.\d+\.\d+/) }) {
                $0.contains("20.11.1")
            },
            Check(.memory, "5 天前否掉的：会话问迁不迁 S3，答留在 R2", s3Said.contains { $0.contains(/B|R2|不迁|留在/) } && !s3Said.contains { $0.trimmingCharacters(in: .whitespaces) == "A" }),
            Check(.memory, "5 天前否掉的理由：贵、团队没人熟 AWS（答出至少一条）", reasons.contains(/贵|成本|费用|AWS|不熟|没人熟/), note: reasons.isEmpty ? "（没回）" : ""),
            Check(.memory, "1 天前改的偏好：派活时带的是新的（中文提交信息）", preference.hasPrefix("带了新的"), note: "——\(preference)"),
            try await recalled("1 天前改的偏好：问起时答中文", key.language, fabricated: { $0.contains("英文") }) { $0.contains("中文") && !$0.contains(/现在.{0,6}英文|用英文写/) },
            try await recalled("补记后有块要合、他触发冷换新：问车位答 B2 层 117", key.parking, fabricated: { $0.contains(/[A-Z]?\d+ ?层|\d{2,3} ?号/) }) {
                $0.contains("B2") && $0.contains("117")
            },
            Check(.carry, "2 天前答应的：周报数据出来告诉他访问量 48,210", told.contains { $0.contains(/48,?210|4\.8 ?万|48210/) }),
            Check(.carry, "冷醒来换新了", renewed.count == cold.count, note: "（\(renewed.count)/\(cold.count) 次：\(renewed.map(\.label).joined(separator: "、"))）"),
            Check(.carry, "冷醒来后不重做：除导出 CSV 外没另建任务", extra.isEmpty,
                  note: extra.isEmpty ? "" : "（另建：\(extra.compactMap { $0.args["title"] as? String }.joined(separator: "、"))）"),
            Check(.carry, "不重复问他、不对同一会话重复说", !askedTwice && resaid.isEmpty),
            Check(.result, "问这几天的事：回了他、没派新活", try await reply(key.wrap) != nil && calls(key.wrap, "task", ["add", "start"]).isEmpty),
        ]
    }

    // MARK: 统计

    func summarize() async {
        let rounds = eval.rounds.filter { $0.wake != .enabled }
        let durations = rounds.compactMap { round in round.finishedAt.map { $0.timeIntervalSince(round.startedAt) } }.sorted()
        let median = durations.isEmpty ? "—" : seconds(durations[durations.count / 2])
        let usage = rig.brainDirectory.map(BrainUsage.rounds(in:)) ?? []
        let all = eval.rounds
        let merged = await merges()
        // 开销按轮对齐（大脑报的与记下的轮按先后对应）
        let cost = { (indices: [Int]) in indices.filter { $0 < usage.count }.map { usage[$0] }.reduce(BrainUsage(), +) }
        let total = usage.reduce(BrainUsage(), +)
        let renewals = eval.renewals
        let renewedAt = renewals.compactMap { round in steps.firstIndex { $0.window?.contains(round.startedAt) == true }.map { "第 \($0 + 1) 步「\(steps[$0].label)」" } }
        let cells = { (usage: BrainUsage) in usage.cells.replacingOccurrences(of: " | ", with: "、") }
        var lines = [
            "", "## 多日", "",
            "- 预置历史：对话 \(history.logged) 条、记忆 \(history.memoryLines) 行（\(history.pinned) 行一直记着）、做完的任务 \(history.doneTasks) 件",
            "- 醒来 \(rounds.count) 次（不含预热；剧本叫醒 \(steps.count) 次），换新 \(renewals.count) 次（大脑开了新的对话）"
                + (renewedAt.isEmpty ? "" : "，在" + renewedAt.joined(separator: "、")),
            "- 每轮用时中位 \(median)",
            "- 合计（含预热）：\(BrainUsage.header.replacingOccurrences(of: " | ", with: "、")) = \(cells(total))",
            "- 其中合并的轮（写了摘要的轮，第 \(merged.map { "\($0["round"]!)" }.joined(separator: "、")) 轮）：\(cells(cost(merged.map { $0["round"] as! Int })))",
            "- 合并 \(merged.count) 轮、写了 \(merged.reduce(0) { $0 + ($1["summaries"] as! Int) }) 条摘要："
                + merged.map { "第 \($0["round"]!) 轮（\(($0["renewal"] as! Bool) ? "新会话的第一轮" : "接着原会话")，\($0["step"]!)，\($0["summaries"]!) 条），之后视图 \($0["viewLines"]!) 行" }
                .joined(separator: "；"),
            "- 记忆视图行数（摘要条数）：" + snapshots.map { "\($0.label) \($0.lines)（\($0.summaries)）" }.joined(separator: " → "),
        ]
        eval.extra["merges"] = merged
        eval.extra["viewLines"] = snapshots.map { ["after": $0.label, "lines": $0.lines, "summaries": $0.summaries] }
        // 单列：补记以后第一次换新的那一轮，与那次换新起第一次写了摘要的那一轮（合并可能推到更后的换新）；同一轮只列一行。
        // 合并在空闲时醒来的方案在换新前就合完了，只有第一行
        let renewed = all.indices.first { all[$0].startedAt >= notedAt ?? .distantFuture && CueEval.opensSession(all[$0]) }
        let wrote = renewed.flatMap { first in merged.compactMap { $0["round"] as? Int }.first { $0 >= first } }
        var singled: [[String: Any]] = []
        for (label, index) in [("补记后第一次换新", renewed), ("补记后换新时写摘要的那一轮", wrote == renewed ? nil : wrote)] {
            guard let index else { continue }
            let round = all[index], used = cost([index]), took = round.finishedAt.map { $0.timeIntervalSince(round.startedAt) } ?? 0
            let summaries = merged.first { $0["round"] as? Int == index }?["summaries"] as? Int ?? 0
            let step = steps.first { $0.window?.contains(round.startedAt) == true }?.label ?? "步与步之间"
            lines.append("- \(label)（第 \(index) 轮，\(step)）：用时 \(seconds(took))，\(CueEval.opensSession(round) ? "新会话的第一轮" : "接着原会话")，写了 \(summaries) 条摘要；\(cells(used))")
            singled.append(used.json.merging(["label": label, "seconds": took, "renewal": CueEval.opensSession(round), "summaries": summaries]) { $1 })
        }
        eval.extra["rounds"] = singled
        eval.report = lines + stepTable()
    }
}
#endif
