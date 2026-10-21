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

    /// 大脑的 stdout 副本放在哪（`EvalBrain.launch` 写）
    static func directory(in root: URL) -> URL { root.appending(path: "usage", directoryHint: .isDirectory) }

    /// 每个大脑进程一个文件，按起进程的先后；每轮一项
    static func rounds(in root: URL) -> [BrainUsage] {
        files(root).flatMap { file in
            let events = events(file)
            return claude(events) + pi(events)
        }
    }

    /// 大脑在哪几轮开了新的对话（轮的序号同 `rounds`）：第一个进程之后每个进程的第一轮，和 Pi 回应过 new_session 之后的那一轮
    static func renewed(in root: URL) -> [Int] {
        var index = 0, out: [Int] = []
        for (number, file) in files(root).enumerated() {
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

    private static func files(_ root: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory(in: root), includingPropertiesForKeys: [.creationDateKey])) ?? []
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
                guard let current = round, let message = event["message"] as? [String: Any], message["role"] as? String == "assistant",
                    let usage = message["usage"] as? [String: Any]
                else { continue }
                round = current + BrainUsage(
                    input: usage["input"] as? Int ?? 0, cacheRead: usage["cacheRead"] as? Int ?? 0, cacheWrite: usage["cacheWrite"] as? Int ?? 0,
                    output: usage["output"] as? Int ?? 0, cost: (usage["cost"] as? [String: Any])?["total"] as? Double ?? 0)
            case "agent_settled":
                if let done = round { rounds.append(done) }
                round = nil
            default: break
            }
        }
        return rounds
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
