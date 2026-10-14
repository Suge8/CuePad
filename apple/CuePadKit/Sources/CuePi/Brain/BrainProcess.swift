#if os(macOS)
import Darwin
import Foundation
import Synchronization

/// 大脑的子进程：标准输入写一行一个 JSON，标准输出读一行一个 JSON，标准错误只留末尾给退出原因。
/// - 自成一个进程组（`POSIX_SPAWN_SETPGROUP`）：进程退出后把组里剩下的（它起的、没跟着走的子进程）一并结束，不留孤儿；
/// - 只继承三个标准描述符（`POSIX_SPAWN_CLOEXEC_DEFAULT`）：App 打开的文件与连接不漏进去；
/// - 写端设了 `F_SETNOSIGPIPE`：进程已退出时写入只报错，不给 App 发 SIGPIPE。
final class BrainProcess: Sendable {
    let pid: pid_t
    private let input: Int32
    let lines: AsyncStream<Data>
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

    init(executable: URL, arguments: [String], directory: URL, environment: [String: String]) throws {
        let stdin = try Self.pipe(), stdout = try Self.pipe(), stderr = try Self.pipe()
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin.read, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdout.write, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderr.write, STDERR_FILENO)
        posix_spawn_file_actions_addchdir(&actions, directory.path)
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, 0)
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

    /// 写一条 JSON（一行）。
    func write(_ object: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        data.append(0x0A)
        let failed = data.withUnsafeBytes { bytes -> Bool in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(input, bytes.baseAddress! + offset, bytes.count - offset)
                if n < 0 { if errno == EINTR { continue }; return true }
                offset += n
            }
            return false
        }
        if failed { throw CueBrainError.notRunning }
    }

    /// 关标准输入：三家都把 EOF 当作"收尾退出"。
    func closeInput() {
        let open = shared.state.withLock { s in defer { s.inputOpen = false }; return s.inputOpen }
        if open { close(input) }
    }

    /// 让它退出并等到退出：先关标准输入请它收尾，不走再 SIGTERM，还不走就结束整个进程组。
    func stop(grace: Duration = .seconds(5)) async {
        shared.state.withLock { $0.stopping = true }
        closeInput()
        if await exited(within: grace) { return }
        kill(pid, SIGTERM)
        if await exited(within: grace) { return }
        killpg(pid, SIGKILL)
        _ = await exited(within: nil)
    }

    /// 读完标准输出（逐行交给 `handle`）后等进程退出，返回退出原因；是 `stop()` 让它退出的返回 nil。
    func pump(_ handle: (Data) async -> Void) async -> String? {
        for await line in lines { await handle(line) }
        _ = await exited(within: nil)
        let (status, stopping, stderr) = shared.state.withLock { ($0.status ?? -1, $0.stopping, $0.stderr) }
        if stopping { return nil }
        let code = (status & 0x7F) == 0 ? "退出码 \((status >> 8) & 0xFF)" : "被信号 \(status & 0x7F) 结束"
        let tail = String(decoding: stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return tail.isEmpty ? code : "\(code)：\(tail)"
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

    /// 专用线程读到 EOF，按 `\n` 切行（JSON 字符串里的 U+2028/2029 不是行界）。
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
            close(fd)
            done()
        }
    }
}

#endif
