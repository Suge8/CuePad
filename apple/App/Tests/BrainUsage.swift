#if os(macOS)
import Foundation

/// 大脑一轮的开销，从大脑 stdout 的副本里读：
/// - Claude Code：每轮的 result 事件里 `modelUsage`（各模型的 token）与 `total_cost_usd` 是这个进程到此的累计，
///   同一进程相邻两轮相减得这一轮（含 Claude Code 自己顺带的小模型请求）；
/// - Pi：一轮从 `agent_start` 到 `agent_settled`，这一轮里每条助手消息 `message_end` 的 usage（input、cacheRead、cacheWrite、output、cost.total）相加。
nonisolated struct BrainUsage {
    var input = 0, cacheRead = 0, cacheWrite = 0, output = 0
    var cost = 0.0

    static let header = "输入 | 缓存读 | 缓存写 | 输出 | 费用"
    var cells: String { "\(input) | \(cacheRead) | \(cacheWrite) | \(output) | $\(String(format: "%.4f", cost))" }

    /// Pi 每次请求模型前的计费标识记录（`EvalBrain.billingLog` 写）
    static func billingLog(in root: URL) -> URL { root.appending(path: "billing.jsonl") }

    /// 请求数、系统提示首块带计费标识的请求数
    static func billing(in root: URL) -> (requests: Int, marked: Int) {
        let requests = ((try? String(contentsOf: billingLog(in: root), encoding: .utf8)) ?? "").split(separator: "\n")
            .compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any] }
        return (requests.count, requests.count { $0["billing"] as? Bool == true })
    }

    /// Cue 的大脑的 stdout 副本放在哪（`EvalBrain.launch` 写）
    static func directory(in root: URL) -> URL { root.appending(path: "usage", directoryHint: .isDirectory) }
    /// 后台整理记忆（做梦）的大脑的 stdout 副本：逐轮开销与换新只读 Cue 的，不读这里
    static func dreamDirectory(in root: URL) -> URL { directory(in: root).appending(path: "dream", directoryHint: .isDirectory) }

    /// 一次后台做梦：进程的起止（副本文件的建立与最后写入）与开销
    struct Dream {
        let started, finished: Date
        let usage: BrainUsage
        func contains(_ date: Date) -> Bool { started <= date && date <= finished.addingTimeInterval(1) }  // 摘要入库取整到毫秒，收尾放宽
    }

    /// 每个做梦进程一次，按起进程的先后；开销是整个进程的（一次性进程只做一轮，收掉时不一定报完一轮的结束）
    static func dreams(in root: URL) -> [Dream] {
        files(in: dreamDirectory(in: root)).map { file in
            let dates = try? file.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
            let events = events(file), results = claude(events)
            let usage = (results.isEmpty ? events.compactMap(assistant) : results).reduce(BrainUsage(), +)
            return Dream(started: dates?.creationDate ?? .distantPast, finished: dates?.contentModificationDate ?? .distantPast, usage: usage)
        }
    }

    /// 每个大脑进程一个文件，按起进程的先后；每轮一项
    static func rounds(in root: URL) -> [BrainUsage] {
        files(in: directory(in: root)).flatMap { file in
            let events = events(file)
            return claude(events) + pi(events)
        }
    }

    /// 大脑在哪几轮开了新的对话（轮的序号同 `rounds`）：第一个进程之后每个进程的第一轮，和 Pi 回应过 new_session 之后的那一轮
    static func renewed(in root: URL) -> [Int] {
        var index = 0, out: [Int] = []
        for (number, file) in files(in: directory(in: root)).enumerated() {
            var fresh = number > 0
            for event in events(file) {
                switch event["type"] as? String {
                case "response" where event["command"] as? String == "new_session": fresh = true
                case "result", "agent_settled":
                    if fresh { out.append(index) }
                    fresh = false
                    index += 1
                default: break
                }
            }
        }
        return out
    }

    private static func files(in directory: URL) -> [URL] {
        let files = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []).filter { $0.pathExtension == "jsonl" }
        func created(_ file: URL) -> Date { (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return files.sorted { created($0) < created($1) }
    }

    private static func events(_ file: URL) -> [[String: Any]] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").compactMap { line -> [String: Any]? in
            guard line.contains(#""type":"result""#) || line.contains(#""type":"agent_"#) || line.contains(#""type":"message_end""#)
                || line.contains(#""command":"new_session""#)
            else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
        }
    }

    private static func claude(_ events: [[String: Any]]) -> [BrainUsage] {
        var previous = BrainUsage()
        return events.filter { $0["type"] as? String == "result" }.map { event in
            var sofar = BrainUsage(cost: event["total_cost_usd"] as? Double ?? 0)
            for case let model as [String: Any] in (event["modelUsage"] as? [String: Any] ?? [:]).values {
                sofar.input += model["inputTokens"] as? Int ?? 0
                sofar.cacheRead += model["cacheReadInputTokens"] as? Int ?? 0
                sofar.cacheWrite += model["cacheCreationInputTokens"] as? Int ?? 0
                sofar.output += model["outputTokens"] as? Int ?? 0
            }
            defer { previous = sofar }
            return sofar - previous
        }
    }

    private static func pi(_ events: [[String: Any]]) -> [BrainUsage] {
        var rounds: [BrainUsage] = [], round: BrainUsage?
        for event in events {
            switch event["type"] as? String {
            case "agent_start": if round == nil { round = BrainUsage() }
            case "message_end":
                guard let current = round, let used = assistant(event) else { continue }
                round = current + used
            case "agent_settled":
                if let done = round { rounds.append(done) }
                round = nil
            default: break
            }
        }
        return rounds
    }

    /// Pi 一条助手消息 `message_end` 报的开销
    private static func assistant(_ event: [String: Any]) -> BrainUsage? {
        guard event["type"] as? String == "message_end", let message = event["message"] as? [String: Any], message["role"] as? String == "assistant",
            let usage = message["usage"] as? [String: Any]
        else { return nil }
        return BrainUsage(
            input: usage["input"] as? Int ?? 0, cacheRead: usage["cacheRead"] as? Int ?? 0, cacheWrite: usage["cacheWrite"] as? Int ?? 0,
            output: usage["output"] as? Int ?? 0, cost: (usage["cost"] as? [String: Any])?["total"] as? Double ?? 0)
    }

    /// 写进 score.json、LongMemEval 题目 json 的样子
    var json: [String: Any] { ["input": input, "cacheRead": cacheRead, "cacheWrite": cacheWrite, "output": output, "cost": cost] }

    init(input: Int = 0, cacheRead: Int = 0, cacheWrite: Int = 0, output: Int = 0, cost: Double = 0) {
        (self.input, self.cacheRead, self.cacheWrite, self.output, self.cost) = (input, cacheRead, cacheWrite, output, cost)
    }

    static func + (a: Self, b: Self) -> Self {
        Self(input: a.input + b.input, cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite, output: a.output + b.output, cost: a.cost + b.cost)
    }

    static func - (a: Self, b: Self) -> Self {
        Self(input: a.input - b.input, cacheRead: a.cacheRead - b.cacheRead, cacheWrite: a.cacheWrite - b.cacheWrite, output: a.output - b.output, cost: a.cost - b.cost)
    }
}
#endif
