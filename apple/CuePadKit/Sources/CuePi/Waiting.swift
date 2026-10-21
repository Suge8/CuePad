#if os(macOS)
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
    /// 请会话结束后等它下桥
    public static let end: Duration = .seconds(10)
    /// 请托管的进程退出后等它自己收尾多久，过了就强杀（Pi 的收尾实测 80 次里 11 次停住超过这个数）
    static let endGrace: Duration = .seconds(5)
    /// 托管的会话歇着满这么久就退出（不算结束，发话时再接着）
    public static let hostedIdle: Duration = .seconds(30 * 60)
}

/// 至多等 `limit`：到点取消 `operation` 并抛 `timeout`。`operation` 要响应取消（到点后要等它返回）。
func withDeadline<T: Sendable>(
    _ limit: Duration, orThrow timeout: any Error, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: limit)
            throw timeout
        }
        defer { group.cancelAll() }
        return try await group.next()!
    }
}

/// 一条连接上等回应的请求（Pi 扩展的 ack、Claude Code 的控制请求、Codex 与 Pi 大脑的 RPC）：按 id 配上回应，至多等 `timeout`；
/// 调用方取消时立即以取消结束（请求已发出，对端照常处理）；连接断了等着的全部失败，之后的请求不再发。
@MainActor
final class PendingReplies<ID: Hashable & Sendable, Reply: Sendable> {
    private var waiting: [ID: CheckedContinuation<Reply, any Error>] = [:]
    private var closed: (any Error)?
    private let timeout: Duration
    private let timeoutError: any Error

    init(timeout: Duration, timeoutError: any Error) {
        self.timeout = timeout
        self.timeoutError = timeoutError
    }

    /// 连接断了之后为 true（`closeAll` 之后）。
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
                let (limit, error) = (timeout, timeoutError)
                timer = Task { [weak self] in
                    guard (try? await Task.sleep(for: limit)) != nil else { return }
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

    /// 连接断了：等着的全部以 `error` 失败，之后的请求直接抛它。
    func closeAll(_ error: any Error) {
        closed = error
        let all = waiting.values
        waiting = [:]
        for continuation in all { continuation.resume(throwing: error) }
    }
}
#endif
