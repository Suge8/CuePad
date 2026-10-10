#if os(macOS)
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

    /// 是 socket、属于当前用户、且只有属主可读写。扩展 bind 之后才 chmod 0600，
    /// 之前的瞬间权限偏宽，跳过即可：chmod 的属性变更事件会触发重扫。
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
    enum ConnectError: Error { case pathTooLong, socket(Int32), connect(Int32), peerNotOwner }

    let lines: AsyncStream<Data>
    private let fd: Int32
    private let source: DispatchSourceRead
    private let writeQueue = DispatchQueue(label: "cuepi.socket.write")
    /// fd 是进程全局的：关闭后排队中的写入不能落到被复用的描述符上，所以写与关闭互斥；值是 fd 是否已关闭
    private let closed = Mutex(false)

    /// 连接到本机 socket：本地 connect 是微秒级；对端进程被冻结时也由内核 backlog 接住，不会阻塞。
    init(path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ConnectError.socket(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: addr.sun_path) else { Darwin.close(fd); throw ConnectError.pathTooLong }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path.utf8) }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { let e = errno; Darwin.close(fd); throw ConnectError.connect(e) }

        // 对端必须是当前用户的进程
        var euid: uid_t = 0, egid: gid_t = 0
        guard getpeereid(fd, &euid, &egid) == 0, euid == getuid() else { Darwin.close(fd); throw ConnectError.peerNotOwner }

        self.fd = fd
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        lines = stream
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "cuepi.socket.read"))
        self.source = source
        let buffer = LineBuffer()
        source.setEventHandler {
            var chunk = [UInt8](repeating: 0, count: 256 * 1024)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { source.cancel(); return }
            for line in buffer.append(chunk[0..<n]) { continuation.yield(line) }
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

    func write(_ data: Data) {
        writeQueue.async { [self] in
            closed.withLock {
                guard !$0 else { return }
                data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                        if n <= 0 { return } // 对端已断开：读端会随即 EOF
                        offset += n
                    }
                }
            }
        }
    }

    func close() { source.cancel() }
}

private final class LineBuffer: @unchecked Sendable {
    private var data = Data()

    func append(_ bytes: ArraySlice<UInt8>) -> [Data] {
        data.append(contentsOf: bytes)
        var out: [Data] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let line = data[data.startIndex..<newline]
            if !line.isEmpty { out.append(Data(line)) }
            data = Data(data[data.index(after: newline)...])
        }
        return out
    }
}

/// 进程退出通知（kqueue `NOTE_EXIT`，非子进程也可用）。连接的 EOF 在进程退出过程中就会到达，
/// 此时进程可能还没被父进程回收（`kill(pid, 0)` 仍成功），所以强杀后的残留清理由它触发，而不是轮询。
final class ProcessExitWatcher {
    private let source: DispatchSourceProcess

    init(pid: Int32, onExit: @escaping @Sendable () -> Void) {
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler(handler: onExit)
        source.resume()
    }

    func cancel() { source.cancel() }
}
#endif
