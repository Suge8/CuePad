#if os(macOS)
import CueStore
import Foundation

/// 托管的 Claude Code 收下的一句话或一条斜杠命令送没送达（Claude Code 2.1.317 实测）：交出时带着 `uuid`（投送请求 id），
/// 它以 `command_lifecycle` 报这一条 queued → started → completed 或 cancelled。started 不算：没登录、模型不可用、额度用完时
/// 也先报 started，连 `system/status` 的 requesting 也报，再合成一条出错回答、以 `is_error` 的 `result` 收尾、报 cancelled。
/// 所以模型开始回话（`ClaudeStream.onReply`；压缩是 `status` 的 compacting）或 completed 才算送达；cancelled 之前这一轮出错收尾就是没送达
/// （`PiBridgeError.refused`，原因是它的原话）；开始后被停下、没出错的 cancelled 是收下了（停下这一轮不改它送达过）；
/// 等不到（`AgentTimeouts.reply`）与进程退出是未确认。
@MainActor
final class ClaudeDelivery {
    private let verdicts = PendingReplies<String, Void>(timeout: AgentTimeouts.reply, timeoutError: PiBridgeError.ackTimeout)
    /// 已 started、还没定下的那一条（小写的 uuid），与这一轮出错收尾的原话
    private var running: String?
    private var failure: String?

    /// 登记 `uuid`、用 `send` 交出，等它定下。
    func deliver(_ uuid: String, send: () throws -> Void) async throws {
        try await verdicts.request(uuid.lowercased(), send: send)
    }

    /// Claude Code 输出的每一行。
    func observe(_ message: JSONValue) {
        switch message["type"]?.string {
        case "command_lifecycle":
            guard let id = message["command_uuid"]?.string?.lowercased() else { return }
            switch message["state"]?.string {
            case "started": (running, failure) = (id, nil)
            case "completed": settle(id, .success(()))
            // 没出错的取消是开始后被停下（停止、或为下一句停下这一轮）：它已经收下了这句
            case "cancelled": settle(id, failure.map { .failure(PiBridgeError.refused($0)) } ?? .success(()))
            default: break
            }
        case "system" where message["subtype"]?.string == "status" && message["status"]?.string == "compacting":
            replying()
        case "assistant" where message["error"] != nil && running != nil:
            // 它合成的出错回答：正文就是给人看的那句（有的收尾 `result` 不带原话，如 error_during_execution）
            let said = (message["message"]?["content"]?.array ?? []).compactMap { $0["text"]?.string }.joined(separator: "\n")
            if !said.isEmpty { failure = said }
        default:
            break
        }
    }

    /// 模型开始回话（或开始压缩）：started 了的那一条送达了。
    func replying() {
        if let running { settle(running, .success(())) }
    }

    /// 这一轮出错收尾（被停下的不算）：记到 started 了还没定下的那一条上。原因取给人看的那句（"Not logged in · Please run /login"）：
    /// `result` 的原话，没有时是出错回答的正文，都没有才是这一轮出错的原文 `failure`。
    func failed(_ failure: String, in result: JSONValue) {
        guard running != nil else { return }
        let said = result["result"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.failure = said.isEmpty ? self.failure ?? failure : said
    }

    /// 进程退出：等着的以会话结束收尾（结果未知）。
    func close() { verdicts.closeAll(PiBridgeError.sessionEnded) }

    private func settle(_ id: String, _ result: Result<Void, any Error>) {
        verdicts.resolve(id, with: result)
        if running == id { (running, failure) = (nil, nil) }
    }
}
#endif
