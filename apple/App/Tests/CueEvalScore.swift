#if os(macOS)
import CueStore
import Foundation
@testable import CuePad

/// 判定的类别：成绩单（`apple/scripts/score.py`）按它汇总通过数。定义见 docs/verify.md「Cue 评测」。
enum CheckKind: String, CaseIterable {
    /// 事做对没
    case result = "结果"
    /// 该问的问了，不该问的没问
    case ask = "问"
    /// 推送、tell、urgent 是否必要
    case interrupt = "打扰"
    /// 参数填对、没白调
    case tool = "工具"
    /// 换新后接得上
    case carry = "接续"
    /// 以前的事答对
    case memory = "记忆"
}

/// 一条判定。`label` 是它的身份（成绩单按它比两组之间的翻转），这一遍才有的细节写进 `note`；
/// `counted` 为假是这一遍没测到（前提没出现，如那件事没收尾、埋点与考题之间没换新），不计入通过数。
struct Check {
    let kind: CheckKind
    let label: String
    let passed: Bool
    var note = ""
    var counted = true

    init(_ kind: CheckKind, _ label: String, _ passed: Bool, note: String = "", counted: Bool = true) {
        (self.kind, self.label, self.passed, self.note, self.counted) = (kind, label, passed, note, counted)
    }

    /// 写进 .md 的那一行
    var shown: String { "〔\(kind.rawValue)〕\(label)\(note)\(counted ? "" : "〔不计〕")" }
    var failed: Bool { counted && !passed }
}

/// 评测分哪一套：成绩单按套汇总（短场景一遍是目录里各场景的合计）。
enum EvalSuite: String {
    case short = "短场景"
    case long = "长程"
    case days = "多日"
    case bench = "记忆基准"
}

/// 出错的工具调用按原因分：参数校验退回、对象找不到（含对上了好几个）、没有这个工具、其他（会话没送到、读的文件不在等）。
/// 认法是对工具结果的原文做正则：跟着 CueTools 与 CueStoreError 的报错措辞走，那边改了措辞这里要一起改（工具结果不另带机器可读的类别）。
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
    /// 这一遍（一个场景）的量化指标；轮不含刚启用那一轮（预热），开销含预热（同 .md 的合计）。
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
        // 消息的时刻入库时四舍五入到毫秒（Date.stamp）：回复写下后不到半毫秒这一轮就收尾，回复的时刻会进位到收尾之后，所以收尾放宽 1 毫秒
        let isReply = { (message: CueMessage) in
            answering.contains { round in message.createdAt >= round.startedAt && message.createdAt <= (round.finishedAt ?? .distantFuture).addingTimeInterval(0.001) }
        }
        // 他会收到推送、又不是 tell 与回他的话的（出错、起不来这类管理器写的 urgent）
        let otherPushes = messages.filter { $0.urgent && $0.choices == nil && !toldTexts.contains($0.text) && !isReply($0) }
        let replies = messages.filter { $0.choices == nil && $0.taskID == nil && !toldTexts.contains($0.text) && isReply($0) }
        // 他问进展的那一轮：系统提示要的是逐件一句，不受两句的限——上限是两句与件数（非空的行）里大的那个
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
        let urgent = spoken.count { $0.args["urgent"] as? Bool == true }
        return [
            "wakes": counted.count, "calls": calls.count, "failed": failed, "asks": asks.count,
            "interrupts": ["tell": spoken.count, "urgent": urgent, "leave": leaves.count, "other": otherPushes.count, "total": spoken.count + leaves.count + otherPushes.count],
            "overlong": overlong, "renewals": renewals.count,
            "usage": usage.json,
            "roundSeconds": counted.compactMap { round in round.finishedAt.map { $0.timeIntervalSince(round.startedAt) } },
        ]
    }

    /// 回他的话与 tell 至多几句（系统提示：回复至多两句，tell 至多两句）
    static let sentenceLimit = 2
    /// 他在问进展（系统提示："问进展时逐件一句，不受这个限"）：问进展的几种常见说法
    static let progressQuestion = /做到哪|到哪了|进展|进度|怎么样了|开工了吗/

    /// 成绩单读的那一份：判定（类别、身份、过没过、计不计）与指标，写在 `<场景>.score.json`。
    /// `prompt` 是这一遍的系统提示：记下长度与估算的 token（非 ASCII 每字算 1、ASCII 每 4 字符算 1；工具说明另算）。
    /// Pi 当大脑时另记模型请求带没带 Claude 订阅的计费标识（`EvalBrain` 的只读扩展记下的）。
    func writeScore(_ name: String, suite: EvalSuite, checks: [Check], failure: (any Error)?, prompt: String, to output: URL) async throws {
        guard suite != .bench else { return }  // 记忆基准自己判分（bench.py），它的目录里 .json 都是题
        let wide = prompt.unicodeScalars.count { !$0.isASCII }, ascii = prompt.unicodeScalars.count { $0.isASCII }
        var score: [String: Any] = [
            "name": name, "suite": suite.rawValue, "brain": EvalBrain.current.label, "error": failure.map { "\($0)" } ?? NSNull(),
            "checks": checks.map { ["kind": $0.kind.rawValue, "label": $0.label, "passed": $0.passed, "counted": $0.counted, "note": $0.note] },
            "metrics": await metrics(), "extra": extra, "prompt": ["chars": prompt.count, "tokens": wide + ascii / 4],
        ]
        if let directory = rig.brainDirectory, EvalBrain.current.runtime == .pi {
            let billing = BrainUsage.billing(in: directory)
            score["billing"] = ["requests": billing.requests, "marked": billing.marked, "agents": billing.agents.sorted()]
        }
        let data = try JSONSerialization.data(withJSONObject: score, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appending(path: "\(name).score.json"))
    }
}
#endif
