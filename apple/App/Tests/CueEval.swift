#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import CueText
import Foundation
import Testing
@testable import CuePad

/// 一件 Cue 开过工、正在做的任务：开工时送进会话的第一句记在发送记录里（会话里那句因此认作 Cue 说的，不是"他说的"），
/// 会话是本机开着的假扩展（Cue 对它说话、作答都送得到）。
struct Working {
    let task: Card
    let session: FakeExtension
    let prompt: PiChatMessage
    var id: String { session.sessionID }
}

/// 一个场景的现场：Rig、叫醒 Cue 的时刻，以及被叫醒的那一轮。
@MainActor
final class CueEval {
    let rig: CueHostTests.Rig
    private let output: URL
    private var start = Date.distantFuture
    /// 第一次叫醒的时刻：此后的每一轮都写进现场
    private var begin: Date?
    /// 场景里的每一轮（含预热）按 id 留着：运行情况只留最近 `CueKeeper.roundsKept` 轮
    private var archive: [Int: CueRound] = [:]
    /// 场景自己要写进 .md 的段落（长程、多日的统计）
    var report: [String] = []
    /// 场景自己要写进成绩单的（长程的换新方式、多日的记忆合并），JSON 能表示的值
    var extra: [String: Any] = [:]

    private init(_ rig: CueHostTests.Rig, output: URL) {
        self.rig = rig
        self.output = output
    }

    /// 起 Rig、等刚启用那一轮做完，跑 `body`（摆状态、叫醒、判定）；不论成败都把现场写完、停掉大脑，再报没过的判定。
    static func run(
        _ name: String, expect: String, suite: EvalSuite = .short, output: URL = evalOutput,
        rig makeRig: () async throws -> CueHostTests.Rig = { try await CueHostTests.Rig(brain: .current) }, _ body: (CueEval) async throws -> [Check]
    ) async throws {
        let eval = CueEval(try await makeRig(), output: output)
        var checks: [Check] = [], failure: (any Error)?
        do {
            try await eventually("刚启用那一轮做完", timeout: .seconds(300)) { eval.rig.rounds.contains { $0.wake == .enabled && $0.finishedAt != nil } }
            checks = try await body(eval)
            checks.append(try await eval.showsNoIDs())
        } catch {
            failure = error
        }
        await eval.write(name, expect: expect, suite: suite, checks: checks, failure: failure)
        await eval.rig.stop()
        #expect(eval.rig.brainPIDs.isEmpty, "大脑停掉了")
        for check in checks where check.failed { Issue.record("\(name)：\(check.shown)") }
        if let failure { throw failure }
    }

    /// 叫醒 Cue（你说一句，或会话有动静），等被叫醒的那一轮做完。
    func trigger(_ wake: () async throws -> Void) async throws {
        mark()
        try await wake()
        try await eventually("Cue 做完被叫醒的那一轮", timeout: .seconds(420)) { self.round?.finishedAt != nil }
    }

    /// 叫醒 Cue，等它把这次引起的都做完才返回：至少一轮做完、没有在跑的、歇着、话都交了，
    /// 再稳住几秒没有新的一轮（空闲合并记忆这类紧跟着的醒来）。返回这次醒来的时段；没叫醒（等不到一轮开始）为 nil。
    func settle(_ wake: () async throws -> Void) async throws -> ClosedRange<Date>? {
        let from = mark()
        try await wake()
        do {
            try await eventually("Cue 醒来", timeout: .seconds(120)) { self.rig.rounds.contains { $0.startedAt >= from } }
        } catch {
            return nil
        }
        while true {
            try await eventually("Cue 做完这次醒来引起的", timeout: .seconds(900)) { try await self.idle(since: from) }
            let count = rig.rounds.count
            await quietPeriod(.seconds(3))
            if rig.rounds.count == count, try await idle(since: from) { break }
        }
        _ = rounds
        return from...Date.now
    }

    @discardableResult
    private func mark() -> Date {
        start = .now
        if begin == nil { begin = start }
        return start
    }

    private func idle(since from: Date) async throws -> Bool {
        let rounds = rig.rounds
        guard rounds.contains(where: { $0.startedAt >= from && $0.finishedAt != nil }), rounds.allSatisfy({ $0.finishedAt != nil }) else { return false }
        guard try await rig.store.cueState()?.state == .known(.settled) else { return false }
        return try await rig.store.cueMessagesToDeliver().isEmpty
    }

    /// 换新后的第一轮：大脑开了新的对话的那一轮（`BrainUsage.renewed`，从大脑的输出里数：新进程，或 Pi 回应了 new_session）。
    /// 不看上下文用量：缓存过期时开新会话、接上的视图可能比原来的上下文还长。大脑报的轮与记下的轮按先后对齐。
    var renewals: [CueRound] {
        let rounds = rounds
        return (rig.brainDirectory.map(BrainUsage.renewed(in:)) ?? []).filter { $0 < rounds.count }.map { rounds[$0] }
    }

