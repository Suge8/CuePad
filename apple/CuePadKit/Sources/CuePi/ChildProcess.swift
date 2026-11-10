#if os(macOS)
import CueStore
import Darwin
import Foundation
import Synchronization

/// 起进程、读写、等退出、停进程只经这里。
/// - 不挂在 App 底下：经 `/bin/sh` 中转（`relay`）起，中转报出它的 PID 就退出，它挂到 launchd 下。LaunchServices 给没有包的进程
///   （osascript、swift 脚本、xctest 这类一碰窗口服务就登记成应用的）认的是进程树上最近的应用：挂在 App 下，Agent 跑的这些工具
///   都登记成前台的 CuePad，程序坞每次多一个图标、退出后不撤（攒下过几百个）。否决 `responsibility_spawnattrs_setdisclaim`：
///   LaunchServices 不看责任进程（实测照样登记成 CuePad），却会让 Agent 失去 App 拿到的隐私授权；中转不改责任进程，授权照旧；
/// - 只继承列出的描述符（`POSIX_SPAWN_CLOEXEC_DEFAULT`）：App 打开的文件与连接不漏进去；
/// 退出与退出码由 kqueue 的进程事件得知（`NOTE_EXITSTATUS`，不是子进程也给），launchd 回收；
/// - 输出用读事件读，按 `\n` 切行（JSON 字符串里的 U+2028/2029 不是行界）；写入排在一条串行队列上（大图片写进管道时不卡调用方，
///   先后不变），写端设了 `F_SETNOSIGPIPE`：进程已退出时写入只是失败；关了输入之后的写入丢掉（描述符号可能已被别的文件复用）。
public final class ChildProcess: Sendable {
    enum Placement: Sendable {
        /// 自成一个进程组，信号按组发：用户的 Agent 命令常是不带 exec、不转发信号的外壳（版本管理器的 shim、自写的包装），
        /// 只给组长（外壳）SIGTERM，外壳先死，真 Agent 收不到；它自己起的子进程跟着一起收到 SIGTERM，各家实测都照常收尾（#155）。
        /// 组长先退出时，组里剩下的（没跟着走的子进程、外壳下的真 Agent）同样 SIGTERM、宽限 `AgentTimeouts.endGrace` 后 SIGKILL，不留孤儿；
        /// 等它退出的（`exited`、`waitForExit`）等到整组都走，退出码是组长的
        case group
        /// 新会话：App 所在会话与进程组的信号碰不到它，认领（`release()`）之后 App 退出、崩溃它照常在（后台托管的 Pi）。
        /// 认领之前它的生死跟着起它的这一方：中转留一个看守读 `holdFD` 上只有本进程握着写端的管道，没等到认领就读到 EOF
        /// （这个对象没了、App 退出或崩溃）时结束它，SIGTERM 后宽限 `AgentTimeouts.endGrace` 再 SIGKILL。否则起到一半 App 就没了、
        /// 而它的扩展又没接手（没载入、目录已删）时，它既不会空闲自退也没人认，成了一直空转的孤儿
        case detached
    }

    enum Input: Sendable {
        case null
        case pipe
        /// 一根管道的读端，写端也交给它自己（放在 3 号）：还有写端开着，读端永远读不到 EOF（Pi 的 RPC 模式读到 EOF 就收尾）。
        /// App 这边启动后立刻关掉两端，不持有它的任何管道。否决 `/dev/null`（立刻 EOF）与命名管道（要在磁盘上建、要清理）
        case lifeline
    }

    enum Output: Sendable {
        case null
        case lines
        case raw
    }

    let output: AsyncStream<Data>
    let pid: pid_t
    private let placement: Placement
    private let timing: Timing
    private let input: Int32?
    private let writes = DispatchQueue(label: "cuepad.child.write")

    struct State {
        var inputOpen = true
        var stopping = false
        /// SIGTERM 只发一次：停它时发过的，组长退出时不再补
        var terminated = false
        var killed = false
        /// 组长已退出、组里还有人时，到点强杀的那一段
        var deadline: Task<Void, Never>?
        var status: Int32?
        var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    }
    /// 回收与读事件的回调和调用方共享（`Mutex` 不可复制，放进引用里）
    final class Shared: Sendable { let state = Mutex(State()) }
    private let shared = Shared()
    private let errors: ErrorTail?
    private let hold: Mutex<Int32?>

