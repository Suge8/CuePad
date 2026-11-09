#if os(macOS)
import CueStore
import Foundation

extension ClaudeHostedSession {
    /// `interrupting` 时在跑就先停下这一轮、等它收尾，否则并进这一轮。
    func say(_ message: JSONValue, interrupting: Bool) async throws {
        if interrupting { try await interrupt(restarting: true) }
        try put(message)
    }

    func put(_ message: JSONValue) throws {
        try live.write(message)
        began()
    }

    static func userMessage(_ content: JSONValue, extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["type": "user", "message": ["role": "user", "content": content], "parent_tool_use_id": .null].merging(extra) { $1 })
    }

    /// 发出的话（斜杠命令也是）一定开始一轮：从发出那一刻算，不等它的 `system/init`（中间隔着钩子）；为它停下的那一轮收尾时已经开了。
    func began() {
        beginTurn()
        publish(at: .now)
    }

    /// 等着的 `/clear` 都以会话已结束收尾，之后的也直接抛它。
    func closeClears() {
        clearWaits.closeAll(PiBridgeError.sessionEnded)
        clearing.removeAll()
    }

    /// 等的人已超时或走了的也占着自己的位置：它那条 `/clear` 迟到的 `result` 不能算给后面的。
    func endClear(_ outcome: Result<Void, any Error>) {
        guard !clearing.isEmpty else { return }
        clearWaits.resolve(clearing.removeFirst(), with: outcome)
    }

    func interrupt(restarting: Bool) async throws {
        try await stopPhase.run(cancellable: restarting) { [self] in
            // 还没见它的 `system/init` 也照停，不等 init（#81：起得慢就等满 `AgentTimeouts.stop`）：话已交出、中断排在它后面，
            // Claude Code 照样停下这一轮、回 `result`（2.1.318 实测：冻住进程时话与中断一起读到，这一轮不问模型就收尾）
            guard facts.running else { return }
            stopping = true
            restart = restarting
            let seen = closing.count
            do {
                _ = try await live.request(["subtype": "interrupt"])
                try await closing.wait(after: seen)
            } catch {
                restart = false
                throw error
            }
        }
    }

    func release() {
        closing.happened()
    }
}
#endif