    var round: CueRound? { rig.rounds.first { $0.startedAt >= start } }

    /// 这一轮是不是新会话的第一轮：发给大脑的带着视图（新会话从记忆视图与对话视图接上，刚启用那一轮也是）
    static func opensSession(_ round: CueRound) -> Bool { round.sent.contains { $0.contains("<view>") || $0.contains("<memory>") } }

    /// 场景到此的每一轮（含预热），从早到晚
    var rounds: [CueRound] {
        for round in rig.rounds { archive[round.id] = round }
        return archive.values.sorted { $0.startedAt < $1.startedAt }
    }

    /// 那一轮里调的 `tool`（只看 `action` 这一种）与它的参数
    func calls(_ tool: String, _ action: String? = nil) -> [(call: CueToolCall, args: [String: Any])] {
        Self.calls(in: round.map { [$0] } ?? [], tool, action.map { [$0] } ?? [])
    }

    /// `rounds` 里调的 `tool`（`actions` 为空时不论动作）与它的参数
    static func calls(in rounds: [CueRound], _ tool: String, _ actions: Set<String> = []) -> [(call: CueToolCall, args: [String: Any])] {
        rounds.flatMap(\.calls).compactMap { call in
            let args = (try? JSONSerialization.jsonObject(with: Data(call.arguments.utf8))) as? [String: Any] ?? [:]
            guard call.name == tool, actions.isEmpty || (args["action"] as? String).map(actions.contains) == true else { return nil }
            return (call, args)
        }
    }

    /// 工具参数指的是不是这个会话（判定认"对哪个会话"都经这里）：task 写这件任务（编号前缀或标题）；session 写会话（编号前缀或会话名），
    /// 也认这件任务的编号前缀或标题（指那件任务在做的会话）。
    static func refers(_ args: [String: Any], to session: String, title: String, cards: [Card]) -> Bool {
        let isCard = { (ref: String) in cards.contains { $0.id.uuidString.lowercased().hasPrefix(ref) || $0.heading.lowercased() == ref } }
        if let ref = (args["task"] as? String)?.lowercased(), !ref.isEmpty { return isCard(ref) }
        guard let ref = (args["session"] as? String)?.lowercased(), !ref.isEmpty else { return false }
        return session.lowercased().hasPrefix(ref) || title.lowercased() == ref || isCard(ref)
    }

    /// 这次 add 真建了一件任务：成了、且工具没认出同名没做完的那件（"已有没做完的…，没再建"）
    static func built(_ call: CueToolCall) -> Bool { !call.failed && call.result?.hasPrefix("已有没做完的") != true }

    /// 叫醒之后 Cue 写的消息（tell、回复、动态、完成的结果）
    func said(since: Date? = nil) async throws -> [CueMessage] {
        let from = since ?? start
        return try await rig.store.cueMessages(limit: 2000).filter { $0.createdAt >= from && $0.author != .known(.you) && !$0.text.isEmpty }
    }

    /// 他看得到的字（消息与记下的记忆）没抄信封、工具结果里括号中的编号：每个场景都判。
    func showsNoIDs() async throws -> Check {
        let seen = rig.rounds.filter { $0.startedAt >= start }.flatMap { $0.sent + $0.calls.compactMap(\.result) }
        let ids = Set(seen.flatMap { $0.matches(of: /（((?:s-)?[0-9a-f]{6,8})）/).map { String($0.1) } })
        let written = try await said().map(\.text) + calls("memory", "note").compactMap { $0.args["text"] as? String }
        return Check(.tool, "他看得到的字里没有编号", !written.contains { text in ids.contains { text.contains($0) } })
    }

    func reply(since: Date? = nil) async throws -> CueMessage? {
        try await said(since: since).last { $0.author == .known(.cue) && $0.choices == nil && $0.taskID == nil }
    }

