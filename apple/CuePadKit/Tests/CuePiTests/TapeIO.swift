#if os(macOS)
import Darwin
import Foundation
import Synchronization

// MARK: - 底层 I/O

/// 替身那一头：写一行给它（串行，线程安全）。
final class Stub: @unchecked Sendable {
    let fd: Int32
    let pid: Int32
    private let lock = Mutex(())
    /// 已经让它退出（之后它断开不算被强杀）
    var told: Bool {
        get { toldFlag.load(ordering: .relaxed) }
        set { toldFlag.store(newValue, ordering: .relaxed) }
    }
    private let toldFlag = Atomic(false)

    private let waiting = Mutex<(gone: Bool, list: [CheckedContinuation<Void, Never>])>((false, []))

    init(fd: Int32, pid: Int32) { self.fd = fd; self.pid = pid }

    func send(_ line: String) {
        lock.withLock { _ in _ = UnixSocket.writeAll(fd, Data((line + "\n").utf8)) }
    }

    /// 等它写进标准输出的都被 CuePad 读走（替身回 "f"；替身没了也算）。
    func drained() async {
        await withCheckedContinuation { continuation in
            let gone = waiting.withLock { waiting in
                if !waiting.gone { waiting.list.append(continuation) }
                return waiting.gone
            }
            if gone { continuation.resume() } else { send("f") }
        }
    }

    /// 回了 "f"；`gone`：替身断开了，之后的等待都不等。
    func acknowledged(gone: Bool = false) {
        let list = waiting.withLock { waiting in
            defer { waiting.list = [] }
            waiting.gone = waiting.gone || gone
            return waiting.list
        }
        for continuation in list { continuation.resume() }
    }
}

/// 回放时 CuePad 那一端的一条 socket 连接。
final class Connection: @unchecked Sendable {
    let fd: Int32
    private let lock = Mutex(false)

    init(fd: Int32) { self.fd = fd }

    func write(_ text: String) {
        lock.withLock { closed in if !closed { _ = UnixSocket.writeAll(fd, Data(text.utf8)) } }
    }

    func close() {
        lock.withLock { closed in
            guard !closed else { return }
            closed = true
            shutdown(fd, SHUT_RDWR)
        }
    }
}

/// 阻塞地一行一行读一个描述符（读到头为 nil）。
final class LineReader: @unchecked Sendable {
    let fd: Int32
    private var lines = LineSplitter()
    private var ready: [Data] = []
    private var done = false

    init(fd: Int32) { self.fd = fd }

    /// - Parameter partial: 读到头时最后没有换行的那一段也算一行。
    func next(partial: Bool = false) -> Data? {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while ready.isEmpty && !done {
            let n = read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 {
                done = true
                if partial, let rest = lines.flush() { ready.append(rest) }
                break
            }
            ready += lines.append(Data(buffer[0..<n]))
        }
        return ready.isEmpty ? nil : ready.removeFirst()
    }
}

struct LineSplitter {
    private var pending = Data()

    mutating func append(_ data: Data) -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(Data(pending[pending.startIndex..<newline]))
            pending = Data(pending[(newline + 1)...])
        }
        return lines
    }

    mutating func flush() -> Data? {
        defer { pending = Data() }
        return pending.isEmpty ? nil : pending
    }
}

enum UnixSocket {
    struct Failed: Error { let path: String; let code: Int32 }

    /// 像 Pi 扩展那样在临时名上 listen、收紧成 0600 再改名进来：桥只连 0600 的 socket，名字出现时它已经在 listen。
    /// - Parameter creatingDirectory: 所在目录不在就建（0700），像 Pi 扩展那样。
    static func listen(_ path: String, creatingDirectory: Bool = false) throws -> Int32 {
        if creatingDirectory { mkdir((path as NSString).deletingLastPathComponent, 0o700) }
        unlink(path)
        let pending = (path as NSString).deletingLastPathComponent + "/.\(UInt32.random(in: 0...UInt32.max)).tmp"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = address(pending)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, Darwin.listen(fd, 64) == 0, chmod(pending, 0o600) == 0, rename(pending, path) == 0 else {
            let code = errno; close(fd); throw Failed(path: path, code: code)
        }
        return fd
    }

    static func connect(_ path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = address(path)
        let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard connected == 0 else { let code = errno; close(fd); throw Failed(path: path, code: code) }
        return fd
    }

    /// 在监听的描述符上收连接，每个交给 `handle`（不在主线程）；取消返回的事件源即停止并关掉它。
    static func accept(_ fd: Int32, _ handle: @escaping @Sendable (Int32) -> Void) -> DispatchSourceRead {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
        source.setEventHandler {
            while true {
                let client = Darwin.accept(fd, nil, nil)
                guard client >= 0 else { return }
                _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
                var one: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                handle(client)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    static func read(_ fd: Int32, _ chunk: (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return }
            chunk(Data(buffer[0..<n]))
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    private static func address(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8.prefix($0.count - 1)) }
        return addr
    }
}

/// 录制时替身背后的真 Agent：自成进程组（收尾时整组结束），三个标准描述符接到这里。
final class RealProcess: Sendable {
    let pid: pid_t
    let stdin: Int32
    let stdout: Int32
    let stderr: Int32

    init(_ executable: URL, _ arguments: [String], cwd: String, environment: [String: String]) throws {
        var fds = [[Int32]](repeating: [0, 0], count: 3)
        for i in 0..<3 {
            guard Darwin.pipe(&fds[i]) == 0 else { throw POSIXError(.EIO) }
            for fd in fds[i] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        }
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, fds[0][0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fds[1][1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fds[2][1], STDERR_FILENO)
        if !cwd.isEmpty { posix_spawn_file_actions_addchdir(&actions, cwd) }
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var every = sigset_t(), none = sigset_t()
        sigfillset(&every)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &every)
        posix_spawnattr_setsigmask(&attributes, &none)
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        for fd in [fds[0][0], fds[1][1], fds[2][1]] { close(fd) }
        guard code == 0 else { throw POSIXError(.init(rawValue: code) ?? .EIO) }
        self.pid = pid
        stdin = fds[0][1]
        stdout = fds[1][0]
        stderr = fds[2][0]
        _ = fcntl(stdin, F_SETNOSIGPIPE, 1)
    }

    func closeInput() { close(stdin) }

    /// 阻塞到退出，返回 waitpid 的状态。
    func wait() -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        return status
    }
}
#endif
