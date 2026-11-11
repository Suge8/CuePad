#if os(macOS)
import CueAgent
import CueStore
import Foundation

/// 协议见 https://developers.openai.com/codex/app-server （本机版本的完整类型用 `codex app-server generate-ts` 生成）。
/// 一轮开始：`turn/start` 的回应与 `turn/started` 通知谁先到算谁，按轮的 id 只报一次（已经结束的那一轮的回应晚到不再报）。
/// 一轮结束只认这一轮的 `turn/completed`：停下旧的一轮紧接着开新的一轮时，旧的结束可能晚到。失败的先报 `failed`：这一轮不再重试的 `error` 通知的原文，没有就用 `turn.error`；
/// 不看线程状态：失败时 systemError 先于原文与 `turn/completed` 到（实测 0.162.1）。
/// 用量是最近一次请求的 `inputTokens`（已含缓存命中）与 `modelContextWindow`。
/// 插话在这一轮下一次请求模型前进来；最后一次请求时插进的，这一轮接着再请求一次收下它（0.166.0 实测），不会落到下一轮。
/// 子线程（子代理）与线程之外的事不在这里：每条通知处理完原样转给 `onNotification`，服务端请求由开它的一方接（`CodexRPC.onRequest`）。
@MainActor
final class CodexDriver {
    private(set) var rpc: CodexRPC?
    private(set) var thread: String?
    /// 在跑的这一轮与最近结束的一轮（挡住晚到的回应）
    private(set) var turn: String?
    private var finishedTurn: String?
    /// 正在停的那一轮与它的停下，见 `interrupt`
    private var stopping: (turn: String, stop: Stop)?
    private let stopsDone = Occurrences(timeout: nil, timeoutError: CancellationError())
    private var lastError: String?
    /// 一轮开跑（`turn/started`）或结束，见 `interrupt`
    private let activations = Occurrences(timeout: AgentTimeouts.stop, timeoutError: BridgeError.ackTimeout)
    var onEvent: (TurnEvent) -> Void = { _ in }
    var onNotification: (String, JSONValue) -> Void = { _, _ in }

    /// 进程退出报 `exited`（`stop` 让它退的为 nil）。
    @discardableResult
    func launch(
        _ executable: URL, arguments: [String] = [], environment: [String: String], directory: URL? = nil, timing: Timing = .system,
        spawned: (ChildProcess) async throws -> Void = { _ in }
    ) async throws -> CodexRPC {
        let rpc = try await CodexRPC.launch(
            executable, arguments: arguments, environment: environment, directory: directory, timing: timing, spawned: spawned)
        self.rpc = rpc
        rpc.onNotification = { [weak self] in self?.notification($0, $1) }
        rpc.onDraft = { [weak self] thread, draft in
            guard let self, thread == self.thread else { return }
            onEvent(.speaking(draft))
        }
        let process = rpc.process
        rpc.onClose = { [weak self] in
            self?.activations.closeAll(BridgeError.sessionEnded)
            Task { [weak self] in
                let reason = await process.exited()
                self?.onEvent(.exited(reason))
            }
        }
        return rpc
    }

    @discardableResult
    func open(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        guard let rpc else { throw HostedSessionError.notRunning }
        let result = try await rpc.call(method, params)
        thread = result["thread"]?["id"]?.string
        turn = nil
        return result
    }

    func startTurn(_ input: [JSONValue], options: [String: JSONValue] = [:]) async throws {
        guard let rpc, let thread else { throw HostedSessionError.notRunning }
        let params = options.merging(["threadId": .string(thread), "input": .array(input)]) { $1 }
        let started = try await rpc.call("turn/start", .object(params))
        if let id = started["turn"]?["id"]?.string { begin(id) }
    }

