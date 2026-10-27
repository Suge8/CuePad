#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// CuePad 起的一个 `codex app-server` 进程与它上面 CuePad 开的那个线程（`thread`）的驱动：这个线程的一轮只在这里判，翻成
/// `TurnEvent` 同步交给 `onEvent`（按到达先后）。托管会话（`CodexRuntime` 起的进程，一轮接到桥上）与 Cue 的大脑（`CodexBrain`）
/// 共用它。协议见 https://developers.openai.com/codex/app-server （本机版本的完整类型用 `codex app-server generate-ts` 生成）。
/// - 一轮开始：`turn/start` 的回应与 `turn/started` 通知谁先到算谁，按轮的 id 只报一次（已经结束的那一轮的回应晚到不再报）；
/// - 一轮结束：这一轮的 `turn/completed`（别的轮的不算：停下旧的一轮紧接着开新的一轮时，旧的结束可能晚到）。失败的先报 `failed`：
///   这一轮不再重试的 `error` 通知的原文，没有就用 `turn.error`。不看线程状态：失败时 systemError 先于原文与 `turn/completed` 到（实测 0.162.1）；
/// - 工具是这一轮里的 `mcpToolCall` 与 `commandExecution` 项（命令记作 `bash`）；用量是最近一次请求的 `inputTokens`（已含缓存命中）与 `modelContextWindow`；
/// - 正在说的话是 `CodexRPC` 累积好的这个线程的（`onDraft`）：过程中的说明说完、停下与失败的一轮它已清掉，留下的只有给你看的回答；
/// - 子线程（子代理）与线程之外的事不在这里：每条通知处理完原样转给 `onNotification`，服务端请求由开它的一方接（`CodexRPC.onRequest`）。
@MainActor
final class CodexDriver {
    private(set) var rpc: CodexRPC?
    /// CuePad 开的线程（`thread/start`、`thread/resume`，经 `open`）
    private(set) var thread: String?
    /// 在跑的这一轮与最近结束的一轮（挡住晚到的回应）
    private(set) var turn: String?
    private var finishedTurn: String?
    /// 这一轮不再重试的 `error` 通知的原文
    private var lastError: String?
    var onEvent: (TurnEvent) -> Void = { _ in }
    var onNotification: (String, JSONValue) -> Void = { _, _ in }

    /// 起进程并握手（失败时进程已停掉），接上它的通知；进程退出报 `exited`（`stop` 让它退的为 nil）。
    @discardableResult
    func launch(_ executable: URL, arguments: [String] = [], environment: [String: String], directory: URL? = nil) async throws -> CodexRPC {
        let rpc = try await CodexRPC.launch(executable, arguments: arguments, environment: environment, directory: directory)
        self.rpc = rpc
        rpc.onNotification = { [weak self] in self?.notification($0, $1) }
        rpc.onDraft = { [weak self] thread, draft in
            guard let self, thread == self.thread else { return }
            onEvent(.speaking(draft))
        }
        let process = rpc.process
        rpc.onClose = { [weak self] in
            Task { [weak self] in
                let reason = await process?.exited()
                self?.onEvent(.exited(reason))
            }
        }
        return rpc
    }

    /// 开或接着一个线程（`thread/start`、`thread/resume`），之后报的是它的事。
    @discardableResult
    func open(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard let rpc else { throw HostedSessionError.notRunning }
        let result = try await rpc.call(method, params)
        thread = result["thread"]?["id"]?.string
        turn = nil
        return result
    }

    /// 开一轮（`options` 是 `turn/start` 的其余参数）。
    func startTurn(_ input: [JSONValue], options: [String: JSONValue] = [:]) async throws {
        guard let rpc, let thread else { throw HostedSessionError.notRunning }
        let params = options.merging(["threadId": .string(thread), "input": .array(input)]) { $1 }
        let started = try await rpc.call("turn/start", .object(params))
        if let id = started["turn"]?["id"]?.string { begin(id) }
    }

    /// 停下在跑的这一轮，等它真的结束了才回（回应与它的 `turn/completed` 同时到）；没有在跑的什么都不做。
    func interrupt() async throws {
        guard let rpc, let thread, let turn else { return }
        do {
            try await rpc.call("turn/interrupt", ["threadId": .string(thread), "turnId": .string(turn)])
        } catch CodexRPCError.server(-32600, _) {
            // 这一轮在问与停之间自己结束了（"no active turn to interrupt"）
        }
    }

    private func begin(_ id: String) {
        guard turn != id, finishedTurn != id else { return }
        turn = id
        lastError = nil
        onEvent(.turnStarted)
    }

    private func finish(failure: String?) {
        finishedTurn = turn
        turn = nil
        lastError = nil
        if let failure { onEvent(.failed(failure)) }
        onEvent(.turnFinished)
    }

    private func notification(_ method: String, _ params: JSONValue) {
        if let thread, params["threadId"]?.string == thread { own(method, params) }
        onNotification(method, params)
    }

    private func own(_ method: String, _ params: JSONValue) {
        switch method {
        case "turn/started":
            if let id = params["turn"]?["id"]?.string { begin(id) }
        case "turn/completed":
            let completed = params["turn"]
            guard turn != nil, completed?["id"]?.string == turn else {
                finishedTurn = completed?["id"]?.string
                return
            }
            finish(failure: completed?["status"]?.string == "failed" ? lastError ?? CodexModel.failure(of: completed) : nil)
        case "error" where params["willRetry"]?.bool != true:
            lastError = CodexModel.failure(of: params)
        case "item/started" where turn != nil:
            guard let item = params["item"] else { return }
            let id = item["id"]?.string ?? ""
            switch item["type"]?.string {
            case "mcpToolCall":
                onEvent(.tool(id: id, name: item["tool"]?.string ?? "?", arguments: String(decoding: (item["arguments"] ?? [:]).data, as: UTF8.self)))
            case "commandExecution":
                onEvent(.tool(id: id, name: "bash", arguments: jsonString(["command": item["command"]?.string ?? ""])))
            default: break
            }
        case "item/completed" where turn != nil:
            guard let item = params["item"] else { return }
            let id = item["id"]?.string ?? "", failed = ["failed", "declined"].contains(item["status"]?.string)
            switch item["type"]?.string {
            case "mcpToolCall":
                let error = item["error"]?["message"]?.string
                onEvent(.toolDone(id: id, result: error ?? brainText(item["result"]?["content"]), failed: failed || error != nil))
            case "commandExecution":
                onEvent(.toolDone(id: id, result: item["aggregatedOutput"]?.string ?? "", failed: failed))
            default: break
            }
        case "thread/tokenUsage/updated":
            let usage = params["tokenUsage"]
            if let input = usage?["last"]?["inputTokens"]?.int { onEvent(.context(used: input, window: usage?["modelContextWindow"]?.int)) }
        default:
            break
        }
    }

    /// 不再报这个线程的事，结束进程：返回的等待在进程退出后结束。
    func stop() -> @concurrent @Sendable () async -> Void {
        thread = nil
        let process = rpc?.process
        return { await process?.stop() }
    }
}
#endif
