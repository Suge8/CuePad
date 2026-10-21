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
/// 先给 Cue 空闲合并记忆的机会（合并的开销单列），再逐件问起；缓存时长缩短，场景里插几段静止模拟隔了一阵才回来（冷醒来）。跑法见 docs/verify.md「Cue 评测」。
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
    /// 开跑前至多等这么多次合并醒来：记忆预置成正好 4 块待合并，刚启用那一轮它若又记下几条，多出的块也在这里等
    static let merges = 6

    private let history: DaysHistory
    private var mergeRounds: [CueRound] = []
    /// 记忆的样子：预置后、开跑前合并后与每一步做完时有几条摘要、记忆视图几行（看合并发生在哪、合并后视图多大）
    private var snapshots: [(label: String, at: Date, summaries: Int, lines: Int)] = []

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
        try await snapshot("预置")
        try await letItMerge()
        try await snapshot("开跑前合并后")
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
        await quietPeriod(Self.away)
        let wrap = try await say("他：问这几天的事（冷）", "这几天的事现在都怎么样了？")
        return try await judge(Points(date: date, image: image, s3: s3, why: why, csv: csv, language: language, report: report, wrap: wrap, storage: storage))
    }

    /// 开跑前给它空闲合并记忆的机会：等到没有待合并的块，或合并醒来满 `merges` 次。
    private func letItMerge() async throws {
        let from = Date.now
        try? await eventually("记忆合并完", timeout: .seconds(Double(Self.merges) * 40 + 120)) {
            let done = self.eval.rounds.filter { $0.startedAt >= from && Self.isMerge($0) }
            return (try await self.pending() == 0 || done.count >= Self.merges) && done.allSatisfy { $0.finishedAt != nil } && self.eval.rounds.allSatisfy { $0.finishedAt != nil }
        }
        mergeRounds = eval.rounds.filter { $0.startedAt >= from && Self.isMerge($0) }
        notes.append("开跑前合并醒来 \(mergeRounds.count) 次，还剩 \(try await pending()) 块待合并")
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

    /// 合并发生在哪几轮：摘要写下的时刻落在哪一轮（一轮可写几条），那一轮是不是换新的一轮、在哪一步，那一步做完时视图几行
    private func merges() async -> [[String: Any]] {
        let all = eval.rounds, renewed = Set(eval.renewals.map(\.id))
        let made = ((try? await rig.store.cueMemory().summaries) ?? []).filter { $0.createdAt >= (all.first?.startedAt ?? .distantFuture) }
        let byRound = Dictionary(grouping: made) { summary in all.lastIndex { $0.startedAt <= summary.createdAt } ?? 0 }
        return byRound.keys.sorted().map { index in
            let round = all[index], at = byRound[index]!.map(\.createdAt).max()!
            return [
                "round": index, "wake": "\(round.wake)".prefix(40).description, "renewal": renewed.contains(round.id), "summaries": byRound[index]!.count,
                "step": steps.first { $0.window?.contains(round.startedAt) == true }?.label ?? "开跑前",
                "viewLines": snapshots.first { $0.at >= at }?.lines ?? snapshots.last?.lines ?? 0,
            ]
        }
    }

    /// 记忆树上待合并的块
    private func pending() async throws -> Int { CueMemoryView(try await rig.store.cueMemory()).merges.count }

    /// 合并的醒来：请合并的话里有这句
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
            Check(.memory, "5 天前否掉的：会话问迁不迁 S3，答留在 R2", s3Said.contains { $0.contains(/B|R2|不迁|留在/) } && !s3Said.contains { $0.trimmingCharacters(in: .whitespaces) == "A" }),
            Check(.memory, "5 天前否掉的理由：贵、团队没人熟 AWS（答出至少一条）", reasons.contains(/贵|成本|费用|AWS|不熟|没人熟/), note: reasons.isEmpty ? "（没回）" : ""),
            Check(.memory, "1 天前改的偏好：派活时带的是新的（中文提交信息）", preference.hasPrefix("带了新的"), note: "——\(preference)"),
            try await recalled("1 天前改的偏好：问起时答中文", key.language, fabricated: { $0.contains("英文") }) { $0.contains("中文") && !$0.contains(/现在.{0,6}英文|用英文写/) },
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
        let merged = await merges()
        lines.append("- 记忆合并 \(merged.count) 次（写了 \(merged.reduce(0) { $0 + ($1["summaries"] as! Int) }) 条摘要）"
            + merged.map { "；第 \($0["round"]!) 轮（\(($0["renewal"] as! Bool) ? "换新的一轮" : "没换新")，\($0["step"]!)），之后视图 \($0["viewLines"]!) 行" }.joined())
        lines.append("- 记忆视图行数（摘要条数）：" + snapshots.map { "\($0.label) \($0.lines)（\($0.summaries)）" }.joined(separator: " → "))
        eval.extra["merges"] = merged
        eval.extra["viewLines"] = snapshots.map { ["after": $0.label, "lines": $0.lines, "summaries": $0.summaries] }
        lines += notes.map { "- \($0)" }
        lines += ["", "| 步 | 叫醒的事 | 轮数 | 工具调用 |", "| --- | --- | --- | --- |"]
        for (index, step) in steps.enumerated() {
            let rounds = self.rounds(step)
            lines.append("| \(index + 1) | \(step.label) | \(rounds.count) | \(rounds.flatMap(\.calls).map(\.name).joined(separator: "、")) |")
        }
        eval.report = lines
    }
}
#endif
