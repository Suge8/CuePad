#if os(macOS)
import CueStore
import Foundation

/// 托管会话按第一句话起名（`SessionNameSuggestion`），照 Codex 终端界面自动起名（0.166 起的 `thread_title.rs`）：app-server 没有起名的接口，
/// 在承载这个会话的进程里开一个用完不留的临时线程（`ephemeral`，只读、不审批，钩子、工具、MCP 都关），用输出格式跑一轮拿到 `{title}`，
/// 再退订它。模型用终端界面起名的那个（账号的模型清单里有时，低强度），没有就用会话当前的模型。
/// 临时线程报出 `thread/started` 时已记为不是子代理（`notification`），它的推送只到这里（`naming`），不进会话。
/// 终端里的会话不起：终端界面自己会起。
extension CodexRuntime {
    static let namingModel = "gpt-5.6-luna"

    /// 临时线程里关掉的功能：照终端界面起名开的临时线程（`temporary_structured_request.rs`）。钩子必须关：
    /// 托管进程起的线程会把 CuePad 的钩子当成一个新会话报上来。
    private static let namingOff = [
        "apps", "code_mode", "code_mode_only", "context_management", "current_time_reminder", "deferred_executor", "goals", "hooks",
        "image_generation", "memories", "multi_agent", "multi_agent_v2", "plugins", "request_permissions_tool", "shell_snapshot",
        "shell_tool", "standalone_web_search", "token_budget", "tool_suggest", "unified_exec", "view_image",
    ]

    public func suggestName(from firstMessage: String, in id: PiSession.ID) async throws -> String {
        guard let session = tracked[id], let rpc = hosted[session.pid]?.rpc else { throw PiBridgeError.unsupported }
        let cwd = bridge.session(id: id)?.cwd.path(percentEncoded: false) ?? "/"
        let luna = models?.contains { $0.id == Self.namingModel } == true
        let model = luna ? Self.namingModel : bridge.session(id: id)?.model?.key.id
        return try await withDeadline(SessionNameSuggestion.budget, timing: timing, orThrow: PiBridgeError.rejected("failed: timeout")) { @MainActor in
            let effective = try await rpc.call("config/read", ["cwd": .string(cwd)])
            var config: [String: JSONValue] = Dictionary(uniqueKeysWithValues: Self.namingOff.map { ("features.\($0)", false) })
            config["web_search"] = "disabled"
            config["mcp_servers"] = .object((effective["config"]?["mcp_servers"]?.object ?? [:]).mapValues { _ in ["enabled": false] })
            var start: [String: JSONValue] = [
                "cwd": .string(cwd), "ephemeral": true, "sandbox": "read-only", "approvalPolicy": "never", "config": .object(config),
            ]
            if let model { start["model"] = .string(model) }
            guard let thread = try await rpc.call("thread/start", .object(start))["thread"]?["id"]?.string else {
                throw PiBridgeError.rejected("failed: no thread")
            }
            let key = "\(thread).\(rpc.pid)"
            let turn = CodexNamingTurn()
            self.naming[key] = turn
            defer {
                self.naming[key] = nil
                Task { _ = try? await rpc.call("thread/unsubscribe", ["threadId": .string(thread)]) }
            }
            let prompt = "\(SessionNameSuggestion.instructions)\n\nUser prompt:\n\(firstMessage)"
            var params: [String: JSONValue] = [
                "threadId": .string(thread), "input": .array(CodexRPC.input(text: prompt, images: [])),
                "outputSchema": [
                    "type": "object", "required": ["title"], "additionalProperties": false,
                    "properties": ["title": ["type": "string", "minLength": 1, "maxLength": .number(Double(SessionNameSuggestion.limit))]],
                ],
            ]
            if luna { params["effort"] = "low" }
            _ = try await rpc.call("turn/start", .object(params))
            let reply = try await turn.value()
            guard let title = JSONValue.parse(Data(reply.utf8))?["title"]?.string else { throw PiBridgeError.rejected("failed: not a title") }
            return title
        }
    }
}

/// 起名的那一轮：最后一段回答等到这一轮结束交出。
@MainActor
final class CodexNamingTurn {
    private var text: String?
    private var result: Result<String, any Error>?
    private var waiter: CheckedContinuation<String, any Error>?

    func receive(_ method: String, _ params: JSONValue) {
        switch method {
        case "item/completed" where params["item"]?["type"]?.string == "agentMessage":
            text = params["item"]?["text"]?.string
        case "turn/completed":
            let status = params["turn"]?["status"]?.string
            guard status == "completed", let text else { return finish(.failure(PiBridgeError.rejected("failed: \(status ?? "?")"))) }
            finish(.success(text))
        default:
            break
        }
    }

    func value() async throws -> String {
        if let result { return try result.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ outcome: Result<String, any Error>) {
        guard result == nil else { return }
        result = outcome
        waiter?.resume(with: outcome)
        waiter = nil
    }
}
#endif
