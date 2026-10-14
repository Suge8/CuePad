#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// CuePad 起的子进程，唯一的一套起法（Cue 的大脑、后台托管的 Claude Code 与 Codex、超时跑命令 `runCapturing`）：标准输入一行一条写入，
/// 标准输出按行读出（`lines`），标准错误只留末尾给退出原因。
/// - 自成一个进程组（`POSIX_SPAWN_SETPGROUP`）：进程退出后把组里剩下的（它起的、没跟着走的子进程）一并结束，不留孤儿；
/// - 只继承三个标准描述符（`POSIX_SPAWN_CLOEXEC_DEFAULT`）：App 打开的文件与连接不漏进去；信号处置与屏蔽都是缺省的；
/// - 写入排在一条串行队列上（大图片写进管道时不卡调用方，先后不变），写端设了 `F_SETNOSIGPIPE`：进程已退出时写入只是失败，
///   不给 App 发 SIGPIPE；关了输入之后的写入丢掉（描述符号可能已被别的文件复用）。
final class LineProcess: Sendable {
    let pid: pid_t
    let lines: AsyncStream<Data>
    private let input: Int32
    private let writes = DispatchQueue(label: "cuepad.line-process.write")
    private struct State {
        var inputOpen = true
        var stopping = false
        var stderr = Data()
        /// waitpid 拿到的状态；nil 是还没退出
        var status: Int32?
        /// 等退出的人：退出时都以 true 唤醒，限时的到点以 false 唤醒（各自只唤醒一次）
        var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    }
    /// 读线程与调用方共享（`Mutex` 不可复制，放进引用里给读线程）
    private final class Shared: Sendable { let state = Mutex(State()) }
    private let shared = Shared()
    private static let stderrLimit = 4096

    /// `directory` 为 nil 时用本进程的工作目录。`environment` 是完整的环境（不继承本进程的）。
    init(executable: URL, arguments: [String], directory: URL? = nil, environment: [String: String]) throws {
        let stdin = try Self.pipe(), stdout = try Self.pipe(), stderr = try Self.pipe()
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin.read, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdout.write, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr.write, STDERR_FILENO)
        if let directory { posix_spawn_file_actions_addchdir(&actions, directory.path) }
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // 信号的处置与屏蔽不随本进程：本进程（如测试宿主）屏蔽或忽略了 SIGTERM 时，子进程也会收不到，结束它就只剩 SIGKILL
        posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var everySignal = sigset_t(), noSignal = sigset_t()
        sigfillset(&everySignal)
        sigemptyset(&noSignal)
        posix_spawnattr_setsigdefault(&attributes, &everySignal)
        posix_spawnattr_setsigmask(&attributes, &noSignal)
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        for fd in [stdin.read, stdout.write, stderr.write] { close(fd) }
        guard code == 0 else {
            for fd in [stdin.write, stdout.read, stderr.read] { close(fd) }
            throw POSIXError(.init(rawValue: code) ?? .EIO)
        }
        self.pid = pid
        input = stdin.write
        _ = fcntl(input, F_SETNOSIGPIPE, 1)

