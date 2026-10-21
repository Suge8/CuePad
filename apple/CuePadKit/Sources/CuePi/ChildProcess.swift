#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// CuePad 起的一个子进程：起进程、读写、等退出、停进程只经这里（大脑、托管的 Claude Code 与 Codex 说行协议的长驻进程，
/// 后台托管的 Pi，一次性的命令 `run`）。
/// - 只继承列出的描述符（`POSIX_SPAWN_CLOEXEC_DEFAULT`）：App 打开的文件与连接不漏进去；
/// - 退出由内核的进程事件得知（不占线程、不轮询），随即回收，不留僵尸；
/// - 输出用读事件读，按 `\n` 切行（JSON 字符串里的 U+2028/2029 不是行界）；写入排在一条串行队列上（大图片写进管道时不卡调用方，
///   先后不变），写端设了 `F_SETNOSIGPIPE`：进程已退出时写入只是失败；关了输入之后的写入丢掉（描述符号可能已被别的文件复用）。
public final class ChildProcess: Sendable {
    enum Placement: Sendable {
        /// 跟 App 同一个进程组（一次性的命令）
        case inline
        /// 自成一个进程组：退出后把组里剩下的（它起的、没跟着走的子进程）一并结束，不留孤儿；停它时整组结束
        case group
        /// 新会话：App 所在会话与进程组的信号碰不到它，App 退出、崩溃它照常在（后台托管的 Pi）
        case detached
    }

    enum Input: Sendable {
        case null
        /// 经 `write` 一行一条写入
        case pipe
        /// 一根管道的读端，写端也交给它自己（放在 3 号）：还有写端开着，读端永远读不到 EOF（Pi 的 RPC 模式读到 EOF 就收尾）。
        /// App 这边启动后立刻关掉两端，不持有它的任何管道。否决 `/dev/null`（立刻 EOF）与命名管道（要在磁盘上建、要清理）
        case lifeline
    }

    enum Output: Sendable {
        case null
        /// `output` 一行一条
        case lines
        /// `output` 原样的块
        case raw
    }

    /// 标准输出（按 `Output`）；没有接管时立即结束。
    let output: AsyncStream<Data>
    let pid: pid_t
    private let placement: Placement
    private let input: Int32?
    private let writes = DispatchQueue(label: "cuepad.child.write")

    private struct State {
        var inputOpen = true
        var stopping = false
        var stderr = Data()
        /// waitpid 拿到的状态；nil 是还没退出
        var status: Int32?
        /// 等退出的：退出时都以 true 唤醒，限时的到点以 false 唤醒（各自只唤醒一次）
        var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    }
    /// 回收与读事件的回调和调用方共享（`Mutex` 不可复制，放进引用里）
    private final class Shared: Sendable { let state = Mutex(State()) }
    private let shared = Shared()
    /// 脱离 App 的进程的标准错误：已删掉名字的临时文件（只剩描述符），进程退出后随最后一个描述符关闭而释放
    private let errorFile: Int32?
    private static let stderrLimit = 4096