    /// `environment` 是完整的环境（nil 继承本进程的）；`directory` 为 nil 时用本进程的工作目录。
    /// 标准错误只留末尾（`stderrTail`）给退出原因，`keepErrors` 为 false 时丢掉。脱离 App 的进程只读到认领为止
    /// （起不来的原因都在这之前），之后由看守接着读走丢掉：App 退出后它不收 EPIPE，也没有越写越大的文件。
    init(
        _ executable: URL, _ arguments: [String], directory: URL? = nil, environment: [String: String]? = nil,
        placement: Placement, input inputMode: Input = .null, output outputMode: Output = .null, keepErrors: Bool = true,
        timing: Timing = .system
    ) async throws {
        var opened: [Int32] = []
        defer { for fd in opened { close(fd) } }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var input: Int32?
        switch inputMode {
        case .null:
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        case .pipe:
            let stdin = try Self.pipe()
            opened.append(stdin.read)
            input = stdin.write
            posix_spawn_file_actions_adddup2(&actions, stdin.read, STDIN_FILENO)
        case .lifeline:
            let lifeline = try Self.pipe()
            opened += [lifeline.read, lifeline.write]
            posix_spawn_file_actions_adddup2(&actions, lifeline.read, STDIN_FILENO)
            posix_spawn_file_actions_adddup2(&actions, lifeline.write, 3)
        }
        var stdout: Int32?
        if outputMode == .null {
            posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        } else {
            let out = try Self.pipe()
            opened.append(out.write)
            stdout = out.read
            posix_spawn_file_actions_adddup2(&actions, out.write, STDOUT_FILENO)
        }
        var errors: ErrorTail?
        if keepErrors {
            let err = try Self.pipe()
            opened.append(err.write)
            errors = ErrorTail(err.read)
            posix_spawn_file_actions_adddup2(&actions, err.write, STDERR_FILENO)
            if placement == .detached { posix_spawn_file_actions_adddup2(&actions, err.read, Self.errorsFD) }
        } else {
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        }
        if let directory { posix_spawn_file_actions_addchdir(&actions, directory.path) }
        let pid: pid_t, hold: Int32?
        do {
            (pid, hold) = try await Self.spawn(
                executable, arguments, environment: environment ?? ProcessInfo.processInfo.environment, actions: &actions,
                newSession: placement == .detached, drainsErrors: errors != nil
            ) { [shared] in Self.watchExit($0, group: placement == .group, timing: timing, shared: shared, errors: errors) }
        } catch {
            opened += [input, stdout].compactMap { $0 }
            errors?.stop()
            throw error
        }
        self.pid = pid
        self.placement = placement
        self.timing = timing
        self.input = input
        self.errors = errors
        self.hold = Mutex(hold)
        if let input { _ = fcntl(input, F_SETNOSIGPIPE, 1) }

        let (output, emit) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.output = output
        if let stdout {
            let lines = outputMode == .lines ? LineReader() : nil
            Self.read(stdout) { chunk in
                if let lines { lines.split(chunk).forEach { emit.yield($0) } } else { emit.yield(chunk) }
            } done: { emit.finish() }
        } else {
            emit.finish()
        }
    }

    deinit {
        hold.withLock { $0 }.map { _ = close($0) }
    }

    func release() {
        guard let fd = hold.withLock({ fd in defer { fd = nil }; return fd }) else { return }
        _ = Darwin.write(fd, "\n", 1)
        close(fd)
        errors?.stop()
    }

    public enum Attempt: Sendable {
        case finished(status: Int32, output: String)
        case timedOut
        case notStarted
    }

    /// `collect` 为 false 时不接管标准输出：常驻的后代继承了管道就永远读不到结尾。
    /// 自成进程组：超过 `timeout` 时结束它连同它起的整组（不理 SIGTERM、握着输出管道的子进程也一样）。
    /// 取消调用方不影响它：超时照样结束，退出码照实取。`timing` 是量 `timeout` 与结束时宽限的钟：起一个进程要多久取决于系统此刻多忙，
    /// 测试给手动推进的钟，截止只在测试推进时到。
    @concurrent public static func attempt(
        _ executable: URL, _ arguments: [String], directory: URL? = nil, environment: [String: String]? = nil, timeout: Duration? = nil,
        timing: Timing = .system, collect: Bool = true
    ) async -> Attempt {
        guard let process = try? await ChildProcess(
            executable, arguments, directory: directory, environment: environment, placement: .group, output: collect ? .raw : .null,
            keepErrors: false, timing: timing)
        else { return .notStarted }
        // 包一层不继承取消的任务（`withTaskCancellationShield` 要 macOS 27，部署目标是 26）
        return await Task {
            async let output = process.output.reduce(into: Data()) { $0 += $1 }
            guard await process.exited(within: timeout) else {
                process.end()
                return .timedOut  // 不等输出读完：它起的后代可能还握着管道（离开时读取随之取消）
            }
            return .finished(status: process.status ?? -1, output: String(decoding: await output, as: UTF8.self))
        }.value
    }

