#if os(macOS)
import CueStore
import Darwin
import Foundation
import Synchronization

/// 目录与 socket 文件的属主/权限校验（扩展端做同样的检查）。
enum PiSocketDirectory {
    /// `sun_path` 上限 104 字节；文件名 `<uuid>.<pid>.sock` 最长约 52 字节，目录路径再留出余量
    static let maxDirectoryPathLength = 50

    static func prepare(_ directory: URL) throws {
        guard directory.path.utf8.count <= maxDirectoryPathLength else { throw PiBridgeError.socketDirectoryTooLong }
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST {
            throw PiBridgeError.insecureSocketDirectory("cannot create \(directory.path): \(String(cString: strerror(errno)))")
        }
        var st = stat()
        guard lstat(directory.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else {
            throw PiBridgeError.insecureSocketDirectory("\(directory.path) is not a directory")
        }
        guard st.st_uid == getuid(), st.st_mode & 0o777 == 0o700 else {
            throw PiBridgeError.insecureSocketDirectory("\(directory.path) must be owned by you with mode 0700")
        }
    }

    /// 是 socket、属于当前用户、且只有属主可读写（扩展收紧成 0600 后才把它改名进来）。
    static func isOwnSocket(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFSOCK && st.st_uid == getuid() && st.st_mode & 0o077 == 0
    }

    /// 文件名 `<sessionId>.<pid>.sock` 中的 pid
    static func pid(fromSocketName name: String) -> Int32? {
        let parts = name.split(separator: ".")
        guard parts.count >= 3, parts.last == "sock" else { return nil }
        return Int32(parts[parts.count - 2])
    }

    static func processIsDead(_ pid: Int32) -> Bool { kill(pid, 0) == -1 && errno == ESRCH }

    /// 认出一个具体的文件：删掉再在同一路径建的不算同一个（inode 号可能被复用，加上创建时间）。
    struct FileIdentity: Equatable {
        let inode: ino_t
        let bornSeconds: Int
        let bornNanoseconds: Int
    }

    static func identity(of path: String) -> FileIdentity? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return FileIdentity(inode: st.st_ino, bornSeconds: st.st_birthtimespec.tv_sec, bornNanoseconds: st.st_birthtimespec.tv_nsec)
    }
}

/// 一条 Unix socket 连接：按行产出，EOF（含对端被强杀）即 `lines` 结束。
/// 读在专用串行队列的 DispatchSource 上；写在另一条队列上阻塞完成（图片可达数 MB）。
final class PiSocketConnection: Sendable {
    let lines: AsyncStream<Data>
    private let fd: Int32
    private let source: DispatchSourceRead
    private let writeQueue = DispatchQueue(label: "cuepi.socket.write")
    /// fd 是进程全局的：关闭后排队中的写入不能落到被复用的描述符上，所以写与关闭互斥；值是 fd 是否已关闭
    private let closed = Mutex(false)

    /// 连接到本机 socket：本地 connect 是微秒级；对端进程被冻结时也由内核 backlog 接住，不会阻塞。
    convenience init(path: String) throws {
        try self.init(peer: try UnixSocket.connect(path))
    }

    /// 接管一个已连上的描述符（connect 得到的，或监听端 accept 得到的）。对端必须是当前用户的进程，否则关掉它并抛错。
    init(peer fd: Int32) throws {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard UnixSocket.peerIsOwner(fd) else { Darwin.close(fd); throw UnixSocket.Failure.peerNotOwner }

        self.fd = fd
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        lines = stream
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "cuepi.socket.read"))
        self.source = source
        let buffer = ReadBuffer(), lines = LineReader()
        source.setEventHandler {
            guard let chunk = buffer.read(from: fd) else { return source.cancel() }
            for line in lines.split(chunk) { continuation.yield(line) }
        }
        source.setCancelHandler { [self] in
            shutdown(fd, SHUT_RDWR) // 让阻塞中的写入失败返回，释放 closed 的锁
            closed.withLock {
                $0 = true
                Darwin.close(fd)
            }
            continuation.finish()
        }
        source.resume()
    }

    /// `thenClose`：写完（排在之前的写入之后）再关连接。
    func write(_ data: Data, thenClose: Bool = false) {
        writeQueue.async { [self] in
            defer { if thenClose { source.cancel() } }
            closed.withLock {
                guard !$0 else { return }
                writeAll(fd, data)  // 对端已断开时失败：读端会随即 EOF
            }
        }
    }

    func close() { source.cancel() }
}

extension PiProcess {
    /// 此刻用这个 pid 的进程（带启动时刻）；没有为 nil。
    public static func running(pid: Int32) -> PiProcess? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return PiProcess(pid: pid, startedAt: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec))
    }

    /// 还是那一个进程在跑（pid 被复用的不算）。
    public var isRunning: Bool { Self.running(pid: pid) == self }

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(startedAt) / 1_000_000) }
}

/// 盯一个目录本身的增删改名（kqueue），在主线程回调。不用 FSEvents：fseventsd 转发的事件实测晚到 0.4 到 20 多秒，
/// 后台唤醒的会话、终端里新开的会话都要等它才上桥。
@MainActor
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject

    init(_ directory: URL, onChange: @escaping @MainActor () -> Void) throws {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            throw PiBridgeError.insecureSocketDirectory("cannot watch \(directory.path): \(String(cString: strerror(errno)))")
        }
        source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated(onChange) }
        source.setCancelHandler { close(descriptor) }
        source.resume()
    }

    func cancel() { source.cancel() }

    deinit { source.cancel() }
}

/// 进程退出通知（kqueue `NOTE_EXIT`，非子进程也可用），回调在主线程、至多一次。注册时进程已经不在了（事件不会再来）也通知。
/// 连接的 EOF 在进程退出过程中就会到达，此时进程可能还没被父进程回收（`kill(pid, 0)` 仍成功），所以强杀后的残留清理由它触发，而不是轮询。
@MainActor
final class ProcessExitWatcher {
    private let source: DispatchSourceProcess

    init(pid: Int32, onExit: @escaping @MainActor () -> Void) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        self.source = source
        // 取消即放开回调（连同它对事件源的引用）
        let fire: @MainActor () -> Void = {
            guard !source.isCancelled else { return }
            source.cancel()
            onExit()
        }
        source.setEventHandler { MainActor.assumeIsolated(fire) }
        source.resume()
        if kill(pid, 0) == -1 && errno == ESRCH { DispatchQueue.main.async { MainActor.assumeIsolated(fire) } }
    }

    func cancel() { source.cancel() }

    deinit { source.cancel() }
}
#endif
