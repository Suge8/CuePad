#if os(macOS)
import CueAgent
@testable import CueStore
import Foundation
import Testing
@testable import CuePad

/// 用 LongMemEval（longmemeval_s cleaned）给 Cue 的长期记忆打分：改提示词、recall 前后各跑一遍比分数。跑法见 docs/verify.md「LongMemEval」。
/// 每题一个隔离库：启用 Cue 之前把它的历史会话按原时刻写成 Cue 的对话（用户的话是"他"的、已交给 Cue，助手的话是 Cue 的回复）；
/// 信封上的此刻定在提问时刻（`CueTiming.clock`），别的时间规则照真实时钟。等刚启用那一轮做完，把问题作为他的话交给 Cue，收下这一轮 Cue 对他说的话。
/// 题目由 `apple/scripts/lme.py sample` 抽好（`CUEPAD_LME_DATA`），每题写一个 <输出>/<题号>.json（回复、用时、开销、recall 的查询）
/// 与 CueEval 的 .md；已有 .json 的跳过，中断后重跑接着做。判分与报告由 `lme.py judge` 做。
@Suite(.enabled(if: evalEnvironment["CUEPAD_LME_DATA"] != nil, "CUEPAD_LME_DATA 给了题目才跑"), .timeLimit(.minutes(1000)))
struct CueEvalLMETests {
    @Test func longMemEval() async throws {
        let questions = try LMEQuestion.load(URL(filePath: evalEnvironment["CUEPAD_LME_DATA"]!))
        let only = evalEnvironment["CUEPAD_LME_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        let lanes = Int(evalEnvironment["CUEPAD_LME_LANES"] ?? "") ?? 8
        let jobs = questions.filter { (only?.contains($0.id) ?? true) && !FileManager.default.fileExists(atPath: Self.result($0.id).path) }
        await withTaskGroup(of: Void.self) { group in
            var pending = jobs.makeIterator()
            for _ in 0..<lanes {
                guard let question = pending.next() else { break }
                group.addTask { await Self.ask(question) }
            }
            for await _ in group {
                guard let question = pending.next() else { continue }
                group.addTask { await Self.ask(question) }
            }
        }
    }

    /// 不巡视：历史停在几年前，按真实时钟算他早就"很久没说话"，刚启用完就会巡视、把问题并进那一轮
    private static let never = Duration.seconds(100 * 365 * 86400)

    private static let output = URL(filePath: evalEnvironment["CUEPAD_CUE_EVAL_OUT"] ?? "/tmp/cue-eval/lme", directoryHint: .isDirectory)

    private static func result(_ id: String) -> URL { output.appending(path: "\(id).json") }

    @MainActor
    private static func ask(_ question: LMEQuestion) async {
        let brain = EvalBrain.current, asked = question.asked
        do {
            try await CueEval.run(
                question.id, expect: "LongMemEval \(question.type)（\(question.date)）：\(question.question) → \(question.answer)",
                output: output,
                rig: {
                    try await CueHostTests.Rig(
                        brain: brain, patrolAfter: Self.never, clock: { asked }, prepare: { try await $0.store.seed(question.log) })
                }
            ) { eval in
                // 有几题的历史里有晚于提问时刻的会话（官方也照样给）：问题记在它们之后，排进 Cue 订阅的最近对话里才叫得醒它
                let at = max(asked, (question.log.last?.at ?? asked) + 1)
                try await eval.trigger { try await eval.rig.store.say(question.question, at: at) }
                let round = try #require(eval.round)
                let replies = try await eval.said().filter { $0.author == .known(.cue) }.map(\.text)
                try write(question, eval: eval, round: round, replies: replies)
                return [Check("回了他", !replies.isEmpty)]
            }
        } catch {
            Issue.record("\(question.id)：\(error)")
        }
    }

    @MainActor
    private static func write(_ question: LMEQuestion, eval: CueEval, round: CueRound, replies: [String]) throws {
        let rounds = eval.rounds
        let usage = eval.rig.brainDirectory.map(BrainUsage.rounds(in:)) ?? []
        let index = rounds.firstIndex { $0.id == round.id } ?? rounds.count
        func cells(_ usage: BrainUsage) -> [String: Any] {
            ["input": usage.input, "cacheRead": usage.cacheRead, "cacheWrite": usage.cacheWrite, "output": usage.output, "cost": usage.cost]
        }
        let record: [String: Any] = [
            "id": question.id, "type": question.type, "brain": EvalBrain.current.label, "hypothesis": replies.joined(separator: "\n\n"),
            "elapsed": round.finishedAt.map { $0.timeIntervalSince(round.startedAt) } ?? 0,
            "usage": cells(index < usage.count ? usage[index] : BrainUsage()), "total": cells(usage.reduce(BrainUsage(), +)),
            "recalls": CueEval.calls(in: [round], "memory", ["recall"]).filter { !$0.call.failed }.compactMap { $0.args["query"] as? String },
            "calls": round.calls.map(\.name), "context": round.context ?? 0,
        ]
        let file = result(question.id)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: file)
    }
}

extension CueStore {
    /// 他在 `at` 说了一句（问题记在提问时刻：recall 搜得到这句，时刻要与信封上的此刻一致，不能是真实的今天）。
    func say(_ text: String, at: Date) throws {
        try write { _ = try insertCueMessage(.you, text: text, at: at) }
    }
}

/// 一道题（`lme.py sample` 写的一行）：历史会话已按时刻排好、一句一条（他的或 Cue 的），提问时刻是 epoch 秒。
nonisolated struct LMEQuestion: Decodable, Sendable {
    let id, type, question, answer, date: String
    let asked: Date
    let log: [Seeded]

    private enum Keys: String, CodingKey { case id, type, question, answer, date, asked, log }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        (id, type, question, answer, date) = try (
            c.decode(String.self, forKey: .id), c.decode(String.self, forKey: .type), c.decode(String.self, forKey: .question),
            c.decode(String.self, forKey: .answer), c.decode(String.self, forKey: .date))
        asked = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .asked))
        var rows = try c.nestedUnkeyedContainer(forKey: .log), log: [Seeded] = []
        while !rows.isAtEnd {
            var row = try rows.nestedUnkeyedContainer()
            let author = try row.decode(String.self) == "you" ? CueAuthor.you : .cue
            let at = Date(timeIntervalSince1970: try row.decode(Double.self))
            log.append(Seeded(author, try row.decode(String.self), at))
        }
        self.log = log
    }

    static func load(_ file: URL) throws -> [LMEQuestion] {
        try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map { try JSONDecoder().decode(LMEQuestion.self, from: Data($0.utf8)) }
    }
}
#endif