    /// `environment` 是完整的环境（nil 继承本进程的）；`directory` 为 nil 时用本进程的工作目录。
    /// 标准错误只留末尾（`stderrTail`）给退出原因，`keepErrors` 为 false 时丢掉。
    init(
        _ executable: URL, _ arguments: [String], directory: URL? = nil, environment: [String: String]? = nil,
        placement: Placement, input inputMode: Input = .null, output outputMode: Output = .null, keepErrors: Bool = true
    ) throws {
        var opened: [Int32] = []
        defer { for fd in opened { close(fd) } }  // 本进程这端以外的都在启动后关掉
        func pipe() throws -> (read: Int32, write: Int32) {
            var fds: [Int32] = [0, 0]
            guard Darwin.pipe(&fds) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            // 本进程这端不进别的子进程（同时起的其他进程若继承了写端，这边就永远等不到 EOF）
            for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            return (fds[0], fds[1])
        }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        var input: Int32?
        switch inputMode {
        case .null:
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        case .pipe:
            let stdin = try pipe()
            opened.append(stdin.read)
            input = stdin.write
            posix_spawn_file_actions_adddup2(&actions, stdin.read, STDIN_FILENO)
        case .lifeline:
            let lifeline = try pipe()
            opened += [lifeline.read, lifeline.write]
            posix_spawn_file_actions_adddup2(&actions, lifeline.read, STDIN_FILENO)
            posix_spawn_file_actions_adddup2(&actions, lifeline.write, 3)
        }
        var stdout: Int32?
        if outputMode == .null {
            posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        } else {
            let out = try pipe()
            opened.append(out.write)
            stdout = out.read
            posix_spawn_file_actions_adddup2(&actions, out.write, STDOUT_FILENO)
        }
        var stderr: Int32?
        var errorFile: Int32?
        if !keepErrors {
            posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        } else if placement == .detached {
            // 管道在 App 退出后就断了，它再写标准错误会失败：写进临时文件
            let file = try Self.scratchFile()
            errorFile = file
            posix_spawn_file_actions_adddup2(&actions, file, STDERR_FILENO)
        } else {
            let err = try pipe()
            opened.append(err.write)
            stderr = err.read
            posix_spawn_file_actions_adddup2(&actions, err.write, STDERR_FILENO)
        }
        if let directory { posix_spawn_file_actions_addchdir(&actions, directory.path) }

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // 信号处置与屏蔽恢复默认：忽略的信号会跨 exec 继承（测试进程、App 都可能忽略着 SIGTERM），子进程就收不到结束信号
        var signals = sigset_t()
        sigfillset(&signals)
        posix_spawnattr_setsigdefault(&attributes, &signals)
        sigemptyset(&signals)
        posix_spawnattr_setsigmask(&attributes, &signals)
        let placed: Int32 = switch placement {
        case .inline: 0
        case .group: POSIX_SPAWN_SETPGROUP
        case .detached: POSIX_SPAWN_SETSID
        }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | placed))
        if placement == .group { posix_spawnattr_setpgroup(&attributes, 0) }
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = (environment ?? ProcessInfo.processInfo.environment).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard code == 0 else {
            opened += [input, stdout, stderr, errorFile].compactMap { $0 }
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        self.pid = pid
        self.placement = placement
        self.input = input
        self.errorFile = errorFile
        if let input { _ = fcntl(input, F_SETNOSIGPIPE, 1) }

        let shared = shared
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
        if let stderr {
            Self.read(stderr) { chunk in
                shared.state.withLock {
                    $0.stderr.append(chunk)
                    if $0.stderr.count > Self.stderrLimit { $0.stderr = Data($0.stderr.suffix(Self.stderrLimit)) }
                }
            } done: {}
        }
        Self.reap(pid, group: placement == .group, shared: shared)
    }

    deinit {
        if let errorFile { close(errorFile) }
    }

    // MARK: 一次性的命令

    /// 跑一个命令（标准输入、标准错误是空设备），取它的退出码与标准输出（`collect` 为 false 时不接管，常驻的后代继承了管道就永远读不到结尾）。
    /// 自成进程组：超过 `timeout` 时结束它连同它起的整组（不理 SIGTERM、握着输出管道的子进程也一样），返回 nil；无法启动也返回 nil。
    /// 取消调用方不影响它：超时照样结束，退出码照实取。
    @concurrent public static func run(
        _ executable: URL, _ arguments: [String], directory: URL? = nil, environment: [String: String]? = nil, timeout: Duration? = nil,
        collect: Bool = true
    ) async -> (status: Int32, output: String)? {
        guard let process = try? ChildProcess(
            executable, arguments, directory: directory, environment: environment, placement: .group, output: collect ? .raw : .null,
            keepErrors: false)
        else { return nil }
        // 包一层不继承取消的任务（`withTaskCancellationShield` 要 macOS 27，部署目标是 26）
        return await Task {
            async let output = process.output.reduce(into: Data()) { $0 += $1 }
            guard await process.exited(within: timeout) else {
                process.end()
                return nil  // 不等输出读完：它起的后代可能还握着管道（离开时读取随之取消）
            }
            return (process.status ?? -1, String(decoding: await output, as: UTF8.self))
        }.value
    }

    /// 起一个要等人的命令（打开浏览器登录）：标准输入、输出、错误都是空设备，自成进程组。`waitForExit()` 等它结束，`end()` 提前结束它。
    public static func launch(_ executable: URL, _ arguments: [String], environment: [String: String]) throws -> ChildProcess {
        try ChildProcess(executable, arguments, environment: environment, placement: .group, keepErrors: false)
    }

    /// 等它退出，返回退出码（被信号结束为 nil）；不随调用方取消提前返回。
    public func waitForExit() async -> Int32? {
        _ = await Task { await exited(within: nil) }.value
        return status
    }

    // MARK: 读写

    /// 写一行（补上换行）。
    func write(_ line: Data) {
        guard let input else { return }
        let shared = shared
        writes.async {
            guard shared.state.withLock({ $0.inputOpen }) else { return }
            _ = writeAll(input, line + [0x0A])
        }
    }

    /// 关标准输入（排在已发出的写入之后）：说行协议的几家都把 EOF 当作"收尾退出"。
    func closeInput() {
        guard let input else { return }
        let shared = shared
        writes.async {
            let open = shared.state.withLock { s in defer { s.inputOpen = false }; return s.inputOpen }
            if open { close(input) }
        }
    }

    // MARK: 停与等

    /// 请它马上退出、不等：SIGTERM，宽限期过了还没走就 SIGKILL（自成进程组的整组结束）。之后等它退出的一定等得到。
    public func end(grace: Duration = AgentTimeouts.endGrace) {
        Darwin.kill(pid, SIGTERM)
        Task { [self] in
            if await !exited(within: grace) { kill() }
        }
    }

    /// 让它退出并等到退出：先关标准输入请它收尾，不走再 SIGTERM，还不走就 SIGKILL。之后 `exited()` 报 nil。
    /// 调用方取消不让它跳过收尾（SIGKILL 不给它清理的机会，如 Claude Code 的收件箱 socket 就会留在 /tmp/cc-socks 里）。
    func stop(grace: Duration = AgentTimeouts.endGrace) async {
        shared.state.withLock { $0.stopping = true }
        closeInput()
        await Task { [self] in
            if await exited(within: grace) { return }
            Darwin.kill(pid, SIGTERM)
            if await exited(within: grace) { return }
            kill()
            _ = await exited(within: nil)
        }.value
    }

    private func kill() {
        if placement == .group { killpg(pid, SIGKILL) } else { Darwin.kill(pid, SIGKILL) }
    }

    /// 等进程退出，返回退出原因（退出码或信号与标准错误的末尾）；是 `stop()` 让它退出的返回 nil。可以多处一起等，不随取消提前返回。
    func exited() async -> String? {
        _ = await Task { await exited(within: nil) }.value  // 不继承取消
        let (status, stopping) = shared.state.withLock { ($0.status ?? -1, $0.stopping) }
        if stopping { return nil }
        let code = (status & 0x7F) == 0 ? "退出码 \((status >> 8) & 0xFF)" : "被信号 \(status & 0x7F) 结束"
        let tail = stderrTail
        return tail.isEmpty ? code : "\(code)：\(tail)"
    }

    /// 退出码；还没退出或被信号结束为 nil。
    var status: Int32? {
        shared.state.withLock { $0.status }.flatMap { ($0 & 0x7F) == 0 ? ($0 >> 8) & 0xFF : nil }
    }

    /// 标准错误的末尾（至多 4 KB），去掉首尾空白。
    var stderrTail: String {
        var data = shared.state.withLock { $0.stderr }
        if let errorFile {
            var info = stat()
            if fstat(errorFile, &info) == 0, info.st_size > 0 {
                let count = Int(min(info.st_size, off_t(Self.stderrLimit)))
                var buffer = [UInt8](repeating: 0, count: count)
                if pread(errorFile, &buffer, count, info.st_size - off_t(count)) == count { data = Data(buffer) }
            }
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 等进程退出，至多 `limit`（nil 不限时）；退出了返回 true。到点或调用方取消时不管有没有退出都立刻返回 false，好接着升级信号。
    func exited(within limit: Duration?) async -> Bool {
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
                if Task.isCancelled { return giveUp() }
                guard let limit else { return }
                Task {
                    try? await Task.sleep(for: limit)
                    giveUp()
                }
            }
        } onCancel: { giveUp() }
    }

    // MARK: 底层

    /// 进程退出事件到了就回收（注册前就已退出的事件不会来：注册后再非阻塞地回收一次兜住），自成进程组的再结束组里剩下的。
    /// 事件源在进程退出前一直握着自己，与这个对象的生死无关（脱离 App 的 Pi 由它回收）。
    private static func reap(_ pid: pid_t, group: Bool, shared: Shared) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        let collect: @Sendable (Int32) -> Void = { options in
            var status: Int32 = 0
            guard waitpid(pid, &status, options) == pid else { return }
            source.cancel()
            if group { killpg(pid, SIGKILL) }
            let waiters = shared.state.withLock { s in
                s.status = status
                defer { s.waiters = [:] }
                return s.waiters.values
            }
            for waiter in waiters { waiter.resume(returning: true) }
        }
        source.setEventHandler { collect(0) }
        source.resume()
        collect(WNOHANG)
    }

    /// 读到 EOF：每次读事件读出的块交给 `chunk`，结束时关描述符、调 `done`。
    private static func read(_ fd: Int32, chunk: @escaping @Sendable (Data) -> Void, done: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "cuepad.child.read"))
        let buffer = ReadBuffer()
        source.setEventHandler {
            guard let data = buffer.read(from: fd) else { return source.cancel() }
            chunk(data)
        }
        source.setCancelHandler {
            close(fd)
            done()
        }
        source.resume()
    }

    private static func scratchFile() throws -> Int32 {
        var template = Array((NSTemporaryDirectory() + "cuepad-child-XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        template.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }
}

#endif
