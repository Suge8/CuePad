#if os(macOS)
import CueStore
import Foundation

/// 接入里各种等待的时限，唯一的一处。
public enum AgentTimeouts {
    /// Pi 扩展回 ack：多数命令受理就回，`send` 等这句落成会话里的消息（停下在跑的一轮再开也在内）
    public static let ack: Duration = .seconds(10)
    /// Claude Code 的控制请求、Codex 的 RPC 请求（含握手）
    public static let reply: Duration = .seconds(60)
    /// 问一家 Agent 能不能用、有哪些模型（`AgentIntegration.probe`），连同起进程
    public static let probe: Duration = .seconds(20)
    /// 起进程到上桥、拉起后台服务
    public static let launch: Duration = .seconds(30)
    public static let end: Duration = .seconds(10)
    /// 问版本、读列表这类一次性的小命令（连同起进程）
    public static let command: Duration = .seconds(10)
    /// 取用户登录 shell 的 PATH
    public static let shell: Duration = .seconds(5)
    /// 列出在跑的 Claude Code 会话
    public static let list: Duration = .seconds(15)
    /// CuePad 自有子进程的强制收尾宽限；已认领的 Pi 经桥走宿主退出，不用强杀兜底。
    public static let endGrace: Duration = .seconds(5)
    /// 停下在跑的一轮后等它收尾（ACP 的取消回应、Claude Code 的 `result`、等发出的话开跑）与 `/clear` 的结果：对端接了请求却不收尾时到点放弃，免得停止与随后的发话永远等下去
    public static let stop: Duration = .seconds(30)
    /// 托管的会话歇着满这么久就退出（不算结束，发话时再接着）
    public static let hostedIdle: Duration = .seconds(30 * 60)
}

/// 至多等 `limit`（按 `timing` 量）：到点取消 `operation` 并抛 `timeout`。`operation` 要响应取消（到点后要等它返回）。
func withDeadline<T: Sendable>(
    _ limit: Duration, timing: Timing = .system, orThrow timeout: any Error, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await timing.sleep(limit)
            throw timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// 发话里"先停下上一轮"那一段（发停止请求、等回应、等它收尾）：新话还没交出，所以停止（`abort`）可以把整段取消，
/// 不论它卡在哪个等待上；之后的段（交出新话、等送达）不在里面：话已交出，取消会把已收下的话误报成未确认、引起重发。
@MainActor
final class StopPhase {
    private var running: [UUID: Task<Void, any Error>] = [:]

    func run(_ body: @escaping @MainActor () async throws -> Void) async throws {
        let id = UUID()
        let work = Task { try await body() }
        running[id] = work
        defer { running[id] = nil }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
    }

    func cancelAll() { for work in running.values { work.cancel() } }
}

/// 一条连接上等回应的请求（Pi 扩展的 ack、Claude Code 的控制请求、Codex、ACP 与 Pi 大脑的 RPC）：按 id 配上回应，至多等 `timeout`（按 `timing` 量；nil 不限时）；
/// 调用方取消时立即以取消结束（请求已发出，对端照常处理）；连接断了等着的全部失败，之后的请求不再发。
@MainActor
final class PendingReplies<ID: Hashable & Sendable, Reply: Sendable> {
    private var waiting: [ID: CheckedContinuation<Reply, any Error>] = [:]
    private var closed: (any Error)?
    private let timeout: Duration?
    private let timing: Timing
    private let timeoutError: any Error

    init(timeout: Duration?, timing: Timing = .system, timeoutError: any Error) {
        self.timeout = timeout
        self.timing = timing
        self.timeoutError = timeoutError
    }

    var isClosed: Bool { closed != nil }

    /// 登记 `id`、用 `send` 发出请求，等回应。`send` 抛错时不等，原样抛出。
    func request(_ id: ID, send: () throws -> Void) async throws -> Reply {
        if let closed { throw closed }
        var timer: Task<Void, Never>?
        defer { timer?.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting[id] = continuation
                do {
                    try send()
                } catch {
                    waiting.removeValue(forKey: id)?.resume(throwing: error)
                    return
                }
                guard let timeout else { return }
                let (deadline, error, timing) = (timing.now().addingTimeInterval(timeout.seconds), timeoutError, timing)
                timer = Task { [weak self] in
                    guard (try? await timing.sleepUntil(deadline)) != nil else { return }
                    self?.waiting.removeValue(forKey: id)?.resume(throwing: error)
                }
            }
        } onCancel: {
            // 切回主线程前回应已到的话请求已被取走，这里什么都不做，按正常返回
            Task { @MainActor [weak self] in self?.waiting.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
        }
    }

    /// 回应到了：交给等它的请求；没人在等（超时、取消、不是我们发的）返回 false。
    @discardableResult
    func resolve(_ id: ID, with result: Result<Reply, any Error>) -> Bool {
        guard let continuation = waiting.removeValue(forKey: id) else { return false }
        continuation.resume(with: result)
        return true
    }

    /// 等一件没有回应 id 的事（一轮收尾、开跑）：每个等待者自己一个 id，事件到了 `releaseAll` 一起放行；超时与取消同 `request`。
    func wait() async throws where ID == UUID, Reply == Void {
        _ = try await request(UUID()) {}
    }

    /// 等的那件事到了：放行全部等待者。
    func releaseAll() where Reply == Void {
        let all = waiting.values
        waiting = [:]
        for continuation in all { continuation.resume() }
    }

    /// 等着的全部以取消结束（调用方的任务没被取消，是别处要它们放手，如停止）；之后的请求照常。
    func cancelAll() {
        let all = waiting.values
        waiting = [:]
        for continuation in all { continuation.resume(throwing: CancellationError()) }
    }

    /// 连接断了：等着的全部以 `error` 失败，之后的请求直接抛它。
    func closeAll(_ error: any Error) {
        closed = error
        let all = waiting.values
        waiting = [:]
        for continuation in all { continuation.resume(throwing: error) }
    }
}
#endif