    /// 超时与没能启动都是 nil，只在两者不必分开时用。
    @concurrent public static func run(
        _ executable: URL, _ arguments: [String], directory: URL? = nil, environment: [String: String]? = nil, timeout: Duration? = nil,
        timing: Timing = .system, collect: Bool = true
    ) async -> (status: Int32, output: String)? {
        guard case .finished(let status, let output) = await attempt(
            executable, arguments, directory: directory, environment: environment, timeout: timeout, timing: timing, collect: collect)
        else { return nil }
        return (status, output)
    }

    /// 等它退出，返回退出码（被信号结束为 nil）；不随调用方取消提前返回。
    public func waitForExit() async -> Int32? {
        _ = await Task { await exited(within: nil) }.value
        return status
    }

    func write(_ line: Data) {
        guard let input else { return }
        let shared = shared
        writes.async {
            guard shared.state.withLock({ $0.inputOpen }) else { return }
            _ = writeAll(input, line + [0x0A])
        }
    }

    /// 说行协议的几家都把 EOF 当作“收尾退出”。
    func closeInput() {
        guard let input else { return }
        let shared = shared
        writes.async {
            let open = shared.state.withLock { s in defer { s.inputOpen = false }; return s.inputOpen }
            if open { close(input) }
        }
    }

    /// 请它马上退出、不等：SIGTERM，宽限 `AgentTimeouts.endGrace` 过了还没走就 SIGKILL（自成进程组的都按组发）。之后等它退出的一定等得到。
    public func end() {
        terminate()
        Task { [self] in
            if await !exited(within: AgentTimeouts.endGrace) { kill() }
        }
    }

    /// 让它退出并等到退出：先关标准输入请它收尾，不走再 SIGTERM，各宽限 `AgentTimeouts.endGrace`，还不走就 SIGKILL。之后 `exited()` 报 nil。
    /// 调用方取消不让它跳过收尾（SIGKILL 不给它清理的机会，如 Claude Code 的收件箱 socket 就会留在 /tmp/cc-socks 里）。
    func stop() async {
        shared.state.withLock { $0.stopping = true }
        closeInput()
        await Task { [self] in
            if await exited(within: AgentTimeouts.endGrace) { return }
            terminate()
            if await exited(within: AgentTimeouts.endGrace) { return }
            kill()
            _ = await exited(within: nil)
        }.value
    }

    private func terminate() {
        Self.deliver(pid, SIGTERM, group: placement == .group, shared: shared)
    }

    private func kill() {
        Self.deliver(pid, SIGKILL, group: placement == .group, shared: shared)
    }

    /// 等进程退出，返回退出原因（退出码或信号与标准错误的末尾，各端按自己的语言显示）；是 `stop()` 让它退出的返回 nil。
    /// 可以多处一起等，不随取消提前返回。
    func exited() async -> ShownText? {
        _ = await Task { await exited(within: nil) }.value
        let (status, stopping) = shared.state.withLock { ($0.status ?? -1, $0.stopping) }
        if stopping { return nil }
        let code = (status & 0x7F) == 0 ? ShownText("退出码 \((status >> 8) & 0xFF)") : ShownText("被信号 \(status & 0x7F) 结束")
        let tail = stderrTail
        return tail.isEmpty ? code : ShownText("\(code.embedded)：\(tail)")
    }

    var status: Int32? {
        shared.state.withLock { $0.status }.flatMap { ($0 & 0x7F) == 0 ? ($0 >> 8) & 0xFF : nil }
    }

    var stderrTail: String { errors?.text ?? "" }

    /// 等进程退出，至多 `limit`（nil 不限时，按 `timing` 量）；退出了返回 true。到点或调用方取消时不管有没有退出都立刻返回 false，好接着升级信号。
    func exited(within limit: Duration?) async -> Bool {
        guard let limit else { return await waitForExitSignal() }
        return await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await self.waitForExitSignal() }
            group.addTask { (try? await self.timing.sleep(limit)) == nil ? nil : false }
            defer { group.cancelAll() }
            while let result = await group.next() {
                if let result { return result }
            }
            return false
        }
    }

    private func waitForExitSignal() async -> Bool {
        let id = UUID()
        let shared = shared
        let giveUp: @Sendable () -> Void = { shared.state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(returning: false) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let exited = shared.state.withLock { s in
                    if s.status == nil { s.waiters[id] = continuation }
                    return s.status != nil
                }
                if exited { return continuation.resume(returning: true) }
                if Task.isCancelled { giveUp() }
            }
        } onCancel: { giveUp() }
    }
}

/// 用一个起好的进程（或连着进程的连接）办一件事：办完返回或抛错，都先把它停掉。
func withStopped<Resource, T>(_ resource: Resource, stop: (Resource) async -> Void, _ body: (Resource) async throws -> T) async throws -> T {
    do {
        let value = try await body(resource)
        await stop(resource)
        return value
    } catch {
        await stop(resource)
        throw error
    }
}

#endif
