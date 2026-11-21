#if os(macOS)
import CueStore
import Foundation
@testable import CuePad

enum CheckKind: String, CaseIterable {
    case result = "结果"
    case ask = "问"
    case interrupt = "打扰"
    case tool = "工具"
    case carry = "接续"
    case memory = "记忆"
}

struct Check {
    let kind: CheckKind
    let label: String
    let passed: Bool
    var note = ""
    var counted = true

    init(_ kind: CheckKind, _ label: String, _ passed: Bool, note: String = "", counted: Bool = true) {
        (self.kind, self.label, self.passed, self.note, self.counted) = (kind, label, passed, note, counted)
    }

    var shown: String { "〔\(kind.rawValue)〕\(label)\(note)\(counted ? "" : "〔不计〕")" }
    var failed: Bool { counted && !passed }
}

enum EvalSuite: String {
    case short = "短场景"
    case long = "长程"
    case days = "多日"
    case bench = "记忆基准"
}

enum CallFailure: String, CaseIterable {
    case invalid = "参数校验退回"
    case missing = "对象找不到"
    case noTool = "没有这个工具"
    case other = "其他"

    init(_ result: String) {
        if result.contains(/Tool \S+ not found|[Uu]nknown tool|没有这个工具/) {
            self = .noTool
        } else if result.contains(/找不到|没有记忆|没有项目|对上了 \d+ 个|有 \d+ 个任务叫/) {
            self = .missing
        } else if result.contains(
            /只能是|不能为空|要给|要写|至少给|上限|不超过|宽 \d+|写 ISO|是数组|只跟着|不写 body|写 1–|没有 \w+：可用|不用改回|只能加在|已经过了|要是其中之一|正在做「|[Ii]nvalid|[Rr]equired|[Vv]alidation/
        ) {
            self = .invalid
        } else {
            self = .other
        }
    }
}

extension CueEval {
    func metrics() async -> [String: Any] {
        let counted = rounds.filter { $0.wake != .enabled }
        let calls = counted.flatMap(\.calls)
        let tells = Self.calls(in: counted, "tell").filter { !$0.call.failed }
        let asks = tells.filter { $0.args["ask"] != nil }
        let spoken = tells.filter { $0.args["ask"] == nil && $0.args["withdraw"] == nil && $0.args["restore"] == nil && ($0.args["text"] as? String)?.isEmpty == false }
        let leaves = Self.calls(in: counted, "task", ["leave"]).filter { !$0.call.failed }
        let conversation = (try? await rig.store.cueMessages(limit: 5000)) ?? []
        let messages = conversation.filter { $0.author == .known(.cue) && $0.createdAt >= (counted.first?.startedAt ?? .distantFuture) }
        let his = conversation.filter { $0.author == .known(.you) }
        let toldTexts = Set(spoken.compactMap { $0.args["text"] as? String })
        let answering = counted.filter { $0.wake == .message }
        let isReply = { (message: CueMessage) in
            answering.contains { round in message.createdAt >= round.startedAt && message.createdAt <= (round.finishedAt ?? .distantFuture).addingTimeInterval(0.001) }
        }
        let otherPushes = messages.filter { $0.urgent && $0.choices == nil && !toldTexts.contains($0.text) && !isReply($0) }
        let replies = messages.filter { $0.choices == nil && $0.taskID == nil && !toldTexts.contains($0.text) && isReply($0) }
        let asksProgress = { (reply: CueMessage) in
            let round = answering.first { reply.createdAt >= $0.startedAt && reply.createdAt <= ($0.finishedAt ?? .distantFuture) }
            return round.flatMap { round in his.last { $0.createdAt <= round.startedAt } }?.text.contains(Self.progressQuestion) == true
        }
        let overlong = replies.count { reply in
            let items = reply.text.split(separator: "\n").count { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return sentences(reply.text) > (asksProgress(reply) ? max(Self.sentenceLimit, items) : Self.sentenceLimit)
        } + toldTexts.count { sentences($0) > Self.sentenceLimit }
        var failed = Dictionary(uniqueKeysWithValues: CallFailure.allCases.map { ($0.rawValue, 0) })
        for call in calls where call.failed { failed[CallFailure(call.result ?? "").rawValue, default: 0] += 1 }
        let usage = (rig.brainDirectory.map(BrainUsage.rounds(in:)) ?? []).reduce(BrainUsage(), +)
        let dreams = rig.brainDirectory.map(BrainUsage.dreams(in:)) ?? []
        let summaries = ((try? await rig.store.cueMemory().summaries) ?? []).filter { $0.createdAt >= (rounds.first?.startedAt ?? .distantFuture) }
        let background = summaries.count { summary in dreams.contains { $0.contains(summary.createdAt) } }
        let urgent = spoken.count { $0.args["urgent"] as? Bool == true }
        return [
            "wakes": counted.count, "calls": calls.count, "failed": failed, "asks": asks.count,
            "interrupts": ["tell": spoken.count, "urgent": urgent, "leave": leaves.count, "other": otherPushes.count, "total": spoken.count + leaves.count + otherPushes.count],
            "overlong": overlong, "renewals": renewals.count,
            "usage": usage.json,
            "dream": [
                "count": dreams.count, "seconds": dreams.reduce(0) { $0 + $1.finished.timeIntervalSince($1.started) },
                "usage": dreams.map(\.usage).reduce(BrainUsage(), +).json,
            ],
            "merges": Self.calls(in: counted, "memory", ["merge"]).count,
            "summaries": ["background": background, "rounds": summaries.count - background],
            "roundSeconds": counted.compactMap { round in round.finishedAt.map { $0.timeIntervalSince(round.startedAt) } },
        ]
    }

    static let sentenceLimit = 2
    static let progressQuestion = /做到哪|到哪了|进展|进度|怎么样了|开工了吗/

    func writeScore(_ name: String, suite: EvalSuite, checks: [Check], failure: (any Error)?, prompt: String, to output: URL) async throws {
        guard suite != .bench else { return }
        let wide = prompt.unicodeScalars.count { !$0.isASCII }, ascii = prompt.unicodeScalars.count { $0.isASCII }
        var score: [String: Any] = [
            "name": name, "suite": suite.rawValue, "brain": EvalBrain.current.label, "error": failure.map { "\($0)" } ?? NSNull(),
            "checks": checks.map { ["kind": $0.kind.rawValue, "label": $0.label, "passed": $0.passed, "counted": $0.counted] },
            "metrics": await metrics(), "extra": extra, "prompt": ["tokens": wide + ascii / 4],
        ]
        if let directory = rig.brainDirectory, EvalBrain.current.runtime == .pi, EvalBrain.current.model.hasPrefix("anthropic/") {
            let billing = BrainUsage.billing(in: directory)
            score["billing"] = ["requests": billing.requests, "marked": billing.marked]
        }
        let data = try JSONSerialization.data(withJSONObject: score, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appending(path: "\(name).score.json"))
    }
}
#endif
