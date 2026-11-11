#if os(macOS)
import Darwin
import Foundation

/// 对端已关或出错返回 false。
@discardableResult
func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}

/// 只在一条串行队列上用（读缓冲复用，不是每次读都分配 256 KB）。EOF 或读失败返回 nil。
final class ReadBuffer: @unchecked Sendable {
    private var scratch = [UInt8](repeating: 0, count: 256 * 1024)

    func read(from fd: Int32) -> Data? {
        while true {
            let n = scratch.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 && errno == EINTR { continue }
            return n > 0 ? Data(scratch[0..<n]) : nil
        }
    }
}

/// 不含换行与行尾的 `\r`、不含空行；每块只丢弃一次已切出的部分。只在一条串行队列上用。
final class LineReader: @unchecked Sendable {
    private var pending = Data()

    func split(_ chunk: Data) -> [Data] {
        pending.append(chunk)
        var lines: [Data] = []
        var start = 0
        pending.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while start < raw.count, let hit = memchr(base + start, 0x0A, raw.count - start) {
                var end = base.distance(to: UnsafeRawPointer(hit))
                let next = end + 1
                if end > start, raw[end - 1] == 0x0D { end -= 1 }
                if end > start { lines.append(Data(bytes: base + start, count: end - start)) }
                start = next
            }
        }
        pending.removeSubrange(0..<start)
        return lines
    }
}

enum UnixSocket {
    enum Failure: Error, Equatable { case pathTooLong, socket(Int32), connect(Int32), peerNotOwner }

    /// 连上 `path`：本地 connect 是微秒级，对端进程被冻结时也由内核 backlog 接住，不会阻塞。写端不给本进程发 SIGPIPE。
    static func connect(_ path: String) throws(Failure) -> Int32 {
        let fd = try open()
        let rc = try withAddress(path, fd) { Darwin.connect(fd, $0, $1) }
        guard rc == 0 else { let code = errno; close(fd); throw .connect(code) }
        return fd
    }

    /// 在 `path` 上监听（上次没删掉的 socket 文件先删），只有属主能连（0600）；非阻塞，配合读事件 accept。
    static func listen(_ path: String) throws(Failure) -> Int32 {
        let fd = try open()
        unlink(path)
        let bound = try withAddress(path, fd) { bind(fd, $0, $1) }
        guard bound == 0, chmod(path, 0o600) == 0, Darwin.listen(fd, 64) == 0 else { let code = errno; close(fd); throw .connect(code) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        return fd
    }

    static func peerIsOwner(_ fd: Int32) -> Bool {
        var euid: uid_t = 0, egid: gid_t = 0
        return getpeereid(fd, &euid, &egid) == 0 && euid == getuid()
    }

    private static func open() throws(Failure) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .socket(errno) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    private static func withAddress(_ path: String, _ fd: Int32, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) throws(Failure) -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { close(fd); throw .pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path.utf8) }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}
#endif