    private func write(_ name: String, expect: String, suite: EvalSuite, checks: [Check], failure: (any Error)?) async {
        let passed = failure == nil && !checks.isEmpty && !checks.contains(where: \.failed)
        let verdict = failure != nil ? "出错" : passed ? "通过" : "不通过"
        let round = round, rounds = rounds
        let usage = rig.brainDirectory.map(BrainUsage.rounds(in:)) ?? []
        let total = usage.reduce(BrainUsage(), +)
        let elapsed = round?.finishedAt.map { seconds($0.timeIntervalSince(round!.startedAt)) } ?? "—"
        let context = (round ?? rounds.last)?.context.map(String.init) ?? "—"
        var lines = [
            "# \(name)", "", "期望：\(expect)", "", "大脑：\(EvalBrain.current.label)", "",
            "## 判定：\(verdict)", "",
        ]
        lines += checks.map { "- [\($0.passed ? "x" : " ")] \($0.shown)" }
        if let failure { lines += ["", "出错：\(failure)"] }
        lines += report
        lines += ["", "## 用时与上下文", "", "- 被叫醒的这一轮：\(elapsed)，结束时上下文 \(context) token"]
        if let greeting = rounds.first(where: { $0.wake == .enabled }) {
            let took = greeting.finishedAt.map { seconds($0.timeIntervalSince(greeting.startedAt)) } ?? "没做完"
            lines.append("- 刚启用那一轮（预热，不评）：\(took)，上下文 \(greeting.context.map(String.init) ?? "—")，工具 \(greeting.calls.map(\.name).joined(separator: "、"))")
        }
        lines += ["", "## 开销（每轮，含预热；Claude Code 每轮 result 事件报的）", ""]
        if usage.count != rounds.count {
            lines += ["大脑报了 \(usage.count) 轮，记下的轮有 \(rounds.count) 轮，下表按先后对齐，合计以大脑报的为准。", ""]
        }
        if let directory = rig.brainDirectory, EvalBrain.current.runtime == .pi {
            let billing = BrainUsage.billing(in: directory)
            lines += [
                "计费标识：\(billing.marked)/\(billing.requests) 次模型请求的系统提示首块是 Claude 订阅的计费标识，user-agent：\(billing.agents.sorted().joined(separator: "、"))。", "",
            ]
        }
        lines += ["| 轮 | 醒来 | 用时 | 上下文 | \(BrainUsage.header) |", "| --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
        for index in 0..<max(usage.count, rounds.count) {
            let round = index < rounds.count ? rounds[index] : nil
            let took = round?.finishedAt.map { seconds($0.timeIntervalSince(round!.startedAt)) } ?? "—"
            lines.append("| \(index) | \(round.map { "\($0.wake)" } ?? "—") | \(took) | \(round?.context.map(String.init) ?? "—") | \(index < usage.count ? usage[index].cells : "— | — | — | — | —") |")
        }
        lines.append("| 合计 | | | | \(total.cells) |")
        for (index, round) in rounds.filter({ $0.startedAt >= begin ?? start }).enumerated() {
            let setup = round.startedAt < start ? "（铺垫）" : ""
            lines += ["", "## 第 \(index + 1) 轮（醒来：\(round.wake)）\(setup)\(round.finishedAt == nil ? "（写下时还没做完）" : "")", "", "### 发给大脑的"]
            lines += round.sent.flatMap { ["", "```text", $0, "```"] }
            lines += ["", "### 工具调用（\(round.calls.count)）"]
            for (number, call) in round.calls.enumerated() {
                let took = call.finishedAt.map { seconds($0.timeIntervalSince(call.startedAt)) } ?? "没做完"
                lines += ["", "\(number + 1). `\(call.name)` · \(took)\(call.failed ? " · 出错" : "")", "", "```json", call.arguments, "```", "", "```text", call.result ?? "", "```"]
            }
            if let failed = round.failure { lines += ["", "这一轮出错：\(failed)"] }
        }
        lines += ["", "## Cue 写的消息"]
        for message in (try? await said(since: begin)) ?? [] {
            var head = "- **\(message.author.rawValue)**"
            if let choices = message.choices { head += "（等你：\(choices.joined(separator: " / "))）" }
            if message.taskID != nil { head += "（关联任务）" }
            lines += ["", head, "", message.text.split(separator: "\n", omittingEmptySubsequences: false).map { "  > \($0)" }.joined(separator: "\n")]
        }
        do {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try lines.joined(separator: "\n").appending("\n").write(to: output.appending(path: "\(name).md"), atomically: true, encoding: .utf8)
            let prompt = CuePrompt.system(name: CueProfile.defaultName, memory: CueMemoryView(try await rig.store.cueMemory()), agents: [], runtime: EvalBrain.current.runtime)
            try prompt.write(to: output.appending(path: "system-prompt.md"), atomically: true, encoding: .utf8)
            try await writeScore(name, suite: suite, checks: checks, failure: failure, prompt: prompt, to: output)
            // 资料库留一份，看这一场在 Cue 页上的样子（docs/verify.md「Cue 评测」）
            let library = output.appending(path: "\(name).library", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: library)
            try FileManager.default.copyItem(at: rig.app.databaseURL.deletingLastPathComponent(), to: library)
        } catch {
            Issue.record("评测输出没写成：\(error)")
        }
    }
}

func seconds(_ interval: TimeInterval) -> String { String(format: "%.1fs", interval) }
#endif