        let (lines, emit) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        self.lines = lines
        Self.drain(stdout.read) { emit.yield($0) } done: { emit.finish() }
        let shared = shared
        Self.drain(stderr.read) { line in
            shared.state.withLock {
                $0.stderr.append(line + [0x0A])
                if $0.stderr.count > Self.stderrLimit { $0.stderr = Data($0.stderr.suffix(Self.stderrLimit)) }
            }
        } done: {}
        // 阻塞在 waitpid 的专用线程：进程退出即回收（不留僵尸），再结束组里剩下的
        let spawned = pid
        Thread.detachNewThread {
            let pid = spawned
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            killpg(pid, SIGKILL)
            let waiters = shared.state.withLock { s in
                s.status = status
                defer { s.waiters = [:] }
                return s.waiters.values
            }
            for waiter in waiters { waiter.resume(returning: true) }
        }
    }

    /// 写一行（补上换行）。
    func write(_ line: Data) {
        let shared = shared, input = input
        writes.async {
            guard shared.state.withLock({ $0.inputOpen }) else { return }
            (line + [0x0A]).withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let n = Darwin.write(input, bytes.baseAddress! + offset, bytes.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    if n <= 0 { return }  // 进程已退出：读端随即结束，等着的人在那里收尾
                    offset += n
                }
            }
        }
    }

    /// 关标准输入（排在已发出的写入之后）：这几家都把 EOF 当作"收尾退出"。
    func closeInput() {
        let shared = shared, input = input
        writes.async {
            let open = shared.state.withLock { s in defer { s.inputOpen = false }; return s.inputOpen }
            if open { close(input) }
        }
    }

    /// 请它马上退出（不关输入、不等它收尾）：SIGTERM，宽限期过了还没走就结束整个进程组。不等，返回即可接着等读端结束。
    func terminate(grace: Duration = .seconds(5)) {
        kill(pid, SIGTERM)
        Task { [self] in
            if await !exited(within: grace) { killpg(pid, SIGKILL) }
        }
    }

    /// 让它退出并等到退出：先关标准输入请它收尾，不走再 SIGTERM，还不走就结束整个进程组。之后 `exited()` 报 nil。
    func stop(grace: Duration = .seconds(5)) async {
        shared.state.withLock { $0.stopping = true }
        closeInput()
        if await exited(within: grace) { return }
        kill(pid, SIGTERM)
        if await exited(within: grace) { return }
        killpg(pid, SIGKILL)
        _ = await exited(within: nil)
    }

    /// 等进程退出，返回退出原因（退出码或信号与标准错误的末尾）；是 `stop()` 让它退出的返回 nil。可以多处一起等。
    func exited() async -> String? {
        _ = await exited(within: nil)
        let (status, stopping) = shared.state.withLock { ($0.status ?? -1, $0.stopping) }
        if stopping { return nil }
        let code = (status & 0x7F) == 0 ? "退出码 \((status >> 8) & 0xFF)" : "被信号 \(status & 0x7F) 结束"
        let tail = stderrTail
        return tail.isEmpty ? code : "\(code)：\(tail)"
    }

    /// 等进程退出，返回退出码；被信号结束的是 -1。
    func exitCode() async -> Int32 {
        _ = await exited(within: nil)
        let status = shared.state.withLock { $0.status ?? -1 }
        return (status & 0x7F) == 0 ? (status >> 8) & 0xFF : -1
    }

    /// 已经退出了。
    var hasExited: Bool { shared.state.withLock { $0.status != nil } }

    /// 标准错误的末尾（至多 4 KB）。
    var stderrTail: String {
        String(decoding: shared.state.withLock { $0.stderr }, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 等进程退出，至多 `limit`（nil 不限时）；退出了返回 true。到点不管进程有没有退出都立刻返回，好接着升级信号。
    private func exited(within limit: Duration?) async -> Bool {
        let id = UUID()
        let shared = shared
        return await withCheckedContinuation { continuation in
            let exited = shared.state.withLock { s in
                if s.status == nil { s.waiters[id] = continuation }
                return s.status != nil
            }
            if exited { return continuation.resume(returning: true) }
            guard let limit else { return }
            Task {
                try? await Task.sleep(for: limit)
                shared.state.withLock { $0.waiters.removeValue(forKey: id) }?.resume(returning: false)
            }
        }
    }

    private static func pipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard Darwin.pipe(&fds) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        // 本进程这端不进别的子进程（同时起的其他进程若继承了写端，这边就永远等不到 EOF）
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        return (fds[0], fds[1])
    }

    /// 专用线程读到 EOF，按 `\n` 切行（JSON 字符串里的 U+2028/2029 不是行界）；最后没有换行的那一段也算一行。
    private static func drain(_ fd: Int32, line: @escaping @Sendable (Data) -> Void, done: @escaping @Sendable () -> Void) {
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var pending = Data()
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                pending.append(contentsOf: buffer[0..<n])
                while let nl = pending.firstIndex(of: 0x0A) {
                    var piece = pending[pending.startIndex..<nl]
                    if piece.last == 0x0D { piece = piece.dropLast() }
                    if !piece.isEmpty { line(Data(piece)) }
                    pending.removeSubrange(pending.startIndex...nl)
                }
            }
            if pending.last == 0x0D { pending.removeLast() }
            if !pending.isEmpty { line(pending) }
            close(fd)
            done()
        }
    }
}
#endif
