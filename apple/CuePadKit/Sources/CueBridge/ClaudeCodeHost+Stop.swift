#if os(macOS)
import CueStore
import Foundation

extension ClaudeHostedSession {
    func put(_ message: JSONValue) throws {
        try live.write(message)
        emit(.turnStarted)
        publish(at: .now)
    }

    static func userMessage(_ content: JSONValue, extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["type": "user", "message": ["role": "user", "content": content], "parent_tool_use_id": .null].merging(extra) { $1 })
    }

    func closeClears() {
        clearWaits.closeAll(BridgeError.sessionEnded)
        clearing.removeAll()
    }

    func endClear(_ outcome: Result<Void, any Error>) {
        guard !clearing.isEmpty else { return }
        clearWaits.resolve(clearing.removeFirst(), with: outcome)
    }

    /// 请它停下这一轮，收尾（`result`）由 `HostedTurns` 等。还没见它的 `system/init` 也照停（#81）：话已交出、中断排在它后面，
    /// Claude Code 照样停下这一轮、回 `result`（2.1.318 实测：冻住进程时话与中断一起读到，这一轮不问模型就收尾）。
    /// 停下时 Claude Code 可能连排着的任务通知一起取消，所以不再等为它跑的那一轮（`ClaudeHostedTasks.forgetOwed`）。
    /// 没在跑就不停：交出即开轮（`put`），没有开始晚到的窗口，歇着时停只会丢掉排着的任务通知。
    func interrupt() async throws {
        guard turns.running else { return }
        tasks.forgetOwed()
        _ = try await live.request(["subtype": "interrupt"])
    }
}
#endif
