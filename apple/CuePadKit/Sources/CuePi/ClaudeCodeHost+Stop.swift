#if os(macOS)
import CueStore
import Foundation

/// 托管会话与大脑送话、停下这一轮并等它收尾的部分（状态在 `ClaudeHostedSession`）。
extension ClaudeHostedSession {
    /// 送进一句话（`userMessage`）：`interrupting` 时在跑就先停下这一轮、等它收尾，否则并进这一轮。
    func say(_ message: JSONValue, interrupting: Bool) async throws {
        if interrupting { try await interrupt(restarting: true) }
        try put(message)
    }

    /// 写进去，从这一刻算这一轮。
    func put(_ message: JSONValue) throws {
        try live.write(message)
        began()
    }

    /// 一条用户消息；`extra` 是托管会话另带的（`uuid`、`priority`，见 +Control）。
    static func userMessage(_ content: JSONValue, extra: [String: JSONValue] = [:]) -> JSONValue {
        .object(["type": "user", "message": ["role": "user", "content": content], "parent_tool_use_id": .null].merging(extra) { $1 })
    }

    /// 发出的话（斜杠命令也是）一定开始一轮：从发出那一刻算，不等它的 `system/init`（中间隔着钩子）；为它停下的那一轮收尾时已经开了。
    func began() {
        if !facts.running { starting = true }
        beginTurn()
        publish(at: .now)
    }

    /// 这一轮开跑了（或没跑就结束了）：放行等着它的停止。
    func started() {
        starting = false
        startWaits.releaseAll()
    }

    /// `/clear` 的 `result` 到了（或进程退出）：结束最早还在等的那一个。
    func endClear(_ outcome: Result<Void, any Error>) {
        while !clearing.isEmpty {
            if clearWaits.resolve(clearing.removeFirst(), with: outcome) { return }
        }
    }

    /// 停下在跑的这一轮并等它收尾；还没开跑的（`starting`）先等它开跑。歇着什么都不做。
    func interrupt(restarting: Bool) async throws {
        if starting { try await startWaits.wait() }
        guard facts.running else { return }
        stopping = true
        restart = restarting
        let turn = closed
        do {
            _ = try await live.request(["subtype": "interrupt"])
            if closed == turn { try await closing.wait() }
        } catch {
            restart = false
            throw error
        }
    }

    func release() {
        closing.releaseAll()
    }
}
#endif
