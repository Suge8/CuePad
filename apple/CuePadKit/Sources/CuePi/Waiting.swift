#if os(macOS)
import CueStore
import Foundation

/// 接入里各种等待的时限，唯一的一处。
public enum AgentTimeouts {
    /// Pi 扩展回 ack：多数命令受理就回，`send` 等这句落成会话里的消息（停下在跑的一轮再开也在内）
    public static let ack: Duration = .seconds(10)
    public static let reply: Duration = .seconds(60)
    public static let probe: Duration = .seconds(20)
    public static let launch: Duration = .seconds(30)
    public static let end: Duration = .seconds(10)
    public static let command: Duration = .seconds(10)
    public static let shell: Duration = .seconds(5)
    /// Codex 一轮要歇下前，同一进程上认不出主人的线程一起再问的总时限：这段时间卡片仍显示在跑，到点没回的等它下一条推送再问
    public static let settleAsk: Duration = .seconds(5)
    public static let list: Duration = .seconds(15)
    /// CuePad 自有子进程的强制收尾宽限；已认领的 Pi 经桥走宿主退出，不用强杀兜底。
    public static let endGrace: Duration = .seconds(5)
    /// 停下在跑的一轮后等它收尾（ACP 的取消回应、Claude Code 的 `result`、等发出的话开跑）与 `/clear` 的结果：对端接了请求却不收尾时到点放弃，免得停止与随后的发话永远等下去
    public static let stop: Duration = .seconds(30)
    public static let hostedIdle: Duration = .seconds(30 * 60)
    /// 终端里刚起的 Claude Code 起好（能收话）：本机上桥后约 0.5 秒，留给慢机器
    public static let terminalReady: Duration = .seconds(15)
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
/// 取消按代次认：这一段已跑完、外层还没恢复时来的停止，同样让外层不再交话（`run` 返回前核对）。
@MainActor
final class StopPhase {
    private var running: [UUID: Task<Void, any Error>] = [:]
    private var generation = 0

    /// `cancellable` 为 false 的是停止自己的这一段：再按一次停止不该把前一次（中止已发出）报成取消。
    func run(cancellable: Bool = true, _ body: @escaping @MainActor () async throws -> Void) async throws {
        let id = UUID()
        let started = generation
        let work = Task { try await body() }
        if cancellable { running[id] = work }
        defer { running[id] = nil }
        try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        if cancellable, generation != started { throw CancellationError() }
    }

    func cancelAll() {
        generation += 1
        for work in running.values { work.cancel() }
    }
}

/// 按 id 配上回应，至多等 `timeout`（按 `timing` 量；nil 不限时）；调用方取消时立即以取消结束（请求已发出，对端照常处理）；连接断了等着的全部失败，之后的请求不再发。
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

    /// 放行此刻在等的全部；之前、之后都不留痕迹（`Occurrences` 在它上面记次数）。
    fileprivate func releaseAll() where Reply == Void {
        let all = waiting.values
        waiting = [:]
        for continuation in all { continuation.resume() }
    }

    func closeAll(_ error: any Error) {
        closed = error
        let all = waiting.values
        waiting = [:]
        for continuation in all { continuation.resume(throwing: error) }
    }
}

/// 会反复发生的一件事（一轮开跑、一轮收尾、一轮变一次），等的人不错过已经来过的那一次：先记下 `count`，再做会引出它的事
/// （发请求、等回应），然后 `wait(after:)`：记下之后来过就立即返回，没来过才挂起。至多等 `timeout`，取消与断线同 `PendingReplies`。
@MainActor
final class Occurrences {
    private(set) var count = 0
    private let waiting: PendingReplies<UUID, Void>

    init(timeout: Duration?, timing: Timing = .system, timeoutError: any Error) {
        waiting = PendingReplies(timeout: timeout, timing: timing, timeoutError: timeoutError)
    }

    func happened() {
        count += 1
        waiting.releaseAll()
    }

    func wait(after seen: Int) async throws {
        guard count == seen else { return }
        try await next()
    }

    /// 只等下一次，之前来过的不算：给刚同步查过状态、紧接着等的（查与等之间没有挂起，不会漏）。
    func next() async throws {
        _ = try await waiting.request(UUID()) {}
    }

    func closeAll(_ error: any Error) {
        waiting.closeAll(error)
    }
}
#endif