    /// 停下在跑的这一轮，等它真的结束（它的 `turn/completed`）才回：0.167.0 的回应先于 `turn/completed` 到（实测），
    /// 这期间对这一轮再发 `turn/interrupt` Codex 不回（等满 `AgentTimeouts.reply`），发 `turn/start` 会碰上还没结束的这一轮。
    /// 所以一轮只停一次（`stopping`）：停下由驱动自己的任务做完（发请求、要补就补、等它结束），不随等它的调用方取消——取消的只是自己不再等，
    /// 否则请求已发出、标记却跟着清掉，下一次停止又对这一轮发一次；补停中途被取消，接手的停止就只等一个不会再停的请求。
    /// 之后再停（停下后紧接着发话、停与发话同时）等同一次停下；它真的失败了（Codex 回错、连接断了、等结束超时）才另开一次。
    /// `turn/start` 已回了这一轮、它还没开跑时，Codex 回 -32600 "no active turn to interrupt"（0.167.0 实测：紧跟发话就停，几毫秒后才有 `turn/started`）：
    /// 等它开跑再停一次。`turn/started` 可能先于这个回应到（问的工夫里它开跑了），所以从发问前算起。
    func interrupt() async throws {
        guard let rpc, let thread, let turn else { return }
        let stop: Stop
        if let current = stopping, current.turn == turn, current.stop.failure == nil {
            stop = current.stop
        } else {
            stop = Stop()
            stopping = (turn, stop)
            Task {
                do {
                    try await requestStop(turn, thread: thread, on: rpc)
                    while self.turn == turn { try await activations.next() }
                } catch {
                    stop.failure = error
                }
                stop.done = true
                stopsDone.happened()
            }
        }
        while !stop.done { try await stopsDone.next() }
        if let failure = stop.failure { throw failure }
    }

    @MainActor private final class Stop {
        var done = false
        var failure: (any Error)?
    }

    private func requestStop(_ turn: String, thread: String, on rpc: CodexRPC) async throws {
        let params: JSONValue = ["threadId": .string(thread), "turnId": .string(turn)]
        let seen = activations.count
        do {
            try await rpc.call("turn/interrupt", params)
        } catch CodexRPCError.server(-32600, _) where self.turn == turn {
            try await activations.wait(after: seen)
            guard self.turn == turn else { return }
            do {
                try await rpc.call("turn/interrupt", params)
            } catch CodexRPCError.server(-32600, _) {
                // 这一轮在问与停之间自己结束了
            }
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
        activations.happened()
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
            activations.happened()
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
            if item["type"]?.string == "userMessage" {
                if let sent = item["clientId"]?.string.flatMap(UUID.init(uuidString:)) { onEvent(.received(sent)) }
            } else if let tool = Self.tool(item) {
                onEvent(.tool(id: item["id"]?.string ?? "", name: tool.name, arguments: String(decoding: tool.arguments.data, as: UTF8.self)))
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
            case "fileChange":
                onEvent(.toolDone(id: id, result: "", failed: failed))
            default: break
            }
        case "thread/tokenUsage/updated":
            let usage = params["tokenUsage"]
            if let input = usage?["last"]?["inputTokens"]?.int { onEvent(.context(used: input, window: usage?["modelContextWindow"]?.int)) }
        default:
            break
        }
    }

    /// 工具一项（命令、改文件、MCP 工具）的名字与参数；不是这几种的为 nil。命令记作 `bash`、改文件记作 `edit`（参数是第一个文件）。
    static func tool(_ item: JSONValue) -> (name: String, arguments: JSONValue)? {
        switch item["type"]?.string {
        case "mcpToolCall": (item["tool"]?.string ?? "?", item["arguments"] ?? [:])
        case "commandExecution": ("bash", ["command": .string(item["command"]?.string ?? "")])
        case "fileChange": ("edit", ["path": item["changes"]?.array?.first?["path"] ?? .null])
        default: nil
        }
    }

    func stop() -> @concurrent @Sendable () async -> Void {
        thread = nil
        let process = rpc?.process
        return { await process?.stop() }
    }
}
#endif
